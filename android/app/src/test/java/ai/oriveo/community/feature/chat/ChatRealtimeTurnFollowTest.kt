package ai.oriveo.community.feature.chat

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalDensity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Realtime voice sessions (including new sessions started from the home page) land one bubble per turn; the list follows the latest turn, and stops fighting the user's scroll once they scroll up away from the bottom.
 * List structure matches ChatMessagesList: persisted messages plus one temporary realtime bubble item at the end; follow, enter-session and stop-follow effects are attached unchanged.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w390dp-h844dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ChatRealtimeTurnFollowTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val messages = mutableStateListOf<String>()
    private var realtimeActive by mutableStateOf(true)
    private var bottomPaddingDp by mutableStateOf(80)
    private lateinit var scope: CoroutineScope
    private lateinit var listState: LazyListState
    private lateinit var scrollController: ChatScrollController

    private fun launchHomeRealtimeConversation(
        initialTurns: Int,
        conversationId: String = "home-realtime",
        initialConversationId: String? = null,
        liveItemHeightDp: Int = 40,
    ) {
        repeat(initialTurns) { messages += "turn-$it" }
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            val state = rememberLazyListState()
            val controller = rememberChatScrollController()
            listState = state
            scrollController = controller
            scope = rememberCoroutineScope()
            var isPointerDown by remember { mutableStateOf(false) }
            Box(Modifier.height(400.dp)) {
                LazyColumn(
                    state = state,
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag("list")
                        .pointerInput(Unit) {
                            val tracker = PointerPressTracker()
                            awaitPointerEventScope {
                                while (true) {
                                    val event = awaitPointerEvent(PointerEventPass.Initial)
                                    tracker.consume(event.changes.any { it.pressed })?.let { isPointerDown = it }
                                }
                            }
                        },
                    contentPadding = PaddingValues(bottom = bottomPaddingDp.dp),
                ) {
                    itemsIndexed(messages, key = { _, it -> it }) { index, text ->
                        // Same as ChatMessagesList: the last assistant of the pinned-top turn gets a static reserve (heightIn min)
                        val pinned = index == messages.lastIndex && index > 0 &&
                            messages[index - 1] == controller.pinnedTurnUserId && controller.reservePx > 0
                        val reserveDp = with(LocalDensity.current) { controller.reservePx.toDp() }
                        Text(
                            text,
                            if (pinned) {
                                Modifier.fillMaxWidth().heightIn(min = maxOf(120.dp, reserveDp))
                            } else {
                                Modifier.fillMaxWidth().height(120.dp)
                            },
                        )
                    }
                    if (realtimeActive) {
                        item(key = "realtime_live_bubbles") { Box(Modifier.fillMaxWidth().height(liveItemHeightDp.dp)) }
                    }
                }
            }
            ChatFollowToBottomEffect(
                listState = state,
                scrollController = controller,
                isPointerDown = isPointerDown,
                realtimeActive = realtimeActive,
            )
            ChatStreamingModeEffect(isGenerating = false, scrollController = controller)
            // Home-page realtime new session: the session id is created by the home page and is not the initialConversationId passed by the route.
            ChatInitialScrollToBottomEffect(
                conversationId = conversationId,
                initialConversationId = initialConversationId,
                latestMessageCount = messages.size,
                composerOverlayHeightPx = 200,
                listState = state,
                scrollController = controller,
                realtimeActive = realtimeActive,
                onInitialBottomSettledConversationChange = {},
            )
            ChatAnchorTransitionEffect(
                listState = state,
                scrollController = controller,
                isPointerDown = isPointerDown,
                hideKeyboard = {},
            )
        }
        composeRule.waitForIdle()
    }

    private fun landTurn() {
        composeRule.runOnIdle { messages += "turn-${messages.size}" }
        composeRule.waitForIdle()
    }

    private fun lastItemVisible(): Boolean {
        val info = listState.layoutInfo
        return info.visibleItemsInfo.lastOrNull()?.index == info.totalItemsCount - 1
    }

    @Test
    fun realtime_turn_landing_follows_to_latest() {
        launchHomeRealtimeConversation(initialTurns = 1)

        repeat(6) { round ->
            landTurn()
            assertTrue("round $round: latest turn must be visible", lastItemVisible())
            assertFalse("round $round: list must sit at the bottom", listState.canScrollForward)
        }
        assertTrue(scrollController.following)
    }

    @Test
    fun realtime_turn_landing_respects_user_scroll_up() {
        launchHomeRealtimeConversation(initialTurns = 1)
        repeat(5) { landTurn() }
        assertFalse("precondition: following to the bottom", listState.canScrollForward)

        composeRule.onNodeWithTag("list").performTouchInput { swipeDown() }
        composeRule.waitForIdle()
        assertFalse(scrollController.following)
        val firstIndex = listState.firstVisibleItemIndex
        val firstOffset = listState.firstVisibleItemScrollOffset

        repeat(2) { landTurn() }

        assertEquals(firstIndex, listState.firstVisibleItemIndex)
        assertEquals(firstOffset, listState.firstVisibleItemScrollOffset)
        assertTrue(listState.canScrollForward)
        assertFalse(lastItemVisible())
    }

    // Regression: type one turn in a new session (question pinned to top, last assistant gets a reserve computed from the typing input area); after switching to a realtime model the input area becomes
    // the taller voice panel, and the session kickoff overshoots: follow had scrolled to the end of content (the bottom reserve padding), so the whole history scrolled out of the viewport; ending the session also could not recover.
    @Test
    fun realtime_session_after_pinned_text_turn_keeps_history_visible() {
        realtimeActive = false
        bottomPaddingDp = 40
        launchHomeRealtimeConversation(initialTurns = 2, conversationId = "typed-then-live", initialConversationId = null)
        composeRule.runOnIdle {
            scope.launch {
                scrollController.pinToTop(listState, pinId = "turn-0", userIndex = 0, minAssistantVisiblePx = 0)
            }
        }
        composeRule.waitForIdle()
        assertTrue("precondition: pinned turn reserve applied", scrollController.reservePx > 0)

        composeRule.runOnIdle { bottomPaddingDp = 300 } // Realtime model selected: voice panel replaces the input area
        composeRule.waitForIdle()
        assertHistoryVisible("precondition: dock shown before the session")

        composeRule.runOnIdle { realtimeActive = true } // Kickoff: append a zero-height temporary bubble item at the end of the list
        composeRule.waitForIdle()
        assertHistoryVisible("during the session")

        composeRule.waitForIdle() // End session: the temporary bubble item stays in the list
        assertHistoryVisible("after the session ends")

        landTurn() // Start another session and land one turn: the latest turn is visible
        assertTrue("latest turn must be visible", visibleMessageIndices().contains(messages.size - 1))
    }

    private fun visibleMessageIndices(): List<Int> {
        val info = listState.layoutInfo
        val end = info.viewportEndOffset - info.afterContentPadding
        // A message item's text lies within the top 120dp of the item: only count text whose area falls inside the visible band (excluding the bottom overlay)
        val textPx = (120 * composeRule.density.density).toInt()
        return info.visibleItemsInfo
            .filter { it.index < messages.size && it.offset < end && it.offset + textPx > 0 }
            .map { it.index }
    }

    private fun assertHistoryVisible(phase: String) {
        assertTrue("$phase: history must stay on screen, visible=${visibleMessageIndices()}", visibleMessageIndices().isNotEmpty())
    }
}
