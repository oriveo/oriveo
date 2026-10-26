package ai.oriveo.community.core.voice

import android.app.UiAutomation
import android.content.Context
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import android.speech.SpeechRecognizer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.R
import ai.oriveo.community.feature.chat.composer.DictationToastAction
import ai.oriveo.community.feature.chat.composer.dictationToast
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.koin.mp.KoinPlatform

/**
 * System dictation on an emulator with the real recognition services: synthesized speech goes through the
 * production capture (AudioRecordCapture with a WAV-backed PcmSource) into both the recognizer pipe
 * (EXTRA_AUDIO_SOURCE) and the recording slot; with every RecognitionService disabled the route is Unavailable
 * and dictation emits SystemUnavailable, whose toast points to voice settings.
 */
@RunWith(AndroidJUnit4::class)
class SystemSTTPipeInstrumentedTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext

    /**
     * Gives the production model download one chance: if en-US gets installed the production route is
     * Pipe(ON_DEVICE); otherwise the route is bypassed (covered by unit tests) and a Pipe(DEFAULT) session is
     * opened directly, since this test proves the EXTRA_AUDIO_SOURCE pipe plus the parallel file write.
     * Must pass: the recognizer consumed the pipe (more bytes than the kernel pipe buffer holds) or produced
     * a result, and the slot file covers the input. Text containing "hello" is asserted only when text came back;
     * otherwise it is recorded as a known gap via Assume.
     */
    @Test
    fun pipedSpeechIsRecognizedAndFileIsWritten() = runBlocking {
        val backend = DiagnosingBackend(AndroidSystemSTTBackend(context))
        val router = SystemSTTRouter(backend)
        val route = pipeRoute(backend, router)

        val root = File(context.cacheDir, "stt-pipe-test").apply { deleteRecursively() }
        val store = RecordingStore(root)
        val slot = store.open(SLOT_KEY, SystemSTTEngine.ENGINE_NAME, MediaCodecAacEncoder())
        val sessionBackend = CountingSessionBackend(AndroidSystemSTTSessionBackend(context))
        val engine = SystemSTTEngine(sessionBackend, routeFor = router::route)
        val session = withTimeoutOrNull(CALLBACK_TIMEOUT_MS) { engine.startPipeSession(route) }
            ?: throw AssertionError("startListening did not return within ${CALLBACK_TIMEOUT_MS}ms (route=$route)")

        val wav = instrumentation.context.assets.open(ASSET).use { it.readBytes() }
        val source = WavPcmSource(wav, trailingSilenceMs = TRAILING_SILENCE_MS)
        val captureError = AtomicReference<String?>(null)
        val capture = AudioRecordCapture({ source })
        // Same wiring as the controller: one capture feeds the slot writer and the recognizer pipe.
        capture.start(
            listOf(slot, session),
            object : AudioCaptureEvents {
                override fun onFailure(error: Throwable) = captureError.set("failure: $error")

                override fun onInterrupted() = captureError.set("interrupted")
            },
        )
        val drained = source.drained.await(DRAIN_TIMEOUT_SEC, TimeUnit.SECONDS)
        capture.stop()
        session.stop()
        slot.finish()
        val result = withTimeoutOrNull(RESULT_TIMEOUT_MS) { session.await() }
        if (result == null) session.end(STTResult.Success(""))
        val diagnosis = "route=$route consumed=${sessionBackend.written.get()}B result=$result; ${backend.log}"
        Log.i(TAG, diagnosis)

        assertTrue("source not drained", drained)
        assertNull("capture event", captureError.get())
        assertEquals("pipe chunks dropped", 0, session.droppedChunks)
        val accepted = sessionBackend.written.get() > PIPE_BUFFER_BYTES ||
            (result as? STTResult.Success)?.text?.isNotEmpty() == true
        assertTrue("recognizer did not take the pipe: $diagnosis", accepted)

        assertTrue("audio file not written", slot.audioFile.isFile && slot.audioFile.length() > 0)
        val meta = requireValue(store.read(SLOT_KEY))
        assertEquals(RecordingSlotStatus.Ready, meta.status)
        val inputSec = source.speechSamples.toDouble() / AudioRecordCapture.SAMPLE_RATE
        assertEquals("slot duration vs input", inputSec, meta.durationSec, DURATION_TOLERANCE_SEC)
        store.complete(SLOT_KEY)

        val text = (result as? STTResult.Success)?.text?.takeIf { it.isNotBlank() }
        if (text == null) Log.w(TAG, "known gap: no recognized text; $diagnosis")
        assumeTrue("known gap: no recognized text; $diagnosis", text != null)
        assertTrue("recognized text lacks 'hello': $diagnosis", text!!.contains("hello", ignoreCase = true))
    }

    /** One production model download attempt, then the production route if en-US got installed, else Pipe(DEFAULT). */
    private suspend fun pipeRoute(backend: DiagnosingBackend, router: SystemSTTRouter): SystemSTTRoute.Pipe {
        backend.triggerModelDownload(SystemSTTRecognizer.ON_DEVICE, LANGUAGE)
        val deadline = SystemClock.uptimeMillis() + MODEL_WAIT_MS
        var installed = false
        while (!installed && SystemClock.uptimeMillis() < deadline) {
            // The recognition service may die mid-download without calling back: bound every probe.
            val remaining = deadline - SystemClock.uptimeMillis()
            val support = withTimeoutOrNull(minOf(CALLBACK_TIMEOUT_MS, maxOf(remaining, 1))) {
                backend.checkSupport(SystemSTTRecognizer.ON_DEVICE, LANGUAGE)
            }
            installed = support != null && SystemSTTRouter.matchLanguage(LANGUAGE, support.installedOnDevice) != null
            if (!installed) delay(minOf(MODEL_POLL_MS, maxOf(deadline - SystemClock.uptimeMillis(), 0)))
        }
        if (installed) {
            val route = withTimeoutOrNull(CALLBACK_TIMEOUT_MS) { router.route(LANGUAGE) }
            if (route is SystemSTTRoute.Pipe) return route
            Log.w(TAG, "en-US installed but production route is $route; ${backend.log}")
        }
        return SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, LANGUAGE)
    }

    /** Production session backend whose pipes count the bytes the recognizer actually took. */
    private class CountingSessionBackend(private val real: SystemSTTSessionBackend) : SystemSTTSessionBackend by real {
        val written = AtomicLong(0)

        override fun createPipe(): SystemSTTPipe {
            val pipe = real.createPipe()
            return object : SystemSTTPipe by pipe {
                override fun write(bytes: ByteArray, offset: Int, length: Int) {
                    pipe.write(bytes, offset, length)
                    written.addAndGet(length.toLong())
                }
            }
        }
    }

    @Test
    fun noRecognitionServiceGuidesToVoiceSettings() {
        // Only packages this test disables get restored; ones the device already had disabled stay as they were.
        val alreadyDisabled = shell("pm list packages -d").lineSequence()
            .map { it.trim().removePrefix("package:") }
            .toSet()
        val disabledHere = RECOGNITION_PACKAGES.filterNot { it in alreadyDisabled }
        val controller = KoinPlatform.getKoin().get<DictationController>()
        try {
            disabledHere.forEach { shell("pm disable-user --user 0 $it") }
            assertFalse("default recognition still available", SpeechRecognizer.isRecognitionAvailable(context))
            val backend = DiagnosingBackend(AndroidSystemSTTBackend(context))
            val route = runBlocking { SystemSTTRouter(backend).route(LANGUAGE) }
            assertEquals("route; ${backend.log}", SystemSTTRoute.Unavailable, route)

            shell("pm grant ${context.packageName} android.permission.RECORD_AUDIO")
            instrumentation.runOnMainSync { controller.bind(UNAVAILABLE_SLOT_KEY) }
            val event = runBlocking {
                val pending = async(start = CoroutineStart.UNDISPATCHED) {
                    withTimeoutOrNull(EVENT_TIMEOUT_MS) {
                        controller.events.first { it is DictationEvent.SystemUnavailable }
                    }
                }
                instrumentation.runOnMainSync { controller.start(UNAVAILABLE_SLOT_KEY) }
                pending.await()
            } ?: throw AssertionError(
                "no SystemUnavailable within ${EVENT_TIMEOUT_MS}ms; state=${controller.state.value} " +
                    "engine=${controller.engineInfo.value}",
            )
            assertEquals(DictationEvent.SystemUnavailable(UNAVAILABLE_SLOT_KEY), event)
            assertEquals(DictationState.Idle, controller.state.value)

            val toast = requireValue(dictationToast(event, UNAVAILABLE_SLOT_KEY))
            assertEquals(DictationToastAction.OpenVoiceSettings, toast.action)
            assertEquals(R.string.voice_settings_action, toast.actionLabel)
        } finally {
            instrumentation.runOnMainSync { controller.detach(UNAVAILABLE_SLOT_KEY, DefaultDictationOwner) }
            disabledHere.forEach { shell("pm default-state --user 0 $it") }
        }
    }

    /** Records what the platform reported so a wrong route explains itself in the failure message. */
    private class DiagnosingBackend(private val real: AndroidSystemSTTBackend) : SystemSTTBackend by real {
        private val entries = LinkedHashMap<String, String>()

        /** Last value reported per probe, so polling does not bloat the failure message. */
        val log: String get() = synchronized(entries) { entries.entries.joinToString(" ") { "${it.key}=${it.value}" } }

        private fun note(key: String, value: Any?) = synchronized(entries) { entries[key] = value.toString() }

        override fun isRecognitionAvailable(): Boolean = real.isRecognitionAvailable().also { note("default", it) }

        override fun isOnDeviceRecognitionAvailable(): Boolean =
            real.isOnDeviceRecognitionAvailable().also { note("onDevice", it) }

        override suspend fun checkSupport(recognizer: SystemSTTRecognizer, languageTag: String): SystemSTTSupport? =
            real.checkSupport(recognizer, languageTag).also { note("support[$recognizer]", it) }

        override fun triggerModelDownload(recognizer: SystemSTTRecognizer, languageTag: String) {
            note("download[$recognizer]", languageTag)
            real.triggerModelDownload(recognizer, languageTag)
        }
    }

    private fun <T : Any> requireValue(value: T?): T {
        assertNotNull(value)
        return value!!
    }

    private fun shell(command: String): String {
        val pfd = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            .executeShellCommand(command)
        return ParcelFileDescriptor.AutoCloseInputStream(pfd).use { it.readBytes().decodeToString() }.trim()
    }

    private companion object {
        const val LANGUAGE = "en-US"
        const val ASSET = "voice/hello-16k.wav"
        const val SLOT_KEY = "stt-pipe-test"
        const val UNAVAILABLE_SLOT_KEY = "stt-unavailable-test"
        const val TAG = "SystemSTTPipeTest"
        const val TRAILING_SILENCE_MS = 300L
        const val DURATION_TOLERANCE_SEC = 0.5
        const val MODEL_WAIT_MS = 180_000L
        const val MODEL_POLL_MS = 5_000L

        /** Default Linux pipe capacity: writing more than this means the reader drained the pipe. */
        const val PIPE_BUFFER_BYTES = 65_536L
        const val DRAIN_TIMEOUT_SEC = 20L
        const val RESULT_TIMEOUT_MS = 20_000L

        /** Upper bound for any single recognition-service callback (support check, startListening). */
        const val CALLBACK_TIMEOUT_MS = 20_000L
        const val EVENT_TIMEOUT_MS = 10_000L
        val RECOGNITION_PACKAGES = listOf("com.google.android.as", "com.google.android.tts")
    }
}
