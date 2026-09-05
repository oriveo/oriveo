import Foundation

enum OpenAISubscriptionRuntime {
    struct Prepared: Sendable, Equatable {
        let accessToken: String
        let context: OpenAISubscriptionRequestContext
        let didRefresh: Bool
    }

    static func prepare(
        providerID: UUID,
        uid: String = AppSessionStore.activeUID,
        availability: OpenAISubscriptionAvailability? = nil,
        client: OpenAISubscriptionOAuthClient = OpenAISubscriptionOAuthClient(),
        now: Date = Date()
    ) async -> Result<Prepared, OpenAISubscriptionError> {
        let resolvedAvailability = availability ?? MetadataClient.shared.syncOpenAISubscriptionAvailability()
        guard case let .available(config) = resolvedAvailability else {
            return .failure(.configurationUnavailable)
        }

        guard let stored = OpenAISubscriptionCredentialStore.load(providerID: providerID, uid: uid) else {
            return .failure(.unauthorized)
        }

        guard let responsesURL = config.responsesURL else {
            return .failure(.configurationUnavailable)
        }
        let context = OpenAISubscriptionRequestContext(
            responsesURL: responsesURL,
            accountID: stored.accountID,
            requiredHeaders: config.requiredHeaders
        )

        guard stored.needsRefresh(now: now) else {
            return .success(Prepared(accessToken: stored.accessToken, context: context, didRefresh: false))
        }

        guard let refreshToken = stored.refreshToken else {
            return .failure(.unauthorized)
        }

        do {
            let refreshed = try await client.refreshTokens(
                config: config,
                refreshToken: refreshToken,
                previous: stored
            )
            OpenAISubscriptionCredentialStore.save(refreshed, providerID: providerID, uid: uid)
            let refreshedContext = OpenAISubscriptionRequestContext(
                responsesURL: responsesURL,
                accountID: refreshed.accountID,
                requiredHeaders: config.requiredHeaders
            )
            return .success(Prepared(accessToken: refreshed.accessToken, context: refreshedContext, didRefresh: true))
        } catch {
            if let expiresAt = stored.expiresAt, now < expiresAt {
                return .success(Prepared(accessToken: stored.accessToken, context: context, didRefresh: false))
            }
            return .failure(.unauthorized)
        }
    }

    static func persist(tokens: OpenAISubscriptionTokens, providerID: UUID, uid: String = AppSessionStore.activeUID) {
        OpenAISubscriptionCredentialStore.save(tokens, providerID: providerID, uid: uid)
    }

    static func disconnect(
        providerID: UUID,
        uid: String = AppSessionStore.activeUID
    ) {
        OpenAISubscriptionCredentialStore.delete(providerID: providerID, uid: uid)
    }
}
