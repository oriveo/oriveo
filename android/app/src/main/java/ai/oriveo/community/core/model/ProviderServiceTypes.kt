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
    /**
     * The user's additional request body or web-search / thinking custom fields failed local validation, so this message was not sent.
     * Kept apart from [InvalidConfiguration]: the connection itself is fine and must not be presented as a configuration fault (Critical).
     * The technical details carry only a safe code, never key names or values the user wrote (protected fields and forbidden segment names come from a fixed vocabulary and may appear).
     */
    data class LocalRequestRejected(
        val owner: String,
        val reason: String,
        val fieldName: String? = null,
        val line: Int? = null,
        /** For a "field this section does not accept" rejection, the fields the section does allow: official declared paths, never user input. */
        val allowedPaths: List<String> = emptyList(),
    ) : ProviderServiceError()
    /**
     * This message's file attachments, delivered as text, exceed the current model's limits (total size or count), so some files cannot be sent and the whole message was not sent.
     * Like [LocalRequestRejected] this is a local block: the connection is fine and the request never left the device.
     * [fileNames] are the files that fell outside the limit, in attachment order.
     */
    data class AttachmentTextOverLimit(
        val fileNames: List<String>,
        /** The count limit when other files in the same message are also turned away by it; null when only the text total is the problem. */
        val countLimit: Int? = null,
    ) : ProviderServiceError() {
        /** The file names as shown to the user; the same string the persisted safe code encodes. */
        val fileNamesText: String get() = fileNames.joinToString(NAME_SEPARATOR)

        companion object {
            /** Diagnostics use only this stable code, never file names. */
            const val CODE = "attachment_text_over_limit"
            private const val DETAIL_PREFIX = "$CODE:"
            private const val NAME_SEPARATOR = ", "

            /** Whether a persisted `errorDetail` is this kind of failure. */
            fun isDetail(detail: String?): Boolean = detail != null && detail.startsWith(DETAIL_PREFIX)

            /** Restores the displayed file-name string from the persisted safe code; null when it is not this failure or the encoding is damaged. */
            fun fileNamesTextFromDetail(detail: String?): String? {
                if (detail == null || !detail.startsWith(DETAIL_PREFIX)) return null
                return runCatching {
                    String(
                        java.util.Base64.getUrlDecoder()
                            .decode(detail.removePrefix(DETAIL_PREFIX).substringBefore(COUNT_SEPARATOR)),
                        Charsets.UTF_8,
                    )
                }.getOrNull()
            }

            /** When this failure also hit the count limit, restores that limit from the safe code; null when absent or damaged. */
            fun countLimitFromDetail(detail: String?): Int? {
                if (detail == null || !detail.startsWith(DETAIL_PREFIX)) return null
                val body = detail.removePrefix(DETAIL_PREFIX)
                if (COUNT_SEPARATOR !in body) return null
                return body.substringAfter(COUNT_SEPARATOR).toIntOrNull()
            }

            // The base64url alphabet has no ':', so it can safely join the count limit after the name segment.
            private const val COUNT_SEPARATOR = ':'

            internal fun detailFor(fileNames: List<String>, countLimit: Int? = null): String =
                // File names are user content and may contain ':' / '@', so they are encoded and placed after the code
                DETAIL_PREFIX + java.util.Base64.getUrlEncoder().withoutPadding()
                    .encodeToString(fileNames.joinToString(NAME_SEPARATOR).toByteArray(Charsets.UTF_8)) +
                    (countLimit?.let { "$COUNT_SEPARATOR$it" } ?: "")
        }
    }
    /**
     * The number of this message's files delivered as text exceeds the current model's limit and nothing else is over a limit, so the whole message was not sent.
     * A local block like [AttachmentTextOverLimit]; kept separate because the way out is worded differently: this one says "at most N files".
     */
    data class AttachmentCountOverLimit(val maxFiles: Int) : ProviderServiceError() {
        companion object {
            const val CODE = "attachment_count_over_limit"
            private const val DETAIL_PREFIX = "$CODE:"

            /** Whether a persisted `errorDetail` is this kind of failure. */
            fun isDetail(detail: String?): Boolean = detail != null && detail.startsWith(DETAIL_PREFIX)

            /** Restores the count limit from the persisted safe code; null when it is not this failure or the number is damaged. */
            fun maxFilesFromDetail(detail: String?): Int? {
                if (detail == null || !detail.startsWith(DETAIL_PREFIX)) return null
                return detail.removePrefix(DETAIL_PREFIX).toIntOrNull()
            }

            internal fun detailFor(maxFiles: Int): String = DETAIL_PREFIX + maxFiles
        }
    }
    data class Network(val detail: String) : ProviderServiceError()
    data class Upstream(
        val statusCode: Int,
        val detail: String,
        /** Structured `/error/param` only; never inferred from message/detail text. */
        val rejectedParameter: String? = null,
        /** Set when thrown from an unclassified in-stream error frame; blocking or empty-result fallbacks do not count. This flag alone decides "retry without the additional request body"; message text is never compared. */
        val streamErrorFrame: Boolean = false,
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
            is LocalRequestRejected ->
                if (owner == ai.oriveo.community.core.provider.AdditionalRequestBody.OWNER) "Check the additional request body"
                else "Custom request fields"
            is AttachmentTextOverLimit, is AttachmentCountOverLimit -> "Attachment Not Accepted"
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
            is LocalRequestRejected -> "This message was not sent. Fix the custom request fields and try again."
            is AttachmentTextOverLimit ->
                (countLimit?.let { "You can attach up to $it files for this model.\n" } ?: "") +
                    "Not sent: with ${fileNames.joinToString(", ")}, the attached text is over this model's limit. Remove a file or switch models."
            is AttachmentCountOverLimit -> "You can attach up to $maxFiles files for this model."
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
            is LocalRequestRejected -> buildString {
                if (owner == ai.oriveo.community.core.provider.AdditionalRequestBody.OWNER) {
                    append("additional_body_rejected:").append(reason)
                    fieldName?.let { append(':').append(it) }
                } else {
                    append("custom_request_fields_rejected:").append(owner).append(':').append(reason)
                }
                line?.let { append('@').append(it) }
                if (allowedPaths.isNotEmpty()) {
                    // Paths are official declarations and may contain ':' or '@', so they are encoded and appended last
                    append("#allowed=").append(
                        java.util.Base64.getUrlEncoder().withoutPadding()
                            .encodeToString(allowedPaths.joinToString("\u001f").toByteArray(Charsets.UTF_8)),
                    )
                }
            }
            is AttachmentTextOverLimit -> AttachmentTextOverLimit.detailFor(fileNames, countLimit)
            is AttachmentCountOverLimit -> AttachmentCountOverLimit.detailFor(maxFiles)
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

        // Retired key stored by older versions. The mobile apps have no matching switch, so it renders
        // as the current guidance instead of exposing the raw key.
        private val LEGACY_KEYS = mapOf("codex_identity_enable_compat" to CodexIdentityStillRejected)

        fun fromPersistenceKey(raw: String?): RelayGuidanceCode? {
            val key = raw?.takeIf { it.startsWith(PERSISTENCE_PREFIX) }
                ?.removePrefix(PERSISTENCE_PREFIX)
                ?: return null
            return entries.firstOrNull { it.stableKey == key } ?: LEGACY_KEYS[key]
        }
    }
}
