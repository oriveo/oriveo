package ai.oriveo.community.core.voice

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Checks the production functions against every case group in shared/voice-contracts/speakable-text.v1.json, plus prefix stability at every code point. */
class SpeakableTextContractTest {

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/speakable-text.v1.json").readText()).jsonObject

    private fun cases(key: String): List<JsonObject> = fixture[key]!!.jsonArray.map { it.jsonObject }

    private fun JsonObject.str(key: String): String? = this[key].let { el ->
        if (el == null || el is JsonNull) null else el.jsonPrimitive.content
    }

    private fun expectedSegments(case: JsonObject): List<SpeakableSegment> =
        case["expected"]!!.jsonArray.map { el ->
            val obj = el.jsonObject
            when (obj.str("kind")) {
                "sentence" -> SpeakableSegment.Sentence(obj.str("text")!!)
                "placeholder" -> SpeakableSegment.Placeholder(
                    SpeakablePlaceholder.entries.first { it.rawValue == obj.str("placeholder") },
                )
                else -> error("unknown kind: $obj")
            }
        }

    private fun assertCases(key: String) {
        val all = cases(key)
        assertTrue("$key must not be empty", all.isNotEmpty())
        for (case in all) {
            val input = case["input"]!!.jsonObject
            val text = input.str("text")!!
            val final = input["final"]!!.jsonPrimitive.content.toBooleanStrict()
            assertEquals(case.str("id"), expectedSegments(case), speakableSegments(text, final))
        }
    }

    @Test
    fun `cases match fixture`() = assertCases("cases")

    @Test
    fun `streaming cases match fixture`() = assertCases("streamingCases")

    @Test
    fun `placeholder locale cases match fixture`() {
        val all = cases("placeholderLocaleCases")
        assertTrue(all.isNotEmpty())
        for (case in all) {
            val input = case["input"]!!.jsonObject
            assertEquals(
                case.str("id"),
                case.str("expected"),
                placeholderLocale(input.str("readingLanguage"), input.str("uiLocale")),
            )
        }
    }

    @Test
    fun `every code point prefix is a prefix of the final output`() {
        for (case in cases("cases") + cases("streamingCases")) {
            val text = case["input"]!!.jsonObject.str("text")!!
            val full = speakableSegments(text, final = true)
            val offsets = IntArray(text.codePointCount(0, text.length) + 1) { text.offsetByCodePoints(0, it) }
            for (end in offsets) {
                val partial = speakableSegments(text.substring(0, end), final = false)
                assertTrue(
                    "${case.str("id")} prefix of $end UTF-16 units: $partial is not a prefix of $full",
                    partial.size <= full.size && partial == full.subList(0, partial.size),
                )
            }
        }
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("cannot find $relative")
    }
}
