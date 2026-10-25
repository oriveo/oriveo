import Foundation
import Testing
@testable import Oriveo

@Suite("ChatAttachmentImportPolicy", .serialized, .sharedProcessState)
struct ChatAttachmentImportPolicyTests {

    @Test("Resolves Known Text Extension")
    func resolvesKnownTextExtension() {
        let mimeType = ChatAttachmentImportPolicy.resolveMimeType(
            fileName: "sample.ts",
            detectedMimeType: "application/octet-stream"
        )

        #expect(mimeType == "text/plain")
    }

    // Attachment extraction spec section 2: mime is consulted only when the extension is unrecognized, any text/* is accepted as plain text; rejected only when neither extension nor mime is recognized.
    @Test("unknown suffix falls back to mime: text/* is accepted as plain text, binary mime is rejected")
    func unknownExtensionFallsBackToMime() {
        #expect(ChatAttachmentImportPolicy.isSupportedFile(
            fileName: "archive.custompkg",
            detectedMimeType: "text/plain"
        ) == true)
        #expect(ChatAttachmentImportPolicy.isSupportedFile(
            fileName: "archive.custompkg",
            detectedMimeType: "application/octet-stream"
        ) == false)
    }

    @Test("Allows Mime Only Known Types")
    func allowsMimeOnlyKnownTypes() {
        let supported = ChatAttachmentImportPolicy.isSupportedFile(
            fileName: "README",
            detectedMimeType: "application/json"
        )

        #expect(supported == true)
    }

    @Test("Resolves Office Extension")
    func resolvesOfficeExtension() {
        let mimeType = ChatAttachmentImportPolicy.resolveMimeType(
            fileName: "budget.xlsx",
            detectedMimeType: nil
        )

        #expect(mimeType == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    }

    @Test("Validates Attachment Size Limit")
    func validatesAttachmentSizeLimit() {
        #expect(ChatAttachmentImportPolicy.isWithinSizeLimit(30 * 1024 * 1024) == true)
        #expect(ChatAttachmentImportPolicy.isWithinSizeLimit(30 * 1024 * 1024 + 1) == false)
    }

    @Test("Custom Limit Capped By Platform Limit")
    func customLimitCappedByPlatformLimit() {
        #expect(ChatAttachmentImportPolicy.isWithinSizeLimit(35 * 1024 * 1024, customLimit: 100 * 1024 * 1024) == false)
        #expect(ChatAttachmentImportPolicy.isWithinSizeLimit(25 * 1024 * 1024, customLimit: 100 * 1024 * 1024) == true)
    }

    @Test("Custom Limit Below Platform Limit")
    func customLimitBelowPlatformLimit() {
        #expect(ChatAttachmentImportPolicy.isWithinSizeLimit(20 * 1024 * 1024, customLimit: 25 * 1024 * 1024) == true)
        #expect(ChatAttachmentImportPolicy.isWithinSizeLimit(26 * 1024 * 1024, customLimit: 25 * 1024 * 1024) == false)
    }

    @Test("Bounded File Reading")
    func boundedFileReading() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data(repeating: 0x61, count: 8).write(to: url)
        #expect(try BoundedFileReader.data(at: url, maxBytes: 8).count == 8)
        #expect(throws: BoundedFileReadError.self) {
            _ = try BoundedFileReader.data(at: url, maxBytes: 7)
        }
    }

    // MARK: - ImportContext entry follows the read-only facade

    private static let metadataETag = "attachment-import-context"
    private static let partitionID = "import-context"

    private static func installOfficial(controls: String) async throws {
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "capabilityRuntime": {
            "schemaVersion": \(RequestPreferenceResolver.runtimeSchemaVersion),
            "revision": "sha256:import-context", "generatedAt": "2026-10-19T02:00:00Z",
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

    private static func officialContext() -> (ChatAttachmentPicker.ImportContext, CapabilityEvidenceProjection) {
        let persisted = TestFactories.makeModel(id: "input-model", capabilities: [.text, .image])
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: .qwen)
        let provider = TestFactories.makeProvider(id: UUID(), kind: .qwen, models: [model])
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: partitionID,
            hasExplicitValue: false, metadataETag: metadataETag
        )
        let projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider: provider, model: model, identity: identity,
            keys: Set(CapabilityEvidenceFacade.inputCapabilityKeys)
        )
        return (.init(provider: provider, model: model, partitionID: partitionID), projection)
    }

    private static func expectEntryFollowsEditable(
        _ entry: CapabilityEvidenceFacade.AttachmentImportEntry,
        _ projection: CapabilityEvidenceProjection,
        _ label: String
    ) throws {
        let vision = try #require(projection.inputProjection(for: CapabilityEvidenceFacade.visionInputKey), "\(label)")
        let file = try #require(projection.inputProjection(for: CapabilityEvidenceFacade.fileInputKey), "\(label)")
        let video = try #require(projection.inputProjection(for: CapabilityEvidenceFacade.videoInputKey), "\(label)")
        #expect(entry.image == vision.editable, "\(label) image")
        #expect(entry.nativeFile == file.editable, "\(label) nativeFile")
        #expect(entry.video == video.editable, "\(label) video")
    }

    private static func importFile(_ data: Data, name: String, context: ChatAttachmentPicker.ImportContext) async throws
        -> ChatAttachmentPicker.ImportResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return await ChatAttachmentPicker.processFileURL(url, importContext: context)
    }

    @Test("Official unknown: the three keys follow the projection editable, image and video import, textFileInline reads metadata")
    func officialUnknownImportsImage() async throws {
        try await Self.installOfficial(controls: "")
        let (context, projection) = Self.officialContext()
        try Self.expectEntryFollowsEditable(context.entry, projection, "official unknown")
        #expect(context.entry.image, "official unknown imports images (metadata attachmentSupport.image=false no longer participates)")
        #expect(context.entry.nativeFile && context.entry.video)
        #expect(context.entry.textFileInline)

        guard case let .imported(video) = try await Self.importFile(
            Data(repeating: 0, count: 16), name: "clip.mp4", context: context
        ) else {
            Issue.record("official unknown should import video")
            await MetadataClient.shared.resetForTesting()
            return
        }
        #expect(video.kind == .video)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Official three keys unavailable: every entry closes, video and binary files are rejected, text files import")
    func officialUnavailableClosesEntries() async throws {
        try await Self.installOfficial(controls: """
        "vision_input": {"state": "unavailable", "reasonCode": "model_capability_absent"},
        "file_input": {"state": "unavailable", "reasonCode": "model_capability_absent"},
        "video_input": {"state": "unavailable", "reasonCode": "model_capability_absent"}
        """)
        let (context, projection) = Self.officialContext()
        try Self.expectEntryFollowsEditable(context.entry, projection, "official unavailable")
        #expect(!context.entry.image && !context.entry.nativeFile && !context.entry.video)

        let video = try await Self.importFile(Data(repeating: 0, count: 16), name: "clip.mp4", context: context)
        guard case .mediumUnavailable(.video) = video else { Issue.record("video should be rejected: \(video)"); return }
        let binary = try await Self.importFile(Data([0xFF, 0xFE, 0x00, 0xD8]), name: "blob.bin", context: context)
        guard case .unsupported = binary else { Issue.record("binary should be rejected: \(binary)"); return }
        guard case let .imported(text) = try await Self.importFile(
            Data("hello".utf8), name: "note.txt", context: context
        ) else {
            Issue.record("text file should import")
            return
        }
        #expect(text.kind == .file)
        await MetadataClient.shared.resetForTesting()
    }

    @Test("Missing provider or model closes every entry")
    func missingContextClosesEntries() {
        #expect(ChatAttachmentPicker.ImportContext(provider: nil, model: nil).entry == .closed)
    }
}
