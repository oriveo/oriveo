package ai.oriveo.community.core.app

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * In data-related strings, local means "on this device". Older translations used the geographic
 * sense ("area / region"): th "ข้อมูลท้องถิ่น" or "ในพื้นที่", vi "địa phương", which read as data
 * belonging to a place. Local time (th เวลาท้องถิ่น, vi giờ địa phương) and local network
 * (th เครือข่ายท้องถิ่น) really mean that and are allowed.
 */
class LocalMeaningContractTest {

    private val geographic = mapOf(
        "values-th" to Regex("(?<!เวลา|เครือข่าย)ท้องถิ่น|ในพื้นที่"),
        "values-vi" to Regex("(?<!giờ )địa phương", RegexOption.IGNORE_CASE),
    )
    private val englishLocal = Regex("\\blocal\\b", RegexOption.IGNORE_CASE)

    @Test
    fun `th and vi do not render local data as a geographic place`() {
        val english = strings("values")
        val problems = geographic.flatMap { (dir, pattern) ->
            strings(dir).filter { (name, value) ->
                englishLocal.containsMatchIn(english[name].orEmpty()) && pattern.containsMatchIn(value)
            }.map { (name, value) -> "$dir/$name: $value" }
        }
        assertTrue("local translated in its geographic sense:\n" + problems.joinToString("\n"), problems.isEmpty())
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
