import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Memory and failure boundaries of importing several attachments at once.
@Suite("Attachment import · slots before reads, damaged files degrade")
struct AttachmentImportBoundaryTests {
    private func attachment(_ name: String) -> Oriveo.Attachment {
        Oriveo.Attachment(id: UUID(), kind: .file, fileName: name, mimeType: "text/plain", base64Data: "", thumbnailBase64: nil)
    }

    @Test("Stops once the slots are full: the remaining files are not read (rather than read and dropped)")
    func stopsReadingOnceSlotsAreFull() async {
        var read: [Int] = []
        let batch = await AttachmentImportLimiter.importSequentially(Array(0..<10), availableSlots: 3) { index in
            read.append(index)
            return attachment("f\(index)")
        }
        #expect(read == [0, 1, 2], "With 10 files and 3 slots only the first 3 should be read, but \(read) were")
        #expect(batch.accepted.map(\.fileName) == ["f0", "f1", "f2"], "Accepted in selection order")
        #expect(batch.skippedOverLimit == 7)
    }

    @Test("A file that fails to import takes no slot; with no slots nothing is read")
    func failuresDoNotConsumeSlots() async {
        var read: [Int] = []
        let batch = await AttachmentImportLimiter.importSequentially(Array(0..<6), availableSlots: 2) { index in
            read.append(index)
            return index.isMultiple(of: 2) ? nil : attachment("f\(index)")
        }
        #expect(read == [0, 1, 2, 3])
        #expect(batch.accepted.map(\.fileName) == ["f1", "f3"])
        #expect(batch.skippedOverLimit == 2)

        var touched = 0
        let none = await AttachmentImportLimiter.importSequentially(Array(0..<4), availableSlots: 0) { _ -> Oriveo.Attachment? in
            touched += 1
            return nil
        }
        #expect(touched == 0)
        #expect(none.skippedOverLimit == 4)
    }

    /// Goes through the production entry point `ChatAttachmentPicker.processFileURL` (what the file picker calls
    /// for each selected file).
    @Test("A damaged PDF / Office / EPUB degrades to one extraction failure: no crash, not counted as imported",
          arguments: ["broken.pdf", "broken.docx", "broken.xlsx", "broken.pptx", "broken.epub"])
    @MainActor
    func corruptedDocumentsFailGracefully(fileName: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(fileName)
        // The first few bytes look right and the rest is garbage: neither a valid PDF nor a valid zip.
        var bytes = Data(fileName.hasSuffix(".pdf") ? "%PDF-1.7\n".utf8 : "PK\u{03}\u{04}".utf8)
        bytes.append(Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }))
        try bytes.write(to: url)

        let result = await ChatAttachmentPicker.processFileURL(url, importContext: .init(provider: nil))
        switch result {
        case let .extractionFailed(reason, name):
            #expect(name == fileName)
            #expect(reason != .unsupportedFormat, "The format is supported, so the reason should point at the file itself: \(reason.rawValue)")
        case let .imported(attachment):
            // A PDF / Office file may be handed to a model with native file support together with its error code;
            // what it must not be is an empty text that counts as a successful extraction.
            #expect(attachment.extractionErrorCode != nil, "A damaged file must not count as a successful extraction")
        case .oversized, .unsupported:
            Issue.record("The damaged \(fileName) was classified as \(result), so the user never sees why the file could not be processed")
        }
    }

    private func temporaryFile(named name: String, data: Data) throws -> (url: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return (url, { try? FileManager.default.removeItem(at: directory) })
    }

    /// Production entry point → failure reason → production message function. The message has to name the file
    /// and say "may be corrupted" instead of the generic sentence.
    @Test("A damaged PDF shows the may-be-corrupted message with the file name")
    @MainActor
    func corruptedPdfShowsCorruptedMessage() async throws {
        var bytes = Data("%PDF-1.7\n".utf8)
        bytes.append(Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }))
        let file = try temporaryFile(named: "report.pdf", data: bytes)
        defer { file.cleanup() }
        guard case let .extractionFailed(reason, name) = await ChatAttachmentPicker.processFileURL(
            file.url, importContext: .init(provider: nil)
        ) else {
            Issue.record("A damaged PDF should end in an extraction failure")
            return
        }
        #expect(reason == .corruptedFile)
        #expect(reason.importFailureMessageKey == "file_extraction_error_corrupted")
        let message = reason.importFailureMessage(fileName: name, maxInputFileBytes: FileExtractionLimits.default.maxInputFileBytes)
        #expect(message.contains("report.pdf"))
        #expect(message == String(format: L10n.tr("file_extraction_error_corrupted", table: .chat), "report.pdf"))
        #expect(message != String(format: L10n.tr("file_extraction_error_generic", table: .chat), "report.pdf"))
        #expect(!message.contains("file_extraction_error"), "No translation found for the message key: \(message)")
    }

    @Test("A password-protected PDF shows the password-protected message with the file name")
    @MainActor
    func encryptedPdfShowsEncryptedMessage() async throws {
        // Build a PDF that really carries a user password with the system PDF context.
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, CGRect(x: 0, y: 0, width: 300, height: 200), [
            kCGPDFContextUserPassword as String: "secret",
            kCGPDFContextOwnerPassword as String: "owner",
        ])
        UIGraphicsBeginPDFPage()
        ("confidential text" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        UIGraphicsEndPDFContext()
        let file = try temporaryFile(named: "contract.pdf", data: data as Data)
        defer { file.cleanup() }
        guard case let .extractionFailed(reason, name) = await ChatAttachmentPicker.processFileURL(
            file.url, importContext: .init(provider: nil)
        ) else {
            Issue.record("An encrypted PDF should end in an extraction failure")
            return
        }
        #expect(reason == .encryptedPdf)
        let message = reason.importFailureMessage(fileName: name, maxInputFileBytes: FileExtractionLimits.default.maxInputFileBytes)
        #expect(message.contains("contract.pdf"))
        #expect(message == String(format: L10n.tr("file_extraction_error_encrypted_pdf", table: .chat), "contract.pdf"))
        #expect(!message.contains("file_extraction_error"), "No translation found for the message key: \(message)")
    }

    /// A password-protected OOXML file is an OLE compound document container, not a zip: production entry
    /// point → failure reason → production message function.
    @Test("A password-protected docx shows the password-protected message, not the generic or corrupted one")
    @MainActor
    func passwordProtectedDocxShowsPasswordMessage() async throws {
        let bytes = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(repeating: 0, count: 4_096)
        let file = try temporaryFile(named: "plan.docx", data: bytes)
        defer { file.cleanup() }
        guard case let .extractionFailed(reason, name) = await ChatAttachmentPicker.processFileURL(
            file.url, importContext: .init(provider: nil)
        ) else {
            Issue.record("A password-protected docx should end in an extraction failure")
            return
        }
        #expect(reason == .passwordProtectedOffice)
        let message = reason.importFailureMessage(fileName: name, maxInputFileBytes: FileExtractionLimits.default.maxInputFileBytes)
        #expect(message == String(format: L10n.tr("file_extraction_error_encrypted_pdf", table: .chat), "plan.docx"))
        #expect(message.contains("plan.docx"))
        #expect(!message.contains("PDF"), "This message is also used for Office documents and must not single out PDF: \(message)")
    }

    @Test("File too large: the limit in the message is the extractor's effective maxInputFileBytes, not a fixed 50 MB")
    @MainActor
    func tooLargeMessageShowsEffectiveLimit() async throws {
        let limits = FileExtractionLimits(
            maxLines: 500, maxBytes: 204_800, totalCap: 204_800,
            maxInputFileBytes: 2 * 1024 * 1024, maxFiles: 3
        )
        let file = try temporaryFile(named: "big.txt", data: Data(repeating: 0x61, count: limits.maxInputFileBytes + 1))
        defer { file.cleanup() }
        guard case let .extractionFailed(reason, name) = await ChatAttachmentPicker.processFileURL(
            file.url, importContext: .init(provider: nil), extractionLimits: limits
        ) else {
            Issue.record("A file over the extractor limit should end in an extraction failure")
            return
        }
        #expect(reason == .fileTooLarge)
        let message = reason.importFailureMessage(fileName: name, maxInputFileBytes: limits.maxInputFileBytes)
        #expect(message.contains("big.txt"))
        #expect(message == String(format: L10n.tr("file_extraction_error_too_large", table: .chat), "big.txt", 2))
        #expect(message.contains("2"), "\(message)")
        #expect(!message.contains("50"), "\(message)")
        #expect(!message.contains("%"), "A placeholder was not replaced: \(message)")
    }

    @Test("File too large: the limit is rounded down to whole megabytes and is never below 1")
    func tooLargeLimitRoundsDownButNeverBelowOne() {
        let megabyte = 1024 * 1024
        let format = L10n.tr("file_extraction_error_too_large", table: .chat)
        let cases: [(bytes: Int, shown: Int)] = [
            (50 * megabyte, 50), (20 * megabyte, 20), (megabyte * 5 / 2, 2), (megabyte - 1, 1), (10, 1),
        ]
        for (bytes, shown) in cases {
            let message = ExtractionErrorCode.fileTooLarge.importFailureMessage(fileName: "a.pdf", maxInputFileBytes: bytes)
            #expect(message == String(format: format, "a.pdf", shown), "\(bytes) bytes: \(message)")
            #expect(message.contains("\(shown)"), "\(bytes) bytes: \(message)")
            #expect(!message.contains("%"), "A placeholder was not replaced: \(message)")
        }
    }

    @Test("Every failure reason maps to its message; all six messages exist in 16 languages with all their placeholders")
    func importFailureCopyIsComplete() throws {
        let expected: [ExtractionErrorCode: String] = [
            .scannedPdf: "file_extraction_error_scanned_pdf",
            .encryptedPdf: "file_extraction_error_encrypted_pdf",
            .passwordProtectedOffice: "file_extraction_error_encrypted_pdf",
            .corruptedFile: "file_extraction_error_corrupted",
            .unsupportedFormat: "file_extraction_error_unsupported",
            .fileTooLarge: "file_extraction_error_too_large",
            .extractionTimeout: "file_extraction_error_generic",
            .extractionError: "file_extraction_error_generic",
        ]
        for (code, key) in expected {
            #expect(code.importFailureMessageKey == key, "\(code.rawValue)")
        }
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Chat.xcstrings")
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        for key in Set(expected.values) {
            let entry = try #require(strings[key] as? [String: Any], "The Chat table is missing \(key)")
            #expect(entry["extractionState"] as? String == "manual")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(localizations.count == 16, "\(key) has only \(localizations.count) languages")
            for (language, value) in localizations {
                let text = ((value as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
                if key == "file_extraction_error_too_large" {
                    // File name plus the limit in whole megabytes; the unit stays in each language's string.
                    #expect(text.components(separatedBy: "%1$@").count == 2, "\(key) [\(language)] should contain exactly one %1$@: \(text)")
                    #expect(text.components(separatedBy: "%2$lld").count == 2, "\(key) [\(language)] should contain exactly one %2$lld: \(text)")
                    #expect(text.components(separatedBy: "%").count == 3, "\(key) [\(language)] should have no other placeholder: \(text)")
                    #expect(!text.contains("50"), "\(key) [\(language)] must not hard-code the limit: \(text)")
                } else {
                    #expect(text.components(separatedBy: "%@").count == 2, "\(key) [\(language)] should contain exactly one %@: \(text)")
                    #expect(text.components(separatedBy: "%").count == 2, "\(key) [\(language)] should have no other placeholder: \(text)")
                }
            }
        }
    }

    @Test("Per-file size limit: a 30 MB hard cap, and a lower custom limit wins")
    func effectiveSizeLimit() {
        #expect(ChatAttachmentImportPolicy.maxAttachmentBytes == 30 * 1024 * 1024)
        #expect(ChatAttachmentImportPolicy.effectiveMaxBytes(customLimit: 25 * 1024 * 1024) == 25 * 1024 * 1024)
        #expect(ChatAttachmentImportPolicy.effectiveMaxBytes(customLimit: 100 * 1024 * 1024) == 30 * 1024 * 1024)
    }
}
