package ai.oriveo.community.core.data.repository.streaming

import ai.oriveo.community.core.model.GrokSubscriptionFailureReason
import ai.oriveo.community.core.model.OpenAISubscriptionFailureReason
import ai.oriveo.community.core.model.ProviderServiceError

/**
 * The `errorDetail` stored on a failed message.
 *
 * Subscription failures store [ProviderServiceError.userMessage] rather than the technical detail.
 * The failure card looks the stored text up with `ErrorMapper.hasLocalizedProviderMessage` and
 * only shows the sentence written for the user when that lookup hits. The technical detail never
 * hits, so the card would fall back to its generic body and the only specific text left would be
 * the upstream's own wording in the collapsed section. For a rejected Grok client version that is
 * an instruction to run `grok update`, which someone using the app has no CLI to follow.
 * Transport failures already store their user message for the same reason.
 */
internal fun failedMessageDetail(error: ProviderServiceError): String = when (error) {
    is ProviderServiceError.GrokSubscription,
    is ProviderServiceError.OpenAISubscription,
    -> error.userMessage
    else -> error.technicalDetail
}

/** Whether a stored `errorDetail` is a subscription failure (every reason of both providers). */
internal fun isSubscriptionFailureDetail(errorDetail: String?): Boolean =
    errorDetail != null && errorDetail in SUBSCRIPTION_FAILURE_MESSAGES

private val SUBSCRIPTION_FAILURE_MESSAGES: Set<String> =
    GrokSubscriptionFailureReason.entries.map { it.userMessage }.toSet() +
        OpenAISubscriptionFailureReason.entries.map { it.userMessage }

/**
 * The upstream refused the request because the client version is too old (HTTP 426): the version
 * header from the catalog is below what the upstream currently accepts.
 */
internal fun ProviderServiceError.isSubscriptionClientVersionRejection(): Boolean = when (this) {
    is ProviderServiceError.GrokSubscription -> reason == GrokSubscriptionFailureReason.ClientVersionRejected
    is ProviderServiceError.OpenAISubscription -> reason == OpenAISubscriptionFailureReason.Unavailable
    else -> false
}
