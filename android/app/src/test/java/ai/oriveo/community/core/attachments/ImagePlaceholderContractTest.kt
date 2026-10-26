package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.DeepSeekService
import ai.oriveo.community.core.provider.GeminiService
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
 * Shared fixture `shared/test-fixtures/attachments/image-placeholder.v1.json`: a text-only route writes one placeholder line per image,
 * byte-identical on every platform, and the request body the production builder emits for that route carries no image block. One test per case, named after it.
 * Routes with byModel are walked row by row: the row's vision verdict is written into the official metadata and one request goes out through the production outbound path,
 * then the request body is asserted to carry the real image or the placeholder according to the row's outbound.
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

    /** One byModel fixture row: model x vision verdict -> expected outbound. */
    private data class ByModelRow(val model: String, val vision: JsonObject, val outbound: String)

    private val byModel: Map<String, List<ByModelRow>> by lazy {
        readJson("shared/test-fixtures/attachments/image-placeholder.v1.json")["cases"]!!.jsonArray
            .associate { case ->
                val obj = case.jsonObject
                obj["id"]!!.jsonPrimitive.content to obj["byModel"]?.jsonArray.orEmpty().map { row ->
                    val r = row.jsonObject
                    ByModelRow(r["model"]!!.jsonPrimitive.content, r["vision"]!!.jsonObject, r["outbound"]!!.jsonPrimitive.content)
                }
            }
    }

    /** The byModel rows of a case; only asserted non-empty, the count is not pinned. */
    private fun rowsOf(id: String): List<ByModelRow> = byModel.getValue(id).also { assertTrue("$id has no byModel rows", it.isNotEmpty()) }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        openClients.forEach { it.close() }
        openClients.clear()
    }

    @Test
    fun IMAGE_PLACEHOLDER_deepseek_chat() = runTest {
        assertRoute("deepseek_chat", AttachmentTransportProfile.DeepSeekChat)
        rowsOf("deepseek_chat").forEach { row ->
            MetadataTestFixtures.applyRaw(officialVisionMetadata(ProviderKind.DeepSeek, row))
            val body = chatBody { client ->
                DeepSeekService(client, json).sendMessageStream(
                    "key", row.model, listOf(message(ProviderKind.DeepSeek, row.model)), null,
                    false, ReasoningMode.Automatic, false, ChatRequestOptions(),
                ).toList()
            }
            assertOutboundBody("deepseek_chat", row, body, imageBlock = "\"image_url\"")
        }
    }

    @Test
    fun IMAGE_PLACEHOLDER_relay_llamacpp_native() {
        assertRoute("relay_llamacpp_native", AttachmentTransportProfile.LlamaCppNative)
        val body = buildLlamaCppPrompt(listOf(message(ProviderKind.Relay)), ChatRequestOptions())
        assertPlaceholderBody("relay_llamacpp_native", body)
    }

    @Test
    fun IMAGE_PLACEHOLDER_minimax_chat() = runTest {
        assertRoute("minimax_chat", AttachmentTransportProfile.ChatCompletions(ProviderKind.MiniMax))
        rowsOf("minimax_chat").forEach { row ->
            MetadataTestFixtures.applyRaw(officialVisionMetadata(ProviderKind.MiniMax, row))
            val body = chatBody { client ->
                MiniMaxService(client, json).sendMessageStream(
                    "key", row.model, listOf(message(ProviderKind.MiniMax, row.model)), "https://api.minimax.io/v1",
                    false, ReasoningMode.Automatic, false, ChatRequestOptions(),
                ).toList()
            }
            assertOutboundBody("minimax_chat", row, body, imageBlock = "\"image_url\"")
        }
    }

    @Test
    fun IMAGE_PLACEHOLDER_minimax_web() = runTest {
        assertRoute("minimax_web", AttachmentTransportProfile.MiniMaxAnthropicMessages)
        rowsOf("minimax_web").forEach { row ->
            MetadataTestFixtures.applyRaw(miniMaxWebMetadata(row))
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
                    "key", row.model, listOf(message(ProviderKind.MiniMax, row.model)), "https://api.minimax.io/v1",
                    false, ReasoningMode.Automatic, true, ChatRequestOptions(),
                ).toList()
            }
            val body = requireNotNull(captured) { "MiniMax web route did not issue a request" }
            // Confirms the Anthropic-compatible web route was taken, not plain Chat.
            assertTrue(body, body.contains("web_search_20250305"))
            assertOutboundBody("minimax_web", row, body, imageBlock = "\"type\":\"image\"")
        }
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

    private val imageBase64 = "SU1BR0VfUExBQ0VIT0xERVI="

    private fun message(kind: ProviderKind, modelId: String = "test-model"): ChatMessage =
        ProviderTestFixtures.userMessage("what is this", kind, modelId).copy(
            attachments = listOf(
                Attachment(id = "img", kind = AttachmentKind.Image, fileName = "p.png", mimeType = "image/png", base64Data = imageBase64),
            ),
        )

    /** The placeholder declared by the route is byte-identical to the fixture; the fixture's android route name matches the route under test. */
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

    /** Asserts by the byModel row's outbound: native_part sends the real image (block + bytes, no placeholder), placeholder behaves like a text-only route. */
    private fun assertOutboundBody(id: String, row: ByModelRow, body: String, imageBlock: String) {
        when (row.outbound) {
            "native_part" -> {
                assertTrue("$id/${row.model} lacks image block $imageBlock: $body", body.contains(imageBlock))
                assertTrue("$id/${row.model} lacks image bytes: $body", body.contains(imageBase64))
                assertFalse("$id/${row.model} must not write the placeholder: $body", body.contains(fixture.getValue(id)))
            }
            "placeholder" -> assertPlaceholderBody(id, body)
            else -> error("$id/${row.model} unknown outbound ${row.outbound}")
        }
    }

    /** Runs one production Chat streaming request and returns the first request body verbatim. */
    private suspend fun chatBody(send: suspend (HttpClient) -> Unit): String {
        var captured: String? = null
        val client = client { request ->
            if (captured == null) captured = bodyText(request.body)
            respond("data: [DONE]\n\n", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        }
        runCatching { send(client) }
        return requireNotNull(captured) { "chat route did not issue a request" }
    }

    /** Official metadata: one openai_chat model whose capabilityControls.vision_input takes the byModel row's verdict. */
    private fun officialVisionMetadata(kind: ProviderKind, row: ByModelRow): String = buildJsonObject {
        put("version", 1)
        put("providers", buildJsonObject { put(kind.rawValue, buildJsonObject {
            put("resolveMap", buildJsonObject { put(row.model, row.model) })
            put("models", buildJsonObject { put(row.model, buildJsonObject {
                put("canonicalModelId", row.model)
                put("transport", "openai_chat")
                put("capabilityControls", buildJsonObject { put("vision_input", row.vision) })
            }) })
        }) })
    }.toString()

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

    /** Official Gemini web recipe: the real registry plus a model whose web goes through Interactions (same as GeminiServiceTest). */
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

    /** Official MiniMax web recipe: the real registry plus a model whose web goes through the Anthropic-compatible endpoint; the vision verdict comes from the byModel row. */
    private fun miniMaxWebMetadata(row: ByModelRow): String {
        val registry = readJson("shared/capabilityrecipe/capability_runtime.v1.json")
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:image-placeholder-test"),
            "generatedAt" to JsonPrimitive("2026-10-11T00:00:00Z"),
        ))
        return buildJsonObject {
            put("version", 1); put("capabilityRuntime", runtime)
            put("providers", buildJsonObject { put("miniMax", buildJsonObject {
                put("resolveMap", buildJsonObject { put(row.model, row.model) })
                put("models", buildJsonObject { put(row.model, buildJsonObject {
                    put("canonicalModelId", row.model)
                    put("transport", "openai_chat")
                    put("capabilityControls", buildJsonObject {
                        put("web", buildJsonObject {
                            put("state", "auto_available"); put("recipeRef", "minimax.messages.web.v1")
                        })
                        put("vision_input", row.vision)
                    })
                }) })
            }) })
        }.toString()
    }
}
