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
}
