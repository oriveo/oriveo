import XCTest
import ZIPFoundation
@testable import Oriveo

final class FileTextExtractorTests: XCTestCase {

    func testTruncateNoTruncation() {
        let lines = (1...100).map { "line \($0)" }
        let raw = lines.joined(separator: "\n")
        let r = FileTextExtractor.truncate(rawText: raw, sizeBytes: raw.utf8.count)
        XCTAssertFalse(r.truncated)
        XCTAssertEqual(r.totalLines, 100)
        XCTAssertEqual(r.content, raw)
    }

    func testTruncateByLines() {
        let lines = (1...700).map { "line \($0)" }
        let raw = lines.joined(separator: "\n")
        let r = FileTextExtractor.truncate(rawText: raw, sizeBytes: raw.utf8.count)
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.truncationReason, .lines)
        XCTAssertEqual(r.totalLines, 700)
        XCTAssertEqual(r.content.components(separatedBy: "\n").count, 500)
    }

    func testTruncateByBytes() {
        let big = String(repeating: "a", count: 5000)
        let lines = (1...50).map { _ in big }
        let raw = lines.joined(separator: "\n")
        let r = FileTextExtractor.truncate(rawText: raw, sizeBytes: raw.utf8.count)
        XCTAssertTrue(r.truncated)
        XCTAssertLessThanOrEqual(r.content.utf8.count, FileExtractionLimits.default.maxBytes)
    }

    // Look-back alignment on truncation (attachment extraction spec section 3.4): after the binary search for line count, look back at most 50 lines,
    // and cut before a line matching `^#{1,6} ` or `^--- Page `; `===Sheet:` / `===Slide ` are obsolete.
    private func truncateAfterHeader(_ header: String) -> ExtractedText {
        let limits = FileExtractionLimits(maxLines: 500, maxBytes: 100, totalCap: 204_800, maxInputFileBytes: 1_000_000, maxFiles: 3)
        // The first two lines plus 7 body lines of 10 bytes fit exactly in 100 bytes (9 lines); line 10 onward is cut.
        let lines = ["intro", header] + Array(repeating: String(repeating: "a", count: 10), count: 20)
        let raw = lines.joined(separator: "\n")
        return FileTextExtractor.truncate(rawText: raw, sizeBytes: raw.utf8.count, limits: limits)
    }

    func testByteTruncationBacksOffToPageMarkerOrHeading() {
        for header in ["--- Page 2 ---", "--- Page 2 --- [no text layer]", "## Sheet: B", "# Title", "###### Deep", "### Notes"] {
            let r = truncateAfterHeader(header)
            XCTAssertTrue(r.truncated, header)
            XCTAssertEqual(r.truncationReason, .bytes, header)
            XCTAssertEqual(r.content, "intro", header)
        }
    }

    func testByteTruncationIgnoresRetiredAndNonHeadingSeparators() {
        for header in ["===Sheet: A", "===Slide 2", "####### seven", "#tag", "--- Pages"] {
            let r = truncateAfterHeader(header)
            XCTAssertTrue(r.truncated, header)
            // No look-back: keep all lines from the binary search (header lengths differ, line count 9-10).
            XCTAssertGreaterThanOrEqual(r.content.components(separatedBy: "\n").count, 9, header)
            XCTAssertTrue(r.content.hasPrefix("intro\n\(header)\n"), header)
        }
    }

    func testByteTruncationLooksBackAtMostFiftyLines() {
        let limits = FileExtractionLimits(maxLines: 500, maxBytes: 4 + 60 * 3, totalCap: 204_800, maxInputFileBytes: 1_000_000, maxFiles: 3)
        // "## H" (4 bytes) + 60 x ("\n" + "aa") is exactly 184 bytes and fits 61 lines; the look-back reaches only line 12 and never touches "## H" on line 1.
        let lines = ["## H"] + Array(repeating: "aa", count: 80)
        let raw = lines.joined(separator: "\n")
        let r = FileTextExtractor.truncate(rawText: raw, sizeBytes: raw.utf8.count, limits: limits)
        XCTAssertTrue(r.truncated)
        XCTAssertTrue(r.content.hasPrefix("## H\n"))
        XCTAssertEqual(r.content.components(separatedBy: "\n").count, 61)
    }

    // Custom limits (D14)
    /// A single line over the byte limit: hard-cut inside the line at a character boundary, keeping the beginning, never truncating to empty content.
    func testSingleOversizedLineIsCutInsideTheLine() async throws {
        let limits = FileExtractionLimits(maxLines: 500, maxBytes: 10, totalCap: 204_800, maxInputFileBytes: 1_000_000, maxFiles: 3)
        // Each CJK character is 3 bytes: 10 bytes fit 3 characters, and the 4th must not be cut in half.
        let r = FileTextExtractor.truncate(rawText: "\u{4E00}\u{4E8C}\u{4E09}\u{56DB}\u{4E94}\u{516D}", sizeBytes: 18, limits: limits)
        XCTAssertEqual(r.content, "\u{4E00}\u{4E8C}\u{4E09}")
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.truncationReason, .bytes)
        XCTAssertEqual(r.totalLines, 1)

        let ascii = FileTextExtractor.truncate(rawText: String(repeating: "a", count: 25), sizeBytes: 25, limits: limits)
        XCTAssertEqual(ascii.content, String(repeating: "a", count: 10))

        // The first line does not fit and more lines follow: the beginning of the first line is kept all the same.
        let multi = FileTextExtractor.truncate(rawText: String(repeating: "b", count: 25) + "\nsecond", sizeBytes: 32, limits: limits)
        XCTAssertEqual(multi.content, String(repeating: "b", count: 10))
        XCTAssertEqual(multi.totalLines, 2)

        // Production path: minified single-line JSON still has content after extract, and the block given to the model carries the truncation marker.
        let json = "{\"k\":\"" + String(repeating: "v", count: 400_000) + "\"}"
        let extracted = try await FileTextExtractor.extractInBackground(data: Data(json.utf8), fileName: "min.json", mimeType: "application/json")
        XCTAssertEqual(extracted.content.utf8.count, FileExtractionLimits.default.maxBytes)
        XCTAssertTrue(extracted.truncated)
        let block = AttachmentInjector.formatAttachment(
            index: 1, fileName: "min.json", mimeType: "application/json", sizeBytes: extracted.sizeBytes, extracted: extracted
        )
        XCTAssertTrue(block.contains("<TRUNCATED>showing first 1 of 1 lines</TRUNCATED>"))
    }


    func testCustomLimits() {
        let customLimits = FileExtractionLimits(
            maxLines: 10,
            maxBytes: 1024,
            totalCap: 10240,
            maxInputFileBytes: 1024 * 1024,
            maxFiles: 1
        )
        let lines = (1...20).map { "line \($0)" }
        let raw = lines.joined(separator: "\n")
        let r = FileTextExtractor.truncate(rawText: raw, sizeBytes: raw.utf8.count, limits: customLimits)
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.truncationReason, .lines)
        XCTAssertEqual(r.content.components(separatedBy: "\n").count, 10)
    }

    func testFileTooLargeError() async {
        let customLimits = FileExtractionLimits(
            maxLines: 500, maxBytes: 102400, totalCap: 102400,
            maxInputFileBytes: 10, maxFiles: 3
        )
        let data = Data(repeating: 0x61, count: 11) // "aaaaaaaaaaa"
        do {
            _ = try await FileTextExtractor.extractInBackground(data: data, fileName: "test.txt", mimeType: "text/plain", limits: customLimits)
            XCTFail("expected fileTooLarge")
        } catch {
            guard let e = error as? ExtractionError else { return XCTFail("wrong error type") }
            XCTAssertEqual(e.code, .fileTooLarge)
        }
    }

    func testInvalidUTF8InsideODFIsReportedAsCorruption() async throws {
        guard let archive = Archive(accessMode: .create) else {
            return XCTFail("unable to create archive")
        }
        let invalid = Data([0xFF, 0xFE, 0x00])
        try archive.addEntry(
            with: "content.xml",
            type: .file,
            uncompressedSize: UInt32(invalid.count),
            provider: { position, size in invalid[position..<(position + size)] }
        )
        let zip = try XCTUnwrap(archive.data)

        do {
            _ = try await FileTextExtractor.extractInBackground(
                data: zip,
                fileName: "damaged.odt",
                mimeType: "application/vnd.oasis.opendocument.text"
            )
            XCTFail("expected corruptedFile")
        } catch {
            guard let extractionError = error as? ExtractionError else {
                return XCTFail("wrong error type")
            }
            XCTAssertEqual(extractionError.code, .corruptedFile)
        }
    }

    // MARK: - Password-protected OOXML (OLE compound document container)

    private static let oleHeader = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])

    private func officeExtractionCode(data: Data, fileName: String, mimeType: String) async -> ExtractionErrorCode? {
        do {
            _ = try await FileTextExtractor.extractInBackground(data: data, fileName: fileName, mimeType: mimeType)
            return nil
        } catch {
            return (error as? ExtractionError)?.code ?? .extractionError
        }
    }

    func testPasswordProtectedOOXMLIsReportedAsPasswordProtected() async {
        let data = Self.oleHeader + Data(repeating: 0, count: 2_048)
        let cases = [
            ("a.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
            ("a.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
            ("a.PPTX", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        ]
        for (name, mime) in cases {
            let code = await officeExtractionCode(data: data, fileName: name, mimeType: mime)
            XCTAssertEqual(code, .passwordProtectedOffice, name)
        }
    }

    func testOLEHeaderShorterThanSignatureIsNotPasswordProtected() async {
        let mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        for count in [0, 4, 7] {
            let code = await officeExtractionCode(data: Self.oleHeader.prefix(count), fileName: "short.docx", mimeType: mime)
            XCTAssertNotNil(code, "\(count) bytes are not a valid docx")
            XCTAssertNotEqual(code, .passwordProtectedOffice, "\(count) bytes are too few to compare the header")
        }
    }

    // Legacy .doc/.xls/.ppt files are OLE containers themselves and must not be reported as password-protected.
    func testLegacyOLEOfficeFormatsAreNotPasswordProtected() async {
        let data = Self.oleHeader + Data(repeating: 0, count: 2_048)
        let cases = [
            ("old.doc", "application/msword"),
            ("old.xls", "application/vnd.ms-excel"),
            ("old.ppt", "application/vnd.ms-powerpoint"),
            // A legacy format mislabelled with an OOXML MIME type is not compared either
            ("old.doc", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        ]
        for (name, mime) in cases {
            let code = await officeExtractionCode(data: data, fileName: name, mimeType: mime)
            XCTAssertEqual(code, .unsupportedFormat, "\(name) \(mime)")
        }
    }

    func testRegularZipDocxStillExtracts() async throws {
        guard let archive = Archive(accessMode: .create) else {
            return XCTFail("unable to create archive")
        }
        let xml = Data("<w:document><w:body><w:p><w:r><w:t>hello docx</w:t></w:r></w:p></w:body></w:document>".utf8)
        try archive.addEntry(
            with: "word/document.xml",
            type: .file,
            uncompressedSize: UInt32(xml.count),
            provider: { position, size in xml[position..<(position + size)] }
        )
        let zip = try XCTUnwrap(archive.data)
        let extracted = try await FileTextExtractor.extractInBackground(
            data: zip,
            fileName: "plain.docx",
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        )
        XCTAssertTrue(extracted.content.contains("hello docx"), extracted.content)
    }

    // MARK: - Deadline (attachment extraction spec section 14)

    /// Injected monotonic clock: does not expire within 30 seconds, expires at (inclusive) the deadline, `check()` reports extraction_timeout.
    func testExtractionDeadlineExpiresAfterThirtySecondsOfInjectedClock() {
        final class ManualClock: @unchecked Sendable {
            var nanoseconds: UInt64 = 5_000
            // Avoids the synthesized isolated deinit and its iOS 18 back-deploy shim (swift#85663), which crashes the test host on release.
            nonisolated deinit {}
        }
        let clock = ManualClock()
        let deadline = ExtractionDeadline(now: { clock.nanoseconds })
        XCTAssertEqual(deadline.expiresAtNanoseconds, 5_000 + 30_000_000_000)
        XCTAssertFalse(deadline.isExpired)
        XCTAssertNoThrow(try deadline.check())

        clock.nanoseconds += 29_999_999_999
        XCTAssertFalse(deadline.isExpired)

        clock.nanoseconds += 1
        XCTAssertTrue(deadline.isExpired)
        XCTAssertThrowsError(try deadline.check()) { error in
            XCTAssertEqual((error as? ExtractionError)?.code, .extractionTimeout)
        }
    }

    /// By default uses the real monotonic clock: a freshly created deadline does not expire, and the expiry point is "now + 30 seconds".
    func testExtractionDeadlineDefaultsToMonotonicClock() {
        let before = ExtractionDeadline.monotonicNow()
        let deadline = ExtractionDeadline()
        let after = ExtractionDeadline.monotonicNow()
        XCTAssertFalse(deadline.isExpired)
        XCTAssertGreaterThanOrEqual(deadline.expiresAtNanoseconds, before + ExtractionDeadline.defaultBudgetNanoseconds)
        XCTAssertLessThanOrEqual(deadline.expiresAtNanoseconds, after + ExtractionDeadline.defaultBudgetNanoseconds)
    }
}
