package ai.oriveo.community.core.voice.realtime

import android.app.Application
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.core.voice.AndroidAudioSessionCoordinator
import ai.oriveo.community.core.voice.AudioCapture
import ai.oriveo.community.core.voice.PcmSink
import ai.oriveo.community.core.voice.PcmSource
import ai.oriveo.community.core.voice.VoiceTelemetry
import ai.oriveo.community.core.voice.conversation.AndroidConversationAudio
import ai.oriveo.community.core.voice.conversation.CaptureTeardownGate
import ai.oriveo.community.core.voice.conversation.ConversationAudioListener
import ai.oriveo.community.core.voice.conversation.ConversationInterruptions
import ai.oriveo.community.core.voice.conversation.ConversationRoute
import ai.oriveo.community.core.voice.conversation.ConversationAudioException
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.AudioDeviceInfoBuilder
import org.robolectric.shadows.ShadowAudioTrack

/**
 * Production [AndroidRealtimeAudio]: stop() returns on the main thread, and stopping capture (joining the capture thread) is not done on the main thread;
 * opening a new session right after stop leaves only one capture instance; mapping of AudioTrack marker callbacks to onDrained;
 * on start the output device is chosen by cascade order (Bluetooth › wired › speaker), and restored on end.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidRealtimeAudioTeardownTest {

    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val sessionThread = HandlerThread("test-audio-session").apply { start() }
    private val sessions = AndroidAudioSessionCoordinator(app, sessionThread.looper)

    @After
    fun quitSessionThread() {
        sessionThread.quitSafely()
    }

    /** Waits for the coordinator thread to finish the delivered activation. */
    private fun idleSessions() {
        shadowOf(sessionThread.looper).idle()
    }

    /** Waits for stop's deactivation to finish on the coordinator thread. */
    private fun awaitDeactivated(audio: AndroidRealtimeAudio) {
        assertTrue("session never deactivated", audio.deactivated.await(5, TimeUnit.SECONDS))
    }

    /** Makes the coordinator thread block until the returned gate is released, to observe the state before activation. */
    private fun blockSessions(): CountDownLatch {
        val gate = CountDownLatch(1)
        sessions.handler.post { gate.await(5, TimeUnit.SECONDS) }
        return gate
    }

    /** Records the thread stop is called on; releases [stopped] once stop has finished. */
    private class ThreadRecordingCapture : AudioCapture {
        var starts = 0
        val stopThreads = mutableListOf<Thread>()
        val stopped = CountDownLatch(1)

        override fun start(sinks: List<PcmSink>) {
            starts++
        }

        override fun stop() {
            synchronized(stopThreads) { stopThreads += Thread.currentThread() }
            stopped.countDown()
        }
    }

    @Test
    fun `stop stops capture off the main thread`() {
        val capture = ThreadRecordingCapture()
        val audio = AndroidRealtimeAudio(app, sessions, newCapture = { capture })
        val main = Looper.getMainLooper().thread
        assertSame(main, Thread.currentThread())

        audio.start(onFrame = {}, onInterruption = {})
        idleSessions()
        assertEquals(1, capture.starts)
        audio.stop()

        assertTrue("capture stop never ran", capture.stopped.await(5, TimeUnit.SECONDS))
        val threads = synchronized(capture.stopThreads) { capture.stopThreads.toList() }
        assertEquals(1, threads.size)
        assertNotSame(main, threads.single())
    }

    /** Number of instances capturing at once: stop blocks on [release] until the test lets it go. */
    private class Mic {
        val active = AtomicInteger()
        val maxActive = AtomicInteger()
        val release = CountDownLatch(1)
    }

    private class GatedCapture(private val mic: Mic) : AudioCapture {
        val started = CountDownLatch(1)

        override fun start(sinks: List<PcmSink>) {
            val now = mic.active.incrementAndGet()
            mic.maxActive.accumulateAndGet(now) { a, b -> maxOf(a, b) }
            started.countDown()
        }

        override fun stop() {
            mic.release.await(5, TimeUnit.SECONDS)
            mic.active.decrementAndGet()
        }
    }

    @Test
    fun reopen_right_after_stop_has_single_capture() {
        val mic = Mic()
        val gate = CaptureTeardownGate()
        val first = GatedCapture(mic)
        val second = GatedCapture(mic)
        // Single use: one new instance per session; both share the same teardown gate (process-wide in production).
        val firstAudio = AndroidRealtimeAudio(app, sessions, newCapture = { first }, teardowns = gate)
        val secondAudio = AndroidRealtimeAudio(app, sessions, newCapture = { second }, teardowns = gate)

        firstAudio.start(onFrame = {}, onInterruption = {})
        idleSessions()
        assertEquals(0L, first.started.count)
        firstAudio.stop()
        secondAudio.start(onFrame = {}, onInterruption = {})
        idleSessions()
        assertFalse(
            "second capture opened while the first was still stopping",
            second.started.await(200, TimeUnit.MILLISECONDS),
        )

        mic.release.countDown()
        assertTrue("second capture never started", second.started.await(5, TimeUnit.SECONDS))
        assertEquals(1, mic.maxActive.get())
        secondAudio.stop()
    }

    /** Robolectric shadow AudioTrack (playback head = frames written) that records the marker listener the production class attaches. */
    private class MarkerTrack : AudioTrack(
        AudioAttributes.Builder().build(),
        AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(RealtimePCM.OUTPUT_RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build(),
        RealtimePCM.OUTPUT_RATE * 2 / 5,
        MODE_STREAM,
        AudioManager.AUDIO_SESSION_ID_GENERATE,
    ) {
        var marker: OnPlaybackPositionUpdateListener? = null

        override fun setPlaybackPositionUpdateListener(listener: OnPlaybackPositionUpdateListener?, handler: Handler?) {
            marker = listener
            super.setPlaybackPositionUpdateListener(listener, handler)
        }
    }

    @Test
    fun marker_reached_maps_to_on_drained_once() {
        val track = MarkerTrack()
        val other = MarkerTrack()
        val audio = AndroidRealtimeAudio(
            app,
            sessions,
            newCapture = { ThreadRecordingCapture() },
            newTrack = { track },
            teardowns = CaptureTeardownGate(),
        )
        var drained = 0
        audio.start(onFrame = {}, onInterruption = {})
        idleSessions()
        audio.setOnDrained { drained++ }
        val marker = checkNotNull(track.marker) { "no marker listener attached" }

        // Empty queue: a marker does not count as drained.
        marker.onMarkerReached(track)
        assertEquals(0, drained)

        val written = CountDownLatch(1)
        val onWrite = ShadowAudioTrack.OnAudioDataWrittenListener { _, _, _ -> written.countDown() }
        ShadowAudioTrack.addAudioDataListener(onWrite)
        try {
            audio.enqueue(ByteArray(RealtimePCM.OUTPUT_RATE / 50 * 2), "item")
            assertTrue("chunk never reached the track", written.await(5, TimeUnit.SECONDS))
        } finally {
            ShadowAudioTrack.removeAudioDataListener(onWrite)
        }

        // Markers from other tracks are ignored; once the current track's playback head reaches the end of the queue, onDrained fires exactly once.
        marker.onMarkerReached(other)
        assertEquals(0, drained)
        marker.onMarkerReached(track)
        assertEquals(1, drained)

        // After stop, old markers no longer call back.
        audio.stop()
        marker.onMarkerReached(track)
        assertEquals(1, drained)
    }

    private val audioManager = app.getSystemService(AudioManager::class.java)

    private fun device(type: Int): AudioDeviceInfo = AudioDeviceInfoBuilder.newBuilder().setType(type).build()

    /** No headset: output is only the earpiece and speaker; the optional call devices are the same two. */
    private fun noHeadset() {
        val earpiece = device(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE)
        val speaker = device(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
        shadowOf(audioManager).setOutputDevices(listOf(earpiece, speaker))
        shadowOf(audioManager).setAvailableCommunicationDevices(listOf(earpiece, speaker))
    }

    @Test
    fun start_selects_speaker_when_no_headset() {
        noHeadset()
        val audio = AndroidRealtimeAudio(app, sessions, newCapture = { ThreadRecordingCapture() }, teardowns = CaptureTeardownGate())

        audio.start(onFrame = {}, onInterruption = {})
        idleSessions()

        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)
        assertEquals(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, audioManager.communicationDevice?.type)
        assertEquals(VoiceTelemetry.ConversationRoute.Speaker, audio.route)
        audio.stop()
    }

    @Test
    fun stop_restores_communication_device() {
        noHeadset()
        audioManager.mode = AudioManager.MODE_NORMAL
        val audio = AndroidRealtimeAudio(app, sessions, newCapture = { ThreadRecordingCapture() }, teardowns = CaptureTeardownGate())
        audio.start(onFrame = {}, onInterruption = {})
        idleSessions()
        assertEquals(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, audioManager.communicationDevice?.type)

        audio.stop()
        awaitDeactivated(audio)

        assertNull(audioManager.communicationDevice)
        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)
    }

    @Test
    @Config(sdk = [30])
    @Suppress("DEPRECATION")
    fun below_api_31_toggles_speakerphone_and_restores_it() {
        noHeadsetOutputsOnly()
        audioManager.isSpeakerphoneOn = false
        val audio = AndroidRealtimeAudio(app, sessions, newCapture = { ThreadRecordingCapture() }, teardowns = CaptureTeardownGate())

        audio.start(onFrame = {}, onInterruption = {})
        idleSessions()
        assertTrue("speakerphone not selected without a headset", audioManager.isSpeakerphoneOn)

        audio.stop()
        awaitDeactivated(audio)
        assertFalse("speakerphone not restored", audioManager.isSpeakerphoneOn)
    }

    /** Records the mode and thread at play time; play is allowed only after activation completes. */
    private inner class RecordingTrack : AudioTrack(
        AudioAttributes.Builder().build(),
        AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(RealtimePCM.OUTPUT_RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build(),
        RealtimePCM.OUTPUT_RATE * 2 / 5,
        MODE_STREAM,
        AudioManager.AUDIO_SESSION_ID_GENERATE,
    ) {
        @Volatile var modeAtPlay: Int? = null

        override fun play() {
            modeAtPlay = audioManager.mode
            super.play()
        }
    }

    /** Records the mode at the time capture starts. */
    private inner class ModeRecordingCapture : AudioCapture {
        @Volatile var modeAtStart: Int? = null
        var starts = 0

        override fun start(sinks: List<PcmSink>) {
            starts++
            modeAtStart = audioManager.mode
        }

        override fun stop() = Unit
    }

    @Test
    fun `start activates off the main thread`() {
        noHeadset()
        audioManager.mode = AudioManager.MODE_NORMAL
        val audio = AndroidRealtimeAudio(app, sessions, newCapture = { ThreadRecordingCapture() }, teardowns = CaptureTeardownGate())
        val gate = blockSessions()

        audio.start(onFrame = {}, onInterruption = {})
        // start has returned while the coordinator thread is still blocked: nothing on the main thread changed mode or selected a device.
        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)
        assertNull(audioManager.communicationDevice)

        gate.countDown()
        idleSessions()
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)
        assertEquals(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, audioManager.communicationDevice?.type)
        audio.stop()
        awaitDeactivated(audio)
    }

    @Test
    fun `playback and capture start only after activation`() {
        noHeadset()
        audioManager.mode = AudioManager.MODE_NORMAL
        val track = RecordingTrack()
        val capture = ModeRecordingCapture()
        val audio = AndroidRealtimeAudio(
            app,
            sessions,
            newCapture = { capture },
            newTrack = { track },
            teardowns = CaptureTeardownGate(),
        )
        val gate = blockSessions()

        audio.start(onFrame = {}, onInterruption = {})
        assertNull("played before activation", track.modeAtPlay)
        assertEquals(0, capture.starts)

        gate.countDown()
        idleSessions()
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, track.modeAtPlay)
        assertEquals(1, capture.starts)
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, capture.modeAtStart)
        audio.stop()
        awaitDeactivated(audio)
    }

    // Typing-started session: only playback opened, activated per the call profile and starts the playback track, no capture; after capture is opened later, one capture starts, and opening again does not restart it.
    @Test
    fun `playback only starts the track without capture until capture is started`() {
        noHeadset()
        audioManager.mode = AudioManager.MODE_NORMAL
        val track = RecordingTrack()
        val capture = ModeRecordingCapture()
        val audio = AndroidRealtimeAudio(
            app,
            sessions,
            newCapture = { capture },
            newTrack = { track },
            teardowns = CaptureTeardownGate(),
        )

        audio.startPlayback(onInterruption = {}, onActivationFailed = {})
        idleSessions()
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, track.modeAtPlay)
        assertEquals(0, capture.starts)

        audio.startCapture(onFrame = {}, uplinkRateHz = RealtimePCM.OUTPUT_RATE)
        audio.startCapture(onFrame = {}, uplinkRateHz = RealtimePCM.OUTPUT_RATE)
        idleSessions()
        assertEquals(1, capture.starts)
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, capture.modeAtStart)
        audio.stop()
        awaitDeactivated(audio)
    }

    // Opening capture again after everything is fully open does not start a second capture.
    @Test
    fun `capture after full start does not start a second capture`() {
        noHeadset()
        val capture = ModeRecordingCapture()
        val audio = AndroidRealtimeAudio(
            app,
            sessions,
            newCapture = { capture },
            newTrack = { RecordingTrack() },
            teardowns = CaptureTeardownGate(),
        )
        audio.start(onFrame = {}, onInterruption = {})
        audio.startCapture(onFrame = {}, uplinkRateHz = RealtimePCM.OUTPUT_RATE)
        idleSessions()
        assertEquals(1, capture.starts)
        audio.stop()
        awaitDeactivated(audio)
    }

    @Test
    fun `stop deactivates after capture and playback stopped and off the main thread`() {
        noHeadset()
        audioManager.mode = AudioManager.MODE_NORMAL
        val mic = Mic()
        val capture = GatedCapture(mic)
        val audio = AndroidRealtimeAudio(app, sessions, newCapture = { capture }, teardowns = CaptureTeardownGate())
        audio.start(onFrame = {}, onInterruption = {})
        idleSessions()
        assertEquals(0L, capture.started.count)

        audio.stop()
        // stop returned on the main thread before deactivation.
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)
        // Capture has not finished stopping (blocked on release): no deactivation even when the coordinator is idle.
        idleSessions()
        assertFalse("deactivated before capture stopped", audio.deactivated.await(200, TimeUnit.MILLISECONDS))
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)
        assertEquals(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, audioManager.communicationDevice?.type)

        mic.release.countDown()
        awaitDeactivated(audio)
        assertEquals(0, mic.active.get())
        // Deactivation runs as a coordinator operation (calling from another thread throws): mode and the communication device are already restored.
        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)
        assertNull(audioManager.communicationDevice)
    }

    @Test
    fun `stop after takeover does not restore mode`() {
        noHeadset()
        audioManager.mode = AudioManager.MODE_NORMAL
        val audio = AndroidRealtimeAudio(app, sessions, newCapture = { ThreadRecordingCapture() }, teardowns = CaptureTeardownGate())
        audio.start(onFrame = {}, onInterruption = {})
        idleSessions()
        val takeover = sessions.claim(AndroidAudioSessionCoordinator.Client.Conversation)

        audio.stop()
        awaitDeactivated(audio)

        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)
        assertEquals(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, audioManager.communicationDevice?.type)
        assertSame(takeover, sessions.current)
    }

    // Old behaviour: A's deactivation ran only after B acquired the lease, so it did not restore; B recorded the call mode A had left as its own "before", and after stop the mode did not return to NORMAL.
    @Test
    fun `stop then start then stop restores the idle baseline`() {
        noHeadset()
        audioManager.mode = AudioManager.MODE_NORMAL
        val first = AndroidRealtimeAudio(app, sessions, newCapture = { ThreadRecordingCapture() }, teardowns = CaptureTeardownGate())
        first.start(onFrame = {}, onInterruption = {})
        idleSessions()
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)

        first.stop()
        val second = AndroidRealtimeAudio(app, sessions, newCapture = { ThreadRecordingCapture() }, teardowns = CaptureTeardownGate())
        second.start(onFrame = {}, onInterruption = {})
        idleSessions()
        awaitDeactivated(first)
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)
        second.stop()
        awaitDeactivated(second)

        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)
        assertNull(audioManager.communicationDevice)
        assertNull(sessions.current)
    }

    private object SilentConversationListener : ConversationAudioListener {
        override fun onFrame(index: Long, db: Double) = Unit
        override fun onRouteChanged(route: ConversationRoute, privateRouteRemoved: Boolean) = Unit
        override fun onBecomingNoisy() = Unit
        override fun onInterruption(began: Boolean) = Unit
        override fun onFocusLost() = Unit
        override fun onCaptureFailed() = Unit
    }

    // Right after conversation A closes, realtime B starts: A's deactivation releases as false, and when B ends it restores the baseline from before A.
    @Test
    fun `conversation close then realtime start and stop restores the idle baseline`() {
        noHeadset()
        audioManager.mode = AudioManager.MODE_NORMAL
        val conversation = AndroidConversationAudio(
            app,
            sessions,
            File(app.cacheDir, "realtime-handoff-turns"),
            encoderFactory = { error("no encoding in this test") },
            newCapture = { ThreadRecordingCapture() },
            teardowns = CaptureTeardownGate(),
        )
        conversation.open(SilentConversationListener, capture = false)
        idleSessions()
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)

        conversation.close()
        val realtime = AndroidRealtimeAudio(app, sessions, newCapture = { ThreadRecordingCapture() }, teardowns = CaptureTeardownGate())
        realtime.start(onFrame = {}, onInterruption = {})
        idleSessions()
        assertEquals(AudioManager.MODE_IN_COMMUNICATION, audioManager.mode)
        realtime.stop()
        awaitDeactivated(realtime)

        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)
        assertNull(audioManager.communicationDevice)
        assertNull(sessions.current)
    }

    @Test
    fun `stop before activation finishes starts neither playback nor capture`() {
        noHeadset()
        audioManager.mode = AudioManager.MODE_NORMAL
        var tracks = 0
        val capture = ModeRecordingCapture()
        val audio = AndroidRealtimeAudio(
            app,
            sessions,
            newCapture = { capture },
            newTrack = {
                tracks++
                RecordingTrack()
            },
            teardowns = CaptureTeardownGate(),
        )
        val gate = blockSessions()

        audio.start(onFrame = {}, onInterruption = {})
        audio.stop()
        gate.countDown()
        awaitDeactivated(audio)

        assertEquals(0, tracks)
        assertEquals(0, capture.starts)
        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)
        assertNull(audioManager.communicationDevice)
        assertNull(sessions.current)
    }

    /** play blocks on [proceed] until the test releases it; records release. */
    private inner class BlockingPlayTrack : AudioTrack(
        AudioAttributes.Builder().build(),
        AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(RealtimePCM.OUTPUT_RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build(),
        RealtimePCM.OUTPUT_RATE * 2 / 5,
        MODE_STREAM,
        AudioManager.AUDIO_SESSION_ID_GENERATE,
    ) {
        val playing = CountDownLatch(1)
        val proceed = CountDownLatch(1)
        val releases = AtomicInteger()

        override fun play() {
            playing.countDown()
            proceed.await(5, TimeUnit.SECONDS)
            super.play()
        }

        override fun release() {
            releases.incrementAndGet()
            super.release()
        }
    }

    @Test
    fun `stop and isPlaying do not wait for a track blocked in play`() {
        noHeadset()
        audioManager.mode = AudioManager.MODE_NORMAL
        val track = BlockingPlayTrack()
        val capture = ModeRecordingCapture()
        var captures = 0
        val audio = AndroidRealtimeAudio(
            app,
            sessions,
            newCapture = {
                captures++
                capture
            },
            newTrack = { track },
            teardowns = CaptureTeardownGate(),
        )

        audio.start(onFrame = {}, onInterruption = {})
        assertTrue("play never entered", track.playing.await(5, TimeUnit.SECONDS))
        // The coordinator thread is blocked in play: isPlaying and stop on the main thread return immediately.
        val began = System.nanoTime()
        assertFalse(audio.isPlaying)
        audio.stop()
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - began)
        assertTrue("main thread waited ${elapsedMs}ms for play", elapsedMs < 1000)
        assertEquals(0, track.releases.get())

        track.proceed.countDown()
        awaitDeactivated(audio)
        // The stopped track is released once by the side that started the engine; capture was neither created nor started.
        assertEquals(1, track.releases.get())
        assertEquals(0, captures)
        assertEquals(0, capture.starts)
        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)
        assertNull(sessions.current)
    }

    @Test
    fun `focus denied reports the start error on the main thread`() {
        noHeadset()
        shadowOf(audioManager).setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
        val capture = ModeRecordingCapture()
        val audio = AndroidRealtimeAudio(app, sessions, newCapture = { capture }, teardowns = CaptureTeardownGate())
        val failures = mutableListOf<Pair<Throwable, Thread>>()
        var interruptions = 0

        audio.start(
            onFrame = {},
            onInterruption = { interruptions++ },
            uplinkRateHz = RealtimePCM.OUTPUT_RATE,
            onActivationFailed = { failures += it to Thread.currentThread() },
        )
        idleSessions()
        shadowOf(Looper.getMainLooper()).idle()

        // Same exception type and message as the original synchronous throw from start; delivered on the main thread, not treated as an interruption, no capture starts.
        val (error, thread) = failures.single()
        assertTrue(error is ConversationAudioException)
        assertEquals("audio focus denied", error.message)
        assertSame(Looper.getMainLooper().thread, thread)
        assertEquals(0, interruptions)
        assertEquals(0, capture.starts)
        audio.stop()
        awaitDeactivated(audio)
        assertEquals(AudioManager.MODE_NORMAL, audioManager.mode)
    }

    @Test
    fun `route reads the coordinator cache without querying the audio manager`() {
        val headset = device(AudioDeviceInfo.TYPE_BLUETOOTH_SCO)
        val speaker = device(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
        shadowOf(audioManager).setOutputDevices(listOf(headset, speaker))
        shadowOf(audioManager).setAvailableCommunicationDevices(listOf(headset, speaker))
        val audio = AndroidRealtimeAudio(app, sessions, newCapture = { ThreadRecordingCapture() }, teardowns = CaptureTeardownGate())
        // Before activation: the cache has not been read, so the default speaker is used.
        assertEquals(VoiceTelemetry.ConversationRoute.Speaker, audio.route)

        audio.start(onFrame = {}, onInterruption = {})
        idleSessions()
        assertEquals(VoiceTelemetry.ConversationRoute.Bluetooth, audio.route)

        // Bypassing the coordinator to change the communication device directly: a read on the calling thread does not query AudioManager and still returns the value maintained on the coordinator thread.
        audioManager.setCommunicationDevice(speaker)
        assertEquals(VoiceTelemetry.ConversationRoute.Bluetooth, audio.route)
        audio.stop()
        awaitDeactivated(audio)
    }

    /** Below API 31 there is no optional call device list; only the output device is set. */
    private fun noHeadsetOutputsOnly() {
        shadowOf(audioManager).setOutputDevices(
            listOf(device(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE), device(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)),
        )
    }

    /** When capture starts, the read source is opened via the production openSource, recording the silence callback production attaches; the timer is triggered manually by the test. */
    private class SilenceHarness {
        val opened = CountDownLatch(1)
        @Volatile var onSilenceChanged: ((Boolean) -> Unit)? = null
        @Volatile var audioManagerSeen: AudioManager? = null
        val pending = mutableListOf<Pair<Long, () -> Unit>>()
        var interruptions = 0

        val source = object : PcmSource {
            override fun read(buffer: ShortArray, offset: Int, size: Int) = 0
            override fun observeSilenced(onSilenced: () -> Unit): () -> Unit = {}
            override fun stop() = Unit
            override fun release() = Unit
        }

        fun open(manager: AudioManager?, callback: (Boolean) -> Unit): PcmSource {
            audioManagerSeen = manager
            onSilenceChanged = callback
            opened.countDown()
            return source
        }

        fun schedule(delayMs: Long, action: () -> Unit): () -> Unit {
            val entry = delayMs to action
            pending += entry
            return { pending.remove(entry) }
        }

        fun fireTimers() = pending.toList().forEach { entry -> pending.remove(entry); entry.second() }
    }

    private class OpeningCapture : AudioCapture {
        var open: (() -> PcmSource)? = null

        override fun start(sinks: List<PcmSink>) {
            checkNotNull(open).invoke()
        }

        override fun stop() = Unit
    }

    private fun startWithSilence(harness: SilenceHarness): AndroidRealtimeAudio {
        val capture = OpeningCapture()
        val audio = AndroidRealtimeAudio(
            app,
            sessions,
            newCapture = { open -> capture.also { it.open = open } },
            teardowns = CaptureTeardownGate(),
            openSource = harness::open,
            schedule = harness::schedule,
        )
        audio.start(onFrame = {}, onInterruption = { harness.interruptions++ })
        idleSessions()
        assertTrue("capture never opened its source", harness.opened.await(5, TimeUnit.SECONDS))
        assertSame(audioManager, harness.audioManagerSeen)
        return audio
    }

    /** The callback on the capture thread takes effect after being moved to the main thread. */
    private fun silence(harness: SilenceHarness, silenced: Boolean) {
        checkNotNull(harness.onSilenceChanged).invoke(silenced)
        shadowOf(Looper.getMainLooper()).idle()
    }

    @Test
    fun realtime_capture_silenced_three_seconds_interrupts() {
        val harness = SilenceHarness()
        val audio = startWithSilence(harness)

        silence(harness, true)
        assertEquals("silencing alone does not end the session", 0, harness.interruptions)
        assertEquals(listOf(ConversationInterruptions.SILENCE_TIMEOUT_MS), harness.pending.map { it.first })

        harness.fireTimers()
        assertEquals(1, harness.interruptions)
        audio.stop()
    }

    @Test
    fun realtime_capture_silence_released_within_three_seconds_continues() {
        val harness = SilenceHarness()
        val audio = startWithSilence(harness)

        silence(harness, true)
        silence(harness, false)
        assertTrue("release cancels the timeout", harness.pending.isEmpty())
        harness.fireTimers()
        assertEquals(0, harness.interruptions)
        audio.stop()
    }

    @Test
    fun realtime_stop_cancels_pending_silence_timeout() {
        val harness = SilenceHarness()
        val audio = startWithSilence(harness)

        silence(harness, true)
        assertEquals(1, harness.pending.size)
        audio.stop()
        assertTrue("stop cancels the timeout", harness.pending.isEmpty())

        // A late silence callback after stop no longer starts a timeout and does not report an interruption.
        silence(harness, true)
        assertTrue(harness.pending.isEmpty())
        harness.fireTimers()
        assertEquals(0, harness.interruptions)
    }
}
