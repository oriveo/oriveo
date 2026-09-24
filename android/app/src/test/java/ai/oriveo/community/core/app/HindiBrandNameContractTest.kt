package ai.oriveo.community.core.app

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * The brand name Oriveo stays in Latin in every language. Older hi strings transliterated it as
 * "ओरिवियो". Other languages may drop the subject, so only hi is required to keep Oriveo wherever
 * the English names it.
 */
class HindiBrandNameContractTest {

    private val transliteration = Regex("ओर[िी]व")

    @Test
    fun `hi keeps the brand name in Latin`() {
        val english = strings("values")
        val problems = strings("values-hi").filter { (name, value) ->
            transliteration.containsMatchIn(value) ||
                (english[name].orEmpty().contains("Oriveo") && !value.contains("Oriveo"))
        }.map { (name, value) -> "$name: $value" }
        assertTrue("hi transliterates or drops the brand name; keep Oriveo as is:\n" + problems.joinToString("\n"), problems.isEmpty())
    }

    private fun strings(dir: String): Map<String, String> {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File("src/main/res/$dir/strings.xml"))
        val nodes = document.getElementsByTagName("string")
        return buildMap {
            for (index in 0 until nodes.length) {
                val element = nodes.item(index) as? Element ?: continue
                put(element.getAttribute("name"), element.textContent)
            }
        }
    }
}
