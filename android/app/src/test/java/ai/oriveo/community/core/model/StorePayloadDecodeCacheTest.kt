package ai.oriveo.community.core.model

import ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
import java.util.concurrent.atomic.AtomicReference
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * Behavioural lock on "reading the same payload twice decodes it once", following the `cachedRaw`
 * shape already used by `LocalCapabilityCustomFragmentStore`.
 *
 * ## Why object identity is the observation surface
 *
 * `kotlinx.serialization` allocates a fresh object graph on every `decodeFromString` and interns
 * nothing. "The second read returned the same instance" is therefore observable proof that no
 * decode happened in between, without opening a counter in production code just for a test — which
 * would edge up against the rule that a test must not prove a producer correct with events it
 * synthesised itself.
 *
 * ## Why the read lambda hands back a fresh String every time
 *
 * The cache has to compare by **content**, not by reference: a real `SharedPreferences.getString`
 * also returns a new instance each call, so a reference comparison would never hit and the test
 * would pass for the wrong reason.
 */
class StorePayloadDecodeCacheTest {
    private val providerID = "9a1195de-3af9-5888-abc8-b8177c458c07"
    private val model = "gpt-test"

    /** Stands in for SharedPreferences: every read returns a new String with the same content. */
    private fun freshCopyOf(holder: AtomicReference<String?>): String? =
        holder.get()?.let { String(it.toCharArray()) }

    private fun overrides(temperature: Double) = GenerationParameterOverrides(
        mapOf("temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(temperature))),
    )

    private fun identity(): String =
        ModelControlRuntimeIdentity(providerID, model, "openai_responses", "runtime-r7").storageIdentity

    // ── Generation parameters ───────────────────────────────────────────────

    @Test
    fun `generation parameter store decodes the same payload only once`() {
        val payload = AtomicReference<String?>(null)
        val store = GenerationParameterSettingsStore(
            readPayload = { freshCopyOf(payload) },
            writePayload = { payload.set(it) },
        )
        store.setModelDefaults(overrides(0.4), providerID = "provider-a", modelID = "model-a")

        val first = store.modelDefaults("provider-a", "model-a")
        val second = store.modelDefaults("provider-a", "model-a")
        val third = store.connectionDefaults("provider-a")

        assertNotNull(first)
        assertSame("resolving the same payload twice should decode it once", first, second)
        // The third read looks at another scope (there is no connection-level record here) but goes
        // through the same decode, so it must not decode again.
        assertEquals(null, third)
        assertSame("reads across scopes still reuse the same decode", first, store.modelDefaults("provider-a", "model-a"))
    }

    @Test
    fun `generation parameter store re-decodes once the payload changes`() {
        val payload = AtomicReference<String?>(null)
        val store = GenerationParameterSettingsStore(
            readPayload = { freshCopyOf(payload) },
            writePayload = { payload.set(it) },
        )
        store.setModelDefaults(overrides(0.4), providerID = "provider-a", modelID = "model-a")
        val before = store.modelDefaults("provider-a", "model-a")

        store.setModelDefaults(overrides(0.9), providerID = "provider-a", modelID = "model-a")
        val after = store.modelDefaults("provider-a", "model-a")

        assertNotSame("a changed payload must be decoded again", before, after)
        assertEquals(JsonPrimitive(0.9), after?.values?.get("temperature")?.value)
    }

    // ── Capability preferences (records and drafts cache separately) ────────

    @Test
    fun `capability preference store decodes records and drafts only once each`() {
        val payload = AtomicReference<String?>(null)
        val drafts = AtomicReference<String?>(null)
        val store = CapabilityPreferenceStore(
            read = { freshCopyOf(payload) },
            write = { payload.set(it) },
            readDrafts = { freshCopyOf(drafts) },
            writeDrafts = { drafts.set(it) },
        )
        val transport = identity()
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, "deep"),
            providerID, model, transport,
        )
        store.setDraftConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "low"),
            providerID, model, "draft-session", transport,
        )

        val firstRecord = store.scopeValues(providerID, model, null, null, transport).connectionModel
        val secondRecord = store.scopeValues(providerID, model, null, null, transport).connectionModel
        val firstDraft = store.draftConversation(providerID, model, "draft-session", transport)
        val secondDraft = store.draftConversation(providerID, model, "draft-session", transport)

        assertNotNull(firstRecord)
        assertNotNull(firstDraft)
        assertSame("reading the same record payload twice should decode it once", firstRecord, secondRecord)
        assertSame("the draft payload has to be cached too", firstDraft, secondDraft)
    }

    @Test
    fun `capability preference store re-decodes once records or drafts change`() {
        val payload = AtomicReference<String?>(null)
        val drafts = AtomicReference<String?>(null)
        val store = CapabilityPreferenceStore(
            read = { freshCopyOf(payload) },
            write = { payload.set(it) },
            readDrafts = { freshCopyOf(drafts) },
            writeDrafts = { drafts.set(it) },
        )
        val transport = identity()
        store.setConnectionModel(CapabilityPreferenceValues(CapabilityWebPreference.Force, "deep"), providerID, model, transport)
        store.setDraftConversation(CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "low"), providerID, model, "draft-session", transport)
        val recordBefore = store.scopeValues(providerID, model, null, null, transport).connectionModel
        val draftBefore = store.draftConversation(providerID, model, "draft-session", transport)

        store.setConnectionModel(CapabilityPreferenceValues(CapabilityWebPreference.Off, "off"), providerID, model, transport)
        store.setDraftConversation(CapabilityPreferenceValues(CapabilityWebPreference.Force, "max"), providerID, model, "draft-session", transport)
        val recordAfter = store.scopeValues(providerID, model, null, null, transport).connectionModel
        val draftAfter = store.draftConversation(providerID, model, "draft-session", transport)

        assertNotSame(recordBefore, recordAfter)
        assertNotSame(draftBefore, draftAfter)
        assertEquals(CapabilityWebPreference.Off, recordAfter?.web)
        assertEquals("max", draftAfter?.reasoningIntent)
    }
}
