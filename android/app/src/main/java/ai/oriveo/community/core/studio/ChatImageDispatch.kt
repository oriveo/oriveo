package ai.oriveo.community.core.studio

import ai.oriveo.community.core.model.ProviderServiceError

/**
 * Chat image dispatch onto the studio pipeline: which chat image sends move to the studio executor,
 * which attachments become reference images, and how a studio error kind maps onto the chat error.
 * Pure functions, behavior follows chat_image_dispatch.v1.
 */
object ChatImageDispatch {
    /** Attachment of the user message being answered; [hasBytes] = local image bytes are available. */
    data class Candidate(val id: String, val hasBytes: Boolean)

    /** A reference image picked for an edit: 1-based [slot], [role] is "base" or "element". */
    data class Pick(val attachmentId: String, val slot: Int, val role: String)

    sealed interface Decision {
        /** Keep the existing chat image path, unchanged. */
        data object Legacy : Decision

        data class Studio(val operation: ImageOperation, val images: List<Pick>) : Decision
    }

    /** Routes whose chat image sends run on the studio executor (spec.studioRoutes). */
    val STUDIO_ROUTES: List<ImageRoute> = listOf(
        ImageRoute.OPENAI_IMAGES,
        ImageRoute.XAI_IMAGES,
        ImageRoute.OPENROUTER_IMAGES,
        ImageRoute.MINIMAX_IMAGE_GENERATION,
        ImageRoute.DASHSCOPE_MULTIMODAL,
    )

    /** Provider kinds that always keep the legacy chat image path (spec.legacyProviderKinds). */
    val LEGACY_PROVIDER_KINDS: List<String> = listOf("relay")

    /** Fixed studio params of a chat image send (spec.chatParams). */
    val chatParams: ImageParamRequest = ImageParamRequest(aspect = "1:1", resolution = "1K", quality = "standard", n = 1)

    private const val BASE_ROLE = "base"
    private const val ELEMENT_ROLE = "element"

    private val SCHEME = Regex("^[a-z][a-z0-9+.-]*://", RegexOption.IGNORE_CASE)
    private val SCHEME_AND_HOST = Regex("^[a-z][a-z0-9+.-]*://[^/?#\\s]+", RegexOption.IGNORE_CASE)
    private const val DASHSCOPE_NATIVE_SUFFIX = "/api/v1"
    private val DASHSCOPE_SUFFIXES = listOf("/compatible-mode/v1", DASHSCOPE_NATIVE_SUFFIX)

    /**
     * Studio only when the legacy gate already chose image generation, the provider is not relay /
     * managed, a profile resolved and its route is a studio route; anything else stays legacy.
     * Edit-capable profiles take the attachments with local bytes in order, up to maxReferenceImages
     * (missing or non-positive = 1): first is slot 1 base, the rest element; none left = generate.
     */
    fun decide(
        providerKind: String,
        legacyImageDispatch: Boolean,
        profile: ImageProfile?,
        attachments: List<Candidate>,
    ): Decision {
        if (!legacyImageDispatch || providerKind in LEGACY_PROVIDER_KINDS) return Decision.Legacy
        if (profile == null || profile.route !in STUDIO_ROUTES) return Decision.Legacy
        if (ImageOperation.EDIT !in profile.operations) return Decision.Studio(ImageOperation.GENERATE, emptyList())
        val limit = profile.maxReferenceImages?.takeIf { it > 0 } ?: 1
        val picks = attachments.filter { it.hasBytes }.take(limit).mapIndexed { index, candidate ->
            Pick(candidate.id, slot = index + 1, role = if (index == 0) BASE_ROLE else ELEMENT_ROLE)
        }
        if (picks.isEmpty()) return Decision.Studio(ImageOperation.GENERATE, emptyList())
        return Decision.Studio(ImageOperation.EDIT, picks)
    }

    /**
     * Studio base URL for a chat image send, derived from the connection's effective address: trimmed,
     * https:// added without a scheme, trailing slashes dropped. A dashscope_multimodal route swaps one
     * trailing OpenAI-compatible or native suffix for the native /api/v1. Null (blank or no host) keeps
     * the legacy path.
     */
    fun studioBaseUrl(route: String, connectionBaseUrl: String?): String? {
        var base = connectionBaseUrl?.trim().orEmpty()
        if (base.isEmpty()) return null
        if (!SCHEME.containsMatchIn(base)) base = "https://$base"
        base = base.trimEnd('/')
        if (!SCHEME_AND_HOST.containsMatchIn(base)) return null
        if (route != ImageRoute.DASHSCOPE_MULTIMODAL.wire) return base
        // Native DashScope API: drop one OpenAI-compatible or native suffix (case-sensitive), then append /api/v1.
        DASHSCOPE_SUFFIXES.firstOrNull { base.endsWith(it) }?.let { base = base.removeSuffix(it).trimEnd('/') }
        return "$base$DASHSCOPE_NATIVE_SUFFIX"
    }

    /** Chat failure category of a studio error kind (spec.errorMap); null for partial, which completes. */
    fun category(kind: StudioImageErrorKind): String? = when (kind) {
        StudioImageErrorKind.REFUSED, StudioImageErrorKind.INVALID_PARAM -> "upstream_400"
        StudioImageErrorKind.AUTH -> "invalid_key"
        StudioImageErrorKind.INSUFFICIENT_BALANCE -> "quota_exceeded"
        StudioImageErrorKind.RATE_LIMITED -> "rate_limited"
        StudioImageErrorKind.MODEL_UNAVAILABLE -> "model_unavailable"
        StudioImageErrorKind.UPSTREAM_ERROR -> "upstream_502"
        StudioImageErrorKind.TIMEOUT, StudioImageErrorKind.NETWORK -> "network"
        StudioImageErrorKind.DECODE_FAILED -> "empty_response"
        StudioImageErrorKind.STORAGE_FULL -> "upstream_507"
        StudioImageErrorKind.PARTIAL -> null
    }

    /** Chat error for a failed studio send, detail = the result message; null for partial. */
    fun chatFailure(kind: StudioImageErrorKind, message: String): ProviderServiceError? = when (category(kind)) {
        "upstream_400" -> ProviderServiceError.Upstream(statusCode = 400, detail = message)
        "upstream_502" -> ProviderServiceError.Upstream(statusCode = 502, detail = message)
        "upstream_507" -> ProviderServiceError.Upstream(statusCode = 507, detail = message)
        "invalid_key" -> ProviderServiceError.InvalidAPIKey(message)
        "quota_exceeded" -> ProviderServiceError.QuotaExceeded(message)
        "rate_limited" -> ProviderServiceError.RateLimited(message)
        "model_unavailable" -> ProviderServiceError.ModelUnavailable(message)
        "network" -> ProviderServiceError.Network(message)
        "empty_response" -> ProviderServiceError.EmptyResponse
        else -> null
    }
}
