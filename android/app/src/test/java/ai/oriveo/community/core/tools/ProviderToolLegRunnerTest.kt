package ai.oriveo.community.core.tools

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.data.remote.MetadataClient
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
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
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderToolLegRunnerTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `relay request carries local key tools usage option and parses split SSE`() = runTest {
        val engine = MockEngine { request ->
            assertEquals("/gateway/v1/chat/completions", request.url.encodedPath)
            assertEquals("relay-key", request.headers["x-api-key"])
            assertEquals(null, request.headers[HttpHeaders.Authorization])
            assertEquals("acme", request.headers["X-Tenant"])
            assertEquals("sg", request.url.parameters["region"])
            val body = json.parseToJsonElement(readBody(request.body)).jsonObject
            assertEquals("relay-model", body.getValue("model").jsonPrimitive.content)
            assertTrue(body.getValue("stream").jsonPrimitive.boolean)
            assertTrue(body.getValue("stream_options").jsonObject.getValue("include_usage").jsonPrimitive.boolean)
            assertEquals("auto", body.getValue("tool_choice").jsonPrimitive.content)
            assertEquals(1, body.getValue("tools").jsonArray.size)
            assertEquals("priority", body.getValue("service_tier").jsonPrimitive.content)
            respond(
                content = """
                    data: {"choices":[{"delta":{"content":"Looking "}}]}

                    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"fetch_","arguments":"{\\\"query\\\":\\\"pri"}}]}}]}

                    data: {"choices":[{"delta":{"content":[{"type":"output_text","text":"now"}],"tool_calls":[{"index":0,"function":{"name":"page","arguments":"cing\\\"}"}}]}}]}

                    data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}}

                    data: [DONE]
                """.trimIndent(),
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
            )
        }
        val runner = ProviderToolLegRunner(
            client = HttpClient(engine),
            provider = relayProvider(),
            model = toolModel(),
            modelId = "relay-model",
            reasoningMode = ReasoningMode.Automatic,
            json = json,
            requestOptions = relayRequestOptions(),
        )

        val events = runner.run(request()).toList()

        assertTrue(events.contains(ToolLoopLegEvent.TextDelta("Looking ")))
        assertTrue(events.contains(ToolLoopLegEvent.TextDelta("now")))
        assertTrue(events.contains(ToolLoopLegEvent.Usage(ToolLoopUsage(11, 7, 18))))
        val deltas = events.filterIsInstance<ToolLoopLegEvent.ToolCallDeltas>().flatMap { it.deltas }
        assertEquals(2, deltas.size)
        assertEquals("call-1", deltas.first().id)
    }

    @Test
    fun `deterministic unsupported tools response enters the fallback boundary`() = runTest {
        val engine = MockEngine {
            respond(
                content = """{"error":{"message":"This model does not support tools."}}""",
                status = HttpStatusCode.BadRequest,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }
        val runner = ProviderToolLegRunner(
            client = HttpClient(engine),
            provider = relayProvider(),
            model = toolModel(),
            modelId = "relay-model",
            reasoningMode = ReasoningMode.Automatic,
            json = json,
            requestOptions = relayRequestOptions(),
        )

        try {
            runner.run(request()).toList()
            org.junit.Assert.fail("A deterministic tools rejection must enter the fallback boundary")
        } catch (error: ToolsUnsupportedError) {
            val upstream = error.upstream as ProviderServiceError.Upstream
            assertEquals(400, upstream.statusCode)
        }
    }

    @Test
    fun `unrelated bad request remains a provider error and never triggers tool fallback`() = runTest {
        val engine = MockEngine {
            respond(
                content = """{"error":{"message":"messages[0].content must not be empty"}}""",
                status = HttpStatusCode.BadRequest,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }
        val runner = ProviderToolLegRunner(
            client = HttpClient(engine),
            provider = relayProvider(),
            model = toolModel(),
            modelId = "relay-model",
            reasoningMode = ReasoningMode.Automatic,
            json = json,
            requestOptions = relayRequestOptions(),
        )

        try {
            runner.run(request()).toList()
            org.junit.Assert.fail("An unrelated bad request must remain a provider error")
        } catch (error: ProviderServiceError.Upstream) {
            assertEquals(400, error.statusCode)
        }
    }

    /** A Relay without a generation profile is unknown, not unsupported: explicit values still go out. */
    @Test
    fun `unprofiled Relay tool leg sends explicitly configured generation values`() = runTest {
        val bodies = mutableListOf<JsonObject>()
        val engine = MockEngine { request ->
            bodies += json.parseToJsonElement(readBody(request.body)).jsonObject
            respond(
                content = "data: [DONE]\n\n",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
            )
        }

        ProviderToolLegRunner(
            client = HttpClient(engine),
            provider = relayProvider(),
            model = toolModel().copy(generationProfile = GenerationProfileRef()),
            modelId = "relay-model",
            reasoningMode = ReasoningMode.Automatic,
            json = json,
            requestOptions = relayRequestOptions().copy(temperature = 0.3f, maxTokens = 2048),
        ).run(request()).toList()

        // A relay's model list comes from the user's own machine, so a missing profile only means
        // "unknown". Values the user set explicitly are sent so they can find out for themselves.
        assertEquals(JsonPrimitive(0.3f), bodies.single()["temperature"])
        assertEquals(JsonPrimitive(2048), bodies.single()["max_tokens"])

        bodies.clear()
        ProviderToolLegRunner(
            client = HttpClient(engine),
            provider = relayProvider(),
            model = toolModel().copy(generationProfile = GenerationProfileRef()),
            modelId = "relay-model",
            reasoningMode = ReasoningMode.Automatic,
            json = json,
            // An explicit 1.0 is not the same as omitting it; only the legacy default max-token value normalizes to unset.
            requestOptions = relayRequestOptions().copy(
                temperature = ChatRequestOptions.DEFAULT_TEMPERATURE,
                maxTokens = ChatRequestOptions.DEFAULT_MAX_TOKENS,
            ),
        ).run(request()).toList()

        // An explicit 1.0 is still explicit intent and is sent. The legacy default max-token value
        // is normalized to null by `MessageBuilder` and stays absent: explicit values pass, leftover
        // encodings of an old default do not.
        assertEquals(JsonPrimitive(ChatRequestOptions.DEFAULT_TEMPERATURE), bodies.single()["temperature"])
        assertFalse(bodies.single().containsKey("max_tokens"))
    }

    @Test
    fun `tool legs apply the same model profile overrides as normal chat`() = runTest {
        var capturedBody: JsonObject? = null
        val engine = MockEngine { request ->
            capturedBody = json.parseToJsonElement(readBody(request.body)).jsonObject
            respond(
                content = "data: [DONE]\n\n",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
            )
        }
        val model = toolModel().copy(generationProfile = GenerationProfileRef(
            template = "openai_chat_completions",
            parameters = listOf(
                GenerationParameterRef(id = "temperature", support = "supported"),
                GenerationParameterRef(id = "max_output_tokens", support = "supported"),
            ),
            wire = mapOf("temperature" to "temperature", "max_output_tokens" to "max_tokens"),
        ))
        ProviderToolLegRunner(
            client = HttpClient(engine),
            provider = relayProvider(),
            model = model,
            modelId = "relay-model",
            reasoningMode = ReasoningMode.Automatic,
            json = json,
            requestOptions = relayRequestOptions().copy(
                generationParameters = GenerationParameterOverrides(mapOf(
                    "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0)),
                    "max_output_tokens" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(1024)),
                )),
                activeModel = model,
            ),
        ).run(request()).toList()
        val body = requireNotNull(capturedBody)
        assertEquals(0, body.getValue("temperature").jsonPrimitive.content.toInt())
        assertEquals(1024, body.getValue("max_tokens").jsonPrimitive.content.toInt())
    }

    @Test
    fun `public metadata projection controls actual tool leg generation body`() = runTest {
        val original = MetadataClient.instance
        val metadata = MetadataClient()
        MetadataClient.instance = metadata
        try {
            metadata.loadNetworkPayloadForTesting(
                """
                {"profiles":{"generation":{"parameters":{"temperature":{"valueSchema":"number"}},"templates":{"openai_chat_completions":{"transport":"openai_chat","wire":{"temperature":"current_temperature"}}}}},"providers":{"openAI":{"resolveMap":{"official-model":"official-model"},"models":{"official-model":{
                  "canonicalModelId":"official-model","transport":"openai_chat",
                  "profiles":{"generation":{"template":"openai_chat_completions","parameters":[{"id":"temperature","support":"supported","source":"authoritative_metadata"}] }},
                  "capabilityEvidenceView":{"schema":"capability-evidence-view/v1","candidates":[
                    {"key":"tool_call","support":"supported","source":"server_typed","grade":"machine_verified",
                     "scope":"provider_model_transport","providerKind":"openAI","modelId":"official-model","transport":"openai_chat",
                     "observedAt":1000,"expiresAt":9999999999999},
                    {"key":"generation_parameter/temperature","support":"supported","source":"server_profile","grade":"effect_verified",
                     "scope":"provider_model_transport","providerKind":"openAI","modelId":"official-model","transport":"openai_chat",
                     "generationRevision":"profile-r1"}
                  ]}
                }}}}}
                """.trimIndent(),
                "etag-r1",
            )
            var captured: JsonObject? = null
            val engine = MockEngine { request ->
                captured = json.parseToJsonElement(readBody(request.body)).jsonObject
                respond(
                    content = "data: [DONE]\n\n",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
                )
            }
            val model = AIModel(
                id = "official-model",
                name = "Official model",
                toolCall = true,
                generationProfile = GenerationProfileRef(
                    template = "openai_chat_completions",
                    parameters = listOf(GenerationParameterRef(id = "temperature", support = "supported")),
                    wire = mapOf("temperature" to "stale_temperature"),
                ),
            )
            ProviderToolLegRunner(
                client = HttpClient(engine),
                provider = Provider(id = "official", kind = ProviderKind.OpenAI, apiKey = "official-key"),
                model = model,
                modelId = model.id,
                reasoningMode = ReasoningMode.Automatic,
                json = json,
                requestOptions = ChatRequestOptions(
                    generationParameters = GenerationParameterOverrides(mapOf(
                        "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.2)),
                    )),
                ),
            ).run(request()).toList()

            assertEquals(
                0.2,
                requireNotNull(requireNotNull(captured)["current_temperature"]?.jsonPrimitive?.content).toDouble(),
                0.0001,
            )
            assertFalse(requireNotNull(captured).containsKey("stale_temperature"))
        } finally {
            MetadataClient.instance = original
            MetadataTestFixtures.clear()
        }
    }

    @Test
    fun `official tool leg clamps and writes the current reasoning profile not a persisted stale one`() = runTest {
        MetadataTestFixtures.applyRaw(
            """{"version":1,"profiles":{"reasoning":{"current_reasoning":{"levels":["balanced"],"params":{"balanced":{"reasoning_effort":"current-balanced"}}}}},"providers":{"openAI":{"resolveMap":{"official-reasoning":"official-reasoning"},"models":{"official-reasoning":{"canonicalModelId":"official-reasoning","transport":"openai_chat","profiles":{"reasoning":"current_reasoning"},"capabilityEvidenceView":{"schema":"capability-evidence-view/v1","candidates":[{"key":"tool_call","support":"supported","source":"server_typed","grade":"machine_verified","scope":"provider_model_transport","providerKind":"openAI","modelId":"official-reasoning","transport":"openai_chat","observedAt":1000,"expiresAt":9999999999999}]}}}}}}""",
        )
        var body: JsonObject? = null
        val engine = MockEngine { request ->
            body = json.parseToJsonElement(readBody(request.body)).jsonObject
            respond("data: [DONE]\n\n", HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()))
        }
        val staleModel = toolModel(reasoningProfile = "stale_reasoning").copy(
            id = "official-reasoning",
            name = "Official reasoning",
        )
        ProviderToolLegRunner(
            client = HttpClient(engine),
            provider = Provider(id = "official", kind = ProviderKind.OpenAI, apiKey = "official-key"),
            model = staleModel,
            modelId = staleModel.id,
            reasoningMode = ReasoningMode.Deep,
            json = json,
        ).run(request()).toList()

        assertEquals("current-balanced", requireNotNull(body)["reasoning_effort"]?.jsonPrimitive?.content)
    }

    @Test
    fun `Relay Auto without a declared profile cannot authorize generation override`() = runTest {
        val engine = MockEngine { request ->
            error("Auto transport must not guess a protocol or dispatch")
        }
        val provider = relayProvider().copy(
            relayRequested = relayProvider().relayRequested?.copy(transport = RelayTransport.Auto),
        )
        try {
            ProviderToolLegRunner(
                client = HttpClient(engine),
                provider = provider,
                model = toolModel().copy(generationProfile = GenerationProfileRef()),
                modelId = "relay-model",
                reasoningMode = ReasoningMode.Automatic,
                json = json,
                requestOptions = relayRequestOptions(),
            )
            org.junit.Assert.fail("Auto transport must remain unavailable until the connection negotiates a protocol")
        } catch (_: ProviderServiceError.InvalidConfiguration) {
            // Expected: protocol identity is a request boundary, not an inference target.
        }
    }

    @Test
    fun `availability gates only non capability transport prerequisites`() {
        val supported = toolModel()
        val relay = relayProvider()
        assertTrue(ToolLoopTransportAvailability.supportsToolTransport(relay, supported))
        assertTrue(ToolLoopTransportAvailability.supportsToolTransport(
            relay.copy(relayRequested = relay.relayRequested?.copy(transport = RelayTransport.OpenAIResponses)),
            supported,
        ))
        assertTrue(ToolLoopTransportAvailability.supportsToolTransport(relay, supported.copy(toolCall = false)))
        assertFalse(ToolLoopTransportAvailability.supportsToolTransport(
            relay.copy(relayRequested = relay.relayRequested?.copy(transport = RelayTransport.Auto)),
            supported,
        ))
        assertTrue(ToolLoopTransportAvailability.supportsToolTransport(
            relay.copy(kind = ProviderKind.OpenAI),
            supported,
            resolvedTransport = ToolWireProtocol.OpenAIChat.wireValue,
        ))
        assertTrue(ToolLoopTransportAvailability.supportsToolTransport(
            relay.copy(kind = ProviderKind.Anthropic),
            supported,
            resolvedTransport = ToolWireProtocol.AnthropicMessages.wireValue,
        ))
        assertTrue(ToolLoopTransportAvailability.supportsToolTransport(
            relay.copy(kind = ProviderKind.Gemini),
            supported,
            resolvedTransport = ToolWireProtocol.GeminiGenerate.wireValue,
        ))
    }

    @Test
    fun `reasoning profile is deep merged and explicit relay effort wins`() = runTest {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "profiles": {
                "reasoning": {
                  "relay_reasoning": {
                    "levels": ["deep"],
                    "params": {
                      "deep": {
                        "enable_thinking": true,
                        "thinking": { "budget": 4096 },
                        "reasoning_effort": "server-medium"
                      }
                    }
                  }
                }
              },
              "providers": {}
            }
            """.trimIndent(),
        )
        val engine = MockEngine { request ->
            val body = json.parseToJsonElement(readBody(request.body)).jsonObject
            assertTrue(body.getValue("enable_thinking").jsonPrimitive.boolean)
            assertEquals(4096, body.getValue("thinking").jsonObject.getValue("budget").jsonPrimitive.content.toInt())
            assertEquals("high", body.getValue("reasoning_effort").jsonPrimitive.content)
            respond(
                content = "data: [DONE]\n\n",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
            )
        }
        val provider = relayProvider().copy(
            relayRequested = relayProvider().relayRequested?.copy(reasoningEffort = RelayReasoningEffort.High),
        )
        val runner = ProviderToolLegRunner(
            client = HttpClient(engine),
            provider = provider,
            model = toolModel(reasoningProfile = "relay_reasoning"),
            modelId = "relay-model",
            reasoningMode = ReasoningMode.Deep,
            json = json,
            requestOptions = relayRequestOptions(),
        )

        assertTrue(runner.run(request()).toList().isEmpty())
    }

    @Test
    fun `relay persisted reasoning effort cannot bypass a missing dispatch identity`() {
        val provider = relayProvider().copy(
            relayRequested = relayProvider().relayRequested?.copy(reasoningEffort = RelayReasoningEffort.High),
        )
        try {
            ProviderToolLegRunner(
                client = HttpClient(MockEngine { error("must not dispatch without an identity") }),
                provider = provider,
                model = toolModel(reasoningProfile = "relay_reasoning"),
                modelId = "relay-model",
                reasoningMode = ReasoningMode.Automatic,
                json = json,
                requestOptions = ChatRequestOptions(),
            )
            org.junit.Assert.fail("missing identity must fail closed before a tool request is built")
        } catch (_: ProviderServiceError.InvalidConfiguration) {
            // Tool call and the persisted High effort share one final projection; neither escapes.
        }
    }

    private fun relayProvider() = Provider(
        id = "relay",
        kind = ProviderKind.Relay,
        apiKey = "relay-key",
        baseUrlText = "https://relay.test/gateway/v1",
        relayRequested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            authMode = RelayAuthMode.XApiKey,
            serviceTier = "priority",
            headers = listOf(RelayKeyValue("X-Tenant", "acme")),
            queryParams = listOf(RelayKeyValue("region", "sg")),
        ),
    )

    private fun relayRequestOptions() = ChatRequestOptions(
        capabilityEvidenceIdentity = CapabilityEvidenceIdentity(
            partitionId = "test-user",
            connectionInstanceId = "relay",
            connectionGeneration = "generation-1",
            credentialEpoch = "credential-1",
            providerKind = ProviderKind.Relay.rawValue,
            metadataRevision = "local-1",
            generationRevision = "local-1",
        ),
    )

    private fun toolModel(reasoningProfile: String? = null) = AIModel(
        id = "relay-model",
        name = "Relay Model",
        reasoningProfile = reasoningProfile,
        reasoningModeAvailable = reasoningProfile != null,
        toolCall = true,
    )

    private fun request() = ToolLoopLegRequest(
        messages = listOf(ToolLoopMessage("user", "Find the plan")),
        tools = listOf(ToolLoopToolDefinition(function = ToolLoopToolFunction(
            name = "lookup",
            description = "Look up a record",
            parameters = json.parseToJsonElement(
                """{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"""
            ).jsonObject,
        ))),
        toolChoice = ToolLoopToolChoice.Auto,
    )

    private fun readBody(content: OutgoingContent): String = when (content) {
        is TextContent -> content.text
        is OutgoingContent.ByteArrayContent -> content.bytes().toString(Charsets.UTF_8)
        else -> error("Unsupported request body ${content::class}")
    }
}
