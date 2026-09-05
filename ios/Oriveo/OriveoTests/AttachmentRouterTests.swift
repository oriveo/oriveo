import Testing
import Foundation
@testable import Oriveo

@Suite("AttachmentRouter")
struct AttachmentRouterTests {

    private static let openAIOfficeMimes = [
        "application/pdf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/rtf",
        "text/rtf",
        "application/vnd.oasis.opendocument.text",
        "application/vnd.oasis.opendocument.spreadsheet",
        "application/vnd.oasis.opendocument.presentation",
    ]

    private static func makeAttachment(
        kind: Oriveo.AttachmentKind = .file,
        mimeType: String =
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        originalBase64: String? = "ZmFrZQ==",
        sizeBytes: Int? = 5_000,
        errorCode: String? = nil
    ) -> Oriveo.Attachment {
        Oriveo.Attachment(
            id: UUID(),
            kind: kind,
            fileName: "test.docx",
            mimeType: mimeType,
            base64Data: nil,
            extractedSizeBytes: sizeBytes,
            extractionErrorCode: errorCode,
            originalBase64Data: originalBase64
        )
    }

    private static func makeModel(
        id: String = "gpt-5",
        nativeFileMimes: [String] = openAIOfficeMimes,
        pdfNativeDefault: Bool = false
    ) -> AIModel {
        AIModel(
            id: id,
            name: id,
            capabilities: [.text, .image, .file],
            reasoningModeAvailable: false,
            isAvailable: true,
            isDefault: true,
            priceTier: "premium",
            nativeFileMimes: nativeFileMimes,
            pdfNativeDefault: pdfNativeDefault
        )
    }

    @Test("queue limiter caps pending attachments by model max")
    func queueLimiterCapsPendingAttachmentsByModelMax() {
        let existing = [
            Self.makeAttachment(),
            Self.makeAttachment()
        ]
        let incoming = [
            Self.makeAttachment(),
            Self.makeAttachment()
        ]

        let result = AttachmentImportLimiter.limit(
            existing: existing,
            incoming: incoming,
            maxAttachments: 3
        )

        #expect(result.accepted.count == 1)
        #expect(result.rejectedCount == 1)
    }


    @Test("docx → OpenAI GPT-5 → native")
    func docxOpenAINative() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(),
            provider: .openAI,
            model: Self.makeModel()
        )
        #expect(route == .native)
    }

    @Test("docx → OpenAI gpt-4o-mini (whitelisted) → native")
    func docxOpenAIMiniNative() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(),
            provider: .openAI,
            model: Self.makeModel(id: "gpt-4o-mini")
        )
        #expect(route == .native)
    }

    @Test("docx → OpenAI dall-e (no nativeFileMimes) → clientExtract")
    func docxOpenAIDallEClient() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(),
            provider: .openAI,
            model: Self.makeModel(id: "dall-e-3", nativeFileMimes: [])
        )
        #expect(route == .clientExtract)
    }

    @Test("docx → OpenRouter (only PDF mime) → clientExtract")
    func docxOpenRouterClient() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(),
            provider: .openRouter,
            model: Self.makeModel(nativeFileMimes: ["application/pdf"])
        )
        #expect(route == .clientExtract)
    }

    @Test("docx → Anthropic (only PDF mime) → clientExtract")
    func docxAnthropicClient() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(),
            provider: .anthropic,
            model: Self.makeModel(nativeFileMimes: ["application/pdf"])
        )
        #expect(route == .clientExtract)
    }

    @Test("docx → DeepSeek (no nativeFileMimes) → clientExtract")
    func docxDeepSeekClient() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(),
            provider: .deepseek,
            model: Self.makeModel(nativeFileMimes: [])
        )
        #expect(route == .clientExtract)
    }


    @Test("PDF → OpenAI GPT-5 (pdfNativeDefault=false) → clientExtract")
    func pdfOpenAIClient() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(mimeType: "application/pdf"),
            provider: .openAI,
            model: Self.makeModel(pdfNativeDefault: false)
        )
        #expect(route == .clientExtract)
    }

    @Test("PDF → Anthropic (pdfNativeDefault=false) → clientExtract")
    func pdfAnthropicClient() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(mimeType: "application/pdf"),
            provider: .anthropic,
            model: Self.makeModel(
                nativeFileMimes: ["application/pdf"],
                pdfNativeDefault: false
            )
        )
        #expect(route == .clientExtract)
    }

    @Test("PDF → Gemini with pdfNativeDefault → native")
    func pdfGeminiNative() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(mimeType: "application/pdf"),
            provider: .gemini,
            model: Self.makeModel(
                nativeFileMimes: ["application/pdf"],
                pdfNativeDefault: true
            )
        )
        #expect(route == .native)
    }


    @Test("scanned_pdf → GPT-5 → native (D1 fallback)")
    func scannedPdfOpenAINative() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(
                mimeType: "application/pdf",
                errorCode: "scanned_pdf"
            ),
            provider: .openAI,
            model: Self.makeModel(pdfNativeDefault: false)
        )
        #expect(route == .native)
    }

    @Test("scanned_pdf → Claude → native (D1 fallback)")
    func scannedPdfAnthropicNative() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(
                mimeType: "application/pdf",
                errorCode: "scanned_pdf"
            ),
            provider: .anthropic,
            model: Self.makeModel(
                nativeFileMimes: ["application/pdf"],
                pdfNativeDefault: false
            )
        )
        #expect(route == .native)
    }

    @Test("scanned_pdf → DeepSeek (no native PDF) → clientExtract")
    func scannedPdfDeepSeekClient() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(
                mimeType: "application/pdf",
                errorCode: "scanned_pdf"
            ),
            provider: .deepseek,
            model: Self.makeModel(nativeFileMimes: [])
        )
        #expect(route == .clientExtract)
    }


    @Test("Oversized Client")
    func oversizedClient() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(sizeBytes: 35 * 1024 * 1024),
            provider: .openAI,
            model: Self.makeModel()
        )
        #expect(route == .clientExtract)
    }

    @Test("no originalBase64Data → clientExtract")
    func missingBase64Client() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(originalBase64: nil),
            provider: .openAI,
            model: Self.makeModel()
        )
        #expect(route == .clientExtract)
    }

    @Test("Image Kind Client")
    func imageKindClient() {
        let route = AttachmentRouter.decide(
            attachment: Self.makeAttachment(kind: .image),
            provider: .openAI,
            model: Self.makeModel()
        )
        #expect(route == .clientExtract)
    }


    @Test("Native Bytes Thresholds")
    func nativeBytesThresholds() {
        #expect(AttachmentRouter.maxNativeBytes(for: .openAI) == 30 * 1024 * 1024)
        #expect(AttachmentRouter.maxNativeBytes(for: .anthropic) == 30 * 1024 * 1024)
        #expect(AttachmentRouter.maxNativeBytes(for: .gemini) == 20 * 1024 * 1024)
        #expect(AttachmentRouter.maxNativeBytes(for: .deepseek) == 30 * 1024 * 1024)
    }
}
