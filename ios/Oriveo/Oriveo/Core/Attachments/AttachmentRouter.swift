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

    /// extractionErrorCode == "scanned_pdf" → native( fallback)
    ///     - model.pdfNativeDefault == true → native(Gemini)
    static func decide(
        attachment: Attachment,
        provider: ProviderKind,
        model: AIModel
    ) -> AttachmentRoute {
        guard attachment.kind == .file else { return .clientExtract }

        let mime = attachment.mimeType.lowercased()
        guard model.nativeFileMimes.contains(mime) else { return .clientExtract }

        guard let base64 = attachment.originalBase64Data, !base64.isEmpty else {
            return .clientExtract
        }

        if let bytes = attachment.extractedSizeBytes,
           bytes > 0,
           bytes > maxNativeBytes(for: provider) {
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
