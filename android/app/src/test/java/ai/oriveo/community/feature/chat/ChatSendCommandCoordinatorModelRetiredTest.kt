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
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
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
 * and no send ever rewrites the stored modelID of an existing conversation. Assertions go through the
 * production entry [ChatSendCommandCoordinator.sendMessage].
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

        val launched = send(provider, conversation(provider, "gpt-vanished"), "gpt-vanished")

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

    private var launchedModelId: String? = null

    private fun TestScope.send(
        provider: Provider,
        conversation: Conversation,
        modelId: String,
    ): Boolean {
        coEvery { providerRepository.getById(provider.id) } returns provider
        coEvery { conversationRepository.getWithMessages(conversation.id) } returns conversation
        var launched = false
        val coordinator = ChatSendCommandCoordinator(
            viewModelScope = this,
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            currentConversation = { conversation },
            currentConversationId = { conversation.id },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = {},
            onDisclosureRequired = { _, _ -> },
            onDisclosureConfirmationFailed = {},
            onConversationActivated = {},
            onComposerConsumed = {},
            requestPin = {},
            onSendSettled = {},
            launchSend = ChatSendLauncher { _, _, sentModelId, _, _, _, _, _, _, _, _ ->
                launched = true
                launchedModelId = sentModelId
            },
        )
        coordinator.sendMessage("hello", null, provider.id, modelId)
        advanceUntilIdle()
        return launched
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
