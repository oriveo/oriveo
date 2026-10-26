package ai.oriveo.community.core.i18n

import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class LocalizationPlaceholderTokenTest {

    // Case-insensitive: a lowercase `zxph0qz` has leaked into production (27 Web strings showed it as button
    // text) and a case-sensitive regex caught none of them. Any such leak is a case variant from the
    // machine-translation pipeline, so block them all.
    private val tokenPattern = Regex("ZXPH\\d+QZ|__ORIVEO_TOKEN_", RegexOption.IGNORE_CASE)

    private val stringFileNames = listOf("strings.xml", "strings_voice.xml")

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
    fun `android string resources do not expose translation protection tokens`() {
        val failures = mutableListOf<String>()
        val factory = DocumentBuilderFactory.newInstance()

        resDir.listFiles { file -> file.isDirectory && file.name.startsWith("values") }
            .orEmpty()
            .sortedBy { it.name }
            .forEach { valuesDir ->
                stringFileNames.forEach fileLoop@{ fileName ->
                    val stringsFile = File(valuesDir, fileName)
                    if (!stringsFile.exists()) return@fileLoop

                    val nodeList = factory.newDocumentBuilder()
                        .parse(stringsFile)
                        .getElementsByTagName("string")
                    for (i in 0 until nodeList.length) {
                        val element = nodeList.item(i) as Element
                        val value = element.textContent.orEmpty()
                        if (tokenPattern.containsMatchIn(value)) {
                            failures += "${valuesDir.name}/$fileName/${element.getAttribute("name")}: $value"
                        }
                    }
                }
            }

        assertTrue(
            "Android localization placeholder tokens leaked:\n${failures.joinToString("\n")}",
            failures.isEmpty(),
        )
    }
}
