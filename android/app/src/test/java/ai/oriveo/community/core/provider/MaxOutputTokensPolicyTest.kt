package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.tools.ToolLoopLegRequest
import ai.oriveo.community.core.tools.ToolLoopMessage
import ai.oriveo.community.core.tools.ToolLoopToolChoice
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.content.TextContent
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.headersOf
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test

/** max_tokens of Anthropic Messages resolves as explicit value > model maxOutputTokens > protocol default 8192. */
class MaxOutputTokensPolicyTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val modelId = "claude-haiku-4-5"

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    /** The shape matches the claude entries of bundled-metadata.v2; when [maxOutputTokens] is null the entry omits the field. */
    private fun injectCatalogModel(maxOutputTokens: Int?) {
        val maxJson = maxOutputTokens?.let { ""","maxOutputTokens":$it""" }.orEmpty()
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"${ProviderKind.Anthropic.rawValue}":{"defaultModelId":"$modelId",""" +
                """"resolveMap":{"$modelId":"$modelId"},"models":{""" +
                """"$modelId":{"canonicalModelId":"$modelId","displayName":"Claude Haiku 4.5","contextLength":200000""" +
                """$maxJson}}}}}""",
        )
    }

    /** Sends once through the official production path (AnthropicService.sendMessageStream) and returns max_tokens from the request body. */
    private suspend fun officialMaxTokens(options: ChatRequestOptions = ChatRequestOptions()): Int {
        var body: String? = null
        val client = HttpClient(
            MockEngine { request ->
                if (body == null) {
                    body = when (val content = request.body) {
                        is TextContent -> content.text
                        is OutgoingContent.ByteArrayContent -> content.bytes().decodeToString()
                        else -> error("unexpected request body ${content::class}")
                    }
                }
                respond("data: [DONE]\n\n", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
            },
        ) { install(ContentNegotiation) { json(json) } }
        runCatching {
            AnthropicService(client, json, TransportRegistry(json)).sendMessageStream(
                apiKey = "sk-test",
                modelID = modelId,
                messages = listOf(ChatMessage(
                    id = "u1",
                    role = ChatRole.User,
                    text = "Hi",
                    providerKind = ProviderKind.Anthropic,
                    providerName = "Anthropic",
                    modelID = modelId,
                    modelName = modelId,
                    state = ChatMessageState.Delivered,
                )),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = options,
            ).toList()
        }
        val sent = assertNotNull("production path sent no request", body).let { body!! }
        return json.parseToJsonElement(sent).jsonObject.getValue("max_tokens").jsonPrimitive.int
    }

    @Test
    fun `official anthropic uses the catalog model maxOutputTokens`() = runTest {
        injectCatalogModel(64_000)
        assertEquals(64_000, MetadataClient.resolveCatalogModel(modelId, ProviderKind.Anthropic)?.maxOutputTokens)
        assertEquals(64_000, officialMaxTokens())
    }

    @Test
    fun `explicit max tokens wins over the catalog value`() = runTest {
        injectCatalogModel(64_000)
        assertEquals(1_000, officialMaxTokens(ChatRequestOptions(outputTokenBudget = 1_000)))
        assertEquals(1_000, MaxOutputTokensPolicy.anthropicMessages(1_000, 64_000))
    }

    @Test
    fun `model without maxOutputTokens falls back to the protocol default`() = runTest {
        injectCatalogModel(null)
        assertEquals(MaxOutputTokensPolicy.ANTHROPIC_MESSAGES_DEFAULT, officialMaxTokens())
        assertEquals(8192, MaxOutputTokensPolicy.anthropicMessages(null, 0))
    }
}
