package ai.oriveo.community.core.studio

import java.util.regex.Pattern
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Closed error kinds, named as in image_error_samples.v1. */
enum class StudioImageErrorKind(val wire: String) {
    REFUSED("refused"),
    AUTH("auth"),
    INSUFFICIENT_BALANCE("insufficient_balance"),
    RATE_LIMITED("rate_limited"),
    INVALID_PARAM("invalid_param"),
    MODEL_UNAVAILABLE("model_unavailable"),
    UPSTREAM_ERROR("upstream_error"),
    TIMEOUT("timeout"),
    NETWORK("network"),
    PARTIAL("partial"),
    DECODE_FAILED("decode_failed"),
    STORAGE_FULL("storage_full"),
}

/**
 * Error normalization for Studio image generation: [policy] gives the quota / retry / UI rules of a
 * kind and [classify] turns an HTTP status plus parsed body into one closed kind (null = ok).
 * Behavior follows image_error_samples.v1.
 */
object StudioImageError {
    enum class ConsumesFreeQuota(val wire: String) {
        NONE("none"),
        BY_DELIVERED_COUNT("by_delivered_count"),
        ALREADY_SETTLED("already_settled"),
    }

    enum class AutoRetry(val wire: String) { NONE("none"), ONCE_BEFORE_BODY_SENT("once_before_body_sent") }

    /** [ui] is the fixture's UI action key; [report] marks kinds worth reporting upstream. */
    data class Policy(val consumesFreeQuota: ConsumesFreeQuota, val autoRetry: AutoRetry, val ui: String, val report: Boolean)

    fun policy(kind: StudioImageErrorKind): Policy = when (kind) {
        StudioImageErrorKind.REFUSED -> plain("rewrite_prompt_or_switch_model")
        StudioImageErrorKind.AUTH -> plain("check_key")
        StudioImageErrorKind.INSUFFICIENT_BALANCE -> plain("top_up_or_switch_model")
        StudioImageErrorKind.RATE_LIMITED -> plain("retry_later")
        StudioImageErrorKind.INVALID_PARAM -> plain("show_raw_and_switch_model", report = true)
        StudioImageErrorKind.MODEL_UNAVAILABLE -> plain("switch_model")
        StudioImageErrorKind.UPSTREAM_ERROR -> plain("retry")
        StudioImageErrorKind.TIMEOUT -> plain("retry")
        StudioImageErrorKind.NETWORK -> Policy(ConsumesFreeQuota.NONE, AutoRetry.ONCE_BEFORE_BODY_SENT, "retry", false)
        StudioImageErrorKind.PARTIAL -> Policy(ConsumesFreeQuota.BY_DELIVERED_COUNT, AutoRetry.NONE, "fill_missing", false)
        StudioImageErrorKind.DECODE_FAILED -> plain("retry", report = true)
        StudioImageErrorKind.STORAGE_FULL ->
            Policy(ConsumesFreeQuota.ALREADY_SETTLED, AutoRetry.NONE, "free_space_then_retry_save", false)
    }

    private fun plain(ui: String, report: Boolean = false) = Policy(ConsumesFreeQuota.NONE, AutoRetry.NONE, ui, report)

    // ASCII-only case folding: Kotlin IGNORE_CASE implies UNICODE_CASE, which lets U+017F / U+0131 match s / i.
    private val BALANCE_TEXT = Pattern.compile("insufficient[_ ](?:quota|balance)|余额不足|额度不足", Pattern.CASE_INSENSITIVE).toRegex()
    private val JSON_NUMBER = Regex("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
    private val ALL_DIGITS = Regex("^[0-9]+$")
    private val REFUSAL_FINISH_REASONS = setOf("IMAGE_SAFETY", "PROHIBITED_CONTENT", "SAFETY", "IMAGE_PROHIBITED_CONTENT")

    /**
     * [body] is the parsed JSON body, the raw text as a JSON string when the body is not JSON, or
     * null when there is no body. HTTP class decides first, then the 4xx error code / balance text,
     * then the 2xx body against [nRequested]. Returns null for ok.
     */
    fun classify(http: Int, body: JsonElement?, nRequested: Int): StudioImageErrorKind? {
        when {
            http == 401 || http == 403 -> return StudioImageErrorKind.AUTH
            http == 402 -> return StudioImageErrorKind.INSUFFICIENT_BALANCE
            http == 404 -> return StudioImageErrorKind.MODEL_UNAVAILABLE
            http == 429 ->
                return if (hasBalanceText(body)) StudioImageErrorKind.INSUFFICIENT_BALANCE else StudioImageErrorKind.RATE_LIMITED
            http >= 500 || http < 200 || http in 300..399 -> return StudioImageErrorKind.UPSTREAM_ERROR
            http in 400..499 -> return classifyClientError(body)
        }
        return classifySuccess(body as? JsonObject, body, nRequested)
    }

    private fun classifyClientError(body: JsonElement?): StudioImageErrorKind {
        val code = ((body as? JsonObject)?.get("error") as? JsonObject)?.get("code").string()
        return when {
            code == "moderation_blocked" || code == "content_policy_violation" -> StudioImageErrorKind.REFUSED
            code == "model_not_found" || code == "model_not_available" -> StudioImageErrorKind.MODEL_UNAVAILABLE
            hasBalanceText(body) -> StudioImageErrorKind.INSUFFICIENT_BALANCE
            else -> StudioImageErrorKind.INVALID_PARAM
        }
    }

    private fun classifySuccess(root: JsonObject?, body: JsonElement?, nRequested: Int): StudioImageErrorKind? {
        val status = (root?.get("base_resp") as? JsonObject)?.get("status_code").number()
        if (status != null && status != 0.0) {
            return when (status) {
                1002.0 -> StudioImageErrorKind.RATE_LIMITED
                1004.0 -> StudioImageErrorKind.AUTH
                1008.0 -> StudioImageErrorKind.INSUFFICIENT_BALANCE
                1026.0, 1027.0 -> StudioImageErrorKind.REFUSED
                else -> StudioImageErrorKind.INVALID_PARAM
            }
        }
        val blockReason = (root?.get("promptFeedback") as? JsonObject)?.get("blockReason").string()
        if (!blockReason.isNullOrEmpty()) return StudioImageErrorKind.REFUSED
        val delivered = StudioImageResponse.parse(body).images.size
        if (delivered == 0) {
            val finishReason = ((root?.get("candidates") as? JsonArray)?.firstOrNull() as? JsonObject)?.get("finishReason").string()
            val refused = finishReason in REFUSAL_FINISH_REASONS ||
                failedCount((root?.get("metadata") as? JsonObject)?.get("failed_count")) > 0
            return if (refused) StudioImageErrorKind.REFUSED else StudioImageErrorKind.DECODE_FAILED
        }
        return if (delivered < nRequested) StudioImageErrorKind.PARTIAL else null
    }

    /** failed_count counts only as a JSON number or an all-digit string; anything else is 0. */
    private fun failedCount(value: JsonElement?): Double {
        val primitive = value as? JsonPrimitive ?: return 0.0
        if (!primitive.isString) return primitive.number() ?: 0.0
        val text = primitive.content
        if (!ALL_DIGITS.matches(text)) return 0.0
        return if (text.trimStart('0').isEmpty()) 0.0 else 1.0
    }

    /** Balance text is matched against string values only, recursing into objects and arrays; keys are ignored. */
    private fun hasBalanceText(value: JsonElement?): Boolean = when (value) {
        is JsonObject -> value.values.any(::hasBalanceText)
        is JsonArray -> value.any(::hasBalanceText)
        is JsonPrimitive -> value.isString && BALANCE_TEXT.containsMatchIn(value.content)
        else -> false
    }

    private fun JsonElement?.string(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

    /**
     * JSON numbers only (not strings, not booleans or null). kotlinx tree parsing also accepts tokens
     * such as 01, NaN, 1026d, 0x1p4 and 1e400, so the token must match the JSON number grammar in full
     * and convert to a finite double.
     */
    private fun JsonElement?.number(): Double? {
        val primitive = (this as? JsonPrimitive)?.takeIf { !it.isString } ?: return null
        if (!JSON_NUMBER.matches(primitive.content)) return null
        return primitive.content.toDouble().takeIf { it.isFinite() }
    }
}

/** Per-image transport / decode failures map to the error kind of the same name. */
val StudioImageResponse.Failure.errorKind: StudioImageErrorKind
    get() = when (this) {
        StudioImageResponse.Failure.NETWORK -> StudioImageErrorKind.NETWORK
        StudioImageResponse.Failure.TIMEOUT -> StudioImageErrorKind.TIMEOUT
        StudioImageResponse.Failure.DECODE_FAILED -> StudioImageErrorKind.DECODE_FAILED
    }
