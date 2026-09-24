package ai.oriveo.community.ui.component

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * What TalkBack announces for the reveal toggle on secret fields (source-level contract).
 *
 * Unit tests here have no compose-ui-test dependency and cannot read the real semantics tree,
 * so this asserts on the production source with comments stripped and reads the 16 strings.xml
 * files directly.
 *
 * The show/hide button used to hard-code "Show password" / "Hide password" as its
 * contentDescription: TalkBack users in other languages heard English, and API key fields were
 * announced as passwords.
 */
class SecureFieldAccessibilityContractTest {

    private val fieldPath = "ui/component/OriveoLabeledField.kt"
    private val showKey = "secure_field_show"
    private val hideKey = "secure_field_hide"

    @Test
    fun `secure field visibility toggle reads its label from string resources`() {
        val code = codeWithoutComments(fieldPath)

        val literalDescription = Regex("contentDescription\\s*=[^\\n]*\"").find(code)?.value
        assertEquals(
            "$fieldPath must not use a literal contentDescription; non-English TalkBack would read English: $literalDescription",
            null,
            literalDescription,
        )
        assertFalse("$fieldPath still has a hard-coded English label", code.contains("Show password") || code.contains("Hide password"))
        assertTrue(
            "the visibility toggle must pick R.string.$showKey / R.string.$hideKey by its current state",
            code.contains("stringResource(") &&
                code.contains("R.string.$showKey") &&
                code.contains("R.string.$hideKey"),
        )
    }

    @Test
    fun `secure field toggle labels exist in every locale and differ by state`() {
        val files = stringFiles()
        assertEquals("expected the default plus 15 locales, 16 strings.xml files", 16, files.size)

        val english = parseStrings(File(resDir, "values/strings.xml"))
        val englishShow = english[showKey] ?: error("values/strings.xml is missing $showKey")
        val englishHide = english[hideKey] ?: error("values/strings.xml is missing $hideKey")

        files.forEach { (dir, file) ->
            val strings = parseStrings(file)
            val show = strings[showKey]?.trim().orEmpty()
            val hide = strings[hideKey]?.trim().orEmpty()
            assertTrue("$dir is missing $showKey", show.isNotEmpty())
            assertTrue("$dir is missing $hideKey", hide.isNotEmpty())
            assertNotEquals("$dir reads the show and hide states the same", show, hide)
            if (dir != "values") {
                assertNotEquals("$dir reuses the English $showKey", englishShow, show)
                assertNotEquals("$dir reuses the English $hideKey", englishHide, hide)
            }
        }
    }

    private val resDir = File("src/main/res")

    private fun stringFiles(): List<Pair<String, File>> =
        resDir.listFiles { f -> f.isDirectory && f.name.startsWith("values") }
            .orEmpty()
            .mapNotNull { dir -> File(dir, "strings.xml").takeIf { it.exists() }?.let { dir.name to it } }
            .sortedBy { it.first }

    private fun parseStrings(file: File): Map<String, String> {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val nodes = document.getElementsByTagName("string")
        return buildMap {
            for (index in 0 until nodes.length) {
                val element = nodes.item(index) as? Element ?: continue
                val name = element.getAttribute("name")
                if (name.isNotBlank()) put(name, element.textContent)
            }
        }
    }

    private fun source(relativePath: String): String =
        File("src/main/java/ai/oriveo/community/$relativePath").readText()

    /** Code with comments stripped; comments may quote the old wording without failing the check. */
    private fun codeWithoutComments(relativePath: String): String =
        source(relativePath)
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lineSequence()
            .joinToString("\n") { it.substringBefore("//") }
}
