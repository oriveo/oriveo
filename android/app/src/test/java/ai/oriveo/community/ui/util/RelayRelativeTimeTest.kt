package ai.oriveo.community.ui.util

import android.content.Context
import android.content.res.Configuration
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Relay relative time: injected clock, tiers use the same sentences as iOS. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RelayRelativeTimeTest {
    private val zone = ZoneId.of("Asia/Shanghai")
    private val now = at(2026, 10, 13, 9, 30)

    private fun at(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int = 0): Long =
        LocalDateTime.of(y, mo, d, h, mi, s).atZone(zone).toInstant().toEpochMilli()

    private fun context(locale: Locale): Context {
        val base = ApplicationProvider.getApplicationContext<Context>()
        val config = Configuration(base.resources.configuration).apply { setLocale(locale) }
        return base.createConfigurationContext(config)
    }

    private fun format(timestamp: Long, locale: Locale = Locale.US): String =
        formatRelayRelativeTime(context(locale), timestamp, now = now, zone = zone, locale = locale)

    @Test
    fun `RL2-RELTIME-01 buckets follow the contract`() {
        assertEquals(RelayRelativeTime.JustNow, RelayRelativeTime.of(now - 59_999, now, zone))
        assertEquals(RelayRelativeTime.Minutes(1), RelayRelativeTime.of(now - 60_000, now, zone))
        assertEquals(RelayRelativeTime.Minutes(59), RelayRelativeTime.of(now - 3_599_999, now, zone))
        assertEquals(RelayRelativeTime.Hours(1), RelayRelativeTime.of(now - 3_600_000, now, zone))
        assertEquals(RelayRelativeTime.Hours(23), RelayRelativeTime.of(now - 86_399_999, now, zone))
        // A full 24 h and falling on yesterday in the local calendar -> Yesterday; earlier -> month and day.
        assertEquals(RelayRelativeTime.Yesterday, RelayRelativeTime.of(at(2026, 10, 12, 8, 0), now, zone))
        assertEquals(RelayRelativeTime.MonthDay(sameYear = true), RelayRelativeTime.of(at(2026, 10, 11, 23, 0), now, zone))
        assertEquals(RelayRelativeTime.MonthDay(sameYear = false), RelayRelativeTime.of(at(2025, 12, 30, 12, 0), now, zone))
    }

    @Test
    fun `RL2-RELTIME-01 english strings match iOS without the abbreviated min dot`() {
        assertEquals("Just now", format(now - 5_000))
        assertEquals("3 min ago", format(now - 3 * 60_000))
        assertEquals("2 hr ago", format(now - 2 * 3_600_000))
        assertEquals("Yesterday", format(at(2026, 10, 12, 8, 0)))
        assertEquals("Oct 1", format(at(2026, 10, 1, 8, 0)))
        assertEquals("Dec 30, 2025", format(at(2025, 12, 30, 12, 0)))
    }

    @Test
    fun `RL2-RELTIME-01 localized strings come from the iOS copy`() {
        assertEquals("3 \u5206\u949f\u524d", format(now - 3 * 60_000, Locale.SIMPLIFIED_CHINESE))
        assertEquals("2 giờ trước", format(now - 2 * 3_600_000, Locale.forLanguageTag("vi")))
        assertEquals("Vor 3 Min.", format(now - 3 * 60_000, Locale.GERMAN))
        assertEquals("À l'instant", format(now - 5_000, Locale.FRENCH))
    }

    @Test
    fun `RL2-RELTIME-01 relay detail and key rows use the relay formatter`() {
        val board = source("feature/providers/detail/RelayDetailBoardView.kt")
        assertTrue("detail Checked ...", "relay_detail_checked_at, formatRelayRelativeTime(" in board)
        assertFalse(Regex("[^y]formatRelativeTime\\(").containsMatchIn(board))
        val keys = source("feature/providers/detail/RelayKeysPage.kt")
        assertTrue("key row Last: ...", "formatRelayRelativeTime(" in keys)
        assertFalse(Regex("[^y]formatRelativeTime\\(").containsMatchIn(keys))
    }

    private fun source(path: String): String {
        val direct = File("src/main/java/ai/oriveo/community", path)
        return (if (direct.isFile) direct else File("app/src/main/java/ai/oriveo/community", path)).readText()
    }
}
