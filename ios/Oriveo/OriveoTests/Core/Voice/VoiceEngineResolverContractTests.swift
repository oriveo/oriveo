import Foundation
import Testing
@testable import Oriveo

/// The production VoiceEngineResolver matches the resolveCases and optionCases in shared/voice-contracts/engine-resolution.v2.json.
@Suite("Voice engine resolver contract")
struct VoiceEngineResolverContractTests {

    // MARK: Fixture parsing

    private struct CaseInput {
        let id: String
        let direction: VoiceDirection
        let catalog: VoiceCatalog
        let connections: [VoiceConnection]
        let raw: [String: Any]
    }

    private static func caseInput(_ item: [String: Any]) throws -> CaseInput {
        let id = item["id"] as? String ?? "?"
        let input = try #require(item["input"] as? [String: Any], "\(id) is missing input")
        let direction = try #require((input["direction"] as? String).flatMap(VoiceDirection.init(rawValue:)), "\(id) direction")
        let document = try VoiceCatalogContractTests.catalogDocument(input["catalog"])
        let rawConnections = try #require(input["connections"] as? [[String: Any]], "\(id) connections")
        let connections = try rawConnections.map { raw in
            VoiceConnection(
                id: try #require(raw["id"] as? String),
                providerKind: try #require((raw["providerKind"] as? String).flatMap(ProviderKind.init(rawValue:))),
                authMode: try #require((raw["authMode"] as? String).flatMap(ProviderAuthMode.init(rawValue:))),
                hasKey: try #require(raw["hasKey"] as? Bool)
            )
        }
        return CaseInput(
            id: id,
            direction: direction,
            catalog: VoiceCatalogDecoder.decode(document),
            connections: connections,
            raw: input
        )
    }

    private static func selection(_ raw: Any?, id: String) throws -> VoiceEngineSelection {
        let selection = try #require(raw as? [String: Any], "\(id) selection")
        switch selection["engine"] as? String {
        case "system":
            return .system
        case "cloud":
            return .cloud(VoiceCloudEngine(
                providerKind: try #require((selection["providerKind"] as? String).flatMap(ProviderKind.init(rawValue:))),
                connectionID: try #require(selection["connectionId"] as? String),
                model: try #require(selection["model"] as? String),
                voice: selection["voice"] as? String
            ))
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }

    // MARK: Rendering (using the fixture's expected keys)

    private static func render(_ resolution: VoiceEngineResolution) -> [String: Any] {
        switch resolution {
        case .system(let fallback):
            var out: [String: Any] = [
                "engine": "system",
                "notice": resolution.notice,
                "persist": resolution.persist.rawValue,
            ]
            if let fallback { out["reason"] = fallback.rawValue }
            return out
        case .cloud(let engine):
            var out: [String: Any] = [
                "engine": "cloud",
                "providerKind": engine.providerKind.rawValue,
                "connectionId": engine.connectionID,
                "model": engine.model,
            ]
            if let voice = engine.voice { out["voice"] = voice }
            return out
        }
    }

    private static func render(_ option: VoiceEngineOption) -> [String: Any] {
        switch option {
        case .system:
            return ["engine": "system"]
        case .cloud(let providerKind, let connectionID, let model, let isDefault):
            return [
                "engine": "cloud",
                "providerKind": providerKind.rawValue,
                "connectionId": connectionID,
                "model": model,
                "isDefault": isDefault,
            ]
        }
    }

    // MARK: Cases

    @Test("resolveCases all match")
    func resolveCasesMatchFixture() throws {
        let all = try VoiceCatalogContractTests.cases("resolveCases")
        #expect(all.count >= 14, "Too few fixture cases: \(all.count)")
        for item in all {
            let input = try Self.caseInput(item)
            let expected = try #require(item["expected"] as? [String: Any], "\(input.id) is missing expected")
            let resolution = VoiceEngineResolver.resolve(
                direction: input.direction,
                selection: try Self.selection(input.raw["selection"], id: input.id),
                catalog: input.catalog,
                connections: input.connections
            )
            let rendered = Self.render(resolution)
            #expect(
                NSDictionary(dictionary: rendered).isEqual(to: expected),
                "\(input.id)\nactual \(VoiceCatalogContractTests.describe(rendered))\nexpected \(VoiceCatalogContractTests.describe(expected))"
            )
            if case .cloud = resolution {
                // An effective cloud engine shows no notice and does not rewrite storage
                #expect(!resolution.notice && resolution.persist == .keep, "\(input.id)")
            }
        }
    }

    @Test("optionCases all match")
    func optionCasesMatchFixture() throws {
        let all = try VoiceCatalogContractTests.cases("optionCases")
        #expect(all.count >= 3, "Too few fixture cases: \(all.count)")
        for item in all {
            let input = try Self.caseInput(item)
            let expected = try #require(item["expected"] as? [[String: Any]], "\(input.id) is missing expected")
            let rendered = VoiceEngineResolver.options(
                direction: input.direction,
                catalog: input.catalog,
                connections: input.connections
            ).map(Self.render)
            #expect(
                NSArray(array: rendered).isEqual(to: expected),
                "\(input.id)\nactual \(VoiceCatalogContractTests.describe(rendered))\nexpected \(VoiceCatalogContractTests.describe(expected))"
            )
        }
    }

    @Test("realtimeResolveCases all match (system = follow the current model)")
    func realtimeResolveCasesMatchFixture() throws {
        let all = try VoiceCatalogContractTests.cases("realtimeResolveCases")
        #expect(all.count >= 9, "Too few fixture cases: \(all.count)")
        for item in all {
            let input = try Self.caseInput(item)
            #expect(input.direction == .realtime, "\(input.id)")
            let expected = try #require(item["expected"] as? [String: Any], "\(input.id) is missing expected")
            let resolution = VoiceEngineResolver.resolve(
                direction: input.direction,
                selection: try Self.selection(input.raw["selection"], id: input.id),
                catalog: input.catalog,
                connections: input.connections
            )
            let rendered = Self.render(resolution)
            #expect(
                NSDictionary(dictionary: rendered).isEqual(to: expected),
                "\(input.id)\nactual \(VoiceCatalogContractTests.describe(rendered))\nexpected \(VoiceCatalogContractTests.describe(expected))"
            )
            if case .cloud = resolution {
                #expect(!resolution.notice && resolution.persist == .keep, "\(input.id)")
            }
        }
    }

    @Test("realtimeOptionCases all match")
    func realtimeOptionCasesMatchFixture() throws {
        let all = try VoiceCatalogContractTests.cases("realtimeOptionCases")
        #expect(all.count >= 4, "Too few fixture cases: \(all.count)")
        for item in all {
            let input = try Self.caseInput(item)
            #expect(input.direction == .realtime, "\(input.id)")
            let expected = try #require(item["expected"] as? [[String: Any]], "\(input.id) is missing expected")
            let rendered = VoiceEngineResolver.options(
                direction: input.direction,
                catalog: input.catalog,
                connections: input.connections
            ).map(Self.render)
            #expect(
                NSArray(array: rendered).isEqual(to: expected),
                "\(input.id)\nactual \(VoiceCatalogContractTests.describe(rendered))\nexpected \(VoiceCatalogContractTests.describe(expected))"
            )
        }
    }

    @Test("pendingCases all match")
    func pendingCasesMatchFixture() throws {
        let all = try VoiceCatalogContractTests.cases("pendingCases")
        #expect(all.count >= 3, "Too few fixture cases: \(all.count)")
        for item in all {
            let input = try Self.caseInput(item)
            let expected = try #require(item["expected"] as? [String], "\(input.id) is missing expected")
            let rendered = VoiceEngineResolver.pendingProviders(
                direction: input.direction,
                catalog: input.catalog,
                connections: input.connections
            ).map(\.rawValue)
            #expect(rendered == expected, "\(input.id)\nactual \(rendered)\nexpected \(expected)")
        }
    }
}
