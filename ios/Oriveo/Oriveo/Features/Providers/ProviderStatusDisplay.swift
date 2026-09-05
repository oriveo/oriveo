import Foundation

enum ProviderEffectiveStatusKind {
    case connected
    case syncing
    case issue
    case needsKey

    var isHealthy: Bool {
        self == .connected || self == .syncing
    }

    var isWarning: Bool {
        self == .issue || self == .needsKey
    }
}

extension Provider {
    var effectiveStatusKind: ProviderEffectiveStatusKind {
        if apiKey.isEmpty
            && RelayCredentialPolicy.requiresCredential(relayRequested) {
            return .needsKey
        }
        switch status {
        case .connected: return .connected
        case .syncing: return .syncing
        case .issue: return .issue
        }
    }

    var effectiveStatusTitle: String {
        switch effectiveStatusKind {
        case .needsKey: return L10n.tr("Needs API Key", table: .providers)
        case .connected, .syncing, .issue: return status.title
        }
    }
}

enum ProviderIssueMessage {
    static let unverifiedConnectionKey = "Connection has not been verified."
    static let catalogUnavailableKey = "Couldn't load the model list"

    static let subscriptionMessageKeys: Set<String> = {
        let grok: [GrokSubscriptionError] = [
            .clientVersionRejected, .subscriptionNotEligible, .unauthorized, .quotaExhausted,
        ]
        let codex: [OpenAISubscriptionError] = [
            .clientVersionRejected, .subscriptionNotEligible, .unauthorized, .quotaExhausted,
        ]
        return Set(grok.map(\.userFacingMessageKey) + codex.map(\.userFacingMessageKey))
    }()

    static func localized(_ messageKey: String) -> String {
        let usesProvidersTable = messageKey == unverifiedConnectionKey
            || messageKey == catalogUnavailableKey
            || subscriptionMessageKeys.contains(messageKey)
        return usesProvidersTable ? L10n.tr(messageKey, table: .providers) : L10n.tr(messageKey)
    }
}
