package ai.oriveo.community.core.data.entity

/**
 * Single-row projection behind the notes card on the home screen: how many active notes there are
 * plus the title of the most recent one.
 *
 * [latestTitle] is null when there are no active notes and "" when the most recent note has an
 * empty title, which the card renders as its "untitled note" placeholder. The two cases have to
 * stay distinguishable, which is why this is nullable rather than coalesced to an empty string.
 */
data class NoteSummary(
    val activeCount: Int,
    val latestTitle: String?,
)
