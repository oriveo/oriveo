package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.StreamActivity
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Edge cases of the closed signal set: where the event name comes from (the `event:` line or the
 * `type` in the payload) and unknown values.
 *
 * The full production parsing path (real SSE to service to StreamEvent.Activity) is covered in
 * AnthropicServiceTest, OpenAIServiceTest and MoonshotServiceTest.
 */
class StreamActivitySignalsTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `responses signal reads the event name from the payload when the event line is absent`() {
        val added = root(
            """{"type":"response.output_item.added","output_index":1,"item":{"id":"ws_1","type":"web_search_call","status":"in_progress"}}""",
        )
        // The Responses stream of OpenAICompatibleService (Grok and others) has no event: line, so
        // the event name is only in the payload.
        assertEquals(StreamActivity.WebSearch, StreamActivitySignals.openAIResponses(null, added))
        // OpenAIService passes an empty string when there is no event: line; the signal must
        // not be lost because of it.
        assertEquals(StreamActivity.WebSearch, StreamActivitySignals.openAIResponses("", added))
    }

    @Test
    fun `responses signal ignores the done event and non web search items`() {
        assertNull(
            StreamActivitySignals.openAIResponses(
                "response.output_item.done",
                root("""{"item":{"id":"ws_1","type":"web_search_call","status":"completed"}}"""),
            ),
        )
        listOf("function_call", "file_search_call", "reasoning", "message").forEach { type ->
            assertNull(
                type,
                StreamActivitySignals.openAIResponses(
                    "response.output_item.added",
                    root("""{"item":{"type":"$type","name":"web_search"}}"""),
                ),
            )
        }
        assertNull(StreamActivitySignals.openAIResponses("response.output_item.added", root("""{"item":"web_search_call"}""")))
    }

    @Test
    fun `anthropic signal requires server_tool_use named web_search on a block start`() {
        val block = """{"content_block":{"type":"server_tool_use","name":"web_search"}}"""
        assertEquals(StreamActivity.WebSearch, StreamActivitySignals.anthropicMessages("content_block_start", root(block)))
        assertEquals(
            StreamActivity.WebSearch,
            StreamActivitySignals.anthropicMessages(
                null,
                root("""{"type":"content_block_start","content_block":{"type":"server_tool_use","name":"web_search"}}"""),
            ),
        )
        assertNull(StreamActivitySignals.anthropicMessages("content_block_delta", root(block)))
        assertNull(
            StreamActivitySignals.anthropicMessages(
                "content_block_start",
                root("""{"content_block":{"type":"tool_use","name":"web_search"}}"""),
            ),
        )
        assertNull(
            StreamActivitySignals.anthropicMessages(
                "content_block_start",
                root("""{"content_block":{"type":"server_tool_use","name":"web_fetch"}}"""),
            ),
        )
    }

    @Test
    fun `moonshot signal accepts only the exact closed set value`() {
        assertEquals(StreamActivity.WebSearch, StreamActivitySignals.moonshotToolCall("\$web_search"))
        listOf("web_search", "search", "\$web_fetch", "", null).forEach { name ->
            assertNull("$name", StreamActivitySignals.moonshotToolCall(name))
        }
    }

    private fun root(raw: String) = json.parseToJsonElement(raw).jsonObject
}
