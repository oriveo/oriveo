package ai.oriveo.community.core.voice

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt
import kotlinx.coroutines.launch
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * S0 device probe. Logs facts under tag VoiceS0 and asserts nothing about
 * quality: which recognizers support zh-CN / en-US, whether a live EXTRA_AUDIO_SOURCE pipe emits partial results
 * (and how fast), and how long TTS echo stays audible on the mic after playback ends.
 * Needs s0-zh.wav / s0-en.wav (16 kHz mono PCM16) in getExternalFilesDir("s0") and RECORD_AUDIO granted.
 */
@RunWith(AndroidJUnit4::class)
class VoiceS0ProbeTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val main = Handler(Looper.getMainLooper())

    @Test
    fun recognizerSupportAndLivePartials() {
        assumeTrue(Build.VERSION.SDK_INT >= 33)
        log("device ${Build.MANUFACTURER} ${Build.MODEL} sdk=${Build.VERSION.SDK_INT}")
        log("defaultAvailable=${SpeechRecognizer.isRecognitionAvailable(context)} onDeviceAvailable=${SpeechRecognizer.isOnDeviceRecognitionAvailable(context)}")
        for (kind in listOf("DEFAULT", "ON_DEVICE")) {
            // The on-device (SODA) service lists Mandarin as cmn-Hans-CN and rejects zh-CN with a language-pack error.
            val zh = if (kind == "ON_DEVICE") "cmn-Hans-CN" else "zh-CN"
            for ((lang, file) in listOf(zh to "s0-zh.wav", "en-US" to "s0-en.wav")) {
                support(kind, lang)
                for (segmented in listOf(true, false)) live(kind, lang, file, segmented)
            }
        }
    }

    /**
     * S5 RC1: raw recognizer callbacks for the Mandarin clips whose middle text goes missing in segmented sessions.
     * Part one drives SpeechRecognizer directly with the production pipe intent (ON_DEVICE, cmn-Hans-CN) and records
     * every partial, every segment candidate (null / empty kept) with confidence, session end and errors. Part two
     * replays the same clips through the production SystemSTTPipeSession and records live transcript changes.
     * Writes getExternalFilesDir("s5-results")/segments.json; asserts nothing about recognition quality.
     */
    @Test
    fun segmentRawCallbacks() = kotlinx.coroutines.runBlocking {
        assumeTrue(Build.VERSION.SDK_INT >= 33)
        val dir = File(context.getExternalFilesDir("s5"), "dict")
        val clips = listOf("dict-zh-CN-02.wav", "dict-zh-CN-08.wav", "dict-zh-CN-01.wav")
        val raw = org.json.JSONArray()
        for (clip in clips) raw.put(rawSegments(File(dir, clip)))
        val router = SystemSTTRouter(AndroidSystemSTTBackend(context))
        val engine = SystemSTTEngine(AndroidSystemSTTSessionBackend(context), routeFor = router::route)
        val production = org.json.JSONArray()
        for (clip in clips) production.put(productionSegments(router, engine, File(dir, clip)))
        val json = org.json.JSONObject()
            .put("device", "${Build.MANUFACTURER} ${Build.MODEL} sdk=${Build.VERSION.SDK_INT}")
            .put("raw", raw)
            .put("production", production)
        File(context.getExternalFilesDir("s5-results"), "segments.json").writeText(json.toString(2))
    }

    private fun rawSegments(file: File): org.json.JSONObject {
        val samples = wavSamples(file)
        val pipe = ParcelFileDescriptor.createPipe()
        val events = org.json.JSONArray()
        val ended = CountDownLatch(1)
        var audioStart = 0L
        var recognizer: SpeechRecognizer? = null
        fun at() = SystemClock.uptimeMillis() - audioStart
        fun event(type: String, block: org.json.JSONObject.() -> Unit = {}) {
            val item = org.json.JSONObject().put("at", at()).put("type", type).apply(block)
            synchronized(events) { events.put(item) }
            log("rc1 ${file.name} $item")
        }
        fun candidates(bundle: Bundle?): org.json.JSONArray {
            val out = org.json.JSONArray()
            val texts = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            val scores = bundle?.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
            if (texts == null) return out.put(org.json.JSONObject().put("list", "null"))
            texts.forEachIndexed { index, text ->
                out.put(
                    org.json.JSONObject()
                        .put("text", text ?: "<null>")
                        .put("confidence", scores?.getOrNull(index)?.toDouble() ?: org.json.JSONObject.NULL),
                )
            }
            return out
        }
        val listener = object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = event("ready")
            override fun onBeginningOfSpeech() = event("begin")
            override fun onRmsChanged(rmsdB: Float) = Unit
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = event("eos")
            override fun onError(error: Int) { event("error") { put("code", error) }; ended.countDown() }
            override fun onPartialResults(partialResults: Bundle?) = event("partial") { put("candidates", candidates(partialResults)) }
            override fun onSegmentResults(segmentResults: Bundle) = event("segment") { put("candidates", candidates(segmentResults)) }
            override fun onEndOfSegmentedSession() { event("sessionEnd"); ended.countDown() }
            override fun onResults(results: Bundle?) { event("results") { put("candidates", candidates(results)) }; ended.countDown() }
            override fun onEvent(eventType: Int, params: Bundle?) = event("event") { put("eventType", eventType) }
        }
        val started = CountDownLatch(1)
        main.post {
            recognizer = create("ON_DEVICE")
            val r = recognizer ?: run { started.countDown(); return@post }
            r.setRecognitionListener(listener)
            r.startListening(SystemSTTEngine.pipeIntent("cmn-Hans-CN", pipe[0]))
            started.countDown()
        }
        started.await(5, TimeUnit.SECONDS)
        if (recognizer == null) {
            pipe.forEach { runCatching { it.close() } }
            return org.json.JSONObject().put("clip", file.name).put("unavailable", true)
        }
        // Real-time pace like the microphone: 20 ms chunks, then 1.5 s silence, then close the pipe (ends the session).
        val out = FileOutputStream(pipe[1].fileDescriptor)
        val chunk = SAMPLE_RATE / 50
        val total = samples.size + SAMPLE_RATE * 3 / 2
        audioStart = SystemClock.uptimeMillis()
        val writer = Thread {
            val bytes = ByteBuffer.allocate(chunk * 2).order(ByteOrder.LITTLE_ENDIAN)
            var position = 0
            try {
                while (position < total) {
                    bytes.clear()
                    for (i in 0 until chunk) bytes.putShort(if (position + i < samples.size) samples[position + i] else 0)
                    out.write(bytes.array())
                    position += chunk
                    val wait = audioStart + position.toLong() * 1_000 / SAMPLE_RATE - SystemClock.uptimeMillis()
                    if (wait > 0) Thread.sleep(wait)
                }
            } catch (error: Exception) {
                event("writeFailed") { put("error", error.javaClass.simpleName) }
            }
            runCatching { out.close() }
        }.apply { start() }
        writer.join(total * 1_000L / SAMPLE_RATE + 3_000)
        if (writer.isAlive) {
            event("writerBlocked")
            runCatching { pipe[0].close() }
            writer.interrupt()
        }
        runCatching { pipe[1].close() }
        val endedInTime = ended.await(15, TimeUnit.SECONDS)
        main.post { recognizer?.destroy() }
        runCatching { pipe[0].close() }
        Thread.sleep(500)
        return org.json.JSONObject()
            .put("clip", file.name)
            .put("speechMs", samples.size * 1_000L / SAMPLE_RATE)
            .put("ended", endedInTime)
            .put("events", synchronized(events) { org.json.JSONArray(events.toString()) })
    }

    private suspend fun productionSegments(router: SystemSTTRouter, engine: SystemSTTEngine, file: File): org.json.JSONObject {
        val route = router.route("zh-CN")
        val session = engine.startSession(route) as? SystemSTTPipeSession
            ?: return org.json.JSONObject().put("clip", file.name).put("route", route.toString()).put("pipe", false)
        val changes = org.json.JSONArray()
        val startedAt = SystemClock.uptimeMillis()
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default)
        val job = scope.launch(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
            session.live.collect { transcript ->
                val item = org.json.JSONObject()
                    .put("at", SystemClock.uptimeMillis() - startedAt)
                    .put("finals", org.json.JSONArray(transcript.finals))
                    .put("partial", transcript.partial)
                synchronized(changes) { changes.put(item) }
                log("rc1 prod ${file.name} $item")
            }
        }
        val source = WavPcmSource(file.readBytes(), trailingSilenceMs = 800)
        val capture = AudioRecordCapture({ source })
        capture.start(listOf(session), object : AudioCaptureEvents {
            override fun onFailure(error: Throwable) = Unit
            override fun onInterrupted() = Unit
        })
        source.drained.await(30, TimeUnit.SECONDS)
        val stopAt = SystemClock.uptimeMillis() - startedAt
        capture.stop()
        session.stop()
        val result = kotlinx.coroutines.withTimeoutOrNull(SystemSTTEngine.STOP_RESULT_TIMEOUT_MS) { session.await() }
            ?: SystemSTTEngine.TIMEOUT_RESULT
        job.cancel()
        Thread.sleep(500)
        return org.json.JSONObject()
            .put("clip", file.name)
            .put("route", route.toString())
            .put("speechMs", source.speechSamples * 1_000L / SAMPLE_RATE)
            .put("stopAt", stopAt)
            .put("result", result.toString())
            .put("dropped", session.droppedChunks)
            .put("finals", org.json.JSONArray(session.live.value.finals))
            .put("changes", synchronized(changes) { org.json.JSONArray(changes.toString()) })
    }

    @Test
    fun ttsTailAfterPlaybackEnd() {
        val pcm = wavSamples(File(context.getExternalFilesDir("s0"), "s0-en.wav"))
        val audio = context.getSystemService(AudioManager::class.java)
        val previousMode = audio.mode
        audio.mode = AudioManager.MODE_IN_COMMUNICATION
        if (Build.VERSION.SDK_INT >= 31) {
            audio.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                ?.let { audio.setCommunicationDevice(it) }
        }
        val volume = audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL)
        val maxVolume = audio.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
        log("tail: voiceCallVolume=$volume/$maxVolume aecAvailable=${AcousticEchoCanceler.isAvailable()}")
        try {
            for (aec in listOf(true, false)) repeat(3) { round -> tailRound(pcm, aec, round) }
        } finally {
            if (Build.VERSION.SDK_INT >= 31) audio.clearCommunicationDevice()
            audio.mode = previousMode
        }
    }

    /** Reproduces the shipped dictation path: record into a slot, then replay the .aac through the production engine. */
    /**
     * Production live dictation, 20 rounds alternating zh-CN / en-US: production router + engine session, the device
     * WAV played at real-time pace through AudioRecordCapture into the recording slot and the pipe session; after stop
     * the outcome follows LiveDictationRules.dictationOutcome (the recording is recognized only when the live final is
     * empty). Every round must see at least one non-empty partial from the recognizer and end with text.
     */
    @Test
    fun productionFileReplayPath() = kotlinx.coroutines.runBlocking {
        val router = SystemSTTRouter(AndroidSystemSTTBackend(context))
        val engine = SystemSTTEngine(AndroidSystemSTTSessionBackend(context), routeFor = router::route)
        val failures = mutableListOf<String>()
        repeat(REPLAY_ROUNDS) { round ->
            val (lang, file) = if (round % 2 == 0) "zh-CN" to "s0-zh.wav" else "en-US" to "s0-en.wav"
            val line = runCatching { replayRound(router, engine, lang, file, round) }
                .getOrElse { "lang=$lang round=$round error=$it" }
            log("VOICE-S2 $line")
            if (!line.startsWith("ok ")) failures += line
        }
        org.junit.Assert.assertTrue("failed rounds ${failures.size}/$REPLAY_ROUNDS: $failures", failures.isEmpty())
    }

    /** One production live round; returns "ok ..." or "fail ..." with language, first partial ms, partial count, source, text. */
    private suspend fun replayRound(router: SystemSTTRouter, engine: SystemSTTEngine, lang: String, file: String, round: Int): String {
        val route = router.route(lang)
        val session = engine.startSession(route) as? SystemSTTPipeSession
            ?: return "fail lang=$lang round=$round route=$route (not a pipe route)"
        val watch = LivePartialWatch(kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default), session.live)
        val root = File(context.cacheDir, "s2-prod").apply { deleteRecursively() }
        val store = RecordingStore(root)
        val slot = store.open(REPLAY_SLOT, SystemSTTEngine.ENGINE_NAME, MediaCodecAacEncoder())
        val source = WavPcmSource(File(context.getExternalFilesDir("s0"), file).readBytes(), trailingSilenceMs = 800)
        val capture = AudioRecordCapture({ source })
        capture.start(listOf(slot, session), object : AudioCaptureEvents {
            override fun onFailure(error: Throwable) = Unit
            override fun onInterrupted() = Unit
        })
        source.drained.await(20, TimeUnit.SECONDS)
        // Same order as the controller: stop capture, then the live session, then close the slot.
        capture.stop()
        session.stop()
        slot.finish()
        val liveResult = kotlinx.coroutines.withTimeoutOrNull(SystemSTTEngine.STOP_RESULT_TIMEOUT_MS) { session.await() }
            ?: SystemSTTEngine.TIMEOUT_RESULT
        watch.close()
        val transcript = session.live.value
        val live = when {
            liveResult is STTResult.Success -> LiveSessionResult(transcript.finals, transcript.partial, LiveEnded.Ok, hasRecording = true)
            (liveResult as STTResult.Failed).failure == DictationFailure.Timeout ->
                LiveSessionResult(transcript.finals, transcript.partial, LiveEnded.Timeout, hasRecording = true)
            else -> LiveSessionResult(transcript.finals, transcript.partial, LiveEnded.Failed, reportableKind(liveResult.failure), true)
        }
        val needFile = !(live.ended == LiveEnded.Ok && DictationRules.join(live.finals).isNotEmpty())
        val fileResult = if (needFile) {
            val meta = store.read(REPLAY_SLOT)
            val segment = STTSegment(
                aac = slot.audioFile,
                primingFrames = meta?.primingFrames ?: RecordingWriter.DEFAULT_PRIMING_FRAMES,
                envelope = meta?.envelope.orEmpty(),
            )
            when (val r = kotlinx.coroutines.withTimeoutOrNull(30_000) { engine.transcribe(segment, lang) } ?: SystemSTTEngine.TIMEOUT_RESULT) {
                is STTResult.Success -> LiveFileResult.Text(r.text)
                is STTResult.Failed -> LiveFileResult.Failed(reportableKind(r.failure))
            }
        } else {
            null
        }
        store.complete(REPLAY_SLOT)
        val outcome = LiveDictationRules.dictationOutcome(live, fileResult)
        val ok = watch.partialBeforeFinal && outcome.result == DictationOutcomeResult.Text && !outcome.text.isNullOrBlank()
        return "${if (ok) "ok" else "fail"} lang=$lang round=$round route=$route firstPartialMs=${watch.firstPartialMs} " +
            "partials=${watch.partials} firstFinalMs=${watch.firstFinalMs} live=${live.ended.rawValue}${live.failureKind?.let { "/$it" }.orEmpty()} liveRaw=$liveResult " +
            "source=${outcome.source?.rawValue ?: outcome.result.rawValue} dropped=${session.droppedChunks} text=${outcome.text}"
    }

    /** Same folding as the controller: recognizer codes by table, network, timeout as busy, the rest other. */
    private fun reportableKind(failure: DictationFailure): SystemFailureKind {
        val kind = when (failure) {
            is DictationFailure.Recognizer -> SystemFailure.kindOf(SystemFailureInput.Code(failure.code))
            DictationFailure.Network -> SystemFailureKind.Network
            DictationFailure.Timeout -> SystemFailureKind.Busy
            else -> SystemFailureKind.Other
        }
        return if (kind.isReportable) kind else SystemFailureKind.Other
    }

    private fun support(kind: String, lang: String) {
        val done = CountDownLatch(1)
        var line = "timeout"
        main.post {
            val recognizer = create(kind) ?: run { line = "unavailable"; done.countDown(); return@post }
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang)
            recognizer.checkRecognitionSupport(intent, Executors.newSingleThreadExecutor(), object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    fun pick(list: List<String>) = list.filter { it.startsWith("zh") || it.startsWith("cmn") || it.startsWith("en") }
                    line = "installed=${pick(support.installedOnDeviceLanguages)} supportedOnDevice=${pick(support.supportedOnDeviceLanguages)} " +
                        "pending=${pick(support.pendingOnDeviceLanguages)} online=${pick(support.onlineLanguages)}"
                    main.post { recognizer.destroy() }
                    done.countDown()
                }

                override fun onError(error: Int) {
                    line = "error=$error"
                    main.post { recognizer.destroy() }
                    done.countDown()
                }
            })
        }
        done.await(5, TimeUnit.SECONDS)
        log("support kind=$kind lang=$lang $line")
    }

    private fun live(kind: String, lang: String, file: String, segmented: Boolean) {
        val samples = wavSamples(File(context.getExternalFilesDir("s0"), file))
        val pipe = ParcelFileDescriptor.createPipe()
        val events = StringBuffer()
        val ended = CountDownLatch(1)
        var audioStart = 0L
        var audioEnd = 0L
        var firstPartialAt = -1L
        var partials = 0
        var lastText = ""
        var finalAt = -1L
        var recognizer: SpeechRecognizer? = null
        fun at() = SystemClock.uptimeMillis() - audioStart
        val listener = object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) { events.append(" ready") }
            override fun onBeginningOfSpeech() { events.append(" begin@${at()}") }
            override fun onRmsChanged(rmsdB: Float) = Unit
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() { events.append(" eos@${at()}") }
            override fun onError(error: Int) { events.append(" error=$error@${at()}"); ended.countDown() }
            override fun onPartialResults(partialResults: Bundle?) {
                val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                if (text.isNotEmpty()) {
                    if (firstPartialAt < 0) firstPartialAt = at()
                    partials++
                }
            }
            override fun onSegmentResults(segmentResults: Bundle) {
                lastText += segmentResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                finalAt = at()
                events.append(" segment@${at()}")
            }
            override fun onEndOfSegmentedSession() { events.append(" sessionEnd@${at()}"); ended.countDown() }
            override fun onResults(results: Bundle?) {
                lastText += results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                finalAt = at()
                events.append(" results@${at()}")
                ended.countDown()
            }
            override fun onEvent(eventType: Int, params: Bundle?) = Unit
        }
        val started = CountDownLatch(1)
        main.post {
            recognizer = create(kind)
            val r = recognizer ?: run { started.countDown(); return@post }
            r.setRecognitionListener(listener)
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang)
                .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pipe[0])
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                .putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, SAMPLE_RATE)
            if (segmented) intent.putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
            r.startListening(intent)
            started.countDown()
        }
        started.await(5, TimeUnit.SECONDS)
        if (recognizer == null) {
            log("live kind=$kind lang=$lang segmented=$segmented unavailable")
            pipe.forEach { runCatching { it.close() } }
            return
        }
        // Feed like a microphone: 20 ms chunks at real-time pace, then 1.5 s of silence, then close. A recognizer
        // that never reads would block the pipe write, so the writer runs on its own thread with a deadline.
        val out = FileOutputStream(pipe[1].fileDescriptor)
        val chunk = SAMPLE_RATE / 50
        val total = samples.size + SAMPLE_RATE * 3 / 2
        audioStart = SystemClock.uptimeMillis()
        val writer = Thread {
            val bytes = ByteBuffer.allocate(chunk * 2).order(ByteOrder.LITTLE_ENDIAN)
            var position = 0
            try {
                while (position < total) {
                    bytes.clear()
                    for (i in 0 until chunk) bytes.putShort(if (position + i < samples.size) samples[position + i] else 0)
                    out.write(bytes.array())
                    position += chunk
                    if (position >= samples.size && audioEnd == 0L) audioEnd = SystemClock.uptimeMillis()
                    val wait = audioStart + position.toLong() * 1_000 / SAMPLE_RATE - SystemClock.uptimeMillis()
                    if (wait > 0) Thread.sleep(wait)
                }
            } catch (error: Exception) {
                events.append(" writeFailed=${error.javaClass.simpleName}@${at()}")
            }
            runCatching { out.close() }
        }.apply { start() }
        writer.join(total * 1_000L / SAMPLE_RATE + 3_000)
        if (writer.isAlive) {
            events.append(" writerBlocked@${at()}")
            runCatching { pipe[0].close() }
            writer.interrupt()
        }
        runCatching { pipe[1].close() }
        if (!segmented) main.post { recognizer?.stopListening() }
        ended.await(15, TimeUnit.SECONDS)
        val speechEndMs = audioEnd - audioStart
        main.post { recognizer?.destroy() }
        runCatching { pipe[0].close() }
        log(
            "live kind=$kind lang=$lang segmented=$segmented speechMs=$speechEndMs firstPartialMs=$firstPartialAt " +
                "partials=$partials finalMs=$finalAt text=\"$lastText\" events:$events",
        )
        Thread.sleep(500)
    }

    private fun create(kind: String): SpeechRecognizer? = when (kind) {
        "ON_DEVICE" -> if (SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else null
        else -> if (SpeechRecognizer.isRecognitionAvailable(context)) SpeechRecognizer.createSpeechRecognizer(context) else null
    }

    private fun tailRound(pcm: ShortArray, aec: Boolean, round: Int) {
        val frame = SAMPLE_RATE / 50
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, max(minBuffer, frame * 8),
        )
        val canceler = if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(record.audioSessionId) else null
        canceler?.enabled = aec
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build(),
            )
            .setAudioFormat(
                AudioFormat.Builder().setSampleRate(SAMPLE_RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build(),
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        val frames = ArrayList<Pair<Long, Double>>()
        val running = java.util.concurrent.atomic.AtomicBoolean(true)
        record.startRecording()
        val reader = Thread {
            val buffer = ShortArray(frame)
            while (running.get()) {
                val n = record.read(buffer, 0, frame)
                if (n <= 0) continue
                var sum = 0.0
                for (i in 0 until n) sum += buffer[i].toDouble() * buffer[i]
                val rms = sqrt(sum / n) / 32768.0
                val db = if (rms > 0) 20 * log10(rms) else -120.0
                synchronized(frames) { frames += SystemClock.uptimeMillis() to db }
            }
        }.apply { start() }
        Thread.sleep(1_000)
        val playStart = SystemClock.uptimeMillis()
        track.play()
        track.write(pcm, 0, pcm.size)
        var headEnd = -1L
        while (SystemClock.uptimeMillis() - playStart < pcm.size * 1_000L / SAMPLE_RATE + 3_000) {
            if (track.playbackHeadPosition >= pcm.size) {
                headEnd = SystemClock.uptimeMillis()
                break
            }
            Thread.sleep(5)
        }
        val ts = AudioTimestamp()
        val presentedEnd = if (track.getTimestamp(ts)) {
            ts.nanoTime / 1_000_000 + (pcm.size - ts.framePosition) * 1_000 / SAMPLE_RATE
        } else {
            -1L
        }
        Thread.sleep(3_000)
        running.set(false)
        reader.join(1_000)
        track.stop()
        track.release()
        record.stop()
        canceler?.release()
        record.release()
        val snapshot = synchronized(frames) { frames.toList() }
        val baseline = snapshot.filter { it.first < playStart }.map { it.second }.sorted()
        val floor = if (baseline.isEmpty()) -90.0 else baseline[baseline.size / 2]
        val during = snapshot.filter { it.first in playStart..headEnd }.map { it.second }
        val after = snapshot.filter { headEnd > 0 && it.first > headEnd }
        // Noise suppression drives silence to digital zero, so a floor-relative tail is meaningless: report the
        // loudest frame and the frames at or above the VAD start gate (-55 dBFS) per window after playback end.
        val windows = listOf(0L to 200L, 200L to 500L, 500L to 800L, 800L to 1_500L, 1_500L to 3_000L)
        val perWindow = windows.joinToString(" ") { (from, to) ->
            val inWindow = after.filter { it.first - headEnd in from until to }.map { it.second }
            "[$from-$to]max=${"%.1f".format(inWindow.maxOrNull() ?: -120.0)}/n55=${inWindow.count { it >= -55.0 }}"
        }
        val peakDuring = during.maxOrNull() ?: Double.NaN
        val n55During = during.count { it >= -55.0 }
        log(
            "tail aec=$aec round=$round floorDb=${"%.1f".format(floor)} peakDuringDb=${"%.1f".format(peakDuring)} " +
                "n55During=$n55During/${during.size} after: $perWindow " +
                "headEndMs=${headEnd - playStart} presentedEndMinusHeadEndMs=${if (presentedEnd > 0) presentedEnd - headEnd else -1}",
        )
        Thread.sleep(500)
    }

    private fun wavSamples(file: File): ShortArray {
        val bytes = file.readBytes()
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var offset = 12
        while (offset + 8 <= bytes.size) {
            val id = String(bytes, offset, 4, Charsets.US_ASCII)
            val size = buffer.getInt(offset + 4)
            if (id == "data") {
                val out = ShortArray(size / 2)
                for (i in out.indices) out[i] = buffer.getShort(offset + 8 + i * 2)
                return out
            }
            offset += 8 + size + (size and 1)
        }
        error("no data chunk in ${file.name}")
    }

    private fun log(line: String) = Log.i(TAG, line)

    private companion object {
        const val TAG = "VoiceS0"
        const val SAMPLE_RATE = 16_000
        const val REPLAY_ROUNDS = 20
        const val REPLAY_SLOT = "probe:s2"
    }
}
