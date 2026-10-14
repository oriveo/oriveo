package ai.oriveo.community.ui.util

import android.content.Context
import android.text.format.DateFormat
import ai.oriveo.community.R
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.ZoneId
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Relative-time tiers for the relay "Checked ..." / "Last: ..." labels (same answer on all platforms).
 * The system DateUtils abbreviation yields "min." and differs per language, so here strings are produced tier by tier following the iOS copy.
 */
sealed interface RelayRelativeTime {
    data object JustNow : RelayRelativeTime
    data class Minutes(val value: Long) : RelayRelativeTime
    data class Hours(val value: Long) : RelayRelativeTime
    data object Yesterday : RelayRelativeTime
    data class MonthDay(val sameYear: Boolean) : RelayRelativeTime

    companion object {
        private const val MINUTE = 60_000L
        private const val HOUR = 60 * MINUTE
        private const val DAY = 24 * HOUR

        fun of(timestamp: Long, now: Long, zone: ZoneId): RelayRelativeTime {
            val elapsed = now - timestamp
            if (elapsed < MINUTE) return JustNow
            if (elapsed < HOUR) return Minutes(elapsed / MINUTE)
            if (elapsed < DAY) return Hours(elapsed / HOUR)
            val day = Instant.ofEpochMilli(timestamp).atZone(zone).toLocalDate()
            val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
            if (day == today.minusDays(1)) return Yesterday
            return MonthDay(sameYear = day.year == today.year)
        }
    }
}

fun formatRelayRelativeTime(
    context: Context,
    timestamp: Long,
    now: Long = System.currentTimeMillis(),
    zone: ZoneId = ZoneId.systemDefault(),
    locale: Locale = context.resources.configuration.locales[0],
): String = when (val bucket = RelayRelativeTime.of(timestamp, now, zone)) {
    RelayRelativeTime.JustNow -> context.getString(R.string.relay_relative_just_now)
    is RelayRelativeTime.Minutes -> context.getString(R.string.relay_relative_minutes_ago, bucket.value)
    is RelayRelativeTime.Hours -> context.getString(R.string.relay_relative_hours_ago, bucket.value)
    RelayRelativeTime.Yesterday -> context.getString(R.string.yesterday)
    is RelayRelativeTime.MonthDay -> {
        val pattern = DateFormat.getBestDateTimePattern(locale, if (bucket.sameYear) "MMMd" else "yMMMd")
        SimpleDateFormat(pattern, locale).apply { timeZone = TimeZone.getTimeZone(zone) }.format(Date(timestamp))
    }
}
