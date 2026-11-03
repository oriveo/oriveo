package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTransport
import io.mockk.coEvery
import io.mockk.mockk
import io.mockk.slot
import io.mockk.verify
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A realtime voice session on the draft page creates the conversation through the same path as the first
 * [ChatSendCommandCoordinator.sendMessage] (pending instructions, draft migration, onConversationActivated), but sends nothing.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatSendCommandCoordinatorFirstConversationTest {
    private val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)
    private val parameterStore = mockk<GenerationParameterSettingsStore>(relaxed = true)

    private val model = AIModel(id = "gpt-4o-mini", name = "GPT-4o mini", isDefault = true, capabilities = listOf(ModelCapability.Text))
    private val provider = Provider(
        id = "openai-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        apiKey = "local-key",
        models = listOf(model),
    )

    private val instructionsSlot = slot<String>()
    private val modelSlot = slot<String>()
    private val activated = mutableListOf<String>()
    private val adopted = mutableListOf<String>()
    private var launches = 0

    private fun TestScope.coordinator(
        draftInstructions: String = "DRAFT-INSTRUCTIONS",
        voiceCatalog: VoiceCatalog? = null,
    ): ChatSendCommandCoordinator {
        coEvery { providerRepository.getById(provider.id) } returns provider
        coEvery {
            conversationRepository.create(
                providerID = any(),
                providerKind = any(),
                modelID = capture(modelSlot),
                title = any(),
                folderID = any(),
                skillId = any(),
                useMemory = any(),
                instructions = capture(instructionsSlot),
            )
        } answers {
            Conversation(
                id = "conversation-1",
                title = "New Chat",
                providerID = provider.id,
                providerKind = provider.kind,
                modelID = modelSlot.captured,
                instructions = instructionsSlot.captured,
            )
        }
        return ChatSendCommandCoordinator(
            viewModelScope = this,
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            currentConversation = { null },
            currentConversationId = { activated.lastOrNull() },
            pendingDraftInstructions = { draftInstructions },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = {},
            onDisclosureRequired = { _, _ -> },
            onConversationActivated = { activated += it },
            generationParameterSettingsStore = parameterStore,
            generationParameterDraftSessionId = { "draft-session" },
            adoptMcpDraft = { adopted += it },
            onComposerConsumed = {},
            requestPin = {},
            onSendSettled = {},
            launchSend = { _, _, _, _, _, _, _, _, _, _, _ -> launches++ },
            voiceCatalog = { voiceCatalog },
        )
    }

    @Test
    fun create_first_conversation_without_send() = runTest(timeout = 30.seconds) {
        val c = coordinator()
        val id = c.createFirstConversation(provider.id, model.id)
        assertEquals("conversation-1", id)
        assertEquals("DRAFT-INSTRUCTIONS", instructionsSlot.captured)
        assertEquals(listOf("conversation-1"), adopted)
        assertEquals(listOf("conversation-1"), activated)
        verify {
            parameterStore.migrateSession(
                providerID = provider.id,
                modelID = model.id,
                fromConversationID = "draft-session",
                toConversationID = "conversation-1",
                profileFingerprint = any(),
            )
        }
        assertEquals(0, launches)
        // A conversation already exists: no second one is created.
        assertEquals("conversation-1", c.createFirstConversation(provider.id, model.id))
        assertEquals(listOf("conversation-1"), adopted)
    }

    @Test
    fun planned_conversation_matches_created() = runTest(timeout = 30.seconds) {
        val c = coordinator()
        val planned = c.plannedFirstConversation(provider.id, model.id)!!
        assertTrue(activated.isEmpty())
        assertTrue(adopted.isEmpty())
        c.createFirstConversation(provider.id, model.id)
        assertEquals(provider.id, planned.providerID)
        assertEquals(provider.kind, planned.providerKind)
        assertEquals(modelSlot.captured, planned.modelID)
        assertEquals(instructionsSlot.captured, planned.instructions)
    }

    @Test
    fun planned_conversation_normalizes_draft_instructions() = runTest(timeout = 30.seconds) {
        val raw = "  \n\t  "
        val planned = coordinator(draftInstructions = raw).plannedFirstConversation(provider.id, model.id)!!
        assertEquals(ai.oriveo.community.core.context.ConversationInstructions.normalize(raw), planned.instructions)
    }

    @Test
    fun first_conversation_keeps_realtime_model() = runTest(timeout = 30.seconds) {
        val catalog = VoiceCatalog(
            schemaVersion = 2,
            providers = mapOf(
                ProviderKind.OpenAI to VoiceProviderCatalog(
                    realtime = listOf(
                        VoiceRealtimeEntry(
                            model = "gpt-realtime",
                            transport = VoiceTransport.OpenAIRealtime,
                            path = "/v1/realtime",
                            contextWindow = 32_000,
                            voices = listOf(VoiceOption("marin", isDefault = true)),
                            inputTranscriptionModel = "gpt-4o-mini-transcribe",
                        ),
                    ),
                ),
            ),
        )
        val c = coordinator(voiceCatalog = catalog)
        // On the draft page, the user picks a realtime model and says the first sentence: the opening plan and the persisted conversation both use that realtime model, not the default text model gpt-4o-mini.
        assertEquals("gpt-realtime", c.plannedFirstConversation(provider.id, "gpt-realtime")?.modelID)
        assertEquals("conversation-1", c.createFirstConversation(provider.id, "gpt-realtime"))
        assertEquals("gpt-realtime", modelSlot.captured)
    }
}
