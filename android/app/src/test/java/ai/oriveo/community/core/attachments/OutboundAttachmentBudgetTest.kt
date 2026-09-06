package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class OutboundAttachmentBudgetTest {

    private val oneMb = 1024L * 1024L

    private fun image(id: String, localImageId: String = "img-$id") = Attachment(
        id = id,
        kind = AttachmentKind.Image,
        fileName = "$id.jpg",
        mimeType = "image/jpeg",
        localImageId = localImageId,
    )

    private fun pdf(id: String, extractedText: String? = "ZXh0cmFjdGVk") = Attachment(
        id = id,
        kind = AttachmentKind.File,
        fileName = "$id.pdf",
        mimeType = "application/pdf",
        base64Data = extractedText,
        rawContentRef = "blob-$id",
    )

    private fun message(
        id: String,
        role: ChatRole,
        text: String,
        attachments: List<Attachment>?,
    ) = ChatMessage(
        id = id,
        role = role,
        text = text,
        providerKind = ProviderKind.OpenAI,
        providerName = "OpenAI",
        modelName = "gpt-test",
        state = ChatMessageState.Delivered,
        attachments = attachments,
    )

    private fun user(text: String, vararg attachments: Attachment) =
        message("u-$text", ChatRole.User, text, attachments.toList().takeIf { it.isNotEmpty() })

    private fun assistant(text: String) =
        message("a-$text", ChatRole.Assistant, text, null)

    private suspend fun apply(
        messages: List<ChatMessage>,
        budgetBytes: Long,
        sizeBytes: Long = 3 * 1024 * 1024,
    ) = OutboundAttachmentBudget.apply(
        messages = messages,
        budgetBytes = budgetBytes,
        imageSizeOf = { sizeBytes },
        blobSizeOf = { sizeBytes },
    )

    @Test
    fun `messages without attachments are returned untouched`() = runTest {
        val messages = listOf(user("hi"), assistant("hello"))

        val out = apply(messages, budgetBytes = 0)

        assertSame(messages, out)
    }

    @Test
    fun `current turn attachments survive even when they alone blow the budget`() = runTest {
        val messages = listOf(user("look at this", image("a")))

        val out = apply(messages, budgetBytes = 1, sizeBytes = 25 * oneMb)

        assertEquals(listOf(image("a")), out[0].attachments)
        assertEquals("look at this", out[0].text)
    }

    @Test
    fun `history images beyond the budget become placeholders`() = runTest {

        val messages = listOf(
            user("first", image("old")),
            assistant("ok"),
            user("second", image("recent")),
            assistant("ok"),
            user("third"),
        )

        val out = apply(messages, budgetBytes = 4 * oneMb, sizeBytes = 3 * oneMb)

        assertEquals(listOf(image("recent")), out[2].attachments)

        assertNull(out[0].attachments)
        assertTrue(out[0].text.startsWith("first"))
        assertTrue(out[0].text.contains("[Image omitted: old.jpg"))
    }

    @Test
    fun `history files keep extracted text and drop only the raw bytes`() = runTest {
        val messages = listOf(
            user("read this", pdf("report")),
            assistant("ok"),
            user("and now this?"),
        )

        val out = apply(messages, budgetBytes = 0, sizeBytes = 25 * oneMb)

        val kept = out[0].attachments!!.single()
        assertEquals("ZXh0cmFjdGVk", kept.base64Data)
        assertNull(kept.rawContentRef)
        assertNull(kept.originalBase64Data)

        assertEquals("read this", out[0].text)
    }

    @Test
    fun `history files without extracted text are dropped with a placeholder`() = runTest {
        val messages = listOf(
            user("binary blob", pdf("scan", extractedText = null)),
            assistant("ok"),
            user("next"),
        )

        val out = apply(messages, budgetBytes = 0, sizeBytes = 25 * oneMb)

        assertNull(out[0].attachments)
        assertTrue(out[0].text.contains("[File omitted: scan.pdf"))
    }

    @Test
    fun `scanned pdf empty-string marker is not mistaken for usable text`() = runTest {

        val messages = listOf(
            user("scanned", pdf("scanned", extractedText = "")),
            assistant("ok"),
            user("next"),
        )

        val out = apply(messages, budgetBytes = 0, sizeBytes = 25 * oneMb)

        assertNull(out[0].attachments)
        assertTrue(out[0].text.contains("[File omitted: scanned.pdf"))
    }

    @Test
    fun `dropping an image-only message leaves the placeholder as its text`() = runTest {
        val messages = listOf(
            user("", image("lonely")),
            assistant("ok"),
            user("follow up"),
        )

        val out = apply(messages, budgetBytes = 0, sizeBytes = oneMb)

        assertNull(out[0].attachments)
        assertTrue(out[0].text.contains("[Image omitted: lonely.jpg"))
    }

    @Test
    fun `already inlined image base64 costs nothing extra from disk`() = runTest {
        val inlined = image("cached").copy(base64Data = "AAAA")
        val messages = listOf(
            user("older", inlined),
            assistant("ok"),
            user("newer"),
        )

        val out = apply(messages, budgetBytes = 1024, sizeBytes = 25 * oneMb)

        assertEquals(listOf(inlined), out[0].attachments)
    }
}
