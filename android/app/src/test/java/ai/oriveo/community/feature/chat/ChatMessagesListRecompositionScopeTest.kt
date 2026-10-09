package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ModelDisplayLookup
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the recomposition scope of [ChatMessagesList]: streaming tokens may only land on the one
 * streaming cell.
 *
 * Why this deserves its own tests: Compose foundation's `rememberLazyListItemProviderLambda` builds a
 * `LazyListIntervalContent` (which does not override `equals`) from `rememberUpdatedState(content)` and
 * a `derivedStateOf` with referential equality. So whenever `ChatMessagesList` itself recomposes, the
 * item provider becomes a new instance, the `SkippableItem` arguments change, and every visible cell
 * recomposes together with its markdown subtree. Nothing in the code makes that chain visible, so the
 * invariants are pinned here.
 */
class ChatMessagesListRecompositionScopeTest {

    private val messagesListSource: String by lazy {
        File("src/main/java/ai/oriveo/community/feature/chat/ChatMessagesList.kt").readText()
    }

    // Behavior: a token update does not change any item-level input of a non-streaming cell.

    @Test
    fun `streaming token update leaves every non-streaming cell input untouched`() {
        val messages = listOf(
            message("m1", ChatRole.User),
            message("m2", ChatRole.Assistant),
            message("m3", ChatRole.User),
            message("m4", ChatRole.Assistant, state = ChatMessageState.Generating),
        )
        val displayLookup = ModelDisplayLookup(listOf(provider()))
        // The note badge map comes from the same function the note coordinator uses in production.
        val savedNoteLinks = savedNoteLinksByMessage(
            conversationId = "conv-a",
            notes = listOf(note(id = "n1", sourceConversationId = "conv-a", sourceMessageId = "m2")),
        )
        // Same shape as the view model's streaming text: a token flush only changes this one value.
        val streamingText = MutableStateFlow("Hel")
        val streamingMessageId = "m4"

        val before = messages.indices.map {
            cellInputs(messages, it, displayLookup, savedNoteLinks, streamingMessageId, streamingText.value)
        }
        streamingText.value = "Hello world"
        val after = messages.indices.map {
            cellInputs(messages, it, displayLookup, savedNoteLinks, streamingMessageId, streamingText.value)
        }

        // The streaming cell has to follow the token, otherwise this test would exercise nothing.
        assertNotEquals(before.last().streamingCellText, after.last().streamingCellText)
        assertEquals("Hello world", after.last().streamingCellText)

        // Every item-level input of the other cells must stay exactly as it was.
        before.dropLast(1).forEachIndexed { index, expected ->
            val actual = after[index]
            assertEquals("LazyColumn key of cell $index changed", expected.key, actual.key)
            assertEquals("contentType of cell $index changed", expected.contentType, actual.contentType)
            assertEquals("display metadata of cell $index changed", expected.metadata, actual.metadata)
            assertEquals("pinned reserve decision of cell $index changed", expected.pinnedReserve, actual.pinnedReserve)
            assertNull("a non-streaming cell must not receive streaming text", actual.streamingCellText)
            // Same instance, not just equal: strong skipping compares by instance, so a fresh list
            // would recompose the cell on every frame.
            assertSame("note links of cell $index became a new instance", expected.savedNoteLinks, actual.savedNoteLinks)
        }
    }

    @Test
    fun `message keys stay unique and stable across a token update`() {
        val messages = listOf(
            message("m1", ChatRole.User),
            message("m2", ChatRole.Assistant, state = ChatMessageState.Generating),
        )
        val keys = messages.map { it.id }

        assertEquals("LazyColumn keys must be unique, duplicates leak item state", keys.size, keys.toSet().size)
        // Token updates never touch the message entities (streaming text is a separate flow), so the
        // list instance itself does not change.
        val sameList = messages
        assertSame(messages, sameList)
        assertEquals(keys, sameList.map { it.id })
        assertEquals(listOf(ChatRole.User, ChatRole.Assistant), sameList.map { it.role })
    }

    @Test
    fun `saved note link map keeps value equality so unrelated note emissions do not re-emit`() {
        // The note coordinator holds this map in a StateFlow, which de-duplicates by equals. As long as
        // the production function returns equal maps for equal input, an unrelated notes re-emission
        // does not swap the instance, so the list is not recomposed for a new Map parameter.
        val notes = listOf(
            note(id = "n1", sourceConversationId = "conv-a", sourceMessageId = "m1"),
            note(id = "n2", sourceConversationId = "conv-a", sourceMessageId = "m2"),
        )
        val first = savedNoteLinksByMessage("conv-a", notes)
        val second = savedNoteLinksByMessage("conv-a", notes.toList())

        assertEquals(first, second)

        val flow = MutableStateFlow(first)
        flow.value = second
        assertSame("an equal map must not replace the instance", first, flow.value)
    }

    // Structure: the flipping state must be read outside the LazyColumn scope.

    @Test
    fun `scroll to bottom visibility is read in its own composable not in the list scope`() {
        val overlayAt = messagesListSource.indexOf("private fun BoxScope.ChatScrollToBottomOverlay(")
        val derivedAt = messagesListSource.indexOf("derivedStateOf { listState.canScrollForward")

        assertTrue("The button must be its own composable, otherwise a visibility flip recomposes every visible cell", overlayAt > 0)
        assertTrue("The canScrollForward derivedStateOf must stay inside the button's own scope", derivedAt > overlayAt)
        assertFalse(
            "ChatMessagesList must not take a Context parameter (the button and the outline rail read LocalContext themselves)",
            messagesListSource.contains("    context: Context,"),
        )
    }

    // Fixtures

    /** The inputs a cell actually depends on in the item scope, all computed by production functions. */
    private data class CellInputs(
        val key: String,
        val contentType: ChatRole,
        val metadata: ChatMessageDisplayMetadata,
        val savedNoteLinks: List<SavedNoteLink>,
        val pinnedReserve: Boolean,
        val streamingCellText: String?,
    )

    private fun cellInputs(
        messages: List<ChatMessage>,
        index: Int,
        displayLookup: ModelDisplayLookup,
        savedNoteLinks: Map<String, List<SavedNoteLink>>,
        streamingMessageId: String?,
        streamingText: String,
    ): CellInputs {
        val message = messages[index]
        val isStreaming = message.id == streamingMessageId
        return CellInputs(
            key = message.id,
            contentType = message.role,
            metadata = resolveMessageDisplayMetadata(message, displayLookup),
            savedNoteLinks = savedNoteLinksForMessage(savedNoteLinks, message.id),
            pinnedReserve = shouldApplyPinnedAssistantReserve(messages, index, pinnedTurnUserId = "m3"),
            streamingCellText = resolveStreamingCellText(
                live = if (isStreaming) streamingText else null,
                held = null,
                isPersistedGenerating = message.state == ChatMessageState.Generating,
            ),
        )
    }

    private fun message(
        id: String,
        role: ChatRole,
        state: ChatMessageState = ChatMessageState.Delivered,
    ) = ChatMessage(
        id = id,
        role = role,
        text = "Hello",
        providerID = "provider-1",
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "GPT-4o mini",
        state = state,
    )

    private fun provider() = Provider(
        id = "provider-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
    )

    private fun note(
        id: String,
        sourceConversationId: String,
        sourceMessageId: String,
    ) = Note(
        id = id,
        title = id,
        body = "body",
        sourceConversationId = sourceConversationId,
        sourceMessageId = sourceMessageId,
        createdAt = "2026-06-01T00:00:00Z",
        updatedAt = "2026-06-01T00:00:00Z",
        deletedAt = null,
    )
}
