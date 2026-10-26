package ai.oriveo.community.core.voice

import ai.oriveo.community.core.model.ProviderAuthMode
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * resolveCases / optionCases of shared/voice-contracts/engine-resolution.v2.json are compared case by case against the production resolution result.
 * catalog "base" = the data of shared/model-contracts/voice_catalog_contract.v2.json, decoded by the production decoder.
 * When expected omits notice / persist, compare as "no notice, keep the original selection".
 */
class VoiceEngineResolverContractTest {

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/engine-resolution.v2.json").readText()).jsonObject

    private val baseCatalog: JsonElement =
        Json.parseToJsonElement(workspaceFile("shared/model-contracts/voice_catalog_contract.v2.json").readText())
            .jsonObject["data"]!!

    private fun cases(key: String): List<JsonObject> = fixture[key]!!.jsonArray.map { it.jsonObject }

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun catalog(input: JsonObject): VoiceCatalog {
        val element = input["catalog"]!!
        val data = if (element is JsonPrimitive && element.content == "base") baseCatalog else element
        return VoiceCatalogDecoder.decode(data)
    }

    private fun kind(raw: String?) = requireNotNull(VoiceProviderKinds.fromRawValue(raw)) { "unknown providerKind $raw" }

    private fun direction(input: JsonObject) = VoiceDirection.fromRawValue(input.str("direction"))!!

    private fun connections(input: JsonObject): List<VoiceConnection> = input["connections"]!!.jsonArray.map {
        val c = it.jsonObject
        VoiceConnection(
            id = c.str("id")!!,
            providerKind = kind(c.str("providerKind")),
            authMode = ProviderAuthMode.entries.first { mode -> mode.rawValue == c.str("authMode") },
            hasKey = c["hasKey"]!!.jsonPrimitive.boolean,
        )
    }

    private fun selection(obj: JsonObject): VoiceEngineSelection = when (obj.str("engine")) {
        "system" -> VoiceEngineSelection.System
        "cloud" -> VoiceEngineSelection.Cloud(kind(obj.str("providerKind")), obj.str("connectionId")!!, obj.str("model")!!, obj.str("voice"))
        else -> error("unknown engine: $obj")
    }

    private fun expectedResolution(obj: JsonObject): VoiceEngineResolution {
        val engine = when (obj.str("engine")) {
            "system" -> VoiceEngine.System
            "cloud" -> VoiceEngine.Cloud(kind(obj.str("providerKind")), obj.str("connectionId")!!, obj.str("model")!!, obj.str("voice"))
            else -> error("unknown engine: $obj")
        }
        return VoiceEngineResolution(
            engine = engine,
            reason = obj.str("reason")?.let { raw -> VoiceFallbackReason.entries.first { it.rawValue == raw } },
            notice = obj["notice"]?.jsonPrimitive?.boolean ?: false,
            persist = obj.str("persist")?.let { raw -> VoiceSelectionPersist.entries.first { it.rawValue == raw } }
                ?: VoiceSelectionPersist.Keep,
        )
    }

    private fun expectedOption(obj: JsonObject): VoiceEngineOption = when (obj.str("engine")) {
        "system" -> VoiceEngineOption.System
        "cloud" -> VoiceEngineOption.Cloud(
            kind(obj.str("providerKind")),
            obj.str("connectionId")!!,
            obj.str("model")!!,
            obj["isDefault"]!!.jsonPrimitive.boolean,
        )
        else -> error("unknown engine: $obj")
    }

    @Test
    fun `resolve cases match fixture`() = assertResolveCases("resolveCases")

    @Test
    fun realtimeResolveCasesMatchFixture() = assertResolveCases("realtimeResolveCases")

    @Test
    fun `option cases match fixture`() = assertOptionCases("optionCases")

    @Test
    fun realtimeOptionCasesMatchFixture() = assertOptionCases("realtimeOptionCases")

    private fun assertResolveCases(key: String) {
        val all = cases(key)
        assertTrue("$key must not be empty", all.isNotEmpty())
        for (case in all) {
            val input = case["input"]!!.jsonObject
            val actual = VoiceEngineResolver.resolve(
                catalog(input),
                direction(input),
                selection(input["selection"]!!.jsonObject),
                connections(input),
            )
            assertEquals(case.str("id"), expectedResolution(case["expected"]!!.jsonObject), actual)
        }
    }

    private fun assertOptionCases(key: String) {
        val all = cases(key)
        assertTrue("$key must not be empty", all.isNotEmpty())
        for (case in all) {
            val input = case["input"]!!.jsonObject
            val actual = VoiceEngineResolver.options(catalog(input), direction(input), connections(input))
            val expected = case["expected"]!!.jsonArray.map { expectedOption(it.jsonObject) }
            assertEquals(case.str("id"), expected, actual)
        }
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Cannot find $relative")
    }
}
