package ai.oriveo.community.ui.util

import android.text.format.DateUtils

/** Formats a timestamp as a relative time string (e.g. "5 min ago"); [now] defaults to the system clock and a fixture clock can be injected. */
fun formatRelativeTime(timestamp: Long, now: Long = System.currentTimeMillis()): String {
    return DateUtils.getRelativeTimeSpanString(
        timestamp,
        now,
        DateUtils.MINUTE_IN_MILLIS,
        DateUtils.FORMAT_ABBREV_RELATIVE,
    ).toString()
}
