package ai.oriveo.community.core.data.repository.streaming

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

// A streaming partial that writes inline generated images into messages.text lets a single image push the row past the 2MB CursorWindow
class StreamingImageInlineStripTest {

    private val bigBase64 = "A".repeat(3_000_000)

    @Test
    fun stripsCompleteInlineImageAndKeepsSurroundingText() {
        val text = "Here you go:\n![generated](data:image/png;base64,$bigBase64)\nEnjoy."

        assertEquals("Here you go:\n\nEnjoy.", StreamingImageProcessor.stripInlineImageData(text))
    }

    // The stream has not finished: the data URI is only half there, with no closing parenthesis
    @Test
    fun stripsUnclosedInlineImageTail() {
        val text = "Drawing it now ![img](data:image/jpeg;base64,$bigBase64"

        assertEquals("Drawing it now ", StreamingImageProcessor.stripInlineImageData(text))
    }

    @Test
    fun stripsBase64WrappedAcrossLines() {
        val text = "a ![x](data:image/png;base64,AAAA\nBBBB\nCC==) b"

        assertEquals("a  b", StreamingImageProcessor.stripInlineImageData(text))
    }

    @Test
    fun leavesPlainMarkdownAndUrlImagesUntouched() {
        val text = "See ![chart](https://example.com/a.png) and (data) [link](https://x.y)"

        assertSame(text, StreamingImageProcessor.stripInlineImageData(text))
    }

    // Strips only the image: text after it that is properly closed and contains parentheses is not swallowed by the tail rule
    @Test
    fun keepsTextAfterCompleteImageEvenWithParentheses() {
        val text = "![a](data:image/png;base64,QUJD) then (note) end"

        assertEquals(" then (note) end", StreamingImageProcessor.stripInlineImageData(text))
    }
}
