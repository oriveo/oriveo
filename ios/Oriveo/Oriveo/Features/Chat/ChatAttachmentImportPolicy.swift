import Foundation
import UniformTypeIdentifiers

nonisolated enum ChatAttachmentImportPolicy {
    nonisolated static let maxAttachmentBytes = 30 * 1024 * 1024

    private static let textExtensions: Set<String> = [
        "txt", "csv", "md", "json", "xml", "html", "css",
        "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs",
        "java", "kt", "swift", "c", "cpp", "h", "hpp",
        "sh", "bash", "zsh", "yaml", "yml", "toml", "ini",
        "env", "log", "sql", "graphql", "proto",
    ]

    private static let officeExtensions: Set<String> = [
        "docx", "xlsx", "pptx", "odt", "ods", "odp", "rtf", "epub",
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "mpeg", "mpg", "avi", "flv", "webm", "wmv", "3gp",
    ]

    private static let supportedMimeTypes: Set<String> = [
        "text/plain",
        "text/csv",
        "text/markdown",
        "text/html",
        "text/css",
        "text/xml",
        "text/javascript",
        "application/json",
        "application/xml",
        "application/javascript",
        "application/typescript",
        "application/x-yaml",
        "application/x-sh",
        "application/pdf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.oasis.opendocument.text",
        "application/vnd.oasis.opendocument.spreadsheet",
        "application/vnd.oasis.opendocument.presentation",
        "application/rtf",
        "text/rtf",
        "application/epub+zip",
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

        for ext in textExtensions.sorted() {
            append(UTType(tag: ext, tagClass: .filenameExtension, conformingTo: .text))
        }
        for ext in officeExtensions.sorted() {
            append(UTType(tag: ext, tagClass: .filenameExtension, conformingTo: .data))
        }
        for ext in videoExtensions.sorted() {
            append(UTType(tag: ext, tagClass: .filenameExtension, conformingTo: .movie))
        }

        return result
    }()

    static func isSupportedFile(fileName: String, detectedMimeType: String?) -> Bool {
        let ext = normalizedExtension(fileName)
        if !ext.isEmpty {
            return ext == "pdf" || textExtensions.contains(ext) || officeExtensions.contains(ext) || videoExtensions.contains(ext)
        }

        return isSupportedMimeType(normalizeMimeType(detectedMimeType))
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
            return fallbackMIMEType(for: ext)
        }

        let normalizedMime = normalizeMimeType(detectedMimeType)
        return isSupportedMimeType(normalizedMime) ? normalizedMime : "application/octet-stream"
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
        case "html":
            return "text/html"
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
            return "application/octet-stream"
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

    private static func isSupportedMimeType(_ mimeType: String) -> Bool {
        guard !mimeType.isEmpty else { return false }
        return supportedMimeTypes.contains(mimeType)
    }
}
