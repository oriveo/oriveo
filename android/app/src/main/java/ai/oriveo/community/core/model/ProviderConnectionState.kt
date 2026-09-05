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
    data class Issue(val message: String) : ProviderConnectionState()

    
    val title: String
        get() = when (this) {
            is Connected -> "Connected"
            is Syncing -> "Syncing"
            is Issue -> "Issue"
        }
}
