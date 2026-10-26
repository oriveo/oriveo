package ai.oriveo.community.core.voice

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** [KeepScreenOnHolds]: dictation and read aloud share one per-target hold count; the original value returns only after the last hold ends. */
class KeepScreenOnHoldsTest {
    private class FakeView(var keepScreenOn: Boolean = false) {
        var writes = 0
    }

    private val holds = KeepScreenOnHolds<FakeView>(
        read = { it.keepScreenOn },
        write = { view, on ->
            view.keepScreenOn = on
            view.writes++
        },
    )
    private val dictation = Any()
    private val readAloud = Any()

    @Test
    fun keep_awake_survives_dictation_end_during_read_aloud() {
        val view = FakeView()
        holds.acquire(view, dictation)
        assertTrue(view.keepScreenOn)
        holds.acquire(view, readAloud)
        holds.release(view, dictation)
        assertTrue("read aloud still holds", view.keepScreenOn)
        holds.release(view, readAloud)
        assertFalse(view.keepScreenOn)
    }

    @Test
    fun keep_awake_restores_original_after_both_end() {
        val alreadyOn = FakeView(keepScreenOn = true)
        holds.acquire(alreadyOn, readAloud)
        holds.acquire(alreadyOn, dictation)
        holds.release(alreadyOn, readAloud)
        holds.release(alreadyOn, dictation)
        assertTrue("original true is restored", alreadyOn.keepScreenOn)

        val off = FakeView()
        holds.acquire(off, readAloud)
        holds.acquire(off, dictation)
        holds.release(off, readAloud)
        assertTrue(off.keepScreenOn)
        holds.release(off, dictation)
        assertFalse("original false is restored", off.keepScreenOn)
    }

    @Test
    fun repeated_acquire_and_release_are_idempotent() {
        val view = FakeView()
        holds.acquire(view, dictation)
        holds.acquire(view, dictation)
        holds.acquire(view, readAloud)
        holds.release(view, dictation)
        holds.release(view, dictation)
        assertTrue("a repeated release must not drop the read aloud hold", view.keepScreenOn)
        holds.release(view, readAloud)
        holds.release(view, readAloud)
        assertFalse(view.keepScreenOn)
        val writes = view.writes
        holds.release(view, dictation)
        assertEquals("release without a hold writes nothing", writes, view.writes)
    }

    @Test
    fun holds_are_tracked_per_target() {
        val a = FakeView()
        val b = FakeView()
        holds.acquire(a, dictation)
        holds.acquire(b, readAloud)
        holds.release(a, dictation)
        assertFalse(a.keepScreenOn)
        assertTrue(b.keepScreenOn)
        holds.release(b, readAloud)
        assertFalse(b.keepScreenOn)
    }
}
