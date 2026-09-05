package ai.oriveo.community.feature.chat

import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import ai.oriveo.community.ui.component.coerceHeightConstraintPx

/** Max frames for the post-pin reconciliation scrollBy loop (a safety net; once reserve is in effect it normally settles within 1-2 frames). */
private const val PIN_RECONCILE_MAX_FRAMES = 12

/** Tolerance (px) for deciding the user bubble is flush with the top of the viewport. */
private const val PIN_RECONCILE_TOLERANCE_PX = 2

/** Max frames to poll, before starting the pin animation, waiting for the reserve's heightIn to actually land in layout (exits early once ready instead of always waiting the full budget). */
private const val PIN_RESERVE_READY_MAX_FRAMES = 8

/** Tolerance (px) for deciding reserve is ready: covers the dp<->px round-trip rounding gap between the assistant cell's measured height and the reserve value. */
private const val PIN_RESERVE_READY_SLOP_PX = 8

/**
 * The single writer for chat-list scroll behavior -- pin-to-top plus stick-to-bottom follow.
 *
 * Why this was consolidated: pin animation, follow-to-bottom, scroll-on-entry, and the FAB's
 * jump-to-latest used to live as 4 separate `LaunchedEffect`s in ChatScreen, each calling
 * [LazyListState]'s `animateScrollToItem` / `scrollBy` / `scrollToItem` directly and
 * interlocking through three bare booleans (`following`/`isPinning`/`isPointerDown`) -- races
 * scattered across call sites, hard to unit test, and patched repeatedly over time (double
 * detachment, gestures stolen right as rendering finished).
 *
 * This controller collects **every scroll-writing primitive** into three methods -- [pinToTop],
 * [followToBottom], [scrollToBottom] -- and keeps following/pinning/reserve state as private,
 * observable state that only the controller itself can mutate, with all arbitration logic
 * living inside those methods. ChatScreen's effects are reduced to a thin "observe a signal,
 * call the matching intent method" delegation.
 *
 * The state-machine parts ([reset] / [resumeFollowing] / [applyTransition]) are pure state
 * transitions and can be unit tested without depending on Compose.
 */
@Stable
internal class ChatScrollController {

    /** Stick-to-bottom follow flag. True on send/return-to-bottom, false once the user scrolls up to stop following. Drives follow-to-bottom once the answer outgrows the reserve. */
    var following by mutableStateOf(false)
        private set

    /** True while the send-time pin's animateScrollToItem is running; follow yields to the pin animation during this window to avoid fighting over position. */
    var isPinning by mutableStateOf(false)
        private set

    /**
     * Streaming-time still mode: while true, follow always yields -- the viewport stays put,
     * the answer grows downward below the user message, and can extend off-screen (the user has
     * to scroll or tap the FAB to catch up). Driven by generation state (i.e. while streaming).
     *
     * Why: the old "keep following to the bottom while streaming" behavior, combined with the
     * streaming height floor, could push the transient blank space left behind when a block
     * closes into the visible area (that blank space would otherwise sit off-screen). Users
     * would see a gap suddenly appear below the answer right as the completion haptic fired,
     * and read it as "done rendering" when it wasn't. Not following during streaming keeps that
     * gap off-screen, removes the scrollBy jitter that comes with following, and removes the
     * "scrolled to a blank bottom" visual that made the haptic misleading.
     */
    var streamingMode by mutableStateOf(false)
        private set

    /** User-message id of the most recently pinned-to-top turn; the assistant item immediately after it gets a static reserve (heightIn min) at the item level. */
    var pinnedTurnUserId by mutableStateOf<String?>(null)
        private set

    /** Minimum reserved height for that turn's assistant reply (px), computed once at send time as viewport minus the user bubble's height. */
    var reservePx by mutableIntStateOf(0)
        private set

    /**
     * A **monotonically increasing height floor** (px, never decreases) for the pinned-to-top
     * turn's assistant cell, layered on top of the reserve. Why this exists: during streaming,
     * a block closing and getting re-parsed, a committed segment reflowing, or the settled
     * state releasing its internal streamingHeightFloor can all momentarily drop the cell's
     * natural height for one frame. If the user has already scrolled away from the pinned
     * position and the cell sits at or crosses firstVisibleItem, LazyColumn's "keep the
     * viewport filled" anchor logic pulls the anchor back -- and the user bubble propped up by
     * the reserve is exactly the geometric point it snaps back to, bouncing the viewport back
     * to **the start of this turn's reply**. Clamping the cell height with a monotonic floor
     * means it never dips, so LazyColumn never has anything to "fill in" and never triggers that
     * snap-back. Reset on turn change / conversation switch by [pinToTop] / [reset].
     */
    var pinnedAssistantFloorPx by mutableIntStateOf(0)
        private set

    /** Whether we're currently in a pinned-to-top turn (feeds the `anchored` input to [decideAnchorTransition]). */
    val isAnchored: Boolean get() = pinnedTurnUserId != null

    /** Reset on conversation switch/entry: clears any reserve left over from a previous short answer, otherwise the new conversation's scroll target would count that leftover blank space and the last message wouldn't sit flush at the bottom. */
    fun reset() {
        pinnedTurnUserId = null
        reservePx = 0
        pinnedAssistantFloorPx = 0
        following = false
        isPinning = false
        // Note: deliberately not clearing streamingMode here -- it tracks generation state and
        // is driven independently by ChatScreen's isGenerating effect. If reset() cleared it,
        // switching into a conversation that's still streaming would wipe out the true value
        // the generation-state effect just set, causing an incorrect follow.
    }

    /** Resumes following (after the scroll-to-bottom-on-entry completes, or from the FAB's jump-to-latest). */
    fun resumeFollowing() {
        following = true
    }

    /**
     * Called when the user taps to jump via the table-of-contents rail: stops following so
     * [ChatFollowToBottomEffect] doesn't drag the viewport back down while the
     * animateScrollToItem jump is still in flight (most noticeable when jumping to an older
     * message).
     */
    fun stopFollowingForJump() {
        following = false
    }

    /**
     * Enters/exits streaming-still mode (driven by ChatScreen based on generation state).
     *
     * Entering streaming (active=true) must force `following = false`. Otherwise, the
     * `following=true` set by [resumeFollowing] at the end of the entry-time scroll-to-bottom
     * effect can carry over into this turn's send: [streamingMode] suppresses [followToBottom]
     * while streaming (so nothing jitters and the problem stays hidden), but once streaming ends
     * and streamingMode clears, that stale `following=true` makes followToBottom snap straight
     * to the bottom, yanking a short answer's pinned position down to flush-bottom -- the user
     * sees the content "finish rendering, jump up, then bounce back". Exiting streaming
     * (active=false) leaves `following` untouched; whether it returns to true is decided later
     * by [decideAnchorTransition]'s Reclaim branch, once the list is settled, based on whether
     * it's actually at the bottom.
     */
    fun updateStreamingMode(active: Boolean) {
        streamingMode = active
        if (active) following = false
    }

    /**
     * Reports this frame's measured height for the pinned assistant cell, maintaining the
     * monotonic floor (never decreases). Called from the item's onSizeChanged.
     *
     * Passed through [coerceHeightConstraintPx] first: the floor gets fed back into layout as
     * `heightIn(min = ...)`, and a height outside what Compose's Constraints can represent would
     * make every subsequent measure pass throw `IllegalArgumentException` (observed in practice
     * as "Can't represent a width of 0 and height of 262146").
     */
    fun reportPinnedAssistantHeight(heightPx: Int) {
        val safeHeightPx = coerceHeightConstraintPx(heightPx)
        if (safeHeightPx > pinnedAssistantFloorPx) pinnedAssistantFloorPx = safeHeightPx
    }

    /**
     * Frame-by-frame follow while the keyboard shows/hides: each time the IME inset height
     * changes by [deltaPx] (positive when it grows, negative when it shrinks), the list content
     * scrolls by the same amount, canceling out how
     * [androidx.compose.foundation.layout.imePadding] resizes the viewport, so the latest
     * message tracks the keyboard smoothly instead of jumping once the animation ends.
     * Arbitration lives in [shouldFollowImeInset]: only applies while already following /
     * already at the bottom before the IME opened, and not while streaming, pinning, or with a
     * finger down. **The only place that calls `scrollBy` for IME following.**
     */
    /** Whether to follow this frame's IME delta (a pure decision over the controller's own state; testable without depending on Compose). */
    fun canFollowImeInset(
        deltaPx: Int,
        wasAtLatestBeforeIme: Boolean,
        isPointerDown: Boolean,
    ): Boolean = shouldFollowImeInset(
        imeDeltaPx = deltaPx,
        followingLatest = following,
        wasAtLatestBeforeIme = wasAtLatestBeforeIme,
        streaming = streamingMode,
        isPinning = isPinning,
        isPointerDown = isPointerDown,
    )

    suspend fun followImeInset(
        listState: LazyListState,
        deltaPx: Int,
        wasAtLatestBeforeIme: Boolean,
        isPointerDown: Boolean,
    ) {
        if (!canFollowImeInset(deltaPx, wasAtLatestBeforeIme, isPointerDown)) return
        listState.scrollBy(deltaPx.toFloat())
    }

    /**
     * Applies one frame's decision from [decideAnchorTransition]. Returns whether the keyboard
     * should be dismissed (true only for [AnchorTransition.Detach]). Keeps the follow flag's
     * writes centralized here so callers never set [following] directly.
     */
    fun applyTransition(transition: AnchorTransition): Boolean = when (transition) {
        AnchorTransition.Detach -> {
            following = false
            true
        }
        AnchorTransition.Reclaim -> {
            following = true
            false
        }
        AnchorTransition.NoOp -> false
    }

    
    suspend fun pinToTop(
        listState: LazyListState,
        pinId: String,
        userIndex: Int,
        minAssistantVisiblePx: Int,
    ) {
        isPinning = true
        
        
        withFrameNanos { }
        val viewportH = (listState.layoutInfo.viewportEndOffset - listState.layoutInfo.viewportStartOffset)
            .coerceAtLeast(0)
        val userHeightPx = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.key == pinId }?.size ?: 0
        
        reservePx = computeReservePx(viewportH, userHeightPx, minAssistantVisiblePx)
        pinnedTurnUserId = pinId
        pinnedAssistantFloorPx = 0
        val pinScrollOffset = computeLongUserPinScrollOffsetPx(viewportH, userHeightPx, minAssistantVisiblePx)
        
        
        
        
        val viewportTop = listState.layoutInfo.viewportStartOffset
        
        
        
        
        
        var reserveReadyFrames = 0
        while (reserveReadyFrames < PIN_RESERVE_READY_MAX_FRAMES) {
            val assistant = listState.layoutInfo.visibleItemsInfo
                .firstOrNull { it.index == userIndex + 1 }
            
            
            if (assistant != null && assistant.size >= reservePx - PIN_RESERVE_READY_SLOP_PX) break
            if (assistant == null && reserveReadyFrames >= 1) break
            withFrameNanos { }
            reserveReadyFrames++
        }
        listState.animateScrollToItem(userIndex, pinScrollOffset + viewportTop)
        
        
        var reconcileFrames = 0
        while (reconcileFrames < PIN_RECONCILE_MAX_FRAMES) {
            val info = listState.layoutInfo
            val userItem = info.visibleItemsInfo.firstOrNull { it.key == pinId }
            if (userItem == null) {
                listState.scrollToItem(userIndex, pinScrollOffset)
            } else {
                val delta = userItem.offset - (info.viewportStartOffset + pinScrollOffset)
                if (delta <= PIN_RECONCILE_TOLERANCE_PX) break
                listState.scrollBy(delta.toFloat())
            }
            withFrameNanos { }
            reconcileFrames++
        }
        isPinning = false
    }

    
    suspend fun followToBottom(
        listState: LazyListState,
        overflow: Int,
        isPointerDown: Boolean,
    ) {
        
        if (streamingMode || !following || isPointerDown || isPinning) return
        if (overflow > 0) listState.scrollBy(overflow.toFloat())
    }

    
    suspend fun scrollToBottom(listState: LazyListState, messageCount: Int) {
        if (messageCount <= 0) return
        val lastIndex = (messageCount - 1).coerceAtLeast(0)
        listState.scrollToItem(lastIndex)
        
        alignLastMessageToBottom(listState, lastIndex)
        
        
        
        
        var stableFrames = 0
        repeat(30) {
            withFrameNanos { }
            val corrected = alignLastMessageToBottom(listState, lastIndex)
            if (corrected) {
                stableFrames = 0
            } else {
                stableFrames++
                if (stableFrames >= 3) return
            }
        }
    }

    
    private suspend fun alignLastMessageToBottom(listState: LazyListState, lastIndex: Int): Boolean {
        val info = listState.layoutInfo
        val lastMessage = info.visibleItemsInfo.firstOrNull { it.index == lastIndex }
        if (lastMessage == null) {
            listState.scrollToItem(lastIndex)
            return true
        }
        val delta = bottomAlignDelta(
            lastMessageBottom = lastMessage.offset + lastMessage.size,
            viewportEndOffset = info.viewportEndOffset,
            afterContentPadding = info.afterContentPadding,
        )
        if (delta > PIN_RECONCILE_TOLERANCE_PX || delta < -PIN_RECONCILE_TOLERANCE_PX) {
            listState.scroll { scrollBy(delta.toFloat()) }
            return true
        }
        return false
    }
}


@Composable
internal fun rememberChatScrollController(): ChatScrollController = remember { ChatScrollController() }
