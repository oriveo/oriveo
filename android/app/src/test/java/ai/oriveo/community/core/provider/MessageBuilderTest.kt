package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class MessageBuilderTest {

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
    fun `supportsFileAttachments respects provider support matrix`() {
        assertTrue(
            MessageBuilder.supportsFileAttachments(
                providerKind = ProviderKind.OpenAI,
                capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.File),
            ),
        )
        assertFalse(
            MessageBuilder.supportsFileAttachments(
                providerKind = null,
                capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.File),
            ),
        )
    }

    @Test
    fun `supportsFileAttachments works for SiliconFlow textFileInline`() {
        // SiliconFlow sets textFileInline=true and no longer depends on model.capabilities.File
        assertTrue(
            MessageBuilder.supportsFileAttachments(
                providerKind = ProviderKind.SiliconFlow,
                capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.File),
            ),
        )
        // Even with no File capability, textFileInline=true is enough to support it
        assertTrue(
            MessageBuilder.supportsFileAttachments(
                providerKind = ProviderKind.SiliconFlow,
                capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.Image),
            ),
        )
    }

    @Test
    fun `canAttachFile accepts text file for SiliconFlow`() {
        val textContent = Base64.getEncoder().encodeToString("def hello(): pass".toByteArray())
        assertTrue(
            MessageBuilder.canAttachFile(
                providerKind = ProviderKind.SiliconFlow,
                mimeType = "text/plain",
                base64Data = textContent,
            ),
        )
    }

    @Test
    fun `canAttachFile rejects PDF for SiliconFlow`() {
        val binaryPdf = Base64.getEncoder().encodeToString(
            byteArrayOf(0x25, 0x50, 0x44, 0x46, 0x2D, 0xFF.toByte()),
        )
        assertFalse(
            MessageBuilder.canAttachFile(
                providerKind = ProviderKind.SiliconFlow,
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
    fun `canAttachFile rejects binary relay file without native file support`() {
        val binaryPdf = Base64.getEncoder().encodeToString(
            byteArrayOf(0x25, 0x50, 0x44, 0x46, 0x2D, 0xFF.toByte()),
        )
        assertFalse(
            MessageBuilder.canAttachFile(
                providerKind = ProviderKind.Relay,
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

    // -- sanitizeOutboundMessages: normalising a history before it is sent, which is what made retries in an older
    // conversation fail forever --

    private fun msg(
        id: String,
        role: ChatRole,
        text: String,
        state: ChatMessageState,
    ) = ChatMessage(
        id = id, role = role, text = text,
        providerKind = ProviderKind.OpenRouter,
        providerName = "Test", modelName = "test-model",
        state = state,
    )

    @Test
    fun `sanitizeOutboundMessages - drops an empty failed assistant, the root cause of the retry bug`() {
        // Even when it is the keepAssistantId (a retry reuses its id), an empty text means it is dropped
        val messages = listOf(
            msg("u1", ChatRole.User, "hi", ChatMessageState.Delivered),
            msg("a1", ChatRole.Assistant, "", ChatMessageState.Failed),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages, keepAssistantId = "a1")
        assertEquals(listOf("u1"), result.map { it.id })
    }

    @Test
    fun `sanitizeOutboundMessages - a healthy conversation is passed through untouched`() {
        val messages = listOf(
            msg("u1", ChatRole.User, "hi", ChatMessageState.Delivered),
            msg("a1", ChatRole.Assistant, "hello", ChatMessageState.Delivered),
            msg("u2", ChatRole.User, "more", ChatMessageState.Delivered),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages)
        assertEquals(listOf("u1", "a1", "u2"), result.map { it.id })
    }

    @Test
    fun `sanitizeOutboundMessages - dropping an empty failed assistant in the middle also drops the older user, keeping only the latest`() {
        val messages = listOf(
            msg("u1", ChatRole.User, "q1", ChatMessageState.Delivered),
            msg("a1", ChatRole.Assistant, "", ChatMessageState.Failed),
            msg("u2", ChatRole.User, "q2", ChatMessageState.Delivered),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages)
        // Removing the empty a1 leaves u1 and u2 adjacent. The answer to u1 already failed or was abandoned, so the older u1
        // is dropped and only the latest u2 is sent: roles stay strictly alternating and two independent questions are not
        // merged into a single prompt the model would try to answer at once.
        assertEquals(listOf(ChatRole.User), result.map { it.role })
        assertEquals("q2", result.single().text)
        assertEquals(listOf("u2"), result.map { it.id })
    }

    @Test
    fun `sanitizeOutboundMessages - dropping an empty failed assistant mid-history keeps only the latest user and stays strictly alternating`() {
        // u1 -> a1(delivered) -> u2 -> a2(failed, empty) -> u3: once a2 is dropped, u2 and u3 are adjacent, and since the
        // answer to u2 already failed or was abandoned, u2 is dropped and only u3 survives.
        val messages = listOf(
            msg("u1", ChatRole.User, "q1", ChatMessageState.Delivered),
            msg("a1", ChatRole.Assistant, "a1", ChatMessageState.Delivered),
            msg("u2", ChatRole.User, "q2", ChatMessageState.Delivered),
            msg("a2", ChatRole.Assistant, "", ChatMessageState.Failed),
            msg("u3", ChatRole.User, "q3", ChatMessageState.Delivered),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages)
        assertEquals(
            listOf(ChatRole.User, ChatRole.Assistant, ChatRole.User),
            result.map { it.role },
        )
        assertEquals(listOf("q1", "a1", "q3"), result.map { it.text })
        assertEquals(listOf("u1", "a1", "u3"), result.map { it.id })
    }

    @Test
    fun `sanitizeOutboundMessages - an interrupted assistant with partial text is kept as context`() {
        val messages = listOf(
            msg("u1", ChatRole.User, "hi", ChatMessageState.Delivered),
            msg("a1", ChatRole.Assistant, "partial", ChatMessageState.Interrupted),
        )
        // Whatever was generated before the user pressed stop is valid context, so this assistant is kept even though it is
        // not the keepId. It also separates the two user turns naturally, so the model does not treat the earlier question
        // as unanswered and answer it a second time.
        val result = MessageBuilder.sanitizeOutboundMessages(messages, keepAssistantId = null)
        assertEquals(listOf("u1", "a1"), result.map { it.id })
    }

    @Test
    fun `sanitizeOutboundMessages - the interrupted assistant being continued is kept via keepId`() {
        val messages = listOf(
            msg("u1", ChatRole.User, "hi", ChatMessageState.Delivered),
            msg("a1", ChatRole.Assistant, "partial", ChatMessageState.Interrupted),
            msg("u2", ChatRole.User, "Continue", ChatMessageState.Delivered),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages, keepAssistantId = "a1")
        assertEquals(listOf("u1", "a1", "u2"), result.map { it.id })
    }

    @Test
    fun `sanitizeOutboundMessages - a failed assistant with partial text is kept as a prefill target`() {
        val messages = listOf(
            msg("u1", ChatRole.User, "hi", ChatMessageState.Delivered),
            msg("a1", ChatRole.Assistant, "partial answer", ChatMessageState.Failed),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages, keepAssistantId = "a1")
        assertEquals(listOf("u1", "a1"), result.map { it.id })
    }

    @Test
    fun `sanitizeOutboundMessages - a new question after a stop drops the old question once the empty interrupted assistant is removed`() {
        // Reproduces and pins a bug seen in the field: ask question A, press stop before the assistant emits any text (an
        // empty interruption), then ask question B. The old implementation merged A and B into one prompt and the model
        // answered both. Now the older question A is dropped and only B is sent.
        val messages = listOf(
            msg("uA", ChatRole.User, "what is that micro frontend framework called", ChatMessageState.Delivered),
            msg("aA", ChatRole.Assistant, "", ChatMessageState.Interrupted),
            msg("uB", ChatRole.User, "who runs that video studio", ChatMessageState.Delivered),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages)
        assertEquals(listOf("uB"), result.map { it.id })
        assertEquals("who runs that video studio", result.single().text)
    }

    @Test
    fun `sanitizeOutboundMessages - a failed turn never reaches the payload, including one filled with placeholder error copy and no keepId`() {
        // Some clients overwrite the text with localised error copy when the partial is empty, which is what the failure
        // bubble renders; here the text is simply empty. Either way a failed turn must not be sent to the model as
        // assistant context, or the error copy becomes a fake answer and is re-sent on every subsequent turn. Anything
        // with state == Failed is dropped, and when it is not the keepId the older user goes with it.
        val messages = listOf(
            msg("u1", ChatRole.User, "q1", ChatMessageState.Delivered),
            msg("a1", ChatRole.Assistant, "Request failed: invalid key", ChatMessageState.Failed),
            msg("u2", ChatRole.User, "q2", ChatMessageState.Delivered),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages)
        assertEquals(listOf("u2"), result.map { it.id })
        assertEquals("q2", result.single().text)
    }

    @Test
    fun `sanitizeOutboundMessages - a new question after a stop with partial text keeps the assistant between the two users so only the new question is answered`() {
        // Stopping late means the assistant already produced a partial, which is kept as valid context. It separates the
        // two user turns, satisfying strict alternation while still giving the model context, so the model answers only
        // the latest uB and does not re-answer uA.
        val messages = listOf(
            msg("uA", ChatRole.User, "what is that micro frontend framework called", ChatMessageState.Delivered),
            msg("aA", ChatRole.Assistant, "you probably mean micro-app", ChatMessageState.Interrupted),
            msg("uB", ChatRole.User, "who runs that video studio", ChatMessageState.Delivered),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages)
        assertEquals(
            listOf(ChatRole.User, ChatRole.Assistant, ChatRole.User),
            result.map { it.role },
        )
        assertEquals(listOf("uA", "aA", "uB"), result.map { it.id })
    }

    @Test
    fun `sanitizeOutboundMessages - adjacent assistants from an abnormal history are merged back into alternation`() {
        // Defensive: the normal path cannot produce adjacent assistants, since the message that gets dropped is always an
        // assistant and that leaves two users adjacent. But if an abnormal history does contain them, their text and
        // attachments are merged so a strict gateway does not reject two consecutive turns with the same role.
        val messages = listOf(
            msg("u1", ChatRole.User, "q1", ChatMessageState.Delivered),
            msg("a1", ChatRole.Assistant, "part1", ChatMessageState.Delivered),
            msg("a2", ChatRole.Assistant, "part2", ChatMessageState.Delivered),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages)
        assertEquals(listOf(ChatRole.User, ChatRole.Assistant), result.map { it.role })
        assertEquals("part1\n\npart2", result.last().text)
    }

    private fun imageAttachment(id: String) = Attachment(
        id = id, kind = AttachmentKind.Image,
        fileName = "generated.png", mimeType = "image/png", base64Data = "b64gen",
    )

    @Test
    fun `sanitizeOutboundMessages - strips a generated image from an assistant but keeps its text, the cause of an Upstream 400 after switching to a text-only model`() {
        val messages = listOf(
            msg("u1", ChatRole.User, "draw me a farmer", ChatMessageState.Delivered),
            msg("a1", ChatRole.Assistant, "here is the image I generated for you", ChatMessageState.Delivered)
                .copy(attachments = listOf(imageAttachment("gen1"))),
            msg("u2", ChatRole.User, "nice one", ChatMessageState.Delivered),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages)
        assertEquals(listOf("u1", "a1", "u2"), result.map { it.id })
        // The assistant text survives while the image attachment is stripped
        assertEquals("here is the image I generated for you", result[1].text)
        assertTrue(result[1].attachments.isNullOrEmpty())
    }

    @Test
    fun `sanitizeOutboundMessages - an image-only assistant becomes empty once stripped, so it is removed and the older user is dropped too`() {
        val messages = listOf(
            msg("u1", ChatRole.User, "draw me a farmer", ChatMessageState.Delivered),
            msg("a1", ChatRole.Assistant, "", ChatMessageState.Delivered)
                .copy(attachments = listOf(imageAttachment("gen1"))),
            msg("u2", ChatRole.User, "nice one", ChatMessageState.Delivered),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages)
        // Stripping the image leaves a1 empty, so it is removed, u1 and u2 become adjacent, and only the latest u2 remains
        assertEquals(listOf(ChatRole.User), result.map { it.role })
        assertEquals("nice one", result.single().text)
        assertEquals(listOf("u2"), result.map { it.id })
    }

    @Test
    fun `sanitizeOutboundMessages - an image uploaded by the user is not stripped, only the assistant role is touched`() {
        val messages = listOf(
            msg("u1", ChatRole.User, "what is this", ChatMessageState.Delivered)
                .copy(attachments = listOf(imageAttachment("up1"))),
        )
        val result = MessageBuilder.sanitizeOutboundMessages(messages)
        assertEquals(listOf("up1"), result.single().attachments?.map { it.id })
    }

    @Test
    fun `sanitizeOutboundMessages + buildOpenAIMessages - an assistant generated image never reaches the payload`() {
        val messages = listOf(
            msg("u1", ChatRole.User, "draw me a farmer", ChatMessageState.Delivered),
            msg("a1", ChatRole.Assistant, "here is the image I generated for you", ChatMessageState.Delivered)
                .copy(attachments = listOf(imageAttachment("gen1"))),
            msg("u2", ChatRole.User, "nice one", ChatMessageState.Delivered),
        )
        val sanitized = MessageBuilder.sanitizeOutboundMessages(messages)
        val json = MessageBuilder.buildOpenAIMessages(sanitized, ProviderKind.OpenAI)
        assertFalse(json.contains("image_url"))
        assertFalse(json.contains("b64gen"))
    }
}
