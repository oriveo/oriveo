package ai.oriveo.community.core.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalCapabilityCustomFragmentStoreTest {
    private val identity = "openai_responses|model-a"

    /** A missing legacy key means a fresh install or an already-migrated state: do nothing, and don't backfill the marker key either. */
    // Generation records are migrated into the additional request body (contract: migration of existing content), so the master-switch migration semantics are verified with the web owner.
    @Test
    fun retiredGateMigrationIsANoOpWhenTheLegacyKeyIsAbsent() {
        var raw: String? = null
        var cleared = false
        val seed = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        seed.setFragment("{\"temperature\":0.2}", "provider-a", "model-a", "conversation-a", identity, LocalCapabilityCustomFragmentStore.WEB_NAMESPACE)
        val before = raw

        LocalCapabilityCustomFragmentStore(
            { raw }, { raw = it },
            readRetiredDeveloperGate = { null },
            clearRetiredDeveloperGate = { cleared = true },
        ).fragment("provider-a", "model-a", "conversation-a", identity, LocalCapabilityCustomFragmentStore.WEB_NAMESPACE)

        assertFalse("cleanup should not run when the key is absent", cleared)
        assertEquals("no record should be rewritten when the key is absent", before, raw)
    }

    /** The master switch was on: the configuration still applies as-is, only the legacy key gets cleared. */
    @Test
    fun retiredGateMigrationKeepsCustomWhenTheGateWasOn() {
        var raw: String? = null
        var gate: Boolean? = true
        val seed = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        seed.setFragment("{\"temperature\":0.2}", "provider-a", "model-a", "conversation-a", identity, LocalCapabilityCustomFragmentStore.WEB_NAMESPACE)

        val store = LocalCapabilityCustomFragmentStore(
            { raw }, { raw = it },
            readRetiredDeveloperGate = { gate },
            clearRetiredDeveloperGate = { gate = null },
        )

        // Migration is deferred to the first read: read first, then assert the legacy key was cleared.
        assertEquals(
            "{\"temperature\":0.2}",
            store.fragment("provider-a", "model-a", "conversation-a", identity, LocalCapabilityCustomFragmentStore.WEB_NAMESPACE),
        )
        assertNull("the legacy key must be cleared", gate)
    }

    /**
     * The master switch was off: any existing enabled record must be disabled, while
     * `rawJSON` is preserved as-is.
     *
     * Without this migration, those records would suddenly start going out the moment the
     * master switch disappears -- silently making a decision on the user's behalf that they
     * never made, and the first sign of it would be a message that fails to send or behaves
     * differently.
     */
    @Test
    fun retiredGateMigrationDisarmsCustomWhenTheGateWasOff() {
        var raw: String? = null
        var gate: Boolean? = false
        val seed = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        seed.setFragment("{\"temperature\":0.2}", "provider-a", "model-a", "conversation-a", identity, LocalCapabilityCustomFragmentStore.WEB_NAMESPACE)

        val store = LocalCapabilityCustomFragmentStore(
            { raw }, { raw = it },
            readRetiredDeveloperGate = { gate },
            clearRetiredDeveloperGate = { gate = null },
        )

        assertNull("must not go out once disabled", store.fragment("provider-a", "model-a", "conversation-a", identity, LocalCapabilityCustomFragmentStore.WEB_NAMESPACE))
        val configuration = store.configuration("provider-a", "model-a", "conversation-a", identity, LocalCapabilityCustomFragmentStore.WEB_NAMESPACE)
        assertFalse(configuration.enabled)
        assertEquals("the draft must be preserved as-is", "{\"temperature\":0.2}", configuration.rawJSON)
        assertNull(gate)
    }

    /** Idempotent: once the legacy key is gone, constructing the store again does not rewrite anything a second time (and won't turn off a configuration the user has re-enabled). */
    @Test
    fun retiredGateMigrationIsIdempotent() {
        var raw: String? = null
        var gate: Boolean? = false
        val seed = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        seed.setFragment("{\"temperature\":0.2}", "provider-a", "model-a", "conversation-a", identity, LocalCapabilityCustomFragmentStore.WEB_NAMESPACE)
        LocalCapabilityCustomFragmentStore(
            { raw }, { raw = it },
            readRetiredDeveloperGate = { gate },
            clearRetiredDeveloperGate = { gate = null },
        ).fragment("provider-a", "model-a", "conversation-a", identity, LocalCapabilityCustomFragmentStore.WEB_NAMESPACE)
        // The user re-enabled it.
        val reenabled = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        reenabled.setFragment("{\"temperature\":0.9}", "provider-a", "model-a", "conversation-a", identity, LocalCapabilityCustomFragmentStore.WEB_NAMESPACE)

        val store = LocalCapabilityCustomFragmentStore(
            { raw }, { raw = it },
            readRetiredDeveloperGate = { gate },
            clearRetiredDeveloperGate = { gate = null },
        )

        assertEquals(
            "{\"temperature\":0.9}",
            store.fragment("provider-a", "model-a", "conversation-a", identity, LocalCapabilityCustomFragmentStore.WEB_NAMESPACE),
        )
    }

    /** DI's viewModel{} factory constructs the store on the main thread: construction must not touch any storage entry point. */
    @Test
    fun construction_doesNotReadPrefs() {
        var gateReads = 0
        var prefsCalls = 0
        LocalCapabilityCustomFragmentStore(
            read = { prefsCalls++; null },
            write = { prefsCalls++ },
            readRetiredDeveloperGate = { gateReads++; false },
            clearRetiredDeveloperGate = { prefsCalls++ },
            readAdditionalBody = { prefsCalls++; null },
            writeAdditionalBody = { prefsCalls++ },
        )

        assertEquals("the retired master switch must not be read during construction", 0, gateReads)
        assertEquals("storage must not be read or written during construction", 0, prefsCalls)
    }

    /** The first read runs the migrations once; later reads and writes do not rerun them (the legacy key is deliberately not cleared, so this verifies the guard rather than the migration's own idempotency). */
    @Test
    fun firstRead_runsMigrationsOnce() {
        var raw: String? = null
        var additional: String? = null
        val seed = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        seed.setFragment("{\"temperature\":0.2}", "provider-a", "model-a", "conversation-a", identity)
        var gateReads = 0
        var additionalWrites = 0
        val store = LocalCapabilityCustomFragmentStore(
            { raw }, { raw = it },
            readRetiredDeveloperGate = { gateReads++; false },
            clearRetiredDeveloperGate = {},
            readAdditionalBody = { additional },
            writeAdditionalBody = { additionalWrites++; additional = it },
        )

        store.effectiveConfiguration("provider-a", "model-a", "conversation-a", identity)
        store.effectiveConfiguration("provider-a", "model-a", "conversation-a", identity)

        assertEquals("retired master switch migration runs only once", 1, gateReads)
        assertEquals("generation fragment migration writes the additional request body only once", 1, additionalWrites)
        assertEquals(
            "{\"temperature\":0.2}",
            store.additionalBody("provider-a", "model-a", "conversation-a").rawJSON,
        )
        assertEquals(1, gateReads)
    }

    /**
     * When the conversation layer has no record, fall back to the model default scope. Both sides
     * must read the same way: the provider detail page writes to the model default tier, and
     * reading them separately would leave the edit page blank while the field is still going out.
     */
    @Test
    fun effectiveConfigurationFallsBackToTheModelDefaultScope() {
        var raw: String? = null
        val store = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        store.setConfiguration(
            LocalCapabilityCustomFragmentStore.Configuration(enabled = true, rawJSON = "{\"temperature\":0.2}"),
            "provider-a", "model-a", conversationID = null, transportIdentity = identity,
        )

        assertEquals(
            "{\"temperature\":0.2}",
            store.effectiveConfiguration("provider-a", "model-a", "conversation-a", identity).rawJSON,
        )
        assertEquals(
            mapOf("generation" to "{\"temperature\":0.2}"),
            store.fragmentsByOwner("provider-a", "model-a", "conversation-a", identity),
        )

        // A conversation-level record (even a disabled one) means the user explicitly chose in this conversation; the model default must not override it.
        store.setConfiguration(
            LocalCapabilityCustomFragmentStore.Configuration(enabled = false, rawJSON = "{\"temperature\":0.9}"),
            "provider-a", "model-a", "conversation-a", identity,
        )
        assertEquals(
            "{\"temperature\":0.9}",
            store.effectiveConfiguration("provider-a", "model-a", "conversation-a", identity).rawJSON,
        )
        assertTrue(store.fragmentsByOwner("provider-a", "model-a", "conversation-a", identity).isEmpty())
    }

    @Test
    fun rawFragmentIsLocalAndIsolatedByConversationConnectionModelAndTransport() {
        var raw: String? = null
        val store = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        store.setFragment("{\"temperature\":0.2}", "provider-a", "model-a", "conversation-a", "openai_responses|model-a")

        assertEquals("{\"temperature\":0.2}", store.fragment("provider-a", "model-a", "conversation-a", "openai_responses|model-a"))
        assertNull(store.fragment("provider-a", "model-a", "conversation-b", "openai_responses|model-a"))
        assertNull(store.fragment("provider-a", "model-a", "conversation-a", "openai_chat|model-a"))
        assertNull(store.fragment("provider-b", "model-a", "conversation-a", "openai_responses|model-a"))
        // The private record has no sync wire shape and disabling deletes the only sendable copy.
        store.setFragment(null, "provider-a", "model-a", "conversation-a", "openai_responses|model-a")
        assertNull(store.fragment("provider-a", "model-a", "conversation-a", "openai_responses|model-a"))
    }

    @Test
    fun draftMigratesThenDeletionScopesRemoveRawFragment() {
        var raw: String? = null
        val store = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        store.setFragment("{\"temperature\":0.2}", "provider-a", "model-a", "draft", "openai_responses|model-a")
        store.migrateConversation("provider-a", "model-a", "draft", "conversation-a", "openai_responses|model-a")

        assertNull(store.fragment("provider-a", "model-a", "draft", "openai_responses|model-a"))
        assertEquals("{\"temperature\":0.2}", store.fragment("provider-a", "model-a", "conversation-a", "openai_responses|model-a"))
        store.removeScopes(providerID = "provider-a", modelID = "model-a")
        assertNull(store.fragment("provider-a", "model-a", "conversation-a", "openai_responses|model-a"))
    }

    @Test
    fun ownerNamespacesAreMutuallyIsolatedAndAllMigrateWithTheConversation() {
        var raw: String? = null
        val store = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        val identity = "openai_chat|model-a"
        LocalCapabilityCustomFragmentStore.supportedNamespaces().forEachIndexed { index, namespace ->
            store.setFragment("{\"value\":$index}", "provider-a", "model-a", "draft", identity, namespace)
        }
        store.migrateConversation("provider-a", "model-a", "draft", "conversation-a", identity)
        LocalCapabilityCustomFragmentStore.supportedNamespaces().forEachIndexed { index, namespace ->
            assertEquals("{\"value\":$index}", store.fragment("provider-a", "model-a", "conversation-a", identity, namespace))
            assertNull(store.fragment("provider-a", "model-a", "draft", identity, namespace))
        }
    }
}
