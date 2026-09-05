import Foundation
import PDFKit

enum PdfTextExtractor {
    /// - Throws: `ExtractionError(.encryptedPdf)` / `ExtractionError(.scannedPdf)` / `ExtractionError(.corruptedFile)`
    static func extract(data: Data) throws -> String {
        guard let document = PDFDocument(data: data) else {
            throw ExtractionError(code: .corruptedFile)
        }

        if document.isLocked || document.isEncrypted {
            throw ExtractionError(code: .encryptedPdf)
        }

        var parts: [String] = []
        for pageIdx in 0..<document.pageCount {
            guard let page = document.page(at: pageIdx) else { continue }
            let pageText = page.string ?? ""
            let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }

        if parts.isEmpty {
            throw ExtractionError(code: .scannedPdf)
        }

        return parts.joined(separator: "\n\n")
    }
}
