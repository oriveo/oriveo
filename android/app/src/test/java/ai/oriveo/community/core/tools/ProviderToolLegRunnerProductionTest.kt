package ai.oriveo.community.core.tools

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.ReasoningMode
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
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderToolLegRunnerProductionTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `responses runner dispatches flat tools and decodes encrypted continuation`() = runTest {
        val engine = MockEngine { request ->
            assertEquals("/gateway/v1/responses", request.url.encodedPath)
            assertEquals("Bearer key", request.headers[HttpHeaders.Authorization])
            val body = json.parseToJsonElement(readBody(request.body)).jsonObject
            assertEquals("function", body["tools"]!!.jsonArray[0].jsonObject["type"]!!.jsonPrimitive.content)
            respond(
                """
                event: response.output_item.done
                data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","encrypted_content":"opaque","summary":[]}}

                event: response.output_item.added
                data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_r","name":"lookup","arguments":""}}

                event: response.function_call_arguments.delta
                data: {"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"query\":\"plan\"}"}

                event: response.completed
                data: {"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":8,"output_tokens":3,"total_tokens":11}}}
                """.trimIndent(),
                HttpStatusCode.OK,
                headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
            )
        }
        val events = runner(engine, RelayTransport.OpenAIResponses, RelayAuthMode.Bearer).run(request()).toList()
        assertEquals("call_r", events.toolCalls().first().id)
        assertTrue(events.filterIsInstance<ToolLoopLegEvent.ProviderContinuation>().any {
            it.state.toString().contains("opaque")
        })
        assertTrue(events.contains(ToolLoopLegEvent.Usage(ToolLoopUsage(8, 3, 11))))
    }

    @Test
    fun `anthropic runner dispatches native schema and retains signature blocks`() = runTest {
        val engine = MockEngine { request ->
            assertEquals("/gateway/v1/messages", request.url.encodedPath)
            assertEquals("key", request.headers["x-api-key"])
            assertEquals("2023-06-01", request.headers["anthropic-version"])
            val body = json.parseToJsonElement(readBody(request.body)).jsonObject
            assertNotNull(body["tools"]!!.jsonArray[0].jsonObject["input_schema"])
            respond(
                """
                event: content_block_start
                data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

                event: content_block_delta
                data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"search"}}

                event: content_block_delta
                data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig_a"}}

                event: content_block_start
                data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call_a","name":"lookup","input":{}}}

                event: content_block_delta
                data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"plan\"}"}}

                event: message_stop
                data: {"type":"message_stop"}
                """.trimIndent(),
                HttpStatusCode.OK,
                headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
            )
        }
        val events = runner(engine, RelayTransport.AnthropicMessages, RelayAuthMode.XApiKey).run(request()).toList()
        assertEquals("call_a", events.toolCalls().first().id)
        assertTrue(events.filterIsInstance<ToolLoopLegEvent.ProviderContinuation>().last().state.toString().contains("sig_a"))
    }

    @Test
    fun `gemini runner dispatches declarations and retains thought signature`() = runTest {
        val engine = MockEngine { request ->
            assertTrue(request.url.encodedPath.endsWith("/models/model:streamGenerateContent"))
            assertEquals("sse", request.url.parameters["alt"])
            assertEquals("key", request.headers["x-goog-api-key"])
            val body = json.parseToJsonElement(readBody(request.body)).jsonObject
            assertNotNull(body["tools"]!!.jsonArray[0].jsonObject["functionDeclarations"])
            respond(
                """data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"lookup","args":{"query":"plan"}},"thoughtSignature":"sig_g"}]}}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2,"totalTokenCount":7}}
                """.trimIndent(),
                HttpStatusCode.OK,
                headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
            )
        }
        val events = runner(engine, RelayTransport.GeminiGenerateContent, RelayAuthMode.XGoogApiKey).run(request()).toList()
        assertEquals("lookup", events.toolCalls().first().function.name)
        assertTrue(events.filterIsInstance<ToolLoopLegEvent.ProviderContinuation>().single().state.toString().contains("sig_g"))
        assertTrue(events.contains(ToolLoopLegEvent.Usage(ToolLoopUsage(5, 2, 7))))
    }

    @Test
    fun `official gemini endpoint uses metadata models path exactly once`() = runTest {
        val original = MetadataClient.instance
        val metadata = MetadataClient()
        MetadataClient.instance = metadata
        try {
            metadata.loadNetworkPayloadForTesting(
                """
                {"providers":{"gemini":{
                  "transport":{"baseUrl":"https://generativelanguage.googleapis.com","endpoints":{"chat":"/v1beta/models"}},
                  "resolveMap":{"model":"model"},
                  "models":{"model":{"canonicalModelId":"model","transport":"gemini_generate","capabilityEvidenceView":{"schema":"capability-evidence-view/v1","candidates":[{"key":"tool_call","support":"supported","source":"server_typed","grade":"machine_verified","scope":"provider_model_transport","providerKind":"gemini","modelId":"model","transport":"gemini_generate","observedAt":1000,"expiresAt":9999999999999}]}}}
                }}}
                """.trimIndent(),
                "gemini-etag",
            )
            val engine = MockEngine { request ->
                assertEquals("/v1beta/models/model:streamGenerateContent", request.url.encodedPath)
                assertEquals("sse", request.url.parameters["alt"])
                respond(
                    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"done\"}]}}]}\n\n",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
                )
            }
            ProviderToolLegRunner(
                client = HttpClient(engine),
                provider = Provider(id = "gemini", kind = ProviderKind.Gemini, apiKey = "key"),
                model = AIModel("model", "Model", toolCall = true),
                modelId = "model",
                reasoningMode = ReasoningMode.Automatic,
                json = json,
            ).run(request()).toList()
        } finally {
            MetadataClient.instance = original
        }
    }

    private fun runner(engine: MockEngine, transport: RelayTransport, authMode: RelayAuthMode) =
        ProviderToolLegRunner(
            client = HttpClient(engine),
            provider = Provider(
                id = "relay",
                kind = ProviderKind.Relay,
                apiKey = "key",
                baseUrlText = "https://relay.test/gateway/v1",
                relayRequested = RelayRequestedConfig(transport = transport, authMode = authMode),
            ),
            model = AIModel("model", "Model", toolCall = true),
            modelId = "model",
            reasoningMode = ReasoningMode.Automatic,
            json = json,
            requestOptions = ChatRequestOptions(capabilityEvidenceIdentity = CapabilityEvidenceIdentity(
                partitionId = "user",
                connectionInstanceId = "relay",
                connectionGeneration = "g1",
                credentialEpoch = "c1",
                providerKind = ProviderKind.Relay.rawValue,
                metadataRevision = "m1",
                generationRevision = "g1",
            )),
        )

    private fun request() = ToolLoopLegRequest(
        messages = listOf(ToolLoopMessage("user", "Find the plan")),
        tools = listOf(ToolLoopToolDefinition(function = ToolLoopToolFunction(
            "lookup",
            "Search",
            json.parseToJsonElement("""{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}""").jsonObject,
        ))),
        toolChoice = ToolLoopToolChoice.Auto,
    )

    private fun List<ToolLoopLegEvent>.toolCalls(): List<ToolLoopToolCall> {
        val accumulated = mutableMapOf<Int, ToolLoopToolCallDelta>()
        filterIsInstance<ToolLoopLegEvent.ToolCallDeltas>().forEach { event ->
            ToolCallLoop.mergeToolCallDeltas(accumulated, event.deltas)
        }
        return ToolCallLoop.finalizeToolCalls(accumulated, legIndex = 0)
    }

    private fun readBody(content: OutgoingContent): String = when (content) {
        is TextContent -> content.text
        is OutgoingContent.ByteArrayContent -> content.bytes().toString(Charsets.UTF_8)
        else -> error("Unsupported body ${content::class}")
    }
}
