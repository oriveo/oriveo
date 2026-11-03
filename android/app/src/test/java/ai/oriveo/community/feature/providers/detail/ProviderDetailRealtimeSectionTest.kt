package ai.oriveo.community.feature.providers.detail

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTransport
import ai.oriveo.community.core.voice.realtime.HomeRealtimeSelectionStore
import ai.oriveo.community.testing.TestSharedPreferences
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Provider detail "Realtime voice" section (same as iOS): shown only for official apiKey connections; rows follow catalog order with isDefault first;
 * Header "N available models" counts text models only; the chat button writes the home selection and returns to home (first use shows the cloud notice first); the check mark marks the home selection.
 */
class ProviderDetailRealtimeSectionTest {

    private val prefs = TestSharedPreferences()
    private val settings = VoiceEngineSettings { prefs }

    private val openAI = Provider(
        id = "conn-openai",
        kind = ProviderKind.OpenAI,
        apiKey = "sk-live",
        baseUrlText = "https://api.openai.com/v1",
        models = listOf(AIModel(id = "gpt-5", name = "GPT-5")),
    )
    private val realtime = VoiceRealtimeEntry(
        model = "gpt-realtime",
        transport = VoiceTransport.OpenAIRealtime,
        path = "/realtime",
        contextWindow = 32_000,
        voices = listOf(VoiceOption("marin", isDefault = true)),
        inputTranscriptionModel = "gpt-4o-transcribe",
        isDefault = true,
    )
    private val mini = realtime.copy(model = "gpt-realtime-mini", isDefault = false)
    private val available = VoiceCatalogState.Available(
        VoiceCatalog(
            schemaVersion = 2,
            providers = mapOf(ProviderKind.OpenAI to VoiceProviderCatalog(realtime = listOf(mini, realtime))),
        ),
    )

    @Test
    fun `only official apiKey connections show the group`() {
        val relay = Provider(id = "conn-relay", kind = ProviderKind.Relay, apiKey = "rk", baseUrlText = "https://relay.example.com/v1")
        val openRouter = Provider(id = "conn-or", kind = ProviderKind.OpenRouter, apiKey = "or-live")
        val subscription = openAI.copy(id = "conn-sub", authMode = ProviderAuthMode.Subscription)
        val allKinds = VoiceCatalogState.Available(
            VoiceCatalog(
                schemaVersion = 2,
                providers = listOf(ProviderKind.OpenAI, ProviderKind.Relay, ProviderKind.OpenRouter)
                    .associateWith { VoiceProviderCatalog(realtime = listOf(realtime)) },
            ),
        )
        for (provider in listOf(relay, openRouter, subscription)) {
            assertNull(provider.id, providerDetailRealtimeState(provider, allKinds, selection = null))
            assertNull(provider.id, providerDetailRealtimeState(provider, catalogState = null, selection = null))
        }
        assertNotNull(providerDetailRealtimeState(openAI, allKinds, selection = null))
    }

    @Test
    fun `rows follow catalog order with isDefault first`() {
        val rows = providerDetailRealtimeState(openAI, available, selection = null)!!
        assertEquals(listOf("gpt-realtime", "gpt-realtime-mini"), rows.rows.map { it.entry.model })
    }

    @Test
    fun no_rows_no_section_while_loading_or_failed() {
        // Same as iOS ProviderRealtimeModelsSection: no rows means no section; while loading or on failure, no spinner or "unable to load" either
        assertNull(providerDetailRealtimeState(openAI, catalogState = null, selection = null))
        assertNull(providerDetailRealtimeState(openAI, VoiceCatalogState.LoadFailed, selection = null))
        assertNull(providerDetailRealtimeState(openAI, VoiceCatalogState.Unavailable, selection = null))
        val noRealtime = VoiceCatalogState.Available(
            VoiceCatalog(schemaVersion = 2, providers = mapOf(ProviderKind.OpenAI to VoiceProviderCatalog())),
        )
        assertNull(providerDetailRealtimeState(openAI, noRealtime, selection = null))
        val section = source("ProviderDetailRealtimeModels.kt")
        assertFalse("no loading spinner", section.contains("CircularProgressIndicator"))
        assertFalse("no failure retry row", section.contains("provider_detail_realtime_retry_button"))
        assertFalse("rows no longer carry the left gradient tile of the picker", section.contains("ModelPickerRealtimeRow"))
    }

    @Test
    fun chat_button_has_button_role_and_tag() {
        val section = source("ProviderDetailRealtimeModels.kt")
        val button = section.substring(section.indexOf("private fun RealtimeRowChatButton("))
        assertTrue("chat button exposed with button semantics", button.contains("role = Role.Button"))
        assertTrue(section.contains(".testTag(\"provider_detail_realtime_model_chat_button\")"))
        assertTrue(section.contains(".sentryClickTag(\"provider_detail_realtime_model_chat_button\")"))
        assertFalse(section.contains("\"provider_detail_realtime_chat_button\""))
    }

    @Test
    fun `check mark equals home selection of this connection`() {
        val rows = providerDetailRealtimeState(openAI, available, selection = openAI.id to "gpt-realtime-mini")!!
        assertEquals(listOf(false, true), rows.rows.map { it.checked })
        val otherConnection = providerDetailRealtimeState(openAI, available, selection = "conn-other" to "gpt-realtime-mini")!!
        assertTrue(otherConnection.rows.none { it.checked })
    }

    @Test
    fun `header count only counts text models`() {
        assertNotNull(providerDetailRealtimeState(openAI, available, selection = null))
        assertEquals(1, openAI.enabledModelCount)
        val section = source("ProviderDetailRealtimeModels.kt")
        assertFalse("realtime section must not change the text model count", section.contains("enabledModelCount"))
        assertFalse("realtime section header carries no count", section.contains("provider_detail_n_models"))
    }

    @Test
    fun `chat button writes home selection and returns home once disclosure accepted`() {
        val store = HomeRealtimeSelectionStore()
        var homeOpened = 0
        // First time: notify first, do not write or navigate
        val pending = startProviderDetailRealtime(
            providerId = openAI.id,
            providerKind = openAI.kind,
            modelId = "gpt-realtime",
            disclosure = settings.disclosure,
            selection = store,
            openHome = { homeOpened += 1 },
        )
        assertNotNull(pending)
        assertNull(store.selection.value)
        assertEquals(0, homeOpened)

        acceptProviderDetailRealtime(pending!!, settings.disclosure, store) { homeOpened += 1 }
        assertEquals(openAI.id to "gpt-realtime", store.selection.value)
        assertEquals(1, homeOpened)
        assertTrue(settings.disclosure.isAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime))

        // Already agreed: write directly and return to home
        val again = startProviderDetailRealtime(
            providerId = openAI.id,
            providerKind = openAI.kind,
            modelId = "gpt-realtime-mini",
            disclosure = settings.disclosure,
            selection = store,
            openHome = { homeOpened += 1 },
        )
        assertNull(again)
        assertEquals(openAI.id to "gpt-realtime-mini", store.selection.value)
        assertEquals(2, homeOpened)
    }

    @Test
    fun `detail screen and nav host wire the realtime group`() {
        val screen = source("ProviderDetailScreen.kt")
        val enabledCall = screen.indexOf("providerDetailEnabledModels(")
        val realtimeCall = screen.indexOf("providerDetailRealtimeModels(")
        assertTrue(enabledCall >= 0 && realtimeCall > enabledCall)
        assertTrue(screen.contains("onStartRealtime"))
        val nav = File("src/main/java/ai/oriveo/community/core/navigation/OriveoNavHost.kt").readText()
        assertTrue(nav.contains("onStartRealtime = "))
        assertTrue(nav.contains("startProviderDetailRealtime("))
        assertTrue(nav.contains("acceptProviderDetailRealtime("))
    }

    private fun source(name: String): String =
        File("src/main/java/ai/oriveo/community/feature/providers/detail/$name").readText()
}
