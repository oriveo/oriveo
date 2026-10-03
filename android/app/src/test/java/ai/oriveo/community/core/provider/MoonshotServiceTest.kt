package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamActivity
import ai.oriveo.community.core.model.StreamEvent
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
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

class MoonshotServiceTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry =
        ai.oriveo.community.core.provider.transport.TransportRegistry(json)

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private fun requestBodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    /**
     * Pins the three integration behaviours of the streaming web-search tool loop, and guards
     * against Kimi's thinking output being suppressed:
     * 1. In automatic mode with web search on, the request body carries `tools` but **no
     *    `thinking` block**. Thinking and web search are independent on this upstream; k2.5
     *    and k2.6 have thinking enabled by default, so forcing it to disabled would silence
     *    the reasoning stream.
     * 2. The assistant tool-call message that is fed back must carry `reasoning_content`.
     *    Kimi's contract returns a 400 when thinking is active and that field is missing. The
     *    tool message echoes the arguments back verbatim.
     * 3. Reasoning and content deltas are emitted live across every leg, "\n\n" is inserted
     *    where one leg's reasoning meets the next, and usage is accumulated leg by leg
     *    because each leg is billed on its own.
     */
    @Test
    fun `webSearch streaming tool loop decouples thinking and echoes reasoning_content`() = runTest {
        // A missing runtime entry means zero automatic configuration, so the only source of the
        // builtin $web_search tool is the exact recipe under capabilityRuntime
        // (moonshot.chat.web.v1, executionKind=client_tool_loop). There is no fallback to
        // profiles.webSearch.mergeParams any more: hand this leg only a profile and it emits no
        // tools at all.
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "capabilityRuntime": ${MetadataTestFixtures.capabilityRuntimeJson()},
              "providers": {
                "moonshot": {
                  "defaultModelId": "kimi-k2.5",
                  "resolveMap": { "kimi-k2.5": "kimi-k2.5" },
                  "models": {
                    "kimi-k2.5": {
                      "canonicalModelId": "kimi-k2.5",
                      "transport": "openai_chat",
                      "capabilities": ["web"],
                      "capabilityControls": ${MetadataTestFixtures.capabilityControlsJson(
                        MetadataTestFixtures.ControlSpec(
                            capability = "web",
                            recipeRef = "moonshot.chat.web.v1",
                        ),
                    )}
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
        val leg1 = """
            data: {"choices":[{"delta":{"role":"assistant","content":""}}],"usage":null}

            data: {"choices":[{"delta":{"reasoning_content":"first let me think"}}],"usage":null}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t-1","type":"builtin_function","function":{"name":"${'$'}web_search","arguments":"{\"search"}}]}}],"usage":null}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"_id\":\"abc\"}"}}]}}],"usage":null}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"cached_tokens":2}}

            data: [DONE]
        """.trimIndent()
        val leg2 = """
            data: {"choices":[{"delta":{"reasoning_content":"now to sum up"}}],"usage":null}

            data: {"choices":[{"delta":{"content":"the answer"}}],"usage":null}

            data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":7,"cached_tokens":3}}

            data: [DONE]
        """.trimIndent()

        val requestBodies = mutableListOf<String>()
        val client = HttpClient(
            MockEngine { request ->
                requestBodies.add(requestBodyText(request.body))
                respond(
                    content = if (requestBodies.size == 1) leg1 else leg2,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = MoonshotService(client, json, transportRegistry)

        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "kimi-k2.5",
            messages = listOf(userMessage("what is the weather in Shanghai")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(),
        ).toList()

        // 1. Two legs; automatic mode with web search carries tools but no thinking block.
        assertEquals(2, requestBodies.size)
        assertTrue(requestBodies[0].contains("\"tools\""))
        assertFalse(requestBodies[0].contains("\"thinking\""))

        // 2. The second leg feeds back an assistant echo carrying reasoning_content plus
        // tool_calls, and a tool message that returns the arguments unchanged.
        val secondMessages = json.parseToJsonElement(requestBodies[1]).jsonObject["messages"]!!.jsonArray
        val echo = secondMessages[secondMessages.size - 2].jsonObject
        assertEquals("assistant", echo["role"]!!.jsonPrimitive.content)
        assertEquals("first let me think", echo["reasoning_content"]!!.jsonPrimitive.content)
        assertEquals(1, echo["tool_calls"]!!.jsonArray.size)
        val toolMessage = secondMessages.last().jsonObject
        assertEquals("tool", toolMessage["role"]!!.jsonPrimitive.content)
        assertEquals("t-1", toolMessage["tool_call_id"]!!.jsonPrimitive.content)
        assertEquals("""{"search_id":"abc"}""", toolMessage["content"]!!.jsonPrimitive.content)

        // 3. Event stream: reasoning is emitted live with a separator inserted between legs,
        // and usage accumulates (prompt 10+20 including cached, completion 5+7).
        val reasoning = events.filterIsInstance<StreamEvent.Reasoning>().joinToString("") { it.text }
        assertEquals("first let me think\n\nnow to sum up", reasoning)
        val deltas = events.filterIsInstance<StreamEvent.Delta>().joinToString("") { it.text }
        assertEquals("the answer", deltas)
        val done = events.last() as StreamEvent.Done
        assertEquals("the answer", done.result.text)
        assertEquals("first let me think\n\nnow to sum up", done.result.reasoningText)

        // 4. This leg accepted $web_search, so "web search started" is emitted once before the
        // feed-back: after the first leg's content and before anything from the second leg, whose
        // first delta is what clears it.
        assertEquals(
            listOf(StreamEvent.Activity(StreamActivity.WebSearch)),
            events.filterIsInstance<StreamEvent.Activity>(),
        )
        val activityAt = events.indexOfFirst { it is StreamEvent.Activity }
        assertEquals("first let me think", (events[activityAt - 1] as StreamEvent.Reasoning).text)
        assertTrue(
            events.drop(activityAt + 1).filterIsInstance<StreamEvent.Reasoning>().any { it.text == "now to sum up" },
        )
        assertEquals(30, done.result.promptTokens)
        assertEquals(12, done.result.completionTokens)
    }

    /** When the model does not start a search the single leg finishes on its own, and the event behaviour matches a plain stream. */
    @Test
    fun `webSearch streaming tool loop ends after single leg without tool_calls`() = runTest {
        val leg = """
            data: {"choices":[{"delta":{"reasoning_content":"thinking it through"}}],"usage":null}

            data: {"choices":[{"delta":{"content":"a direct answer"}}],"usage":{"prompt_tokens":4,"completion_tokens":2}}

            data: [DONE]
        """.trimIndent()

        var calls = 0
        val client = HttpClient(
            MockEngine {
                calls += 1
                respond(
                    content = leg,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = MoonshotService(client, json, transportRegistry)

        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "kimi-k2.5",
            messages = listOf(userMessage("hello")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(),
        ).toList()

        assertEquals(1, calls)
        // No search was started by the model, so there is no activity: having web search switched
        // on is not an observation.
        assertTrue(events.none { it is StreamEvent.Activity })
        val done = events.last() as StreamEvent.Done
        assertEquals("a direct answer", done.result.text)
        assertEquals("thinking it through", done.result.reasoningText)
    }

    @Test
    fun `webSearch streaming tool loop uses profile maxToolLoops`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "webSearch": {
                  "kimi_web_search": {
                    "maxToolLoops": 1,
                    "mergeParams": {
                      "tools": [
                        { "type": "builtin_function", "function": { "name": "${'$'}web_search" } }
                      ]
                    }
                  }
                }
              },
              "providers": {
                "moonshot": {
                  "defaultModelId": "kimi-k2.5",
                  "resolveMap": { "kimi-k2.5": "kimi-k2.5" },
                  "models": {
                    "kimi-k2.5": {
                      "canonicalModelId": "kimi-k2.5",
                      "profiles": { "webSearch": "kimi_web_search" }
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
        val loopingLeg = """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t-1","type":"builtin_function","function":{"name":"${'$'}web_search","arguments":"{}"}}]}}],"usage":null}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}

            data: [DONE]
        """.trimIndent()

        var calls = 0
        val client = HttpClient(
            MockEngine {
                calls += 1
                respond(
                    content = loopingLeg,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = MoonshotService(client, json, transportRegistry)

        try {
            service.sendMessageStream(
                apiKey = "sk-test",
                modelID = "kimi-k2.5",
                messages = listOf(userMessage("keep searching")),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = true,
                requestOptions = ChatRequestOptions(),
            ).toList()
        } catch (_: ProviderServiceError.InvalidConfiguration) {
            // A pending call at the bound is an explicit failure even if a leg emitted text;
            // no dangling tool state may surface as a successful Done event.
        }

        assertEquals(2, calls)
    }

    @Test
    fun `webSearch streaming tool loop does not clamp server maxToolLoops to local legacy limit`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "webSearch": {
                  "kimi_web_search": {
                    "maxToolLoops": 5,
                    "mergeParams": {
                      "tools": [
                        { "type": "builtin_function", "function": { "name": "${'$'}web_search" } }
                      ]
                    }
                  }
                }
              },
              "providers": {
                "moonshot": {
                  "defaultModelId": "kimi-k2.5",
                  "resolveMap": { "kimi-k2.5": "kimi-k2.5" },
                  "models": {
                    "kimi-k2.5": {
                      "canonicalModelId": "kimi-k2.5",
                      "profiles": { "webSearch": "kimi_web_search" }
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )
        val loopingLeg = """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"t-1","type":"builtin_function","function":{"name":"${'$'}web_search","arguments":"{}"}}]}}],"usage":null}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}

            data: [DONE]
        """.trimIndent()

        var calls = 0
        val client = HttpClient(
            MockEngine {
                calls += 1
                respond(
                    content = loopingLeg,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = MoonshotService(client, json, transportRegistry)

        try {
            service.sendMessageStream(
                apiKey = "sk-test",
                modelID = "kimi-k2.5",
                messages = listOf(userMessage("keep searching")),
                baseUrl = null,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = true,
                requestOptions = ChatRequestOptions(),
            ).toList()
        } catch (_: ProviderServiceError.InvalidConfiguration) {
            // The sixth tool-call is explicit exhaustion, never a misleading successful partial response.
        }

        assertEquals(6, calls)
    }

    @Test
    fun `formula performs same-origin tools and fibers loop for default and custom API roots`() = runTest {
        val root = File(System.getProperty("user.dir")).absoluteFile.parentFile!!.parentFile!!
        val registry = json.parseToJsonElement(File(root, "shared/capabilityrecipe/capability_runtime.v1.json").readText()).jsonObject
        val runtime = JsonObject(registry + mapOf(
            "revision" to JsonPrimitive("sha256:formula-test"),
            "generatedAt" to JsonPrimitive("2026-08-11T00:00:00Z"),
        ))
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1); put("capabilityRuntime", runtime)
            put("providers", buildJsonObject { put("moonshot", buildJsonObject {
                put("resolveMap", buildJsonObject { put("kimi-k3", "kimi-k3") })
                put("models", buildJsonObject { put("kimi-k3", buildJsonObject {
                    put("transport", "openai_chat")
                    put("capabilityControls", buildJsonObject { put("web", buildJsonObject {
                        put("state", "auto_available"); put("recipeRef", "moonshot.formula.web.v1")
                    }) })
                }) })
            }) })
        }.toString())

        listOf(null to "https://api.moonshot.ai/v1", "https://proxy.test/custom/v1" to "https://proxy.test/custom/v1").forEach { (custom, expectedRoot) ->
            val captured = mutableListOf<Pair<String, String>>()
            var chatLeg = 0
            val client = HttpClient(MockEngine { request ->
                val path = request.url.encodedPath
                captured += request.url.toString() to runCatching { requestBodyText(request.body) }.getOrDefault("")
                when {
                    request.method == HttpMethod.Get && path.endsWith("/formulas/moonshot/web-search:latest/tools") -> respond(
                        """{"tools":[{"type":"function","function":{"name":"search","parameters":{}}}]}""",
                        HttpStatusCode.OK,
                    )
                    path.endsWith("/formulas/moonshot/web-search:latest/fibers") -> respond(
                        """{"context":{"encrypted_output":"----MOONSHOT ENCRYPTED BEGIN----opaque----MOONSHOT ENCRYPTED END----"}}""",
                        HttpStatusCode.OK,
                    )
                    else -> {
                        chatLeg += 1
                        val stream = if (chatLeg == 1) """
                            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"search","arguments":"{\"q\":\"a\\u0062\"}"}}]}}]}

                            data: [DONE]
                        """.trimIndent() else """
                            data: {"choices":[{"delta":{"content":"done"}}]}

                            data: [DONE]
                        """.trimIndent()
                        respond(stream, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
                    }
                }
            })
            val events = MoonshotService(client, json, transportRegistry).sendMessageStream(
                "sk", "kimi-k3", listOf(userMessage("news")), custom, false,
                ReasoningMode.Automatic, true, ChatRequestOptions(),
            ).toList()
            assertTrue(captured.any { it.first == "$expectedRoot/formulas/moonshot/web-search:latest/tools" })
            val fiber = captured.single { it.first == "$expectedRoot/formulas/moonshot/web-search:latest/fibers" }
            val fiberBody = json.parseToJsonElement(fiber.second).jsonObject
            assertEquals(setOf("name", "arguments"), fiberBody.keys)
            assertEquals("search", fiberBody["name"]!!.jsonPrimitive.content)
            assertEquals("{\"q\":\"a\\u0062\"}", fiberBody["arguments"]!!.jsonPrimitive.content)
            val finalChat = captured.last().second
            assertTrue(finalChat.contains("----MOONSHOT ENCRYPTED BEGIN----opaque----MOONSHOT ENCRYPTED END----"))
            assertTrue(events.any { it is StreamEvent.RecipeContinuation })
            // The closed set holds only `$web_search`. The tool of the Formula loop is named
            // `search`, which is not in it and must not be reported.
            assertTrue(events.none { it is StreamEvent.Activity })
            assertEquals("done", (events.last() as StreamEvent.Done).result.text)
        }

        var duplicateRequests = 0
        val duplicateClient = HttpClient(MockEngine { request ->
            duplicateRequests += 1
            assertTrue(request.url.encodedPath.endsWith("/formulas/moonshot/web-search:latest/tools"))
            respond(
                """{"tools":[{"type":"function","function":{"name":"search","parameters":{}}},{"type":"function","function":{"name":"search","parameters":{}}}]}""",
                HttpStatusCode.OK,
            )
        })
        val duplicateError = runCatching {
            MoonshotService(duplicateClient, json, transportRegistry).sendMessageStream(
                "sk", "kimi-k3", listOf(userMessage("news")), null, false,
                ReasoningMode.Automatic, true, ChatRequestOptions(),
            ).toList()
        }.exceptionOrNull()
        assertTrue(duplicateError is ProviderServiceError.InvalidConfiguration)
        assertEquals("duplicate Formula tools must fail before chat/fiber network", 1, duplicateRequests)
    }

    /**
     * A client tool loop allows at most 8 steps and defaults to 6, so the effective cap is
     * `min(recipe value, 8)`.
     *
     * The recipe asks for 12 here and the loop must run 8 tool legs plus 1 synthesis leg = 9
     * requests. This pins the hard cap against any tighter, provider-specific clamp.
     */
    @Test
    fun `webSearch tool loop caps server recipe maxToolLoops at contract hard cap eight`() = runTest {
        val registry = json.parseToJsonElement(MetadataTestFixtures.capabilityRuntimeJson()).jsonObject
        val recipes = registry["recipes"]!!.jsonObject.toMutableMap()
        val chatRecipe = recipes["moonshot.chat.web.v1"]!!.jsonObject.toMutableMap()
        chatRecipe["maxToolLoops"] = JsonPrimitive(12)
        recipes["moonshot.chat.web.v1"] = JsonObject(chatRecipe)
        val runtime = JsonObject(registry + ("recipes" to JsonObject(recipes)))
        MetadataTestFixtures.applyRaw(
            buildJsonObject {
                put("version", 1)
                put("capabilityRuntime", runtime)
                put("providers", buildJsonObject {
                    put("moonshot", buildJsonObject {
                        put("defaultModelId", JsonPrimitive("kimi-k2.5"))
                        put("resolveMap", buildJsonObject { put("kimi-k2.5", JsonPrimitive("kimi-k2.5")) })
                        put("models", buildJsonObject {
                            put("kimi-k2.5", buildJsonObject {
                                put("canonicalModelId", JsonPrimitive("kimi-k2.5"))
                                put("transport", JsonPrimitive("openai_chat"))
                                put("capabilities", JsonArray(listOf(JsonPrimitive("web"))))
                                put(
                                    "capabilityControls",
                                    json.parseToJsonElement(
                                        MetadataTestFixtures.capabilityControlsJson(
                                            MetadataTestFixtures.ControlSpec(
                                                capability = "web",
                                                recipeRef = "moonshot.chat.web.v1",
                                            ),
                                        ),
                                    ).jsonObject,
                                )
                            })
                        })
                    })
                })
            }.toString()
        )

        var calls = 0
        val client = HttpClient(
            MockEngine {
                calls += 1
                respond(
                    content = loopingBuiltinLeg("t-$calls"),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = MoonshotService(client, json, transportRegistry)

        service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "kimi-k2.5",
            messages = listOf(userMessage("つづけて")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(),
        ).toList()

        // 8 tool legs + 1 synthesis leg with tool_choice:none.
        assertEquals(9, calls)
    }

    /**
     * Defaults to 6 steps when neither the recipe nor the profile provides a step count.
     */
    @Test
    fun `webSearch tool loop defaults to contract six steps when no server or profile value`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "webSearch": {
                  "kimi_web_search": {
                    "mergeParams": {
                      "tools": [
                        { "type": "builtin_function", "function": { "name": "${'$'}web_search" } }
                      ]
                    }
                  }
                }
              },
              "providers": {
                "moonshot": {
                  "defaultModelId": "kimi-k2.5",
                  "resolveMap": { "kimi-k2.5": "kimi-k2.5" },
                  "models": {
                    "kimi-k2.5": {
                      "canonicalModelId": "kimi-k2.5",
                      "profiles": { "webSearch": "kimi_web_search" }
                    }
                  }
                }
              }
            }
            """.trimIndent()
        )

        var calls = 0
        val client = HttpClient(
            MockEngine {
                calls += 1
                respond(
                    content = loopingBuiltinLeg("t-$calls"),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = MoonshotService(client, json, transportRegistry)

        service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "kimi-k2.5",
            messages = listOf(userMessage("つづけて")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(),
        ).toList()

        // 6 tool legs + 1 synthesis leg.
        assertEquals(7, calls)
    }

    /**
     * The system message appended for Kimi at the step limit must use web search's own wording.
     * Web search has no `[n]` citation scheme, so wording that asks for numbered citations would
     * only make the model invent citation numbers.
     */
    @Test
    fun `step limit notice sent to Kimi uses web search wording without citation markers`() = runTest {
        applyWebRecipe(maxToolLoops = 6)
        val bodies = mutableListOf<JsonObject>()
        val client = HttpClient(
            MockEngine { request ->
                bodies += json.parseToJsonElement(requestBodyText(request.body)).jsonObject
                respond(
                    content = loopingBuiltinLeg("t-${bodies.size}"),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        webSearchStream(MoonshotService(client, json, transportRegistry)).toList()

        val finalBody = bodies.last()
        assertEquals("none", finalBody["tool_choice"]?.jsonPrimitive?.content)
        val notice = finalBody["messages"]!!.jsonArray.last().jsonObject
        assertEquals("system", notice["role"]?.jsonPrimitive?.content)
        val text = notice["content"]!!.jsonPrimitive.content
        assertEquals(MOONSHOT_WEB_SEARCH_PROMPTS.stepLimitReached, text)
        assertEquals(
            "The web search limit was reached. Answer now using the search results you already have. " +
                "Do not call another tool.",
            text,
        )
        assertFalse("web search has no [n] citation scheme: $text", text.contains("[n]"))
        assertFalse(text.contains("cite", ignoreCase = true))
        assertFalse(text.contains("research", ignoreCase = true))
        // Citation wording must not appear anywhere in the request body.
        assertFalse(finalBody.toString().contains("cite sources as [n]"))
    }

    /**
     * Steps are counted per call, not per leg: 3 parallel web searches in one leg use 3 steps.
     * With a cap of 6 the limit is hit after two tool legs, 3 requests in total; counting per leg
     * would give 7.
     */
    @Test
    fun `three parallel web searches in one leg consume three steps`() = runTest {
        applyWebRecipe(maxToolLoops = 6)
        val bodies = mutableListOf<JsonObject>()
        val client = HttpClient(
            MockEngine { request ->
                bodies += json.parseToJsonElement(requestBodyText(request.body)).jsonObject
                val leg = bodies.size
                respond(
                    content = toolCallLeg(
                        (0 until 3).map { Triple("t-$leg-$it", "${'$'}web_search", "{\\\"q\\\":$it}") },
                    ),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        webSearchStream(MoonshotService(client, json, transportRegistry)).toList()

        assertEquals("2 tool legs (3 steps each) + 1 synthesis leg", 3, bodies.size)
        assertEquals("none", bodies.last()["tool_choice"]?.jsonPrimitive?.content)
        // All six calls were executed and fed back (builtin shape: arguments are echoed as is).
        val toolMessages = bodies.last()["messages"]!!.jsonArray
            .map { it.jsonObject }
            .filter { it["role"]?.jsonPrimitive?.content == "tool" }
        assertEquals(
            listOf("t-1-0", "t-1-1", "t-1-2", "t-2-0", "t-2-1", "t-2-2"),
            toolMessages.map { it["tool_call_id"]!!.jsonPrimitive.content },
        )
        assertEquals("{\"q\":2}", toolMessages.last()["content"]!!.jsonPrimitive.content)
    }

    /**
     * The unregistered-tool callback can fire several times in one run. The index sent downstream
     * must be unique across the whole run: `NativeToolCallAccumulator.merge` joins chunks by index,
     * so numbering from 0 each time would treat the second leg's call as a continuation of the
     * first leg's and concatenate the arguments into broken JSON.
     */
    @Test
    fun `unregistered tool calls from different legs stay separate downstream`() = runTest {
        applyWebRecipe(maxToolLoops = 6)
        var calls = 0
        val client = HttpClient(
            MockEngine {
                calls += 1
                val leg = when (calls) {
                    // Mixed leg: one executable web search + one unregistered tool => one callback, the loop continues.
                    1 -> toolCallLeg(
                        listOf(
                            Triple("s-1", "${'$'}web_search", "{}"),
                            Triple("u-1", "mystery_a", "{\\\"a\\\":1}"),
                        ),
                    )
                    // Whole leg unregistered => second callback, and the loop ends without another leg.
                    2 -> toolCallLeg(listOf(Triple("u-2", "mystery_b", "{\\\"b\\\":2}")))
                    else -> error("no request is expected after a fully unregistered leg")
                }
                respond(
                    content = leg,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )

        val events = webSearchStream(MoonshotService(client, json, transportRegistry)).toList()

        assertEquals(2, calls)
        // Merge the way ChatRepository does in production: one table, the same merge / finalize.
        val accumulated = mutableMapOf<Int, ai.oriveo.community.core.model.ToolCallDelta>()
        events.filterIsInstance<StreamEvent.ToolCallDeltas>().forEach { event ->
            NativeToolCallAccumulator.merge(accumulated, event.deltas)
        }
        val unhandled = NativeToolCallAccumulator.finalize(accumulated, namespace = "provider_tool_call")
        assertEquals(listOf("mystery_a", "mystery_b"), unhandled.map { it.name })
        assertEquals(listOf("{\"a\":1}", "{\"b\":2}"), unhandled.map { it.arguments })
        assertEquals(listOf("u-1", "u-2"), unhandled.map { it.id })
    }

    private fun webSearchStream(service: MoonshotService) = service.sendMessageStream(
        apiKey = "sk-test",
        modelID = "kimi-k2.5",
        messages = listOf(userMessage("つづけて")),
        baseUrl = null,
        supportsImageGen = false,
        reasoningMode = ReasoningMode.Automatic,
        webSearchEnabled = true,
        requestOptions = ChatRequestOptions(),
    )

    /**
     * The builtin `$web_search` comes only from the exact capabilityRuntime recipe; a legacy
     * profile alone puts no tools in the request body. The step count is set explicitly by the
     * recipe so the cases do not depend on fixture defaults.
     */
    private fun applyWebRecipe(maxToolLoops: Int) {
        val registry = json.parseToJsonElement(MetadataTestFixtures.capabilityRuntimeJson()).jsonObject
        val recipes = registry["recipes"]!!.jsonObject.toMutableMap()
        val chatRecipe = recipes["moonshot.chat.web.v1"]!!.jsonObject.toMutableMap()
        chatRecipe["maxToolLoops"] = JsonPrimitive(maxToolLoops)
        recipes["moonshot.chat.web.v1"] = JsonObject(chatRecipe)
        val runtime = JsonObject(registry + ("recipes" to JsonObject(recipes)))
        MetadataTestFixtures.applyRaw(
            buildJsonObject {
                put("version", 1)
                put("capabilityRuntime", runtime)
                put("providers", buildJsonObject {
                    put("moonshot", buildJsonObject {
                        put("defaultModelId", JsonPrimitive("kimi-k2.5"))
                        put("resolveMap", buildJsonObject { put("kimi-k2.5", JsonPrimitive("kimi-k2.5")) })
                        put("models", buildJsonObject {
                            put("kimi-k2.5", buildJsonObject {
                                put("canonicalModelId", JsonPrimitive("kimi-k2.5"))
                                put("transport", JsonPrimitive("openai_chat"))
                                put("capabilities", JsonArray(listOf(JsonPrimitive("web"))))
                                put(
                                    "capabilityControls",
                                    json.parseToJsonElement(
                                        MetadataTestFixtures.capabilityControlsJson(
                                            MetadataTestFixtures.ControlSpec(
                                                capability = "web",
                                                recipeRef = "moonshot.chat.web.v1",
                                            ),
                                        ),
                                    ).jsonObject,
                                )
                            })
                        })
                    })
                })
            }.toString()
        )
    }

    /** Several parallel tool calls in one leg: (id, name, arguments already escaped as a JSON string). */
    private fun toolCallLeg(calls: List<Triple<String, String, String>>): String {
        val toolCalls = calls.mapIndexed { index, (id, name, arguments) ->
            val type = if (name.startsWith("${'$'}")) "builtin_function" else "function"
            """{"index":$index,"id":"$id","type":"$type","function":{"name":"$name","arguments":"$arguments"}}"""
        }.joinToString(",")
        return """
            data: {"choices":[{"delta":{"tool_calls":[$toolCalls]}}],"usage":null}

            data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}

            data: [DONE]
        """.trimIndent()
    }

    private fun loopingBuiltinLeg(callId: String) = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"$callId","type":"builtin_function","function":{"name":"${'$'}web_search","arguments":"{}"}}]}}],"usage":null}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}

        data: [DONE]
    """.trimIndent()

    private fun userMessage(text: String) = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.Moonshot,
        providerName = "Kimi",
        modelName = "kimi-k2.5",
        state = ChatMessageState.Delivered,
    )
}
