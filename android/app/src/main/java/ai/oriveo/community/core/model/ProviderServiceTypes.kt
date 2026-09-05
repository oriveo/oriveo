package ai.oriveo.community.core.model

/** What a model-catalog refresh returned. */
data class ProviderSyncResult(
    val models: List<AIModel>,
)

/** What one completed chat request returned. */
data class ProviderChatResult(
    val text: String,
    val promptTokens: Int = 0,
    val completionTokens: Int = 0,
    val estimatedCost: Double = 0.0,
    val attachments: List<Attachment>? = null,
    val servedModelID: String? = null,
    val reasoningText: String? = null,
    /** Sources the model cited, for the providers that report them. */
    val citations: List<Citation>? = null,
    /** Input tokens the provider served from its own cache, billed at a reduced rate. */
    val cachedInputTokens: Int? = null,
    /** Cache-write tokens for the short TTL. Null means not reported, which is not zero. */
    val cacheCreation5mTokens: Int? = null,
    /** Cache-write tokens for the long TTL. Null means not reported, which is not zero. */
    val cacheCreation1hTokens: Int? = null,
    /** Name of a [ai.oriveo.community.core.provider.CostSource]; null falls back to an estimate. */
    val costSource: String? = null,
)

/** Everything that can go wrong between this app and a provider the user configured. */
sealed class ProviderServiceError : Exception() {
    data class InvalidAPIKey(val detail: String) : ProviderServiceError()
    data class QuotaExceeded(val detail: String) : ProviderServiceError()
    data class ModelUnavailable(val detail: String) : ProviderServiceError()
    data class RateLimited(val detail: String) : ProviderServiceError()
    data object EmptyModelCatalog : ProviderServiceError()
    data object EmptyResponse : ProviderServiceError()
    data class InvalidConfiguration(val detail: String) : ProviderServiceError()
    data class Network(val detail: String) : ProviderServiceError()
    data class Upstream(
        val statusCode: Int,
        val detail: String,
        /** Structured `/error/param` only; never inferred from message/detail text. */
        val rejectedParameter: String? = null,
    ) : ProviderServiceError()
    /**
     * A Grok subscription sign-in failed.
     *
     * Kept apart from [InvalidAPIKey] and [QuotaExceeded] because the fix is different. A rejected
     * API key means "check the key", while a rejected subscription means the plan does not cover
     * third-party apps, the sign-in expired, or the period's quota is gone. Folding them together
     * sends the user to the wrong place.
     */
    data class GrokSubscription(
        val reason: GrokSubscriptionFailureReason,
        val detail: String,
    ) : ProviderServiceError()

    /** A Codex (ChatGPT) subscription sign-in failed, for the same reasons as above. */
    data class OpenAISubscription(
        val reason: OpenAISubscriptionFailureReason,
        val detail: String,
    ) : ProviderServiceError()

    data class RelayUpstream(
        val statusCode: Int,
        val guidance: String,
        val detail: String,
        /** Stable code for the guidance text, so a retry can be offered without parsing it. */
        val guidanceCode: RelayGuidanceCode? = null,
    ) : ProviderServiceError()

    val title: String
        get() = when (this) {
            is InvalidAPIKey -> "Invalid API Key"
            is QuotaExceeded -> "Provider Quota Reached"
            is ModelUnavailable -> "Model Unavailable"
            is RateLimited -> "Provider Rate Limited"
            is EmptyModelCatalog -> "No Models Found"
            is EmptyResponse -> "Empty Provider Response"
            is InvalidConfiguration -> "Provider Configuration Error"
            is Network, is Upstream -> "Provider Request Failed"
            is GrokSubscription -> "Grok subscription"
            is OpenAISubscription -> "ChatGPT subscription"
            is RelayUpstream -> "Relay Error ($statusCode)"
        }

    val userMessage: String
        get() = when (this) {
            is InvalidAPIKey -> "The API key could not be validated. Check the value or generate a new key."
            is QuotaExceeded -> "The provider reports that the quota or credit for this API key is used up. Check your billing with the provider, or switch models."
            is ModelUnavailable -> "This model is currently unavailable from the provider. Switch models or try again later."
            is RateLimited -> "The provider is temporarily rate limiting this request. Please wait a moment and try again."
            is EmptyModelCatalog -> "The provider returned an empty model catalog, so we could not finish setup."
            is EmptyResponse -> "The provider returned no assistant content for this message."
            is InvalidConfiguration -> "The selected provider configuration is incomplete, so the request could not be sent."
            is Network -> "The request did not complete successfully. Please check your network and try again."
            is Upstream -> "The provider returned an error for this request. Please retry or switch models."
            is GrokSubscription -> reason.userMessage
            is OpenAISubscription -> reason.userMessage
            is RelayUpstream -> guidance
        }

    val technicalDetail: String
        get() = when (this) {
            is InvalidAPIKey -> detail
            is QuotaExceeded -> detail
            is ModelUnavailable -> detail
            is RateLimited -> detail
            is EmptyModelCatalog -> "The provider model catalog returned zero models."
            is EmptyResponse -> "The provider chat completion finished without any text content."
            is InvalidConfiguration -> detail
            is Network -> detail
            is Upstream -> "Upstream HTTP $statusCode: $detail"
            is GrokSubscription -> "Grok subscription ${reason.name}: $detail"
            is OpenAISubscription -> "ChatGPT subscription ${reason.name}: $detail"
            is RelayUpstream -> "Upstream HTTP $statusCode: $detail"
        }

    override val message: String
        get() = technicalDetail
}

/**
 * Why a Grok subscription sign-in was refused.
 *
 * [userMessage] is the English fallback. [ai.oriveo.community.core.error.ErrorMapper] maps each
 * case to a localized string, so translated builds never fall through to this text.
 */
enum class GrokSubscriptionFailureReason(val userMessage: String) {
    /** The upstream rejected this client version. An API key still works. */
    ClientVersionRejected(
        "Grok subscription sign-in is temporarily unavailable while we update it. " +
            "You can connect with an API key instead.",
    ),

    /** The plan on the xAI account does not cover third-party apps. */
    NotEligible(
        "Your xAI account's current plan doesn't allow using the Grok subscription in third-party apps.",
    ),

    /** The sign-in has expired and needs to be authorized again. */
    Expired("Your Grok sign-in has expired. Please authorize again."),

    /** This period's quota is gone; it returns on the next reset. */
    QuotaExhausted(
        "You've used up this period's Grok subscription quota. It will resume after the next reset.",
    ),
}

/**
 * Why a Codex (ChatGPT) subscription sign-in was refused. Deliberately a separate enum from
 * [GrokSubscriptionFailureReason]: the wording names a different product, and merging them would
 * force one of the two to read wrong.
 */
enum class OpenAISubscriptionFailureReason(val userMessage: String) {
    /** The upstream rejected this client version. An API key still works. */
    Unavailable(
        "ChatGPT subscription sign-in is temporarily unavailable while we update it. " +
            "You can connect with an API key instead.",
    ),

    /** The plan on the OpenAI account does not cover Codex in third-party apps. */
    NotEligible(
        "Your ChatGPT account's current plan doesn't allow using Codex in third-party apps.",
    ),

    /** The sign-in has expired and needs to be authorized again. */
    Expired("Your ChatGPT sign-in has expired. Please authorize again."),

    /** This period's quota is gone; it returns on the next reset. */
    QuotaExhausted(
        "You've used up this period's Codex quota. It will resume after the next reset.",
    ),
}

/** Stable keys for the relay guidance texts, so a stored hint survives a translation change. */
enum class RelayGuidanceCode(val stableKey: String) {
    CodexIdentitySwitchType("codex_identity_switch_type"),
    CodexIdentityEnableCompat("codex_identity_enable_compat"),
    CodexIdentityStillRejected("codex_identity_still_rejected"),
    ResponsesOnlyEndpoint("responses_only_endpoint"),
    UpstreamUnreachable("upstream_unreachable"),
    ModelNotOffered("model_not_offered"),
    ResponsesProtocolRequired("responses_protocol_required"),
    StoreParamRejected("store_param_rejected"),
    ServiceTierInvalid("service_tier_invalid"),
    MaxTokensRequired("max_tokens_required"),
    AnthropicAuthHeader("anthropic_auth_header"),
    ImageSchemaMismatch("image_schema_mismatch"),
    RateLimited("rate_limited");

    val persistenceKey: String get() = "relay_guidance:$stableKey"

    companion object {
        private const val PERSISTENCE_PREFIX = "relay_guidance:"

        fun fromPersistenceKey(raw: String?): RelayGuidanceCode? {
            val key = raw?.takeIf { it.startsWith(PERSISTENCE_PREFIX) }
                ?.removePrefix(PERSISTENCE_PREFIX)
                ?: return null
            return entries.firstOrNull { it.stableKey == key }
        }
    }
}
