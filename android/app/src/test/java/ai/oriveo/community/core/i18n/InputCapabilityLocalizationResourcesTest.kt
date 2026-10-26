package ai.oriveo.community.core.i18n

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertTrue
import org.junit.Assume
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The input-capability copy (disabled reasons / first hint / one-tap resend / bubble annotation) reuses the Web `capability.input.*` strings verbatim in all 16 languages.
 */
class InputCapabilityLocalizationResourcesTest {

    private val localeByValuesDir = linkedMapOf(
        "values" to "en",
        "values-zh-rCN" to "zh-Hans",
        "values-zh-rTW" to "zh-Hant",
        "values-ja" to "ja",
        "values-ko" to "ko",
        "values-es" to "es",
        "values-fr" to "fr",
        "values-de" to "de",
        "values-pt-rBR" to "pt-BR",
        "values-ar" to "ar",
        "values-hi" to "hi",
        "values-in" to "id",
        "values-vi" to "vi",
        "values-th" to "th",
        "values-tr" to "tr",
        "values-ru" to "ru",
    )

    private val expectedKeys = buildList {
        listOf("image", "file", "video").forEach { add("capability_input_hint_first_attach_$it") }
        listOf("model_absent", "wire_not_implemented", "kill_switch", "rejected_recently", "user_removed")
            .forEach { reason -> listOf("image", "file", "video").forEach { add("capability_input_disabled_${reason}_$it") } }
        listOf("image", "file", "video").forEach { add("capability_input_resend_without_$it") }
        add("capability_input_bubble_not_sent_to_model")
    }

    private val androidRoot: File by lazy {
        var dir = File(System.getProperty("user.dir") ?: ".").absoluteFile
        repeat(8) {
            if (File(dir, "app/src/main/res/values/strings.xml").exists()) return@lazy dir
            dir = dir.parentFile ?: return@repeat
        }
        error("Cannot find Android project root from ${System.getProperty("user.dir")}")
    }

    private val webMessagesDir: File by lazy {
        File(androidRoot.parentFile, "web/apps/app/messages")
    }

    private fun parseStrings(valuesDir: String): Map<String, String> {
        val file = File(androidRoot, "app/src/main/res/$valuesDir/strings_input_capability.xml")
        if (!file.exists()) return emptyMap()
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val nodeList = doc.getElementsByTagName("string")
        val map = mutableMapOf<String, String>()
        for (i in 0 until nodeList.length) {
            val element = nodeList.item(i) as Element
            // The DOM has already restored &amp;; restore apostrophes by the Android string resource rules.
            map[element.getAttribute("name")] = element.textContent.replace("\\'", "'")
        }
        return map
    }

    private fun snake(segment: String): String =
        segment.replace(Regex("([A-Z])")) { "_" + it.value.lowercase() }

    private fun flatten(node: JsonObject, prefix: String, out: MutableMap<String, String>) {
        node.forEach { (key, value) ->
            val name = prefix + "_" + snake(key)
            when (value) {
                is JsonObject -> flatten(value, name, out)
                is JsonPrimitive -> out[name] = value.content
                else -> out[name] = value.toString()
            }
        }
    }

    private fun webStrings(locale: String): Map<String, String>? {
        val json = Json.parseToJsonElement(File(webMessagesDir, "$locale.json").readText()).jsonObject
        val out = mutableMapOf<String, String>()
        val input = json.getValue("capability").jsonObject["input"]?.jsonObject ?: return null
        flatten(input, "capability_input", out)
        return out
    }

    @Test
    fun `input capability strings match web copy in all 16 locales`() {
        assertTrue(expectedKeys.size == 22)
        // The web copy this test compares against ships with the web client; skip until the web tree carries capability.input.
        Assume.assumeTrue("web messages carry no capability.input yet", webStrings("en") != null)
        val failures = mutableListOf<String>()
        localeByValuesDir.forEach { (valuesDir, locale) ->
            val android = parseStrings(valuesDir)
            val web = webStrings(locale).orEmpty()
            if (web.keys != expectedKeys.toSet()) {
                failures += "web $locale capability.input keys drifted: ${web.keys.sorted()}"
            }
            expectedKeys.forEach { key ->
                val value = android[key]
                when {
                    value == null -> failures += "$valuesDir missing $key"
                    value.isBlank() -> failures += "$valuesDir has blank $key"
                    value != web[key] -> failures += "$valuesDir $key differs from web $locale: $value != ${web[key]}"
                }
            }
        }
        assertTrue("Input capability localization drift:\n${failures.joinToString("\n")}", failures.isEmpty())
    }
}
