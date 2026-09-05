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
        XCTAssertTrue(s.contains("<TRUNCATED>showing first 500 of 700 lines"))
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

    func testWrapperVersionResolve() {
        XCTAssertEqual(AttachmentWrapperVersion.resolve(provider: .deepseek), .markdownV1)
        XCTAssertEqual(AttachmentWrapperVersion.resolve(provider: .qwen), .markdownV1)
        XCTAssertEqual(AttachmentWrapperVersion.resolve(provider: .anthropic), .xmlV1)
        XCTAssertEqual(AttachmentWrapperVersion.resolve(provider: .openAI), .xmlV1)
        XCTAssertEqual(AttachmentWrapperVersion.resolve(provider: .groq), .xmlV1)
    }
}
