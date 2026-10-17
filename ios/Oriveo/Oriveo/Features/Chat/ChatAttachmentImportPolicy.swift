import Foundation
import UniformTypeIdentifiers

nonisolated enum ChatAttachmentImportPolicy {
    nonisolated static let maxAttachmentBytes = 30 * 1024 * 1024

    // The list of text-extractable types lives only in `AttachmentTypeClassifier` (attachment extraction spec section 2); this file only handles video routing.
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "mpeg", "mpg", "avi", "flv", "webm", "wmv", "3gp",
    ]

    private static let videoMimeTypes: Set<String> = [
        "video/mp4",
        "video/mpeg",
        "video/quicktime",
        "video/x-msvideo",
        "video/x-flv",
        "video/webm",
        "video/x-ms-wmv",
        "video/3gpp",
    ]

    static let supportedFileContentTypes: [UTType] = {
        var seen = Set<String>()
        var result: [UTType] = []

        func append(_ type: UTType?) {
            guard let type, seen.insert(type.identifier).inserted else { return }
            result.append(type)
        }

        append(.content)
        append(.data)

        append(.pdf)
        append(.text)
        append(.plainText)
        append(.utf8PlainText)
        append(.sourceCode)
        append(.json)
        append(.xml)
        append(.commaSeparatedText)
        append(.rtf)
        append(.movie)
        append(.mpeg4Movie)
        append(.quickTimeMovie)

        // Legacy formats are listed too: after selection the entry point shows a "save as a new format" hint, instead of silently graying them out in the picker.
        for entry in AttachmentTypeClassifier.entries {
            let conformance: UTType = entry.kind == .text ? .text : .data
            for ext in entry.extensions.sorted() {
                append(UTType(tag: ext, tagClass: .filenameExtension, conformingTo: conformance))
            }
        }
        for ext in videoExtensions.sorted() {
            append(UTType(tag: ext, tagClass: .filenameExtension, conformingTo: .movie))
        }

        return result
    }()

    /// Importable files: types recognized as extractable per attachment extraction spec section 2, or video. Legacy formats do not count (the entry point shows a separate hint).
    static func isSupportedFile(fileName: String, detectedMimeType: String?) -> Bool {
        if isVideo(fileName: fileName, detectedMimeType: detectedMimeType) { return true }
        switch AttachmentTypeClassifier.classify(fileName: fileName, mimeType: detectedMimeType) {
        case .legacy, .unsupported: return false
        default: return true
        }
    }

    /// Legacy formats (doc / xls / ppt / iWork): blocked at the entry point with a hint to save as a new format.
    static func isLegacyFormat(fileName: String, detectedMimeType: String?) -> Bool {
        AttachmentTypeClassifier.classify(fileName: fileName, mimeType: detectedMimeType) == .legacy
    }

    private static func isVideo(fileName: String, detectedMimeType: String?) -> Bool {
        let ext = normalizedExtension(fileName)
        if !ext.isEmpty, AttachmentTypeClassifier.classify(fileName: fileName, mimeType: nil) == .unsupported {
            return videoExtensions.contains(ext)
        }
        return ext.isEmpty && videoMimeTypes.contains(normalizeMimeType(detectedMimeType))
    }

    /// - Parameters:
    static func isWithinSizeLimit(_ byteCount: Int, customLimit: Int? = nil) -> Bool {
        byteCount <= effectiveMaxBytes(customLimit: customLimit)
    }

    static func effectiveMaxBytes(customLimit: Int?) -> Int {
        max(0, min(customLimit ?? maxAttachmentBytes, maxAttachmentBytes))
    }

    static func resolveMimeType(fileName: String, detectedMimeType: String?) -> String {
        let ext = normalizedExtension(fileName)
        if !ext.isEmpty {
            let byExtension = fallbackMIMEType(for: ext)
            if byExtension != "application/octet-stream" { return byExtension }
        }

        let normalizedMime = normalizeMimeType(detectedMimeType)
        if ext.isEmpty, videoMimeTypes.contains(normalizedMime) { return normalizedMime }
        let kind = AttachmentTypeClassifier.classify(fileName: fileName, mimeType: normalizedMime)
        switch kind {
        case .legacy, .unsupported:
            return "application/octet-stream"
        default:
            // If the detected mime already belongs to this class, keep it; otherwise (e.g. a Dockerfile recognized by filename) use the class's canonical mime.
            if AttachmentTypeClassifier.classify(mimeType: normalizedMime) == kind { return normalizedMime }
            return AttachmentTypeClassifier.entry(kind)?.mimes.first ?? "application/octet-stream"
        }
    }

    static func fallbackMIMEType(for ext: String) -> String {
        switch ext.lowercased() {
        case "txt", "log", "ini", "env", "sh", "bash", "zsh",
             "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs",
             "java", "kt", "swift", "c", "cpp", "h", "hpp",
             "toml", "graphql", "proto", "sql":
            return "text/plain"
        case "csv":
            return "text/csv"
        case "md":
            return "text/markdown"
        case "json":
            return "application/json"
        case "xml":
            return "application/xml"
        case "html", "htm":
            return "text/html"
        case "xhtml":
            return "application/xhtml+xml"
        case "css":
            return "text/css"
        case "yaml", "yml":
            return "application/x-yaml"
        case "pdf":
            return "application/pdf"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx":
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx":
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "odt":
            return "application/vnd.oasis.opendocument.text"
        case "ods":
            return "application/vnd.oasis.opendocument.spreadsheet"
        case "odp":
            return "application/vnd.oasis.opendocument.presentation"
        case "rtf":
            return "application/rtf"
        case "epub":
            return "application/epub+zip"
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "mpeg", "mpg":
            return "video/mpeg"
        case "avi":
            return "video/x-msvideo"
        case "flv":
            return "video/x-flv"
        case "webm":
            return "video/webm"
        case "wmv":
            return "video/x-ms-wmv"
        case "3gp":
            return "video/3gpp"
        default:
            // Other plain-text extensions in the list (vue, rst, same-named extensions like Makefile, etc.) are all sent as text/plain.
            return AttachmentTypeClassifier.classify(fileName: "file." + ext.lowercased(), mimeType: nil) == .text
                ? "text/plain"
                : "application/octet-stream"
        }
    }

    private static func normalizedExtension(_ fileName: String) -> String {
        URL(fileURLWithPath: fileName).pathExtension.lowercased()
    }

    private static func normalizeMimeType(_ mimeType: String?) -> String {
        mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}
