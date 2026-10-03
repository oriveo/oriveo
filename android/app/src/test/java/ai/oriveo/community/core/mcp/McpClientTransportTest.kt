package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.mcp.McpClientHarness.Companion.eventually
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.REQUEST_ID_PLACEHOLDER
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.json
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.redirect
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.sse
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.status
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.stub
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.textResult
import java.net.SocketTimeoutException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Transport layer of the protocol client.
 *
 * Redirects, https, byte limits, streaming SSE, strict id matching, cancellation, timeouts. Every assertion exercises the production path of `McpClient`:
 * requests are sent by production code, and assertions are on the requests the replay layer actually received (or did not) and the error codes production code produced.
 */
class McpClientTransportTest {

    private val harness = McpClientHarness()
    private val transport get() = harness.transport
    private val weather = McpClientHarness.weatherArguments

    private suspend fun callError(client: McpClient, name: String = "get_weather"): McpErrorCode? = try {
        client.callTool(name, weather)
        null
    } catch (error: McpClientException) {
        error.code
    }

    /** A "connection cut off" record is recognized by the tool name unique to each test case. */
    private suspend fun wasAborted(toolName: String) = eventually {
        transport.abortedRequests().any { it.jsonRpcMethod == "tools/call" && it.jsonRpcName == toolName }
    }

    // ── Redirects ────────────────────────────────────────

    @Test
    fun `probe redirected cross-origin is unreachable and second host gets nothing`() = runBlocking {
        transport.enqueue(redirect(EVIL), stub("protocol/stateless/tools-list.response.json"))
        val outcome = harness.client().connect(bearerToken = "mcp_at_example")
        assertEquals(McpConnectOutcome.Unreachable, outcome)
        val requests = transport.requests()
        assertEquals(1, requests.size)
        assertEquals("mcp.example.com", requests.first().host)
        assertEquals("Bearer mcp_at_example", requests.first().header("Authorization"))
        assertFalse("the second host must receive no request after a cross-origin redirect", requests.any { it.host == "evil.example" })
    }

    @Test
    fun `tools call redirected cross-origin leaks neither token nor arguments`() = runBlocking {
        val client = harness.modern(listOf(redirect(EVIL), json(textResult("leaked"))), bearerToken = "mcp_at_example")
        assertEquals(McpErrorCode.Unreachable, callError(client))
        assertFalse(transport.requests().any { it.host == "evil.example" })
        assertEquals(1, transport.requests("tools/call").size)
    }

    @Test
    fun `downgrade to http and different port are not same origin`() = runBlocking {
        for (target in listOf("http://mcp.example.com/mcp", "https://mcp.example.com:8443/mcp")) {
            val client = harness.modern(listOf(redirect(target), json(textResult("leaked"))), bearerToken = "mcp_at_example")
            assertEquals(target, McpErrorCode.Unreachable, callError(client))
            assertEquals(target, 1, transport.requests("tools/call").size)
            assertFalse(target, transport.requests().any { it.url == target })
        }
    }

    @Test
    fun `relative redirect resolving to another origin is rejected`() = runBlocking {
        val client = harness.modern(listOf(redirect("//evil.example/collect"), json(textResult("leaked"))), bearerToken = "mcp_at_example")
        assertEquals(McpErrorCode.Unreachable, callError(client))
        assertFalse(transport.requests().any { it.host == "evil.example" })
    }

    @Test
    fun `same-origin https method-preserving redirect is followed with the token on both hops`() = runBlocking {
        val client = harness.modern(
            listOf(redirect("https://mcp.example.com/v2/mcp"), json(textResult("moved"))),
            bearerToken = "mcp_at_example",
        )
        assertEquals("moved", client.callTool("get_weather", weather).text)
        val calls = transport.requests("tools/call")
        assertEquals(listOf("/mcp", "/v2/mcp"), calls.map { it.path })
        assertTrue(calls.all { it.host == "mcp.example.com" })
        assertTrue(calls.all { it.header("Authorization") == "Bearer mcp_at_example" })
    }

    @Test
    fun `redirect that would rewrite POST to GET is not followed`() = runBlocking {
        for (code in listOf(301, 302, 303)) {
            val client = harness.modern(listOf(redirect("https://mcp.example.com/v2/mcp", status = code), json(textResult("moved"))))
            assertEquals("$code", McpErrorCode.Unreachable, callError(client))
            assertFalse(transport.requests().any { it.method == "GET" })
            assertEquals(1, transport.requests("tools/call").size)
        }
    }

    @Test
    fun `same-origin redirects stop after five hops`() = runBlocking {
        transport.setFallback(redirect("https://mcp.example.com/mcp"))
        assertEquals(McpConnectOutcome.Unreachable, harness.client().connect())
        assertEquals(McpHttpLimits.MAX_REDIRECTS + 1, transport.requests().size)
    }

    // ── https only ────────────────────────────────────────

    @Test
    fun `non-https endpoint sends nothing`() = runBlocking {
        transport.enqueue(stub("protocol/stateless/tools-list.response.json"))
        val client = harness.client(endpoint = "http://mcp.example.com/mcp")
        assertEquals(McpConnectOutcome.Unreachable, client.connect(bearerToken = "mcp_at_example"))
        assertTrue(transport.requests().isEmpty())
    }

    // ── Resource limits ────────────────────────────────────────

    @Test
    fun `response body over 8 MB is server_error`() = runBlocking {
        val padding = "x".repeat(McpHttpLimits.MAX_RESPONSE_BYTES + 1)
        val client = harness.modern(listOf(json(textResult(padding), rewriteId = false)))
        assertEquals(McpErrorCode.ServerError, callError(client))
    }

    @Test
    fun `declared Content-Length over the limit is rejected before reading`() = runBlocking {
        val client = harness.modern(
            listOf(json(textResult("small"), headers = mapOf("Content-Length" to (McpHttpLimits.MAX_RESPONSE_BYTES + 1).toString()))),
        )
        assertEquals(McpErrorCode.ServerError, callError(client))
    }

    @Test
    fun `sse flooding without a final response aborts at 8 MB`() = runBlocking {
        val chunk = "data: " + "y".repeat(1024 * 1024) + "\n\n"
        val client = harness.modern(listOf(sse(List(9) { chunk }, keepOpen = true)), McpRuntimeConfig(callTimeoutSeconds = 30.0))
        assertEquals(McpErrorCode.ServerError, callError(client, "flood_stream"))
        assertTrue("the connection must be cut off once the limit is exceeded", wasAborted("flood_stream"))
    }

    @Test
    fun `deeply nested body is a parse failure not a crash`() = runBlocking {
        val depth = 50_000
        val nested = "[".repeat(depth) + "]".repeat(depth)
        val body = """{"jsonrpc":"2.0","id":$REQUEST_ID_PLACEHOLDER,"result":{"content":[],"structuredContent":$nested}}"""
        val client = harness.modern(listOf(json(body, rewriteId = false)))
        assertEquals(McpErrorCode.ServerError, callError(client))
    }

    @Test
    fun `huge numbers in id and error code do not crash`() = runBlocking {
        val hugeId = """{"jsonrpc":"2.0","id":1e30,"result":{"content":[{"type":"text","text":"x"}]}}"""
        val hugeCode = """{"jsonrpc":"2.0","id":$REQUEST_ID_PLACEHOLDER,"error":{"code":1e30,"message":"boom"}}"""
        val client = harness.modern(listOf(json(hugeId, rewriteId = false), json(hugeCode, rewriteId = false)))
        assertEquals(McpErrorCode.ServerError, callError(client))
        assertEquals(McpErrorCode.ServerError, callError(client))

        transport.reset()
        transport.enqueue(
            json("""{"jsonrpc":"2.0","id":1e30,"error":{"code":1e30,"message":"boom"}}""", status = 400, rewriteId = false),
            status(400),
        )
        assertEquals(McpConnectOutcome.NotMcp, harness.client().connect())
    }

    @Test
    fun `oversized structuredContent is dropped and fallback text trimmed`() = runBlocking {
        val big = "z".repeat(500)
        val onlyStructured = """{"jsonrpc":"2.0","id":$REQUEST_ID_PLACEHOLDER,"result":{"content":[],"structuredContent":{"blob":"$big"}}}"""
        val withText = """{"jsonrpc":"2.0","id":$REQUEST_ID_PLACEHOLDER,"result":{"content":[{"type":"text","text":"ok"}],"structuredContent":{"blob":"$big"}}}"""
        val client = harness.modern(listOf(json(onlyStructured), json(withText)), McpRuntimeConfig(maxResultChars = 100))

        val fallback = client.callTool("get_weather", weather)
        assertTrue(fallback.truncated)
        assertEquals(100, fallback.text.length)
        assertTrue(fallback.text.endsWith(McpClientLimits.TRUNCATION_MARKER))
        assertNull(fallback.structuredContent)
        assertEquals(McpErrorCode.ResultTooLarge, fallback.errorCode)

        val text = client.callTool("get_weather", weather)
        assertEquals("ok", text.text)
        assertFalse(text.truncated)
        assertNull("an oversized structuredContent must not bypass the limit and stay in the result", text.structuredContent)
        assertEquals(McpErrorCode.ResultTooLarge, text.errorCode)
    }

    @Test
    fun `structured content fixture keeps text first and structured value intact`() = runBlocking {
        val client = harness.modern(listOf(stub("protocol/shared/tools-call.structured-content.response.json")))
        val result = client.callTool("get_weather", weather)
        assertEquals("""{"temperature": 22.5, "conditions": "Partly cloudy", "humidity": 65}""", result.text)
        assertEquals(65L, result.structuredContent["humidity"].longOrNull)
        assertEquals(22.5, result.structuredContent["temperature"].doubleOrNull)
        assertFalse(result.truncated)
        assertNull(result.errorCode)
    }

    // ── Streaming SSE ────────────────────────────────────────

    @Test
    fun `sse returns as soon as the final response arrives without waiting for close`() = runBlocking {
        val final = "event: message\ndata: " + textResult("done") + "\n\n"
        val client = harness.modern(listOf(sse(listOf(": keep-alive\n\n", final), keepOpen = true)), McpRuntimeConfig(callTimeoutSeconds = 20.0))
        val started = System.nanoTime()
        val result = client.callTool("open_stream", weather)
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertEquals("done", result.text)
        assertTrue("must not wait for stream close or timeout, took ${elapsedMs}ms", elapsedMs < 5_000)
        assertTrue("the connection must be closed proactively once the final response arrives", wasAborted("open_stream"))
        assertEquals(1, transport.requests("tools/call").size)
    }

    @Test
    fun `sse returns on an unterminated final event with the stream left open`() = runBlocking {
        val client = harness.modern(listOf(sse(listOf("data: " + textResult("done") + "\n"), keepOpen = true)), McpRuntimeConfig(callTimeoutSeconds = 20.0))
        val started = System.nanoTime()
        assertEquals("done", client.callTool("get_weather", weather).text)
        assertTrue((System.nanoTime() - started) / 1_000_000 < 5_000)
    }

    @Test
    fun `sse survives chunks cut inside lines multibyte characters and CRLF`() = runBlocking {
        // The placeholder would be cut by the chunking, so the id is hard-coded: the probe used 1, this call is 2.
        val payload = textResult("72°F は 😀").replace(REQUEST_ID_PLACEHOLDER, "2")
        val bytes = ("event: message\r\ndata: $payload\r\n\r\n").toByteArray(Charsets.UTF_8)
        val chunks = (bytes.indices step 7).map { start -> bytes.copyOfRange(start, minOf(start + 7, bytes.size)) }
        val stub = sse(emptyList()).copy(chunks = chunks, chunkIntervalMillis = 2)
        val client = harness.modern(listOf(stub))
        assertEquals("72°F は 😀", client.callTool("get_weather", weather).text)
    }

    @Test
    fun `sse picks the response by id among notifications and foreign responses`() = runBlocking {
        val stream = listOf(
            """data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"working"}}""" + "\n\n",
            """data: {"jsonrpc":"2.0","id":987654,"result":{"content":[{"type":"text","text":"someone else's"}]}}""" + "\n\n",
            "data: " + textResult("mine") + "\n\n",
        )
        assertEquals("mine", harness.modern(listOf(sse(stream))).callTool("get_weather", weather).text)
    }

    // ── Strict id matching ────────────────────────────────────────

    @Test
    fun `mismatched id is a protocol error in json and sse`() = runBlocking {
        val wrong = """{"jsonrpc":"2.0","id":987654,"result":{"content":[{"type":"text","text":"not yours"}]}}"""
        val client = harness.modern(listOf(json(wrong, rewriteId = false), sse(listOf("data: $wrong\n\n"))))
        assertEquals(McpErrorCode.ServerError, callError(client))
        assertEquals(McpErrorCode.ServerError, callError(client))
    }

    @Test
    fun `string id does not match`() = runBlocking {
        val body = """{"jsonrpc":"2.0","id":"$REQUEST_ID_PLACEHOLDER","result":{"content":[{"type":"text","text":"x"}]}}"""
        assertEquals(McpErrorCode.ServerError, callError(harness.modern(listOf(json(body, rewriteId = false)))))
    }

    @Test
    fun `null id json-rpc error counts as this request's error`() = runBlocking {
        val body = """{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}"""
        val client = harness.modern(listOf(json(body, status = 400)))
        try {
            client.callTool("get_weather", weather)
            fail("should have failed")
        } catch (error: McpClientException) {
            assertEquals(McpErrorCode.ServerError, error.code)
            assertEquals("Invalid Request", error.detail)
        }
    }

    // ── Cancellation ────────────────────────────────────────

    @Test
    fun `caller cancellation aborts the request and yields cancelled`() = runBlocking {
        val client = harness.modern(listOf(json(textResult("late"), delayMillis = 5_000)))
        var code: McpErrorCode? = null
        val job = launchCall { code = callError(client, "cancel_me") }
        delay(150)
        job.cancel()
        job.join()
        assertEquals(McpErrorCode.Cancelled, code)
        assertTrue("cancellation must reach the underlying connection", wasAborted("cancel_me"))
    }

    @Test
    fun `concurrent calls keep their own cancel handles`() = runBlocking {
        val client = harness.modern(listOf(json(textResult("slow"), delayMillis = 5_000), json(textResult("fast"), delayMillis = 100)))
        val slow = async { callError(client) }
        delay(100)
        assertEquals("fast", client.callTool("get_weather", weather).text)
        // The fast one has already finished. The slow one must still be cancellable.
        client.cancel()
        assertEquals(McpErrorCode.Cancelled, slow.await())
    }

    @Test
    fun `cancelling one call leaves the other running`() = runBlocking {
        val client = harness.modern(listOf(json(textResult("cancelled"), delayMillis = 5_000), json(textResult("kept"), delayMillis = 400)))
        var doomedCode: McpErrorCode? = null
        val doomed = launchCall { doomedCode = callError(client) }
        delay(100)
        val kept = async { client.callTool("get_weather", weather) }
        delay(100)
        doomed.cancel()
        doomed.join()
        assertEquals(McpErrorCode.Cancelled, doomedCode)
        assertEquals("kept", kept.await().text)
    }

    @Test
    fun `connect is cancellable and reports failed cancelled`() = runBlocking {
        transport.enqueue(stub("protocol/stateless/tools-list.response.json").copy(delayMillis = 5_000))
        val client = harness.client()
        var outcome: McpConnectOutcome? = null
        val job = launchCall { outcome = client.connect() }
        delay(150)
        job.cancel()
        job.join()
        assertEquals(McpConnectOutcome.Failed(McpClientException(McpErrorCode.Cancelled)), outcome)
        assertNull(client.session)
    }

    @Test
    fun `legacy cancellation also sends notifications cancelled with id and session headers`() = runBlocking {
        val client = harness.legacy(listOf(json(textResult("late"), delayMillis = 5_000)))
        var code: McpErrorCode? = null
        val job = launchCall { code = callError(client) }
        delay(150)
        job.cancel()
        job.join()
        assertEquals(McpErrorCode.Cancelled, code)

        assertTrue(eventually { transport.requests("notifications/cancelled").isNotEmpty() })
        val notification = transport.requests("notifications/cancelled").first()
        val call = transport.requests("tools/call").first()
        assertEquals(call.jsonRpcId, notification.json["params"]["requestId"].longOrNull)
        assertNull(notification.json["id"])
        assertEquals(McpClientTest.SESSION_ID, notification.header("MCP-Session-Id"))
        assertEquals("2025-11-25", notification.header("MCP-Protocol-Version"))
    }

    @Test
    fun `modern cancellation only closes the connection`() = runBlocking {
        val client = harness.modern(listOf(json(textResult("late"), delayMillis = 5_000)))
        var code: McpErrorCode? = null
        val job = launchCall { code = callError(client) }
        delay(150)
        job.cancel()
        job.join()
        assertEquals(McpErrorCode.Cancelled, code)
        delay(300)
        assertTrue(transport.requests("notifications/cancelled").isEmpty())
    }

    // ── Timeouts ────────────────────────────────────────

    @Test
    fun `transport idle timeout strictly exceeds the call timeout`() = runBlocking {
        val client = harness.modern(listOf(json(textResult("ok"))), McpRuntimeConfig(callTimeoutSeconds = 90.0))
        client.callTool("get_weather", weather)
        transport.requests().forEach { assertTrue(it.request.idleTimeoutMillis > 90_000) }
    }

    @Test
    fun `transport-level timeout maps to timeout not unreachable`() = runBlocking {
        val client = harness.modern(listOf(McpScriptedTransport.Stub(error = SocketTimeoutException("read timed out"))))
        assertEquals(McpErrorCode.Timeout, callError(client))
    }

    @Test
    fun `open sse stream without a final response times out and closes`() = runBlocking {
        val client = harness.modern(listOf(sse(listOf(": keep-alive\n\n"), keepOpen = true)), McpRuntimeConfig(callTimeoutSeconds = 0.4))
        assertEquals(McpErrorCode.Timeout, callError(client, "silent_stream"))
        assertTrue(wasAborted("silent_stream"))
    }

    /** Starts the call in its own coroutine so it can be cancelled from outside (simulates the chat loop being cancelled when the user taps stop). */
    private fun CoroutineScope.launchCall(block: suspend () -> Unit) = launch { block() }

    companion object {
        const val EVIL = "https://evil.example/collect"
    }
}
