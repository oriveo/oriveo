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
    fun `negative memory overrides unknown and positive memory requires a native adapter`() {
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
        assertFalse(negative.permitsOutbound("tool_call"))
        assertEquals("connection_memory", negative.decision("tool_call")?.resolution?.source)

        val positive = CapabilityEvidenceProductionAdapter.toolCallProjection(
            relay,
            model,
            identity = identity,
            memoryVerdict = true,
        )
        assertTrue(positive.permitsOutbound("tool_call"))

        val auto = relay.copy(relayRequested = relay.relayRequested?.copy(transport = RelayTransport.Auto))
        val unavailable = CapabilityEvidenceProductionAdapter.toolCallProjection(
            auto,
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
        modelId = model.id,
        effectiveTransport = "openai_chat",
        endpointFingerprint = "relay-endpoint",
    )
}
