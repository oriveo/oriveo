package ai.oriveo.community.core.i18n

import org.junit.Assert.assertEquals
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class NotesProductLanguageTest {

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
    fun `note entry and detail labels explain saved chat notes`() {
        val en = strings("values")
        val zhHans = strings("values-zh-rCN")
        val zhHant = strings("values-zh-rTW")

        assertEquals("Saved note", en.getValue("notes_detail_body"))
        assertEquals("\u6536\u85cf\u7b14\u8bb0", zhHans.getValue("notes_detail_body"))
        assertEquals("\u6536\u85cf\u7b46\u8a18", zhHant.getValue("notes_detail_body"))
        assertEquals("Save chat content as notes", en.getValue("notes_subtitle"))
        assertEquals("\u628a\u804a\u5929\u5185\u5bb9\u5b58\u6210\u7b14\u8bb0", zhHans.getValue("notes_subtitle"))
        assertEquals("Save chat content as notes", en.getValue("notes_empty_description"))
        assertEquals("\u628a\u804a\u5929\u5185\u5bb9\u5b58\u6210\u7b14\u8bb0", zhHans.getValue("notes_empty_description"))
    }

    private fun strings(valuesDirName: String): Map<String, String> {
        val file = File(File(resDir, valuesDirName), "strings.xml")
        val nodes = DocumentBuilderFactory.newInstance()
            .newDocumentBuilder()
            .parse(file)
            .getElementsByTagName("string")
        return buildMap {
            for (i in 0 until nodes.length) {
                val element = nodes.item(i) as Element
                put(element.getAttribute("name"), element.textContent)
            }
        }
    }
}
