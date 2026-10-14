package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.GeminiService
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.MiniMaxService
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.relay.buildLlamaCppPrompt
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.mockk
import java.io.File
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Shared fixture `attachments/image-placeholder.v1.json`: for text-only wires each image is written as one placeholder line,
 * byte-identical on all clients, and the request body produced by that wire's production builder contains no image block. One same-named test per case.
 */
class ImagePlaceholderContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val openClients = mutableListOf<HttpClient>()

    private val fixture: Map<String, String> by lazy {
        readJson("shared/test-fixtures/attachments/image-placeholder.v1.json")["cases"]!!.jsonArray
            .associate { case ->
                val obj = case.jsonObject
                obj["id"]!!.jsonPrimitive.content to obj["placeholder"]!!.jsonPrimitive.content
            }
    }

    private val androidRoutes: Map<String, String> by lazy {
        readJson("shared/test-fixtures/attachments/image-placeholder.v1.json")["cases"]!!.jsonArray
            .associate { case ->
                val obj = case.jsonObject
                obj["id"]!!.jsonPrimitive.content to obj["routes"]!!.jsonObject["android"]!!.jsonPrimitive.content
            }
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        openClients.forEach { it.close() }
        openClients.clear()
    }

    @Test
    fun IMAGE_PLACEHOLDER_deepseek_chat() {
        assertRoute("deepseek_chat", AttachmentTransportProfile.DeepSeekChat)
        val body = MessageBuilder.buildChatCompletionsMessages(listOf(message(ProviderKind.DeepSeek)), ProviderKind.DeepSeek)
        assertPlaceholderBody("deepseek_chat", body)
    }

    @Test
    fun IMAGE_PLACEHOLDER_relay_llamacpp_native() {
        assertRoute("relay_llamacpp_native", AttachmentTransportProfile.LlamaCppNative)
        val body = buildLlamaCppPrompt(listOf(message(ProviderKind.Relay)), ChatRequestOptions())
        assertPlaceholderBody("relay_llamacpp_native", body)
    }

    @Test
    fun IMAGE_PLACEHOLDER_minimax_chat() {
        assertRoute("minimax_chat", AttachmentTransportProfile.ChatCompletions(ProviderKind.MiniMax))
        val body = MessageBuilder.buildChatCompletionsMessages(listOf(message(ProviderKind.MiniMax)), ProviderKind.MiniMax)
        assertPlaceholderBody("minimax_chat", body)
    }

    @Test
    fun IMAGE_PLACEHOLDER_minimax_web() = runTest {
        assertRoute("minimax_web", AttachmentTransportProfile.MiniMaxAnthropicMessages)
        MetadataTestFixtures.applyRaw(miniMaxWebMetadata())
        var captured: String? = null
        val client = client { request ->
            if (captured == null) captured = bodyText(request.body)
            respond(
                content = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
            )
        }
        runCatching {
            MiniMaxService(client, json).sendMessageStream(
                "key", "MiniMax-M3", listOf(message(ProviderKind.MiniMax, "MiniMax-M3")), "https://api.minimax.io/v1",
                false, ReasoningMode.Automatic, true, ChatRequestOptions(),
            ).toList()
        }
        val body = requireNotNull(captured) { "MiniMax web route did not issue a request" }
        // Confirm that the Anthropic-compatible web search wire is used, not plain Chat.
        assertTrue(body, body.contains("web_search_20250305"))
        assertPlaceholderBody("minimax_web", body)
    }

    @Test
    fun IMAGE_PLACEHOLDER_gemini_interactions() = runTest {
        assertRoute("gemini_interactions", AttachmentTransportProfile.GeminiInteractions)
        MetadataTestFixtures.applyRaw(geminiInteractionsMetadata())
        var path = ""
        var captured: String? = null
        val client = client { request ->
            path = request.url.encodedPath
            if (captured == null) captured = bodyText(request.body)
            respond("""{"id":"int-1","status":"completed","steps":[{"type":"model_output","content":[{"text":"ok"}]}]}""", HttpStatusCode.OK)
        }
        GeminiService(client, json, TransportRegistry(json)).sendMessage(
            "key", "gemini-3-flash", listOf(message(ProviderKind.Gemini, "gemini-3-flash")), null, false,
            ReasoningMode.Automatic, true, ChatRequestOptions(),
        )
        assertEquals("/v1beta/interactions", path)
        assertPlaceholderBody("gemini_interactions", requireNotNull(captured))
    }

    // ── helpers ──

    private val imageBase64 = "SU1BR0VfUExBQ0VIT0xERVI="

    private fun message(kind: ProviderKind, modelId: String = "test-model"): ChatMessage =
        ProviderTestFixtures.userMessage("what is this", kind, modelId).copy(
            attachments = listOf(
                Attachment(id = "img", kind = AttachmentKind.Image, fileName = "p.png", mimeType = "image/png", base64Data = imageBase64),
            ),
        )

    /** The placeholder declared by the wire is byte-identical to the fixture; the fixture's android wire name matches the wire under test. */
    private fun assertRoute(id: String, profile: AttachmentTransportProfile) {
        val expectedName = when (profile) {
            is AttachmentTransportProfile.ChatCompletions -> "ChatCompletions(${profile.provider.name})"
            else -> profile::class.simpleName
        }
        assertEquals(id, androidRoutes.getValue(id), expectedName)
        assertEquals(id, fixture.getValue(id), profile.imagePlaceholderText)
    }

    /** The request body has the placeholder line and no image block or image bytes. */
    private fun assertPlaceholderBody(id: String, body: String) {
        val placeholder = fixture.getValue(id)
        assertTrue("$id request body lacks the placeholder: $body", body.contains(placeholder))
        assertFalse("$id request body carries image bytes: $body", body.contains(imageBase64))
        listOf("\"image_url\"", "\"inlineData\"", "\"type\":\"image\"", "\"input_image\"").forEach { block ->
            assertFalse("$id request body carries image block $block: $body", body.contains(block))
        }
    }

    private fun client(handler: suspend io.ktor.client.engine.mock.MockRequestHandleScope.(io.ktor.client.request.HttpRequestData) -> io.ktor.client.request.HttpResponseData): HttpClient =
        HttpClient(MockEngine(handler)).also { openClients.add(it) }

    private fun bodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    private fun repoRoot(): File = File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!

    private fun readJson(relativePath: String): JsonObject =
        json.parseToJsonElement(File(repoRoot(), relativePath).readText()).jsonObject

    /** Official Gemini web-search recipe: the real Server registry + a model whose web goes through Interactions (same as in GeminiServiceTest). */
    private fun geminiInteractionsMetadata(): String {
        val registry = readJson("shared/capabilityrecipe/capability_runtime.v1.json")
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:image-placeholder-test"),
            "generatedAt" to JsonPrimitive("2026-10-11T00:00:00Z"),
        ))
        return buildJsonObject {
            put("version", 1); put("capabilityRuntime", runtime)
            put("providers", buildJsonObject { put("gemini", buildJsonObject {
                put("resolveMap", buildJsonObject { put("gemini-3-flash", "gemini-3-flash") })
                put("models", buildJsonObject { put("gemini-3-flash", buildJsonObject {
                    put("transport", "gemini_interactions")
                    put("capabilityControls", buildJsonObject { put("web", buildJsonObject {
                        put("state", "auto_available"); put("recipeRef", "gemini.interactions.web.v1")
                    }) })
                }) })
            }) })
        }.toString()
    }

    /** Official MiniMax web-search recipe: the real Server registry + a model whose web goes through the Anthropic-compatible endpoint. */
    private fun miniMaxWebMetadata(): String {
        val registry = readJson("shared/capabilityrecipe/capability_runtime.v1.json")
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:image-placeholder-test"),
            "generatedAt" to JsonPrimitive("2026-10-11T00:00:00Z"),
        ))
        return buildJsonObject {
            put("version", 1); put("capabilityRuntime", runtime)
            put("providers", buildJsonObject { put("miniMax", buildJsonObject {
                put("resolveMap", buildJsonObject { put("MiniMax-M3", "MiniMax-M3") })
                put("models", buildJsonObject { put("MiniMax-M3", buildJsonObject {
                    put("canonicalModelId", "MiniMax-M3")
                    put("transport", "openai_chat")
                    put("capabilityControls", buildJsonObject { put("web", buildJsonObject {
                        put("state", "auto_available"); put("recipeRef", "minimax.messages.web.v1")
                    }) })
                }) })
            }) })
        }.toString()
    }
}
