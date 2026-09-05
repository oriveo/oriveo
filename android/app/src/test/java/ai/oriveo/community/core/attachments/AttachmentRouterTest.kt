package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.assertEquals
import org.junit.Test

class AttachmentRouterTest {

    private val openAIOfficeMimes = listOf(
        "application/pdf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/rtf",
        "text/rtf",
        "application/vnd.oasis.opendocument.text",
        "application/vnd.oasis.opendocument.spreadsheet",
        "application/vnd.oasis.opendocument.presentation",
    )

    private fun makeAttachment(
        kind: AttachmentKind = AttachmentKind.File,
        mimeType: String =
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        originalBase64: String? = "ZmFrZQ==",
        sizeBytes: Int? = 5_000,
        errorCode: String? = null,
    ) = Attachment(
        id = "a-1",
        kind = kind,
        fileName = "test.docx",
        mimeType = mimeType,
        base64Data = null,
        extractedSizeBytes = sizeBytes,
        extractionErrorCode = errorCode,
        originalBase64Data = originalBase64,
    )

    private fun makeModel(
        id: String = "gpt-5",
        nativeFileMimes: List<String> = openAIOfficeMimes,
        pdfNativeDefault: Boolean = false,
    ) = AIModel(
        id = id,
        name = id,
        capabilities = listOf(ModelCapability.Text, ModelCapability.Image, ModelCapability.File),
        priceTier = "premium",
        nativeFileMimes = nativeFileMimes,
        pdfNativeDefault = pdfNativeDefault,
    )

    

    @Test fun `docx OpenAI GPT-5 to Native`() {
        val route = AttachmentRouter.decide(
            makeAttachment(),
            ProviderKind.OpenAI,
            makeModel(),
        )
        assertEquals(AttachmentRoute.Native, route)
    }

    @Test fun `docx OpenAI gpt-4o-mini (whitelisted) to Native`() {
        val route = AttachmentRouter.decide(
            makeAttachment(),
            ProviderKind.OpenAI,
            makeModel(id = "gpt-4o-mini"),
        )
        assertEquals(AttachmentRoute.Native, route)
    }

    @Test fun `docx OpenAI dall-e (empty nativeFileMimes) to ClientExtract`() {
        val route = AttachmentRouter.decide(
            makeAttachment(),
            ProviderKind.OpenAI,
            makeModel(id = "dall-e-3", nativeFileMimes = emptyList()),
        )
        assertEquals(AttachmentRoute.ClientExtract, route)
    }

    @Test fun `docx OpenRouter (only PDF mime) to ClientExtract`() {
        val route = AttachmentRouter.decide(
            makeAttachment(),
            ProviderKind.OpenRouter,
            makeModel(nativeFileMimes = listOf("application/pdf")),
        )
        assertEquals(AttachmentRoute.ClientExtract, route)
    }

    @Test fun `docx Anthropic (only PDF mime) to ClientExtract`() {
        val route = AttachmentRouter.decide(
            makeAttachment(),
            ProviderKind.Anthropic,
            makeModel(nativeFileMimes = listOf("application/pdf")),
        )
        assertEquals(AttachmentRoute.ClientExtract, route)
    }

    @Test fun `docx DeepSeek (no nativeFileMimes) to ClientExtract`() {
        val route = AttachmentRouter.decide(
            makeAttachment(),
            ProviderKind.DeepSeek,
            makeModel(nativeFileMimes = emptyList()),
        )
        assertEquals(AttachmentRoute.ClientExtract, route)
    }

    

    @Test fun `PDF OpenAI GPT-5 pdfNativeDefault false to ClientExtract`() {
        val route = AttachmentRouter.decide(
            makeAttachment(mimeType = "application/pdf"),
            ProviderKind.OpenAI,
            makeModel(pdfNativeDefault = false),
        )
        assertEquals(AttachmentRoute.ClientExtract, route)
    }

    @Test fun `PDF Anthropic pdfNativeDefault false to ClientExtract`() {
        val route = AttachmentRouter.decide(
            makeAttachment(mimeType = "application/pdf"),
            ProviderKind.Anthropic,
            makeModel(nativeFileMimes = listOf("application/pdf"), pdfNativeDefault = false),
        )
        assertEquals(AttachmentRoute.ClientExtract, route)
    }

    @Test fun `PDF Gemini pdfNativeDefault true to Native (D28)`() {
        val route = AttachmentRouter.decide(
            makeAttachment(mimeType = "application/pdf"),
            ProviderKind.Gemini,
            makeModel(nativeFileMimes = listOf("application/pdf"), pdfNativeDefault = true),
        )
        assertEquals(AttachmentRoute.Native, route)
    }

    

    @Test fun `scanned_pdf OpenAI GPT-5 to Native (D1 fallback)`() {
        val route = AttachmentRouter.decide(
            makeAttachment(mimeType = "application/pdf", errorCode = "scanned_pdf"),
            ProviderKind.OpenAI,
            makeModel(pdfNativeDefault = false),
        )
        assertEquals(AttachmentRoute.Native, route)
    }

    @Test fun `scanned_pdf Anthropic Claude to Native (D1 fallback)`() {
        val route = AttachmentRouter.decide(
            makeAttachment(mimeType = "application/pdf", errorCode = "scanned_pdf"),
            ProviderKind.Anthropic,
            makeModel(nativeFileMimes = listOf("application/pdf"), pdfNativeDefault = false),
        )
        assertEquals(AttachmentRoute.Native, route)
    }

    @Test fun `scanned_pdf DeepSeek (no native PDF) to ClientExtract`() {
        val route = AttachmentRouter.decide(
            makeAttachment(mimeType = "application/pdf", errorCode = "scanned_pdf"),
            ProviderKind.DeepSeek,
            makeModel(nativeFileMimes = emptyList()),
        )
        assertEquals(AttachmentRoute.ClientExtract, route)
    }

    

    @Test fun `oversized 30MB on OpenAI to ClientExtract (Android 25MB threshold)`() {
        val route = AttachmentRouter.decide(
            makeAttachment(sizeBytes = 30 * 1024 * 1024),
            ProviderKind.OpenAI,
            makeModel(),
        )
        assertEquals(AttachmentRoute.ClientExtract, route)
    }

    @Test fun `no originalBase64Data to ClientExtract`() {
        val route = AttachmentRouter.decide(
            makeAttachment(originalBase64 = null),
            ProviderKind.OpenAI,
            makeModel(),
        )
        assertEquals(AttachmentRoute.ClientExtract, route)
    }

    @Test fun `image kind to ClientExtract (image goes via independent path)`() {
        val route = AttachmentRouter.decide(
            makeAttachment(kind = AttachmentKind.Image),
            ProviderKind.OpenAI,
            makeModel(),
        )
        assertEquals(AttachmentRoute.ClientExtract, route)
    }

    

    @Test fun `maxNativeBytes per provider`() {
        assertEquals(25 * 1024 * 1024, AttachmentRouter.maxNativeBytes(ProviderKind.OpenAI))
        assertEquals(25 * 1024 * 1024, AttachmentRouter.maxNativeBytes(ProviderKind.Anthropic))
        assertEquals(20 * 1024 * 1024, AttachmentRouter.maxNativeBytes(ProviderKind.Gemini))
        assertEquals(25 * 1024 * 1024, AttachmentRouter.maxNativeBytes(ProviderKind.DeepSeek))
    }
}
