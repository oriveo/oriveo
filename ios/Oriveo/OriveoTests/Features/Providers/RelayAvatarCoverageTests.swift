import Foundation
import Testing
@testable import Oriveo

/// Full relay avatar coverage: every connection avatar goes through `ConnectionAvatarIcon`,
/// and no call site draws `ProviderBadgeIcon` from the protocol type itself. A missed call site is exactly why the chat list on a real device still showed the old logo.
@Suite("Relay 2.0 · relay avatar full coverage")
@MainActor
struct RelayAvatarCoverageTests {

    // MARK: - Component decisions

    @Test("RL2-AVATAR-COVER-01 a relay name containing an aggregator brand -> brand image")
    func relayWithAggregatorNameUsesBrand() {
        var relay = TestFactories.makeProvider(
            kind: .relay,
            baseURLText: "https://proxy.example.com/v1",
            customName: "OpenRouter backup"
        )
        relay.relayKind = .openaiCompatible
        let content = ConnectionAvatarIcon.content(provider: relay, kind: .relay, relayKind: relay.relayKind)
        #expect(content == .relay(.brand("ProviderOpenRouter")))
    }

    /// Previously "has a name -> first letter"; since the default avatar icon contract (`relay-avatar-icon.v1.json`), a relay that matches no brand gets a default icon picked by connection id.
    @Test("RL2-AVATAR-COVER-02 a relay that matches no brand -> the default icon picked by connection id")
    func relayWithNameUsesInitial() {
        var relay = TestFactories.makeProvider(
            kind: .relay,
            models: [TestFactories.makeModel(id: "claude-sonnet-4-5")],
            baseURLText: "https://p.example.com/v1",
            customName: "Proxy"
        )
        relay.relayKind = .anthropicCompatible
        let content = ConnectionAvatarIcon.content(provider: relay, kind: .relay, relayKind: relay.relayKind)
        #expect(content == .relay(.icon(RelayAvatarResolver.defaultIcon(providerID: relay.id.uuidString))))
    }

    @Test("RL2-AVATAR-COVER-03 the relay connection is gone / no connection recorded -> generic, not drawn from the protocol type")
    func relayWithoutProviderUsesGeneric() {
        let content = ConnectionAvatarIcon.content(provider: nil, kind: .relay, relayKind: .openaiCompatible)
        #expect(content == .relay(.generic))
        // For entry points that only have a lookup result: if the lookup says generic, draw generic; only when it says nil (local / official) does the original logo apply.
        #expect(ConnectionAvatarIcon(relayAvatar: .generic, kind: .relay).content == .relay(.generic))
        #expect(
            ConnectionAvatarIcon(relayAvatar: nil, kind: .relay, relayKind: .openaiCompatible).content
                == .badge(kind: .relay, relayKind: .openaiCompatible)
        )
    }

    @Test("RL2-AVATAR-COVER-04 a local-engine connection still goes through ProviderBadgeIcon")
    func localEngineUsesProviderBadge() {
        var local = TestFactories.makeProvider(kind: .relay, baseURLText: "http://192.168.1.20:8080", customName: "Box")
        local.relayKind = .openaiCompatible
        local.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .none,
            securityMode: .localHTTP,
            engineProfile: "ollama"
        )
        let content = ConnectionAvatarIcon.content(provider: local, kind: .relay, relayKind: local.relayKind)
        #expect(content == .badge(kind: .relay, relayKind: .openaiCompatible))
    }

    @Test("RL2-AVATAR-COVER-04 an official provider goes through ProviderBadgeIcon")
    func officialUsesProviderBadge() {
        let official = TestFactories.makeProvider(kind: .openAI)
        #expect(ConnectionAvatarIcon.content(provider: official, kind: .openAI, relayKind: nil) == .badge(kind: .openAI, relayKind: nil))
        // Official sources that record no connection, such as notes.
        #expect(ConnectionAvatarIcon.content(provider: nil, kind: .anthropic, relayKind: nil) == .badge(kind: .anthropic, relayKind: nil))
    }

    // MARK: - Source gate

    /// Files allowed to call `ProviderBadgeIcon` with `relayKind:` directly. A new entry must say why it cannot get the relay connection.
    private static let allowedRelayKindCallers: [String: String] = [
        "Shared/Components/ChipsAndBadges.swift": "Inside ConnectionAvatarIcon: only reached after it was judged not to be a relay connection (local engine / official)",
    ]

    @Test("RL2-AVATAR-COVER-05 production sources no longer bypass the unified component to call ProviderBadgeIcon with relayKind")
    func noDirectRelayKindBadgeOutsideComponent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Features/Providers
            .deletingLastPathComponent()   // Features
            .deletingLastPathComponent()   // OriveoTests
            .deletingLastPathComponent()   // Oriveo
            .appendingPathComponent("Oriveo")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var hitsByAllowedFile: [String: Int] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let allowed = Self.allowedRelayKindCallers.keys.first { url.path.hasSuffix("/" + $0) }
            for arguments in Self.badgeCallArguments(in: source) where arguments.contains("relayKind:") {
                if let allowed {
                    hitsByAllowedFile[allowed, default: 0] += 1
                } else {
                    offenders.append("\(url.lastPathComponent): ProviderBadgeIcon(\(arguments))")
                }
            }
        }
        #expect(offenders.isEmpty, "Switch to ConnectionAvatarIcon: \(offenders)")
        // A stale entry (the file no longer has such a call) must be removed too, so the allowlist cannot only grow.
        for file in Self.allowedRelayKindCallers.keys {
            #expect(hitsByAllowedFile[file, default: 0] > 0, "\(file) no longer has a call with relayKind; remove the entry")
        }
    }

    /// Extracts the argument text inside the parentheses of each `ProviderBadgeIcon(` call (multi-line, with balanced parentheses).
    private static func badgeCallArguments(in source: String) -> [String] {
        let marker = "ProviderBadgeIcon("
        var results: [String] = []
        var searchStart = source.startIndex
        while let range = source.range(of: marker, range: searchStart..<source.endIndex) {
            var depth = 1
            var cursor = range.upperBound
            while cursor < source.endIndex, depth > 0 {
                switch source[cursor] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                cursor = source.index(after: cursor)
            }
            let end = depth == 0 ? source.index(before: cursor) : cursor
            results.append(String(source[range.upperBound..<end]))
            searchStart = cursor
        }
        return results
    }
}
