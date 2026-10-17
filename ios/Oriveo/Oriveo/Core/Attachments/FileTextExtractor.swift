import Foundation

// MARK: - Output model

nonisolated struct ExtractedText: Equatable, Sendable {
    let content: String              // plain text after truncation
    let totalLines: Int              // original total line count
    let truncated: Bool
    let truncationReason: TruncationReason?
    let sizeBytes: Int               // original file size in bytes (used for <FILE_SIZE>)
    /// PDF where no page has a text layer and the body came from OCR (attachment extraction spec section 12); the attachment still records `scanned_pdf`.
    var scanned: Bool = false

    nonisolated enum TruncationReason: String, Equatable, Sendable {
        case lines
        case bytes
    }
}

nonisolated enum ExtractionErrorCode: String, Equatable, Sendable {
    case encryptedPdf            = "encrypted_pdf"
    case scannedPdf              = "scanned_pdf"
    case passwordProtectedOffice = "password_protected_office"
    case corruptedFile           = "corrupted_file"
    case unsupportedFormat       = "unsupported_format"
    case fileTooLarge            = "file_too_large"
    case extractionTimeout       = "extraction_timeout"
    case extractionError         = "extraction_error"
    /// Legacy formats (doc / xls / ppt / iWork): used only for a local hint at the entry point, never extracted and never shown to the model (attachment extraction spec sections 1, 2).
    case legacyFormat            = "legacy_format"
}

extension ExtractionErrorCode {
    /// Localization key of the import-failure message (Chat table, with one filename placeholder; "file too large" also takes an integer megabyte limit).
    /// Classification and the 16-language copy match the Android `ChatAttachmentCoordinator` mapping entry by entry: a password-protected PDF and an Office
    /// document share the "password protected" message (the key name keeps encrypted_pdf); timeouts and unclassified failures use the generic one.
    var importFailureMessageKey: String {
        switch self {
        case .scannedPdf: return "file_extraction_error_scanned_pdf"
        case .encryptedPdf, .passwordProtectedOffice: return "file_extraction_error_encrypted_pdf"
        case .corruptedFile: return "file_extraction_error_corrupted"
        case .unsupportedFormat: return "file_extraction_error_unsupported"
        case .fileTooLarge: return "file_extraction_error_too_large"
        case .extractionTimeout, .extractionError: return "file_extraction_error_generic"
        case .legacyFormat: return "file_extraction_error_legacy_format"
        }
    }

    /// Import-failure message shown to the user.
    /// - Parameter maxInputFileBytes: the input limit actually in effect for this extraction (a model override may lower it),
    ///   used only by "file too large"; rounded down to whole megabytes, shown as at least 1.
    func importFailureMessage(fileName: String, maxInputFileBytes: Int) -> String {
        let format = L10n.tr(importFailureMessageKey, table: .chat)
        guard self == .fileTooLarge else { return String(format: format, fileName) }
        return String(format: format, fileName, max(1, maxInputFileBytes / (1024 * 1024)))
    }
}

// MARK: - Usable body (attachment extraction spec sections 12, 13)

nonisolated extension Attachment {
    /// An error code does not rule out a body: no error code, or `scanned_pdf` - a fully scanned file recognized by OCR carries a body and still records this code,
    /// so that routes with native capability still send the original as before.
    var extractionErrorAllowsText: Bool {
        extractionErrorCode == nil || extractionErrorCode == ExtractionErrorCode.scannedPdf.rawValue
    }

    /// Usable body: body non-empty and error code empty or `scanned_pdf`. Injection, text quota counting and the text fallback decision all share this one predicate.
    var hasUsableExtractedText: Bool {
        extractionErrorAllowsText && base64Data?.isEmpty == false
    }
}

/// Source of the file extraction entry point
enum ExtractionSource: String {
    case filePicker = "file"
    case dragDrop = "drag_drop"
    case paste = "paste"
}

nonisolated struct ExtractionError: Error, Equatable, Sendable {
    let code: ExtractionErrorCode
    let underlying: String?          // dev-facing error description, not shown to the user

    init(code: ExtractionErrorCode, underlying: String? = nil) {
        self.code = code
        self.underlying = underlying
    }
}

// MARK: - Truncation constants (Spec section 2.2, after D16 revision)

/// Default FileExtractionLimits (client defaults).
/// In use, merged with the `model.attachmentExtraction` override via `FileExtractionLimits.resolve(model:)` (D14).
nonisolated struct FileExtractionLimits: Equatable, Sendable {
    let maxLines: Int
    let maxBytes: Int
    let totalCap: Int
    let maxInputFileBytes: Int
    let maxFiles: Int               // D17 hard cap on number of files

    // maxBytes as a static property for external access (compatible with old code)
    static var maxBytes: Int { `default`.maxBytes }

    static let `default` = FileExtractionLimits(
        maxLines: 500,
        maxBytes: 204_800,             // 200KB UTF-8 per file (as of 2026Q2 mainstream model context >= 200K; DeepSeek 128K can be tightened by an admin override)
        totalCap: 204_800,             // D16 revision -> 200KB total (worst case for Chinese is about 66K tokens, leaving DeepSeek 128K 62K of headroom for chat history + output)
        maxInputFileBytes: 50 * 1024 * 1024, // 50MB hard input limit
        maxFiles: 3                    // D17 hard cap on number of files (Lost in the Middle)
    )

    /// Merge the model.attachmentExtraction override and return the effective limits
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

// MARK: - UI language (attachment extraction spec section 1)

/// Used only for the encoding-detection tiebreak (spec section 4) and the OCR language (section 13); every other UI language is treated as `en`.
nonisolated enum ExtractionUILanguage: String, Sendable, Hashable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja
    case ko
    case ru
    case en

    init(code: String) {
        self = Self(rawValue: code) ?? .en
    }

    init(_ language: AppLanguage) {
        switch language {
        case .chineseSimplified: self = .zhHans
        case .chineseTraditional: self = .zhHant
        case .japanese: self = .ja
        case .korean: self = .ko
        case .russian: self = .ru
        default: self = .en
        }
    }
}

// MARK: - Type classification (attachment extraction spec section 2, single source of truth)

/// Result of type classification. rawValue matches the group names in the fixture `supported-types.v1.json` and golden `classification[].kind`.
nonisolated enum AttachmentFileKind: String, CaseIterable, Sendable {
    case legacy, pdf, epub, html, rtf, docx, xlsx, pptx, odt, ods, odp, text, unsupported
}

/// The single type list shared by entry-point checks (picker filtering, drag and drop, paste) and extractors.
nonisolated enum AttachmentTypeClassifier {
    struct Entry: Sendable {
        let kind: AttachmentFileKind
        let extensions: [String]
        let mimes: [String]
    }

    /// Order and content match the fixture `supported-types.v1.json` (the contract test compares entry by entry).
    static let entries: [Entry] = [
        Entry(kind: .legacy,
              extensions: ["doc", "xls", "ppt", "pages", "numbers", "key"],
              mimes: ["application/msword", "application/vnd.ms-excel", "application/vnd.ms-powerpoint",
                      "application/vnd.apple.pages", "application/vnd.apple.numbers", "application/vnd.apple.keynote"]),
        Entry(kind: .pdf, extensions: ["pdf"], mimes: ["application/pdf"]),
        Entry(kind: .epub, extensions: ["epub"], mimes: ["application/epub+zip"]),
        Entry(kind: .html, extensions: ["html", "htm", "xhtml"], mimes: ["text/html", "application/xhtml+xml"]),
        Entry(kind: .rtf, extensions: ["rtf"], mimes: ["application/rtf", "text/rtf"]),
        Entry(kind: .docx, extensions: ["docx"],
              mimes: ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"]),
        Entry(kind: .xlsx, extensions: ["xlsx"],
              mimes: ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"]),
        Entry(kind: .pptx, extensions: ["pptx"],
              mimes: ["application/vnd.openxmlformats-officedocument.presentationml.presentation"]),
        Entry(kind: .odt, extensions: ["odt"], mimes: ["application/vnd.oasis.opendocument.text"]),
        Entry(kind: .ods, extensions: ["ods"], mimes: ["application/vnd.oasis.opendocument.spreadsheet"]),
        Entry(kind: .odp, extensions: ["odp"], mimes: ["application/vnd.oasis.opendocument.presentation"]),
        Entry(kind: .text,
              extensions: [
                  "txt", "text", "md", "markdown", "mdx", "rst", "adoc", "asciidoc", "org", "tex", "bib", "srt", "vtt",
                  "json", "jsonl", "ndjson", "geojson", "ipynb", "csv", "tsv", "xml", "svg", "yaml", "yml", "toml", "ini",
                  "cfg", "conf", "properties", "env", "log", "diff", "patch", "gitignore", "editorconfig",
                  "py", "pyi", "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte", "astro",
                  "go", "rs", "java", "kt", "kts", "scala", "groovy", "gradle", "swift", "m", "mm",
                  "c", "h", "cpp", "hpp", "cc", "cs", "fs", "vb", "rb", "php", "pl", "pm", "lua", "dart", "r", "jl",
                  "hs", "ml", "ex", "exs", "erl", "clj", "zig", "nim",
                  "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "sql", "graphql", "proto",
                  "css", "scss", "sass", "less", "tf", "hcl", "cmake",
              ],
              mimes: [
                  "text/plain", "text/markdown", "text/csv", "text/tab-separated-values", "text/xml", "text/css",
                  "text/javascript", "text/x-yaml", "text/x-toml", "text/x-ini", "text/x-python", "text/x-go",
                  "application/json", "application/xml", "application/x-yaml", "application/javascript",
                  "application/typescript", "application/x-sh", "image/svg+xml",
              ]),
    ]

    /// List of whole filenames to match when there is no extension (fixture `text.filenames`).
    static let textFilenames: [String] = ["dockerfile", "makefile", "license", "readme", "gitignore", "editorconfig"]

    /// Any unclassified `text/*` is treated as plain text (fixture `text.anyTextMime`).
    static let anyTextMime = true

    private static let kindByExtension: [String: AttachmentFileKind] = {
        var map: [String: AttachmentFileKind] = [:]
        for entry in entries { for ext in entry.extensions { map[ext] = entry.kind } }
        return map
    }()

    private static let kindByMime: [String: AttachmentFileKind] = {
        var map: [String: AttachmentFileKind] = [:]
        for entry in entries { for mime in entry.mimes { map[mime] = entry.kind } }
        return map
    }()

    static func entry(_ kind: AttachmentFileKind) -> Entry? {
        entries.first { $0.kind == kind }
    }

    /// Classify by extension if recognized; look at the mime only when the extension is unrecognized or empty.
    static func classify(fileName: String, mimeType: String?) -> AttachmentFileKind {
        let name = fileName.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? fileName
        let dotCount = name.reduce(0) { $0 + ($1 == "." ? 1 : 0) }
        if dotCount == 0 || (name.hasPrefix(".") && dotCount == 1) {
            // Filename without an extension (Dockerfile, .gitignore): compare against filenames first, then the text extension list.
            let bare = (name.hasPrefix(".") ? String(name.dropFirst()) : name).lowercased()
            if textFilenames.contains(bare) || entry(.text)?.extensions.contains(bare) == true {
                return .text
            }
        } else if let dot = name.lastIndex(of: ".") {
            let ext = String(name[name.index(after: dot)...]).lowercased()
            if let kind = kindByExtension[ext] { return kind }
        }
        return classify(mimeType: mimeType)
    }

    static func classify(mimeType: String?) -> AttachmentFileKind {
        let mime = normalizedMime(mimeType)
        guard !mime.isEmpty else { return .unsupported }
        if let kind = kindByMime[mime] { return kind }
        if anyTextMime, mime.hasPrefix("text/") { return .text }
        return .unsupported
    }

    /// Strip parameters (`; charset=...`) and leading/trailing whitespace, lowercase.
    static func normalizedMime(_ mimeType: String?) -> String {
        guard let mimeType else { return "" }
        let base = mimeType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Deadline (attachment extraction spec section 14)

/// A 30-second deadline per extraction, timed with a monotonic clock; each extraction loop calls `check()` at the start of every round. The clock is injectable (for tests).
nonisolated struct ExtractionDeadline: Sendable {
    static let defaultBudgetNanoseconds: UInt64 = 30_000_000_000

    /// Monotonic clock (nanoseconds since system boot, unaffected by wall-clock adjustments).
    static func monotonicNow() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private let now: @Sendable () -> UInt64
    let expiresAtNanoseconds: UInt64

    init(
        budgetNanoseconds: UInt64 = ExtractionDeadline.defaultBudgetNanoseconds,
        now: @escaping @Sendable () -> UInt64 = { ExtractionDeadline.monotonicNow() }
    ) {
        self.now = now
        self.expiresAtNanoseconds = now() &+ budgetNanoseconds
    }

    var isExpired: Bool {
        now() >= expiresAtNanoseconds
    }

    /// Report `extraction_timeout` once expired.
    func check() throws {
        if isExpired { throw ExtractionError(code: .extractionTimeout, underlying: "extraction deadline exceeded") }
    }
}

// MARK: - Unified entry point

nonisolated enum FileTextExtractor {
    /// Synchronous entry point, runs on the main thread, no OCR: a fully scanned file reports `scanned_pdf`.
    /// Imported attachments go through `extractInBackground`.
    @MainActor
    static func extract(
        data: Data,
        fileName: String,
        mimeType: String,
        limits: FileExtractionLimits = .default,
        source: ExtractionSource = .filePicker,
        uiLanguage: ExtractionUILanguage = ExtractionUILanguage(AppLocalization.currentLanguage)
    ) throws -> ExtractedText {
        try extractInner(
            data: data,
            fileName: fileName,
            mimeType: mimeType,
            limits: limits,
            uiLanguage: uiLanguage,
            ocr: nil
        )
    }

    /// Entry point for imported attachments: extraction runs on a GCD background queue, and PDF pages without a text layer go through Vision OCR (attachment extraction spec section 13).
    /// Vision's `RecognizeTextRequest` has only an async API, and OCR waits synchronously for its result on this background thread, so the whole extraction must not run on the main thread;
    /// a GCD thread rather than the cooperative thread pool is used so the wait does not occupy Swift concurrency threads.
    @MainActor
    static func extractInBackground(
        data: Data,
        fileName: String,
        mimeType: String,
        limits: FileExtractionLimits = .default,
        source: ExtractionSource = .filePicker,
        uiLanguage: ExtractionUILanguage = ExtractionUILanguage(AppLocalization.currentLanguage)
    ) async throws -> ExtractedText {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try extractInner(
                        data: data,
                        fileName: fileName,
                        mimeType: mimeType,
                        limits: limits,
                        uiLanguage: uiLanguage,
                        ocr: PdfOcr.visionHook(uiLanguage: uiLanguage)
                    )
                })
            }
        }
    }

    /// The actual extraction logic
    private static func extractInner(
        data: Data,
        fileName: String,
        mimeType: String,
        limits: FileExtractionLimits,
        uiLanguage: ExtractionUILanguage,
        ocr: PdfOcrHook?
    ) throws -> ExtractedText {

        // 1. Hard file size limit
        guard data.count <= limits.maxInputFileBytes else {
            throw ExtractionError(code: .fileTooLarge)
        }

        // 2. Type classification (spec section 2) -> dispatch to the matching extractor
        let kind = AttachmentTypeClassifier.classify(fileName: fileName, mimeType: mimeType)
        let rawText: String
        var scanned = false

        let archiveBudget = ArchiveExtractionBudget.attachment(maxOutputBytes: limits.maxBytes)
        let deadline = ExtractionDeadline()
        do {
            switch kind {
            case .pdf:
                let pdf = try PdfTextExtractor.extract(data: data, deadline: deadline, ocr: ocr)
                rawText = pdf.text
                scanned = pdf.scanned

            case .epub:
                rawText = try EpubTextExtractor.extract(data: data, uiLanguage: uiLanguage, budget: archiveBudget, deadline: deadline)

            case .html:
                rawText = try HtmlTextExtractor.extract(data: data, uiLanguage: uiLanguage, deadline: deadline)

            case .rtf:
                rawText = try RtfTextExtractor.extract(data: data, deadline: deadline)

            case .docx, .xlsx, .pptx:
                // The extension may be unrecognized (class decided by mime); always use the classification result as the format name.
                let format = kind.rawValue
                guard !OfficeTextExtractor.isPasswordProtected(data, fileExtension: format) else {
                    throw ExtractionError(code: .passwordProtectedOffice)
                }
                guard let officeText = try OfficeTextExtractor.extractText(
                    from: data,
                    fileExtension: format,
                    budget: archiveBudget,
                    deadline: deadline
                ) else {
                    throw ExtractionError(code: .unsupportedFormat)
                }
                rawText = officeText

            case .odt, .ods, .odp:
                rawText = try OdfTextExtractor.extract(data: data, fileExtension: kind.rawValue, budget: archiveBudget, deadline: deadline)

            case .text:
                rawText = try PlainTextExtractor.extract(data: data, uiLanguage: uiLanguage)

            case .legacy, .unsupported:
                // Legacy formats are blocked at the entry point (spec section 2); reaching here is treated as unsupported.
                throw ExtractionError(code: .unsupportedFormat)
            }
        } catch let error as BoundedArchiveError {
            switch error {
            case .invalidUTF8, .doctypeDeclared:
                throw ExtractionError(code: .corruptedFile, underlying: String(describing: error))
            case .tooManyEntries, .entryTooLarge, .archiveTooLarge:
                throw ExtractionError(code: .fileTooLarge, underlying: String(describing: error))
            }
        }

        // 3. Truncation
        var result = Self.truncate(rawText: rawText, sizeBytes: data.count, limits: limits)
        result.scanned = scanned
        return result
    }

    // MARK: - Truncation

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

        // Truncate by line count
        if truncatedLines.count > limits.maxLines {
            truncatedLines = Array(truncatedLines.prefix(limits.maxLines))
            truncated = true
            reason = .lines
        }

        // Truncate by bytes (on line boundaries)
        var joined = truncatedLines.joined(separator: "\n")
        if let utf8Count = joined.data(using: .utf8)?.count,
           utf8Count > limits.maxBytes {
            // Binary search for the maximum number of lines that fit
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
            if lo == 0, let firstLine = truncatedLines.first {
                // Not even the first line fits (minified JSON, single-line log, PDF extraction result without line breaks):
                // truncating by whole lines would give empty content, so hard-cut inside the line at a UTF-8 character boundary, keeping the beginning.
                joined = Self.utf8Prefix(firstLine, maxBytes: limits.maxBytes)
            } else {
                truncatedLines = Array(truncatedLines.prefix(lo))
                // D17: logical separator fallback
                truncatedLines = Self.alignToLogicalBoundary(truncatedLines)
                joined = truncatedLines.joined(separator: "\n")
            }
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

    /// The longest prefix of at most `maxBytes` UTF-8 bytes that does not split a multibyte character.
    static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > maxBytes else { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: max(0, maxBytes))
        // If it lands on a continuation byte (10xxxxxx), step back to the first byte of this character.
        while end > utf8.startIndex, utf8[end] & 0xC0 == 0x80 {
            end = utf8.index(before: end)
        }
        return String(decoding: utf8[..<end], as: UTF8.self)
    }

    /// Look-back alignment on truncation (attachment extraction spec section 3.4): look back at most 50 lines from the last line,
    /// and cut before the first line matching `^#{1,6} ` or `^--- Page ` (excluding that line); do not align when the match is the first line of the kept part.
    static func alignToLogicalBoundary(_ lines: [String]) -> [String] {
        guard !lines.isEmpty else { return lines }
        for i in stride(from: lines.count - 1, through: max(0, lines.count - 50), by: -1) {
            if isSectionStart(lines[i]) {
                return i == 0 ? lines : Array(lines.prefix(i))
            }
        }
        return lines
    }

    /// Heading line (1-6 `#` followed by one space) or PDF page marker.
    private static func isSectionStart(_ line: String) -> Bool {
        if line.hasPrefix("--- Page ") { return true }
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return false }
        return line.dropFirst(hashes).first == " "
    }
}
