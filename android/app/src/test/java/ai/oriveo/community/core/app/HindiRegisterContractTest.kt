package ai.oriveo.community.core.app

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * When the app speaks to the user, hi uses the आप register. Older translations left तुम-register -ओ
 * imperatives ("विवरण छुपाओ", "सबको अचयनित करो", "हटो और स्केल करो") that read as ordering the user
 * around. Quick prompts the user sends to the assistant ("सरलता से समझाओ") are in the user's own
 * voice and are not in this word list.
 */
class HindiRegisterContractTest {

    private val tumImperatives = listOf("करो", "जाओ", "हटाओ", "हटो", "छुपाओ", "छिपाओ", "दिखाओ", "देखो", "चुनो", "रखो", "बदलो", "भेजो")
    private val word = Regex("(?<![\\u0900-\\u097F])(${tumImperatives.joinToString("|")})(?![\\u0900-\\u097F])")

    @Test
    fun `hi does not order the user around with tum imperatives`() {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File("src/main/res/values-hi/strings.xml"))
        val nodes = document.getElementsByTagName("string")
        val problems = (0 until nodes.length)
            .mapNotNull { nodes.item(it) as? Element }
            .filter { word.containsMatchIn(it.textContent) }
            .map { "${it.getAttribute("name")}: ${it.textContent}" }
        assertTrue("hi still has तुम-register imperatives; use the आप register (-एँ / -ें):\n" + problems.joinToString("\n"), problems.isEmpty())
    }
}
