package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.emptyJson
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.json
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.networkError
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.notMcpCases
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.sseBody
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.status
import ai.oriveo.community.core.mcp.McpScriptedTransport.Companion.stub
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The remote MCP protocol client.
 *
 * Mostly fixture replay: `shared/test-fixtures/mcp/protocol/` is the single source of truth. Requests are sent by
 * production code and answered by the replay layer;
 * the assertions look at the requests the replay layer actually received and the results production code returned.
 */
class McpClientTest {

    private val harness = McpClientHarness()
    private val transport get() = harness.transport
    private val weather = McpClientHarness.weatherArguments

    private fun renewedInitializeStub(): McpScriptedTransport.Stub {
        val base = stub("protocol/session/initialize.response.json")
        return base.copy(headers = base.headers.filterKeys { !it.equals("MCP-Session-Id", true) } + ("MCP-Session-Id" to RENEWED_SESSION_ID))
    }

    private suspend fun callError(client: McpClient, name: String = "get_weather"): McpClientException? = try {
        client.callTool(name, weather)
        null
    } catch (error: McpClientException) {
        error
    }

    // ── Full replay of both protocol eras ──────────────────

    @Test
    fun `modern round trip probe list call`() = runBlocking {
        transport.enqueue(
            stub("protocol/stateless/tools-list.response.json"),
            stub("protocol/stateless/tools-list.response.json"),
            stub("protocol/stateless/tools-call.response.json"),
        )
        val client = harness.client()

        val session = client.connect().session
        assertNotNull(session)
        assertEquals(McpProtocolGeneration.Stateless, session!!.generation)
        assertEquals("2026-07-28", session.protocolVersion)

        val tools = client.listTools()
        assertEquals(listOf("get_weather", "create_issue"), tools.map { it.name })
        assertEquals("Weather Information Provider", tools.first().displayTitle)
        assertTrue(tools.first().readOnly)

        val result = client.callTool("get_weather", weather)
        assertFalse(result.isError)
        assertTrue(result.text.contains("72°F"))
        assertFalse(result.truncated)
        assertNull(result.errorCode)

        val probe = transport.requests("tools/list").first()
        assertEquals("tools/list", probe.header("Mcp-Method"))
        assertNull(probe.header("Mcp-Name"))
        assertEquals("2026-07-28", probe.header("MCP-Protocol-Version"))
        assertEquals("application/json, text/event-stream", probe.header("Accept"))

        val call = transport.requests("tools/call").first()
        assertEquals("tools/call", call.header("Mcp-Method"))
        assertEquals("get_weather", call.header("Mcp-Name"))
        assertEquals("2026-07-28", call.header("MCP-Protocol-Version"))
        assertNull(call.header("Authorization"))
    }

    @Test
    fun `legacy round trip falls back on empty 400`() = runBlocking {
        transport.enqueue(
            emptyJson(400),
            stub("protocol/session/initialize.response.json"),
            stub("protocol/session/tools-list.response.json"),
            stub("protocol/session/tools-call.response.json"),
        )
        val client = harness.client()

        val session = client.connect(bearerToken = "mcp_at_example").session!!
        assertEquals(McpProtocolGeneration.Session, session.generation)
        assertEquals("2025-11-25", session.protocolVersion)
        assertEquals(SESSION_ID, session.sessionId)

        assertEquals(listOf("get_weather", "create_issue"), client.listTools().map { it.name })
        val result = client.callTool("get_weather", weather)
        assertFalse(result.isError)
        assertTrue(result.text.contains("72°F"))

        assertNull(transport.requests("initialize").first().header("MCP-Protocol-Version"))
        val call = transport.requests("tools/call").first()
        assertEquals("2025-11-25", call.header("MCP-Protocol-Version"))
        assertEquals(SESSION_ID, call.header("MCP-Session-Id"))
        assertNull(call.header("Mcp-Method"))
        assertNull(call.header("Mcp-Name"))
        assertEquals("Bearer mcp_at_example", call.header("Authorization"))
        assertEquals(SESSION_ID, transport.requests("tools/list").last().header("MCP-Session-Id"))
    }

    // ── Era detection state machine ────────────────────────

    @Test
    fun `-32022 is modern and retries with supported version without initialize`() = runBlocking {
        transport.enqueue(
            stub("protocol/stateless/error.unsupported-protocol-version.json"),
            stub("protocol/stateless/tools-list.response.json"),
        )
        val session = harness.client().connect().session!!
        assertEquals(McpProtocolGeneration.Stateless, session.generation)
        assertTrue(transport.requests("initialize").isEmpty())
        assertEquals(2, transport.requests("tools/list").size)
        assertEquals("2026-07-28", transport.requests("tools/list").last().header("MCP-Protocol-Version"))
    }

    @Test
    fun `-32020 and -32021 are modern and do not fall back`() = runBlocking {
        for (fixture in listOf("protocol/stateless/error.header-mismatch.json", "protocol/stateless/error.missing-required-capability.json")) {
            transport.reset()
            transport.enqueue(stub(fixture))
            val outcome = harness.client().connect()
            assertTrue(fixture, outcome is McpConnectOutcome.Failed)
            assertEquals(McpErrorCode.ServerError, (outcome as McpConnectOutcome.Failed).error.code)
            assertNotNull(fixture, outcome.error.detail)
            assertTrue(transport.requests("initialize").isEmpty())
        }
    }

    @Test
    fun `empty 400 falls back to initialize`() = runBlocking {
        transport.enqueue(emptyJson(400), stub("protocol/session/initialize.response.json"))
        val session = harness.client().connect().session!!
        assertEquals(McpProtocolGeneration.Session, session.generation)
        assertEquals(1, transport.requests("initialize").size)
    }

    @Test
    fun `generic legacy -32602 without modern markers falls back to initialize`() = runBlocking {
        // Fixture error.legacy-before-initialize.json: the generic -32602 a legacy server returns when it receives tools/list before initialize.
        transport.enqueue(
            stub("protocol/shared/error.legacy-before-initialize.json"),
            stub("protocol/session/initialize.response.json"),
        )
        val session = harness.client().connect().session!!
        assertEquals(McpProtocolGeneration.Session, session.generation)
        assertEquals("2025-11-25", session.protocolVersion)
        assertEquals(1, transport.requests("initialize").size)
    }

    @Test
    fun `invalid params with modern markers and 404 method not found are modern`() = runBlocking {
        for (fixture in listOf("protocol/shared/error.invalid-params.json", "protocol/shared/error.method-not-found.json")) {
            transport.reset()
            transport.enqueue(stub(fixture))
            val outcome = harness.client().connect()
            assertEquals(fixture, McpErrorCode.ServerError, (outcome as McpConnectOutcome.Failed).error.code)
            assertTrue(fixture, transport.requests("initialize").isEmpty())
        }
    }

    @Test
    fun `four not-mcp responses are not_mcp without initialize`() = runBlocking {
        for ((caseId, case) in notMcpCases()) {
            transport.reset()
            transport.enqueue(case)
            assertEquals(caseId, McpConnectOutcome.NotMcp, harness.client().connect())
            assertTrue(caseId, transport.requests("initialize").isEmpty())
        }
    }

    // ── SSE (one case per era) ─────────────────────────────

    @Test
    fun `sse modern and legacy tools call parse with notification`() = runBlocking {
        val modern = harness.modern(listOf(sseBody(McpFixture.text("protocol/stateless/tools-call.sse.txt"))))
        assertTrue(modern.callTool("get_weather", weather).text.contains("72°F"))

        val legacy = harness.legacy(listOf(sseBody(McpFixture.text("protocol/session/tools-call.sse.txt"))))
        val result = legacy.callTool("get_weather", weather)
        assertFalse(result.isError)
        assertTrue(result.text.contains("72°F"))
    }

    // ── Pagination ─────────────────────────────────────────

    @Test
    fun `tools list follows nextCursor to the end`() = runBlocking {
        val page1 = """{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"a","inputSchema":{}}],"nextCursor":"p2"}}"""
        val page2 = """{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"b","inputSchema":{}}]}}"""
        val client = harness.modern(listOf(json(page1), json(page2)))
        assertEquals(listOf("a", "b"), client.listTools().map { it.name })
        val lists = transport.requests("tools/list")
        assertEquals(3, lists.size)
        assertTrue(lists[2].bodyText!!.contains("\"cursor\":\"p2\""))
    }

    @Test
    fun `tools list fails after twenty pages`() = runBlocking {
        transport.enqueue(stub("protocol/stateless/tools-list.response.json"))
        transport.setFallback(json("""{"jsonrpc":"2.0","id":2,"result":{"tools":[],"nextCursor":"more"}}"""))
        val client = harness.client()
        assertNotNull(client.connect().session)
        try {
            client.listTools()
            fail("more than 20 pages should fail")
        } catch (error: McpClientException) {
            assertEquals(McpErrorCode.ServerError, error.code)
        }
        assertEquals(21, transport.requests("tools/list").size)
    }

    // ── Timeouts and network errors ────────────────────────

    @Test
    fun `call timeout maps to timeout`() = runBlocking {
        val body = """{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"late"}]}}"""
        val client = harness.modern(listOf(json(body, delayMillis = 1_000)), McpRuntimeConfig(callTimeoutSeconds = 0.2))
        assertEquals(McpErrorCode.Timeout, callError(client)?.code)
    }

    @Test
    fun `network failure maps to unreachable`() = runBlocking {
        val client = harness.modern(listOf(networkError()))
        assertEquals(McpErrorCode.Unreachable, callError(client)?.code)
    }

    @Test
    fun `probe network failure is unreachable and not retried`() = runBlocking {
        transport.enqueue(networkError())
        assertEquals(McpConnectOutcome.Unreachable, harness.client().connect())
        assertEquals(1, transport.requests("tools/list").size)
        assertTrue(transport.requests("initialize").isEmpty())
    }

    // ── Result truncation ──────────────────────────────────

    @Test
    fun `trimming joins text and replaces non-text with placeholder`() = runBlocking {
        val body = """{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"hello "},{"type":"image","data":"x"},{"type":"text","text":"world"}]}}"""
        val result = harness.modern(listOf(json(body))).callTool("get_weather", weather)
        assertEquals("hello [non-text content: image]world", result.text)
        assertFalse(result.truncated)
    }

    @Test
    fun `trimming falls back to structuredContent json text`() = runBlocking {
        val body = """{"jsonrpc":"2.0","id":3,"result":{"resultType":"complete","content":[],"structuredContent":{"temperature":22.5,"conditions":"Partly cloudy"}}}"""
        val result = harness.modern(listOf(json(body))).callTool("get_weather", weather)
        assertEquals("""{"temperature":22.5,"conditions":"Partly cloudy"}""", result.text)
        assertNotNull(result.structuredContent)
        assertFalse(result.truncated)
    }

    @Test
    fun `trimming truncates and marks beyond maxResultChars`() = runBlocking {
        val body = """{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"${"x".repeat(200)}"}]}}"""
        val result = harness.modern(listOf(json(body)), McpRuntimeConfig(maxResultChars = 30)).callTool("get_weather", weather)
        assertTrue(result.truncated)
        assertEquals(30, result.text.length)
        assertTrue(result.text.endsWith(McpClientLimits.TRUNCATION_MARKER))
        assertEquals(McpErrorCode.ResultTooLarge, result.errorCode)
        assertFalse(result.isError)
    }

    // ── Tool execution errors and MRTR ─────────────────────

    @Test
    fun `isError true maps to tool_error result`() = runBlocking {
        val result = harness.modern(listOf(stub("protocol/shared/tools-call.is-error.response.json"))).callTool("get_weather", weather)
        assertTrue(result.isError)
        assertEquals(McpErrorCode.ToolError, result.errorCode)
        assertTrue(result.text.contains("Invalid departure date"))
    }

    @Test
    fun `input_required maps to needs_input_unsupported`() = runBlocking {
        val result = harness.modern(listOf(stub("protocol/shared/tools-call.input-required.response.json"))).callTool("get_weather", weather)
        assertEquals(McpErrorCode.NeedsInputUnsupported, result.errorCode)
    }

    @Test
    fun `unknown tool -32602 maps to tool_error`() = runBlocking {
        val client = harness.modern(listOf(stub("protocol/session/error.unknown-tool.json")))
        try {
            client.callTool("invalid_tool_name", JsonObject(emptyMap()))
            fail("should have failed")
        } catch (error: McpClientException) {
            assertEquals(McpErrorCode.ToolError, error.code)
        }
    }

    // ── Retry discipline ───────────────────────────────────

    @Test
    fun `tools call is never retried`() = runBlocking {
        val client = harness.modern(listOf(networkError(), stub("protocol/stateless/tools-call.response.json")))
        assertEquals(McpErrorCode.Unreachable, callError(client)?.code)
        assertEquals("tools/call must never be replayed automatically once sent", 1, transport.requests("tools/call").size)
    }

    @Test
    fun `tools list retries once on pre-connect network error`() = runBlocking {
        val client = harness.modern(listOf(networkError(), stub("protocol/stateless/tools-list.response.json")))
        assertEquals(2, client.listTools().size)
        assertEquals(3, transport.requests("tools/list").size)
    }

    // ── Legacy session termination ─────────────────────────

    @Test
    fun `session terminated on list reinitializes once and writes new session back`() = runBlocking {
        transport.enqueue(
            emptyJson(400),
            stub("protocol/session/initialize.response.json"),
            stub("protocol/session/error.session-terminated.json"),
            renewedInitializeStub(),
            stub("protocol/session/tools-list.response.json"),
            stub("protocol/session/tools-call.response.json"),
        )
        val client = harness.client()
        assertEquals(SESSION_ID, client.connect().session?.sessionId)

        assertEquals(2, client.listTools().size)
        val initializes = transport.requests("initialize")
        assertEquals(2, initializes.size)
        assertNull(initializes[1].header("MCP-Session-Id"))
        assertEquals(RENEWED_SESSION_ID, client.session?.sessionId)
        assertEquals(RENEWED_SESSION_ID, transport.requests("tools/list").last().header("MCP-Session-Id"))

        client.callTool("get_weather", weather)
        assertEquals(RENEWED_SESSION_ID, transport.requests("tools/call").first().header("MCP-Session-Id"))
        val initialized = transport.requests("notifications/initialized")
        assertEquals(2, initialized.size)
        assertEquals(RENEWED_SESSION_ID, initialized.last().header("MCP-Session-Id"))
    }

    @Test
    fun `session terminated on call recovers session but does not replay`() = runBlocking {
        val client = harness.legacy(
            listOf(
                stub("protocol/session/error.session-terminated.json"),
                renewedInitializeStub(),
                stub("protocol/session/tools-call.response.json"),
            ),
        )
        assertEquals(McpErrorCode.ServerError, callError(client)?.code)
        assertEquals("must not be replayed automatically", 1, transport.requests("tools/call").size)
        assertEquals(RENEWED_SESSION_ID, client.session?.sessionId)

        client.callTool("get_weather", weather)
        assertEquals(RENEWED_SESSION_ID, transport.requests("tools/call").last().header("MCP-Session-Id"))
    }

    // ── Classification of the fallback handshake ───────────

    @Test
    fun `initialize 401 is needsAuth and records the challenge`() = runBlocking {
        val fixture = McpFixture.json("auth/401.www-authenticate.json")
        val header = fixture["headers"]["WWW-Authenticate"].stringOrNull!!
        transport.enqueue(emptyJson(400), status(401, mapOf("WWW-Authenticate" to header)))
        val client = harness.client()
        assertEquals(McpConnectOutcome.NeedsAuth, client.connect())
        val challenge = client.authChallenge!!
        assertEquals(fixture["expect"]["resourceMetadataURL"].stringOrNull, challenge.resourceMetadata)
        assertEquals(fixture["expect"]["scope"].stringOrNull, challenge.scope)
    }

    @Test
    fun `ordinary website is not_mcp rather than unreachable`() = runBlocking {
        val html = McpScriptedTransport.Stub(status = 400, headers = mapOf("Content-Type" to "text/html"), body = "<h1>Bad Request</h1>".toByteArray())
        for (second in listOf(html, emptyJson(404), json("""{"ok":true}"""))) {
            transport.reset()
            transport.enqueue(html, second)
            assertEquals(McpConnectOutcome.NotMcp, harness.client().connect())
            assertEquals(1, transport.requests("initialize").size)
        }
    }

    @Test
    fun `foreign json-rpc service rejecting initialize with -32601 is not_mcp`() = runBlocking {
        transport.enqueue(
            json("""{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}""", status = 400),
            json("""{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}"""),
        )
        assertEquals(McpConnectOutcome.NotMcp, harness.client().connect())
    }

    @Test
    fun `rejected handshake is failed server_error`() = runBlocking {
        val refusals = listOf(
            """{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Internal error"}}""",
            """{"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"Old","version":"1"}}}""",
        )
        for (refusal in refusals) {
            transport.reset()
            transport.enqueue(emptyJson(400), json(refusal))
            val client = harness.client()
            val outcome = client.connect()
            assertEquals(refusal, McpErrorCode.ServerError, (outcome as McpConnectOutcome.Failed).error.code)
            assertNull(client.session)
        }
    }

    @Test
    fun `probe 200 without a real tools list result is not_mcp`() = runBlocking {
        val bodies = listOf(
            """{"jsonrpc":"2.0","id":1,"result":{}}""",
            """{"jsonrpc":"2.0","id":1,"result":"ok"}""",
            """{"id":1,"result":{"tools":[]}}""",
            """{"result":{"tools":[]}}""",
        )
        for (body in bodies) {
            transport.reset()
            transport.enqueue(json(body))
            val client = harness.client()
            assertEquals(body, McpConnectOutcome.NotMcp, client.connect())
            assertNull(client.session)
        }
    }

    @Test
    fun `probe 200 with generic json-rpc error falls back to initialize`() = runBlocking {
        transport.enqueue(
            json("""{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Server not initialized"}}"""),
            stub("protocol/session/initialize.response.json"),
        )
        assertEquals(McpProtocolGeneration.Session, harness.client().connect().session?.generation)
    }

    // ── Era detection markers ──────────────────────────────

    @Test
    fun `legacy session and protocol-version header mentions are not modern markers`() = runBlocking {
        val messages = listOf(
            "Bad Request: Mcp-Session-Id header is required",
            "Bad Request: MCP-Session-Id header is required",
            "Invalid or missing mcp-session-id",
            "Bad Request: Unsupported MCP-Protocol-Version header",
            "Invalid mcp-protocol-version: 2026-07-28",
            "Mcp-Protocol-Version header must be one of 2025-06-18, 2025-03-26",
        )
        for (message in messages) {
            assertFalse(message, McpProtocol.containsModernMarker(message))
            transport.reset()
            transport.enqueue(
                json("""{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"$message"}}""", status = 400),
                stub("protocol/session/initialize.response.json"),
            )
            assertEquals(message, McpProtocolGeneration.Session, harness.client().connect().session?.generation)
            assertEquals(1, transport.requests("initialize").size)
        }
    }

    @Test
    fun `modern-only header names in error text stay modern`() = runBlocking {
        val messages = listOf(
            "Missing required header: Mcp-Method",
            "mcp-name does not match params.name",
            "Unexpected header Mcp-Param-Region",
        )
        for (message in messages) {
            transport.reset()
            transport.enqueue(json("""{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"$message"}}""", status = 400))
            val outcome = harness.client().connect()
            assertEquals(message, McpErrorCode.ServerError, (outcome as McpConnectOutcome.Failed).error.code)
            assertTrue(message, transport.requests("initialize").isEmpty())
        }
    }

    @Test
    fun `-32022 listing only legacy versions goes to handshake with the highest listed`() = runBlocking {
        val error = """{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2025-03-26","2025-06-18","2024-11-05"],"requested":"2026-07-28"}}}"""
        val initialized = """{"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"Legacy","version":"1"}}}"""
        transport.enqueue(json(error, status = 400), json(initialized))
        val session = harness.client().connect().session!!
        assertEquals(McpProtocolGeneration.Session, session.generation)
        assertEquals("2025-06-18", session.protocolVersion)
        assertEquals("Legacy", session.serverName)

        assertEquals(1, transport.requests("tools/list").size)
        val initialize = transport.requests("initialize").first()
        assertEquals("2025-06-18", initialize.json["params"]["protocolVersion"].stringOrNull)
        assertNull(initialize.header("Mcp-Method"))
        assertNull(initialize.header("MCP-Protocol-Version"))
    }

    @Test
    fun `-32022 with nothing in common fails without blind retry`() = runBlocking {
        transport.enqueue(
            json("""{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2027-01-01"]}}}""", status = 400),
        )
        val outcome = harness.client().connect()
        assertEquals(McpErrorCode.ServerError, (outcome as McpConnectOutcome.Failed).error.code)
        assertEquals(1, transport.requests().size)
    }

    // ── 403 insufficient_scope ─────────────────────────────

    @Test
    fun `403 insufficient_scope on call is needs_auth and records challenge`() = runBlocking {
        val fixture = McpFixture.json("auth/403.insufficient-scope.json")
        val client = harness.modern(listOf(stub("auth/403.insufficient-scope.json")))
        try {
            client.callTool("create_issue", JsonObject(emptyMap()))
            fail("should have failed")
        } catch (error: McpClientException) {
            assertEquals(fixture["expect"]["errorCode"].stringOrNull, error.code.wireValue)
        }
        val challenge = client.authChallenge!!
        assertEquals("insufficient_scope", challenge.error)
        assertEquals("files:write", challenge.scope)
        assertEquals("https://mcp.example.com/.well-known/oauth-protected-resource", challenge.resourceMetadata)
    }

    @Test
    fun `403 insufficient_scope on probe and list is needsAuth but plain 403 is not`() = runBlocking {
        transport.enqueue(stub("auth/403.insufficient-scope.json"))
        assertEquals(McpConnectOutcome.NeedsAuth, harness.client().connect())

        val client = harness.modern(listOf(stub("auth/403.insufficient-scope.json"), emptyJson(403)))
        assertEquals(McpErrorCode.NeedsAuth, runCatching { client.listTools() }.exceptionOrNull().let { (it as McpClientException).code })
        assertEquals(McpErrorCode.ServerError, runCatching { client.listTools() }.exceptionOrNull().let { (it as McpClientException).code })
    }

    // ── Mcp-Name encoding ──────────────────────────────────

    @Test
    fun `non-ascii tool name is base64 encoded in Mcp-Name and original in body`() = runBlocking {
        val name = "날씨조회_ünï"
        val client = harness.modern(listOf(json("""{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"ok"}]}}""")))
        client.callTool(name, weather)
        val call = transport.requests("tools/call").first()
        val header = call.header("Mcp-Name")!!
        assertTrue(header.startsWith("=?base64?") && header.endsWith("?="))
        assertTrue(header.all { it.code < 0x80 })
        val encoded = header.removePrefix("=?base64?").removeSuffix("?=")
        assertEquals(name, String(java.util.Base64.getDecoder().decode(encoded), Charsets.UTF_8))
        assertEquals(name, call.jsonRpcName)
    }

    @Test
    fun `header value encoding rules`() {
        assertEquals("get_weather", McpClient.headerValue("get_weather"))
        assertEquals("a b.c-d/e", McpClient.headerValue("a b.c-d/e"))
        for (value in listOf(" padded", "padded ", "tab\there", "line\nbreak", "=?base64?Zm9v?=", "é")) {
            val header = McpClient.headerValue(value)
            assertTrue(value, header.startsWith("=?base64?") && header.endsWith("?="))
            val encoded = header.removePrefix("=?base64?").removeSuffix("?=")
            assertEquals(value, String(java.util.Base64.getDecoder().decode(encoded), Charsets.UTF_8))
        }
    }

    // ── Request fixture replay (headers and bodies sent by the production path) ──

    @Test
    fun `modern requests match fixtures`() = runBlocking {
        val anonymous = harness.modern(listOf(stub("protocol/stateless/tools-list.response.json")))
        anonymous.listTools()
        val lists = transport.requests("tools/list")
        assertEquals(2, lists.size)
        lists.forEach { assertEquals(emptyList<String>(), harness.mismatches(it, "protocol/stateless/tools-list.request.json")) }

        transport.reset()
        transport.enqueue(stub("protocol/stateless/tools-list.response.json"), stub("protocol/stateless/tools-call.response.json"))
        val authorized = harness.client()
        assertNotNull(authorized.connect(bearerToken = "mcp_at_example").session)
        authorized.callTool("get_weather", weather)
        val call = transport.requests("tools/call").first()
        assertEquals(emptyList<String>(), harness.mismatches(call, "protocol/stateless/tools-call.request.json"))

        // The two required `_meta` fields are checked by name, not only through the whole-object comparison.
        for (request in lists + call) {
            val meta = request.json["params"]["_meta"]
            assertEquals(request.header("MCP-Protocol-Version"), meta["io.modelcontextprotocol/protocolVersion"].stringOrNull)
            assertTrue(meta["io.modelcontextprotocol/clientCapabilities"] is JsonObject)
            assertEquals(request.jsonRpcMethod, request.header("Mcp-Method"))
        }
    }

    @Test
    fun `legacy requests match fixtures`() = runBlocking {
        transport.enqueue(emptyJson(400), stub("protocol/session/initialize.response.json"), stub("protocol/session/tools-list.response.json"))
        val anonymous = harness.client()
        assertNotNull(anonymous.connect().session)
        anonymous.listTools()

        assertEquals(emptyList<String>(), harness.mismatches(transport.requests("initialize").first(), "protocol/session/initialize.request.json"))
        assertEquals(
            emptyList<String>(),
            harness.mismatches(transport.requests("notifications/initialized").first(), "protocol/session/initialized.notification.json"),
        )
        assertEquals(emptyList<String>(), harness.mismatches(transport.requests("tools/list").last(), "protocol/session/tools-list.request.json"))
        // Handshake order: initialize -> initialized -> other requests.
        assertEquals(
            listOf("tools/list", "initialize", "notifications/initialized", "tools/list"),
            transport.requests().mapNotNull { it.jsonRpcMethod },
        )

        transport.reset()
        transport.enqueue(emptyJson(400), stub("protocol/session/initialize.response.json"), stub("protocol/session/tools-call.response.json"))
        val authorized = harness.client()
        assertNotNull(authorized.connect(bearerToken = "mcp_at_example").session)
        authorized.callTool("get_weather", weather)
        assertEquals(emptyList<String>(), harness.mismatches(transport.requests("tools/call").first(), "protocol/session/tools-call.request.json"))
    }

    @Test
    fun `session id never appears in string descriptions`() = runBlocking {
        val client = harness.legacy()
        val session = client.session!!
        assertEquals(SESSION_ID, session.sessionId)
        for (text in listOf(session.toString(), McpConnectOutcome.Connected(session).toString())) {
            assertFalse(text, text.contains(SESSION_ID))
        }
    }

    @Test
    fun `client error message never carries server detail`() {
        val error = McpClientException(McpErrorCode.ServerError, "secret-ish server text " + "x".repeat(300))
        assertEquals(200, error.detail!!.length)
        assertFalse(error.toString().contains("secret-ish"))
        assertFalse(error.message!!.contains("secret-ish"))
    }

    // ── Cancellation ───────────────────────────────────────

    @Test
    fun `cancel in-flight tools call is cancelled`() = runBlocking {
        val body = """{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"late"}]}}"""
        val client = harness.modern(listOf(json(body, delayMillis = 2_000)))
        val call = async { callError(client) }
        delay(100)
        client.cancel()
        assertEquals(McpErrorCode.Cancelled, call.await()?.code)
    }

    companion object {
        const val SESSION_ID = "c1f2a3b4d5e60718293a4b5c6d7e8f90"
        const val RENEWED_SESSION_ID = "renewed-session-0f9e8d7c6b5a"
    }
}
