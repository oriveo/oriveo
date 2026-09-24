package ai.oriveo.community.core.app

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * Older translations turned hi buttons and short labels into bare infinitives (-ना), which read like
 * dictionary entries rather than buttons: Stop as रुकना, Default as गलती करना ("to make a mistake"),
 * Model as नमूना ("sample"). Buttons use the आप-register imperative (-एँ / -ें) and labels use nouns.
 */
class HindiButtonLabelContractTest {

    /** Words that end in -ना but are nouns or adjectives, not infinitives */
    private val nounsEndingInNa = mapOf(
        "महीना" to "month (noun)",
        "योजना" to "plan (noun)",
        "सालाना" to "yearly (adjective)",
        "नमूना" to "sample (noun)",
        "संरचना" to "composition (noun)",
    )
    private val devanagariWord = Regex("[\\u0900-\\u097F]+")

    @Test
    fun `hi short labels are not bare infinitives`() {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File("src/main/res/values-hi/strings.xml"))
        val nodes = document.getElementsByTagName("string")
        val problems = (0 until nodes.length)
            .mapNotNull { nodes.item(it) as? Element }
            .filter { looksLikeInfinitiveLabel(it.textContent) }
            .map { "${it.getAttribute("name")}: ${it.textContent}" }
        assertTrue("hi short labels read as infinitives (-ना); use an आप-register imperative or a noun:\n" + problems.joinToString("\n"), problems.isEmpty())
    }

    private fun looksLikeInfinitiveLabel(value: String): Boolean {
        val trimmed = value.trim()
        if (trimmed.split(Regex("\\s+")).size > 3) return false
        val last = devanagariWord.findAll(trimmed).lastOrNull()?.value ?: return false
        return last.endsWith("ना") && last !in nounsEndingInNa
    }
}
