import Foundation

/// Avatar of a relay connection. Neither the brand image nor the initial gets a backing plate or an outline.
nonisolated enum RelayAvatar: Hashable, Sendable {
    /// Aggregator brand: an existing official brand asset name.
    case brand(String)
    /// The first letter or digit of the display name (the domain if empty).
    case initial(String)
    /// Nothing could be extracted: the existing relay icon.
    case generic
}

/// The single resolver shared by the model picker group header, the chat top bar, the message header, the detail header and the provider list.
///
/// The source of truth for the rules is the fixture `shared/test-fixtures/relay/relay-avatar.v1.json`: the lowercased display name and URL host are matched against brand keywords in table order,
/// first hit wins; if an exclusion word (the app's own name) matches, brand matching is skipped. Model id and protocol type never take part --
/// inferring from the model id used to draw ordinary relays as OpenAI / Anthropic. Local connections do not go through this function.
nonisolated enum RelayAvatarResolver {
    struct Brand: Sendable {
        let id: String
        let keywords: [String]
        let kind: ProviderKind
        let assetName: String
    }

    /// To add a built-in relay brand, add it only to the fixture and this table.
    static let brands: [Brand] = [
        Brand(id: "openrouter", keywords: ["openrouter"], kind: .openRouter, assetName: "ProviderOpenRouter"),
        Brand(id: "siliconflow", keywords: ["siliconflow"], kind: .siliconFlow, assetName: "ProviderSiliconFlow"),
        Brand(id: "together", keywords: ["together.ai", "together.xyz", "togetherai"], kind: .together, assetName: "ProviderTogether"),
        Brand(id: "fireworks", keywords: ["fireworks"], kind: .fireworks, assetName: "ProviderFireworks"),
        Brand(id: "groq", keywords: ["groq"], kind: .groq, assetName: "ProviderGroq"),
    ]

    static let excludeKeywords = ["oriveo"]

    static func resolve(name: String, urlString: String) -> RelayAvatar {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = host(of: urlString)
        if let brand = brand(name: trimmedName, host: host) {
            return .brand(brand.assetName)
        }
        if let initial = firstLetterOrDigit(trimmedName) {
            return .initial(initial)
        }
        if let host, let initial = firstLetterOrDigit(strippedHost(host)) {
            return .initial(initial)
        }
        return .generic
    }

    /// nil = not a relay connection (official provider / local); the caller uses the original logo.
    static func avatar(for provider: Provider) -> RelayAvatar? {
        guard provider.kind == .relay, !isLocalEngine(provider) else { return nil }
        return resolve(name: provider.customName ?? "", urlString: provider.baseURLText ?? "")
    }

    /// For places that still read `ProviderKind` (list brand color, cost card): the brand a relay connection matched, or nil if none.
    static func brandKind(for provider: Provider) -> ProviderKind? {
        let host = host(of: provider.baseURLText ?? "")
        let name = (provider.customName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return brand(name: name, host: host)?.kind
    }

    /// Local connection = an engine was recognized (the same criterion as the local one on the detail page board).
    static func isLocalEngine(_ provider: Provider) -> Bool {
        let engine = provider.relayRequested?.engineProfile?.trimmingCharacters(in: .whitespacesAndNewlines)
        return engine?.isEmpty == false
    }

    // MARK: - Private

    private static func brand(name: String, host: String?) -> Brand? {
        let haystacks = [name.lowercased(), host ?? ""].filter { !$0.isEmpty }
        guard !haystacks.isEmpty else { return nil }
        if excludeKeywords.contains(where: { keyword in haystacks.contains { $0.contains(keyword) } }) {
            return nil
        }
        return brands.first { brand in
            brand.keywords.contains { keyword in haystacks.contains { $0.contains(keyword) } }
        }
    }

    private static func host(of urlString: String) -> String? {
        let raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        guard let host = URL(string: withScheme)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    private static func strippedHost(_ host: String) -> String {
        for prefix in ["api.", "www."] where host.hasPrefix(prefix) {
            return String(host.dropFirst(prefix.count))
        }
        return host
    }

    /// The first letter or digit; Latin letters are uppercased (cases that expand to several characters, such as ß, stay as they are).
    private static func firstLetterOrDigit(_ text: String) -> String? {
        guard let character = text.first(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let upper = String(character).uppercased()
        return upper.count == 1 ? upper : String(character)
    }
}
