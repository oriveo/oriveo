package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.GrokSubscriptionFailureReason
import ai.oriveo.community.core.model.OpenAISubscriptionFailureReason
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.StreamEvent
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.request
import io.ktor.client.statement.bodyAsChannel
import io.ktor.utils.io.jvm.javaio.toInputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import java.nio.charset.StandardCharsets

/**
 * Which subscription lane this request is going out on.
 *
 * Deliberately not a boolean: 401/403/426/429 mean the same thing on both subscription lanes but
 * have to be worded differently, and the wording must name the provider, because a user may be
 * connected to a Grok subscription and a ChatGPT subscription at the same time. A boolean can only
 * express "is this a subscription", which leaves nothing to work with once it is time to pick the
 * sentence the user actually reads.
 *
 * [None] is API-key mode: it falls through to the generic classification, where 401/403 become
 * InvalidAPIKey, i.e. "swap in another key".
 */
enum class ProviderSubscriptionLane { None, Grok, OpenAI }

/**
 * Shared SSE (Server-Sent Events) parser.
 *
 * Turns the ByteReadChannel of a Ktor HttpResponse into a Flow<StreamEvent>. It covers every
 * OpenAI-compatible protocol (data: JSON / [DONE]) as well as Anthropic's two-line
 * event: / data: framing.
 *
 * Performance contract: the upstream of every Flow returned by a parse* function is explicitly
 * pinned to `flowOn(Dispatchers.IO)`, because internally it does blocking IO through
 * `toInputStream().bufferedReader().readLine()`. This used to rely on the caller happening to
 * collect on IO (ChatStreamingManager collects with scope = IO), which left the door open for a
 * later refactor to move collection to Main and ANR outright. The guarantee is pinned here rather
 * than borrowed from a call site.
 */
object SseParser {

    private val QUOTA_PATTERN = Regex("quota|daily limit|used up|insufficient quota|credit|billing hard limit|allowance")
    private val UNAVAILABLE_PATTERN = Regex("temporarily unavailable|currently unavailable|not available|model not exist|model_not_found|no such model|disabled|offline|maintenance")

    /**
     * Per-chunk fault-tolerance helper: it swallows JSON parse failures only, i.e. the case where
     * an upstream sends bytes that are not valid JSON. Every other Throwable (an NPE, a type
     * mismatch, an outright bug of ours) is allowed to propagate so the user at least sees an error
     * instead of silence.
     *
     * History: this fallback used to be a `catch (_: Exception)` black hole. DeepSeek emits
     * `"usage":null` in the middle of a chunk, which makes `JsonNull.jsonObject` throw
     * IllegalArgumentException; that exception was swallowed along with the delta, so the user was
     * left staring at an "empty response" with nothing to go on. See the historical note in
     * OpenAICompatibleService.
     */
    private inline fun <T> tolerantParseChunk(block: () -> T): T? = try {
        block()
    } catch (_: kotlinx.serialization.SerializationException) {
        null
    }

    /**
     * Holds back an upstream failure until every event emitted before it has been delivered across
     * the `flowOn` channel, and moves the upstream onto IO.
     *
     * ## Why this is needed
     * `ChannelFlow.collect` is `coroutineScope { collector.emitAll(produceImpl(this)) }`, so the
     * producer is a child coroutine of that scope. When a child fails,
     * `JobSupport.finalizeFinishingState` first calls `cancelParent(cause)`, which cancels the
     * scope and with it the downstream currently sitting in `emitAll`, and only afterwards runs
     * `ProducerCoroutine.onCancelled` to `close(cause)` the channel. The consequence: any element
     * that has already been emitted into the channel but whose `downstream.emit` has not finished
     * yet is thrown away together with the cancellation. The busier the machine, the later the
     * downstream is scheduled, and the more elements are lost.
     *
     * The product requirement is that when an upstream reports an error inside a 200 stream, the
     * text it already produced before the error stays visible, with the partial reply rendered
     * above the error card. Losing events makes that behaviour intermittent: adding `buffer(0)` at
     * the two Gemini call sites narrowed the window but did not close it, and unit tests still went
     * red at random under nine-way parallelism, with a different class failing on each run
     * (GeminiServiceTest, SseParserStreamErrorTest and RelayTransportCoordinatorStreamTest taking
     * turns).
     *
     * ## How it works
     * The exception is wrapped into an ordinary element and pushed through the channel. The
     * upstream coroutine then completes normally, so the downstream is never cancelled, the channel
     * drains in FIFO order, and the failure necessarily lands after every event that preceded it,
     * to be rethrown on the downstream side.
     *
     * ## Why capacity is a parameter instead of one hardcoded value
     * Buffer capacity is backpressure behaviour and has nothing to do with the ordering bug this
     * helper exists to fix. Changing it would change how far ahead of the downstream the parser is
     * allowed to run:
     *   - the two Gemini call sites used `buffer(0)` = RENDEZVOUS, so parsing never runs ahead of
     *     the downstream;
     *   - the other five used a bare `flowOn` = `Channel.BUFFERED`, which defaults to 64.
     *     Why those two spellings are equivalent: `flowOn` builds a
     *     `ChannelFlowOperatorImpl(capacity = OPTIONAL_CHANNEL)` whose `produceCapacity` resolves
     *     `OPTIONAL_CHANNEL` to `Channel.BUFFERED`, while `buffer(BUFFERED).flowOn(IO)` goes
     *     through `ChannelFlow.fuse`, whose `capacity == OPTIONAL_CHANNEL -> this.capacity` branch
     *     yields `BUFFERED` as well.
     * Quietly turning 64 into RENDEZVOUS would make SSE reads wait on the downstream's pace, and a
     * long stream could then run into the upstream's idle timeout. That is a behaviour change, not
     * a bug fix, so each call site passes the capacity it already had and this helper has zero
     * effect on backpressure.
     */
    private fun <T> Flow<T>.failAfterPendingEvents(capacity: Int = Channel.BUFFERED): Flow<T> =
        map { Result.success(it) }
            .catch { cause ->
                // Cancellation (the user pressed stop, or the enclosing scope ended) has to
                // propagate untouched; it must never be wrapped up as just another event.
                if (cause is CancellationException) throw cause
                emit(Result.failure(cause))
            }
            .buffer(capacity)
            .flowOn(Dispatchers.IO)
            .map { it.getOrThrow() }

    /**
     * OpenAI  SSE : `data: {json}` with `[DONE]` terminator.
     *  OpenRouter, OpenAI Chat Completions, Groq, Together, Fireworks.
     */
    fun parseOpenAICompatible(
        response: HttpResponse,
        json: Json,
        onChunk: (String) -> StreamEvent?,
        onDone: () -> StreamEvent,
    ): Flow<StreamEvent> = flow {
        val reader = response.bodyAsChannel()
            .toInputStream()
            .bufferedReader(StandardCharsets.UTF_8)
        val ctx = currentCoroutineContext()

        reader.use { bufferedReader ->
            while (ctx.isActive) {
                val line = bufferedReader.readLine() ?: break

                // The space after `data:` is optional in the SSE spec - DashScope's native stream
                // omits it, OpenAI-compatible ones include it - so tolerate both spellings.
                if (!line.startsWith("data:")) continue
                val payload = line.removePrefix("data:").trim()
                if (payload == "[DONE]") break
                if (payload.isEmpty()) continue

                throwIfStreamErrorPayload(json, payload)
                val event = tolerantParseChunk { onChunk(payload) }
                if (event != null) emit(event)
            }
        }

        emit(onDone())
    }.failAfterPendingEvents() // bare flowOn was Channel.BUFFERED(64); capacity unchanged

    /**
     * OpenAI-compatible SSE framing, multi-event variant.
     *
     * A single chunk can carry a text delta and a citations increment at the same time.
     * [parseOpenAICompatible] can only produce one event per chunk, which cannot express "text and
     * citations arrived together", so this variant lets [onChunk] return a List.
     */
    fun parseOpenAICompatibleMulti(
        response: HttpResponse,
        json: Json,
        topLevelCodeMessageIsProviderError: Boolean = true,
        onChunk: (String) -> List<StreamEvent>,
        onDone: () -> StreamEvent,
    ): Flow<StreamEvent> = flow {
        val reader = response.bodyAsChannel()
            .toInputStream()
            .bufferedReader(StandardCharsets.UTF_8)
        val ctx = currentCoroutineContext()
        var currentEvent = ""

        reader.use { bufferedReader ->
            while (ctx.isActive) {
                val line = bufferedReader.readLine() ?: break

                if (line.startsWith("event:")) {
                    currentEvent = line.removePrefix("event:").trim()
                    continue
                }
                // DashScope's native SSE is `data:{json}` with no space after the colon, while
                // OpenAI-compatible endpoints send `data: {json}`. That space is optional in the
                // SSE spec, so strip `data:` and trim: matching only the spaced form would skip
                // every line of the native framing and surface an empty response.
                if (!line.startsWith("data:")) continue
                val rawPayload = line.removePrefix("data:").trim()
                if (rawPayload == "[DONE]") break
                val payload = injectEventTypeIfNeeded(rawPayload, currentEvent, json)
                currentEvent = ""
                if (payload.isEmpty()) continue

                throwIfStreamErrorPayload(
                    json = json,
                    payload = payload,
                    topLevelCodeMessageIsProviderError = topLevelCodeMessageIsProviderError,
                )
                val events = tolerantParseChunk { onChunk(payload) }
                if (events != null) for (event in events) emit(event)
            }
        }

        emit(onDone())
    }.failAfterPendingEvents() // bare flowOn was Channel.BUFFERED(64); capacity unchanged

    /**
     * OpenAI-compatible SSE payload stream for consumers with their own domain event type.
     * Keeps framing, cancellation, error-payload handling, and IO dispatch in the shared parser.
     */
    fun parseOpenAICompatiblePayloads(
        response: HttpResponse,
        json: Json,
    ): Flow<String> = flow {
        val reader = response.bodyAsChannel()
            .toInputStream()
            .bufferedReader(StandardCharsets.UTF_8)
        val ctx = currentCoroutineContext()

        reader.use { bufferedReader ->
            while (ctx.isActive) {
                val line = bufferedReader.readLine() ?: break
                if (!line.startsWith("data:")) continue
                val payload = line.removePrefix("data:").trim()
                if (payload == "[DONE]") break
                if (payload.isEmpty()) continue
                throwIfStreamErrorPayload(json, payload)
                emit(payload)
            }
        }
    }.failAfterPendingEvents() // bare flowOn was Channel.BUFFERED(64); capacity unchanged

    private fun injectEventTypeIfNeeded(payload: String, eventType: String, json: Json): String {
        if (eventType.isBlank()) return payload
        val root = runCatching { json.parseToJsonElement(payload).jsonObject }.getOrNull()
            ?: return payload
        if (root["type"] != null) return payload
        val merged = root.toMutableMap()
        merged["type"] = JsonPrimitive(eventType)
        return JsonObject(merged).toString()
    }

    /**
     * Anthropic SSE framing: `event: {type}\ndata: {json}`.
     */
    fun parseAnthropicStream(
        response: HttpResponse,
        json: Json,
        onEvent: (eventType: String, data: String) -> StreamEvent?,
        onDone: () -> StreamEvent,
    ): Flow<StreamEvent> = flow {
        val reader = response.bodyAsChannel()
            .toInputStream()
            .bufferedReader(StandardCharsets.UTF_8)
        val ctx = currentCoroutineContext()
        var currentEvent = ""

        reader.use { bufferedReader ->
            while (ctx.isActive) {
                val line = bufferedReader.readLine() ?: break

                when {
                    line.startsWith("event: ") -> {
                        currentEvent = line.removePrefix("event: ").trim()
                    }
                    line.startsWith("data: ") && currentEvent.isNotEmpty() -> {
                        val data = line.removePrefix("data: ").trim()
                        if (data.isEmpty()) continue

                        throwIfAnthropicErrorEvent(json, currentEvent, data)
                        val event = tolerantParseChunk { onEvent(currentEvent, data) }
                        if (event != null) emit(event)
                        currentEvent = ""
                    }
                }
            }
        }

        emit(onDone())
    }.failAfterPendingEvents() // bare flowOn was Channel.BUFFERED(64); capacity unchanged

    /**
     * Anthropic SSE, multi-event variant - see [parseOpenAICompatibleMulti] for the rationale.
     *
     * A single chunk can contain both a text delta and a web_search_tool_result content block, so
     * returning a List lets the caller emit several events for it.
     */
    fun parseAnthropicStreamMulti(
        response: HttpResponse,
        json: Json,
        onEvent: (eventType: String, data: String) -> List<StreamEvent>,
        onDone: () -> StreamEvent,
    ): Flow<StreamEvent> = flow {
        val reader = response.bodyAsChannel()
            .toInputStream()
            .bufferedReader(StandardCharsets.UTF_8)
        val ctx = currentCoroutineContext()
        var currentEvent = ""

        reader.use { bufferedReader ->
            while (ctx.isActive) {
                val line = bufferedReader.readLine() ?: break

                when {
                    line.startsWith("event: ") -> {
                        currentEvent = line.removePrefix("event: ").trim()
                    }
                    line.startsWith("data: ") && currentEvent.isNotEmpty() -> {
                        val data = line.removePrefix("data: ").trim()
                        if (data.isEmpty()) continue

                        throwIfAnthropicErrorEvent(json, currentEvent, data)
                        val events = tolerantParseChunk { onEvent(currentEvent, data) }
                        if (events != null) for (event in events) emit(event)
                        currentEvent = ""
                    }
                }
            }
        }

        emit(onDone())
    }.failAfterPendingEvents() // bare flowOn was Channel.BUFFERED(64); capacity unchanged

    /**
     * Gemini SSE framing: `data: {json}` - no event line and no [DONE] terminator.
     * Every data line is a complete JSON response chunk.
     */
    fun parseGeminiStream(
        response: HttpResponse,
        json: Json,
        onChunk: (String) -> StreamEvent?,
        onDone: () -> StreamEvent,
    ): Flow<StreamEvent> = flow {
        val reader = response.bodyAsChannel()
            .toInputStream()
            .bufferedReader(StandardCharsets.UTF_8)
        val ctx = currentCoroutineContext()

        reader.use { bufferedReader ->
            while (ctx.isActive) {
                val line = bufferedReader.readLine() ?: break

                if (!line.startsWith("data: ")) continue
                val payload = line.removePrefix("data: ").trim()
                if (payload.isEmpty()) continue

                throwIfStreamErrorPayload(json, payload)
                val event = tolerantParseChunk { onChunk(payload) }
                if (event != null) emit(event)
            }
        }

        emit(onDone())
    }.failAfterPendingEvents(capacity = 0) // buffer(0) was RENDEZVOUS; capacity unchanged

    /**
     * Gemini SSE, multi-event variant - see [parseOpenAICompatibleMulti] for the rationale.
     */
    fun parseGeminiStreamMulti(
        response: HttpResponse,
        json: Json,
        onChunk: (String) -> List<StreamEvent>,
        onDone: () -> StreamEvent,
    ): Flow<StreamEvent> = flow {
        val reader = response.bodyAsChannel()
            .toInputStream()
            .bufferedReader(StandardCharsets.UTF_8)
        val ctx = currentCoroutineContext()

        reader.use { bufferedReader ->
            while (ctx.isActive) {
                val line = bufferedReader.readLine() ?: break

                if (!line.startsWith("data: ")) continue
                val payload = line.removePrefix("data: ").trim()
                if (payload.isEmpty()) continue

                throwIfStreamErrorPayload(json, payload)
                val events = tolerantParseChunk { onChunk(payload) }
                if (events != null) for (event in events) emit(event)
            }
        }

        emit(onDone())
    }.failAfterPendingEvents(capacity = 0) // buffer(0) was RENDEZVOUS; capacity unchanged

    /**
     * Extracts the error message from an HTTP error response. 401/403/429/5xx are narrowed further
     * to QuotaExceeded / ModelUnavailable by keyword.
     */
    /**
     * Single interception point for errors inside a stream - the `data: {"error":...}` line that
     * OpenAI-compatible protocols use mid-stream.
     *
     * The protocol says the stream is cut right after such an error. Without a throw the error is
     * silently swallowed and the text accumulated so far is delivered as a Done, i.e. a normal
     * completion, leaving the user with a truncated reply, no error message and no way to retry.
     *
     * Only a top-level `error` field counts: the word "error" inside assistant prose lives in the
     * choices[].delta.content string rather than at the top level, so it cannot trigger a false
     * positive, and `{"error":null}` (noise some services emit alongside include_usage) is let
     * through as well.
     */
    internal fun throwIfStreamErrorPayload(
        json: Json,
        payload: String,
        topLevelCodeMessageIsProviderError: Boolean = true,
    ) {
        if (!payload.contains("\"error\"") && !payload.contains("\"code\"")) return
        val root = runCatching { json.parseToJsonElement(payload) }.getOrNull() as? JsonObject ?: return
        val err = root["error"]
        if (err != null && err !is JsonNull) {
            val errObj = err as? JsonObject
            val message = (errObj?.get("message") as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull
                ?: (err as? JsonPrimitive)?.contentOrNull
            val type = (errObj?.get("type") as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull
                ?: (errObj?.get("code") as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull
            // Shape we do not recognise at all: let it through to the existing tolerant decode path
            if (!message.isNullOrBlank() || !type.isNullOrBlank()) throw mapStreamError(type, message)
        }

        // DashScope-compatible endpoints can also return a top-level {"code","message"} inside an
        // HTTP 200 stream. That shape collides with the `request.error` domain event of another SSE
        // dialect, so the protocol cannot be guessed from the fields; the caller decides explicitly
        // according to the protocol it consumes. The text is used for classification only and never
        // reaches the exception detail.
        if (topLevelCodeMessageIsProviderError && root["choices"] == null) {
            val type = (root["code"] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull
            val message = (root["message"] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull
            if (!type.isNullOrBlank() && !message.isNullOrBlank()) throw mapStreamError(type, message)
        }
    }

    /**
     * Anthropic's `event: error` (overloaded_error, api_error and friends) is a terminal event: the
     * server drops the stream as soon as it has been sent. It has to throw so the caller can show
     * an error card. Even an unparseable payload must not be let through, or a truncated reply ends
     * up disguised as a normal completion.
     */
    internal fun throwIfAnthropicErrorEvent(json: Json, eventType: String, data: String) {
        if (eventType != "error") return
        throwIfStreamErrorPayload(json, data)
        throw ProviderServiceError.Upstream(200, "The Anthropic stream reported an unrecognized error.")
    }

    private fun mapStreamError(type: String?, message: String?): ProviderServiceError {
        val lower = "${type.orEmpty()} ${message.orEmpty()}".lowercase()
        return when {
            QUOTA_PATTERN.containsMatchIn(lower) -> ProviderServiceError.QuotaExceeded(
                "The provider stream reported that quota or credit is unavailable.",
            )
            lower.contains("overloaded") || lower.contains("rate limit") || lower.contains("rate_limit") ->
                ProviderServiceError.RateLimited("The provider stream reported a rate limit.")
            lower.contains("authentication") || lower.contains("permission") || lower.contains("api key") ->
                ProviderServiceError.InvalidAPIKey("The provider stream rejected authentication.")
            UNAVAILABLE_PATTERN.containsMatchIn(lower) -> ProviderServiceError.ModelUnavailable(
                "The provider stream reported that the model is unavailable.",
            )
            // The stream was already a 2xx, so there is no finer-grained HTTP status to fall back on
            else -> ProviderServiceError.Upstream(200, "The provider stream reported an error.")
        }
    }

    @JvmOverloads
    suspend fun mapHttpError(
        response: HttpResponse,
        subscription: Boolean = false,
    ): ProviderServiceError = mapHttpError(
        response,
        if (subscription) ProviderSubscriptionLane.Grok else ProviderSubscriptionLane.None,
    )

    /** See [ProviderSubscriptionLane]: the lane decides which subscription's semantics a status code maps to. */
    suspend fun mapHttpError(
        response: HttpResponse,
        lane: ProviderSubscriptionLane,
    ): ProviderServiceError {
        val body = try {
            response.bodyAsChannel()
                .toInputStream()
                .bufferedReader(StandardCharsets.UTF_8)
                .use { it.readText() }
        } catch (_: Exception) {
            "Unknown error"
        }
        // Credentials this request carried itself (Authorization, x-api-key, custom sensitive
        // headers and query parameters): when an upstream echoes them back they must be scrubbed
        // before anything reaches the error card. The decision uses the same sensitive-name table.
        val credentials = RelayEndpointPolicy.credentialMaterial(
            response.request.headers.entries()
                .flatMap { entry -> entry.value.map { entry.key to it } } +
                response.request.url.parameters.entries()
                    .flatMap { entry -> entry.value.map { entry.key to it } },
        )
        return mapHttpError(response.status.value, body, credentials, lane)
    }

    /**
     * Overload for the case where the body has already been consumed: the OpenAI Responses protocol
     * probe has to inspect the body before it can decide whether to fall back to chat/completions,
     * so by then there is no channel left for the overload above to read.
     *
     * OpenAIService used to carry its own private copy of this mapping. That copy was missing 402
     * and the quota/unavailable keyword subdivision, so the Responses branch could never produce
     * QuotaExceeded. Sharing this function removes the fork.
     */
    @JvmOverloads
    fun mapHttpError(
        statusCode: Int,
        body: String,
        credentials: Collection<String> = emptyList(),
        subscription: Boolean = false,
    ): ProviderServiceError = mapHttpError(
        statusCode,
        body,
        credentials,
        if (subscription) ProviderSubscriptionLane.Grok else ProviderSubscriptionLane.None,
    )

    /**
     * See [ProviderSubscriptionLane].
     *
     * This coexists with the `Boolean` overload above instead of replacing it: the call sites of
     * that signature sit in the Grok outbound path, and outbound request building is being reworked
     * elsewhere, so changing the signature would manufacture a conflict for no gain. The semantics
     * are identical (true = the Grok lane); new call sites all go through this lane-aware entry
     * point.
     */
    fun mapHttpError(
        statusCode: Int,
        body: String,
        credentials: Collection<String>,
        lane: ProviderSubscriptionLane,
    ): ProviderServiceError {
        val detail = extractErrorMessage(body, credentials) ?: "HTTP $statusCode"
        // On a subscription lane 401/403/426/429 are each a different situation and must never fall
        // into the key-mode classification below, where 401 and 403 both become InvalidAPIKey and
        // tell the user to swap in another key - a subscription user has no key to swap.
        when (lane) {
            ProviderSubscriptionLane.None -> Unit
            ProviderSubscriptionLane.Grok -> grokSubscriptionFailure(statusCode, detail)?.let { return it }
            ProviderSubscriptionLane.OpenAI -> openAISubscriptionFailure(statusCode, detail)?.let { return it }
        }
        val lower = body.lowercase()
        val isQuota = QUOTA_PATTERN.containsMatchIn(lower)
        val isUnavailable = UNAVAILABLE_PATTERN.containsMatchIn(lower)
        val rejectedParameter = structuredRejectedParameter(body)

        return when (statusCode) {
            401, 403 -> when {
                isQuota -> ProviderServiceError.QuotaExceeded(detail)
                isUnavailable -> ProviderServiceError.ModelUnavailable(detail)
                else -> ProviderServiceError.InvalidAPIKey(detail)
            }
            // Payment Required: the user's own provider account is out of credit (OpenRouter's
            // "Insufficient credits" and the like). An account-level condition belongs in
            // QuotaExceeded, not in the generic Upstream "please try again" fallback.
            402 -> ProviderServiceError.QuotaExceeded(detail)
            429 -> when {
                isQuota -> ProviderServiceError.QuotaExceeded(detail)
                isUnavailable -> ProviderServiceError.ModelUnavailable(detail)
                else -> ProviderServiceError.RateLimited(detail)
            }
            in 500..599 -> if (isUnavailable) ProviderServiceError.ModelUnavailable(detail)
                else ProviderServiceError.Upstream(statusCode, detail, rejectedParameter)
            else -> ProviderServiceError.Upstream(statusCode, detail, rejectedParameter)
        }
    }

    /**
     * The four hard failures of a subscription lane. Every other status code returns `null` and
     * falls through to the generic classification: these four are the only ones for which we can
     * name a specific and distinct recovery action, and hardcoding subscription semantics onto
     * anything else would be faking a precise diagnosis.
     */
    private fun grokSubscriptionFailure(statusCode: Int, detail: String): ProviderServiceError? =
        when (statusCode) {
            401 -> ProviderServiceError.GrokSubscription(GrokSubscriptionFailureReason.Expired, detail)
            403 -> ProviderServiceError.GrokSubscription(GrokSubscriptionFailureReason.NotEligible, detail)
            426 -> ProviderServiceError.GrokSubscription(
                GrokSubscriptionFailureReason.ClientVersionRejected, detail,
            )
            429 -> ProviderServiceError.GrokSubscription(
                GrokSubscriptionFailureReason.QuotaExhausted, detail,
            )
            else -> null
        }

    /**
     * The four hard failures of the Codex lane. Case for case it mirrors [grokSubscriptionFailure]
     * but says something different in each one: a user may be connected to both subscriptions at
     * once, and wording that does not name the provider never tells them where to log in again.
     */
    private fun openAISubscriptionFailure(statusCode: Int, detail: String): ProviderServiceError? =
        when (statusCode) {
            401 -> ProviderServiceError.OpenAISubscription(
                OpenAISubscriptionFailureReason.Expired, detail,
            )
            403 -> ProviderServiceError.OpenAISubscription(
                OpenAISubscriptionFailureReason.NotEligible, detail,
            )
            426 -> ProviderServiceError.OpenAISubscription(
                OpenAISubscriptionFailureReason.Unavailable, detail,
            )
            429 -> ProviderServiceError.OpenAISubscription(
                OpenAISubscriptionFailureReason.QuotaExhausted, detail,
            )
            else -> null
        }

    /** Exact structured field only. Error prose is intentionally never scanned. */
    private fun structuredRejectedParameter(body: String): String? = runCatching {
        val root = Json.parseToJsonElement(body) as? JsonObject ?: return@runCatching null
        val error = root["error"] as? JsonObject ?: return@runCatching null
        (error["param"] as? JsonPrimitive)?.contentOrNull
            ?.takeIf { it.length in 1..128 && Regex("^[A-Za-z_][A-Za-z0-9_.-]*$").matches(it) }
    }.getOrNull()

    /**
     * Extracts the error message from a JSON error body.
     *
     * Security hardening: extraction goes exclusively through [RelayDebugSnippet.extract], which
     * allowlists `error.{message,code,type}`. A JSON parse failure or a missing field returns null;
     * the raw body is never returned. That is what keeps prompt fragments and SSE chunk tokens
     * echoed back by an upstream relay from leaking through the detail field into an error card, a
     * screenshot, or a log pasted into a support thread.
     */
    private fun extractErrorMessage(body: String, credentials: Collection<String>): String? {
        return ai.oriveo.community.core.provider.relay.RelayDebugSnippet.extract(body, redacting = credentials)
    }
}
