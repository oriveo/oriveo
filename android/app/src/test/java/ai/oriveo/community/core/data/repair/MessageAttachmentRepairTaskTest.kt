package ai.oriveo.community.core.data.repair

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.dao.MessageDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.OversizedAttachmentsJsonRow
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.Base64
/**
 * Tests for repairing legacy rows that previously hit SQLiteBlobTooBigException.
 *
 * MessageDao/PreferenceDao are plain interfaces, and AttachmentStore is a concrete class that
 * mockk can mock directly (precedent: BackupServiceTest.kt), so this whole test runs as a plain
 * JVM unit test with no need for Robolectric or a real Room instance.
 */
class MessageAttachmentRepairTaskTest {
    private val accountId = "test-account"

    private val messageDao = mockk<MessageDao>()
    private val preferenceDao = mockk<PreferenceDao>()
    private val attachmentStore = mockk<AttachmentStore>()
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    private lateinit var task: MessageAttachmentRepairTask

    @Before
    fun setUp() {
        task = MessageAttachmentRepairTask(messageDao, preferenceDao, attachmentStore)
        // The inline-image text repair is a separate pass; attachment-repair cases assume it is done, text cases override this
        coEvery { preferenceDao.get(MessageAttachmentRepairTask.TEXT_PREF_KEY) } returns MessageAttachmentRepairTask.PREF_DONE_VALUE
    }

    private fun b64(text: String) = Base64.getEncoder().encodeToString(text.toByteArray())

    @Test
    fun `runIfNeeded skips entirely when already marked done`() = runTest {
        coEvery { preferenceDao.get(MessageAttachmentRepairTask.PREF_KEY) } returns MessageAttachmentRepairTask.PREF_DONE_VALUE

        task.runIfNeeded()

        coVerify(exactly = 0) { messageDao.findOversizedAttachmentsJsonRows(any()) }
    }

    @Test
    fun `runIfNeeded repairs oversized row and marks done`() = runTest {
        val attachment = Attachment(
            id = "att-1",
            kind = AttachmentKind.Image,
            fileName = "photo.jpg",
            mimeType = "image/jpeg",
            base64Data = b64("fake-image-bytes"),
            localImageId = "local-1",
        )
        val rawJson = json.encodeToString(listOf(attachment))

        coEvery { preferenceDao.get(MessageAttachmentRepairTask.PREF_KEY) } returns null
        coEvery {
            messageDao.findOversizedAttachmentsJsonRows(MessageAttachmentRepairTask.ATTACHMENTS_THRESHOLD_CHARS)
        } returns listOf(OversizedAttachmentsJsonRow(id = "msg-1", accountId = accountId, len = rawJson.length))
        coEvery { messageDao.readAttachmentsJsonChunk(accountId, "msg-1", 1, any()) } returns rawJson
        val updatedSlot = slot<String>()
        coEvery { messageDao.updateAttachmentsJson(accountId, "msg-1", capture(updatedSlot)) } returns 1
        coEvery { preferenceDao.set(PreferenceEntity(MessageAttachmentRepairTask.PREF_KEY, MessageAttachmentRepairTask.PREF_DONE_VALUE)) } returns Unit

        task.runIfNeeded()

        val repaired = json.decodeFromString<List<Attachment>>(updatedSlot.captured!!)
        assertEquals(1, repaired.size)
        assertNull("an image attachment that already has localImageId should no longer carry base64Data after repair", repaired[0].base64Data)
        assertEquals("local-1", repaired[0].localImageId)
        coVerify { preferenceDao.set(PreferenceEntity(MessageAttachmentRepairTask.PREF_KEY, MessageAttachmentRepairTask.PREF_DONE_VALUE)) }
    }

    @Test
    fun `runIfNeeded reads oversized row across multiple chunk calls and reassembles correctly`() = runTest {
        // fileName is deliberately padded past CHUNK_SIZE_CHARS (200,000) to force 2+ substr
        // chunk calls, so this actually exercises the chunk-reassembly logic instead of
        // happening to read everything in a single call.
        val attachment = Attachment(
            id = "att-2",
            kind = AttachmentKind.File,
            fileName = "generic-" + "x".repeat(MessageAttachmentRepairTask.CHUNK_SIZE_CHARS + 5_000) + ".bin",
            mimeType = "text/plain",
            rawContentRef = "existing-ref",
        )
        val fullJson = json.encodeToString(listOf(attachment))
        val totalLen = fullJson.length
        assertTrue("test precondition: the total length must exceed a single chunk's size for this test to mean anything", totalLen > MessageAttachmentRepairTask.CHUNK_SIZE_CHARS)

        coEvery { preferenceDao.get(MessageAttachmentRepairTask.PREF_KEY) } returns null
        coEvery { messageDao.findOversizedAttachmentsJsonRows(any()) } returns
            listOf(OversizedAttachmentsJsonRow(id = "msg-2", accountId = accountId, len = totalLen))
        // Simulates chunked reads: each call slices the in-memory string using the caller's
        // (1-indexed) start/length, matching real SQLite substr() semantics, to verify the
        // chunk-reassembly logic itself is correct (regardless of the actual CHUNK_SIZE_CHARS
        // used internally -- as long as it walks all the way to totalLen, the number of chunk
        // calls doesn't matter).
        coEvery { messageDao.readAttachmentsJsonChunk(accountId, "msg-2", any(), any()) } answers {
            val start = thirdArg<Int>()
            val length = arg<Int>(3)
            val zeroBasedStart = (start - 1).coerceAtLeast(0)
            if (zeroBasedStart >= totalLen) {
                null
            } else {
                fullJson.substring(zeroBasedStart, minOf(zeroBasedStart + length, totalLen))
            }
        }
        val updatedSlot = slot<String>()
        coEvery { messageDao.updateAttachmentsJson(accountId, "msg-2", capture(updatedSlot)) } returns 1
        coEvery { preferenceDao.set(any()) } returns Unit

        task.runIfNeeded()

        val repaired = json.decodeFromString<List<Attachment>>(updatedSlot.captured!!)
        assertEquals(1, repaired.size)
        assertEquals("att-2", repaired[0].id)
    }

    @Test
    fun `repairAttachmentsJson degrades to null on malformed json instead of throwing`() = runTest {
        val result = task.repairAttachmentsJson("{not a valid attachments json")
        assertNull(result)
    }

    @Test
    fun `repairAttachmentsJson returns raw json unchanged when attachment list is empty`() = runTest {
        val raw = json.encodeToString(emptyList<Attachment>())
        val result = task.repairAttachmentsJson(raw)
        assertEquals(raw, result)
    }

    @Test
    fun `repairAttachmentsJson relocates oversized native file bytes to blob store`() = runTest {
        val bigOriginal = b64("x".repeat(500_000))
        val attachment = Attachment(
            id = "att-3",
            kind = AttachmentKind.File,
            fileName = "doc.pdf",
            mimeType = "application/pdf",
            base64Data = b64("extracted text"),
            originalBase64Data = bigOriginal,
        )
        val raw = json.encodeToString(listOf(attachment))
        // At the call site, saveBlob(data, id = generateUuidString()) evaluates the default id
        // argument too, so it's actually a two-argument call -- the matcher must cover both
        // arguments, or it falls through to the unmatched branch and the runCatching inside
        // AttachmentSlimmer silently swallows MockK's unmatched-call exception, degrading to null.
        every { attachmentStore.saveBlob(any(), any()) } returns "new-blob-id"

        val result = task.repairAttachmentsJson(raw)
        val repaired = json.decodeFromString<List<Attachment>>(result!!)

        assertEquals(1, repaired.size)
        assertNull(repaired[0].originalBase64Data)
        assertEquals("new-blob-id", repaired[0].rawContentRef)
        assertTrue("the extracted text should be preserved", repaired[0].base64Data == b64("extracted text"))
    }

    @Test
    fun `runIfNeeded does not mark done and does not throw when scan itself fails`() = runTest {
        coEvery { preferenceDao.get(MessageAttachmentRepairTask.PREF_KEY) } returns null
        coEvery { messageDao.findOversizedAttachmentsJsonRows(any()) } throws RuntimeException("boom")

        // must not throw upward -- this is a hard requirement, the repair task itself must never crash the app
        task.runIfNeeded()

        coVerify(exactly = 0) { preferenceDao.set(any()) }
    }

    @Test
    fun `runIfNeeded does not mark done when any row repair fails so it retries next launch`() = runTest {
        val goodAttachment = Attachment(
            id = "att-ok",
            kind = AttachmentKind.Image,
            fileName = "photo.jpg",
            mimeType = "image/jpeg",
            base64Data = b64("bytes"),
            localImageId = "local-ok",
        )
        val goodJson = json.encodeToString(listOf(goodAttachment))

        coEvery { preferenceDao.get(MessageAttachmentRepairTask.PREF_KEY) } returns null
        coEvery { messageDao.findOversizedAttachmentsJsonRows(any()) } returns listOf(
            OversizedAttachmentsJsonRow(id = "msg-bad", accountId = accountId, len = 100),
            OversizedAttachmentsJsonRow(id = "msg-good", accountId = accountId, len = goodJson.length),
        )
        // the bad row throws during the chunk-read phase (simulating a SQLite-layer failure); the good row repairs normally
        coEvery { messageDao.readAttachmentsJsonChunk(accountId, "msg-bad", any(), any()) } throws RuntimeException("io failure")
        coEvery { messageDao.readAttachmentsJsonChunk(accountId, "msg-good", 1, any()) } returns goodJson
        coEvery { messageDao.updateAttachmentsJson(accountId, "msg-good", any()) } returns 1

        task.runIfNeeded()

        // the good row is repaired as usual; but since a row failed, this run does not write the done marker, so the next launch retries everything
        coVerify(exactly = 1) { messageDao.updateAttachmentsJson(accountId, "msg-good", any()) }
        coVerify(exactly = 0) { preferenceDao.set(any()) }
    }

    // A streaming partial wrote a generated image into the text and bloated the row; read in chunks, save the image, write text and attachments back together
    @Test
    fun `text repair extracts inline image to store and rewrites text with attachment`() = runTest {
        val imageB64 = b64("png-bytes")
        val text = "Here:\n![img](data:image/png;base64,$imageB64)\nDone ![half](data:image/png;base64,AAAA"
        coEvery { preferenceDao.get(MessageAttachmentRepairTask.PREF_KEY) } returns MessageAttachmentRepairTask.PREF_DONE_VALUE
        coEvery { preferenceDao.get(MessageAttachmentRepairTask.TEXT_PREF_KEY) } returns null
        coEvery {
            messageDao.findOversizedInlineImageTextRows(MessageAttachmentRepairTask.TEXT_THRESHOLD_CHARS)
        } returns listOf(OversizedAttachmentsJsonRow(id = "msg-1", accountId = accountId, len = text.length))
        // Hand out only 7 characters per read to force multi-chunk assembly
        coEvery { messageDao.readTextChunk(accountId, "msg-1", any(), any()) } answers {
            val start = thirdArg<Int>() - 1
            text.substring(start, minOf(text.length, start + 7))
        }
        coEvery { messageDao.attachmentsJsonLength(accountId, "msg-1") } returns null
        every { attachmentStore.saveOriginalImage(any(), any()) } returns ai.oriveo.community.core.data.attachment.StoredImage("img-1", "image/png")
        val textSlot = slot<String>()
        val jsonWrites = mutableListOf<String?>()
        coEvery { messageDao.updateTextAndAttachmentsJson(accountId, "msg-1", capture(textSlot), captureNullable(jsonWrites)) } returns 1
        coEvery { preferenceDao.set(PreferenceEntity(MessageAttachmentRepairTask.TEXT_PREF_KEY, MessageAttachmentRepairTask.PREF_DONE_VALUE)) } returns Unit

        val chunked = MessageAttachmentRepairTask(messageDao, preferenceDao, attachmentStore, chunkSizeChars = 7)
        chunked.runIfNeeded()

        assertEquals("Here:\n\nDone ", textSlot.captured)
        val attachments = json.decodeFromString<List<Attachment>>(jsonWrites.single()!!)
        assertEquals(1, attachments.size)
        assertEquals("img-1", attachments.single().localImageId)
        assertNull(attachments.single().base64Data)
        coVerify { preferenceDao.set(PreferenceEntity(MessageAttachmentRepairTask.TEXT_PREF_KEY, MessageAttachmentRepairTask.PREF_DONE_VALUE)) }
    }

    // When saving fails the images must not be removed from the text: the row is not rewritten, no completion marker is written, and the next launch retries
    @Test
    fun `text repair leaves row untouched and retries when image save fails`() = runTest {
        val text = "![img](data:image/png;base64,${b64("png-bytes")})"
        coEvery { preferenceDao.get(MessageAttachmentRepairTask.PREF_KEY) } returns MessageAttachmentRepairTask.PREF_DONE_VALUE
        coEvery { preferenceDao.get(MessageAttachmentRepairTask.TEXT_PREF_KEY) } returns null
        coEvery {
            messageDao.findOversizedInlineImageTextRows(MessageAttachmentRepairTask.TEXT_THRESHOLD_CHARS)
        } returns listOf(OversizedAttachmentsJsonRow(id = "msg-1", accountId = accountId, len = text.length))
        coEvery { messageDao.readTextChunk(accountId, "msg-1", 1, any()) } returns text
        coEvery { messageDao.attachmentsJsonLength(accountId, "msg-1") } returns null
        every { attachmentStore.saveOriginalImage(any(), any()) } returns null

        task.runIfNeeded()

        coVerify(exactly = 0) { messageDao.updateTextAndAttachmentsJson(any(), any(), any(), any()) }
        coVerify(exactly = 0) { preferenceDao.set(PreferenceEntity(MessageAttachmentRepairTask.TEXT_PREF_KEY, MessageAttachmentRepairTask.PREF_DONE_VALUE)) }
    }

    // Existing installs already have the attachment repair marker; it must not skip the text pass
    @Test
    fun `text repair runs even when attachment repair is already marked done`() = runTest {
        coEvery { preferenceDao.get(MessageAttachmentRepairTask.PREF_KEY) } returns MessageAttachmentRepairTask.PREF_DONE_VALUE
        coEvery { preferenceDao.get(MessageAttachmentRepairTask.TEXT_PREF_KEY) } returns null
        coEvery { messageDao.findOversizedInlineImageTextRows(any()) } returns emptyList()
        coEvery { preferenceDao.set(any()) } returns Unit

        task.runIfNeeded()

        coVerify { messageDao.findOversizedInlineImageTextRows(MessageAttachmentRepairTask.TEXT_THRESHOLD_CHARS) }
        coVerify { preferenceDao.set(PreferenceEntity(MessageAttachmentRepairTask.TEXT_PREF_KEY, MessageAttachmentRepairTask.PREF_DONE_VALUE)) }
    }
}
