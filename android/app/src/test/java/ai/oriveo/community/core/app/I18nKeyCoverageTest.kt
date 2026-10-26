package ai.oriveo.community.core.app

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * i18n key coverage check: a locale missing a key silently falls back to English at runtime (this
 * has previously accumulated 40-98 missing keys unnoticed, including a whole set of error copy).
 * Any new key must be backfilled to every locale at the same time; this test is the gate that
 * catches it.
 */
class I18nKeyCoverageTest {

    private val resDir = File("src/main/res")

    private val elementRegex =
        Regex("""<string\s+name="([^"]+)"([^>]*)>(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)

    /** key to text; excludeNonTranslatable only applies to the default locale. */
    private fun entries(file: File, excludeNonTranslatable: Boolean): Map<String, String> {
        return elementRegex.findAll(file.readText())
            .filter { !excludeNonTranslatable || !it.groupValues[2].contains("translatable=\"false\"") }
            .associate { it.groupValues[1] to it.groupValues[3] }
    }

    /** Resource files covered by the check; each is compared only with the same-named file under values/. */
    private val stringFileNames = listOf("strings.xml", "strings_voice.xml")

    /** Locales are the values-* directories that contain strings.xml; a missing same-named file is reported by the caller. */
    private fun localeStringFiles(fileName: String): List<Pair<String, File>> =
        resDir.listFiles { f -> f.isDirectory && f.name.startsWith("values-") && File(f, "strings.xml").exists() }
            .orEmpty()
            .map { dir -> dir.name to File(dir, fileName) }
            .sortedBy { it.first }

    @Test
    fun `all locales cover every translatable key`() {
        val problems = StringBuilder()
        for (fileName in stringFileNames) {
            val base = entries(File(resDir, "values/$fileName"), excludeNonTranslatable = true).keys
            assertTrue("the default $fileName should not be empty", base.isNotEmpty())

            for ((locale, file) in localeStringFiles(fileName)) {
                if (!file.exists()) {
                    problems.append("$locale/$fileName is missing\n")
                    continue
                }
                val missing = base - entries(file, excludeNonTranslatable = false).keys
                if (missing.isNotEmpty()) {
                    problems.append("$locale/$fileName is missing ${missing.size} key(s): ${missing.sorted().take(10)}\n")
                }
            }
        }
        assertTrue("the following locales are missing keys; any new copy must be translated for all of them:\n$problems", problems.isEmpty())
    }

    @Test
    fun `locale placeholders match the default locale`() {
        // a missing or misspelled placeholder crashes outright, or renders misaligned, at getString(resId, args)
        val placeholderRegex = Regex("""%\d+\$[sdf]|%[sdf]""")
        val problems = StringBuilder()
        for (fileName in stringFileNames) {
            val base = entries(File(resDir, "values/$fileName"), excludeNonTranslatable = true)
            for ((locale, file) in localeStringFiles(fileName)) {
                if (!file.exists()) continue // reported by the coverage check
                for ((key, text) in entries(file, excludeNonTranslatable = false)) {
                    val baseText = base[key] ?: continue
                    val expected = placeholderRegex.findAll(baseText).map { it.value }.toSet()
                    val actual = placeholderRegex.findAll(text).map { it.value }.toSet()
                    if (expected == actual) continue
                    // with a single placeholder, %d and %1$d are equivalent (an existing translation using the positional form is safe; allow it)
                    if (expected.size <= 1 && actual.size <= 1) {
                        val normalize = { s: Set<String> -> s.map { it.last() }.toSet() }
                        if (normalize(expected) == normalize(actual)) continue
                    }
                    problems.append("$locale/$fileName/$key: expected $expected, actual $actual\n")
                }
            }
        }
        assertTrue("the following translations have placeholders that don't match the default locale:\n$problems", problems.isEmpty())
    }
}
