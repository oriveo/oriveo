import Foundation
import Testing
@testable import Oriveo

/// RL2-WEBPROBE-KEY: driven by `preferenceIdentity` in `shared/test-fixtures/relay/web-probe.v1.json`.
/// The relay web switch stores its preference under one fixed identity (relay / relay-web) that does not change
/// with the transport or the metadata version; when a scope has no record under the fixed identity, the newest
/// web value under an older identity in the same scope is read and written back once. Goes through the production `RelayWebSwitch`.
@Suite("RL2-WEBPROBE-KEY · relay web preference fixed addressing", .serialized)
@MainActor
struct RelayWebPreferenceIdentityTests {
    nonisolated private static func loadFixture(_ name: String) throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return (object as? [String: Any]) ?? [:]
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    nonisolated private static let section: [String: Any] =
        ((try? loadFixture("web-probe.v1.json")) ?? [:])["preferenceIdentity"] as? [String: Any] ?? [:]
    nonisolated private static let cases: [[String: Any]] = section["cases"] as? [[String: Any]] ?? []
    nonisolated private static let caseIds = cases.compactMap { $0["caseId"] as? String }

    private static func isolatedDefaults() -> UserDefaults {
        let name = "relay-web-key-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A model on an auto connection; `transport` nil = transport not decided yet, anything else = the model's own transport.
    private static func pair(modelID: String, transport: String?, providerID: UUID) -> (Provider, AIModel) {
        var model = TestFactories.makeModel(id: modelID, capabilities: [.text], isDefault: true)
        if let transport, let value = RelayTransport(rawValue: transport) {
            model.relayTransport = value
            model.relayTransportSource = .user
        }
        let provider = Provider(
            id: providerID, kind: .relay, status: .connected, models: [model], catalogModels: [model],
            apiKey: "sk-test", apiKeyPreview: "...test", baseURLText: "https://relay-key.example.com/v1",
            relayRequested: RelayRequestedConfig(transport: .auto)
        )
        return (provider, model)
    }

    private static func values(_ web: String) throws -> CapabilityPreferenceValues {
        CapabilityPreferenceValues(web: try #require(CapabilityWebPreference(rawValue: web)))
    }

    @Test("RL2-WEBPROBE-KEY", arguments: caseIds)
    func key(caseId: String) throws {
        let label = "RL2-WEBPROBE-KEY-\(caseId)"
        #expect(Self.caseIds.count == 4, "\(label) fixture count")
        let testCase = try #require(Self.cases.first { $0["caseId"] as? String == caseId })
        let expect = try #require(testCase["expect"] as? [String: Any])
        let modelID = try #require(testCase["modelId"] as? String)
        let providerID = UUID()
        let store = GenerationParameterSettingsStore(defaults: Self.isolatedDefaults())
        let fragments = RelayWebFragmentStore(defaults: Self.isolatedDefaults())
        let fixed = try #require(Self.section["wire"] as? String)

        switch caseId {
        case "identity_ignores_transport":
            let transports = (testCase["transports"] as? [Any] ?? []).map { $0 as? String }
            let pairs = transports.map { Self.pair(modelID: modelID, transport: $0, providerID: providerID) }
            for (provider, model) in pairs {
                #expect(RelayWebSwitch.transportIdentity(provider: provider, model: model) == expect["wire"] as? String,
                        "\(label) wire（\(model.relayTransport?.rawValue ?? "null")）")
                #expect(RelayWebSwitch.modelID(provider: provider, model: model) == expect["canonicalModelId"] as? String,
                        "\(label) canonicalModelId")
            }
            // Write under the first transport; every other transport reads the same record.
            let conversation = UUID()
            RelayWebSwitch.write(true, provider: pairs[0].0, model: pairs[0].1, conversationID: conversation, store: store)
            for (provider, model) in pairs {
                #expect(RelayWebSwitch.isOn(
                    provider: provider, model: model, conversationID: conversation, store: store, fragments: fragments
                ) == true, "\(label) same record (\(model.relayTransport?.rawValue ?? "null")）")
            }

        case "write_before_transport_decided_reads_after":
            let steps = try #require(testCase["steps"] as? [[String: Any]])
            let (provider, model) = Self.pair(modelID: modelID, transport: steps[0]["transport"] as? String, providerID: providerID)
            let draft = UUID(), c1 = UUID()
            RelayWebSwitch.write(steps[0]["write"] as? String == "on", provider: provider, model: model, conversationID: draft, store: store)
            // First send of a new conversation: the draft-scope record moves to the real conversation (the same function AppState.sendMessage calls), after which the transport is decided.
            RelayWebSwitch.migrateSession(provider: provider, model: model, from: draft, to: c1, store: store)
            let (after, afterModel) = Self.pair(modelID: modelID, transport: steps[1]["transportAfter"] as? String, providerID: providerID)
            #expect(RelayWebSwitch.isOn(
                provider: after, model: afterModel, conversationID: c1, store: store, fragments: fragments
            ) == expect["isOn"] as? Bool, "\(label) isOn")

        default:
            let legacy = try #require(testCase["legacyRecord"] as? [String: Any])
            #expect(legacy["scope"] as? String == "connection_model", "\(label) precondition: fixture scope")
            let (provider, model) = Self.pair(modelID: modelID, transport: legacy["finalTransport"] as? String, providerID: providerID)
            let legacyWire = try #require(CapabilityPreferenceRuntimeIdentity(
                canonicalModelID: modelID, finalTransport: try #require(legacy["finalTransport"] as? String),
                runtimeRevision: try #require(legacy["runtimeRevision"] as? String)
            ).wireValue)
            store.setCapabilityPreferences(
                try Self.values(try #require(legacy["web"] as? String)), providerID: providerID, modelID: modelID,
                conversationID: nil, transportIdentity: legacyWire
            )
            var fixedBefore: CapabilityPreferenceValues?
            if let record = testCase["fixedRecord"] as? [String: Any] {
                store.setCapabilityPreferences(
                    try Self.values(try #require(record["web"] as? String)), providerID: providerID, modelID: modelID,
                    conversationID: nil, transportIdentity: fixed
                )
                fixedBefore = store.capabilityPreferences(
                    providerID: providerID, modelID: modelID, conversationID: nil, transportIdentity: fixed
                )
            }
            let isOn = RelayWebSwitch.isOn(
                provider: provider, model: model, conversationID: UUID(), store: store, fragments: fragments
            )
            #expect(isOn == expect["isOn"] as? Bool, "\(label) isOn")
            let fixedAfter = store.capabilityPreferences(
                providerID: providerID, modelID: modelID, conversationID: nil, transportIdentity: fixed
            )
            if expect["fixedRecordWritten"] as? Bool == true {
                #expect(fixedBefore == nil && fixedAfter?.web == CapabilityWebPreference(rawValue: legacy["web"] as? String ?? ""),
                        "\(label) written back to the fixed identity: \(String(describing: fixedAfter))")
                // The write-back happens once: reading again changes nothing (the value matches the old record; the reasoning level does not move).
                #expect(fixedAfter?.reasoningIntent == nil, "\(label) only web moves")
            } else {
                #expect(fixedAfter == fixedBefore, "\(label) the fixed record is not overwritten by the old record: \(String(describing: fixedAfter))")
            }
        }
    }
}
