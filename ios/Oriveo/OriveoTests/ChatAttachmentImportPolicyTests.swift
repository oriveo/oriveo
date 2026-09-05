import Foundation
import Testing
@testable import Oriveo

@Suite("ChatAttachmentImportPolicy")
struct ChatAttachmentImportPolicyTests {

    @Test("Resolves Known Text Extension")
    func resolvesKnownTextExtension() {
        let mimeType = ChatAttachmentImportPolicy.resolveMimeType(
            fileName: "sample.ts",
            detectedMimeType: "application/octet-stream"
        )

        #expect(mimeType == "text/plain")
    }

    @Test("Rejects Unknown Extension Even If Mime Looks Textual")
    func rejectsUnknownExtensionEvenIfMimeLooksTextual() {
        let supported = ChatAttachmentImportPolicy.isSupportedFile(
            fileName: "archive.custompkg",
            detectedMimeType: "text/plain"
        )

        #expect(supported == false)
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
}
