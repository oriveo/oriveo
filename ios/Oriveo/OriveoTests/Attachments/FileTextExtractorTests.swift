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
    /// A file with a single line over the byte limit: cut inside the line on a character boundary, keeping the beginning instead of truncating to nothing.
    func testSingleOversizedLineIsCutInsideTheLine() throws {
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
        let extracted = try FileTextExtractor.extract(data: Data(json.utf8), fileName: "min.json", mimeType: "application/json")
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

    func testFileTooLargeError() {
        let customLimits = FileExtractionLimits(
            maxLines: 500, maxBytes: 102400, totalCap: 102400,
            maxInputFileBytes: 10, maxFiles: 3
        )
        let data = Data(repeating: 0x61, count: 11) // "aaaaaaaaaaa"
        XCTAssertThrowsError(try FileTextExtractor.extract(data: data, fileName: "test.txt", mimeType: "text/plain", limits: customLimits)) { err in
            guard let e = err as? ExtractionError else { return XCTFail("wrong error type") }
            XCTAssertEqual(e.code, .fileTooLarge)
        }
    }

    func testInvalidUTF8InsideODFIsReportedAsCorruption() throws {
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

        XCTAssertThrowsError(
            try FileTextExtractor.extract(
                data: zip,
                fileName: "damaged.odt",
                mimeType: "application/vnd.oasis.opendocument.text"
            )
        ) { error in
            guard let extractionError = error as? ExtractionError else {
                return XCTFail("wrong error type")
            }
            XCTAssertEqual(extractionError.code, .corruptedFile)
        }
    }

    // MARK: - Password-protected OOXML (OLE compound document container)

    private static let oleHeader = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])

    private func officeExtractionCode(data: Data, fileName: String, mimeType: String) -> ExtractionErrorCode? {
        do {
            _ = try FileTextExtractor.extract(data: data, fileName: fileName, mimeType: mimeType)
            return nil
        } catch {
            return (error as? ExtractionError)?.code ?? .extractionError
        }
    }

    func testPasswordProtectedOOXMLIsReportedAsPasswordProtected() {
        let data = Self.oleHeader + Data(repeating: 0, count: 2_048)
        let cases = [
            ("a.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
            ("a.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
            ("a.PPTX", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        ]
        for (name, mime) in cases {
            XCTAssertEqual(officeExtractionCode(data: data, fileName: name, mimeType: mime), .passwordProtectedOffice, name)
        }
    }

    func testOLEHeaderShorterThanSignatureIsNotPasswordProtected() {
        let mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        for count in [0, 4, 7] {
            let code = officeExtractionCode(data: Self.oleHeader.prefix(count), fileName: "short.docx", mimeType: mime)
            XCTAssertNotNil(code, "\(count) bytes are not a valid docx")
            XCTAssertNotEqual(code, .passwordProtectedOffice, "\(count) bytes are too few to compare the header")
        }
    }

    // Legacy .doc/.xls/.ppt files are OLE containers themselves and must not be reported as password-protected.
    func testLegacyOLEOfficeFormatsAreNotPasswordProtected() {
        let data = Self.oleHeader + Data(repeating: 0, count: 2_048)
        let cases = [
            ("old.doc", "application/msword"),
            ("old.xls", "application/vnd.ms-excel"),
            ("old.ppt", "application/vnd.ms-powerpoint"),
            // A legacy format mislabelled with an OOXML MIME type is not compared either
            ("old.doc", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        ]
        for (name, mime) in cases {
            XCTAssertEqual(officeExtractionCode(data: data, fileName: name, mimeType: mime), .unsupportedFormat, "\(name) \(mime)")
        }
    }

    func testRegularZipDocxStillExtracts() throws {
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
        let extracted = try FileTextExtractor.extract(
            data: zip,
            fileName: "plain.docx",
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        )
        XCTAssertTrue(extracted.content.contains("hello docx"), extracted.content)
    }
}
