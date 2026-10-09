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

    private val docxMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    private fun nativeDocx(name: String) = Attachment(
        id = name,
        kind = AttachmentKind.File,
        fileName = name,
        mimeType = docxMime,
        base64Data = Base64.getEncoder().encodeToString("extracted".toByteArray()),
        extractedSizeBytes = 5_000,
        originalBase64Data = "ZmFrZQ==",
    )

    private fun nativeModel(pdfNativeDefault: Boolean = false) = ai.oriveo.community.core.model.AIModel(
        id = "m",
        name = "m",
        capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.Text),
        nativeFileMimes = listOf(docxMime),
        pdfNativeDefault = pdfNativeDefault,
    )

    /** The five request-body construction paths, each through its public entry point as it stands. */
    private fun builders(model: ai.oriveo.community.core.model.AIModel?): Map<String, (List<ChatMessage>) -> String> = mapOf(
        "chat completions" to { messages -> MessageBuilder.buildOpenAIMessages(messages, ProviderKind.Groq, activeModel = model) },
        "deepseek" to { messages -> MessageBuilder.buildDeepSeekMessages(messages, activeModel = model) },
        "responses" to { messages -> MessageBuilder.buildOpenAIResponsesInput(messages, model) },
        "anthropic" to { messages -> MessageBuilder.buildAnthropicMessages(messages, model) },
        "gemini" to { messages -> MessageBuilder.buildGeminiContents(messages, model) },
    )

    private val pdfMime = "application/pdf"

    private fun textPdf() = Attachment(
        id = "text-pdf",
        kind = AttachmentKind.File,
        fileName = "report.pdf",
        mimeType = pdfMime,
        base64Data = Base64.getEncoder().encodeToString("extracted report body".toByteArray()),
        extractedSizeBytes = 5_000,
        originalBase64Data = "VEVYVFBERg==",
    )

    private fun scannedPdf() = Attachment(
        id = "scan-pdf",
        kind = AttachmentKind.File,
        fileName = "scan.pdf",
        mimeType = pdfMime,
        base64Data = "",
        extractedSizeBytes = 5_000,
        originalBase64Data = "U0NBTlBERg==",
        extractionErrorCode = "scanned_pdf",
    )

    private fun <T> withGeminiPdfCatalog(block: () -> T): T {
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{
              "gemini":{"resolveMap":{"gemini-x":"gemini-x"},"models":{"gemini-x":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true}}},
              "openAI":{"resolveMap":{"gemini-x":"gemini-x"},"models":{"gemini-x":{"nativeFileMimes":["application/pdf","$docxMime"]}}}
            }}""",
        )
        return try { block() } finally { MetadataTestFixtures.clear() }
    }

    /**
     * When a relay speaks an official protocol, the routing rules are exactly those of a direct connection; when it is marked "no file blocks this time" (a fallback resend), the same file
     * is injected as text. The model comes from the production catalog resolution and the request body from the Relay builder functions.
     */
    @Test
    fun relayGeminiRoutesLikeDirectAndDropsFileBlocksOnlyWhenAsked() = withGeminiPdfCatalog {
        fun body(attachment: Attachment, options: ai.oriveo.community.core.model.ChatRequestOptions) =
            ai.oriveo.community.core.provider.relay.buildGeminiBody(
                messages = listOf(makeMsg(ProviderKind.Relay, "read", attachment)),
                modelID = "gemini-x",
                supportsImageGen = false,
                reasoningMode = ai.oriveo.community.core.model.ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = options,
            )
        val normal = ai.oriveo.community.core.model.ChatRequestOptions()
        val native = body(textPdf(), normal)
        assertTrue(native, native.contains(""""inlineData":{"mimeType":"application/pdf","data":"VEVYVFBERg=="}"""))
        assertFalse(native, native.contains("extracted report body"))
        assertTrue(body(scannedPdf(), normal).contains("U0NBTlBERg=="))

        val textOnly = body(textPdf(), normal.copy(nativeFilesDisabled = true))
        assertTrue(textOnly, textOnly.contains("extracted report body"))
        assertFalse(textOnly, textOnly.contains("inlineData"))
    }

    @Test
    fun relayResponsesDropsFileBlocksOnlyWhenAsked() = withGeminiPdfCatalog {
        fun body(options: ai.oriveo.community.core.model.ChatRequestOptions) =
            ai.oriveo.community.core.provider.relay.buildResponsesBody(
                modelID = "gemini-x",
                messages = listOf(makeMsg(ProviderKind.Relay, "read", nativeDocx("n.docx"))),
                stream = true,
                supportsImageGen = false,
                reasoningMode = ai.oriveo.community.core.model.ReasoningMode.Automatic,
                webSearchEnabled = false,
                requestOptions = options,
            )
        val normal = ai.oriveo.community.core.model.ChatRequestOptions()
        assertTrue(body(normal).contains("input_file"))
        val textOnly = body(normal.copy(nativeFilesDisabled = true))
        assertTrue(textOnly, textOnly.contains("extracted"))
        assertFalse(textOnly, textOnly.contains("input_file"))
    }

    /** A direct route is unchanged: the same text PDF still goes up natively on official Gemini. */
    @Test
    fun directGeminiStillUploadsTextPdfNatively() = withGeminiPdfCatalog {
        val model = ai.oriveo.community.core.data.remote.MetadataClient.resolveAIModelForRouter("gemini-x", ProviderKind.Gemini)
        val body = MessageBuilder.buildGeminiContents(listOf(makeMsg(ProviderKind.Gemini, "read", textPdf())), model)
        assertTrue(body, body.contains(""""inlineData":{"mimeType":"application/pdf","data":"VEVYVFBERg=="}"""))
        assertFalse(body, body.contains("extracted report body"))
    }

    @Test
    fun openRouterEmitsNativeFilePartsForNonUserMessagesToo() {
        // A file judged native is not in the text; if a non-user message did not emit the file block, the file would be in neither place.
        val assistant = makeMsg(ProviderKind.OpenRouter, "here is the file", nativeDocx("n.docx"))
            .copy(role = ChatRole.Assistant)
        val next = makeMsg(ProviderKind.OpenRouter, "thanks").copy(id = "m2", attachments = null)
        val body = MessageBuilder.buildOpenAIMessages(listOf(assistant, next), ProviderKind.OpenRouter, activeModel = nativeModel())
        assertTrue(body, body.contains(""""type":"file""""))
        assertTrue(body, body.contains("""data:$docxMime;base64,ZmFrZQ=="""))
        assertFalse("A native file must not also be injected as text: $body", body.contains("ATTACHMENT_FILE"))
    }

    @Test
    fun nativelyUploadedFilesDoNotCountAgainstTheTextLimits() {
        // 1 native file + 3 text files: the text count is exactly at the limit. If the native file were counted, the 4th would be blocked.
        val msg = makeMsg(
            ProviderKind.OpenAI, "read",
            nativeDocx("n.docx"),
            makeTextAttachment("a", "a.txt"), makeTextAttachment("b", "b.txt"), makeTextAttachment("c", "c.txt"),
        )
        val model = nativeModel()
        for (name in listOf("responses", "anthropic", "gemini")) {
            val body = builders(model).getValue(name)(listOf(msg))
            assertTrue("$name: $body", body.contains("c.txt"))
            assertTrue("$name: the native file should arrive as original bytes: $body", body.contains("ZmFrZQ=="))
        }
    }

    @Test
    fun everyBuilderRejectsTheMessageBeingSentWhenAFileCannotBeDelivered() {
        val msg = makeMsg(
            ProviderKind.OpenAI, "read",
            makeTextAttachment("a", "a.txt"), makeTextAttachment("b", "b.txt"),
            makeTextAttachment("c", "c.txt"), makeTextAttachment("d", "d.txt"),
        )
        for ((name, build) in builders(nativeModel())) {
            try {
                build(listOf(msg))
                fail("$name should block a file that cannot be delivered")
            } catch (error: ai.oriveo.community.core.model.ProviderServiceError.AttachmentCountOverLimit) {
                // Four small files exceed only the count and not the total: what is said is "at most N files".
                assertEquals(name, 3, error.maxFiles)
            }
        }
    }

    @Test
    fun everyBuilderLetsHistoryThroughAndOnlyGuardsTheLastUserMessage() {
        val overLimit = makeMsg(
            ProviderKind.OpenAI, "read",
            makeTextAttachment("a", "a.txt"), makeTextAttachment("b", "b.txt"),
            makeTextAttachment("c", "c.txt"), makeTextAttachment("d", "d.txt"),
        )
        val answer = makeMsg(ProviderKind.OpenAI, "done").copy(id = "m2", role = ChatRole.Assistant, attachments = null)
        val current = makeMsg(ProviderKind.OpenAI, "next").copy(id = "m3", attachments = null)
        for ((name, build) in builders(nativeModel())) {
            val body = build(listOf(overLimit, answer, current))
            assertTrue("$name: $body", body.contains("c.txt"))
            assertFalse("$name: $body", body.contains("d.txt"))
        }
        // When an assistant used for continuation follows the current turn, the guarded one is still the last user message.
        for ((name, build) in builders(nativeModel())) {
            try {
                build(listOf(overLimit, answer))
                fail("$name should block the last user message")
            } catch (_: ai.oriveo.community.core.model.ProviderServiceError.AttachmentCountOverLimit) {
            }
        }
    }

    // ── llama.cpp native: there is only one prompt, and files are delivered as text ──

    @Test
    fun llamaCppNativePromptCarriesAttachedFilesAsText() {
        val options = ai.oriveo.community.core.model.ChatRequestOptions(systemPrompt = "sys")
        val msg = makeMsg(ProviderKind.Relay, "read this", makeTextAttachment("llama file body", "notes.txt"))
        val expected = AttachmentInjector.injectAll(
            userText = "read this",
            attachments = MessageBuilder.toAttachmentPayloads(msg.attachments!!),
            wrapper = ai.oriveo.community.core.attachments.AttachmentWrapperVersion.XmlV1,
        ).text

        val prompt = ai.oriveo.community.core.provider.relay.buildLlamaCppPrompt(listOf(msg), options)
        assertTrue(prompt, prompt.contains("user: $expected"))
        assertTrue(prompt, prompt.contains("llama file body"))

        val body = ai.oriveo.community.core.provider.relay.buildLlamaCppNativeBody(listOf(msg), stream = true, requestOptions = options)
        assertTrue(body, body.contains("notes.txt") && body.contains("llama file body"))
    }

    @Test
    fun llamaCppNativePromptIsUnchangedWithoutFilesAndStillAcceptsFileOnlyMessages() {
        val options = ai.oriveo.community.core.model.ChatRequestOptions(systemPrompt = "sys")
        val plain = makeMsg(ProviderKind.Relay, "  hi  ").copy(attachments = null)
        assertEquals(
            "system: sys\nuser: hi\nassistant:",
            ai.oriveo.community.core.provider.relay.buildLlamaCppPrompt(listOf(plain), options),
        )
        // In the bytes that go out, the segments are separated by JSON newline escapes, which parse back to newline characters, not a literal backslash followed by n.
        val body = ai.oriveo.community.core.provider.relay.buildLlamaCppNativeBody(listOf(plain), stream = true, requestOptions = options)
        assertTrue(body, body.contains("\"prompt\":\"system: sys\\nuser: hi\\nassistant:\""))
        assertEquals(
            "system: sys\nuser: hi\nassistant:",
            kotlinx.serialization.json.Json.parseToJsonElement(body).let {
                (it as kotlinx.serialization.json.JsonObject)["prompt"]!!.let { p -> (p as kotlinx.serialization.json.JsonPrimitive).content }
            },
        )
        // A message with only files and no text used to be skipped entirely.
        val fileOnly = makeMsg(ProviderKind.Relay, "", makeTextAttachment("only body", "only.txt"))
        val prompt = ai.oriveo.community.core.provider.relay.buildLlamaCppPrompt(listOf(fileOnly), options)
        assertTrue(prompt, prompt.contains("user: ") && prompt.contains("only body"))
    }

    /** The prompt is plain text and cannot carry images: leave a one-line placeholder so the model knows an image did not arrive, instead of treating it as nonexistent. */
    @Test
    fun llamaCppNativeTellsTheModelAnImageWasNotDelivered() {
        val options = ai.oriveo.community.core.model.ChatRequestOptions()
        val image = Attachment(id = "img", kind = AttachmentKind.Image, fileName = "p.png", mimeType = "image/png", base64Data = "aW1hZ2U=")
        val placeholder = ai.oriveo.community.core.attachments.AttachmentTransportProfile.LlamaCppNative.imagePlaceholderText!!
        val withText = ai.oriveo.community.core.provider.relay.buildLlamaCppPrompt(
            listOf(makeMsg(ProviderKind.Relay, "what is this", image)), options,
        )
        assertTrue(withText, withText.contains("user: what is this\n\n$placeholder"))
        assertFalse(withText, withText.contains("aW1hZ2U="))
        // A message with only an image used to vanish entirely.
        val imageOnly = ai.oriveo.community.core.provider.relay.buildLlamaCppPrompt(
            listOf(makeMsg(ProviderKind.Relay, "", image)), options,
        )
        assertTrue(imageOnly, imageOnly.contains("user: $placeholder"))
    }

    @Test
    fun imagePlaceholdersAreDeclaredOnTheTextOnlyTransports() {
        assertEquals("[Image omitted: unsupported by DeepSeek]", ai.oriveo.community.core.attachments.AttachmentTransportProfile.DeepSeekChat.imagePlaceholderText)
        // The same literal on all three clients: every new text-only route uses this one sentence.
        assertEquals("[Image omitted: this route sends text only]", ai.oriveo.community.core.attachments.AttachmentTransportProfile.LlamaCppNative.imagePlaceholderText)
        // Routes that can carry images have no placeholder.
        assertNull(ai.oriveo.community.core.attachments.AttachmentTransportProfile.GeminiInteractions.imagePlaceholderText)
        assertNull(ai.oriveo.community.core.attachments.AttachmentTransportProfile.OpenAIResponses.imagePlaceholderText)
        // Removing file blocks does not change how images are sent.
        assertEquals(
            ai.oriveo.community.core.attachments.AttachmentTransportProfile.LlamaCppNative.imagePlaceholderText,
            ai.oriveo.community.core.attachments.AttachmentTransportProfile.LlamaCppNative.withoutNativeFiles().imagePlaceholderText,
        )
        val image = Attachment(id = "img", kind = AttachmentKind.Image, fileName = "p.png", mimeType = "image/png", base64Data = "aW1hZ2U=")
        val deepSeek = MessageBuilder.buildDeepSeekContentForTest(makeMsg(ProviderKind.DeepSeek, "hi", image))
        assertEquals("hi\n\n[Image omitted: unsupported by DeepSeek]", deepSeek)
    }

    @Test
    fun llamaCppNativeRejectsTheMessageBeingSentWhenAFileCannotBeDelivered() {
        val options = ai.oriveo.community.core.model.ChatRequestOptions()
        val big = "x".repeat(150 * 1024)
        val overLimit = makeMsg(ProviderKind.Relay, "read", makeTextAttachment(big, "a.txt"), makeTextAttachment(big, "b.txt"))
        try {
            ai.oriveo.community.core.provider.relay.buildLlamaCppPrompt(listOf(overLimit), options)
            fail("A current turn with a file that does not fit should be blocked")
        } catch (error: ai.oriveo.community.core.model.ProviderServiceError.AttachmentTextOverLimit) {
            assertEquals(listOf("b.txt"), error.fileNames)
        }
        // The same message in history is not blocked: the one that fits is delivered as usual.
        val current = makeMsg(ProviderKind.Relay, "next").copy(id = "m2", attachments = null)
        val prompt = ai.oriveo.community.core.provider.relay.buildLlamaCppPrompt(listOf(overLimit, current), options)
        assertTrue(prompt.contains("a.txt"))
        assertFalse(prompt.contains("b.txt"))
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
