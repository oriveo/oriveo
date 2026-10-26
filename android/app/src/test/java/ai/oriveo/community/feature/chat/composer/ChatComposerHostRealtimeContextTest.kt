package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.feature.chat.realtimeVoiceTarget
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.context.MemoryKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.feature.chat.DraftChatViewModelFixture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The Chat target of the chat page ≋ is produced by [ai.oriveo.community.feature.chat.ChatViewModel.realtimeVoiceTarget]
 * (the host only calls it): its context is wired to realtimeSessionContext rather than manualCompactionContext, and the
 * draft's createConversation goes through the real first-send conversation path
 * onConversationActivated -> flushPendingPinnedNotes.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatComposerHostRealtimeContextTest {

    private val dispatcher = StandardTestDispatcher()
    private val applicationScope = CoroutineScope(dispatcher + SupervisorJob())
    private val provider = DraftChatViewModelFixture.sendable(
        Provider(id = "conn-openai", kind = ProviderKind.OpenAI, apiKey = "sk-test", customName = "Work OpenAI"),
        modelId = "gpt-5",
    )
    private val skill = Skill(id = "skill-1", name = "Librarian", systemPrompt = "SKILL-PROMPT-librarian")
    private val memory = MemoryItem(
        id = "memory-1",
        kind = MemoryKind.FACT,
        content = "MEMORY-likes-tea",
        mutationId = "mutation-1",
        deviceId = "device-1",
    )
    private val note = Note(
        id = "22222222-2222-2222-2222-222222222222",
        title = "Draft",
        body = "PINNED-NOTE-pending",
        createdAt = "2026-06-01T00:00:00Z",
        updatedAt = "2026-06-01T00:00:00Z",
    )

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun chat_target_context_uses_realtime_session_context() = runTest(dispatcher) {
        val fixture = DraftChatViewModelFixture(
            provider = provider,
            applicationScope = applicationScope,
            skills = listOf(skill),
            memoryItems = listOf(memory),
        )
        val viewModel = fixture.create()
        advanceUntilIdle()
        val conversation = Conversation(
            id = "c1",
            title = "t",
            providerID = provider.id,
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-5",
            skillId = skill.id,
            messages = listOf(
                ChatMessage(
                    id = "m1",
                    role = ChatRole.User,
                    text = "what does the manual say",
                    providerKind = ProviderKind.OpenAI,
                    providerName = "Work OpenAI",
                    modelName = "gpt-5",
                    state = ChatMessageState.Delivered,
                ),
            ),
        )

        val target = viewModel.realtimeVoiceTarget("c1")
        assertEquals("c1", target.conversationId)
        val request = target.context(conversation)

        assertEquals(viewModel.sendCoordinator.realtimeSessionContext(conversation, listOf(memory)), request)
        assertEquals("SKILL-PROMPT-librarian", request.conversation.skillPrompt)
        assertEquals(listOf("MEMORY-likes-tea"), request.memoryItems.map { it.content })
    }

    @Test
    fun chat_draft_target_creates_through_conversation_activation() = runTest(dispatcher) {
        val fixture = DraftChatViewModelFixture(provider = provider, applicationScope = applicationScope, notes = listOf(note))
        val viewModel = fixture.create()
        advanceUntilIdle()
        viewModel.noteCoordinator.attachNoteToContext(note)
        assertEquals(listOf(note.id), viewModel.noteCoordinator.pendingPinnedNoteIds)

        val target = viewModel.realtimeVoiceTarget(null)
        assertEquals(null, target.conversationId)
        // Draft opening plan: the conversation the first send would create (not persisted).
        val planned = target.newConversation!!.invoke()
        assertEquals("", planned?.id)
        assertEquals("gpt-5", planned?.modelID)
        assertTrue(fixture.created.isEmpty())

        val id = target.createConversation!!.invoke()
        advanceUntilIdle()

        // Real onConversationActivated: activates the conversation and persists the notes pinned while composing.
        assertEquals("chat-new", id)
        assertEquals(listOf("chat-new"), fixture.created)
        assertEquals(listOf(note.id), fixture.pinned)
        // The conversation is already active: asking again returns the same id without creating another.
        assertEquals("chat-new", target.createConversation!!.invoke())
        assertEquals(listOf("chat-new"), fixture.created)
    }

    /** Host wiring lock: the Chat target of ChatComposerHost must come from realtimeVoiceTarget, never be assembled by hand or fall back to manualCompactionContext. */
    @Test
    fun chat_composer_host_uses_view_model_realtime_target() {
        val host = java.io.File("src/main/java/ai/oriveo/community/feature/chat/composer/ChatComposerHost.kt").readText()
        assertTrue(host.contains("target = viewModel.realtimeVoiceTarget(conversationId)"))
        assertFalse(host.contains("VoiceConversationTarget.Chat("))
        assertFalse(host.contains("manualCompactionContext"))
    }
}
