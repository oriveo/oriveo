import Foundation
import Testing
@testable import Oriveo

/// RL2-WEBPROBE-STATE: web_search truth for relays, driven by `shared/test-fixtures/relay/web-probe.v1.json`
/// presentationCases: saved fragments, probe records and user overrides are really written into the production shared store / model, and the web_search state is read from the production capability projection
/// (the model library globe and the capability badge share one entry point, `ChatView.capabilityProjection` -> RelayTruthAdapter).
/// Truth = user override > record for the current (effective fragment hash) > unknown, independent of the chat web toggle.
@Suite("RL2-WEBPROBE-STATE - relay web truth", .serialized)
@MainActor
struct RelayWebSearchTruthTests {
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

    nonisolated private static let fixture: [String: Any] = (try? loadFixture("web-probe.v1.json")) ?? [:]

    nonisolated private static let cases: [[String: Any]] =
        (fixture["presentationCases"] as? [String: Any])?["cases"] as? [[String: Any]] ?? []

    nonisolated private static let caseIds = cases.compactMap { $0["caseId"] as? String }

    private static let transport = RelayTransport.openaiChatCompletions

    private static func model(userOverride: Bool?) -> AIModel {
        var model = AIModel(
            id: "relay-web-truth-model", name: "relay-web-truth-model", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        model.relayTransport = transport
        model.relayTransportSource = .reachable
        if let userOverride { model.relayCapabilityOverrides = RelayCapabilityOverrides(web: userOverride, source: .user) }
        return model
    }

    private static func provider(_ model: AIModel) -> Provider {
        Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "sk-relay", apiKeyPreview: "...elay", baseURLText: "https://relay-web-truth.test/v1",
            relayRequested: RelayRequestedConfig(transport: transport)
        )
    }

    private static let savedRaw = #"{"web_search_options":{"search_context_size":"low"}}"#

    @Test("RL2-WEBPROBE-08 STATE", arguments: caseIds)
    func state(caseId: String) throws {
        let label = "RL2-WEBPROBE-STATE-\(caseId)"
        #expect(Self.caseIds.count == 12, "\(label) fixture case count")
        let testCase = try #require(Self.cases.first { $0["caseId"] as? String == caseId }, "\(label)")
        let expect = try #require(testCase["expect"] as? [String: Any], "\(label)")
        let model = Self.model(userOverride: testCase["userOverride"] as? Bool)
        let provider = Self.provider(model)
        defer {
            RelayWebFragmentStore.shared.deleteConnection(provider.id)
            RelayWebProbeStore.shared.clearConnection(provider.id.uuidString)
        }
        let saved = testCase["savedFragment"] as? Bool == true
        let raw = saved ? Self.savedRaw : try #require(RelayWebFragments.template(for: Self.transport), "\(label) template")
        let fragment = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        if saved {
            #expect(
                RelayWebFragmentStore.shared.save(connectionID: provider.id, transport: Self.transport, raw: raw) == nil,
                "\(label) store fragment"
            )
        }
        if let record = testCase["record"] as? [String: Any] {
            let result = try #require(RelayWebProbeRecord.Result(rawValue: record["result"] as? String ?? ""))
            let hash = record["fragmentHash"] as? String == "current"
                ? RelayWebProbe.fragmentHash(fragment)
                : RelayWebProbe.fragmentHash(["other": true])
            RelayWebProbeStore.shared.record(
                connectionID: provider.id.uuidString, modelID: model.id, transport: Self.transport.rawValue,
                result: result, source: .tested, fragmentHash: hash
            )
        }

        let projection = ChatView.capabilityProjection(
            provider: provider, model: model, partitionID: "relay-web-search-truth-tests"
        )
        let support = projection.resolution(for: "web_search")?.support
        let truth: String = switch support {
        case .supported?: "supported"
        case .unsupported?: "unsupported"
        case .unknown?, nil: "unknown"
        }
        #expect(truth == expect["truth"] as? String, "\(label) truth: \(String(describing: support))")

        // Production decision of the input bar web control: every in-scope relay model has the toggle (whether it is on is decided separately by the preference).
        let verdict = CapabilityControlResolution.resolve(provider: provider, model: model, capability: "web")
        #expect(verdict.state == .customOnly, "\(label) toggle available: \(verdict.state) \(verdict.reasonCode ?? "nil")")
    }
}
