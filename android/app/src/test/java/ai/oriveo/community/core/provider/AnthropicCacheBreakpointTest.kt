package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.relay.RelayChatBuildExtras
import ai.oriveo.community.core.provider.relay.buildAnthropicBody
import ai.oriveo.community.core.provider.transport.TransportRegistry
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
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Anthropic allows at most 4 cache_control breakpoints per request. With 5 images in the current
 * turn plus an image in history, the request body of both production paths (direct Anthropic and
 * relay) must carry no more than 1 cache_control.
 */
class AnthropicCacheBreakpointTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val modelId = "claude-haiku-4-5"

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun image(id: String) = Attachment(
        id = id,
        kind = AttachmentKind.Image,
        fileName = "$id.png",
        mimeType = "image/png",
        base64Data = "iVBORw0KGgo$id",
    )

    private fun conversation(): List<ChatMessage> {
        val history = ProviderTestFixtures.userMessage("What is in this picture?", ProviderKind.Anthropic, modelId)
            .copy(attachments = listOf(image("h1")))
        val answer = ChatMessage(
            id = "a1",
            role = ChatRole.Assistant,
            text = "A cat.",
            providerKind = ProviderKind.Anthropic,
            providerName = "Anthropic",
            modelName = modelId,
            state = ChatMessageState.Delivered,
        )
        val current = ProviderTestFixtures.userMessage("Compare these five.", ProviderKind.Anthropic, modelId)
            .copy(attachments = (1..5).map { image("c$it") })
        return listOf(history, answer, current)
    }

    private fun countCacheControl(body: String): Int = Regex("\"cache_control\"").findAll(body).count()

    private fun imageBlocks(messages: JsonArray): Int = messages.sumOf { message ->
        (message.jsonObject["content"] as? JsonArray)?.count {
            it.jsonObject["type"]?.jsonPrimitive?.content == "image"
        } ?: 0
    }

    @Test
    fun `official anthropic keeps only the top level breakpoint`() = runTest {
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
                messages = conversation(),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(),
            ).toList()
        }

        val sent = assertNotNull("production path sent no request", body).let { body!! }
        val parsed = json.parseToJsonElement(sent).jsonObject
        val messages = parsed.getValue("messages").jsonArray
        assertEquals("The 1 history image and the 5 current-turn images must all be sent", 6, imageBlocks(messages))
        assertTrue("At most 1 cache_control: $sent", countCacheControl(sent) <= 1)
        assertEquals("Content blocks never get cache_control", 0, countCacheControl(messages.toString()))
    }

    @Test
    fun `relay anthropic puts a single breakpoint on the last block of the last user`() {
        val body = buildAnthropicBody(
            modelID = modelId,
            messages = conversation(),
            stream = true,
            reasoningMode = ReasoningMode.Automatic,
            requestOptions = ChatRequestOptions(),
            // Without capability evidence the vision gate would drop the images; this test measures breakpoints on a request with images, so keep them.
            buildExtras = RelayChatBuildExtras(keepImageAttachments = true),
        )
        val parsed = json.parseToJsonElement(body).jsonObject
        val messages = parsed.getValue("messages").jsonArray
        assertEquals(6, imageBlocks(messages))
        assertTrue("At most 1 cache_control: $body", countCacheControl(body) <= 1)
        assertNull("The relay sends no top-level cache_control", parsed["cache_control"])
        val lastUser = messages.last { it.jsonObject["role"]?.jsonPrimitive?.content == "user" }.jsonObject
        val lastBlock = lastUser.getValue("content").jsonArray.last().jsonObject
        assertNotNull("The breakpoint sits on the last content block of the last user message", lastBlock["cache_control"])
        assertEquals(1, countCacheControl(body))
    }

    @Test
    fun `relay anthropic marks a text only last user turn`() {
        val messages = listOf(ProviderTestFixtures.userMessage("Hello", ProviderKind.Anthropic, modelId))
        val body = buildAnthropicBody(
            modelID = modelId,
            messages = messages,
            stream = true,
            reasoningMode = ReasoningMode.Automatic,
            requestOptions = ChatRequestOptions(),
        )
        val content = json.parseToJsonElement(body).jsonObject.getValue("messages").jsonArray.single()
            .jsonObject.getValue("content").jsonArray.single().jsonObject
        assertEquals("Hello", content["text"]?.jsonPrimitive?.content)
        assertNotNull(content["cache_control"])
        assertTrue(content["cache_control"] is JsonObject)
    }
}
