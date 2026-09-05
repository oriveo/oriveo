package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.ProviderKind


enum class AttachmentWrapperVersion(val raw: String) {
    XmlV1("xml-v1"),
    MarkdownV1("markdown-v1");

    companion object {
        fun resolve(provider: ProviderKind): AttachmentWrapperVersion = when (provider) {
            ProviderKind.DeepSeek, ProviderKind.Qwen, ProviderKind.Moonshot,
            ProviderKind.Zhipu, ProviderKind.MiniMax, ProviderKind.SiliconFlow -> MarkdownV1
            else -> XmlV1
        }
    }
}


object AttachmentInjector {

    data class AttachmentPayload(
        val fileName: String,
        val mimeType: String,
        val sizeBytes: Int,
        val extracted: ExtractedText?,
        val errorCode: ExtractionErrorCode?,
    )

    enum class SkipReason { TooManyFiles, TotalCapExceeded }

    data class SkippedAttachment(val fileName: String, val reason: SkipReason)

    data class InjectResult(
        val text: String,
        val skipped: List<SkippedAttachment>,
    )

    
    private val errorInstructions = mapOf(
        ExtractionErrorCode.EncryptedPdf to
            "This file is encrypted and cannot be read. DO NOT fabricate or guess content. Tell the user the file is encrypted and ask them to decrypt it before uploading.",
        ExtractionErrorCode.ScannedPdf to
            "This is a scanned PDF without a text layer. The current model cannot OCR it. DO NOT fabricate content. Tell the user to switch to a vision-capable model (e.g., GPT-4o, Claude 3.5 Sonnet, Gemini 2.5 Pro) and re-upload.",
        ExtractionErrorCode.PasswordProtectedOffice to
            "This Office file is password-protected and cannot be read. DO NOT fabricate content. Tell the user to remove the password and re-upload.",
        ExtractionErrorCode.CorruptedFile to
            "This file is corrupted and cannot be parsed. DO NOT fabricate content. Tell the user the file may be damaged and ask them to re-upload a valid copy.",
        ExtractionErrorCode.UnsupportedFormat to
            "This file format is not supported by the local extractor. DO NOT fabricate content. Tell the user which formats are supported (PDF / DOCX / XLSX / PPTX / EPUB / HTML / plain text / code files).",
        ExtractionErrorCode.FileTooLarge to
            "This file exceeds the maximum size limit. DO NOT fabricate content. Tell the user the file is too large and ask them to split or shorten it.",
        ExtractionErrorCode.ExtractionTimeout to
            "Extraction of this file timed out (over 30 seconds). DO NOT fabricate content. Tell the user the file is too complex; ask them to simplify or split it.",
        ExtractionErrorCode.ExtractionError to
            "Extraction failed due to an internal error. DO NOT fabricate content. Tell the user to try again or use a different file.",
    )

    
    private fun fileTypeShort(mime: String, fileName: String): String {
        return when (mime.lowercase()) {
            "application/pdf" -> "pdf"
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> "docx"
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -> "xlsx"
            "application/vnd.openxmlformats-officedocument.presentationml.presentation" -> "pptx"
            "application/epub+zip" -> "epub"
            "text/html", "application/xhtml+xml" -> "html"
            "text/markdown" -> "md"
            "application/json" -> "json"
            "application/xml", "text/xml" -> "xml"
            else -> fileName.substringAfterLast('.', "").lowercase().ifEmpty { "txt" }
        }
    }

    

    fun formatAttachmentXml(index: Int, payload: AttachmentPayload): String = buildString {
        val sizeKB = (payload.sizeBytes + 1023) / 1024
        val fileType = fileTypeShort(payload.mimeType, payload.fileName)
        appendLine("<ATTACHMENT_FILE>")
        appendLine("<FILE_INDEX>$index</FILE_INDEX>")
        appendLine("<FILE_NAME>${payload.fileName}</FILE_NAME>")
        appendLine("<FILE_TYPE>$fileType</FILE_TYPE>")
        if (payload.extracted != null) {
            appendLine("<FILE_LINES>${payload.extracted.totalLines}</FILE_LINES>")
        }
        appendLine("<FILE_SIZE_KB>$sizeKB</FILE_SIZE_KB>")
        appendLine("<FILE_CONTENT>")
        if (payload.extracted != null) {
            appendLine(payload.extracted.content)
        } else {
            
            val code = payload.errorCode ?: ExtractionErrorCode.ExtractionError
            appendLine("[ERROR: extraction failed - ${code.raw}]")
            appendLine("[INSTRUCTION: ${errorInstructions[code] ?: errorInstructions[ExtractionErrorCode.ExtractionError]!!}]")
        }
        appendLine("</FILE_CONTENT>")
        if (payload.extracted?.truncated == true) {
            val n = payload.extracted.content.split("\n").size
            val total = payload.extracted.totalLines
            val text = when (payload.extracted.truncationReason) {
                ExtractedText.TruncationReason.Lines ->
                    "showing first $n of $total lines (size cap 200KB)"
                ExtractedText.TruncationReason.Bytes ->
                    "showing first $n of $total lines (truncated to fit 200KB cap)"
                null -> null
            }
            text?.let { appendLine("<TRUNCATED>$it</TRUNCATED>") }
        }
        append("</ATTACHMENT_FILE>")
    }

    

    fun formatAttachmentMarkdown(index: Int, payload: AttachmentPayload): String = buildString {
        val sizeKB = (payload.sizeBytes + 1023) / 1024
        val fileType = fileTypeShort(payload.mimeType, payload.fileName)
        appendLine("---")
        appendLine("## Attachment $index: ${payload.fileName}")
        appendLine("- Type: $fileType")
        appendLine("- Size: $sizeKB KB")
        if (payload.extracted != null) {
            if (payload.extracted.truncated) {
                val n = payload.extracted.content.split("\n").size
                appendLine("- Lines: ${payload.extracted.totalLines} (showing first $n, size cap 200KB)")
            } else {
                appendLine("- Lines: ${payload.extracted.totalLines}")
            }
            appendLine()
            appendLine("```")
            appendLine(payload.extracted.content)
            appendLine("```")
        } else {
            val code = payload.errorCode ?: ExtractionErrorCode.ExtractionError
            appendLine("- Status: **EXTRACTION FAILED** (error: ${code.raw})")
            appendLine()
            appendLine("> **Instruction to model:** ${errorInstructions[code] ?: errorInstructions[ExtractionErrorCode.ExtractionError]!!}")
        }
        append("---")
    }

    
    fun formatAttachment(
        wrapper: AttachmentWrapperVersion = AttachmentWrapperVersion.XmlV1,
        index: Int,
        payload: AttachmentPayload,
    ): String = when (wrapper) {
        AttachmentWrapperVersion.XmlV1 -> formatAttachmentXml(index, payload)
        AttachmentWrapperVersion.MarkdownV1 -> formatAttachmentMarkdown(index, payload)
    }

    
    fun injectAll(
        userText: String,
        attachments: List<AttachmentPayload>,
        limits: FileExtractionLimits = FileExtractionLimits.DEFAULT,
        wrapper: AttachmentWrapperVersion = AttachmentWrapperVersion.XmlV1,
    ): InjectResult {
        val parts = mutableListOf<String>()
        if (userText.isNotEmpty()) parts.add(userText)

        var consumed = 0
        val skipped = mutableListOf<SkippedAttachment>()
        var emittedIndex = 0

        for (att in attachments) {
            
            if (emittedIndex >= limits.maxFiles) {
                skipped.add(SkippedAttachment(att.fileName, SkipReason.TooManyFiles))
                continue
            }
            val block = formatAttachment(wrapper, emittedIndex + 1, att)
            val blockBytes = block.toByteArray(Charsets.UTF_8).size
            
            if (consumed + blockBytes > limits.totalCap) {
                skipped.add(SkippedAttachment(att.fileName, SkipReason.TotalCapExceeded))
                continue
            }
            parts.add(block)
            consumed += blockBytes
            emittedIndex += 1
        }

        return InjectResult(text = parts.joinToString("\n\n"), skipped = skipped)
    }

    
    const val SYSTEM_PROMPT_GUIDANCE = "When the user attaches files (see <ATTACHMENT_FILE> blocks or \"## Attachment N:\" sections in the message), refer to them by file name in your response. If a file's content is an [ERROR: ...] block, do not fabricate the content — explain the error to the user and follow the embedded instruction."
}
