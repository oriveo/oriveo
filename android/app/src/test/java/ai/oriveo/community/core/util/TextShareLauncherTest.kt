package ai.oriveo.community.core.util

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TextShareLauncherTest {

    @Test
    fun `large UTF-8 text is not eligible for an inline Binder payload`() {
        val text = "カ".repeat(500_000)

        assertFalse(TextShareLauncher.shouldShareInline(text))
    }

    @Test
    fun `small message remains eligible for inline sharing`() {
        assertTrue(TextShareLauncher.shouldShareInline("hello"))
    }

    @Test
    fun `production file writer preserves a payload larger than Binder capacity`() {
        val cacheDir = Files.createTempDirectory("oriveo-text-share").toFile()
        try {
            val text = "カ".repeat(500_000)

            val file = TextShareLauncher.createShareFile(
                cacheDir = cacheDir,
                requestedFileName = "conversation.md",
                text = text,
                shareId = "large-export",
                nowMillis = 1_000L,
            )

            assertEquals("conversation.md", file.name)
            assertEquals(text, file.readText(Charsets.UTF_8))
            assertTrue(file.length() > 1_000_000L)
            assertTrue(file.canonicalPath.startsWith(File(cacheDir, "shared_text").canonicalPath))
        } finally {
            cacheDir.deleteRecursively()
        }
    }

    @Test
    fun `file name sanitization cannot escape the share cache`() {
        val cacheDir = Files.createTempDirectory("oriveo-text-share").toFile()
        try {
            val file = TextShareLauncher.createShareFile(
                cacheDir = cacheDir,
                requestedFileName = "../../outside.md",
                text = "safe",
                shareId = "path-test",
                nowMillis = 1_000L,
            )

            assertEquals(".._.._outside.md", file.name)
            assertTrue(file.canonicalPath.startsWith(File(cacheDir, "shared_text").canonicalPath))
        } finally {
            cacheDir.deleteRecursively()
        }
    }
}
