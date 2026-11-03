package ai.oriveo.community.feature.chat.composer

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Keeps the EnhancedComposer method body split.
 *
 * ART's bytecode verifier rejected the whole EnhancedComposerKt class on the debug build
 * (VerifyError "[0x3A8A] copy-reference v11<-v253 type=Boolean"): the single Compose method had grown
 * close to the 256-register limit, so the chat composer crashed as soon as it was loaded. The fix moved
 * self-contained UI blocks into private composables in the same file.
 *
 * Robolectric runs on the JVM and never goes through the ART verifier, so this cannot reproduce the
 * crash; it only fails when the function body grows back. Measured after the split: 980 lines.
 */
class EnhancedComposerSizeGuardTest {

    @Test
    fun enhancedComposerBodyStaysSplit() {
        val lines = File(SOURCE_PATH).readLines()
        val start = lines.indexOfFirst { it.contains("fun EnhancedComposer(") }
        assertTrue("fun EnhancedComposer( not found in $SOURCE_PATH", start >= 0)
        val end = (start until lines.size).firstOrNull { lines[it] == "}" }
        assertTrue("end of EnhancedComposer not found in $SOURCE_PATH", end != null)
        val bodyLines = end!! - start + 1
        assertTrue(
            "EnhancedComposer spans $bodyLines lines (limit $MAX_LINES); move self-contained UI blocks into " +
                "private composables instead of growing it back toward ART's 256-register verifier limit",
            bodyLines <= MAX_LINES,
        )
    }

    private companion object {
        const val SOURCE_PATH = "src/main/java/ai/oriveo/community/feature/chat/composer/EnhancedComposer.kt"

        /** Measured length after the split (980) plus 40 lines of headroom. */
        const val MAX_LINES = 1020
    }
}
