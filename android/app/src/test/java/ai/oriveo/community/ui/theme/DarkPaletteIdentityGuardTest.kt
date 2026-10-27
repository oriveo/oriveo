package ai.oriveo.community.ui.theme

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source guard: do not decide "is this dark" by "current color value == some field of DarkOriveoColors".
 *
 * Dark has 7 switchable palettes and fields such as backgroundBase change with the palette; comparing against one palette's value
 * misjudges dark as light once another palette is selected. Always use `OriveoTheme.isDark` to decide light or dark.
 */
class DarkPaletteIdentityGuardTest {

    @Test
    fun `no source compares a color against a DarkOriveoColors field`() {
        val root = File("src/main/java")
        assertTrue("cannot find src/main/java, wrong working directory", root.isDirectory)
        val pattern = Regex("""(==|!=)\s*DarkOriveoColors\.|DarkOriveoColors\.\w+\s*(==|!=)""")
        val offenders = root.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { file ->
                file.readLines().mapIndexedNotNull { index, line ->
                    if (pattern.containsMatchIn(line)) "${file.path}:${index + 1}: ${line.trim()}" else null
                }
            }
            .toList()
        assertTrue(
            "use OriveoTheme.isDark to decide dark; do not compare against DarkOriveoColors values:\n" +
                offenders.joinToString("\n"),
            offenders.isEmpty(),
        )
    }
}
