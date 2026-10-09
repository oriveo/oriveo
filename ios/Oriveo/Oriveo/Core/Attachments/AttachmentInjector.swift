import Foundation

enum AttachmentWrapperVersion: String {
    case xmlV1 = "xml-v1"
    case markdownV1 = "markdown-v1"

    static func resolve(provider: ProviderKind) -> AttachmentWrapperVersion {
        switch provider {
        case .deepseek, .qwen, .moonshot, .zhipu, .miniMax, .siliconFlow:
            return .markdownV1
        default:
            return .xmlV1
        }
    }
}

enum AttachmentInjector {


    static let errorInstructions: [ExtractionErrorCode: String] = [
        .encryptedPdf:            "This file is encrypted and cannot be read. DO NOT fabricate or guess content. Tell the user the file is encrypted and ask them to decrypt it before uploading.",
        .scannedPdf:              "This is a scanned PDF without a text layer. The current model cannot OCR it. DO NOT fabricate content. Tell the user to switch to a vision-capable model (e.g., GPT-4o, Claude 3.5 Sonnet, Gemini 2.5 Pro) and re-upload.",
        .passwordProtectedOffice: "This Office file is password-protected and cannot be read. DO NOT fabricate content. Tell the user to remove the password and re-upload.",
        .corruptedFile:           "This file is corrupted and cannot be parsed. DO NOT fabricate content. Tell the user the file may be damaged and ask them to re-upload a valid copy.",
        .unsupportedFormat:       "This file format is not supported by the local extractor. DO NOT fabricate content. Tell the user which formats are supported (PDF / DOCX / XLSX / PPTX / EPUB / HTML / plain text / code files).",
        .fileTooLarge:            "This file is past the size the local extractor will read, either as stored or once unpacked. DO NOT fabricate content. Tell the user the file is too large and ask them to split or shorten it.",
        .extractionTimeout:       "Extraction of this file timed out (over 30 seconds). DO NOT fabricate content. Tell the user the file is too complex; ask them to simplify or split it.",
        .extractionError:         "Extraction failed due to an internal error. DO NOT fabricate content. Tell the user to try again or use a different file.",
    ]


    private static func fileTypeShort(mime: String, fileName: String) -> String {
        let lower = mime.lowercased()
        switch lower {
        case "application/pdf": return "pdf"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return "pptx"
        case "application/vnd.oasis.opendocument.text": return "odt"
        case "application/vnd.oasis.opendocument.spreadsheet": return "ods"
        case "application/vnd.oasis.opendocument.presentation": return "odp"
        case "application/epub+zip": return "epub"
        case "text/html", "application/xhtml+xml": return "html"
        case "text/markdown": return "md"
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        case "application/rtf", "text/rtf": return "rtf"
        case "image/svg+xml": return "svg"
        default:
            let ext = (fileName as NSString).pathExtension.lowercased()
            return ext.isEmpty ? "txt" : ext
        }
    }


    static func formatAttachmentXML(
        index: Int,
        fileName: String,
        mimeType: String,
        sizeBytes: Int,
        extracted: ExtractedText?,
        errorCode: ExtractionErrorCode? = nil
    ) -> String {
        let sizeKB = (sizeBytes + 1023) / 1024
        let fileType = fileTypeShort(mime: mimeType, fileName: fileName)

        var lines: [String] = []
        lines.append("<ATTACHMENT_FILE>")
        lines.append("<FILE_INDEX>\(index)</FILE_INDEX>")
        lines.append("<FILE_NAME>\(fileName)</FILE_NAME>")
        lines.append("<FILE_TYPE>\(fileType)</FILE_TYPE>")

        if let extracted = extracted {
            lines.append("<FILE_LINES>\(extracted.totalLines)</FILE_LINES>")
        }
        lines.append("<FILE_SIZE_KB>\(sizeKB)</FILE_SIZE_KB>")

        lines.append("<FILE_CONTENT>")
        if let extracted = extracted {
            lines.append(extracted.content)
        } else {
            let code = errorCode ?? .extractionError
            lines.append("[ERROR: extraction failed - \(code.rawValue)]")
            lines.append("[INSTRUCTION: \(errorInstructions[code] ?? errorInstructions[.extractionError]!)]")
        }
        lines.append("</FILE_CONTENT>")

        if let extracted = extracted, extracted.truncated {
            let n = extracted.content.components(separatedBy: "\n").count
            // The marker carries neither a size cap nor a reason: the cap varies per model, so a fixed number
            // would be wrong, and a rebuilt ExtractedText has no reason to report anyway.
            lines.append("<TRUNCATED>showing first \(n) of \(extracted.totalLines) lines</TRUNCATED>")
        }
        lines.append("</ATTACHMENT_FILE>")
        return lines.joined(separator: "\n")
    }


    static func formatAttachmentMarkdown(
        index: Int,
        fileName: String,
        mimeType: String,
        sizeBytes: Int,
        extracted: ExtractedText?,
        errorCode: ExtractionErrorCode? = nil
    ) -> String {
        let sizeKB = (sizeBytes + 1023) / 1024
        let fileType = fileTypeShort(mime: mimeType, fileName: fileName)

        var lines: [String] = []
        lines.append("---")
        lines.append("## Attachment \(index): \(fileName)")
        lines.append("- Type: \(fileType)")
        lines.append("- Size: \(sizeKB) KB")

        if let extracted = extracted {
            if extracted.truncated {
                let n = extracted.content.components(separatedBy: "\n").count
                lines.append("- Lines: \(extracted.totalLines) (showing first \(n))")
            } else {
                lines.append("- Lines: \(extracted.totalLines)")
            }
            lines.append("")
            lines.append("```")
            lines.append(extracted.content)
            lines.append("```")
        } else {
            let code = errorCode ?? .extractionError
            lines.append("- Status: **EXTRACTION FAILED** (error: \(code.rawValue))")
            lines.append("")
            lines.append("> **Instruction to model:** \(errorInstructions[code] ?? errorInstructions[.extractionError]!)")
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }


    static func formatAttachment(
        wrapper: AttachmentWrapperVersion = .xmlV1,
        index: Int,
        fileName: String,
        mimeType: String,
        sizeBytes: Int,
        extracted: ExtractedText?,
        errorCode: ExtractionErrorCode? = nil
    ) -> String {
        switch wrapper {
        case .xmlV1:
            return formatAttachmentXML(
                index: index, fileName: fileName, mimeType: mimeType,
                sizeBytes: sizeBytes, extracted: extracted, errorCode: errorCode
            )
        case .markdownV1:
            return formatAttachmentMarkdown(
                index: index, fileName: fileName, mimeType: mimeType,
                sizeBytes: sizeBytes, extracted: extracted, errorCode: errorCode
            )
        }
    }


    static func injectAll(
        intoUserText userText: String,
        fileAttachments: [(fileName: String, mimeType: String, sizeBytes: Int, extracted: ExtractedText?, errorCode: ExtractionErrorCode?)],
        limits: FileExtractionLimits = .default,
        wrapper: AttachmentWrapperVersion = .xmlV1
    ) -> (text: String, skipped: [(fileName: String, reason: SkipReason)]) {
        let result = injectAllIndexed(
            intoUserText: userText,
            fileAttachments: fileAttachments,
            limits: limits,
            wrapper: wrapper
        )
        return (result.text, result.skipped.map { (fileAttachments[$0.index].fileName, $0.reason) })
    }

    /// Same logic as `injectAll`, but skipped files are identified by index so files with the same name
    /// can still be matched back to their attachments.
    static func injectAllIndexed(
        intoUserText userText: String,
        fileAttachments: [(fileName: String, mimeType: String, sizeBytes: Int, extracted: ExtractedText?, errorCode: ExtractionErrorCode?)],
        limits: FileExtractionLimits = .default,
        wrapper: AttachmentWrapperVersion = .xmlV1
    ) -> (text: String, skipped: [(index: Int, reason: SkipReason)]) {
        var parts: [String] = []
        // Whitespace-only text is not placed in front of the attachment blocks; with no files to inject
        // the text is returned unchanged.
        if fileAttachments.isEmpty || !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(userText)
        }

        var consumed = 0
        var skipped: [(index: Int, reason: SkipReason)] = []
        var emittedIndex = 0

        for (sourceIndex, (fileName, mime, size, extracted, code)) in fileAttachments.enumerated() {
            if emittedIndex >= limits.maxFiles {
                skipped.append((sourceIndex, .tooManyFiles))
                continue
            }
            let block = formatAttachment(
                wrapper: wrapper,
                index: emittedIndex + 1,
                fileName: fileName,
                mimeType: mime,
                sizeBytes: size,
                extracted: extracted,
                errorCode: code
            )
            // The total cap counts body text only. The per-file cap applied at extraction time measures the
            // body, so adding the wrapper and truncation marker here would skip a file that was cut to exactly the cap.
            let contentBytes = extracted?.content.utf8.count ?? 0

            if consumed + contentBytes > limits.totalCap {
                skipped.append((sourceIndex, .totalCapExceeded))
                continue
            }
            parts.append(block)
            consumed += contentBytes
            emittedIndex += 1
        }

        return (parts.joined(separator: "\n\n"), skipped)
    }

    enum SkipReason {
        case tooManyFiles       // D17
        case totalCapExceeded   // D16
    }


    static let systemPromptGuidance = """
    When the user attaches files (see <ATTACHMENT_FILE> blocks or "## Attachment N:" sections in the message), refer to them by file name in your response. If a file's content is an [ERROR: ...] block, do not fabricate the content - explain the error to the user and follow the embedded instruction.
    """
}
