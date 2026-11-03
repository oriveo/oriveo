package ai.oriveo.community.core.studio

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/**
 * Runs every case and visibility case of the shared image_profile_resolution.v1 fixture and
 * checks the hard-coded enums / required fields / route tables against image_profile.v2.
 */
class ImageProfileResolutionContractTest {
    private fun load(name: String): JsonObject {
        val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("\u5171\u4eab/model-contracts/$name") }
            .firstOrNull { Files.exists(it) }
            ?: error("$name not found")
        return Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    private val fixture: JsonObject by lazy { load("image_profile_resolution.v1.json") }
    private val schema: JsonObject by lazy { load("image_profile.v2.json") }

    private fun JsonObject.objOrNull(key: String): JsonObject? = this[key] as? JsonObject
    private fun JsonObject.strOrNull(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content
    private fun JsonObject.strings(key: String): List<String> = getValue(key).jsonArray.map { it.jsonPrimitive.content }

    private val tableProfiles: JsonObject by lazy {
        fixture.getValue("metadata").jsonObject.getValue("profiles").jsonObject.getValue("image").jsonObject
    }

    // Raw entries go through the production adapter, so non-object entries and non-string refs are judged there.
    private fun entries(raw: JsonObject?): Map<String, ImageProfileSlice.ModelEntry> = ImageProfileResolver.entriesOf(raw)

    private val slice: ImageProfileSlice by lazy {
        val providers = fixture.getValue("metadata").jsonObject.getValue("providers").jsonObject
        // The production adapter drops non-object table entries (their ref reads as dangling).
        ImageProfileResolver.sliceOf(
            profiles = tableProfiles,
            providers = providers.mapValues { (_, value) ->
                val provider = value.jsonObject
                ImageProfileSlice.Provider(
                    models = entries(provider.objOrNull("models")),
                    imageModels = entries(provider.objOrNull("imageModels")),
                )
            },
        )
    }

    private fun relayOf(raw: JsonObject?): ImageProfileResolver.Relay? = raw?.let { relay ->
        ImageProfileResolver.Relay(
            officialMatch = relay.objOrNull("officialMatch")?.let {
                ImageProfileResolver.OfficialMatch(providerKind = it.str("providerKind"), modelId = it.str("modelId"))
            },
            probe = relay.strOrNull("probe"),
            userDeclared = relay.objOrNull("userDeclared"),
        )
    }

    private val cases: List<JsonObject> by lazy { fixture.getValue("cases").jsonArray.map { it.jsonObject } }

    private fun resolveCase(case: JsonObject): ImageProfileResolver.Resolution {
        val input = case.getValue("input").jsonObject
        return ImageProfileResolver.resolve(
            slice = slice,
            providerKind = input.strOrNull("providerKind"),
            modelId = input.str("modelId"),
            relay = relayOf(input.objOrNull("relay")),
        )
    }

    private fun caseNamed(id: String): JsonObject = cases.first { it.str("caseId") == id }

    @Test
    fun `every shared case matches profileRef reason and appliedOverride`() {
        assertEquals("image_profile_resolution.v1", fixture.str("contractId"))
        assertTrue("fixture has cases", cases.isNotEmpty())
        for (case in cases) {
            val id = case.str("caseId")
            val expect = case.getValue("expect").jsonObject
            val actual = resolveCase(case)
            assertEquals("$id.profileRef", expect.strOrNull("profileRef"), actual.profileRef)
            assertEquals("$id.reason", expect.strOrNull("reason"), actual.reason?.wire)
            assertEquals("$id.appliedOverride", expect.objOrNull("appliedOverride"), actual.appliedOverride)
            assertEquals("$id has a profile exactly when reason is null", actual.reason == null, actual.profile != null)
        }
    }

    @Test
    fun `override is shallow-merged over the table entry`() {
        val profile = resolveCase(caseNamed("official.dashscope_multimodal.override_merges")).profile
            ?: error("override case resolves to a profile")
        assertEquals(2, profile.maxReferenceImages)
        assertEquals(listOf(5.0, 15.0), profile.typicalSeconds)
        assertEquals(ImageRoute.DASHSCOPE_MULTIMODAL, profile.route)
        assertEquals(ImageSizeParam.DASHSCOPE_WXH, profile.sizeParam)
        assertEquals(ImageEditTransport.INLINE, profile.editTransport)
        assertEquals(mapOf("1K" to 1024, "2K" to 2048), profile.resolutions)
        assertEquals(ImageProfileSource.OFFICIAL_API, profile.source)
    }

    @Test
    fun `user declared profile is used as declared`() {
        val result = resolveCase(caseNamed("relay.user_declared_wins"))
        val profile = result.profile ?: error("declared profile resolves")
        assertEquals(ImageProfileResolver.USER_DECLARED_REF, result.profileRef)
        assertEquals(listOf(ImageOperation.GENERATE), profile.operations)
        assertNull(profile.editTransport)
        assertEquals(ImageProfileSource.USER_DECLARED, profile.source)
        assertNull("declared profile carries no override", result.appliedOverride)
    }

    @Test
    fun `every visibility case matches expectVisible`() {
        val visibility = fixture.getValue("visibilityCases").jsonArray.map { it.jsonObject }
        assertTrue("fixture has visibility cases", visibility.isNotEmpty())
        for (case in visibility) {
            val id = case.str("caseId")
            val ref = case.str("profileRef")
            val validation = ImageProfileResolver.validate(tableProfiles.getValue(ref).jsonObject)
            assertNull("$id.$ref validates", validation.reason)
            val context = case.getValue("context").jsonObject
            assertEquals(
                id,
                case.getValue("expectVisible").jsonPrimitive.boolean,
                ImageProfileResolver.visibleInStudio(
                    profile = validation.profile,
                    connectionUsable = context.getValue("connectionUsable").jsonPrimitive.boolean,
                    hasBase = context.getValue("hasBase").jsonPrimitive.boolean,
                    referenceCount = context.getValue("referenceCount").jsonPrimitive.int,
                ),
            )
        }
        assertFalse(ImageProfileResolver.visibleInStudio(null, connectionUsable = true, hasBase = false, referenceCount = 0))
    }

    @Test
    fun `reasons outside the shared cases follow the validation order`() {
        val base = tableProfiles.getValue("openai_gpt_image").jsonObject
        fun reasonOf(edit: MutableMap<String, JsonElement>.() -> Unit): ImageProfileReason? =
            ImageProfileResolver.validate(JsonObject(base.toMutableMap().apply(edit))).reason
        fun ops(vararg values: String) = JsonArray(values.map { JsonPrimitive(it) })

        assertNull("unknown fields are ignored", reasonOf { put("futureField", JsonPrimitive(1)) })
        assertEquals(ImageProfileReason.MISSING_REQUIRED_FIELD, reasonOf { put("route", JsonNull) })
        assertEquals(
            ImageProfileReason.MISSING_REQUIRED_FIELD,
            reasonOf { remove("source"); put("route", JsonPrimitive("images_api")) },
        )
        assertEquals(
            ImageProfileReason.NOT_IMAGE_OUTPUT,
            reasonOf { put("imageOutput", JsonPrimitive(false)); put("route", JsonPrimitive("images_api")) },
        )
        assertEquals(
            ImageProfileReason.UNKNOWN_ROUTE,
            reasonOf { put("route", JsonPrimitive("images_api")); put("sizeParam", JsonPrimitive("pixels")) },
        )
        assertEquals(
            ImageProfileReason.UNKNOWN_SIZE_PARAM,
            reasonOf { put("sizeParam", JsonPrimitive("pixels")); put("operations", ops()) },
        )
        assertEquals(ImageProfileReason.UNKNOWN_OPERATION, reasonOf { put("operations", ops()) })
        assertEquals(ImageProfileReason.UNKNOWN_OPERATION, reasonOf { put("operations", ops("generate", "upscale")) })
        assertEquals(ImageProfileReason.UNKNOWN_OPERATION, reasonOf { put("operations", JsonPrimitive("generate")) })
        assertEquals(ImageProfileReason.SIZE_PARAM_NOT_ALLOWED, reasonOf { put("sizeParam", JsonPrimitive("aspect_only")) })
        assertEquals(ImageProfileReason.UNKNOWN_EDIT_TRANSPORT, reasonOf { remove("editTransport") })
        assertEquals(ImageProfileReason.EDIT_TRANSPORT_WITHOUT_EDIT, reasonOf { put("operations", ops("generate")) })
        assertEquals(ImageProfileReason.UNKNOWN_SOURCE, reasonOf { put("source", JsonPrimitive("guess")) })
    }

    @Test
    fun `hard-coded enums required fields and route tables match image_profile v2`() {
        val enums = schema.getValue("enums").jsonObject
        assertEquals(enums.strings("operations"), ImageOperation.entries.map { it.wire })
        assertEquals(enums.strings("routes"), ImageRoute.entries.map { it.wire })
        assertEquals(enums.strings("editTransports"), ImageEditTransport.entries.map { it.wire })
        assertEquals(enums.strings("sizeParams"), ImageSizeParam.entries.map { it.wire })
        assertEquals(enums.strings("sources"), ImageProfileSource.entries.map { it.wire })
        assertEquals(schema.getValue("fields").jsonObject.strings("required"), ImageProfileResolver.REQUIRED_FIELDS)
        val routes = schema.getValue("routes").jsonObject
        assertEquals(routes.keys - "\$comment", ImageRoute.entries.map { it.wire }.toSet())
        for (route in ImageRoute.entries) {
            val raw = routes.getValue(route.wire).jsonObject
            assertEquals(
                "${route.wire}.allowedEditTransports",
                raw.strings("allowedEditTransports"),
                route.allowedEditTransports.map { it.wire },
            )
            assertEquals(
                "${route.wire}.allowedSizeParams",
                raw.strings("allowedSizeParams"),
                route.allowedSizeParams.map { it.wire },
            )
        }
        assertEquals(fixture.strings("reasons"), ImageProfileReason.entries.map { it.wire })
    }
}
