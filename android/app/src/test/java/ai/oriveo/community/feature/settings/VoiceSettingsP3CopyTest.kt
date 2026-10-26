package ai.oriveo.community.feature.settings

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Voice conversation engine copy: every key in p3-copy.v1.json (settingsKeyMap.android) ships word for word
 * in all 16 locales; `%1$@` is written back as `%1$s`.
 */
class VoiceSettingsP3CopyTest {
    private val copy: JsonObject = Json.parseToJsonElement(
        File("../../shared/voice-contracts/p3-copy.v1.json").readText(),
    ).jsonObject

    @Test
    fun realtimeKeysMatchP3CopyInAllLocales() {
        val map = copy.obj("settingsKeyMap").obj("android")
        val pairs = map.keys.filterNot { it.startsWith("_") }.map { it to map.str(it) }
        assertEquals(9, pairs.size)
        assertEquals(16, locales().size)
        for (locale in locales()) {
            val strings = strings(locale)
            for ((p3Key, androidKey) in pairs) {
                val expected = copy.obj("keys").obj(p3Key).obj("values").str(locale).replace("%1\$@", "%1\$s")
                assertEquals("$locale/$androidKey", expected, strings[androidKey])
            }
        }
    }

    private fun locales(): List<String> = copy.getValue("locales").jsonArray.map { it.jsonPrimitive.content }

    private fun JsonObject.obj(key: String): JsonObject = getValue(key).jsonObject

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    private fun strings(locale: String): Map<String, String> {
        val dir = when (locale) {
            "en" -> "values"
            "zh-Hans" -> "values-zh-rCN"
            "zh-Hant" -> "values-zh-rTW"
            "id" -> "values-in"
            "pt-BR" -> "values-pt-rBR"
            else -> "values-$locale"
        }
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(File("src/main/res/$dir/strings_voice.xml"))
        val nodes = doc.getElementsByTagName("string")
        return (0 until nodes.length).associate { i ->
            val node = nodes.item(i)
            node.attributes.getNamedItem("name").nodeValue to unescape(node.textContent)
        }
    }

    // Android resource escapes: \' \" \\ and a leading \@ / \?.
    private fun unescape(raw: String): String = buildString {
        var i = 0
        while (i < raw.length) {
            val c = raw[i]
            if (c == '\\' && i + 1 < raw.length) {
                append(raw[i + 1])
                i += 2
            } else {
                append(c)
                i++
            }
        }
    }
}
