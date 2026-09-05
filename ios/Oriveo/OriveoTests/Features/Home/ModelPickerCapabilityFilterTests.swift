import Foundation
import Testing
@testable import Oriveo

/// Capability visibility in the model picker.
///
/// This suite protects exactly one thing: the badges and the chip counts can never diverge. If the
/// user sees "83 can think", the list must contain exactly 83 rows showing the thinking badge.
/// Writing the rule twice - once for the chip and once for the row - is the failure mode this
/// guards against.
@Suite("Model picker capability filter", .serialized)
@MainActor
struct ModelPickerCapabilityFilterTests {
    @Test("Counts Match Badges Model By Model")
    func countsMatchBadgesModelByModel() async throws {
        try await Self.loadFixture()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let models = Self.fixtureModels
        let section = ModelPickerSection(provider: provider, models: models)

        let counts = ModelPickerCapabilityFilter.counts(sections: [section])

        #expect(counts[.web] == 3, "the web count should be m-web, m-both and m-crowded, got \(counts[.web] ?? -1)")
        #expect(counts[.reasoning] == 3, "the reasoning count should be m-think, m-both and m-crowded, got \(counts[.reasoning] ?? -1)")
        let claimsWeb = try #require(models.first { $0.id == "m-claims-web" })
        #expect(claimsWeb.capabilities.contains(.web), "the control model must really declare web on its own")
        #expect(
            !ModelPickerCapabilityFilter.matches(model: claimsWeb, provider: provider, capability: .web),
            "a bare declaration with no published recipe must not light the web badge"
        )

        for capability in ModelPickerCapabilityFilter.Capability.allCases {
            let badgeRows = models.filter {
                ModelPickerCapabilityFilter.intentCapabilities(model: $0, provider: provider)
                    .contains(capability)
            }.count
            #expect(
                counts[capability] == badgeRows,
                "\(capability.rawValue): the chip says \(counts[capability] ?? -1) but \(badgeRows) rows show the badge"
            )
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Crowded Row Keeps Intent Badges")
    func crowdedRowKeepsIntentBadges() async throws {
        try await Self.loadFixture()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let crowded = try #require(Self.fixtureModels.first { $0.id == "m-crowded" })
        let truncated = crowded.visibleMetadataCapabilities(provider: provider, maxCapabilities: 2)
        let full = ModelPickerCapabilityFilter.visibleCapabilities(model: crowded, provider: provider)
        #expect(truncated.count == 2)
        #expect(full.count > truncated.count, "this row must really carry enough capabilities to be truncated, otherwise the test proves nothing")
        #expect(!truncated.contains(.reasoning))
        #expect(full.contains(.reasoning))
        #expect(
            ModelPickerCapabilityFilter.intentCapabilities(visibleCapabilities: full)
                .contains(.reasoning),
            "the thinking badge must survive the untruncated pass"
        )
        #expect(
            ModelPickerCapabilityFilter.intentCapabilities(visibleCapabilities: full)
                == ModelPickerCapabilityFilter.intentCapabilities(model: crowded, provider: provider),
            "the row renderer and the filter must return the same result"
        )
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Apply Filters By Intersection")
    func applyFiltersByIntersection() async throws {
        try await Self.loadFixture()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let sections = [ModelPickerSection(provider: provider, models: Self.fixtureModels)]

        #expect(
            ModelPickerCapabilityFilter.apply(sections: sections, active: []).first?.models.count == 6,
            "selecting no chip must not change the list"
        )

        let webOnly = ModelPickerCapabilityFilter.apply(sections: sections, active: [.web])
        #expect(webOnly.flatMap(\.models).map(\.id).sorted() == ["m-both", "m-crowded", "m-web"])

        let both = ModelPickerCapabilityFilter.apply(sections: sections, active: [.web, .reasoning])
        #expect(both.flatMap(\.models).map(\.id).sorted() == ["m-both", "m-crowded"])

        let noneMatch = ModelPickerCapabilityFilter.apply(
            sections: [ModelPickerSection(
                provider: provider,
                models: Self.fixtureModels.filter { $0.id == "m-plain" }
            )],
            active: [.web]
        )
        #expect(noneMatch.isEmpty)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Picker Consumes The Shared Filter")
    func pickerConsumesTheSharedFilter() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Home", "HomeModelPickerSheet.swift",
        ])
        #expect(sheet.contains("capabilityFilterChips"), "the picker has no capability filter chips")
        #expect(sheet.contains("ModelPickerCapabilityFilter.apply("))
        #expect(sheet.contains("ModelPickerCapabilityFilter.counts("))
        #expect(
            sheet.contains("ModelPickerCapabilityFilter.intentCapabilities(visibleCapabilities:"),
            "the row badge does not use the same rule"
        )
        #expect(
            sheet.contains("capabilityCounts = ModelPickerCapabilityFilter.counts("),
            "the counts are not cached in @State"
        )
        #expect(sheet.contains("Clear capability filters"))
    }

    // MARK: - fixture

    /// Six models covering five shapes: web only, reasoning only, both, neither, so many
    /// capabilities that the row is truncated, and - the important one - a model that declares web
    /// on its own with no published recipe behind it.
    ///
    /// That last model is the control: it makes "judge by the raw `model.capabilities`" and "judge
    /// by the capability resolution" disagree. Without it both rules agree on this fixture and the
    /// "badges and counts share one source" assertion proves nothing - swapping the rule for the raw
    /// capabilities left every test green.
    private static let fixtureModels: [AIModel] = [
        TestFactories.makeModel(id: "m-web", capabilities: [.text, .web]),
        TestFactories.makeModel(id: "m-think", capabilities: [.text, .reasoning]),
        TestFactories.makeModel(id: "m-both", capabilities: [.text, .web, .reasoning]),
        TestFactories.makeModel(id: "m-plain", capabilities: [.text]),
        TestFactories.makeModel(id: "m-crowded", capabilities: [.text, .image, .file, .web, .reasoning]),
        TestFactories.makeModel(id: "m-claims-web", capabilities: [.text, .web]),
    ]

    private static func loadFixture() async throws {
        await MetadataClient.shared.resetForTesting()
        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let webControls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(capability: "web", recipeRef: "openai.responses.web.v1")
        )
        let reasoningControls = try CapabilityRuntimeFixtures.controlsJSON(
            .init(
                capability: "reasoning",
                recipeRef: "openai.responses.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "openai.responses.reasoning.v1"
                )
            )
        )
        let bothControls = try CapabilityRuntimeFixtures.controlsJSON(
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
            "webSearch": {"web-profile": {"mergeParams": {"tools": [{"type":"web_search"}]}}},
            "reasoning": {"reasoning-profile": {"levels": ["balanced", "deep"]}}
          },
          "providers": {"openAI": {
            "resolveMap": {
              "m-web":"m-web", "m-think":"m-think", "m-both":"m-both",
              "m-plain":"m-plain", "m-crowded":"m-crowded", "m-claims-web":"m-claims-web"
            },
            "models": {
              "m-web": {"canonicalModelId":"m-web","transport":"openai_responses",
                "capabilities":["text","web"],"profiles":{"webSearch":"web-profile"},"capabilityControls":\(webControls)},
              "m-think": {"canonicalModelId":"m-think","transport":"openai_responses",
                "capabilities":["text","reasoning"],"profiles":{"reasoning":"reasoning-profile"},"capabilityControls":\(reasoningControls)},
              "m-both": {"canonicalModelId":"m-both","transport":"openai_responses",
                "capabilities":["text","web","reasoning"],
                "profiles":{"webSearch":"web-profile","reasoning":"reasoning-profile"},
                "capabilityControls":\(bothControls)},
              "m-plain": {"canonicalModelId":"m-plain","transport":"openai_responses",
                "capabilities":["text"]},
              "m-crowded": {"canonicalModelId":"m-crowded","transport":"openai_responses",
                "capabilities":["text","image","file","web","reasoning"],
                "profiles":{"webSearch":"web-profile","reasoning":"reasoning-profile"},
                "capabilityControls":\(bothControls)},
              "m-claims-web": {"canonicalModelId":"m-claims-web","transport":"openai_responses",
                "capabilities":["text","web"]}
            }
          }}
        }
        """, metadataETag: "model-picker-filter-fixture")
    }

    private static func source(_ components: [String]) throws -> String {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            current = current.deletingLastPathComponent()
        }
        fatalError("source not found: \(components.joined(separator: "/"))")
    }
}
