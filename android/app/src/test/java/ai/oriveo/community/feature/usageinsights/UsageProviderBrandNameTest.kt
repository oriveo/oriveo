package ai.oriveo.community.feature.usageinsights

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Usage page provider names use the brand spelling for known kinds and only
 * capitalize the raw kind for unknown ones.
 */
class UsageProviderBrandNameTest {

    @Test
    fun known_kind_uses_brand_name() {
        assertEquals("OpenAI", usageProviderBrandName("openai"))
        assertEquals("OpenAI", usageProviderBrandName("openAI"))
        assertEquals("DeepSeek", usageProviderBrandName("deepseek"))
        assertEquals("OpenRouter", usageProviderBrandName("openrouter"))
        assertEquals("SiliconFlow", usageProviderBrandName("siliconFlow"))
    }

    @Test
    fun unknown_kind_falls_back_to_capitalized() {
        assertEquals("Acme", usageProviderBrandName("acme"))
        assertEquals("", usageProviderBrandName(""))
    }

    @Test
    fun no_titlecase_left() {
        val root = File("src/main/java/ai/oriveo/community/feature/usageinsights")
        val files = root.walkTopDown()
            .filter { it.isFile && it.extension == "kt" && it.name != "UsageProviderBrandName.kt" }
            .toList()
        assertTrue("no usage insights sources found, guard is not looking at the right directory", files.size > 5)
        val offenders = files.flatMap { file ->
            file.readLines().mapIndexedNotNull { index, line ->
                if (line.contains("replaceFirstChar")) "${file.name}:${index + 1}" else null
            }
        }
        assertTrue("provider names must go through usageProviderBrandName, found titlecase at: $offenders", offenders.isEmpty())
        val callers = files.count { it.readText().contains("usageProviderBrandName(") }
        assertTrue("expected usageProviderBrandName at the provider name sites, found in $callers files", callers >= 5)
    }
}
