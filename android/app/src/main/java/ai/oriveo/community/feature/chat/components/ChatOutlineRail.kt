package ai.oriveo.community.feature.chat.components

import android.content.Context
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.feature.chat.ChatScrollController
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Gap left between the jumped-to message and the top of the viewport, matching search-jump spacing. */
private val PIN_TOP_GAP = 16.dp
/** Fixed dark chip fill for the tooltip regardless of theme, so it never washes out on a light background. */
private val OUTLINE_TOOLTIP_FILL = Color(0xFF1F212B)
/** Delay before the rail collapses back to its idle state after interaction ends. */
private const val RAIL_COLLAPSE_DELAY_MS = 600L
/** Layout breakpoint: container width >= 600dp uses a bar shape, otherwise a dot. */
private const val BAR_BREAKPOINT_DP = 600

/**
 * Message navigation rail on the right edge of the chat (similar to the outline rail
 * seen in other chat products).
 *
 * - One tick per user turn; only shown once there are more than [OUTLINE_MIN_USER_TURNS].
 * - The currently visible turn is always highlighted in the primary color; hover/touch
 *   brightens the whole rail and shows a text preview tooltip for the pointed-at tick.
 * - Tapping a tick smoothly scrolls that message to the top (with a small gap) and
 *   fires a light haptic.
 * - The current-turn calculation runs through [derivedStateOf] so recomposition only
 *   happens when the result actually changes, not every frame; jumping sets
 *   following=false first so the follow effect doesn't fight the jump for scroll position.
 */
@Composable
internal fun BoxScope.ChatOutlineRail(
    messages: List<ChatMessage>,
    listState: LazyListState,
    hasMoreAbove: Boolean,
    hasMoreBelow: Boolean,
    scrollController: ChatScrollController,
    context: Context,
    coroutineScope: CoroutineScope,
) {
    val colors = OriveoTheme.colors
    val density = LocalDensity.current
    val hapticFeedback = LocalHapticFeedback.current
    val widthDp = LocalConfiguration.current.screenWidthDp
    val isBar = widthDp >= BAR_BREAKPOINT_DP

    val attachmentLabel = stringResource(R.string.outline_attachment_only)
    val navLabel = stringResource(R.string.outline_nav_label)

    val ticks = remember(messages, attachmentLabel) { deriveOutlineTicks(messages, attachmentLabel) }
    if (ticks.size <= OUTLINE_MIN_USER_TURNS) return
    // Read the latest message list from inside the jump coroutine (index lookups stay
    // valid even after a prepend shifts everything -- see the note on scrollToMessage).
    val latestMessages = rememberUpdatedState(messages)

    // Rail dimensions per layout mode.
    val railWidth = if (isBar) 28.dp else 44.dp
    val rightMargin = if (isBar) 8.dp else 6.dp
    val defaultRowH = if (isBar) 14.dp else 12.dp

    // Current visible turn: the lowest user message above the activation line at the top third of the viewport.
    val currentIndex by remember(ticks, listState, hasMoreAbove, hasMoreBelow) {
        derivedStateOf { computeCurrentUserIndex(listState, ticks, hasMoreAbove, hasMoreBelow) }
    }
    val currentId = ticks.getOrNull(currentIndex)?.id

    var active by remember { mutableStateOf(false) }
    var pointedIndex by remember { mutableIntStateOf(-1) }
    var interacting by remember { mutableStateOf(false) }
    // Freeze the visible tick window while interacting: scrubbing changes currentId,
    // which would otherwise slide the window under the finger and make ticks shift
    // out from underneath the touch. Freezing on press and unfreezing on release keeps
    // the window stable during the gesture and lets it resume following afterward.
    var frozenRange by remember { mutableStateOf<IntRange?>(null) }
    // Clear the freeze whenever the tick list itself is replaced wholesale (e.g. switching
    // conversations); normal pagination only appends ticks, so a frozen range stays valid after clamping.
    LaunchedEffect(ticks.size) { frozenRange = null }

    // Collapse back to idle 600ms after the finger lifts; re-touching restarts the effect and cancels the collapse.
    LaunchedEffect(interacting) {
        if (interacting) {
            active = true
            return@LaunchedEffect
        }
        if (!active) return@LaunchedEffect
        delay(RAIL_COLLAPSE_DELAY_MS)
        active = false
        pointedIndex = -1
        // Interaction is over: unfreeze the window so it resumes following the current turn.
        frozenRange = null
    }

    // Scrolls to and pins the target user message (with PIN_TOP_GAP of headroom). Uses an
    // immediate scrollToItem so scrubbing tracks the finger and taps feel snappy; the
    // LazyColumn can jump straight to an index without any self-sizing correction pass.
    // The index has to be re-resolved from latestMessages inside the coroutine: jumping
    // near the top can trigger a prepend that expands the window, and if that lands
    // between resolving the index in the gesture callback and running scrollToItem, the
    // inserted items at the top would shift the old index and land on the wrong message.
    // The pointerInput(ticks) gesture block's closure also doesn't refresh until ticks
    // changes, so the captured messages list could be several frames stale --
    // rememberUpdatedState guarantees the coroutine reads the current value.
    fun scrollToMessage(id: String) {
        if (latestMessages.value.none { it.id == id }) return
        scrollController.stopFollowingForJump()
        coroutineScope.launch {
            val index = latestMessages.value.indexOfFirst { it.id == id }
            if (index < 0) return@launch
            val gapPx = with(density) { PIN_TOP_GAP.roundToPx() }
            listState.scrollToItem(index, listState.layoutInfo.viewportStartOffset + gapPx)
        }
    }

    // Tap / accessibility jump: scroll plus a confirm haptic.
    fun jumpTo(id: String) {
        scrollToMessage(id)
        @Suppress("DEPRECATION")
        (context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator)
            ?.vibrate(VibrationEffect.createOneShot(20, VibrationEffect.DEFAULT_AMPLITUDE))
    }

    BoxWithConstraints(
        modifier = Modifier
            .align(Alignment.CenterEnd)
            .fillMaxHeight()
            .width(railWidth + rightMargin),
    ) {
        // 62% height cap: the rail is centered vertically, leaving roughly the bottom
        // 19% clear for the scroll-to-bottom button so a full-height rail can never
        // extend down into the button's tap area.
        val maxRailHpx = (constraints.maxHeight * 0.62f).toInt()
        val defaultRowHpx = with(density) { defaultRowH.roundToPx() }
        // Row height is fixed rather than proportionally compressed -- compressing to fit
        // still overflowed and felt too cramped with hundreds of turns, so capacity
        // overflow is handled instead by the sliding window below (tail-aligned paging).
        val rowHpx = defaultRowHpx
        val rowH = with(density) { rowHpx.toDp() }
        val capacity = if (rowHpx > 0) maxRailHpx / rowHpx else ticks.size
        // Sliding window: once tick count exceeds capacity, center the window on the
        // current turn and let it slide as the user scrolls/pages; during interaction the
        // window is frozen (see frozenRange above). Clamp guards against the frozen range
        // going out of bounds if ticks shrink mid-interaction (e.g. switching conversations).
        val range = (frozenRange ?: outlineVisibleRange(ticks.size, currentIndex, capacity))
            .let { r ->
                if (r.isEmpty()) r
                else r.first.coerceAtMost(ticks.size - 1) until (r.last + 1).coerceAtMost(ticks.size)
            }
        val windowTicks = if (range.isEmpty()) emptyList() else ticks.subList(range.first, range.last + 1)
        val topFaded = range.first > 0
        val bottomFaded = !range.isEmpty() && range.last + 1 < ticks.size

        Column(
            modifier = Modifier
                .align(Alignment.Center)
                .width(railWidth)
                .padding(end = rightMargin)
                .semantics { contentDescription = navLabel }
                // Keyed on windowTicks: while interacting the window is frozen so the
                // gesture never restarts; outside interaction, a sliding window restarts
                // the gesture safely since there's no active pointer or side effect yet.
                .pointerInput(windowTicks, rowHpx) {
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        interacting = true
                        // Freeze the window as soon as the finger goes down, so ticks
                        // don't shift under the touch point for the rest of the gesture.
                        if (frozenRange == null) frozenRange = range
                        var idx = (down.position.y / rowHpx).toInt().coerceIn(0, windowTicks.lastIndex)
                        pointedIndex = idx
                        var moved = false
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull() ?: break
                            if (!change.pressed) break
                            val pos = change.position
                            if ((pos - down.position).getDistance() > viewConfiguration.touchSlop) {
                                moved = true
                            }
                            val newIdx = (pos.y / rowHpx).toInt().coerceIn(0, windowTicks.lastIndex)
                            if (newIdx != idx) {
                                idx = newIdx
                                pointedIndex = idx
                                // Scrubbing: the list follows the finger in real time (only
                                // scrolling when the tick actually changes) plus a light tick haptic.
                                if (moved) {
                                    hapticFeedback.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                    scrollToMessage(windowTicks[idx].id)
                                }
                            }
                            // Consume the event so dragging on the rail doesn't propagate to the LazyColumn.
                            change.consume()
                        }
                        // Tap jumps with a confirm haptic; a drag has already followed in
                        // real time, so releasing just settles on the final tick.
                        if (moved) scrollToMessage(windowTicks[idx].id) else jumpTo(windowTicks[idx].id)
                        interacting = false
                    }
                },
        ) {
            windowTicks.forEachIndexed { index, tick ->
                // Highlight is determined by id, since the window's local index isn't comparable across windows.
                val isCurrent = tick.id == currentId
                val isPointed = active && index == pointedIndex

                val targetW: androidx.compose.ui.unit.Dp
                val targetH: androidx.compose.ui.unit.Dp
                val targetColor = when {
                    isCurrent || isPointed -> colors.primary
                    active -> colors.textSecondary
                    else -> colors.textTertiary.opacity(0.55f)
                }
                if (isBar) {
                    targetW = when {
                        isCurrent || isPointed -> 22.dp
                        active -> 18.dp
                        else -> 16.dp
                    }
                    targetH = if (isCurrent || isPointed) 2.5.dp else 2.dp
                } else {
                    val d = when {
                        isCurrent || isPointed -> 7.dp
                        active -> 6.dp
                        else -> 5.dp
                    }
                    targetW = d
                    targetH = d
                }
                val tickW by animateDpAsState(targetW, label = "outlineTickW")
                val tickH by animateDpAsState(targetH, label = "outlineTickH")
                val tickColor by animateColorAsState(targetColor, label = "outlineTickColor")
                // Fade the ticks at the window's edges (two alpha steps, hinting there's more beyond); current/pointed ticks are exempt.
                val fade = tickFadeAlpha(
                    index = index,
                    count = windowTicks.size,
                    topFaded = topFaded,
                    bottomFaded = bottomFaded,
                    exempt = isCurrent || isPointed,
                )

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(rowH)
                        .alpha(fade)
                        .semantics {
                            contentDescription = context.getString(R.string.outline_jump_to, tick.preview)
                            role = Role.Button
                            selected = isCurrent
                            onClick { jumpTo(tick.id); true }
                        },
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    Box(
                        modifier = Modifier
                            .size(width = tickW, height = tickH)
                            .clip(RoundedCornerShape(percent = 50))
                            .background(tickColor),
                    )

                    if (isPointed) {
                        val maxChars = previewCharLimit(widthDp)
                        val tooltipText = clampPreview(tick.preview, maxChars)
                        val gapPx = with(density) { 6.dp.roundToPx() }
                        // Rendered in a separate Popup window so it fully escapes the parent's
                        // width(railWidth) constraint tree -- otherwise the text can't measure
                        // its width and renders as an empty box. clippingEnabled=false keeps it
                        // from being clipped by the screen edge.
                        Popup(
                            popupPositionProvider = remember(gapPx) {
                                object : PopupPositionProvider {
                                    override fun calculatePosition(
                                        anchorBounds: IntRect,
                                        windowSize: IntSize,
                                        layoutDirection: LayoutDirection,
                                        popupContentSize: IntSize,
                                    ): IntOffset {
                                        // Anchored to the outside of the tick (LTR: rail on the
                                        // right so the tooltip goes left; RTL: mirrored), vertically
                                        // centered, and clamped to stay within the window bounds.
                                        val x = if (layoutDirection == LayoutDirection.Rtl) {
                                            anchorBounds.right + gapPx
                                        } else {
                                            anchorBounds.left - popupContentSize.width - gapPx
                                        }
                                        val y = anchorBounds.top + anchorBounds.height / 2 - popupContentSize.height / 2
                                        return IntOffset(
                                            x.coerceIn(0, (windowSize.width - popupContentSize.width).coerceAtLeast(0)),
                                            y.coerceIn(0, (windowSize.height - popupContentSize.height).coerceAtLeast(0)),
                                        )
                                    }
                                }
                            },
                            properties = PopupProperties(focusable = false, clippingEnabled = false),
                        ) {
                            Box(
                                modifier = Modifier
                                    .widthIn(min = 80.dp, max = tooltipMaxWidthDp(widthDp).dp)
                                    .shadow(10.dp, RoundedCornerShape(12.dp))
                                    .background(OUTLINE_TOOLTIP_FILL, RoundedCornerShape(12.dp))
                                    .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp))
                                    .padding(horizontal = 12.dp, vertical = 7.dp),
                            ) {
                                Text(
                                    text = tooltipText,
                                    color = Color.White,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Medium,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Determines the currently visible turn: the lowest user message above the activation
 * line at the top third of the viewport. Uses visibleItemsInfo to find the item index
 * at the activation line, then falls back to the user message at or before that index
 * (covering a user turn that has already scrolled above the viewport). Falls back to
 * the first user turn if none is found.
 */
private fun computeCurrentUserIndex(
    listState: LazyListState,
    ticks: List<OutlineTick>,
    hasMoreAbove: Boolean,
    hasMoreBelow: Boolean,
): Int {
    val info = listState.layoutInfo
    val visible = info.visibleItemsInfo
    // Return -1 when the state can't be determined yet (first frame not laid out, or
    // before the initial settle at the bottom) so the sliding window defaults to the
    // last page -- entering a conversation starts at the bottom, and falling back to the
    // first item instead would misplace the initial window at the head of the list.
    if (visible.isEmpty() || ticks.isEmpty()) return -1
    val vpTop = info.viewportStartOffset
    val activationY = vpTop + (info.viewportEndOffset - vpTop) * 0.33f
    var activationIndex = visible.first().index
    for (item in visible) {
        if (item.offset <= activationY) activationIndex = item.index else break
    }
    val focusIndex = outlineFocusIndex(ticks, activationIndex)
    return resolveOutlineActiveIndex(
        tickCount = ticks.size,
        focusIndex = focusIndex,
        atConversationStart = !hasMoreAbove && !listState.canScrollBackward,
        atConversationEnd = !hasMoreBelow && !listState.canScrollForward,
    )
}
