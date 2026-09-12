package ai.oriveo.community.feature.home.homescreen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class HomeHeaderTest {
    @Test
    fun `header date formats weekday with app locale`() {
        val date = Date(1_748_801_600_000L) // 2025-06-01T12:00:00Z, Sunday
        val timeZone = TimeZone.getTimeZone("UTC")

        val zhResult = formatHomeHeaderDate(date, Locale.forLanguageTag("zh-Hans"), timeZone)
        assertTrue(zhResult.contains("6") && zhResult.contains("1"))
        assertTrue(zhResult.any { it.code in 0x4E00..0x9FFF })

        val jaResult = formatHomeHeaderDate(date, Locale.JAPANESE, timeZone)
        assertTrue(jaResult.contains("6") && jaResult.contains("1"))
        assertTrue(jaResult.any { it.code in 0x4E00..0x9FFF })

        assertEquals(
            "6월 1일 일요일",
            formatHomeHeaderDate(date, Locale.KOREAN, timeZone),
        )
        assertEquals(
            "Sunday, June 1",
            formatHomeHeaderDate(date, Locale.ENGLISH, timeZone),
        )
    }

    @Test
    fun `cased eyebrow only for scripts that have letter case`() {
        // 11sp + uppercase + letter spacing only for Latin / Cyrillic; CJK, Arabic, Devanagari and Thai have no case, and spacing would break joined scripts
        assertTrue(homeHeaderUsesCasedEyebrow(Locale.ENGLISH))
        assertTrue(homeHeaderUsesCasedEyebrow(Locale.forLanguageTag("ru")))
        assertTrue(homeHeaderUsesCasedEyebrow(Locale.forLanguageTag("pt-BR")))
        assertFalse(homeHeaderUsesCasedEyebrow(Locale.forLanguageTag("zh-Hans")))
        assertFalse(homeHeaderUsesCasedEyebrow(Locale.JAPANESE))
        assertFalse(homeHeaderUsesCasedEyebrow(Locale.KOREAN))
        assertFalse(homeHeaderUsesCasedEyebrow(Locale.forLanguageTag("ar")))
        assertFalse(homeHeaderUsesCasedEyebrow(Locale.forLanguageTag("hi")))
        assertFalse(homeHeaderUsesCasedEyebrow(Locale.forLanguageTag("th")))
    }

    @Test
    fun `header clock ticks on the next local hour including half-hour time zones`() {
        val utc = TimeZone.getTimeZone("UTC")
        // 2025-06-01T11:59:30Z → next full hour 12:00:00, 30 seconds away
        assertEquals(30_000L, millisUntilNextLocalHour(1_748_779_170_000L, utc))
        // Asia/Kolkata is +05:30: the same instant is 17:29:30 local, and the next local full hour 18:00:00 is 30 minutes 30 seconds away
        val kolkata = TimeZone.getTimeZone("Asia/Kolkata")
        assertEquals(30 * 60_000L + 30_000L, millisUntilNextLocalHour(1_748_779_170_000L, kolkata))
        // Exactly on the hour waits a full hour rather than 0 (no busy loop)
        assertEquals(3_600_000L, millisUntilNextLocalHour(1_748_779_200_000L, utc))
    }
}
