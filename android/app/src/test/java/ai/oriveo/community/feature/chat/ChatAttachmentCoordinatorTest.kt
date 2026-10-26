package ai.oriveo.community.feature.chat

import android.content.Context
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.provider.AttachmentInputGate
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Attachments put back into the composer on edit are saved under new keys: the draft shares no local file key
 * with the original message, so deleting the original message (which removes the files it owned exclusively)
 * leaves the draft's images and raw bytes intact.
 */
class ChatAttachmentCoordinatorTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private fun realAttachmentStore(): AttachmentStore {
        val dir = tempFolder.newFolder()
        val context = mockk<Context> { every { filesDir } returns dir }
        return AttachmentStore(context)
    }

    private fun coordinator(store: AttachmentStore) = ChatAttachmentCoordinator(
        attachmentProcessor = mockk(relaxed = true),
        globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true),
        activeModel = { null },
        pendingAttachments = { emptyList() },
        addAttachment = { _, _ -> },
        presentAttachmentSizeLimitDialog = {},
        attachmentInputGate = { AttachmentInputGate(image = true, nativeFile = true, video = true) },
        attachmentStore = { store },
        ioDispatcher = Dispatchers.Unconfined,
    )

    @Test
    fun restoredForEdit_copiesToNewImageKey() = runTest {
        val store = realAttachmentStore()
        store.saveImageRaw("img-local", byteArrayOf(1, 2, 3))
        store.saveThumbnailRaw("img-local", byteArrayOf(4, 5))
        // An image stored under the attachment id, without a localImageId
        store.saveImageRaw("att-keyed", byteArrayOf(6, 7))
        val blobId = store.saveBlob(byteArrayOf(8, 9, 10), "blob-raw")
        val original = listOf(
            Attachment(id = "att-local", kind = AttachmentKind.Image, fileName = "a.jpg", mimeType = "image/jpeg", localImageId = "img-local"),
            Attachment(id = "att-keyed", kind = AttachmentKind.Image, fileName = "b.jpg", mimeType = "image/jpeg"),
            Attachment(id = "att-video", kind = AttachmentKind.Video, fileName = "v.mp4", mimeType = "video/mp4", rawContentRef = blobId),
        )

        val coordinator = coordinator(store)
        val restored = coordinator.restoredForEdit(original)

        assertEquals(listOf("a.jpg", "b.jpg", "v.mp4"), restored.map { it.fileName })
        // Images whose original cannot be read are not put back
        val missing = Attachment(id = "att-missing", kind = AttachmentKind.Image, fileName = "c.jpg", mimeType = "image/jpeg", localImageId = "img-gone")
        assertEquals(emptyList<Attachment>(), coordinator.restoredForEdit(listOf(missing)))
        val originalKeys = original.flatMap { listOfNotNull(it.id, it.localImageId, it.rawContentRef) }.toSet()
        restored.forEach { attachment ->
            val keys = listOfNotNull(attachment.id, attachment.localImageId, attachment.rawContentRef)
            assertTrue("The draft must not share file keys with the original message: $keys", keys.none { it in originalKeys })
        }
        val (local, keyed, video) = restored
        assertNotEquals(local.localImageId, keyed.localImageId)

        // After the original message's files are removed, the draft's files are still there
        listOf("img-local", "att-keyed").forEach { store.delete(it) }
        store.deleteBlob(blobId)
        assertArrayEquals(byteArrayOf(1, 2, 3), store.loadImageBytes(local.localImageId!!))
        assertArrayEquals(byteArrayOf(4, 5), store.loadThumbnailBytes(local.localImageId!!))
        assertArrayEquals(byteArrayOf(6, 7), store.loadImageBytes(keyed.localImageId!!))
        assertArrayEquals(byteArrayOf(8, 9, 10), store.loadBlobBytes(video.rawContentRef!!))
    }

    @Test
    fun editResend_restoreCompletesBeforeDelete() = runTest {
        // Saving under new keys finishes before the original message row is deleted (deleting the row purges the files it owned exclusively)
        val store = realAttachmentStore()
        store.saveImageRaw("img-edit", byteArrayOf(1, 2, 3))
        val original = listOf(
            Attachment(id = "att-edit", kind = AttachmentKind.Image, fileName = "e.jpg", mimeType = "image/jpeg", localImageId = "img-edit"),
        )
        val coordinator = coordinator(store)
        val events = mutableListOf<String>()
        var draft = emptyList<Attachment>()

        runEditTruncation(
            restoreAttachments = {
                // Suspends mid-save: if the delete did not wait for it, it would run first
                delay(50)
                draft = coordinator.restoredForEdit(original)
                events += "restored"
            },
            stopStream = { events += "stopped" },
            deleteMessages = {
                events += "deleted"
                // Simulate the purge after the row delete removing the files the original message owned exclusively
                store.delete("img-edit")
                true
            },
        )

        assertEquals(listOf("restored", "stopped", "deleted"), events)
        assertEquals(1, draft.size)
        assertNotEquals("img-edit", draft.single().localImageId)
        assertArrayEquals(byteArrayOf(1, 2, 3), store.loadImageBytes(draft.single().localImageId!!))
        assertNull(store.loadImageBytes("img-edit"))
    }
}
