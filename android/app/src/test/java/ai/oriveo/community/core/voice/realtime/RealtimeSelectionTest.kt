package ai.oriveo.community.core.voice.realtime

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class RealtimeSelectionTest {
    private val entry = VoiceRealtimeEntry(
        model = "gpt-realtime",
        transport = VoiceTransport.OpenAIRealtime,
        path = "/v1/realtime",
        contextWindow = 32_000,
        voices = listOf(VoiceOption("marin", isDefault = true)),
        inputTranscriptionModel = "gpt-4o-mini-transcribe",
        isDefault = true,
    )
    private val catalog = VoiceCatalog(
        schemaVersion = 2,
        providers = mapOf(
            ProviderKind.OpenAI to VoiceProviderCatalog(realtime = listOf(entry)),
            ProviderKind.Relay to VoiceProviderCatalog(realtime = listOf(entry)),
        ),
    )

    private fun provider(kind: ProviderKind, authMode: ProviderAuthMode = ProviderAuthMode.ApiKey) = Provider(
        id = "provider-${kind.name}",
        kind = kind,
        apiKey = "sk-test",
        authMode = authMode,
        status = ProviderConnectionState.Connected,
    )

    @Test
    fun `official apiKey connection resolves catalog realtime model`() {
        val openAI = provider(ProviderKind.OpenAI)

        val hit = RealtimeSelection.realtimeEntry(openAI, " gpt-realtime ", catalog)

        assertEquals(entry, hit)
        val model = RealtimeSelection.realtimeAIModel(hit!!)
        assertEquals("gpt-realtime", model.id)
        assertEquals("gpt-realtime", model.name)
        assertEquals(32_000, model.contextLength)
    }

    @Test
    fun `relay connection is never realtime even when catalog lists the model`() {
        assertNull(RealtimeSelection.realtimeEntry(provider(ProviderKind.Relay), "gpt-realtime", catalog))
    }

    @Test
    fun `subscription login connection is never realtime`() {
        val subscription = provider(ProviderKind.OpenAI, ProviderAuthMode.Subscription)

        assertNull(RealtimeSelection.realtimeEntry(subscription, "gpt-realtime", catalog))
    }

    @Test
    fun `model absent from catalog or catalog not loaded is not realtime`() {
        val openAI = provider(ProviderKind.OpenAI)

        // Do not guess from the id text: a model whose id contains "realtime" but is absent from the catalog does not count.
        assertNull(RealtimeSelection.realtimeEntry(openAI, "gpt-realtime-mini", catalog))
        assertNull(RealtimeSelection.realtimeEntry(openAI, "gpt-realtime", null))
        assertNull(RealtimeSelection.realtimeEntry(provider(ProviderKind.Anthropic), "gpt-realtime", catalog))
        assertFalse(RealtimeSelection.isRealtime(openAI, "gpt-5.4", catalog))
    }
}
