package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import java.net.SocketTimeoutException
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayDiscoveryServiceTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `html success continues to the next candidate and duplicate ids keep first occurrence`() = runTest {
        val requestedPaths = mutableListOf<String>()
        val service = service { request ->
            requestedPaths += request.url.encodedPath
            when (request.url.encodedPath) {
                "/models" -> respond("<html>fallback</html>", HttpStatusCode.OK)
                "/v1/models" -> respond(
                    """{"data":[{"id":"gpt-a"},{"id":"gpt-a"},{"name":"gpt-b"}]}""",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
                )
                else -> respond("", HttpStatusCode.NotFound)
            }
        }

        val result = service.discover(
            endpoint = "https://relay.test/chat/completions",
            apiKey = "sk-test",
            modelHint = null,
        )

        assertEquals(listOf("/models", "/v1/models"), requestedPaths)
        assertEquals(listOf("gpt-a", "gpt-b"), result.detections.first().modelIDs)
        assertEquals(RelayDiscoveryFailureKind.InvalidResponse, result.attempts.first().failure)
    }

    @Test
    fun `authentication rejection terminates discovery immediately`() = runTest {
        var requestCount = 0
        val service = service {
            requestCount += 1
            respond("denied", HttpStatusCode.Unauthorized)
        }

        val result = service.discover("https://relay.test", "bad-key", null)

        assertEquals(1, requestCount)
        assertEquals(RelayDiscoveryFailureKind.AuthenticationRejected, result.blockingFailure)
        assertTrue(result.detections.isEmpty())
    }

    @Test
    fun `rate limit terminates immediately without retrying`() = runTest {
        var requestCount = 0
        val service = service(retryBackoffMs = listOf(0L, 0L)) {
            requestCount += 1
            respond("slow down", HttpStatusCode.TooManyRequests)
        }

        val result = service.discover("https://relay.test", "sk-test", null)

        assertEquals(1, requestCount)
        assertEquals(RelayDiscoveryFailureKind.RateLimited, result.blockingFailure)
        assertEquals("slow down", result.attempts.single().upstreamMessage)
    }

    @Test
    fun `server failure terminates immediately without retrying`() = runTest {
        var requestCount = 0
        val service = service(retryBackoffMs = listOf(0L, 0L)) {
            requestCount += 1
            respond("upstream unavailable", HttpStatusCode.ServiceUnavailable)
        }

        val result = service.discover("https://relay.test", "sk-test", null)

        assertEquals(1, requestCount)
        assertEquals(RelayDiscoveryFailureKind.TemporaryFailure, result.blockingFailure)
        assertEquals("upstream unavailable", result.attempts.single().upstreamMessage)
    }

    @Test
    fun `responses generation probe detects a route after every catalog route is missing`() = runTest {
        val requestedPaths = mutableListOf<String>()
        val service = service { request ->
            requestedPaths += request.url.encodedPath
            if (request.url.encodedPath == "/v1/responses") {
                respond("model missing", HttpStatusCode.BadRequest)
            } else {
                respond("not found", HttpStatusCode.NotFound)
            }
        }

        val result = service.discover("https://relay.test", "sk-test", null)

        val detection = result.detections.single()
        assertEquals(RelayTransport.OpenAIResponses, detection.transport)
        assertEquals(RelayDetectionEvidence.GenerationProbe, detection.detectionEvidence)
        assertFalse(detection.generationVerified)
        assertTrue(requestedPaths.contains("/v1/responses"))
        assertFalse(requestedPaths.contains("/v1/models/$SENTINEL:generateContent"))
    }

    @Test
    fun `generation probe continues after an html fallback success`() = runTest {
        val requestedPaths = mutableListOf<String>()
        val service = service { request ->
            requestedPaths += request.url.encodedPath
            when (request.url.encodedPath) {
                "/v1/chat/completions" -> respond("<html>fallback</html>", HttpStatusCode.OK)
                "/chat/completions" -> respond("model missing", HttpStatusCode.BadRequest)
                else -> respond("not found", HttpStatusCode.NotFound)
            }
        }

        val result = service.discover(
            endpoint = "https://relay.test",
            apiKey = "sk-test",
            modelHint = null,
            forcedTransport = RelayTransport.OpenAIChatCompletions,
        )

        assertEquals(RelayTransport.OpenAIChatCompletions, result.detections.single().transport)
        assertEquals(
            listOf("/v1/chat/completions", "/chat/completions"),
            result.attempts
                .filter { it.kind == RelayDiscoveryAttemptKind.GenerationProbe }
                .map { java.net.URI(it.requestUrl).path },
        )
        assertEquals(
            RelayDiscoveryFailureKind.InvalidResponse,
            result.attempts.first { it.requestUrl.endsWith("/v1/chat/completions") }.failure,
        )
    }

    @Test
    fun `sentinel probe json success detects route without claiming generation verification`() = runTest {
        val service = service { request ->
            if (request.url.encodedPath.endsWith("/chat/completions")) {
                respond("{}", HttpStatusCode.OK)
            } else {
                respond("not found", HttpStatusCode.NotFound)
            }
        }

        val result = service.discover(
            endpoint = "https://relay.test",
            apiKey = "sk-test",
            modelHint = null,
            forcedTransport = RelayTransport.OpenAIChatCompletions,
        )

        val detection = result.detections.single()
        assertEquals(RelayDetectionEvidence.GenerationProbe, detection.detectionEvidence)
        assertFalse(detection.generationVerified)
        assertTrue(detection.modelIDs.isEmpty())
    }

    @Test
    fun `user model accepts an SSE success response`() = runTest {
        val service = service { request ->
            if (request.url.encodedPath.endsWith("/responses")) {
                respond(
                    "data: {\"output\":[]}\n\ndata: [DONE]\n\n",
                    HttpStatusCode.OK,
                    headersOf(HttpHeaders.ContentType, ContentType.Text.EventStream.toString()),
                )
            } else {
                respond("not found", HttpStatusCode.NotFound)
            }
        }

        val result = service.discover(
            endpoint = "https://relay.test/v1/responses",
            apiKey = "sk-test",
            modelHint = "gpt-relay",
        )

        assertEquals(RelayTransport.OpenAIResponses, result.detections.single().transport)
        assertTrue(result.detections.single().generationVerified)
    }

    @Test
    fun `transient timeout retries the same request before succeeding`() = runTest {
        var requestCount = 0
        val service = service(retryBackoffMs = listOf(0L, 0L)) {
            requestCount += 1
            if (requestCount < 3) throw SocketTimeoutException("timed out")
            respond("""{"data":[]}""", HttpStatusCode.OK)
        }

        val result = service.discover("https://relay.test", "sk-test", null)

        assertEquals(3, requestCount)
        assertNull(result.blockingFailure)
        assertTrue(result.detections.isNotEmpty())
    }

    @Test
    fun `exhausted transient retries report root cause and retry count`() = runTest {
        var requestCount = 0
        val service = service(retryBackoffMs = listOf(0L, 0L)) {
            requestCount += 1
            throw SocketTimeoutException("socket timed out")
        }

        val result = service.discover("https://relay.test", "sk-test", null)

        assertEquals(3, requestCount)
        assertEquals(RelayDiscoveryFailureKind.Network, result.blockingFailure)
        val attempt = result.attempts.single()
        val message = attempt.upstreamMessage.orEmpty()
        assertTrue(message.contains("socket timed out"))
        assertFalse(message.contains("Retried"))
        assertEquals(2, attempt.retryCount)
    }

    @Test
    fun `embedded query and user info are rejected before sending a request`() = runTest {
        var requestCount = 0
        val service = service {
            requestCount += 1
            respond("unexpected", HttpStatusCode.OK)
        }

        val queryResult = service.discover("https://relay.test/v1?token=secret", "sk-test", null)
        val userInfoResult = service.discover("https://user:pass@relay.test/v1", "sk-test", null)

        assertEquals(0, requestCount)
        assertEquals(RelayDiscoveryFailureKind.EmbeddedQuery, queryResult.blockingFailure)
        assertEquals(RelayDiscoveryFailureKind.InvalidEndpoint, userInfoResult.blockingFailure)
    }

    @Test
    fun `cross origin redirect is never followed with credentials`() = runTest {
        val requestedHosts = mutableListOf<String>()
        val service = service { request ->
            requestedHosts += request.url.host
            respond(
                "redirect",
                HttpStatusCode.Found,
                headersOf(HttpHeaders.Location, "https://other.test/models"),
            )
        }

        val result = service.discover(
            endpoint = "https://relay.test/chat/completions",
            apiKey = "sk-secret",
            modelHint = null,
            includeGenerationProbe = false,
        )

        assertEquals(setOf("relay.test"), requestedHosts.toSet())
        assertEquals(RelayDiscoveryFailureKind.InvalidResponse, result.blockingFailure)
    }

    @Test
    fun `local discovery uses the configured transport security and auth path`() = runTest {
        val requests = mutableListOf<io.ktor.client.request.HttpRequestData>()
        val service = service { request ->
            requests += request
            respond(
                """{"data":[{"id":"local-model"}]}""",
                HttpStatusCode.OK,
                headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }
        val requested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            authMode = RelayAuthMode.None,
            securityMode = RelayConnectionSecurityMode.LocalHttp,
            headers = listOf(RelayKeyValue("X-Trace", "preserved-in-draft")),
            queryParams = listOf(RelayKeyValue("tenant", "preserved-in-draft")),
        )

        val result = service.discover(
            endpoint = "http://127.0.0.1:11434/v1",
            apiKey = "",
            modelHint = null,
            forcedTransport = RelayTransport.OpenAIChatCompletions,
            includeGenerationProbe = false,
            relayRequested = requested,
        )

        assertTrue(result.toString(), result.detections.isNotEmpty())
        assertEquals(
            listOf("local-model"),
            result.detections.first { it.transport == RelayTransport.OpenAIChatCompletions }.modelIDs,
        )
        assertTrue(requests.isNotEmpty())
        requests.forEach { sent ->
            assertEquals("127.0.0.1", sent.url.host)
            assertNull(sent.headers[HttpHeaders.Authorization])
            assertNull(sent.headers["X-Trace"])
            assertNull(sent.url.parameters["tenant"])
        }
    }

    private fun service(
        retryBackoffMs: List<Long> = emptyList(),
        handler: suspend io.ktor.client.engine.mock.MockRequestHandleScope.(io.ktor.client.request.HttpRequestData) -> io.ktor.client.request.HttpResponseData,
    ): RelayDiscoveryService = RelayDiscoveryService(
        client = HttpClient(MockEngine(handler)),
        json = json,
        retryBackoffMs = retryBackoffMs,
    )

    private companion object {
        const val SENTINEL = RelayDiscoveryService.SENTINEL_PROBE_MODEL_ID
    }
}
