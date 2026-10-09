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

    /// Import -> persisted fields -> rebuild at send time, all through production functions: the rebuilt
    /// ExtractedText has no reason, and the model must still be told the file was truncated (both wrappers).
    @Test("Text file over the line cap: both wrapper formats tell the model it was truncated at send time")
    @MainActor
    func truncatedImportStillTellsTheModelAtSendTime() async throws {
        let attachment = try await importLongTextFile(lines: 600)
        #expect(attachment.extractedTruncated == true)
        #expect(attachment.extractedTotalLines == 600)

        let xml = AttachmentDelivery.plan(
            userText: "q", attachments: [attachment], transport: AttachmentTransport.anthropicMessages.profile, model: nil
        )
        #expect(xml.skipped.isEmpty)
        #expect(xml.injectedText.contains("<TRUNCATED>showing first 500 of 600 lines</TRUNCATED>"), "\(xml.injectedText.suffix(160))")

        let markdown = AttachmentDelivery.plan(
            userText: "q", attachments: [attachment], transport: AttachmentTransport.deepSeekChat.profile, model: nil
        )
        #expect(markdown.injectedText.contains("- Lines: 600 (showing first 500)"), "\(markdown.injectedText.prefix(200))")
    }

    @Test("Text file over the line cap: it is added, flagged as truncated, and produces one notice with the real line counts")
    @MainActor
    func truncatedImportProducesNotice() async throws {
        let attachment = try await importLongTextFile(lines: 600, name: "notes.txt")
        #expect(attachment.extractedTruncated == true)

        let notice = try #require(ChatAttachmentPicker.truncationNotice(for: attachment))
        let format = L10n.tr("file_extraction_truncated_notice", table: .chat)
        #expect(format != "file_extraction_truncated_notice", "The Chat table is missing this string")
        #expect(notice == String(format: format, "notes.txt", 500, 600), "\(notice)")
        #expect(notice.contains("notes.txt") && notice.contains("500") && notice.contains("600"), "\(notice)")
        #expect(!notice.contains("%"), "Placeholder was not substituted: \(notice)")

        // Files that were not truncated produce no notice; each truncated file in a batch gets its own line.
        let short = try await importLongTextFile(lines: 20, name: "short.txt")
        #expect(short.extractedTruncated == false)
        #expect(ChatAttachmentPicker.truncationNotice(for: short) == nil)
        #expect(ChatAttachmentPicker.truncationNotice(for: [short]) == nil)
        let second = try await importLongTextFile(lines: 900, name: "log.txt")
        let merged = try #require(ChatAttachmentPicker.truncationNotice(for: [attachment, short, second]))
        #expect(merged == [notice, String(format: format, "log.txt", 500, 900)].joined(separator: "\n"), "\(merged)")
    }

    @Test("Truncation notice exists in 16 languages: file name, kept lines and total lines each appear exactly once")
    func truncationNoticeCopyIsComplete() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Chat.xcstrings")
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let entry = try #require(strings["file_extraction_truncated_notice"] as? [String: Any])
        #expect(entry["extractionState"] as? String == "manual")
        let localizations = try #require(entry["localizations"] as? [String: Any])
        #expect(localizations.count == 16, "Only \(localizations.count) languages")
        for (language, value) in localizations {
            let text = ((value as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            for placeholder in ["%1$@", "%2$lld", "%3$lld"] {
                #expect(text.components(separatedBy: placeholder).count == 2, "[\(language)] should contain exactly one \(placeholder): \(text)")
            }
            #expect(text.components(separatedBy: "%").count == 4, "[\(language)] should have no other placeholder: \(text)")
        }
    }

    @Test("the text budget gate on add: files that do not fit are not added, the verdict matches send time, and files that may go native take no budget")
    @MainActor
    func addTimeTextBudgetGateMatchesSendTime() async throws {
        let first = try await importLongTextFile(lines: 400, name: "first.txt")
        let second = try await importLongTextFile(lines: 400, name: "second.txt")
        let small = try await importLongTextFile(lines: 2, name: "small.txt")
        let firstBytes = try #require(Data(base64Encoded: first.resolvedBase64Data)).count
        // The limit fits one 400-line file plus a small file, but not two of the big ones.
        var model = AIModel(
            id: "m", name: "m", capabilities: [.text, .file], reasoningModeAvailable: false,
            isAvailable: true, isDefault: true, priceTier: "premium",
            attachmentExtraction: AttachmentExtractionLimits(totalCap: firstBytes + 100)
        )

        let gate = AttachmentDelivery.admitWithinTextBudget(
            existing: [first], incoming: [second, small], provider: .openAI, model: model
        )
        #expect(gate.accepted.map(\.fileName) == ["small.txt"])
        #expect(gate.rejected.map(\.fileName) == ["second.txt"])
        // The send-time verdict on the same set of files: the rejected one does not fit there either, and the accepted one does.
        let sendAll = AttachmentDelivery.plan(
            userText: "q", attachments: [first, second, small], transport: AttachmentTransport.openAIChat.profile, model: model
        )
        #expect(sendAll.skipped.map(\.attachment.fileName) == ["second.txt"])
        let sendAccepted = AttachmentDelivery.plan(
            userText: "q", attachments: [first] + gate.accepted, transport: AttachmentTransport.openAIChat.profile, model: model
        )
        #expect(sendAccepted.skipped.isEmpty)

        // Without a model the default limit applies and all of these fit.
        let defaults = AttachmentDelivery.admitWithinTextBudget(existing: [first], incoming: [second], provider: nil, model: nil)
        #expect(defaults.rejected.isEmpty)

        // Files on the allow-list that may go as native file blocks at send time: no budget, not rejected, left to be judged by route at send time.
        model.nativeFileMimes = ["application/pdf"]
        model.pdfNativeDefault = true
        let pdf = Attachment(
            id: UUID(), kind: .file, fileName: "big.pdf", mimeType: "application/pdf",
            base64Data: first.resolvedBase64Data, extractedSizeBytes: 9_000, originalBase64Data: "JVBERi0="
        )
        let withNative = AttachmentDelivery.admitWithinTextBudget(
            existing: [pdf], incoming: [pdf, first, second], provider: .gemini, model: model
        )
        #expect(withNative.accepted.map(\.fileName) == ["big.pdf", "first.txt"])
        #expect(withNative.rejected.map(\.fileName) == ["second.txt"])

        // The notice text: the Chat table has this entry, and its placeholder is replaced by the file name.
        let format = L10n.tr("file_extraction_text_budget_exceeded", table: .chat)
        #expect(format != "file_extraction_text_budget_exceeded", "the Chat table is missing this string")
        let notice = String(format: format, "second.txt")
        #expect(notice.contains("second.txt") && !notice.contains("%"), "\(notice)")
    }

    @Test("the budget-full notice exists in all 16 languages with exactly one file name placeholder, and Arabic has direction isolates on both sides")
    func textBudgetExceededCopyIsComplete() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Chat.xcstrings")
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let entry = try #require(strings["file_extraction_text_budget_exceeded"] as? [String: Any])
        #expect(entry["extractionState"] as? String == "manual")
        let localizations = try #require(entry["localizations"] as? [String: Any])
        #expect(localizations.count == 16, "only \(localizations.count) languages")
        for (language, value) in localizations {
            let text = ((value as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            #expect(text.components(separatedBy: "%@").count == 2, "[\(language)] expected exactly one %@: \(text)")
            #expect(text.components(separatedBy: "%").count == 2, "[\(language)] unexpected extra placeholder: \(text)")
            #expect(!text.contains("{"), "[\(language)] leftover web placeholder: \(text)")
        }
        let arabic = ((localizations["ar"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
        #expect(arabic.contains("\u{2066}%@\u{2069}"))
    }

    @MainActor
    private func importLongTextFile(lines: Int, name: String = "long.txt") async throws -> Oriveo.Attachment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try Data((1...lines).map { "line \($0)" }.joined(separator: "\n").utf8).write(to: url)
        guard case let .imported(attachment) = await ChatAttachmentPicker.processFileURL(url, importContext: .init(provider: nil)) else {
            throw CocoaError(.fileReadUnknown)
        }
        return attachment
    }

    @Test("Per-file size limit: a 30 MB hard cap, and a lower custom limit wins")
    func effectiveSizeLimit() {
        #expect(ChatAttachmentImportPolicy.maxAttachmentBytes == 30 * 1024 * 1024)
        #expect(ChatAttachmentImportPolicy.effectiveMaxBytes(customLimit: 25 * 1024 * 1024) == 25 * 1024 * 1024)
        #expect(ChatAttachmentImportPolicy.effectiveMaxBytes(customLimit: 100 * 1024 * 1024) == 30 * 1024 * 1024)
    }
}
