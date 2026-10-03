package ai.oriveo.community.core.mcp

import io.ktor.utils.io.ByteChannel
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.writeFully
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// Replay layer for the MCP protocol client tests.
//
// Production code sends requests through [McpRawTransport]; [McpScriptedTransport] here replays fixtures from a queue
// (`shared/test-fixtures/mcp/`, the single source shared by all clients) and records every request **actually
// received** plus connections cut off midway. What is under test is the request production code sends and the error
// code it throws; the replay layer only answers.

object McpFixture {
    val root: File by lazy {
        generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
            .map { File(it, "shared/test-fixtures/mcp") }
            .firstOrNull { it.isDirectory }
            ?: error("shared/test-fixtures/mcp not found")
    }

    fun text(name: String): String = File(root, name).readText(Charsets.UTF_8)

    fun json(name: String): JsonElement = Json.parseToJsonElement(text(name))
}

class McpScriptedTransport : McpRawTransport {

    data class Stub(
        val status: Int = 200,
        val headers: Map<String, String> = emptyMap(),
        val body: ByteArray = ByteArray(0),
        /** How long to wait before sending the response headers (cancellable). */
        val delayMillis: Long = 0,
        /** Send no response and fail with this exception instead (simulates a network-layer error). */
        val error: Exception? = null,
        /** Rewrite the id of a JSON-RPC response with a non-null id to this request's id (fixture ids are the fixed values from recording time). */
        val rewriteId: Boolean = true,
        /** Response body delivered in chunks (when set, [body] is not used). `__REQUEST_ID__` inside a chunk is replaced with this request's id. */
        val chunks: List<ByteArray>? = null,
        val chunkIntervalMillis: Long = 20,
        /** Do not finish after the body is sent (simulates a server that sends the final response but never closes the stream). */
        val keepOpen: Boolean = false,
    )

    class Captured(val request: McpHttpRequest) {
        val url: String get() = request.url
        val method: String get() = request.method
        val host: String? get() = McpOrigin.parse(request.url)?.host
        val path: String? get() = McpOrigin.parse(request.url)?.path
        val bodyText: String? get() = request.body?.toString(Charsets.UTF_8)
        val json: JsonElement? get() = bodyText?.let { runCatching { Json.parseToJsonElement(it) }.getOrNull() }
        val jsonRpcMethod: String? get() = json["method"].stringOrNull
        val jsonRpcName: String? get() = json["params"]["name"].stringOrNull
        val jsonRpcId: Long? get() = json["id"].longOrNull

        fun header(name: String): String? = request.header(name)
    }

    private val lock = Any()
    private val queue = ArrayDeque<Stub>()
    private var fallback: Stub? = null
    private val captured = mutableListOf<Captured>()
    private val aborted = mutableListOf<Captured>()

    fun reset() = synchronized(lock) {
        queue.clear()
        fallback = null
        captured.clear()
        aborted.clear()
    }

    fun enqueue(vararg stubs: Stub) = synchronized(lock) { queue.addAll(stubs) }

    fun enqueue(stubs: List<Stub>) = synchronized(lock) { queue.addAll(stubs) }

    fun setFallback(stub: Stub) = synchronized(lock) { fallback = stub }

    fun requests(method: String? = null): List<Captured> = synchronized(lock) {
        captured.filter { method == null || it.jsonRpcMethod == method }
    }

    fun abortedRequests(): List<Captured> = synchronized(lock) { aborted.toList() }

    override suspend fun <T> exchange(request: McpHttpRequest, block: suspend (McpHttpHead, ByteReadChannel) -> T): T {
        val capture = Captured(request)
        val isNotification = capture.json is JsonObject && capture.json["id"] == null && capture.jsonRpcMethod != null
        val stub = synchronized(lock) {
            captured += capture
            if (isNotification) null else queue.removeFirstOrNull() ?: fallback
        }
        if (isNotification) {
            return block(McpHttpHead(202, emptyMap()), ByteReadChannel(ByteArray(0)))
        }
        stub ?: throw IOException("no scripted response")
        try {
            if (stub.delayMillis > 0) delay(stub.delayMillis)
            stub.error?.let { throw it }
            val requestId = capture.jsonRpcId
            val chunks = (stub.chunks ?: listOf(stub.body)).map { chunk ->
                var data = replacingPlaceholder(chunk, requestId)
                if (stub.rewriteId && stub.chunks == null && requestId != null) data = rewritingId(data, requestId)
                data
            }
            val head = McpHttpHead(stub.status, stub.headers.mapKeys { it.key.lowercase() })
            return coroutineScope {
                val channel = ByteChannel(autoFlush = true)
                val writer = launch {
                    for (chunk in chunks) {
                        channel.writeFully(chunk)
                        if (stub.chunks != null) delay(stub.chunkIntervalMillis)
                    }
                    if (stub.keepOpen) awaitCancellation()
                    channel.flushAndClose()
                }
                try {
                    block(head, channel)
                } finally {
                    // The client stopped reading before the server finished writing: this connection was cut off by the client.
                    if (writer.isActive) synchronized(lock) { aborted += capture }
                    writer.cancel()
                }
            }
        } catch (error: CancellationException) {
            synchronized(lock) { if (capture !in aborted) aborted += capture }
            throw error
        }
    }

    companion object {
        const val REQUEST_ID_PLACEHOLDER = "__REQUEST_ID__"

        private fun replacingPlaceholder(data: ByteArray, requestId: Long?): ByteArray {
            if (requestId == null) return data
            val text = data.toString(Charsets.UTF_8)
            if (!text.contains(REQUEST_ID_PLACEHOLDER)) return data
            return text.replace(REQUEST_ID_PLACEHOLDER, requestId.toString()).toByteArray(Charsets.UTF_8)
        }

        /** Makes the replayed response echo the request id as a well-behaved server would (both the JSON body and SSE data lines are rewritten). */
        private fun rewritingId(data: ByteArray, requestId: Long): ByteArray {
            if (data.isEmpty()) return data
            val text = data.toString(Charsets.UTF_8)
            runCatching { Json.parseToJsonElement(text) }.getOrNull()?.let { value ->
                val rewritten = rewrite(value, requestId) ?: return data
                return McpJson.ordered(rewritten).toByteArray(Charsets.UTF_8)
            }
            val lines = text.split("\n").map { line ->
                if (!line.startsWith("data:")) return@map line
                val payload = line.removePrefix("data:").trimEnd('\r')
                val value = runCatching { Json.parseToJsonElement(payload) }.getOrNull() ?: return@map line
                val rewritten = rewrite(value, requestId) ?: return@map line
                "data: " + McpJson.ordered(rewritten) + if (line.endsWith("\r")) "\r" else ""
            }
            return lines.joinToString("\n").toByteArray(Charsets.UTF_8)
        }

        /** Only rewrites JSON-RPC responses with a non-null id; notifications, errors with `id: null` and plain JSON are left alone. */
        private fun rewrite(value: JsonElement, requestId: Long): JsonElement? {
            val obj = value as? JsonObject ?: return null
            if (obj["result"] == null && obj["error"] == null) return null
            val id = obj["id"]
            if (id == null || id is JsonNull) return null
            return JsonObject(obj.mapValues { (key, item) -> if (key == "id") JsonPrimitive(requestId) else item })
        }

        /** Fixture response (`{status, headers, body | raw}`) → replay entry. */
        fun stub(json: JsonElement): Stub {
            val headers = json["headers"].jsonObjectOrNull?.mapNotNull { (key, value) ->
                value.stringOrNull?.let { key to it }
            }?.toMap().orEmpty()
            val raw = json["raw"].stringOrNull
            val body = when {
                raw != null -> raw.toByteArray(Charsets.UTF_8)
                json["body"] != null -> McpJson.ordered(json["body"]!!).toByteArray(Charsets.UTF_8)
                else -> ByteArray(0)
            }
            return Stub(status = json["status"].longOrNull?.toInt() ?: 200, headers = headers, body = body)
        }

        fun stub(fixture: String): Stub = stub(McpFixture.json(fixture))

        fun json(
            text: String,
            status: Int = 200,
            headers: Map<String, String> = emptyMap(),
            delayMillis: Long = 0,
            rewriteId: Boolean = true,
        ) = Stub(
            status = status,
            headers = mapOf("Content-Type" to "application/json") + headers,
            body = text.toByteArray(Charsets.UTF_8),
            delayMillis = delayMillis,
            rewriteId = rewriteId,
        )

        fun status(status: Int, headers: Map<String, String> = emptyMap()) = Stub(status = status, headers = headers)

        fun emptyJson(status: Int) = Stub(status = status, headers = mapOf("Content-Type" to "application/json"))

        /** An SSE stream delivered in chunks. `__REQUEST_ID__` inside a chunk stands for this request's id. */
        fun sse(chunks: List<String>, keepOpen: Boolean = false) = Stub(
            status = 200,
            headers = mapOf("Content-Type" to "text/event-stream"),
            chunks = chunks.map { it.toByteArray(Charsets.UTF_8) },
            keepOpen = keepOpen,
        )

        fun sseBody(text: String) = Stub(
            status = 200,
            headers = mapOf("Content-Type" to "text/event-stream"),
            body = text.toByteArray(Charsets.UTF_8),
        )

        fun redirect(to: String, status: Int = 307) = Stub(status = status, headers = mapOf("Location" to to))

        fun networkError(error: Exception = java.net.ConnectException("refused")) = Stub(error = error)

        fun notMcpCases(): List<Pair<String, Stub>> =
            McpFixture.json("protocol/shared/not-mcp.responses.json")["cases"].jsonArrayOrNull.orEmpty().mapNotNull { item ->
                val id = item["caseId"].stringOrNull ?: return@mapNotNull null
                id to stub(item)
            }

        fun textResult(text: String) =
            """{"jsonrpc":"2.0","id":__REQUEST_ID__,"result":{"content":[{"type":"text","text":"$text"}]}}"""
    }
}

/** Sets up connected clients. */
class McpClientHarness {
    val transport = McpScriptedTransport()

    fun client(endpoint: String = ENDPOINT, runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback) =
        McpClient(endpoint = endpoint, runtimeConfig = runtimeConfig, transport = transport)

    /** A client connected with the modern protocol: the probe uses `tools/list`, then [stubs] are replayed in order. */
    suspend fun modern(
        stubs: List<McpScriptedTransport.Stub> = emptyList(),
        runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback,
        bearerToken: String? = null,
    ): McpClient {
        transport.reset()
        transport.enqueue(McpScriptedTransport.stub("protocol/stateless/tools-list.response.json"))
        transport.enqueue(stubs)
        val client = client(runtimeConfig = runtimeConfig)
        checkNotNull(client.connect(bearerToken).session) { "not connected" }
        return client
    }

    /** A client connected with the legacy protocol: the modern probe gets a 400 with an empty body → falls back to `initialize`. */
    suspend fun legacy(
        stubs: List<McpScriptedTransport.Stub> = emptyList(),
        runtimeConfig: McpRuntimeConfig = McpRuntimeConfig.fallback,
        bearerToken: String? = null,
    ): McpClient {
        transport.reset()
        transport.enqueue(McpScriptedTransport.emptyJson(400))
        transport.enqueue(McpScriptedTransport.stub("protocol/session/initialize.response.json"))
        transport.enqueue(stubs)
        val client = client(runtimeConfig = runtimeConfig)
        checkNotNull(client.connect(bearerToken).session) { "not connected" }
        return client
    }

    /**
     * Compares a request sent by the production path against a fixture: method, path, every header the fixture lists,
     * protocol headers that show up without being listed, and the canonical request body with `id` removed.
     */
    fun mismatches(captured: McpScriptedTransport.Captured, fixture: String): List<String> {
        val expected = McpFixture.json(fixture)
        val problems = mutableListOf<String>()
        if (captured.method != expected["method"].stringOrNull) problems += "method: ${captured.method}"
        if (captured.path != expected["path"].stringOrNull) problems += "path: ${captured.path}"
        val headers = expected["headers"].jsonObjectOrNull.orEmpty()
        for ((key, value) in headers) {
            if (captured.header(key) != value.stringOrNull) problems += "header $key: ${captured.header(key)}"
        }
        for (key in listOf("MCP-Protocol-Version", "Mcp-Method", "Mcp-Name", "MCP-Session-Id", "Authorization")) {
            if (headers.keys.none { it.equals(key, ignoreCase = true) } && captured.header(key) != null) {
                problems += "unexpected header $key"
            }
        }
        val expectedBody = expected["body"] as? JsonObject
        val actualBody = captured.json as? JsonObject
        if (expectedBody == null || actualBody == null) return problems + "body is not a JSON object"
        if (expectedBody["id"] != null && actualBody["id"].longOrNull == null) problems += "id is not an integer"
        if (expectedBody["id"] == null && actualBody["id"] != null) problems += "notification carries an id"
        val strip = { obj: JsonObject -> McpJson.canonical(JsonObject(obj.filterKeys { it != "id" })) }
        if (strip(expectedBody) != strip(actualBody)) problems += "body: ${strip(actualBody)}"
        return problems
    }

    companion object {
        const val ENDPOINT = "https://mcp.example.com/mcp"

        val weatherArguments: JsonElement = buildJsonObject { put("location", "New York") }

        /** Polls until the condition holds or the timeout expires (asynchronous side requests and cut-off connections take a moment to land in the record). */
        suspend fun eventually(timeoutMillis: Long = 2_000, condition: () -> Boolean): Boolean {
            val deadline = System.currentTimeMillis() + timeoutMillis
            while (System.currentTimeMillis() < deadline) {
                if (condition()) return true
                delay(20)
            }
            return condition()
        }
    }
}
