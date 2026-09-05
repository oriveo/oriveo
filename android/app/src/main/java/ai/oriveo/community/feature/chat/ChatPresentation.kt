package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation

// =========================================================================
// Conversation load state machine
// =========================================================================

/**
 * How a conversation screen is currently loading. Rendering and composer availability are both
 * decided from this single value.
 *
 * A missing provider deliberately does not appear here: that is resolved inside [Content] from
 * `conversationState.issue` and surfaced by ConversationIssueBanner.
 */
internal enum class ChatLoadState {
    /** The local database read failed. */
    LocalFailure,

    /** The conversation is confirmed gone, so the screen returns to the conversation list. */
    Deleted,

    /** At least one message is on hand: the normal chat screen, composer enabled. */
    Content,

    /** Still reading from storage and not yet past the timeout: keep the skeleton, say nothing. */
    Bootstrapping,

    /** Timed out with still no body: error card with a retry action, composer disabled. */
    Stalled,

    /** Confirmed to have no history (new chat, or a draft): welcome screen, composer enabled. */
    Empty,
}

/** How long the skeleton may stay up before the screen is treated as [ChatLoadState.Stalled]. */
internal const val CHAT_LOAD_STALLED_TIMEOUT_MS: Long = 12_000L

/**
 * Priority chain, top to bottom, first match wins. The order is load bearing and must not change:
 *
 * 1. localLoadFailed                                 -> LocalFailure
 * 2. a conversation was requested and is confirmed gone -> Deleted
 * 3. messages are already on hand                    -> Content
 * 4. no conversation was requested (a brand new chat) -> Empty
 * 5. the conversation is a draft                     -> Empty
 * 6. the stored metadata shows no history at all     -> Empty
 * 7. the timeout elapsed                             -> Stalled
 * 8. otherwise                                       -> Bootstrapping
 *
 * Rule 4 exists because a brand new chat must never enter a loading state; without it, creating a
 * conversation would show a skeleton and then stall after the timeout.
 *
 * Rule 6 is deliberately conservative. `messageCount` and `previewText` are only ever used to veto
 * an empty verdict, never to prove that history exists. If either is non-empty the screen keeps
 * waiting: stalling for a few seconds is far better than rendering a conversation that does have
 * history as empty, because the user would then start typing into it and silently lose the
 * context, or delete it as junk.
 *
 * @param hasMissingInitialConversation the conversation was looked up and is definitely not there
 * @param elapsedSinceEnterMs milliseconds since the conversation id was requested
 */
internal fun resolveChatLoadState(
    requestedConversationId: String?,
    conversation: Conversation?,
    hasMissingInitialConversation: Boolean,
    elapsedSinceEnterMs: Long = 0L,
    localLoadFailed: Boolean = false,
): ChatLoadState {
    if (localLoadFailed) return ChatLoadState.LocalFailure
    if (requestedConversationId != null && hasMissingInitialConversation) return ChatLoadState.Deleted
    if (conversation?.messages?.isNotEmpty() == true) return ChatLoadState.Content

    if (requestedConversationId == null) return ChatLoadState.Empty

    if (conversation != null && (conversation.isDraft || conversation.draftText.isNotBlank())) {
        return ChatLoadState.Empty
    }

    if (conversation != null && !conversation.hasHistoryEvidence()) {
        return ChatLoadState.Empty
    }

    if (elapsedSinceEnterMs >= CHAT_LOAD_STALLED_TIMEOUT_MS) return ChatLoadState.Stalled

    return ChatLoadState.Bootstrapping
}

/**
 * Whether the stored metadata shows any sign that this conversation has messages.
 *
 * Only ever used as a veto: any non-empty signal forbids an empty verdict. Using it the other way
 * around, to prove history exists, would be wrong.
 */
private fun Conversation.hasHistoryEvidence(): Boolean =
    messageCount > 0 || messages.isNotEmpty() || previewText.isNotBlank()

/** Neither the skeleton nor a stalled screen may send a message. */
internal fun ChatLoadState.blocksSending(): Boolean =
    this == ChatLoadState.Bootstrapping ||
        this == ChatLoadState.Stalled ||
        this == ChatLoadState.LocalFailure

/**
 * Minimum accumulated upward scroll before the pinned anchor is released, in pixels.
 *
 * A smaller value detaches on any single pixel of movement, which finger jitter and frame-to-frame
 * fling noise trigger constantly. 16dp is 16px at mdpi and 24/32px at hdpi/xhdpi, which lines up
 * with what the platform pan gesture treats as deliberate movement.
 */
internal const val SCROLL_DETACH_THRESHOLD_PX: Int = 16

/**
 * Decides whether the list scrolled up, from the lexicographic change in
 * [androidx.compose.foundation.lazy.LazyListState.firstVisibleItemIndex] and
 * [androidx.compose.foundation.lazy.LazyListState.firstVisibleItemScrollOffset]. This is the input
 * that releases the pinned anchor when the user scrolls back through history.
 *
 * - the first visible index decreased: scrolled up
 * - the index is unchanged and the offset decreased by at least [SCROLL_DETACH_THRESHOLD_PX]: up
 * - anything else: not up, which importantly includes appending a new item at the bottom, since
 *   that leaves firstVisible untouched
 */
internal fun isScrolledUp(
    prevFirstVisibleIndex: Int,
    prevFirstVisibleOffset: Int,
    curFirstVisibleIndex: Int,
    curFirstVisibleOffset: Int,
    thresholdPx: Int = SCROLL_DETACH_THRESHOLD_PX,
): Boolean {
    if (curFirstVisibleIndex < prevFirstVisibleIndex) return true
    if (curFirstVisibleIndex > prevFirstVisibleIndex) return false
    return curFirstVisibleOffset <= prevFirstVisibleOffset - thresholdPx
}

// =========================================================================
// Pin to top plus stick-to-bottom follow: static reserve geometry
// =========================================================================

/**
 * Minimum height reserved for the assistant message of the pinned turn, in pixels.
 *
 * Computed once when the message is sent and attached as `heightIn(min)` to that turn's assistant
 * cell, which hands ownership of the cell height back to the content itself: the app only
 * guarantees a floor.
 *
 *     reserve = max(viewportHeightPx - userHeightPx, minAssistantVisiblePx)
 *
 * - Normal case: `userH + reserve = viewportH`, so the user message sits at the top of the viewport
 *   and the answer fills in below it. While the answer is shorter than the reserve the cell height
 *   does not change, so the content size does not change and the viewport stays still. This gets
 *   the same short-answer behaviour a dynamic spacer would, with no per-frame recomputation.
 * - Very long user message (userH >= viewportH): the reserve collapses to [minAssistantVisiblePx],
 *   and [computeLongUserPinScrollOffsetPx] scrolls up far enough to reveal the start of the answer.
 * - Once the answer outgrows the reserve the cell simply grows and stick-to-bottom follow keeps the
 *   bottom in view.
 */
internal fun computeReservePx(
    viewportHeightPx: Int,
    userHeightPx: Int,
    minAssistantVisiblePx: Int,
): Int = (viewportHeightPx - userHeightPx).coerceAtLeast(minAssistantVisiblePx)

/**
 * The static reserve belongs to the current pinned turn only. Once a newer message appears after
 * the previous assistant message, that message must drop the reserve; otherwise a failed or very
 * short answer keeps holding a screen of blank space open above the next user message.
 */
internal fun shouldApplyPinnedAssistantReserve(
    messages: List<ChatMessage>,
    index: Int,
    pinnedTurnUserId: String?,
): Boolean {
    if (pinnedTurnUserId == null) return false
    val message = messages.getOrNull(index) ?: return false
    if (message.role != ChatRole.Assistant) return false
    if (index != messages.lastIndex) return false
    return messages.getOrNull(index - 1)?.id == pinnedTurnUserId
}

/** How much of the assistant answer stays visible when the user message is too tall to pin. */
internal const val MIN_ASSISTANT_VISIBLE_HINT_DP: Int = 120

/**
 * Scroll offset used when pinning a very long user message, in pixels. This is the `scrollOffset`
 * argument to [androidx.compose.foundation.lazy.LazyListState.scrollToItem], which pushes the item
 * that many pixels above the top of the viewport.
 *
 * Normally the user message is pinned flush with the top and the offset is zero. When
 * `userHeightPx + minAssistantVisiblePx > viewportHeightPx`, doing that would leave the answer
 * entirely below the fold, so the message is pushed up by exactly enough to bring
 * [minAssistantVisiblePx] of the assistant answer into view.
 *
 * This only decides the initial resting position; the user then scrolls down normally to read the
 * rest of their own message.
 */
internal fun computeLongUserPinScrollOffsetPx(
    viewportHeightPx: Int,
    userHeightPx: Int,
    minAssistantVisiblePx: Int,
): Int = (userHeightPx + minAssistantVisiblePx - viewportHeightPx).coerceAtLeast(0)

/**
 * Correction that aligns the bottom of the last message with the true bottom of the list, which is
 * `viewportEndOffset - afterContentPadding`.
 *
 * androidx computes `viewportEndOffset = maxOffset + afterContentPadding`, so it includes the
 * bottom content padding and that has to be subtracted. A positive result means scroll further
 * down, a negative one means the list overshot and has to come back by the same amount.
 */
internal fun bottomAlignDelta(
    lastMessageBottom: Int,
    viewportEndOffset: Int,
    afterContentPadding: Int,
): Int = lastMessageBottom - (viewportEndOffset - afterContentPadding)

/** Inputs to the detach/reclaim decision, packed into a value type that plays well with distinctUntilChanged. */
internal data class ChatScrollSignal(
    val scrolling: Boolean,
    val canScrollForward: Boolean,
    val firstVisibleIndex: Int,
    val firstVisibleOffset: Int,
)

/**
 * A single-frame decision about turning stick-to-bottom follow on or off.
 *
 * `anchored` means the list is on a pinned turn; `anchorDetached` means follow is currently off.
 * - [Detach]: the user scrolled up while following, so stop following and dismiss the keyboard
 * - [Reclaim]: the list came to rest at the bottom while not following, so resume following
 * - [NoOp]: not on a pinned turn, not scrolling upward, or still moving
 */
internal sealed class AnchorTransition {
    object NoOp : AnchorTransition()
    object Detach : AnchorTransition()
    object Reclaim : AnchorTransition()
}

/**
 * Decides, for one frame, whether to stop or resume following the bottom of the list.
 *
 * Detaching deliberately does not require `anchored`. Any upward scroll while following stops
 * follow, pinned turn or not. Requiring a pinned turn is what made scrolling back through an
 * existing conversation impossible: follow was on with no pin, the upward scroll could never
 * interrupt it, and the first asynchronous relayout at the bottom yanked the list back down.
 *
 * Detaching also does not require the finger to be down. A scroll plus an upward direction already
 * expresses "the user is reading back", and a fling that continues after the finger lifts has to be
 * able to stop follow too. [isScrolledUp] already excludes programmatic follow scrolls, the
 * jump-to-latest button and newly appended bottom items, so none of those detach by accident.
 *
 * Reclaiming does still require `anchored`. Only a pinned turn resumes following on its own once
 * the list is at rest, at the bottom, with no finger down. In an older conversation the user gets
 * the explicit jump-to-latest button instead, so follow never resumes behind their back.
 */
internal fun decideAnchorTransition(
    anchored: Boolean,
    anchorDetached: Boolean,
    isPointerDown: Boolean,
    signal: ChatScrollSignal,
    scrolledUp: Boolean,
): AnchorTransition {
    if (!anchorDetached && signal.scrolling && scrolledUp) return AnchorTransition.Detach
    if (anchored && anchorDetached && !signal.scrolling && !isPointerDown && !signal.canScrollForward) {
        return AnchorTransition.Reclaim
    }
    return AnchorTransition.NoOp
}

/**
 * Whether list content should track the keyboard height frame by frame while the IME animates.
 *
 * [imeDeltaPx] is this frame's change in bottom inset, positive as the keyboard opens and negative
 * as it closes. Scrolling by exactly that amount cancels out what `imePadding()` does to the
 * viewport, so the latest message rides up with the keyboard instead of being covered and then
 * jumping into place when the animation ends.
 *
 * Only track when the user is still following the latest message, or was at the latest message
 * before the keyboard appeared, so someone reading history is never dragged to the bottom. A finger
 * on the list, an in-flight pin animation, and streaming all take precedence.
 */
internal fun shouldFollowImeInset(
    imeDeltaPx: Int,
    followingLatest: Boolean,
    wasAtLatestBeforeIme: Boolean,
    streaming: Boolean,
    isPinning: Boolean,
    isPointerDown: Boolean,
): Boolean {
    if (imeDeltaPx == 0 || streaming || isPinning || isPointerDown) return false
    return followingLatest || wasAtLatestBeforeIme
}

/**
 * Finds the user message to pin: the User message immediately preceding the streaming assistant
 * message.
 *
 * Send, retry and continue all generate their user message id inside
 * [ai.oriveo.community.core.data.repository.ChatRepository], where the call site cannot see it, so
 * the id is looked up from the persisted list when streaming starts rather than passed in. Null
 * means nothing was found, and no anchor is applied.
 */
internal fun resolvePinnedUserMessageId(
    messages: List<ChatMessage>,
    streamingAssistantId: String,
): String? {
    val assistantIndex = messages.indexOfFirst { it.id == streamingAssistantId }
    if (assistantIndex < 0) return null
    for (i in assistantIndex - 1 downTo 0) {
        if (messages[i].role == ChatRole.User) return messages[i].id
    }
    return null
}

// =========================================================================
// Streaming finalize race: what text a cell renders
// =========================================================================

/**
 * Holds the last frame of streamed text for one assistant message, with the lifetime of a
 * `remember(message.id)`.
 *
 * A plain var rather than snapshot state: it is only read during the finalize race frame, and
 * writing it does not need to trigger recomposition on its own because the cell already recomposes
 * on the streaming text flow, the streaming message id and the message state.
 */
internal class StreamingCellHold {
    var text: String? = null
    var reasoning: String? = null
}

/**
 * Picks the text a streaming cell renders, covering the race at the end of a stream.
 *
 * Two asynchronous paths finish in no guaranteed order:
 * - session cleanup in the streaming manager clears the streaming message id and text, straight
 *   through a StateFlow to the main thread, which is fast;
 * - the message row reaching Delivered goes through a database invalidation, a requery, and two
 *   context switches in the window loader before it reaches the UI, which is slow.
 *
 * In the window where cleanup wins, the message in the persisted list is still Generating and the
 * streamed text has already been cut off. Falling straight back to the stored row would render
 * empty text, because partial text below the checkpoint threshold is never written; the markdown
 * view would unmount into a typing indicator and remount when Delivered arrives, which reads as the
 * whole answer flickering the instant it finishes. Holding the last streamed frame across that
 * window avoids it, and the hold is released as soon as the state leaves Generating. With no race
 * this is exactly [live], so behaviour is unchanged.
 *
 * @param live this frame's value from the streaming text flow, null once the cell is no longer the
 *        streaming message
 * @param held the last non-empty streamed text for this message, from [StreamingCellHold]
 * @param isPersistedGenerating whether the persisted row still says Generating
 */
internal fun resolveStreamingCellText(
    live: String?,
    held: String?,
    isPersistedGenerating: Boolean,
): String? = when {
    !live.isNullOrEmpty() -> live
    isPersistedGenerating && !held.isNullOrEmpty() -> held
    else -> live
}

// Rate limit detection lives at the top level so tests reach the production implementation. It was
// previously private, and each test carried its own copy, which meant the tests stayed green even
// with the production version deleted.

private val rateLimitPattern = Regex(
    "(rate.?limit|too many requests|429|quota exceeded)",
    RegexOption.IGNORE_CASE,
)

/** Whether a failed message is a rate limit error, which decides if "switch model" is offered. */
internal fun isRateLimitError(message: ChatMessage): Boolean {
    if (message.state != ChatMessageState.Failed) return false
    val combined = "${message.errorTitle.orEmpty()} ${message.errorDetail.orEmpty()}"
    return rateLimitPattern.containsMatchIn(combined)
}
