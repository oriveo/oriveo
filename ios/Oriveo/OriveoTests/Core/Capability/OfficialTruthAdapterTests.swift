import Foundation
import Testing
@testable import Oriveo

/// The three input keys of an official connection only read the recipe's `capabilityControls[key]` through
/// production `capabilityProjection(provider:)`: a missing key = unknown (the entry stays open), and the legacy
/// catalog `capabilities` bit no longer produces supported.
@Suite("OfficialTruthAdapter", .serialized, .sharedProcessState)
struct OfficialTruthAdapterTests {
    private static let metadataETag = "official-input-truth"
    private static let keys: Set<String> = Set(CapabilityEvidenceFacade.inputCapabilityKeys)

    private static func install(capabilities: [String], controls: String, toolCall: Bool? = nil) async throws {
        let encoded = try JSONSerialization.data(withJSONObject: capabilities)
        let capabilitiesJSON = String(decoding: encoded, as: UTF8.self)
        let toolCallJSON = toolCall.map { " \"toolCall\": \($0)," } ?? ""
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": {
            "schemaVersion": \(RequestPreferenceResolver.runtimeSchemaVersion),
            "revision": "sha256:official-input", "generatedAt": "2026-10-19T02:00:00Z",
            "recipes": {}, "controlDefinitions": {}, "sourceIndex": {}
          },
          "providers": {"qwen": {"resolveMap": {"input-model": "input-model"},
            "models": {"input-model": {
              "canonicalModelId": "input-model", "transport": "openai_chat",
              "capabilities": \(capabilitiesJSON),\(toolCallJSON)
              "profiles": {},
              "capabilityControls": {\(controls)}
            }}
          }}
        }
        """, metadataETag: metadataETag)
    }

    private static func projection(keys: Set<String> = keys) -> (CapabilityEvidenceProjection, Provider, AIModel) {
        let persisted = TestFactories.makeModel(id: "input-model", capabilities: [.text, .image])
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: .qwen)
        let provider = TestFactories.makeProvider(id: UUID(), kind: .qwen, models: [model])
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: "u1",
            hasExplicitValue: false, metadataETag: metadataETag
        )
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity, keys: keys
        )
        return (projection, provider, model)
    }

    private static func inputProjection(provider: Provider, model: AIModel, key: String)
        -> CapabilityEvidenceFacade.InputCapabilityProjection {
        let verdict = CapabilityControlResolution.inputVerdict(
            providerKind: provider.kind, modelID: model.id, key: key
        )
        return CapabilityEvidenceFacade.inputCapabilityProjection(
            verdict: .init(state: verdict.state, reasonCode: verdict.reasonCode),
            endImplements: true, override: nil, negativeCacheHit: false, connection: .official
        )
    }

    @Test("Each of the three input keys projects its own capabilityControls entry")
    func eachInputKeyProjectsOwnControl() async throws {
        try await Self.install(capabilities: ["text", "image"], controls: """
        "vision_input": {"state": "auto_available", "sourceRefs": ["qwen.docs"]},
        "file_input": {"state": "unavailable", "reasonCode": "transport_not_supported"},
        "video_input": {"state": "unavailable", "reasonCode": "model_capability_absent"}
        """)
        let (projection, provider, model) = Self.projection()
        #expect(ProviderForm.of(provider) == .official)

        #expect(projection.resolution(for: "vision_input")?.support == .supported)
        #expect(projection.permitsOutbound("vision_input"))
        #expect(projection.resolution(for: "file_input")?.support == .unsupported)
        #expect(!projection.permitsOutbound("file_input"))
        #expect(projection.resolution(for: "video_input")?.support == .unsupported)

        let vision = Self.inputProjection(provider: provider, model: model, key: "vision_input")
        #expect(vision.visible && vision.editable && vision.outbound == .nativePart)
        let file = Self.inputProjection(provider: provider, model: model, key: "file_input")
        #expect(file.disabledReason == .wireNotImplemented)
        let video = Self.inputProjection(provider: provider, model: model, key: "video_input")
        #expect(video.disabledReason == .modelAbsent)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("A missing key = unknown with the entry open; capabilities containing image without a control is still unknown")
    func missingControlStaysUnknownDespiteImageBit() async throws {
        try await Self.install(capabilities: ["text", "image", "file", "video"], controls: "")
        let (projection, provider, model) = Self.projection()
        #expect(model.capabilities.contains(.image), "Precondition: the legacy catalog bit does have image")

        for key in CapabilityEvidenceFacade.inputCapabilityKeys {
            let resolution = try #require(projection.resolution(for: key), "\(key)")
            #expect(resolution.support == .unknown, "\(key)")
            #expect(resolution.source != CapabilityEvidenceFacade.Source.legacyMetadata, "\(key) does not fall back to the legacy catalog bit")
            let input = Self.inputProjection(provider: provider, model: model, key: key)
            #expect(!input.visible && input.editable, "\(key) entry open")
            #expect(input.outbound == .nativePart && input.hint == .firstAttachOnce, "\(key)")
            #expect(input.disabledReason == nil, "\(key)")
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Official tool_call evidence missing with top-level toolCall=true: projects unknown and does not fall back to the top-level field")
    func officialToolCallWithoutEvidenceProjectsUnknown() async throws {
        try await Self.install(capabilities: ["text"], controls: "", toolCall: true)
        let resolved = try #require(MetadataClient.shared.syncResolveCatalogModel(modelID: "input-model", providerKind: .qwen))
        #expect(resolved.toolCall == true, "Precondition: catalog top-level toolCall=true")
        #expect(resolved.capabilityEvidenceCandidates.allSatisfy { $0.key != "tool_call" }, "Precondition: there is no tool_call evidence")
        let (projection, _, _) = Self.projection(keys: ["tool_call"])
        let resolution = try #require(projection.resolution(for: "tool_call"))
        #expect(resolution.support == .unknown)
        #expect(resolution.source != CapabilityEvidenceFacade.Source.legacyMetadata)
        #expect(!projection.hasConclusiveDecision("tool_call"))
        await MetadataClient.shared.resetForTesting()
    }
}
