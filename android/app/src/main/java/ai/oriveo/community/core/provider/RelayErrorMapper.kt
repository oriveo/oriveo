package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayGuidanceCode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayTransport
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

data class RelayErrorContext(
    val relayKind: RelayKind? = null,
    val transport: RelayTransport? = null,
    val authMode: RelayAuthMode? = null,
    val modelID: String? = null,
    val codexCompatIdentity: Boolean? = null,
)

/**
 * An upstream error payload from a custom endpoint, in OpenAI's standard shape
 * `{ error: { code, message, param } }`.
 *
 * Used to recognise the fail-closed errors that are worth retrying: an unsupported
 * image_generation tool, or an unsupported xhigh reasoning effort.
 */
data class RelayUpstreamErrorPayload(
    val code: String?,
    val message: String?,
    val param: String?,
)

/** Hints for the retry-without-tool fallback, handed back by the retry wrapper through the
 *  builder closure. */
data class RelayRetryHints(
    val reasoningEffortOverride: String? = null,
    val removeTools: Boolean = false,
)

object RelayErrorMapper {
    fun classify(
        status: Int,
        body: String,
        upstreamUrl: String? = null,
        context: RelayErrorContext = RelayErrorContext(),
        credentials: Collection<String> = emptyList(),
    ): ProviderServiceError? {
        val detail = extractDetail(body, credentials)

        if (status == 403 && isCodexClientIdentityRejection(detail)) {
            return when {
                !isCodexStyleContext(context) -> relayError(
                    status,
                    RelayGuidanceCode.CodexIdentitySwitchType,
                    "This custom LLM requires Codex client identity. Open Providers → this connection → Connection settings → Protocol type and switch to “Codex (Responses)”, then retry.",
                    detail,
                )
                context.codexCompatIdentity == false -> relayError(
                    status,
                    RelayGuidanceCode.CodexIdentityEnableCompat,
                    "This custom LLM requires Codex client identity. Open Providers → this connection → Connection settings → Compatibility and turn on “Codex compatible identity”, then retry.",
                    detail,
                )
                else -> relayError(
                    status,
                    RelayGuidanceCode.CodexIdentityStillRejected,
                    "This custom LLM still rejects Oriveo's Codex client identity. Open Providers → this connection → Connection settings → Advanced HTTP and set a custom User-Agent or header, or switch to another custom LLM.",
                    detail,
                )
            }
        }

        if (status == 404 && upstreamUrl != null && isChatCompletionsUrl(upstreamUrl) && isCodexStyleHost(upstreamUrl)) {
            return relayError(
                status,
                RelayGuidanceCode.ResponsesOnlyEndpoint,
                "This custom LLM only exposes /v1/responses and rejects /chat/completions. Open Providers → this connection → Connection settings → Protocol type and switch to “Codex (Responses)”, then retry.",
                detail,
            )
        }

        if (status == 502 && isUpstreamRelayError(detail)) {
            return relayError(
                status,
                RelayGuidanceCode.UpstreamUnreachable,
                "This custom LLM could not reach its upstream provider. This is not your configuration. Switch to another custom LLM or contact its service provider.",
                detail,
            )
        }

        if ((status == 404 || status == 400) && isUpstreamModelUnavailable(detail)) {
            return relayError(
                status,
                RelayGuidanceCode.ModelNotOffered,
                "This custom LLM does not offer this model. Open Providers → this connection → Connection settings → Model and choose a supported model ID.",
                detail,
            )
        }

        if (status == 400 && isResponsesProtocolMismatch(detail) && isOpenAIChatContext(context)) {
            return relayError(
                status,
                RelayGuidanceCode.ResponsesProtocolRequired,
                "This custom LLM requires the OpenAI Responses protocol. Open Providers → this connection → Connection settings → Protocol type and switch to “Codex (Responses)”, then retry.",
                detail,
            )
        }

        if (status == 400 && isUnknownStoreParameter(detail)) {
            return relayError(
                status,
                RelayGuidanceCode.StoreParamRejected,
                "This custom LLM rejects the store/disable_response_storage field. Open Providers → this connection → Connection settings → Compatibility and turn off “Don't keep responses in the cloud”, then retry.",
                detail,
            )
        }

        if (status == 400 && isInvalidServiceTier(detail)) {
            return relayError(
                status,
                RelayGuidanceCode.ServiceTierInvalid,
                "This custom LLM does not accept the current OpenAI service tier value. Open Providers → this connection → Connection settings → Compatibility and clear “OpenAI service tier”, then retry.",
                detail,
            )
        }

        if (status == 400 && isMissingMaxTokens(detail) && isAnthropicContext(context)) {
            return relayError(
                status,
                RelayGuidanceCode.MaxTokensRequired,
                // The user-visible wording lives in `R.string.relay_guidance_max_tokens_required`
                // and is localised by guidance code. This English copy is only the fallback for
                // non-composable call sites, and it must stay word for word identical to the
                // resource: when the settings page was renamed and this string kept the old
                // name, the fallback pointed users somewhere that no longer existed.
                "This custom LLM requires the max_tokens parameter. Open Advanced Settings and set a max_tokens value, then retry.",
                detail,
            )
        }

        if ((status == 401 || status == 403) && isAnthropicAuthMismatch(detail, context)) {
            return relayError(
                status,
                RelayGuidanceCode.AnthropicAuthHeader,
                "This custom LLM expects an Anthropic-style x-api-key header. Open Providers → this connection → Connection settings → Authentication and switch to “x-api-key”, then retry.",
                detail,
            )
        }

        if (status == 400 && isImageUrlSchemaMismatch(detail) && isLikelyOpenAIModelOnAnthropic(context)) {
            return relayError(
                status,
                RelayGuidanceCode.ImageSchemaMismatch,
                "Image attachments use a schema that does not match this custom LLM's protocol. Open Providers → this connection → Connection settings → Protocol type and choose a protocol that fits your model, then retry.",
                detail,
            )
        }

        if (status == 429) {
            return relayError(
                status,
                RelayGuidanceCode.RateLimited,
                "This custom LLM hit a rate limit. Wait a moment, lower request volume, or switch to another key or custom LLM.",
                detail,
            )
        }

        return null
    }

    /**
     * Parses a 4xx body into OpenAI's standard error shape, or null when it cannot be parsed.
     *
     * This reads the raw body directly rather than going through the RelayDebugSnippet
     * allowlist: the retry decision is internal and never leaves the process.
     */
    private val parserJson = Json { ignoreUnknownKeys = true; isLenient = true }

    fun parseUpstreamErrorPayload(body: String?): RelayUpstreamErrorPayload? {
        if (body.isNullOrBlank()) return null
        return try {
            val element = parserJson.parseToJsonElement(body) as? JsonObject ?: return null
            // Top-level error object.
            when (val err = element["error"]) {
                is JsonObject -> return RelayUpstreamErrorPayload(
                    code = err.stringField("code"),
                    message = err.stringField("message"),
                    param = err.stringField("param"),
                )
                is JsonPrimitive -> if (err.isString) {
                    return RelayUpstreamErrorPayload(code = null, message = err.contentOrNull, param = null)
                }
                else -> Unit
            }
            // Also accept the in-stream `response.failed` shape, where the error is nested
            // inside the response object.
            val nested = (element["response"] as? JsonObject)?.get("error") as? JsonObject
            if (nested != null) {
                return RelayUpstreamErrorPayload(
                    code = nested.stringField("code"),
                    message = nested.stringField("message"),
                    param = nested.stringField("param"),
                )
            }
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun JsonObject.stringField(key: String): String? {
        val prim = this[key] as? JsonPrimitive ?: return null
        if (!prim.isString) return null
        return prim.contentOrNull?.takeIf { it.isNotEmpty() }
    }

    /**
     * Recognises an "image_generation tool is not supported" error, which drives the
     * retry-without-tool fallback.
     *
     * The rules are deliberately tight so vision and image-attachment errors are not caught by
     * mistake:
     * - main path: param points exactly at tools[*] AND (message contains "image_generation"
     *   OR code is in the whitelist)
     * - on its own: code == "tool_not_supported"
     * - last resort: message strictly contains the underscored "image_generation" phrase
     *
     * Matching the bare word "image" is not allowed - vision errors would collide with it.
     */
    fun isImageGenerationToolUnsupportedError(
        payload: RelayUpstreamErrorPayload?,
        statusCode: Int,
    ): Boolean {
        if (statusCode !in 400..499 || payload == null) return false

        val code = payload.code?.lowercase().orEmpty()
        val message = payload.message.orEmpty()
        val messageLower = message.lowercase()
        val param = payload.param.orEmpty()

        if (code == "tool_not_supported") return true

        val paramTargetsTools = paramMatchesTools(param)
        val codeWhitelist = setOf("unknown_parameter", "unsupported_parameter", "invalid_parameter")
        if (paramTargetsTools && (messageLower.contains("image_generation") || code in codeWhitelist)) {
            return true
        }

        // Last resort: it has to be the underscored "image_generation" or "web_search" phrase,
        // never a bare "image". web_search is included because a few endpoints answer
        // "web_search is not supported"; the retry clears the whole tools array indiscriminately,
        // which matches the general stance that tool-protocol support here is unproven.
        if (messageLower.contains("image_generation")) return true
        if (messageLower.contains("web_search")) return true
        if (isImageEndpointModelMismatch(messageLower)) return true
        return false
    }

    /** Recognises a "reasoning_effort=xhigh is not supported" error. */
    fun isReasoningEffortXHighError(
        payload: RelayUpstreamErrorPayload?,
        statusCode: Int,
    ): Boolean {
        if (statusCode !in 400..499 || payload == null) return false
        val message = payload.message.orEmpty().lowercase()
        return message.contains("xhigh") || (message.contains("reasoning") && message.contains("effort"))
    }

    private fun paramMatchesTools(param: String): Boolean {
        if (param.equals("tools", ignoreCase = true)) return true
        // Matches shapes such as tools[0] and tools[12].type.
        val regex = Regex("^tools(\\[\\d+](\\.[a-z_]+)?)?$", RegexOption.IGNORE_CASE)
        return regex.matches(param)
    }

    private fun isImageEndpointModelMismatch(messageLower: String): Boolean {
        return messageLower.contains("unsupported model:") &&
            messageLower.contains("only gpt-image") &&
            messageLower.contains("supported on this endpoint")
    }

    fun mapOrDefault(
        status: Int,
        body: String,
        upstreamUrl: String? = null,
        context: RelayErrorContext = RelayErrorContext(),
        credentials: Collection<String> = emptyList(),
    ): ProviderServiceError {
        classify(status, body, upstreamUrl, context, credentials)?.let { return it }
        val detail = extractDetail(body, credentials).ifBlank { "HTTP $status" }
        return when (status) {
            401, 403 -> ProviderServiceError.InvalidAPIKey(detail)
            429 -> ProviderServiceError.RateLimited(detail)
            else -> ProviderServiceError.Upstream(status, detail)
        }
    }

    private fun relayError(
        status: Int,
        guidanceCode: RelayGuidanceCode,
        guidance: String,
        detail: String,
    ) = ProviderServiceError.RelayUpstream(
        statusCode = status,
        guidance = guidance,
        detail = detail,
        guidanceCode = guidanceCode,
    )

    /**
     * Extracts a user-facing detail string, and nothing else.
     *
     * Only [RelayDebugSnippet.extract] is used, which allowlists `error.{message,code,type}`.
     * If the JSON does not parse, or none of those fields are present, this returns an empty
     * string and **never** a truncated raw body. That is what stops a prompt fragment or an SSE
     * chunk token echoed back by the endpoint from leaking through the detail field into an
     * error card, a screenshot or a support log.
     */
    private fun extractDetail(body: String, credentials: Collection<String>): String {
        return ai.oriveo.community.core.provider.relay.RelayDebugSnippet
            .extract(body, redacting = credentials)
            .orEmpty()
    }

    private fun isCodexClientIdentityRejection(body: String): Boolean {
        val lower = body.lowercase()
        return listOf(
            "codex official clients",
        ).any { lower.contains(it) }
    }

    private fun isUpstreamRelayError(body: String): Boolean {
        val lower = body.lowercase()
        return listOf(
            "upstream_error",
            "upstream authentication",
            "upstream timeout",
            "upstream service",
        ).any { lower.contains(it) }
    }

    private fun isResponsesProtocolMismatch(body: String): Boolean {
        val lower = body.lowercase()
        return lower.contains("unknown parameter") && body.contains("input[")
    }

    private fun isUnknownStoreParameter(body: String): Boolean {
        val lower = body.lowercase()
        if (!lower.contains("unknown parameter") && !lower.contains("unrecognized parameter")) return false
        return lower.contains("'store'") ||
            lower.contains("\"store\"") ||
            lower.contains("disable_response_storage")
    }

    private fun isInvalidServiceTier(body: String): Boolean {
        val lower = body.lowercase()
        if (!lower.contains("service_tier") && !lower.contains("service tier")) return false
        return lower.contains("invalid") || lower.contains("not allowed") || lower.contains("unsupported")
    }

    private fun isMissingMaxTokens(body: String): Boolean {
        val lower = body.lowercase()
        if (!lower.contains("max_tokens")) return false
        return lower.contains("required") ||
            lower.contains("must include") ||
            lower.contains("missing")
    }

    private fun isAnthropicAuthMismatch(body: String, context: RelayErrorContext): Boolean {
        val lower = body.lowercase()
        if (
            context.authMode == RelayAuthMode.Bearer &&
            context.modelID?.let { RelayFamilyHeuristics.infer(it) == RelayModelFamily.Anthropic } == true &&
            (lower.contains("invalid api key") || lower.contains("unauthorized") || lower.contains("authentication"))
        ) {
            return true
        }
        val xApiKeyHints = lower.contains("x-api-key") || lower.contains("anthropic-version")
        val authErrorHints = lower.contains("authentication_error") ||
            lower.contains("authentication failed") ||
            lower.contains("required")
        return xApiKeyHints && authErrorHints
    }

    private fun isImageUrlSchemaMismatch(body: String): Boolean {
        val lower = body.lowercase()
        if (!lower.contains("image_url") && !lower.contains("image content")) return false
        return lower.contains("invalid") ||
            lower.contains("not allowed") ||
            lower.contains("unknown") ||
            lower.contains("unsupported")
    }

    private fun isUpstreamModelUnavailable(body: String): Boolean {
        val lower = body.lowercase()
        return listOf(
            "model_not_found",
            "model not found",
            "does not exist",
            "unknown model",
        ).any { lower.contains(it) }
    }

    private fun isChatCompletionsUrl(value: String): Boolean = value.contains("/chat/completions")

    private fun isCodexStyleHost(value: String): Boolean {
        val lower = value.lowercase()
        return listOf("packy", "ylsagi", "code-for", "ccswitch", "cc-switch", "codex").any { lower.contains(it) }
    }

    private fun isCodexStyleContext(context: RelayErrorContext): Boolean =
        context.relayKind == RelayKind.CodexStyle || context.transport == RelayTransport.OpenAIResponses

    private fun isOpenAIChatContext(context: RelayErrorContext): Boolean =
        context.transport == null ||
            context.transport == RelayTransport.OpenAIChatCompletions ||
            context.transport == RelayTransport.Auto

    private fun isAnthropicContext(context: RelayErrorContext): Boolean =
        context.transport == null || context.transport == RelayTransport.AnthropicMessages

    private fun isLikelyOpenAIModelOnAnthropic(context: RelayErrorContext): Boolean {
        if (context.transport != RelayTransport.AnthropicMessages) return false
        return context.modelID?.let { RelayFamilyHeuristics.infer(it) == RelayModelFamily.OpenAI } ?: true
    }
}
