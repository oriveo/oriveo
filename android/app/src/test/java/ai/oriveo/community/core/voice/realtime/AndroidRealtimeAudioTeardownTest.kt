package ai.oriveo.community.core.voice.realtime

import android.app.Application
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.core.voice.AudioCapture
import ai.oriveo.community.core.voice.PcmSink
import ai.oriveo.community.core.voice.conversation.CaptureTeardownGate
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAudioTrack

/**
 * Production [AndroidRealtimeAudio]: stop() returns on the main thread, and stopping capture (joining the capture thread) is not done on the main thread;
 * opening a new session right after stop leaves only one capture instance; mapping of AudioTrack marker callbacks to onDrained.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidRealtimeAudioTeardownTest {

    private val app = ApplicationProvider.getApplicationContext<Application>()

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
        val audio = AndroidRealtimeAudio(app, newCapture = { capture })
        val main = Looper.getMainLooper().thread
        assertSame(main, Thread.currentThread())

        audio.start(onFrame = {}, onInterruption = {})
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
        val firstAudio = AndroidRealtimeAudio(app, newCapture = { first }, teardowns = gate)
        val secondAudio = AndroidRealtimeAudio(app, newCapture = { second }, teardowns = gate)

        firstAudio.start(onFrame = {}, onInterruption = {})
        assertEquals(0L, first.started.count)
        firstAudio.stop()
        secondAudio.start(onFrame = {}, onInterruption = {})
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
            newCapture = { ThreadRecordingCapture() },
            newTrack = { track },
            teardowns = CaptureTeardownGate(),
        )
        var drained = 0
        audio.start(onFrame = {}, onInterruption = {})
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
}
