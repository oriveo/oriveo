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
    fun `header cjk detection follows app locale`() {
        assertTrue(isHomeHeaderCJKLocale(Locale.forLanguageTag("zh-Hans")))
        assertTrue(isHomeHeaderCJKLocale(Locale.JAPANESE))
        assertTrue(isHomeHeaderCJKLocale(Locale.KOREAN))
        assertFalse(isHomeHeaderCJKLocale(Locale.ENGLISH))
    }
}
