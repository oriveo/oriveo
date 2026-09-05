package ai.oriveo.community.core.provider

import ai.oriveo.community.core.attachments.AttachmentInjector
import ai.oriveo.community.core.attachments.ExtractedText
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class MessageBuilderAttachmentTest {

    private fun makeTextAttachment(text: String, fileName: String = "doc.txt"): Attachment {
        val encoded = Base64.getEncoder().encodeToString(text.toByteArray())
        return Attachment(
            id = "1",
            kind = AttachmentKind.File,
            fileName = fileName,
            mimeType = "text/plain",
            base64Data = encoded,
        )
    }

    private fun makeMsg(providerKind: ProviderKind, text: String, vararg attachments: Attachment) = ChatMessage(
        id = "m1",
        role = ChatRole.User,
        text = text,
        providerKind = providerKind,
        providerName = "Test",
        modelID = "test-model",
        modelName = "Test Model",
        state = ChatMessageState.Delivered,
        attachments = attachments.toList(),
    )

    @Test
    fun deepseekIncludesAttachmentMarkdownWrapper() {
        val att = makeTextAttachment("Hello document")
        val msg = makeMsg(ProviderKind.DeepSeek, "Read this", att)
        val s = MessageBuilder.buildDeepSeekContentForTest(msg)
        assertTrue("Should contain user text", s.contains("Read this"))
        // DeepSeek uses the markdown-v1 attachment format
        assertTrue("Should contain markdown wrapper", s.contains("## Attachment 1: doc.txt"))
        assertTrue("Should contain file content", s.contains("Hello document"))
    }

    @Test
    fun deepseekNoAttachmentReturnsPlainText() {
        val msg = makeMsg(ProviderKind.DeepSeek, "Hello world")
        val s = MessageBuilder.buildDeepSeekContentForTest(msg)
        assertTrue(s.contains("Hello world"))
        assertFalse(s.contains("ATTACHMENT_FILE"))
    }

    @Test
    fun supportsFileD2NoCapabilityRequired() {
        // textFileInline=true no longer depends on the model's declared capabilities
        val result = MessageBuilder.supportsFileAttachments(ProviderKind.DeepSeek, emptyList())
        assertTrue("DeepSeek with textFileInline=true must accept files", result)
    }

    @Test
    fun toAttachmentPayloadsExtractsText() {
        val text = "line1\nline2"
        val att = makeTextAttachment(text)
        val payloads = MessageBuilder.toAttachmentPayloads(listOf(att))
        assertFalse(payloads.isEmpty())
        val payload = payloads[0]
        assertNotNull(payload.extracted)
        assertTrue(payload.extracted!!.content.contains("line1"))
    }

    @Test
    fun toAttachmentPayloadsHandlesErrorCode() {
        val att = Attachment(
            id = "2",
            kind = AttachmentKind.File,
            fileName = "scan.pdf",
            mimeType = "application/pdf",
            base64Data = "",
            extractionErrorCode = "scanned_pdf",
        )
        val payloads = MessageBuilder.toAttachmentPayloads(listOf(att))
        assertFalse(payloads.isEmpty())
        val payload = payloads[0]
        assertNull("a scanned_pdf must not carry extracted content", payload.extracted)
        assertEquals(ExtractionErrorCode.ScannedPdf, payload.errorCode)
    }
}
