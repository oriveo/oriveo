package ai.oriveo.community.core.app

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class NoteCaptureStringContractTest {

    @Test
    fun chatNoteCaptureEntryLabelsReuseSaveAsNoteCopy() {
        val valueFiles = File("src/main/res")
            .listFiles { file -> file.isDirectory && file.name.startsWith("values") }
            ?.map { File(it, "strings.xml") }
            ?.filter { it.exists() }
            .orEmpty()
            .sortedBy { it.path }

        assertTrue("expected Android resource string files", valueFiles.isNotEmpty())

        valueFiles.forEach { file ->
            val strings = parseStringResources(file)
            val saveAsNote = strings["notes_chat_save_as_note"]
                ?: error("${file.path} is missing notes_chat_save_as_note")

            listOf(
                "notes_chat_save_code_as_note",
                "notes_chat_add_selection_to_note",
                "notes_crosscheck_save",
            ).forEach { key ->
                val value = strings[key] ?: error("${file.path} is missing $key")
                assertEquals(
                    "${file.parentFile?.name ?: file.path}: $key must reuse notes_chat_save_as_note",
                    saveAsNote,
                    value,
                )
            }
        }
    }

    private fun parseStringResources(file: File): Map<String, String> {
        val document = DocumentBuilderFactory.newInstance()
            .newDocumentBuilder()
            .parse(file)
        val nodes = document.getElementsByTagName("string")
        return buildMap {
            for (index in 0 until nodes.length) {
                val element = nodes.item(index) as? Element ?: continue
                val name = element.getAttribute("name")
                if (name.isNotBlank()) {
                    put(name, element.textContent)
                }
            }
        }
    }
}
