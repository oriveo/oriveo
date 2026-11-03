package ai.oriveo.community.core.studio

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/**
 * Runs every case of the shared studio_prompt_compose.v1 fixture through the production
 * composer and compares composed / error / adjustments with expect.
 */
class StudioPromptComposeContractTest {
    private fun load(name: String): JsonObject {
        val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("\u5171\u4eab/studio-contracts/$name") }
            .firstOrNull { Files.exists(it) }
            ?: error("$name not found")
        return Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    private val fixture: JsonObject by lazy { load("studio_prompt_compose.v1.json") }

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    private fun specOf(raw: JsonObject): StudioPromptComposer.Spec = StudioPromptComposer.Spec(
        sectionSeparator = raw.str("sectionSeparator"),
        inlineReference = raw.str("inlineReference"),
        referenceTemplate = raw.str("referenceTemplate"),
        baseTemplate = raw.str("baseTemplate"),
        styleTemplate = raw.str("styleTemplate"),
        effectsTemplate = raw.str("effectsTemplate"),
        effectsJoiner = raw.str("effectsJoiner"),
        roleWords = raw.getValue("roleWords").jsonObject.mapValues { it.value.jsonPrimitive.content },
    )

    private fun inputOf(raw: JsonObject): StudioPromptComposer.Input = StudioPromptComposer.Input(
        userPrompt = raw.str("userPrompt"),
        references = raw.getValue("references").jsonArray.map {
            val ref = it.jsonObject
            StudioPromptComposer.Reference(n = ref.getValue("n").jsonPrimitive.int, role = ref.str("role"))
        },
        styleFragment = (raw["styleFragment"] as? JsonPrimitive)?.contentOrNull,
        effectFragments = (raw["effectFragments"] as? JsonArray)?.map { it.jsonPrimitive.content } ?: emptyList(),
        maxPromptChars = raw.getValue("maxPromptChars").jsonPrimitive.int,
    )

    private fun StudioPromptComposer.Result.toJson(): JsonObject = JsonObject(
        mapOf(
            "composed" to (composed?.let { JsonPrimitive(it) } ?: JsonNull),
            "error" to (error?.let { JsonPrimitive(it.wire) } ?: JsonNull),
            "adjustments" to JsonArray(
                adjustments.map {
                    JsonObject(mapOf("field" to JsonPrimitive(it.field.wire), "dropped" to JsonPrimitive(it.dropped)))
                },
            ),
        ),
    )

    @Test
    fun composeCases() {
        val spec = specOf(fixture.getValue("spec").jsonObject)
        val cases = fixture.getValue("cases").jsonArray.map { it.jsonObject }
        assertTrue("fixture has no cases", cases.isNotEmpty())
        val failures = cases.mapNotNull { case ->
            val caseId = case.str("caseId")
            val actual = StudioPromptComposer.compose(spec, inputOf(case.getValue("input").jsonObject)).toJson()
            val expected = case.getValue("expect").jsonObject
            if (actual == expected) null else "$caseId: expected $expected but was $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun builtInSpecEqualsFixtureSpec() {
        assertEquals("built-in spec equals fixture spec", specOf(fixture.getValue("spec").jsonObject), StudioPromptComposer.SPEC)
    }
}
