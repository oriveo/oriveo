import Foundation
import Testing
@testable import Oriveo

// Video placeholders and native-file outbound for official connections.
// The fixture `shared/test-fixtures/attachments/media-outbound.v1.json` is the same bytes on every end;
// both the body text and the native grouping come from what the production `AttachmentDelivery.plan` produces.

@Suite("media-outbound.v1 (iOS)", .serialized, .sharedProcessState)
struct MediaOutboundContractTests {
    private struct Fixture: Decodable {
        struct VideoCase: Decodable {
            struct Routes: Decodable { let ios: String? }
            let id: String
            let videos: Int
            let placeholder: String
            let expectLines: Int
            let routes: Routes
        }
        struct FileCase: Decodable {
            struct Expect: Decodable {
                let nativeFilePart: Bool
                let textInjected: Bool
                let placeholderLine: Bool
            }
            let id: String
            let connection: String
            let routeNativeFiles: Bool
            let fileInputOutbound: String
            let extractedText: Bool
            let expect: Expect
        }
        let v: Int
        let videoPlaceholderCases: [VideoCase]
        let nativeFileCases: [FileCase]
    }

    private static let docxMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    private static let extractedMarker = "EXTRACTED-DOCX-TEXT"

    private static func fixture() throws -> Fixture {
        let url = try fixtureURL("attachments/media-outbound.v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.v == 1)
        return fixture
    }

    /// Shared fixture directory `shared/test-fixtures/<relativePath>`.
    private static func fixtureURL(_ relativePath: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/\(relativePath)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func iosRoute(_ name: String) -> AttachmentTransport? {
        switch name {
        case "deepSeekChat": .deepSeekChat
        case "miniMaxChat": .miniMaxChat
        default: nil
        }
    }

    private static func video(_ index: Int) -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(),
            kind: .video,
            fileName: "clip-\(index).mp4",
            mimeType: "video/mp4",
            base64Data: "VklERU8tQllURVM="
        )
    }

    private static func model() -> AIModel {
        AIModel(
            id: "contract-model",
            name: "contract-model",
            capabilities: [.text, .file],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: true,
            priceTier: "premium",
            nativeFileMimes: [docxMime]
        )
    }

    private static func docx() -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(),
            kind: .file,
            fileName: "report.docx",
            mimeType: docxMime,
            base64Data: Data(extractedMarker.utf8).base64EncodedString(),
            extractedSizeBytes: extractedMarker.utf8.count,
            originalBase64Data: "UEstWklQLUJZVEVT"
        )
    }

    /// The file_input projection comes from production metadata: the fixture outbound maps to the catalog capabilityControls state.
    private static func loadFileInputMetadata(_ outbound: String) async throws {
        let state = switch outbound {
        case "native_part": "auto_available"
        case "placeholder": "unavailable"
        default: throw CocoaError(.coderInvalidValue)
        }
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version":1,
          "providers":{"openAI":{"resolveMap":{"contract-model":"contract-model"},"models":{
            "contract-model":{"canonicalModelId":"contract-model","transport":"openai_chat",
              "capabilities":["text","file"],
              "capabilityControls":{"file_input":{"state":"\(state)","wireFamily":"openai_chat.file"}}}
          }}},
          "capabilityRuntime":{
            "schemaVersion":\(RequestPreferenceResolver.runtimeSchemaVersion),
            "revision":"sha256:media-outbound","generatedAt":"2026-10-19T02:00:00Z",
            "recipes":{},"controlDefinitions":{},"sourceIndex":{}
          }
        }
        """, metadataETag: "media-outbound-\(outbound)")
    }

    private func runVideo(_ id: String) throws {
        let fixture = try Self.fixture()
        let c = try #require(fixture.videoPlaceholderCases.first { $0.id == id })
        let routeName = try #require(c.routes.ios)
        let route = try #require(Self.iosRoute(routeName))
        let profile = route.profile
        #expect(profile.videoPlaceholderText == c.placeholder)

        let videos = (0..<c.videos).map(Self.video)
        let plan = AttachmentDelivery.plan(
            userText: "watch this", attachments: videos, transport: profile, model: nil
        )
        let lines = plan.injectedText.components(separatedBy: "\n\n")
        #expect(lines.first == "watch this")
        #expect(lines.filter { $0 == c.placeholder }.count == c.expectLines)
        #expect(lines.count == 1 + c.expectLines)
        for video in videos {
            #expect(!plan.injectedText.contains(video.fileName))
            #expect(!plan.injectedText.contains("VklERU8tQllURVM="))
        }
        #expect(plan.native.isEmpty)
    }

    private func runFile(_ id: String) async throws {
        let fixture = try Self.fixture()
        let c = try #require(fixture.nativeFileCases.first { $0.id == id })
        #expect(c.connection == "official")
        #expect(c.extractedText)
        try await Self.loadFileInputMetadata(c.fileInputOutbound)
        let profile = AttachmentTransportProfile.forTesting(
            provider: .openAI, wrapper: .xmlV1,
            supportsNativeFiles: c.routeNativeFiles, nativeFiles: .always
        )
        let provider = TestFactories.makeProvider(id: UUID(), kind: .openAI)
        let evidenceModel = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(
            Self.model(), providerKind: .openAI
        )
        let identity = CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: evidenceModel, partitionID: "u1",
            hasExplicitValue: true, metadataETag: "media-outbound-\(c.fileInputOutbound)"
        )
        let file = Self.docx()
        let original = TestFactories.makeMessage(
            text: "summarize", providerID: provider.id, providerKind: .openAI,
            modelID: evidenceModel.id, attachments: [file]
        )
        let request = URLRequest(url: try #require(URL(string: "https://api.openai.com/v1/chat/completions")))
        // The production finalChatIntent reads the file_input projection and produces the outbound copy.
        let intent = CapabilityEvidenceRequestContext.$current.withValue(identity) {
            CapabilityEvidenceProductionAdapter.finalChatIntent(
                messages: [original], request: request, effectiveTransport: "openai_chat",
                model: evidenceModel, requestedReasoningMode: .automatic, webSearchEnabled: false
            )
        }
        let outboundFile = try #require(intent.outboundMessages.first?.attachments?.first)
        // The native raw data is kept only when the projection allows it; otherwise it is stripped, the extracted text stays, and the original conversation attachment is unchanged.
        #expect((outboundFile.originalBase64Data != nil) == (c.fileInputOutbound == "native_part"))
        #expect(outboundFile.base64Data == file.base64Data)
        #expect(original.attachments?.first?.originalBase64Data == file.originalBase64Data)

        let plan = AttachmentDelivery.plan(
            userText: "summarize", attachments: [outboundFile], transport: profile, model: Self.model()
        )
        #expect(!plan.native.isEmpty == c.expect.nativeFilePart)
        #expect(plan.injectedText.contains(Self.extractedMarker) == c.expect.textInjected)
        #expect(plan.injectedText.contains("omitted") == c.expect.placeholderLine)
        #expect(plan.skipped.isEmpty)
    }

    @Test func MEDIA_OUTBOUND_caseIdsLocked() throws {
        let fixture = try Self.fixture()
        #expect(Set(fixture.videoPlaceholderCases.map(\.id)) == [
            "video_deepseek_chat", "video_minimax_chat", "video_two_videos_two_lines",
        ])
        #expect(Set(fixture.nativeFileCases.map(\.id)) == [
            "file_native_when_projection_native", "file_text_when_projection_placeholder", "file_text_when_route_text_only",
        ])
    }

    @Test func MEDIA_OUTBOUND_video_deepseek_chat() throws { try runVideo("video_deepseek_chat") }
    @Test func MEDIA_OUTBOUND_video_minimax_chat() throws { try runVideo("video_minimax_chat") }
    @Test func MEDIA_OUTBOUND_video_two_videos_two_lines() throws { try runVideo("video_two_videos_two_lines") }
    /// A route that sends images natively but takes no video (Anthropic Messages) has no image placeholder; videos still get the generic placeholder, are never silently dropped, and never enter native blocks.
    @Test func nativeImageRouteVideoUsesGenericPlaceholder() throws {
        let generic = "[Video omitted: this route sends text only]"
        let profile = AttachmentTransport.anthropicMessages.profile
        #expect(profile.imagePlaceholderText == nil)
        #expect(profile.videoPlaceholderText == generic)
        #expect(generic == textOnlyRouteImagePlaceholder.replacingOccurrences(of: "Image", with: "Video"))

        let videos = (0..<2).map(Self.video)
        let plan = AttachmentDelivery.plan(
            userText: "watch this", attachments: videos, transport: profile, model: Self.model()
        )
        #expect(plan.injectedText.components(separatedBy: "\n\n") == ["watch this", generic, generic])
        #expect(plan.native.isEmpty)
        for video in videos {
            #expect(!plan.injectedText.contains(video.fileName))
        }

        // A route that can take video natively (Gemini generateContent) writes no placeholder.
        let gemini = AttachmentDelivery.plan(
            userText: "watch this", attachments: videos,
            transport: AttachmentTransport.geminiGenerateContent.profile, model: nil
        )
        #expect(AttachmentTransport.geminiGenerateContent.profile.videoPlaceholderText == nil)
        #expect(gemini.injectedText == "watch this")
    }

    @Test func MEDIA_OUTBOUND_file_native_when_projection_native() async throws { try await runFile("file_native_when_projection_native") }
    @Test func MEDIA_OUTBOUND_file_text_when_projection_placeholder() async throws { try await runFile("file_text_when_projection_placeholder") }
    @Test func MEDIA_OUTBOUND_file_text_when_route_text_only() async throws { try await runFile("file_text_when_route_text_only") }
}
