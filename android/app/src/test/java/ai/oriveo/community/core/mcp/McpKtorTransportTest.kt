package ai.oriveo.community.core.mcp

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.toByteArray
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.ktor.utils.io.ByteReadChannel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Production transport [KtorMcpRawTransport]: wraps a MockEngine in the same client configuration production uses and
 * proves that the underlying client **does not follow redirects itself** (only `McpHttp` follows them, by policy),
 * that request headers and body go out untouched, and that response header names are lowercased.
 */
class McpKtorTransportTest {

    private val recorded = mutableListOf<io.ktor.client.request.HttpRequestData>()

    private fun transport(respond: suspend io.ktor.client.engine.mock.MockRequestHandleScope.(io.ktor.client.request.HttpRequestData) -> io.ktor.client.request.HttpResponseData): KtorMcpRawTransport {
        val engine = MockEngine { request ->
            recorded += request
            respond(request)
        }
        return KtorMcpRawTransport(HttpClient(engine) { KtorMcpRawTransport.configure(this) })
    }

    @Test
    fun `raw transport sends headers and body and never follows redirects itself`() = runBlocking {
        val raw = transport {
            respond(ByteReadChannel(""), HttpStatusCode.TemporaryRedirect, headersOf(HttpHeaders.Location, "https://evil.example/collect"))
        }
        val request = McpHttpRequest(
            url = "https://mcp.example.com/mcp",
            headers = listOf("Authorization" to "Bearer mcp_at_example", "Accept" to McpClientLimits.ACCEPT_HEADER),
            body = """{"jsonrpc":"2.0"}""".toByteArray(),
            contentType = "application/json",
        )
        val head = raw.exchange(request) { head, _ -> head }
        assertEquals(307, head.status)
        assertEquals("https://evil.example/collect", head.headers["location"])
        assertEquals(1, recorded.size)
        val sent = recorded.single()
        assertEquals("Bearer mcp_at_example", sent.headers["Authorization"])
        assertEquals(McpClientLimits.ACCEPT_HEADER, sent.headers["Accept"])
        assertEquals("application/json", sent.body.contentType?.toString())
        assertEquals("""{"jsonrpc":"2.0"}""", String(sent.body.toByteArray()))
    }

    @Test
    fun `production transport plus redirect policy never reaches the other origin`() = runBlocking {
        val raw = transport { request ->
            if (request.url.host == "mcp.example.com") {
                respond(ByteReadChannel(""), HttpStatusCode.TemporaryRedirect, headersOf(HttpHeaders.Location, "https://evil.example/collect"))
            } else {
                respond(ByteReadChannel("leaked"), HttpStatusCode.OK)
            }
        }
        val request = McpHttpRequest(url = "https://mcp.example.com/mcp", headers = listOf("Authorization" to "Bearer t"), body = ByteArray(0))
        try {
            McpHttp.send(request, raw, McpRedirectPolicy.SameOriginHttps)
            fail("a cross-origin redirect must be rejected")
        } catch (expected: McpHttpException.RedirectRejected) {
        }
        assertTrue(recorded.none { it.url.host == "evil.example" })

        recorded.clear()
        try {
            McpHttp.send(request, raw, McpRedirectPolicy.Never)
            fail("the token endpoint follows no redirect")
        } catch (expected: McpHttpException.RedirectRejected) {
        }
        assertEquals(1, recorded.size)
    }

    @Test
    fun `non-https url is refused before the transport sees it`() = runBlocking {
        val raw = transport { respond(ByteReadChannel("ok"), HttpStatusCode.OK) }
        try {
            McpHttp.send(McpHttpRequest(url = "http://mcp.example.com/mcp"), raw, McpRedirectPolicy.SameOriginHttps)
            fail("a non-https URL must not be sent")
        } catch (expected: McpHttpException.InsecureUrl) {
        }
        assertTrue(recorded.isEmpty())
    }

    @Test
    fun `same origin redirect is followed by the policy layer with headers intact`() = runBlocking {
        val raw = transport { request ->
            if (request.url.encodedPath == "/mcp") {
                respond(ByteReadChannel(""), HttpStatusCode.PermanentRedirect, headersOf(HttpHeaders.Location, "/v2/mcp"))
            } else {
                respond(ByteReadChannel("moved"), HttpStatusCode.OK, headersOf("X-Mixed-Case", "v"))
            }
        }
        val response = McpHttp.send(
            McpHttpRequest(url = "https://mcp.example.com/mcp", headers = listOf("Authorization" to "Bearer t"), body = "{}".toByteArray()),
            raw,
            McpRedirectPolicy.SameOriginHttps,
        )
        assertEquals("moved", String(response.body))
        assertEquals("v", response.headers["x-mixed-case"])
        assertEquals(listOf("/mcp", "/v2/mcp"), recorded.map { it.url.encodedPath })
        assertTrue(recorded.all { it.headers["Authorization"] == "Bearer t" && it.method.value == "POST" })
    }
}
