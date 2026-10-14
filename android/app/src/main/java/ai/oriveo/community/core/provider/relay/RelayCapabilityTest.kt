package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.capability.truth.ProviderForm
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.isRelayGenerationSuccessResponse
import ai.oriveo.community.core.tools.ToolLoopToolDefinition
import ai.oriveo.community.core.tools.ToolLoopToolFunction
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * The capability test items, in send order; [wire] matches the keys of the fixture `requests` / `mustContain`.
 * [Web] is the 4th item: listed once the first protocol is known, and the repository runs a manual web probe after the first three,
 * probing temporarily with that protocol's built-in template when no snippet is stored.
 */
enum class RelayCapabilityTestKind(val wire: String) {
    Text("text"),
    Image("image"),
    Tool("tool"),
    Web("web"),
}

/** The verdict for one response; [wire] matches the fixture `classifyCases[].expect`. */
enum class RelayCapabilityVerdict(val wire: String) {
    Accepted("accepted"),
    Rejected("rejected"),
    Undetermined("undetermined"),

    /** Image / tool returned 2xx but the response has no evidence: same as undetermined, nothing written, the old value stays. [classify] never produces it. */
    NotObserved("notObserved"),

    /** Web item only (probe results are passed to the panel as-is): searched = searched, silent = 2xx but did not search. [classify] never produces them. */
    Searched("searched"),
    Silent("silent"),
}

/** The reason attached to a verdict; [wire] matches the fixture `classifyCases[].reason`, and the panel shows one sentence for it. */
enum class RelayCapabilityTestReason(val wire: String) {
    Ok("ok"),
    UpstreamRejected("upstream_rejected"),
    NotFound("not_found"),
    Unauthorized("unauthorized"),
    Forbidden("forbidden"),
    RateLimited("rate_limited"),
    Html("html"),
    Server("server"),
    Http("http"),
    Network("network"),
    Timeout("timeout"),
    NotObserved("not_observed"),
}

data class RelayCapabilityClassification(val verdict: RelayCapabilityVerdict, val reason: RelayCapabilityTestReason)

/** Stop reason; [wire] matches the fixture `panelCases[].stopReason`. */
enum class RelayCapabilityTestStopReason(val wire: String) {
    Cancelled("cancelled"),
    Connection("connection"),
    Protocol("protocol"),
    Unavailable("unavailable"),
}

/** The outcome of one test request: a fully read HTTP response (no status code throws), no response, or the overall deadline reached. */
sealed interface RelayCapabilityTestResponse {
    data class Http(
        val status: Int,
        val contentType: String?,
        val body: String,
        val evidence: RelayCapabilityTestEvidence = RelayCapabilityTestEvidence.None,
    ) : RelayCapabilityTestResponse
    data object NetworkFailure : RelayCapabilityTestResponse
    data object Timeout : RelayCapabilityTestResponse
}

/**
 * Evidence obtained by parsing a 2xx response through this protocol's production stream: [visibleText] = the concatenated visible text,
 * [functionCallNames] = the parsed function call names (in order). [None] for non-2xx or when not parsed.
 */
data class RelayCapabilityTestEvidence(val visibleText: String, val functionCallNames: List<String>) {
    companion object {
        val None = RelayCapabilityTestEvidence(visibleText = "", functionCallNames = emptyList())
    }
}

/** The reading of one item: [status] exists only when an HTTP response was obtained; [elapsedMs] runs from start to fully read (or to the deadline). */
data class RelayCapabilityTestItemResult(
    val kind: RelayCapabilityTestKind,
    val verdict: RelayCapabilityVerdict,
    val reason: RelayCapabilityTestReason,
    val status: Int?,
    val elapsedMs: Long,
)

/** In-progress snapshot: items to test, completed items, and the item being sent. */
data class RelayCapabilityTestProgress(
    val planned: List<RelayCapabilityTestKind>,
    val results: List<RelayCapabilityTestItemResult>,
    val running: RelayCapabilityTestKind?,
)

/**
 * The result of one test. [textFailed] = the text baseline was not accepted, nothing else was sent and nothing is written;
 * [image] / [toolCall] null = that item was not tested (a user override exists or it was interrupted). [sent] holds the requests actually sent, in order.
 * [stopReason] non-null = interrupted: readings of completed items stay in [items] and nothing is written. [written] = the result has been written back to the connection.
 */
data class RelayCapabilityTestRun(
    val textFailed: Boolean,
    val sent: List<RelayCapabilityTestKind>,
    val image: RelayCapabilityVerdict?,
    val toolCall: RelayCapabilityVerdict?,
    val planned: List<RelayCapabilityTestKind> = emptyList(),
    val items: List<RelayCapabilityTestItemResult> = emptyList(),
    val stopReason: RelayCapabilityTestStopReason? = null,
    val written: Boolean = false,
    /** The fragment source carried when the web item is listed; null when it is not listed. */
    val webSource: RelayWebSource? = null,
) {
    /** Whether there are readings to write (image / tool accepted or rejected). */
    val hasWritableResult: Boolean
        get() = !textFailed && stopReason == null &&
            listOf(image, toolCall).any { it == RelayCapabilityVerdict.Accepted || it == RelayCapabilityVerdict.Rejected }
}

/**
 * User-initiated "Test capabilities": runs only when the user taps the button, using the protocol currently in effect for the model
 * to send at most 3 small streaming requests: text -> image -> tool, each built by the same production builders as chat (URL / headers / body),
 * with a per-item overall deadline of [PER_ITEM_DEADLINE_SECONDS] seconds; sent once, with no fallback, no self-healing, no retry and no negative cache writes.
 * Verdicts and request shapes follow the shared fixture `capability-test.v1.json`; the send primitive is injected by the caller.
 */
object RelayCapabilityTest {
    const val MAX_OUTPUT_TOKENS = 16
    /** Per-item overall deadline (from start to reading the last byte). */
    const val PER_ITEM_DEADLINE_SECONDS = 30
    const val PER_ITEM_DEADLINE_MILLIS = PER_ITEM_DEADLINE_SECONDS * 1_000L
    private const val TEXT_PROMPT = "Hi"
    private const val IMAGE_PROMPT = "What color is this image? Answer in one word."
    private const val IMAGE_MIME_TYPE = "image/png"
    private const val IMAGE_PNG_BASE64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR42mP4z8CAFTEMLQkAKP8/wc53yE8AAAAASUVORK5CYII="
    private const val TOOL_PROMPT = "What time is it? Use the tool."
    private const val TOOL_NAME = "get_current_time"
    private const val TOOL_DESCRIPTION = "Returns the current time. Has no side effects."
    /** The built-in image is pure red; the image item's visible text must contain that word as a whole word (fixture builtins.imageExpectedAnswer, case-insensitive). */
    private const val IMAGE_EXPECTED_ANSWER = "red"
    private val IMAGE_ANSWER_PATTERN =
        Regex("(?<![\\p{L}\\p{N}_])${Regex.escape(IMAGE_EXPECTED_ANSWER)}(?![\\p{L}\\p{N}_])", RegexOption.IGNORE_CASE)

    private const val IMAGE_KEY = "image"
    private const val TOOL_KEY = "toolCall"

    /** HTTP statuses in the rejection signals (404 additionally yields not_found); all other failures (401 / 403 / 429 / 5xx ...) count as "could not be determined". */
    private val REJECTION_STATUSES = setOf(400, 415, 422)

    /** The "body" in the 200 error-body criterion: the top-level content keys of successful responses in the four protocols; any non-null means there is a body. */
    private val CONTENT_KEYS = listOf("choices", "candidates", "output", "content")

    /** The "output" keys in SSE events (fixture $comment): any non-null, or a type starting with response.output. */
    private val SSE_OUTPUT_KEYS = listOf("choices", "candidates", "delta", "output", "content", "content_block")
    private val SSE_ERROR_TYPES = setOf("error", "response.failed")

    private val lenientJson = Json { ignoreUnknownKeys = true }

    /** The single function tool carried by the tool item (fixture builtins.tool), placed into `tools` in the protocol shape of this client's chat tool leg. */
    val tool: ToolLoopToolDefinition = ToolLoopToolDefinition(
        function = ToolLoopToolFunction(
            name = TOOL_NAME,
            description = TOOL_DESCRIPTION,
            parameters = buildJsonObject {
                put("type", "object")
                putJsonObject("properties") {
                    putJsonObject("timezone") {
                        put("type", "string")
                        put("description", "IANA time zone name, for example UTC.")
                    }
                }
            },
        ),
    )

    /** The synthetic user message of the item (fixture builtins): handed to the chat builder, through the same message pipeline as a normal send. */
    fun message(kind: RelayCapabilityTestKind, modelID: String): ChatMessage = ChatMessage(
        id = "capability-test-${kind.wire}",
        role = ChatRole.User,
        text = when (kind) {
            RelayCapabilityTestKind.Text -> TEXT_PROMPT
            RelayCapabilityTestKind.Image -> IMAGE_PROMPT
            RelayCapabilityTestKind.Tool -> TOOL_PROMPT
            RelayCapabilityTestKind.Web -> RelayWebProbe.PROMPT
        },
        providerKind = ProviderKind.Relay,
        providerName = "",
        modelID = modelID,
        modelName = modelID,
        state = ChatMessageState.Delivered,
        attachments = if (kind == RelayCapabilityTestKind.Image) {
            listOf(
                Attachment(
                    id = "capability-test-image",
                    kind = AttachmentKind.Image,
                    fileName = "capability-test.png",
                    mimeType = IMAGE_MIME_TYPE,
                    base64Data = IMAGE_PNG_BASE64,
                ),
            )
        } else {
            null
        },
    )

    /** Optional inputs handed to the builder for the item: output limit 16; one function tool for the tool item; the image item keeps the image. */
    internal fun buildExtras(kind: RelayCapabilityTestKind): RelayChatBuildExtras = RelayChatBuildExtras(
        maxOutputTokens = MAX_OUTPUT_TOKENS,
        functionTool = tool.takeIf { kind == RelayCapabilityTestKind.Tool },
        keepImageAttachments = kind == RelayCapabilityTestKind.Image,
    )

    /**
     * Items to test: text is always first; image / tool items that already have a user override are skipped;
     * [web] = the web item is listed ([listsWeb]), and web goes last.
     */
    fun plannedKinds(existing: RelayCapabilityOverrides?, web: Boolean = false): List<RelayCapabilityTestKind> = buildList {
        add(RelayCapabilityTestKind.Text)
        if (!existing.isUserSet(IMAGE_KEY)) add(RelayCapabilityTestKind.Image)
        if (!existing.isUserSet(TOOL_KEY)) add(RelayCapabilityTestKind.Tool)
        if (web) add(RelayCapabilityTestKind.Web)
    }

    /**
     * Whether the 4th web item is listed: relay form, testable (the first protocol is known and is one of the four generation protocols);
     * a stored snippet is no longer required. The panel's first frame and the orchestration use the same criterion, so the web item is disclosed truthfully before any request is sent.
     */
    fun listsWeb(provider: Provider, model: AIModel): Boolean =
        RelayWebProbe.isProbeForm(provider) && isTestable(provider, model)

    /** The fragment source of the web item: the first-send protocol has a stored fragment = saved, otherwise = the built-in template; null when not listed. */
    fun webSource(provider: Provider, model: AIModel, fragments: RelayWebFragmentStore = RelayWebFragmentStore.shared): RelayWebSource? {
        if (!listsWeb(provider, model)) return null
        val transport = RelayFirstSendTransport.resolve(provider, model)
        return if (fragments.effective(provider)[transport.value] != null) RelayWebSource.Saved else RelayWebSource.Template
    }

    /** The fragment carried by this web probe: a stored fragment first, otherwise that protocol's built-in template; [source] follows. Null when not listed. */
    fun webProbeFragment(
        provider: Provider,
        model: AIModel,
        fragments: RelayWebFragmentStore = RelayWebFragmentStore.shared,
    ): Pair<RelayWebSource, JsonObject>? {
        if (!listsWeb(provider, model)) return null
        val transport = RelayFirstSendTransport.resolve(provider, model)
        fragments.effective(provider)[transport.value]?.let { return RelayWebSource.Saved to it }
        return RelayWebFragments.template(transport)?.let { RelayWebSource.Template to it }
    }

    /** Protocol short name (chat / responses / messages / gemini); other protocols do not support testing and return null. */
    fun shortName(transport: RelayTransport): String? = when (transport) {
        RelayTransport.OpenAIChatCompletions -> "chat"
        RelayTransport.OpenAIResponses -> "responses"
        RelayTransport.AnthropicMessages -> "messages"
        RelayTransport.GeminiGenerateContent -> "gemini"
        RelayTransport.LlamaCppNative, RelayTransport.Auto -> null
    }

    /** Scope is the same as the per-model probe: Relay form, no engineProfile, and the model's first protocol (read the same way as chat) is one of the four generation protocols. */
    fun isTestable(provider: Provider, model: AIModel): Boolean =
        ProviderForm.of(provider) == ProviderForm.Relay &&
            provider.relayRequested?.engineProfile.isNullOrBlank() &&
            shortName(RelayFirstSendTransport.resolve(provider, model)) != null

    /**
     * Entry condition for "Test capabilities": testable, and there are still items to test, meaning image and tool do not both already have user overrides,
     * or the 4th web item can be listed ([listsWeb], it is enough that the first protocol is known).
     */
    fun offersTest(provider: Provider, model: AIModel): Boolean {
        if (!isTestable(provider, model)) return false
        val overrides = model.relayCapabilityOverrides
        return !(overrides.isUserSet(IMAGE_KEY) && overrides.isUserSet(TOOL_KEY)) || listsWeb(provider, model)
    }

    /**
     * Entry condition for "Restore automatic": Relay form, no engineProfile, and tested items exist.
     * The effective protocol need not be one of the four: tested values must be clearable after the protocol changed.
     */
    fun offersRestore(provider: Provider, model: AIModel): Boolean =
        ProviderForm.of(provider) == ProviderForm.Relay &&
            provider.relayRequested?.engineProfile.isNullOrBlank() &&
            hasTestedResults(model)

    /** Whether the model has override entries whose source is tested (the condition for the "Restore automatic" entry). */
    fun hasTestedResults(model: AIModel): Boolean {
        val overrides = model.relayCapabilityOverrides ?: return false
        return overrides.testedKeys.any { overrides.hasValue(it) }
    }

    fun classify(status: Int, contentType: String?, body: String): RelayCapabilityClassification {
        fun result(verdict: RelayCapabilityVerdict, reason: RelayCapabilityTestReason) = RelayCapabilityClassification(verdict, reason)
        if (status !in 200..299) {
            return when {
                status in REJECTION_STATUSES -> result(RelayCapabilityVerdict.Rejected, RelayCapabilityTestReason.UpstreamRejected)
                status == 404 -> result(RelayCapabilityVerdict.Rejected, RelayCapabilityTestReason.NotFound)
                status == 401 -> result(RelayCapabilityVerdict.Undetermined, RelayCapabilityTestReason.Unauthorized)
                status == 403 -> result(RelayCapabilityVerdict.Undetermined, RelayCapabilityTestReason.Forbidden)
                status == 429 -> result(RelayCapabilityVerdict.Undetermined, RelayCapabilityTestReason.RateLimited)
                status in 500..599 -> result(RelayCapabilityVerdict.Undetermined, RelayCapabilityTestReason.Server)
                else -> result(RelayCapabilityVerdict.Undetermined, RelayCapabilityTestReason.Http)
            }
        }
        // A console fallback page is not an API response and cannot be judged.
        if (!isRelayGenerationSuccessResponse(body, contentType)) {
            return result(RelayCapabilityVerdict.Undetermined, RelayCapabilityTestReason.Html)
        }
        val rejected = if (contentType.orEmpty().lowercase().contains("text/event-stream")) {
            sseRejected(body)
        } else {
            jsonErrorBodyRejected(body)
        }
        return if (rejected) {
            result(RelayCapabilityVerdict.Rejected, RelayCapabilityTestReason.UpstreamRejected)
        } else {
            result(RelayCapabilityVerdict.Accepted, RelayCapabilityTestReason.Ok)
        }
    }

    private fun JsonObject.present(key: String): Boolean = this[key].let { it != null && it !is JsonNull }

    private fun jsonErrorBodyRejected(body: String): Boolean {
        val payload = runCatching { lenientJson.parseToJsonElement(body) as? JsonObject }.getOrNull() ?: return false
        return payload.present("error") && CONTENT_KEYS.none { payload.present(it) }
    }

    /** SSE (fixture $comment): an error event with no output event -> rejected; non-JSON data lines and comment lines are not events. */
    private fun sseRejected(body: String): Boolean = sseScan(body).let { (sawError, sawOutput) -> sawError && !sawOutput }

    /** Whether SSE contains an error event (same criterion as [classify]); the web probe uses it to judge an "error frame after output" as undetermined. */
    internal fun sseHasErrorEvent(body: String): Boolean = sseScan(body).first

    private fun sseScan(body: String): Pair<Boolean, Boolean> {
        var sawError = false
        var sawOutput = false
        body.lineSequence()
            .map { it.trimEnd('\r') }
            .filter { it.startsWith("data:") }
            .mapNotNull { line ->
                runCatching { lenientJson.parseToJsonElement(line.removePrefix("data:").trim()) as? JsonObject }.getOrNull()
            }
            .forEach { event ->
                val type = (event["type"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                if (event.present("error") || type in SSE_ERROR_TYPES) sawError = true
                if (SSE_OUTPUT_KEYS.any { event.present(it) } || type?.startsWith("response.output") == true) sawOutput = true
            }
        return sawError to sawOutput
    }

    /** Whether the item has evidence in the response: text needs none; image = the visible text contains the expected answer as a whole word; tool = a parsed function call with the built-in tool name. */
    internal fun observed(kind: RelayCapabilityTestKind, evidence: RelayCapabilityTestEvidence): Boolean = when (kind) {
        RelayCapabilityTestKind.Text -> true
        RelayCapabilityTestKind.Image -> IMAGE_ANSWER_PATTERN.containsMatchIn(evidence.visibleText)
        RelayCapabilityTestKind.Tool -> TOOL_NAME in evidence.functionCallNames
        // The web item is not judged by this function (it uses RelayWebProbe evidence).
        RelayCapabilityTestKind.Web -> true
    }

    /**
     * Run one test (no write-back): text is the baseline and anything but accepted stops; items with a user override are not sent.
     * Before each item, ask [beforeSend] (connection identity / effective protocol / model testable); non-null interrupts and completed items are kept.
     * [send] reads the whole response; exceeding [deadlineMillis] counts as timeout, and a thrown error (except cancellation) counts as a network error.
     * [web] = list the web item: it only enters the plan (progress and panel), this function does not send it, and the caller runs the web probe after the first three.
     */
    suspend fun run(
        existing: RelayCapabilityOverrides?,
        web: Boolean = false,
        deadlineMillis: Long = PER_ITEM_DEADLINE_MILLIS,
        clockMillis: () -> Long = { System.nanoTime() / 1_000_000L },
        beforeSend: suspend (RelayCapabilityTestKind) -> RelayCapabilityTestStopReason? = { null },
        onProgress: (RelayCapabilityTestProgress) -> Unit = {},
        send: suspend (kind: RelayCapabilityTestKind) -> RelayCapabilityTestResponse,
    ): RelayCapabilityTestRun {
        val planned = plannedKinds(existing, web)
        val sent = mutableListOf<RelayCapabilityTestKind>()
        val items = mutableListOf<RelayCapabilityTestItemResult>()
        fun verdictOf(kind: RelayCapabilityTestKind) = items.firstOrNull { it.kind == kind }?.verdict
        fun snapshot(stopReason: RelayCapabilityTestStopReason? = null, textFailed: Boolean = false) = RelayCapabilityTestRun(
            textFailed = textFailed,
            sent = sent.toList(),
            image = verdictOf(RelayCapabilityTestKind.Image),
            toolCall = verdictOf(RelayCapabilityTestKind.Tool),
            planned = planned,
            items = items.toList(),
            stopReason = stopReason,
        )
        for (kind in planned) {
            if (kind == RelayCapabilityTestKind.Web) continue
            beforeSend(kind)?.let { return snapshot(stopReason = it) }
            onProgress(RelayCapabilityTestProgress(planned, items.toList(), kind))
            sent += kind
            val started = clockMillis()
            val response = try {
                withTimeoutOrNull(deadlineMillis) { send(kind) } ?: RelayCapabilityTestResponse.Timeout
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                RelayCapabilityTestResponse.NetworkFailure
            }
            val elapsed = (clockMillis() - started).coerceAtLeast(0L)
            val item = when (response) {
                is RelayCapabilityTestResponse.Http -> classify(response.status, response.contentType, response.body).let {
                    // Evidence step: an accepted image / tool item must also find evidence in the response, otherwise notObserved.
                    if (it.verdict == RelayCapabilityVerdict.Accepted && !observed(kind, response.evidence)) {
                        RelayCapabilityTestItemResult(
                            kind, RelayCapabilityVerdict.NotObserved, RelayCapabilityTestReason.NotObserved, response.status, elapsed,
                        )
                    } else {
                        RelayCapabilityTestItemResult(kind, it.verdict, it.reason, response.status, elapsed)
                    }
                }
                RelayCapabilityTestResponse.NetworkFailure ->
                    RelayCapabilityTestItemResult(kind, RelayCapabilityVerdict.Undetermined, RelayCapabilityTestReason.Network, null, elapsed)
                RelayCapabilityTestResponse.Timeout ->
                    RelayCapabilityTestItemResult(kind, RelayCapabilityVerdict.Undetermined, RelayCapabilityTestReason.Timeout, null, elapsed)
            }
            items += item
            onProgress(RelayCapabilityTestProgress(planned, items.toList(), null))
            if (kind == RelayCapabilityTestKind.Text && item.verdict != RelayCapabilityVerdict.Accepted) {
                return snapshot(textFailed = true)
            }
        }
        return snapshot()
    }

    /**
     * Merge the result into the override table: accepted writes true, rejected writes false (source tested); undetermined / notObserved write nothing and keep the old value;
     * user entries are unchanged; the other three keys are untouched. Returns null when nothing is left.
     */
    fun applyingResult(overrides: RelayCapabilityOverrides?, run: RelayCapabilityTestRun): RelayCapabilityOverrides? {
        if (run.textFailed) return overrides
        var next = overrides ?: RelayCapabilityOverrides()
        fun write(key: String, verdict: RelayCapabilityVerdict?) {
            val value = when (verdict) {
                RelayCapabilityVerdict.Accepted -> true
                RelayCapabilityVerdict.Rejected -> false
                RelayCapabilityVerdict.Undetermined, RelayCapabilityVerdict.NotObserved,
                RelayCapabilityVerdict.Searched, RelayCapabilityVerdict.Silent, null,
                -> return
            }
            if (next.isUserSet(key)) return
            next = when (key) {
                IMAGE_KEY -> next.copy(image = value)
                else -> next.copy(toolCall = value)
            }.let { it.copy(testedKeys = it.testedKeys + key) }
        }
        write(IMAGE_KEY, run.image)
        write(TOOL_KEY, run.toolCall)
        return next.takeUnless { it.isEmpty }
    }

    /**
     * Write back to the connection: models with the same id in both the enabled list and the catalog are updated. When a full round really ran (text baseline passed), clear the model's current-protocol
     * image and toolCall negative caches; file is untouched.
     */
    fun applyingResult(
        provider: Provider,
        modelID: String,
        run: RelayCapabilityTestRun,
        negativeCache: RelayNegativeCache = RelayNegativeCache.shared,
    ): Provider {
        if (!run.textFailed) {
            (provider.models + provider.catalogModels).firstOrNull { it.id == modelID }
                ?.let { RelayNegativeCache.keyFor(provider, it) }
                ?.let { negativeCache.clear(it, listOf(RelayNegativeCache.Kind.Image, RelayNegativeCache.Kind.ToolCall)) }
        }
        return provider.mapModel(modelID) { it.copy(relayCapabilityOverrides = applyingResult(it.relayCapabilityOverrides, run)) }
    }

    /** Restore automatic: clears only tested entries and keeps user entries; returns null when nothing is left (field omitted). */
    fun restoringAutomatic(overrides: RelayCapabilityOverrides?): RelayCapabilityOverrides? {
        val current = overrides ?: return null
        fun <T> keep(key: String, value: T?): T? = value.takeUnless { key in current.testedKeys }
        return RelayCapabilityOverrides(
            image = keep("image", current.image),
            file = keep("file", current.file),
            imageGeneration = keep("imageGeneration", current.imageGeneration),
            toolCall = keep("toolCall", current.toolCall),
            reasoningLevels = keep("reasoningLevels", current.reasoningLevels),
            web = keep("web", current.web),
        ).takeUnless { it.isEmpty }
    }

    fun restoringAutomatic(provider: Provider, modelID: String): Provider =
        provider.mapModel(modelID) { it.copy(relayCapabilityOverrides = restoringAutomatic(it.relayCapabilityOverrides)) }

    private fun Provider.mapModel(modelID: String, transform: (AIModel) -> AIModel): Provider {
        fun List<AIModel>.mapped() = map { if (it.id == modelID) transform(it) else it }
        return copy(models = models.mapped(), catalogModels = catalogModels.mapped())
    }

    private fun RelayCapabilityOverrides.hasValue(key: String): Boolean = when (key) {
        "image" -> image != null
        "file" -> file != null
        "imageGeneration" -> imageGeneration != null
        "toolCall" -> toolCall != null
        "reasoningLevels" -> reasoningLevels != null
        "web" -> web != null
        else -> false
    }

    private fun RelayCapabilityOverrides?.isUserSet(key: String): Boolean =
        this != null && hasValue(key) && key !in testedKeys
}
