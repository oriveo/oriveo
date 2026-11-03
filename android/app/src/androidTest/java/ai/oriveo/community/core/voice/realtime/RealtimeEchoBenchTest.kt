package ai.oriveo.community.core.voice.realtime

import android.Manifest
import android.content.Context
import android.media.AudioManager
import android.media.MediaRecorder
import android.media.audiofx.AudioEffect
import android.os.Build
import androidx.annotation.RequiresApi
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.voice.AudioRecordCapture
import ai.oriveo.community.core.voice.PcmSource
import ai.oriveo.community.core.voice.VoiceTelemetry
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.conversation.SpeechProbModel
import ai.oriveo.community.core.voice.conversation.SpeechProbSource
import ai.oriveo.community.core.voice.conversation.VadEvent
import ai.oriveo.community.core.voice.conversation.VoiceConversationVad
import ai.oriveo.community.core.voice.live.VoiceLive
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt
import org.json.JSONArray
import ai.oriveo.community.core.voice.AndroidAudioSessionCoordinator
import org.json.JSONObject
import org.koin.mp.KoinPlatform
import org.junit.Test
import org.junit.runner.RunWith

/**
 * G3 realtime playback-echo bench (schema realtime-echo-bench/v1): opens production capture via [AndroidRealtimeAudio] (source=vc uses VOICE_COMMUNICATION, source=mic is the MIC control),
 * after a 3 s silent baseline, plays the replies[] corpus (20 segments) as model downlink one by one, waiting 2 s after each segment is drained,
 * with nobody speaking. Each 20 ms uplink frame first feeds Silero to get the frame prob, then steps the production gate [RealtimeUplinkGate] frame by frame (model mode, fed prob;
 * on inference failure passes null as production does; result field gateOpenSpeech), plus an energy-only gate control fed dB only (gateEnergyOpenSpeech / misreleasedEnergy),
 * and two [VoiceConversationVad] instances (energy, and Silero model mode sharing one Silero instance). pb / pe timing matches production GatedAudio (onset = first segment enqueued and playback starts,
 * end = drained callback). Both gates open and close on the same frame. Measurement only, no threshold assertions.
 * Per-frame trace (schema realtime-echo-trace/v1, for offline replay): same name as the result with suffix .trace.json; frames is [db, prob] per frame
 * (db to 1 decimal, prob to 3 decimals, null on inference failure); cycles is {id, pb, pe} per segment (frame index where the gate's onset / drained calls ran).
 * Args: -e source vc|mic, -e volume 0..100 (percent of STREAM_VOICE_CALL max; result volumePct records the requested value, the actual step is in
 * voiceCallVolume / voiceCallMax), -e runId (defaults to the current millisecond timestamp).
 * Corpus: getExternalFilesDir("s5")/manifest.json; result: getExternalFilesDir("realtime-echo")/realtime-echo-android-<source>-<volume>.json,
 * writes phase=running before starting and phase=done (with totals) at the end; on error (including Silero load failure, no fallback) writes phase=error and rethrows;
 * logcat TAG RealtimeEcho prints a summary line. aec is the AEC effect actually enabled on this app's recording config during capture (readable on API 30+ only; older versions mark the group as error).
 *
 * Barge-in ([bargeIn], schema realtime-echo-bargein/v1, vc only, args -e volume / -e runId): plays the first 10 replies[] segments; after each onset,
 * after 3 s injects one conversation[] line (5 Chinese, 5 English) through [InjectingPcmSource] sample by sample into the capture stream (after AEC, so the conclusion is optimistic), and measures the production gate.
 * Release timing: onsetFrame = injection start frame + leadMs/20, swallowedFrames = max(0, flushFromFrame - onsetFrame),
 * openLatencyFrames = openAtFrame - onsetFrame (the first gate Open after that segment's onset). Result: realtime-echo-android-bargein-<volume>.json.
 */
@RunWith(AndroidJUnit4::class)
class RealtimeEchoBenchTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    private class Reply(val id: String, val lang: String, val samples: ShortArray)

    /** Barge-in corpus line: wav samples and leading silence leadMs. */
    private class Utterance(val id: String, val lang: String, val samples: ShortArray, val leadMs: Long)

    /** One injection: [position] is the next sample index to add, [startSample] is the capture-stream index of the first added sample (-1 if not started). */
    private class Injection(val utterance: Utterance) {
        var position = 0
        var startSample = -1L
        val done = CountDownLatch(1)
    }

    /** Playback cycle for one reply segment: onset frame pb, end frame pe (capture frame indexes); the barge-in rig attaches this segment's injection. */
    private class Cycle(val reply: Reply, val pb: Long) {
        var pe: Long = -1
        var injection: Injection? = null
    }

    /** One gate Open: frame, reason, flush start frame. */
    private class GateOpen(val at: Long, val reason: UplinkGateOpenReason, val flushFromFrame: Long)

    /** Capture measurement result (for the result file). */
    private class Capture(val routeName: String, val aec: Boolean, val volumeIndex: Int, val volumeMax: Int)

    // Everything except annotated fields is guarded by [lock]: the capture thread writes per frame; the test thread and the main thread (drained) change cycles.
    private val lock = Any()
    private val gate = RealtimeUplinkGate()
    private val gateEnergy = RealtimeUplinkGate()
    private val energyVad = VoiceConversationVad()
    private val sileroVad = VoiceConversationVad()
    private var probs: SpeechProbModel? = null
    private var frame = 0L
    private var route = ConversationRoute.SPEAKER
    private var pb: Long? = null
    private var pe: Long? = null
    private val dbs = ArrayList<Double>()
    private val frameProbs = ArrayList<Double?>()
    private val frameRefs = ArrayList<Double?>()

    // Same as the production controller: the downlink reference for gate frames comes from the [AndroidRealtimeAudio] under test.
    @Volatile private var reference: RealtimeAudioIO? = null
    private val released = ArrayList<Boolean>()
    private val energyStarts = ArrayList<Long>()
    private val sileroStarts = ArrayList<Long>()
    private val speechOpens = ArrayList<Long>()
    private val energySpeechOpens = ArrayList<Long>()
    private val opens = ArrayList<GateOpen>()
    private val held = ArrayDeque<Long>()
    private val cycles = ArrayList<Cycle>()
    private var baselineReady = CountDownLatch(1)
    private var drained = CountDownLatch(1)
    private val injector = AtomicReference<Injection?>(null)

    /** Owned by the capture thread: total samples read from the real source so far. */
    private var sourceSamples = 0L

    @Test
    fun bench() {
        val args = InstrumentationRegistry.getArguments()
        val source = args.getString("source") ?: "vc"
        val volumePct = args.getString("volume")?.toInt() ?: 100
        require(source == "vc" || source == "mic") { "source must be vc or mic, got $source" }
        require(volumePct in 0..100) { "volume must be 0..100, got $volumePct" }
        val runId = args.getString("runId") ?: System.currentTimeMillis().toString()
        val dir = context.getExternalFilesDir("realtime-echo")!!.apply { mkdirs() }
        val result = File(dir, "realtime-echo-android-$source-$volumePct.json")
        result.writeText(header(runId, "running", source, volumePct).toString(2))
        try {
            val capture = measure(source, volumePct, replies(), plan = emptyList())
            write(result, runId, source, volumePct, capture)
        } catch (error: Throwable) {
            result.writeText(header(runId, "error", source, volumePct).put("error", error.toString()).toString(2))
            throw error
        }
    }

    @Test
    fun bargeIn() {
        val args = InstrumentationRegistry.getArguments()
        val volumePct = args.getString("volume")?.toInt() ?: 100
        require(volumePct in 0..100) { "volume must be 0..100, got $volumePct" }
        val runId = args.getString("runId") ?: System.currentTimeMillis().toString()
        val dir = context.getExternalFilesDir("realtime-echo")!!.apply { mkdirs() }
        val result = File(dir, "realtime-echo-android-bargein-$volumePct.json")
        result.writeText(bargeInHeader(runId, "running", volumePct).toString(2))
        try {
            val plan = utterances()
            val replies = replies()
            check(replies.size >= plan.size) { "corpus has ${replies.size} replies, barge-in needs ${plan.size}" }
            val capture = measure(BARGE_IN_SOURCE, volumePct, replies.take(plan.size), plan)
            writeBargeIn(result, runId, volumePct, capture)
        } catch (error: Throwable) {
            result.writeText(bargeInHeader(runId, "error", volumePct).put("error", error.toString()).toString(2))
            throw error
        }
    }

    /** [plan] non-empty: after segment n's onset, inject plan[n] at [BARGE_IN_AT_MS] (capture goes through [InjectingPcmSource]). */
    private fun measure(source: String, volumePct: Int, replies: List<Reply>, plan: List<Utterance>): Capture {
        InstrumentationRegistry.getInstrumentation().uiAutomation
            .grantRuntimePermission(context.packageName, Manifest.permission.RECORD_AUDIO)

        val audio = if (plan.isNotEmpty()) {
            AndroidRealtimeAudio(context, audioSessions(), { openSource -> AudioRecordCapture({ InjectingPcmSource(openSource()) }) })
        } else if (source == "vc") {
            AndroidRealtimeAudio(context, audioSessions())
        } else {
            AndroidRealtimeAudio(context, audioSessions(), { _ -> AudioRecordCapture(context, MediaRecorder.AudioSource.MIC) })
        }
        reference = audio
        probs = SpeechProbSource.silero(context).load()
        val audioManager = context.getSystemService(AudioManager::class.java)
        var previousVolume: Int? = null
        val routeName: String
        val volumeIndex: Int
        val volumeMax: Int
        val aec: Boolean
        try {
            audio.setOnDrained {
                // Same as GatedAudio.endCycle: end the cycle in the drained callback; pe is the frame of the next step.
                synchronized(lock) {
                    if (pb != null && pe == null) {
                        pe = frame
                        cycles.lastOrNull()?.pe = frame
                        gate.playbackEnded()
                        gateEnergy.playbackEnded()
                    }
                }
                drained.countDown()
            }
            onMain {
                audio.start(
                    onFrame = ::onFrame,
                    onInterruption = { Log.w(TAG, "audio interruption") },
                    uplinkRateHz = RealtimePCM.INPUT_RATE,
                )
            }
            check(baselineReady.await(BASELINE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) { "capture delivered no baseline frames" }
            // Per-output-device volume is recorded separately: mode / routing switches run async on the coordinator thread. Wait for a 3 s baseline, and only set volume after output has taken effect,
            // otherwise it lands on the pre-switch device and, after switching to speaker, falls back to speaker's own volume (first run on 2026-10-29 at vc 60 actually gave 15/15).
            volumeMax = audioManager.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
            previousVolume = audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
            val wantIndex = (volumeMax * volumePct / 100.0).roundToInt()
            runCatching { audioManager.setStreamVolume(AudioManager.STREAM_VOICE_CALL, wantIndex, 0) }
            volumeIndex = audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
            check(volumeIndex == wantIndex) { "voice call volume $volumeIndex/$volumeMax, wanted $wantIndex" }
            routeName = audio.route.toConversationRoute().name.lowercase()
            // Read the AEC actually enabled during capture; do not infer it from isAvailable().
            aec = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                aecEnabled(audioManager)
            } else {
                error("aec state needs API 30 (AudioRecordingConfiguration.clientEffects), sdk ${Build.VERSION.SDK_INT}")
            }

            for ((n, reply) in replies.withIndex()) {
                drained = CountDownLatch(1)
                // Resample in 1 s chunks: the production function is called per frame; passing the whole 10 s at once overflows Int in count * 24000
                val up = ShortArray(reply.samples.size * 3 / 2 + RESAMPLE_CHUNK)
                var count = 0
                val chunkOut = ShortArray(RESAMPLE_CHUNK * 3 / 2)
                var at = 0
                while (at < reply.samples.size) {
                    val n = minOf(RESAMPLE_CHUNK, reply.samples.size - at)
                    val wrote = RealtimePCM.resample16kTo24k(reply.samples.copyOfRange(at, at + n), n, chunkOut)
                    System.arraycopy(chunkOut, 0, up, count, wrote)
                    count += wrote
                    at += n
                }
                val pcm = RealtimePCM.toLittleEndian(up, count)
                onMain {
                    val wasPlaying = audio.isPlaying
                    audio.enqueue(pcm, reply.id)
                    // Same as GatedAudio.enqueue: when enqueue starts playback, take the route and start the cycle.
                    if (!wasPlaying && audio.isPlaying) {
                        val sampled = audio.route.toConversationRoute()
                        synchronized(lock) {
                            route = sampled
                            pb = frame
                            pe = null
                            gate.playbackStarted(sampled)
                            gateEnergy.playbackStarted(sampled)
                            // Same as the in-gate VAD: on playback start, discard the sentence in progress; keep the noise floor.
                            energyVad.reset()
                            sileroVad.reset()
                            cycles += Cycle(reply, frame)
                        }
                    }
                }
                plan.getOrNull(n)?.let { utterance ->
                    Thread.sleep(BARGE_IN_AT_MS)
                    val injection = Injection(utterance)
                    synchronized(lock) {
                        val cycle = cycles.lastOrNull()
                        check(cycle?.reply === reply) { "reply ${reply.id} did not start playback" }
                        cycle.injection = injection
                    }
                    injector.set(injection)
                    val ok = injection.done.await(INJECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                    injector.compareAndSet(injection, null)
                    check(ok) { "utterance ${utterance.id} was not fully injected" }
                }
                check(drained.await(DRAIN_TIMEOUT_MS, TimeUnit.MILLISECONDS)) { "reply ${reply.id} did not drain" }
                Thread.sleep(AFTER_DRAIN_MS)
            }
        } finally {
            previousVolume?.let { runCatching { audioManager.setStreamVolume(AudioManager.STREAM_VOICE_CALL, it, 0) } }
            onMain { audio.stop() }
            synchronized(lock) { probs?.close(); probs = null }
        }
        return Capture(routeName, aec, volumeIndex, volumeMax)
    }

    /** Wraps the real capture source (as in VoiceS5Rig): after each read, saturating-adds the next batch of the current injected segment to the samples read, and records the first sample index. */
    private inner class InjectingPcmSource(private val delegate: PcmSource) : PcmSource {
        override fun read(buffer: ShortArray, offset: Int, size: Int): Int {
            val n = delegate.read(buffer, offset, size)
            if (n <= 0) return n
            val before = sourceSamples
            sourceSamples += n
            val injection = injector.get() ?: return n
            synchronized(injection) {
                if (injection.position >= injection.utterance.samples.size) return n
                if (injection.startSample < 0) injection.startSample = before
                val samples = injection.utterance.samples
                val count = minOf(n, samples.size - injection.position)
                for (i in 0 until count) {
                    val mixed = buffer[offset + i] + samples[injection.position + i]
                    buffer[offset + i] = mixed.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                }
                injection.position += count
                if (injection.position >= samples.size) injection.done.countDown()
            }
            return n
        }

        override fun observeSilenced(onSilenced: () -> Unit): () -> Unit = delegate.observeSilenced(onSilenced)

        override fun stop() = delegate.stop()

        override fun release() = delegate.release()
    }

    /** AEC actually enabled on this app's active recording config: client session effect or capture stream effect has EFFECT_TYPE_AEC. */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun aecEnabled(audioManager: AudioManager): Boolean {
        val configs = audioManager.activeRecordingConfigurations
        check(configs.isNotEmpty()) { "no active recording configuration while capturing" }
        return configs.any { config ->
            (config.clientEffects + config.effects).any { it.type == AudioEffect.EFFECT_TYPE_AEC }
        }
    }

    private fun header(runId: String, phase: String, source: String, volumePct: Int): JSONObject = JSONObject()
        .put("schema", "realtime-echo-bench/v1")
        .put("runId", runId)
        .put("phase", phase)
        .put("platform", "android")
        .put("device", DEVICE)
        .put("os", OS)
        .put("source", source)
        .put("volumePct", volumePct)

    /** Capture thread: 16 kHz PCM16 LE, steps the gate and both VADs per 20 ms frame. */
    private fun onFrame(bytes: ByteArray) {
        val frameBytes = RealtimePCM.frameBytes(RealtimePCM.INPUT_RATE)
        var offset = 0
        synchronized(lock) {
            while (offset < bytes.size) {
                val size = minOf(frameBytes, bytes.size - offset)
                stepFrame(bytes, offset, size)
                offset += size
            }
        }
    }

    private fun stepFrame(bytes: ByteArray, offset: Int, size: Int) {
        val index = frame
        val db = RealtimePCM.blockDb(bytes, offset, size) ?: SILENT_FRAME_DB
        // Same as production: feed Silero first to get this frame's prob, then step the gate; on inference failure (null) pass it through to the gate unchanged.
        val samples = ShortArray(size / 2) { i ->
            val p = offset + 2 * i
            ((bytes[p + 1].toInt() shl 8) or (bytes[p].toInt() and 0xff)).toShort()
        }
        val prob = probs?.feed(samples)?.toDouble()
        val ref = reference?.playbackReferenceDb()
        val step = gate.step(db, prob, ref)
        val energyStep = gateEnergy.step(db)
        if (energyStep is UplinkGateStep.Open && energyStep.reason == UplinkGateOpenReason.SPEECH) energySpeechOpens += index
        frame++
        dbs += db
        frameProbs += prob
        frameRefs += ref
        released += false
        when (step) {
            UplinkGateStep.Send -> {
                held.clear()
                released[index.toInt()] = true
            }
            UplinkGateStep.Hold -> {
                held.addLast(index)
                if (held.size > MAX_HELD_FRAMES) held.removeFirst()
            }
            is UplinkGateStep.Open -> {
                held.forEach { at -> if (at >= step.flushFromFrame) released[at.toInt()] = true }
                held.clear()
                released[index.toInt()] = true
                if (step.reason == UplinkGateOpenReason.SPEECH) speechOpens += index
                opens += GateOpen(index, step.reason, step.flushFromFrame)
            }
        }
        if (energyVad.step(index, db, route, pb, pe) is VadEvent.SpeechStart) energyStarts += index
        if (sileroVad.step(index, db, route, pb, pe, prob ?: 0.0) is VadEvent.SpeechStart) sileroStarts += index
        if (frame == BASELINE_FRAMES.toLong()) baselineReady.countDown()
    }

    private fun write(result: File, runId: String, source: String, volumePct: Int, capture: Capture) {
        val routeName = capture.routeName
        val aec = capture.aec
        val volumeIndex = capture.volumeIndex
        val volumeMax = capture.volumeMax
        val segments = JSONArray()
        var misreleased = 0
        var misreleasedEnergy = 0
        var energySegments = 0
        var sileroSegments = 0
        val baselineDb: Double
        synchronized(lock) {
            baselineDb = median(dbs.subList(0, minOf(BASELINE_FRAMES, dbs.size)))
            cycles.forEachIndexed { n, c ->
                val end = if (c.pe >= 0) c.pe else frame
                val next = cycles.getOrNull(n + 1)?.pb ?: frame
                val residual = (c.pb until end).filter { it < dbs.size }.map { dbs[it.toInt()] - baselineDb }.sorted()
                val vadEnd = end + VAD_TAIL_FRAMES
                val energy = energyStarts.count { it >= c.pb && it < vadEnd }
                val silero = sileroStarts.count { it >= c.pb && it < vadEnd }
                val opened = speechOpens.any { it >= c.pb && it < next }
                val openedEnergy = energySpeechOpens.any { it >= c.pb && it < next }
                val releasedFrames = (c.pb..end).count { it < released.size && released[it.toInt()] }
                if (opened) misreleased++
                if (openedEnergy) misreleasedEnergy++
                if (energy > 0) energySegments++
                if (silero > 0) sileroSegments++
                segments.put(
                    JSONObject()
                        .put("id", c.reply.id)
                        .put("lang", c.reply.lang)
                        .put("playFrames", end - c.pb)
                        .put("residualDbMean", if (residual.isEmpty()) JSONObject.NULL else round1(residual.average()))
                        .put("residualDbP95", if (residual.isEmpty()) JSONObject.NULL else round1(nearestRank(residual, 95)))
                        .put("vadEnergyStarts", energy)
                        .put("vadSileroStarts", silero)
                        .put("gateOpenSpeech", opened)
                        .put("gateEnergyOpenSpeech", openedEnergy)
                        .put("releasedDuringPlayback", releasedFrames),
                )
            }
        }
        val out = header(runId, "done", source, volumePct)
            .put("voiceCallVolume", volumeIndex)
            .put("voiceCallMax", volumeMax)
            .put("route", routeName)
            .put("aec", aec)
            .put("baselineDb", round1(baselineDb))
            .put("segments", segments)
            .put(
                "totals",
                JSONObject()
                    .put("segments", segments.length())
                    .put("misreleased", misreleased)
                    .put("misreleasedEnergy", misreleasedEnergy)
                    .put("vadEnergySegments", energySegments)
                    .put("vadSileroSegments", sileroSegments),
            )
        result.writeText(out.toString(2))
        writeTrace(result, source, volumePct)
        Log.i(
            TAG,
            "realtime-echo platform=android source=$source volumePct=$volumePct route=$routeName aec=$aec " +
                "baselineDb=${round1(baselineDb)} segments=${segments.length()} misreleased=$misreleased " +
                "misreleasedEnergy=$misreleasedEnergy " +
                "vadEnergySegments=$energySegments vadSileroSegments=$sileroSegments device=$DEVICE os=$OS",
        )
    }

    private fun bargeInHeader(runId: String, phase: String, volumePct: Int): JSONObject =
        header(runId, phase, BARGE_IN_SOURCE, volumePct)
            .put("schema", "realtime-echo-bargein/v1")
            .put("injection", "postAec")

    private fun writeBargeIn(result: File, runId: String, volumePct: Int, capture: Capture) {
        val segments = JSONArray()
        val swallowed = ArrayList<Long>()
        var openedSpeech = 0
        var misreleasedEnergy = 0
        val frameSamples = RealtimePCM.frameBytes(RealtimePCM.INPUT_RATE) / 2
        synchronized(lock) {
            cycles.forEachIndexed { n, c ->
                val injection = checkNotNull(c.injection) { "reply ${c.reply.id} has no injection" }
                val utterance = injection.utterance
                check(injection.startSample >= 0) { "utterance ${utterance.id} never reached the capture" }
                val injectFrame = injection.startSample / frameSamples
                val onset = injectFrame + utterance.leadMs / FRAME_MS
                val next = cycles.getOrNull(n + 1)?.pb ?: frame
                val open = opens.firstOrNull { it.at >= c.pb && it.at < next }
                val openedEnergy = energySpeechOpens.any { it >= c.pb && it < next }
                if (openedEnergy) misreleasedEnergy++
                val swallowedFrames = open?.let { maxOf(0L, it.flushFromFrame - onset) }
                if (open?.reason == UplinkGateOpenReason.SPEECH) openedSpeech++
                swallowedFrames?.let { swallowed += it }
                val end = if (c.pe >= 0) c.pe else frame
                segments.put(
                    JSONObject()
                        .put("id", c.reply.id)
                        .put("utterance", utterance.id)
                        .put("lang", utterance.lang)
                        .put("leadMs", utterance.leadMs)
                        .put("pb", c.pb)
                        .put("playFrames", end - c.pb)
                        .put("injectFrame", injectFrame)
                        .put("onsetFrame", onset)
                        .put("openReason", open?.reason?.rawValue ?: JSONObject.NULL)
                        .put("openAtFrame", open?.at ?: JSONObject.NULL)
                        .put("flushFromFrame", open?.flushFromFrame ?: JSONObject.NULL)
                        .put("swallowedFrames", swallowedFrames ?: JSONObject.NULL)
                        .put("openLatencyFrames", open?.let { it.at - onset } ?: JSONObject.NULL)
                        .put("gateEnergyOpenSpeech", openedEnergy),
                )
            }
        }
        val sorted = swallowed.sorted()
        val p50: Any = if (sorted.isEmpty()) JSONObject.NULL else sorted[((50 * sorted.size + 99) / 100 - 1).coerceIn(0, sorted.size - 1)]
        val max: Any = sorted.lastOrNull() ?: JSONObject.NULL
        val out = bargeInHeader(runId, "done", volumePct)
            .put("voiceCallVolume", capture.volumeIndex)
            .put("voiceCallMax", capture.volumeMax)
            .put("route", capture.routeName)
            .put("aec", capture.aec)
            .put("segments", segments)
            .put(
                "totals",
                JSONObject()
                    .put("segments", segments.length())
                    .put("openedSpeech", openedSpeech)
                    .put("misreleasedEnergy", misreleasedEnergy)
                    .put("swallowedP50", p50)
                    .put("swallowedMax", max),
            )
        result.writeText(out.toString(2))
        writeTrace(result, BARGE_IN_SOURCE, volumePct)
        Log.i(
            TAG,
            "realtime-echo-bargein platform=android volumePct=$volumePct route=${capture.routeName} aec=${capture.aec} " +
                "segments=${segments.length()} openedSpeech=$openedSpeech misreleasedEnergy=$misreleasedEnergy swallowedP50=$p50 swallowedMax=$max " +
                "injection=postAec device=$DEVICE os=$OS",
        )
    }

    /** Frame-by-frame trace (realtime-echo-trace/v1): same directory and name as [result], suffix .trace.json. */
    private fun writeTrace(result: File, source: String, volumePct: Int) {
        val frames = JSONArray()
        val traceCycles = JSONArray()
        synchronized(lock) {
            for (i in dbs.indices) {
                val prob = frameProbs[i]
                val ref = frameRefs[i]
                frames.put(
                    JSONArray()
                        .put(round1(dbs[i]))
                        .put(if (prob == null) JSONObject.NULL else round3(prob))
                        .put(if (ref == null) JSONObject.NULL else round1(ref)),
                )
            }
            cycles.forEach { c ->
                traceCycles.put(
                    JSONObject()
                        .put("id", c.reply.id)
                        .put("pb", c.pb)
                        .put("pe", if (c.pe >= 0) c.pe else JSONObject.NULL),
                )
            }
        }
        val trace = JSONObject()
            .put("schema", "realtime-echo-trace/v1")
            .put("frameMs", FRAME_MS)
            .put("source", source)
            .put("volumePct", volumePct)
            .put("frames", frames)
            .put("cycles", traceCycles)
        File(result.parentFile, result.nameWithoutExtension + ".trace.json").writeText(trace.toString())
    }

    /** Barge-in corpus: manifest conversation[] (skipping pause), first [BARGE_IN_PER_LANG] Chinese and English lines each. */
    private fun utterances(): List<Utterance> {
        val root = context.getExternalFilesDir("s5")!!
        val manifest = JSONObject(File(root, "manifest.json").readText())
        val defaultLead = manifest.optLong("leadMs", 0L)
        val items = requireNotNull(manifest.optJSONArray("conversation")) { "corpus manifest has no conversation" }
        val all = (0 until items.length()).map { items.getJSONObject(it) }.filter { !it.optBoolean("pause", false) }
        return listOf("zh", "en").flatMap { prefix ->
            val picked = all.filter { it.getString("lang").startsWith(prefix) }.take(BARGE_IN_PER_LANG)
            check(picked.size == BARGE_IN_PER_LANG) { "conversation corpus has ${picked.size} $prefix utterances, need $BARGE_IN_PER_LANG" }
            picked.map {
                Utterance(
                    it.getString("id"),
                    it.getString("lang"),
                    VoiceLive.readWav(File(root, it.getString("file"))),
                    it.optLong("leadMs", defaultLead),
                )
            }
        }
    }

    private fun replies(): List<Reply> {
        val root = context.getExternalFilesDir("s5")!!
        val manifest = JSONObject(File(root, "manifest.json").readText())
        val items = requireNotNull(manifest.optJSONArray("replies")) { "corpus manifest has no replies" }
        return (0 until items.length()).map { items.getJSONObject(it) }.map {
            Reply(it.getString("id"), it.getString("lang"), VoiceLive.readWav(File(root, it.getString("file"))))
        }
    }

    private fun onMain(block: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync(block)

    private fun VoiceTelemetry.ConversationRoute.toConversationRoute(): ConversationRoute = when (this) {
        VoiceTelemetry.ConversationRoute.Speaker -> ConversationRoute.SPEAKER
        VoiceTelemetry.ConversationRoute.Headset -> ConversationRoute.HEADPHONES
        VoiceTelemetry.ConversationRoute.Bluetooth -> ConversationRoute.BLUETOOTH
    }

    private companion object {
        const val TAG = "RealtimeEcho"
        const val SILENT_FRAME_DB = -120.0
        const val MAX_HELD_FRAMES = 100
        const val BASELINE_FRAMES = 150 // 3 s
        const val VAD_TAIL_FRAMES = 40
        const val AFTER_DRAIN_MS = 2_000L
        const val BASELINE_TIMEOUT_MS = 15_000L
        const val RESAMPLE_CHUNK = 16_000
        const val DRAIN_TIMEOUT_MS = 60_000L
        const val BARGE_IN_SOURCE = "vc"
        const val BARGE_IN_AT_MS = 3_000L
        const val BARGE_IN_PER_LANG = 5
        const val INJECT_TIMEOUT_MS = 30_000L
        const val FRAME_MS = 20L

        val DEVICE = "${Build.MANUFACTURER} ${Build.MODEL}"
        val OS = "Android ${Build.VERSION.RELEASE} (sdk ${Build.VERSION.SDK_INT})"

        fun median(values: List<Double>): Double =
            if (values.isEmpty()) SILENT_FRAME_DB else nearestRank(values.sorted(), 50)

        /** Nearest-rank percentile: sorted[ceil(p * n) - 1], p = percent / 100, integer math avoids floating-point error. */
        fun nearestRank(sorted: List<Double>, percent: Int): Double =
            sorted[((percent * sorted.size + 99) / 100 - 1).coerceIn(0, sorted.size - 1)]

        fun round1(value: Double): Double = (value * 10).roundToInt() / 10.0

        fun round3(value: Double): Double = (value * 1000).roundToInt() / 1000.0
    }

    /** Production singleton coordinator (Koin), on the same serial thread as the in-app realtime voice session. */
    private fun audioSessions(): AndroidAudioSessionCoordinator = KoinPlatform.getKoin().get()
}
