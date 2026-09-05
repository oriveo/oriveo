import Foundation

enum GrokSubscriptionRuntime {
    struct Prepared: Sendable, Equatable {
        let accessToken: String
        let context: GrokSubscriptionRequestContext
        let didRefresh: Bool
    }

    static func prepare(
        providerID: UUID,
        uid: String = AppSessionStore.activeUID,
        availability: GrokSubscriptionAvailability? = nil,
        client: GrokSubscriptionOAuthClient = GrokSubscriptionOAuthClient(),
        now: Date = Date()
    ) async -> Result<Prepared, GrokSubscriptionError> {
        let resolvedAvailability = availability ?? MetadataClient.shared.syncGrokSubscriptionAvailability()
        guard case let .available(config) = resolvedAvailability else {
            return .failure(.configurationUnavailable)
        }

        guard let stored = GrokSubscriptionCredentialStore.load(providerID: providerID, uid: uid) else {
            return .failure(.unauthorized)
        }

        guard let chatURL = config.chatURL else {
            return .failure(.configurationUnavailable)
        }
        let context = GrokSubscriptionRequestContext(
            chatURL: chatURL,
            responsesURL: config.responsesURL,
            requiredHeaders: config.requiredHeaders,
            transport: (GrokSubscriptionAuthConfig.transportKind(apiBackend: config.apiBackend) ?? .openaiChat).rawValue
        )

        guard stored.needsRefresh(now: now) else {
            return .success(Prepared(accessToken: stored.accessToken, context: context, didRefresh: false))
        }

        guard let refreshToken = stored.refreshToken else {
            return .failure(.unauthorized)
        }

        do {
            let refreshed = try await client.refreshTokens(config: config, refreshToken: refreshToken)
            GrokSubscriptionCredentialStore.save(refreshed, providerID: providerID, uid: uid)
            return .success(Prepared(accessToken: refreshed.accessToken, context: context, didRefresh: true))
        } catch {
            if let expiresAt = stored.expiresAt, now < expiresAt {
                return .success(Prepared(accessToken: stored.accessToken, context: context, didRefresh: false))
            }
            return .failure(.unauthorized)
        }
    }

    static func persist(tokens: GrokSubscriptionTokens, providerID: UUID, uid: String = AppSessionStore.activeUID) {
        GrokSubscriptionCredentialStore.save(tokens, providerID: providerID, uid: uid)
    }

    static func disconnect(
        providerID: UUID,
        uid: String = AppSessionStore.activeUID,
        client: GrokSubscriptionOAuthClient = GrokSubscriptionOAuthClient()
    ) async {
        if case let .available(config) = MetadataClient.shared.syncGrokSubscriptionAvailability(),
           let stored = GrokSubscriptionCredentialStore.load(providerID: providerID, uid: uid) {
            await client.revoke(config: config, token: stored.accessToken)
        }
        GrokSubscriptionCredentialStore.delete(providerID: providerID, uid: uid)
    }
}

extension GrokSubscriptionError {
    var userFacingMessage: String { L10n.tr(userFacingMessageKey, table: .providers) }

    var userFacingMessageKey: String {
        switch self {
        case .clientVersionRejected, .configurationUnavailable:
            return "Grok subscription sign-in is temporarily unavailable while we update it. You can connect with an API key instead."
        case .subscriptionNotEligible:
            return "Your xAI account's current plan doesn't allow using the Grok subscription in third-party apps."
        case .unauthorized:
            return "Your Grok sign-in has expired. Please authorize again."
        case .quotaExhausted:
            return "You've used up this period's Grok subscription quota. It will resume after the next reset."
        case .codeExpired:
            return "The authorization code expired. Please start again."
        case .accessDenied:
            return "Authorization was declined."
        case .authorizationPending, .slowDown:
            return "Waiting for authorization in your browser…"
        case .transport, .upstream:
            return "Couldn't reach Grok. Check your connection and try again."
        }
    }


    var requiresConfigRefresh: Bool {
        self == .clientVersionRejected
    }
}
