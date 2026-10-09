import Foundation

nonisolated enum AttachmentRoute: Equatable, Sendable {
    case native
    case clientExtract
}

nonisolated enum AttachmentRouter {

    private static let pdfMime = "application/pdf"
    private static let scannedPdfCode = "scanned_pdf"

    static func maxNativeBytes(for provider: ProviderKind) -> Int {
        switch provider {
        case .openAI: return 30 * 1024 * 1024
        case .anthropic: return 30 * 1024 * 1024
        case .gemini: return 20 * 1024 * 1024
        default: return 30 * 1024 * 1024
        }
    }

    /// Original file size in bytes, derived from the base64 length without decoding
    /// (decoding a large file would cost tens of MB of temporary memory).
    static func originalByteCount(ofBase64 base64: String) -> Int {
        let utf8 = base64.utf8
        var padding = 0
        var index = utf8.endIndex
        while padding < 2, index > utf8.startIndex {
            index = utf8.index(before: index)
            guard utf8[index] == UInt8(ascii: "=") else { break }
            padding += 1
        }
        return max(0, utf8.count / 4 * 3 - padding)
    }

    /// Decides whether an attachment is uploaded natively or extracted to text on the client.
    ///
    /// Any unmet precondition falls back to clientExtract:
    ///  1. Only `.file` attachments are handled; images and video take their own path
    ///  2. The mime type must be in the model's `nativeFileMimes` allow-list
    ///  3. `originalBase64Data` must be kept (raw bytes)
    ///  4. The original file size must be <= `maxNativeBytes(provider)`
    ///  5. PDF policy:
    ///     - extractionErrorCode == "scanned_pdf" -> native
    ///     - model.pdfNativeDefault == true -> native (Gemini)
    ///     - otherwise -> clientExtract (OpenAI / Anthropic default)
    ///  6. Any other native-capable mime (docx/xlsx/pptx/rtf/odt) -> native
    ///
    /// When the transport's mode is `.off` the result is always clientExtract; the other two modes route alike.
    static func decide(
        attachment: Attachment,
        provider: ProviderKind,
        model: AIModel,
        mode: NativeFileMode = .always
    ) -> AttachmentRoute {
        guard mode != .off else { return .clientExtract }
        guard attachment.kind == .file else { return .clientExtract }

        let mime = attachment.mimeType.lowercased()
        guard model.nativeFileMimes.contains(mime) else { return .clientExtract }

        guard let base64 = attachment.originalBase64Data, !base64.isEmpty else {
            return .clientExtract
        }

        // Compare the original file that would be uploaded, not the extracted text, which is usually tens of KB and never reaches the threshold.
        if originalByteCount(ofBase64: base64) > maxNativeBytes(for: provider) {
            return .clientExtract
        }

        if mime == pdfMime {
            if attachment.extractionErrorCode == scannedPdfCode {
                return .native
            }
            if model.pdfNativeDefault {
                return .native
            }
            return .clientExtract
        }

        return .native
    }
}
