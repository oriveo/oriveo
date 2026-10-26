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
import ai.oriveo.community.testing.BundledAttachmentSupportFixture
import io.ktor.client.engine.mock.respond
import kotlinx.coroutines.flow.toList
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class MessageBuilderAttachmentTest {

    // Attachment support of official providers comes only from metadata; after a case that injected any, the MetadataClient.instance table is cleared.
    @After
    fun clearInjectedMetadata() = BundledAttachmentSupportFixture.clear()

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
        // textFileInline=true no longer depends on the model's declared capabilities; text inlining is not gated by file_input.
        BundledAttachmentSupportFixture.install("deepseek")
        val gate = ai.oriveo.community.feature.chat.ChatModelCapabilityResolver(
            metadata = BundledAttachmentSupportFixture.bundledMetadataClient(),
        ).attachmentInputGate(
            ai.oriveo.community.core.model.Provider(id = "deepseek", kind = ProviderKind.DeepSeek),
            ai.oriveo.community.core.model.AIModel(id = "deepseek-v4-pro", name = "DeepSeek V4 Pro"),
        )
        assertFalse("bundled file_input=unavailable, so native files cannot be attached", gate.nativeFile)
        assertTrue("DeepSeek with textFileInline=true must accept files", gate.file)
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
        // Routes that only send text: llama.cpp native and Gemini Interactions.
        listOf(
            ai.oriveo.community.core.attachments.AttachmentTransportProfile.LlamaCppNative,
            ai.oriveo.community.core.attachments.AttachmentTransportProfile.GeminiInteractions,
        ).forEach { assertFalse("$it", it.sendsImages) }
        // DeepSeek / MiniMax no longer write a placeholder for the whole route: whether an image is sent follows the vision projection, and the placeholder text is only used when the projection says placeholder.
        listOf(
            ai.oriveo.community.core.attachments.AttachmentTransportProfile.DeepSeekChat,
            ai.oriveo.community.core.attachments.AttachmentTransportProfile.ChatCompletions(ProviderKind.MiniMax),
            ai.oriveo.community.core.attachments.AttachmentTransportProfile.MiniMaxAnthropicMessages,
        ).forEach { assertTrue("$it", it.sendsImages) }
        assertEquals("[Image omitted: unsupported by DeepSeek]", ai.oriveo.community.core.attachments.AttachmentTransportProfile.DeepSeekChat.imagePlaceholderText)
        // The same literal on all three clients: every new text-only route uses this one sentence.
        assertEquals("[Image omitted: this route sends text only]", ai.oriveo.community.core.attachments.AttachmentTransportProfile.LlamaCppNative.imagePlaceholderText)
        assertEquals("[Image omitted: this route sends text only]", ai.oriveo.community.core.attachments.AttachmentTransportProfile.GeminiInteractions.imagePlaceholderText)
        // Routes that can carry images have no placeholder.
        assertNull(ai.oriveo.community.core.attachments.AttachmentTransportProfile.OpenAIResponses.imagePlaceholderText)
        // Removing file blocks does not change how images are sent.
        assertEquals(
            ai.oriveo.community.core.attachments.AttachmentTransportProfile.LlamaCppNative.imagePlaceholderText,
            ai.oriveo.community.core.attachments.AttachmentTransportProfile.LlamaCppNative.withoutNativeFiles().imagePlaceholderText,
        )
        // The DeepSeek body no longer hard-codes an image placeholder: the outbound gate decides whether the image stays.
        val image = Attachment(id = "img", kind = AttachmentKind.Image, fileName = "p.png", mimeType = "image/png", base64Data = "aW1hZ2U=")
        val deepSeek = MessageBuilder.buildDeepSeekContentForTest(makeMsg(ProviderKind.DeepSeek, "hi", image))
        assertEquals("hi", deepSeek)
    }

    // -- DeepSeek official outbound follows the vision projection --

    private val deepSeekImage = Attachment(id = "img", kind = AttachmentKind.Image, fileName = "p.png", mimeType = "image/png", base64Data = "aW1hZ2U=")

    /** Official DeepSeek metadata: one openai_chat model, with the vision verdict given by parameter. */
    private fun deepSeekVisionMetadata(model: String, visionControl: String) =
        """{"version":1,"providers":{"${ProviderKind.DeepSeek.rawValue}":{"resolveMap":{"$model":"$model"},"models":{"$model":""" +
            """{"canonicalModelId":"$model","transport":"openai_chat","capabilityControls":{"vision_input":$visionControl}}}}}}"""

    /** Sends one streaming request through the production DeepSeekService and returns the messages of the request body. */
    private suspend fun deepSeekSentMessages(model: String, message: ChatMessage): kotlinx.serialization.json.JsonArray {
        var captured: String? = null
        val client = io.ktor.client.HttpClient(io.ktor.client.engine.mock.MockEngine { request ->
            if (captured == null) captured = (request.body as io.ktor.http.content.TextContent).text
            respond(
                "data: [DONE]\n\n", io.ktor.http.HttpStatusCode.OK,
                io.ktor.http.headersOf(io.ktor.http.HttpHeaders.ContentType, "text/event-stream"),
            )
        })
        runCatching {
            DeepSeekService(client, kotlinx.serialization.json.Json { ignoreUnknownKeys = true }).sendMessageStream(
                "key", model, listOf(message), null, false,
                ai.oriveo.community.core.model.ReasoningMode.Automatic, false, ai.oriveo.community.core.model.ChatRequestOptions(),
            ).toList()
        }
        client.close()
        val body = kotlinx.serialization.json.Json.parseToJsonElement(requireNotNull(captured) { "DeepSeek did not issue a request" })
        return (body as kotlinx.serialization.json.JsonObject)["messages"] as kotlinx.serialization.json.JsonArray
    }

    @Test
    fun deepseekFlashSendsTheImageAsAnImageUrlDataUrl() = kotlinx.coroutines.test.runTest {
        MetadataTestFixtures.applyRaw(deepSeekVisionMetadata("deepseek-flash", """{"state":"auto_available","wireFamily":"openai_chat.image_url"}"""))
        try {
            val messages = deepSeekSentMessages("deepseek-flash", makeMsg(ProviderKind.DeepSeek, "what is this", deepSeekImage))
            val body = messages.toString()
            assertTrue(body, body.contains(""""image_url":{"url":"data:image/""") && body.contains("aW1hZ2U="))
            assertFalse(body, body.contains("[Image omitted"))
        } finally {
            MetadataTestFixtures.clear()
        }
    }

    @Test
    fun deepseekV4ProWritesThePlaceholderAfterTheTextAndFileBlocks() = kotlinx.coroutines.test.runTest {
        MetadataTestFixtures.applyRaw(
            deepSeekVisionMetadata(
                "deepseek-v4-pro",
                """{"state":"unavailable","reasonCode":"model_capability_absent","wireFamily":"openai_chat.image_url"}""",
            ),
        )
        try {
            val original = makeMsg(ProviderKind.DeepSeek, "Read this", makeTextAttachment("file body", "notes.txt"), deepSeekImage)
            val messages = deepSeekSentMessages("deepseek-v4-pro", original)
            val content = (messages.last() as kotlinx.serialization.json.JsonObject)["content"]
            val text = (content as kotlinx.serialization.json.JsonPrimitive).content
            val placeholder = ai.oriveo.community.core.attachments.AttachmentTransportProfile.DeepSeekChat.imagePlaceholderText!!
            val bodyAt = text.indexOf("Read this")
            val fileAt = text.indexOf("file body")
            val placeholderAt = text.indexOf(placeholder)
            assertTrue(text, bodyAt == 0 && fileAt > bodyAt && placeholderAt > fileAt)
            // A blank line between the body / file blocks and the placeholder, same as the video placeholder main path and on iOS / desktop / Web.
            assertTrue(text, text.endsWith("\n\n$placeholder") && !text.endsWith("\n\n\n$placeholder"))
            assertFalse(messages.toString(), messages.toString().contains("image_url") || messages.toString().contains("aW1hZ2U="))
            // The original local message is unchanged.
            assertEquals("Read this", original.text)
            assertEquals(2, original.attachments!!.size)
        } finally {
            MetadataTestFixtures.clear()
        }
    }

    /**
     * Resending history: after the outbound gate swaps images / videos for placeholders, the body and each placeholder are always separated by "\n\n";
     * when the next turn sends it as history again it is split back by the same separator and joined as-is, without stacking into "\n" or extra blank lines.
     */
    @Test
    fun historyResendKeepsBlankLineBetweenTextAndEveryCarriedPlaceholder() = kotlinx.coroutines.test.runTest {
        MetadataTestFixtures.applyRaw(
            deepSeekVisionMetadata(
                "deepseek-v4-pro",
                """{"state":"unavailable","reasonCode":"model_capability_absent","wireFamily":"openai_chat.image_url"}""",
            ),
        )
        try {
            val model = ai.oriveo.community.core.model.AIModel(
                id = "deepseek-v4-pro",
                name = "DeepSeek V4 Pro",
                capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.Text),
            )
            val inputs = requireNotNull(
                ai.oriveo.community.core.capability.truth.resolveInputCapabilityProjections(
                    ai.oriveo.community.core.model.Provider(id = "official-deepseek", kind = ProviderKind.DeepSeek),
                    model,
                ),
            )
            val placeholder = routeImagePlaceholder(ProviderKind.DeepSeek.rawValue)
            val original = makeMsg(ProviderKind.DeepSeek, "Look", deepSeekImage, deepSeekImage.copy(id = "img-2"))
            val history = messagesForInputOutbound(listOf(original), inputs, placeholder).single()
            assertEquals("Look\n\n$placeholder\n\n$placeholder", history.text)
            assertEquals("Look" to listOf(placeholder, placeholder), MessageBuilder.splitOutboundPlaceholders(history))

            val current = makeMsg(ProviderKind.DeepSeek, "next").copy(id = "m2", attachments = null)
            val body = MessageBuilder.buildDeepSeekMessages(listOf(history, current), activeModel = model)
            val messages = kotlinx.serialization.json.Json.parseToJsonElement("[$body]") as kotlinx.serialization.json.JsonArray
            val resent = ((messages.first() as kotlinx.serialization.json.JsonObject)["content"] as kotlinx.serialization.json.JsonPrimitive).content
            assertEquals("Look\n\n$placeholder\n\n$placeholder", resent)
            // When the body is empty only placeholders remain, still separated by a blank line.
            val imageOnly = messagesForInputOutbound(listOf(makeMsg(ProviderKind.DeepSeek, "", deepSeekImage)), inputs, placeholder).single()
            assertEquals(placeholder, imageOnly.text)
            assertEquals("" to listOf(placeholder), MessageBuilder.splitOutboundPlaceholders(imageOnly))
        } finally {
            MetadataTestFixtures.clear()
        }
    }

    /** Official metadata: deepseek-v4-pro hangs under [kind] and uses [transport], with vision unavailable and native files allowed. */
    private fun placeholderAndPdfMetadata(kind: ProviderKind, transport: String, fileWire: String) =
        """{"version":1,"providers":{"${kind.rawValue}":{"resolveMap":{"deepseek-v4-pro":"deepseek-v4-pro"},"models":{"deepseek-v4-pro":""" +
            """{"canonicalModelId":"deepseek-v4-pro","transport":"$transport","capabilityControls":{""" +
            """"vision_input":{"state":"unavailable","reasonCode":"model_capability_absent"},""" +
            """"file_input":{"state":"auto_available","wireFamily":"$fileWire"}}}}}}}"""

    /**
     * One turn with two images + one native PDF where vision resolves to placeholder: after the production outbound gate the part order of all four protocols is [body text, file block, placeholder text],
     * and the placeholder text joins two lines with "\n\n" (same as iOS / desktop / Web); the original local message is unchanged.
     */
    @Test
    fun placeholderIsOneTrailingTextPartAfterTheFileBlockOnEveryProtocol() {
        data class Case(
            val name: String,
            val kind: ProviderKind,
            val transport: String,
            val fileWire: String,
            val build: (List<ChatMessage>, ai.oriveo.community.core.model.AIModel) -> String,
            val parts: (kotlinx.serialization.json.JsonArray) -> kotlinx.serialization.json.JsonArray,
            val textOf: (kotlinx.serialization.json.JsonObject) -> String?,
            val fileTag: (kotlinx.serialization.json.JsonObject) -> Boolean,
        )
        fun obj(e: kotlinx.serialization.json.JsonElement) = e as kotlinx.serialization.json.JsonObject
        fun str(o: kotlinx.serialization.json.JsonObject, k: String) = (o[k] as? kotlinx.serialization.json.JsonPrimitive)?.content
        val lastContent = { arr: kotlinx.serialization.json.JsonArray -> obj(arr.last())["content"] as kotlinx.serialization.json.JsonArray }
        val cases = listOf(
            Case("openai chat", ProviderKind.OpenRouter, "openai_chat", "openai_chat.file",
                { m, model -> MessageBuilder.buildOpenAIMessages(m, ProviderKind.OpenRouter, activeModel = model) }, lastContent,
                { o -> if (str(o, "type") == "text") str(o, "text") else null }, { o -> str(o, "type") == "file" }),
            Case("responses", ProviderKind.OpenAI, "openai_responses", "openai_responses.input_file",
                { m, model -> MessageBuilder.buildOpenAIResponsesInput(m, model) }, lastContent,
                { o -> if (str(o, "type") == "input_text") str(o, "text") else null }, { o -> str(o, "type") == "input_file" }),
            Case("anthropic", ProviderKind.Anthropic, "anthropic_messages", "anthropic.document",
                { m, model -> MessageBuilder.buildAnthropicMessages(m, model) }, lastContent,
                { o -> if (str(o, "type") == "text") str(o, "text") else null }, { o -> str(o, "type") == "document" }),
            Case("gemini", ProviderKind.Gemini, "gemini_generate_content", "gemini.inline_data",
                { m, model -> MessageBuilder.buildGeminiContents(m, model) },
                { arr -> obj(arr.last())["parts"] as kotlinx.serialization.json.JsonArray },
                { o -> str(o, "text") }, { o -> o["inlineData"] != null }),
        )
        val model = ai.oriveo.community.core.model.AIModel(
            id = "deepseek-v4-pro",
            name = "DeepSeek V4 Pro",
            capabilities = listOf(ai.oriveo.community.core.model.ModelCapability.Text),
            nativeFileMimes = listOf(pdfMime),
            pdfNativeDefault = true,
        )
        for (case in cases) {
            MetadataTestFixtures.applyRaw(placeholderAndPdfMetadata(case.kind, case.transport, case.fileWire))
            try {
                val original = makeMsg(case.kind, "Read this", deepSeekImage, deepSeekImage.copy(id = "img-2"), textPdf())
                val inputs = requireNotNull(
                    ai.oriveo.community.core.capability.truth.resolveInputCapabilityProjections(
                        ai.oriveo.community.core.model.Provider(id = "official-${case.kind.rawValue}", kind = case.kind),
                        model,
                    ),
                ) { case.name }
                val placeholder = routeImagePlaceholder(case.kind.rawValue)
                val gated = messagesForInputOutbound(listOf(original), inputs, placeholder)
                val body = case.build(gated, model)
                val parts = case.parts(kotlinx.serialization.json.Json.parseToJsonElement("[$body]") as kotlinx.serialization.json.JsonArray)
                    .map { obj(it) }
                assertEquals("${case.name}: $body", 3, parts.size)
                assertTrue("${case.name}: $body", case.textOf(parts[0])!!.startsWith("Read this"))
                assertFalse("${case.name}: $body", case.textOf(parts[0])!!.contains(placeholder))
                assertTrue("${case.name}: $body", case.fileTag(parts[1]))
                assertEquals("${case.name}: $body", "$placeholder\n\n$placeholder", case.textOf(parts[2]))
                assertFalse("${case.name}: $body", body.contains("aW1hZ2U="))
                // The original local message is unchanged.
                assertEquals("Read this", original.text)
                assertEquals(3, original.attachments!!.size)
            } finally {
                MetadataTestFixtures.clear()
            }
        }
    }

    /** Older Android compressed PNG screenshots to JPEG yet still labeled them image/png; Anthropic validates bytes against media_type, so a wrong label is a straight 400. */
    @Test
    fun imageMimeSentUpstreamFollowsTheBytesNotTheLabel() {
        val jpegBase64 = Base64.getEncoder().encodeToString(
            byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte()) + ByteArray(32),
        )
        val image = Attachment(id = "img", kind = AttachmentKind.Image, fileName = "shot.png", mimeType = "image/png", base64Data = jpegBase64)
        val messages = listOf(makeMsg(ProviderKind.Anthropic, "what is this", image))
        for ((name, build) in builders(null).filterKeys { it in setOf("chat completions", "responses", "anthropic", "gemini") }) {
            val body = build(messages)
            assertTrue("$name: $body", body.contains(jpegBase64))
            assertTrue("$name: $body", body.contains("image/jpeg"))
            assertFalse("$name: $body", body.contains("image/png"))
        }
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
