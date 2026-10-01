package ai.oriveo.community.core.i18n

import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Full-width punctuation belongs to Chinese and Japanese only. Copying it into other languages gives
 * labels like "Top P（Parameter）". Apart from zh-rCN, zh-rTW and ja, no locale (the default English
 * included) may contain these full-width marks.
 */
class FullwidthPunctuationLocalizationTest {

    private val cjkDirs = setOf("values-zh-rCN", "values-zh-rTW", "values-ja")
    private val fullwidth = Regex("[（）。，：；！？「」、]")

    private val resDir: File by lazy {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(8) {
            val candidate = File(dir, "app/src/main/res")
            if (File(candidate, "values/strings.xml").exists()) return@lazy candidate
            dir = dir.parentFile ?: return@repeat
        }
        error("Cannot find Android res directory from ${System.getProperty("user.dir")}")
    }

    @Test
    fun `non CJK string resources contain no fullwidth punctuation`() {
        val failures = mutableListOf<String>()
        val factory = DocumentBuilderFactory.newInstance()
        val dirs = resDir.listFiles { file -> file.isDirectory && file.name.startsWith("values") && file.name !in cjkDirs }
            .orEmpty()
            .filter { File(it, "strings.xml").exists() }
            .sortedBy { it.name }
        // Finding almost no directories means the path lookup broke; without this the test would pass forever.
        assertTrue("only ${dirs.size} non-CJK values directories found", dirs.size >= 13)

        dirs.forEach { valuesDir ->
            val document = factory.newDocumentBuilder().parse(File(valuesDir, "strings.xml"))
            // Check string, string-array items and plurals items alike.
            listOf("string", "item").forEach { tag ->
                val nodes = document.getElementsByTagName(tag)
                for (i in 0 until nodes.length) {
                    val element = nodes.item(i) as Element
                    val value = element.textContent.orEmpty()
                    if (fullwidth.containsMatchIn(value)) {
                        val name = element.getAttribute("name").ifEmpty {
                            (element.parentNode as? Element)?.getAttribute("name").orEmpty()
                        }
                        failures += "${valuesDir.name}/$name: $value"
                    }
                }
            }
        }

        assertTrue(
            "full-width punctuation outside Chinese and Japanese:\n${failures.joinToString("\n")}",
            failures.isEmpty(),
        )
    }
}
