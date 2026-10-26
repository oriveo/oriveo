package ai.oriveo.community.core.provider

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Reconciles the shared contract inputCapabilityCases case by case: the five projected fields of the facade equal expect (including the serialized names). */
class InputCapabilityCasesTest {
    private val json = Json

    @Test
    fun `input capability cases match shared expectations`() {
        val cases = json.parseToJsonElement(workspaceFile("shared/model-contracts/capability_evidence_contract.v1.json").readText())
            .jsonObject.getValue("inputCapabilityCases").jsonObject.getValue("cases").jsonArray
        assertTrue(cases.isNotEmpty())
        for (raw in cases) {
            val case = raw.jsonObject
            val id = case.getValue("id").jsonPrimitive.content
            val projection = CapabilityEvidenceFacade.projectInputCapability(
                key = case.getValue("key").jsonPrimitive.content,
                verdict = case.getValue("verdict").asVerdict(),
                endImplements = case.getValue("endImplements").jsonPrimitive.boolean,
                override = case.getValue("override").takeUnless { it is JsonNull }?.let { override ->
                    json.decodeFromJsonElement(
                        CapabilityEvidenceFacade.InputCapabilityOverride.serializer(),
                        override.jsonObject.getValue("op"),
                    )
                },
                negativeCacheHit = case.getValue("negativeCacheHit").jsonPrimitive.boolean,
                connection = json.decodeFromJsonElement(
                    CapabilityEvidenceFacade.InputCapabilityConnection.serializer(),
                    case.getValue("connection"),
                ),
            )
            assertEquals(id, case.getValue("expect").jsonObject, projection.toJson())
        }
    }

    private fun kotlinx.serialization.json.JsonElement.asVerdict(): CapabilityEvidenceFacade.InputCapabilityVerdict? {
        if (this is JsonNull) return null
        val obj = jsonObject
        return CapabilityEvidenceFacade.InputCapabilityVerdict(
            state = obj.getValue("state").jsonPrimitive.content,
            reasonCode = obj["reasonCode"]?.jsonPrimitive?.content,
            wireFamily = obj["wireFamily"]?.jsonPrimitive?.content,
        )
    }

    private fun CapabilityEvidenceFacade.InputCapabilityProjection.toJson(): JsonObject = buildJsonObject {
        put("visible", JsonPrimitive(visible))
        put("editable", JsonPrimitive(editable))
        put("outbound", json.encodeToJsonElement(CapabilityEvidenceFacade.InputCapabilityOutbound.serializer(), outbound))
        put("hint", hint?.let { json.encodeToJsonElement(CapabilityEvidenceFacade.InputCapabilityHint.serializer(), it) } ?: JsonNull)
        put(
            "disabledReason",
            disabledReason?.let {
                json.encodeToJsonElement(CapabilityEvidenceFacade.InputCapabilityDisabledReason.serializer(), it)
            } ?: JsonNull,
        )
    }

    /** Looks up the relative path under the repository root, walking up from the current working directory (after MetadataClientRevisionTest.workspaceFile). */
    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("not found: $relative")
    }
}
