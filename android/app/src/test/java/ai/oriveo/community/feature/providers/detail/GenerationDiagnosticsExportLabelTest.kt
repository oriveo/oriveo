package ai.oriveo.community.feature.providers.detail

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The generation parameter sheet exports **redacted diagnostics**, but the button borrowed the backup
 * page's "Export", so it had the same name as the button above it that really exports a backup and
 * did not say what it exports. All three apps now say "Export diagnostics".
 */
class GenerationDiagnosticsExportLabelTest {

    private val resDir = File("src/main/res")
    private val stringRegex = Regex("""<string\s+name="([^"]+)"[^>]*>(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)

    private fun strings(dir: String): Map<String, String> =
        stringRegex.findAll(File(resDir, "$dir/strings.xml").readText())
            .associate { it.groupValues[1] to it.groupValues[2] }

    @Test
    fun `diagnostics export button uses its own label`() {
        val source = File("src/main/java/ai/oriveo/community/feature/providers/detail/GenerationParameterDefaultsSheet.kt").readText()
        val start = source.indexOf("exportDiagnostics.launch(")
        assertTrue("diagnostics export button not found", start >= 0)
        val end = source.indexOf("TextButton(", start + 1).takeIf { it > 0 } ?: source.length
        val button = source.substring(start, end)
        assertTrue("the diagnostics export button does not use generation_diagnostics_export", button.contains("R.string.generation_diagnostics_export"))
        assertFalse("the diagnostics export button still uses the backup page's Export", button.contains("R.string.export_backup_title"))
    }

    @Test
    fun `diagnostics export label is written for every locale`() {
        val english = strings("values")["generation_diagnostics_export"]
        assertEquals("Export diagnostics", english)
        val locales = resDir.listFiles { f -> f.isDirectory && f.name.startsWith("values-") && File(f, "strings.xml").exists() }
            .orEmpty()
            .map { it.name }
            .sorted()
        assertEquals(15, locales.size)
        for (locale in locales) {
            val values = strings(locale)
            val label = values["generation_diagnostics_export"]
            assertTrue("$locale is missing generation_diagnostics_export", !label.isNullOrBlank())
            assertNotEquals("$locale is still English", english, label)
            assertNotEquals("$locale reads exactly like the backup page's Export", values["export_backup_title"], label)
        }
    }
}
