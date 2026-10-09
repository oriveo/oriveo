import XCTest
@testable import Oriveo

final class AttachmentInjectorTests: XCTestCase {

    func testFormatAttachmentXMLNoTruncation() {
        let extracted = ExtractedText(
            content: "hello\nworld",
            totalLines: 2,
            truncated: false,
            truncationReason: nil,
            sizeBytes: 11
        )
        let s = AttachmentInjector.formatAttachment(
            wrapper: .xmlV1,
            index: 1,
            fileName: "a.txt",
            mimeType: "text/plain",
            sizeBytes: 11,
            extracted: extracted
        )
        XCTAssertTrue(s.contains("<FILE_INDEX>1</FILE_INDEX>"))
        XCTAssertTrue(s.contains("<FILE_NAME>a.txt</FILE_NAME>"))
        XCTAssertTrue(s.contains("<FILE_LINES>2</FILE_LINES>"))
        XCTAssertTrue(s.contains("<FILE_SIZE_KB>1</FILE_SIZE_KB>"))
        XCTAssertTrue(s.contains("hello\nworld"))
        XCTAssertFalse(s.contains("<TRUNCATED>"))
    }

    func testFormatAttachmentXMLTruncated() {
        let extracted = ExtractedText(
            content: (1...500).map { "L\($0)" }.joined(separator: "\n"),
            totalLines: 700,
            truncated: true,
            truncationReason: .lines,
            sizeBytes: 50000
        )
        let s = AttachmentInjector.formatAttachment(
            wrapper: .xmlV1,
            index: 2,
            fileName: "big.md",
            mimeType: "text/markdown",
            sizeBytes: 50000,
            extracted: extracted
        )
        // Even with a reason the cap number is no longer written: the marker is identical to the one without a reason.
        XCTAssertTrue(s.contains("<TRUNCATED>showing first 500 of 700 lines</TRUNCATED>"))
        XCTAssertFalse(s.contains("200KB"))
        for reason in [ExtractedText.TruncationReason.lines, .bytes] {
            let withReason = ExtractedText(
                content: extracted.content, totalLines: 700, truncated: true, truncationReason: reason, sizeBytes: 50000
            )
            let markdown = AttachmentInjector.formatAttachment(
                wrapper: .markdownV1, index: 1, fileName: "big.md", mimeType: "text/markdown",
                sizeBytes: 50000, extracted: withReason
            )
            XCTAssertTrue(markdown.contains("- Lines: 700 (showing first 500)\n"), "\(reason)")
            XCTAssertFalse(markdown.contains("200KB"), "\(reason)")
            let xml = AttachmentInjector.formatAttachment(
                wrapper: .xmlV1, index: 1, fileName: "big.md", mimeType: "text/markdown",
                sizeBytes: 50000, extracted: withReason
            )
            XCTAssertTrue(xml.contains("<TRUNCATED>showing first 500 of 700 lines</TRUNCATED>"), "\(reason)")
        }
    }

    func testFormatAttachmentXMLError() {
        let s = AttachmentInjector.formatAttachment(
            wrapper: .xmlV1,
            index: 1,
            fileName: "p.pdf",
            mimeType: "application/pdf",
            sizeBytes: 12345,
            extracted: nil,
            errorCode: .scannedPdf
        )
        XCTAssertTrue(s.contains("[ERROR: extraction failed - scanned_pdf]"))
        XCTAssertTrue(s.contains("[INSTRUCTION:"))
        XCTAssertTrue(s.contains("DO NOT fabricate"))
    }

    func testFormatAttachmentMarkdown() {
        let extracted = ExtractedText(
            content: "line1\nline2",
            totalLines: 2,
            truncated: false,
            truncationReason: nil,
            sizeBytes: 11
        )
        let s = AttachmentInjector.formatAttachment(
            wrapper: .markdownV1,
            index: 1,
            fileName: "doc.txt",
            mimeType: "text/plain",
            sizeBytes: 11,
            extracted: extracted
        )
        XCTAssertTrue(s.contains("## Attachment 1: doc.txt"))
        XCTAssertTrue(s.contains("- Type: txt"))
        XCTAssertTrue(s.contains("```"))
        XCTAssertTrue(s.contains("line1\nline2"))
    }

    func testInjectAllD17TooManyFiles() {
        let small = ExtractedText(content: "x", totalLines: 1, truncated: false, truncationReason: nil, sizeBytes: 1)
        let result = AttachmentInjector.injectAll(
            intoUserText: "prompt",
            fileAttachments: [
                ("a.txt", "text/plain", 1, small, nil),
                ("b.txt", "text/plain", 1, small, nil),
                ("c.txt", "text/plain", 1, small, nil),
                ("d.txt", "text/plain", 1, small, nil),
            ]
        )
        XCTAssertTrue(result.text.contains("a.txt"))
        XCTAssertTrue(result.text.contains("b.txt"))
        XCTAssertTrue(result.text.contains("c.txt"))
        XCTAssertFalse(result.text.contains("d.txt"))
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.skipped[0].fileName, "d.txt")
        XCTAssertEqual(result.skipped[0].reason, .tooManyFiles)
    }

    func testInjectAllD16TotalCapExceeded() {
        let text150k = String(repeating: "y", count: 150_000)
        let text100k = String(repeating: "z", count: 100_000)
        let extracted150 = ExtractedText(content: text150k, totalLines: 1, truncated: false, truncationReason: nil, sizeBytes: 150_000)
        let extracted100 = ExtractedText(content: text100k, totalLines: 1, truncated: false, truncationReason: nil, sizeBytes: 100_000)
        let result = AttachmentInjector.injectAll(
            intoUserText: "user prompt",
            fileAttachments: [
                ("a.txt", "text/plain", 150_000, extracted150, nil),
                ("b.txt", "text/plain", 100_000, extracted100, nil),
            ]
        )
        XCTAssertEqual(result.skipped.count, 1)
        guard result.skipped.count == 1 else { return }
        XCTAssertEqual(result.skipped[0].fileName, "b.txt")
        XCTAssertEqual(result.skipped[0].reason, .totalCapExceeded)
        XCTAssertTrue(result.text.contains("a.txt"))
        XCTAssertFalse(result.text.contains("b.txt"))
    }

    /// An ExtractedText rebuilt from a persisted attachment at send time has no reason (`BaseAPIService` hard-codes nil); the marker must still be emitted.
    func testTruncatedWithoutReasonStillEmitsMarker() {
        let content = (1...500).map { "L\($0)" }.joined(separator: "\n")
        let extracted = ExtractedText(
            content: content, totalLines: 700, truncated: true, truncationReason: nil, sizeBytes: 9_000
        )
        let xml = AttachmentInjector.formatAttachment(
            wrapper: .xmlV1, index: 1, fileName: "big.txt", mimeType: "text/plain",
            sizeBytes: 9_000, extracted: extracted
        )
        XCTAssertTrue(xml.contains("<TRUNCATED>showing first 500 of 700 lines</TRUNCATED>"), xml.suffix(200).description)

        let markdown = AttachmentInjector.formatAttachment(
            wrapper: .markdownV1, index: 1, fileName: "big.txt", mimeType: "text/plain",
            sizeBytes: 9_000, extracted: extracted
        )
        XCTAssertTrue(markdown.contains("- Lines: 700 (showing first 500)"), markdown.prefix(200).description)
    }

    /// The total budget counts body text only: two bodies summing exactly to totalCap are both injected; the wrapper does not use budget.
    func testTotalCapCountsContentBytesOnly() {
        let limits = FileExtractionLimits.default
        let half = limits.totalCap / 2
        let first = String(repeating: "a", count: half)
        let second = String(repeating: "b", count: limits.totalCap - half)
        for wrapper in [AttachmentWrapperVersion.xmlV1, .markdownV1] {
            let result = AttachmentInjector.injectAll(
                intoUserText: "prompt",
                fileAttachments: [
                    ("first.txt", "text/plain", first.utf8.count,
                     ExtractedText(content: first, totalLines: 1, truncated: false, truncationReason: nil, sizeBytes: first.utf8.count), nil),
                    ("second.txt", "text/plain", second.utf8.count,
                     ExtractedText(content: second, totalLines: 1, truncated: false, truncationReason: nil, sizeBytes: second.utf8.count), nil),
                ],
                limits: limits,
                wrapper: wrapper
            )
            XCTAssertTrue(result.skipped.isEmpty, "\(wrapper.rawValue) skipped \(result.skipped.map(\.fileName))")
            XCTAssertTrue(result.text.contains("first.txt"))
            XCTAssertTrue(result.text.contains("second.txt"))
        }

        // One byte more exceeds the cap: the budget still applies.
        let over = AttachmentInjector.injectAll(
            intoUserText: "prompt",
            fileAttachments: [
                ("first.txt", "text/plain", first.utf8.count,
                 ExtractedText(content: first, totalLines: 1, truncated: false, truncationReason: nil, sizeBytes: first.utf8.count), nil),
                ("second.txt", "text/plain", second.utf8.count + 1,
                 ExtractedText(content: second + "b", totalLines: 1, truncated: false, truncationReason: nil, sizeBytes: second.utf8.count + 1), nil),
            ],
            limits: limits
        )
        XCTAssertEqual(over.skipped.map(\.fileName), ["second.txt"])
    }

    func testFileTooLargeInstructionCoversUnpackedSize() {
        let s = AttachmentInjector.formatAttachment(
            wrapper: .xmlV1, index: 1, fileName: "big.docx", mimeType: "application/zip",
            sizeBytes: 1, extracted: nil, errorCode: .fileTooLarge
        )
        XCTAssertTrue(s.contains(
            "[INSTRUCTION: This file is past the size the local extractor will read, either as stored or once unpacked. DO NOT fabricate content. Tell the user the file is too large and ask them to split or shorten it.]"
        ))
    }

    func testFileTypeKnowsOdfRtfAndSvgWithoutAnExtension() {
        let expected = [
            "application/vnd.oasis.opendocument.text": "odt",
            "application/vnd.oasis.opendocument.spreadsheet": "ods",
            "application/vnd.oasis.opendocument.presentation": "odp",
            "application/rtf": "rtf",
            "text/rtf": "rtf",
            "image/svg+xml": "svg",
        ]
        let body = ExtractedText(content: "x", totalLines: 1, truncated: false, truncationReason: nil, sizeBytes: 1)
        for (mime, type) in expected {
            let s = AttachmentInjector.formatAttachment(
                wrapper: .xmlV1, index: 1, fileName: "untitled", mimeType: mime, sizeBytes: 1, extracted: body
            )
            XCTAssertTrue(s.contains("<FILE_TYPE>\(type)</FILE_TYPE>"), mime)
        }
    }

    func testWhitespaceOnlyUserTextIsNotPrepended() {
        let body = ExtractedText(content: "x", totalLines: 1, truncated: false, truncationReason: nil, sizeBytes: 1)
        let blank = AttachmentInjector.injectAll(
            intoUserText: " \n\t ", fileAttachments: [("a.txt", "text/plain", 1, body, nil)]
        )
        XCTAssertTrue(blank.text.hasPrefix("<ATTACHMENT_FILE>"))
        let kept = AttachmentInjector.injectAll(
            intoUserText: " hi ", fileAttachments: [("a.txt", "text/plain", 1, body, nil)]
        )
        XCTAssertTrue(kept.text.hasPrefix(" hi \n\n<ATTACHMENT_FILE>"))
    }

    func testWrapperVersionResolve() {
        XCTAssertEqual(AttachmentWrapperVersion.resolve(provider: .deepseek), .markdownV1)
        XCTAssertEqual(AttachmentWrapperVersion.resolve(provider: .qwen), .markdownV1)
        XCTAssertEqual(AttachmentWrapperVersion.resolve(provider: .anthropic), .xmlV1)
        XCTAssertEqual(AttachmentWrapperVersion.resolve(provider: .openAI), .xmlV1)
        XCTAssertEqual(AttachmentWrapperVersion.resolve(provider: .groq), .xmlV1)
    }
}
