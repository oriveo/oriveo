package ai.oriveo.community.core.provider

import ai.oriveo.community.core.attachments.AttachmentDelivery
import ai.oriveo.community.core.attachments.AttachmentHydrator
import ai.oriveo.community.core.attachments.AttachmentRoute
import ai.oriveo.community.core.attachments.AttachmentRouter
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import java.util.Base64
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.fail
import org.junit.Test

/** The pre-send verdict and the real send reach the same conclusion. */
class AttachmentSendPreflightTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    private val model = AIModel(id = "m", name = "m", capabilities = listOf(ModelCapability.Text))

    private fun textFile(name: String, bytes: Int) = Attachment(
        id = name,
        kind = AttachmentKind.File,
        fileName = name,
        mimeType = "text/plain",
        base64Data = Base64.getEncoder().encodeToString("x".repeat(bytes).toByteArray()),
    )

    private fun pdf(extractedBytes: Int, original: String?) = Attachment(
        id = "pdf",
        kind = AttachmentKind.File,
        fileName = "paper.pdf",
        mimeType = "application/pdf",
        base64Data = Base64.getEncoder().encodeToString("p".repeat(extractedBytes).toByteArray()),
        originalBase64Data = original,
        rawContentRef = "blob-pdf",
    )

    @Test
    fun `preflight raises the very error the production message builder throws`() {
        val provider = Provider(id = "or", kind = ProviderKind.OpenRouter, apiKey = "k")
        val files = listOf(textFile("a.txt", 150 * 1024), textFile("b.txt", 150 * 1024))

        val preflight = AttachmentSendPreflight.undeliverable(provider, model, "read", files)

        val message = ChatMessage(
            id = "u1", role = ChatRole.User, text = "read", providerKind = ProviderKind.OpenRouter,
            providerName = "OpenRouter", modelName = "m", state = ChatMessageState.Delivered, attachments = files,
        )
        try {
            MessageBuilder.buildOpenAIMessages(listOf(message), ProviderKind.OpenRouter, activeModel = model)
            fail("The production builder should block")
        } catch (error: ProviderServiceError.AttachmentTextOverLimit) {
            assertEquals(error, preflight)
        }
    }

    @Test
    fun `a file that may go native on one possible route is never blocked up front`() {
        // Gemini: generateContent uploads the PDF natively without using the text budget; Interactions and the tool loop leg can only send text.
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"gemini":{"resolveMap":{"m":"m"},
               "models":{"m":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true}}}}}""",
        )
        val provider = Provider(id = "g", kind = ProviderKind.Gemini, apiKey = "k")
        val files = listOf(textFile("a.txt", 150 * 1024), pdf(extractedBytes = 150 * 1024, original = null))

        assertNull(AttachmentSendPreflight.undeliverable(provider, model, "read", files))

        // The same two files do not fit on a connection that can only send text.
        val textOnly = Provider(id = "or", kind = ProviderKind.OpenRouter, apiKey = "k")
        assertEquals(
            ProviderServiceError.AttachmentTextOverLimit(listOf("paper.pdf")),
            AttachmentSendPreflight.undeliverable(textOnly, model, "read", files),
        )
    }

    @Test
    fun `the add-time gate only refuses a file that no possible route could fit`() {
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"gemini":{"resolveMap":{"m":"m"},
               "models":{"m":{"nativeFileMimes":["application/pdf"],"pdfNativeDefault":true}}}}}""",
        )
        val existing = listOf(textFile("a.txt", 150 * 1024))
        val incomingPdf = pdf(extractedBytes = 150 * 1024, original = null)
        val incomingText = textFile("b.txt", 150 * 1024)

        // Gemini's generateContent uploads this PDF natively, which does not use the text budget: it must not be refused at add time.
        val gemini = Provider(id = "g", kind = ProviderKind.Gemini, apiKey = "k")
        assertEquals(false, AttachmentSendPreflight.exceedsTextBudgetOnAdd(gemini, model, existing, incomingPdf))
        // A plain text file uses the budget on every route.
        assertEquals(true, AttachmentSendPreflight.exceedsTextBudgetOnAdd(gemini, model, existing, incomingText))

        val textOnly = Provider(id = "or", kind = ProviderKind.OpenRouter, apiKey = "k")
        assertEquals(true, AttachmentSendPreflight.exceedsTextBudgetOnAdd(textOnly, model, existing, incomingPdf))
        assertEquals(false, AttachmentSendPreflight.exceedsTextBudgetOnAdd(textOnly, model, emptyList(), incomingText))
        // The count limit is not this gate's concern (that is a different sentence).
        val many = (1..3).map { textFile("f$it.txt", 8) }
        assertEquals(false, AttachmentSendPreflight.exceedsTextBudgetOnAdd(textOnly, model, many, textFile("g.txt", 8)))
    }

    @Test
    fun `assumed hydration routes exactly like the attachment after real hydration`() = runTest {
        val routerModel = AIModel(
            id = "m", name = "m", capabilities = listOf(ModelCapability.Text),
            nativeFileMimes = listOf("application/pdf"), pdfNativeDefault = true,
        )
        val stored = pdf(extractedBytes = 64, original = null)
        val assumed = AttachmentHydrator.assumeHydratedForRouting(stored)!!
        val hydrated = AttachmentHydrator.hydrateOne(stored, loadImageBase64 = { null }, loadBlobBase64 = { "JVBERi0=" })

        assertEquals(AttachmentRoute.Native, AttachmentRouter.decide(hydrated, ProviderKind.Gemini, routerModel))
        assertEquals(
            AttachmentRouter.decide(hydrated, ProviderKind.Gemini, routerModel),
            AttachmentRouter.decide(assumed, ProviderKind.Gemini, routerModel),
        )
        // The content used for text injection is unaffected by the placeholder.
        assertEquals(
            AttachmentDelivery.toAttachmentPayloads(listOf(hydrated)),
            AttachmentDelivery.toAttachmentPayloads(listOf(assumed)),
        )

        // A complete attachment is returned as is; one without even extracted text cannot be judged.
        val complete = pdf(extractedBytes = 64, original = "JVBERi0=")
        assertSame(complete, AttachmentHydrator.assumeHydratedForRouting(complete))
        assertNull(AttachmentHydrator.assumeHydratedForRouting(stored.copy(base64Data = null)))
        val inline = textFile("a.txt", 8)
        assertSame(inline, AttachmentHydrator.assumeHydratedForRouting(inline))
    }
}
