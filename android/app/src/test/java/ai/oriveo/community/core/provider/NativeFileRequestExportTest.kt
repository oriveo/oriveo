package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
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
import java.io.File
import java.util.Base64
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * On the four direct routes, when the model allowlist includes PDF, the request body produced by the production send path carries a native file block.
 *
 * It is also an export tool: when the environment variable `ORIVEO_REQUEST_EXPORT_DIR` (or the system property `oriveo.requestExportDir`) is set,
 * it writes each route's URL path, query parameters, non-credential request headers and JSON body into that directory,
 * for people to check against a real upstream. No real request is sent here; the network layer is MockEngine.
 *
 * The model id can be overridden with `ORIVEO_REQUEST_EXPORT_MODEL_<OPENAI|ANTHROPIC|GEMINI|OPENROUTER>`.
 */
class NativeFileRequestExportTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry = TransportRegistry(json)

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private class Captured(
        val path: String,
        val query: Map<String, String>,
        val headers: Map<String, String>,
        val body: JsonObject,
    )

    private val pdfBytes: ByteArray = minimalPdf(MARKER)
    private val pdfBase64: String = Base64.getEncoder().encodeToString(pdfBytes)

    /** The extracted text deliberately does not contain the marker word: if the upstream can answer with it, it can only have read the original file. */
    private fun markerPdf() = Attachment(
        id = "att-pdf",
        kind = AttachmentKind.File,
        fileName = "marker.pdf",
        mimeType = PDF_MIME,
        base64Data = Base64.getEncoder().encodeToString(EXTRACTED_PLACEHOLDER.toByteArray()),
        originalBase64Data = pdfBase64,
        extractedSizeBytes = EXTRACTED_PLACEHOLDER.length,
    )

    private fun question(kind: ProviderKind, modelId: String, attachment: Attachment = markerPdf()) =
        listOf(ProviderTestFixtures.userMessage(QUESTION, kind, modelId).copy(attachments = listOf(attachment)))

    private fun catalogWithNativePdf(kind: ProviderKind, modelId: String) {
        MetadataTestFixtures.applyRaw(
            buildJsonObject {
                put("version", 1)
                put("providers", buildJsonObject {
                    put(kind.rawValue, buildJsonObject {
                        put("resolveMap", buildJsonObject { put(modelId, modelId) })
                        put("models", buildJsonObject {
                            put(modelId, buildJsonObject {
                                put("nativeFileMimes", JsonArray(listOf(JsonPrimitive(PDF_MIME))))
                                put("pdfNativeDefault", true)
                            })
                        })
                    })
                })
            }.toString(),
        )
    }

    private suspend fun capture(send: suspend (HttpClient) -> Unit): Captured {
        var captured: Captured? = null
        val client = HttpClient(
            MockEngine { request ->
                if (captured == null) {
                    val text = when (val body = request.body) {
                        is TextContent -> body.text
                        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
                        else -> error("unexpected request body ${body::class}")
                    }
                    val headers = (request.headers.entries() + request.body.headers.entries())
                        .filterNot { (name, _) -> name.lowercase() in CREDENTIAL_HEADERS }
                        .associate { (name, values) -> name to values.joinToString(",") }
                    val query = request.url.parameters.entries()
                        .filterNot { (name, _) -> name.lowercase() == "key" }
                        .associate { (name, values) -> name to values.joinToString(",") }
                    captured = Captured(request.url.encodedPath, query, headers, json.parseToJsonElement(text).jsonObject)
                }
                respond("data: [DONE]\n\n", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
            },
        ) { install(ContentNegotiation) { json(json) } }
        // The response is an empty stream and the Service may end with "empty reply"; all that matters here is the one request it sent.
        runCatching { send(client) }
        return assertNotNull("production path sent no request", captured).let { captured!! }
    }

    private fun export(route: String, captured: Captured) {
        val dir = setting("ORIVEO_REQUEST_EXPORT_DIR", "oriveo.requestExportDir") ?: return
        val target = File(dir).apply { mkdirs() }.resolve("android-$route.json")
        target.writeText(
            Json { prettyPrint = true }.encodeToString(
                JsonObject.serializer(),
                buildJsonObject {
                    put("route", route)
                    put("method", "POST")
                    put("url_path", captured.path)
                    put("url_query", buildJsonObject { captured.query.forEach { (k, v) -> put(k, v) } })
                    put("headers", buildJsonObject { captured.headers.forEach { (k, v) -> put(k, v) } })
                    put("marker", MARKER)
                    put("body", captured.body)
                },
            ),
        )
        println("[request-export] $route -> ${target.absolutePath}")
    }

    private fun modelId(route: String, default: String): String =
        setting("ORIVEO_REQUEST_EXPORT_MODEL_${route.uppercase()}", "oriveo.requestExportModel.$route") ?: default

    private fun setting(env: String, property: String): String? =
        (System.getProperty(property) ?: System.getenv(env))?.takeIf { it.isNotBlank() }

    private fun JsonElement.objects(): Sequence<JsonObject> = sequence {
        when (val element = this@objects) {
            is JsonObject -> {
                yield(element)
                element.values.forEach { yieldAll(it.objects()) }
            }
            is JsonArray -> element.forEach { yieldAll(it.objects()) }
            else -> Unit
        }
    }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

    private fun assertNoExtractedText(captured: Captured) {
        assertFalse(
            "A file uploaded natively must not also be injected as extracted text",
            captured.body.toString().contains(EXTRACTED_PLACEHOLDER),
        )
        assertTrue(captured.body.toString().contains(QUESTION))
    }

    @Test
    fun `openai responses carries the pdf as an input_file`() = runTest {
        val modelId = modelId("openai", "gpt-4.1-mini")
        catalogWithNativePdf(ProviderKind.OpenAI, modelId)

        val captured = capture { client ->
            OpenAIService(client = client, json = json, transportRegistry = transportRegistry).sendMessageStream(
                apiKey = "sk-test",
                modelID = modelId,
                messages = question(ProviderKind.OpenAI, modelId),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(),
            ).toList()
        }

        assertTrue(captured.path, captured.path.endsWith("/responses"))
        val block = captured.body.objects().single { it.string("type") == "input_file" }
        assertEquals("marker.pdf", block.string("filename"))
        assertEquals("data:$PDF_MIME;base64,$pdfBase64", block.string("file_data"))
        assertNoExtractedText(captured)
        export("openai-responses", captured)
    }

    @Test
    fun `anthropic messages carries the pdf as a document block`() = runTest {
        val modelId = modelId("anthropic", "claude-haiku-4-5")
        catalogWithNativePdf(ProviderKind.Anthropic, modelId)

        val captured = capture { client ->
            AnthropicService(client, json, transportRegistry).sendMessageStream(
                apiKey = "sk-test",
                modelID = modelId,
                messages = question(ProviderKind.Anthropic, modelId),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(),
            ).toList()
        }

        assertTrue(captured.path, captured.path.endsWith("/messages"))
        val block = captured.body.objects().single { it.string("type") == "document" }
        val source = block.getValue("source").jsonObject
        assertEquals("base64", source.string("type"))
        assertEquals(PDF_MIME, source.string("media_type"))
        assertEquals(pdfBase64, source.string("data"))
        assertNoExtractedText(captured)
        export("anthropic-messages", captured)
    }

    @Test
    fun `gemini generateContent carries the pdf as inlineData`() = runTest {
        val modelId = modelId("gemini", "gemini-2.5-flash")
        catalogWithNativePdf(ProviderKind.Gemini, modelId)

        val captured = capture { client ->
            GeminiService(client, json, transportRegistry).sendMessageStream(
                apiKey = "sk-test",
                modelID = modelId,
                messages = question(ProviderKind.Gemini, modelId),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(),
            ).toList()
        }

        assertTrue(captured.path, captured.path.contains("$modelId:") && captured.path.contains("enerateContent"))
        val inline = captured.body.objects().mapNotNull { it["inlineData"] as? JsonObject }.single()
        assertEquals(PDF_MIME, inline.string("mimeType"))
        assertEquals(pdfBase64, inline.string("data"))
        assertNoExtractedText(captured)
        export("gemini-generate-content", captured)
    }

    @Test
    fun `openrouter chat completions carries the pdf as a file part when the model whitelists it`() = runTest {
        val modelId = modelId("openrouter", "openai/gpt-4.1-mini")
        val activeModel = AIModel(
            id = modelId,
            name = modelId,
            capabilities = listOf(ModelCapability.Text, ModelCapability.File),
            nativeFileMimes = listOf(PDF_MIME),
            pdfNativeDefault = true,
        )

        val captured = capture { client ->
            OpenRouterService(client, json, transportRegistry).sendMessageStream(
                apiKey = "sk-test",
                modelID = modelId,
                messages = question(ProviderKind.OpenRouter, modelId),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(activeModel = activeModel),
            ).toList()
        }

        assertTrue(captured.path, captured.path.endsWith("/chat/completions"))
        val part = captured.body.objects().single { it.string("type") == "file" }
        val file = part.getValue("file").jsonObject
        assertEquals("marker.pdf", file.string("filename"))
        assertEquals("data:$PDF_MIME;base64,$pdfBase64", file.string("file_data"))
        assertNoExtractedText(captured)
        export("openrouter-chat-completions", captured)
    }

    /**
     * The previous test uses a hand-built model object. In production the OpenRouter route works attachments out from the entry in the model list,
     * and that entry only comes from the [CatalogModelBuilder] build and refresh: both must carry the catalog allowlist.
     */
    @Test
    fun `openrouter carries the pdf as a file part for a model that came through the catalog build path`() = runTest {
        val modelId = "openai/gpt-4.1-mini"
        catalogWithNativePdf(ProviderKind.OpenRouter, modelId)
        val built = CatalogModelBuilder.buildCatalogModel(ProviderKind.OpenRouter, modelId, modelId)
        val refreshed = CatalogModelBuilder.enrichStoredModel(AIModel(id = modelId, name = modelId), ProviderKind.OpenRouter)

        for (activeModel in listOf(built, refreshed)) {
            val captured = capture { client ->
                OpenRouterService(client, json, transportRegistry).sendMessageStream(
                    apiKey = "sk-test",
                    modelID = modelId,
                    messages = question(ProviderKind.OpenRouter, modelId),
                    baseUrl = null,
                    supportsImageGen = false,
                    reasoningMode = ReasoningMode.Automatic,
                    webSearchEnabled = false,
                    requestOptions = ChatRequestOptions(activeModel = activeModel),
                ).toList()
            }

            val part = captured.body.objects().single { it.string("type") == "file" }
            assertEquals("data:$PDF_MIME;base64,$pdfBase64", part.getValue("file").jsonObject.string("file_data"))
            assertNoExtractedText(captured)
        }
    }

    @Test
    fun `openrouter keeps injecting text when the model does not whitelist the mime`() = runTest {
        val activeModel = AIModel(
            id = "vendor/text-only",
            name = "Text only",
            capabilities = listOf(ModelCapability.Text, ModelCapability.File),
        )

        val captured = capture { client ->
            OpenRouterService(client, json, transportRegistry).sendMessageStream(
                apiKey = "sk-test",
                modelID = activeModel.id,
                messages = question(ProviderKind.OpenRouter, activeModel.id),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(activeModel = activeModel),
            ).toList()
        }

        assertNull(captured.body.objects().firstOrNull { it.string("type") == "file" })
        assertFalse(captured.body.toString().contains(pdfBase64))
        assertTrue(captured.body.toString().contains(EXTRACTED_PLACEHOLDER))
    }

    @Test
    fun `the marker pdf is a well formed single page document`() {
        val text = pdfBytes.toString(Charsets.ISO_8859_1)
        assertTrue(text.startsWith("%PDF-1.4"))
        assertTrue(text.contains("($MARKER) Tj"))
        val startXref = text.substringAfter("startxref\n").substringBefore("\n").toInt()
        assertTrue(text.substring(startXref).startsWith("xref"))
        // Every offset in the cross-reference table points at the start of its object.
        val offsets = text.substring(startXref).lines().drop(3).take(5).map { it.substring(0, 10).toInt() }
        offsets.forEachIndexed { index, offset ->
            assertTrue("object ${index + 1}", text.substring(offset).startsWith("${index + 1} 0 obj"))
        }
    }

    private companion object {
        const val MARKER = "ORIVEO-PDF-MARKER-7391"
        const val QUESTION = "What is the marker word in this PDF? Answer with the marker word only."
        const val PDF_MIME = "application/pdf"
        const val EXTRACTED_PLACEHOLDER = "client-extracted-text-placeholder"
        val CREDENTIAL_HEADERS = setOf("authorization", "x-api-key", "x-goog-api-key", "api-key")

        /** A hand-assembled minimal single-page PDF: one line of Helvetica text, with the cross-reference table generated from the actual offsets. */
        fun minimalPdf(text: String): ByteArray {
            val content = "BT /F1 24 Tf 72 720 Td ($text) Tj ET"
            val objects = listOf(
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " +
                    "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                "<< /Length ${content.length} >>\nstream\n$content\nendstream",
            )
            val out = StringBuilder("%PDF-1.4\n")
            val offsets = objects.mapIndexed { index, body ->
                val offset = out.length
                out.append("${index + 1} 0 obj\n$body\nendobj\n")
                offset
            }
            val xref = out.length
            out.append("xref\n0 ${objects.size + 1}\n0000000000 65535 f \n")
            offsets.forEach { out.append("%010d 00000 n \n".format(it)) }
            out.append("trailer\n<< /Size ${objects.size + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n")
            return out.toString().toByteArray(Charsets.ISO_8859_1)
        }
    }
}
