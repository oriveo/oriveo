package ai.oriveo.community.feature.providers.detail

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
/**
 * Naming and layout gate for the provider detail/add screen's settings entries.
 *
 * 1. **Two rows in the same settings card both labeled "advanced settings"**: it was already
 *    known that an official provider would show two rows with the same name and icon, and only
 *    the icon was changed (`Tune` to `Settings`) at the time, leaving the label collision in
 *    place -- a non-relay provider uses `advanced_settings`, while the next row,
 *    `generation_model_behavior`, resolves to the same label. So all 15 official providers
 *    really do show two identically named rows, and tapping the first one actually opens the
 *    connection info sheet.
 * 2. **`OriveoCard`'s content lambda is a Box scope**: dropping multiple `Text` calls straight
 *    into the card makes them all stack on top of each other in the top-left corner, and any
 *    `Spacer(height)` between them produces zero pixels of separation (the provider name and
 *    the autofill hint on the connection info card visibly ran together). This kind of layout
 *    collapse doesn't throw or crash -- only a real screenshot reveals it, so it's pinned down
 *    here in source instead.
 */
class ProviderSettingsEntryNamingTest {

    private companion object {
        const val CARD = "OriveoCard"
        val SKIP = listOf("}", ")", "]", "//", "*", ".")
    }

    // -- naming: an entry's label must match the destination page's name; no two rows on one screen may share a label --

    /** The connection row is always "connection settings", regardless of relay vs official -- matches the shape of iOS's `ProviderSettingsRow.connection`. */
    @Test
    fun `the connection row is always named connection settings`() {
        val card = repoFile("feature/providers/detail/ProviderDetailSettingsCard.kt").readText()
        assertTrue(
            "the connection row must use provider_detail_connection_settings",
            card.contains("R.string.provider_detail_connection_settings"),
        )
        assertFalse(
            "the settings card must not branch on relay to produce an \"advanced settings\" title -- that's exactly how the two rows end up sharing a label",
            card.contains("R.string.advanced_settings"),
        )
    }

    /** "Advanced settings" is reserved for the generation-parameters page; connection-related pages must never reuse that name. */
    @Test
    fun `connection pages never borrow the advanced settings name`() {
        listOf(
            "feature/providers/detail/ProviderDetailScreen.kt",
            "feature/providers/setup/ProviderSetupScreen.kt",
        ).forEach { relative ->
            val source = repoFile(relative).readText()
            assertFalse(
                "$relative still uses R.string.advanced_settings to label a connection-related entry or page",
                Regex("""R\.string\.advanced_settings\b""").containsMatchIn(source),
            )
        }
    }

    /** The entry button opens the connection settings sheet, so both must reference the same key. */
    @Test
    fun `the setup entry button and its sheet share one name`() {
        val setup = repoFile("feature/providers/setup/ProviderSetupScreen.kt").readText()
        assertEquals(
            "the add-provider screen's entry button and the sheet it opens must both use provider_detail_connection_settings",
            2,
            Regex("""R\.string\.provider_detail_connection_settings""").findAll(setup).count(),
        )
    }

    /** The two rows' **values** must never collide in any of the 16 languages -- distinct keys alone don't prevent this; the user reads the resolved value. */
    @Test
    fun `connection settings and advanced settings never collide in any language`() {
        val collisions = valuesDirs().mapNotNull { dir ->
            val strings = File(dir, "strings.xml").takeIf { it.exists() }?.readText() ?: return@mapNotNull null
            val connection = stringValue(strings, "provider_detail_connection_settings")
            val advanced = stringValue(strings, "generation_model_behavior")
            if (connection != null && advanced != null && connection == advanced) {
                "${dir.name}: both rows are labeled \"$connection\""
            } else {
                null
            }
        }
        assertEquals("no two rows on the same settings card may share a label", emptyList<String>(), collisions)
    }

    // -- layout: OriveoCard's content is a Box scope --

    /**
     * A card with more than one top-level child must wrap them in its own Column/Row --
     * `OriveoCard` places its content in a Box, so without a wrapper everything stacks on top
     * of everything else. The scan has to balance parentheses before looking for the lambda:
     * many `OriveoCard(` call sites in this codebase span multiple lines, and a regex that only
     * matches the single-line `OriveoCard {` form would miss all of them.
     */
    @Test
    fun `every OriveoCard with multiple children wraps them in a layout container`() {
        val offenders = sourceRoot().walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { file -> boxScopeOffenders(file).map { "${file.name}:${it.first} has ${it.second} top-level children, which will stack on top of each other in the Box" } }
            .toList()
        assertEquals("multi-element OriveoCard content must be wrapped in a Column/Row", emptyList<String>(), offenders)
    }

    /** Returns (line number, top-level child count), reporting only call sites with more than one. The declaration `fun OriveoCard(` itself doesn't count as a call. */
    private fun boxScopeOffenders(file: File): List<Pair<Int, Int>> {
        val source = file.readText()
        val lines = source.lines()
        val lineStart = IntArray(lines.size)
        var acc = 0
        lines.forEachIndexed { index, line -> lineStart[index] = acc; acc += line.length + 1 }
        fun lineOf(position: Int): Int {
            var low = 0
            var high = lines.lastIndex
            while (low < high) {
                val mid = (low + high + 1) / 2
                if (lineStart[mid] <= position) low = mid else high = mid - 1
            }
            return low
        }

        val offenders = mutableListOf<Pair<Int, Int>>()
        var search = source.indexOf(CARD)
        while (search >= 0) {
            val afterName = search + CARD.length
            if (source.substring(maxOf(0, search - 4), search).trimEnd().endsWith("fun")) {
                search = source.indexOf(CARD, afterName)
                continue
            }
            var cursor = afterName
            while (cursor < source.length && source[cursor].isWhitespace()) cursor++
            if (cursor < source.length && source[cursor] == '(') {
                var depth = 0
                while (cursor < source.length) {
                    if (source[cursor] == '(') depth++
                    if (source[cursor] == ')') {
                        depth--
                        if (depth == 0) { cursor++; break }
                    }
                    cursor++
                }
                while (cursor < source.length && source[cursor].isWhitespace()) cursor++
            }
            if (cursor >= source.length || source[cursor] != '{') {
                search = source.indexOf(CARD, afterName)
                continue
            }
            val headerLine = lineOf(search)
            val baseIndent = lines[headerLine].indexOfFirst { !it.isWhitespace() }
            val childIndent = baseIndent + 4
            var children = 0
            var row = lineOf(cursor) + 1
            while (row < lines.size) {
                val current = lines[row]
                val trimmed = current.trim()
                if (trimmed.isEmpty()) { row++; continue }
                val indent = current.indexOfFirst { !it.isWhitespace() }
                if (indent <= baseIndent && trimmed.startsWith("}")) break
                if (indent == childIndent && SKIP.none { trimmed.startsWith(it) }) children++
                row++
            }
            if (children > 1) offenders += (headerLine + 1) to children
            search = source.indexOf(CARD, afterName)
        }
        return offenders
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    private fun stringValue(xml: String, name: String): String? =
        Regex("""<string name="$name">(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)
            .find(xml)?.groupValues?.get(1)

    private fun valuesDirs(): List<File> =
        resRoot().listFiles()!!.filter { it.isDirectory && it.name.startsWith("values") }.sortedBy { it.name }

    private fun resRoot(): File =
        File(sourceRoot().parentFile!!.parentFile!!.parentFile!!.parentFile!!, "res")

    /** `.../java/ai/oriveo/community` */
    private fun sourceRoot(): File =
        repoFile("feature/providers/detail/ProviderDetailSettingsCard.kt")
            .parentFile!!.parentFile!!.parentFile!!.parentFile!!

    private fun repoFile(relative: String): File {
        val direct = File("src/main/java/ai/oriveo/community/$relative")
        if (direct.exists()) return direct
        var dir = File(System.getProperty("user.dir")!!).absoluteFile
        val prefix = "android/app/src/main/java/ai/oriveo/community/"
        while (true) {
            val candidate = File(dir, prefix + relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile ?: break
        }
        error("could not find $relative")
    }
}
