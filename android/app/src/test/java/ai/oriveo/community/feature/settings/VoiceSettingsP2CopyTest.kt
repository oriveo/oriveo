package ai.oriveo.community.feature.settings

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The voice settings header and footers name the voice conversation, word for word from p2-copy.v1.json
 * (settingsKeyMap.android), in all 16 locales; the notification channel name ships in the same 16 locales.
 */
class VoiceSettingsP2CopyTest {
    private val copy: JsonObject = Json.parseToJsonElement(
        File("../../shared/voice-contracts/p2-copy.v1.json").readText(),
    ).jsonObject

    @Test
    fun settingsKeysMatchP2CopyInAllLocales() {
        val map = copy.obj("settingsKeyMap").obj("android")
        val pairs = map.keys.asSequence()
            .filterNot { it.startsWith("_") }
            .map { it to map.str(it) }
            .filterNot { it.second.startsWith("n/a") }
            .toList()
        assertEquals(4, pairs.size)
        for (locale in locales()) {
            val strings = strings(locale)
            for ((p2Key, androidKey) in pairs) {
                val expected = copy.obj("keys").obj(p2Key).obj("values").str(locale)
                assertEquals("$locale/$androidKey", expected, strings[androidKey])
            }
        }
    }

    @Test
    fun channelNameMatchesP2CopyInAllLocales() {
        val values = copy.obj("keys").obj("voice_conversation_channel_name").obj("values")
        assertEquals(16, locales().size)
        for (locale in locales()) {
            val actual = strings(locale)["voice_conversation_channel_name"]
            assertEquals(locale, values.str(locale), actual)
        }
        assertTrue(strings("zh-Hans")["voice_settings_header"]!!.contains("\u5b9e\u65f6\u8bed\u97f3"))
    }

    // Dictation live-update and failure-card copy follows p2-copy word for word; %1$@ becomes Android's %1$s, and "Done" uses the existing ✓ key.
    @Test
    fun dictationKeysMatchP2CopyInAllLocales() {
        val pairs = listOf(
            "voice_dictation_listening_placeholder", "voice_dictation_no_text_body",
            "voice_dictation_action_change_language", "voice_dictation_action_switch_engine",
            "voice_dictation_fail_network_title", "voice_dictation_fail_network_body",
            "voice_dictation_fail_busy_title", "voice_dictation_fail_busy_body",
            "voice_dictation_fail_language_title", "voice_dictation_fail_language_body",
            "voice_dictation_fail_no_service_title", "voice_dictation_fail_no_service_body",
            "voice_language_pack_prompt", "voice_language_pack_download", "voice_language_pack_downloading",
        ).map { it to it } + ("voice_dictation_done" to "voice_dictation_transcribe")
        for (locale in locales()) {
            val strings = strings(locale)
            for ((p2Key, androidKey) in pairs) {
                val expected = copy.obj("keys").obj(p2Key).obj("values").str(locale).replace("%1\$@", "%1\$s")
                assertEquals("$locale/$androidKey", expected, strings[androidKey])
            }
        }
    }

    // New voice conversation status words, voice hints and the recognition-language pill follow p2-copy word for word.
    @Test
    fun conversationKeysMatchP2CopyInAllLocales() {
        val keys = listOf(
            "voice_conversation_status_say_again", "voice_conversation_status_check_language",
            "voice_conversation_prompt_say_again", "voice_conversation_prompt_check_language",
            "voice_conversation_prompt_echo_hint", "voice_conversation_language_chip",
            "voice_conversation_language_chip_a11y_hint",
        )
        for (locale in locales()) {
            val strings = strings(locale, "strings_voice_conversation.xml")
            for (key in keys) {
                val expected = copy.obj("keys").obj(key).obj("values").str(locale).replace("%1\$@", "%1\$s")
                assertEquals("$locale/$key", expected, strings[key])
            }
        }
    }

    private fun locales(): List<String> = copy.getValue("locales").jsonArray.map { it.jsonPrimitive.content }

    private fun JsonObject.obj(key: String): JsonObject = getValue(key).jsonObject

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    private fun strings(locale: String, file: String = "strings_voice.xml"): Map<String, String> {
        val dir = when (locale) {
            "en" -> "values"
            "zh-Hans" -> "values-zh-rCN"
            "zh-Hant" -> "values-zh-rTW"
            "id" -> "values-in"
            "pt-BR" -> "values-pt-rBR"
            else -> "values-$locale"
        }
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(File("src/main/res/$dir/$file"))
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
