package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ModelRetirement
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatConversationStateTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `new chat and empty model conversation fall back along the new chat chain without retired isDefault`() {
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-legacy","retiredModels":[{"id":"gpt-legacy","displayName":"GPT Legacy","retiredAt":"2026-07-24T00:00:00Z","routedTo":"gpt-next"}],"resolveMap":{"gpt-next":"gpt-next"},"models":{"gpt-next":{"canonicalModelId":"gpt-next","displayName":"GPT Next"}}}}}""")
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(id = "gpt-legacy", name = "GPT Legacy", isDefault = true),
                AIModel(id = "gpt-next", name = "GPT Next"),
            ),
        )
        val newChat = resolveChatConversationState(
            conversation = null,
            providers = listOf(provider),
            activeProviderId = provider.id,
            activeModelId = null,
            providersLoaded = true,
        )
        val emptyModelConversation = resolveChatConversationState(
            conversation = Conversation(
                id = "conversation-1",
                title = "Empty model",
                providerID = provider.id,
                providerKind = ProviderKind.OpenAI,
                modelID = "",
            ),
            providers = listOf(provider),
            activeProviderId = null,
            activeModelId = null,
            providersLoaded = true,
        )

        assertEquals("gpt-next", newChat.model?.id)
        assertEquals("gpt-next", emptyModelConversation.model?.id)
    }

    @Test
    fun `provider list still loading does not raise the removed connection banner nor block send`() {
        val conversation = Conversation(
            id = "conversation-1",
            title = "Loading providers",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "model-1",
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = emptyList(),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
            providersLoaded = false,
        )

        assertEquals(null, state.issue)
        assertFalse(state.isReadOnly)
        assertFalse(state.isSendBlocked)
    }

    @Test
    fun `missing provider keeps existing conversation readable and shows the banner when the loaded provider list is empty`() {
        val conversation = Conversation(
            id = "conversation-1",
            title = "Missing provider",
            providerID = "provider-missing",
            providerKind = ProviderKind.OpenAI,
            modelID = "model-1",
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = emptyList(),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
            providersLoaded = true,
        )

        assertFalse(state.isReadOnly)
        assertTrue(state.isSendBlocked)
        assertEquals(ChatConversationIssueKind.ProviderMissing, state.issue?.kind)
        assertEquals("model-1", state.issue?.missingProviderModelName)
        // No connection at all: the button opens add-connection instead of the model picker.
        assertFalse(state.issue!!.hasUsableConnection)
        assertFalse(state.issue!!.canRepairFromModelPicker)
        assertEquals(null, state.provider)
        assertEquals(null, state.model)
    }

    @Test
    fun `new chat with an empty chain leaves provider null instead of taking the first listed connection`() {
        // Empty chain (e.g. the only official connection lacks a key, so the caller resolves activeProviderId = null): go to model selection, do not fall back to the first listed connection.
        val keyless = Provider(
            id = "provider-keyless",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-next", name = "GPT Next")),
        )

        val state = resolveChatConversationState(
            conversation = null,
            providers = listOf(keyless),
            activeProviderId = null,
            activeModelId = null,
            providersLoaded = true,
        )

        assertEquals(null, state.provider)
        assertEquals(null, state.model)
        assertEquals(null, state.issue)
    }

    @Test
    fun `new chat without providers is still blocked`() {
        val state = resolveChatConversationState(
            conversation = null,
            providers = emptyList(),
            activeProviderId = null,
            activeModelId = null,
            providersLoaded = true,
        )

        assertTrue(state.isReadOnly)
        assertEquals(ChatConversationIssueKind.NoProvidersAvailable, state.issue?.kind)
    }

    @Test
    fun `missing provider shows the banner and blocks send instead of falling back to another provider`() {
        val conversation = Conversation(
            id = "conversation-1",
            title = "Missing provider",
            providerID = "provider-missing",
            providerKind = ProviderKind.OpenAI,
            modelID = "model-missing",
        )
        val fallbackModel = AIModel(id = "fallback-model", name = "Fallback Model", isDefault = true)
        val fallbackProvider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(fallbackModel),
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(fallbackProvider),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
            providersLoaded = true,
        )

        assertFalse(state.isReadOnly)
        assertTrue(state.isSendBlocked)
        assertEquals(ChatConversationIssueKind.ProviderMissing, state.issue?.kind)
        assertTrue(state.issue!!.rendersAboveComposer)
        assertTrue(state.issue!!.canRepairFromModelPicker)
        assertEquals(null, state.provider)
        assertEquals(null, state.model)
    }

    @Test
    fun `missing model keeps conversation readable without issue banner while catalog is not loaded`() {
        val conversation = Conversation(
            id = "conversation-1",
            title = "Missing model",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "model-missing",
        )
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "model-available", name = "Available")),
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(provider),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
            providersLoaded = true,
        )

        assertFalse(state.isReadOnly)
        assertEquals(null, state.issue)
        // An unloaded catalog counts as available: send the stored id as is, do not silently swap in a default.
        assertEquals("model-missing", state.model?.id)
    }

    @Test
    fun `unavailable model keeps conversation readable without issue banner`() {
        val conversation = Conversation(
            id = "conversation-1",
            title = "Unavailable model",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "model-unavailable",
        )
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "model-unavailable",
                    name = "Unavailable",
                    isAvailable = false,
                ),
            ),
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(provider),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
            providersLoaded = true,
        )

        assertFalse(state.isReadOnly)
        assertEquals(null, state.issue)
        assertEquals("model-unavailable", state.model?.id)
    }

    @Test
    fun `provider issue keeps conversation available without extra attention state`() {
        val model = AIModel(id = "model-1", name = "GPT-4o")
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Issue("Key expired"),
            models = listOf(model),
        )
        val conversation = Conversation(
            id = "conversation-1",
            title = "Provider issue",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "model-1",
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(provider),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
            providersLoaded = true,
        )

        assertFalse(state.isReadOnly)
        assertEquals(null, state.issue)
    }
    @Test
    fun `missing model in a loaded catalog raises ModelRetired without falling back to default`() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val conversation = Conversation(
            id = "conversation-1",
            title = "Missing model",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "model-missing",
        )
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-next", name = "GPT Next", isDefault = true)),
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(provider),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
            providersLoaded = true,
        )

        assertEquals(ChatConversationIssueKind.ModelRetired, state.issue?.kind)
        assertEquals(ModelRetirement.Status.Missing, state.issue?.modelRetirement?.status)
        assertEquals(null, state.model)
        assertFalse(state.isReadOnly)
        assertTrue(state.isSendBlocked)
    }

    @Test
    fun `tombstoned conversation model raises ModelRetired with name and successor`() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val conversation = Conversation(
            id = "conversation-1",
            title = "Retired model",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-legacy",
        )
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(id = "gpt-legacy", name = "GPT Legacy"),
                AIModel(id = "gpt-next", name = "GPT Next", isDefault = true),
            ),
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(provider),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
            providersLoaded = true,
        )

        val retirement = state.issue?.modelRetirement
        assertEquals(ChatConversationIssueKind.ModelRetired, state.issue?.kind)
        assertEquals(ModelRetirement.Status.Retired, retirement?.status)
        assertEquals("GPT Legacy", retirement?.displayName)
        assertEquals("gpt-next", retirement?.successorId)
        assertEquals("gpt-legacy", retirement?.modelIdAfter)
        assertTrue(state.isSendBlocked)
        assertFalse(state.isReadOnly)
    }

    @Test
    fun `ModelRetired issue renders above the composer`() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val conversation = Conversation(
            id = "conversation-1",
            title = "Retired model",
            providerID = "provider-1",
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-legacy",
        )
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-next", name = "GPT Next", isDefault = true)),
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(provider),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
            providersLoaded = true,
        )

        assertEquals(ChatConversationIssueKind.ModelRetired, state.issue?.kind)
        assertTrue(state.issue?.rendersAboveComposer == true)
    }

    @Test
    fun `relay conversation is not judged by the official retirement rules`() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val conversation = Conversation(
            id = "conversation-1",
            title = "Relay",
            providerID = "relay-1",
            providerKind = ProviderKind.Relay,
            modelID = "gpt-legacy",
        )
        val provider = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-legacy", name = "GPT Legacy")),
        )

        val state = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(provider),
            activeProviderId = conversation.providerID,
            activeModelId = conversation.modelID,
            providersLoaded = true,
        )

        assertEquals(null, state.issue)
        assertEquals("gpt-legacy", state.model?.id)
        assertFalse(state.isSendBlocked)
    }

    @Test
    fun `empty model conversation picks catalog default over an available isDefault`() {
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-mini","retiredModels":[],"resolveMap":{},"models":{"gpt-next":{"canonicalModelId":"gpt-next","displayName":"GPT Next"},"gpt-mini":{"canonicalModelId":"gpt-mini","displayName":"GPT Mini"}}}}}""")
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(id = "gpt-next", name = "GPT Next", isDefault = true),
                AIModel(id = "gpt-mini", name = "GPT Mini"),
            ),
        )
        val emptyModelConversation = Conversation(
            id = "conversation-1",
            title = "Empty model",
            providerID = provider.id,
            providerKind = ProviderKind.OpenAI,
            modelID = "",
        )

        val state = resolveChatConversationState(
            conversation = emptyModelConversation,
            providers = listOf(provider),
            activeProviderId = null,
            activeModelId = null,
            providersLoaded = true,
        )

        assertEquals("gpt-mini", state.model?.id)
    }

    @Test
    fun `empty model conversation prefers the last used model of its own connection when usable`() {
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-mini","retiredModels":[{"id":"gpt-legacy","displayName":"GPT Legacy","retiredAt":"2026-07-24T00:00:00Z","routedTo":"gpt-mini"}],"resolveMap":{},"models":{"gpt-next":{"canonicalModelId":"gpt-next","displayName":"GPT Next"},"gpt-mini":{"canonicalModelId":"gpt-mini","displayName":"GPT Mini"}}}}}""")
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(id = "gpt-legacy", name = "GPT Legacy"),
                AIModel(id = "gpt-next", name = "GPT Next"),
                AIModel(id = "gpt-mini", name = "GPT Mini"),
            ),
        )
        val conversation = Conversation(
            id = "conversation-1",
            title = "Empty model",
            providerID = provider.id,
            providerKind = ProviderKind.OpenAI,
            modelID = "",
        )
        fun modelFor(lastUsed: LastUsedModelRef?) = resolveChatConversationState(
            conversation = conversation,
            providers = listOf(provider),
            activeProviderId = null,
            activeModelId = null,
            providersLoaded = true,
            lastUsedModelRef = lastUsed,
        ).model?.id

        assertEquals("gpt-next", modelFor(LastUsedModelRef(provider.id, "gpt-next")))
        // Last used is on another connection or retired: ignore it and use the new-chat fallback (catalog default).
        assertEquals("gpt-mini", modelFor(LastUsedModelRef("provider-other", "gpt-next")))
        assertEquals("gpt-mini", modelFor(LastUsedModelRef(provider.id, "gpt-legacy")))
    }

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
                  "resolveMap": { "gpt-next": "gpt-next" },
                  "models": { "gpt-next": { "canonicalModelId": "gpt-next", "displayName": "GPT Next" } }
                }
              }
            }
        """.trimIndent()
    }
}
