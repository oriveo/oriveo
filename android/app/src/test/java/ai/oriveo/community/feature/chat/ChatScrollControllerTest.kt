package ai.oriveo.community.feature.chat

import androidx.compose.ui.unit.Constraints
import ai.oriveo.community.ui.component.MAX_HEIGHT_CONSTRAINT_PX
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [ChatScrollController]'s state machine (no LazyListState involved -- only
 * verifies the follow / pin-to-top / reserve state transitions and the arbitration
 * predicates). Mirrors the same "state should be purely unit-testable" goal as iOS's
 * ChatStickToBottomControllerTests.
 */
class ChatScrollControllerTest {

    @Test
    fun `initial state is detached and unanchored`() {
        val c = ChatScrollController()
        assertFalse(c.following)
        assertFalse(c.isPinning)
        assertFalse(c.isAnchored)
        assertEquals(0, c.reservePx)
        assertEquals(0, c.pinnedAssistantFloorPx)
    }

    @Test
    fun `resumeFollowing turns following on`() {
        val c = ChatScrollController()
        c.resumeFollowing()
        assertTrue(c.following)
    }

    @Test
    fun `Detach transition stops following and signals keyboard hide`() {
        val c = ChatScrollController()
        c.resumeFollowing()
        val shouldHideKeyboard = c.applyTransition(AnchorTransition.Detach)
        assertFalse(c.following)
        assertTrue(shouldHideKeyboard)
    }

    @Test
    fun `Reclaim transition resumes following without keyboard hide`() {
        val c = ChatScrollController()
        val shouldHideKeyboard = c.applyTransition(AnchorTransition.Reclaim)
        assertTrue(c.following)
        assertFalse(shouldHideKeyboard)
    }

    @Test
    fun `NoOp transition leaves following untouched`() {
        val c = ChatScrollController()
        c.resumeFollowing()
        c.applyTransition(AnchorTransition.NoOp)
        assertTrue(c.following)
        c.applyTransition(AnchorTransition.Detach)
        c.applyTransition(AnchorTransition.NoOp)
        assertFalse(c.following)
    }

    @Test
    fun `reset clears follow state but not streamingMode (generation state is driven separately)`() {
        val c = ChatScrollController()
        c.resumeFollowing()
        c.applyTransition(AnchorTransition.Reclaim)
        c.updateStreamingMode(true)
        c.reportPinnedAssistantHeight(900)
        c.reset()
        assertFalse(c.following)
        assertFalse(c.isPinning)
        assertFalse(c.isAnchored)
        assertEquals(0, c.reservePx)
        assertEquals(0, c.pinnedAssistantFloorPx)
        // streamingMode is not cleared by reset -- switching into a conversation that's
        // mid-stream must keep the value the generation-state effect just set.
        assertTrue(c.streamingMode)
    }

    @Test
    fun `pinnedAssistantFloorPx is monotonic non-decreasing`() {
        val c = ChatScrollController()
        assertEquals(0, c.pinnedAssistantFloorPx)
        c.reportPinnedAssistantHeight(800)
        assertEquals(800, c.pinnedAssistantFloorPx)
        // A block-close relayout, or the frame where a settled cell's natural height briefly
        // drops, must not let the floor sink -- that's what stops LazyColumn from bouncing
        // back up to the pinned position.
        c.reportPinnedAssistantHeight(600)
        assertEquals(800, c.pinnedAssistantFloorPx)
        // The floor keeps rising as content keeps growing.
        c.reportPinnedAssistantHeight(1200)
        assertEquals(1200, c.pinnedAssistantFloorPx)
    }

    /**
     * The floor is fed back into layout via `heightIn(min=)`; once it exceeds what
     * [Constraints] can represent, every subsequent measure pass throws
     * `Can't represent a width of 0 and height of N in Constraints`. This constructs a real
     * [Constraints] directly so the assertion catches that.
     */
    @Test
    fun `pinnedAssistantFloorPx never exceeds what Constraints can represent`() {
        val c = ChatScrollController()
        c.reportPinnedAssistantHeight(262_146)
        assertEquals(MAX_HEIGHT_CONSTRAINT_PX, c.pinnedAssistantFloorPx)
        Constraints(minWidth = 0, maxWidth = Constraints.Infinity, minHeight = c.pinnedAssistantFloorPx)
        // Reporting even higher values afterward does not push past the cap.
        c.reportPinnedAssistantHeight(Int.MAX_VALUE)
        assertEquals(MAX_HEIGHT_CONSTRAINT_PX, c.pinnedAssistantFloorPx)
    }

    @Test
    fun `non-positive reported height never lowers or corrupts the floor`() {
        val c = ChatScrollController()
        c.reportPinnedAssistantHeight(800)
        c.reportPinnedAssistantHeight(-1)
        assertEquals(800, c.pinnedAssistantFloorPx)
    }

    @Test
    fun `streamingMode toggles (stream-frozen behavior)`() {
        val c = ChatScrollController()
        assertFalse(c.streamingMode)
        c.updateStreamingMode(true)
        assertTrue(c.streamingMode)
        c.updateStreamingMode(false)
        assertFalse(c.streamingMode)
    }

    @Test
    fun `streamingMode is independent of following`() {
        // Even if `following` gets set to true via reclaim, streamingMode still
        // independently suppresses follow (see followToBottom).
        val c = ChatScrollController()
        c.updateStreamingMode(true)
        c.resumeFollowing()
        assertTrue(c.following)
        assertTrue(c.streamingMode)
    }

    @Test
    fun `entering streaming clears residual following (mirrors iOS setStreamingMode)`() {
        // Regression guard for a short reply that renders, scrolls up briefly, then snaps
        // back down: entering an existing conversation leaves `following=true` (set by
        // resumeFollowing() at the end of ChatInitialScrollToBottomEffect); sending a message
        // in that conversation then enters streaming, which pins to top without resetting
        // `following`, so streamingMode suppresses follow during the stream (no jitter). But
        // once streaming ends and streamingMode clears, the stale `following=true` makes
        // followToBottom snap to the bottom immediately, yanking a short answer's pinned-top
        // position down to the last line. Mirrors iOS's
        // ChatStickToBottomController.setStreamingMode(true), which forces isFollowing=false
        // so entering streaming always clears the stale state.
        val c = ChatScrollController()
        c.resumeFollowing() // simulates following=true after entering an existing conversation
        assertTrue(c.following)
        c.updateStreamingMode(true) // sending a message enters streaming
        assertFalse(c.following)
        assertTrue(c.streamingMode)
    }

    @Test
    fun `follows ime inset only while following or was at latest`() {
        val c = ChatScrollController()
        c.resumeFollowing()
        assertTrue(c.canFollowImeInset(deltaPx = 40, wasAtLatestBeforeIme = false, isPointerDown = false))

        c.applyTransition(AnchorTransition.Detach)
        assertFalse(c.canFollowImeInset(deltaPx = 40, wasAtLatestBeforeIme = false, isPointerDown = false))
        // not following, but was at the bottom before the keyboard appeared -> still follows
        // (both showing and hiding the keyboard fall back to the pre-keyboard position).
        assertTrue(c.canFollowImeInset(deltaPx = 40, wasAtLatestBeforeIme = true, isPointerDown = false))
    }

    @Test
    fun `does not follow ime inset during streaming`() {
        val c = ChatScrollController()
        c.resumeFollowing()
        c.updateStreamingMode(true)
        // stream-frozen: both showing and hiding the keyboard yield.
        assertFalse(c.canFollowImeInset(deltaPx = 40, wasAtLatestBeforeIme = true, isPointerDown = false))
        assertFalse(c.canFollowImeInset(deltaPx = -40, wasAtLatestBeforeIme = true, isPointerDown = false))
    }
}
