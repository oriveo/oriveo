import Foundation
import Testing
@testable import Oriveo

/// RL2-WEBPROBE-STATE: web_search truth for relays, driven by `shared/test-fixtures/relay/web-probe.v1.json`
/// presentationCases: fragments and probe records are really written into the production shared store, and the web_search state is read from the production capability projection
/// (the model library globe and the capability badge share one entry point, `ChatView.capabilityProjection` -> RelayTruthAdapter),
/// while sendsFragment is read from the production decision of the input bar web control, `CapabilityControlResolution.resolve`.
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

    private static func model() -> AIModel {
        var model = AIModel(
            id: "relay-web-truth-model", name: "relay-web-truth-model", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        model.relayTransport = transport
        model.relayTransportSource = .reachable
        return model
    }

    private static func provider(_ model: AIModel) -> Provider {
        Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [],
            apiKey: "sk-relay", apiKeyPreview: "...elay", baseURLText: "https://relay-web-truth.test/v1",
            relayRequested: RelayRequestedConfig(transport: transport)
        )
    }

    @Test("RL2-WEBPROBE-STATE", arguments: caseIds)
    func state(caseId: String) throws {
        let label = "RL2-WEBPROBE-STATE-\(caseId)"
        #expect(Self.caseIds.count == 6, "\(label) fixture case count")
        let testCase = try #require(Self.cases.first { $0["caseId"] as? String == caseId }, "\(label)")
        let expect = try #require(testCase["expect"] as? [String: Any], "\(label)")
        let model = Self.model()
        let provider = Self.provider(model)
        defer {
            RelayWebFragmentStore.shared.deleteConnection(provider.id)
            RelayWebProbeStore.shared.clearConnection(provider.id.uuidString)
        }
        let raw = try #require(RelayWebFragments.template(for: Self.transport), "\(label) template")
        let fragment = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        if testCase["hasFragment"] as? Bool == true {
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
        let state: String = switch support {
        case .supported?: "supported"
        case .unsupported?: "unsupported"
        case .unknown?, nil: "unknown"
        }
        #expect(state == expect["state"] as? String, "\(label) state：\(String(describing: support))")

        let verdict = CapabilityControlResolution.resolve(provider: provider, model: model, capability: "web")
        #expect(
            (verdict.state == .customOnly) == (expect["sendsFragment"] as? Bool),
            "\(label) sendsFragment：\(verdict.state) \(verdict.reasonCode ?? "nil")"
        )
    }
}
