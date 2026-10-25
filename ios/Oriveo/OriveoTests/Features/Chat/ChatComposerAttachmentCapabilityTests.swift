import Foundation
import Testing
@testable import Oriveo

/// The composer's attachment entries only read the facade's entry result: an unavailable entry stays visible but disabled and states the reason.
@Suite("ChatComposerAttachmentCapability", .serialized, .sharedProcessState)
struct ChatComposerAttachmentCapabilityTests {
    private static let metadataETag = "composer-attachment-capability"
    private static let partitionID = "composer-attachment"
    private static let vision = CapabilityEvidenceFacade.visionInputKey

    private static func installOfficial(controls: String) async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": {
            "schemaVersion": \(RequestPreferenceResolver.runtimeSchemaVersion),
            "revision": "sha256:composer-attachment", "generatedAt": "2026-10-19T02:00:00Z",
            "recipes": {}, "controlDefinitions": {}, "sourceIndex": {}
          },
          "providers": {"qwen": {
            "attachmentSupport": {"image": false, "nativeFile": false, "textFileInline": true},
            "resolveMap": {"input-model": "input-model"},
            "models": {"input-model": {
              "canonicalModelId": "input-model", "transport": "openai_chat",
              "capabilities": ["text", "image", "file", "video"],
              "profiles": {},
              "capabilityControls": {\(controls)}
            }}
          }}
        }
        """, metadataETag: metadataETag)
    }

    private static func official(provider existing: Provider? = nil) -> (Provider, AIModel, ComposerAttachmentEntries) {
        let provider: Provider
        if let existing {
            provider = existing
        } else {
            let persisted = TestFactories.makeModel(id: "input-model", capabilities: [.text, .image, .video])
            let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: .qwen)
            provider = TestFactories.makeProvider(id: UUID(), kind: .qwen, models: [model])
        }
        let model = provider.models[0]
        return (provider, model, .resolve(provider: provider, model: model, partitionID: partitionID))
    }

    private static func expectDisabled(
        _ entry: ComposerAttachmentEntries.Entry,
        _ reason: CapabilityEvidenceFacade.InputDisabledReason,
        _ medium: InputCapabilityCopy.Medium,
        _ label: String
    ) {
        #expect(entry.isVisible && !entry.isEnabled, "\(label) is visible and disabled")
        #expect(entry.disabledReason == InputCapabilityCopy.disabled(reason, medium), "\(label) reason")
        #expect(!entry.hintsFirstAttach, "\(label) shows no hint while disabled")
    }

    @Test("official unknown: the image entry is enabled with a first-use hint, consistent with the visibleCapabilityKeys criterion")
    func officialUnknownImageEntryEnabled() async throws {
        try await Self.installOfficial(controls: "")
        let (provider, model, entries) = Self.official()
        #expect(entries.image.isEnabled && entries.image.disabledReason == nil)
        #expect(entries.image.hintsFirstAttach)
        let projection = ChatView.capabilityProjection(provider: provider, model: model, partitionID: Self.partitionID)
        let keys = ChatView.visibleCapabilityKeys(provider: provider, model: model, projection: projection)
        #expect(ChatComposerBar.supportsImageAttachment(provider: provider, model: model, visibleCapabilityKeys: keys))
        #expect(ChatView.photoPickerVisible(provider: provider, model: model, partitionID: Self.partitionID))
        await MetadataClient.shared.resetForTesting()
    }

    @Test("official unavailable: image / video entries are visible but disabled with model_absent, the text file entry stays enabled")
    func officialUnavailableDisablesWithReason() async throws {
        try await Self.installOfficial(controls: """
        "vision_input": {"state": "unavailable", "reasonCode": "model_capability_absent"},
        "file_input": {"state": "unavailable", "reasonCode": "model_capability_absent"},
        "video_input": {"state": "unavailable", "reasonCode": "model_capability_absent"}
        """)
        let (_, model, entries) = Self.official()
        Self.expectDisabled(entries.image, .modelAbsent, .image, "image")
        _ = model
        Self.expectDisabled(entries.video, .modelAbsent, .video, "video")
        #expect(entries.file.isEnabled, "textFileInline=true still accepts text files")
        await MetadataClient.shared.resetForTesting()
    }

    @Test("official wire family not implemented here: the image entry is visible but disabled with wire_not_implemented")
    func officialUnimplementedFamilyDisables() async throws {
        try await Self.installOfficial(controls: """
        "vision_input": {"state": "auto_available", "wireFamily": "openai_chat.input_audio"}
        """)
        let (_, _, entries) = Self.official()
        Self.expectDisabled(entries.image, .wireNotImplemented, .image, "unimplemented family")
        await MetadataClient.shared.resetForTesting()
    }

    @Test("official v2 negative-cache hit: the image entry is visible but disabled with rejected_recently")
    func officialNegativeCacheDisables() async throws {
        let family = "openai_chat.image_url"
        try await Self.installOfficial(controls: """
        "vision_input": {"state": "auto_available", "wireFamily": "\(family)", "sourceRefs": ["qwen.docs"]}
        """)
        let (provider, model, before) = Self.official()
        #expect(before.image.isEnabled && !before.image.hintsFirstAttach, "precondition: auto_available is enabled and shows no hint")
        let identity = try #require(ChatView.capabilityEvidenceIdentity(
            provider: provider, model: model, partitionID: Self.partitionID
        ))
        let connectionID = provider.id.uuidString
        defer { CapabilityNegativeCache.shared.clearConnection(connectionID) }
        CapabilityNegativeCache.shared.record(
            connectionId: connectionID, modelId: identity.query.effectiveModelID, wireFamily: family,
            capabilityKey: Self.vision, signatureId: "openai.image_unsupported",
            verdictRevision: CapabilityNegativeCache.verdictRevision(.init(
                state: "auto_available", wireFamily: family, sourceRefs: ["qwen.docs"]
            ))
        )
        let (_, _, after) = Self.official(provider: provider)
        Self.expectDisabled(after.image, .rejectedRecently, .image, "negative cache")
        await MetadataClient.shared.resetForTesting()
    }

    @Test("picking / dropping unavailable media: nothing is queued, the hint states the same reason; the first-use hint is given once per model")
    func admissionRefusesWithSameReasonAndHintsOnce() async throws {
        try await Self.installOfficial(controls: """
        "vision_input": {"state": "unavailable", "reasonCode": "model_capability_absent"}
        """)
        let (_, _, blocked) = Self.official()
        let image = TestFactories.makeImageAttachment()
        let file = TestFactories.makeFileAttachment(fileName: "note.txt", mimeType: "text/plain")
        let admission = ComposerAttachmentAdmission.partition([image, file], entries: blocked)
        #expect(admission.accepted.map(\.id) == [file.id])
        #expect(admission.refusalReasons == [try #require(blocked.image.disabledReason)])

        try await Self.installOfficial(controls: "")
        let (provider, model, open) = Self.official()
        let defaults = try #require(UserDefaults(suiteName: "composer-hint-\(UUID().uuidString)"))
        let history = InputCapabilityHintHistory(defaults: defaults)
        let first = ComposerAttachmentAdmission.firstAttachHint(
            added: [image], entries: open, providerID: provider.id, modelID: model.id, history: history
        )
        #expect(first == InputCapabilityCopy.hintFirstAttach(.image))
        let second = ComposerAttachmentAdmission.firstAttachHint(
            added: [image], entries: open, providerID: provider.id, modelID: model.id, history: history
        )
        #expect(second == nil, "one hint per model regardless of medium")
        await MetadataClient.shared.resetForTesting()
    }

    @Test("official video_input key missing and the model's legacy field does not declare video: the video entry is visible and tappable")
    func officialMissingVideoKeyOpensVideoEntry() async throws {
        try await Self.installOfficial(controls: "")
        let persisted = TestFactories.makeModel(id: "input-model", capabilities: [.text, .image])
        var model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: .qwen)
        model.capabilities = model.capabilities.filter { $0 != .video }
        #expect(!model.capabilities.contains(.video), "precondition: the legacy field does not declare video")
        let provider = TestFactories.makeProvider(id: UUID(), kind: .qwen, models: [model])
        let entries = ComposerAttachmentEntries.resolve(provider: provider, model: model, partitionID: Self.partitionID)
        #expect(entries.video.isVisible && entries.video.isEnabled && entries.video.disabledReason == nil)
        #expect(entries.video.hintsFirstAttach)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("the file picker picks an unavailable video: the rejection hint equals the entry reason and is not counted as \"unsupported format\"")
    @MainActor
    func fileImporterRefusalUsesEntryReason() async throws {
        try await Self.installOfficial(controls: """
        "vision_input": {"state": "unavailable", "reasonCode": "model_capability_absent"},
        "file_input": {"state": "unavailable", "reasonCode": "model_capability_absent"},
        "video_input": {"state": "unavailable", "reasonCode": "model_capability_absent"}
        """)
        let (provider, model, entries) = Self.official()
        let videoReason = try #require(entries.video.disabledReason)
        #expect(videoReason == InputCapabilityCopy.disabled(.modelAbsent, .video))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = directory.appendingPathComponent("clip.mp4")
        try Data(repeating: 0, count: 16).write(to: clip)
        let blob = directory.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: blob)

        let result = await ChatDropImport.processFileURLs(
            [clip, blob],
            availableSlots: 5,
            importContext: .init(provider: provider, model: model, partitionID: Self.partitionID),
            byteLimit: 1_024,
            extractionLimits: .default,
            refusalReasons: entries.fileImportRefusalReasons
        )
        #expect(result.attachments.isEmpty)
        #expect(result.refusalReasons == [videoReason])
        #expect(result.rejectedCount == 1, "a .bin that is unsupported by itself is still counted as \"unsupported format\"")
        await MetadataClient.shared.resetForTesting()
    }
}
