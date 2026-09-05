package ai.oriveo.community.core.provider

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Release-only real-engine matrix. Every case enters through [LocalEngineConnector] and then uses
 * [RelayService] for non-streaming, streaming, and cancellation; no fixture server can satisfy it.
 */
@RunWith(AndroidJUnit4::class)
class LocalEngineReleaseRuntimeTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val client = HttpClient(OkHttp) { expectSuccess = false }
    private val relayService = RelayService(client, json, TransportRegistry(json))
    private val connector = LocalEngineConnector(client, json, relayService)
    private val arguments get() = InstrumentationRegistry.getArguments()

    @After
    fun closeClient() {
        client.close()
    }

    @Test
    fun ollama() = verifyRuntime(
        engine = LocalEngineKind.Ollama,
        endpoint = endpoint("ollamaPort", 11_435),
    )

    @Test
    fun llamaCpp() = verifyRuntime(
        engine = LocalEngineKind.LlamaCpp,
        endpoint = endpoint("llamaCppPort", 8_080),
    )

    @Test
    fun lmStudio() = verifyRuntime(
        engine = LocalEngineKind.LmStudio,
        endpoint = endpoint("lmStudioPort", 1_234),
    )

    @Test
    fun vLLM() = verifyRuntime(
        engine = LocalEngineKind.Vllm,
        endpoint = endpoint("vllmPort", 8_000),
    )

    @Test
    fun openWebUI() {
        val endpoint = requiredArgument("openWebUIUrl")
        assertTrue(endpoint.startsWith("https://"))
        val keyURL = requiredArgument("openWebUIKeyUrl")
        assertTrue(keyURL.startsWith("https://"))
        verifyRuntime(
            engine = LocalEngineKind.OpenWebUI,
            endpoint = endpoint,
            securityMode = RelayConnectionSecurityMode.RemoteHttps,
            apiKey = fetchRuntimeCredential(keyURL),
        )
    }

    private fun verifyRuntime(
        engine: LocalEngineKind,
        endpoint: String,
        securityMode: RelayConnectionSecurityMode = RelayConnectionSecurityMode.LocalHttp,
        apiKey: String = "",
    ) = runBlocking {
        val connection = withTimeout(60_000) {
            connector.connect(
                engine = engine,
                rawEndpoint = endpoint,
                securityMode = securityMode,
                apiKey = apiKey,
            )
        }
        assertEquals(engine, connection.engine)
        assertFalse(connection.modelIds.isEmpty())
        assertTrue(connection.selectedModelId in connection.modelIds)

        val message = message("Reply with exactly OK.", connection.selectedModelId)
        val nonStreaming = withTimeout(60_000) {
            relayService.sendMessage(
                apiKey = apiKey,
                modelID = connection.selectedModelId,
                messages = listOf(message),
                baseUrl = connection.apiBaseUrl,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(
                    maxTokens = 32,
                    relayRequested = connection.requested.copy(stream = false),
                ),
            )
        }
        assertTrue(nonStreaming.result.text.isNotBlank())

        val streamedText = StringBuilder()
        withTimeout(60_000) {
            relayService.sendMessageStream(
                apiKey = apiKey,
                modelID = connection.selectedModelId,
                messages = listOf(message),
                baseUrl = connection.apiBaseUrl,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(
                    maxTokens = 32,
                    relayRequested = connection.requested.copy(stream = true),
                ),
            ).collect { event ->
                if (event is StreamEvent.Delta) streamedText.append(event.text)
            }
        }
        assertTrue(streamedText.isNotBlank())

        val firstStreamEvent = CompletableDeferred<Unit>()
        val cancellation = launch {
            relayService.sendMessageStream(
                apiKey = apiKey,
                modelID = connection.selectedModelId,
                messages = listOf(message("Count upward slowly from one to one thousand.", connection.selectedModelId)),
                baseUrl = connection.apiBaseUrl,
                supportsImageGen = false,
                reasoningMode = ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = ChatRequestOptions(
                    maxTokens = 512,
                    relayRequested = connection.requested.copy(stream = true),
                ),
            ).collect { event ->
                if (event is StreamEvent.Delta || event is StreamEvent.Reasoning) {
                    firstStreamEvent.complete(Unit)
                }
            }
        }
        withTimeout(60_000) { firstStreamEvent.await() }
        cancellation.cancelAndJoin()
        assertTrue(cancellation.isCancelled)
    }

    private fun endpoint(portArgument: String, defaultPort: Int): String =
        "http://${requiredArgument("runtimeHost")}:${arguments.getString(portArgument)?.toIntOrNull() ?: defaultPort}"

    private fun requiredArgument(name: String): String =
        arguments.getString(name)?.trim()?.takeIf(String::isNotEmpty)
            ?: error("missing instrumentation argument: $name")

    private fun fetchRuntimeCredential(rawURL: String): String {
        val connection = URL(rawURL).openConnection() as HttpURLConnection
        connection.connectTimeout = 10_000
        connection.readTimeout = 10_000
        connection.instanceFollowRedirects = false
        try {
            assertTrue(connection.responseCode in 200..299)
            val bytes = connection.inputStream.use { it.readBytes() }
            assertTrue(bytes.size < 512)
            return bytes.toString(Charsets.UTF_8).trim().also { assertTrue(it.isNotEmpty()) }
        } finally {
            connection.disconnect()
        }
    }

    private fun message(text: String, modelID: String) = ChatMessage(
        id = UUID.randomUUID().toString(),
        role = ChatRole.User,
        text = text,
        providerKind = ProviderKind.Relay,
        providerName = "Release runtime",
        modelID = modelID,
        modelName = modelID,
        state = ChatMessageState.Delivered,
    )
}
