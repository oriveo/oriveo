import Foundation
import Testing
@testable import Oriveo

@Suite("Model Identity Contract")
struct ModelIdentityContractTests {

    private struct ContractFile: Decodable {
        let version: Int
        let lookupCases: [LookupCase]
        let dedupeCases: [DedupeCase]
        let storedIdentifierCases: [StoredIdentifierCase]
        let sameRemoteCases: [SameRemoteCase]
        let relayCases: RelayCases
    }

    /// Relay section: sameness is judged by the literal ID; date snapshots / canonical / display name do not take part.
    private struct RelayCases: Decodable {
        let providerKind: String
        let sameRemoteCases: [RelaySameRemoteCase]
        let lookupCases: [RelayLookupCase]
        let storedIdentifierCases: [RelayStoredIdentifierCase]
        let dedupeCases: [DedupeCase]
        let readCompatCases: [RelayReadCompatCase]
    }

    private struct RelaySameRemoteCase: Decodable {
        let id: String
        let left: ContractModel
        let right: ContractModel
        let expected: Bool
    }

    private struct RelayLookupCase: Decodable {
        let id: String
        let query: String
        let models: [ContractModel]
        let expectedModelId: String?
    }

    private struct RelayStoredIdentifierCase: Decodable {
        let id: String
        let model: ContractModel
        let expectedStoredModelId: String
    }

    private struct RelayReadCompatCase: Decodable {
        let id: String
        let storedModelId: String
        let enabledModels: [ContractModel]
        let expectedModelId: String?
    }

    private struct LookupCase: Decodable {
        let id: String
        let providerKind: String
        let query: String
        let expectedCanonicalModelId: String?
        let expectedModelId: String?
        let models: [ContractModel]
    }

    private struct DedupeCase: Decodable {
        let id: String
        let models: [ContractModel]
        let expectedModelIds: [String]
    }

    private struct StoredIdentifierCase: Decodable {
        let id: String
        let providerKind: String
        let model: ContractModel
        let expectedStoredModelId: String
    }

    private struct SameRemoteCase: Decodable {
        let id: String
        let providerKind: String
        let left: ContractModel
        let right: ContractModel
        let expected: Bool
    }

    private struct ContractModel: Decodable {
        let id: String
        let name: String
        let canonicalModelId: String?
    }

    private static func findContractURL() -> URL {
        let startURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relativeComponents = ["shared", "model-contracts", "model_identity_contract.v1.json"]

        var currentURL = startURL
        while true {
            let candidate = relativeComponents.reduce(currentURL) { partialResult, component in
                partialResult.appendingPathComponent(component)
            }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                break
            }
            currentURL = parentURL
        }

        preconditionFailure("Unable to locate model_identity_contract.v1.json from \(startURL.path)")
    }

    private static let contract: ContractFile = {
        let contractURL = findContractURL()
        let data = try! Data(contentsOf: contractURL)
        return try! JSONDecoder().decode(ContractFile.self, from: data)
    }()

    @Test("Contract Loaded")
    func contractLoaded() {
        #expect(Self.contract.version == 1)
        #expect(!Self.contract.lookupCases.isEmpty)
    }

    @Test("lookup cases")
    func lookupCases() {
        for testCase in Self.contract.lookupCases {
            let provider = makeProvider(kind: providerKind(from: testCase.providerKind), models: testCase.models)
            let resolved = ModelResolver.matchingModel(for: testCase.query, in: provider)

            #expect(
                resolved?.id == testCase.expectedModelId,
                "lookup \(testCase.id) expected \(testCase.expectedModelId ?? "nil"), got \(resolved?.id ?? "nil")"
            )
            #expect(
                resolved?.canonicalModelId ?? resolved?.id == testCase.expectedCanonicalModelId,
                "canonical \(testCase.id) expected \(testCase.expectedCanonicalModelId ?? "nil"), got \(resolved?.canonicalModelId ?? resolved?.id ?? "nil")"
            )
        }
    }

    @Test("dedupe cases")
    func dedupeCases() {
        for testCase in Self.contract.dedupeCases {
            let deduped = CatalogModelBuilder.deduplicateByCanonical(testCase.models.map(makeModel))
            #expect(
                deduped.map(\.id) == testCase.expectedModelIds,
                "dedupe \(testCase.id) expected \(testCase.expectedModelIds), got \(deduped.map(\.id))"
            )
        }
    }

    @Test("stored identifier cases")
    func storedIdentifierCases() {
        for testCase in Self.contract.storedIdentifierCases {
            let model = makeModel(testCase.model)
            let stored = ModelResolver.preferredStoredModelIdentifier(
                for: model,
                providerKind: providerKind(from: testCase.providerKind)
            )
            #expect(
                stored == testCase.expectedStoredModelId,
                "stored id \(testCase.id) expected \(testCase.expectedStoredModelId), got \(stored)"
            )
        }
    }

    @Test("same remote model cases")
    func sameRemoteCases() {
        for testCase in Self.contract.sameRemoteCases {
            let result = ModelResolver.modelsShareSameRemoteModel(
                makeModel(testCase.left),
                makeModel(testCase.right),
                providerKind: providerKind(from: testCase.providerKind)
            )
            #expect(
                result == testCase.expected,
                "same remote \(testCase.id) expected \(testCase.expected), got \(result)"
            )
        }
    }

    @Test("relay same remote cases")
    func relaySameRemoteCases() {
        let kind = providerKind(from: Self.contract.relayCases.providerKind)
        for testCase in Self.contract.relayCases.sameRemoteCases {
            let left = makeModel(testCase.left)
            let right = makeModel(testCase.right)
            #expect(
                ModelResolver.modelsShareSameRemoteModel(left, right, providerKind: kind) == testCase.expected,
                "relay same remote \(testCase.id) expected \(testCase.expected)"
            )
            #expect(
                ModelResolver.modelsShareSameRemoteModel(right, left, providerKind: kind) == testCase.expected,
                "relay same remote (swapped) \(testCase.id) expected \(testCase.expected)"
            )
        }
    }

    @Test("relay lookup cases")
    func relayLookupCases() {
        let kind = providerKind(from: Self.contract.relayCases.providerKind)
        for testCase in Self.contract.relayCases.lookupCases {
            let provider = makeProvider(kind: kind, models: testCase.models)
            let resolved = ModelResolver.matchingModel(for: testCase.query, in: provider)
            #expect(
                resolved?.id == testCase.expectedModelId,
                "relay lookup \(testCase.id) expected \(testCase.expectedModelId ?? "nil"), got \(resolved?.id ?? "nil")"
            )
        }
    }

    @Test("relay stored identifier cases")
    func relayStoredIdentifierCases() {
        let kind = providerKind(from: Self.contract.relayCases.providerKind)
        for testCase in Self.contract.relayCases.storedIdentifierCases {
            let stored = ModelResolver.preferredStoredModelIdentifier(for: makeModel(testCase.model), providerKind: kind)
            #expect(
                stored == testCase.expectedStoredModelId,
                "relay stored id \(testCase.id) expected \(testCase.expectedStoredModelId), got \(stored)"
            )
        }
    }

    @Test("relay dedupe cases")
    func relayDedupeCases() {
        let kind = providerKind(from: Self.contract.relayCases.providerKind)
        for testCase in Self.contract.relayCases.dedupeCases {
            let deduped = CatalogModelBuilder.deduplicate(testCase.models.map(makeModel), providerKind: kind)
            #expect(
                deduped.map(\.id) == testCase.expectedModelIds,
                "relay dedupe \(testCase.id) expected \(testCase.expectedModelIds), got \(deduped.map(\.id))"
            )
        }
    }

    @Test("relay read compat cases")
    func relayReadCompatCases() {
        let kind = providerKind(from: Self.contract.relayCases.providerKind)
        for testCase in Self.contract.relayCases.readCompatCases {
            let resolved = ModelResolver.resolveStoredModel(
                testCase.storedModelId,
                in: testCase.enabledModels.map(makeModel),
                providerKind: kind
            )
            #expect(
                resolved?.id == testCase.expectedModelId,
                "relay read compat \(testCase.id) expected \(testCase.expectedModelId ?? "nil"), got \(resolved?.id ?? "nil")"
            )
        }
    }

    private func providerKind(from rawValue: String) -> ProviderKind {
        ProviderKind(rawValue: rawValue)!
    }

    private func makeModel(_ model: ContractModel) -> AIModel {
        TestFactories.makeModel(
            id: model.id,
            name: model.name,
            capabilities: [.text],
            isAvailable: true,
            canonicalModelId: model.canonicalModelId
        )
    }

    private func makeProvider(kind: ProviderKind, models: [ContractModel]) -> Provider {
        let resolvedModels = models.map(makeModel)
        return TestFactories.makeProvider(
            kind: kind,
            models: resolvedModels,
            catalogModels: resolvedModels
        )
    }
}
