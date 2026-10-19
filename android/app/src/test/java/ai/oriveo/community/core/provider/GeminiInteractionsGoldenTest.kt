package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
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
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Shared golden (gemini_interactions.request-golden.v1.json) and SSE fixtures (recorded/gemini_interactions_*.sse)
 * drive the production builder / parser. Case names are shared across platforms: golden case id, SSE file name without extension, GI_PATH_FROM_RECIPE.
 */
class GeminiInteractionsGoldenTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val openClients = mutableListOf<HttpClient>()

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        openClients.forEach { it.close() }
        openClients.clear()
    }

    // ── golden: request body ──────────────────────────────────────────

    @Test fun GI_TEXT_SINGLE() = assertGolden("GI_TEXT_SINGLE")
    @Test fun GI_MULTI_TURN_SYSTEM() = assertGolden("GI_MULTI_TURN_SYSTEM")
    @Test fun GI_WEB_ON() = assertGolden("GI_WEB_ON")
    @Test fun GI_THINKING_AUTOMATIC() = assertGolden("GI_THINKING_AUTOMATIC")
    @Test fun GI_THINKING_OFF() = assertGolden("GI_THINKING_OFF")
    @Test fun GI_THINKING_LOW() = assertGolden("GI_THINKING_LOW")
    @Test fun GI_THINKING_BALANCED() = assertGolden("GI_THINKING_BALANCED")
    @Test fun GI_THINKING_DEEP_WEB_MULTI_TURN() = assertGolden("GI_THINKING_DEEP_WEB_MULTI_TURN")
    @Test fun GI_IMAGE_PRE_ACTIVATION() = assertGolden("GI_IMAGE_PRE_ACTIVATION")
    @Test fun GI_IMAGE_ACTIVATED() = assertGolden("GI_IMAGE_ACTIVATED")
    @Test fun GI_DOCUMENT_ACTIVATED() = assertGolden("GI_DOCUMENT_ACTIVATED")
    @Test fun GI_DOCUMENT_PRE_ACTIVATION() = assertGolden("GI_DOCUMENT_PRE_ACTIVATION")
    @Test fun GI_EMPTY_ASSISTANT_SKIPPED() = assertGolden("GI_EMPTY_ASSISTANT_SKIPPED")

    @Test
    fun GI_PATH_FROM_RECIPE() {
        val service = GeminiService(HttpClient(MockEngine { respond("{}") }).also(openClients::add), json, transportRegistry())
        val route = webRecipeJson()["route"]!!.jsonObject
        fun build(path: String, baseUrl: String?) = service.buildInteractionsRequest(
            apiKey = "key", modelID = "gemini-3.1-flash-lite",
            messages = listOf(ProviderTestFixtures.userMessage("Hello", ProviderKind.Gemini, "gemini-3.1-flash-lite")),
            baseUrl = baseUrl, stream = true, runtime = runtime(),
            route = JsonObject(route + ("path" to JsonPrimitive(path))),
            webRecipe = null, reasoningRecipe = null, reasoningIntent = null,
        ).first

        assertTrue(build("/v1beta/interactions", null).endsWith("/v1beta/interactions"))
        assertEquals("https://relay.example/v1beta/interactions", build("/v1beta/interactions", "https://relay.example/v1"))
        assertEquals("https://relay.example/v1/interactions", build("/v1/interactions", "https://relay.example/v1beta"))
        listOf("/v1/models", "/v1beta/interactions/x", "").forEach { path ->
            try {
                build(path, null)
                fail("non-allowlisted path $path should be a configuration error")
            } catch (_: ProviderServiceError.InvalidConfiguration) {
            }
        }
    }

    // ── replay: SSE ───────────────────────────────────────────────

    @Test fun gemini_interactions_text() = assertReplay("gemini_interactions_text")
    @Test fun gemini_interactions_thought_summary() = assertReplay("gemini_interactions_thought_summary")
    @Test fun gemini_interactions_search_citation() = assertReplay("gemini_interactions_search_citation")
    @Test fun gemini_interactions_error() = assertReplay("gemini_interactions_error")
    @Test fun gemini_interactions_error_after_text() = assertReplay("gemini_interactions_error_after_text")
    @Test fun gemini_interactions_truncated() = assertReplay("gemini_interactions_truncated")
    @Test fun gemini_interactions_incomplete() = assertReplay("gemini_interactions_incomplete")
    @Test fun gemini_interactions_failed() = assertReplay("gemini_interactions_failed")
    @Test fun gemini_interactions_cancelled() = assertReplay("gemini_interactions_cancelled")

    /** The 2026-10-13 real samples (kind=c4_sample in recorded_samples) go through the same parser and comparison helper; measurement is not replayed. */
    @Test
    fun GI_LIVE_RECORDED_SAMPLES() = runTest {
        val manifest = readJson(fixtureDirectory().resolve("recorded/gemini_interactions.expected.json"))
        val samples = (manifest["recorded_samples"] as JsonArray).map { it.jsonObject }.filter { it.str("kind") == "c4_sample" }
        assertEquals(5, samples.size)
        samples.forEach { sample ->
            val name = sample.str("file")!!.removeSuffix(".sse")
            val expected = sample["expected"]!!.jsonObject
            assertTrue("$name text is empty", !expected.str("text").isNullOrEmpty())
            replay(name, expected)
        }
    }

    // ── golden driver ─────────────────────────────────────────────

    private fun assertGolden(id: String) {
        val golden = readJson(fixtureDirectory().resolve("gemini_interactions.request-golden.v1.json"))
        val case = (golden["cases"] as JsonArray).map { it.jsonObject }.single { it.str("id") == id }
        val input = case["input"]!!.jsonObject
        val model = input.str("model")!!
        val reasoningRecipeJson = golden["reasoning_recipe"]!!.jsonObject
        val webRecipe = if (input.bool("web")) selection(webRecipeJson(), null, null) else null
        val reasoningIntent = input.str("reasoning")
        val reasoningRecipe = if (input.bool("reasoning_recipe")) {
            selection(
                reasoningRecipeJson,
                reasoningIntent,
                reasoningRecipeJson["availableIntents"]!!.jsonArray.map { it.jsonPrimitive.content },
            )
        } else null
        val stage = when (input.str("attachment_profile")) {
            "activated" -> GeminiService.InteractionsAttachmentStage.Activated
            else -> GeminiService.InteractionsAttachmentStage.PreActivation
        }
        val messages = (input["messages"] as JsonArray).mapIndexed { index, raw -> message(index, raw.jsonObject, model) }
        val service = GeminiService(HttpClient(MockEngine { respond("{}") }).also(openClients::add), json, transportRegistry())

        val (_, bodyText) = service.buildInteractionsRequest(
            apiKey = "key", modelID = model, messages = messages, baseUrl = null, stream = true,
            runtime = runtime(reasoningRecipeJson),
            route = webRecipeJson()["route"]!!.jsonObject,
            webRecipe = webRecipe,
            reasoningRecipe = reasoningRecipe,
            reasoningIntent = reasoningIntent,
            attachmentStage = stage,
            requestOptions = ChatRequestOptions(systemPrompt = input.str("system").orEmpty()),
        )
        val body = json.parseToJsonElement(bodyText).jsonObject

        assertFalse("$id carries previous_interaction_id: $body", hasKeyAnywhere(body, "previous_interaction_id"))
        assertEquals(id, JsonPrimitive(false), body["store"])
        case["expected_body"]?.let { expected -> assertEquals(id, expected, body) }
        val assertions = case["assertions"] as? JsonObject ?: return
        val steps = body["input"]!!.jsonArray.map { it.jsonObject }
        (assertions["input_step_types"] as? JsonArray)?.let { types ->
            assertEquals(id, types.map { it.jsonPrimitive.content }, steps.map { it.str("type") })
        }
        (assertions["content_types_only"] as? JsonArray)?.let { allowed ->
            val actual = steps.flatMap { step -> step["content"]!!.jsonArray.map { it.jsonObject.str("type") } }.toSet()
            assertEquals(id, allowed.map { it.jsonPrimitive.content }.toSet(), actual)
        }
        (assertions["user_text_contains"] as? JsonArray)?.let { needles ->
            val userText = steps.filter { it.str("type") == "user_input" }
                .flatMap { step -> step["content"]!!.jsonArray.mapNotNull { it.jsonObject.str("text") } }
                .joinToString("\n")
            needles.forEach { needle -> assertTrue("$id user text is missing ${needle.jsonPrimitive.content}: $userText", userText.contains(needle.jsonPrimitive.content)) }
        }
        (assertions["absent_keys_anywhere"] as? JsonArray)?.forEach { key ->
            assertFalse("$id contains ${key.jsonPrimitive.content}: $body", hasKeyAnywhere(body, key.jsonPrimitive.content))
        }
        (assertions["absent_substrings"] as? JsonArray)?.forEach { needle ->
            assertFalse("$id contains ${needle.jsonPrimitive.content}: $bodyText", bodyText.contains(needle.jsonPrimitive.content))
        }
        (assertions["absent_pointers"] as? JsonArray)?.forEach { pointer ->
            assertNull("$id contains ${pointer.jsonPrimitive.content}: $body", resolvePointer(body, pointer.jsonPrimitive.content))
        }
        (assertions["store"] as? JsonPrimitive)?.let { assertEquals(id, it, body["store"]) }
    }

    private fun message(index: Int, raw: JsonObject, model: String): ChatMessage {
        val parts = raw["parts"]!!.jsonArray.map { it.jsonObject }
        val text = parts.filter { it.str("type") == "text" }.joinToString("") { it.str("text").orEmpty() }
        val attachments = parts.mapIndexedNotNull { partIndex, part ->
            when (part.str("type")) {
                "image" -> Attachment(
                    id = "img-$index-$partIndex", kind = AttachmentKind.Image, fileName = "image-$partIndex.png",
                    mimeType = part.str("mime_type")!!, base64Data = part.str("data"),
                )
                // Local file attachment: base64Data is the extracted text (injected when delivered as text) and originalBase64Data is the original file.
                "document" -> Attachment(
                    id = "doc-$index-$partIndex", kind = AttachmentKind.File,
                    fileName = part.str("name") ?: "document-$partIndex.pdf",
                    mimeType = part.str("mime_type")!!,
                    base64Data = part.str("extracted_text")?.let {
                        java.util.Base64.getEncoder().encodeToString(it.toByteArray())
                    },
                    originalBase64Data = part.str("data"),
                )
                else -> null
            }
        }
        return if (raw.str("role") == "assistant") {
            ChatMessage(
                "a-$index", ChatRole.Assistant, text, providerKind = ProviderKind.Gemini, providerName = "Gemini",
                modelID = model, modelName = model, state = ChatMessageState.Delivered,
            )
        } else {
            ProviderTestFixtures.userMessage(text, ProviderKind.Gemini, model)
                .copy(attachments = attachments.ifEmpty { null })
        }
    }

    // ── SSE driver ────────────────────────────────────────────────

    private fun assertReplay(name: String) = runTest {
        val manifest = readJson(fixtureDirectory().resolve("recorded/gemini_interactions.expected.json"))
        val entry = (manifest["fixtures"] as JsonArray).map { it.jsonObject }.single { it.str("file") == "$name.sse" }
        replay(name, entry["expected"]!!.jsonObject)
    }

    private suspend fun replay(name: String, expected: JsonObject) {
        val directory = fixtureDirectory().resolve("recorded")
        val sse = String(Files.readAllBytes(directory.resolve("$name.sse")), Charsets.UTF_8)

        // 1) The production parser consumes frame by frame: text / thinking / citations / evidence / errors / terminal state / usage.
        val parser = GeminiService.InteractionsStreamParser()
        val events = mutableListOf<StreamEvent>()
        var thrown: ProviderServiceError? = null
        for (line in sse.lines()) {
            if (!line.startsWith("data:")) continue
            val payload = line.removePrefix("data:").trim()
            if (payload == "[DONE]") break
            try {
                events += parser.consume(json.parseToJsonElement(payload).jsonObject)
            } catch (error: ProviderServiceError) {
                thrown = error
                break
            }
        }
        // When an error was already thrown the terminal state is settled and finish() just returns it; a stream cut off without a terminal state makes finish() throw.
        try {
            parser.finish()
        } catch (error: ProviderServiceError) {
            thrown = error
        }

        assertEquals(name, expected.str("text"), events.filterIsInstance<StreamEvent.Delta>().joinToString("") { it.text })
        assertEquals(name, expected.str("thinking"), events.filterIsInstance<StreamEvent.Reasoning>().joinToString("") { it.text })
        val citations = events.filterIsInstance<StreamEvent.Citations>().flatMap { it.citations }
        assertEquals(
            name,
            expected["citations"]!!.jsonArray.map {
                val c = it.jsonObject
                listOf(c.str("url"), c.str("title"), c["start_index"]!!.jsonPrimitive.intOrNull, c["end_index"]!!.jsonPrimitive.intOrNull)
            },
            citations.map { listOf(it.url, it.title, it.startIndex, it.endIndex) },
        )
        val evidence = events.filterIsInstance<StreamEvent.ToolResult>()
        assertEquals(
            name,
            expected["search_evidence"]!!.jsonArray.map { "google_search|results=${it.jsonObject["result_count"]!!.jsonPrimitive.content}" },
            evidence.map { "${it.tool}|${it.summary}" },
        )
        // interrupted is treated as an error and throws the same upstream error as failed; the code comes from this table.
        val interruptedCode = INTERRUPTED_CODES[name]
        if (interruptedCode != null) {
            assertEquals(name, "interrupted", expected.str("terminal"))
            assertNotNull("$name interruption should throw", thrown)
            assertEquals(name, interruptedCode, parser.error?.code)
            assertEquals(name, "after_content", parser.error?.phase)
            assertTrue("$name upstream error carries no code: $thrown", thrown.toString().contains(interruptedCode))
        }
        assertEquals(name, expected.str("terminal"), parser.terminal?.wire)
        // Errors thrown on a terminal failure / cancellation / dropped stream carry the finish of the gemini_interactions family
        EXPECTED_ERROR_FINISH[name]?.let { expectedFinish ->
            val finish = (thrown as? ProviderServiceError.Upstream)?.streamFinish
            assertEquals(name, expectedFinish, finish)
            assertEquals(name, "gemini_interactions", finish?.family?.wire)
        }
        val expectedError = expected["error"] as? JsonObject
        if (interruptedCode != null) {
            // Already asserted above
        } else if (expectedError == null) {
            assertNull(name, thrown)
            assertNull(name, parser.error)
        } else {
            assertNotNull(name, thrown)
            val error = requireNotNull(parser.error)
            assertEquals(name, expectedError.str("code"), error.code)
            assertEquals(name, expectedError.str("message"), error.message)
            assertEquals(name, expectedError.str("phase"), error.phase)
            assertTrue("$name upstream error carries no code: $thrown", thrown.toString().contains(expectedError.str("code")!!))
        }
        val expectedUsage = expected["usage"] as? JsonObject
        if (expectedUsage == null) {
            assertNull(name, parser.usage)
        } else {
            val usage = requireNotNull(parser.usage)
            assertEquals(name, expectedUsage["input_total"]!!.jsonPrimitive.intOrNull, usage.inputTokens)
            assertEquals(name, expectedUsage["output_total"]!!.jsonPrimitive.intOrNull, usage.outputTokens)
            assertEquals(name, expectedUsage["reasoning"]!!.jsonPrimitive.intOrNull, usage.thoughtTokens)
        }

        // 2) The whole production chain (Mock HTTP -> SseParser -> parser): the text arrives the same way, and errors throw the local upstream error.
        applyInteractionsMetadata()
        val client = HttpClient(MockEngine { request ->
            assertTrue(request.url.encodedPath, request.url.encodedPath.endsWith("/interactions"))
            respond(sse, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        }).also(openClients::add)
        val streamed = mutableListOf<StreamEvent>()
        val streamError = try {
            GeminiService(client, json, transportRegistry()).sendMessageStream(
                "key", "gemini-3-flash",
                listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Gemini, "gemini-3-flash")),
                null, false, ReasoningMode.Automatic, true, ChatRequestOptions(),
            ).collect { streamed += it }
            null
        } catch (error: ProviderServiceError) {
            error
        }
        assertEquals(name, expected.str("text"), streamed.filterIsInstance<StreamEvent.Delta>().joinToString("") { it.text })
        assertEquals(name, expectedError != null || interruptedCode != null, streamError != null)
        assertTrue(name, streamed.none { it is StreamEvent.RecipeContinuation })
        if (expectedError == null && interruptedCode == null) {
            val done = streamed.last() as StreamEvent.Done
            expectedUsage?.let {
                assertEquals(name, it["input_total"]!!.jsonPrimitive.intOrNull, done.result.promptTokens)
                assertEquals(
                    name,
                    it["output_total"]!!.jsonPrimitive.intOrNull!! + it["reasoning"]!!.jsonPrimitive.intOrNull!!,
                    done.result.completionTokens,
                )
                // The fixtures all report total_cached_tokens=0: once the upstream has reported it, 0 is written; it is not missing.
                assertEquals(name, 0, done.result.cachedInputTokens)
            }
        }
    }

    // ── fixtures and recipe ──────────────────────────────────────

    private fun applyInteractionsMetadata() {
        val runtime = JsonObject(serverRegistry() + mapOf(
            "revision" to JsonPrimitive("sha256:interactions-golden"),
            "generatedAt" to JsonPrimitive("2026-10-13T00:00:00Z"),
        ))
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1); put("capabilityRuntime", runtime)
            put("providers", buildJsonObject { put("gemini", buildJsonObject {
                put("resolveMap", buildJsonObject { put("gemini-3-flash", "gemini-3-flash") })
                put("models", buildJsonObject { put("gemini-3-flash", buildJsonObject {
                    put("transport", "gemini_interactions")
                    put("capabilityControls", buildJsonObject { put("web", buildJsonObject {
                        put("state", "auto_available"); put("recipeRef", WEB_RECIPE)
                    }) })
                }) })
            }) })
        }.toString())
    }

    private fun runtime(vararg extra: JsonObject): JsonObject = JsonObject(mapOf(
        "recipes" to JsonObject(
            mapOf(WEB_RECIPE to webRecipeJson()) + extra.associateBy { it.str("id")!! },
        ),
    ))

    private fun selection(recipe: JsonObject, intent: String?, available: List<String>?) =
        MetadataClient.CapabilityRecipeSelection(
            id = recipe.str("id")!!,
            providerKind = recipe.str("providerKind")!!,
            capability = recipe.str("capability")!!,
            executionKind = recipe.str("executionKind")!!,
            selectedIntent = intent,
            availableIntents = available,
            requestOps = recipe["requestOps"]!!.jsonArray.map {
                val op = it.jsonObject
                MetadataClient.CapabilityRecipeOperation(op.str("op")!!, op.str("pointer"), op.str("intent"), op["value"])
            },
            continuationKind = recipe.str("continuationKind"),
            responseParserKind = recipe.str("responseParserKind"),
            route = recipe["route"] as? JsonObject,
        )

    private fun webRecipeJson(): JsonObject = serverRegistry()["recipes"]!!.jsonObject[WEB_RECIPE]!!.jsonObject

    private fun serverRegistry(): JsonObject = readJson(
        repositoryRoot().resolve("shared/capabilityrecipe/capability_runtime.v1.json"),
    )

    private fun fixtureDirectory(): Path = repositoryRoot().resolve("shared/test-fixtures/provider-toolcall")

    private fun repositoryRoot(): Path = generateSequence(Path.of(System.getProperty("user.dir")).toAbsolutePath()) { it.parent }
        .firstOrNull { Files.exists(it.resolve("shared/test-fixtures/provider-toolcall/gemini_interactions.request-golden.v1.json")) }
        ?: error("Gemini Interactions golden fixtures not found")

    private fun readJson(path: Path): JsonObject =
        json.parseToJsonElement(String(Files.readAllBytes(path), Charsets.UTF_8)).jsonObject

    private fun transportRegistry() = ai.oriveo.community.core.provider.transport.TransportRegistry(json)

    private fun hasKeyAnywhere(element: JsonElement, key: String): Boolean = when (element) {
        is JsonObject -> key in element || element.values.any { hasKeyAnywhere(it, key) }
        is JsonArray -> element.any { hasKeyAnywhere(it, key) }
        else -> false
    }

    private fun resolvePointer(root: JsonElement, pointer: String): JsonElement? =
        pointer.removePrefix("/").split("/").fold(root as JsonElement?) { node, segment -> (node as? JsonObject)?.get(segment) }

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull
    private fun JsonObject.bool(key: String): Boolean = (this[key] as? JsonPrimitive)?.contentOrNull == "true"

    private companion object {
        const val WEB_RECIPE = "gemini.interactions.web.v1"
        val INTERRUPTED_CODES = mapOf(
            "gemini_interactions_cancelled" to "interaction_cancelled",
            "gemini_interactions_truncated" to "interaction_stream_closed",
        )
        val EXPECTED_ERROR_FINISH = mapOf(
            "gemini_interactions_failed" to ai.oriveo.community.core.context.StreamFinish(
                ai.oriveo.community.core.context.StopFamily.GEMINI_INTERACTIONS,
                ai.oriveo.community.core.context.StreamEnding.CLEAN,
                "failed",
            ),
            "gemini_interactions_cancelled" to ai.oriveo.community.core.context.StreamFinish(
                ai.oriveo.community.core.context.StopFamily.GEMINI_INTERACTIONS,
                ai.oriveo.community.core.context.StreamEnding.CLEAN,
                "cancelled",
            ),
            "gemini_interactions_truncated" to ai.oriveo.community.core.context.StreamFinish(
                ai.oriveo.community.core.context.StopFamily.GEMINI_INTERACTIONS,
                ai.oriveo.community.core.context.StreamEnding.EOF_WITHOUT_MARKER,
                null,
            ),
        )
    }
}
