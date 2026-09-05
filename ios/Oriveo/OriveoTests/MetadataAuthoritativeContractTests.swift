//  MetadataAuthoritativeContractTests.swift
//  OriveoTests

import Foundation
import Testing
@testable import Oriveo

@Suite("Metadata Authoritative Contract Tests", .serialized)
struct MetadataAuthoritativeContractTests {

    // MARK: - Fixture decode types

    fileprivate struct ContractFile: Decodable {
        let contractVersion: Int
        let version: Int
        let metadata: JSONValue
        let topLevelExpectations: TopLevelExpectations
        let providerExpectations: [ProviderExpectation]
        let modelExpectations: [ModelExpectation]
        let negativeExpectations: [NegativeExpectation]
        let vendorIntegrityExpectations: VendorIntegrityExpectations
    }

    fileprivate struct TopLevelExpectations: Decodable {
        let expectedContractVersion: Int
        let expectedVersion: Int
        let requiredTopLevelFields: [String]
        let requiredProviderFields: [String]
    }

    fileprivate struct ProviderExpectation: Decodable {
        let id: String
        let providerKind: String
        let expectedDefaultModelId: String
        let expectedCanonicalModelCount: Int
        let expectedAttachmentSupport: AttachmentSupportExpectation
    }

    fileprivate struct AttachmentSupportExpectation: Decodable {
        let image: Bool
        let nativeFile: Bool
        let textFileInline: Bool
    }

    fileprivate struct ModelExpectation: Decodable {
        let id: String
        let providerKind: String
        let query: String
        let expectedCanonicalModelId: String
        let expectedDisplayName: String?
        let expectedContextLength: Int?
        let expectedMaxOutputTokens: Int?
        let expectedSupportsTemperature: Bool?
        let expectedPricingStatus: String
        let expectedPromptPerMToken: Double?
        let expectedCompletionPerMToken: Double?
        let expectedCachedInputPerMToken: Double?
        let expectedCapabilities: [String]
        let expectedReasoningProfile: String?
        let expectedWebSearchProfile: String?
        let expectedImageGenProfile: String?
        let expectedVendorKey: String?
        let expectedVendorName: String?
        let expectedGroupKey: String?
        let expectedGroupName: String?
        let expectedRecommended: Bool
        let expectedBadgeOrder: [String]
        let expectedIsDefault: Bool
    }

    fileprivate struct NegativeExpectation: Decodable {
        let id: String
        let providerKind: String
        let query: String
        let expectedResolved: Bool
    }

    fileprivate struct VendorIntegrityExpectations: Decodable {
        let aggregatorProviders: [String]
        let directProviders: [String]
        let expectations: [VendorIntegrityCase]
    }

    fileprivate struct VendorIntegrityCase: Decodable {
        let providerKind: String
        let modelId: String
        let vendorKey: String?
        let vendorName: String?
    }


    fileprivate indirect enum JSONValue: Decodable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let int = try? container.decode(Int.self) {
                self = .int(int)
            } else if let double = try? container.decode(Double.self) {
                self = .double(double)
            } else if let str = try? container.decode(String.self) {
                self = .string(str)
            } else if let arr = try? container.decode([JSONValue].self) {
                self = .array(arr)
            } else if let obj = try? container.decode([String: JSONValue].self) {
                self = .object(obj)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported JSON value in fixture"
                )
            }
        }

        var foundationObject: Any {
            switch self {
            case .null: return NSNull()
            case .bool(let v): return v
            case .int(let v): return v
            case .double(let v): return v
            case .string(let v): return v
            case .array(let arr): return arr.map { $0.foundationObject }
            case .object(let obj):
                var out: [String: Any] = [:]
                for (k, v) in obj {
                    out[k] = v.foundationObject
                }
                return out
            }
        }

        func object(_ key: String) -> JSONValue? {
            if case .object(let dict) = self { return dict[key] }
            return nil
        }

        var boolValue: Bool? {
            if case .bool(let v) = self { return v }
            return nil
        }

        var stringValue: String? {
            if case .string(let v) = self { return v }
            return nil
        }
    }

    // MARK: - Fixture loading

    fileprivate static func findContractURL() -> URL {
        let startURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relativeComponents = ["shared", "model-contracts", "metadata_authoritative_contract.v1.json"]

        var currentURL = startURL
        while true {
            let candidate = relativeComponents.reduce(currentURL) { partial, component in
                partial.appendingPathComponent(component)
            }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path { break }
            currentURL = parentURL
        }

        preconditionFailure("Unable to locate metadata_authoritative_contract.v1.json from \(startURL.path)")
    }

    fileprivate static let contract: ContractFile = {
        let url = findContractURL()
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(ContractFile.self, from: data)
    }()

    fileprivate static func metadataJSONString() -> String {
        let object = contract.metadata.foundationObject
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    fileprivate static func makeLoadedClient() async throws -> MetadataClient {
        let client = MetadataClient()
        try await client.loadForTesting(json: metadataJSONString())
        return client
    }

    fileprivate static func providerKind(from raw: String) -> ProviderKind {
        guard let kind = ProviderKind(rawValue: raw) else {
            preconditionFailure("Unknown ProviderKind rawValue in fixture: \(raw)")
        }
        return kind
    }

    /// fixture capability rawValue -> ModelCapability
    fileprivate static func capability(from raw: String) -> ModelCapability {
        guard let cap = ModelCapability(rawValue: raw) else {
            preconditionFailure("Unknown ModelCapability rawValue in fixture: \(raw)")
        }
        return cap
    }

    // MARK: - Tests

    @Test("Top Level Contract")
    func topLevelContract() async throws {
        let client = try await Self.makeLoadedClient()

        #expect(Self.contract.contractVersion == Self.contract.topLevelExpectations.expectedContractVersion)
        #expect(Self.contract.version == Self.contract.topLevelExpectations.expectedVersion)

        let version = await client.currentVersion()
        #expect(version == Self.contract.topLevelExpectations.expectedVersion)

        let snapshot = await client.contractVersionSnapshot()
        #expect(snapshot.metadataContractVersion == Self.contract.topLevelExpectations.expectedContractVersion)
        #expect(snapshot.isCompatible)
        #expect(!snapshot.shouldSafeDegrade)

        let metadata = Self.contract.metadata
        for field in Self.contract.topLevelExpectations.requiredTopLevelFields {
            #expect(metadata.object(field) != nil)
        }

        guard case .object(let providersDict) = (metadata.object("providers") ?? .null) else {
            Issue.record("fixture metadata.providers is not an object")
            return
        }
        for (providerName, providerNode) in providersDict {
            for field in Self.contract.topLevelExpectations.requiredProviderFields {
                #expect(
                    providerNode.object(field) != nil,
                    "provider \(providerName) is missing required field: \(field)"
                )
            }
        }
    }

    @Test("Provider Expectations")
    func providerExpectations() async throws {
        let client = try await Self.makeLoadedClient()

        for expectation in Self.contract.providerExpectations {
            let kind = Self.providerKind(from: expectation.providerKind)

            let defaultID = await client.providerDefaultModelID(providerKind: kind)
            #expect(
                defaultID == expectation.expectedDefaultModelId,
                "[\(expectation.id)] defaultModelId expected \(expectation.expectedDefaultModelId), got \(defaultID ?? "nil")"
            )

            let modelIDs = await client.providerModelIDs(providerKind: kind)
            #expect(
                modelIDs.count == expectation.expectedCanonicalModelCount,
                "[\(expectation.id)] canonical model count expected \(expectation.expectedCanonicalModelCount), got \(modelIDs.count) (ids=\(modelIDs))"
            )

            guard let providerNode = Self.contract.metadata
                .object("providers")?
                .object(expectation.providerKind)
            else {
                Issue.record("fixture providers is missing \(expectation.providerKind)")
                continue
            }
            let attachment = providerNode.object("attachmentSupport")
            #expect(
                attachment?.object("image")?.boolValue == expectation.expectedAttachmentSupport.image,
                "[\(expectation.id)] attachmentSupport.image mismatch"
            )
            #expect(
                attachment?.object("nativeFile")?.boolValue == expectation.expectedAttachmentSupport.nativeFile,
                "[\(expectation.id)] attachmentSupport.nativeFile mismatch"
            )
            #expect(
                attachment?.object("textFileInline")?.boolValue == expectation.expectedAttachmentSupport.textFileInline,
                "[\(expectation.id)] attachmentSupport.textFileInline mismatch"
            )
        }
    }

    @Test("Validation Contract")
    func validationContract() async throws {
        let client = try await Self.makeLoadedClient()

        for kindRaw in ["qwen", "miniMax", "zhipu", "siliconFlow"] {
            let kind = Self.providerKind(from: kindRaw)
            let validation = try #require(
                await client.providerValidation(providerKind: kind),
                "\(kindRaw) is missing a validation contract"
            )
            #expect(validation.probe == "list_models", "\(kindRaw) probe mismatch")
            #expect(validation.probePath == "/models", "\(kindRaw) probePath mismatch")
            #expect(validation.authMode == "bearer", "\(kindRaw) authMode mismatch")
            #expect(validation.headerProfile == "none", "\(kindRaw) headerProfile mismatch")
            #expect(validation.invalidKeySignals?.count == 1, "\(kindRaw) signal count mismatch")
            #expect(validation.invalidKeySignals?.first?.status == 401, "\(kindRaw) signal status mismatch")
            #expect(validation.invalidKeySignals?.first?.bodyIncludes == nil, "\(kindRaw) signal bodyIncludes mismatch")
        }

        let orValidation = try #require(
            await client.providerValidation(providerKind: .openRouter),
            "openRouter is missing a validation contract"
        )
        #expect(orValidation.probe == "key_info")
        #expect(orValidation.probePath == "/key")
        #expect(orValidation.authMode == "bearer")
        #expect(orValidation.headerProfile == "openrouter")
        #expect(orValidation.invalidKeySignals?.first?.status == 401)
    }

    @Test("Model Expectations")
    func modelExpectations() async throws {
        let client = try await Self.makeLoadedClient()

        for expectation in Self.contract.modelExpectations {
            let kind = Self.providerKind(from: expectation.providerKind)

            guard let resolved = await client.resolveCatalogModel(
                modelID: expectation.query,
                providerKind: kind
            ) else {
                Issue.record("[\(expectation.id)] resolveCatalogModel returned nil for \(expectation.query) on \(expectation.providerKind)")
                continue
            }

            // canonical id / display name / context
            #expect(
                resolved.canonicalModelId == expectation.expectedCanonicalModelId,
                "[\(expectation.id)] canonicalModelId mismatch: expected \(expectation.expectedCanonicalModelId), got \(resolved.canonicalModelId)"
            )
            #expect(
                resolved.displayName == expectation.expectedDisplayName,
                "[\(expectation.id)] displayName mismatch: expected \(expectation.expectedDisplayName ?? "nil"), got \(resolved.displayName ?? "nil")"
            )
            #expect(
                resolved.contextLength == expectation.expectedContextLength,
                "[\(expectation.id)] contextLength mismatch: expected \(String(describing: expectation.expectedContextLength)), got \(String(describing: resolved.contextLength))"
            )
            #expect(
                resolved.maxOutputTokens == expectation.expectedMaxOutputTokens,
                "[\(expectation.id)] maxOutputTokens mismatch: expected \(String(describing: expectation.expectedMaxOutputTokens)), got \(String(describing: resolved.maxOutputTokens))"
            )
            #expect(
                resolved.supportsTemperature == expectation.expectedSupportsTemperature,
                "[\(expectation.id)] supportsTemperature mismatch: expected \(String(describing: expectation.expectedSupportsTemperature)), got \(String(describing: resolved.supportsTemperature))"
            )

            // pricing
            #expect(
                resolved.pricingStatus == expectation.expectedPricingStatus,
                "[\(expectation.id)] pricingStatus mismatch: expected \(expectation.expectedPricingStatus), got \(resolved.pricingStatus)"
            )
            assertOptionalPrice(
                resolved.promptPerToken,
                expectedPerMToken: expectation.expectedPromptPerMToken,
                label: "[\(expectation.id)] promptPerToken"
            )
            assertOptionalPrice(
                resolved.completionPerToken,
                expectedPerMToken: expectation.expectedCompletionPerMToken,
                label: "[\(expectation.id)] completionPerToken"
            )

            let expectedCapabilities = expectation.expectedCapabilities.map(Self.capability(from:))
            #expect(
                resolved.capabilities == expectedCapabilities,
                "[\(expectation.id)] capabilities mismatch: expected \(expectedCapabilities), got \(resolved.capabilities)"
            )

            // profiles
            #expect(
                resolved.profiles.reasoning == expectation.expectedReasoningProfile,
                "[\(expectation.id)] reasoning profile mismatch: expected \(expectation.expectedReasoningProfile ?? "nil"), got \(resolved.profiles.reasoning ?? "nil")"
            )
            #expect(
                resolved.profiles.webSearch == expectation.expectedWebSearchProfile,
                "[\(expectation.id)] webSearch profile mismatch: expected \(expectation.expectedWebSearchProfile ?? "nil"), got \(resolved.profiles.webSearch ?? "nil")"
            )
            #expect(
                resolved.profiles.imageGen == expectation.expectedImageGenProfile,
                "[\(expectation.id)] imageGen profile mismatch: expected \(expectation.expectedImageGenProfile ?? "nil"), got \(resolved.profiles.imageGen ?? "nil")"
            )

            // uiHints
            #expect(
                resolved.uiHints.groupKey == expectation.expectedGroupKey,
                "[\(expectation.id)] groupKey mismatch"
            )
            #expect(
                resolved.uiHints.groupName == expectation.expectedGroupName,
                "[\(expectation.id)] groupName mismatch"
            )
            #expect(
                resolved.uiHints.recommended == expectation.expectedRecommended,
                "[\(expectation.id)] recommended mismatch"
            )

            let expectedBadge = expectation.expectedBadgeOrder.map(Self.capability(from:))
            #expect(
                resolved.uiHints.badgeOrder == expectedBadge,
                "[\(expectation.id)] badgeOrder mismatch: expected \(expectedBadge), got \(String(describing: resolved.uiHints.badgeOrder))"
            )

            // isDefault
            #expect(
                resolved.isDefault == expectation.expectedIsDefault,
                "[\(expectation.id)] isDefault mismatch: expected \(expectation.expectedIsDefault), got \(resolved.isDefault)"
            )

            #expect(
                resolved.vendorKey == expectation.expectedVendorKey,
                "[\(expectation.id)] vendorKey mismatch: expected \(expectation.expectedVendorKey ?? "nil"), got \(resolved.vendorKey ?? "nil")"
            )
            #expect(
                resolved.vendorName == expectation.expectedVendorName,
                "[\(expectation.id)] vendorName mismatch: expected \(expectation.expectedVendorName ?? "nil"), got \(resolved.vendorName ?? "nil")"
            )
        }
    }

    @Test("Negative Expectations")
    func negativeExpectations() async throws {
        let client = try await Self.makeLoadedClient()

        for expectation in Self.contract.negativeExpectations {
            let kind = Self.providerKind(from: expectation.providerKind)
            let resolved = await client.resolveCatalogModel(
                modelID: expectation.query,
                providerKind: kind
            )
            if expectation.expectedResolved {
                #expect(resolved != nil, "[\(expectation.id)] expected resolution but got nil")
            } else {
                #expect(
                    resolved == nil,
                    "[\(expectation.id)] expected nil for \(expectation.query) on \(expectation.providerKind), got \(String(describing: resolved?.canonicalModelId))"
                )
            }
        }
    }

    @Test("Vendor Integrity Expectations")
    func vendorIntegrityExpectations() async throws {
        let client = try await Self.makeLoadedClient()
        let aggregator = Set(Self.contract.vendorIntegrityExpectations.aggregatorProviders)
        let direct = Set(Self.contract.vendorIntegrityExpectations.directProviders)

        for expectation in Self.contract.vendorIntegrityExpectations.expectations {
            let kind = Self.providerKind(from: expectation.providerKind)
            guard let resolved = await client.resolveCatalogModel(
                modelID: expectation.modelId,
                providerKind: kind
            ) else {
                Issue.record("[\(expectation.providerKind)/\(expectation.modelId)] resolveCatalogModel returned nil")
                continue
            }

            #expect(
                resolved.vendorKey == expectation.vendorKey,
                "[\(expectation.providerKind)/\(expectation.modelId)] vendorKey expected \(expectation.vendorKey ?? "nil"), got \(resolved.vendorKey ?? "nil")"
            )
            #expect(
                resolved.vendorName == expectation.vendorName,
                "[\(expectation.providerKind)/\(expectation.modelId)] vendorName expected \(expectation.vendorName ?? "nil"), got \(resolved.vendorName ?? "nil")"
            )

            if aggregator.contains(expectation.providerKind) {
                #expect(
                    resolved.vendorKey?.isEmpty == false,
                    "Aggregator provider \(expectation.providerKind) model \(expectation.modelId) must declare vendorKey"
                )
            }
            if direct.contains(expectation.providerKind) {
                #expect(
                    resolved.vendorKey == nil,
                    "Direct provider \(expectation.providerKind) model \(expectation.modelId) must not carry vendorKey"
                )
                #expect(
                    resolved.vendorName == nil,
                    "Direct provider \(expectation.providerKind) model \(expectation.modelId) must not carry vendorName"
                )
            }
        }
    }

    @Test("Image Generation Model Still Resolves")
    func imageGenerationModelStillResolves() async throws {
        let client = try await Self.makeLoadedClient()
        let resolved = await client.resolveCatalogModel(modelID: "qwen-image", providerKind: .qwen)
        #expect(resolved != nil)
        #expect(resolved?.canonicalModelId == "qwen-image")
        #expect(resolved?.capabilities == [.text, .imageGen])
        #expect(resolved?.profiles.imageGen == "qwen_image_v1")
        #expect(resolved?.pricingStatus == "free")
        #expect(resolved?.promptPerToken == 0)
        #expect(resolved?.completionPerToken == 0)
    }

    // MARK: - Helpers

    private func assertOptionalPrice(
        _ actualPerToken: Double?,
        expectedPerMToken: Double?,
        label: String
    ) {
        switch (actualPerToken, expectedPerMToken) {
        case (nil, nil):
            return
        case (let actual?, let expected?):
            let expectedPerToken = expected / 1_000_000.0
            if expectedPerToken == 0 {
                #expect(actual == 0, "\(label): expected 0, got \(actual)")
            } else {
                let diff = abs(actual - expectedPerToken)
                #expect(
                    diff < 1e-12,
                    "\(label): expected \(expectedPerToken) (= \(expected)/1e6), got \(actual), diff=\(diff)"
                )
            }
        case (let actual?, nil):
            Issue.record("\(label): expected nil, got \(actual)")
        case (nil, let expected?):
            Issue.record("\(label): expected \(expected)/1e6, got nil")
        }
    }
}
