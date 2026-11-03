package ai.oriveo.community.ui.util

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Long model IDs wrap only after "-", "_" and "/"; sample values mirror the iOS test. */
class ModelIdBreaksTest {

    @Test
    fun modelIdBreaksAtSeparators() {
        assertEquals(
            "gemini-​3.8-​live-​extended-​thinking",
            modelIdDisplay("gemini-3.8-live-extended-thinking"),
        )
        assertEquals("a_​b/​c", modelIdDisplay("a_b/c"))
        // No separator, no change: never break inside a word
        assertEquals("gpt4o", modelIdDisplay("gpt4o"))
    }

    @Test
    fun accessibilityUsesRawId() {
        val id = "gemini-3.8-live-extended-thinking"
        // Display only: removing U+200B yields the raw id
        assertEquals(id, modelIdDisplay(id).replace("​", ""))

        val picker = source("feature/modelpicker/ModelPickerSheet.kt")
        val row = picker.slice("private fun ModelPickerRow(", "fun buildProviderSections(")
        assertTrue(row.contains("val title = modelIdDisplay(rawTitle)"))
        assertTrue(row.contains("contentDescription = rawTitle"))
        val realtime = picker.slice("internal fun ModelPickerRealtimeRow(", "private fun ModelPickerRealtimeFilterChip(")
        assertTrue(realtime.contains("text = modelIdDisplay(entry.model)"))
        assertTrue(realtime.contains("contentDescription = entry.model"))
        assertTrue(realtime.contains("overflow = TextOverflow.Ellipsis"))

        val detail = source("feature/providers/detail/ProviderDetailRealtimeModels.kt")
            .slice("private fun ProviderDetailRealtimeModelRow(", "if (row.checked)")
        assertTrue(detail.contains("text = modelIdDisplay(row.entry.model)"))
        assertTrue(detail.contains("contentDescription = row.entry.model"))
        assertTrue(detail.contains("maxLines = 2"))
    }

    private fun source(path: String) = File("src/main/java/ai/oriveo/community/$path").readText()

    private fun String.slice(from: String, to: String): String {
        val start = indexOf(from)
        check(start >= 0) { "missing $from" }
        val end = indexOf(to, start)
        check(end > start) { "missing $to" }
        return substring(start, end)
    }
}
