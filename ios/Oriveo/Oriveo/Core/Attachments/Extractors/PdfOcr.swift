import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Recognize the text on one page bitmap (attachment extraction spec section 13): return lines in the engine's reading order; an empty array if no text was recognized.
nonisolated protocol PdfPageTextRecognizer {
    func recognizeLines(in image: CGImage) throws -> [String]
}

/// Scanned-document OCR (spec section 13): pages without a text layer are rendered to a bitmap with a 2000 px long side and handed to the recognition engine; only pages numbered 1-50 are processed
/// (counted by page number, not by "nth page without a text layer"), sharing one deadline with extraction; pages hit by the deadline, a page number over the limit, or a render or recognition error
/// get `.notProcessed` without raising an error.
nonisolated enum PdfOcr {
    static let maxPages = 50
    static let renderLongSidePixels: CGFloat = 2000

    /// For production: Vision `RecognizeTextRequest`, language chosen by the UI language.
    static func visionHook(uiLanguage: ExtractionUILanguage) -> PdfOcrHook {
        hook(recognizer: VisionPdfPageRecognizer(uiLanguage: uiLanguage))
    }

    static func hook(recognizer: any PdfPageTextRecognizer) -> PdfOcrHook {
        { document, pageIndices, deadline in
            recognize(document: document, pageIndices: pageIndices, deadline: deadline, recognizer: recognizer)
        }
    }

    static func recognize(
        document: PDFDocument,
        pageIndices: [Int],
        deadline: ExtractionDeadline,
        recognizer: any PdfPageTextRecognizer
    ) -> [Int: PdfOcrPageOutcome] {
        var outcomes: [Int: PdfOcrPageOutcome] = [:]
        for pageIndex in pageIndices {
            // pageIndex starts at 0, page number = pageIndex + 1.
            guard pageIndex < maxPages, !deadline.isExpired else {
                outcomes[pageIndex] = .notProcessed
                continue
            }
            // Each page's bitmap and intermediate recognition objects are released when that page ends, so a scan of dozens of pages does not pile up memory.
            outcomes[pageIndex] = autoreleasepool { () -> PdfOcrPageOutcome in
                // A render or recognition error writes `[not processed]`; only successful recognition with empty result writes `[no text layer]`.
                guard let page = document.page(at: pageIndex), let image = render(page) else { return .notProcessed }
                guard let lines = try? recognizer.recognizeLines(in: image) else { return .notProcessed }
                let text = lines.joined(separator: "\n")
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .text(text)
            }
        }
        return outcomes
    }

    /// Render the page, in display orientation, to a white-background bitmap whose long side is `longSide` pixels.
    static func render(_ page: PDFPage, longSide: CGFloat = renderLongSidePixels) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let quarterTurns = (((page.rotation % 360) + 360) % 360) / 90
        let size = quarterTurns % 2 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = longSide / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // PDFPage drawing already includes the page rotation and the crop-box origin transform.
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}

/// Vision `RecognizeTextRequest` (iOS 18), `recognitionLevel = .accurate`.
nonisolated struct VisionPdfPageRecognizer: PdfPageTextRecognizer {
    /// nil means let Vision detect the language automatically.
    let languages: [Locale.Language]?

    init(uiLanguage: ExtractionUILanguage) {
        languages = Self.recognitionLanguages(for: uiLanguage)
    }

    /// Spec section 13: Simplified Chinese / Traditional Chinese / Japanese / Korean each paired with English; other UI languages auto-detect.
    static func recognitionLanguages(for uiLanguage: ExtractionUILanguage) -> [Locale.Language]? {
        let identifiers: [String]
        switch uiLanguage {
        case .zhHans: identifiers = ["zh-Hans", "en-US"]
        case .zhHant: identifiers = ["zh-Hant", "en-US"]
        case .ja: identifiers = ["ja-JP", "en-US"]
        case .ko: identifiers = ["ko-KR", "en-US"]
        case .ru, .en: return nil
        }
        return identifiers.map { Locale.Language(identifier: $0) }
    }

    func recognizeLines(in image: CGImage) throws -> [String] {
        // Only an async API exists: wait for it to finish on the current (non-main) thread. Waiting on the main thread would freeze the UI, so refuse it outright.
        guard !Thread.isMainThread else {
            assertionFailure("Vision OCR must not block the main thread")
            throw VisionRecognitionError.calledOnMainThread
        }
        let pending = PendingRecognition()
        let input = UncheckedImage(image: image)
        let languages = languages
        Task.detached(priority: .userInitiated) {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            if let languages {
                request.recognitionLanguages = languages
                request.automaticallyDetectsLanguage = false
            } else {
                request.automaticallyDetectsLanguage = true
            }
            do {
                let observations = try await request.perform(on: input.image)
                pending.finish(.success(observations.compactMap { $0.topCandidates(1).first?.string }))
            } catch {
                pending.finish(.failure(error))
            }
        }
        return try pending.wait()
    }
}

nonisolated enum VisionRecognitionError: Error {
    case calledOnMainThread
}

/// CGImage is read-only and is passed across into the recognition task.
private nonisolated struct UncheckedImage: @unchecked Sendable {
    let image: CGImage
}

/// Synchronously wait for the result of one async recognition.
private nonisolated final class PendingRecognition: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<[String], Error> = .success([])

    func finish(_ result: Result<[String], Error>) {
        self.result = result
        semaphore.signal()
    }

    func wait() throws -> [String] {
        semaphore.wait()
        return try result.get()
    }
}
