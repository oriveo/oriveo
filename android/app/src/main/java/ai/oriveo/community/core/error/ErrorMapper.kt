package ai.oriveo.community.core.error

import android.content.Context
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.GrokSubscriptionFailureReason
import ai.oriveo.community.core.model.OpenAISubscriptionFailureReason
import ai.oriveo.community.core.model.OriveoError
import ai.oriveo.community.core.model.OriveoErrorSeverity
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayGuidanceCode

import ai.oriveo.community.core.provider.RelayEndpointPolicy

/**
 * Turns a provider failure into something a person can act on: a title, a message, and one
 * suggested action, all localized.
 */
object ErrorMapper {

    fun map(error: ProviderServiceError, context: Context): OriveoError = OriveoError(
        title = localizeProviderErrorTitle(error.title, context),
        message = localizeProviderErrorMessage(error, context),
        actionTitle = actionTitle(error, context),
        detail = error.technicalDetail,
        severity = severity(error),
    )

    fun map(exception: Exception, context: Context): OriveoError = when (exception) {
        is ProviderServiceError -> map(exception, context)
        else -> OriveoError(
            title = context.getString(R.string.error_generic_title),
            message = exception.message ?: context.getString(R.string.error_generic_message),
            actionTitle = context.getString(R.string.retry),
            detail = exception.stackTraceToString().take(500),
            severity = OriveoErrorSeverity.Warning,
        )
    }

    /** The one action most likely to get the user unstuck, shown on the error itself. */
    private fun actionTitle(error: ProviderServiceError, context: Context): String = when (error) {
        is ProviderServiceError.InvalidAPIKey -> context.getString(R.string.change_api_key)
        is ProviderServiceError.QuotaExceeded -> context.getString(R.string.switch_model)
        is ProviderServiceError.ModelUnavailable -> context.getString(R.string.switch_model)
        is ProviderServiceError.RateLimited -> context.getString(R.string.retry)
        is ProviderServiceError.EmptyModelCatalog -> context.getString(R.string.retry)
        is ProviderServiceError.EmptyResponse -> context.getString(R.string.retry)
        is ProviderServiceError.InvalidConfiguration -> context.getString(R.string.fix_now)
        is ProviderServiceError.Network -> context.getString(R.string.retry)
        is ProviderServiceError.Upstream -> context.getString(R.string.switch_model)
        is ProviderServiceError.RelayUpstream -> context.getString(R.string.fix_now)
        is ProviderServiceError.GrokSubscription -> context.getString(R.string.fix_now)
        is ProviderServiceError.OpenAISubscription -> context.getString(R.string.fix_now)
    }

    /**
     * Critical means the user has to change a setting before anything will work again; everything
     * else is worth retrying as it stands.
     */
    private fun severity(error: ProviderServiceError): OriveoErrorSeverity = when (error) {
        is ProviderServiceError.InvalidAPIKey -> OriveoErrorSeverity.Critical
        is ProviderServiceError.InvalidConfiguration -> OriveoErrorSeverity.Critical
        else -> OriveoErrorSeverity.Warning
    }

    /**
     * Maps a stored English message back to a translated string.
     *
     * A connection's last error is persisted as the English text, because the row outlives the
     * process that produced it and the user can change language in between. Looking the text back
     * up here means the message is translated when it is read, not when it was written.
     */
    private val MESSAGE_TO_RES: Map<String, Int> = mapOf(
        "API Key required" to R.string.error_api_key_required,
        "The API key could not be validated. Check the value or generate a new key." to R.string.error_invalid_api_key_message,
        "The provider reports that the quota or credit for this API key is used up. Check your billing with the provider, or switch models." to R.string.error_provider_quota_exceeded_message,
        "This model is currently unavailable from the provider. Switch models or try again later." to R.string.error_model_unavailable_message,
        "The provider is temporarily rate limiting this request. Please wait a moment and try again." to R.string.error_rate_limited_message,
        "The provider returned an empty model catalog, so we could not finish setup." to R.string.error_no_models_message,
        "The provider returned no assistant content for this message." to R.string.error_empty_response_message,
        "The selected provider configuration is incomplete, so the request could not be sent." to R.string.error_config_message,
        RelayEndpointPolicy.HTTPS_REQUIRED_MESSAGE to R.string.relay_setup_invalid_endpoint_message,
        "The request did not complete successfully. Please check your network and try again." to R.string.error_network_message,
        "The provider returned an error for this request. Please retry or switch models." to R.string.error_upstream_message,
        "We couldn't verify the connection. You can retry from the provider details." to R.string.provider_connection_unverified,
        "Connection has not been verified." to R.string.provider_connection_unverified,
        "relay_connection_unverified" to R.string.provider_connection_unverified,
        "relay_image_route_unsupported" to R.string.relay_image_route_unsupported,
        "relay_image_chat_model_required" to R.string.relay_image_chat_model_required,
        GrokSubscriptionFailureReason.ClientVersionRejected.userMessage to
            R.string.grok_subscription_error_unavailable,
        GrokSubscriptionFailureReason.NotEligible.userMessage to
            R.string.grok_subscription_error_not_eligible,
        GrokSubscriptionFailureReason.Expired.userMessage to
            R.string.grok_subscription_error_expired,
        GrokSubscriptionFailureReason.QuotaExhausted.userMessage to
            R.string.grok_subscription_error_quota,
        ProviderRepository.SUBSCRIPTION_CATALOG_UNAVAILABLE_MESSAGE to
            R.string.provider_catalog_unavailable,
        OpenAISubscriptionFailureReason.Unavailable.userMessage to
            R.string.openai_subscription_error_unavailable,
        OpenAISubscriptionFailureReason.NotEligible.userMessage to
            R.string.openai_subscription_error_not_eligible,
        OpenAISubscriptionFailureReason.Expired.userMessage to
            R.string.openai_subscription_error_expired,
        OpenAISubscriptionFailureReason.QuotaExhausted.userMessage to
            R.string.openai_subscription_error_quota,
        ProviderRepository.CODEX_CATALOG_UNAVAILABLE_MESSAGE to
            R.string.openai_subscription_catalog_unavailable,
    )

    private fun relayGuidanceResource(code: RelayGuidanceCode): Int = when (code) {
        RelayGuidanceCode.CodexIdentitySwitchType -> R.string.relay_guidance_codex_identity_switch_type
        RelayGuidanceCode.CodexIdentityEnableCompat -> R.string.relay_guidance_codex_identity_enable_compat
        RelayGuidanceCode.CodexIdentityStillRejected -> R.string.relay_guidance_codex_identity_still_rejected
        RelayGuidanceCode.ResponsesOnlyEndpoint -> R.string.relay_guidance_responses_only_endpoint
        RelayGuidanceCode.UpstreamUnreachable -> R.string.relay_guidance_upstream_unreachable
        RelayGuidanceCode.ModelNotOffered -> R.string.relay_guidance_model_not_offered
        RelayGuidanceCode.ResponsesProtocolRequired -> R.string.relay_guidance_responses_protocol_required
        RelayGuidanceCode.StoreParamRejected -> R.string.relay_guidance_store_param_rejected
        RelayGuidanceCode.ServiceTierInvalid -> R.string.relay_guidance_service_tier_invalid
        RelayGuidanceCode.MaxTokensRequired -> R.string.relay_guidance_max_tokens_required
        RelayGuidanceCode.AnthropicAuthHeader -> R.string.relay_guidance_anthropic_auth_header
        RelayGuidanceCode.ImageSchemaMismatch -> R.string.relay_guidance_image_schema_mismatch
        RelayGuidanceCode.RateLimited -> R.string.relay_guidance_rate_limited
    }

    private fun localizeRelayGuidance(
        error: ProviderServiceError.RelayUpstream,
        context: Context,
    ): String {
        val resId = error.guidanceCode?.let(::relayGuidanceResource)
            ?: return localizeProviderErrorMessage(error.guidance, context)
        return context.getString(resId)
    }

    /** Relay failures carry their own guidance text; everything else uses its user message. */
    fun localizeProviderErrorMessage(error: ProviderServiceError, context: Context): String =
        if (error is ProviderServiceError.RelayUpstream) {
            localizeRelayGuidance(error, context)
        } else {
            localizeProviderErrorMessage(error.userMessage, context)
        }

    fun localizeProviderErrorMessage(rawMessage: String, context: Context): String {
        RelayGuidanceCode.fromPersistenceKey(rawMessage)?.let { code ->
            return context.getString(relayGuidanceResource(code))
        }
        val resId = MESSAGE_TO_RES[rawMessage] ?: return rawMessage
        return context.getString(resId)
    }

    fun hasLocalizedProviderMessage(rawMessage: String?): Boolean =
        rawMessage != null && (
            RelayGuidanceCode.fromPersistenceKey(rawMessage) != null ||
                MESSAGE_TO_RES.containsKey(rawMessage)
            )

    /** The title counterpart to [MESSAGE_TO_RES], for the same reason. */
    private val TITLE_TO_RES: Map<String, Int> = mapOf(
        "Invalid API Key" to R.string.error_invalid_api_key,
        "Provider Quota Reached" to R.string.error_provider_quota_exceeded,
        "Model Unavailable" to R.string.error_model_unavailable,
        "Provider Rate Limited" to R.string.error_rate_limited,
        "No Models Found" to R.string.error_no_models,
        "Empty Provider Response" to R.string.error_empty_response,
        "Provider Configuration Error" to R.string.error_config,
        "Provider Request Failed" to R.string.error_request_failed,
        "Request Failed" to R.string.message_failed,
        "Grok subscription" to R.string.grok_subscription_title,
        "ChatGPT subscription" to R.string.openai_subscription_title,
    )

    /** RelayUpstream titles carry the status code, so they are matched rather than looked up. */
    private val RELAY_TITLE_REGEX = Regex("""^Relay Error \((\d+)\)$""")

    fun localizeProviderErrorTitle(rawTitle: String, context: Context): String {
        TITLE_TO_RES[rawTitle]?.let { return context.getString(it) }
        RELAY_TITLE_REGEX.matchEntire(rawTitle)?.let { match ->
            val code = match.groupValues[1].toIntOrNull() ?: return rawTitle
            return context.getString(R.string.error_relay_upstream_title, code)
        }
        return rawTitle
    }
}
