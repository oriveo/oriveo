package ai.oriveo.community.ui.component

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import org.junit.Assert.assertEquals
import org.junit.Test

class AttachmentImageDisplaySourceTest {

    @Test
    fun `display prefers the stored original over the thumbnail`() {
        val attachment = Attachment(
            id = "attachment-1",
            kind = AttachmentKind.Image,
            fileName = "photo.jpg",
            mimeType = "image/jpeg",
            localImageId = "local-image-id",
            thumbnailBase64 = "thumbnail",
        )

        val source = resolveAttachmentDisplaySource(attachment) { localId ->
            localId == "local-image-id"
        }

        assertEquals(AttachmentImageDisplaySource.LocalOriginal, source)
    }

    @Test
    fun `display falls back to the thumbnail when the original is gone from the store`() {
        val attachment = Attachment(
            id = "attachment-1",
            kind = AttachmentKind.Image,
            fileName = "photo.jpg",
            mimeType = "image/jpeg",
            localImageId = "local-image-id",
            thumbnailBase64 = "thumbnail",
        )

        val source = resolveAttachmentDisplaySource(attachment) { false }

        assertEquals(AttachmentImageDisplaySource.Thumbnail, source)
    }

    @Test
    fun `inline base64 is used when there is no stored original`() {
        val attachment = Attachment(
            id = "attachment-2",
            kind = AttachmentKind.Image,
            fileName = "inline.png",
            mimeType = "image/png",
            base64Data = "aW5saW5lLWJ5dGVz",
        )

        val source = resolveAttachmentDisplaySource(attachment) { false }

        assertEquals(AttachmentImageDisplaySource.InlineOriginal, source)
    }

    @Test
    fun `a base64Data holding a URL is not treated as inline bytes`() {
        val attachment = Attachment(
            id = "attachment-3",
            kind = AttachmentKind.Image,
            fileName = "remote.png",
            mimeType = "image/png",
            base64Data = "https://example.com/remote.png",
        )

        val source = resolveAttachmentDisplaySource(attachment) { false }

        assertEquals(AttachmentImageDisplaySource.None, source)
    }

    @Test
    fun `non image attachments have no display source`() {
        val attachment = Attachment(
            id = "attachment-4",
            kind = AttachmentKind.File,
            fileName = "notes.pdf",
            mimeType = "application/pdf",
            thumbnailBase64 = "thumbnail",
        )

        val source = resolveAttachmentDisplaySource(attachment) { true }

        assertEquals(AttachmentImageDisplaySource.None, source)
    }
}
