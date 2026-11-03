package ai.oriveo.community.core.voice.realtime

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.core.voice.AndroidAudioSessionCoordinator
import ai.oriveo.community.core.voice.AudioCapture
import ai.oriveo.community.core.voice.AudioCaptureEvents
import ai.oriveo.community.core.voice.AudioRecordCapture
import ai.oriveo.community.core.voice.AudioSessionOps
import ai.oriveo.community.core.voice.PcmSink
import ai.oriveo.community.core.voice.PcmSource
import ai.oriveo.community.core.voice.RecordingWriter
import ai.oriveo.community.core.voice.conversation.BLUETOOTH_TYPES
import ai.oriveo.community.core.voice.conversation.CaptureTeardownGate
import ai.oriveo.community.core.voice.conversation.CommunicationRecordSource
import ai.oriveo.community.core.voice.conversation.ConversationAudioException
import ai.oriveo.community.core.voice.conversation.ConversationInterruptions
import ai.oriveo.community.core.voice.conversation.ConversationFrames
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.conversation.EarconKind
import ai.oriveo.community.core.voice.conversation.FrameChunker
import ai.oriveo.community.core.voice.conversation.VOICE_COMMUNICATION_ATTRIBUTES
import ai.oriveo.community.core.voice.conversation.playEarconTrack
import ai.oriveo.community.core.voice.conversation.WIRED_TYPES
import ai.oriveo.community.core.voice.conversation.routeForOutputs
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch

/**
 * Realtime voice audio IO: communication-source capture uplinked as PCM16 LE frames at the rate the transport
 * declares (16 kHz passed through, or resampled to 24 kHz), plus 24 kHz PCM16 streaming playback with per-item
 * played-duration tracking.
 */
interface RealtimeAudioIO {
    /**
     * Starts capture and playback. [onFrame] gets 24 kHz PCM16 LE frames; [onInterruption] fires on focus loss.
     * An instance serves one session only: once [stop] has been called it cannot be started again.
     */
    fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit)

    /**
     * [start] with [onFrame] getting PCM16 LE frames at [uplinkRateHz] ([RealtimePCM.INPUT_RATE] passes the
     * microphone through, [RealtimePCM.OUTPUT_RATE] resamples). Implementations without a real microphone may
     * ignore the rate; the default does.
     */
    fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit, uplinkRateHz: Int) =
        start(onFrame, onInterruption)

    /**
     * Async activation form of [start]: when activation fails after [start] returns (e.g. focus is refused), [onActivationFailed] receives on the main thread
     * the same exception that the synchronous [start] would have thrown. The default implementation activates synchronously and throws on failure.
     */
    fun start(
        onFrame: (ByteArray) -> Unit,
        onInterruption: () -> Unit,
        uplinkRateHz: Int,
        onActivationFailed: (Throwable) -> Unit,
    ) = start(onFrame, onInterruption, uplinkRateHz)

    /**
     * Playback only (a session opened by typing, without the mic): output, audio mode and focus follow [start], but no capture starts; [startCapture] opens the mic later.
     * The default implementation (one without a real microphone) opens everything like [start] and drops the frames.
     */
    fun startPlayback(onInterruption: () -> Unit, onActivationFailed: (Throwable) -> Unit) =
        start({}, onInterruption, RealtimePCM.OUTPUT_RATE, onActivationFailed)

    /**
     * Starts capture after [startPlayback]: [onFrame] receives PCM16 LE frames at [uplinkRateHz]; if capture fails, the [startPlayback] interruption callback is used.
     * The default does nothing (there is no real microphone).
     */
    fun startCapture(onFrame: (ByteArray) -> Unit, uplinkRateHz: Int) = Unit

    /** Queues 24 kHz PCM16 LE audio belonging to [itemId] for playback. */
    fun enqueue(pcm16: ByteArray, itemId: String)

    /** Milliseconds of [itemId] actually played so far; 0 when unknown. */
    fun playedMs(itemId: String): Long

    /** True while queued samples have not finished playing. */
    val isPlaying: Boolean

    /**
     * Registers the player's own completion callback: [onDrained] fires (on any thread) when the last queued sample
     * has played. Never fires after [stopPlayback] until more audio is queued. Hosts never poll [isPlaying] for this.
     */
    fun setOnDrained(onDrained: () -> Unit) = Unit

    /**
     * Registers the playback level callback: [onBlock] gets each block actually written to the output, as its RMS
     * dBFS ([RealtimePCM.blockDb], null for digital silence) and its sample count at [RealtimePCM.OUTPUT_RATE].
     * Fires on the writer thread; implementations without a real output may never call it.
     */
    fun setOnPlaybackLevel(onBlock: (db: Double?, samples: Int) -> Unit) = Unit

    /**
     * Registers the capture tap: [onFrame] gets each 20 ms microphone frame at [RealtimePCM.INPUT_RATE] (before any
     * resampling) on the capture thread, right before the uplink frame made from it reaches the start callback.
     * Implementations without a real microphone may never call it.
     */
    fun setOnCaptureFrame(onFrame: (ShortArray) -> Unit) = Unit

    /**
     * dBFS ([RealtimePCM.blockDb]) of the downlink block (≤ 20 ms) at the current playback head, read on the capture
     * thread as the echo reference of the frame being gated. Null when not playing, when the head is past everything
     * written, for digital silence, and for implementations without a real output.
     */
    fun playbackReferenceDb(): Double? = null

    /**
     * Drops everything queued and silences the output immediately.
     * Milliseconds already played per item are frozen and still reported by [playedMs].
     */
    fun stopPlayback()

    /** Stops capture and playback and releases audio focus. */
    fun stop()

    /** Plays a short earcon outside the assistant playback queue; returns when it has finished. */
    suspend fun playEarcon(kind: EarconKind) = Unit
    /**
     * [onChange] gets the target output route each time an output device change re-routed the session to a
     * different route, on the main thread. The default never calls it.
     */
    fun setOnRouteChanged(onChange: (ConversationRoute) -> Unit) = Unit

    /** The output route the session is on; the default is the speaker. */
    val route: ConversationRoute get() = ConversationRoute.SPEAKER
}

/** Pure PCM helpers for the realtime path. */
object RealtimePCM {
    const val INPUT_RATE = 16_000
    const val OUTPUT_RATE = 24_000

    /**
     * Registers the capture tap: [onFrame] gets each 20 ms microphone frame at [RealtimePCM.INPUT_RATE] (before any
     * resampling) on the capture thread, right before the uplink frame made from it reaches the start callback.
     * Implementations without a real microphone may never call it.
     */
    fun setOnCaptureFrame(onFrame: (ShortArray) -> Unit) = Unit

    /**
     * Linear-interpolation 16 kHz → 24 kHz of the first [count] samples of [input] into the caller's [out] (at
     * least count * 3 / 2 long), so a capture loop reuses one buffer; returns the number of samples written.
     */
    fun resample16kTo24k(input: ShortArray, count: Int, out: ShortArray): Int {
        if (count == 0) return 0
        val outSize = count * OUTPUT_RATE / INPUT_RATE
        require(out.size >= outSize) { "output buffer holds ${out.size} samples, needs $outSize" }
        for (i in 0 until outSize) {
            // Source position = i * 2 / 3, split into integer index and fraction (in thirds).
            val num = i * INPUT_RATE
            val index = num / OUTPUT_RATE
            val frac = (num % OUTPUT_RATE).toDouble() / OUTPUT_RATE
            val a = input[index.coerceAtMost(count - 1)].toInt()
            val b = input[(index + 1).coerceAtMost(count - 1)].toInt()
            out[i] = (a + (b - a) * frac).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
        return outSize
    }

    /** Bytes of one 20 ms frame of mono PCM16 at [rateHz]. */
    fun frameBytes(rateHz: Int): Int = rateHz / 50 * 2

    /**
     * RMS dBFS of the [size] bytes of PCM16 LE in [pcm16] from [offset] (the recorder's
     * [RecordingWriter.windowLevel]); null for an empty or digitally silent block.
     */
    fun blockDb(pcm16: ByteArray, offset: Int = 0, size: Int = pcm16.size - offset): Double? {
        val count = size / 2
        var sumSquares = 0.0
        for (i in 0 until count) {
            val p = offset + 2 * i
            val v = ((pcm16[p + 1].toInt() shl 8) or (pcm16[p].toInt() and 0xff)).toShort().toDouble()
            sumSquares += v * v
        }
        return RecordingWriter.windowLevel(sumSquares, count)
    }

    fun toLittleEndian(samples: ShortArray, count: Int = samples.size): ByteArray {
        val out = ByteArray(count * 2)
        for (i in 0 until count) {
            val v = samples[i].toInt()
            out[i * 2] = (v and 0xFF).toByte()
            out[i * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        }
        return out
    }
}

/**
 * Runs a blocking teardown step ([stop] joins the capture thread / releases native audio) on [scope] so the
 * calling (main) thread never waits for it; NonCancellable so a cancelled scope still finishes the teardown.
 */
internal fun launchTeardown(scope: CoroutineScope, stop: () -> Unit): Job =
    scope.launch(NonCancellable) { runCatching { stop() } }

/**
 * Production [RealtimeAudioIO]: AudioRecord(VOICE_COMMUNICATION) + AudioTrack(24 kHz, MODE_STREAM).
 * Single use: not reusable across sessions, [start] after [stop] throws.
 */
class AndroidRealtimeAudio internal constructor(
    private val context: Context,
    // Audio session coordinator: mode / route / focus are serialized onto its thread, not done on the calling thread.
    private val sessions: AndroidAudioSessionCoordinator,
    private val newCapture: (openSource: () -> PcmSource) -> AudioCapture,
    private val newTrack: () -> AudioTrack = ::buildPlaybackTrack,
    private val teardowns: CaptureTeardownGate = CaptureTeardownGate.Shared,
    // Capture read source: opened with AudioManager and the mute callback; tests swap it to inject mute events.
    private val openSource: (AudioManager?, (silenced: Boolean) -> Unit) -> PcmSource =
        { manager, onSilenceChanged -> CommunicationRecordSource.open(manager, onSilenceChanged) },
    // Timer for the mute timeout: returns a cancel handle; null uses the main thread's postDelayed.
    private val schedule: ((delayMs: Long, action: () -> Unit) -> () -> Unit)? = null,
) : RealtimeAudioIO {
    constructor(context: Context, sessions: AndroidAudioSessionCoordinator) :
        this(context, sessions, { AudioRecordCapture(it) })

    private val mainHandler = Handler(Looper.getMainLooper())
    private val writer = Executors.newSingleThreadExecutor { Thread(it, "realtime-audio-out").apply { isDaemon = true } }
    private val lock = Any()
    private val stopped = AtomicBoolean(false)
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Guarded by [lock].
    private var capture: AudioCapture? = null
    private var captureStart: Job? = null
    private var track: AudioTrack? = null
    private var lease: AndroidAudioSessionCoordinator.Lease? = null

    // Guarded by [lock]: capture is already open or requested ([start] opens everything, or [startCapture]); a further request does not reopen it.
    private var captureRequested = false

    // The interruption callback recorded by a playback-only start; if a later-started capture fails or times out on mute, it is used to wrap up.
    @Volatile private var playbackInterruption: () -> Unit = {}

    // Guarded by [lock]: capture that starts after stop() has taken the engine is stopped by its teardown task.
    private var lateTeardown: Job? = null

    // Read and written only on the coordinator thread.
    private var focusRequest: AudioFocusRequest? = null
    private var deviceCallback: AudioDeviceCallback? = null

    /** Completes after the activation posted by [start] finishes (or is skipped by [stop]). */
    private val activated = CompletableDeferred<Unit>()

    /** [stop]'s deactivation releases once it finishes on the coordinator thread. */
    internal val deactivated = CountDownLatch(1)

    @Volatile private var cachedRoute = ConversationRoute.SPEAKER

    // Grace period for the system muting capture: used only on the main thread; [stop] takes it and cancels it.
    @Volatile private var silence: ConversationInterruptions? = null

    @Volatile private var onDrained: () -> Unit = {}

    @Volatile private var onPlaybackLevel: (Double?, Int) -> Unit = { _, _ -> }

    @Volatile private var onCaptureFrame: (ShortArray) -> Unit = {}

    @Volatile private var onRouteChanged: (ConversationRoute) -> Unit = {}

    // Read and written only on the coordinator thread: the most recently applied target route.
    private var appliedRoute: ConversationRoute? = null

    // Guarded by [lock]. Frame counts are relative to the last flush (playbackHeadPosition resets there).
    private var framesQueued = 0L
    private var generation = 0L
    private val itemRanges = HashMap<String, LongArray>() // itemId -> [startFrame, endFrame)
    private val frozenMs = HashMap<String, Long>() // itemId -> ms played before earlier stopPlayback() calls

    // Guarded by [lock]: echo reference ring, preallocated. Block k (k < refBlocks) starts at refStarts[k % size]
    // frames written to the track since the last flush, with level refDbs[k % size] (NaN = digital silence).
    private val refStarts = LongArray(REF_BLOCKS)
    private val refDbs = DoubleArray(REF_BLOCKS)
    private var refBlocks = 0L
    private var framesWritten = 0L
    override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit) =
        start(onFrame, onInterruption, RealtimePCM.OUTPUT_RATE)

    override fun start(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit, uplinkRateHz: Int) =
        start(onFrame, onInterruption, uplinkRateHz) { onInterruption() }

    /**
     * Returns immediately: activation (mode → route → focus) runs on the coordinator thread, and playback and capture start only after it finishes. A failed activation (e.g. focus refused) hands the
     * exception to [onActivationFailed] on the main thread.
     */
    override fun start(
        onFrame: (ByteArray) -> Unit,
        onInterruption: () -> Unit,
        uplinkRateHz: Int,
        onActivationFailed: (Throwable) -> Unit,
    ) {
        requireUplinkRate(uplinkRateHz)
        begin(onInterruption, onActivationFailed, CaptureStart(onFrame, uplinkRateHz))
    }

    /** Playback only: activation is the same as [start]; the playback track starts but capture does not; [startCapture] opens it later. */
    override fun startPlayback(onInterruption: () -> Unit, onActivationFailed: (Throwable) -> Unit) =
        begin(onInterruption, onActivationFailed, capture = null)

    /**
     * Starts capture later: posted to the coordinator thread, queued after activation; not done if activation failed, the session is stopped, or capture is already open (including by [start]).
     * If capture cannot start, it wraps up through the interruption callback.
     */
    override fun startCapture(onFrame: (ByteArray) -> Unit, uplinkRateHz: Int) {
        requireUplinkRate(uplinkRateHz)
        synchronized(lock) {
            if (stopped.get() || lease == null || captureRequested) return
            captureRequested = true
            sessions.post {
                val playing = synchronized(lock) { !stopped.get() && track != null }
                if (!playing) return@post
                val interruption = playbackInterruption
                try {
                    startCaptureEngine(onFrame, interruption, uplinkRateHz)
                } catch (error: Exception) {
                    mainHandler.post { if (!stopped.get()) interruption() }
                }
            }
        }
    }

    private fun requireUplinkRate(uplinkRateHz: Int) =
        require(uplinkRateHz == RealtimePCM.INPUT_RATE || uplinkRateHz == RealtimePCM.OUTPUT_RATE) {
            "unsupported uplink rate $uplinkRateHz"
        }

    /** Uplink callback and rate for capture; null = playback only. */
    private class CaptureStart(val onFrame: (ByteArray) -> Unit, val uplinkRateHz: Int)

    private fun begin(
        onInterruption: () -> Unit,
        onActivationFailed: (Throwable) -> Unit,
        capture: CaptureStart?,
    ) {
        check(!stopped.get()) { "AndroidRealtimeAudio is single use; create a new instance per session" }
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            .setAudioAttributes(VOICE_COMMUNICATION_ATTRIBUTES)
            .setOnAudioFocusChangeListener({ change ->
                when (change) {
                    AudioManager.AUDIOFOCUS_LOSS,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
                    -> mainHandler.post { onInterruption() }
                }
            }, sessions.handler)
            .build()
        // Take the lease and post the activation inside [lock]: a deactivation posted by a concurrent stop() necessarily queues after it.
        synchronized(lock) {
            check(!stopped.get()) { "stopped while starting" }
            check(lease == null) { "AndroidRealtimeAudio already started" }
            lease = sessions.claim(AndroidAudioSessionCoordinator.Client.Realtime)
            playbackInterruption = onInterruption
            captureRequested = capture != null
            sessions.post {
                try {
                    if (!stopped.get()) activate(request, onInterruption, capture)
                } catch (error: Exception) {
                    mainHandler.post { if (!stopped.get()) onActivationFailed(error) }
                } finally {
                    activated.complete(Unit)
                }
            }
        }
    }

    /** On the coordinator thread. */
    private fun AudioSessionOps.activate(
        request: AudioFocusRequest,
        onInterruption: () -> Unit,
        capture: CaptureStart?,
    ) {
        enterSession()
        changeMode(AudioManager.MODE_IN_COMMUNICATION)
        appliedRoute = routeForOutputs(devices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type })
            .also { applyRoute(it) }
        watchDevices()
        cachedRoute = sessionRoute()
        focusRequest = request
        if (requestFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            throw ConversationAudioException("audio focus denied")
        }
        if (!startTrack()) return
        capture?.let { startCaptureEngine(it.onFrame, onInterruption, it.uplinkRateHz) }
    }

    /**
     * Same rule as the cascaded conversation: Bluetooth > wired > speaker. On API 31+ the communication device is chosen (not set if nothing matches); the following opens the speaker only when there is no private route.
     */
    private fun AudioSessionOps.applyRoute(target: ConversationRoute) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val devices = availableRoutes()
            val wanted = when (target) {
                ConversationRoute.BLUETOOTH -> devices.firstOrNull { it.type in BLUETOOTH_TYPES }
                ConversationRoute.HEADPHONES -> devices.firstOrNull { it.type in WIRED_TYPES }
                ConversationRoute.SPEAKER -> devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            }
            if (wanted != null) runCatching { routeTo(wanted) }
        } else {
            speakerphone(target == ConversationRoute.SPEAKER)
        }
    }

    /**
     * Communication device type → Bluetooth / headset / speaker (API 31+). With no device (below API 31, or not set), it is judged by the current output device using the same rule:
     * Bluetooth > wired > speaker.
     */
    private fun AudioSessionOps.sessionRoute(): ConversationRoute {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) currentRouteDevice()?.type else null
        if (type != null) {
            return when (type) {
                in BLUETOOTH_TYPES -> ConversationRoute.BLUETOOTH
                in WIRED_TYPES -> ConversationRoute.HEADPHONES
                else -> ConversationRoute.SPEAKER
            }
        }
        return routeForOutputs(devices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type })
    }

    /** When a device is added or removed, the route is reset on the spot by the same rule and [cachedRoute] is refreshed; if the target route changed, it is announced on the main thread; the callback is delivered on the coordinator thread. */
    private fun AudioSessionOps.watchDevices() {
        val ops = this
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) = ops.reroute()

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) = ops.reroute()
        }
        registerDeviceCallback(callback)
        deviceCallback = callback
    }

    /** On the coordinator thread. */
    private fun AudioSessionOps.reroute() {
        if (stopped.get()) return
        val target = routeForOutputs(devices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type })
        applyRoute(target)
        cachedRoute = sessionRoute()
        if (target == appliedRoute) return
        appliedRoute = target
        mainHandler.post { if (!stopped.get()) onRouteChanged(target) }
    }

    override fun setOnRouteChanged(onChange: (ConversationRoute) -> Unit) {
        onRouteChanged = onChange
    }

    override val route: ConversationRoute
        get() = cachedRoute

    override fun setOnDrained(onDrained: () -> Unit) {
        this.onDrained = onDrained
    }

    override fun setOnPlaybackLevel(onBlock: (db: Double?, samples: Int) -> Unit) {
        onPlaybackLevel = onBlock
    }

    override fun setOnCaptureFrame(onFrame: (ShortArray) -> Unit) {
        onCaptureFrame = onFrame
    }

    /** Maps the track's marker callback to [onDrained]: only the current track, before stop, queue fully played. */
    private fun attachDrainListener(built: AudioTrack) {
        built.setPlaybackPositionUpdateListener(
            object : AudioTrack.OnPlaybackPositionUpdateListener {
                override fun onMarkerReached(reached: AudioTrack) {
                    // A marker from before a flush or stop must not report a drain of the new queue.
                    val drained = synchronized(lock) {
                        !stopped.get() && track === reached && framesQueued > 0 && headFrames() >= framesQueued
                    }
                    if (drained) onDrained()
                }

                override fun onPeriodicNotification(track: AudioTrack) = Unit
            },
            mainHandler,
        )
    }

    /** On the coordinator thread, starts the playback track after activation; false = [stop] arrived, nothing was started (capture is not started either). */
    private fun startTrack(): Boolean {
        if (stopped.get()) return false
        // Building the track and calling play are binder calls and do not hold [lock], so stop / enqueue / isPlaying on the main thread are not stalled by them.
        val built = newTrack()
        try {
            attachDrainListener(built)
            built.play()
        } catch (error: Exception) {
            runCatching { built.release() }
            throw error
        }
        val adopted = synchronized(lock) {
            if (stopped.get()) {
                false
            } else {
                track = built
                true
            }
        }
        if (!adopted) {
            // stop() arrived during track building and did not see this track: release it here (outside the lock), and do not start capture either.
            runCatching { built.release() }
        }
        return adopted
    }

    /** On the coordinator thread, starts capture after the playback track is up; not started after [stop]. */
    private fun startCaptureEngine(onFrame: (ByteArray) -> Unit, onInterruption: () -> Unit, uplinkRateHz: Int) {
        // The microphone runs at 16 kHz: a 16 kHz uplink is encoded as is; 24 kHz reuses one buffer for the
        // resampled frame (frames arrive one at a time on the capture thread).
        val upsampled = if (uplinkRateHz == RealtimePCM.INPUT_RATE) {
            null
        } else {
            ShortArray(ConversationFrames.FRAME_SAMPLES * RealtimePCM.OUTPUT_RATE / RealtimePCM.INPUT_RATE)
        }
        val chunker = FrameChunker { _, frame ->
            onCaptureFrame(frame)
            if (upsampled == null) {
                onFrame(RealtimePCM.toLittleEndian(frame))
            } else {
                val count = RealtimePCM.resample16kTo24k(frame, frame.size, upsampled)
                onFrame(RealtimePCM.toLittleEndian(upsampled, count))
            }
        }
        if (stopped.get()) return
        // Realtime has no pause state: mute does not end the session immediately; if it clears within 3 s nothing happens (capture keeps reading during mute and uplink carries zero data); only a timeout wraps up by interruption.
        val interruptions = ConversationInterruptions(
            onInterruption = {},
            onSilenceTimeout = { if (!stopped.get()) onInterruption() },
            schedule = schedule ?: { delayMs, action ->
                val task = Runnable { if (!stopped.get()) action() }
                mainHandler.postDelayed(task, delayMs)
                ({ mainHandler.removeCallbacks(task) })
            },
        )
        silence = interruptions
        val audioManager = context.getSystemService(AudioManager::class.java)
        val started = newCapture {
            // The first check is called back on the capture thread: always forwarded to the main thread; callbacks arriving after stop are dropped.
            openSource(audioManager) { silenced ->
                mainHandler.post {
                    if (!stopped.get() && silence === interruptions) {
                        interruptions.update(ConversationInterruptions.Source.SILENCED, silenced)
                    }
                }
            }
        }
        val events = object : AudioCaptureEvents {
            override fun onFailure(error: Throwable) {
                mainHandler.post { onInterruption() }
            }

            override fun onInterrupted() = Unit
        }
        // A capture stopped just before (this or an earlier session) still releases AudioRecord on IO:
        // open the new one only after that.
        val startJob = teardowns.startAfterTeardowns(
            ioScope,
            start = { started.start(listOf(PcmSink { samples, count -> chunker.add(samples, count) }), events) },
            onFailure = { mainHandler.post { if (!stopped.get()) onInterruption() } },
        )
        synchronized(lock) {
            if (stopped.get()) {
                // stop() interleaved with this start: capture it did not see is stopped here, and deactivation waits for it.
                lateTeardown = stopCapture(started, startJob)
            } else {
                capture = started
                captureStart = startJob
            }
        }
    }

    /** Off the calling thread: drops a deferred start (or awaits one already running), then stops [stopping]. */
    private fun stopCapture(stopping: AudioCapture, pendingStart: Job?): Job =
        teardowns.launchTeardown(ioScope) {
            pendingStart?.cancelAndJoin()
            stopping.stop()
        }

    override fun enqueue(pcm16: ByteArray, itemId: String) {
        val frames = (pcm16.size / BYTES_PER_FRAME).toLong()
        if (frames == 0L) return
        val gen = synchronized(lock) {
            val range = itemRanges.getOrPut(itemId) { longArrayOf(framesQueued, framesQueued) }
            framesQueued += frames
            range[1] = framesQueued
            // Completion callback when the head reaches the end of everything queued so far.
            track?.let { runCatching { it.setNotificationMarkerPosition(framesQueued.toInt()) } }
            generation
        }
        val bytes = pcm16.copyOf(frames.toInt() * BYTES_PER_FRAME)
        try {
            writer.execute {
                // Written in slices of at most 20 ms, re-checking the generation before each one so
                // stopPlayback()/stop() cut playback within one slice.
                var offset = 0
                while (offset < bytes.size) {
                    val t = synchronized(lock) { if (gen == generation) track else null } ?: return@execute
                    val size = minOf(SLICE_BYTES, bytes.size - offset)
                    // Blocking write on the writer thread; a concurrent pause+flush unblocks it.
                    val written = runCatching { t.write(bytes, offset, size) }.getOrDefault(-1)
                    if (written <= 0) return@execute
                    // Level of what was actually handed to the track, not of what was queued.
                    val db = RealtimePCM.blockDb(bytes, offset, written)
                    // A flush since the write discarded it: only the current generation's blocks are references.
                    synchronized(lock) { if (gen == generation) recordReference(db, written / BYTES_PER_FRAME) }
                    onPlaybackLevel(db, written / BYTES_PER_FRAME)
                    offset += written
                }
            }
        } catch (_: RejectedExecutionException) {
            // Writer already shut down by stop().
        }
    }

    private fun headFrames(): Long = track?.let { it.playbackHeadPosition.toLong() and 0xffffffffL } ?: 0L

    // Guarded by [lock]. Writer thread: array writes only, no allocation.
    private fun recordReference(db: Double?, frames: Int) {
        val slot = (refBlocks % REF_BLOCKS).toInt()
        refStarts[slot] = framesWritten
        refDbs[slot] = db ?: Double.NaN
        refBlocks++
        framesWritten += frames
    }

    // Guarded by [lock]: newest block starting at or before [head]; null past the written end or older than the ring.
    private fun referenceAt(head: Long): Double? {
        if (head >= framesWritten) return null
        val newest = refBlocks - 1
        val oldest = maxOf(0L, refBlocks - REF_BLOCKS)
        var k = newest
        while (k >= oldest) {
            val slot = (k % REF_BLOCKS).toInt()
            if (refStarts[slot] <= head) return refDbs[slot].takeUnless { it.isNaN() }
            k--
        }
        return null
    }

    override fun playbackReferenceDb(): Double? {
        var current: AudioTrack? = null
        var gen = 0L
        synchronized(lock) {
            current = track
            gen = generation
        }
        val t = current ?: return null
        // The head read is a native call: outside [lock], then discarded if a flush happened meanwhile.
        val head = runCatching { t.playbackHeadPosition.toLong() and 0xffffffffL }.getOrElse { return null }
        return synchronized(lock) { if (gen == generation) referenceAt(head) else null }
    }

    override fun playedMs(itemId: String): Long = synchronized(lock) {
        val ms = (frozenMs[itemId] ?: 0L) + livePlayedMs(itemId)
        // Diagnostics only (debug builds): the playback head behind this value, read without changing it.
        if (BuildConfig.DEBUG) RealtimeVoiceLog.d("playedMs ${headProbe(itemId)} ms=$ms", chatty = true)
        ms
    }

    /** Read-only snapshot of the playback head behind [playedMs] for [itemId] (diagnostics). */
    internal data class HeadProbe(
        val itemId: String,
        val head: Long,
        val rangeStart: Long?,
        val rangeEnd: Long?,
        val framesQueued: Long,
        // Null when no track exists yet.
        val playState: Int?,
        // AudioTrack.getTimestamp frame position; -1 when the track reports none.
        val timestampFrames: Long,
    ) {
        override fun toString(): String =
            "itemId=$itemId head=$head range=[$rangeStart,$rangeEnd) framesQueued=$framesQueued " +
                "playState=$playState timestampFrames=$timestampFrames"
    }

    internal fun headProbe(itemId: String): HeadProbe = synchronized(lock) {
        val t = track
        val range = itemRanges[itemId]
        val timestamp = AudioTimestamp()
        val stamped = t != null && runCatching { t.getTimestamp(timestamp) }.getOrDefault(false)
        HeadProbe(
            itemId = itemId,
            head = headFrames(),
            rangeStart = range?.get(0),
            rangeEnd = range?.get(1),
            framesQueued = framesQueued,
            playState = t?.let { runCatching { it.playState }.getOrNull() },
            timestampFrames = if (stamped) timestamp.framePosition else -1L,
        )
    }

    // Guarded by [lock]: ms of [itemId] played since the last flush.
    private fun livePlayedMs(itemId: String): Long {
        val range = itemRanges[itemId] ?: return 0L
        val played = (headFrames() - range[0]).coerceIn(0L, range[1] - range[0])
        return played * 1000 / RealtimePCM.OUTPUT_RATE
    }

    override val isPlaying: Boolean
        get() = synchronized(lock) { track != null && headFrames() < framesQueued }

    override fun stopPlayback() {
        synchronized(lock) {
            // Freeze what each item has played before the flush resets the playback head.
            for (itemId in itemRanges.keys) {
                frozenMs[itemId] = (frozenMs[itemId] ?: 0L) + livePlayedMs(itemId)
            }
            itemRanges.clear()
            generation++
            framesQueued = 0L
            refBlocks = 0L
            framesWritten = 0L
            track?.let {
                runCatching { it.pause() }
                runCatching { it.flush() }
                // The head restarts at 0: clear the marker so the old end position cannot fire.
                runCatching { it.setNotificationMarkerPosition(0) }
                runCatching { it.play() }
            }
        }
    }

    /**
     * Returns immediately. Capture stops on IO and the track is released on the write thread; deactivation runs on the coordinator thread only after both (and any unfinished activation) complete:
     * focus is released, then the route and mode are restored; the last two happen only if this session still holds the lease.
     */
    override fun stop() {
        if (!stopped.compareAndSet(false, true)) return
        // Drop the drain callback first: a marker posted before stop must not reach the controller.
        onDrained = {}
        // Cancel the pending mute timeout; the mute callback is unsubscribed when capture stops, and a late one is blocked by stopped.
        silence?.let { pending ->
            silence = null
            if (Looper.myLooper() == Looper.getMainLooper()) pending.cancel() else mainHandler.post { pending.cancel() }
        }
        val engines = synchronized(lock) {
            generation++
            framesQueued = 0L
            refBlocks = 0L
            framesWritten = 0L
            itemRanges.clear()
            frozenMs.clear()
            track?.let {
                // Unblocks a write in flight; the writer then sees the new generation and exits.
                runCatching { it.pause() }
                runCatching { it.flush() }
            }
            StoppedEngines(capture, captureStart, track, lease).also {
                capture = null
                captureStart = null
                track = null
                lease = null
            }
        }
        // AudioRecordCapture.stop() joins the capture thread and releases AudioRecord: keep it off the main thread.
        val captureStopped = engines.capture?.let { stopCapture(it, engines.pendingStart) }
        // Released on the writer thread so it never races a write; then the writer is retired.
        val trackReleased = engines.track?.let { released ->
            val done = CompletableDeferred<Unit>()
            try {
                writer.execute {
                    runCatching { released.release() }
                    done.complete(Unit)
                }
            } catch (_: RejectedExecutionException) {
                launchTeardown(ioScope) {
                    runCatching { released.release() }
                    done.complete(Unit)
                }
            }
            done
        }
        writer.shutdown()
        val held = engines.lease
        ioScope.launch(NonCancellable) {
            captureStopped?.join()
            if (held != null) activated.await()
            synchronized(lock) { lateTeardown }?.join()
            trackReleased?.await()
            sessions.post {
                try {
                    deactivate(held)
                } finally {
                    deactivated.countDown()
                }
            }
        }
    }

    private class StoppedEngines(
        val capture: AudioCapture?,
        val pendingStart: Job?,
        val track: AudioTrack?,
        val lease: AndroidAudioSessionCoordinator.Lease?,
    )

    /** On the coordinator thread: focus is released per its own request; the session baseline is restored only while [held] is still the current holder. */
    private fun AudioSessionOps.deactivate(held: AndroidAudioSessionCoordinator.Lease?) {
        focusRequest?.let { runCatching { abandonFocus(it) } }
        focusRequest = null
        deviceCallback?.let { runCatching { unregisterDeviceCallback(it) } }
        deviceCallback = null
        if (held != null && sessions.release(held)) restoreBaseline()
    }

    override suspend fun playEarcon(kind: EarconKind) {
        if (stopped.get()) return
        playEarconTrack(kind)
    }

    private companion object {
        const val BYTES_PER_FRAME = 2

        /** 20 ms of 24 kHz mono PCM16. */
        const val SLICE_BYTES = RealtimePCM.OUTPUT_RATE / 50 * BYTES_PER_FRAME

        // Echo reference ring: 128 blocks of ≤ 20 ms ≥ 2.5 s, longer than any output latency.
        const val REF_BLOCKS = 128
    }
}

/** Production playback track: 24 kHz mono PCM16, MODE_STREAM, at least 200 ms of buffer. */
private fun buildPlaybackTrack(): AudioTrack {
    val rate = RealtimePCM.OUTPUT_RATE
    val mask = AudioFormat.CHANNEL_OUT_MONO
    val encoding = AudioFormat.ENCODING_PCM_16BIT
    val min = AudioTrack.getMinBufferSize(rate, mask, encoding)
    return AudioTrack.Builder()
        .setAudioAttributes(VOICE_COMMUNICATION_ATTRIBUTES)
        .setAudioFormat(AudioFormat.Builder().setEncoding(encoding).setSampleRate(rate).setChannelMask(mask).build())
        .setTransferMode(AudioTrack.MODE_STREAM)
        .setBufferSizeInBytes(maxOf(min, rate * PLAYBACK_BYTES_PER_FRAME / 5))
        .build()
}

private const val PLAYBACK_BYTES_PER_FRAME = 2
