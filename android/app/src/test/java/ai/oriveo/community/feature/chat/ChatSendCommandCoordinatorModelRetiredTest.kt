package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTransport
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * A conversation model that has been retired or is missing from the loaded catalog never sends a request,
 * and no send ever rewrites the stored modelID of an existing conversation. Assertions go through the production entry [ChatSendCommandCoordinator.sendMessage].
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatSendCommandCoordinatorModelRetiredTest {
    private val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>(relaxed = true)

    @Before
    fun setUp() {
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
    }

    @After
    fun tearDown() {
        setBundledSnapshotActive(false)
        MetadataTestFixtures.clear()
    }

    @Test
    fun `tombstoned conversation model blocks send without rewriting the conversation`() = runTest {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAIProvider("gpt-legacy", "gpt-next")

        val launched = send(provider, conversation(provider, "gpt-legacy"), "gpt-legacy")

        assertFalse(launched)
        coVerify(exactly = 0) { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `model missing from a loaded catalog blocks send`() = runTest {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAIProvider("gpt-next")

        // Voice catalog ready (empty): an id not in the text catalog on an official apiKey connection is still judged missing (only the not-ready case is exempted).
        val launched = send(provider, conversation(provider, "gpt-vanished"), "gpt-vanished", voiceCatalog = EMPTY_VOICE_CATALOG)

        assertFalse(launched)
        coVerify(exactly = 0) { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `alias resolved through resolveMap sends and keeps the stored id`() = runTest {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAIProvider("gpt-next")

        val launched = send(provider, conversation(provider, "gpt-next-2026-01-01"), "gpt-next-2026-01-01")

        assertTrue(launched)
        coVerify(exactly = 0) { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `unloaded catalog sends the stored model as is`() = runTest {
        val provider = openAIProvider("gpt-next")

        val launched = send(provider, conversation(provider, "gpt-legacy"), "gpt-legacy")

        assertTrue(launched)
        assertEquals("gpt-legacy", launchedModelId)
        coVerify(exactly = 0) { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `bundled snapshot sends a model missing from it as is`() = runTest {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        setBundledSnapshotActive(true)
        val provider = openAIProvider("gpt-next")

        val launched = send(provider, conversation(provider, "gpt-vanished"), "gpt-vanished")

        assertTrue(launched)
        assertEquals("gpt-vanished", launchedModelId)
        coVerify(exactly = 0) { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `conversation model enabled only through its canonical id is not judged missing`() = runTest {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAIProvider("gpt-next").let { base ->
            base.copy(models = base.models + AIModel(
                id = "gpt-custom-2026-01-01",
                name = "GPT Custom",
                capabilities = listOf(ModelCapability.Text),
                canonicalModelId = "gpt-custom",
            ))
        }

        val launched = send(provider, conversation(provider, "gpt-custom"), "gpt-custom")

        assertTrue(launched)
    }

    @Test
    fun `conversation whose provider was deleted is neither sent through another provider nor rewritten`() = runTest {
        val provider = openAIProvider("gpt-next")
        coEvery { providerRepository.getById("provider-deleted") } returns null
        val orphan = conversation(provider, "gpt-old").copy(providerID = "provider-deleted")

        val launched = send(provider, orphan, "gpt-next")

        assertFalse(launched)
        coVerify(exactly = 0) { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `realtime_selection_voice_entry_allowed_with_loaded_catalog`() = runTest {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAIProvider("gpt-next").copy(apiKey = "sk-test")
        val coordinator = coordinator(provider, conversation(provider, REALTIME_MODEL), voiceCatalog = REALTIME_VOICE_CATALOG)

        val allowed = coordinator.voiceEntryAllowed(provider.id, REALTIME_MODEL)

        assertTrue(allowed)
    }

    /** Realtime model selected: the voice entry only goes through realtime disclosure (judged on the voice station), and no provider disclosure is shown anymore. */
    @Test
    fun `realtime_voice_entry_skips_provider_disclosure`() = runTest {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns false
        val provider = openAIProvider("gpt-next").copy(apiKey = "sk-test")
        val coordinator = coordinator(provider, conversation(provider, REALTIME_MODEL), voiceCatalog = REALTIME_VOICE_CATALOG)

        val allowed = coordinator.voiceEntryAllowed(provider.id, REALTIME_MODEL)

        assertTrue(allowed)
        assertTrue(disclosurePrompts.isEmpty())
    }

    /** Realtime model selected: typed send only goes through the realtime disclosure (judged on the host), and no provider disclosure is shown (home full-flow case 07). */
    @Test
    fun `realtime_typed_send_skips_provider_disclosure`() = runTest {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns false
        val provider = openAIProvider("gpt-next").copy(apiKey = "sk-test")
        val coordinator = coordinator(provider, conversation(provider, REALTIME_MODEL), voiceCatalog = REALTIME_VOICE_CATALOG)
        val typed = mutableListOf<String>()
        backgroundScope.launch { coordinator.realtimeTyped.collect { typed += it } }
        testScheduler.runCurrent()

        coordinator.sendMessage("hello", null, provider.id, REALTIME_MODEL)
        testScheduler.runCurrent()

        assertTrue(disclosurePrompts.isEmpty())
        assertEquals(listOf("hello"), typed)
    }

    @Test
    fun `realtime_typed_send_emits_realtime_typed_with_loaded_catalog`() = runTest {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAIProvider("gpt-next").copy(apiKey = "sk-test")
        val coordinator = coordinator(provider, conversation(provider, REALTIME_MODEL), voiceCatalog = REALTIME_VOICE_CATALOG)
        val typed = mutableListOf<String>()
        // The collector lives in backgroundScope: advanceUntilIdle only waits for foreground tasks, so runCurrent lets it subscribe first and then receive.
        backgroundScope.launch { coordinator.realtimeTyped.collect { typed += it } }
        testScheduler.runCurrent()

        coordinator.sendMessage("hello", null, provider.id, REALTIME_MODEL)
        testScheduler.runCurrent()

        assertEquals(listOf("hello"), typed)
        assertFalse(textLaunched)
    }

    @Test
    fun `text_model_missing_from_loaded_catalog_still_blocks`() = runTest {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAIProvider("gpt-next").copy(apiKey = "sk-test")

        val launched = send(provider, conversation(provider, "gpt-vanished"), "gpt-vanished", voiceCatalog = REALTIME_VOICE_CATALOG)

        assertFalse(launched)
    }

    /** While the voice catalog is not ready, a realtime id on an official apiKey connection is not judged retired against the text catalog, so sending is not blocked as no_model. */
    @Test
    fun `realtime_id_not_blocked_while_voice_catalog_pending`() = runTest {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAIProvider("gpt-next").copy(apiKey = "sk-test")

        val launched = send(provider, conversation(provider, REALTIME_MODEL), REALTIME_MODEL, voiceCatalog = null)

        // Waiting for the catalog: no text request is built, no no_model is recorded, and no model-selection error is shown.
        assertFalse(launched)
        assertEquals(0, modelSelectionErrors)
        coVerify(exactly = 0) { conversationRepository.updateProviderAndModel(any(), any(), any(), any(), any()) }
    }

    /** When voice delivery (delivery=VOICE) selects a realtime model it is also not handed to the text API; it only records realtime_model and shows no error. */
    @Test
    fun `voice_delivery_with_realtime_model_is_refused`() = runTest {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = openAIProvider("gpt-next").copy(apiKey = "sk-test")
        var blocked = 0

        coordinator(provider, conversation(provider, REALTIME_MODEL), voiceCatalog = REALTIME_VOICE_CATALOG)
            .sendMessage(
                "hello",
                null,
                provider.id,
                REALTIME_MODEL,
                delivery = ai.oriveo.community.core.context.ContextDelivery.VOICE,
                onBlocked = { blocked++ },
            )
        advanceUntilIdle()

        assertFalse(textLaunched)
        assertEquals(0, modelSelectionErrors)
        assertEquals(1, blocked)
    }

    private var launchedModelId: String? = null
    private var textLaunched = false
    private var modelSelectionErrors = 0
    private val disclosurePrompts = mutableListOf<ProviderDisclosurePrompt>()

    private fun TestScope.send(
        provider: Provider,
        conversation: Conversation,
        modelId: String,
        voiceCatalog: VoiceCatalog? = null,
    ): Boolean {
        coordinator(provider, conversation, voiceCatalog = voiceCatalog)
            .sendMessage("hello", null, provider.id, modelId)
        advanceUntilIdle()
        return textLaunched
    }

    private fun TestScope.coordinator(
        provider: Provider,
        conversation: Conversation,
        voiceCatalog: VoiceCatalog? = null,
    ): ChatSendCommandCoordinator {
        coEvery { providerRepository.getById(provider.id) } returns provider
        coEvery { conversationRepository.getWithMessages(conversation.id) } returns conversation
        return ChatSendCommandCoordinator(
            viewModelScope = this,
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            currentConversation = { conversation },
            currentConversationId = { conversation.id },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = { modelSelectionErrors++ },
            onDisclosureRequired = { prompt, _ -> disclosurePrompts += prompt },
            onDisclosureConfirmationFailed = {},
            onConversationActivated = {},
            onComposerConsumed = {},
            requestPin = {},
            onSendSettled = {},
            launchSend = ChatSendLauncher { _, _, sentModelId, _, _, _, _, _, _, _, _ ->
                textLaunched = true
                launchedModelId = sentModelId
            },
            voiceCatalog = { voiceCatalog },
        )
    }

    private fun setBundledSnapshotActive(active: Boolean) {
        MetadataClient::class.java.getDeclaredField("bundledSnapshotActive")
            .apply { isAccessible = true }
            .setBoolean(MetadataClient.instance, active)
    }


    private fun openAIProvider(vararg modelIds: String): Provider = Provider(
        id = "provider-openai",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        models = modelIds.map(::textModel),
    )

    private fun textModel(id: String): AIModel =
        AIModel(id = id, name = id, capabilities = listOf(ModelCapability.Text))

    private fun conversation(provider: Provider, modelId: String): Conversation = Conversation(
        id = "conversation-1",
        title = "Retired model",
        providerID = provider.id,
        providerKind = provider.kind,
        modelID = modelId,
        messages = emptyList(),
    )

    private companion object {
        const val REALTIME_MODEL = "gpt-realtime"

        val EMPTY_VOICE_CATALOG = VoiceCatalog(schemaVersion = 2)

        val REALTIME_VOICE_CATALOG = VoiceCatalog(
            schemaVersion = 2,
            providers = mapOf(
                ProviderKind.OpenAI to VoiceProviderCatalog(
                    realtime = listOf(
                        VoiceRealtimeEntry(
                            model = REALTIME_MODEL,
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

        val OPENAI_CATALOG = """
            {
              "version": 1,
              "contractVersion": 1,
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-next",
                  "retiredModels": [
                    { "id": "gpt-legacy", "displayName": "GPT Legacy", "retiredAt": "2026-07-24T00:00:00Z", "routedTo": "gpt-next" }
                  ],
                  "resolveMap": { "gpt-next": "gpt-next", "gpt-next-2026-01-01": "gpt-next" },
                  "models": { "gpt-next": { "canonicalModelId": "gpt-next", "displayName": "GPT Next" } }
                }
              }
            }
        """.trimIndent()
    }
}
