package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentExtractionLimits
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class AttachmentDeliveryTest {

    private val docxMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    private fun textFile(name: String, content: String) = Attachment(
        id = name,
        kind = AttachmentKind.File,
        fileName = name,
        mimeType = "text/plain",
        base64Data = Base64.getEncoder().encodeToString(content.toByteArray()),
    )

    /** A docx that meets every precondition of AttachmentRouter for native upload, while also carrying extracted text that can be injected. */
    private fun nativeCapableDocx(name: String = "report.docx") = Attachment(
        id = name,
        kind = AttachmentKind.File,
        fileName = name,
        mimeType = docxMime,
        base64Data = Base64.getEncoder().encodeToString("extracted body".toByteArray()),
        extractedSizeBytes = 5_000,
        originalBase64Data = "ZmFrZQ==",
    )

    private fun model(
        nativeFileMimes: List<String> = listOf(docxMime),
        attachmentExtraction: AttachmentExtractionLimits? = null,
    ) = AIModel(
        id = "m",
        name = "m",
        capabilities = listOf(ModelCapability.Text, ModelCapability.File),
        nativeFileMimes = nativeFileMimes,
        attachmentExtraction = attachmentExtraction,
    )

    private fun plan(
        attachments: List<Attachment>,
        model: AIModel?,
        allowNative: Boolean,
        baseText: String = "question",
        wrapper: AttachmentWrapperVersion = AttachmentWrapperVersion.XmlV1,
    ) = AttachmentDelivery.plan(
        baseText = baseText,
        attachments = attachments,
        model = model,
        transport = when {
            allowNative -> AttachmentTransportProfile.OpenAIResponses.also { assertEquals(wrapper, it.wrapper) }
            // Pick one route without native blocks for each of the two wrapper formats.
            wrapper == AttachmentWrapperVersion.MarkdownV1 -> AttachmentTransportProfile.DeepSeekChat
            else -> AttachmentTransportProfile.ChatCompletions(ProviderKind.OpenAI)
        },
    )

    @Test
    fun `relay and subscription transports route exactly like the direct ones until told to drop file blocks`() {
        val pdfMime = "application/pdf"
        val pdfModel = model(nativeFileMimes = listOf(pdfMime, docxMime)).copy(pdfNativeDefault = true)
        fun pdf(name: String, errorCode: String? = null) = Attachment(
            id = name, kind = AttachmentKind.File, fileName = name, mimeType = pdfMime,
            base64Data = if (errorCode == null) java.util.Base64.getEncoder().encodeToString("body".toByteArray()) else "",
            extractedSizeBytes = 5_000, originalBase64Data = "ZmFrZQ==", extractionErrorCode = errorCode,
        )
        val files = listOf(pdf("text.pdf"), pdf("scan.pdf", "scanned_pdf"), nativeCapableDocx())
        val direct = AttachmentDelivery.plan("q", files, pdfModel, AttachmentTransportProfile.GeminiGenerateContent)
        assertEquals(3, direct.native.size)
        for (transport in listOf(
            AttachmentTransportProfile.SubscriptionResponses,
            AttachmentTransportProfile.RelayOpenAIResponses,
            AttachmentTransportProfile.RelayAnthropicMessages,
            AttachmentTransportProfile.RelayGeminiGenerateContent,
        )) {
            val plan = AttachmentDelivery.plan("q", files, pdfModel, transport)
            assertEquals(transport.toString(), direct.items.map { it.route }, plan.items.map { it.route })
            // Fallback resend: the same route without file blocks, everything delivered as text.
            val textOnly = AttachmentDelivery.plan("q", files, pdfModel, transport.withoutNativeFiles())
            assertEquals(transport.toString(), emptyList<Attachment>(), textOnly.native)
            assertEquals(transport.toString(), 3, textOnly.items.count { it.route == AttachmentDelivery.Route.Text })
        }
    }

    @Test
    fun `a native-capable model still gets text when the request path cannot carry raw files`() {
        val docx = nativeCapableDocx()
        // Precondition: the same attachment and the same model really go native on a path that allows it; otherwise the assertions below prove nothing.
        assertEquals(
            listOf(AttachmentDelivery.Route.Native),
            plan(listOf(docx), model(), allowNative = true).items.map { it.route },
        )

        val result = plan(listOf(docx), model(), allowNative = false)

        assertEquals(listOf(AttachmentDelivery.Route.Text), result.items.map { it.route })
        assertTrue(result.native.isEmpty())
        assertTrue(result.text, result.text.contains("extracted body"))
    }

    @Test
    fun `without a model every file is delivered as text`() {
        val result = plan(listOf(nativeCapableDocx(), textFile("a.txt", "alpha")), model = null, allowNative = true)

        assertEquals(
            listOf(AttachmentDelivery.Route.Text, AttachmentDelivery.Route.Text),
            result.items.map { it.route },
        )
        assertTrue(result.native.isEmpty())
        assertTrue(result.skipped.isEmpty())
    }

    @Test
    fun `a file that pushes the text past the total cap is skipped with the cap as the reason`() {
        val half = "x".repeat(FileExtractionLimits.DEFAULT.totalCap / 2 + 1)
        val first = textFile("first.txt", half)
        val second = textFile("second.txt", half)

        val result = plan(listOf(first, second), model = null, allowNative = false)

        assertEquals(
            listOf(AttachmentDelivery.Route.Text, AttachmentDelivery.Route.Skipped),
            result.items.map { it.route },
        )
        assertNull(result.items[0].skipReason)
        assertEquals(AttachmentInjector.SkipReason.TotalCapExceeded, result.items[1].skipReason)
        assertEquals(listOf(second), result.skipped.map { it.attachment })
    }

    @Test
    fun `files past the count limit are skipped with the count as the reason`() {
        val files = (1..4).map { textFile("f$it.txt", "body $it") }

        val result = plan(files, model = null, allowNative = false)

        assertEquals(listOf(files[3]), result.skipped.map { it.attachment })
        assertEquals(AttachmentInjector.SkipReason.TooManyFiles, result.skipped.single().skipReason)
    }

    @Test
    fun `a skipped file is attributed to the right attachment when two files share a name`() {
        val small = textFile("same.txt", "tiny").copy(id = "small")
        val huge = textFile("same.txt", "x".repeat(FileExtractionLimits.DEFAULT.totalCap)).copy(id = "huge")

        val result = plan(listOf(small, huge), model = null, allowNative = false)

        assertEquals(listOf("huge"), result.skipped.map { it.attachment.id })
    }

    @Test
    fun `natively uploaded files do not count against the text limits`() {
        val files = listOf(
            nativeCapableDocx("n.docx"),
            textFile("a.txt", "a"),
            textFile("b.txt", "b"),
            textFile("c.txt", "c"),
        )

        val result = plan(files, model(), allowNative = true)

        assertEquals(listOf(files[0]), result.native)
        assertTrue(result.skipped.isEmpty())
    }

    @Test
    fun `the model's total cap override decides what is skipped`() {
        val files = listOf(textFile("a.txt", "12345678"), textFile("b.txt", "12345678"))
        val tight = model(attachmentExtraction = AttachmentExtractionLimits(totalCap = 10))

        val result = plan(files, tight, allowNative = false)

        assertEquals(listOf(files[1]), result.skipped.map { it.attachment })
    }

    /** Count and total both over the limit: each says its own thing, and the text line names only the files that do not fit the total. */
    @Test
    fun `count and text limits exceeded together are both reported and only the oversized files are named`() {
        val files = listOf(
            textFile("a.txt", "a"),
            textFile("big.txt", "x".repeat(FileExtractionLimits.DEFAULT.totalCap)),
            textFile("c.txt", "c"),
            textFile("d.txt", "d"),
            textFile("e.txt", "e"),
        )
        val result = plan(files, model(), allowNative = false)
        assertEquals(
            listOf(AttachmentInjector.SkipReason.TotalCapExceeded, AttachmentInjector.SkipReason.TooManyFiles),
            result.skipped.map { it.skipReason },
        )
        assertEquals(
            ProviderServiceError.AttachmentTextOverLimit(
                fileNames = listOf("big.txt"),
                countLimit = FileExtractionLimits.DEFAULT.maxFiles,
            ),
            AttachmentDelivery.undeliverable(result),
        )
    }

    @Test
    fun `the planned text is byte-identical to calling the injector directly`() {
        val files = listOf(
            textFile("a.md", "# title\nbody"),
            Attachment(
                id = "scan",
                kind = AttachmentKind.File,
                fileName = "scan.pdf",
                mimeType = "application/pdf",
                base64Data = "",
                extractionErrorCode = "scanned_pdf",
            ),
            textFile("c.txt", "x".repeat(FileExtractionLimits.DEFAULT.totalCap)),
            textFile("d.txt", "tail"),
        )
        val image = Attachment(id = "img", kind = AttachmentKind.Image, fileName = "p.png", mimeType = "image/png")

        for (wrapper in AttachmentWrapperVersion.entries) {
            val expected = AttachmentInjector.injectAll(
                userText = "question",
                attachments = AttachmentDelivery.toAttachmentPayloads(files),
                limits = FileExtractionLimits.DEFAULT,
                wrapper = wrapper,
            )
            val result = plan(files + image, model = null, allowNative = false, wrapper = wrapper)

            assertEquals(expected.text, result.text)
            assertEquals(expected.skipped.map { it.fileName }, result.skipped.map { it.attachment.fileName })
            assertTrue("Images are not part of the file delivery verdict", result.items.none { it.attachment.id == "img" })
        }
    }

    @Test
    fun `a current turn blocked only by the file count reports the count limit`() {
        val result = plan((1..5).map { textFile("f$it.txt", "body $it") }, model = null, allowNative = false)

        try {
            AttachmentDelivery.requireDeliverable(result, isCurrentTurn = true)
            org.junit.Assert.fail("A current turn over the count limit should be blocked")
        } catch (error: ProviderServiceError.AttachmentCountOverLimit) {
            assertEquals(FileExtractionLimits.DEFAULT.maxFiles, error.maxFiles)
        }
        // History messages are not blocked.
        AttachmentDelivery.requireDeliverable(result, isCurrentTurn = false)
    }

    @Test
    fun `a current turn over both limits is stopped naming only the files the text budget kept out`() {
        val files = listOf(
            textFile("a.txt", "alpha"),
            textFile("huge.txt", "x".repeat(FileExtractionLimits.DEFAULT.totalCap + 1)),
            textFile("c.txt", "gamma"),
            textFile("d.txt", "delta"),
            textFile("e.txt", "epsilon"),
        )
        val result = plan(files, model = null, allowNative = false)
        assertEquals(
            listOf(AttachmentInjector.SkipReason.TotalCapExceeded, AttachmentInjector.SkipReason.TooManyFiles),
            result.skipped.map { it.skipReason },
        )

        try {
            AttachmentDelivery.requireDeliverable(result, isCurrentTurn = true)
            org.junit.Assert.fail("A current turn over the total limit should be blocked")
        } catch (error: ProviderServiceError.AttachmentTextOverLimit) {
            // e.txt was turned away by the count limit and is covered by the other "at most N files" line.
            assertEquals(listOf("huge.txt"), error.fileNames)
            assertEquals(FileExtractionLimits.DEFAULT.maxFiles, error.countLimit)
        }
    }
}
