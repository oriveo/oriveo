package ai.oriveo.community.feature.chat

import android.content.Context
import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.context.MemoryItem
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.NoteRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Note
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.core.streaming.ChatStreamingManager
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf

/**
 * A real ChatViewModel on a draft chat page (no conversationId), for the realtime voice Chat target cases: the
 * repositories are fakes -- create builds [createdId] and records it in [created], and the note id persisted by
 * pinNoteToConversation is recorded in [pinned] and read back with the conversation.
 * Callers run Dispatchers.setMain first, then [create], and advance the scheduler so the connection / model resolve.
 */
internal class DraftChatViewModelFixture(
    private val provider: Provider,
    private val applicationScope: CoroutineScope,
    private val notes: List<Note> = emptyList(),
    private val skills: List<Skill> = emptyList(),
    private val memoryItems: List<MemoryItem> = emptyList(),
    private val createdId: String = "chat-new",
) {
    val created = mutableListOf<String>()
    val pinned = mutableListOf<String>()

    fun create(): ChatViewModel {
        val appPreferences = mockk<AppPreferencesRepository>(relaxed = true)
        every { appPreferences.lastUsedModelRef } returns flowOf(null)
        every { appPreferences.lastUsedModelRefSnapshot } returns null
        every { appPreferences.memoryText } returns MutableStateFlow("")
        every { appPreferences.memoryAntiForgetEnabled } returns MutableStateFlow(false)
        every { appPreferences.memoryAntiForgetText } returns MutableStateFlow("")
        coEvery { appPreferences.hasAcceptedProviderDisclosure(any()) } returns true
        val providers = mockk<ProviderRepository>()
        every { providers.observeAll() } returns flowOf(listOf(provider))
        coEvery { providers.getById(provider.id) } returns provider
        every { providers.currentCapabilityPartitionId() } returns "test-partition"
        coEvery { providers.capabilityEvidenceIdentity(any(), any(), "test-partition") } returns null
        every { providers.toolCallMemoryVerdict(any(), any()) } returns null
        val conversations = mockk<ConversationRepository>()
        conversations.stubMessageWindowLoaderDefaults(MessageWindowFakeStore())
        coEvery { conversations.getWithMessages(any()) } returns null
        coEvery { conversations.updateProviderAndModel(any(), any(), any(), any(), any()) } returns Unit
        coEvery { conversations.updateDraft(any(), any()) } returns Unit
        coEvery { conversations.create(any(), any(), any(), any(), any(), any(), any(), any()) } answers {
            created += createdId
            Conversation(
                id = createdId,
                title = "",
                providerID = firstArg(),
                providerKind = secondArg(),
                modelID = thirdArg(),
            )
        }
        coEvery { conversations.pinNoteToConversation(any(), any()) } answers {
            pinned += secondArg<String>()
            pinned.toList()
        }
        val noteRepository = mockk<NoteRepository>(relaxed = true)
        every { noteRepository.observeActive() } returns flowOf(notes)
        coEvery { noteRepository.getActiveNotesByIds(any()) } answers { notes.filter { it.id in firstArg<List<String>>() } }
        val skillRepository = mockk<SkillRepository>(relaxed = true)
        coEvery { skillRepository.getById(any()) } answers { skills.firstOrNull { it.id == firstArg<String>() } }
        val streaming = mockk<ChatStreamingManager>(relaxed = true)
        every { streaming.streamingText(any()) } returns MutableStateFlow("")
        every { streaming.streamingMessageId(any()) } returns MutableStateFlow(null)
        return ChatViewModel(
            savedStateHandle = SavedStateHandle(),
            context = mockk<Context>(relaxed = true),
            appPreferencesRepository = appPreferences,
            providerRepository = providers,
            conversationRepository = conversations,
            noteRepository = noteRepository,
            chatStreamingManager = streaming,
            skillRepository = skillRepository,
            attachmentProcessor = mockk(relaxed = true),
            globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true),
            applicationScope = applicationScope,
            memoryItemsSource = flowOf(memoryItems),
        )
    }

    companion object {
        /** The fixture connection must be able to create a conversation: credentialed, connected, with default model [modelId]. */
        fun sendable(provider: Provider, modelId: String): Provider = provider.copy(
            status = ai.oriveo.community.core.model.ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = modelId,
                    name = modelId,
                    isDefault = true,
                    capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.Text),
                ),
            ),
        )
    }
}
