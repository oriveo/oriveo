package ai.oriveo.community.core.studio

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
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
 * Runs every case of the shared image_param_normalization.v1 fixture: profile plus
 * profileOverride are shallow-merged as JSON, validated by the production resolver, then
 * normalized and compared field by field (error included) with expect.
 */
class ImageParamNormalizationContractTest {
    private fun load(name: String): JsonObject {
        val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("\u5171\u4eab/model-contracts/$name") }
            .firstOrNull { Files.exists(it) }
            ?: error("$name not found")
        return Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    private val fixture: JsonObject by lazy { load("image_param_normalization.v1.json") }
    private val profiles: JsonObject by lazy { fixture.getValue("profiles").jsonObject }
    private val cases: List<JsonObject> by lazy { fixture.getValue("cases").jsonArray.map { it.jsonObject } }

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    private fun JsonObject.optString(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

    private fun profileOf(case: JsonObject): ImageProfile {
        val base = profiles.getValue(case.str("profile")).jsonObject
        val override = case["profileOverride"] as? JsonObject
        val merged = if (override == null) base else JsonObject(base + override)
        val validation = ImageProfileResolver.validate(merged)
        return validation.profile ?: error("${case.str("caseId")} does not validate: ${validation.reason}")
    }

    private fun requestOf(case: JsonObject): ImageParamRequest {
        val raw = case.getValue("request").jsonObject
        return ImageParamRequest(
            aspect = raw.optString("aspect"),
            resolution = raw.optString("resolution"),
            quality = raw.optString("quality"),
            n = (raw["n"] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.int,
        )
    }

    private fun ImageParamAdjustment.Value?.toJson(): JsonElement = when (this) {
        null -> JsonNull
        is ImageParamAdjustment.Value.Text -> JsonPrimitive(text)
        is ImageParamAdjustment.Value.Count -> JsonPrimitive(count)
        is ImageParamAdjustment.Value.Counts -> JsonArray(counts.map { JsonPrimitive(it) })
    }

    private fun ImageParamNormalizer.Outcome.toJson(): JsonObject {
        error?.let { return JsonObject(mapOf("error" to JsonPrimitive(it.wire))) }
        val params = params ?: error("outcome has neither params nor error")
        return JsonObject(
            mapOf(
                "aspect" to JsonPrimitive(params.aspect),
                "resolution" to JsonPrimitive(params.resolution),
                "quality" to (params.quality?.let { JsonPrimitive(it) } ?: JsonNull),
                "wire" to JsonObject(params.wire),
                "batches" to JsonArray(params.batches.map { JsonPrimitive(it) }),
                "adjustments" to JsonArray(
                    params.adjustments.map {
                        JsonObject(mapOf("field" to JsonPrimitive(it.field.wire), "from" to it.from.toJson(), "to" to it.to.toJson()))
                    },
                ),
            ),
        )
    }

    @Test
    fun `every shared case matches expect`() {
        assertEquals("image_param_normalization.v1", fixture.str("contractId"))
        assertTrue("fixture has cases", cases.isNotEmpty())
        val defaultAspect = fixture.str("defaultAspect")
        for (case in cases) {
            val id = case.str("caseId")
            val outcome = ImageParamNormalizer.normalize(profileOf(case), requestOf(case), defaultAspect)
            assertEquals(id, case.getValue("expect").jsonObject, outcome.toJson())
        }
    }

    @Test
    fun `cases cover every route and size param`() {
        val used = cases.map { profileOf(it) }
        assertEquals(ImageRoute.entries.toSet(), used.map { it.route }.toSet())
        assertEquals(ImageSizeParam.entries.toSet(), used.map { it.sizeParam }.toSet())
    }

    @Test
    fun `error wire values are the closed pair`() {
        assertEquals(listOf("invalid_request", "invalid_profile"), ImageParamError.entries.map { it.wire })
        assertEquals(listOf("aspect", "resolution", "size", "quality", "n"), ImageParamAdjustment.Field.entries.map { it.wire })
    }
}
