package ai.oriveo.community.core.provider

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source guard: the default usageReported = true of ProviderChatResult is for test fixtures only,
 * so every production construction must name `usageReported =` among its own arguments (paren depth 1); otherwise a new exit that forgets to fill it would record "no usage returned" as a real 0.
 * Text inside strings and comments is neither a construction nor an argument; a same-named argument inside a nested call does not count.
 */
class ProviderChatResultUsageReportedGuardTest {

    @Test
    fun every_production_construction_names_usageReported() {
        val root = File("src/main/java")
        assertTrue("source root not found: ${root.absolutePath}", root.isDirectory)
        val missing = mutableListOf<String>()
        var scanned = 0
        root.walkTopDown().filter { it.isFile && it.extension == "kt" }.forEach { file ->
            val scan = scan(file.readText())
            scanned += scan.scanned
            scan.missingLines.forEach { missing += "${file.relativeTo(root).path}:$it" }
        }
        assertTrue("no ProviderChatResult construction scanned", scanned > 0)
        assertTrue(
            "ProviderChatResult constructions missing explicit usageReported =:\n" + missing.joinToString("\n"),
            missing.isEmpty(),
        )
    }

    /** Guard self-test: one case each for depth, strings, comments and templates, making sure the guard itself does not let a missed fill through. */
    @Test
    fun guard_only_accepts_depth_one_named_argument_outside_strings_and_comments() {
        val q = "\""
        val sample = listOf(
            "val a = ProviderChatResult(text = ${q}x$q, usageReported = false)",
            "val b = ProviderChatResult(text = ${q}usageReported = true$q)",
            "val c = ProviderChatResult(text = wrap(usageReported = true))",
            "val d = ProviderChatResult(text = ${q}x$q /* usageReported = true */)",
            "val e = ProviderChatResult(text = ${q}x$q, // usageReported = true\n)",
            "// ProviderChatResult(text = ${q}x$q)",
            "val f = ${q}ProviderChatResult(text = x)$q",
            "val g = ProviderChatResult(text = $q\${wrap(${q}y$q)}$q, usageReported = r.usageReported)",
            "val h = ProviderChatResult(text = ${q}x$q, promptTokens = list.count { usageReported == true })",
            "val i = ProviderChatResult(\n    text = ${q}${q}${q}a \"b\" usageReported = true${q}${q}${q},\n)",
            "data class ProviderChatResult(val text: String)",
        ).joinToString("\n")
        val result = scan(sample)
        assertEquals(8, result.scanned)
        assertEquals(listOf(2, 3, 4, 5, 10, 11), result.missingLines)
    }

    private data class Scan(val scanned: Int, val missingLines: List<Int>)

    private fun scan(source: String): Scan {
        val text = SourceMasker(source).masked()
        val missing = mutableListOf<Int>()
        var scanned = 0
        CALL.findAll(text).forEach { match ->
            val start = match.range.first
            val lineStart = text.lastIndexOf('\n', start) + 1
            // The class declaration itself is not a construction.
            if (text.substring(lineStart, start).trim().endsWith("class")) return@forEach
            scanned++
            if (!USAGE_REPORTED.containsMatchIn(depthOneArguments(text, match.range.last))) {
                missing += text.substring(0, start).count { it == '\n' } + 1
            }
        }
        return Scan(scanned, missing)
    }

    /** From the opening paren take only the argument text at paren depth 1 (contents of nested ( ) [ ] { } are dropped, leaving a placeholder). */
    private fun depthOneArguments(text: String, openParen: Int): String {
        val out = StringBuilder()
        var depth = 0
        for (i in openParen until text.length) {
            val c = text[i]
            when (c) {
                '(', '[', '{' -> { depth++; if (depth == 2) out.append('_') }
                ')', ']', '}' -> if (--depth == 0) return out.toString()
                else -> if (depth == 1) out.append(c)
            }
        }
        return out.toString()
    }

    /** Replaces the contents of comments and string literals with spaces (newlines and indices kept); code inside string templates `${...}` is kept as usual. */
    private class SourceMasker(private val src: String) {
        private val out = StringBuilder(src)

        fun masked(): String {
            code(0, inTemplate = false)
            return out.toString()
        }

        private fun blank(from: Int, to: Int) {
            for (k in from until minOf(to, src.length)) if (src[k] != '\n') out.setCharAt(k, ' ')
        }

        /** Scans the code area; when [inTemplate], returns the index of the unbalanced `}` when it is met. */
        private fun code(start: Int, inTemplate: Boolean): Int {
            var i = start
            var braces = 0
            while (i < src.length) {
                val c = src[i]
                when {
                    src.startsWith("//", i) -> {
                        val end = src.indexOf('\n', i).let { if (it < 0) src.length else it }
                        blank(i, end); i = end
                    }
                    src.startsWith("/*", i) -> {
                        val end = src.indexOf("*/", i + 2).let { if (it < 0) src.length else it + 2 }
                        blank(i, end); i = end
                    }
                    src.startsWith("\"\"\"", i) -> { blank(i, i + 3); i = string(i + 3, raw = true) }
                    c == '"' -> { blank(i, i + 1); i = string(i + 1, raw = false) }
                    c == '\'' -> {
                        val body = if (i + 1 < src.length && src[i + 1] == '\\') i + 3 else i + 2
                        val end = src.indexOf('\'', minOf(body, src.length)).let { if (it < 0) src.length else it + 1 }
                        blank(i, end); i = end
                    }
                    c == '{' -> { braces++; i++ }
                    c == '}' -> {
                        if (inTemplate && braces == 0) return i
                        braces--; i++
                    }
                    else -> i++
                }
            }
            return i
        }

        /** Scans a string body ([start] is after the opening quote) and returns the index after the closing quote. */
        private fun string(start: Int, raw: Boolean): Int {
            var i = start
            while (i < src.length) {
                when {
                    !raw && src[i] == '\\' -> { blank(i, i + 2); i += 2 }
                    src.startsWith("\${", i) -> {
                        blank(i, i + 2)
                        val close = code(i + 2, inTemplate = true)
                        blank(close, close + 1)
                        i = close + 1
                    }
                    raw && src.startsWith("\"\"\"", i) -> {
                        var end = i + 3
                        while (end < src.length && src[end] == '"') end++
                        blank(i, end)
                        return end
                    }
                    !raw && src[i] == '"' -> { blank(i, i + 1); return i + 1 }
                    else -> { blank(i, i + 1); i++ }
                }
            }
            return i
        }
    }

    private companion object {
        val CALL = Regex("""\bProviderChatResult\(""")
        val USAGE_REPORTED = Regex("""(?:^|,)\s*usageReported\s*=(?!=)""")
    }
}
