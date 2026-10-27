package ai.oriveo.community.ui.component.markdown

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontStyle
import ai.oriveo.community.ui.theme.DarkPaletteContract
import ai.oriveo.community.ui.theme.LightOriveoColors
import java.nio.file.Files
import java.nio.file.Paths
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Reads the code-highlight source of truth shared by every client, `shared/theme-contracts/code-highlight.v1.json` (read only).
 * The tests do not copy a second set of hex values; expected values always come from here.
 */
internal object CodeHighlightContract {

    val root: JsonObject by lazy {
        val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("shared/theme-contracts/code-highlight.v1.json") }
            .firstOrNull { Files.exists(it) }
            ?: error("code-highlight.v1.json not found")
        Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    val roles: List<String> get() = root.getValue("roles").jsonArray.map { it.jsonPrimitive.content }

    val light: JsonObject get() = root.getValue("light").jsonObject

    val dark: JsonObject get() = root.getValue("dark").jsonObject

    val classifyCases: List<JsonObject> get() = root.getValue("classifyCases").jsonArray.map { it.jsonObject }

    fun color(set: JsonObject, key: String): Color = DarkPaletteContract.color(set.getValue(key))

    /** A `{ from, alpha }` whole-line background -> the from color @ alpha. */
    fun lineColor(set: JsonObject, key: String): Color {
        val line = set.getValue(key).jsonObject
        return DarkPaletteContract.color(line.getValue("from")).copy(alpha = DarkPaletteContract.float(line.getValue("alpha")))
    }

    /** JSON role -> Android MarkdownColors field. */
    val roleReaders: Map<String, (MarkdownColors) -> Color> = linkedMapOf(
        "text" to { c -> c.syntaxText },
        "keyword" to { c -> c.syntaxKeyword },
        "string" to { c -> c.syntaxString },
        "number" to { c -> c.syntaxNumber },
        "function" to { c -> c.syntaxFunction },
        "type" to { c -> c.syntaxType },
        "property" to { c -> c.syntaxProperty },
        "comment" to { c -> c.syntaxComment },
        "punctuation" to { c -> c.syntaxPunctuation },
        "diffAdd" to { c -> c.syntaxDiffAdd },
        "diffDelete" to { c -> c.syntaxDiffDelete },
        "diffHunk" to { c -> c.syntaxDiffHunk },
    )
}

class CodeHighlightContractTest {

    private val lightColors = MarkdownTheme.resolveColors(LightOriveoColors, isDark = false)

    /** One unique color per role: cases assert by role and are not masked by two roles sharing a color (e.g. string / diffAdd). */
    private val distinctColors = lightColors.copy(
        syntaxText = Color(0xFF000001),
        syntaxKeyword = Color(0xFF000002),
        syntaxString = Color(0xFF000003),
        syntaxNumber = Color(0xFF000004),
        syntaxFunction = Color(0xFF000005),
        syntaxType = Color(0xFF000006),
        syntaxProperty = Color(0xFF000007),
        syntaxComment = Color(0xFF000008),
        syntaxPunctuation = Color(0xFF000009),
        syntaxDiffAdd = Color(0xFF00000A),
        syntaxDiffDelete = Color(0xFF00000B),
        syntaxDiffHunk = Color(0xFF00000C),
    )

    @Test
    fun `contract lists exactly the twelve mapped roles`() {
        assertEquals(CodeHighlightContract.roleReaders.keys.toList(), CodeHighlightContract.roles)
    }

    @Test
    fun `light roles equal contract light`() {
        for ((role, read) in CodeHighlightContract.roleReaders) {
            assertEquals("light $role", CodeHighlightContract.color(CodeHighlightContract.light, role), read(lightColors))
        }
        assertEquals(CodeHighlightContract.lineColor(CodeHighlightContract.light, "diffAddLine"), lightColors.syntaxDiffAddLine)
        assertEquals(CodeHighlightContract.lineColor(CodeHighlightContract.light, "diffDeleteLine"), lightColors.syntaxDiffDeleteLine)
    }

    @Test
    fun `dark roles equal contract dark under every palette`() {
        val instances = DarkPaletteContract.instances()
        assertEquals(7, instances.size)
        for ((id, palette) in instances) {
            val colors = MarkdownTheme.resolveColors(palette, isDark = true)
            for ((role, read) in CodeHighlightContract.roleReaders) {
                assertEquals("$id $role", CodeHighlightContract.color(CodeHighlightContract.dark, role), read(colors))
            }
            assertEquals("$id diffAddLine", CodeHighlightContract.lineColor(CodeHighlightContract.dark, "diffAddLine"), colors.syntaxDiffAddLine)
            assertEquals("$id diffDeleteLine", CodeHighlightContract.lineColor(CodeHighlightContract.dark, "diffDeleteLine"), colors.syntaxDiffDeleteLine)
            // The palette only changes the code block background
            assertEquals("$id codeBg", palette.codeBlockBg, colors.codeBlockBg)
            assertEquals("$id codeHeaderBg", palette.codeBlockHeaderBg, colors.codeBlockSurface)
        }
    }

    @Test
    fun `classify cases color each expected text with its role`() {
        val cases = CodeHighlightContract.classifyCases
        assertTrue(cases.isNotEmpty())
        for (colors in listOf(distinctColors, lightColors)) {
            for (case in cases) {
                val name = case.getValue("name").jsonPrimitive.content
                val code = case.getValue("code").jsonPrimitive.content
                val language = case.getValue("language").jsonPrimitive.content
                val result = SyntaxHighlighter.highlight(code, language, colors)
                assertEquals(name, code, result.text)
                for (pair in case.getValue("expect").jsonArray) {
                    val (text, role) = pair.jsonArray.map { it.jsonPrimitive.content }
                    val expected = CodeHighlightContract.roleReaders.getValue(role)(colors)
                    val start = code.indexOf(text)
                    assertTrue("$name: '$text' not in code", start >= 0)
                    val end = start + text.length
                    // The whole segment is covered by one span of that role's color, and every span overlapping it has the same color
                    assertTrue(
                        "$name: '$text' should be $role",
                        result.spanStyles.any { it.start <= start && it.end >= end && it.item.color == expected },
                    )
                    assertTrue(
                        "$name: '$text' mixes other colors",
                        result.spanStyles
                            .filter { it.start < end && it.end > start && it.item.color != Color.Unspecified }
                            .all { it.item.color == expected },
                    )
                }
            }
        }
    }

    @Test
    fun `comments are never italic`() {
        assertFalse(CodeHighlightContract.root.getValue("italicComments").jsonPrimitive.boolean)
        val samples = CodeHighlightContract.classifyCases.map {
            it.getValue("code").jsonPrimitive.content to it.getValue("language").jsonPrimitive.content
        } + listOf("val x = 1 // \u4e2d\u6587\u6ce8\u91ca" to "kotlin", "# \u6ce8\u91ca" to "python")
        for ((code, language) in samples) {
            val result = SyntaxHighlighter.highlight(code, language, lightColors)
            assertTrue(code, result.spanStyles.none { it.item.fontStyle == FontStyle.Italic })
        }
    }

    @Test
    fun `diff add and delete lines carry full line background annotations`() {
        val code = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old /* x\n+new\n same"
        val result = SyntaxHighlighter.highlight(code, "diff", lightColors)
        val lines = result.getStringAnnotations(SyntaxHighlighter.DIFF_LINE_TAG, 0, result.length)
            .map { code.substring(it.start, it.end) to it.item }
        assertEquals(
            listOf("-old /* x" to SyntaxHighlighter.DIFF_LINE_DELETE, "+new" to SyntaxHighlighter.DIFF_LINE_ADD),
            lines,
        )
        // The same helper also serves streaming: only completed lines carry a background
        val streaming = highlightStreamingCode("+a\n-b", "patch", lightColors)
        assertEquals(
            listOf("+a"),
            streaming.getStringAnnotations(SyntaxHighlighter.DIFF_LINE_TAG, 0, streaming.length)
                .map { streaming.text.substring(it.start, it.end) },
        )
    }
}
