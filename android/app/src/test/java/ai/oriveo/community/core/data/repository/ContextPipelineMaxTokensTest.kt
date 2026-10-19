package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.GenerationParameterOutboundContractTest
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * On the chat main path max_tokens = plan.budget.oWire, and when the Anthropic thinking budget is >= it, max_tokens = budget + 4096.
 *
 * Production path: the real ChatRepository.sendMessage (with chatContext) -> the real AnthropicService, with MockEngine only capturing the request body.
 */
class ContextPipelineMaxTokensTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        openClients.forEach { it.close() }
        openClients.clear()
        MetadataTestFixtures.clear()
    }

    @Test
    fun max_tokens_equals_o_wire() = runTest {
        MetadataTestFixtures.clear()
        // W=16000 TOTAL: R = min(max(8192, 1600), 8000) = 8000 → oWire = min(8192, 8000) = 8000.
        val model = AIModel(id = "claude-window-16k", name = "Claude 16k", contextLength = 16_000, maxOutputTokens = 8192)
        val body = sendThroughAnthropic(model)

        assertEquals("8000", body.getValue("max_tokens").jsonPrimitive.content)
    }

    @Test
    fun max_tokens_model_default_8192() = runTest {
        // The metadata gives a 64000 output limit but AIModel has no maxOutputTokens: the O chain falls to 8192, and with W=128000 oWire = 8192.
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"anthropic":{"resolveMap":{"$NO_MAX_MODEL":"$NO_MAX_MODEL"},""" +
                """"models":{"$NO_MAX_MODEL":{"maxOutputTokens":64000,"contextLength":128000}}}}}""",
        )
        val model = AIModel(id = NO_MAX_MODEL, name = "Claude no max", contextLength = 128_000)
        val body = sendThroughAnthropic(model)

        assertEquals("8192", body.getValue("max_tokens").jsonPrimitive.content)
    }

    @Test
    fun max_tokens_thinking_guard() = runTest {
        // The Deep tier thinking budget 16384 >= oWire 8000 -> max_tokens = 16384 + 4096.
        MetadataTestFixtures.applyRaw(GenerationParameterOutboundContractTest().officialMetadata().toString())
        val model = AIModel(
            id = GenerationParameterOutboundContractTest.OFFICIAL_MODEL,
            name = "Claude Sonnet",
            contextLength = 16_000,
            maxOutputTokens = 8192,
        )
        val body = sendThroughAnthropic(model, reasoningMode = ReasoningMode.Deep)

        assertEquals("16384", body.getValue("thinking").jsonObject.getValue("budget_tokens").jsonPrimitive.content)
        assertEquals("20480", body.getValue("max_tokens").jsonPrimitive.content)
    }

    @Test
    fun max_tokens_user_setting_budgeted() = runTest {
        // The panel's "max output" enters the user level of the O chain: user 4000, model 8192, W=16000 -> R=8000, oWire = 4000.
        MetadataTestFixtures.applyRaw(GenerationParameterOutboundContractTest().officialMetadata().toString())
        val model = AIModel(
            id = GenerationParameterOutboundContractTest.OFFICIAL_MODEL,
            name = "Claude Sonnet",
            contextLength = 16_000,
            maxOutputTokens = 8192,
        )
        val budgeted = sendThroughAnthropic(model, maxOutputOverride = 4000)
        assertEquals("4000", budgeted.getValue("max_tokens").jsonPrimitive.content)

        // When the panel value exceeds R the sent value = min(O, R) = 8000, and the resolver no longer overrides it with the original 12000.
        val clamped = sendThroughAnthropic(model, maxOutputOverride = 12_000)
        assertEquals("8000", clamped.getValue("max_tokens").jsonPrimitive.content)
    }

    // ── harness ──

    private suspend fun sendThroughAnthropic(
        model: AIModel,
        reasoningMode: ReasoningMode = ReasoningMode.Automatic,
        maxOutputOverride: Int? = null,
    ): JsonObject {
        val bodies = mutableListOf<JsonObject>()
        val client = HttpClient(MockEngine { request ->
            bodies += json.parseToJsonElement(bodyText(request.body)).jsonObject
            respond("data: [DONE]\n\n", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        }).also { openClients += it }
        val provider = Provider(id = "anthropic-1", kind = ProviderKind.Anthropic, apiKey = "byok-key", models = listOf(model))
        val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
            every { it.serviceFor(any<Provider>(), any()) } returns AnthropicService(client, json, TransportRegistry(json))
            coEvery { it.getById(provider.id) } returns provider
        }
        val repository = ChatRepository(
            conversationRepository = mockk<ConversationRepository>(relaxed = true),
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        val conversation = Conversation(
            id = "conversation-1",
            title = "Budget",
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = model.id,
            useMemory = false,
        )
        runCatching {
            repository.sendMessage(
                conversation = conversation,
                text = "Hello",
                provider = provider,
                modelID = model.id,
                existingMessages = emptyList(),
                reasoningMode = reasoningMode,
                requestOptions = ChatRequestOptions(
                    activeModel = model,
                    generationParameters = maxOutputOverride?.let {
                        GenerationParameterOverrides(
                            mapOf("max_output_tokens" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(it))),
                        )
                    },
                    chatContext = ChatContextRequest(ContextConversation(id = conversation.id, useMemory = false)),
                ),
                outputs = ConversationStreamingOutputs(
                    streamingText = MutableStateFlow(""),
                    streamingMessageId = MutableStateFlow(null),
                ),
            )
        }
        return bodies.single()
    }

    private fun bodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    private companion object {
        const val NO_MAX_MODEL = "claude-no-max"
    }
}
