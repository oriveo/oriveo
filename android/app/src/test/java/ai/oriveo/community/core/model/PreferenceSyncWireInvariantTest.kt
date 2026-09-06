package ai.oriveo.community.core.model

import android.content.Context
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.nio.file.Files
import java.nio.file.Paths

/**
 * Cross-platform wire invariants for the exported preference documents.
 *
 * Every platform has to encode the same content into byte-for-byte identical envelopes: if one side
 * reorders a key set or writes an explicit null where another omits the field, importing the other's
 * document looks like a change and writes back a document that looks like a change in turn. Two
 * invariants are locked down here, both read from the contract files under shared/model-contracts
 * rather than restated:
 * 1. Top-level keys stay constant - schemaVersion and empty arrays are written, not omitted.
 * 2. Null optional fields are omitted, matching Web's `...(x ? {x} : {})` and Swift's nil omission.
 *
 * A third invariant, that arrays sort by code point (`~` sorts after `z`, matching Web's
 * `compareWireId` and Swift's `<`), is asserted on the store's own ordering.
 */
@RunWith(RobolectricTestRunner::class)
class PreferenceSyncWireInvariantTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()
    private val transport = "r1.b3BlbmFpX2NoYXQ.cnVudGltZS1yNw"

    /** Single source of truth: the wireInvariants section of the two sync contracts under shared/model-contracts. */
    private fun invariants(contract: String) =
        Json.parseToJsonElement(contractText(contract)).jsonObject.getValue("wireInvariants").jsonObject

    private fun topLevelKeys(contract: String) =
        invariants(contract).getValue("alwaysPresentTopLevelKeys").jsonObject
            .getValue("keys").jsonArray.map { it.jsonPrimitive.content }.toSet()

    private fun omitWhenNull(contract: String) =
        invariants(contract).getValue("omitWhenNull").jsonObject
            .getValue("recordFields").jsonArray.map { it.jsonPrimitive.content }

    private fun contractText(name: String): String {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve("shared/model-contracts/$name") }
            .firstOrNull(Files::exists) ?: error("$name not found")
        return String(Files.readAllBytes(path), Charsets.UTF_8)
    }

    /**
     * The document as plain values, so a missing field and a field holding null are told apart by
     * key presence. The JSON text comes from the production exporter, never from a Json instance
     * configured here, or the test would only be checking its own settings.
     */
    private fun wireMap(exportedJson: String): Map<String, Any?> =
        (Json.parseToJsonElement(exportedJson) as JsonObject).mapValues { (_, value) -> value.toPlainValue() }

    private fun JsonElement.toPlainValue(): Any? = when (this) {
        is JsonNull -> null
        is JsonObject -> entries.associate { (key, value) -> key to value.toPlainValue() }
        is JsonArray -> map { it.toPlainValue() }
        is JsonPrimitive -> booleanOrNull ?: longOrNull ?: doubleOrNull ?: content
    }

    @Test
    fun `generation wire always carries schemaVersion and arrays and omits null fields`() {
        GenerationParameterSettingsStore.from(context).setModelDefaults(
            GenerationParameterOverrides(
                mapOf("temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4))),
            ),
            providerID = PROVIDER, modelID = "gpt-test",
        )
        val wire = wireMap(GenerationParameterSyncContract.from(context).exportJSON())

        assertEquals(topLevelKeys(GENERATION_CONTRACT), wire.keys)
        assertEquals(1, (wire["schemaVersion"] as Number).toInt())
        @Suppress("UNCHECKED_CAST")
        val record = (wire["records"] as List<Map<String, Any?>>).single()
        // A model_default record has no conversation, and the fields it does not carry have to be
        // absent from the object rather than present holding null.
        assertFalse("conversationId must be omitted entirely, not written as an explicit null", "conversationId" in record)
        omitWhenNull(GENERATION_CONTRACT).forEach { field ->
            assertFalse("$field is present but null; it must be omitted instead", field in record && record[field] == null)
        }
    }

    @Test
    fun `empty generation wire still carries schemaVersion and arrays`() {
        val wire = wireMap(GenerationParameterSyncContract.from(context).exportJSON())

        assertEquals(topLevelKeys(GENERATION_CONTRACT), wire.keys)
        assertEquals(emptyList<Any>(), wire["records"])
        assertEquals(emptyList<Any>(), wire["tombstones"])
    }

    @Test
    fun `capability tombstone order is code point ordered across the tilde boundary`() {
        val store = CapabilityPreferenceStore.from(context)
        listOf("~deepseek/deepseek-v4-flash", "z-ai/glm-5", "cohere/north-mini").forEach { model ->
            store.setConnectionModel(
                CapabilityPreferenceValues(CapabilityWebPreference.Force, null), PROVIDER, model, transport,
            )
            store.setConnectionModel(null, PROVIDER, model, transport)
        }
        val ids = store.exportPayload().tombstones.map { it.recordID }
        assertEquals(3, ids.size)
        // Contract test case: ICU collation (as an older Web implementation's localeCompare did)
        // sorts `~deepseek` ahead of `z-ai`.
        val expected = invariants(CAPABILITY_CONTRACT).getValue("orderingBoundaryCase").jsonObject
            .getValue("codePointOrder").jsonArray.map { element ->
                element.jsonPrimitive.content.substringAfter("07:").substringBefore(":r1.")
            }
        assertEquals(expected, ids.map { it.substringAfter("07:").substringBefore(":r1.") })
    }

    private companion object {
        const val CAPABILITY_CONTRACT = "capability_preference_sync.v1.json"
        const val GENERATION_CONTRACT = "generation_parameter_sync.v1.json"
        const val PROVIDER = "9A1195DE-3AF9-5888-ABC8-B8177C458C07"
    }
}
