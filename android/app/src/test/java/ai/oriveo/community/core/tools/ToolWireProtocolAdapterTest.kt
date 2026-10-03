package ai.oriveo.community.core.tools

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolWireProtocolAdapterTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val call = ToolLoopToolCall(
        id = "call_1",
        function = ToolLoopToolCallFunction("lookup", "{\"query\":\"plan\"}"),
    )
    private val tool = ToolLoopToolDefinition(function = ToolLoopToolFunction(
        name = "lookup",
        description = "Search",
        parameters = json.parseToJsonElement(
            """{"type":"object","properties":{"query":{"type":["string","null"]}},"required":["query"],"additionalProperties":false}""",
        ).jsonObject,
    ))

    @Test
    fun `openai chat adapter encodes paired assistant call and tool result`() {
        val body = body(ToolWireProtocol.OpenAIChat)
        val messages = body.getValue("messages").jsonArray
        assertEquals("lookup", messages[1].jsonObject["tool_calls"]!!.jsonArray[0]
            .jsonObject["function"]!!.jsonObject["name"]!!.jsonPrimitive.content)
        assertEquals("call_1", messages[2].jsonObject["tool_call_id"]!!.jsonPrimitive.content)
        assertEquals("auto", body["tool_choice"]!!.jsonPrimitive.content)
    }

    @Test
    fun `openai chat adapter replays exact reasoning assistant before tool result`() {
        val assistant = json.parseToJsonElement(
            """{"role":"assistant","content":"","reasoning_content":"search first","tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"query\":\"plan\"}"}}]}""",
        ).jsonObject
        val body = body(
            ToolWireProtocol.OpenAIChat,
            continuation = buildJsonObject {
                put("protocol", ToolWireProtocol.OpenAIChat.wireValue)
                put("state", buildJsonObject { put("assistantMessages", JsonArray(listOf(assistant))) })
            },
        )

        val messages = body.getValue("messages").jsonArray
        assertEquals(assistant, messages[1])
        assertEquals("call_1", messages[2].jsonObject["tool_call_id"]!!.jsonPrimitive.content)
    }

    @Test
    fun `responses adapter replays encrypted reasoning before call output`() {
        val body = body(
            ToolWireProtocol.OpenAIResponses,
            continuation = continuation(
                "openai_responses",
                """[{"type":"reasoning","id":"rs_1","encrypted_content":"opaque","summary":[]}]""",
            ),
        )
        val input = body.getValue("input").jsonArray
        val reasoningIndex = input.indexOfFirst { it.jsonObject["type"]?.jsonPrimitive?.content == "reasoning" }
        val callIndex = input.indexOfFirst { it.jsonObject["type"]?.jsonPrimitive?.content == "function_call" }
        val outputIndex = input.indexOfFirst { it.jsonObject["type"]?.jsonPrimitive?.content == "function_call_output" }
        assertTrue(reasoningIndex >= 0 && reasoningIndex < callIndex && callIndex < outputIndex)
        assertEquals("opaque", input[reasoningIndex].jsonObject["encrypted_content"]!!.jsonPrimitive.content)
        assertEquals("output_text", input[reasoningIndex + 1].jsonObject["content"]!!.jsonArray[0]
            .jsonObject["type"]!!.jsonPrimitive.content)
    }

    @Test
    fun `anthropic adapter replays signed blocks and emits tool result block`() {
        val body = body(
            ToolWireProtocol.AnthropicMessages,
            continuation = continuation(
                "anthropic_messages",
                """[{"type":"thinking","thinking":"search","signature":"sig_a"},{"type":"tool_use","id":"call_1","name":"lookup","input":{"query":"plan"}}]""",
            ),
        )
        val messages = body.getValue("messages").jsonArray
        assertEquals("sig_a", messages[1].jsonObject["content"]!!.jsonArray[0]
            .jsonObject["signature"]!!.jsonPrimitive.content)
        assertEquals("tool_result", messages[2].jsonObject["content"]!!.jsonArray[0]
            .jsonObject["type"]!!.jsonPrimitive.content)
        assertEquals("input_schema", body.getValue("tools").jsonArray[0].jsonObject.keys.last())
    }

    @Test
    fun `gemini adapter preserves thought signature and normalizes nullable schema`() {
        val body = body(
            ToolWireProtocol.GeminiGenerate,
            continuation = continuation(
                "gemini_generate",
                """[{"role":"model","parts":[{"functionCall":{"name":"lookup","args":{"query":"plan"}},"thoughtSignature":"sig_g"}]}]""",
            ),
        )
        val contents = body.getValue("contents").jsonArray
        assertEquals("sig_g", contents[1].jsonObject["parts"]!!.jsonArray[0]
            .jsonObject["thoughtSignature"]!!.jsonPrimitive.content)
        assertEquals("lookup", contents[2].jsonObject["parts"]!!.jsonArray[0]
            .jsonObject["functionResponse"]!!.jsonObject["name"]!!.jsonPrimitive.content)
        val querySchema = body.getValue("tools").jsonArray[0].jsonObject["functionDeclarations"]!!.jsonArray[0]
            .jsonObject["parameters"]!!.jsonObject["properties"]!!.jsonObject["query"]!!.jsonObject
        assertEquals("string", querySchema["type"]!!.jsonPrimitive.content)
        assertTrue(querySchema["nullable"]!!.jsonPrimitive.content.toBoolean())
        assertFalse(body.containsKey("model"))
    }

    @Test
    fun `decoders retain provider continuation needed by the second leg`() {
        val openAIChat = ToolWireStreamDecoder(
            ToolWireProtocol.OpenAIChat,
            json,
            "moonshot_reasoning_v1",
        )
        val openAIEvents = openAIChat.parse(
            null,
            """{"choices":[{"delta":{"content":"","reasoning_content":"","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"query\":\"plan\"}"}}]},"finish_reason":"tool_calls"}]}""",
        )
        val openAIState = openAIEvents.filterIsInstance<ToolLoopLegEvent.ProviderContinuation>().single().state
        assertEquals("", openAIState["assistantMessages"]!!.jsonArray[0]
            .jsonObject["reasoning_content"]!!.jsonPrimitive.content)

        val anthropic = ToolWireStreamDecoder(ToolWireProtocol.AnthropicMessages, json)
        anthropic.parse("content_block_start", """{"index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}""")
        anthropic.parse("content_block_delta", """{"index":0,"delta":{"type":"thinking_delta","thinking":"search"}}""")
        val anthropicEvents = anthropic.parse(
            "content_block_delta",
            """{"index":0,"delta":{"type":"signature_delta","signature":"sig_a"}}""",
        )
        val anthropicState = anthropicEvents.filterIsInstance<ToolLoopLegEvent.ProviderContinuation>().last().state
        assertEquals("sig_a", anthropicState["blocks"]!!.jsonArray[0].jsonObject["signature"]!!.jsonPrimitive.content)

        val responses = ToolWireStreamDecoder(ToolWireProtocol.OpenAIResponses, json)
        responses.parse(
            "response.created",
            """{"type":"response.created","response":{"id":"resp_1"}}""",
        )
        val responseEvents = responses.parse(
            "response.output_item.done",
            """{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","encrypted_content":"opaque","summary":[]}}""",
        )
        val responseState = responseEvents.filterIsInstance<ToolLoopLegEvent.ProviderContinuation>().single().state
        assertEquals("resp_1", responseState["previousResponseId"]!!.jsonPrimitive.content)
        assertEquals("opaque", responseState["blocks"]!!.jsonArray[0].jsonObject["encrypted_content"]!!.jsonPrimitive.content)

        val gemini = ToolWireStreamDecoder(ToolWireProtocol.GeminiGenerate, json)
        val geminiEvents = gemini.parse(
            null,
            """{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"lookup","args":{"query":"plan"}},"thoughtSignature":"sig_g"}]}}]}""",
        )
        val geminiState = geminiEvents.filterIsInstance<ToolLoopLegEvent.ProviderContinuation>().single().state
        assertEquals("sig_g", geminiState["blocks"]!!.jsonArray[0].jsonObject["parts"]!!.jsonArray[0]
            .jsonObject["thoughtSignature"]!!.jsonPrimitive.content)
    }

    private fun body(protocol: ToolWireProtocol, continuation: JsonObject? = null): JsonObject =
        ToolWireProtocolAdapter.buildBody(
            protocol = protocol,
            modelId = "model",
            request = ToolLoopLegRequest(
                messages = listOf(
                    ToolLoopMessage("user", "What is the plan?"),
                    ToolLoopMessage(
                        role = "assistant",
                        content = JsonPrimitive("Let me look."),
                        toolCalls = listOf(call),
                        providerContinuation = continuation,
                    ),
                    ToolLoopMessage("tool", JsonPrimitive("{\"ok\":true}"), toolCallId = "call_1"),
                ),
                tools = listOf(tool),
                toolChoice = ToolLoopToolChoice.Auto,
            ),
        )

    private fun continuation(protocol: String, blocks: String) = buildJsonObject {
        put("protocol", protocol)
        put("state", buildJsonObject { put("blocks", json.parseToJsonElement(blocks)) })
    }
}
