package ai.oriveo.community.core.model

import android.content.Context
import android.os.Looper
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.nio.file.Files
import java.nio.file.Paths

/**
 * Cross-platform wire invariants.
 *
 * All platforms must encode the same content into byte-for-byte identical wire envelopes,
 * otherwise the side reading the other's envelope judges it "behind" and writes back, and the
 * other side writes back again -- an infinite ping-pong caused only by ordering or key-set
 * differences. This file locks down three invariants on the Android side:
 * 1. Top-level keys stay constant (schemaVersion and empty arrays must not be omitted by
 *    encodeDefaults).
 * 2. Null optional fields are omitted (matching the shape of Web's `...(x ? {x} : {})` and
 *    Swift's nil omission).
 * 3. Arrays sort by code point (`~` sorts after `z`, matching Web's `compareWireId` and
 *    Swift's `<`).
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

    @Test
    fun `capability wire always carries schemaVersion and arrays and omits null fields`() {
        val store = CapabilityPreferenceStore.from(context)
        val coordinator = CapabilityPreferenceSyncCoordinator(context)
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, null),
            "9A1195DE-3AF9-5888-ABC8-B8177C458C07", "gpt-test", transport,
        )
        val wire = coordinator.foundationValue(store.exportPayload())
        assertEquals(topLevelKeys(CAPABILITY_CONTRACT), wire.keys)
        assertEquals(2, (wire["schemaVersion"] as Number).toInt())
        @Suppress("UNCHECKED_CAST")
        val record = (wire["records"] as List<Map<String, Any>>).single()
        omitWhenNull(CAPABILITY_CONTRACT).forEach { field ->
            assertFalse("$field must be omitted entirely when empty, not written as an explicit null", field in record)
        }
        assertTrue("recordId" in record && "web" in record && "revision" in record)
    }

    @Test
    fun `empty capability wire still carries schemaVersion and arrays`() {
        val wire = CapabilityPreferenceSyncCoordinator(context)
            .foundationValue(CapabilityPreferenceSyncPayload())
        assertEquals(topLevelKeys(CAPABILITY_CONTRACT), wire.keys)
        assertEquals(emptyList<Any>(), wire["records"])
        assertEquals(emptyList<Any>(), wire["tombstones"])
    }

    @Test
    fun `generation wire always carries schemaVersion and arrays and omits null fields`() {
        val settings = GenerationParameterSettingsStore.from(context)
        settings.setModelDefaults(
            GenerationParameterOverrides(
                mapOf("temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4))),
            ),
            providerID = "9A1195DE-3AF9-5888-ABC8-B8177C458C07", modelID = "gpt-test",
        )
        val contract = GenerationParameterSyncContract.from(context)
        val wire = GenerationParameterSyncCoordinator(context).foundationValue(contract.exportPayload())
        assertEquals(topLevelKeys(GENERATION_CONTRACT), wire.keys)
        assertEquals(1, (wire["schemaVersion"] as Number).toInt())
        @Suppress("UNCHECKED_CAST")
        val record = (wire["records"] as List<Map<String, Any>>).single()
        assertFalse("a model_default record has no conversation, must not be written as an explicit null", "conversationId" in record)
    }

    @Test
    fun `capability tombstone wire order is code point ordered across the tilde boundary`() {
        val store = CapabilityPreferenceStore.from(context)
        val provider = "9A1195DE-3AF9-5888-ABC8-B8177C458C07"
        listOf("~deepseek/deepseek-v4-flash", "z-ai/glm-5", "cohere/north-mini").forEach { model ->
            store.setConnectionModel(
                CapabilityPreferenceValues(CapabilityWebPreference.Force, null), provider, model, transport,
            )
            store.setConnectionModel(null, provider, model, transport)
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

    // ── emptyEnvelopeNeverOutbound ─────────────────────────────────────
    //
    // A `set(merge)` write treats array fields as a full replacement: publishing a completely
    // empty envelope would wipe out the existing preferences. `bind` publishes immediately on
    // binding, and a fresh install's first bind happens to be completely empty -- without this
    // guard that would be a real path to losing existing preferences.

    /** Both contracts must declare this invariant: if it's ever removed or renamed, this test fails first. */
    @Test
    fun `both contracts declare the empty envelope invariant`() {
        listOf(CAPABILITY_CONTRACT, GENERATION_CONTRACT).forEach { name ->
            assertTrue(
                "$name must declare wireInvariants.emptyEnvelopeNeverOutbound",
                "emptyEnvelopeNeverOutbound" in invariants(name),
            )
        }
    }

    @Test
    fun `capability bind never publishes an empty envelope`() {
        assertEquals(emptyList<Map<String, Any>>(), publishedOnCapabilityBind())
    }

    @Test
    fun `capability bind publishes an envelope that carries records`() {
        CapabilityPreferenceStore.from(context).setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, null),
            PROVIDER, "gpt-test", transport,
        )
        val published = publishedOnCapabilityBind()
        assertEquals(1, published.size)
        assertEquals(1, (published.single().getValue("records") as List<*>).size)
    }

    /** A legitimate "everything deleted" state carries tombstones, it isn't a fully empty envelope, and must still publish normally. */
    @Test
    fun `capability bind still publishes a tombstone only envelope`() {
        val store = CapabilityPreferenceStore.from(context)
        val values = CapabilityPreferenceValues(CapabilityWebPreference.Force, null)
        store.setConnectionModel(values, PROVIDER, "gpt-test", transport)
        store.setConnectionModel(null, PROVIDER, "gpt-test", transport)

        val published = publishedOnCapabilityBind()
        assertEquals(1, published.size)
        assertEquals(emptyList<Any>(), published.single().getValue("records"))
        assertEquals(1, (published.single().getValue("tombstones") as List<*>).size)
    }

    @Test
    fun `generation bind never publishes an empty envelope`() {
        assertEquals(emptyList<Map<String, Any>>(), publishedOnGenerationBind())
    }

    @Test
    fun `generation bind publishes an envelope that carries records`() {
        GenerationParameterSettingsStore.from(context).setModelDefaults(
            GenerationParameterOverrides(
                mapOf("temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4))),
            ),
            providerID = PROVIDER, modelID = "gpt-test",
        )
        val published = publishedOnGenerationBind()
        assertEquals(1, published.size)
        assertEquals(1, (published.single().getValue("records") as List<*>).size)
    }

    @Test
    fun `generation bind still publishes a tombstone only envelope`() {
        val settings = GenerationParameterSettingsStore.from(context)
        val overrides = GenerationParameterOverrides(
            mapOf("temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4))),
        )
        settings.setModelDefaults(overrides, providerID = PROVIDER, modelID = "gpt-test")
        settings.setModelDefaults(null, providerID = PROVIDER, modelID = "gpt-test")

        val published = publishedOnGenerationBind()
        assertEquals(1, published.size)
        assertEquals(emptyList<Any>(), published.single().getValue("records"))
        assertEquals(1, (published.single().getValue("tombstones") as List<*>).size)
    }

    /** bind's immediate first publish runs on the main-thread handler; Robolectric defaults to PAUSED, so it must be drained explicitly. */
    private fun publishedOnCapabilityBind(): List<Map<String, Any>> {
        val published = mutableListOf<Map<String, Any>>()
        CapabilityPreferenceSyncCoordinator(context).bind { published += it }
        shadowOf(Looper.getMainLooper()).idle()
        return published
    }

    private fun publishedOnGenerationBind(): List<Map<String, Any>> {
        val published = mutableListOf<Map<String, Any>>()
        GenerationParameterSyncCoordinator(context).bind { published += it }
        shadowOf(Looper.getMainLooper()).idle()
        return published
    }

    private companion object {
        const val CAPABILITY_CONTRACT = "capability_preference_sync.v1.json"
        const val GENERATION_CONTRACT = "generation_parameter_sync.v1.json"
        const val PROVIDER = "9A1195DE-3AF9-5888-ABC8-B8177C458C07"
    }
}
