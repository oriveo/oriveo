package ai.oriveo.community.core.search

import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.provider.RelayEndpointPolicy
import java.io.IOException
import java.io.InterruptedIOException
import java.net.InetAddress
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

sealed interface SearchExecution {
    data class Results(val results: List<SearchResultItem>) : SearchExecution
    data object Empty : SearchExecution
    /** sent = false: the pre-key check failed or the device refused to send, so no request went out (does not count as a request). */
    data class Failed(val outcome: SearchErrorOutcome, val sent: Boolean = true) : SearchExecution
}

/**
 * External search request executor (OkHttp). Security boundary:
 * - for preset services, [SearchCatalog.presetHostCheck] runs before any key is sent; no request unless it returns ok;
 * - HTTPS only; http is allowed only on the LAN, judged by [RelayEndpointPolicy], with the connection pinned to the IP resolved at judgment time (prevents DNS rebinding);
 * - only same-origin 3xx redirects are followed (scheme + host + port all equal; https → http counts as cross-origin), at most [MAX_REDIRECTS] hops, each hop re-judged and IP-pinned;
 *   cross-origin / too many hops / invalid Location aborts without sending, so an authenticated request is never carried to another host;
 * - a local refusal and a redirect abort are both recorded as transportFailure = blocked (→ request_rejected);
 * - LAN http with a key is still sent (the form validation already shows the cleartext_lan hint); credentials are not a reason to refuse;
 * - a response body over [SearchHardLimits.MAX_RESPONSE_BYTES] aborts = response_too_large; timeout comes from clampedLimits / the fixed custom value.
 */
class SearchExecutor internal constructor(
    private val baseClient: OkHttpClient,
    private val resolveHostIPs: (String) -> List<String>,
) {
    constructor() : this(sharedClient, RelayEndpointPolicy::resolveHostIPs)

    /** Preset service: entry is the current catalog entry (adopted), withdrawn is the withdrawn state from the adoption result. */
    suspend fun executePreset(
        entry: JsonObject,
        regionId: String,
        boundHost: String,
        withdrawn: Boolean,
        key: String?,
        query: String,
        count: Int?,
        otherServices: Int = 0,
    ): SearchExecution {
        val verdict = SearchCatalog.presetHostCheck(boundHost, entry, regionId, withdrawn)
        if (verdict != "ok") {
            return SearchExecution.Failed(
                SearchTransport.classifySearchError(SearchErrorInput(preflight = verdict, otherServices = otherServices)),
                sent = false,
            )
        }
        val target = SearchCatalog.presetTarget(entry, regionId)
        val spec = entry["transport"] as? JsonObject
        if (target == null || spec == null) {
            return SearchExecution.Failed(
                SearchTransport.classifySearchError(SearchErrorInput(preflight = "service_withdrawn", otherServices = otherServices)),
                sent = false,
            )
        }
        val limits = SearchCatalog.clampedLimits(entry)
        // Do not send an empty query; treat it as no results
        val request = SearchTransport.buildSearchRequest(spec, target, query, count, key) as? SearchHttpRequest
            ?: return SearchExecution.Empty
        return execute(request, spec, count, limits.timeoutSec, custom = false, otherServices = otherServices)
    }

    /** Custom service: mapping is the same_as snapshot or a manual mapping (not used by searxng). */
    suspend fun executeCustom(
        protocol: String,
        address: String,
        mapping: JsonObject?,
        key: String?,
        query: String,
        count: Int?,
        otherServices: Int = 0,
    ): SearchExecution {
        val spec = SearchCustomService.customServiceSpec(protocol, mapping)
        val target = SearchCustomService.customServiceTarget(protocol, address)
        if (spec == null || target == null) {
            return SearchExecution.Failed(
                SearchTransport.classifySearchError(SearchErrorInput(custom = true, otherServices = otherServices)),
                sent = false,
            )
        }
        val request = SearchTransport.buildSearchRequest(spec, target, query, count, key) as? SearchHttpRequest
            ?: return SearchExecution.Empty
        return execute(request, spec, count, SearchCustomService.customTimeoutSec, custom = true, otherServices = otherServices)
    }

    /** Send one already-built request and map the result per spec. */
    suspend fun execute(
        request: SearchHttpRequest,
        spec: JsonObject,
        count: Int?,
        timeoutSec: Int,
        custom: Boolean,
        otherServices: Int,
    ): SearchExecution {
        val rules = spec["errors"] as? JsonArray
        fun fail(input: SearchErrorInput, sent: Boolean = true) = SearchExecution.Failed(
            SearchTransport.classifySearchError(input.copy(rules = rules, custom = custom, otherServices = otherServices)),
            sent = sent,
        )
        val blocked = SearchErrorInput(transportFailure = "blocked")
        val firstUrl = request.url.toHttpUrlOrNull() ?: return fail(blocked, sent = false)
        val timeout = timeoutSec.coerceIn(1, SearchHardLimits.MAX_TIMEOUT_SEC).toLong()
        // The timeout is the total budget of the whole call: counted from the first DNS resolution, covering every same-origin redirect hop
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeout)
        val payload = request.body?.let { Json.encodeToString(JsonObject.serializer(), it).toByteArray(Charsets.UTF_8) }
        var url = firstUrl
        var method = request.method
        var body = payload
        var hops = 0
        while (true) {
            // Every hop goes through the security check again and pins the IP
            val budgetMs = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
            if (budgetMs <= 0) return fail(SearchErrorInput(transportFailure = "timeout"))
            // DNS resolution counts toward the total budget; resolution timeout = timeout, security check failure = blocked
            val verdict = withTimeoutOrNull(budgetMs) { pinnedAddresses(url) }
                ?: return fail(SearchErrorInput(transportFailure = "timeout"))
            // Refused locally on the first hop = no request went out; when a later hop is refused, the previous hop has already been sent
            val pinned = verdict.getOrNull() ?: return fail(blocked, sent = hops > 0)
            val remainingMs = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
            if (remainingMs <= 0) return fail(SearchErrorInput(transportFailure = "timeout"))
            val client = baseClient.newBuilder()
                .followRedirects(false)
                .followSslRedirects(false)
                .callTimeout(remainingMs, TimeUnit.MILLISECONDS)
                .connectTimeout(timeout, TimeUnit.SECONDS)
                .readTimeout(timeout, TimeUnit.SECONDS)
                .writeTimeout(timeout, TimeUnit.SECONDS)
                .apply {
                    if (pinned.isNotEmpty()) {
                        dns(
                            object : Dns {
                                override fun lookup(hostname: String): List<InetAddress> = pinned
                            },
                        )
                    }
                }
                .build()
            val builder = Request.Builder().url(url)
            request.headers.forEach { (name, value) -> builder.header(name, value) }
            if (body == null) builder.removeHeader("Content-Type")
            builder.method(method, body?.toRequestBody(JSON_MEDIA))

            val raw = when (val r = call(client.newCall(builder.build()))) {
                is RawOutcome.Failure -> return fail(SearchErrorInput(transportFailure = r.kind))
                is RawOutcome.Done -> r
            }
            if (raw.status in 300..399) {
                // Follow only same-origin redirects (scheme + host + port all equal; https → http counts as cross-origin), at most MAX_REDIRECTS hops,
                // the next hop goes through the security check again; cross-origin / too many hops / invalid Location always aborts without sending and is recorded as blocked
                val next = raw.location?.let(url::resolve)
                val sameOrigin = next != null && next.scheme == url.scheme && next.host == url.host && next.port == url.port
                if (!sameOrigin || hops >= MAX_REDIRECTS) return fail(blocked)
                hops += 1
                url = next!!
                // Method rewriting follows browsers: 303, and POST on 301 / 302 → GET with the body dropped; 307 / 308 unchanged
                if (raw.status == 303 || (method == "POST" && raw.status in setOf(301, 302))) {
                    if (method != "HEAD") method = "GET"
                    body = null
                }
                continue
            }
            val parsed: JsonElement? = raw.body?.let { runCatching { Json.parseToJsonElement(it) }.getOrNull() }
            if (raw.status !in 200..299) return fail(SearchErrorInput(status = raw.status, body = parsed))
            if (parsed == null) return fail(SearchErrorInput(parse = "mismatch"))
            return when (val result = SearchTransport.parseSearchResponse(spec, parsed, count)) {
                is SearchParseResult.Results -> SearchExecution.Results(result.results)
                SearchParseResult.Empty -> SearchExecution.Empty
                is SearchParseResult.Error -> fail(SearchErrorInput(parse = "mismatch"))
            }
        }
    }

    /**
     * Security check: https as usual (the resolved IP is pinned; if it cannot be resolved, leave it to system DNS, failure is network);
     * http only for addresses [RelayEndpointPolicy] judges as LAN / local, pinning the IP from judgment time. Returns null = refuse to send.
     */
    private suspend fun pinnedAddresses(url: HttpUrl): Result<List<InetAddress>> =
        pinnedOrNull(url)?.let { Result.success(it) } ?: Result.failure(SecurityException("blocked by local policy"))

    private suspend fun pinnedOrNull(url: HttpUrl): List<InetAddress>? {
        val host = if (url.host.contains(':')) "[${url.host}]" else url.host
        val origin = "${url.scheme}://$host:${url.port}"
        val mode = when (url.scheme) {
            "https" -> RelayConnectionSecurityMode.RemoteHttps
            "http" -> RelayConnectionSecurityMode.LocalHttp
            else -> return null
        }
        val ips = runInterruptible(Dispatchers.IO) { resolveHostIPs(origin) }
        val verdict = RelayEndpointPolicy.classify(origin, mode, ips)
        if (!verdict.allowed) return null
        return withContext(Dispatchers.IO) { verdict.pinnedIPs.map { InetAddress.getByName(it) } }
    }

    private sealed interface RawOutcome {
        data class Done(val status: Int, val body: String?, val location: String?) : RawOutcome
        data class Failure(val kind: String) : RawOutcome
    }

    private suspend fun call(call: Call): RawOutcome = suspendCancellableCoroutine { cont ->
        cont.invokeOnCancellation { call.cancel() }
        call.enqueue(
            object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    cont.resume(RawOutcome.Failure(if (e is InterruptedIOException) "timeout" else "network"))
                }

                override fun onResponse(call: Call, response: Response) {
                    val outcome = try {
                        response.use { readLimited(it) }
                    } catch (e: InterruptedIOException) {
                        RawOutcome.Failure("timeout")
                    } catch (e: IOException) {
                        RawOutcome.Failure("network")
                    }
                    cont.resume(outcome)
                }
            },
        )
    }

    private fun readLimited(response: Response): RawOutcome {
        if (response.code in 300..399) return RawOutcome.Done(response.code, null, response.header("Location"))
        val limit = SearchHardLimits.MAX_RESPONSE_BYTES.toLong()
        val body = response.body
        if (body.contentLength() > limit) return RawOutcome.Failure("too_large")
        val source = body.source()
        // Ask for 1 extra byte: if we get it, the limit is exceeded
        if (source.request(limit + 1)) return RawOutcome.Failure("too_large")
        val bytes = source.buffer.readByteArray()
        return RawOutcome.Done(response.code, if (bytes.isEmpty()) null else String(bytes, Charsets.UTF_8), null)
    }

    companion object {
        /** Maximum number of same-origin https redirect hops to follow (same across all platforms). */
        const val MAX_REDIRECTS = 5
        private val JSON_MEDIA = "application/json".toMediaType()
        private val sharedClient: OkHttpClient by lazy { OkHttpClient() }
    }
}
