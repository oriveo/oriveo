import Foundation


struct ExtractedText: Equatable {
    let content: String
    let totalLines: Int
    let truncated: Bool
    let truncationReason: TruncationReason?
    let sizeBytes: Int

    enum TruncationReason: String, Equatable {
        case lines
        case bytes
    }
}

enum ExtractionErrorCode: String, Equatable {
    case encryptedPdf            = "encrypted_pdf"
    case scannedPdf              = "scanned_pdf"
    case passwordProtectedOffice = "password_protected_office"
    case corruptedFile           = "corrupted_file"
    case unsupportedFormat       = "unsupported_format"
    case fileTooLarge            = "file_too_large"
    case extractionTimeout       = "extraction_timeout"
    case extractionError         = "extraction_error"
}

enum ExtractionSource: String {
    case filePicker = "file"
    case dragDrop = "drag_drop"
    case paste = "paste"
}

struct ExtractionError: Error, Equatable {
    let code: ExtractionErrorCode
    let underlying: String?

    init(code: ExtractionErrorCode, underlying: String? = nil) {
        self.code = code
        self.underlying = underlying
    }
}


nonisolated struct FileExtractionLimits: Equatable, Sendable {
    let maxLines: Int
    let maxBytes: Int
    let totalCap: Int
    let maxInputFileBytes: Int
    let maxFiles: Int

    static var maxBytes: Int { `default`.maxBytes }

    static let `default` = FileExtractionLimits(
        maxLines: 500,
        maxBytes: 204_800,
        totalCap: 204_800,
        maxInputFileBytes: 50 * 1024 * 1024,
        maxFiles: 3
    )

    static func resolve(model: AIModel?) -> FileExtractionLimits {
        guard let override = model?.attachmentExtraction else {
            return .default
        }
        return FileExtractionLimits(
            maxLines: override.maxLines ?? Self.default.maxLines,
            maxBytes: override.maxBytes ?? Self.default.maxBytes,
            totalCap: override.totalCap ?? Self.default.totalCap,
            maxInputFileBytes: override.maxInputFileBytes ?? Self.default.maxInputFileBytes,
            maxFiles: override.maxAttachments ?? Self.default.maxFiles
        )
    }
}


enum FileTextExtractor {
    static let supportedMimes: Set<String> = [
        "text/plain", "text/markdown", "text/csv", "text/tab-separated-values",
        "text/x-yaml", "text/x-toml", "text/x-ini",
        "application/json", "application/xml", "application/x-yaml",
        "text/html", "image/svg+xml",
        "application/pdf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.oasis.opendocument.text",
        "application/vnd.oasis.opendocument.spreadsheet",
        "application/vnd.oasis.opendocument.presentation",
        "application/rtf", "text/rtf",
        "application/epub+zip",
    ]

    static func extract(
        data: Data,
        fileName: String,
        mimeType: String,
        limits: FileExtractionLimits = .default,
        source: ExtractionSource = .filePicker
    ) throws -> ExtractedText {
        let startedAt = Date()

        do {
            let result = try extractInner(
                data: data,
                fileName: fileName,
                mimeType: mimeType,
                limits: limits
            )
            return result
        } catch let e as ExtractionError {
            throw e
        }
    }

    private static func extractInner(
        data: Data,
        fileName: String,
        mimeType: String,
        limits: FileExtractionLimits
    ) throws -> ExtractedText {

        guard data.count <= limits.maxInputFileBytes else {
            throw ExtractionError(code: .fileTooLarge)
        }

        let ext = (fileName as NSString).pathExtension.lowercased()
        let rawText: String

        let archiveBudget = ArchiveExtractionBudget.attachment(maxOutputBytes: limits.maxBytes)
        do {
            switch (mimeType.lowercased(), ext) {
            case ("application/pdf", _), (_, "pdf"):
                rawText = try PdfTextExtractor.extract(data: data)

            case ("application/epub+zip", _), (_, "epub"):
                rawText = try EpubTextExtractor.extract(data: data, budget: archiveBudget)

            case ("text/html", _), ("application/xhtml+xml", _), (_, "html"), (_, "htm"), (_, "xhtml"):
                rawText = try HtmlTextExtractor.extract(data: data)

            case ("application/rtf", _), ("text/rtf", _), (_, "rtf"):
                rawText = try RtfTextExtractor.extract(data: data)

            case ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", _),
                 ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", _),
                 ("application/vnd.openxmlformats-officedocument.presentationml.presentation", _),
                 (_, "docx"), (_, "xlsx"), (_, "pptx"):
                guard let officeText = try OfficeTextExtractor.extractText(
                    from: data,
                    fileExtension: ext,
                    budget: archiveBudget
                ) else {
                    throw ExtractionError(code: .unsupportedFormat)
                }
                rawText = officeText

            case ("application/vnd.oasis.opendocument.text", _),
                 ("application/vnd.oasis.opendocument.spreadsheet", _),
                 ("application/vnd.oasis.opendocument.presentation", _),
                 (_, "odt"), (_, "ods"), (_, "odp"):
                rawText = try OdfTextExtractor.extract(data: data, fileExtension: ext, budget: archiveBudget)

            case _ where supportedMimes.contains(mimeType.lowercased()),
                 _ where Self.textExtensions.contains(ext):
                rawText = try PlainTextExtractor.extract(data: data)

            default:
                throw ExtractionError(code: .unsupportedFormat)
            }
        } catch let error as BoundedArchiveError {
            switch error {
            case .invalidUTF8:
                throw ExtractionError(code: .corruptedFile, underlying: String(describing: error))
            case .tooManyEntries, .entryTooLarge, .archiveTooLarge:
                throw ExtractionError(code: .fileTooLarge, underlying: String(describing: error))
            }
        }

        return Self.truncate(rawText: rawText, sizeBytes: data.count, limits: limits)
    }


    static func truncate(
        rawText: String,
        sizeBytes: Int,
        limits: FileExtractionLimits = .default
    ) -> ExtractedText {
        let lines = rawText.components(separatedBy: "\n")
        let totalLines = lines.count

        var truncatedLines = lines
        var truncated = false
        var reason: ExtractedText.TruncationReason?

        if truncatedLines.count > limits.maxLines {
            truncatedLines = Array(truncatedLines.prefix(limits.maxLines))
            truncated = true
            reason = .lines
        }

        var joined = truncatedLines.joined(separator: "\n")
        if let utf8Count = joined.data(using: .utf8)?.count,
           utf8Count > limits.maxBytes {
            var lo = 0
            var hi = truncatedLines.count
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                let candidate = truncatedLines.prefix(mid).joined(separator: "\n")
                if (candidate.data(using: .utf8)?.count ?? 0) <= limits.maxBytes {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            truncatedLines = Array(truncatedLines.prefix(lo))
            truncatedLines = Self.alignToLogicalBoundary(truncatedLines)
            joined = truncatedLines.joined(separator: "\n")
            truncated = true
            reason = reason ?? .bytes
        }

        return ExtractedText(
            content: joined,
            totalLines: totalLines,
            truncated: truncated,
            truncationReason: reason,
            sizeBytes: sizeBytes
        )
    }

    private static func alignToLogicalBoundary(_ lines: [String]) -> [String] {
        let separatorPatterns = ["===Sheet:", "===Slide ", "## "]
        for i in stride(from: lines.count - 1, through: max(0, lines.count - 50), by: -1) {
            let line = lines[i]
            if separatorPatterns.contains(where: { line.hasPrefix($0) }) {
                return Array(lines.prefix(i))
            }
        }
        return lines
    }


    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonl", "ndjson",
        "csv", "tsv", "xml", "yaml", "yml", "toml", "ini",
        "cfg", "conf", "log", "env", "gitignore", "editorconfig",
        "py", "js", "jsx", "ts", "tsx", "mjs", "cjs",
        "go", "rs", "java", "kt", "kts", "swift", "m", "mm",
        "c", "h", "cpp", "hpp", "cc", "cs", "rb", "php",
        "sh", "bash", "zsh", "ps1", "bat", "cmd", "sql",
        "r", "lua", "dart", "vue", "svelte",
        "scss", "sass", "less", "css",
        "gradle", "groovy", "proto", "graphql",
    ]
}
