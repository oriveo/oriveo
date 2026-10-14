package ai.oriveo.community.feature.providers.detail

import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.RelayWebFragmentStore
import ai.oriveo.community.core.provider.relay.RelayWebFragments
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The detail page "web search" row and saving on the web search settings page (RelayDetail board model card). */
@OptIn(ExperimentalCoroutinesApi::class)
class RelayDetailWebSearchTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun relay(requested: RelayRequestedConfig = RelayRequestedConfig(transport = RelayTransport.OpenAIResponses)) =
        Provider(id = "provider-1", kind = ProviderKind.Relay, baseUrlText = "https://relay.test/v1", relayRequested = requested)

    private fun webRow(provider: Provider, store: RelayWebFragmentStore) =
        RelayDetailBoardModel.build(provider, isRedetecting = false, webFragmentStore = store)
            .modelRows.firstOrNull { it.id == RelayDetailRowId.WebSearch }

    @Test
    fun relay_detail_web_search_row_sits_under_the_model_library_and_opens_the_settings_page() {
        val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        val rows = RelayDetailBoardModel.build(relay(), isRedetecting = false, webFragmentStore = store).modelRows
        // The parameters row is merged into the third row of the model card.
        assertEquals(listOf(RelayDetailRowId.ModelLibrary, RelayDetailRowId.WebSearch, RelayDetailRowId.Parameters), rows.map { it.id })
        val row = rows[1]
        assertEquals(R.string.web_search, row.titleRes)
        assertEquals(R.string.relay_web_row_subtitle, row.valueRes)
        assertEquals(RelayDetailAction.OpenWebSearch, row.action)

        // Local engine connections have no web search row.
        val local = relay(RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, engineProfile = "ollama"))
        assertNull(webRow(local, store))
    }

    @Test
    fun relay_detail_web_search_row_status_follows_the_effective_fragments() {
        val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        assertEquals(R.string.relay_web_status_not_set, webRow(relay(), store)?.trailingRes)

        // A legacy field mapped on read also counts as configured.
        val legacy = relay(RelayRequestedConfig(transport = RelayTransport.OpenAIResponses, hasWebSearch = true))
        assertEquals(R.string.relay_web_status_set, webRow(legacy, store)?.trailingRes)

        store.save("provider-1", RelayTransport.AnthropicMessages, """{"tools":[{"type":"web_search_20250305","name":"web_search"}]}""")
        assertEquals(R.string.relay_web_status_set, webRow(relay(), store)?.trailingRes)
    }

    @Test
    fun relay_web_search_save_writes_the_store_and_clears_the_two_legacy_fields() = runTest(dispatcher) {
        val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        val provider = relay(
            RelayRequestedConfig(transport = RelayTransport.OpenAIResponses, hasWebSearch = true, webSearchProfile = "oai_responses_web"),
        )
        val repository = mockk<ProviderRepository>(relaxed = true)
        every { repository.observeById("provider-1") } returns MutableStateFlow(provider)
        val saved = slot<Provider>()
        coEvery { repository.updateProvider(capture(saved)) } returns Unit
        val viewModel = ProviderDetailViewModel(
            savedStateHandle = SavedStateHandle(mapOf("providerID" to "provider-1")),
            providerRepository = repository,
            appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true),
            metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
            applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true),
            defaultDispatcher = dispatcher,
        )

        // Page initial value: with nothing stored, the mapped legacy field result is shown.
        val texts = RelayWebSearchPageModel.initialTexts(provider, store)
        assertTrue(texts.getValue(RelayTransport.OpenAIResponses).contains("web_search"))

        // The Messages section is filled with a template and the Responses section is cleared: after saving only the Messages section remains stored.
        val edited = texts + mapOf(
            RelayTransport.OpenAIResponses to "",
            RelayTransport.GeminiGenerateContent to "",
            RelayTransport.AnthropicMessages to RelayWebSearchPageModel.templateText(RelayTransport.AnthropicMessages),
        )
        val plan = requireNotNull(RelayWebSearchPageModel.plan(edited))
        viewModel.saveRelayWebFragments(provider, plan, store)
        advanceUntilIdle()

        assertEquals(setOf(RelayTransport.AnthropicMessages.value), store.stored("provider-1").keys)
        assertEquals(RelayWebFragments.template(RelayTransport.AnthropicMessages), store.stored("provider-1")[RelayTransport.AnthropicMessages.value])
        val requested = saved.captured.relayRequested!!
        assertFalse("hasWebSearch is cleared", requested.hasWebSearch)
        assertNull("webSearchProfile is cleared", requested.webSearchProfile)
        assertEquals(RelayTransport.OpenAIResponses, requested.transport)

        // Save is not tappable when any section has an error.
        assertNull(RelayWebSearchPageModel.plan(edited + (RelayTransport.OpenAIChatCompletions to """{"model":"x"}""")))
    }
}
