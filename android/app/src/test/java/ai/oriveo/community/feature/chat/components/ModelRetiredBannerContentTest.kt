package ai.oriveo.community.feature.chat.components

import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.core.provider.ModelRetirement
import ai.oriveo.community.feature.chat.ChatConversationIssue
import ai.oriveo.community.feature.chat.ChatConversationIssueKind
import ai.oriveo.community.feature.chat.resolveChatConversationState
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ModelRetiredBannerContentTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun provider(models: List<AIModel>) = Provider(
        id = "provider-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        models = models,
    )

    private fun issue(status: ModelRetirement.Status, successorId: String?) = ChatConversationIssue(
        kind = ChatConversationIssueKind.ModelRetired,
        isBlocking = false,
        modelRetirement = ModelRetirement.ConversationModelStatus(
            status = status,
            successorId = successorId,
            displayName = "GPT Legacy",
            sendBlocked = true,
            modelIdAfter = "gpt-legacy",
        ),
    )

    @Test
    fun `retired model with an enabled successor offers a direct switch`() {
        MetadataTestFixtures.applyRaw(OPENAI_CATALOG)
        val provider = provider(
            listOf(
                AIModel(id = "gpt-legacy", name = "GPT Legacy"),
                AIModel(id = "gpt-next", name = "GPT Next", isDefault = true),
            ),
        )
        val conversation = Conversation(
            id = "conversation-1",
            title = "Retired model",
            providerID = provider.id,
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-legacy",
        )
        // Comes from the production path: the issue produced by resolveChatConversationState
        val issue = requireNotNull(
            resolveChatConversationState(conversation, listOf(provider), provider.id, conversation.modelID, providersLoaded = true).issue,
        )

        val content = requireNotNull(modelRetiredBannerContent(issue, provider, ModelDisplayLookup(listOf(provider))))

        assertEquals(R.string.chat_model_retired_banner, content.messageRes)
        assertEquals("GPT Legacy", content.modelName)
        assertEquals(R.string.chat_model_retired_switch_to, content.actionRes)
        assertEquals("GPT Next", content.actionArg)
        assertEquals(ModelRetiredBannerContent.SwitchTarget("provider-1", "gpt-next"), content.switchTarget)
    }

    @Test
    fun `retired model whose successor is not enabled asks to choose a model`() {
        val provider = provider(listOf(AIModel(id = "gpt-legacy", name = "GPT Legacy")))
        val content = requireNotNull(
            modelRetiredBannerContent(issue(ModelRetirement.Status.Retired, "gpt-next"), provider, ModelDisplayLookup(listOf(provider))),
        )

        assertEquals(R.string.chat_model_retired_banner, content.messageRes)
        assertEquals("GPT Legacy", content.modelName)
        assertEquals(R.string.chat_model_removed_choose, content.actionRes)
        assertNull(content.actionArg)
        assertNull(content.switchTarget)
    }

    @Test
    fun `canonical successor enabled as its dated snapshot still offers a direct switch`() {
        val provider = provider(
            listOf(
                AIModel(id = "gpt-legacy", name = "GPT Legacy"),
                AIModel(id = "gpt-next-2026-01-01", name = "GPT Next", canonicalModelId = "gpt-next"),
            ),
        )
        val content = requireNotNull(
            modelRetiredBannerContent(issue(ModelRetirement.Status.Retired, "gpt-next"), provider, ModelDisplayLookup(listOf(provider))),
        )

        assertEquals(R.string.chat_model_retired_switch_to, content.actionRes)
        assertEquals("GPT Next", content.actionArg)
        assertEquals(ModelRetiredBannerContent.SwitchTarget("provider-1", "gpt-next-2026-01-01"), content.switchTarget)
    }

    @Test
    fun `retired model without successor asks to choose a model`() {
        val provider = provider(listOf(AIModel(id = "gpt-next", name = "GPT Next")))
        val content = requireNotNull(
            modelRetiredBannerContent(issue(ModelRetirement.Status.Retired, null), provider, ModelDisplayLookup(listOf(provider))),
        )

        assertEquals(R.string.chat_model_removed_choose, content.actionRes)
        assertNull(content.switchTarget)
    }

    @Test
    fun `missing model asks to choose a model`() {
        val provider = provider(listOf(AIModel(id = "gpt-next", name = "GPT Next")))
        val content = requireNotNull(
            modelRetiredBannerContent(issue(ModelRetirement.Status.Missing, "gpt-next"), provider, ModelDisplayLookup(listOf(provider))),
        )

        assertEquals(R.string.chat_model_retired_banner, content.messageRes)
        assertEquals(R.string.chat_model_removed_choose, content.actionRes)
        assertNull(content.switchTarget)
    }

    @Test
    fun `issue without retirement yields no retired banner content`() {
        val issue = ChatConversationIssue(kind = ChatConversationIssueKind.ModelMissing, isBlocking = false)
        assertNull(modelRetiredBannerContent(issue, null, ModelDisplayLookup(emptyList())))
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
