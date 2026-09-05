package ai.oriveo.community.core.provider.relay

import android.content.Context
import ai.oriveo.community.R
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class RelayTransportCoordinatorResponseTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `chat completions HTML success response stays visible but is not reportable`() = runTest {
        assertMalformedSuccessResponse(RelayTransport.OpenAIChatCompletions)
    }

    @Test
    fun `responses HTML success response stays visible but is not reportable`() = runTest {
        assertMalformedSuccessResponse(RelayTransport.OpenAIResponses)
    }

    @Test
    fun `malformed success response uses localized fallback when guidance code is absent`() = runTest {
        val error = captureMalformedSuccessResponse(RelayTransport.OpenAIChatCompletions)
        val context: Context = mockk()
        every { context.getString(R.string.error_upstream_message) } returns "localized upstream error"

        assertEquals(
            "localized upstream error",
            ErrorMapper.localizeProviderErrorMessage(error, context),
        )
    }

    @Test
    fun `valid JSON schema mismatch remains reportable without persisting response body`() = runTest {
        val upstreamSecret = "sk-upstream-echo-must-not-survive"
        val coordinator = coordinator("""{"choices":"$upstreamSecret"}""")
        val error = try {
            sendMessage(coordinator, RelayTransport.OpenAIChatCompletions)
            throw AssertionError("Expected valid JSON with the wrong schema to fail")
        } catch (error: SerializationException) {
            error
        }

        assertEquals(
            "The custom LLM returned JSON that does not match the expected response schema.",
            error.message,
        )
        assertFalse(error.message.orEmpty().contains(upstreamSecret))
    }

    @Test
    fun `resolved API root is used exactly without inserting v1`() = runTest {
        var requestedUrl: String? = null
        val client = HttpClient(
            MockEngine { request ->
                requestedUrl = request.url.toString()
                respond(
                    content = """{"choices":[{"message":{"content":"pong"}}]}""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
            },
        )
        val coordinator = RelayTransportCoordinator(
            client = client,
            json = json,
            transportRegistry = TransportRegistry(json),
        )

        coordinator.sendMessage(
            apiKey = "relay-key",
            modelID = "model",
            messages = listOf(ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "model")),
            baseUrl = "https://relay.example.com/original",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIChatCompletions,
                    authMode = RelayAuthMode.Bearer,
                    stream = false,
                    resolvedAPIBaseURL = "https://relay.example.com/custom/api",
                ),
            ),
        )

        assertEquals("https://relay.example.com/custom/api/chat/completions", requestedUrl)
    }

    private suspend fun assertMalformedSuccessResponse(transport: RelayTransport) {
        val error = captureMalformedSuccessResponse(transport)

        assertEquals(HttpStatusCode.OK.value, error.statusCode)
        assertEquals(
            "Upstream HTTP 200: The custom LLM returned malformed JSON.",
            error.technicalDetail,
        )
        assertFalse(error.technicalDetail.contains("<!doctype html>"))
    }

    private suspend fun captureMalformedSuccessResponse(
        transport: RelayTransport,
    ): ProviderServiceError.RelayUpstream {
        val coordinator = coordinator("<!doctype html><html lang=\"zh\"><body>Relay home</body></html>")
        return try {
            sendMessage(coordinator, transport)
            throw AssertionError("Expected malformed Relay response to fail for $transport")
        } catch (error: ProviderServiceError.RelayUpstream) {
            error
        }
    }

    private suspend fun sendMessage(
        coordinator: RelayTransportCoordinator,
        transport: RelayTransport,
    ) {
        coordinator.sendMessage(
            apiKey = "relay-key",
            modelID = "claude-opus-4-8",
            messages = listOf(
                ProviderTestFixtures.userMessage("Hi", ProviderKind.Relay, "claude-opus-4-8"),
            ),
            baseUrl = "https://relay.example.com/v1",
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = ChatRequestOptions(
                relayRequested = RelayRequestedConfig(
                    transport = transport,
                    authMode = RelayAuthMode.Bearer,
                    stream = false,
                ),
            ),
        )
    }

    private fun coordinator(responseBody: String): RelayTransportCoordinator {
        val client = HttpClient(
            MockEngine {
                respond(
                    content = responseBody,
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, ContentType.Text.Html.toString()),
                )
            },
        )
        return RelayTransportCoordinator(
            client = client,
            json = json,
            transportRegistry = TransportRegistry(json),
        )
    }
}
