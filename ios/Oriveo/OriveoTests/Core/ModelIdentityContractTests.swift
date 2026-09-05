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
