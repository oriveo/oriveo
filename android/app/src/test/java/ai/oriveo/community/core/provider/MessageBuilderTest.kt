package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.testing.BundledAttachmentSupportFixture
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class MessageBuilderTest {

    // Attachment support of official providers comes only from metadata; after a case that injected any, the MetadataClient.instance table is cleared.
    @After
    fun clearInjectedMetadata() = BundledAttachmentSupportFixture.clear()

    private fun textMessage(role: ChatRole, text: String) = ChatMessage(
        id = "test", role = role, text = text,
        providerKind = ProviderKind.OpenRouter,
        providerName = "Test", modelName = "test-model",
        state = ChatMessageState.Delivered,
    )

    private fun messageWithImage(text: String) = textMessage(ChatRole.User, text).copy(
        attachments = listOf(
            Attachment(
                id = "att1", kind = AttachmentKind.Image,
                fileName = "photo.jpg", mimeType = "image/jpeg",
                base64Data = "dGVzdA==",
            )
        )
    )

    // ── OpenAI Message Building ──

    @Test
    fun `buildOpenAIMessages - text only returns simple content`() {
        val msgs = listOf(textMessage(ChatRole.User, "Hello"))
        val result = MessageBuilder.buildOpenAIMessages(msgs, ProviderKind.OpenAI)
        assertTrue(result.contains("\"role\":\"user\""))
        assertTrue(result.contains("\"Hello\""))
    }

    @Test
    fun `buildOpenAIMessages - with image attachment includes image_url`() {
        val msgs = listOf(messageWithImage("What is this?"))
        val result = MessageBuilder.buildOpenAIMessages(msgs, ProviderKind.OpenAI)
        assertTrue(result.contains("image_url"))
        assertTrue(result.contains("data:image/jpeg;base64,dGVzdA=="))
        assertTrue(result.indexOf(""""type":"text"""") < result.indexOf("image_url"))
    }

    @Test
    fun `buildOpenAIMessages - OpenRouter file attachment uses AttachmentInjector text block`() {
        // Every file attachment goes through AttachmentInjector; the native file_data path is not used.
        val textContent = java.util.Base64.getEncoder().encodeToString("PDF extracted text".toByteArray())
        val msg = textMessage(ChatRole.User, "Check this PDF").copy(
            attachments = listOf(
                Attachment(
                    id = "att2", kind = AttachmentKind.File,
                    fileName = "doc.pdf", mimeType = "text/plain",
                    base64Data = textContent,
                )
            )
        )
        val result = MessageBuilder.buildOpenAIMessages(listOf(msg), ProviderKind.OpenRouter)
        // xml-v1 wrapper (OpenRouter uses xml-v1)
        assertTrue("Should contain ATTACHMENT_FILE wrapper", result.contains("ATTACHMENT_FILE") || result.contains("doc.pdf"))
        assertTrue("Should contain text part", result.contains("\"type\":\"text\""))
    }

    @Test
    fun `buildOpenAIMessages - prepends system prompt when provided`() {
        val msgs = listOf(textMessage(ChatRole.User, "Hello"))
        val result = MessageBuilder.buildOpenAIMessages(
            messages = msgs,
            providerKind = ProviderKind.OpenAI,
            systemPrompt = "Be concise",
        )
        assertTrue(result.startsWith("{\"role\":\"system\""))
        assertTrue(result.contains("Be concise"))
    }

    @Test
    fun `buildOpenAIResponsesInput - file attachments go through AttachmentInjector text block`() {
        // An ordinary file with no scanned_pdf error goes through AttachmentInjector as input_text.
        val textFile = Base64.getEncoder().encodeToString("hello from file".toByteArray())
        val msg = textMessage(ChatRole.User, "Read both").copy(
            attachments = listOf(
                Attachment(
                    id = "txt",
                    kind = AttachmentKind.File,
                    fileName = "notes.txt",
                    mimeType = "text/plain",
                    base64Data = textFile,
                ),
            ),
        )

        val result = MessageBuilder.buildOpenAIResponsesInput(listOf(msg))

        assertTrue(result.contains("\"type\":\"input_text\""))
        assertTrue(result.contains("notes.txt"))
        assertTrue(result.contains("hello from file"))
    }

    @Test
    fun `buildOpenAIResponsesInput - plain history uses role-correct typed text parts`() {
        val result = MessageBuilder.buildOpenAIResponsesInput(listOf(
            textMessage(ChatRole.User, "question"),
            textMessage(ChatRole.Assistant, "answer"),
        ))

        assertTrue(result.contains(""""role":"user","content":[{"type":"input_text","text":"question"}]"""))
        assertTrue(result.contains(""""role":"assistant","content":[{"type":"output_text","text":"answer"}]"""))
        assertFalse(result.contains(""""content":""""))
    }

    @Test
    fun `buildOpenAIResponsesInput - assistant history drops stale input attachments`() {
        val result = MessageBuilder.buildOpenAIResponsesInput(listOf(
            messageWithImage("past answer").copy(role = ChatRole.Assistant),
        ))

        assertTrue(result.contains(""""type":"output_text","text":"past answer""""))
        assertFalse(result.contains("input_image"))
        assertFalse(result.contains("input_file"))
    }

    // ── Anthropic Message Building ──

    @Test
    fun `buildAnthropicMessages - image uses base64 source`() {
        val msgs = listOf(messageWithImage("Describe this"))
        val result = MessageBuilder.buildAnthropicMessages(msgs)
        assertTrue(result.contains("\"type\":\"image\""))
        assertTrue(result.contains("\"type\":\"base64\""))
        assertTrue(result.contains("\"media_type\":\"image/jpeg\""))
        assertTrue(result.indexOf(""""type":"text"""") < result.indexOf(""""type":"image""""))
    }

    @Test
    fun `buildAnthropicMessages - text only uses simple string content`() {
        val msgs = listOf(textMessage(ChatRole.User, "Hello"))
        val result = MessageBuilder.buildAnthropicMessages(msgs)
        assertTrue(result.contains("\"role\":\"user\""))
        assertTrue(result.contains("Hello"))
    }

    // ── Gemini Message Building ──

    @Test
    fun `buildGeminiContents - maps assistant to model role`() {
        val msgs = listOf(textMessage(ChatRole.Assistant, "Hi there"))
        val result = MessageBuilder.buildGeminiContents(msgs)
        assertTrue(result.contains("\"role\":\"model\""))
    }

    @Test
    fun `buildGeminiContents - image uses inlineData`() {
        val msgs = listOf(messageWithImage("What is this?"))
        val result = MessageBuilder.buildGeminiContents(msgs)
        assertTrue(result.contains("inlineData"))
        assertTrue(result.contains("\"mimeType\":\"image/jpeg\""))
        assertTrue(result.indexOf(""""text":"What is this?"""") < result.indexOf("inlineData"))
    }

    @Test
    fun `normalizeRequestOptions preserves explicit temperature and omits legacy max token default`() {
        val normalized = MessageBuilder.normalizeRequestOptions(
            ChatRequestOptions(
                temperature = ChatRequestOptions.DEFAULT_TEMPERATURE,
                maxTokens = ChatRequestOptions.DEFAULT_MAX_TOKENS,
                systemPrompt = "  ",
            ),
        )

        assertEquals(ChatRequestOptions.DEFAULT_TEMPERATURE, normalized.temperature)
        assertEquals(null, normalized.maxTokens)
        assertEquals("", normalized.systemPrompt)
    }

    @Test
    fun `file entry follows provider text inline without native file_input`() {
        // SiliconFlow sets textFileInline=true and no longer depends on model.capabilities.File; text inlining is not gated by file_input.
        BundledAttachmentSupportFixture.install("siliconFlow")
        val resolver = ai.oriveo.community.feature.chat.ChatModelCapabilityResolver(metadata = ai.oriveo.community.core.data.remote.MetadataClient())
        val model = ai.oriveo.community.core.model.AIModel(
            id = "unlisted",
            name = "Unlisted",
            capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.Image),
        )
        assertTrue(resolver.attachmentInputGate(ai.oriveo.community.core.model.Provider(id = "sf", kind = ProviderKind.SiliconFlow), model).file)
        assertFalse(resolver.attachmentInputGate(null, model).file)
    }

    @Test
    fun `canAttachFile accepts text file through text inline gate`() {
        val textContent = Base64.getEncoder().encodeToString("def hello(): pass".toByteArray())
        assertTrue(
            MessageBuilder.canAttachFile(
                gate = ai.oriveo.community.core.provider.AttachmentInputGate(textFileInline = true),
                mimeType = "text/plain",
                base64Data = textContent,
            ),
        )
    }

    @Test
    fun `canAttachFile rejects binary PDF through text inline gate`() {
        val binaryPdf = Base64.getEncoder().encodeToString(
            byteArrayOf(0x25, 0x50, 0x44, 0x46, 0x2D, 0xFF.toByte()),
        )
        assertFalse(
            MessageBuilder.canAttachFile(
                gate = ai.oriveo.community.core.provider.AttachmentInputGate(textFileInline = true),
                mimeType = "application/pdf",
                base64Data = binaryPdf,
            ),
        )
    }

    @Test
    fun `buildOpenAIMessages - SiliconFlow text file inlined to message`() {
        val textContent = Base64.getEncoder().encodeToString("print('hello')".toByteArray())
        val msg = textMessage(ChatRole.User, "Run this code").copy(
            attachments = listOf(
                Attachment(
                    id = "file1", kind = AttachmentKind.File,
                    fileName = "main.py", mimeType = "text/plain",
                    base64Data = textContent,
                )
            )
        )
        val result = MessageBuilder.buildOpenAIMessages(listOf(msg), ProviderKind.SiliconFlow)
        // A text file has to be inlined into the message
        assertTrue(result.contains("main.py"))
        assertTrue(result.contains("print('hello')"))
        // and the native file content part must not be used
        assertFalse(result.contains("\"type\":\"file\""))
    }

    @Test
    fun `canAttachFile gates binary file on native file_input`() {
        val binaryPdf = Base64.getEncoder().encodeToString(
            byteArrayOf(0x25, 0x50, 0x44, 0x46, 0x2D, 0xFF.toByte()),
        )
        assertFalse(
            MessageBuilder.canAttachFile(
                gate = ai.oriveo.community.core.provider.AttachmentInputGate(textFileInline = true),
                mimeType = "application/pdf",
                base64Data = binaryPdf,
            ),
        )
        assertTrue(
            MessageBuilder.canAttachFile(
                gate = ai.oriveo.community.core.provider.AttachmentInputGate(nativeFile = true),
                mimeType = "application/pdf",
                base64Data = binaryPdf,
            ),
        )
    }

    @Test
    fun `resolveAttachmentMimeType falls back from filename when resolver is generic`() {
        assertEquals(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            MessageBuilder.resolveAttachmentMimeType(
                fileName = "brief.docx",
                detectedMimeType = "application/octet-stream",
            ),
        )
    }

    // ── Inline Image Extraction ──

    @Test
    fun `extractInlineImages - no images returns original text`() {
        val (text, images) = MessageBuilder.extractInlineImages("Hello world")
        assertEquals("Hello world", text)
        assertTrue(images.isEmpty())
    }

    @Test
    fun `extractInlineImages - extracts base64 image from markdown`() {
        val markdown = "Here is an image: ![alt](data:image/png;base64,iVBORw0KGgo=) done"
        val (text, images) = MessageBuilder.extractInlineImages(markdown)
        assertEquals(1, images.size)
        assertEquals("image/png", images[0].first)
        assertEquals("iVBORw0KGgo=", images[0].second)
        assertTrue(text.contains("Here is an image:"))
        assertTrue(!text.contains("data:image"))
    }

    @Test
    fun `extractInlineImages - multiple images`() {
        val md = "![a](data:image/jpeg;base64,abc=) text ![b](data:image/png;base64,def=)"
        val (_, images) = MessageBuilder.extractInlineImages(md)
        assertEquals(2, images.size)
    }

    // Column-wrapped base64 that is not extracted leaves the whole data URI in the persisted text and the row exceeds the CursorWindow limit
    @Test
    fun `extractInlineImages - line wrapped base64 is extracted and whitespace removed`() {
        val md = "before\n![g](data:image/png;base64,iVBO\nRw0K\r\nGgo= )\nafter"
        val (text, images) = MessageBuilder.extractInlineImages(md)
        assertEquals(listOf("image/png" to "iVBORw0KGgo="), images)
        assertFalse(text.contains("data:image"))
        assertTrue(text.contains("before") && text.contains("after"))
    }
}
