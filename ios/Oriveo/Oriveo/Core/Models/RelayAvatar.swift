import Foundation

/// Avatar of a relay connection. Neither the brand image, the initial nor the default icon gets a backing plate or an outline.
nonisolated enum RelayAvatar: Hashable, Sendable {
    /// Aggregator brand: an existing official brand asset name.
    case brand(String)
    /// The first letter or digit of the display name (the domain if empty).
    case initial(String)
    /// The default icon, or the icon the user picked on this device (fixture `relay-avatar-icon.v1.json`).
    case icon(RelayAvatarIcon)
    /// Nothing could be extracted: the existing relay icon.
    case generic
}

/// The 10 original icons for default relay avatars (asset `RelayAvatar/<id>`, template rendering); the order is the fixture's `icons` order (modulo index and picker cell order).
nonisolated enum RelayAvatarIcon: String, CaseIterable, Hashable, Sendable {
    case paperPlane = "paper-plane"
    case signalTower = "signal-tower"
    case relayBell = "relay-bell"
    case satellite
    case signpost
    case archBridge = "arch-bridge"
    case kite
    case messageBottle = "message-bottle"
    case pennant
    case hotAirBalloon = "hot-air-balloon"

    /// Fixture `icons[].id`, also the choice value stored on device.
    var id: String { rawValue }

    /// Namespaced asset name in the asset catalog (`Assets.xcassets/RelayAvatar/<id>`, template rendering; the asset carries its own layer opacities).
    var assetName: String { "RelayAvatar/\(rawValue)" }

    /// Fixture `icons[].palette`: an existing color token (dark 400 / light 600, following the theme) that the renderer tints with.
    var paletteToken: String {
        switch self {
        case .paperPlane: return "detailRow.indigo"
        case .signalTower: return "detailRow.teal"
        case .relayBell: return "capability.attachment"
        case .satellite: return "capability.reasoning"
        case .signpost: return "capability.vision"
        case .archBridge: return "capability.webSearch"
        case .kite: return "detailRow.rose"
        case .messageBottle: return "detailRow.cyan"
        case .pennant: return "detailRow.orange"
        case .hotAirBalloon: return "capability.tools"
        }
    }

    /// Label of the picker cell (Providers table, English source text as the key).
    var titleKey: String {
        switch self {
        case .paperPlane: return "Paper plane"
        case .signalTower: return "Signal tower"
        case .relayBell: return "Bell"
        case .satellite: return "Satellite"
        case .signpost: return "Signpost"
        case .archBridge: return "Bridge"
        case .kite: return "Kite"
        case .messageBottle: return "Bottle"
        case .pennant: return "Pennant"
        case .hotAirBalloon: return "Balloon"
        }
    }
}

/// One cell of the "Change icon" sheet: brand (only when the base layer matched a brand) -> the 10 icons -> initial (only when the base layer can get one).
nonisolated enum RelayAvatarPickerCell: Hashable, Sendable {
    case brand(RelayAvatarResolver.Brand)
    case icon(RelayAvatarIcon)
    case letter(String)

    /// The value to store when this cell is picked; nil = delete the stored choice (brand cell).
    var storedChoice: String? {
        switch self {
        case .brand: return nil
        case let .icon(icon): return icon.id
        case .letter: return RelayAvatarResolver.letterChoice
        }
    }

    /// The avatar this cell draws.
    var avatar: RelayAvatar {
        switch self {
        case let .brand(brand): return .brand(brand.assetName)
        case let .icon(icon): return .icon(icon)
        case let .letter(text): return .initial(text)
        }
    }
}

/// The single resolver shared by the model picker group header, the chat top bar, the message header, the detail header and the provider list.
///
/// The source of truth for the rules is the fixture `shared/test-fixtures/relay/relay-avatar.v1.json`: the lowercased display name and URL host are matched against brand keywords in table order,
/// first hit wins; if an exclusion word (the app's own name) matches, brand matching is skipped. Model id and protocol type never take part --
/// inferring from the model id used to draw ordinary relays as OpenAI / Anthropic. Local connections do not go through this function.
nonisolated enum RelayAvatarResolver {
    struct Brand: Hashable, Sendable {
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

    /// Storing this value on device = use the initial (fixture `letterChoice`).
    static let letterChoice = "letter"

    /// Base layer (`relay-avatar.v1.json`: brand -> initial -> generic). Places that draw avatars do not call it directly;
    /// they go through `resolve(providerID:name:urlString:choice:)` / `avatar(for:choice:)`.
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

    /// Icon layer (fixture `relay-avatar-icon.v1.json`): on-device choice -> base-layer brand -> default icon picked by connection id.
    /// With an empty connection id, the base-layer result is returned as is.
    static func resolve(providerID: String, name: String, urlString: String, choice: String?) -> RelayAvatar {
        let key = normalizedHashKey(providerID)
        guard !key.isEmpty else { return resolve(name: name, urlString: urlString) }
        if let choice {
            if let icon = RelayAvatarIcon(rawValue: choice) {
                return .icon(icon)
            }
            if choice == letterChoice {
                // The initial skips brand matching; without an initial it falls to the default icon (never back to the brand).
                if let text = initial(name: name, urlString: urlString) {
                    return .initial(text)
                }
                return .icon(defaultIcon(normalizedKey: key))
            }
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let brand = brand(name: trimmedName, host: host(of: urlString)) {
            return .brand(brand.assetName)
        }
        return .icon(defaultIcon(normalizedKey: key))
    }

    /// Cells of the "Change icon" sheet, ordered as in the fixture's `pickerCases`.
    static func pickerCells(name: String, urlString: String) -> [RelayAvatarPickerCell] {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var cells: [RelayAvatarPickerCell] = []
        if let brand = brand(name: trimmedName, host: host(of: urlString)) {
            cells.append(.brand(brand))
        }
        cells += RelayAvatarIcon.allCases.map(RelayAvatarPickerCell.icon)
        if let text = initial(name: name, urlString: urlString) {
            cells.append(.letter(text))
        }
        return cells
    }

    static func pickerCells(for provider: Provider) -> [RelayAvatarPickerCell] {
        pickerCells(name: provider.customName ?? "", urlString: provider.baseURLText ?? "")
    }

    /// Default icon assigned stably by connection id: 32-bit FNV-1a (over the UTF-8 bytes after trimming ASCII whitespace and lowercasing A-Z) modulo 10.
    static func defaultIcon(providerID: String) -> RelayAvatarIcon {
        defaultIcon(normalizedKey: normalizedHashKey(providerID))
    }

    static func fnv1a32(_ key: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return hash
    }

    /// Base layer: nil = not a relay connection (official provider / local). Draw avatars with `avatar(for:choice:)`.
    static func avatar(for provider: Provider) -> RelayAvatar? {
        guard provider.kind == .relay, !isLocalEngine(provider) else { return nil }
        return resolve(name: provider.customName ?? "", urlString: provider.baseURLText ?? "")
    }

    /// Shared by every place that draws a relay avatar: nil = not a relay connection (official provider / local); the caller uses the original logo.
    /// `choice` is the choice stored on device (`RelayAvatarChoiceStore`), or nil if there is none.
    static func avatar(for provider: Provider, choice: String?) -> RelayAvatar? {
        guard provider.kind == .relay, !isLocalEngine(provider) else { return nil }
        return resolve(
            providerID: provider.id.uuidString,
            name: provider.customName ?? "",
            urlString: provider.baseURLText ?? "",
            choice: choice
        )
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

    /// The base layer's initial rule (skipping brand matching): the first letter or digit of the display name, otherwise of the domain without api. / www.
    private static func initial(name: String, urlString: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let initial = firstLetterOrDigit(trimmedName) { return initial }
        if let host = host(of: urlString) { return firstLetterOrDigit(strippedHost(host)) }
        return nil
    }

    /// Only trims leading and trailing ASCII whitespace and only lowercases ASCII A-Z; every other byte is left alone.
    private static func normalizedHashKey(_ providerID: String) -> String {
        let asciiSpaces: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]
        var bytes = Array(providerID.utf8)
        while let first = bytes.first, asciiSpaces.contains(first) { bytes.removeFirst() }
        while let last = bytes.last, asciiSpaces.contains(last) { bytes.removeLast() }
        let lowered = bytes.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        return String(decoding: lowered, as: UTF8.self)
    }

    private static func defaultIcon(normalizedKey: String) -> RelayAvatarIcon {
        let icons = RelayAvatarIcon.allCases
        return icons[Int(fnv1a32(normalizedKey) % UInt32(icons.count))]
    }

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
