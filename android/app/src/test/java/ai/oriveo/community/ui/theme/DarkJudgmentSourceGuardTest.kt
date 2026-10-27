package ai.oriveo.community.ui.theme

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source guard: do not decide "is this dark" by whether the background equals the default dark.
 * The 7 dark palettes have different base colors, so after switching to a non-default palette such a comparison is always false and dark gets treated as light.
 * Always use `OriveoTheme.isDark` to decide whether the theme is dark.
 */
class DarkJudgmentSourceGuardTest {

    private val forbidden = Regex(
        """(==|!=)\s*DarkOriveoColors\.(backgroundBase|background)\b|DarkOriveoColors\.(backgroundBase|background)\s*(==|!=)"""
    )

    @Test
    fun `main sources never detect dark mode by comparing against the default dark background`() {
        val root = File("src/main/java")
        assertTrue("cannot find the main source directory: ${root.absolutePath}", root.isDirectory)
        val hits = root.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { file ->
                file.readLines().mapIndexedNotNull { index, line ->
                    if (forbidden.containsMatchIn(line)) "${file.path}:${index + 1}: ${line.trim()}" else null
                }
            }
            .toList()
        assertTrue("use OriveoTheme.isDark instead:\n" + hits.joinToString("\n"), hits.isEmpty())
    }

    @Test
    fun `guard pattern catches both comparison orders`() {
        assertTrue(forbidden.containsMatchIn("val dark = colors.backgroundBase == DarkOriveoColors.backgroundBase"))
        assertTrue(forbidden.containsMatchIn("if (DarkOriveoColors.background != bg) return"))
        assertTrue(!forbidden.containsMatchIn("val bg = DarkOriveoColors.backgroundBase"))
    }
}
