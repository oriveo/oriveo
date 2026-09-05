package ai.oriveo.community.feature.chat

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Layout guard rails for the failure recovery card (the same card once
 * overlapped on another platform: the "technical details" line at the bottom
 * of the card covered the assistant message's avatar and model name row below
 * it, because the card's height fell short of what its content needed).
 *
 * On Android the card adapts to content through two rules, both pinned here
 * with structural assertions -- once either one is changed, a visual
 * regression won't fail any functional test, so this is the only thing that
 * catches it:
 * 1. the card never has a fixed height, a height cap, or maxLines -- the
 *    number of body lines is entirely driven by content;
 * 2. the card is a sequential sibling in the host Column, not a layer floating
 *    on top of the message (a Box + align would overlap).
 */
class MessageRecoveryCardLayoutGuardTest {

    private val cardSource = File(
        "src/main/java/ai/oriveo/community/feature/chat/recovery/MessageRecoveryCard.kt",
    ).readText()

    private val hostSource = File(
        "src/main/java/ai/oriveo/community/feature/chat/recovery/MessageItemWithActions.kt",
    ).readText()

    // The card's implementation body (excludes the Preview samples at the end of the file).
    private val cardBody = cardSource.substringBefore("// -- Previews --")

    @Test
    fun `recovery card never pins or caps its own height`() {
        listOf(".height(", ".heightIn(", ".requiredHeight(", ".aspectRatio(").forEach { token ->
            assertFalse(
                "MessageRecoveryCard must not use $token -- longer body text in other languages " +
                    "(including the countdown variant) must be able to grow the card's height on its own; " +
                    "pinning a height would clip the technical-details line at the bottom.",
                cardBody.contains(token),
            )
        }
    }

    @Test
    fun `recovery card title and body are never truncated`() {
        assertFalse(
            "the recovery card's title/body must not set maxLines: truncating a four-line body down to one or two lines hides the failure reason.",
            cardBody.contains("maxLines"),
        )
        assertFalse(
            "the recovery card must not set overflow -- any overflow setting means someone intends to truncate it.",
            cardBody.contains("overflow ="),
        )
    }

    @Test
    fun `recovery card stays a sequential sibling instead of an overlay`() {
        // The card follows MessageBubble as a sequential sibling in the same Column,
        // so it always renders after the avatar + model name row instead of overlapping it.
        val columnStart = hostSource.indexOf("        Column {")
        assertTrue("host structure changed: couldn't find the Column wrapping the message and the recovery card", columnStart > 0)
        val bubbleIndex = hostSource.indexOf("MessageBubble(", columnStart)
        val cardIndex = hostSource.indexOf("MessageRecoveryCard(", columnStart)
        assertTrue("MessageBubble / MessageRecoveryCard must both live inside this Column", bubbleIndex > 0 && cardIndex > 0)
        assertTrue("the recovery card must come after the message bubble in sequential flow, not moved earlier or into an overlay", bubbleIndex < cardIndex)
        assertFalse(
            "the recovery card must not use align to stack itself: Box + align is exactly what causes that overlap.",
            Regex("""MessageRecoveryCard\([^)]*align""", RegexOption.DOT_MATCHES_ALL)
                .containsMatchIn(hostSource),
        )
    }

    @Test
    fun `pinned assistant reserve is a floor and never a ceiling`() {
        // A pinned-to-top turn adds heightIn(min=...) to its cell. As long as it stays a min,
        // the cell still grows when content exceeds the reserved height; writing it as a max would clip the recovery card.
        val listSource = File(
            "src/main/java/ai/oriveo/community/feature/chat/ChatMessagesList.kt",
        ).readText()
        val reserveModifiers = Regex("""\.heightIn\(([^)]*)\)""").findAll(listSource).toList()
        assertTrue("ChatMessagesList should still reserve a heightIn for the pinned-to-top layout", reserveModifiers.isNotEmpty())
        reserveModifiers.forEach { match ->
            val args = match.groupValues[1]
            assertTrue("a chat cell's heightIn may only pin a minimum: ${match.value}", args.contains("min ="))
            assertFalse("a chat cell's heightIn must not set a maximum: ${match.value}", args.contains("max ="))
        }
    }
}
