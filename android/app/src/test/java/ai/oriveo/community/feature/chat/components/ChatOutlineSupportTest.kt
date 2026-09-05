package ai.oriveo.community.feature.chat.components

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Test

class ChatOutlineSupportTest {

    private fun msg(
        id: String,
        role: ChatRole,
        text: String,
        attachments: List<Attachment>? = null,
    ) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "GPT-4o mini",
        state = ChatMessageState.Delivered,
        attachments = attachments,
    )

    private val attachment = Attachment(
        id = "a1",
        kind = AttachmentKind.Image,
        fileName = "x.png",
        mimeType = "image/png",
    )

    @Test
    fun derivePreview_takesFirstLineCollapsesWhitespaceTrims() {
        assertEquals("hello world", derivePreview(msg("1", ChatRole.User, "  hello   world  \nsecond"), "(att)"))
        assertEquals("a b", derivePreview(msg("1", ChatRole.User, "a\t\tb"), "(att)"))
    }

    @Test
    fun derivePreview_emptyTextFallsBackToAttachmentLabel() {
        assertEquals("(att)", derivePreview(msg("1", ChatRole.User, "   "), "(att)"))
        assertEquals("(att)", derivePreview(msg("1", ChatRole.User, "", listOf(attachment)), "(att)"))
    }

    @Test
    fun deriveOutlineTicks_keepsOnlyUserMessagesInOrder() {
        val ticks = deriveOutlineTicks(
            listOf(
                msg("u1", ChatRole.User, "first"),
                msg("a1", ChatRole.Assistant, "answer"),
                msg("u2", ChatRole.User, "second"),
            ),
            "(att)",
        )
        assertEquals(listOf("u1", "u2"), ticks.map { it.id })
        assertEquals(listOf("first", "second"), ticks.map { it.preview })
        assertEquals(listOf(0, 2), ticks.map { it.messageIndex })
    }

    @Test
    fun resolveOutlineActiveIndex_appliesRealEdgesBeforeFocusLine() {
        assertEquals(5, resolveOutlineActiveIndex(6, 4, atConversationStart = false, atConversationEnd = true))
        assertEquals(0, resolveOutlineActiveIndex(6, 1, atConversationStart = true, atConversationEnd = false))
        // A short conversation sits at both the start and end boundary at once: show the most recent turn.
        assertEquals(3, resolveOutlineActiveIndex(4, 1, atConversationStart = true, atConversationEnd = true))
        assertEquals(3, resolveOutlineActiveIndex(6, 3, atConversationStart = false, atConversationEnd = false))
        assertEquals(-1, resolveOutlineActiveIndex(0, 0, atConversationStart = true, atConversationEnd = true))
    }

    @Test
    fun outlineFocusIndex_usesBinarySearchAcrossSparseMessageIndices() {
        val ticks = listOf(
            OutlineTick("u1", "one", 0),
            OutlineTick("u2", "two", 4),
            OutlineTick("u3", "three", 9),
        )
        assertEquals(0, outlineFocusIndex(ticks, 0))
        assertEquals(1, outlineFocusIndex(ticks, 7))
        assertEquals(2, outlineFocusIndex(ticks, 99))
    }

    @Test
    fun clampPreview_truncatesBeyondLimitWithEllipsis() {
        assertEquals("short", clampPreview("short", 10))
        assertEquals("abcd…", clampPreview("abcdefghij", 4))
        assertEquals("さくらさ…", clampPreview("さくらさくら", 4))
    }

    @Test
    fun previewCharLimit_usesBreakpoints() {
        assertEquals(48, previewCharLimit(1280))
        assertEquals(32, previewCharLimit(900))
        assertEquals(24, previewCharLimit(500))
    }

    @Test
    fun tooltipMaxWidthDp_clampsSmallScreens() {
        assertEquals(320, tooltipMaxWidthDp(1280))
        assertEquals(240, tooltipMaxWidthDp(900))
        assertEquals(220, tooltipMaxWidthDp(360))
        assertEquals(152, tooltipMaxWidthDp(200))
    }

    @Test
    fun outlineVisibleRange_matrix() {
        // Fully visible within capacity
        assertEquals(0 until 10, outlineVisibleRange(totalCount = 10, currentIndex = 3, capacity = 54))
        assertEquals(0 until 54, outlineVisibleRange(totalCount = 54, currentIndex = 0, capacity = 54))
        // Tail-aligned paging: the last page is [46,100); the window is the same anywhere within that page (the dot grid doesn't shift while scrolling within a page).
        assertEquals(46 until 100, outlineVisibleRange(totalCount = 100, currentIndex = 99, capacity = 54))
        assertEquals(46 until 100, outlineVisibleRange(totalCount = 100, currentIndex = 46, capacity = 54))
        // Crossing a page boundary: 45 falls into the previous page (a partial page sits at the top of the earliest history).
        assertEquals(0 until 46, outlineVisibleRange(totalCount = 100, currentIndex = 45, capacity = 54))
        assertEquals(0 until 46, outlineVisibleRange(totalCount = 100, currentIndex = 5, capacity = 54))
        // Regression for "3 stray dots": with 57 turns, the tail page of the conversation is always a full window of 54.
        assertEquals(3 until 57, outlineVisibleRange(totalCount = 57, currentIndex = 56, capacity = 54))
        assertEquals(0 until 3, outlineVisibleRange(totalCount = 57, currentIndex = 2, capacity = 54))
        // No highlight (-1): the tail page.
        assertEquals(46 until 100, outlineVisibleRange(totalCount = 100, currentIndex = -1, capacity = 54))
        // current out of range clamps to the tail page.
        assertEquals(46 until 100, outlineVisibleRange(totalCount = 100, currentIndex = 200, capacity = 54))
        // Evenly divisible boundary: 108 = 2 full pages.
        assertEquals(54 until 108, outlineVisibleRange(totalCount = 108, currentIndex = 107, capacity = 54))
        assertEquals(0 until 54, outlineVisibleRange(totalCount = 108, currentIndex = 53, capacity = 54))
        // Defensive: capacity <= 0 shows everything.
        assertEquals(0 until 10, outlineVisibleRange(totalCount = 10, currentIndex = 3, capacity = 0))
        // Empty list.
        assertEquals(IntRange.EMPTY, outlineVisibleRange(totalCount = 0, currentIndex = -1, capacity = 54))
    }

    @Test
    fun tickFadeAlpha_edgesAndExemption() {
        // Two fade tiers at the top; active/pointed-to entries are exempt.
        assertEquals(0.15f, tickFadeAlpha(index = 0, count = 54, topFaded = true, bottomFaded = false, exempt = false))
        assertEquals(0.55f, tickFadeAlpha(index = 1, count = 54, topFaded = true, bottomFaded = false, exempt = false))
        assertEquals(1f, tickFadeAlpha(index = 0, count = 54, topFaded = true, bottomFaded = false, exempt = true))
        // Two fade tiers at the bottom.
        assertEquals(0.15f, tickFadeAlpha(index = 53, count = 54, topFaded = false, bottomFaded = true, exempt = false))
        assertEquals(0.55f, tickFadeAlpha(index = 52, count = 54, topFaded = false, bottomFaded = true, exempt = false))
        // Not at an edge / not faded.
        assertEquals(1f, tickFadeAlpha(index = 10, count = 54, topFaded = true, bottomFaded = true, exempt = false))
        assertEquals(1f, tickFadeAlpha(index = 0, count = 54, topFaded = false, bottomFaded = false, exempt = false))
    }
}
