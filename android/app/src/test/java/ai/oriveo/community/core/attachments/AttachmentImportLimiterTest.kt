package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test


class AttachmentImportLimiterTest {

    @Test
    fun `counts every kind against the same budget`() {
        val existing = listOf(
            attachment("img-1", AttachmentKind.Image),
            attachment("file-1", AttachmentKind.File),
            attachment("video-1", AttachmentKind.Video),
        )

        val result = AttachmentImportLimiter.limit(
            existing = existing,
            incoming = listOf(attachment("img-2", AttachmentKind.Image)),
            maxAttachments = 3,
        )

        assertTrue(result.accepted.isEmpty())
        assertEquals(1, result.rejectedCount)
    }

    @Test
    fun `accepts what still fits and rejects only the overflow`() {
        val result = AttachmentImportLimiter.limit(
            existing = listOf(attachment("img-1", AttachmentKind.Image)),
            incoming = listOf(
                attachment("img-2", AttachmentKind.Image),
                attachment("img-3", AttachmentKind.Image),
                attachment("img-4", AttachmentKind.Image),
            ),
            maxAttachments = 3,
        )

        assertEquals(listOf("img-2", "img-3"), result.accepted.map { it.id })
        assertEquals(1, result.rejectedCount)
    }

    @Test
    fun `accepts everything when it fits`() {
        val incoming = listOf(attachment("img-1", AttachmentKind.Image))
        val result = AttachmentImportLimiter.limit(
            existing = emptyList(),
            incoming = incoming,
            maxAttachments = 3,
        )

        assertEquals(incoming, result.accepted)
        assertEquals(0, result.rejectedCount)
    }

    @Test
    fun `rejects everything when the budget is non positive`() {
        val result = AttachmentImportLimiter.limit(
            existing = emptyList(),
            incoming = listOf(attachment("img-1", AttachmentKind.Image)),
            maxAttachments = 0,
        )

        assertTrue(result.accepted.isEmpty())
        assertEquals(1, result.rejectedCount)
    }

    @Test
    fun `over-full existing list never yields negative slots`() {
        val result = AttachmentImportLimiter.limit(
            existing = List(5) { attachment("img-$it", AttachmentKind.Image) },
            incoming = listOf(attachment("img-new", AttachmentKind.Image)),
            maxAttachments = 3,
        )

        assertTrue(result.accepted.isEmpty())
        assertEquals(1, result.rejectedCount)
    }

    @Test
    fun `default client budget matches iOS maxFiles`() {
        assertEquals(3, FileExtractionLimits.DEFAULT.maxFiles)
    }

    private fun attachment(id: String, kind: AttachmentKind) = Attachment(
        id = id,
        kind = kind,
        fileName = "f.bin",
        mimeType = "application/octet-stream",
    )
}
