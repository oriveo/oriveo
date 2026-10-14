package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.CapabilityExecutionCollector
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.feature.modelpicker.isModelTransportSupportedForModelPicker
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.headersOf
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The shared fixture gemini_interactions.selection.v1.json drives production route selection: metadata is fed the fixture's
 * model + capability_controls, goes out through GeminiService.sendMessageStream, and the URL and body actually sent are asserted
 * per conventions.assertions. Case names match iOS / Web.
 */
class GeminiInteractionsSelectionTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        openClients.forEach { it.close() }
        openClients.clear()
    }

    @Test fun GI_SEL_REASONING_EXPLICIT() = assertSelection("GI_SEL_REASONING_EXPLICIT")
    @Test fun GI_SEL_REASONING_AUTOMATIC() = assertSelection("GI_SEL_REASONING_AUTOMATIC")
    @Test fun GI_SEL_WEB_OFF_STAYS_GENERATE() = assertSelection("GI_SEL_WEB_OFF_STAYS_GENERATE")
    @Test fun GI_SEL_VIDEO_EXCLUDES_INTERACTIONS() = assertSelection("GI_SEL_VIDEO_EXCLUDES_INTERACTIONS")
    @Test fun GI_SEL_VIDEO_IN_HISTORY_EXCLUDES_INTERACTIONS() = assertSelection("GI_SEL_VIDEO_IN_HISTORY_EXCLUDES_INTERACTIONS")
    @Test fun GI_SEL_VIDEO_WITHOUT_DATA_EXCLUDES_INTERACTIONS() = assertSelection("GI_SEL_VIDEO_WITHOUT_DATA_EXCLUDES_INTERACTIONS")

    /** Models that the Server delivers with transport=gemini_interactions can be decoded and are visible in the catalog and selector, and sending still goes through Gemini dispatch. */
    @Test
    fun `gemini_interactions transport stays visible and dispatches through gemini`() {
        val fixture = readJson(fixtureDirectory().resolve("gemini_interactions.selection.v1.json"))
        val modelID = fixture["model"]!!.jsonObject.str("modelId")!!
        applySelectionMetadata(fixture)

        val kind = TransportKind.fromWireValue("gemini_interactions")
        assertEquals(TransportKind.GeminiInteractions, kind)
        // When Interactions is not selected it falls back to generateContent, with the same strategy as GeminiGenerate.
        assertEquals(TransportKind.GeminiGenerate, TransportRegistry(json).strategy(kind!!).kind)
        val provider = Provider(
            id = "gemini-1", kind = ProviderKind.Gemini, status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = modelID, name = modelID, isAvailable = true, isDefault = true)),
        )
        val catalog = ProviderCatalogResolver.resolve(provider).catalog.map { it.model.id }
        assertTrue("catalog hid $modelID: $catalog", modelID in catalog)
        assertTrue(isModelTransportSupportedForModelPicker(provider, AIModel(id = modelID, name = modelID)))
        assertTrue(GeminiService.interactionsRoute(modelID, true, ReasoningMode.Automatic, historyHasVideo = false) != null)
    }

    /** When the model transport is not gemini_interactions, Interactions is not selected even if the web control points at endpoint_route. */
    @Test
    fun `interactions route requires the model transport to be gemini_interactions`() {
        val fixture = readJson(fixtureDirectory().resolve("gemini_interactions.selection.v1.json"))
        val model = fixture["model"]!!.jsonObject
        applySelectionMetadata(JsonObject(fixture + ("model" to JsonObject(model + ("transport" to JsonPrimitive("gemini_generate"))))))
        assertNull(GeminiService.interactionsRoute(model.str("modelId")!!, true, ReasoningMode.Deep, historyHasVideo = false))
    }

    private fun assertSelection(id: String) = runTest {
        val fixture = readJson(fixtureDirectory().resolve("gemini_interactions.selection.v1.json"))
        val case = fixture["cases"]!!.jsonArray.map { it.jsonObject }.single { it.str("id") == id }
        val input = case["input"]!!.jsonObject
        val expected = case["expected"]!!.jsonObject
        val modelID = fixture["model"]!!.jsonObject.str("modelId")!!
        applySelectionMetadata(fixture)

        val messages = input["messages"]!!.jsonArray.mapIndexed { index, raw -> message(index, raw.jsonObject, modelID) }
        val reasoningMode = when (val intent = input.str("reasoning")) {
            null -> ReasoningMode.Automatic
            else -> requireNotNull(ReasoningMode.fromIntentOrNull(intent)) { "unmapped intent $intent" }
        }
        val webEnabled = (input["web"] as JsonPrimitive).content == "true"
        val route = expected.str("route")

        var url: String? = null
        var bodyText: String? = null
        val client = HttpClient(MockEngine { request ->
            url = request.url.toString()
            bodyText = String((request.body as OutgoingContent.ByteArrayContent).bytes(), Charsets.UTF_8)
            val sse = if (request.url.encodedPath.endsWith("/interactions")) {
                String(Files.readAllBytes(fixtureDirectory().resolve("recorded/gemini_interactions_text.sse")), Charsets.UTF_8)
            } else {
                "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"ok\"}]},\"finishReason\":\"STOP\"}]}\n\n"
            }
            respond(sse, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        }).also(openClients::add)
        val collector = CapabilityExecutionCollector()
        val events = mutableListOf<StreamEvent>()
        GeminiService(client, json, TransportRegistry(json)).sendMessageStream(
            "key", modelID, messages, null, false, reasoningMode, webEnabled,
            ChatRequestOptions(capabilityExecutionCollector = collector),
        ).collect { events += it }
        assertTrue("$id did not finish normally: $events", events.last() is StreamEvent.Done)

        val path = java.net.URI(requireNotNull(url) { "$id has no outbound request" }).path
        val body = json.parseToJsonElement(requireNotNull(bodyText)).jsonObject
        val requestedOwners = collector.requestedResults().map { it.owner }.toSet()
        when (route) {
            "interactions" -> {
                assertTrue("$id path=$path", path.endsWith(expected.str("path_suffix")!!))
                val expectedConfig = expected["generation_config"]
                if (expectedConfig == null || expectedConfig is JsonNull) {
                    assertFalse("$id must not have generation_config: $body", "generation_config" in body)
                } else {
                    assertEquals(id, expectedConfig, body["generation_config"])
                }
                assertEquals(id, expected["tools"], body["tools"])
                // Even if the auto level compiled a thinking recipe it does not count as requested; only an explicit level does.
                val reasoningRequested = input.str("reasoning") != null
                assertEquals("$id requested=$requestedOwners", setOfNotNull("web", "reasoning".takeIf { reasoningRequested }), requestedOwners)
            }
            "generate_content" -> {
                assertTrue("$id path=$path", path.contains(":streamGenerateContent"))
                listOf("input", "store", "generation_config", "tools").forEach { key ->
                    assertFalse("$id body must not have $key: $body", key in body)
                }
                listOf("thinking_summaries", "thinking_level").forEach { key ->
                    assertFalse("$id body must not have $key: $body", hasKeyAnywhere(body, key))
                }
                // The recipe of the gemini_interactions protocol is not compiled and does not count as requested.
                assertFalse("$id requested=$requestedOwners", "web" in requestedOwners || "reasoning" in requestedOwners)
                val videoInline = expected["video_inline"]
                val inline = body["contents"]!!.jsonArray
                    .flatMap { it.jsonObject["parts"]!!.jsonArray }
                    .mapNotNull { it.jsonObject["inlineData"] }
                if (videoInline != null && videoInline !is JsonNull) {
                    assertTrue("$id contents lack the video inlineData: $body", videoInline in inline)
                } else {
                    assertTrue("$id must not have inlineData: $body", inline.isEmpty())
                }
            }
            else -> error("unknown route $route")
        }
    }

    // ── Fixtures and recipes ──────────────────────────────────────────────

    private fun applySelectionMetadata(fixture: JsonObject) {
        val registry = serverRegistry()
        val golden = readJson(fixtureDirectory().resolve("gemini_interactions.request-golden.v1.json"))
        val reasoningRecipe = golden["reasoning_recipe"]!!.jsonObject
        val reasoningId = reasoningRecipe.str("id")!!
        val recipes = registry["recipes"]!!.jsonObject
        // When the registry already has the same id the Server wins (field-by-field consistency with the golden is guarded by Server tests); otherwise the golden entry is installed.
        val withReasoning = if (reasoningId in recipes) recipes else JsonObject(
            recipes + (reasoningId to JsonObject(reasoningRecipe + ("reviewedAt" to JsonPrimitive("2026-10-13")))),
        )
        val runtime = JsonObject(registry + mapOf(
            "recipes" to withReasoning,
            "revision" to JsonPrimitive("sha256:interactions-selection"),
            "generatedAt" to JsonPrimitive("2026-10-13T00:00:00Z"),
        ))
        val model = fixture["model"]!!.jsonObject
        val modelID = model.str("modelId")!!
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1); put("capabilityRuntime", runtime)
            put("providers", buildJsonObject { put("gemini", buildJsonObject {
                put("resolveMap", buildJsonObject { put(modelID, modelID) })
                put("models", buildJsonObject { put(modelID, buildJsonObject {
                    put("transport", model.str("transport")!!)
                    put("capabilities", JsonArray(listOf("text", "vision", "video").map(::JsonPrimitive)))
                    put("capabilityControls", fixture["capability_controls"]!!)
                }) })
            }) })
        }.toString())
    }

    private fun message(index: Int, raw: JsonObject, model: String): ChatMessage {
        val parts = raw["parts"]!!.jsonArray.map { it.jsonObject }
        val text = parts.filter { it.str("type") == "text" }.joinToString("") { it.str("text").orEmpty() }
        val attachments = parts.mapIndexedNotNull { partIndex, part ->
            if (part.str("type") != "video") return@mapIndexedNotNull null
            Attachment(
                id = "video-$index-$partIndex", kind = AttachmentKind.Video, fileName = "clip-$partIndex.mp4",
                mimeType = part.str("mime_type")!!, base64Data = part.str("data"),
            )
        }
        return if (raw.str("role") == "assistant") {
            ChatMessage(
                "a-$index", ChatRole.Assistant, text, providerKind = ProviderKind.Gemini, providerName = "Gemini",
                modelID = model, modelName = model, state = ChatMessageState.Delivered,
            )
        } else {
            ProviderTestFixtures.userMessage(text, ProviderKind.Gemini, model).copy(attachments = attachments.ifEmpty { null })
        }
    }

    private fun serverRegistry(): JsonObject = readJson(
        repositoryRoot().resolve("shared/capabilityrecipe/capability_runtime.v1.json"),
    )

    private fun fixtureDirectory(): Path = repositoryRoot().resolve("shared/test-fixtures/provider-toolcall")

    private fun repositoryRoot(): Path = generateSequence(Path.of(System.getProperty("user.dir")).toAbsolutePath()) { it.parent }
        .firstOrNull { Files.exists(it.resolve("shared/test-fixtures/provider-toolcall/gemini_interactions.selection.v1.json")) }
        ?: error("Gemini Interactions selection fixture not found")

    private fun readJson(path: Path): JsonObject =
        json.parseToJsonElement(String(Files.readAllBytes(path), Charsets.UTF_8)).jsonObject

    private fun hasKeyAnywhere(element: JsonElement, key: String): Boolean = when (element) {
        is JsonObject -> key in element || element.values.any { hasKeyAnywhere(it, key) }
        is JsonArray -> element.any { hasKeyAnywhere(it, key) }
        else -> false
    }

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull
}
