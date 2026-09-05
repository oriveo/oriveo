import Foundation
import Testing
@testable import Oriveo


@Suite("PresentationModelCard Presentation Contract", .serialized)
struct PresentationModelCardTests {

    private func makeDescriptor(
        canonical: String = "gpt-5.4",
        display: String = "GPT-5.4",
        vendorKey: String? = nil,
        vendorName: String? = nil,
        groupKey: String? = nil,
        groupName: String? = nil,
        contextLength: Int? = 200_000,
        prompt: Double? = 2.5 / 1_000_000,
        completion: Double? = 10.0 / 1_000_000,
        pricingStatus: String = "priced",
        capabilities: [ModelCapability] = [.text, .reasoning],
        badgeOrder: [ModelCapability]? = [.reasoning],
        recommended: Bool = true,
        rank: Int? = 200,
        isEnabled: Bool = true,
        isDefault: Bool = false
    ) -> PresentationModelDescriptor {
        PresentationModelDescriptor(
            canonicalModelID: canonical,
            displayName: display,
            vendorKey: vendorKey,
            vendorName: vendorName,
            groupKey: groupKey,
            groupName: groupName,
            contextLength: contextLength,
            promptPerToken: prompt,
            completionPerToken: completion,
            pricingStatus: pricingStatus,
            capabilities: capabilities,
            badgeOrder: badgeOrder,
            recommended: recommended,
            rank: rank,
            isEnabled: isEnabled,
            isDefault: isDefault
        )
    }

    @Test("Sort By Rank Then Canonical Id Ascii Ascending")
    func sortByRankThenCanonicalIdAsciiAscending() {
        let a = makeDescriptor(canonical: "alpha", rank: 100)
        let b = makeDescriptor(canonical: "bravo", rank: 100)
        let c = makeDescriptor(canonical: "charlie", rank: 200)
        let d = makeDescriptor(canonical: "Delta", rank: 50)

        let sorted = PresentationModelSorter.sorted([a, b, c, d])

        #expect(sorted.map(\.canonicalModelID) == ["charlie", "alpha", "bravo", "Delta"])
    }

    @Test("Sort Handles Nil Rank")
    func sortHandlesNilRank() {
        let a = makeDescriptor(canonical: "foo", rank: nil)
        let b = makeDescriptor(canonical: "bar", rank: 10)
        let sorted = PresentationModelSorter.sorted([a, b])
        #expect(sorted.map(\.canonicalModelID) == ["bar", "foo"])
    }

    @Test("Subtitle Fallback")
    func subtitleFallback() {
        let withVendor = makeDescriptor(vendorName: "Anthropic", groupName: "Claude 4")
        let withoutVendor = makeDescriptor(vendorName: nil, groupName: "GPT-5")
        let empty = makeDescriptor(vendorName: nil, groupName: nil)

        #expect(withVendor.vendorName == "Anthropic")
        #expect(withoutVendor.groupName == "GPT-5")
        #expect(empty.vendorName == nil && empty.groupName == nil)
    }

    @Test("From AIModel Ignores Provider Kind")
    func fromAIModelIgnoresProviderKind() {
        let model = AIModel(
            id: "anthropic/claude-sonnet-4",
            name: "Claude Sonnet 4",
            capabilities: [.text, .reasoning],
            reasoningModeAvailable: true,
            isAvailable: true,
            isDefault: false,
            priceTier: "$3/M",
            groupKey: "anthropic",
            groupName: "Anthropic",
            promptPrice: 0.000003,
            completionPrice: 0.000015,
            canonicalModelId: "anthropic/claude-sonnet-4",
            isRecommended: true,
            sortRank: 150,
            badgeOrder: [.reasoning]
        )
        let descriptor = PresentationModelDescriptor(from: model, isEnabled: true, isDefault: false)

        #expect(descriptor.canonicalModelID == "anthropic/claude-sonnet-4")
        #expect(descriptor.groupKey == "anthropic")
        #expect(descriptor.groupName == "Anthropic")
        #expect(descriptor.pricingStatus == "priced")
        #expect(descriptor.capabilities == [.text, .reasoning])
        #expect(descriptor.rank == 150)
    }

    @Test("Compact Visible Capabilities Use Production Evidence")
    func compactVisibleCapabilitiesUseProductionEvidence() async throws {
        await MetadataClient.shared.resetForTesting()
        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(capability: "web", recipeRef: "openai.responses.web.v1"),
            .init(
                capability: "reasoning",
                recipeRef: "openai.responses.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "openai.responses.reasoning.v1"
                )
            )
        )
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": \(runtime),
          "profiles": {
            "reasoning": {"reasoning-profile": {"levels": ["deep"]}},
            "webSearch": {"web-profile": {"mergeParams": {"tools": [{"type":"web_search"}]}}}
          },
          "providers": {"openAI": {
            "resolveMap": {"badge-model":"badge-model"},
            "models": {"badge-model": {
              "canonicalModelId":"badge-model",
              "transport":"openai_responses",
              "capabilities":["text","image","web","reasoning"],
              "capabilityControls":\(controls),
              "profiles":{"reasoning":"reasoning-profile","webSearch":"web-profile"}
            }}
          }}
        }
        """, metadataETag: "badge-etag")
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let model = AIModel(
            id: "badge-model",
            name: "Badge Model",
            capabilities: [.text, .image, .file, .web, .reasoning],
            reasoningModeAvailable: true,
            isAvailable: true,
            isDefault: true,
            priceTier: "",
            badgeOrder: [.image, .file, .web, .reasoning]
        )

        #expect(model.visibleMetadataCapabilities(provider: provider, maxCapabilities: 2) == [.image, .web])

        var relay = TestFactories.makeProvider(id: UUID(), kind: .relay)
        relay.baseURLText = "https://relay.test/v1"
        relay.relayRequested = .init(transport: .auto)
        #expect(
            model.visibleMetadataCapabilities(provider: relay, maxCapabilities: 4) == [.file],
            "When Relay has no actual transport/final endpoint scope, the H2 badge must fail-closed; file stays as-is"
        )
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Badge Reprojects After Observed Metadata Revision")
    func badgeReprojectsAfterObservedMetadataRevision() async throws {
        await MetadataClient.shared.resetForTesting()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let model = TestFactories.makeModel(id: "observed-badge", capabilities: [.text, .web])
        let before = await CapabilityEvidenceObservationBridge.shared.contentRevision

        #expect(model.visibleMetadataCapabilities(provider: provider).isEmpty)
        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(capability: "web", recipeRef: "openai.responses.web.v1")
        )
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": \(runtime),
          "profiles": {
            "webSearch": {"web-profile": {"mergeParams": {"tools": [{"type":"web_search"}]}}}
          },
          "providers": {"openAI": {
            "resolveMap": {"observed-badge":"observed-badge"},
            "models": {"observed-badge": {
              "canonicalModelId":"observed-badge",
              "transport":"openai_responses",
              "capabilities":["text","web"],
              "capabilityControls":\(controls),
              "profiles":{"webSearch":"web-profile"}
            }}
          }}
        }
        """, metadataETag: "observed-badge-etag")

        let after = await CapabilityEvidenceObservationBridge.shared.contentRevision
        #expect(after > before)
        #expect(model.visibleMetadataCapabilities(provider: provider) == [.web])
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Model List Rows Project Once Per Model And Revision")
    func modelListRowsProjectOncePerModelAndRevision() {
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let revision: UInt64 = 42
        let models = (0..<810).map { index in
            TestFactories.makeModel(
                id: "projection-count-\(index)",
                capabilities: [.text, .file]
            )
        }
        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()

        for model in models {
            _ = ModelListMetadataRow(
                model: model,
                provider: provider,
                capabilityEvidenceRevision: revision,
                compact: true,
                showPrice: false
            ).body
        }

        for model in models {
            #expect(
                ModelCapabilityEvidencePresentation.constructionCountForTesting(
                    providerKind: provider.kind,
                    modelID: model.id
                ) == 1,
                "\(model.id) must construct presentation only once during a single row-body evaluation of the same revision"
            )
        }
    }

    @Test("Precomputed Capabilities Avoid Child Row Reprojection")
    func precomputedCapabilitiesAvoidChildRowReprojection() {
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let model = TestFactories.makeModel(
            id: "precomputed-row",
            capabilities: [.text, .file]
        )
        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()

        _ = ProviderEnabledModelRow(
            model: model,
            provider: provider,
            capabilityEvidenceRevision: 42,
            isHighlighted: false,
            isMissingFromCatalog: false,
            isLast: true,
            canSetDefault: true,
            canRemove: true,
            setDefaultAction: {},
            chatAction: {},
            removeAction: {}
        ).body
        #expect(
            ModelCapabilityEvidencePresentation.constructionCountForTesting(
                providerKind: provider.kind,
                modelID: model.id
            ) == 1,
            "Enabled row may construct production presentation only once for visibility"
        )

        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        let projected = model.visibleMetadataCapabilities(provider: provider)
        #expect(
            ModelCapabilityEvidencePresentation.constructionCountForTesting(
                providerKind: provider.kind,
                modelID: model.id
            ) == 1
        )

        _ = ModelListMetadataRow(
            model: model,
            provider: provider,
            capabilityEvidenceRevision: 42,
            projectedCapabilities: projected,
            compact: true,
            showPrice: false
        ).body

        #expect(
            ModelCapabilityEvidencePresentation.constructionCountForTesting(
                providerKind: provider.kind,
                modelID: model.id
            ) == 1
        )
    }
}
