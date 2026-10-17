package ai.oriveo.community.core.attachments

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ImageMediaTypeTest {

    private fun b64(vararg head: Int) = Base64.getEncoder().encodeToString(head.map { it.toByte() }.toByteArray() + ByteArray(16))

    private fun b64(head: String, tail: String = "") = Base64.getEncoder().encodeToString((head + tail).toByteArray() + ByteArray(16))

    @Test
    fun `recognises the four formats providers accept`() {
        assertEquals("image/jpeg", ImageMediaType.sniff(b64(0xFF, 0xD8, 0xFF, 0xE0)))
        assertEquals("image/png", ImageMediaType.sniff(b64(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)))
        assertEquals("image/gif", ImageMediaType.sniff(b64("GIF89a")))
        assertEquals("image/webp", ImageMediaType.sniff(b64("RIFF", "\u0000\u0000\u0000\u0000WEBPVP8 ")))
    }

    @Test
    fun `falls back to the declared mime when bytes are unknown or not base64`() {
        assertNull(ImageMediaType.sniff(b64("RIFF", "\u0000\u0000\u0000\u0000WAVEfmt ")))
        assertEquals("image/heic", ImageMediaType.resolve(b64("\u0000\u0000\u0000\u0018ftypheic"), "image/heic"))
        assertEquals("image/png", ImageMediaType.resolve("%%%not base64%%%", "image/png"))
        assertEquals("image/png", ImageMediaType.resolve("", "image/png"))
    }

    @Test
    fun `line wrapped base64 still sniffs`() {
        val wrapped = Base64.getMimeEncoder().encodeToString(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte()) + ByteArray(200))
        assertEquals("image/jpeg", ImageMediaType.sniff(wrapped))
    }
}
