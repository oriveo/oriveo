import Foundation
import Testing
@testable import Oriveo

/// Cross-client contract for the connection-level web fragment of a relay
///
/// Fixture `shared/test-fixtures/relay/web-fragment.v1.json`: the five sections validate / merge / legacy / citation / presentation
/// drive production functions caseId by caseId; also covers the detail page "Web" row and the web settings page clearing legacy fields on save.
@Suite("Relay web fragment - cross-client fixture (RELAY-WEBFRAG)", .serialized)
@MainActor
struct RelayWebFragmentContractTests {

    // MARK: - Fixture

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/web-fragment.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func cases(_ section: String) throws -> [[String: Any]] {
        try #require(try fixture()[section] as? [[String: Any]])
    }

    private static func transport(_ raw: Any?) throws -> RelayTransport {
        let name = try #require(raw as? String)
        return try #require(RelayTransport(rawValue: name))
    }

    private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l as [String: Any], r as [String: Any]): return NSDictionary(dictionary: l).isEqual(to: r)
        default: return false
        }
    }

    private static func isolatedStore() -> RelayWebFragmentStore {
        let suite = "relay-web-fragment-tests-\(UUID().uuidString)"
        return RelayWebFragmentStore(defaults: UserDefaults(suiteName: suite)!)
    }

    // MARK: - validate

    @Test("RELAY-WEBFRAG-validate: each caseId's validation result and error code match the fixture")
    func RELAY_WEBFRAG_validate() throws {
        let items = try Self.cases("validateCases")
        #expect(items.count == 16)
        for item in items {
            let caseId = try #require(item["caseId"] as? String)
            let raw: String
            if let pad = item["rawPadTo"] as? Int {
                raw = "{\"x\":\"" + String(repeating: "a", count: pad - 8) + "\"}"
                #expect(raw.utf8.count == pad, "RELAY-WEBFRAG-validate-\(caseId) precondition: raw byte count")
            } else {
                raw = try #require(item["raw"] as? String)
            }
            let expect = try #require(item["expect"] as? [String: Any])
            let result = RelayWebFragments.validate(raw)
            if expect["ok"] as? Bool == true {
                if case let .failure(error) = result {
                    Issue.record("RELAY-WEBFRAG-validate-\(caseId): expected to pass, got \(error.code)")
                }
            } else {
                guard case let .failure(error) = result else {
                    Issue.record("RELAY-WEBFRAG-validate-\(caseId): expected \(expect["error"] ?? ""), but it passed")
                    continue
                }
                #expect(error.code == expect["error"] as? String, "RELAY-WEBFRAG-validate-\(caseId)")
                if let key = expect["key"] as? String {
                    #expect(error == .forbiddenKey(key), "RELAY-WEBFRAG-validate-\(caseId)")
                }
            }
        }
    }

    // MARK: - merge

    @Test("RELAY-WEBFRAG-merge: builder output + fragment -> fixture expect")
    func RELAY_WEBFRAG_merge() throws {
        let items = try Self.cases("mergeCases")
        #expect(items.count == 8)
        for item in items {
            let caseId = try #require(item["caseId"] as? String)
            var body = try #require(item["builderBody"] as? [String: Any])
            let fragment = try #require(item["fragment"] as? [String: Any])
            RelayWebFragments.merge(transport: try Self.transport(item["transport"]), into: &body, fragment: fragment)
            #expect(Self.same(body, item["expect"]), "RELAY-WEBFRAG-merge-\(caseId)：\(body)")
        }
    }

    // MARK: - legacy

    @Test("RELAY-WEBFRAG-legacy: legacy fields are mapped at read time (stored value wins) and the result is not written back")
    func RELAY_WEBFRAG_legacy() throws {
        let fixture = try Self.fixture()
        let profiles = try #require(fixture["legacyProfiles"] as? [String: [String: Any]])
        let items = try Self.cases("legacyCases")
        #expect(items.count == 14)
        for item in items {
            let caseId = try #require(item["caseId"] as? String)
            let legacy = try #require(item["relayRequested"] as? [String: Any])
            var requested = try JSONDecoder().decode(
                RelayRequestedConfig.self, from: JSONSerialization.data(withJSONObject: legacy)
            )
            requested.transport = .openaiResponses
            let provider = Provider(
                id: UUID(), kind: .relay, status: .connected, models: [], catalogModels: [],
                apiKey: "sk", apiKeyPreview: "", baseURLText: "https://relay.test/v1", relayRequested: requested
            )
            let store = Self.isolatedStore()
            let stored = try #require(item["stored"] as? [String: [String: Any]])
            for (key, object) in stored {
                let raw = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                #expect(store.save(connectionID: provider.id, transport: try Self.transport(key), raw: raw) == nil)
            }
            let effective = store.effective(provider: provider, profiles: { profiles })
            let expect = try #require(item["expect"] as? [String: [String: Any]])
            #expect(Set(effective.raw.keys) == Set(expect.keys), "RELAY-WEBFRAG-legacy-\(caseId)：\(effective.raw)")
            for (key, object) in expect {
                #expect(
                    Self.same(effective.object(for: try Self.transport(key)), object),
                    "RELAY-WEBFRAG-legacy-\(caseId)：\(key) = \(effective.raw[key] ?? "nil")"
                )
            }
            // The mapping exists only in memory: neither the store nor the connection config was rewritten.
            #expect(store.stored(connectionID: provider.id).count == stored.count, "RELAY-WEBFRAG-legacy-\(caseId)")
            #expect(provider.relayRequested == requested, "RELAY-WEBFRAG-legacy-\(caseId)")
        }
    }

    @Test("RELAY-WEBFRAG-legacy-metadata_profile_without_known_transport_is_not_mapped: metadata has it but the transport table does not -> not mapped")
    func RELAY_WEBFRAG_legacy_unknown_transport_profile() throws {
        let requested = try JSONDecoder().decode(
            RelayRequestedConfig.self,
            from: Data(#"{"transport":"openai_responses","hasWebSearch":true,"webSearchProfile":"brand_new_web"}"#.utf8)
        )
        let mapped = requested.legacyWebFragments(profiles: { ["brand_new_web": ["tools": [["type": "web_search"]]]] })
        #expect(mapped.isEmpty, "\(mapped)")
    }

    // MARK: - citation

    @Test("RELAY-WEBFRAG-citation: the citation profile is derived from the fragment merged this turn")
    func RELAY_WEBFRAG_citation() throws {
        let items = try Self.cases("citationCases")
        #expect(items.count == 12)
        for item in items {
            let caseId = try #require(item["caseId"] as? String)
            let profile = RelayWebFragments.citationProfile(
                transport: try Self.transport(item["transport"]),
                fragment: item["fragment"] as? [String: Any]
            )
            #expect(profile == item["expect"] as? String, "RELAY-WEBFRAG-citation-\(caseId)：\(profile ?? "nil")")
        }
    }

    // MARK: - presentation

    @Test("RELAY-WEBFRAG-presentation: shape of the web row in the model options panel")
    func RELAY_WEBFRAG_presentation() throws {
        let items = try Self.cases("presentationCases")
        #expect(items.count == 5)
        for item in items {
            let caseId = try #require(item["caseId"] as? String)
            let fragments = try #require(item["fragments"] as? [String: [String: Any]])
            let fact = RelayWebFragments.panelFact(
                engineProfile: item["engineProfile"] as? String,
                effectiveTransport: try Self.transport(item["effectiveTransport"]),
                fragments: RelayWebFragmentSet.from(objects: fragments)
            )
            let shape = ModelOptionCapabilityShape.resolve(.init(
                capability: .web,
                // The presentation state from the catalog must not affect a relay's web row: deliberately pass a value that would render as a switch.
                presentation: .automaticAvailable,
                availableIntents: ["off", "automatic"],
                selectedIntent: "automatic",
                connection: .custom,
                protocolUndecided: item["protocolUndecided"] as? Bool ?? false,
                relayWeb: fact
            ))
            let expect = try #require(item["expect"] as? [String: Any])
            let label = "RELAY-WEBFRAG-presentation-\(caseId)"
            switch expect["shape"] as? String {
            case "protocolUndecided":
                guard case .protocolUndecided = shape else { Issue.record("\(label)：\(shape)"); continue }
            case "disclosure":
                guard case let .disclosure(disclosure) = shape else { Issue.record("\(label)：\(shape)"); continue }
                // Rows with a fragment derive their state from local probe records (no record here = Set · not verified); all copy lives in the Chat table.
                #expect(disclosure.status == L10n.tr(expect["status"] as? String ?? "", table: .chat), "\(label)")
                if expect["action"] as? String == "openConnectionWebSearch" {
                    #expect(disclosure.action == .openConnectionWebSearch, "\(label)")
                }
            case "notice":
                guard case let .notice(notice) = shape else { Issue.record("\(label)：\(shape)"); continue }
                #expect(notice.status == L10n.tr(expect["status"] as? String ?? "", table: .chat), "\(label)")
                #expect(notice.link?.action == .openConnectionWebSearch, "\(label)")
                #expect(notice.link?.title == L10n.tr("Open web search settings", table: .chat), "\(label)")
            default:
                Issue.record("\(label): unknown fixture shape")
            }
        }
    }

    // MARK: - Detail page "Web" row

    /// Fetch the "Web" row by id: once the "Parameters" row is merged into the model card as its last row, it is no longer the final row.
    private static func webSearchRow(_ provider: Provider) -> RelayDetailBoardModel.Row? {
        RelayDetailBoardModel.make(provider)?.modelRows.first { $0.id == .webSearch }
    }

    private static func relayProvider(_ requested: RelayRequestedConfig = RelayRequestedConfig(transport: .openaiResponses)) -> Provider {
        Provider(
            id: UUID(), kind: .relay, status: .connected, models: [], catalogModels: [],
            apiKey: "sk", apiKeyPreview: "", baseURLText: "https://relay.test/v1", relayRequested: requested
        )
    }

    @Test("RELAY-WEBFRAG-detail: a relay model card has a Web row below the model-library row; the local engine does not")
    func RELAY_WEBFRAG_detail_row_appears() throws {
        let board = try #require(RelayDetailBoardModel.make(Self.relayProvider()))
        // Model card has three rows: model library -> web -> parameters (the "Parameters" row was merged in as the last row).
        #expect(board.modelRows.map(\.id) == [.modelLibrary, .webSearch, .parameters])
        let row = try #require(board.modelRows.first { $0.id == .webSearch })
        #expect(row.destination == .webSearch)
        #expect(row.titleKey == "Web Search")
        #expect(row.value == .key("Set this up if the service behind this connection runs its own web search"))

        var local = Self.relayProvider(RelayRequestedConfig(transport: .openaiChatCompletions, engineProfile: "ollama"))
        local.baseURLText = "http://127.0.0.1:11434"
        let localBoard = try #require(RelayDetailBoardModel.make(local))
        #expect(!localBoard.modelRows.contains { $0.id == .webSearch })
    }

    @Test("RELAY-WEBFRAG-detail: the Web row status follows the effective fragment (store plus legacy-field mapping)")
    func RELAY_WEBFRAG_detail_row_status() throws {
        let provider = Self.relayProvider()
        defer { RelayWebFragmentStore.shared.deleteConnection(provider.id) }
        #expect(Self.webSearchRow(provider)?.trailingKey == "Not set up")
        RelayWebFragmentStore.shared.save(connectionID: provider.id, transport: .openaiResponses, raw: #"{"tools":[{"type":"web_search"}]}"#)
        #expect(Self.webSearchRow(provider)?.trailingKey == "Set up")

        RelayWebFragmentStore.shared.deleteConnection(provider.id)
        var legacy = RelayRequestedConfig(transport: .openaiResponses)
        legacy = try JSONDecoder().decode(
            RelayRequestedConfig.self, from: Data(#"{"transport":"openai_responses","hasWebSearch":true}"#.utf8)
        )
        #expect(Self.webSearchRow(Self.relayProvider(legacy))?.trailingKey == "Set up")
    }

    // MARK: - Saving from the web settings page

    @Test("RELAY-WEBFRAG-save: saving writes the store (empty sections are deleted) and clears the two legacy fields")
    func RELAY_WEBFRAG_save_clears_legacy_fields() throws {
        let requested = try JSONDecoder().decode(
            RelayRequestedConfig.self,
            from: Data(#"{"transport":"openai_responses","hasWebSearch":true,"webSearchProfile":"future_web"}"#.utf8)
        )
        let provider = Self.relayProvider(requested)
        let store = Self.isolatedStore()
        var draft = RelayWebSearchDraft.initial(provider: provider, store: store)
        // With no store, the editor shows the legacy-field mapping result.
        #expect(Set(draft.texts.keys) == ["openai_responses", "gemini_generate_content"])
        draft.clear(.geminiGenerateContent)
        draft.setText(#"{"model":"x"}"#, for: .openaiChatCompletions)
        #expect(!draft.canSave)
        #expect(draft.error(.openaiChatCompletions) == .forbiddenKey("model"))
        #expect(draft.save(provider: provider, store: store) == nil, "nothing is written when there are errors")
        draft.useTemplate(.openaiChatCompletions)

        let saved = try #require(draft.save(provider: provider, store: store))
        #expect(saved.relayRequested?.hasWebSearch == nil)
        #expect(saved.relayRequested?.webSearchProfile == nil)
        #expect(saved.relayRequested?.transport == .openaiResponses, "other fields are untouched")
        #expect(Set(store.stored(connectionID: provider.id).keys) == ["openai_responses", "openai_chat_completions"])
    }
}
