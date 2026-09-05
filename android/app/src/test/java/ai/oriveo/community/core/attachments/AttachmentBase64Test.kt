package ai.oriveo.community.core.attachments

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AttachmentBase64Test {

    @Test fun `shouldPersistOriginalBase64 PDF`() {
        assertTrue(shouldPersistOriginalBase64("application/pdf"))
        assertTrue(shouldPersistOriginalBase64("APPLICATION/PDF"))
    }

    @Test fun `shouldPersistOriginalBase64 Office 8 mime`() {
        assertTrue(shouldPersistOriginalBase64("application/vnd.openxmlformats-officedocument.wordprocessingml.document"))
        assertTrue(shouldPersistOriginalBase64("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"))
        assertTrue(shouldPersistOriginalBase64("application/vnd.openxmlformats-officedocument.presentationml.presentation"))
        assertTrue(shouldPersistOriginalBase64("application/rtf"))
        assertTrue(shouldPersistOriginalBase64("text/rtf"))
        assertTrue(shouldPersistOriginalBase64("application/vnd.oasis.opendocument.text"))
        assertTrue(shouldPersistOriginalBase64("application/vnd.oasis.opendocument.spreadsheet"))
        assertTrue(shouldPersistOriginalBase64("application/vnd.oasis.opendocument.presentation"))
    }

    @Test fun `shouldPersistOriginalBase64 reject non-native mimes`() {
        assertFalse(shouldPersistOriginalBase64("text/plain"))
        assertFalse(shouldPersistOriginalBase64("application/json"))
        assertFalse(shouldPersistOriginalBase64("image/png"))
        assertFalse(shouldPersistOriginalBase64("video/mp4"))
        assertFalse(shouldPersistOriginalBase64("application/epub+zip"))
        assertFalse(shouldPersistOriginalBase64(""))
    }

    @Test fun `streamingBase64 matches standard java util Base64 encoder`() {
        // streamingBase64 is implemented with java.util.Base64.Encoder.wrap -- standard
        // RFC 4648 base64; android.util.Base64.NO_WRAP is the same variant (no line wrap, with padding)
        val sample = "Hello, せかい! 🐾".toByteArray(Charsets.UTF_8)
        val streamed = streamingBase64(sample)
        val expected = java.util.Base64.getEncoder().encodeToString(sample)
        assertEquals(expected, streamed)
    }

    @Test fun `streamingBase64 handles empty bytes`() {
        assertEquals("", streamingBase64(ByteArray(0)))
    }

    @Test fun `streamingBase64 handles large input without OOM`() {
        // 1MB input -- verifies streaming large data doesn't crash
        val big = ByteArray(1 * 1024 * 1024) { (it % 256).toByte() }
        val encoded = streamingBase64(big)
        // base64 output size is roughly input × 4/3
        assertTrue(encoded.length > big.size * 4 / 3 - 10)
        assertTrue(encoded.length < big.size * 4 / 3 + 100)
    }
}
