package ai.oriveo.community.core.mcp

import io.ktor.client.network.sockets.ConnectTimeoutException
import io.ktor.client.network.sockets.SocketTimeoutException as KtorSocketTimeoutException
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.readAvailable
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

// Protocol client for remote MCP.
//
// Covers detection and negotiation across the two protocol generations, request shapes, `tools/list`, `tools/call` and
// MRTR; calls, cancellation, retries and resource limits; the closed set of error codes; no retry once a `tools/call` has
// been sent; and credentials never leaving for another origin through a redirect (see `McpHttp.kt`).
//
// Only Streamable HTTP over https: JSON-RPC is POSTed to the server address, and the response is either a single JSON
// document or an SSE stream.

/** The negotiated protocol era. */
enum class McpProtocolEra { Modern, Legacy }

/** The result of a successful negotiation. A legacy-protocol session id is kept only in memory and in the local connection state; it is never logged. */
data class McpSession(
    val generation: McpProtocolGeneration,
    val protocolVersion: String,
    val sessionId: String? = null,
    /** The server's self-reported name (legacy: `serverInfo.name` from `initialize`; null when the modern probe does not provide one). */
    val serverName: String? = null,
    /**
     * The server's self-reported icon URL (legacy: the one picked from `serverInfo.icons` of `initialize` by
     * [McpServerIconPolicy]). The modern probe does not read `serverInfo`, so it is null.
     */
    val serverIconUrl: String? = null,
) {
    val era: McpProtocolEra get() = if (generation == McpProtocolGeneration.Stateless) McpProtocolEra.Modern else McpProtocolEra.Legacy

    /** The session id is never logged: when stringified, only its presence is reported. */
    override fun toString(): String =
        "McpSession(generation=${generation.wireValue}, protocolVersion=$protocolVersion, " +
            "sessionId=${if (sessionId == null) "null" else "<redacted>"})"
}

/**
 * Protocol client error. [code] is within the closed set of error codes; [detail] is the server's own text, used only for
 * the local step payload and the user-visible failure description (truncated to 200 characters). **It never goes into
 * `toolSteps` or logs**, which is why it is not part of [message]: only the error code can leak through `toString()`.
 */
class McpClientException(val code: McpErrorCode, detail: String? = null) : Exception(code.wireValue) {
    val detail: String? = detail?.take(MAX_DETAIL_LENGTH)

    override fun equals(other: Any?): Boolean =
        other is McpClientException && other.code == code && other.detail == detail

    override fun hashCode(): Int = code.hashCode() * 31 + (detail?.hashCode() ?: 0)

    companion object {
        const val MAX_DETAIL_LENGTH = 200
    }
}

/**
 * Terminal states of detection and negotiation. `NotMcp` / `Unreachable` / `NeedsAuth` are not error codes of the closed
 * set; they are intermediate results of the add-server state machine. The error code carried by `Failed` is one of
 * `server_error` / `timeout` / `cancelled`.
 */
sealed class McpConnectOutcome {
    data class Connected(override val session: McpSession) : McpConnectOutcome()
    data object NotMcp : McpConnectOutcome()
    data object NeedsAuth : McpConnectOutcome()
    data object Unreachable : McpConnectOutcome()
    data class Failed(val error: McpClientException) : McpConnectOutcome()

    open val session: McpSession? get() = null
}

/**
 * The completed result of a `tools/call`. A tool execution error (`isError: true`) and MRTR (`input_required`) are both
 * **regular results**, not JSON-RPC errors; only transport and protocol failures throw [McpClientException].
 */
data class McpToolCallResult(
    /** The trimmed text fed back to the model. */
    val text: String,
    /** `result.isError == true`. */
    val isError: Boolean,
    /** `tool_error` / `needs_input_unsupported` / `result_too_large`, or null. */
    val errorCode: McpErrorCode?,
    /** Whether the result was truncated for exceeding `maxResultChars`. */
    val truncated: Boolean,
    val structuredContent: JsonElement?,
)

/** Built-in client defaults (used when the model catalog carries no limits; the feature is not disabled because of it). */
object McpClientLimits {
    const val FALLBACK_CALL_TIMEOUT_SECONDS = 60.0
    const val FALLBACK_MAX_RESULT_CHARS = 24_000
    const val TRUNCATION_MARKER = "\n\n[result truncated]"
    const val ACCEPT_HEADER = "application/json, text/event-stream"

    /** Upper bound for waiting on a legacy cancellation notification. It is a best-effort side request and should not hang for a minute along with the call timeout. */
    const val CANCEL_NOTIFICATION_TIMEOUT_MILLIS = 5_000L
}

/**
 * Protocol client for remote MCP (dual-era). One instance corresponds to one server address; the negotiation result is
 * cached in the instance. Methods may be called concurrently (two interleaved tool calls); all state is thread-safe.
 */
class McpClient(
    private val endpoint: String,
    private val runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback,
    private val transport: McpRawTransport,
) {
    @Volatile private var bearerToken: String? = null

    @Volatile private var negotiatedSession: McpSession? = null

    @Volatile private var lastAuthChallenge: McpAuthChallenge? = null

    private val nextRequestId = AtomicInteger(1)

    /**
     * HTTP exchanges in flight, registered by request id. Two interleaved calls each register and clear their own entry,
     * so the one that finishes first does not clear the other's cancellation handle.
     */
    private val inFlight = ConcurrentHashMap<Int, Deferred<McpExchange>>()

    /** Scope for fire-and-forget side requests such as the legacy cancellation notification: not tied to the caller, so they are sent even when the caller is cancelled. */
    private val sideScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The currently negotiated session (null until negotiation succeeds). */
    val session: McpSession? get() = negotiatedSession

    /**
     * The challenge parsed from the most recent 401 / 403 `insufficient_scope`. The discovery step of the add-server flow
     * prefers its `resource_metadata`; without a challenge the well-known URL is constructed instead.
     */
    val authChallenge: McpAuthChallenge? get() = lastAuthChallenge

    // -- Detection and negotiation --------------------------------

    /**
     * Detects the server's protocol generation and negotiates a version.
     *
     * 1. Send a modern-shaped `tools/list` first.
     * 2. Success (the body is a valid `tools/list` result) -> modern (stateless).
     * 3. `400` -> **read the response body first**: only a recognizable modern JSON-RPC error means the server is modern
     *    and **must not be retried with `initialize`**; an empty body, a non-JSON-RPC body, or a generic JSON-RPC error
     *    without any modern identifier always falls back.
     * 4. `404` with a JSON-RPC body -> modern; a bare 404 -> not an MCP server (no HTTP+SSE fallback).
     * 5. Network failure -> `unreachable`; generation detection is not retried.
     *
     * Returns `Failed(cancelled)` when the caller's coroutine is cancelled (or [cancel] was called).
     */
    suspend fun connect(bearerToken: String? = null): McpConnectOutcome {
        this.bearerToken = bearerToken
        negotiatedSession = null
        lastAuthChallenge = null

        val outcome = try {
            performConnect()
        } catch (error: McpClientException) {
            return when (error.code) {
                McpErrorCode.Timeout, McpErrorCode.Cancelled, McpErrorCode.ServerError -> McpConnectOutcome.Failed(error)
                else -> McpConnectOutcome.Unreachable
            }
        }
        if (outcome is McpConnectOutcome.Connected) negotiatedSession = outcome.session
        return outcome
    }

    private suspend fun performConnect(): McpConnectOutcome {
        val probe = modernProbe()
        if (requiresAuth(probe)) return McpConnectOutcome.NeedsAuth

        val error = probe.message?.get("error")
        if (error != null && (probe.status == 400 || probe.status == 200)) {
            // Read the body before deciding whether to fall back. Some legacy servers answer "not initialized yet" with
            // 200 + a JSON-RPC error instead of 400; the criterion is the same: whether the body has a modern identifier.
            return resolveProbeError(error)
        }

        return when (probe.status) {
            200 -> when {
                isToolsListResult(probe.message) -> McpConnectOutcome.Connected(modernSession())
                // The body is JSON-RPC but does not match our request id: the server speaks JSON-RPC but violates the protocol.
                probe.mismatchedId -> McpConnectOutcome.Failed(McpClientException(McpErrorCode.ServerError))
                // 200 but the body is not a valid JSON-RPC result (HTML, plain JSON, missing `tools`) -> not an MCP server.
                else -> McpConnectOutcome.NotMcp
            }
            // Empty body / not JSON-RPC -> fall back to initialize.
            400 -> legacyHandshake(McpProtocol.LEGACY_INITIALIZE_VERSION)
            404 -> {
                val message = probe.message
                if (message != null) {
                    McpConnectOutcome.Failed(McpClientException(McpErrorCode.ServerError, message["error"]["message"].stringOrNull))
                } else {
                    McpConnectOutcome.NotMcp
                }
            }
            405 -> McpConnectOutcome.NotMcp
            in 200..299 -> McpConnectOutcome.NotMcp
            else -> McpConnectOutcome.Failed(McpClientException(McpErrorCode.ServerError))
        }
    }

    /** Routes a JSON-RPC error received by the probe. */
    private suspend fun resolveProbeError(error: JsonElement): McpConnectOutcome {
        // A generic error without any modern identifier -> a legacy server refusing before initialize; fall back to the handshake.
        if (!isRecognizableModernError(error)) return legacyHandshake(McpProtocol.LEGACY_INITIALIZE_VERSION)
        val detail = error["message"].stringOrNull
        // -32020 / -32021, or any other error carrying a modern identifier / `data.supported`: still modern, no fallback.
        if (error["code"].longOrNull != McpProtocol.UNSUPPORTED_VERSION_ERROR_CODE) {
            return McpConnectOutcome.Failed(McpClientException(McpErrorCode.ServerError, detail))
        }

        // -32022: pick the highest version we support from `data.supported`.
        val supported = error["data"]["supported"].jsonArrayOrNull?.mapNotNull { it.stringOrNull }.orEmpty()
        if (McpProtocol.MODERN_VERSION in supported) {
            val retry = modernProbe()
            if (requiresAuth(retry)) return McpConnectOutcome.NeedsAuth
            if (retry.status == 200 && isToolsListResult(retry.message)) {
                return McpConnectOutcome.Connected(modernSession())
            }
            return McpConnectOutcome.Failed(
                McpClientException(McpErrorCode.ServerError, retry.message["error"]["message"].stringOrNull),
            )
        }
        // The server only lists legacy versions: resending the modern shape is pointless, so switch to the handshake and use the version it listed.
        val legacy = supported.filter { it in McpProtocol.LEGACY_VERSIONS }.maxOrNull()
        if (legacy != null) return legacyHandshake(legacy)
        return McpConnectOutcome.Failed(McpClientException(McpErrorCode.ServerError, detail))
    }

    private fun modernSession() = McpSession(McpProtocolGeneration.Stateless, McpProtocol.MODERN_VERSION)

    private suspend fun modernProbe(): McpExchange {
        val id = nextId()
        val request = makeRequest(id, "tools/list", emptyList(), toolName = null, session = modernSession())
        // Network failure -> unreachable; generation detection is not retried.
        return exchange(request, requestId = id, key = id, allowsPreConnectRetry = false)
    }

    /** The outcome of `initialize`. */
    private sealed class InitializeOutcome {
        class Established(val session: McpSession) : InitializeOutcome()
        data object NeedsAuth : InitializeOutcome()

        /** The handshake does not hold: the peer is not an MCP server. */
        data object NotMcp : InitializeOutcome()

        /** The peer is an MCP server but rejected this handshake (JSON-RPC error, 5xx, or a version we do not support). */
        class Rejected(val error: McpClientException) : InitializeOutcome()
    }

    /** Legacy handshake: `initialize` -> `initialized`. */
    private suspend fun legacyHandshake(version: String): McpConnectOutcome = when (val outcome = performInitialize(version)) {
        is InitializeOutcome.Established -> {
            sendInitializedNotification(outcome.session)
            McpConnectOutcome.Connected(outcome.session)
        }
        InitializeOutcome.NeedsAuth -> McpConnectOutcome.NeedsAuth
        // Neither the modern probe nor the fallback handshake holds (an ordinary website answering 400 to a JSON POST ends up here) -> not an MCP server.
        InitializeOutcome.NotMcp -> McpConnectOutcome.NotMcp
        is InitializeOutcome.Rejected -> McpConnectOutcome.Failed(outcome.error)
    }

    /** Sends `initialize` and parses the negotiation result. Network failures, timeouts and cancellation are thrown as usual. */
    private suspend fun performInitialize(version: String): InitializeOutcome {
        val id = nextId()
        val response = exchange(makeInitializeRequest(id, version), requestId = id, key = id, allowsPreConnectRetry = false)
        if (requiresAuth(response)) return InitializeOutcome.NeedsAuth
        if (response.status >= 500) return InitializeOutcome.Rejected(McpClientException(McpErrorCode.ServerError))
        val message = response.message
            ?: return if (response.mismatchedId) {
                InitializeOutcome.Rejected(McpClientException(McpErrorCode.ServerError))
            } else {
                InitializeOutcome.NotMcp
            }
        val error = message["error"]
        if (error != null) {
            // A legacy server always implements initialize; a peer lacking even that method is some other JSON-RPC service.
            if (error["code"].longOrNull == McpProtocol.METHOD_NOT_FOUND_ERROR_CODE) return InitializeOutcome.NotMcp
            return InitializeOutcome.Rejected(McpClientException(McpErrorCode.ServerError, error["message"].stringOrNull))
        }
        val result = message["result"] as? JsonObject
        val negotiated = result?.get("protocolVersion").stringOrNull
        if (response.status !in 200..299 || result == null || negotiated == null) return InitializeOutcome.NotMcp
        // The server answered with a version we do not support: disconnect, as the specification requires.
        if (negotiated !in McpProtocol.LEGACY_VERSIONS) {
            return InitializeOutcome.Rejected(McpClientException(McpErrorCode.ServerError))
        }
        return InitializeOutcome.Established(
            McpSession(
                generation = McpProtocolGeneration.Session,
                protocolVersion = negotiated,
                sessionId = response.headers["mcp-session-id"],
                serverName = result["serverInfo"]["name"].stringOrNull,
                serverIconUrl = McpServerIconPolicy.pick(result["serverInfo"]["icons"], endpoint),
            ),
        )
    }

    private suspend fun sendInitializedNotification(session: McpSession) {
        val request = makeNotificationRequest("notifications/initialized", params = null, session = session)
        try {
            exchange(request, requestId = null, key = nextId(), allowsPreConnectRetry = false)
        } catch (error: McpClientException) {
            // The notification is best effort: if the server missed it, a later request fails and is handled by that request's result.
        }
    }

    /** Performs the handshake once more after the server terminated a legacy session; on success the new session is stored and later calls carry the new session id. */
    private suspend fun reinitialize(): McpSession? {
        val outcome = performInitialize(McpProtocol.LEGACY_INITIALIZE_VERSION) as? InitializeOutcome.Established ?: return null
        sendInitializedNotification(outcome.session)
        negotiatedSession = outcome.session
        return outcome.session
    }

    // -- tools/list -----------------------------------------------

    /** Fetches the complete tool list. **Pagination must be followed to the end**; at most 20 pages per run, beyond that it fails. */
    suspend fun listTools(): List<McpToolDefinition> {
        var session = negotiatedSession ?: throw McpClientException(McpErrorCode.ServerError)
        val tools = mutableListOf<McpToolDefinition>()
        var cursor: String? = null
        var pages = 0
        var didReinitialize = false

        while (true) {
            if (pages >= McpProtocol.MAX_TOOLS_LIST_PAGES) throw McpClientException(McpErrorCode.ServerError)
            pages += 1

            val id = nextId()
            val params = if (cursor != null) listOf("cursor" to JsonPrimitive(cursor)) else emptyList()
            val request = makeRequest(id, "tools/list", params, toolName = null, session = session)
            val response = send(request, id, session, allowsPreConnectRetry = true)
            if (requiresAuth(response)) throw McpClientException(McpErrorCode.NeedsAuth)

            // The server terminated the legacy session (404): initialize once more, without retrying indefinitely.
            if (session.generation == McpProtocolGeneration.Session && response.status == 404 && !didReinitialize) {
                didReinitialize = true
                val renegotiated = reinitialize()
                if (renegotiated != null) {
                    session = renegotiated
                    // Cursors issued by the old session are meaningless in the new one; start over.
                    tools.clear()
                    cursor = null
                    pages = 0
                    continue
                }
            }

            val result = response.message?.get("result") as? JsonObject
                ?: throw McpClientException(McpErrorCode.ServerError, response.message["error"]["message"].stringOrNull)
            result["tools"].jsonArrayOrNull?.let { array -> tools += array.mapNotNull(McpToolDefinition::fromJson) }
            val next = result["nextCursor"].stringOrNull
            if (!next.isNullOrEmpty()) {
                cursor = next
                continue
            }
            return tools
        }
    }

    // -- tools/call -----------------------------------------------

    /** Calls a tool. A tool execution error (`isError`) and MRTR (`input_required`) are returned as results; transport and protocol failures throw. */
    suspend fun callTool(name: String, arguments: JsonElement): McpToolCallResult {
        val session = negotiatedSession ?: throw McpClientException(McpErrorCode.ServerError)
        val id = nextId()
        val request = makeRequest(id, "tools/call", listOf("name" to JsonPrimitive(name), "arguments" to arguments), name, session)
        // No automatic retry once tools/call has been sent (replaying a writing tool would write twice).
        val response = send(request, id, session, allowsPreConnectRetry = false)
        if (requiresAuth(response)) throw McpClientException(McpErrorCode.NeedsAuth)

        // The legacy session was terminated: initialize once to restore the session, but **do not replay this call**.
        if (session.generation == McpProtocolGeneration.Session && response.status == 404) {
            try {
                reinitialize()
            } catch (error: McpClientException) {
                // A failed recovery does not change the verdict on this call: it has already failed.
            }
            throw McpClientException(McpErrorCode.ServerError, response.message["error"]["message"].stringOrNull)
        }

        val message = response.message ?: throw McpClientException(McpErrorCode.ServerError)
        val error = message["error"]
        if (error != null) {
            val detail = error["message"].stringOrNull
            // Protocol errors such as an unknown tool are treated as tool_error (fixture error.unknown-tool.json).
            if (error["code"].longOrNull == McpProtocol.INVALID_PARAMS_ERROR_CODE) {
                throw McpClientException(McpErrorCode.ToolError, detail)
            }
            throw McpClientException(McpErrorCode.ServerError, detail)
        }
        val result = message["result"] as? JsonObject ?: throw McpClientException(McpErrorCode.ServerError)

        // MRTR: the decision looks at resultType only and does not recognize method names such as elicitation/create.
        if (result["resultType"].stringOrNull == "input_required") {
            return McpToolCallResult("", isError = false, errorCode = McpErrorCode.NeedsInputUnsupported, truncated = false, structuredContent = null)
        }

        val trimmed = trim(result)
        val isError = result["isError"].booleanOrNull ?: false
        return McpToolCallResult(
            text = trimmed.text,
            isError = isError,
            errorCode = when {
                isError -> McpErrorCode.ToolError
                trimmed.truncated || trimmed.droppedStructured -> McpErrorCode.ResultTooLarge
                else -> null
            },
            truncated = trimmed.truncated,
            structuredContent = trimmed.structuredContent,
        )
    }

    // -- Cancellation ---------------------------------------------

    /**
     * Cancels every request in flight on this client (closing the response stream is the cancellation). To cancel a
     * single call, cancel the coroutine that started it; cancellation propagates down to the connection.
     */
    fun cancel() {
        inFlight.values.forEach { it.cancel() }
    }

    // -- Result trimming ------------------------------------------

    private class Trimmed(val text: String, val truncated: Boolean, val structuredContent: JsonElement?, val droppedStructured: Boolean)

    /**
     * Text items of `content` are concatenated in order; non-text items become a placeholder note; when the text is empty
     * and `structuredContent` exists, its JSON text is used; anything beyond `maxResultChars` is truncated and marked at
     * the end. `structuredContent` itself is subject to the same limit: if it exceeds it once serialized, it is dropped
     * entirely (truncated JSON is not JSON), so an 8 MB object cannot stay in the result by bypassing the limit.
     */
    private fun trim(result: JsonObject): Trimmed {
        val parts = mutableListOf<String>()
        result["content"].jsonArrayOrNull?.forEach { item ->
            val type = item["type"].stringOrNull
            val text = item["text"].stringOrNull
            if (type == "text" && text != null) parts += text else parts += placeholder(type ?: "unknown")
        }
        var text = parts.joinToString("")
        val limit = maxResultChars
        var structured = result["structuredContent"]?.takeUnless { it is JsonNull }
        var droppedStructured = false
        if (structured != null) {
            val serialized = McpJson.ordered(structured)
            if (text.isEmpty()) text = serialized
            if (serialized.length > limit) {
                structured = null
                droppedStructured = true
            }
        }
        if (text.length <= limit) return Trimmed(text, false, structured, droppedStructured)
        val marker = McpClientLimits.TRUNCATION_MARKER
        val keep = maxOf(0, limit - marker.length)
        return Trimmed(safePrefix(text, keep) + marker, true, structured, droppedStructured)
    }

    /** Truncation never splits a surrogate pair (otherwise the text fed back to the model would contain half an emoji). */
    private fun safePrefix(text: String, length: Int): String {
        if (length <= 0) return ""
        val end = if (text[length - 1].isHighSurrogate()) length - 1 else length
        return text.substring(0, end)
    }

    private fun placeholder(type: String) = "[non-text content: $type]"

    private val callTimeoutMillis: Long
        get() {
            val seconds = runtimeConfig.callTimeoutSeconds.takeIf { it > 0 } ?: McpClientLimits.FALLBACK_CALL_TIMEOUT_SECONDS
            return (seconds * 1000).toLong()
        }

    private val maxResultChars: Int
        get() = runtimeConfig.maxResultChars.takeIf { it > 0 } ?: McpClientLimits.FALLBACK_MAX_RESULT_CHARS

    // -- Authorization challenge ----------------------------------

    /** 401, or 403 + `insufficient_scope` (step-up is not implemented currently; it is handled as `needs_auth`). Records the challenge on a match. */
    private fun requiresAuth(response: McpExchange): Boolean {
        val header = response.headers["www-authenticate"]
        if (McpAuthResponseMapping.needsAuthErrorCode(response.status, header) == null) return false
        lastAuthChallenge = McpWwwAuthenticate.parse(header)
        return true
    }

    // -- Request construction -------------------------------------

    private fun nextId(): Int = nextRequestId.getAndIncrement()

    private fun baseHeaders(session: McpSession?): MutableList<Pair<String, String>> {
        val headers = mutableListOf("Accept" to McpClientLimits.ACCEPT_HEADER)
        bearerToken?.let { headers += "Authorization" to "Bearer $it" }
        // initialize itself does not carry MCP-Protocol-Version (the specification requires it on subsequent requests).
        if (session != null) {
            headers += "MCP-Protocol-Version" to session.protocolVersion
            if (session.generation == McpProtocolGeneration.Session && session.sessionId != null) {
                headers += "MCP-Session-Id" to session.sessionId
            }
        }
        return headers
    }

    private fun request(headers: List<Pair<String, String>>, body: JsonElement, timeoutMillis: Long = callTimeoutMillis) = McpHttpRequest(
        url = endpoint,
        method = "POST",
        headers = headers,
        body = McpJson.ordered(body).toByteArray(Charsets.UTF_8),
        contentType = "application/json",
        // Timeouts are decided by our own timer; the transport's idle timeout must be strictly larger, otherwise the two
        // timers race and a configured `callTimeoutSeconds` above the transport default is cut off by the lower layer first.
        idleTimeoutMillis = timeoutMillis + McpHttpLimits.IDLE_TIMEOUT_MARGIN_MILLIS,
    )

    /** Request construction shared by both protocol generations. Modern requests carry `_meta` and the `Mcp-Method` / `Mcp-Name` headers; legacy ones only the negotiated version and the session id. */
    private fun makeRequest(
        id: Int,
        method: String,
        params: List<Pair<String, JsonElement>>,
        toolName: String?,
        session: McpSession,
    ): McpHttpRequest {
        val headers = baseHeaders(session)
        val pairs = params.toMutableList()
        if (session.generation == McpProtocolGeneration.Stateless) {
            pairs += "_meta" to modernMeta(session.protocolVersion)
            headers += "Mcp-Method" to method
            if (toolName != null) headers += "Mcp-Name" to headerValue(toolName)
        }
        return request(headers, jsonRpcMessage(id, method, JsonObject(linkedMapOf(*pairs.toTypedArray()))))
    }

    private fun makeInitializeRequest(id: Int, version: String): McpHttpRequest {
        val params = buildJsonObject {
            put("protocolVersion", version)
            putJsonObject("capabilities") { putJsonObject("tools") {} }
            putJsonObject("clientInfo") {
                put("name", McpProtocol.CLIENT_INFO_NAME)
                put("version", McpProtocol.CLIENT_INFO_VERSION)
            }
        }
        return request(baseHeaders(null), jsonRpcMessage(id, "initialize", params))
    }

    private fun makeNotificationRequest(
        method: String,
        params: JsonElement?,
        session: McpSession,
        timeoutMillis: Long = callTimeoutMillis,
    ): McpHttpRequest {
        val body = buildJsonObject {
            put("jsonrpc", "2.0")
            put("method", method)
            if (params != null) put("params", params)
        }
        return request(baseHeaders(session), body, timeoutMillis)
    }

    private fun jsonRpcMessage(id: Int, method: String, params: JsonElement): JsonElement = buildJsonObject {
        put("jsonrpc", "2.0")
        put("id", id)
        put("method", method)
        put("params", params)
    }

    /** Per-request `_meta` of the modern protocol: `protocolVersion` and `clientCapabilities` are required, `clientInfo` is a SHOULD. */
    private fun modernMeta(version: String): JsonElement = buildJsonObject {
        put(McpProtocol.META_PROTOCOL_VERSION_KEY, version)
        putJsonObject(McpProtocol.META_CLIENT_INFO_KEY) {
            put("name", McpProtocol.CLIENT_INFO_NAME)
            put("version", McpProtocol.CLIENT_INFO_VERSION)
        }
        putJsonObject(McpProtocol.META_CLIENT_CAPABILITIES_KEY) { putJsonObject("tools") {} }
    }

    // -- Transport ------------------------------------------------

    /** Sends a request that belongs to a negotiated session. When cancelled, the legacy protocol additionally sends a cancellation notification. */
    private suspend fun send(request: McpHttpRequest, id: Int, session: McpSession, allowsPreConnectRetry: Boolean): McpExchange {
        try {
            return exchange(request, requestId = id, key = id, allowsPreConnectRetry = allowsPreConnectRetry)
        } catch (error: McpClientException) {
            if (error.code == McpErrorCode.Cancelled && session.generation == McpProtocolGeneration.Session) {
                sendCancelledNotification(id, session)
            }
            throw error
        }
    }

    /**
     * Legacy cancellation notification: closing the response stream already is the cancellation, this merely tells a
     * legacy server it can stop. Best effort: it is not awaited, failures are ignored, and it takes none of the caller's
     * time. The modern protocol has no such notification over Streamable HTTP.
     */
    private fun sendCancelledNotification(requestId: Int, session: McpSession) {
        val params = buildJsonObject {
            put("requestId", requestId)
            put("reason", "User requested cancellation")
        }
        val request = makeNotificationRequest(
            "notifications/cancelled",
            params,
            session,
            timeoutMillis = McpClientLimits.CANCEL_NOTIFICATION_TIMEOUT_MILLIS,
        )
        sideScope.launch {
            try {
                execute(request, requestId = null, timeoutMillis = McpClientLimits.CANCEL_NOTIFICATION_TIMEOUT_MILLIS, allowsPreConnectRetry = false)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
            }
        }
    }

    /**
     * A single HTTP exchange. Cancelling the caller's coroutine, or someone calling [cancel], aborts the connection and
     * throws `cancelled`.
     * - [requestId]: the JSON-RPC request id; notifications have none, pass null (the response body is not awaited).
     * - [key]: the key in the cancellation table.
     */
    private suspend fun exchange(request: McpHttpRequest, requestId: Int?, key: Int, allowsPreConnectRetry: Boolean): McpExchange {
        if (!currentCoroutineContext().isActive) throw McpClientException(McpErrorCode.Cancelled)
        // Second gate for https-only: on top of address validation, the client itself sends nothing (tokens included) to a non-https address.
        if (!McpOrigin.isHttps(endpoint)) throw McpClientException(McpErrorCode.Unreachable)
        val timeout = callTimeoutMillis
        return try {
            coroutineScope {
                val deferred = async {
                    execute(request, requestId, timeout, allowsPreConnectRetry)
                }
                inFlight[key] = deferred
                try {
                    deferred.await()
                } finally {
                    inFlight.remove(key, deferred)
                }
            }
        } catch (error: CancellationException) {
            // The caller was cancelled or `cancel()` aborted this exchange: map to `cancelled` of the closed set, not to `unreachable`.
            throw McpClientException(McpErrorCode.Cancelled)
        }
    }

    private suspend fun execute(request: McpHttpRequest, requestId: Int?, timeoutMillis: Long, allowsPreConnectRetry: Boolean): McpExchange {
        var attempt = 0
        while (true) {
            try {
                return withTimeout(timeoutMillis) {
                    try {
                        perform(request, requestId)
                    } catch (error: Exception) {
                        // When the timer fires or on cancellation, the lower layer may end with an IO exception rather than a
                        // cancellation exception (the connection was aborted). Attribute by coroutine state first, so that a
                        // timeout or cancellation is not reported as a connection failure.
                        if (error !is CancellationException) ensureActive()
                        throw error
                    }
                }
            } catch (error: TimeoutCancellationException) {
                throw McpClientException(McpErrorCode.Timeout)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                currentCoroutineContext().ensureActive()
                if (allowsPreConnectRetry && attempt == 0 && isPreConnect(error)) {
                    attempt += 1
                    continue
                }
                throw clientError(error)
            }
        }
    }

    /** Transport errors -> error codes of the closed set. Cancellation and timeout have their own codes and are not folded into `unreachable`. */
    private fun clientError(error: Exception): McpClientException = when (error) {
        is McpClientException -> error
        is HttpRequestTimeoutException, is KtorSocketTimeoutException, is SocketTimeoutException, is ConnectTimeoutException ->
            McpClientException(McpErrorCode.Timeout)
        is McpHttpException.BodyTooLarge, is McpJsonException -> McpClientException(McpErrorCode.ServerError)
        // Every other network error, non-https, and rejected redirects.
        else -> McpClientException(McpErrorCode.Unreachable)
    }

    /**
     * Sends the request and returns the JSON-RPC response **matching this request's id**.
     *
     * The SSE stream is parsed as it arrives: as soon as the matching final response is seen, it returns and closes the
     * connection without waiting for the server to close the stream (the final response SHOULD end the stream, but that
     * is not guaranteed). Both forms are subject to the same byte limit.
     */
    private suspend fun perform(request: McpHttpRequest, requestId: Int?): McpExchange =
        McpHttp.withResponse(request, transport, McpRedirectPolicy.SameOriginHttps) { head, body ->
            // A notification has no response to wait for: the status line is enough.
            if (requestId == null) return@withResponse McpExchange(head.status, head.headers, null, false)

            val limit = McpHttpLimits.MAX_RESPONSE_BYTES
            val declared = head.headers["content-length"]?.trim()?.toLongOrNull()
            if (declared != null && declared > limit) throw McpHttpException.BodyTooLarge()

            val candidates = mutableListOf<JsonElement>()
            if (head.isEventStream) {
                val found = readEventStream(body, requestId, limit, candidates)
                if (found != null) return@withResponse McpExchange(head.status, head.headers, found, false)
            } else {
                val bytes = McpHttp.readBody(body, limit)
                if (bytes.isNotEmpty()) {
                    val value = McpJson.parseOrNull(bytes)
                    // Fallback for a dishonest Content-Type: try once more as SSE. Rejected bodies (deep nesting, bad numbers)
                    // parse as neither and end up as "no matching response", which the caller handles as a protocol error.
                    if (value != null) candidates += value else candidates += McpSse.messages(bytes)
                }
            }
            val message = candidates.firstOrNull { isResponse(it, requestId) }
            // Notifications mixed into the stream have no result / error and do not count; only a result / error with a non-matching id is a protocol error.
            McpExchange(head.status, head.headers, message, message == null && candidates.any(::isJsonRpcResponse))
        }

    /** Reads SSE as a stream: returns once the message with the matching id arrives; other messages are collected in [candidates]. */
    private suspend fun readEventStream(
        body: ByteReadChannel,
        requestId: Int,
        limit: Int,
        candidates: MutableList<JsonElement>,
    ): JsonElement? {
        val parser = McpSseParser()
        val buffer = ByteArray(8 * 1024)
        var received = 0L
        while (true) {
            val read = body.readAvailable(buffer, 0, buffer.size)
            if (read < 0) break
            for (index in 0 until read) {
                received += 1
                if (received > limit) throw McpHttpException.BodyTooLarge()
                val message = parser.consume(buffer[index]) ?: continue
                if (isResponse(message, requestId)) return message
                candidates += message
            }
        }
        parser.finish()?.let(candidates::add)
        return null
    }

    private fun isJsonRpcResponse(message: JsonElement): Boolean =
        message["jsonrpc"].stringOrNull == "2.0" && (message["result"] != null || message["error"] != null)

    /**
     * Whether this is the response to this request: **matched strictly by id**, with no fallback to "the first response
     * in the stream", since a response with a mixed-up id may be another call's result. The only exception is what
     * JSON-RPC allows: an error with a null id (the server could not read the request id).
     */
    private fun isResponse(message: JsonElement, requestId: Int): Boolean {
        if (!isJsonRpcResponse(message)) return false
        val id = message["id"]
        if (message["result"] == null && (id == null || id is JsonNull)) return true
        return id.longOrNull == requestId.toLong()
    }

    /** Retries once, and only for network errors that happen before the connection is established. `tools/call` never passes this switch. */
    private fun isPreConnect(error: Exception): Boolean = error is UnknownHostException ||
        error is ConnectException ||
        error is NoRouteToHostException ||
        error is SSLHandshakeException ||
        error is SSLPeerUnverifiedException

    companion object {
        /**
         * Header values of the modern protocol: visible ASCII is sent as is; values with non-ASCII, control characters or
         * leading / trailing whitespace are encoded as `=?base64?{base64 of the UTF-8}?=` (lowercase prefix and suffix).
         * Put into a header verbatim, the transport would rewrite or reject non-ASCII bytes, and the server would answer
         * `-32020` when header and body disagree. A value that itself looks like an encoded result is encoded as well, so
         * the peer does not decode it wrongly.
         */
        fun headerValue(value: String): String {
            val isPlain = value.all { it.code in 0x20..0x7E } &&
                value == value.trim(' ', '\t') &&
                !value.startsWith("=?base64?")
            if (isPlain) return value
            return "=?base64?" + java.util.Base64.getEncoder().encodeToString(value.toByteArray(Charsets.UTF_8)) + "?="
        }

        /** A valid `tools/list` result: `result` is an object with a `tools` array. */
        private fun isToolsListResult(message: JsonElement?): Boolean = message["result"]["tools"] is JsonArray

        /**
         * "Recognizable modern error": any one of these marks the server as modern, which must not be retried with
         * `initialize`.
         * (1) the error code is `-32022` / `-32021` / `-32020`; (2) the error's `message` or `data` contains an identifier
         * exclusive to the modern protocol; (3) the error carries `data.supported`.
         */
        private fun isRecognizableModernError(error: JsonElement): Boolean {
            val code = error["code"].longOrNull
            if (code != null && code in McpProtocol.MODERN_ERROR_CODES) return true
            if (error["data"]["supported"] != null) return true
            val message = error["message"].stringOrNull
            if (message != null && McpProtocol.containsModernMarker(message)) return true
            val data = error["data"]
            if (data != null && McpProtocol.containsModernMarker(McpJson.ordered(data))) return true
            return false
        }
    }
}

/** The result of one JSON-RPC exchange: HTTP status, response headers (lowercase names), and the response matching the request id. */
private class McpExchange(
    val status: Int,
    val headers: Map<String, String>,
    /** The JSON-RPC response matching this request's id; null when the body is empty, not JSON-RPC, or no id matches. */
    val message: JsonElement?,
    /** The body contains a JSON-RPC response, but none matches this request's id. */
    val mismatchedId: Boolean,
)
