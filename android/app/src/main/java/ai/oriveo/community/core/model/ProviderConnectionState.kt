package ai.oriveo.community.core.model

import androidx.compose.runtime.Immutable
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Immutable
@Serializable
sealed class ProviderConnectionState {

    @Immutable
    @Serializable
    @SerialName("connected")
    data object Connected : ProviderConnectionState()

    @Immutable
    @Serializable
    @SerialName("syncing")
    data object Syncing : ProviderConnectionState()

    @Immutable
    @Serializable
    @SerialName("issue")
    data class Issue(
        val message: String,
        /** Typed reason: the new-chat "unavailable connection" check reads only this, never the [message] text. */
        val reason: ProviderIssueReason = ProviderIssueReason.Error,
    ) : ProviderConnectionState() {
        companion object {
            /** Missing credential: a subscription connection is signed out, any other is missing a key; the text is mapped from the reason. */
            fun missingCredential(authMode: ProviderAuthMode): Issue = if (authMode == ProviderAuthMode.Subscription) {
                Issue(SIGN_IN_REQUIRED_MESSAGE, ProviderIssueReason.SignInRequired)
            } else {
                Issue(API_KEY_REQUIRED_MESSAGE, ProviderIssueReason.MissingCredential)
            }

            const val API_KEY_REQUIRED_MESSAGE = "API Key required"
            const val SIGN_IN_REQUIRED_MESSAGE = "Sign in required"
        }
    }

    val title: String
        get() = when (this) {
            is Connected -> "Connected"
            is Syncing -> "Syncing"
            is Issue -> "Issue"
        }
}

/** Reason behind a [ProviderConnectionState.Issue]. A missing key and being signed out both count as a missing credential; any other error is [Error]. */
@Serializable
enum class ProviderIssueReason {
    @SerialName("missingCredential") MissingCredential,
    @SerialName("signInRequired") SignInRequired,
    @SerialName("error") Error,
    ;

    val isMissingCredential: Boolean
        get() = this == MissingCredential || this == SignInRequired
}
