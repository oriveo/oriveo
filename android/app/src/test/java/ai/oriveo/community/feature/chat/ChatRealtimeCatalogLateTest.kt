package ai.oriveo.community.feature.chat

import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTransport
import ai.oriveo.community.core.voice.realtime.RealtimeSelection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.mockk.verify

/**
 * Cold start with a late voice catalog: while the catalog is not ready, the selected realtime model is not collapsed into a text model (activeModelId is not rewritten),
 * and once the catalog is ready the same selection is recomputed and classified as realtime.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ChatRealtimeCatalogLateTest {
    private val textModel = AIModel(id = "gpt-4o-mini", name = "GPT-4o mini", isDefault = true, capabilities = listOf(ModelCapability.Text))
    private val provider = Provider(
        id = "openai-1",
        kind = ProviderKind.OpenAI,
        status = ProviderConnectionState.Connected,
        apiKey = "local-key",
        models = listOf(textModel),
    )
    private val catalog = VoiceCatalog(
        schemaVersion = 2,
        providers = mapOf(
            ProviderKind.OpenAI to VoiceProviderCatalog(
                realtime = listOf(
                    VoiceRealtimeEntry(
                        model = REALTIME,
                        transport = VoiceTransport.OpenAIRealtime,
                        path = "/v1/realtime",
                        contextWindow = 32_000,
                        voices = listOf(VoiceOption("marin", isDefault = true)),
                        inputTranscriptionModel = "gpt-4o-mini-transcribe",
                    ),
                ),
            ),
        ),
    )

    private fun resolve(conversation: Conversation?, voiceCatalog: VoiceCatalog?) = resolveChatConversationState(
        conversation = conversation,
        providers = listOf(provider),
        activeProviderId = provider.id,
        activeModelId = REALTIME,
        providersLoaded = true,
        voiceCatalog = voiceCatalog,
    )

    private fun assertLateCatalog(conversation: Conversation?) {
        // Catalog not ready: the selected item keeps the realtime model instead of being rewritten to a text model.
        val early = resolve(conversation, voiceCatalog = null)
        assertFalse(RealtimeSelection.isRealtime(early.provider, early.model?.id, null))
        assertNull(conversationSelectionToSync(listOf(provider), provider.id, REALTIME, early, voiceCatalog = null))
        // Catalog ready and recomputed: session state is realtime, and the selected item is still not rewritten.
        val ready = resolve(conversation, voiceCatalog = catalog)
        assertEquals(REALTIME, ready.model?.id)
        assertTrue(RealtimeSelection.isRealtime(ready.provider, ready.model?.id, catalog))
        assertNull(conversationSelectionToSync(listOf(provider), provider.id, REALTIME, ready, voiceCatalog = catalog))
    }

    @Test
    fun draft_keeps_realtime_selection_until_catalog_ready() = assertLateCatalog(conversation = null)

    @Test
    fun conversation_keeps_realtime_selection_until_catalog_ready() = assertLateCatalog(
        Conversation(
            id = "conversation-1",
            title = "Chat",
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = REALTIME,
        ),
    )

    @Test
    fun catalog_not_ready_still_converges_enabled_text_model() {
        // Selected item is in the text list: catalog not ready does not affect the existing collapse (nothing is written if the resolved result matches the selection).
        val state = resolveChatConversationState(
            conversation = null,
            providers = listOf(provider),
            activeProviderId = provider.id,
            activeModelId = textModel.id,
            providersLoaded = true,
        )
        assertNull(conversationSelectionToSync(listOf(provider), provider.id, textModel.id, state, voiceCatalog = null))
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        MetadataTestFixtures.clear()
    }

    private fun conversationOn(target: Provider, modelId: String) = Conversation(
        id = "conversation-1",
        title = "Chat",
        providerID = target.id,
        providerKind = target.kind,
        modelID = modelId,
    )

    @Test
    fun realtime_conversation_not_retired_while_voice_catalog_pending() {
        // Text catalog loaded without the realtime id: do not mark it retired while the voice catalog is not ready.
        MetadataTestFixtures.applyRaw(TEXT_CATALOG)
        val conversation = conversationOn(provider, REALTIME)
        assertNull(resolve(conversation, voiceCatalog = null).issue)
        // Catalog arrives and is re-checked: classified as realtime, still not retired.
        val ready = resolve(conversation, voiceCatalog = catalog)
        assertNull(ready.issue)
        assertEquals(REALTIME, ready.model?.id)
    }

    @Test
    fun awaiting_voice_catalog_blocks_send_until_catalog_arrives() {
        // Voice catalog not ready and the session model is not in the enabled text list: show "waiting for catalog" and block send, with no problem row.
        MetadataTestFixtures.applyRaw(TEXT_CATALOG)
        val conversation = conversationOn(provider, REALTIME)
        val pending = resolve(conversation, voiceCatalog = null)
        assertTrue(pending.isAwaitingVoiceCatalog)
        assertTrue(pending.isSendBlocked)
        assertNull(pending.issue)
        // Catalog arrives and contains this id: after re-check, no longer waiting, sendable.
        val ready = resolve(conversation, voiceCatalog = catalog)
        assertFalse(ready.isAwaitingVoiceCatalog)
        assertFalse(ready.isSendBlocked)
    }

    @Test
    fun switch_provider_with_realtime_id_not_retired() {
        // Session on connection A; user switches to another official apiKey connection and selects a realtime id: do not retire while the catalog is not ready.
        MetadataTestFixtures.applyRaw(TEXT_CATALOG)
        val other = provider.copy(id = "openai-2", apiKey = "other-key")
        val state = resolveChatConversationState(
            conversation = conversationOn(provider, textModel.id),
            providers = listOf(provider, other),
            activeProviderId = other.id,
            activeModelId = REALTIME,
            providersLoaded = true,
            voiceCatalog = null,
        )
        assertEquals(other.id, state.provider?.id)
        assertNull(state.issue)
    }

    @Test
    fun catalog_ready_recomputes_realtime_selection() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val states = MutableStateFlow<VoiceCatalogState?>(null)
        val viewModel = DraftChatViewModelFixture(
            provider = provider,
            applicationScope = backgroundScope,
            voiceCatalog = { (states.value as? VoiceCatalogState.Available)?.catalog },
        ).create()
        testScheduler.runCurrent()
        val subscription = backgroundScope.launch { viewModel.recomputeWhenVoiceCatalogReady(states) }
        // Catalog not ready and realtime model selected: the selection is not rewritten, but not yet classified as realtime.
        viewModel.selectModel(provider.id, REALTIME)
        testScheduler.runCurrent()
        assertEquals(REALTIME, viewModel.activeModelId)
        assertFalse(viewModel.isRealtimeModelSelected())
        // Catalog becomes available: session state recomputed once, classified as realtime, selection unchanged.
        states.value = VoiceCatalogState.Available(catalog)
        testScheduler.runCurrent()
        assertEquals(REALTIME, viewModel.conversationState.model?.id)
        assertTrue(viewModel.isRealtimeModelSelected())
        assertEquals(REALTIME, viewModel.activeModelId)
        assertEquals(provider.id, viewModel.selectedRealtimeVoice()?.connectionId)
        // Same available catalog pushed again (refresh): no recomputed write.
        val settled = viewModel.conversationState
        states.value = VoiceCatalogState.Available(catalog)
        testScheduler.runCurrent()
        assertTrue(settled === viewModel.conversationState)
        subscription.cancel()
    }

    @Test
    fun catalog_change_recomputes_realtime_selection() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val states = MutableStateFlow<VoiceCatalogState?>(VoiceCatalogState.Available(catalog))
        val viewModel = DraftChatViewModelFixture(
            provider = provider,
            applicationScope = backgroundScope,
            voiceCatalog = { (states.value as? VoiceCatalogState.Available)?.catalog },
        ).create()
        testScheduler.runCurrent()
        val subscription = backgroundScope.launch { viewModel.recomputeWhenVoiceCatalogReady(states) }
        viewModel.selectModel(provider.id, REALTIME)
        testScheduler.runCurrent()
        assertEquals(REALTIME, viewModel.conversationState.model?.id)
        assertTrue(viewModel.isRealtimeModelSelected())
        val realtimeState = viewModel.conversationState
        // Still available but content changed (model retired): re-check; session state is no longer the realtime placeholder model
        val withoutRealtime = catalog.copy(
            providers = mapOf(
                ProviderKind.OpenAI to VoiceProviderCatalog(
                    realtime = catalog.provider(ProviderKind.OpenAI).realtime.map { it.copy(model = "$REALTIME-mini") },
                ),
            ),
        )
        states.value = VoiceCatalogState.Available(withoutRealtime)
        testScheduler.runCurrent()
        assertNotEquals(realtimeState, viewModel.conversationState)
        assertFalse(viewModel.isRealtimeModelSelected())
        subscription.cancel()
    }

    private fun DraftChatViewModelFixture.verifyNoLastUsedWrite() {
        verify(exactly = 0) { appPreferences.primeLastUsedModel(any(), any()) }
        coVerify(exactly = 0) { appPreferences.setLastUsedModel(any<String>(), any<String>()) }
        coVerify(exactly = 0) { appPreferences.setLastUsedModel(any<String>(), any<AIModel>(), any()) }
    }

    @Test
    fun catalog_nil_select_defers_last_used() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val states = MutableStateFlow<VoiceCatalogState?>(null)
        val fixture = DraftChatViewModelFixture(
            provider = provider,
            applicationScope = backgroundScope,
            voiceCatalog = { (states.value as? VoiceCatalogState.Available)?.catalog },
        )
        val viewModel = fixture.create()
        testScheduler.runCurrent()
        val subscription = backgroundScope.launch { viewModel.recomputeWhenVoiceCatalogReady(states) }
        // Realtime model selected before the catalog is ready: stage it, no prewarm, no last-used write.
        viewModel.selectModel(provider.id, REALTIME)
        testScheduler.runCurrent()
        fixture.verifyNoLastUsedWrite()
        // Catalog arrives: the staged item is classified as realtime, realtime selection set, still no last-used write.
        states.value = VoiceCatalogState.Available(catalog)
        testScheduler.runCurrent()
        assertTrue(viewModel.isRealtimeModelSelected())
        assertEquals(REALTIME, viewModel.activeModelId)
        fixture.verifyNoLastUsedWrite()
        subscription.cancel()
    }

    @Test
    fun catalog_nil_select_text_writes_last_used_on_arrival() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val states = MutableStateFlow<VoiceCatalogState?>(null)
        val fixture = DraftChatViewModelFixture(
            provider = provider,
            applicationScope = backgroundScope,
            voiceCatalog = { (states.value as? VoiceCatalogState.Available)?.catalog },
        )
        val viewModel = fixture.create()
        testScheduler.runCurrent()
        val subscription = backgroundScope.launch { viewModel.recomputeWhenVoiceCatalogReady(states) }
        // Text model selected before the catalog is ready: likewise staged, no write.
        viewModel.selectModel(provider.id, textModel.id)
        testScheduler.runCurrent()
        fixture.verifyNoLastUsedWrite()
        // Catalog arrives: the staged item is classified as non-realtime; last-used is written as usual (once only).
        states.value = VoiceCatalogState.Available(catalog)
        testScheduler.runCurrent()
        assertFalse(viewModel.isRealtimeModelSelected())
        verify(exactly = 1) { fixture.appPreferences.primeLastUsedModel(provider.id, textModel.id) }
        coVerify(exactly = 1) { fixture.appPreferences.setLastUsedModel(provider.id, textModel, provider.kind) }
        // Same catalog pushed again: the staged item is already consumed, no write.
        states.value = VoiceCatalogState.Available(catalog.copy())
        testScheduler.runCurrent()
        coVerify(exactly = 1) { fixture.appPreferences.setLastUsedModel(provider.id, textModel, provider.kind) }
        subscription.cancel()
    }

    @Test
    fun pending_selection_resolves_when_providers_load_after_catalog() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val states = MutableStateFlow<VoiceCatalogState?>(null)
        val loaded = MutableStateFlow<List<Provider>?>(null)
        val fixture = DraftChatViewModelFixture(
            provider = provider,
            applicationScope = backgroundScope,
            voiceCatalog = { (states.value as? VoiceCatalogState.Available)?.catalog },
            providersFlow = loaded.filterNotNull(),
        )
        val viewModel = fixture.create()
        testScheduler.runCurrent()
        val subscription = backgroundScope.launch { viewModel.recomputeWhenVoiceCatalogReady(states) }
        // Text model selected before both the catalog and the connection list arrive: stage it, no write.
        viewModel.selectModel(provider.id, textModel.id)
        testScheduler.runCurrent()
        fixture.verifyNoLastUsedWrite()
        // Catalog arrived first, connection list still not loaded: cannot classify yet, no write.
        states.value = VoiceCatalogState.Available(catalog)
        testScheduler.runCurrent()
        fixture.verifyNoLastUsedWrite()
        // Connection list arrives later: classify the already-arrived catalog once; non-realtime is written as last-used as usual (once only).
        loaded.value = listOf(provider)
        testScheduler.runCurrent()
        verify(exactly = 1) { fixture.appPreferences.primeLastUsedModel(provider.id, textModel.id) }
        coVerify(exactly = 1) { fixture.appPreferences.setLastUsedModel(provider.id, textModel, provider.kind) }
        // Same catalog pushed again: the staged item is already consumed, no write.
        states.value = VoiceCatalogState.Available(catalog.copy())
        testScheduler.runCurrent()
        coVerify(exactly = 1) { fixture.appPreferences.setLastUsedModel(provider.id, textModel, provider.kind) }
        subscription.cancel()
    }

    @Test
    fun pending_unknown_id_toasts_model_gone_and_keeps_selection() = runTest {
        Dispatchers.setMain(UnconfinedTestDispatcher(testScheduler))
        val prefs = mockk<AppPreferencesRepository>(relaxed = true)
        val repository = mockk<ProviderRepository>(relaxed = true)
        coEvery { repository.getById(provider.id) } returns provider
        val snackbar = mockk<GlobalSnackbarManager>(relaxed = true)
        var catalogNow: VoiceCatalog? = null
        var selected = provider.id to textModel.id
        val coordinator = ChatModelSelectionCoordinator(
            viewModelScope = backgroundScope,
            appPreferencesRepository = prefs,
            providerRepository = repository,
            conversationRepository = mockk<ConversationRepository>(relaxed = true),
            globalSnackbarManager = snackbar,
            providers = { listOf(provider) },
            activeProviderId = { selected.first },
            activeModelId = { selected.second },
            activeConversationId = { null },
            voiceCatalog = { catalogNow },
        )
        // Id selected before the catalog is ready that neither the connection text list nor the realtime catalog recognizes: stage it, no write.
        coordinator.selectModel(provider.id, UNKNOWN) { p, m -> selected = p to m }
        testScheduler.runCurrent()
        verify(exactly = 0) { prefs.primeLastUsedModel(any(), any()) }
        // Catalog arrives and reclassifies: not recognized, toast "no longer available", no last-used write, original selection restored.
        catalogNow = catalog
        coordinator.resolvePendingSelection(catalog, listOf(provider))
        testScheduler.runCurrent()
        verify(exactly = 1) {
            snackbar.show(
                match {
                    it.message == UiText.Resource(R.string.voice_realtime_failure_model_gone, listOf(UNKNOWN)) &&
                        it.style == GlobalToastStyle.Warning
                },
            )
        }
        verify(exactly = 0) { prefs.primeLastUsedModel(any(), any()) }
        coVerify(exactly = 0) { prefs.setLastUsedModel(any<String>(), any<String>()) }
        coVerify(exactly = 0) { prefs.setLastUsedModel(any<String>(), any<AIModel>(), any()) }
        assertEquals(provider.id to textModel.id, selected)
    }

    private companion object {
        const val UNKNOWN = "gpt-unknown-42"
        const val REALTIME = "gpt-realtime"
        val TEXT_CATALOG = """
            {"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-4o-mini","retiredModels":[],"resolveMap":{},"models":{"gpt-4o-mini":{"canonicalModelId":"gpt-4o-mini","displayName":"GPT-4o mini"}}}}}
        """.trimIndent()
    }
}
