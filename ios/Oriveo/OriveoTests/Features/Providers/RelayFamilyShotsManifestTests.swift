import Foundation
import Testing
@testable import Oriveo

/// The debug-shots entry reads the shared manifest `shared/test-fixtures/shots/relay.v1.json` (same-named tests on every platform).
/// Expected values are what `RelayFamilyDebugShots.Demo` produced before the manifest existed (as literals); the manifest only moves them without changing any value.
/// The manifest holds the same values on every platform and follows the iOS golden values.
@Suite("Shots manifest: relay family", .serialized)
@MainActor
struct RelayFamilyShotsManifestTests {
    typealias Shots = RelayFamilyDebugShots
    typealias Manifest = RelayFamilyDebugShots.Manifest

    private static func manifestData() throws -> Data {
        try Shots.manifestData()
    }

    private static func stage(_ shot: Shots.Shot, data: Data? = nil) throws -> Shots.Staged {
        let bytes = try data ?? manifestData()
        return try #require(Shots.stage(shot, manifestData: { bytes }))
    }

    /// Edits a copy of the manifest: `edit` receives the parsed mutable dictionary.
    private static func editedManifest(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: manifestData()) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("shotsManifestPagesMatchImplemented: the manifest page-name set == this platform's page-name table")
    func shotsManifestPagesMatchImplemented() throws {
        let manifest = try Manifest.load(from: Self.manifestData())
        #expect(Set(manifest.pages.map(\.name)) == Set(Shots.Shot.allCases.map(\.rawValue)))
        #expect(manifest.pages.count == Shots.Shot.allCases.count)
    }

    @Test("shotsManifestWebProbeRecords: relayWebSearchRejected writes a rejected record keyed by the current fragment hash, and the page lists that model in its rejection area")
    func shotsManifestWebProbeRecords() throws {
        let shot = try #require(Shots.Shot(rawValue: "relayWebSearchRejected"), "relayWebSearchRejected is not implemented on this platform")
        let staged = try Self.stage(shot)
        #expect(staged.path.last == .relayWebSearch(providerID: staged.relay.id))
        let suite = "relay-shots-web-probe-\(UUID().uuidString)"
        let fragments = RelayWebFragmentStore(defaults: UserDefaults(suiteName: suite + "-fragments")!)
        let records = RelayWebProbeStore(defaults: UserDefaults(suiteName: suite + "-records")!)
        Shots.seedWebProbeState(staged, fragments: fragments, records: records)
        let rejected = RelayWebSearchBoardModel.rejectedModels(provider: staged.relay, fragments: fragments, records: records)
        #expect(rejected.map(\.modelID) == ["claude-sonnet-5"])
        let record = records.record(
            connectionID: staged.relay.id.uuidString, modelID: "claude-sonnet-5", transport: "openai_chat_completions"
        )
        #expect(record?.result == .rejected && record?.source == .tested)
    }

    /// Temporary stores: fragments / records / preferences, the same types as production.
    private static func webStores() -> (RelayWebFragmentStore, RelayWebProbeStore, GenerationParameterSettingsStore) {
        let suite = "relay-shots-model-options-\(UUID().uuidString)"
        return (
            RelayWebFragmentStore(defaults: UserDefaults(suiteName: suite + "-fragments")!),
            RelayWebProbeStore(defaults: UserDefaults(suiteName: suite + "-records")!),
            GenerationParameterSettingsStore(defaults: UserDefaults(suiteName: suite + "-preferences")!)
        )
    }

    /// After the stores are seeded from the shot presets, the panel web row is computed by the production `RelayWebSwitch.isOn` + `RelayWebProbe.panelFact`.
    private static func modelOptionsFact(_ shot: Shots.Shot) throws -> RelayWebFact {
        let staged = try Self.stage(shot)
        let modelID = try #require(staged.presets.chatModelID)
        #expect(modelID == "gpt-5.6-sol")
        let model = try #require(staged.relay.models.first { $0.id == modelID })
        let (fragments, records, preferences) = Self.webStores()
        Shots.seedWebProbeState(staged, fragments: fragments, records: records)
        Shots.seedChatWebPreference(staged, store: preferences)
        // No saved fragment: the effective fragment is the first-send protocol (Responses) template.
        #expect(fragments.chatFragments(for: staged.relay) == nil)
        #expect(RelayWebProbe.transport(provider: staged.relay, model: model) == .openaiResponses)
        let isOn = RelayWebSwitch.isOn(
            provider: staged.relay, model: model, conversationID: UUID(), store: preferences, fragments: fragments
        )
        let shape = RelayWebProbe.panelFact(
            provider: staged.relay, model: model, preference: isOn, fragments: fragments, records: records
        )
        guard case let .relay(fact) = shape else {
            Issue.record("the panel web row is not a relay fact: \(shape)")
            throw ShapeMismatch()
        }
        return fact
    }

    private struct ShapeMismatch: Error {}

    @Test("shotsManifestModelOptionsWeb: template hash searched + chat web on -> toggle on, Search confirmed")
    func shotsManifestModelOptionsWeb() throws {
        let fact = try Self.modelOptionsFact(.relayModelOptionsWeb)
        #expect(fact.savedFragment == false)
        #expect(fact.probe == .searched)
        #expect(fact.preference == true)
        #expect(fact.row == .toggle)
        #expect(fact.isOn)
        #expect(fact.statusId == .searched)
        #expect(fact.retestLink == nil)
        #expect(try Self.stage(.relayModelOptionsWeb).path.isEmpty)
    }

    @Test("shotsManifestModelOptionsWebRejected: template hash rejected, preference unset -> still an operable toggle, rejected, Test capabilities")
    func shotsManifestModelOptionsWebRejected() throws {
        let staged = try Self.stage(.relayModelOptionsWebRejected)
        #expect(staged.presets.chatWebSearch == false)
        let fact = try Self.modelOptionsFact(.relayModelOptionsWebRejected)
        #expect(fact.savedFragment == false)
        #expect(fact.probe == .rejected)
        #expect(fact.row == .toggle)
        #expect(fact.isOn == false)
        #expect(fact.statusId == .rejected)
        #expect(fact.retestLink == .openTestCapabilities)
    }

    @Test("shotsManifestAdvancedWebRow: relayAdvanced template hash searched + tested web override -> Search confirmed · Tested")
    func shotsManifestAdvancedWebRow() throws {
        let staged = try Self.stage(.relayAdvanced)
        let model = try #require(staged.relay.models.first { $0.id == "gpt-5.6-sol" })
        #expect(model.relayCapabilityOverrides?.web == true)
        #expect(model.relayCapabilityOverrides?.sources[.web] == .tested)
        #expect(staged.relay.catalogModels.first { $0.id == model.id } == model)
        let (fragments, records, _) = Self.webStores()
        Shots.seedWebProbeState(staged, fragments: fragments, records: records)
        let fact = try #require(RelayWebProbe.fact(
            provider: staged.relay, model: model, preference: nil, fragments: fragments, records: records
        ))
        #expect(fact.probeStatus == .searched)
        #expect(fact.advancedSource == .tested)
        #expect(fact.userOverride == nil)
    }

    @Test("shotsManifestBuildsDemoRelay: the demo connection built matches the pre-manifest one field by field")
    func shotsManifestBuildsDemoRelay() throws {
        let staged = try Self.stage(.relayDetail)
        let relay = staged.relay
        #expect(relay.id == UUID(uuidString: "5E1A7000-0000-4000-8000-000000000001"))
        #expect(relay.kind == .relay)
        #expect(relay.status == .connected)
        #expect(relay.lastError == nil)
        #expect(relay.customName == "Demo Relay")
        #expect(relay.baseURLText == "https://api.relay-demo.example")
        #expect(relay.apiKey == "sk-relay-demo-main-7Q4f")
        #expect(relay.apiKeyPreview == APIKeyMask.masked("sk-relay-demo-main-7Q4f"))
        #expect(relay.relayRequested?.transport == .auto)
        #expect(relay.relayRequested?.authMode == .bearer)
        #expect(relay.relayRequested?.securityMode == .remoteHTTPS)
        #expect(relay.relayRequested?.resolvedAPIBaseURLs == [
            "openai_chat_completions": "https://api.relay-demo.example/v1",
            "openai_responses": "https://api.relay-demo.example/v1",
        ])
        #expect(relay.cachedAvailableModelCount == 9)

        // Three keys: the main key's httpStatus is nil (null in the manifest).
        let keys = try #require(relay.relayKeys)
        #expect(keys.map(\.id) == [RelayKeyBinding.implicitKeyID, "k-demo-backup", "k-demo-team"])
        #expect(keys.map(\.name) == ["Main", "Backup", nil])
        #expect(keys.map(\.apiKey) == ["", "sk-relay-demo-backup-9Zc2", "sk-relay-demo-team-51Lx"])
        #expect(keys.map(\.status?.state) == [.ok, .invalid, .limited])
        #expect(keys.map(\.status?.httpStatus) == [nil, 401, 429])

        let main = RelayKeyBinding.implicitKeyID
        #expect(relay.catalogModels.map(\.id) == [
            "gpt-5.6-sol", "gpt-5.6-mini", "gpt-image-1", "claude-sonnet-5", "claude-opus-5", "claude-haiku-5",
            "relay-chat-large", "claude-sonnet-5-extended-thinking-preview-20261001", "deepseek-chat",
        ])
        #expect(relay.catalogModels.map(\.relayListedByKeyIDs) == [
            [main, "k-demo-team"], [main, "k-demo-team"], [main], ["k-demo-backup"], ["k-demo-backup"], ["k-demo-backup"],
            [main], ["k-demo-backup"], ["k-demo-team"],
        ])

        #expect(relay.models.map(\.id) == [
            "gpt-5.6-sol", "claude-sonnet-5", "relay-chat-large", "claude-sonnet-5-extended-thinking-preview-20261001",
        ])
        #expect(relay.models.map(\.relayKeyID) == [main, "k-demo-backup", main, "k-demo-backup"])
        #expect(relay.models.map(\.relayCapabilityOverrides) == [
            RelayCapabilityOverrides(image: true, toolCall: true, source: .tested),
            RelayCapabilityOverrides(image: true, file: false),
            nil, nil,
        ])
        #expect(relay.models.map(\.relayTransport) == [.openaiResponses, .openaiChatCompletions, nil, nil])
        #expect(relay.models.map(\.relayTransportSource) == [.observed, .reachable, nil, nil])
        // The enabled row and the catalog write the same model together.
        for model in relay.models {
            #expect(relay.catalogModels.first { $0.id == model.id } == model)
        }

        let last = try Self.stage(.relayLibraryLast).relay
        #expect(last.models.map(\.id) == ["gpt-5.6-sol"])

        for shot in [Shots.Shot.relayDetailIssue, .relayAdvancedFixed] {
            let chosen = try Self.stage(shot).relay
            #expect(chosen.relayRequested?.transport == .openaiResponses)
            #expect(chosen.models.allSatisfy { $0.relayTransport == nil && $0.relayTransportSource == nil })
            #expect(chosen.models.first?.relayCapabilityOverrides == RelayCapabilityOverrides(
                image: true, toolCall: true, source: .tested
            ))
        }
        let issue = try Self.stage(.relayDetailIssue).relay
        #expect(issue.status == .issue(ProviderIssueMessage.unverifiedConnectionKey))
        #expect(issue.lastError == ProviderIssueMessage.unverifiedConnectionKey)
        #expect(try Self.stage(.relayAdvancedFixed).relay.status == .connected)

        // relayKeysAdded: the team key is staged as just added with an ok fetch, and the page presets the success notice computed by the production notice logic (3 listed, only this key listed 1).
        let added = try Self.stage(.relayKeysAdded)
        #expect(added.relay.relayKeys?.first { $0.id == "k-demo-team" }?.status?.state == .ok)
        #expect(added.presets.keysNotices == [.added(keyID: "k-demo-team", listed: 3, new: 1)])
        #expect(staged.presets.keysNotices.isEmpty)

        // Local engine: the manifest writes false out explicitly.
        let local = staged.local
        #expect(local.id == UUID(uuidString: "5E1A7000-0000-4000-8000-000000000002"))
        #expect(local.customName == "Studio Ollama")
        #expect(local.baseURLText == "http://192.168.1.20:11434")
        #expect(local.relayRequested?.transport == .openaiChatCompletions)
        #expect(local.relayRequested?.authMode == RelayAuthMode.none)
        #expect(local.relayRequested?.securityMode == .localHTTP)
        #expect(local.relayRequested?.engineProfile == "ollama")
        #expect(local.catalogModels.map(\.id) == ["qwen3:8b", "llama3.3:70b", "gemma3:12b"])
        #expect(local.catalogModels.map(\.engineDeclaration) == [
            EngineDeclaration(image: false, toolCall: true, thinking: true),
            EngineDeclaration(toolCall: true, thinking: false),
            EngineDeclaration(image: true),
        ])
        #expect(local.models.map(\.id) == ["qwen3:8b", "llama3.3:70b"])
        #expect(local.cachedAvailableModelCount == 3)

        #expect(staged.setupCatalog == [
            "gpt-5.6-sol", "gpt-5.6-mini", "gpt-image-1", "claude-sonnet-5", "claude-opus-5", "claude-haiku-5",
            "deepseek-chat", "relay-chat-large", "claude-sonnet-5-extended-thinking-preview-20261001",
        ])
    }

    @Test("shotsManifestValuesFollowManifest: editing the manifest changes the output accordingly")
    func shotsManifestValuesFollowManifest() throws {
        let data = try Self.editedManifest { object in
            var relay = object["relay"] as? [String: Any] ?? [:]
            relay["name"] = "Changed Relay"
            object["relay"] = relay
            let catalog = object["setupCatalog"] as? [Any] ?? []
            object["setupCatalog"] = Array(catalog.prefix(2))
            var pages = object["pages"] as? [[String: Any]] ?? []
            for index in pages.indices where pages[index]["name"] as? String == "relayCapabilityTest" {
                var preset = pages[index]["preset"] as? [String: Any] ?? [:]
                var test = preset["capabilityTest"] as? [String: Any] ?? [:]
                var results = test["results"] as? [String: Any] ?? [:]
                var text = results["text"] as? [String: Any] ?? [:]
                text["elapsedMs"] = 999
                results["text"] = text
                test["results"] = results
                preset["capabilityTest"] = test
                pages[index]["preset"] = preset
            }
            object["pages"] = pages
        }
        let detail = try Self.stage(.relayDetail, data: data)
        #expect(detail.relay.customName == "Changed Relay")
        #expect(detail.setupCatalog == ["gpt-5.6-sol", "gpt-5.6-mini"])
        let seed = try #require(try Self.stage(.relayCapabilityTest, data: data).presets.capabilityTest)
        #expect(seed.input.results[.text]?.elapsedMs == 999)
        #expect(seed.input.results[.image]?.elapsedMs == 860)
    }

    @Test("shotsManifestUnreadableRefuses: an invalid manifest or one missing relay fails to load and the entry refuses to open")
    func shotsManifestUnreadableRefuses() throws {
        let broken = Data("{ not json".utf8)
        #expect(throws: (any Error).self) { try Manifest.load(from: broken) }
        #expect(Shots.stage(.relayDetail, manifestData: { broken }) == nil)

        let missingRelay = try Self.editedManifest { $0.removeValue(forKey: "relay") }
        #expect(throws: (any Error).self) { try Manifest.load(from: missingRelay) }
        #expect(Shots.stage(.relayDetail, manifestData: { missingRelay }) == nil)

        // An unreadable file is refused as well.
        struct Unreadable: Error {}
        #expect(Shots.stage(.relayDetail, manifestData: { throw Unreadable() }) == nil)

        // A page absent from the manifest is refused the same way as an unknown page name.
        let withoutPage = try Self.editedManifest { object in
            let pages = object["pages"] as? [[String: Any]] ?? []
            object["pages"] = pages.filter { $0["name"] as? String != "relayKeys" }
        }
        #expect(Shots.stage(.relayKeys, manifestData: { withoutPage }) == nil)
        #expect(Shots.stage(.relayDetail, manifestData: { withoutPage }) != nil)
    }
}
