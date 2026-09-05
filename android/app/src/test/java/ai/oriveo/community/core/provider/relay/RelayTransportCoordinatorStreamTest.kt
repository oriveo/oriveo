package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.utils.io.ByteReadChannel
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Regression coverage for how RelayTransportCoordinator parses streaming protocols:
 *  - Anthropic thinking_delta has to be emitted as Reasoning without leaking into the
 *    answer text; it used to be dropped entirely.
 *  - A blocking finishReason from Gemini has to raise an explicit error; it used to
 *    degrade into a silent EmptyResponse.
 */
class RelayTransportCoordinatorStreamTest {

    private val json = Json { ignoreUnknownKeys = true }
    private val transportRegistry = TransportRegistry(json)

    private fun coordinator(stream: String): RelayTransportCoordinator {
        val client = HttpClient(
            MockEngine {
                respond(
                    content = ByteReadChannel(stream),
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
                )
            },
        )
        return RelayTransportCoordinator(client = client, json = json, transportRegistry = transportRegistry)
    }

    private fun anthropicStreamEvents(stream: String) = coordinator(stream).sendMessageStream(
        apiKey = "anth-key",
        modelID = "claude-sonnet-4-5",
        messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "claude-sonnet-4-5")),
        baseUrl = "https://relay.example.com/v1",
        supportsImageGen = false,
        reasoningMode = ReasoningMode.Automatic,
        webSearchEnabled = false,
        requestOptions = ChatRequestOptions(
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.AnthropicMessages,
                authMode = RelayAuthMode.XApiKey,
            ),
        ),
    )

    private fun geminiStreamEvents(stream: String) = coordinator(stream).sendMessageStream(
        apiKey = "goog-key",
        modelID = "gemini-2.5-pro",
        messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "gemini-2.5-pro")),
        baseUrl = "https://relay.example.com/v1beta",
        supportsImageGen = false,
        reasoningMode = ReasoningMode.Automatic,
        webSearchEnabled = false,
        requestOptions = ChatRequestOptions(
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.GeminiGenerateContent,
                authMode = RelayAuthMode.XGoogApiKey,
            ),
        ),
    )

    @Test
    fun `anthropic relay emits reasoning for thinking_delta without polluting text stream`() = runTest {
        val stream = ProviderTestFixtures.anthropicStream(
            ProviderTestFixtures.anthropicEvent("message_start", "{\"message\":{\"usage\":{\"input_tokens\":5}}}"),
            ProviderTestFixtures.anthropicEvent("content_block_delta", "{\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"let me think\"}}"),
            ProviderTestFixtures.anthropicEvent("content_block_delta", "{\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\" harder\"}}"),
            ProviderTestFixtures.anthropicEvent("content_block_delta", "{\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig==\"}}"),
            ProviderTestFixtures.anthropicEvent("content_block_delta", "{\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}"),
            ProviderTestFixtures.anthropicEvent("message_delta", "{\"usage\":{\"output_tokens\":3}}"),
        )

        val events = anthropicStreamEvents(stream).toList()

        val reasoning = events.filterIsInstance<StreamEvent.Reasoning>()
        assertEquals(listOf("let me think", " harder"), reasoning.map { it.text })

        // The answer stream stays clean of thinking output: the deltas carry answer text
        // only, and the final text contains no reasoning.
        val deltas = events.filterIsInstance<StreamEvent.Delta>()
        assertEquals(listOf("hello"), deltas.map { it.text })
        val done = events.last() as StreamEvent.Done
        assertEquals("hello", done.result.text)
    }

    @Test
    fun `anthropic relay text_delta stream keeps working`() = runTest {
        val stream = ProviderTestFixtures.anthropicStream(
            ProviderTestFixtures.anthropicEvent("message_start", "{\"message\":{\"usage\":{\"input_tokens\":5}}}"),
            ProviderTestFixtures.anthropicEvent("content_block_delta", "{\"delta\":{\"type\":\"text_delta\",\"text\":\"hel\"}}"),
            ProviderTestFixtures.anthropicEvent("content_block_delta", "{\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}"),
            ProviderTestFixtures.anthropicEvent("message_delta", "{\"usage\":{\"output_tokens\":3}}"),
        )

        val events = anthropicStreamEvents(stream).toList()

        val deltas = events.filterIsInstance<StreamEvent.Delta>()
        assertEquals(listOf("hel", "lo"), deltas.map { it.text })
        val done = events.last() as StreamEvent.Done
        assertEquals("hello", done.result.text)
        assertEquals(3, done.result.completionTokens)
        assertTrue(events.filterIsInstance<StreamEvent.Reasoning>().isEmpty())
    }

    @Test
    fun `gemini relay throws on finishReason SAFETY in stream`() = runTest {
        val stream = buildString {
            appendLine("""data: {"candidates":[{"content":{"parts":[{"text":"par"}]}}]}""")
            appendLine("""data: {"candidates":[{"content":{"parts":[]},"finishReason":"SAFETY"}]}""")
        }

        val collected = mutableListOf<StreamEvent>()
        try {
            geminiStreamEvents(stream).collect { collected += it }
            fail("Expected ProviderServiceError.Upstream for finishReason=SAFETY")
        } catch (error: ProviderServiceError.Upstream) {
            assertEquals(200, error.statusCode)
            assertTrue("detail should mention SAFETY: ${error.detail}", error.detail.contains("SAFETY"))
        }
        // Text already emitted before the block is not rolled back.
        assertTrue(collected.any { it is StreamEvent.Delta && it.text == "par" })
    }

    @Test
    fun `gemini relay throws on promptFeedback blockReason in stream`() = runTest {
        val stream = """data: {"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}""" + "\n"

        try {
            geminiStreamEvents(stream).toList()
            fail("Expected ProviderServiceError.Upstream for blockReason=PROHIBITED_CONTENT")
        } catch (error: ProviderServiceError.Upstream) {
            assertEquals(200, error.statusCode)
            assertTrue("detail should mention PROHIBITED_CONTENT: ${error.detail}", error.detail.contains("PROHIBITED_CONTENT"))
        }
    }

    @Test
    fun `gemini relay does not throw on STOP or MAX_TOKENS finish reasons`() = runTest {
        val stream = buildString {
            appendLine("""data: {"candidates":[{"content":{"parts":[{"text":"hello"}]},"finishReason":"MAX_TOKENS"}]}""")
            appendLine("""data: {"candidates":[{"content":{"parts":[]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":5}}""")
        }

        val events = geminiStreamEvents(stream).toList()

        assertEquals("hello", (events.first() as StreamEvent.Delta).text)
        val done = events.last() as StreamEvent.Done
        assertEquals("hello", done.result.text)
    }
}
