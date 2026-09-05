package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * End-to-end citation stream: after the service is wired through TransportRegistry, citations
 * still flow all the way through.
 *
 * A canned SSE stream containing a web_search_tool_result block is injected through MockEngine and
 * travels AnthropicService -> strategy.parseCitations -> emitted Citations events -> accumulation,
 * and the test finally asserts that StreamEvent.Citations appears with the right URL and title.
 */
class CitationsStreamE2ETest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry = TransportRegistry(json)

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `anthropic service emits Citations event from web_search_tool_result chunk`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Anthropic,
                defaultModelId = "claude-sonnet-4",
                resolveMap = mapOf("claude-sonnet-4" to "claude-sonnet-4"),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        "claude-sonnet-4",
                        displayName = "Claude Sonnet 4",
                    ),
                ),
            )
        )

        // An Anthropic streaming response: message_start -> content_block_start (web_search_tool_result) -> message_delta,
        // where the content[] inside content_block_start carries url / title / cited_text.
        val sse = """
            event: message_start
            data: {"message":{"usage":{"input_tokens":15}}}

            event: content_block_start
            data: {"index":0,"content_block":{"type":"web_search_tool_result","content":[{"url":"https://anthropic.example/article-a","title":"Article A","cited_text":"snippet A"},{"url":"https://anthropic.example/article-b","title":"Article B","cited_text":"snippet B"}]}}

            event: content_block_delta
            data: {"delta":{"type":"text_delta","text":"hi"}}

            event: message_delta
            data: {"usage":{"output_tokens":5}}

        """.trimIndent()

        val client = HttpClient(
            MockEngine {
                respond(
                    content = sse,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/event-stream"),
                )
            }
        )
        val service = AnthropicService(client, json, transportRegistry)
        val events = service.sendMessageStream(
            apiKey = "sk-test",
            modelID = "claude-sonnet-4",
            messages = listOf(userMessage("search")),
            baseUrl = null,
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = true,
            requestOptions = ChatRequestOptions(),
        ).toList()

        // At least one Citations event has to show up
        val citationEvents = events.filterIsInstance<StreamEvent.Citations>()
        assertTrue("Expected at least one StreamEvent.Citations", citationEvents.isNotEmpty())

        // Flatten every citation into a single list
        val allUrls = citationEvents.flatMap { it.citations }.map { it.url }
        assertEquals(
            listOf(
                "https://anthropic.example/article-a",
                "https://anthropic.example/article-b",
            ),
            allUrls,
        )

        // Delta events are still delivered alongside them
        val deltas = events.filterIsInstance<StreamEvent.Delta>()
        assertTrue("Expected at least one Delta event", deltas.isNotEmpty())
    }

    private fun userMessage(text: String): ChatMessage = ChatMessage(
        id = "msg-1",
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.Anthropic,
        providerName = "Anthropic",
        modelID = "claude-sonnet-4",
        modelName = "Claude Sonnet 4",
        state = ChatMessageState.Delivered,
    )
}
