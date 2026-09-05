//  PresentationContractTests.swift
//  OriveoTests

import Foundation
import Testing

@Suite("Phase 5 Presentation Contract (iOS)", .serialized)
struct PresentationContractTests {

    // MARK: - Fixture schema

    fileprivate struct FixtureFile: Decodable {
        let contractVersion: Int
        let leafCases: [LeafCase]
        let containerCases: [ContainerCase]
        let stateCases: [StateCase]

        enum CodingKeys: String, CodingKey {
            case contractVersion, leafCases, containerCases, stateCases
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.contractVersion = (try? c.decode(Int.self, forKey: .contractVersion)) ?? 0
            self.leafCases = (try? c.decode([LeafCase].self, forKey: .leafCases)) ?? []
            self.containerCases = (try? c.decode([ContainerCase].self, forKey: .containerCases)) ?? []
            self.stateCases = (try? c.decode([StateCase].self, forKey: .stateCases)) ?? []
        }
    }

    fileprivate struct LeafCase: Decodable {
        let id: String
        let providerKind: String
        let model: FixtureModel
        let expectedRender: ExpectedLeafRender
    }

    fileprivate struct ContainerCase: Decodable {
        let id: String
        let providerKind: String
        let models: [FixtureModel]
        let expectedRender: ExpectedContainerRender
    }

    fileprivate struct StateCase: Decodable {
        let id: String
        let providerKind: String
        let metadataSource: String?
        let providerData: FixtureProviderData
        let manualRetainedModels: [FixtureManualRetainedModel]
        let expectedRender: ExpectedStateRender

        enum CodingKeys: String, CodingKey {
            case id, providerKind, metadataSource, providerData, manualRetainedModels, expectedRender
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.providerKind = try c.decode(String.self, forKey: .providerKind)
            self.metadataSource = try? c.decode(String.self, forKey: .metadataSource)
            self.providerData = try c.decode(FixtureProviderData.self, forKey: .providerData)
            self.manualRetainedModels = (try? c.decode([FixtureManualRetainedModel].self, forKey: .manualRetainedModels)) ?? []
            self.expectedRender = try c.decode(ExpectedStateRender.self, forKey: .expectedRender)
        }
    }

    fileprivate struct FixtureModel: Decodable {
        let canonicalModelId: String
        let displayName: String?
        let vendorKey: String?
        let vendorName: String?
        let contextLength: Int?
        let pricing: FixturePricing?
        let pricingStatus: String
        let capabilities: [String]
        let profiles: FixtureProfiles?
        let uiHints: FixtureUIHints

        enum CodingKeys: String, CodingKey {
            case canonicalModelId, displayName, vendorKey, vendorName,
                 contextLength, pricing, pricingStatus, capabilities, profiles, uiHints
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.canonicalModelId = try c.decode(String.self, forKey: .canonicalModelId)
            self.displayName = try? c.decode(String.self, forKey: .displayName)
            self.vendorKey = try? c.decode(String.self, forKey: .vendorKey)
            self.vendorName = try? c.decode(String.self, forKey: .vendorName)
            self.contextLength = try? c.decode(Int.self, forKey: .contextLength)
            self.pricing = try? c.decode(FixturePricing.self, forKey: .pricing)
            self.pricingStatus = (try? c.decode(String.self, forKey: .pricingStatus)) ?? "unknown"
            self.capabilities = (try? c.decode([String].self, forKey: .capabilities)) ?? []
            self.profiles = try? c.decode(FixtureProfiles.self, forKey: .profiles)
            self.uiHints = (try? c.decode(FixtureUIHints.self, forKey: .uiHints)) ?? FixtureUIHints()
        }
    }

    fileprivate struct FixturePricing: Decodable {
        let promptPerMToken: Double?
        let completionPerMToken: Double?
        let cachedInputPerMToken: Double?

        enum CodingKeys: String, CodingKey {
            case promptPerMToken, completionPerMToken, cachedInputPerMToken
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.promptPerMToken = try? c.decode(Double.self, forKey: .promptPerMToken)
            self.completionPerMToken = try? c.decode(Double.self, forKey: .completionPerMToken)
            self.cachedInputPerMToken = try? c.decode(Double.self, forKey: .cachedInputPerMToken)
        }
    }

    fileprivate struct FixtureProfiles: Decodable {
        let reasoning: String?
        let webSearch: String?
        let imageGen: String?

        enum CodingKeys: String, CodingKey {
            case reasoning, webSearch, imageGen
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.reasoning = try? c.decode(String.self, forKey: .reasoning)
            self.webSearch = try? c.decode(String.self, forKey: .webSearch)
            self.imageGen = try? c.decode(String.self, forKey: .imageGen)
        }
    }

    fileprivate struct FixtureUIHints: Decodable {
        let groupKey: String?
        let groupName: String?
        let rank: Int?
        let recommended: Bool
        let badgeOrder: [String]

        init() {
            self.groupKey = nil
            self.groupName = nil
            self.rank = nil
            self.recommended = false
            self.badgeOrder = []
        }

        enum CodingKeys: String, CodingKey {
            case groupKey, groupName, rank, recommended, badgeOrder
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.groupKey = try? c.decode(String.self, forKey: .groupKey)
            self.groupName = try? c.decode(String.self, forKey: .groupName)
            self.rank = try? c.decode(Int.self, forKey: .rank)
            self.recommended = (try? c.decode(Bool.self, forKey: .recommended)) ?? false
            self.badgeOrder = (try? c.decode([String].self, forKey: .badgeOrder)) ?? []
        }
    }

    fileprivate struct FixtureProviderData: Decodable {
        let displayName: String
        let defaultModelId: String?
        let validationModelId: String?
        let resolveMap: [String: String]
        let models: [String: FixtureProviderModel]

        enum CodingKeys: String, CodingKey {
            case displayName, defaultModelId, validationModelId, resolveMap, models
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
            self.defaultModelId = try? c.decode(String.self, forKey: .defaultModelId)
            self.validationModelId = try? c.decode(String.self, forKey: .validationModelId)
            self.resolveMap = (try? c.decode([String: String].self, forKey: .resolveMap)) ?? [:]
            self.models = (try? c.decode([String: FixtureProviderModel].self, forKey: .models)) ?? [:]
        }
    }

    fileprivate struct FixtureProviderModel: Decodable {
        let canonicalModelId: String?
        let displayName: String?
        let pricingStatus: String?
        let capabilities: [String]
        let uiHints: FixtureUIHints?

        enum CodingKeys: String, CodingKey {
            case canonicalModelId, displayName, pricingStatus, capabilities, uiHints
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.canonicalModelId = try? c.decode(String.self, forKey: .canonicalModelId)
            self.displayName = try? c.decode(String.self, forKey: .displayName)
            self.pricingStatus = try? c.decode(String.self, forKey: .pricingStatus)
            self.capabilities = (try? c.decode([String].self, forKey: .capabilities)) ?? []
            self.uiHints = try? c.decode(FixtureUIHints.self, forKey: .uiHints)
        }
    }

    fileprivate struct FixtureManualRetainedModel: Decodable {
        let modelId: String
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case modelId, displayName
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.modelId = try c.decode(String.self, forKey: .modelId)
            self.displayName = try? c.decode(String.self, forKey: .displayName)
        }
    }


    fileprivate struct ExpectedLeafRender: Decodable, Equatable {
        let showsVendorSubtitle: Bool
        let vendorSubtitleText: String?
        let showsRecommendedBadge: Bool
        let capabilityBadges: [String]
        let showsCachedPricing: Bool
        let pricingBranch: String
        let showsReasoningPicker: Bool
        let showsWebSearchPicker: Bool
        let showsImageGenPicker: Bool

        enum CodingKeys: String, CodingKey {
            case showsVendorSubtitle, vendorSubtitleText, showsRecommendedBadge,
                 capabilityBadges, showsCachedPricing, pricingBranch,
                 showsReasoningPicker, showsWebSearchPicker, showsImageGenPicker
        }

        init(
            showsVendorSubtitle: Bool,
            vendorSubtitleText: String?,
            showsRecommendedBadge: Bool,
            capabilityBadges: [String],
            showsCachedPricing: Bool,
            pricingBranch: String,
            showsReasoningPicker: Bool,
            showsWebSearchPicker: Bool,
            showsImageGenPicker: Bool
        ) {
            self.showsVendorSubtitle = showsVendorSubtitle
            self.vendorSubtitleText = vendorSubtitleText
            self.showsRecommendedBadge = showsRecommendedBadge
            self.capabilityBadges = capabilityBadges
            self.showsCachedPricing = showsCachedPricing
            self.pricingBranch = pricingBranch
            self.showsReasoningPicker = showsReasoningPicker
            self.showsWebSearchPicker = showsWebSearchPicker
            self.showsImageGenPicker = showsImageGenPicker
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.showsVendorSubtitle = try c.decode(Bool.self, forKey: .showsVendorSubtitle)
            self.vendorSubtitleText = try? c.decode(String.self, forKey: .vendorSubtitleText)
            self.showsRecommendedBadge = try c.decode(Bool.self, forKey: .showsRecommendedBadge)
            self.capabilityBadges = (try? c.decode([String].self, forKey: .capabilityBadges)) ?? []
            self.showsCachedPricing = try c.decode(Bool.self, forKey: .showsCachedPricing)
            self.pricingBranch = try c.decode(String.self, forKey: .pricingBranch)
            self.showsReasoningPicker = try c.decode(Bool.self, forKey: .showsReasoningPicker)
            self.showsWebSearchPicker = try c.decode(Bool.self, forKey: .showsWebSearchPicker)
            self.showsImageGenPicker = try c.decode(Bool.self, forKey: .showsImageGenPicker)
        }
    }

    fileprivate struct ExpectedContainerRender: Decodable, Equatable {
        let groupHeaders: [String]
        let modelOrderWithinGroups: [String: [String]]

        enum CodingKeys: String, CodingKey {
            case groupHeaders, modelOrderWithinGroups
        }

        init(groupHeaders: [String], modelOrderWithinGroups: [String: [String]]) {
            self.groupHeaders = groupHeaders
            self.modelOrderWithinGroups = modelOrderWithinGroups
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.groupHeaders = (try? c.decode([String].self, forKey: .groupHeaders)) ?? []
            self.modelOrderWithinGroups = (try? c.decode([String: [String]].self, forKey: .modelOrderWithinGroups)) ?? [:]
        }
    }

    fileprivate struct ExpectedStateRender: Decodable, Equatable {
        let showsEmptyStateCopy: Bool
        let showsRetryAction: Bool
        let showsCatalogList: Bool
        let showsOfflineBanner: Bool
        let showsManualRetainedSection: Bool
        let manualRetainedHeaderKey: String?

        enum CodingKeys: String, CodingKey {
            case showsEmptyStateCopy, showsRetryAction, showsCatalogList,
                 showsOfflineBanner, showsManualRetainedSection, manualRetainedHeaderKey
        }

        init(
            showsEmptyStateCopy: Bool,
            showsRetryAction: Bool,
            showsCatalogList: Bool,
            showsOfflineBanner: Bool,
            showsManualRetainedSection: Bool,
            manualRetainedHeaderKey: String?
        ) {
            self.showsEmptyStateCopy = showsEmptyStateCopy
            self.showsRetryAction = showsRetryAction
            self.showsCatalogList = showsCatalogList
            self.showsOfflineBanner = showsOfflineBanner
            self.showsManualRetainedSection = showsManualRetainedSection
            self.manualRetainedHeaderKey = manualRetainedHeaderKey
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.showsEmptyStateCopy = try c.decode(Bool.self, forKey: .showsEmptyStateCopy)
            self.showsRetryAction = try c.decode(Bool.self, forKey: .showsRetryAction)
            self.showsCatalogList = try c.decode(Bool.self, forKey: .showsCatalogList)
            self.showsOfflineBanner = try c.decode(Bool.self, forKey: .showsOfflineBanner)
            self.showsManualRetainedSection = try c.decode(Bool.self, forKey: .showsManualRetainedSection)
            self.manualRetainedHeaderKey = try? c.decode(String.self, forKey: .manualRetainedHeaderKey)
        }
    }

    // MARK: - Fixture loading

    fileprivate static func findFixtureURL() -> URL {
        let startURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relativeComponents = ["shared", "model-contracts", "presentation_fixtures.v1.json"]

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

        preconditionFailure("Unable to locate presentation_fixtures.v1.json from \(startURL.path)")
    }

    fileprivate static let fixture: FixtureFile = {
        let url = findFixtureURL()
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(FixtureFile.self, from: data)
    }()


    fileprivate static let aggregatorProviderKinds: Set<String> = ["openRouter", "siliconFlow"]

    fileprivate static let manualRetainedHeaderKey = "providers.catalog.manualRetainedHeader"

    fileprivate static func derivePresentation(model: FixtureModel) -> ExpectedLeafRender {
        let vendorKey = model.vendorKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let vendorName = model.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let showsVendor = !vendorKey.isEmpty && !vendorName.isEmpty

        let capabilitySet = Set(model.capabilities)
        let badges = model.uiHints.badgeOrder.filter { $0 != "text" && capabilitySet.contains($0) }

        let pricingBranch = model.pricingStatus
        let showsCachedPricing = pricingBranch == "priced"

        let reasoning = model.profiles?.reasoning?.isEmpty == false
        let webSearch = model.profiles?.webSearch?.isEmpty == false
        let imageGen = model.profiles?.imageGen?.isEmpty == false

        return ExpectedLeafRender(
            showsVendorSubtitle: showsVendor,
            vendorSubtitleText: showsVendor ? vendorName : nil,
            showsRecommendedBadge: model.uiHints.recommended,
            capabilityBadges: badges,
            showsCachedPricing: showsCachedPricing,
            pricingBranch: pricingBranch,
            showsReasoningPicker: reasoning,
            showsWebSearchPicker: webSearch,
            showsImageGenPicker: imageGen
        )
    }

    fileprivate static func deriveContainerPresentation(
        providerKind: String,
        models: [FixtureModel]
    ) -> ExpectedContainerRender {
        let isAggregator = aggregatorProviderKinds.contains(providerKind)

        var groupOrder: [String] = []
        var buckets: [String: [FixtureModel]] = [:]
        for model in models {
            let header: String
            if isAggregator {
                header = (model.vendorName?.isEmpty == false ? model.vendorName! : "Unknown")
            } else {
                header = (model.uiHints.groupName?.isEmpty == false ? model.uiHints.groupName! : "Other")
            }
            if buckets[header] == nil {
                buckets[header] = []
                groupOrder.append(header)
            }
            buckets[header]!.append(model)
        }

        var sortedBuckets: [String: [FixtureModel]] = [:]
        for (header, list) in buckets {
            sortedBuckets[header] = list.sorted { lhs, rhs in
                let lr = lhs.uiHints.rank ?? 0
                let rr = rhs.uiHints.rank ?? 0
                if lr != rr { return lr > rr }
                return lhs.canonicalModelId < rhs.canonicalModelId
            }
        }

        let orderedHeaders: [String]
        if isAggregator {
            orderedHeaders = groupOrder
        } else {
            orderedHeaders = groupOrder.sorted { a, b in
                let maxA = sortedBuckets[a]?.map { $0.uiHints.rank ?? 0 }.max() ?? 0
                let maxB = sortedBuckets[b]?.map { $0.uiHints.rank ?? 0 }.max() ?? 0
                if maxA != maxB { return maxA > maxB }
                return a < b
            }
        }

        var orderWithin: [String: [String]] = [:]
        for header in orderedHeaders {
            orderWithin[header] = (sortedBuckets[header] ?? []).map { $0.canonicalModelId }
        }

        return ExpectedContainerRender(
            groupHeaders: orderedHeaders,
            modelOrderWithinGroups: orderWithin
        )
    }

    fileprivate static func deriveStatePresentation(
        metadataSource: String?,
        providerData: FixtureProviderData,
        manualRetainedModels: [FixtureManualRetainedModel]
    ) -> ExpectedStateRender {
        let hasModels = !providerData.models.isEmpty
        let hasManualRetained = !manualRetainedModels.isEmpty
        let isOffline = metadataSource == "cachedOffline"

        return ExpectedStateRender(
            showsEmptyStateCopy: !hasModels,
            showsRetryAction: !hasModels,
            showsCatalogList: hasModels,
            showsOfflineBanner: isOffline,
            showsManualRetainedSection: hasManualRetained,
            manualRetainedHeaderKey: hasManualRetained ? manualRetainedHeaderKey : nil
        )
    }

    // MARK: - Tests

    @Test("fixture loads with expected contract version")
    func fixtureLoads() {
        #expect(Self.fixture.contractVersion == 1)
        #expect(!Self.fixture.leafCases.isEmpty)
        #expect(!Self.fixture.containerCases.isEmpty)
        #expect(!Self.fixture.stateCases.isEmpty)
    }

    @Test("leaf cases stay aligned")
    func leafCases() {
        for caseEntry in Self.fixture.leafCases {
            let actual = Self.derivePresentation(model: caseEntry.model)
            #expect(
                actual == caseEntry.expectedRender,
                "leaf `\(caseEntry.id)`: expected \(caseEntry.expectedRender), got \(actual)"
            )
        }
    }

    @Test("container cases stay aligned")
    func containerCases() {
        for caseEntry in Self.fixture.containerCases {
            let actual = Self.deriveContainerPresentation(
                providerKind: caseEntry.providerKind,
                models: caseEntry.models
            )
            #expect(
                actual == caseEntry.expectedRender,
                "container `\(caseEntry.id)`: expected \(caseEntry.expectedRender), got \(actual)"
            )
        }
    }

    @Test("state cases stay aligned")
    func stateCases() {
        for caseEntry in Self.fixture.stateCases {
            let actual = Self.deriveStatePresentation(
                metadataSource: caseEntry.metadataSource,
                providerData: caseEntry.providerData,
                manualRetainedModels: caseEntry.manualRetainedModels
            )
            #expect(
                actual == caseEntry.expectedRender,
                "state `\(caseEntry.id)`: expected \(caseEntry.expectedRender), got \(actual)"
            )
        }
    }
}
