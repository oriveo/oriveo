package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * State-machine invariants that keep the chat screen from showing a loading skeleton forever.
 *
 * The three that matter most: a message arriving dismisses the skeleton immediately, the skeleton
 * has a hard 12s ceiling, and every waiting state blocks the composer.
 */
class ChatLoadStateTest {

    private val convId = "11111111-1111-1111-1111-111111111111"

    private fun conversation(
        messages: List<ChatMessage> = emptyList(),
        isDraft: Boolean = false,
        draftText: String = "",
        previewText: String = "",
        messageCount: Int = 0,
    ) = Conversation(
        id = convId,
        title = "t",
        providerID = "p",
        providerKind = ProviderKind.OpenAI,
        modelID = "m",
        messages = messages,
        isDraft = isDraft,
        draftText = draftText,
        previewText = previewText,
        messageCount = messageCount,
    )

    private fun message() = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = "hi",
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "m",
        state = ChatMessageState.Delivered,
    )

    // -- priority chain --

    @Test
    fun `local failure outranks everything`() {
        assertEquals(
            ChatLoadState.LocalFailure,
            resolveChatLoadState(
                requestedConversationId = convId,
                conversation = conversation(messages = listOf(message())),
                hasMissingInitialConversation = true,
                elapsedSinceEnterMs = CHAT_LOAD_STALLED_TIMEOUT_MS,
                localLoadFailed = true,
            ),
        )
    }

    @Test
    fun `missing conversation outranks content`() {
        assertEquals(
            ChatLoadState.Deleted,
            resolveChatLoadState(
                requestedConversationId = convId,
                conversation = conversation(messages = listOf(message())),
                hasMissingInitialConversation = true,
            ),
        )
    }

    /** As soon as a local message shows up, the skeleton is dismissed, however long the wait was. */
    @Test
    fun `content wins over every loading state`() {
        assertEquals(
            ChatLoadState.Content,
            resolveChatLoadState(
                requestedConversationId = convId,
                conversation = conversation(messages = listOf(message())),
                hasMissingInitialConversation = false,
                elapsedSinceEnterMs = CHAT_LOAD_STALLED_TIMEOUT_MS * 10,
            ),
        )
    }

    @Test
    fun `brand new chat never enters a loading state`() {
        assertEquals(
            ChatLoadState.Empty,
            resolveChatLoadState(
                requestedConversationId = null,
                conversation = null,
                hasMissingInitialConversation = false,
                elapsedSinceEnterMs = CHAT_LOAD_STALLED_TIMEOUT_MS * 10,
            ),
        )
    }

    @Test
    fun `draft conversation is empty not stalled`() {
        assertEquals(
            ChatLoadState.Empty,
            resolveChatLoadState(
                requestedConversationId = convId,
                conversation = conversation(isDraft = true),
                hasMissingInitialConversation = false,
                elapsedSinceEnterMs = CHAT_LOAD_STALLED_TIMEOUT_MS * 10,
            ),
        )
    }

    /** The skeleton must have a 12s ceiling; no path may show it forever. */
    @Test
    fun `bootstrapping becomes stalled at the 12s ceiling`() {
        assertEquals(12_000L, CHAT_LOAD_STALLED_TIMEOUT_MS)

        assertEquals(
            ChatLoadState.Bootstrapping,
            resolveChatLoadState(
                requestedConversationId = convId,
                conversation = conversation(messageCount = 3),
                hasMissingInitialConversation = false,
                elapsedSinceEnterMs = CHAT_LOAD_STALLED_TIMEOUT_MS - 1,
            ),
        )
        assertEquals(
            ChatLoadState.Stalled,
            resolveChatLoadState(
                requestedConversationId = convId,
                conversation = conversation(messageCount = 3),
                hasMissingInitialConversation = false,
                elapsedSinceEnterMs = CHAT_LOAD_STALLED_TIMEOUT_MS,
            ),
        )
    }

    /**
     * An empty local read must not win when it collides with "metadata says there is history".
     *
     * `messageCount` and `previewText` are only ever allowed to veto an empty verdict. Landing on
     * Empty here would render a conversation that does have history as an empty one and let the
     * user start chatting right into it (silently dropping the context, and they would likely
     * delete it out of confusion). Better to keep waiting and then stall.
     */
    @Test
    fun `an empty local read does not win over metadata history evidence`() {
        assertEquals(
            ChatLoadState.Stalled,
            resolveChatLoadState(
                requestedConversationId = convId,
                conversation = conversation(messageCount = 12),
                hasMissingInitialConversation = false,
                elapsedSinceEnterMs = CHAT_LOAD_STALLED_TIMEOUT_MS,
            ),
        )
        assertEquals(
            ChatLoadState.Stalled,
            resolveChatLoadState(
                requestedConversationId = convId,
                conversation = conversation(previewText = "left off mid-conversation"),
                hasMissingInitialConversation = false,
                elapsedSinceEnterMs = CHAT_LOAD_STALLED_TIMEOUT_MS,
            ),
        )
    }

    // -- stalled / skeleton states block sending --

    @Test
    fun `stalled and skeleton states block sending`() {
        assertTrue(ChatLoadState.Stalled.blocksSending())
        assertTrue(ChatLoadState.Bootstrapping.blocksSending())
        assertTrue(ChatLoadState.LocalFailure.blocksSending())

        assertFalse(ChatLoadState.Content.blocksSending())
        assertFalse(ChatLoadState.Empty.blocksSending())
        assertFalse(ChatLoadState.Deleted.blocksSending())
    }

    // -- an empty non-draft conversation (a stalled-misjudgment regression) --

    /**
     * Regression: a non-draft empty conversation was being misjudged as stalled (skeleton ->
     * error card + composer permanently disabled, and retrying did not help).
     *
     * This kind of conversation is real: its last message was deleted, and nothing in the stored
     * metadata suggests otherwise. The correct behavior is the welcome page with a usable
     * composer; anything else is a clear regression.
     */
    @Test
    fun `an empty conversation without history evidence shows the welcome state`() {
        val state = resolveChatLoadState(
            requestedConversationId = convId,
            conversation = conversation(),
            hasMissingInitialConversation = false,
        )
        assertEquals(ChatLoadState.Empty, state)
        assertFalse(state.blocksSending())
    }

    /** With evidence of history, an empty read must never land on empty: it waits, then stalls. */
    @Test
    fun `history evidence keeps waiting and then stalls`() {
        assertEquals(
            ChatLoadState.Bootstrapping,
            resolveChatLoadState(
                requestedConversationId = convId,
                conversation = conversation(previewText = "left off mid-conversation"),
                hasMissingInitialConversation = false,
            ),
        )
        assertEquals(
            ChatLoadState.Stalled,
            resolveChatLoadState(
                requestedConversationId = convId,
                conversation = conversation(messageCount = 66),
                hasMissingInitialConversation = false,
                elapsedSinceEnterMs = CHAT_LOAD_STALLED_TIMEOUT_MS,
            ),
        )
    }
}
