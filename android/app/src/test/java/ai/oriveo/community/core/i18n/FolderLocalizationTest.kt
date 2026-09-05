package ai.oriveo.community.core.i18n

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory


class FolderLocalizationTest {

    
    private val folderStringKeys = listOf(
        "folders",
        "new_folder",
        "folder_name",
        "create_folder",
        "rename_folder",
        "delete_folder",
        "delete_folder_title",
        "delete_folder_confirm",
        "move_to_folder",
        "remove_from_folder",
        "folder_created",
        "folder_deleted",
        "moved_to_folder",
        "batch_moved_to_folder",
        "removed_from_folder",
        "batch_removed_from_folder",
        "empty_folder",
        "empty_folder_hint",
        "search_in_folder",
        "view_all",
    )

    
    private val toastKeys = listOf(
        "folder_created",
        "folder_deleted",
        "moved_to_folder",
        "batch_moved_to_folder",
        "removed_from_folder",
        "batch_removed_from_folder",
    )

    
    private val emptyStateKeys = listOf(
        "empty_folder",
        "empty_folder_hint",
    )

    
    private val deleteConfirmKeys = listOf(
        "delete_folder_title",
        "delete_folder_confirm",
    )

    
    private val locales = mapOf(
        "values" to "English",
        "values-zh-rCN" to "Simplified Chinese",
        "values-zh-rTW" to "Traditional Chinese",
        "values-ja" to "Japanese",
        "values-ko" to "Korean",
        "values-es" to "Spanish",
        "values-fr" to "French",
        "values-de" to "German",
        "values-pt-rBR" to "Portuguese (Brazil)",
        "values-ar" to "Arabic",
        "values-hi" to "Hindi",
        "values-in" to "Indonesian",
        "values-vi" to "Vietnamese",
        "values-th" to "Thai",
        "values-tr" to "Turkish",
        "values-ru" to "Russian",
    )

    
    private val resDir: File by lazy {
        
        val projectDir = findProjectRoot()
        File(projectDir, "app/src/main/res").also {
            assertTrue("res directory not found at ${it.absolutePath}", it.exists())
        }
    }

    private fun findProjectRoot(): File {
        
        val candidates = listOf(
            
            System.getProperty("user.dir"),
            
            System.getProperty("project.dir"),
        )

        for (candidate in candidates) {
            if (candidate == null) continue
            var dir = File(candidate)
            
            repeat(10) {
                if (File(dir, "app/src/main/res/values/strings.xml").exists()) return dir
                dir = dir.parentFile ?: return@repeat
            }
        }

        
        val cwd = File(System.getProperty("user.dir") ?: ".")
        if (File(cwd, "app/src/main/res/values/strings.xml").exists()) return cwd

        error("Cannot find Android project root containing app/src/main/res/values/strings.xml")
    }

    
    private fun parseStrings(valuesDir: String): Map<String, String> {
        val file = File(resDir, "$valuesDir/strings.xml")
        if (!file.exists()) return emptyMap()

        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val nodeList = doc.getElementsByTagName("string")
        val map = mutableMapOf<String, String>()
        for (i in 0 until nodeList.length) {
            val element = nodeList.item(i) as Element
            val name = element.getAttribute("name")
            val value = element.textContent
            map[name] = value
        }
        return map
    }

    

    @Test
    fun `TC-24-1-1 all folder string resources exist in all 16 languages`() {
        val missing = mutableListOf<String>()

        for ((valuesDir, langName) in locales) {
            val strings = parseStrings(valuesDir)
            for (key in folderStringKeys) {
                if (key !in strings) {
                    missing.add("$langName ($valuesDir): missing '$key'")
                }
            }
        }

        assertTrue(
            "Missing folder string resources:\n${missing.joinToString("\n")}",
            missing.isEmpty(),
        )
    }

    

    @Test
    fun `TC-24-1-2 toast messages translated in all languages`() {
        val missing = mutableListOf<String>()

        for ((valuesDir, langName) in locales) {
            val strings = parseStrings(valuesDir)
            for (key in toastKeys) {
                if (key !in strings) {
                    missing.add("$langName ($valuesDir): missing toast key '$key'")
                }
            }
        }

        assertTrue(
            "Missing toast message translations:\n${missing.joinToString("\n")}",
            missing.isEmpty(),
        )
    }

    

    @Test
    fun `TC-24-1-3 empty state text translated in all languages`() {
        val missing = mutableListOf<String>()

        for ((valuesDir, langName) in locales) {
            val strings = parseStrings(valuesDir)
            for (key in emptyStateKeys) {
                if (key !in strings) {
                    missing.add("$langName ($valuesDir): missing empty state key '$key'")
                }
            }
        }

        assertTrue(
            "Missing empty state translations:\n${missing.joinToString("\n")}",
            missing.isEmpty(),
        )
    }

    

    @Test
    fun `TC-24-1-4 delete confirmation text translated in all languages`() {
        val missing = mutableListOf<String>()

        for ((valuesDir, langName) in locales) {
            val strings = parseStrings(valuesDir)
            for (key in deleteConfirmKeys) {
                if (key !in strings) {
                    missing.add("$langName ($valuesDir): missing delete confirm key '$key'")
                }
            }
        }

        assertTrue(
            "Missing delete confirmation translations:\n${missing.joinToString("\n")}",
            missing.isEmpty(),
        )
    }

    

    @Test
    fun `TC-24-1-5 all translations are non-empty`() {
        val empty = mutableListOf<String>()

        for ((valuesDir, langName) in locales) {
            val strings = parseStrings(valuesDir)
            for (key in folderStringKeys) {
                val value = strings[key]
                if (value != null && value.isBlank()) {
                    empty.add("$langName ($valuesDir): '$key' has empty value")
                }
            }
        }

        assertTrue(
            "Empty folder string values found:\n${empty.joinToString("\n")}",
            empty.isEmpty(),
        )
    }

    

    @Test
    fun `TC-24-1-6 format placeholders preserved in all translations`() {
        val keysWithPlaceholders = mapOf(
            "delete_folder_title" to listOf("%1\$s"),
            "folder_created" to listOf("%1\$s"),
            "moved_to_folder" to listOf("%1\$s"),
            "batch_moved_to_folder" to listOf("%1\$d", "%2\$s"),
            "batch_removed_from_folder" to listOf("%1\$d"),
        )
        val errors = mutableListOf<String>()

        for ((valuesDir, langName) in locales) {
            val strings = parseStrings(valuesDir)
            for ((key, placeholders) in keysWithPlaceholders) {
                val value = strings[key] ?: continue
                for (ph in placeholders) {
                    if (ph !in value) {
                        errors.add("$langName ($valuesDir): '$key' missing placeholder '$ph' in value '$value'")
                    }
                }
            }
        }

        assertTrue(
            "Missing format placeholders:\n${errors.joinToString("\n")}",
            errors.isEmpty(),
        )
    }

    

    @Test
    fun `TC-24-1-7 non-English translations differ from English`() {
        val englishStrings = parseStrings("values")
        val untranslated = mutableListOf<String>()

        for ((valuesDir, langName) in locales) {
            if (valuesDir == "values") continue
            val strings = parseStrings(valuesDir)
            
            var sameCount = 0
            for (key in folderStringKeys) {
                val engValue = englishStrings[key] ?: continue
                val localValue = strings[key] ?: continue
                if (engValue == localValue) sameCount++
            }
            
            if (sameCount > folderStringKeys.size / 2) {
                untranslated.add("$langName ($valuesDir): $sameCount/${folderStringKeys.size} strings identical to English")
            }
        }

        assertTrue(
            "Translations appear to be untranslated (too similar to English):\n${untranslated.joinToString("\n")}",
            untranslated.isEmpty(),
        )
    }
}
