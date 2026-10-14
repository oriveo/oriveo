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

        // Official CLI gate: the phrase is matched against the raw response body (detail is a redacted
        // snippet). This is not a key problem, so it sits ahead of the generic 403 handling.
        if (ai.oriveo.community.core.provider.relay.RelayClientGate.isClientGated(status, body)) {
            return relayError(
                status,
                RelayGuidanceCode.ClientGated,
                "This key's group only accepts the official Claude CLI. In the account console of the site that issued this key, move the key to a group that allows API access, or create a new key and add it in Providers → this connection → API Keys. Then retry.",
                detail,
            )
        }

        // The mobile apps have no "Codex compatible identity" switch, so a rejected identity can only
        // point at Advanced HTTP, which exists. Two branches, the same as on iOS.
        if (status == 403 && isCodexClientIdentityRejection(detail)) {
            return when {
                !isCodexStyleContext(context) -> relayError(
                    status,
                    RelayGuidanceCode.CodexIdentitySwitchType,
                    "This connection requires a Codex client identity. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses, then retry.",
                    detail,
                )
                else -> relayError(
                    status,
                    RelayGuidanceCode.CodexIdentityStillRejected,
                    "This connection still rejects Oriveo's Codex client identity. Open Providers → this connection → Edit connection → Headers & query params and set a custom User-Agent or header, or switch to another connection.",
                    detail,
                )
            }
        }

        // A standalone image endpoint (imageRoute = images_endpoint) rejected response_format.
        if (status == 400 && upstreamUrl != null && isImagesGenerationsUrl(upstreamUrl) && body.lowercase().contains("response_format")) {
            return relayError(
                status,
                RelayGuidanceCode.ImageResponseFormatRejected,
                "This image model doesn't accept the response_format parameter. Try a different image model ID.",
                detail,
            )
        }

        if (status == 404 && upstreamUrl != null && isChatCompletionsUrl(upstreamUrl) && isCodexStyleHost(upstreamUrl)) {
            return relayError(
                status,
                RelayGuidanceCode.ResponsesOnlyEndpoint,
                "This connection only exposes /v1/responses and rejects /chat/completions. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses, then retry.",
                detail,
            )
        }

        // A 404 on the image endpoint means this connection has no standalone image API. It sits ahead of
        // "model does not exist", in the same order as iOS relayGuidanceFailure.
        if (status == 404 && upstreamUrl != null && isImagesGenerationsUrl(upstreamUrl)) {
            return relayError(
                status,
                RelayGuidanceCode.ImagesEndpointUnavailable,
                "This connection doesn't offer a separate image generation API. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses. Oriveo will then generate images inside the chat instead.",
                detail,
            )
        }

        if (status == 502 && isUpstreamRelayError(detail)) {
            return relayError(
                status,
                RelayGuidanceCode.UpstreamUnreachable,
                "This connection could not reach its upstream provider. This is not your configuration — its administrator's upstream account may be invalid, out of credits, or rate-limited. Switch to another connection or contact its administrator.",
                detail,
            )
        }

        if ((status == 404 || status == 400) && isUpstreamModelUnavailable(detail)) {
            return relayError(
                status,
                RelayGuidanceCode.ModelNotOffered,
                "This connection's upstream does not offer this model. Open Providers → this connection → Model Library and enable a model it actually offers. You can ask its administrator for the exact list of available model IDs.",
                detail,
            )
        }

        if (status == 400 && isResponsesProtocolMismatch(detail) && isOpenAIChatContext(context)) {
            return relayError(
                status,
                RelayGuidanceCode.ResponsesProtocolRequired,
                "This connection requires the OpenAI Responses protocol for this model. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses, then retry.",
                detail,
            )
        }

        if (status == 400 && isUnknownStoreParameter(detail)) {
            return relayError(
                status,
                RelayGuidanceCode.StoreParamRejected,
                "This connection rejects the “store/disable_response_storage” field. Open Providers → this connection → Edit connection → Compatibility and turn off “Don't keep responses in the cloud”, then retry.",
                detail,
            )
        }

        if (status == 400 && isInvalidServiceTier(detail)) {
            return relayError(
                status,
                RelayGuidanceCode.ServiceTierInvalid,
                "This connection does not accept the current service tier value. Open Providers → this connection → Edit connection → Compatibility and clear “Service Tier”, then retry.",
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
                "This connection requires the “max_tokens” parameter. Open Providers → this connection → Parameters and set “Max Tokens” (e.g. 4096), then retry.",
                detail,
            )
        }

        // Judge on the raw body: Anthropic's `error.type` (authentication_error) is not in the redacted snippet.
        if ((status == 401 || status == 403) && isAnthropicAuthMismatch(body, context)) {
            return relayError(
                status,
                RelayGuidanceCode.AnthropicAuthHeader,
                "This connection expects an Anthropic-style x-api-key header. Open Providers → this connection → Edit connection → Authentication and choose “x-api-key”, then retry.",
                detail,
            )
        }

        if (status == 400 && isImageUrlSchemaMismatch(detail) && isLikelyOpenAIModelOnAnthropic(context)) {
            return relayError(
                status,
                RelayGuidanceCode.ImageSchemaMismatch,
                "Image attachments use a schema that doesn't match this model's protocol. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to one that fits this model, then retry.",
                detail,
            )
        }

        // A 429 gets no relay guidance. It falls through to mapOrDefault, which splits by body into
        // quota exhausted / model unavailable / rate limited.

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
        // The key access verdict needs the raw response body, so it can only be computed here (detail is a
        // redacted allowlist snippet); it is attached to the error object and carried out.
        val keyAccess = ai.oriveo.community.core.provider.relay.RelayKeyAccess.signal(status, body)
        val namesThinking = ai.oriveo.community.core.provider.relay.RelayReasoningTiers.bodyNamesThinking(body)
        val namesRouteRejection = ai.oriveo.community.core.provider.relay.RelayProtocolFallback.bodyNamesRouteRejection(body)
        classify(status, body, upstreamUrl, context, credentials)?.let {
            return it.also {
                it.relayKeyAccess = keyAccess
                it.relayBodyNamesThinking = namesThinking
                it.relayBodyNamesRouteRejection = namesRouteRejection
            }
        }
        val detail = extractDetail(body, credentials).ifBlank { "HTTP $status" }
        return when (status) {
            401, 403 -> ProviderServiceError.InvalidAPIKey(detail)
            // The same keyword set as the official path SseParser.mapHttpError, matched on the raw body.
            429 -> {
                val lower = body.lowercase()
                when {
                    SseParser.QUOTA_PATTERN.containsMatchIn(lower) -> ProviderServiceError.QuotaExceeded(detail)
                    SseParser.UNAVAILABLE_PATTERN.containsMatchIn(lower) -> ProviderServiceError.ModelUnavailable(detail)
                    else -> ProviderServiceError.RateLimited(detail)
                }
            }
            else -> ProviderServiceError.Upstream(status, detail)
        }.also {
            it.relayKeyAccess = keyAccess
            it.relayBodyNamesThinking = namesThinking
            it.relayBodyNamesRouteRejection = namesRouteRejection
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

    private fun isImagesGenerationsUrl(value: String): Boolean = value.contains("/images/generations")

    /**
     * A weak hint: a relay whose host mentions Codex most likely speaks the Responses protocol.
     * It only sharpens the wording of a 404; the relay kind and transport decide behaviour.
     */
    private fun isCodexStyleHost(value: String): Boolean = value.lowercase().contains("codex")

    // When the protocol is unknown (transport == null: catalog sync /models, standalone image
    // /images/generations), changing the protocol is meaningless, so only the "still rejected" branch applies.
    private fun isCodexStyleContext(context: RelayErrorContext): Boolean =
        context.transport == null ||
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
