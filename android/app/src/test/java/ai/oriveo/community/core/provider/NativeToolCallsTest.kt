package ai.oriveo.community.core.provider

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeToolCallsTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `openai chat joins fragments when later chunks omit index`() {
        val parser = NativeToolCallParser(NativeToolProtocol.OpenAIChat)
        val target = mutableMapOf<Int, ai.oriveo.community.core.model.ToolCallDelta>()
        listOf(
            """{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":"{\"q\":"}}]}}]}""",
            """{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\"news\"}"}}]}}]}""",
        ).forEach { raw -> NativeToolCallAccumulator.merge(target, parser.parse(null, root(raw))) }

        val call = NativeToolCallAccumulator.finalize(target, "test").single()
        assertEquals("call_1", call.id)
        assertEquals("search", call.name)
        assertEquals("{\"q\":\"news\"}", call.arguments)
    }

    @Test
    fun `responses joins output item and argument delta`() {
        val parser = NativeToolCallParser(NativeToolProtocol.OpenAIResponses)
        val target = mutableMapOf<Int, ai.oriveo.community.core.model.ToolCallDelta>()
        listOf(
            """{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_r","name":"lookup","arguments":""}}""",
            """{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"id\":7}"}""",
        ).forEach { raw -> NativeToolCallAccumulator.merge(target, parser.parse(null, root(raw))) }

        val call = NativeToolCallAccumulator.finalize(target, "test").single()
        assertEquals("call_r", call.id)
        assertEquals("lookup", call.name)
        assertEquals("{\"id\":7}", call.arguments)
    }

    @Test
    fun `anthropic joins tool use and input json deltas`() {
        val parser = NativeToolCallParser(NativeToolProtocol.AnthropicMessages)
        val target = mutableMapOf<Int, ai.oriveo.community.core.model.ToolCallDelta>()
        listOf(
            """{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tool_a","name":"weather","input":{}}}""",
            """{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Paris\"}"}}""",
        ).forEach { raw -> NativeToolCallAccumulator.merge(target, parser.parse(null, root(raw))) }

        val call = NativeToolCallAccumulator.finalize(target, "test").single()
        assertEquals("tool_a", call.id)
        assertEquals("weather", call.name)
        assertEquals("{\"city\":\"Paris\"}", call.arguments)
    }

    // The frames are copied from a recording of a real Anthropic web-search stream.
    @Test
    fun `anthropic server tool input is not a client tool call`() {
        val parser = NativeToolCallParser(NativeToolProtocol.AnthropicMessages)
        val target = mutableMapOf<Int, ai.oriveo.community.core.model.ToolCallDelta>()
        listOf(
            """{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_01bug3W20DWB0LwoUvGoH0nW","name":"web_search","input":{}}}""",
            """{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{"}}""",
            """{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"query"}}""",
        ).forEach { raw -> NativeToolCallAccumulator.merge(target, parser.parse(null, root(raw))) }

        assertEquals(
            "the input of the built-in web search was read as a client tool call; the reply would end with a nameless tool card that nothing can execute",
            emptyList<Any>(),
            NativeToolCallAccumulator.finalize(target, "test"),
        )
    }

    @Test
    fun `gemini reads structured function call`() {
        val parser = NativeToolCallParser(NativeToolProtocol.GeminiGenerate)
        val deltas = parser.parse(
            null,
            root("""{"candidates":[{"content":{"parts":[{"functionCall":{"name":"maps","args":{"place":"Kyoto"}}}]}}]}"""),
        )
        val target = mutableMapOf<Int, ai.oriveo.community.core.model.ToolCallDelta>()
        NativeToolCallAccumulator.merge(target, deltas)

        val call = NativeToolCallAccumulator.finalize(target, "test").single()
        assertEquals("maps", call.name)
        assertEquals("{\"place\":\"Kyoto\"}", call.arguments)
    }

    @Test
    fun `prose and pseudo tags never become tool calls`() {
        NativeToolProtocol.entries.forEach { protocol ->
            val parser = NativeToolCallParser(protocol)
            val root = root("""{"choices":[{"delta":{"content":"<tool_call>{\\\"name\\\":\\\"search\\\"}</tool_call>"}}],"text":"```json tool call```"}""")
            assertTrue(parser.parse(null, root).isEmpty())
        }
    }

    private fun root(raw: String) = json.parseToJsonElement(raw).jsonObject
}
