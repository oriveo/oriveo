package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
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
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
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
import java.io.File

class GeminiServiceTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry =
        ai.oriveo.community.core.provider.transport.TransportRegistry(json)

    // An HttpClient owns a SupervisorJob and an engine thread pool, so it stays alive until it is closed. Running the
    // suite serially with forkEvery=1 hides that, because the process exits with the class; as soon as tests run in
    // parallel several classes share one process and threads plus memory grow linearly with the number of cases.
    private val openClients = mutableListOf<HttpClient>()

    private fun mockClient(engine: MockEngine): HttpClient =
        HttpClient(engine).also { openClients.add(it) }

    private fun requestBodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        openClients.forEach { it.close() }
        openClients.clear()
    }

    @Test
    fun `syncProvider validates key and returns empty models`() = runTest {
        // The service only validates the key and drives the transport; the model list is assembled by ProviderRepository
        // from the catalog metadata.
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Gemini,
                defaultModelId = "gemini-2.5-flash",
                resolveMap = mapOf("gemini-2.5-flash" to "gemini-2.5-flash"),
                models = listOf(
                    MetadataTestFixtures.ModelSpec("gemini-2.5-flash", displayName = "Gemini 2.5 Flash"),
                ),
            )
        )

        val client = mockClient(MockEngine { respond("{}", HttpStatusCode.OK) })
        val service = GeminiService(client, json, transportRegistry)

        val result = service.syncProvider(apiKey = "sk-test", preferredModelID = " gemini-2.5-pro ", baseUrl = null)

        assertTrue(result.models.isEmpty())
    }

    @Test
    fun `sendMessageStream parses text image chunks and cost`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Gemini,
                defaultModelId = "gemini-2.5-flash",
                resolveMap = mapOf("gemini-2.5-flash" to "gemini-2.5-flash"),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        id = "gemini-2.5-flash",
                        promptPerToken = 0.001,
                        completionPerToken = 0.002,
                    ),
                ),
            )
        )

        val stream = buildString {
            appendLine(ProviderTestFixtures.geminiChunk(text = "hello", promptTokens = 7, completionTokens = 11))
            appendLine(ProviderTestFixtures.geminiChunk(text = "", inlineData = "AQID", promptTokens = 7, completionTokens = 11))
        }

        val client = mockClient(
            MockEngine {
                respond(
                    content = stream,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        val service = GeminiService(client, json, transportRegistry)
        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "gemini-2.5-flash",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Gemini, "gemini-2.5-flash")),
            baseUrl = null,
            supportsImageGen = true,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals(2, events.size)
        assertEquals("hello", (events[0] as StreamEvent.Delta).text)

        val done = events.last() as StreamEvent.Done
        assertEquals("hello", done.result.text)
        assertEquals(7, done.result.promptTokens)
        assertEquals(11, done.result.completionTokens)
        assertEquals(0.001 * 7 + 0.002 * 11, done.result.estimatedCost, 1e-9)
        assertEquals(1, done.result.attachments?.size)
        assertEquals(AttachmentKind.Image, done.result.attachments?.first()?.kind)
        assertEquals("AQID", done.result.attachments?.first()?.base64Data)
    }

    @Test
    fun `legacy Gemini profiles do not inject thinking or web params without exact runtime`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "reasoning": {
                  "gem_future": {
                    "levels": ["max"],
                    "params": {
                      "max": { "generationConfig": { "thinkingConfig": { "thinkingBudget": 7777 } } }
                    }
                  }
                },
                "webSearch": {
                  "gem_future_web": {
                    "mergeParams": { "tools": [{ "googleSearch": { "mode": "server" } }] }
                  }
                }
              },
              "providers": {
                "gemini": {
                  "defaultModelId": "gemini-test",
                  "resolveMap": { "gemini-test": "gemini-test" },
                  "models": {
                    "gemini-test": {
                      "canonicalModelId": "gemini-test",
                      "transport": "gemini_generate",
                      "capabilities": ["web"],
                      "profiles": {
                        "reasoning": "gem_future",
                        "webSearch": "gem_future_web"
                      }
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
        var requestBody = ""
        val client = mockClient(
            MockEngine { request ->
                requestBody = requestBodyText(request.body)
                respond(
                    content = "",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        GeminiService(client, json, transportRegistry).sendMessageStream(
            apiKey = "sk-test",
            modelID = "gemini-test",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Gemini, "gemini-test")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Max,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertFalse(requestBody.contains(""""thinkingBudget":7777"""))
        assertFalse(requestBody.contains(""""mode":"server""""))
        assertFalse(requestBody.contains(""""thinkingLevel":"HIGH""""))
    }

    @Test
    fun `sendMessageStream does not inject Gemini web fallback without profile`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "providers": {
                "gemini": {
                  "defaultModelId": "gemini-test",
                  "resolveMap": { "gemini-test": "gemini-test" },
                  "models": {
                    "gemini-test": { "canonicalModelId": "gemini-test" }
                  }
                }
              }
            }
            """.trimIndent()
        )
        var requestBody = ""
        val client = mockClient(
            MockEngine { request ->
                requestBody = requestBodyText(request.body)
                respond(
                    content = "",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        GeminiService(client, json, transportRegistry).sendMessageStream(
            apiKey = "sk-test",
            modelID = "gemini-test",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Gemini, "gemini-test")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Deep,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertFalse(requestBody.contains("googleSearch"))
        assertFalse(requestBody.contains("thinkingConfig"))
    }

    @Test
    fun `Gemini image profile remains but unknown generation control omits max output tokens`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "generation": {
                  "parameters": {
                    "max_output_tokens": { "valueSchema": "integer" }
                  },
                  "templates": {
                    "gemini_generate": {
                      "transport": "gemini_generate",
                      "wire": { "max_output_tokens": "generationConfig.maxOutputTokens" }
                    }
                  }
                },
                "imageGen": {
                  "gem_image_future": {
                    "mergeParams": {
                      "generationConfig": {
                        "responseModalities": ["TEXT", "IMAGE"],
                        "serverImageProfile": true
                      }
                    }
                  }
                }
              },
              "providers": {
                "gemini": {
                  "defaultModelId": "gemini-image-test",
                  "resolveMap": { "gemini-image-test": "gemini-image-test" },
                  "models": {
                    "gemini-image-test": {
                      "canonicalModelId": "gemini-image-test",
                      "transport": "gemini_generate",
                      "capabilities": ["image"],
                      "profiles": {
                        "imageGen": "gem_image_future",
                        "generation": {
                          "template": "gemini_generate",
                          "parameters": [
                            {
                              "id": "max_output_tokens",
                              "support": "supported",
                              "source": "authoritative_metadata"
                            }
                          ]
                        }
                      }
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
        var requestBody = ""
        val client = mockClient(
            MockEngine { request ->
                requestBody = requestBodyText(request.body)
                respond(
                    content = "",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        GeminiService(client, json, transportRegistry).sendMessageStream(
            apiKey = "sk-test",
            modelID = "gemini-image-test",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Gemini, "gemini-image-test")),
            baseUrl = null,
            supportsImageGen = true,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(maxTokens = 2048),
        ).toList()

        assertTrue(requestBody.contains(""""responseModalities":["TEXT","IMAGE"]"""))
        assertTrue(requestBody.contains(""""serverImageProfile":true"""))
        assertFalse(requestBody.contains(""""maxOutputTokens":2048"""))
    }

    @Test
    fun `Interactions sends full Step history without continuation for stream and nonstream`() = runTest {
        val root = File(System.getProperty("user.dir")).absoluteFile.parentFile!!.parentFile!!
        val registry = json.parseToJsonElement(File(root, "shared/capabilityrecipe/capability_runtime.v1.json").readText()).jsonObject
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:interactions-test"),
            "generatedAt" to JsonPrimitive("2026-08-11T00:00:00Z"),
        ))
        MetadataTestFixtures.applyRaw(buildJsonObject {
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
        }.toString())
        val history = listOf(
            ProviderTestFixtures.userMessage("old", ProviderKind.Gemini, "gemini-3-flash"),
            ChatMessage("a1", ChatRole.Assistant, "prior", providerKind = ProviderKind.Gemini, providerName = "Gemini", modelName = "gemini", state = ChatMessageState.Delivered),
            ProviderTestFixtures.userMessage("new", ProviderKind.Gemini, "gemini-3-flash"),
        )

        suspend fun run(stream: Boolean): Pair<JsonObject, List<StreamEvent>> {
            var captured = ""
            val client = mockClient(MockEngine { request ->
                assertEquals("/v1beta/interactions", request.url.encodedPath)
                captured = requestBodyText(request.body)
                if (stream) respond(
                    """
                        data: {"event_type":"interaction.created","interaction":{"id":"early","status":"in_progress"}}

                        data: {"event_type":"step.delta","index":0,"delta":{"type":"thought_signature","signature":"sig"}}

                        data: {"event_type":"step.delta","index":1,"delta":{"type":"text","text":"streamed"}}

                        data: {"event_type":"interaction.completed","interaction":{"id":"int-stream","status":"completed","usage":{"total_input_tokens":2,"total_output_tokens":3}}}

                        data: [DONE]
                    """.trimIndent(), HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"),
                ) else respond(
                    """{"id":"int-nonstream","status":"completed","steps":[{"type":"thought","content":[{"text":"hidden"}]},{"type":"model_output","content":[{"text":"complete"}]}],"usage":{"total_input_tokens":4,"total_output_tokens":5}}""",
                    HttpStatusCode.OK,
                )
            })
            val service = GeminiService(client, json, transportRegistry)
            val events = if (stream) service.sendMessageStream(
                "key", "gemini-3-flash", history, null, false, ReasoningMode.Automatic, true,
                ChatRequestOptions(systemPrompt = "system"),
            ).toList() else {
                val emitted = mutableListOf<StreamEvent>()
                val done = service.sendMessage(
                    "key", "gemini-3-flash", history, null, false, ReasoningMode.Automatic, true,
                    ChatRequestOptions(systemPrompt = "system"),
                )
                emitted += done; emitted
            }
            return json.parseToJsonElement(captured).jsonObject to events
        }

        val (streamBody, streamEvents) = run(true)
        assertEquals(true, streamBody["stream"]!!.jsonPrimitive.content.toBoolean())
        assertEquals("system", streamBody["system_instruction"]!!.jsonPrimitive.content)
        val steps = streamBody["input"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("user_input", "model_output", "user_input"), steps.map { it["type"]!!.jsonPrimitive.content })
        assertEquals("prior", steps[1]["content"]!!.jsonArray.single().jsonObject["text"]!!.jsonPrimitive.content)
        assertEquals("false", streamBody["store"]!!.jsonPrimitive.content)
        assertFalse(streamBody.toString(), "previous_interaction_id" in streamBody || "role" in steps[1] || "parts" in steps[1])
        assertEquals("streamed", streamEvents.filterIsInstance<StreamEvent.Delta>().joinToString("") { it.text })
        assertTrue(streamEvents.none { it is StreamEvent.RecipeContinuation })

        val (nonstreamBody, nonstreamEvents) = run(false)
        assertEquals(false, nonstreamBody["stream"]!!.jsonPrimitive.content.toBoolean())
        assertEquals(3, nonstreamBody["input"]!!.jsonArray.size)
        assertFalse("previous_interaction_id" in nonstreamBody)
        assertEquals("complete", (nonstreamEvents.last() as StreamEvent.Done).result.text)
    }

    // Guards against silent zero-output and truncated streams.
    // Gemini signals a content-policy stop through fields inside a 2xx stream (promptFeedback.blockReason and
    // candidates[].finishReason), so failing to raise on them lets an empty or truncated reply masquerade as a
    // normal completion.

    private fun streamService(stream: String): GeminiService {
        val client = mockClient(
            MockEngine {
                respond(
                    content = stream,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        return GeminiService(client, json, transportRegistry)
    }

    private suspend fun collectStream(
        service: GeminiService,
        events: MutableList<StreamEvent>,
    ): ProviderServiceError? = try {
        service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "gemini-2.5-flash",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Gemini, "gemini-2.5-flash")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(),
        ).collect { events.add(it) }
        null
    } catch (e: ProviderServiceError) {
        e
    }

    @Test
    fun `sendMessageStream throws when prompt is blocked by blockReason`() = runTest {
        // A wholly blocked prompt usually comes back with no candidates and no output at all, which has to raise rather
        // than produce an empty Done
        val stream = """data: {"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}""" + "\n"
        val events = mutableListOf<StreamEvent>()
        val thrown = collectStream(streamService(stream), events)

        val upstream = thrown as? ProviderServiceError.Upstream
            ?: throw AssertionError("expected an Upstream error, got ${thrown?.let { it::class.simpleName } ?: "no error at all"}")
        assertEquals(200, upstream.statusCode)
        assertTrue(upstream.detail.contains("PROHIBITED_CONTENT"))
        assertTrue(events.none { it is StreamEvent.Done })
    }

    @Test
    fun `sendMessageStream throws when finishReason is SAFETY`() = runTest {
        val stream = buildString {
            appendLine("""data: {"candidates":[{"content":{"parts":[{"text":"par"}]}}]}""")
            appendLine("""data: {"candidates":[{"finishReason":"SAFETY"}]}""")
        }
        val events = mutableListOf<StreamEvent>()
        val thrown = collectStream(streamService(stream), events)

        val upstream = thrown as? ProviderServiceError.Upstream
            ?: throw AssertionError("expected an Upstream error, got ${thrown?.let { it::class.simpleName } ?: "no error at all"}")
        assertEquals(200, upstream.statusCode)
        assertTrue(upstream.detail.contains("SAFETY"))
        // Text already emitted before the throw is kept so the failure path upstream can still render it, but a Done event
        // claiming normal completion is never allowed
        assertTrue(events.any { it is StreamEvent.Delta })
        assertTrue(events.none { it is StreamEvent.Done })
    }

    @Test
    fun `sendMessageStream treats STOP finishReason as normal completion`() = runTest {
        // STOP, MAX_TOKENS and a null finishReason are all normal completions and must not be caught by the guard
        val stream = """data: {"candidates":[{"content":{"parts":[{"text":"hello"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":11}}""" + "\n"
        val events = mutableListOf<StreamEvent>()
        val thrown = collectStream(streamService(stream), events)

        if (thrown != null) throw AssertionError("a normal completion must not raise, got ${thrown::class.simpleName}")
        assertEquals("hello", (events.first() as StreamEvent.Delta).text)
        val done = events.last() as StreamEvent.Done
        assertEquals("hello", done.result.text)
        assertEquals(7, done.result.promptTokens)
        assertEquals(11, done.result.completionTokens)
    }

    // ── File attachments on the Interactions route ──────────────────────────────────

    private fun applyInteractionsMetadata() {
        val root = File(System.getProperty("user.dir")).absoluteFile.parentFile!!.parentFile!!
        val registry = json.parseToJsonElement(File(root, "shared/capabilityrecipe/capability_runtime.v1.json").readText()).jsonObject
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:interactions-test"),
            "generatedAt" to JsonPrimitive("2026-08-11T00:00:00Z"),
        ))
        MetadataTestFixtures.applyRaw(buildJsonObject {
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
        }.toString())
    }

    private fun interactionsTextFile(name: String, content: String) = ai.oriveo.community.core.model.Attachment(
        id = name,
        kind = AttachmentKind.File,
        fileName = name,
        mimeType = "text/plain",
        base64Data = java.util.Base64.getEncoder().encodeToString(content.toByteArray()),
    )

    @Test
    fun `Interactions carries attached files as injected text`() = runTest {
        applyInteractionsMetadata()
        val attachments = listOf(interactionsTextFile("notes.txt", "interactions file body"))
        val message = ProviderTestFixtures.userMessage("read this", ProviderKind.Gemini, "gemini-3-flash")
            .copy(attachments = attachments)
        var path = ""
        var captured = ""
        val client = mockClient(MockEngine { request ->
            path = request.url.encodedPath
            captured = requestBodyText(request.body)
            respond("""{"id":"int-1","status":"completed","steps":[{"type":"model_output","content":[{"text":"ok"}]}]}""", HttpStatusCode.OK)
        })

        GeminiService(client, json, transportRegistry).sendMessage(
            "key", "gemini-3-flash", listOf(message), null, false, ReasoningMode.Automatic, true, ChatRequestOptions(),
        )

        assertEquals("/v1beta/interactions", path)
        val expected = ai.oriveo.community.core.attachments.AttachmentInjector.injectAll(
            userText = "read this",
            attachments = MessageBuilder.toAttachmentPayloads(attachments),
            wrapper = ai.oriveo.community.core.attachments.AttachmentWrapperVersion.XmlV1,
        ).text
        assertTrue(expected, expected.contains("interactions file body"))
        val content = json.parseToJsonElement(captured).jsonObject["input"]!!.jsonArray.single().jsonObject["content"]!!.jsonArray
        assertEquals(expected, content.single().jsonObject["text"]!!.jsonPrimitive.content)
    }

    /** The Interactions route sends text only: images are rewritten to a placeholder and no inlineData is sent. */
    @Test
    fun `Interactions writes a placeholder for attached images instead of inlineData parts`() = runTest {
        applyInteractionsMetadata()
        val image = ai.oriveo.community.core.model.Attachment(
            id = "img", kind = AttachmentKind.Image, fileName = "p.png", mimeType = "image/png", base64Data = "aW1hZ2U=",
        )
        val message = ProviderTestFixtures.userMessage("what is this", ProviderKind.Gemini, "gemini-3-flash")
            .copy(attachments = listOf(image, interactionsTextFile("notes.txt", "file body")))
        var captured = ""
        val client = mockClient(MockEngine { request ->
            captured = requestBodyText(request.body)
            respond("""{"id":"int-1","status":"completed","steps":[{"type":"model_output","content":[{"text":"ok"}]}]}""", HttpStatusCode.OK)
        })

        GeminiService(client, json, transportRegistry).sendMessage(
            "key", "gemini-3-flash", listOf(message), null, false, ReasoningMode.Automatic, true, ChatRequestOptions(),
        )

        val content = json.parseToJsonElement(captured).jsonObject["input"]!!.jsonArray.single().jsonObject["content"]!!.jsonArray
        val text = content.single().jsonObject["text"]!!.jsonPrimitive.content
        assertTrue(text, text.contains("what is this\n\n[Image omitted: this route sends text only]"))
        assertTrue(text, text.contains("file body"))
        assertFalse(captured, captured.contains("inlineData"))
        assertFalse(captured, captured.contains("aW1hZ2U="))
    }

    /** Usage accounting: input includes cached tokens, cached tokens are recorded separately (not written when unreported), output = output + thought. */
    @Test
    fun `Interactions usage splits cached input and counts thought tokens as output`() = runTest {
        applyInteractionsMetadata()
        suspend fun done(usage: String): StreamEvent.Done {
            val client = mockClient(MockEngine {
                respond(
                    """
                        data: {"event_type":"step.delta","index":0,"delta":{"type":"text","text":"ok"}}

                        data: {"event_type":"interaction.completed","interaction":{"id":"i","status":"completed","usage":$usage}}

                        data: [DONE]
                    """.trimIndent(), HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            })
            return GeminiService(client, json, transportRegistry).sendMessageStream(
                "key", "gemini-3-flash", listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Gemini, "gemini-3-flash")),
                null, false, ReasoningMode.Automatic, true, ChatRequestOptions(),
            ).toList().last() as StreamEvent.Done
        }

        val cached = done("""{"total_input_tokens":100,"total_cached_tokens":40,"total_output_tokens":10,"total_thought_tokens":5}""")
        assertEquals(100, cached.result.promptTokens)
        assertEquals(40, cached.result.cachedInputTokens)
        assertEquals(15, cached.result.completionTokens)

        val unreported = done("""{"total_input_tokens":100,"total_output_tokens":10}""")
        assertEquals(null, unreported.result.cachedInputTokens)
        assertEquals(10, unreported.result.completionTokens)
    }

    /** The non-streaming path shares the stream's wrap-up: same usage accounting, and a non-completed status throws even when it carries text. */
    @Test
    fun `Interactions nonstream shares usage and terminal status with the stream parser`() = runTest {
        applyInteractionsMetadata()
        suspend fun send(body: String): Result<StreamEvent.Done> {
            val client = mockClient(MockEngine { respond(body, HttpStatusCode.OK) })
            return runCatching {
                GeminiService(client, json, transportRegistry).sendMessage(
                    "key", "gemini-3-flash", listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Gemini, "gemini-3-flash")),
                    null, false, ReasoningMode.Automatic, true, ChatRequestOptions(),
                )
            }
        }
        val steps = """"steps":[{"type":"thought","content":[{"text":"hidden"}]},{"type":"model_output","content":[{"type":"text","text":"answer"}]}]"""

        val done = send("""{"id":"i","status":"completed",$steps,"usage":{"total_input_tokens":11,"total_cached_tokens":0,"total_output_tokens":90,"total_thought_tokens":245}}""").getOrThrow()
        assertEquals("answer", done.result.text)
        assertEquals(11, done.result.promptTokens)
        assertEquals(90 + 245, done.result.completionTokens)
        assertEquals(0, done.result.cachedInputTokens)

        listOf(
            "failed" to "interaction_failed",
            "cancelled" to "interaction_cancelled",
            "requires_action" to "interaction_requires_action",
            "mystery" to "interaction_stream_closed",
        ).forEach { (status, code) ->
            val error = send("""{"id":"i","status":"$status",$steps}""").exceptionOrNull()
            assertTrue("$status -> $error", error is ProviderServiceError.Upstream && error.toString().contains(code))
        }
    }

    /** A request carrying a video does not take the Interactions route (it does not accept video at first release): the whole request stays on generateContent and the video arrives as inlineData. */
    @Test
    fun `video attachment keeps the request on generateContent with inline video`() = runTest {
        applyInteractionsMetadata()
        val video = ai.oriveo.community.core.model.Attachment(
            id = "vid", kind = AttachmentKind.Video, fileName = "clip.mp4", mimeType = "video/mp4", base64Data = "dmlkZW8=",
        )
        val message = ProviderTestFixtures.userMessage("watch this", ProviderKind.Gemini, "gemini-3-flash")
            .copy(attachments = listOf(video))
        var captured = ""
        var path = ""
        val client = mockClient(MockEngine { request ->
            captured = requestBodyText(request.body)
            path = request.url.encodedPath
            respond("""{"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]},"finishReason":"STOP"}]}""", HttpStatusCode.OK)
        })

        GeminiService(client, json, transportRegistry).sendMessage(
            "key", "gemini-3-flash", listOf(message), null, false, ReasoningMode.Automatic, true, ChatRequestOptions(),
        )

        assertTrue(path, path.endsWith(":generateContent"))
        val body = json.parseToJsonElement(captured).jsonObject
        assertFalse(captured, "input" in body || "store" in body)
        val inline = body["contents"]!!.jsonArray.flatMap { it.jsonObject["parts"]!!.jsonArray }
            .mapNotNull { it.jsonObject["inlineData"]?.jsonObject }
        assertEquals(listOf("video/mp4" to "dmlkZW8="), inline.map { it["mimeType"]!!.jsonPrimitive.content to it["data"]!!.jsonPrimitive.content })
    }

    @Test
    fun `Interactions refuses before the network when an attached file cannot be delivered`() = runTest {
        applyInteractionsMetadata()
        val big = "x".repeat(150 * 1024)
        val message = ProviderTestFixtures.userMessage("read this", ProviderKind.Gemini, "gemini-3-flash")
            .copy(attachments = listOf(interactionsTextFile("a.txt", big), interactionsTextFile("b.txt", big)))
        var requests = 0
        val client = mockClient(MockEngine { requests += 1; respond("{}", HttpStatusCode.OK) })

        try {
            GeminiService(client, json, transportRegistry).sendMessage(
                "key", "gemini-3-flash", listOf(message), null, false, ReasoningMode.Automatic, true, ChatRequestOptions(),
            )
            org.junit.Assert.fail("A current turn with a file that does not fit should be blocked")
        } catch (error: ProviderServiceError.AttachmentTextOverLimit) {
            assertEquals(listOf("b.txt"), error.fileNames)
        }
        assertEquals(0, requests)
    }
}
