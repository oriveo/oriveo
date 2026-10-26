package ai.oriveo.community.core.voice

import android.app.UiAutomation
import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.data.repository.ProviderRepository
import java.io.File
import kotlinx.coroutines.flow.first
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.koin.mp.KoinPlatform

/**
 * Crash-recovery probe driven by an external emulator script (scenario crash-recovery). Not a standalone test:
 * phase 1 starts a production-wired dictation (WAV-backed capture, production recording store), writes a ready
 * marker and holds until the script runs `am force-stop`; phase 2 runs in the relaunched process, binds the Koin
 * production controller to the same slot and expects Interrupted with a recording that exports to m4a.
 */
@RunWith(AndroidJUnit4::class)
class CrashRecoveryProbeTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext

    @Test
    fun phase1RecordAndHold() {
        if (!isProbeRun()) return
        val marker = readyMarker(context).apply { delete() }
        val store = RecordingStore.production(context)
        store.complete(SLOT_KEY)
        shell("pm grant ${context.packageName} android.permission.RECORD_AUDIO")
        val wav = instrumentation.context.assets.open(ASSET).use { it.readBytes() }
        val koin = KoinPlatform.getKoin()
        val real = koin.get<DictationEngineFactory>()
        // Recording with a file only needs a Pipe route; the emulator's real route depends on installed models.
        val engines = object : DictationEngineFactory by real {
            override suspend fun systemRoute(language: String?): SystemSTTRoute =
                SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, language ?: LANGUAGE)
        }
        lateinit var controller: DictationController
        // Same wiring as AppModule except the capture source and the route above.
        instrumentation.runOnMainSync {
            controller = DictationController(
                engines = engines,
                settings = koin.get(),
                catalog = koin.get<VoiceCatalogClient>().asDictationCatalogSource(),
                providers = { koin.get<ProviderRepository>().observeAll().first() },
                capture = AudioRecordCapture({ LoopingWavSource(wav) }),
                store = store,
                encoderFactory = { MediaCodecAacEncoder() },
                permission = koin.get<AndroidMicrophonePermission>(),
                environment = AndroidDictationEnvironment(context, koin.get(), koin.get()),
            )
            controller.start(SLOT_KEY)
        }
        val deadline = SystemClock.uptimeMillis() + RECORDING_TIMEOUT_MS
        while (controller.state.value !is DictationState.Recording && SystemClock.uptimeMillis() < deadline) {
            SystemClock.sleep(POLL_MS)
        }
        val state = controller.state.value
        if (state !is DictationState.Recording) fail("not recording within ${RECORDING_TIMEOUT_MS}ms; state=$state")
        marker.parentFile?.mkdirs()
        marker.writeText(SLOT_KEY)
        Log.i(TAG, "recording; ready marker written at ${marker.path}")
        // The script force-stops the process while this sleeps; reaching the end means nobody killed it.
        SystemClock.sleep(HOLD_MS)
        fail("process was not force-stopped within ${HOLD_MS}ms")
    }

    @Test
    fun phase2RecoversAfterRelaunch() {
        if (!isProbeRun()) return
        val store = RecordingStore.production(context)
        try {
            val controller = KoinPlatform.getKoin().get<DictationController>()
            instrumentation.runOnMainSync { controller.bind(SLOT_KEY) }
            val deadline = SystemClock.uptimeMillis() + RECOVERY_TIMEOUT_MS
            while (controller.state.value !is DictationState.Interrupted && SystemClock.uptimeMillis() < deadline) {
                SystemClock.sleep(POLL_MS)
            }
            assertEquals(DictationState.Interrupted(SLOT_KEY), controller.state.value)
            val meta = store.read(SLOT_KEY)
            assertNotNull("slot sidecar missing", meta)
            assertEquals(RecordingSlotStatus.Interrupted, meta!!.status)
            val audio = store.audioFile(SLOT_KEY)
            assertTrue("slot audio missing", audio.isFile && audio.length() > 0)

            val out = File(context.cacheDir, "crash-recovery-probe.m4a").apply { delete() }
            RecordingExporter.toM4a(audio, out)
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(out.path)
                assertTrue("no track in exported m4a", extractor.trackCount > 0)
                val format = extractor.getTrackFormat(0)
                val mime = format.getString(MediaFormat.KEY_MIME)
                assertTrue("track is not audio: $mime", mime?.startsWith("audio/") == true)
                val durationUs = format.getLong(MediaFormat.KEY_DURATION)
                Log.i(TAG, "recovered sidecar=${meta.durationSec}s exported=${durationUs / 1_000}ms")
                assertTrue("exported duration ${durationUs}us < $MIN_DURATION_US", durationUs >= MIN_DURATION_US)
            } finally {
                extractor.release()
                out.delete()
            }
        } finally {
            store.complete(SLOT_KEY)
            readyMarker(context).delete()
        }
    }

    /** Replays the WAV (speech + short silence) back to back so the recording never runs out of input. */
    private class LoopingWavSource(private val wav: ByteArray) : PcmSource {
        private var current = WavPcmSource(wav, trailingSilenceMs = LOOP_SILENCE_MS)

        override fun read(buffer: ShortArray, offset: Int, size: Int): Int {
            if (current.drained.count == 0L) current = WavPcmSource(wav, trailingSilenceMs = LOOP_SILENCE_MS)
            return current.read(buffer, offset, size)
        }

        override fun observeSilenced(onSilenced: () -> Unit): () -> Unit = {}

        override fun stop() = current.stop()

        override fun release() = current.release()
    }

    /**
     * No-op unless the driver script passed `-e voiceProbe crash-recovery`, keeping it out of full connected runs.
     * Plain return instead of Assume: the connected-test XML reports AssumptionViolatedException as a failure.
     */
    private fun isProbeRun(): Boolean =
        InstrumentationRegistry.getArguments().getString(PROBE_ARG) == PROBE_SCENARIO

    private fun shell(command: String): String {
        val pfd = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            .executeShellCommand(command)
        return ParcelFileDescriptor.AutoCloseInputStream(pfd).use { it.readBytes().decodeToString() }.trim()
    }

    private companion object {
        const val TAG = "CrashRecoveryProbe"
        const val SLOT_KEY = "crash-recovery-probe"
        const val PROBE_ARG = "voiceProbe"
        const val PROBE_SCENARIO = "crash-recovery"
        const val ASSET = "voice/hello-16k.wav"
        const val LANGUAGE = "en-US"
        const val LOOP_SILENCE_MS = 300L
        const val POLL_MS = 100L
        const val RECORDING_TIMEOUT_MS = 20_000L
        const val RECOVERY_TIMEOUT_MS = 20_000L
        const val HOLD_MS = 120_000L
        const val MIN_DURATION_US = 2_000_000L

        /** Must match READY_MARKER in the driver script (relative to the app's data dir). */
        fun readyMarker(context: Context) = File(context.filesDir, "voice-probe/crash-recovery.ready")
    }
}
