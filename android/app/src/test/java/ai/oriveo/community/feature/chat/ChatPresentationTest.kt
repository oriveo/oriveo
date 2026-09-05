package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatPresentationTest {

    
    
    

    

    @Test
    fun `scrolled up across items is detected`() {
        assertTrue(
            isScrolledUp(
                prevFirstVisibleIndex = 5,
                prevFirstVisibleOffset = 100,
                curFirstVisibleIndex = 4,
                curFirstVisibleOffset = 200,
            ),
        )
    }

    @Test
    fun `scrolled up within same item requires threshold`() {
        
        assertFalse(
            isScrolledUp(
                prevFirstVisibleIndex = 5,
                prevFirstVisibleOffset = 100,
                curFirstVisibleIndex = 5,
                curFirstVisibleOffset = 90,
            ),
        )
        assertTrue(
            isScrolledUp(
                prevFirstVisibleIndex = 5,
                prevFirstVisibleOffset = 100,
                curFirstVisibleIndex = 5,
                curFirstVisibleOffset = 80,
            ),
        )
    }

    @Test
    fun `firstVisible unchanged is not upward scroll`() {
        
        assertFalse(
            isScrolledUp(
                prevFirstVisibleIndex = 5,
                prevFirstVisibleOffset = 100,
                curFirstVisibleIndex = 5,
                curFirstVisibleOffset = 100,
            ),
        )
    }

    @Test
    fun `scrolled down is not upward`() {
        assertFalse(
            isScrolledUp(
                prevFirstVisibleIndex = 5,
                prevFirstVisibleOffset = 100,
                curFirstVisibleIndex = 6,
                curFirstVisibleOffset = 0,
            ),
        )
    }

    

    @Test
    fun `reserve fills viewport below the pinned user for normal content`() {
        
        assertEquals(
            1700,
            computeReservePx(viewportHeightPx = 2000, userHeightPx = 300, minAssistantVisiblePx = 120),
        )
    }

    @Test
    fun `reserve degrades to the minimum hint for an over-tall user`() {
        
        assertEquals(
            120,
            computeReservePx(viewportHeightPx = 1000, userHeightPx = 1500, minAssistantVisiblePx = 120),
        )
    }

    @Test
    fun `reserve never drops below the minimum hint near the boundary`() {
        
        assertEquals(
            120,
            computeReservePx(viewportHeightPx = 1000, userHeightPx = 920, minAssistantVisiblePx = 120),
        )
    }

    @Test
    fun `pinned assistant reserve only applies to the latest turn`() {
        val messages = listOf(
            message("u1", ChatRole.User),
            message("a1", ChatRole.Assistant),
            message("u2", ChatRole.User),
        )

        assertFalse(
            shouldApplyPinnedAssistantReserve(
                messages = messages,
                index = 1,
                pinnedTurnUserId = "u1",
            ),
        )
    }

    @Test
    fun `pinned assistant reserve applies while the pinned assistant is still latest`() {
        val messages = listOf(
            message("u1", ChatRole.User),
            message("a1", ChatRole.Assistant),
        )

        assertTrue(
            shouldApplyPinnedAssistantReserve(
                messages = messages,
                index = 1,
                pinnedTurnUserId = "u1",
            ),
        )
    }

    

    @Test
    fun `normal length user pins to top with zero offset`() {
        
        assertEquals(
            0,
            computeLongUserPinScrollOffsetPx(
                viewportHeightPx = 1000,
                userHeightPx = 800,
                minAssistantVisiblePx = 120,
            ),
        )
    }

    @Test
    fun `over-tall user is pushed up so assistant shows the minimum hint`() {
        
        
        assertEquals(
            620,
            computeLongUserPinScrollOffsetPx(
                viewportHeightPx = 1000,
                userHeightPx = 1500,
                minAssistantVisiblePx = 120,
            ),
        )
    }

    @Test
    fun `user exactly filling viewport still reserves the assistant hint`() {
        
        assertEquals(
            120,
            computeLongUserPinScrollOffsetPx(
                viewportHeightPx = 1000,
                userHeightPx = 1000,
                minAssistantVisiblePx = 120,
            ),
        )
    }

    @Test
    fun `offset is never negative just below the degradation threshold`() {
        
        assertEquals(
            0,
            computeLongUserPinScrollOffsetPx(
                viewportHeightPx = 1000,
                userHeightPx = 880,
                minAssistantVisiblePx = 120,
            ),
        )
    }

    
    
    
    

    @Test
    fun `anchor transition detaches on fling upward without pointer pressed`() {
        
        
        val decision = decideAnchorTransition(
            anchored = true,
            anchorDetached = false,
            isPointerDown = false,
            signal = ChatScrollSignal(
                scrolling = true,
                canScrollForward = true,
                firstVisibleIndex = 1,
                firstVisibleOffset = 0,
            ),
            scrolledUp = true,
        )
        assertEquals(AnchorTransition.Detach, decision)
    }

    @Test
    fun `anchor transition detaches on touch drag upward`() {
        
        val decision = decideAnchorTransition(
            anchored = true,
            anchorDetached = false,
            isPointerDown = true,
            signal = ChatScrollSignal(
                scrolling = true,
                canScrollForward = true,
                firstVisibleIndex = 2,
                firstVisibleOffset = 0,
            ),
            scrolledUp = true,
        )
        assertEquals(AnchorTransition.Detach, decision)
    }

    @Test
    fun `anchor transition detaches on upward scroll even when not anchored`() {
        
        
        assertEquals(
            AnchorTransition.Detach,
            decideAnchorTransition(
                anchored = false,
                anchorDetached = false,
                isPointerDown = true,
                signal = ChatScrollSignal(scrolling = true, canScrollForward = true, firstVisibleIndex = 0, firstVisibleOffset = 0),
                scrolledUp = true,
            ),
        )
    }

    @Test
    fun `anchor transition stays noop when not anchored and not following`() {
        
        assertEquals(
            AnchorTransition.NoOp,
            decideAnchorTransition(
                anchored = false,
                anchorDetached = true,
                isPointerDown = false,
                signal = ChatScrollSignal(scrolling = true, canScrollForward = true, firstVisibleIndex = 0, firstVisibleOffset = 0),
                scrolledUp = true,
            ),
        )
    }

    @Test
    fun `anchor transition does not reclaim when not anchored`() {
        
        assertEquals(
            AnchorTransition.NoOp,
            decideAnchorTransition(
                anchored = false,
                anchorDetached = true,
                isPointerDown = false,
                signal = ChatScrollSignal(scrolling = false, canScrollForward = false, firstVisibleIndex = 5, firstVisibleOffset = 0),
                scrolledUp = false,
            ),
        )
    }

    @Test
    fun `anchor transition stays noop when scrolledUp is false`() {
        
        assertEquals(
            AnchorTransition.NoOp,
            decideAnchorTransition(
                anchored = true,
                anchorDetached = false,
                isPointerDown = true,
                signal = ChatScrollSignal(scrolling = true, canScrollForward = true, firstVisibleIndex = 3, firstVisibleOffset = 0),
                scrolledUp = false,
            ),
        )
    }

    @Test
    fun `anchor transition reclaims when detached and settled at bottom`() {
        
        val decision = decideAnchorTransition(
            anchored = true,
            anchorDetached = true,
            isPointerDown = false,
            signal = ChatScrollSignal(
                scrolling = false,
                canScrollForward = false,
                firstVisibleIndex = 5,
                firstVisibleOffset = 0,
            ),
            scrolledUp = false,
        )
        assertEquals(AnchorTransition.Reclaim, decision)
    }

    @Test
    fun `anchor transition does not reclaim while finger still touching`() {
        
        assertEquals(
            AnchorTransition.NoOp,
            decideAnchorTransition(
                anchored = true,
                anchorDetached = true,
                isPointerDown = true,
                signal = ChatScrollSignal(scrolling = false, canScrollForward = false, firstVisibleIndex = 5, firstVisibleOffset = 0),
                scrolledUp = false,
            ),
        )
    }

    @Test
    fun `anchor transition does not reclaim while still scrolling`() {
        
        assertEquals(
            AnchorTransition.NoOp,
            decideAnchorTransition(
                anchored = true,
                anchorDetached = true,
                isPointerDown = false,
                signal = ChatScrollSignal(scrolling = true, canScrollForward = false, firstVisibleIndex = 5, firstVisibleOffset = 0),
                scrolledUp = false,
            ),
        )
    }

    

    @Test
    fun `follows ime inset on keyboard appearing while following latest`() {
        assertTrue(
            shouldFollowImeInset(
                imeDeltaPx = 40,
                followingLatest = true,
                wasAtLatestBeforeIme = false,
                streaming = false,
                isPinning = false,
                isPointerDown = false,
            ),
        )
    }

    @Test
    fun `follows ime inset on keyboard appearing when user was at latest`() {
        assertTrue(
            shouldFollowImeInset(
                imeDeltaPx = 40,
                followingLatest = false,
                wasAtLatestBeforeIme = true,
                streaming = false,
                isPinning = false,
                isPointerDown = false,
            ),
        )
    }

    @Test
    fun `follows ime inset on keyboard hiding with negative delta`() {
        assertTrue(
            shouldFollowImeInset(
                imeDeltaPx = -40,
                followingLatest = true,
                wasAtLatestBeforeIme = false,
                streaming = false,
                isPinning = false,
                isPointerDown = false,
            ),
        )
    }

    @Test
    fun `does not follow ime inset while reading history`() {
        assertFalse(
            shouldFollowImeInset(
                imeDeltaPx = 40,
                followingLatest = false,
                wasAtLatestBeforeIme = false,
                streaming = false,
                isPinning = false,
                isPointerDown = false,
            ),
        )
    }

    @Test
    fun `does not follow ime inset while finger is on the list`() {
        assertFalse(
            shouldFollowImeInset(
                imeDeltaPx = 40,
                followingLatest = true,
                wasAtLatestBeforeIme = true,
                streaming = false,
                isPinning = false,
                isPointerDown = true,
            ),
        )
    }

    @Test
    fun `does not follow ime inset when delta is zero`() {
        assertFalse(
            shouldFollowImeInset(
                imeDeltaPx = 0,
                followingLatest = true,
                wasAtLatestBeforeIme = true,
                streaming = false,
                isPinning = false,
                isPointerDown = false,
            ),
        )
    }

    @Test
    fun `does not follow ime inset during streaming`() {
        assertFalse(
            shouldFollowImeInset(
                imeDeltaPx = 40,
                followingLatest = true,
                wasAtLatestBeforeIme = true,
                streaming = true,
                isPinning = false,
                isPointerDown = false,
            ),
        )
    }

    @Test
    fun `does not follow ime inset during pin animation`() {
        assertFalse(
            shouldFollowImeInset(
                imeDeltaPx = 40,
                followingLatest = true,
                wasAtLatestBeforeIme = true,
                streaming = false,
                isPinning = true,
                isPointerDown = false,
            ),
        )
    }

    

    @Test
    fun `pinned user id resolves to the user message preceding the streaming assistant`() {
        val messages = listOf(
            message("u0", ChatRole.User),
            message("a0", ChatRole.Assistant),
            message("u1", ChatRole.User),
            message("a1", ChatRole.Assistant),
        )
        assertEquals("u1", resolvePinnedUserMessageId(messages, streamingAssistantId = "a1"))
    }

    @Test
    fun `pinned user id is null when streaming assistant is absent`() {
        val messages = listOf(message("u0", ChatRole.User))
        assertNull(resolvePinnedUserMessageId(messages, streamingAssistantId = "missing"))
    }

    @Test
    fun `pinned user id is null when no user precedes the assistant`() {
        val messages = listOf(message("a0", ChatRole.Assistant))
        assertNull(resolvePinnedUserMessageId(messages, streamingAssistantId = "a0"))
    }

    
    @Test
    fun `bottomAlignDelta subtracts afterContentPadding from viewportEndOffset`() {
        
        
        assertEquals(
            200,
            bottomAlignDelta(lastMessageBottom = 2000, viewportEndOffset = 1900, afterContentPadding = 100),
        )
    }

    @Test
    fun `bottomAlignDelta pulls back when scrolled past real bottom`() {
        
        assertEquals(
            -600,
            bottomAlignDelta(lastMessageBottom = 1200, viewportEndOffset = 1900, afterContentPadding = 100),
        )
    }

    @Test
    fun `bottomAlignDelta zero when already at real bottom`() {
        assertEquals(
            0,
            bottomAlignDelta(lastMessageBottom = 1800, viewportEndOffset = 1900, afterContentPadding = 100),
        )
    }

    

    @Test
    fun `resolveStreamingCellText prefers live streaming text`() {
        assertEquals(
            "live text",
            resolveStreamingCellText(live = "live text", held = "old", isPersistedGenerating = true),
        )
    }

    @Test
    fun `resolveStreamingCellText falls back to held text in finalize race window`() {
        
        
        assertEquals(
            "full answer",
            resolveStreamingCellText(live = null, held = "full answer", isPersistedGenerating = true),
        )
    }

    @Test
    fun `resolveStreamingCellText falls back to held text when flow resets to empty before id clears`() {
        
        assertEquals(
            "full answer",
            resolveStreamingCellText(live = "", held = "full answer", isPersistedGenerating = true),
        )
    }

    @Test
    fun `resolveStreamingCellText releases held text once message leaves Generating`() {
        
        assertNull(
            resolveStreamingCellText(live = null, held = "full answer", isPersistedGenerating = false),
        )
    }

    @Test
    fun `resolveStreamingCellText keeps empty live at genuine stream start`() {
        
        assertEquals(
            "",
            resolveStreamingCellText(live = "", held = null, isPersistedGenerating = true),
        )
    }

    @Test
    fun `resolveStreamingCellText passes through null for stale Generating rows without session`() {
        
        assertNull(
            resolveStreamingCellText(live = null, held = null, isPersistedGenerating = true),
        )
    }

    private fun message(id: String, role: ChatRole) = ChatMessage(
        id = id,
        role = role,
        text = "Hello",
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "GPT-4o mini",
        state = ChatMessageState.Delivered,
    )
}
