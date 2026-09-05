package ai.oriveo.community.core.provider

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.JsonArray
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalEngineContractTest {
    @Test
    fun `response fingerprints reject wrong engine on correct port`() {
        assertEquals(
            LocalEngineState.WrongEngine,
            LocalEngineContract.classify(LocalEngineKind.LlamaCpp, 200, "text/html", "<html>not llama.cpp</html>"),
        )
        assertEquals(
            LocalEngineState.Ready,
            LocalEngineContract.classify(LocalEngineKind.LlamaCpp, 200, "application/json", Json.parseToJsonElement("{\"status\":\"ok\"}").jsonObject),
        )
        assertEquals(
            LocalEngineState.Ready,
            LocalEngineContract.classify(LocalEngineKind.Ollama, 200, "application/json", Json.parseToJsonElement("{\"models\":[{\"name\":\"fixture:latest\"}]}").jsonObject),
        )
    }

    @Test
    fun `lm studio metadata paths and classify shape stay paired on api v0`() {
        // Captured from a real LM Studio instance: /api/v0/models carries a per-model
        // `state`, while the OpenAI-compatible /v1/models does not. classify keys off
        // data[].state because that is the only shape that tells LM Studio apart from vLLM,
        // so letting the probe path fall back to /v1/models is a regression.
        val v0Payload = """{"data":[{"id":"qwen/qwen3-0.6b","object":"model","type":"llm","state":"loaded","max_context_length":40960}],"object":"list"}"""
        val openAIPayload = """{"data":[{"id":"qwen/qwen3-0.6b","object":"model","owned_by":"organization_owner"}],"object":"list"}"""
        assertEquals(
            LocalEngineState.Ready,
            LocalEngineContract.classify(LocalEngineKind.LmStudio, 200, "application/json", Json.parseToJsonElement(v0Payload).jsonObject),
        )
        assertEquals(
            LocalEngineState.WrongEngine,
            LocalEngineContract.classify(LocalEngineKind.LmStudio, 200, "application/json", Json.parseToJsonElement(openAIPayload).jsonObject),
        )
        val template = LocalEngineContract.templates.getValue(LocalEngineKind.LmStudio)
        assertEquals("/api/v0/models", template.probePath)
        assertEquals("/api/v0/models", template.catalogPath)
        assertEquals("/api/v0/models", template.introspectionPath)
    }

    @Test
    fun `ollama cloud suffix is not labeled local`() {
        assertEquals("cloud", LocalEngineContract.modelLocality(LocalEngineKind.Ollama, "fixture:cloud"))
        assertEquals("local", LocalEngineContract.modelLocality(LocalEngineKind.Ollama, "fixture:latest"))
    }

    @Test
    fun `runtime parser keeps unobserved metrics null from a production payload`() {
        val payload = Json.parseToJsonElement("""[{"id":0,"n_past":128,"n_ctx":4096}]""") as JsonArray
        val snapshot = LocalRuntimeParser.snapshot(payload, "llamacpp:requests_waiting 2\n")
        assertEquals(128, snapshot.contextUsed)
        assertEquals(4096, snapshot.contextLimit)
        assertEquals(2, snapshot.queueDepth)
        assertEquals(null, snapshot.cpuPercent)
        assertEquals(null, snapshot.gpuPercent)
        assertEquals(null, snapshot.tokensPerSecond)
    }

    @Test
    fun `open webui is the fifth bearer compatible template`() {
        val template = LocalEngineContract.templates.getValue(LocalEngineKind.OpenWebUI)
        assertEquals("/api/models", template.catalogPath)
        assertEquals(listOf("/api/chat/completions"), template.generationPaths)
        assertEquals("openai_chat_completions", LocalEngineGenerationProfiles.profile("openwebui")?.template)
        assertEquals(listOf("/api/embeddings"), template.capabilityPaths["embedding"])
        assertEquals(listOf("/rerank", "/v1/rerank"), LocalEngineContract.templates.getValue(LocalEngineKind.LlamaCpp).capabilityPaths["rerank"])
    }

    @Test
    fun `runtime preflight uses template and tokenize and detects context overflow`() = runTest {
        val paths = mutableListOf<String>()
        val engine = MockEngine { request ->
            paths += request.url.encodedPath
            val body = when (request.url.encodedPath) {
                "/apply-template" -> """{"prompt":"templated prompt"}"""
                "/tokenize" -> """{"tokens":[1,2,3,4,5]}"""
                else -> "{}"
            }
            respond(body, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()))
        }
        val client = LocalEngineRuntimeClient(HttpClient(engine), Json { ignoreUnknownKeys = true })

        val result = client.preflight("http://127.0.0.1:8080", LocalEngineKind.LlamaCpp, "hello", 4)

        assertEquals(LocalPromptPreflight.Supported(tokens = 5, contextLimit = 4, exceedsContext = true), result)
        assertEquals(listOf("/apply-template", "/tokenize"), paths)
    }

    @Test
    fun `runtime preflight failure degrades and prompt cache uses slot action`() = runTest {
        val engine = MockEngine { request ->
            if (request.url.encodedPath == "/apply-template") {
                respond("", HttpStatusCode.NotFound)
            } else {
                assertEquals("/slots/3", request.url.encodedPath)
                assertEquals("save", request.url.parameters["action"])
                assertEquals("chat-cache", request.url.parameters["filename"])
                respond("{}", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()))
            }
        }
        val client = LocalEngineRuntimeClient(HttpClient(engine), Json { ignoreUnknownKeys = true })

        assertEquals(
            LocalPromptPreflight.Unavailable,
            client.preflight("http://127.0.0.1:8080", LocalEngineKind.LlamaCpp, "hello", null),
        )
        client.promptCache("http://127.0.0.1:8080", slotID = 3, action = "save", cacheName = "chat-cache")
    }

    @Test
    fun `discovery results stay local and runtime fingerprint hides endpoint`() {
        assertFalse(LocalEngineDiscoverySession.uploadsResults)
        val fingerprint = LocalRuntimeSettingsStore.fingerprint("http://secret-box.local:8080", LocalEngineKind.LlamaCpp)
        assertFalse(fingerprint.contains("secret-box"))
        assertTrue(fingerprint.isNotBlank())
    }
}
