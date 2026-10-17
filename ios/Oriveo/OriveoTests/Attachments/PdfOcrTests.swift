import Foundation
import Testing
import UIKit
@testable import Oriveo

// Attachment extraction spec section 13: a fake OCR engine locks four rules: page cap, deadline, empty recognition, recognition error (real Vision runs in ExtractionGoldenContractTests).

private struct FakeRecognitionError: Error {}

/// Every page returns the same set of lines and the call count is recorded; the fake clock can advance after each recognition; the nth call (1-based) in `failingCalls` throws.
private nonisolated final class FakeRecognizer: PdfPageTextRecognizer {
    let lines: [String]
    let failingCalls: Set<Int>
    let afterEachCall: @Sendable () -> Void
    private(set) var calls = 0
    private(set) var imageSizes: [CGSize] = []

    init(lines: [String], failingCalls: Set<Int> = [], afterEachCall: @escaping @Sendable () -> Void = {}) {
        self.lines = lines
        self.failingCalls = failingCalls
        self.afterEachCall = afterEachCall
    }

    func recognizeLines(in image: CGImage) throws -> [String] {
        calls += 1
        imageSizes.append(CGSize(width: image.width, height: image.height))
        afterEachCall()
        if failingCalls.contains(calls) { throw FakeRecognitionError() }
        return lines
    }
}

/// A monotonic clock that can be advanced manually.
private nonisolated final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 1_000

    func now() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return nanoseconds
    }

    func advance(by delta: UInt64) {
        lock.lock(); nanoseconds += delta; lock.unlock()
    }
}

struct PdfOcrTests {
    /// Generate a PDF: one page per element; nil is a blank page without a text layer.
    private static func makePdf(_ pages: [String?], size: CGSize = CGSize(width: 200, height: 100)) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        return renderer.pdfData { context in
            for text in pages {
                context.beginPage()
                if let text {
                    (text as NSString).draw(at: CGPoint(x: 10, y: 10), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                }
            }
        }
    }

    @Test("scan over 50 pages: only the first 50 pages are recognized, the rest are written as [not processed], still returned as a scan")
    func pageCapIsFifty() throws {
        let data = Self.makePdf(Array(repeating: nil, count: 52))
        let recognizer = FakeRecognizer(lines: ["scan"])
        let pdf = try PdfTextExtractor.extract(data: data, ocr: PdfOcr.hook(recognizer: recognizer))
        #expect(recognizer.calls == 50)
        #expect(pdf.scanned)
        let markers = pdf.text.components(separatedBy: "\n").filter { $0.hasPrefix("--- Page ") }
        let expected = (1...50).map { "--- Page \($0) (OCR) ---" }
            + ["--- Page 51 --- [not processed]", "--- Page 52 --- [not processed]"]
        #expect(markers == expected)
    }

    @Test("the 50-page cap counts by page number: when page 1 has a text layer, pages 2-50 without one are recognized and page 51 onward is written as [not processed]")
    func pageCapCountsPageNumbersNotScannedOrdinals() throws {
        let data = Self.makePdf(["Typed page"] + Array(repeating: nil, count: 51))
        let recognizer = FakeRecognizer(lines: ["scan"])
        let pdf = try PdfTextExtractor.extract(data: data, ocr: PdfOcr.hook(recognizer: recognizer))
        #expect(recognizer.calls == 49)
        #expect(!pdf.scanned)
        let markers = pdf.text.components(separatedBy: "\n").filter { $0.hasPrefix("--- Page ") }
        let expected = ["--- Page 1 ---"] + (2...50).map { "--- Page \($0) (OCR) ---" }
            + ["--- Page 51 --- [not processed]", "--- Page 52 --- [not processed]"]
        #expect(markers == expected)
    }

    @Test("a page with a recognition error is written as [not processed] while successful pages are normal; if all pages error and there is no body, report scanned_pdf")
    func recognitionFailureWritesNotProcessed() throws {
        let data = Self.makePdf([nil, nil, "Typed page"])
        let recognizer = FakeRecognizer(lines: ["second"], failingCalls: [1])
        let pdf = try PdfTextExtractor.extract(data: data, ocr: PdfOcr.hook(recognizer: recognizer))
        #expect(recognizer.calls == 2)
        #expect(!pdf.scanned)
        #expect(pdf.text == "--- Page 1 --- [not processed]\n\n--- Page 2 (OCR) ---\nsecond\n\n--- Page 3 ---\nTyped page")

        let allFail = FakeRecognizer(lines: ["never"], failingCalls: [1, 2])
        do {
            let scan = try PdfTextExtractor.extract(data: Self.makePdf([nil, nil]), ocr: PdfOcr.hook(recognizer: allFail))
            Issue.record("expected scanned_pdf, but extracted \(scan.text.count) characters")
        } catch let error as ExtractionError {
            #expect(error.code == .scannedPdf)
        }
        #expect(allFail.calls == 2)
    }

    @Test("deadline hits mid-OCR: recognized pages are returned as usual, remaining pages are written as [not processed], no timeout is reported")
    func deadlineMarksRemainingPagesNotProcessed() throws {
        let data = Self.makePdf([nil, "Typed page", nil, nil])
        let clock = ManualClock()
        let deadline = ExtractionDeadline(budgetNanoseconds: 1_000) { clock.now() }
        let recognizer = FakeRecognizer(lines: ["first", "second"]) { clock.advance(by: 1_000) }
        let pdf = try PdfTextExtractor.extract(data: data, deadline: deadline, ocr: PdfOcr.hook(recognizer: recognizer))
        #expect(recognizer.calls == 1)
        #expect(!pdf.scanned)
        #expect(pdf.text.hasPrefix("--- Page 1 (OCR) ---\nfirst\nsecond\n\n--- Page 2 ---\nTyped page"))
        #expect(pdf.text.hasSuffix("--- Page 3 --- [not processed]\n\n--- Page 4 --- [not processed]"))
    }

    @Test("empty recognition result: that page is written as [no text layer]; a fully scanned file with all pages empty reports scanned_pdf")
    func emptyRecognitionWritesNoTextLayer() throws {
        let mixed = Self.makePdf(["Typed page", nil])
        let blank = FakeRecognizer(lines: ["  ", ""])
        let pdf = try PdfTextExtractor.extract(data: mixed, ocr: PdfOcr.hook(recognizer: blank))
        #expect(blank.calls == 1)
        #expect(!pdf.scanned)
        #expect(pdf.text.hasSuffix("\n\n--- Page 2 --- [no text layer]"))
        #expect(pdf.text.hasPrefix("--- Page 1 ---\nTyped page"))

        do {
            let scan = try PdfTextExtractor.extract(data: Self.makePdf([nil, nil]), ocr: PdfOcr.hook(recognizer: FakeRecognizer(lines: [])))
            Issue.record("expected scanned_pdf, but extracted \(scan.text.count) characters")
        } catch let error as ExtractionError {
            #expect(error.code == .scannedPdf)
        }
    }

    @Test("the page is rendered to a bitmap with a 2000 px long side and handed to the engine")
    func rendersLongSideTwoThousandPixels() throws {
        let data = Self.makePdf([nil], size: CGSize(width: 300, height: 600))
        let recognizer = FakeRecognizer(lines: ["x"])
        _ = try PdfTextExtractor.extract(data: data, ocr: PdfOcr.hook(recognizer: recognizer))
        #expect(recognizer.imageSizes == [CGSize(width: 1000, height: 2000)])
    }

    @Test("OCR language follows the UI language: Chinese / Japanese / Korean paired with English, others auto-detect")
    func recognitionLanguagesFollowUiLanguage() {
        func ids(_ language: ExtractionUILanguage) -> [String]? {
            VisionPdfPageRecognizer.recognitionLanguages(for: language)?.map { $0.maximalIdentifier }
        }
        #expect(VisionPdfPageRecognizer.recognitionLanguages(for: .zhHans) == [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")])
        #expect(VisionPdfPageRecognizer.recognitionLanguages(for: .zhHant) == [Locale.Language(identifier: "zh-Hant"), Locale.Language(identifier: "en-US")])
        #expect(VisionPdfPageRecognizer.recognitionLanguages(for: .ja) == [Locale.Language(identifier: "ja-JP"), Locale.Language(identifier: "en-US")])
        #expect(VisionPdfPageRecognizer.recognitionLanguages(for: .ko) == [Locale.Language(identifier: "ko-KR"), Locale.Language(identifier: "en-US")])
        #expect(ids(.en) == nil)
        #expect(ids(.ru) == nil)
    }
}
