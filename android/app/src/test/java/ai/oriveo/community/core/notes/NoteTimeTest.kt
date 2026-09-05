package ai.oriveo.community.core.notes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NoteTimeTest {

    @Test
    fun `isoNewer compares correctly`() {
        assertTrue(NoteTime.isoNewer("2026-06-05T00:00:00Z", "2026-06-01T00:00:00Z"))
        assertFalse(NoteTime.isoNewer("2026-06-01T00:00:00Z", "2026-06-05T00:00:00Z"))
        assertFalse(NoteTime.isoNewer("2026-06-01T00:00:00Z", "2026-06-01T00:00:00Z"))
    }

    @Test
    fun `isoNewer treats unparseable remote as not newer`() {
        assertFalse(NoteTime.isoNewer("garbage", "2026-06-01T00:00:00Z"))
        assertFalse(NoteTime.isoNewer(null, "2026-06-01T00:00:00Z"))
    }

    @Test
    fun `isoNewer treats unparseable local as older (remote wins)`() {
        assertTrue(NoteTime.isoNewer("2026-06-01T00:00:00Z", null))
        assertTrue(NoteTime.isoNewer("2026-06-01T00:00:00Z", "garbage"))
    }

    @Test
    fun `nowIso roundtrips through parser`() {
        val now = NoteTime.nowIso()
        assertTrue(NoteTime.isoToMillisOrNull(now) != null)
    }

    @Test
    fun `isoToDate yields yyyy-MM-dd in UTC`() {
        assertEquals("2026-06-10", NoteTime.isoToDate("2026-06-10T23:30:00Z"))
        assertEquals("", NoteTime.isoToDate("garbage"))
    }

    @Test
    fun `millisToIso roundtrips`() {
        val millis = 1_750_000_000_000L
        assertEquals(millis, NoteTime.isoToMillisOrNull(NoteTime.millisToIso(millis)))
    }
}
