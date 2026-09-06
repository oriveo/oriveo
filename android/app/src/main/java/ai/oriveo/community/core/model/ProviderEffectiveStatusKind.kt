package ai.oriveo.community.core.model

enum class ProviderEffectiveStatusKind {
    Connected,
    Syncing,
    Issue,
    NeedsKey,
    ;

    val isHealthy: Boolean
        get() = this == Connected || this == Syncing

    val isWarning: Boolean
        get() = this == Issue || this == NeedsKey
}

val Provider.effectiveStatusKind: ProviderEffectiveStatusKind
    get() {
        if (kind.allowsCredentialEditing && !RelayCredentialPolicy.hasStoredCredential(apiKey) &&
            (kind != ProviderKind.Relay || RelayCredentialPolicy.requiresCredential(relayRequested))
        ) {
            return ProviderEffectiveStatusKind.NeedsKey
        }
        return when (status) {
            is ProviderConnectionState.Connected -> ProviderEffectiveStatusKind.Connected
            is ProviderConnectionState.Syncing -> ProviderEffectiveStatusKind.Syncing
            is ProviderConnectionState.Issue -> ProviderEffectiveStatusKind.Issue
        }
    }
