import Foundation

nonisolated enum RelayCredentialPolicy {

    enum State: String, Sendable {
        case notRequired
        case missing
        case present
        case conflict
    }

    enum EditAction: Sendable {
        case none
        case rotate
        case removeResidual
    }

    static func requiresCredential(authMode: RelayAuthMode?) -> Bool {
        (authMode ?? .auto) != RelayAuthMode.none
    }

    static func requiresCredential(_ requested: RelayRequestedConfig?) -> Bool {
        requiresCredential(authMode: requested?.authMode)
    }

    static func isCleartext(_ securityMode: RelayConnectionSecurityMode?) -> Bool {
        securityMode == .localHTTP || securityMode == .privateVPN
    }

    static func hasStoredKey(_ storedKey: String?) -> Bool {
        guard let storedKey else { return false }
        return !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func editAction(authMode: RelayAuthMode?, hasStoredKey: Bool) -> EditAction {
        guard !requiresCredential(authMode: authMode) else { return .rotate }
        return hasStoredKey ? .removeResidual : .none
    }

    static func state(
        authMode: RelayAuthMode?,
        hasStoredKey: Bool,
        securityMode: RelayConnectionSecurityMode?,
        hasSensitiveMaterial: Bool = false
    ) -> State {
        let requires = requiresCredential(authMode: authMode)
        if isCleartext(securityMode), requires || hasStoredKey || hasSensitiveMaterial {
            return .conflict
        }
        guard requires else { return .notRequired }
        return hasStoredKey ? .present : .missing
    }

    static func state(
        _ requested: RelayRequestedConfig?,
        hasStoredKey: Bool
    ) -> State {
        let sensitive = (requested?.headers?.contains { RelayRequestSecurity.isSensitiveName($0.key) } ?? false)
            || (requested?.queryParams?.contains { RelayRequestSecurity.isSensitiveName($0.key) } ?? false)
        return state(
            authMode: requested?.authMode,
            hasStoredKey: hasStoredKey,
            securityMode: requested?.securityMode,
            hasSensitiveMaterial: sensitive
        )
    }


    enum FormMode: Sendable {
        case create
        case edit
    }

    static func credentialInputRequired(
        mode: FormMode,
        authMode: RelayAuthMode?,
        hasStoredKey: Bool
    ) -> Bool {
        switch mode {
        case .create: return requiresCredential(authMode: authMode) && !hasStoredKey
        case .edit: return false
        }
    }


    struct Mutation: Equatable, Sendable {
        var authMode: RelayAuthMode
        var clearsStoredKey: Bool
    }

    static func removeCredential(currentAuthMode: RelayAuthMode?) -> Mutation {
        Mutation(authMode: currentAuthMode ?? .auto, clearsStoredKey: true)
    }

    static func setAuthMode(_ next: RelayAuthMode, hasStoredKey: Bool) -> Mutation {
        Mutation(authMode: next, clearsStoredKey: next == RelayAuthMode.none && hasStoredKey)
    }


    static func endpointCredentials(
        for requested: RelayRequestedConfig?,
        hasStoredKey: Bool
    ) -> RelayEndpointPolicy.Credentials {
        RelayEndpointPolicy.Credentials(
            authMode: requested?.authMode,
            hasKey: hasStoredKey,
            sensitiveHeaders: (requested?.headers ?? [])
                .map(\.key)
                .filter(RelayRequestSecurity.isSensitiveName),
            sensitiveQueryKeys: (requested?.queryParams ?? [])
                .map(\.key)
                .filter(RelayRequestSecurity.isSensitiveName)
        )
    }
}

nonisolated enum APIKeyMask {
    static let fullyMasked = "••••••••"
    static let separator = "…"

    static func masked(_ apiKey: String) -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.count > 12 else { return fullyMasked }
        return "\(trimmed.prefix(4))\(separator)\(trimmed.suffix(4))"
    }
}
