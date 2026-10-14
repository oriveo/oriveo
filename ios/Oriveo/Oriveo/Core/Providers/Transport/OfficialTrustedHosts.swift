import Foundation

/// Trusted host table for official providers: the official base URLs and region options delivered by metadata are adopted only if they fall within this table.
///
/// The table is delivered by the Server in `providerConfigs[].trustedHosts`, and the client no longer hardcodes it. A delivered empty table is equivalent to a missing field:
/// only the last two labels of the built-in fallback base-URL host are trusted (the fallback hosts of all 15 providers are not under a second-level public suffix, so the client carries no public suffix list).
/// The matching rule is identical on all three platforms: `host == entry || host ends with "." + entry`, and it must be https.
nonisolated enum OfficialTrustedHosts {

    /// Shape check of the delivered table (the client-side subset of the Server's write-time validation): lowercase, at least two labels, not an IP, no port, no wildcard.
    /// Entries with a wrong shape are dropped one by one, so a single bad value does not drag down the whole provider.
    static func isValidShape(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw == raw.lowercased(),
              !raw.contains("*"), !raw.contains(":"), !raw.contains("/") else { return false }
        let labels = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard !label.isEmpty, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        }
        // A group made entirely of digits is an IPv4 address, not a host name.
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
        return true
    }

    /// The delivered table after decoding: entries with a wrong shape are dropped and the rest de-duplicated; returns nil when none remain (equivalent to a missing field).
    static func sanitized(_ raw: [String]?) -> [String]? {
        guard let raw else { return nil }
        var seen = Set<String>()
        let kept = raw.filter { isValidShape($0) && seen.insert($0).inserted }
        return kept.isEmpty ? nil : kept
    }

    /// The effective trusted table. Relay is not a row of `provider_config` and have no trusted table of official base URLs.
    static func effective(providerKind: ProviderKind, delivered: [String]?) -> [String] {
        switch providerKind {
        case .relay:
            return []
        default:
            break
        }
        if let delivered = sanitized(delivered) { return delivered }
        return fallbackRegistrableDomain(for: providerKind).map { [$0] } ?? []
    }

    /// Gets this provider's delivered table from the current metadata snapshot.
    static func delivered(for providerKind: ProviderKind) -> [String]? {
        MetadataClient.shared.syncPublicProviderConfig(providerKind: providerKind)?.trustedHosts?.hosts
    }

    static func hostMatches(_ host: String, trusted: [String]) -> Bool {
        let host = host.lowercased()
        return trusted.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// https and the host is within the trusted table.
    static func isTrustedURL(_ raw: String, providerKind: ProviderKind, delivered: [String]?) -> Bool {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { return false }
        return hostMatches(host, trusted: effective(providerKind: providerKind, delivered: delivered))
    }

    /// The last two labels of the built-in fallback base-URL host.
    static func fallbackRegistrableDomain(for providerKind: ProviderKind) -> String? {
        guard let host = URLComponents(string: EndpointResolver.fallbackBaseURL(for: providerKind))?.host?.lowercased()
        else { return nil }
        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return nil }
        return labels.suffix(2).joined(separator: ".")
    }
}

/// Lenient decoding of `providerConfigs[].trustedHosts`: a wrong shape (not an array of strings) is treated as a missing field,
/// so the whole providerConfigs never fails to decode; each entry goes through `OfficialTrustedHosts.isValidShape`.
nonisolated struct TrustedHostList: Codable, Sendable, Equatable {
    let hosts: [String]?

    init(hosts: [String]?) {
        self.hosts = OfficialTrustedHosts.sanitized(hosts)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try? container.decode([String].self)
        self.init(hosts: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hosts ?? [])
    }
}
