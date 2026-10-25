import Foundation
import Testing
@testable import Oriveo

/// Capability visibility in the model picker.
///
/// This suite protects exactly one thing: the badges and the chip counts can never diverge. If the
/// user sees "83 can think", the list must contain exactly 83 rows showing the thinking badge.
/// Writing the rule twice - once for the chip and once for the row - is the failure mode this
/// guards against.
@Suite("Model picker capability filter", .serialized, .sharedProcessState)
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

    @Test("the intent badge index matches row-by-row evaluation, builds each presentation once, and never shares duplicate ids")
    func intentIndexMatchesDirectEvaluation() async throws {
        try await Self.loadFixture()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        // A repeated model id: one declares capabilities, the other does not (a messy relay catalog).
        let duplicatePlain = TestFactories.makeModel(id: "m-both", capabilities: [.text])
        let sections = [ModelPickerSection(provider: provider, models: Self.fixtureModels + [duplicatePlain])]

        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        let index = ModelPickerCapabilityFilter.intentIndex(sections: sections)
        let constructions = (Self.fixtureModels.map(\.id)).reduce(0) {
            $0 + ModelCapabilityEvidencePresentation.constructionCountForTesting(providerKind: .openAI, modelID: $1)
        }
        // Building the index constructs each id once; the colliding duplicate is neither precomputed nor indexed.
        #expect(constructions == Self.fixtureModels.count)
        #expect(index[ModelPickerCapabilityFilter.indexKey(providerID: provider.id, modelID: "m-both")] == nil)
        #expect(index.count == Self.fixtureModels.count - 1)

        #expect(
            ModelPickerCapabilityFilter.counts(sections: sections, index: index)
                == ModelPickerCapabilityFilter.counts(sections: sections)
        )
        for active in [Set<ModelPickerCapabilityFilter.Capability>([.web]), [.reasoning], [.web, .reasoning]] {
            let indexed = ModelPickerCapabilityFilter.apply(sections: sections, active: active, index: index)
            let direct = ModelPickerCapabilityFilter.apply(sections: sections, active: active)
            #expect(indexed.flatMap(\.models).map(\.id) == direct.flatMap(\.models).map(\.id))
        }

        // Looking up the index builds no presentations, except for the duplicate rows evaluated row by row.
        ModelCapabilityEvidencePresentation.resetConstructionCountsForTesting()
        _ = ModelPickerCapabilityFilter.apply(sections: sections, active: [.web, .reasoning], index: index)
        let afterApply = Self.fixtureModels.map(\.id).reduce(0) {
            $0 + ModelCapabilityEvidencePresentation.constructionCountForTesting(providerKind: .openAI, modelID: $1)
        }
        #expect(afterApply == 2, "only the two rows sharing a duplicate id should be evaluated row by row, got \(afterApply)")
        await MetadataClient.shared.resetForTesting()
    }

    // MARK: - Image / file / video badges read the projection's visible flag

    @Test("an official model with unknown vision shows no badge; only auto + a wire family implemented here does; an unimplemented family does not")
    func imageBadgeFollowsInputProjection() async throws {
        try await Self.loadInputFixture()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let unknown = TestFactories.makeModel(id: "in-image-unknown", capabilities: [.text, .image])
        let missing = TestFactories.makeModel(id: "in-image-missing", capabilities: [.text, .image])
        let auto = TestFactories.makeModel(id: "in-image-auto", capabilities: [.text, .image])
        let unimplemented = TestFactories.makeModel(id: "in-image-unimplemented", capabilities: [.text, .image])

        let autoProjection = ModelCapabilityEvidencePresentation(provider: provider, model: auto)
            .projection.inputProjection(for: CapabilityEvidenceFacade.visionInputKey)
        #expect(autoProjection?.visible == true, "precondition: the production projection for auto + openai_responses.input_image is visible")
        #expect(ModelPickerCapabilityFilter.visibleCapabilities(model: auto, provider: provider).contains(.image))

        for model in [unknown, missing, unimplemented] {
            #expect(
                !ModelPickerCapabilityFilter.visibleCapabilities(model: model, provider: provider).contains(.image),
                "\(model.id)'s vision projection is not visible, so the image badge must stay off"
            )
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("the file and video badges are no longer always shown; they follow the projection's visible flag")
    func fileAndVideoBadgesFollowInputProjection() async throws {
        try await Self.loadInputFixture()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let auto = TestFactories.makeModel(id: "in-media-auto", capabilities: [.text, .file, .video])
        let unknown = TestFactories.makeModel(id: "in-media-unknown", capabilities: [.text, .file, .video])

        let autoBadges = ModelPickerCapabilityFilter.visibleCapabilities(model: auto, provider: provider)
        #expect(autoBadges.contains(.file), "file_input auto + openai_responses.input_file should show the file badge")
        // video_input auto + the wire family implemented here, openai_chat.video_url -> visible.
        #expect(autoBadges.contains(.video))

        let unknownBadges = ModelPickerCapabilityFilter.visibleCapabilities(model: unknown, provider: provider)
        #expect(!unknownBadges.contains(.file), "a missing file_input key means unknown, so the file badge must stay off")
        #expect(!unknownBadges.contains(.video), "video_input unknown must not show the video badge")
        await MetadataClient.shared.resetForTesting()
    }

    @Test("a Qwen model whose capabilities include web while the web control is unknown: no web badge, the same result as the control")
    func qwenWebBadgeMatchesControl() async throws {
        try await Self.loadInputFixture()
        let provider = TestFactories.makeProvider(id: UUID(), kind: .qwen)
        let model = TestFactories.makeModel(id: "qwen-web-unknown", capabilities: [.text, .web])
        #expect(model.capabilities.contains(.web), "precondition: the model declares web bare")

        let control = CapabilityControlResolution.resolve(provider: provider, model: model, capability: "web")
        #expect(!control.isAvailable, "precondition: an unknown web control is unavailable")
        let badges = ModelPickerCapabilityFilter.visibleCapabilities(model: model, provider: provider)
        #expect(badges.contains(.web) == control.isAvailable)
        #expect(!ModelPickerCapabilityFilter.matches(model: model, provider: provider, capability: .web))
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
        // Row badges and the filter share the visibleMetadataCapabilities projection; the row only
        // truncates for display, the same way the provider detail row does.
        #expect(
            sheet.contains("model.visibleMetadataCapabilities(provider: provider)"),
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
        var crowdedControlsObject = CapabilityRuntimeFixtures.controls(
            .init(capability: "web", recipeRef: "openai.responses.web.v1"),
            .init(
                capability: "reasoning",
                recipeRef: "openai.responses.reasoning.v1",
                availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(
                    ofRecipe: "openai.responses.reasoning.v1"
                )
            )
        )
        // The image / file badges only trust the projection's visible flag: give auto + a wire family implemented here explicitly, or this row would not really be crowded enough to be truncated.
        crowdedControlsObject[CapabilityEvidenceFacade.visionInputKey] =
            ["state": "auto_available", "wireFamily": "openai_responses.input_image"]
        crowdedControlsObject[CapabilityEvidenceFacade.fileInputKey] =
            ["state": "auto_available", "wireFamily": "openai_responses.input_file"]
        let crowdedControls = String(decoding: try JSONSerialization.data(
            withJSONObject: crowdedControlsObject, options: [.sortedKeys]
        ), as: UTF8.self)
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
                "capabilityControls":\(crowdedControls)},
              "m-claims-web": {"canonicalModelId":"m-claims-web","transport":"openai_responses",
                "capabilities":["text","web"]}
            }
          }}
        }
        """, metadataETag: "model-picker-filter-fixture")
    }

    /// Fixture for the three input keys and the Qwen web case: each model carries only the controls it tests.
    private static func loadInputFixture() async throws {
        await MetadataClient.shared.resetForTesting()
        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        func model(_ id: String, transport: String, capabilities: String, controls: String) -> String {
            """
            "\(id)": {"canonicalModelId":"\(id)","transport":"\(transport)",
              "capabilities":\(capabilities),"capabilityControls":{\(controls)}}
            """
        }
        let openAIModels = [
            model("in-image-unknown", transport: "openai_responses", capabilities: #"["text","image"]"#,
                  controls: #""vision_input":{"state":"unknown"}"#),
            model("in-image-missing", transport: "openai_responses", capabilities: #"["text","image"]"#,
                  controls: ""),
            model("in-image-auto", transport: "openai_responses", capabilities: #"["text","image"]"#,
                  controls: #""vision_input":{"state":"auto_available","wireFamily":"openai_responses.input_image"}"#),
            model("in-image-unimplemented", transport: "openai_responses", capabilities: #"["text","image"]"#,
                  controls: #""vision_input":{"state":"auto_available","wireFamily":"bedrock.image"}"#),
            model("in-media-auto", transport: "openai_responses", capabilities: #"["text","file","video"]"#,
                  controls: #""file_input":{"state":"auto_available","wireFamily":"openai_responses.input_file"},"video_input":{"state":"auto_available","wireFamily":"openai_chat.video_url"}"#),
            model("in-media-unknown", transport: "openai_responses", capabilities: #"["text","file","video"]"#,
                  controls: #""video_input":{"state":"unknown"}"#),
        ]
        let openAIIDs = ["in-image-unknown", "in-image-missing", "in-image-auto", "in-image-unimplemented",
                         "in-media-auto", "in-media-unknown"]
        let resolveMap = openAIIDs.map { "\"\($0)\":\"\($0)\"" }.joined(separator: ",")
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": \(runtime),
          "providers": {
            "openAI": {"resolveMap": {\(resolveMap)}, "models": {\(openAIModels.joined(separator: ","))}},
            "qwen": {"resolveMap": {"qwen-web-unknown":"qwen-web-unknown"}, "models": {\(
              model("qwen-web-unknown", transport: "openai_chat", capabilities: #"["text","web"]"#,
                    controls: #""web":{"state":"unknown"}"#)
            )}}
          }
        }
        """, metadataETag: "model-picker-input-fixture")
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
