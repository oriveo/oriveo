import Foundation

// Extract text from Office files (docx/xlsx/pptx): shared by chat attachments and skill knowledge reference files; output follows attachment extraction spec sections 5-7.
nonisolated enum OfficeTextExtractor {

    static let supportedExtensions: Set<String> = ["docx", "xlsx", "pptx"]

    static func isOfficeFile(extension ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
    }

    private static let oleCompoundFileSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    /// A password-protected docx/xlsx/pptx is not a zip but an OLE compound document container; opening it as a
    /// zip only yields "file is damaged". The header is compared for OOXML extensions only: legacy
    /// .doc/.xls/.ppt files are OLE containers themselves and must not be taken for encrypted ones.
    static func isPasswordProtected(_ data: Data, fileExtension ext: String) -> Bool {
        guard supportedExtensions.contains(ext.lowercased()) else { return false }
        return data.prefix(oleCompoundFileSignature.count).elementsEqual(oleCompoundFileSignature)
    }

    /// Returning nil means an unsupported format; throwing `ExtractionError` means a parse failure (spec section 16: encryption is decided before opening the zip).
    static func extractText(
        from data: Data,
        fileExtension ext: String,
        budget: ArchiveExtractionBudget = .attachment(maxOutputBytes: FileExtractionLimits.maxBytes),
        deadline: ExtractionDeadline = ExtractionDeadline()
    ) throws -> String? {
        let normalized = ext.lowercased()
        guard supportedExtensions.contains(normalized) else { return nil }
        guard !isPasswordProtected(data, fileExtension: normalized) else {
            throw ExtractionError(code: .passwordProtectedOffice)
        }
        let package = try OfficePackage(data: data, budget: budget, deadline: deadline)
        switch normalized {
        case "docx": return try DocxTextExtractor.extract(package)
        case "xlsx": return try XlsxTextExtractor.extract(package)
        case "pptx": return try PptxTextExtractor.extract(package)
        default:     return nil
        }
    }
}
