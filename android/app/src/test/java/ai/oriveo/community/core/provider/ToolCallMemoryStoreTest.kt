package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.testing.TestSharedPreferences
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolCallMemoryStoreTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Test
    fun `memory persists and remains isolated by account connection auth and model`() {
        val prefs = TestSharedPreferences()
        val relay = relayProvider()
        val model = manualModel()
        val first = ToolCallMemoryStore({ prefs }, json)

        assertTrue(first.record("account-a", relay, model, false, "tools_rejected_4xx"))
        assertEquals(false, first.lookup("account-a", relay, model))
        assertNull(first.lookup("account-b", relay, model))
        assertNull(first.lookup("account-a", relay.copy(id = "relay-2"), model))
        assertNull(first.lookup("account-a", relay.copy(authMode = ProviderAuthMode.Subscription), model))
        assertNull(first.lookup("account-a", relay, model.copy(id = "other")))

        val afterRestart = ToolCallMemoryStore({ prefs }, json)
        assertEquals(false, afterRestart.lookup("account-a", relay, model))
        afterRestart.clearConnection("account-a", relay.id)
        assertNull(afterRestart.lookup("account-a", relay, model))
    }

    @Test
    fun `memory recorded under another modelFactsRevision is void after restart`() {
        val prefs = TestSharedPreferences()
        var revision: String? = "r0"
        val relay = relayProvider()
        val model = manualModel()
        val store = ToolCallMemoryStore({ prefs }, json, factsRevision = { revision })
        assertTrue(store.record("account-a", relay, model, false, "tools_rejected_4xx"))
        assertEquals(false, store.lookup("account-a", relay, model))

        revision = "r1"
        assertNull(store.lookup("account-a", relay, model))
        assertNull(ToolCallMemoryStore({ prefs }, json, factsRevision = { revision }).lookup("account-a", relay, model))
        // Same value and same cause but the revision changed, so it must be re-recorded under the current revision.
        assertTrue(store.record("account-a", relay, model, false, "tools_rejected_4xx"))
        assertEquals(false, store.lookup("account-a", relay, model))
    }

    @Test
    fun `observed support survives a modelFactsRevision change`() {
        val prefs = TestSharedPreferences()
        var revision: String? = "r0"
        val relay = relayProvider()
        val model = manualModel()
        val store = ToolCallMemoryStore({ prefs }, json, factsRevision = { revision })
        assertTrue(store.record("account-a", relay, model, true, "tool_call_observed"))
        revision = "r1"
        assertEquals(true, store.lookup("account-a", relay, model))
        assertEquals(true, ToolCallMemoryStore({ prefs }, json, factsRevision = { revision }).lookup("account-a", relay, model))
    }

    @Test
    fun `catalog models never learn memory while eligible unknown models do`() {
        val store = ToolCallMemoryStore({ TestSharedPreferences() }, json)
        val official = Provider(id = "openai", kind = ProviderKind.OpenAI)
        val catalogModel = AIModel(id = "catalog", name = "Catalog")
        assertFalse(store.record("account", official, catalogModel, true, "observed"))

        val manual = catalogModel.copy(id = "manual", isManual = true)
        assertTrue(store.record("account", official, manual, true, "observed"))
        assertEquals(true, store.lookup("account", official, manual))
    }

    @Test
    fun `relay negative memory is ignored, auto falls back to the first-send native adapter and positive memory can send`() {
        val relay = relayProvider()
        val model = manualModel().copy(toolCall = null)
        val identity = relayIdentity(model)

        val unscoped = CapabilityEvidenceProductionAdapter.toolCallProjection(
            relay,
            model,
            memoryVerdict = false,
        )
        assertFalse(unscoped.permitsOutbound("tool_call"))
        assertEquals("none", unscoped.decision("tool_call")?.resolution?.source)

        val negative = CapabilityEvidenceProductionAdapter.toolCallProjection(
            relay,
            model,
            identity = identity,
            memoryVerdict = false,
        )
        // Ruling (same on all clients): Relay's "tools unsupported" is recognized only from the negative cache, and a false in the old tool memory is treated as no value.
        assertEquals("unknown", negative.decision("tool_call")?.resolution?.support)
        assertTrue(negative.decision("tool_call")?.resolution?.source != "connection_memory")

        val positive = CapabilityEvidenceProductionAdapter.toolCallProjection(
            relay,
            model,
            identity = identity,
            memoryVerdict = true,
        )
        assertTrue(positive.permitsOutbound("tool_call"))

        // The tool final transport takes the first-attempt protocol: an auto connection falls back to the native adapter of the first-attempt protocol (Chat here), so a positive memory can be sent.
        val auto = relay.copy(relayRequested = relay.relayRequested?.copy(transport = RelayTransport.Auto))
        val firstSend = CapabilityEvidenceProductionAdapter.toolCallProjection(
            auto,
            model,
            identity = identity,
            memoryVerdict = true,
        )
        assertTrue(firstSend.permitsOutbound("tool_call"))

        // The native local channel has no tool adapter and the first attempt cannot resolve one either, so a positive memory is still not sendable.
        val native = relay.copy(relayRequested = relay.relayRequested?.copy(transport = RelayTransport.LlamaCppNative))
        val unavailable = CapabilityEvidenceProductionAdapter.toolCallProjection(
            native,
            model,
            identity = identity,
            memoryVerdict = true,
        )
        assertFalse(unavailable.permitsOutbound("tool_call"))
    }

    private fun relayProvider() = Provider(
        id = "relay-1",
        kind = ProviderKind.Relay,
        baseUrlText = "https://relay.test/v1",
        relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
    )

    private fun manualModel() = AIModel(id = "manual-model", name = "Manual", isManual = true)

    private fun relayIdentity(model: AIModel) = CapabilityEvidenceFacade.QueryIdentity(
        partitionId = "account-a",
        connectionInstanceId = "relay-1",
        connectionGeneration = "generation-1",
        credentialEpoch = "credential-1",
        providerKind = ProviderKind.Relay.rawValue,
        authMode = ProviderAuthMode.ApiKey.rawValue,
        modelId = model.id,
        effectiveTransport = "openai_chat",
        endpointFingerprint = "relay-endpoint",
    )
}
