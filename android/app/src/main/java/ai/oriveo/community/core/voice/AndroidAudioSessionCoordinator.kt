package ai.oriveo.community.core.voice

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import androidx.annotation.RequiresApi
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * All voice-feature operations on AudioManager (focus, mode, communication device, speakerphone, device callbacks) are serialized onto one dedicated thread, so binder calls stay off the main thread.
 *
 * Single-holder lease: a later [claim] takes over; [release] returns true only when the caller is still the current holder.
 * The session baseline (mode / speakerphone) is held by [AudioSessionOps]: recorded on the first activation after idle, and not changed on takeover.
 * The holder for which [release] returns true calls [AudioSessionOps.restoreBaseline] to restore it and clear it.
 */
class AndroidAudioSessionCoordinator internal constructor(
    context: Context,
    looper: Looper,
) {
    constructor(context: Context) : this(
        context,
        HandlerThread("oriveo-audio-session").apply { start() }.looper,
    )

    enum class Client { ReadAloud, Conversation, Realtime }

    /** One audio session hold; compared by reference. */
    class Lease internal constructor(val client: Client)

    /** Handler on the coordinator thread; focus listeners and device callbacks attach to it. */
    val handler: Handler = Handler(looper)

    private val ops = AudioSessionOps(
        context.applicationContext.getSystemService(AudioManager::class.java),
        looper,
    )
    private val leaseLock = Any()

    @Volatile
    private var holder: Lease? = null

    val current: Lease? get() = holder

    fun claim(client: Client): Lease = synchronized(leaseLock) {
        Lease(client).also { holder = it }
    }

    fun release(lease: Lease): Boolean = synchronized(leaseLock) {
        if (holder === lease) {
            holder = null
            true
        } else {
            false
        }
    }

    /** Runs [block] on the coordinator thread without waiting; execution is serial in submission order. */
    fun post(block: AudioSessionOps.() -> Unit) {
        handler.post { ops.block() }
    }

    /**
     * Runs [block] on the coordinator thread and suspends until it finishes. If the caller is cancelled, [block] may still run; the caller then undoes its effect via [post].
     */
    suspend fun <T> call(block: AudioSessionOps.() -> T): T {
        if (Looper.myLooper() == handler.looper) return ops.block()
        return suspendCancellableCoroutine { cont ->
            handler.post {
                val result = runCatching { ops.block() }
                if (!cont.isActive) return@post
                result.fold(cont::resume, cont::resumeWithException)
            }
        }
    }
}

/**
 * Typed wrapper for AudioManager calls held by the coordinator; any operation not on the coordinator thread throws [IllegalStateException].
 */
class AudioSessionOps internal constructor(
    private val audioManager: AudioManager?,
    private val looper: Looper,
) {
    // Read and written only on the coordinator thread: mode / speakerphone before the first activation after idle.
    private var baselineMode: Int? = null
    private var baselineSpeakerphone: Boolean? = null

    private fun checkThread() {
        check(Looper.myLooper() == looper) {
            "audio session operation on ${Thread.currentThread().name}, not on the coordinator thread"
        }
    }

    /** Call before changing mode / routing on activation: records the current mode and speakerphone only if no baseline exists; takeovers keep the first one. */
    fun enterSession() {
        checkThread()
        if (baselineMode != null) return
        baselineMode = currentMode()
        baselineSpeakerphone = speakerphone()
    }

    /**
     * Called by the holder for which [AndroidAudioSessionCoordinator.release] returns true: clears the communication device (API 31+) or restores speakerphone (below), then restores
     * mode and clears the baseline. Does nothing when there is no baseline (no session was ever activated).
     */
    fun restoreBaseline() {
        checkThread()
        val mode = baselineMode ?: return
        val speaker = baselineSpeakerphone
        baselineMode = null
        baselineSpeakerphone = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { clearRoute() }
        } else {
            speaker?.let { runCatching { speakerphone(it) } }
        }
        runCatching { changeMode(mode) }
    }

    fun requestFocus(request: AudioFocusRequest): Int {
        checkThread()
        return audioManager?.requestAudioFocus(request) ?: AudioManager.AUDIOFOCUS_REQUEST_FAILED
    }

    fun abandonFocus(request: AudioFocusRequest): Int {
        checkThread()
        return audioManager?.abandonAudioFocusRequest(request) ?: AudioManager.AUDIOFOCUS_REQUEST_FAILED
    }

    fun changeMode(mode: Int) {
        checkThread()
        audioManager?.mode = mode
    }

    fun currentMode(): Int {
        checkThread()
        return audioManager?.mode ?: AudioManager.MODE_NORMAL
    }

    @RequiresApi(Build.VERSION_CODES.S)
    fun routeTo(device: AudioDeviceInfo): Boolean {
        checkThread()
        return audioManager?.setCommunicationDevice(device) ?: false
    }

    @RequiresApi(Build.VERSION_CODES.S)
    fun clearRoute() {
        checkThread()
        audioManager?.clearCommunicationDevice()
    }

    /** Current speakerphone state; if [on] is given, it is set first and then returned. */
    fun speakerphone(on: Boolean? = null): Boolean {
        checkThread()
        val manager = audioManager ?: return false
        if (on != null) manager.isSpeakerphoneOn = on
        return manager.isSpeakerphoneOn
    }

    @RequiresApi(Build.VERSION_CODES.S)
    fun availableRoutes(): List<AudioDeviceInfo> {
        checkThread()
        return audioManager?.availableCommunicationDevices.orEmpty()
    }

    @RequiresApi(Build.VERSION_CODES.S)
    fun currentRouteDevice(): AudioDeviceInfo? {
        checkThread()
        return audioManager?.communicationDevice
    }

    fun devices(flags: Int): List<AudioDeviceInfo> {
        checkThread()
        return audioManager?.getDevices(flags)?.toList().orEmpty()
    }

    /** Registers [callback]; callbacks are delivered on the coordinator thread. */
    fun registerDeviceCallback(callback: AudioDeviceCallback) {
        checkThread()
        audioManager?.registerAudioDeviceCallback(callback, Handler(looper))
    }

    fun unregisterDeviceCallback(callback: AudioDeviceCallback) {
        checkThread()
        audioManager?.unregisterAudioDeviceCallback(callback)
    }
}
