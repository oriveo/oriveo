package ai.oriveo.community.feature.chat.components

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole

/**
 * Pure-logic layer for the conversation outline rail, with no Compose dependency so
 * the derivation, truncation, and threshold logic can be covered by plain JVM unit tests.
 */

/** Display threshold: the outline rail only mounts once there are more than 3 user turns. */
const val OUTLINE_MIN_USER_TURNS = 3

/** One tick corresponding to a single user message. */
data class OutlineTick(
    val id: String,
    val preview: String,
    val messageIndex: Int,
)

private val WHITESPACE = Regex("\\s+")

/**
 * Preview derivation: take the first line, collapse consecutive whitespace, then trim.
 * A user message with no text (attachment only) falls back to the localized [attachmentLabel].
 */
fun derivePreview(message: ChatMessage, attachmentLabel: String): String {
    val firstLine = message.text.substringBefore('\n')
    val collapsed = WHITESPACE.replace(firstLine, " ").trim()
    if (collapsed.isNotEmpty()) return collapsed
    if (!message.attachments.isNullOrEmpty()) return attachmentLabel
    return attachmentLabel
}

/** Derives user turn ticks from the message list, in chronological order, one per user turn. */
fun deriveOutlineTicks(messages: List<ChatMessage>, attachmentLabel: String): List<OutlineTick> =
    messages.mapIndexedNotNull { index, message ->
        if (message.role != ChatRole.User) return@mapIndexedNotNull null
        OutlineTick(id = message.id, preview = derivePreview(message, attachmentLabel), messageIndex = index)
    }

/** Clamps to the start/end boundaries, otherwise uses the mid-conversation reading focus; a short conversation that's fully on screen prefers the newest turn. */
fun resolveOutlineActiveIndex(
    tickCount: Int,
    focusIndex: Int,
    atConversationStart: Boolean,
    atConversationEnd: Boolean,
): Int {
    if (tickCount <= 0) return -1
    if (atConversationEnd) return tickCount - 1
    if (atConversationStart) return 0
    return focusIndex.coerceIn(0, tickCount - 1)
}

/** Last tick in the sorted list whose messageIndex is <= the focus line, found in O(log n). */
fun outlineFocusIndex(ticks: List<OutlineTick>, messageIndex: Int): Int {
    var low = 0
    var high = ticks.lastIndex
    var result = 0
    while (low <= high) {
        val mid = (low + high) ushr 1
        if (ticks[mid].messageIndex <= messageIndex) {
            result = mid
            low = mid + 1
        } else {
            high = mid - 1
        }
    }
    return result
}

/** Maximum tooltip preview character count, tiered by width. */
fun previewCharLimit(widthDp: Int): Int = when {
    widthDp >= 1024 -> 48
    widthDp >= 768 -> 32
    else -> 24
}

/** Maximum tooltip width in dp, tiered by width. */
fun tooltipMaxWidthDp(widthDp: Int): Int = when {
    widthDp >= 1024 -> 320
    widthDp >= 768 -> 240
    else -> minOf(220, maxOf(120, widthDp - 48))
}

/** Truncates to a character limit, appending an ellipsis if it overflows (the character-level clamp). */
fun clampPreview(preview: String, maxChars: Int): String {
    if (preview.length <= maxChars) return preview
    return preview.take(maxChars).trimEnd() + "…"
}

/**
 * Sliding window over the ticks, using tail-aligned pagination: with hundreds of turns
 * it's not practical to show them all at once, so once the tick count exceeds
 * [capacity], pages are aligned from the tail and the window becomes whichever page
 * holds the currently highlighted turn. The dots stay put while scrolling within a
 * page and only jump when crossing a page boundary -- an earlier "continuously slide
 * to stay centered" approach felt restless and was dropped.
 * Tail alignment keeps the last page always full (aligning from the head instead would
 * leave a short remainder page on entering a fresh conversation, showing only a couple
 * of isolated dots); a partial page can only ever appear at the earliest history. With
 * no highlighted turn (currentIndex < 0), the last page is used.
 */
fun outlineVisibleRange(totalCount: Int, currentIndex: Int, capacity: Int): IntRange {
    if (totalCount <= 0) return IntRange.EMPTY
    if (capacity <= 0 || totalCount <= capacity) return 0 until totalCount
    val cur = if (currentIndex >= 0) minOf(currentIndex, totalCount - 1) else totalCount - 1
    val pageFromEnd = (totalCount - 1 - cur) / capacity
    val end = totalCount - pageFromEnd * capacity
    return maxOf(0, end - capacity) until end
}

/**
 * Fades ticks near the window's edges (two opacity steps, hinting there's more above/below
 * when not on the first/last page). The current/pointed tick is exempt -- without this,
 * crossing a page boundary could land the active tick right in the faded edge zone, making
 * it look dim or lost even though it's actually the highlighted one.
 */
fun tickFadeAlpha(index: Int, count: Int, topFaded: Boolean, bottomFaded: Boolean, exempt: Boolean): Float {
    if (exempt) return 1f
    if (topFaded && index < 2) return if (index == 0) 0.15f else 0.55f
    if (bottomFaded && index >= count - 2) return if (index == count - 1) 0.15f else 0.55f
    return 1f
}
