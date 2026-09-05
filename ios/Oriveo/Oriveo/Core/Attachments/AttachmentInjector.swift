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
        .fileTooLarge:            "This file exceeds the maximum size limit. DO NOT fabricate content. Tell the user the file is too large and ask them to split or shorten it.",
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
        case "application/epub+zip": return "epub"
        case "text/html", "application/xhtml+xml": return "html"
        case "text/markdown": return "md"
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
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
            switch extracted.truncationReason {
            case .lines:
                lines.append("<TRUNCATED>showing first \(n) of \(extracted.totalLines) lines (size cap 200KB)</TRUNCATED>")
            case .bytes:
                lines.append("<TRUNCATED>showing first \(n) of \(extracted.totalLines) lines (truncated to fit 200KB cap)</TRUNCATED>")
            case .none: break
            }
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
                lines.append("- Lines: \(extracted.totalLines) (showing first \(n), size cap 200KB)")
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
        var parts: [String] = []
        if !userText.isEmpty {
            parts.append(userText)
        }

        var consumed = 0
        var skipped: [(fileName: String, reason: SkipReason)] = []
        var emittedIndex = 0

        for (fileName, mime, size, extracted, code) in fileAttachments {
            if emittedIndex >= limits.maxFiles {
                skipped.append((fileName, .tooManyFiles))
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
            let blockBytes = block.utf8.count

            if consumed + blockBytes > limits.totalCap {
                skipped.append((fileName, .totalCapExceeded))
                continue
            }
            parts.append(block)
            consumed += blockBytes
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
