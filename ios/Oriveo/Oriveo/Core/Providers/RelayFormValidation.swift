import Foundation

nonisolated enum RelayFormValidation {


    enum Field: String, Sendable, CaseIterable {
        case endpoint
        case securityMode = "security_mode"
        case apiKey = "api_key"
        case modelID = "model_id"
        case transport
        case authMode = "auth_mode"
        case headers
        case queryParams = "query_params"
    }

    enum Group: String, Sendable {
        case connection
        case wireProtocol = "protocol"
        case advancedHTTP = "advanced_http"
    }

    enum RevalidationTrigger: String, Sendable {
        case always
        case never
        case unlessWithinDiscoveredCatalog = "unless_within_discovered_catalog"
    }

    struct FieldDefinition: Sendable, Equatable {
        let field: Field
        let group: Group
        let labelKey: String?
        let placeholder: String?
        let revalidation: RevalidationTrigger
    }

    static let fields: [FieldDefinition] = [
        FieldDefinition(
            field: .endpoint,
            group: .connection,
            labelKey: "Request URL",
            placeholder: "https://api.example.com/v1",
            revalidation: .always
        ),
        FieldDefinition(
            field: .securityMode,
            group: .connection,
            labelKey: "Connection security",
            placeholder: nil,
            revalidation: .always
        ),
        FieldDefinition(
            field: .apiKey,
            group: .connection,
            labelKey: "API Key",
            placeholder: "sk-...",
            revalidation: .always
        ),
        FieldDefinition(
            field: .modelID,
            group: .connection,
            labelKey: "Model",
            placeholder: nil,
            revalidation: .unlessWithinDiscoveredCatalog
        ),
        FieldDefinition(
            field: .transport,
            group: .wireProtocol,
            labelKey: "Protocol",
            placeholder: nil,
            revalidation: .always
        ),
        FieldDefinition(
            field: .authMode,
            group: .wireProtocol,
            labelKey: "Authentication",
            placeholder: nil,
            revalidation: .always
        ),
        FieldDefinition(
            field: .headers,
            group: .advancedHTTP,
            labelKey: "Custom Headers",
            placeholder: "X-Internal-Token",
            revalidation: .always
        ),
        FieldDefinition(
            field: .queryParams,
            group: .advancedHTTP,
            labelKey: "Custom Query Params",
            placeholder: "tenant",
            revalidation: .always
        ),
    ]

    static func definition(for field: Field) -> FieldDefinition? {
        fields.first { $0.field == field }
    }


    enum IssueCode: String, Sendable {
        case endpointRequired = "endpoint_required"
        case endpointRejected = "endpoint_rejected"
        case cleartextCredentials = "cleartext_credentials"
        case securityModeSchemeMismatch = "security_mode_scheme_mismatch"
        case credentialRequired = "credential_required"
        case credentialInvalidCharacters = "credential_invalid_characters"

        var isSilentRequirement: Bool {
            self == .endpointRequired || self == .credentialRequired
        }

        var messageKey: String {
            switch self {
            case .endpointRequired:
                return "Enter a request URL."
            case .endpointRejected:
                return RelayEndpointPolicy.httpsRequiredMessageKey
            case .cleartextCredentials:
                return "An unencrypted connection can't carry a key."
            case .securityModeSchemeMismatch:
                return "This address doesn't match the connection method. Change the connection method to continue."
            case .credentialRequired:
                return "API Key required"
            case .credentialInvalidCharacters:
                return "API Key contains unsupported characters. Please re-paste - it likely picked up a full-width space, zero-width space, or non-ASCII character."
            }
        }

        var localizedMessage: String {
            switch self {
            case .endpointRejected: return L10n.tr(messageKey)
            default: return L10n.tr(messageKey, table: .providers)
            }
        }
    }

    struct FieldIssue: Equatable, Sendable {
        let field: Field
        let code: IssueCode
        let detail: String?

        init(field: Field, code: IssueCode, detail: String? = nil) {
            self.field = field
            self.code = code
            self.detail = detail
        }

        var messageKey: String { code.messageKey }
        var localizedMessage: String { code.localizedMessage }
    }


    static func validate(
        _ draft: RelayFormDraft,
        mode: RelayCredentialPolicy.FormMode
    ) -> [FieldIssue] {
        var issues: [FieldIssue] = []

        let trimmedEndpoint = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCredential = RelayCredentialPolicy.hasStoredKey(trimmedKey)
            || (mode == .edit && draft.hasSavedCredential)

        if trimmedEndpoint.isEmpty {
            issues.append(FieldIssue(field: .endpoint, code: .endpointRequired))
        } else {
            if hasSchemeModeMismatch(endpoint: trimmedEndpoint, securityMode: draft.securityMode) {
                issues.append(FieldIssue(field: .securityMode, code: .securityModeSchemeMismatch))
            }
            do {
                _ = try RelayEndpointPolicy.requireConfigured(
                    trimmedEndpoint,
                    securityMode: draft.securityMode,
                    credentials: RelayCredentialPolicy.endpointCredentials(
                        for: draft.requestedConfigForPolicy(),
                        hasStoredKey: hasCredential
                    )
                )
            } catch {
                let reason = Self.reason(from: error)
                if reason == "cleartext_credentials" {
                    issues.append(
                        FieldIssue(
                            field: cleartextOffendingField(draft, hasCredential: hasCredential),
                            code: .cleartextCredentials,
                            detail: reason
                        )
                    )
                } else {
                    issues.append(FieldIssue(field: .endpoint, code: .endpointRejected, detail: reason))
                }
            }
        }

        if RelayCredentialPolicy.credentialInputRequired(
            mode: mode,
            authMode: draft.authMode,
            hasStoredKey: hasCredential
        ) {
            issues.append(FieldIssue(field: .apiKey, code: .credentialRequired))
        }

        if !trimmedKey.isEmpty, !ProviderKeyInput.isPrintableASCII(trimmedKey) {
            issues.append(FieldIssue(field: .apiKey, code: .credentialInvalidCharacters))
        }

        return issues.sorted { lhs, rhs in
            let order = fields.map(\.field)
            let lhsIndex = order.firstIndex(of: lhs.field) ?? order.count
            let rhsIndex = order.firstIndex(of: rhs.field) ?? order.count
            return lhsIndex < rhsIndex
        }
    }

    static func normalizedEndpoint(
        _ draft: RelayFormDraft,
        mode: RelayCredentialPolicy.FormMode
    ) -> String? {
        guard validate(draft, mode: mode).isEmpty else { return nil }
        let trimmedEndpoint = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCredential = RelayCredentialPolicy.hasStoredKey(draft.apiKey)
            || (mode == .edit && draft.hasSavedCredential)
        return try? RelayEndpointPolicy.requireConfigured(
            trimmedEndpoint,
            securityMode: draft.securityMode,
            credentials: RelayCredentialPolicy.endpointCredentials(
                for: draft.requestedConfigForPolicy(),
                hasStoredKey: hasCredential
            )
        )
    }

    static func displayableIssues(_ issues: [FieldIssue]) -> [FieldIssue] {
        issues.filter { !$0.code.isSilentRequirement }
    }


    private static func hasSchemeModeMismatch(
        endpoint: String,
        securityMode: RelayConnectionSecurityMode
    ) -> Bool {
        guard securityMode == .localHTTP || securityMode == .privateVPN else { return false }
        return endpoint.lowercased().hasPrefix("https://")
    }

    private static func cleartextOffendingField(
        _ draft: RelayFormDraft,
        hasCredential: Bool
    ) -> Field {
        if RelayCredentialPolicy.requiresCredential(authMode: draft.authMode) || hasCredential {
            return .apiKey
        }
        if draft.headers.contains(where: { RelayRequestSecurity.isSensitiveName($0.key) }) {
            return .headers
        }
        return .queryParams
    }

    private static func reason(from error: Error) -> String {
        guard case ProviderServiceError.invalidConfiguration(let detail) = error else {
            return "invalid_url"
        }
        return detail
    }
}

nonisolated enum RelaySecurityModeSelection {
    static let selectableModes: [RelayConnectionSecurityMode] = [
        .remoteHTTPS,
        .localHTTP,
        .privateVPN,
    ]

    struct Assessment: Equatable, Sendable {
        let localHTTPAllowed: Bool
        let privateVPNAllowed: Bool
        let suggestedMode: RelayConnectionSecurityMode?
        let denialReason: String?
    }

    struct PersistedTransition: Equatable, Sendable {
        let requested: RelayRequestedConfig
        let clearsStoredAPIKey: Bool
        let clearsCredentialTables: Bool
    }

    struct EndpointWriteback: Equatable, Sendable {
        let endpoint: String
        let didChange: Bool
    }

    static func assess(endpoint raw: String) async -> Assessment {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Assessment(
                localHTTPAllowed: false,
                privateVPNAllowed: false,
                suggestedMode: nil,
                denialReason: "invalid_url"
            )
        }
        if trimmed.lowercased().hasPrefix("https://") {
            return Assessment(
                localHTTPAllowed: false,
                privateVPNAllowed: false,
                suggestedMode: nil,
                denialReason: "encrypted_endpoint"
            )
        }

        async let localResult = RelayRequestSecurity.classifyForModeSelection(
            trimmed,
            mode: .localHTTP
        )
        async let vpnResult = RelayRequestSecurity.classifyForModeSelection(
            trimmed,
            mode: .privateVPN
        )
        let (local, vpn) = await (localResult, vpnResult)
        let localAllowed = local.allowed
            && ["loopback", "private_lan", "link_local"].contains(local.reason)
        let vpnAllowed = vpn.allowed
        let hasExplicitHTTP = trimmed.lowercased().hasPrefix("http://")
        let hasScheme = trimmed.range(
            of: #"^[a-zA-Z][a-zA-Z0-9+\-.]*://"#,
            options: .regularExpression
        ) != nil
        let suggestion: RelayConnectionSecurityMode?
        if vpn.allowed, vpn.reason == "private_vpn", hasExplicitHTTP || !hasScheme {
            suggestion = .privateVPN
        } else if localAllowed, hasExplicitHTTP || !hasScheme {
            suggestion = .localHTTP
        } else {
            suggestion = nil
        }
        return Assessment(
            localHTTPAllowed: localAllowed,
            privateVPNAllowed: vpnAllowed,
            suggestedMode: suggestion,
            denialReason: localAllowed || vpnAllowed ? nil : (local.reason == "allowed" ? vpn.reason : local.reason)
        )
    }

    static func normalizedEndpoint(
        _ raw: String,
        securityMode: RelayConnectionSecurityMode
    ) -> String? {
        try? RelayEndpointPolicy.requireConfigured(
            raw,
            securityMode: securityMode,
            credentials: .init(authMode: .none)
        )
    }

    static func endpointWriteback(
        _ raw: String,
        securityMode: RelayConnectionSecurityMode
    ) -> EndpointWriteback? {
        guard let normalized = normalizedEndpoint(raw, securityMode: securityMode) else { return nil }
        return EndpointWriteback(
            endpoint: normalized,
            didChange: normalized != raw
        )
    }

    static func allowsReconnectPersistence(
        expectedGeneration: Int,
        currentGeneration: Int,
        expectedMode: RelayConnectionSecurityMode,
        currentRequested: RelayRequestedConfig?
    ) -> Bool {
        expectedGeneration == currentGeneration
            && currentRequested?.securityMode == expectedMode
    }

    static func hasCredentialMaterial(
        apiKey: String,
        authMode: RelayAuthMode,
        headers: [RelayKeyValue],
        queryParams: [RelayKeyValue]
    ) -> Bool {
        RelayCredentialPolicy.requiresCredential(authMode: authMode)
            || RelayCredentialPolicy.hasStoredKey(apiKey)
            || headers.contains(where: { RelayRequestSecurity.isSensitiveName($0.key) })
            || queryParams.contains(where: { RelayRequestSecurity.isSensitiveName($0.key) })
    }

    static func hasCredentialMaterial(
        savedRequested: RelayRequestedConfig?,
        storedAPIKey: String,
        draftAuthMode: RelayAuthMode,
        draftHeaders: [RelayKeyValue],
        draftQueryParams: [RelayKeyValue]
    ) -> Bool {
        let saved = savedRequested ?? RelayRequestedConfig()
        return hasCredentialMaterial(
            apiKey: storedAPIKey,
            authMode: saved.authMode,
            headers: saved.headers ?? [],
            queryParams: saved.queryParams ?? []
        ) || hasCredentialMaterial(
            apiKey: "",
            authMode: draftAuthMode,
            headers: draftHeaders,
            queryParams: draftQueryParams
        )
    }

    static func persistedTransition(
        savedRequested: RelayRequestedConfig?,
        storedAPIKey: String,
        draftAuthMode: RelayAuthMode,
        draftHeaders: [RelayKeyValue],
        draftQueryParams: [RelayKeyValue],
        nextMode: RelayConnectionSecurityMode
    ) -> PersistedTransition {
        var requested = savedRequested ?? RelayRequestedConfig()
        let hasMaterial = hasCredentialMaterial(
            savedRequested: savedRequested,
            storedAPIKey: storedAPIKey,
            draftAuthMode: draftAuthMode,
            draftHeaders: draftHeaders,
            draftQueryParams: draftQueryParams
        )
        let weakMode = nextMode == .localHTTP || nextMode == .privateVPN
        let clearsCredentialMaterial = weakMode && hasMaterial

        requested.securityMode = nextMode
        requested.resolvedAPIBaseURL = nil
        if weakMode {
            requested.authMode = .none
            if clearsCredentialMaterial {
                requested.headers = nil
                requested.queryParams = nil
            }
        }

        return PersistedTransition(
            requested: requested,
            clearsStoredAPIKey: clearsCredentialMaterial,
            clearsCredentialTables: clearsCredentialMaterial
        )
    }
}

nonisolated struct RelayFormDraft: Equatable, Sendable {
    var endpoint: String
    var apiKey: String
    var authMode: RelayAuthMode
    var securityMode: RelayConnectionSecurityMode
    var transport: RelayTransport
    var modelID: String
    var headers: [RelayKeyValue]
    var queryParams: [RelayKeyValue]
    var hasSavedCredential: Bool

    init(
        endpoint: String = "",
        apiKey: String = "",
        authMode: RelayAuthMode = .auto,
        securityMode: RelayConnectionSecurityMode = .remoteHTTPS,
        transport: RelayTransport = .auto,
        modelID: String = "",
        headers: [RelayKeyValue] = [],
        queryParams: [RelayKeyValue] = [],
        hasSavedCredential: Bool = false
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.authMode = authMode
        self.securityMode = securityMode
        self.transport = transport
        self.modelID = modelID
        self.headers = headers
        self.queryParams = queryParams
        self.hasSavedCredential = hasSavedCredential
    }

    init(
        requested: RelayRequestedConfig?,
        endpoint: String,
        apiKey: String = "",
        hasSavedCredential: Bool = false
    ) {
        self.init(
            endpoint: endpoint,
            apiKey: apiKey,
            authMode: requested?.authMode ?? .auto,
            securityMode: requested?.securityMode ?? .remoteHTTPS,
            transport: requested?.transport ?? .auto,
            modelID: requested?.modelID ?? "",
            headers: requested?.headers ?? [],
            queryParams: requested?.queryParams ?? [],
            hasSavedCredential: hasSavedCredential
        )
    }

    func requestedConfigForPolicy() -> RelayRequestedConfig {
        RelayRequestedConfig(
            transport: transport,
            authMode: authMode,
            securityMode: securityMode,
            headers: headers.isEmpty ? nil : headers,
            queryParams: queryParams.isEmpty ? nil : queryParams
        )
    }
}
