import Foundation
import Testing
@testable import Oriveo

/// Relay avatars: the brand table and cases from the fixture `shared/test-fixtures/relay/relay-avatar.v1.json`,
/// plus the five places (model picker group header, chat top bar, message header, detail header, provider list) that must resolve to the same result (BOARD-AVATAR-01).
@Suite("Relay 2.0 · relay avatar")
@MainActor
struct RelayAvatarResolverTests {

    // MARK: - Fixture

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/relay-avatar.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func cases() throws -> [[String: Any]] {
        try #require(try fixture()["cases"] as? [[String: Any]])
    }

    /// Fixture expectation -> this platform's result: a brand id is converted to an existing official asset name through the production brand table.
    private static func expected(_ raw: [String: Any]) throws -> RelayAvatar {
        switch try #require(raw["kind"] as? String) {
        case "brand":
            let id = try #require(raw["brand"] as? String)
            let brand = try #require(RelayAvatarResolver.brands.first { $0.id == id }, "brand table is missing \(id)")
            return .brand(brand.assetName)
        case "initial":
            return .initial(try #require(raw["text"] as? String))
        default:
            return .generic
        }
    }

    private func runCase(_ caseId: String) throws {
        let item = try #require(try Self.cases().first { $0["id"] as? String == caseId }, "fixture is missing \(caseId)")
        let name = item["name"] as? String ?? ""
        let url = item["url"] as? String ?? ""
        let expected = try Self.expected(try #require(item["expected"] as? [String: Any]))
        #expect(RelayAvatarResolver.resolve(name: name, urlString: url) == expected, "\(caseId)")

        // The same input arriving through a production connection (customName + baseURLText) gives the same result even with models attached.
        let models = (item["models"] as? [String] ?? []).map { TestFactories.makeModel(id: $0) }
        let provider = TestFactories.makeProvider(
            kind: .relay,
            models: models,
            baseURLText: url.isEmpty ? nil : url,
            customName: name.isEmpty ? nil : name
        )
        #expect(RelayAvatarResolver.avatar(for: provider) == expected, "\(caseId) via Provider")
    }

    @Test("RD3-AVATAR-openrouter_by_host") func openrouterByHost() throws { try runCase("openrouter_by_host") }
    @Test("RD3-AVATAR-openrouter_by_name") func openrouterByName() throws { try runCase("openrouter_by_name") }
    @Test("RD3-AVATAR-siliconflow_by_host") func siliconflowByHost() throws { try runCase("siliconflow_by_host") }
    @Test("RD3-AVATAR-together_by_host") func togetherByHost() throws { try runCase("together_by_host") }
    @Test("RD3-AVATAR-groq_by_host") func groqByHost() throws { try runCase("groq_by_host") }
    @Test("RD3-AVATAR-initial_latin") func initialLatin() throws { try runCase("initial_latin") }
    @Test("RD3-AVATAR-initial_lowercase") func initialLowercase() throws { try runCase("initial_lowercase") }
    @Test("RD3-AVATAR-initial_cjk") func initialCJK() throws { try runCase("initial_cjk") }
    @Test("RD3-AVATAR-initial_skips_symbols") func initialSkipsSymbols() throws { try runCase("initial_skips_symbols") }
    @Test("RD3-AVATAR-model_ids_ignored") func modelIDsIgnored() throws { try runCase("model_ids_ignored") }
    @Test("RD3-AVATAR-together_word_not_brand") func togetherWordNotBrand() throws { try runCase("together_word_not_brand") }
    @Test("RD3-AVATAR-oriveo_excluded") func oriveoExcluded() throws { try runCase("oriveo_excluded") }
    @Test("RD3-AVATAR-empty_name_uses_host") func emptyNameUsesHost() throws { try runCase("empty_name_uses_host") }
    @Test("RD3-AVATAR-nothing_usable") func nothingUsable() throws { try runCase("nothing_usable") }

    @Test("RD3-AVATAR every fixture case has a test of the same name; the brand table matches the fixture item by item, and assets are existing official brand images")
    func fixtureCoveredAndBrandTableMatches() throws {
        let root = try Self.fixture()
        #expect(Set(try Self.cases().compactMap { $0["id"] as? String }) == [
            "openrouter_by_host", "openrouter_by_name", "siliconflow_by_host", "together_by_host", "groq_by_host",
            "initial_latin", "initial_lowercase", "initial_cjk", "initial_skips_symbols", "model_ids_ignored",
            "together_word_not_brand", "oriveo_excluded", "empty_name_uses_host", "nothing_usable",
        ])
        let brands = try #require(root["brands"] as? [[String: Any]])
        #expect(RelayAvatarResolver.brands.map(\.id) == brands.compactMap { $0["id"] as? String })
        #expect(RelayAvatarResolver.brands.map(\.keywords) == brands.compactMap { $0["keywords"] as? [String] })
        #expect(RelayAvatarResolver.excludeKeywords == (root["excludeKeywords"] as? [String] ?? []))
        for brand in RelayAvatarResolver.brands {
            #expect(brand.assetName == brand.kind.brandAssetName, "\(brand.id) must use an existing official asset")
        }
    }

    @Test("RD3-AVATAR local connections and official providers do not use this function; brand inference no longer looks at the model id or protocol type")
    func localAndOfficialAreNotRelayAvatars() {
        var local = TestFactories.makeProvider(kind: .relay, baseURLText: "http://192.168.1.20:8080", customName: "OpenRouter box")
        local.relayRequested = RelayRequestedConfig(
            transport: .openaiChatCompletions,
            authMode: .none,
            securityMode: .localHTTP,
            engineProfile: "ollama"
        )
        #expect(RelayAvatarResolver.avatar(for: local) == nil)
        #expect(RelayAvatarResolver.avatar(for: TestFactories.makeProvider(kind: .openAI)) == nil)

        var relay = TestFactories.makeProvider(
            kind: .relay,
            models: [TestFactories.makeModel(id: "claude-sonnet-4-5")],
            baseURLText: "https://p.example.com/v1",
            customName: "Proxy"
        )
        relay.relayKind = .anthropicCompatible
        #expect(RelayAvatarResolver.avatar(for: relay) == .initial("P"))
        // Places such as the list / cost card that still read logoKind follow the same brand table: no match means the relay itself.
        #expect(ProviderLogoResolver.logoKind(for: relay) == .relay)
        relay.baseURLText = "https://openrouter.ai/api/v1"
        #expect(ProviderLogoResolver.logoKind(for: relay) == .openRouter)
    }

    // MARK: - BOARD-AVATAR-01

    @Test("BOARD-AVATAR-01 the five places get the same result for one relay connection")
    func boardAvatar01FivePlacesShareOneResult() throws {
        var provider = TestFactories.makeProvider(
            kind: .relay,
            models: [TestFactories.makeModel(id: "gpt-4o")],
            baseURLText: "https://api.groq.com/openai/v1",
            customName: "fast"
        )
        provider.relayRequested = RelayRequestedConfig(transport: .openaiChatCompletions, authMode: .bearer)
        let expected = try #require(RelayAvatarResolver.avatar(for: provider))
        #expect(expected == .brand("ProviderGroq"))

        // Detail header: the avatar produced by the board model.
        #expect(try #require(RelayDetailBoardModel.make(provider)).avatar == expected)

        // Message header: the production lookup (the chat projection `relayAvatar(for:)` forwards to it unchanged) resolves by the session's connection.
        let lookup = ModelDisplayLookup(providers: [provider])
        #expect(lookup.relayAvatar(providerID: provider.id, providerKind: .relay) == expected)
        // The session's connection is gone / none recorded: relay messages use generic; non-relay messages do not use this function.
        #expect(lookup.relayAvatar(providerID: UUID(), providerKind: .relay) == .generic)
        #expect(lookup.relayAvatar(providerID: nil, providerKind: .relay) == .generic)
        #expect(lookup.relayAvatar(providerID: provider.id, providerKind: .openAI) == nil)

        // The model picker group header, chat top bar and provider list (including the summary card) go through the same connection avatar component; the detail header reads the board avatar and the message header reads the projection avatar (both asserted above).
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Features/Providers
            .deletingLastPathComponent()   // Features
            .deletingLastPathComponent()   // OriveoTests
            .deletingLastPathComponent()   // Oriveo
            .appendingPathComponent("Oriveo")
        for file in [
            "Features/Home/HomeModelPickerSheet.swift",
            "Features/Chat/ChatToolbar.swift",
            "Shared/Components/Rows/ProviderListCard.swift",
            "Features/Providers/ProviderSummaryCard.swift",
            "Features/Providers/RelayDetailBoardView.swift",
            "Features/Chat/Cells/AssistantMessageCell.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            // The call may span several lines: strip whitespace before recognizing the component entry.
            let compact = source.filter { !$0.isWhitespace }
            #expect(
                compact.contains("ConnectionAvatarIcon(provider:")
                    || source.contains("relayAvatar: model.relayAvatar")
                    || source.contains("board.avatar"),
                "\(file) does not use the unified avatar"
            )
        }
    }
}
