import Foundation
import Testing
@testable import Oriveo

/// Result-facts matrix consumer.  This deliberately reads the shared roster instead of copying its provider
/// list: adding a new catalog category row without iOS coverage fails this suite immediately.
@Suite("Shared result-facts matrix")
struct ProviderRecipeResultFactsTests {
    @Test("all 15 production-parser categories and all recovery cases are consumed fail-closed")
    func consumesSharedMatrixWithoutSyntheticSuccess() throws {
        let fixture: Fixture = try Self.load(["shared", "model-contracts", "provider_recipe_result_facts.v1.json"])
        #expect(fixture.providerResultCoverage.count == 15)
        #expect(Set(fixture.providerResultCoverage.map(\.providerKind)).count == 15)
        #expect(fixture.recoveryCases.count >= 25)

        // Category 7: the fixture only declares observed where its named production parser emits
        // a normalized production event.  We do not manufacture a parser event here; actual
        // services feed StreamEvent.citations/reasoning into ChatManager, while missing events
        // settle as unconfirmed in CapabilityExecutionTracker.
        for row in fixture.providerResultCoverage {
            #expect(!row.producerFixture.isEmpty)
            switch row.expected {
            case "observed": #expect(!row.producerEvents.isEmpty)
            case "unconfirmed": #expect(row.producerEvents.isEmpty)
            case "no_execution_fact": #expect(row.producerEvents.isEmpty && row.recipeRef.contains(".generation."))
            default: Issue.record("Unknown result expectation for \(row.providerKind): \(row.expected)")
            }
        }

        // Category 8: Server's currently published definitions intentionally have no approved
        // structural locator.  Every fixture case must therefore surface its error; the iOS side
        // bypasses the legacy heuristic whenever the tracker is active, including Relay's
        // independent branch.  A case may carry automaticRetryCount == 1 to represent a prior
        // attempt (recovery.second_attempt_never_repeats); the empty locator map still permits
        // no further automatic recovery.  Mirrors the shared Web assertion.
        for entry in fixture.recoveryCases {
            #expect(entry.automaticRetryCount <= 1)
            if entry.source == "custom" {
                #expect(entry.expected == "user_confirmed_resend_without_located_setting")
            } else {
                #expect(entry.expected == "surface_error")
            }
        }
    }

    @Test("execution facts and custom payload cannot enter cloud/telemetry envelopes")
    func privacyBoundaryIsExplicitInProductionSources() throws {
        let model = try String(contentsOf: Self.file([
            "ios", "Oriveo", "Oriveo", "Core", "Models", "ChatModels.swift",
        ]), encoding: .utf8)
        let mapper = try String(contentsOf: Self.file([
            "ios", "Oriveo", "Oriveo", "Core", "Database", "RecordMappers.swift",
        ]), encoding: .utf8)
        let manager = try String(contentsOf: Self.file([
            "ios", "Oriveo", "Oriveo", "Core", "State", "ChatManager.swift",
        ]), encoding: .utf8)
        #expect(model.contains("capabilityExecution = nil"))
        #expect(model.contains("must never cross the Codable/cloud"))
        #expect(mapper.contains("encodeCapabilityExecution"))
        #expect(model.contains("unhandledToolCalls = nil"))
        #expect(mapper.contains("encodeUnhandledToolCalls"))
        #expect(manager.contains("custom_request_fields_rejected"))
        #expect(!manager.contains("\"recipe_ref\""))
        #expect(!manager.contains("\"capability_execution\""))
        #expect(!manager.contains("\"custom_fragment\""))
    }

    private struct Fixture: Decodable {
        let providerResultCoverage: [ProviderCoverage]
        let recoveryCases: [RecoveryCase]
    }
    private struct ProviderCoverage: Decodable {
        let providerKind: String
        let recipeRef: String
        let expected: String
        let producerFixture: String
        let producerEvents: [String]
    }
    private struct RecoveryCase: Decodable {
        let source: String
        let expected: String
        let automaticRetryCount: Int
    }

    private static func load<T: Decodable>(_ components: [String]) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: file(components)))
    }
    private static func file(_ components: [String]) -> URL {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let candidate = components.reduce(folder) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            folder = folder.deletingLastPathComponent()
        }
        fatalError("fixture not found")
    }
}
