package ai.oriveo.community.core.mcp

import ai.oriveo.community.core.network.NativeUserAgent
import io.ktor.client.HttpClient
import io.ktor.client.HttpClientConfig
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.HttpTimeoutConfig
import io.ktor.client.plugins.timeout
import io.ktor.client.request.header
import io.ktor.client.request.prepareRequest
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.ContentType
import io.ktor.http.HttpMethod
import io.ktor.http.content.ByteArrayContent
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.readAvailable
import java.io.ByteArrayOutputStream
import java.net.URI
import java.util.Locale

// The HTTP foundation for remote MCP: https only, resource limits and redirect handling.
//
// The protocol client (`McpClient`) and the OAuth transport share this layer, and three things are done here exactly once:
// https only, redirects followed **by our own code** according to a policy, and a byte limit on response bodies.
//
// The underlying transport ([McpRawTransport]) sends a single request and never follows redirects itself; the production
// implementation is a dedicated Ktor + OkHttp client (`followRedirects = false`, no cookie / cache plugins).
// Redirect decisions live in this layer instead of being left to OkHttp: when OkHttp follows a redirect it rewrites POST
// to GET and strips `Authorization` across origins, which are decisions made on our behalf. The requirement is that not a
// single byte is sent across origins, and only a decision made in our own code can be checked hop by hop and pinned by tests.

object McpHttpLimits {
    /** Limit for a single response body. Reading stops once it is exceeded. */
    const val MAX_RESPONSE_BYTES = 8 * 1024 * 1024

    /** Limit for OAuth metadata / token / registration responses: these are small documents of a few KB. */
    const val MAX_AUTH_RESPONSE_BYTES = 1024 * 1024

    /** The maximum number of same-origin redirect hops to follow. */
    const val MAX_REDIRECTS = 5

    /**
     * The transport's idle timeout exceeds the call timeout by this many milliseconds: timeouts are always decided by
     * the caller's timer. Otherwise a configured `callTimeoutSeconds` larger than the transport default would be cut
     * off by the lower layer first and reported as a connection failure.
     */
    const val IDLE_TIMEOUT_MARGIN_MILLIS = 30_000L
}

/** Errors of the HTTP foundation. None carries the address or the body (the address may contain a secret). */
sealed class McpHttpException(message: String) : Exception(message) {
    /** The address is not https. */
    class InsecureUrl : McpHttpException("insecure url")

    /** The redirect was rejected: cross-origin, downgraded to non-https, changed the request method, exceeded the hop limit, or the request does not allow redirects at all. */
    class RedirectRejected : McpHttpException("redirect rejected")

    /** The response body exceeds the limit. */
    class BodyTooLarge : McpHttpException("body too large")
}

object McpOrigin {
    fun isHttps(url: String): Boolean {
        val uri = parse(url) ?: return false
        return uri.scheme?.lowercase(Locale.ROOT) == "https" && !uri.host.isNullOrEmpty()
    }

    /** Same origin = identical scheme + host + port (compared after filling in the scheme's default port). */
    fun isSameOrigin(lhs: String, rhs: String): Boolean {
        val left = key(lhs) ?: return false
        val right = key(rhs) ?: return false
        return left == right
    }

    /** `scheme://host:port`, or null when it cannot be parsed. */
    fun key(url: String): String? {
        val uri = parse(url) ?: return null
        val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return null
        val host = uri.host?.lowercase(Locale.ROOT)?.takeIf { it.isNotEmpty() } ?: return null
        val port = if (uri.port >= 0) uri.port else when (scheme) {
            "https" -> 443
            "http" -> 80
            else -> -1
        }
        return "$scheme://$host:$port"
    }

    fun parse(url: String): URI? = try {
        URI(url)
    } catch (error: Exception) {
        null
    }
}

/** Redirect policy (a server's credentials are only sent to the origin of its recorded address). */
enum class McpRedirectPolicy {
    /** Follow same-origin https only, without changing the request method, for at most [McpHttpLimits.MAX_REDIRECTS] hops. */
    SameOriginHttps,

    /** Never follow (token and registration endpoints: the request body carries the authorization code / refresh token / verifier). */
    Never,
}

/** An outbound request. Header names are sent as spelled; `Content-Type` is given separately (Ktor does not allow setting it as a plain header). */
class McpHttpRequest(
    val url: String,
    val method: String = "POST",
    val headers: List<Pair<String, String>> = emptyList(),
    val body: ByteArray? = null,
    val contentType: String? = null,
    /** The transport's idle timeout. Must be strictly greater than the caller's own overall deadline (see [McpHttpLimits.IDLE_TIMEOUT_MARGIN_MILLIS]). */
    val idleTimeoutMillis: Long = 60_000L + McpHttpLimits.IDLE_TIMEOUT_MARGIN_MILLIS,
) {
    /** Header names are compared case-insensitively. */
    fun header(name: String): String? {
        if (name.equals("Content-Type", ignoreCase = true) && contentType != null) return contentType
        return headers.lastOrNull { it.first.equals(name, ignoreCase = true) }?.second
    }

    fun copy(url: String = this.url, method: String = this.method): McpHttpRequest =
        McpHttpRequest(url, method, headers, body, contentType, idleTimeoutMillis)

    /** The address may contain a secret and the headers hold a token: nothing is printed. */
    override fun toString(): String = "McpHttpRequest(method=$method)"
}

/** Response head. Header names are lowercased (HTTP header names are case-insensitive), values are verbatim. */
class McpHttpHead(val status: Int, val headers: Map<String, String>) {
    val contentType: String? get() = headers["content-type"]

    val isEventStream: Boolean get() = contentType.orEmpty().lowercase(Locale.ROOT).contains("text/event-stream")
}

/** An HTTP response fetched in one piece (for OAuth metadata / token / registration). */
class McpHttpResponse(val status: Int, val headers: Map<String, String>, val body: ByteArray) {
    val contentType: String? get() = headers["content-type"]
}

/**
 * The underlying transport: sends a single request, **never follows redirects itself**, and hands the response head and
 * byte stream to [block]. The connection is closed once [block] returns (or throws), so the caller can return as soon as
 * it has read what it needs without draining the stream. The connection is aborted when the coroutine is cancelled.
 */
interface McpRawTransport {
    suspend fun <T> exchange(request: McpHttpRequest, block: suspend (McpHttpHead, ByteReadChannel) -> T): T
}

object McpHttp {
    private val REDIRECT_STATUSES = setOf(301, 302, 303, 307, 308)

    /**
     * Sends the request and hands the response head and byte stream to [block]; redirects are followed here according to [redirect].
     *
     * - The address is not https -> [McpHttpException.InsecureUrl], **without sending a single byte**.
     * - The policy rejects a redirect -> [McpHttpException.RedirectRejected]; the redirect target receives no request.
     * - When following a same-origin redirect the original headers (including `Authorization`) are sent unchanged: the
     *   target is confirmed to be same-origin and the token is meant for it. Otherwise the server would answer 401 after a
     *   same-origin 307 and that would be misreported as "sign in again".
     */
    suspend fun <T> withResponse(
        request: McpHttpRequest,
        transport: McpRawTransport,
        redirect: McpRedirectPolicy,
        block: suspend (McpHttpHead, ByteReadChannel) -> T,
    ): T {
        if (!McpOrigin.isHttps(request.url)) throw McpHttpException.InsecureUrl()
        var current = request
        var hops = 0
        while (true) {
            val step = transport.exchange(current) { head, body ->
                val location = head.headers["location"]
                if (head.status in REDIRECT_STATUSES && location != null) {
                    Step.Redirect(head.status, location)
                } else {
                    Step.Done(block(head, body))
                }
            }
            when (step) {
                is Step.Done -> return step.value
                is Step.Redirect -> {
                    current = nextHop(origin = request, current = current, step = step, policy = redirect, hops = hops)
                    hops += 1
                }
            }
        }
    }

    private sealed class Step<out T> {
        class Done<T>(val value: T) : Step<T>()
        class Redirect(val status: Int, val location: String) : Step<Nothing>()
    }

    private fun nextHop(
        origin: McpHttpRequest,
        current: McpHttpRequest,
        step: Step.Redirect,
        policy: McpRedirectPolicy,
        hops: Int,
    ): McpHttpRequest {
        if (policy != McpRedirectPolicy.SameOriginHttps) throw McpHttpException.RedirectRejected()
        if (hops >= McpHttpLimits.MAX_REDIRECTS) throw McpHttpException.RedirectRejected()
        val target = try {
            URI(current.url).resolve(step.location.trim()).toString()
        } catch (error: Exception) {
            throw McpHttpException.RedirectRejected()
        }
        // Compared against the origin of the **initial request**, not the previous hop: a chain of same-origin hops must not drift away either.
        if (!McpOrigin.isHttps(target) || !McpOrigin.isSameOrigin(origin.url, target)) {
            throw McpHttpException.RedirectRejected()
        }
        // 301 / 302 / 303 rewrite POST to GET: a GET to an MCP endpoint yields either 405 or (on older servers) a hanging
        // long-lived SSE stream. Only method-preserving redirects are followed (307 / 308; 301 / 302 on a GET keep the method).
        val method = current.method.uppercase(Locale.ROOT)
        val rewritesToGet = step.status in setOf(301, 302, 303) && method != "GET" && method != "HEAD"
        if (rewritesToGet) throw McpHttpException.RedirectRejected()
        return current.copy(url = target)
    }

    /** Reads the response body into memory; throws [McpHttpException.BodyTooLarge] and stops reading once [limit] is exceeded. */
    suspend fun readBody(channel: ByteReadChannel, limit: Int = McpHttpLimits.MAX_RESPONSE_BYTES): ByteArray {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        while (true) {
            val read = channel.readAvailable(buffer, 0, buffer.size)
            if (read < 0) break
            if (out.size() + read > limit) throw McpHttpException.BodyTooLarge()
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    /** Fetches the whole response in one piece. */
    suspend fun send(
        request: McpHttpRequest,
        transport: McpRawTransport,
        redirect: McpRedirectPolicy,
        limit: Int = McpHttpLimits.MAX_RESPONSE_BYTES,
    ): McpHttpResponse = withResponse(request, transport, redirect) { head, body ->
        McpHttpResponse(head.status, head.headers, readBody(body, limit))
    }
}

/**
 * Production transport: a dedicated Ktor + OkHttp client.
 *
 * It deliberately does not reuse the app's shared `HttpClient`: that instance installs logging and reachability
 * observers. MCP requests authenticate solely through the
 * `Authorization` header set here; cookies and caching are of no use, and a third-party server must not be able to
 * write them.
 */
class KtorMcpRawTransport(private val client: HttpClient = createClient()) : McpRawTransport {

    override suspend fun <T> exchange(
        request: McpHttpRequest,
        block: suspend (McpHttpHead, ByteReadChannel) -> T,
    ): T {
        val statement = client.prepareRequest {
            url(request.url)
            method = HttpMethod.parse(request.method.uppercase(Locale.ROOT))
            for ((name, value) in request.headers) {
                if (!name.equals("Content-Type", ignoreCase = true)) header(name, value)
            }
            if (request.header("User-Agent") == null) header("User-Agent", userAgent)
            request.body?.let { bytes ->
                val type = request.contentType?.let(ContentType::parse) ?: ContentType.Application.Json
                setBody(ByteArrayContent(bytes, type))
            }
            timeout {
                socketTimeoutMillis = request.idleTimeoutMillis
                requestTimeoutMillis = HttpTimeoutConfig.INFINITE_TIMEOUT_MS
            }
        }
        return statement.execute { response ->
            val headers = mutableMapOf<String, String>()
            response.headers.names().forEach { name ->
                response.headers[name]?.let { headers[name.lowercase(Locale.ROOT)] = it }
            }
            block(McpHttpHead(response.status.value, headers), response.bodyAsChannel())
        }
    }

    private val userAgent: String by lazy { runCatching { NativeUserAgent.current() }.getOrDefault("Oriveo") }

    companion object {
        /** Limit for establishing the connection. The overall call deadline is decided by the timer in `McpClient`. */
        private const val CONNECT_TIMEOUT_MILLIS = 20_000L

        fun createClient(): HttpClient = HttpClient(OkHttp) {
            configure(this)
            engine {
                config {
                    followRedirects(false)
                    followSslRedirects(false)
                    // OkHttp silently resends a request when the connection "looks broken", which could send an already
                    // dispatched tools/call a second time. The retry before the connection is established is done once by `McpClient` itself.
                    retryOnConnectionFailure(false)
                }
            }
        }

        /** Client configuration (tests apply the same configuration to a MockEngine). */
        fun configure(config: HttpClientConfig<*>) {
            config.followRedirects = false
            config.expectSuccess = false
            config.install(HttpTimeout) {
                connectTimeoutMillis = CONNECT_TIMEOUT_MILLIS
            }
        }
    }
}
