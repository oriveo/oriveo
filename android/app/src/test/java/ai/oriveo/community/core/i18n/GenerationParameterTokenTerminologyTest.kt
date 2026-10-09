package ai.oriveo.community.core.i18n

import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * In the generation parameter panel, "token" means an LLM token, not a game chip or a notification
 * code. Translating it as an ordinary English word produces things like "Макс. жетонов" (chips) in
 * Russian or "Mã thông báo tối đa" (notification code) in Vietnamese.
 */
class GenerationParameterTokenTerminologyTest {

    // The Chinese entries are escaped: the access-token and linguistic-token words in each script.
    private val forbidden = mapOf(
        "values-ru" to listOf("жетон"),
        "values-tr" to listOf("jeton", "belirteç"),
        "values-vi" to listOf("mã thông báo"),
        "values-fr" to listOf("jeton"),
        "values-zh-rCN" to listOf("\u4ee4\u724c", "\u8bcd\u5143"),
        "values-zh-rTW" to listOf("\u6b0a\u6756", "\u8a5e\u5143"),
    )

    private val resDir: File by lazy {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(8) {
            val candidate = File(dir, "app/src/main/res")
            if (File(candidate, "values/strings.xml").exists()) return@lazy candidate
            dir = dir.parentFile ?: return@repeat
        }
        error("Cannot find Android res directory from ${System.getProperty("user.dir")}")
    }

    private fun isParameterPanelString(name: String) =
        name == "max_tokens" ||
            name.startsWith("generation_parameter_") ||
            name.startsWith("generation_group_")

    @Test
    fun `parameter panel strings do not translate token literally`() {
        val failures = mutableListOf<String>()
        var scanned = 0
        val factory = DocumentBuilderFactory.newInstance()
        forbidden.forEach { (dir, words) ->
            val document = factory.newDocumentBuilder().parse(File(resDir, "$dir/strings.xml"))
            val nodes = document.getElementsByTagName("string")
            for (i in 0 until nodes.length) {
                val element = nodes.item(i) as Element
                val name = element.getAttribute("name")
                if (!isParameterPanelString(name)) continue
                scanned++
                val value = element.textContent.orEmpty()
                words.filter { value.lowercase().contains(it) }.forEach { failures += "$dir/$name contains \"$it\": $value" }
            }
        }
        // Scanning almost nothing means the key prefixes or the path lookup broke; without this the test would pass forever.
        assertTrue("only $scanned parameter panel strings scanned", scanned >= forbidden.size * 50)
        assertTrue("token translated literally:\n${failures.joinToString("\n")}", failures.isEmpty())
    }
}
