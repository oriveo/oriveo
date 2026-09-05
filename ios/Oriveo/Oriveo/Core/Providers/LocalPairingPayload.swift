import Foundation

nonisolated struct LocalPairingCandidate: Equatable, Sendable {
    let endpoint: String
    let securityMode: RelayConnectionSecurityMode
}

nonisolated struct LocalPairingPayload: Equatable, Sendable {
    private static let maximumEncodedBytes = 16 * 1_024
    private static let maximumDecodedBytes = 12 * 1_024
    private static let maximumEndpointBytes = 2_048
    private static let maximumNameCharacters = 128
    private static let maximumCandidates = 8
    private static let jsonFields: Set<String> = ["v", "name", "urls", "engine", "auth", "fingerprint"]
    private static let uriFields: Set<String> = ["v", "name", "endpoint", "engine", "auth", "mode"]

    let engine: LocalEngineKind
    let candidates: [LocalPairingCandidate]
    let authMode: RelayAuthMode
    let name: String?
    let fingerprint: String?

    var endpoint: String { candidates[0].endpoint }
    var securityMode: RelayConnectionSecurityMode { candidates[0].securityMode }

    static func decode(_ raw: String) throws -> Self {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalPairingError.unsupported }
        guard trimmed.utf8.count <= maximumEncodedBytes else { throw LocalPairingError.tooLarge }
        if trimmed.hasPrefix("oriveo://") { return try decodeLegacyURI(trimmed) }
        let data: Data
        if trimmed.hasPrefix("{") {
            guard let value = trimmed.data(using: .utf8) else { throw LocalPairingError.invalid }
            data = value
        } else {
            var encoded = trimmed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let value = Data(base64Encoded: encoded) else { throw LocalPairingError.invalidEncoding }
            data = value
        }
        guard data.count <= maximumDecodedBytes else { throw LocalPairingError.tooLarge }
        guard let json = String(data: data, encoding: .utf8) else { throw LocalPairingError.invalidEncoding }
        var parser = LosslessJSONFragmentParser(json)
        switch parser.validate() {
        case .success: break
        case .duplicateKey: throw LocalPairingError.duplicateField
        case .tooDeep, .tooManyNodes: throw LocalPairingError.tooLarge
        case .invalid: throw LocalPairingError.invalid
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw LocalPairingError.invalid
        }
        guard !containsCredentialKey(object) else { throw LocalPairingError.containsSecret }
        guard let root = object as? [String: Any] else { throw LocalPairingError.invalid }
        if root["urls"] != nil, root["endpoint"] != nil { throw LocalPairingError.conflictingFields }
        guard Set(root.keys).isSubset(of: jsonFields) else { throw LocalPairingError.invalid }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw LocalPairingError.invalid
        }
        guard wire.v == 1 else { throw LocalPairingError.unsupportedVersion }
        guard let engine = LocalEngineKind(rawValue: wire.engine),
              let authMode = RelayAuthMode(rawValue: wire.auth),
              !wire.urls.isEmpty,
              wire.urls.count <= maximumCandidates else {
            throw LocalPairingError.invalid
        }
        guard wire.name.map({ $0.count <= maximumNameCharacters }) ?? true else {
            throw LocalPairingError.tooLarge
        }
        let candidates = try wire.urls.map { try candidate(for: $0, fingerprint: wire.fingerprint) }
        guard Set(candidates.map { "\($0.securityMode.rawValue)|\($0.endpoint)" }).count == candidates.count else {
            throw LocalPairingError.duplicateField
        }
        return .init(engine: engine, candidates: candidates, authMode: authMode, name: wire.name, fingerprint: wire.fingerprint)
    }

    private static func decodeLegacyURI(_ raw: String) throws -> Self {
        guard let components = URLComponents(string: raw),
              components.scheme == "oriveo", components.host == "local-provider" else {
            throw LocalPairingError.unsupported
        }
        let items = components.queryItems ?? []
        guard !items.contains(where: { isCredentialName($0.name) }) else { throw LocalPairingError.containsSecret }
        let normalizedNames = items.map { $0.name.lowercased() }
        guard Set(normalizedNames).count == normalizedNames.count else {
            throw LocalPairingError.duplicateField
        }
        guard Set(normalizedNames).isSubset(of: uriFields) else { throw LocalPairingError.invalid }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["v"] == "1" else { throw LocalPairingError.unsupportedVersion }
        guard values["auth"] == "none",
              let engineRaw = values["engine"], let engine = LocalEngineKind(rawValue: engineRaw),
              let endpoint = values["endpoint"], !endpoint.isEmpty,
              let modeRaw = values["mode"], let mode = RelayConnectionSecurityMode(rawValue: modeRaw),
              mode == .localHTTP || mode == .privateVPN else { throw LocalPairingError.invalid }
        guard values["name"].map({ $0.count <= maximumNameCharacters }) ?? true else {
            throw LocalPairingError.tooLarge
        }
        try requireCredentialFree(endpoint)
        guard endpoint.utf8.count <= maximumEndpointBytes,
              let parts = URLComponents(string: endpoint),
              parts.scheme?.lowercased() == "http",
              parts.host?.isEmpty == false else {
            throw LocalPairingError.invalid
        }
        return .init(engine: engine, candidates: [.init(endpoint: endpoint, securityMode: mode)], authMode: .none, name: values["name"], fingerprint: nil)
    }

    private static func candidate(for endpoint: String, fingerprint: String?) throws -> LocalPairingCandidate {
        try requireCredentialFree(endpoint)
        guard endpoint.utf8.count <= maximumEndpointBytes else { throw LocalPairingError.tooLarge }
        guard let parts = URLComponents(string: endpoint), let scheme = parts.scheme?.lowercased(), let host = parts.host else {
            throw LocalPairingError.invalid
        }
        if scheme == "https" {
            guard let fingerprint, isValidFingerprint(fingerprint) else { throw LocalPairingError.invalid }
            return .init(endpoint: endpoint, securityMode: .tofuHTTPS)
        }
        guard scheme == "http" else { throw LocalPairingError.invalid }
        let mode: RelayConnectionSecurityMode = isTailscaleHost(host) ? .privateVPN : .localHTTP
        return .init(endpoint: endpoint, securityMode: mode)
    }

    private static func requireCredentialFree(_ endpoint: String) throws {
        guard let parts = URLComponents(string: endpoint) else { throw LocalPairingError.invalid }
        guard parts.user == nil, parts.password == nil,
              !(parts.queryItems ?? []).contains(where: { isCredentialName($0.name) }) else {
            throw LocalPairingError.containsSecret
        }
        guard parts.query == nil else { throw LocalPairingError.invalid }
    }

    private static func isValidFingerprint(_ raw: String) -> Bool {
        guard raw.lowercased().hasPrefix("sha256:") else { return false }
        let value = String(raw.dropFirst(7)).replacingOccurrences(of: ":", with: "")
        return value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func containsCredentialKey(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return object.contains { isCredentialName($0.key) || containsCredentialKey($0.value) }
        }
        return (value as? [Any])?.contains(where: containsCredentialKey) ?? false
    }

    private static func isTailscaleHost(_ raw: String) -> Bool {
        let host = raw.lowercased()
        if host.hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    private static func isCredentialName(_ raw: String) -> Bool {
        let key = raw.lowercased().filter(\.isLetter)
        return key != "auth" && (key == "key" || key.hasSuffix("key") || key.contains("token")
            || key.contains("secret") || key.contains("password") || key.contains("credential")
            || key.contains("authorization"))
    }

    private struct Wire: Decodable {
        let v: Int
        let name: String?
        let urls: [String]
        let engine: String
        let auth: String
        let fingerprint: String?
    }
}

nonisolated enum LocalPairingError: Error, Equatable, Sendable {
    case unsupported
    case unsupportedVersion
    case containsSecret
    case tooLarge
    case duplicateField
    case conflictingFields
    case invalidEncoding
    case invalid
}
