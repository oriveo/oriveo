package ai.oriveo.community.core.app

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * API key terminology in th / vi (resource-level contract).
 *
 * Older translations turned the API key into something else: a door key (th กุญแจ, vi chìa khóa),
 * a keyboard key (vi phím), an English/local duplicate ("API Key คีย์", "Khóa API Key"), or dropped
 * the key and kept only "API" ("กรอก API ของคุณ" reads as "enter your API"). The terms are th
 * "คีย์ API" and vi "khóa API".
 */
class ApiKeyTerminologyContractTest {

    private val resDir = File("src/main/res")

    private val wrongSense = mapOf(
        "values-th" to listOf(
            Regex("กุญแจ") to "กุญแจ is a door key",
            Regex("API Key คีย์|คีย์ API Key|API คีย์") to "duplicated or reversed term",
        ),
        "values-vi" to listOf(
            Regex("chìa khóa", RegexOption.IGNORE_CASE) to "chìa khóa is a physical key",
            Regex("phím API", RegexOption.IGNORE_CASE) to "phím is a keyboard key",
            Regex("khóa API Key", RegexOption.IGNORE_CASE) to "duplicated term",
        ),
    )

    /** API key in English; request header names such as x-api-key / x-goog-api-key do not count */
    private val englishApiKey = Regex("(?<![-\\w])API[ -]?keys?\\b", RegexOption.IGNORE_CASE)
    private val keepsKey = mapOf(
        "values-th" to Regex("คีย์|API ?Key", RegexOption.IGNORE_CASE),
        "values-vi" to Regex("khóa|API ?Key", RegexOption.IGNORE_CASE),
    )

    @Test
    fun `th and vi never render the key as a door key a keyboard key or a duplicate`() {
        val problems = wrongSense.flatMap { (dir, rules) ->
            strings(dir).flatMap { (name, value) ->
                rules.filter { (pattern, _) -> pattern.containsMatchIn(value) }.map { (_, why) -> "$dir/$name: $value ($why)" }
            }
        }
        assertTrue("API key translated as something else:\n" + problems.joinToString("\n"), problems.isEmpty())
    }

    @Test
    fun `th and vi keep the word key wherever English says API key`() {
        val english = strings("values")
        val problems = keepsKey.flatMap { (dir, keeps) ->
            strings(dir).filter { (name, value) ->
                englishApiKey.containsMatchIn(english[name].orEmpty()) && !keeps.containsMatchIn(value)
            }.map { (name, value) -> "$dir/$name: $value" }
        }
        assertTrue("English says API key but the translation only keeps \"API\":\n" + problems.joinToString("\n"), problems.isEmpty())
    }

    private fun strings(dir: String): Map<String, String> {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(File(resDir, "$dir/strings.xml"))
        val nodes = document.getElementsByTagName("string")
        return buildMap {
            for (index in 0 until nodes.length) {
                val element = nodes.item(index) as? Element ?: continue
                put(element.getAttribute("name"), element.textContent)
            }
        }
    }
}
