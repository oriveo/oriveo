package ai.oriveo.community.feature.providers.detail

import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterPresetStore
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayKindDefaults
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.ManualRetainedPruner
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import org.junit.After
import org.junit.Before
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ProviderDetailViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>()
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true)

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        ManualRetainedPruner.flagOverrideForTesting = null
        MetadataTestFixtures.clear()
    }

    @Test
    fun `disableOptionalModels keeps current default only`() = runTest {
        val provider = sampleProvider(
            models = listOf(
                AIModel(id = "gpt-4.1", name = "GPT-4.1", isDefault = true),
                AIModel(id = "gpt-4.1-mini", name = "GPT-4.1 Mini"),
            ),
        )
        every { providerRepository.observeById("provider-1") } returns flowOf(provider)
        io.mockk.coEvery { providerRepository.updateProvider(any()) } returns Unit

        val viewModel = ProviderDetailViewModel(
            savedStateHandle = SavedStateHandle(mapOf("providerID" to "provider-1")),
            providerRepository = providerRepository,
            appPreferencesRepository = appPreferencesRepository,
            metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
            applicationScope = kotlinx.coroutines.CoroutineScope(
                kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Unconfined
            ),
            globalSnackbarManager = globalSnackbarManager,
        )
        val providerJob = backgroundScope.launch(dispatcher) {
            viewModel.provider.collect {}
        }
        advanceUntilIdle()

        viewModel.disableOptionalModels()
        advanceUntilIdle()

        coVerify {
            providerRepository.updateProvider(
                match {
                    it.models.size == 1 &&
                        it.models.first().id == "gpt-4.1" &&
                        it.models.first().isDefault
                },
            )
        }
        providerJob.cancel()
    }

    @Test
    fun `resync emits verified snackbar when status stays Connected`() = runTest {
        val providerState = MutableStateFlow(sampleProvider())
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.resyncProvider("provider-1") } returns Unit

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.resync()
        advanceUntilIdle()

        coVerify(exactly = 1) { providerRepository.resyncProvider("provider-1") }
        io.mockk.verify(exactly = 1) {
            globalSnackbarManager.show(
                match {
                    (it.message as? UiText.Resource)?.resId == R.string.snackbar_connection_verified &&
                        it.style == GlobalToastStyle.Success
                },
            )
        }
        providerJob.cancel()
    }

    @Test
    fun `relay ordinary reverify sends one token only and never refreshes catalog`() = runTest {
        val relay = relayProvider(authMode = RelayAuthMode.None)
        val providerState = MutableStateFlow(relay)
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.reverifyRelayProvider("provider-1") } returns relay

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.resync()
        advanceUntilIdle()

        coVerify(exactly = 1) { providerRepository.reverifyRelayProvider("provider-1") }
        coVerify(exactly = 0) { providerRepository.resyncProvider("provider-1") }
        coVerify(exactly = 0) { providerRepository.refreshRelayCatalogOnly("provider-1") }
        assertEquals(
            ProviderDetailViewModel.RelayCatalogUiState.Available,
            viewModel.relayCatalogUiState(relay),
        )
        providerJob.cancel()
    }

    @Test
    fun `resync emits check-failed snackbar when Repository writes Issue status`() = runTest {
        val providerState = MutableStateFlow(sampleProvider())
        every { providerRepository.observeById("provider-1") } returns providerState
        // Repository swallows the exception internally and sets status to Issue (no cache) / keeps Connected (cached)
        // Simulates the real path where Repository sets status to Issue
        coEvery { providerRepository.resyncProvider("provider-1") } coAnswers {
            providerState.value = providerState.value.copy(
                status = ProviderConnectionState.Issue("Invalid API key"),
            )
        }

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.resync()
        advanceUntilIdle()

        coVerify(exactly = 1) { providerRepository.resyncProvider("provider-1") }
        io.mockk.verify(exactly = 1) {
            globalSnackbarManager.show(
                match {
                    val res = it.message as? UiText.Resource ?: return@match false
                    res.resId == R.string.snackbar_connection_check_failed &&
                        res.args == listOf<Any>("Invalid API key") &&
                        it.style == GlobalToastStyle.Error
                },
            )
        }
        providerJob.cancel()
    }

    @Test
    fun `resync survives rethrown exception with bottom snackbar`() = runTest {
        // Fallback: if Repository ever rethrows, the VM must not crash viewModelScope
        val providerState = MutableStateFlow(sampleProvider())
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.resyncProvider("provider-1") } throws RuntimeException("boom")

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.resync()
        advanceUntilIdle()

        io.mockk.verify(exactly = 1) {
            globalSnackbarManager.show(
                match {
                    val res = it.message as? UiText.Resource ?: return@match false
                    res.resId == R.string.snackbar_connection_check_failed &&
                        res.args == listOf<Any>("boom") &&
                        it.style == GlobalToastStyle.Error
                },
            )
        }
        providerJob.cancel()
    }

    @Test
    fun `resync toggles isResyncing true during and false after`() = runTest {
        // Locks the immediate loading state: isResyncing must be true while resync runs (what the UI uses for the spinner / disabling,
        // and no longer depends on the persisted status, which StateFlow conflation would swallow), and reset to false when done.
        val providerState = MutableStateFlow(sampleProvider())
        every { providerRepository.observeById("provider-1") } returns providerState
        lateinit var viewModel: ProviderDetailViewModel
        coEvery { providerRepository.resyncProvider("provider-1") } coAnswers {
            assertTrue("isResyncing must be true while resync runs", viewModel.isResyncing)
        }

        viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        assertFalse(viewModel.isResyncing)
        viewModel.resync()
        advanceUntilIdle()
        assertFalse("isResyncing must reset after resync completes", viewModel.isResyncing)

        coVerify(exactly = 1) { providerRepository.resyncProvider("provider-1") }
        providerJob.cancel()
    }

    @Test
    fun `resync localizes persisted relay reason code via ErrorMapper`() = runTest {
        // Immediate Relay guidance keeps the full error object; the persisted state keeps only a stable reason code.
        // Input comes from the production constant, so neither old nor current data ever shows the English key to the user.
        val context = io.mockk.mockk<android.content.Context>()
        io.mockk.every {
            context.getString(R.string.provider_connection_unverified)
        } returns "Localized unverified notice"
        org.koin.core.context.startKoin {
            modules(org.koin.dsl.module { single<android.content.Context> { context } })
        }
        try {
            val providerState = MutableStateFlow(sampleProvider())
            every { providerRepository.observeById("provider-1") } returns providerState
            coEvery { providerRepository.resyncProvider("provider-1") } coAnswers {
                providerState.value = providerState.value.copy(
                    status = ProviderConnectionState.Issue(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
                )
            }

            val viewModel = createViewModel(providerState)
            val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
            advanceUntilIdle()

            viewModel.resync()
            advanceUntilIdle()

            io.mockk.verify(exactly = 1) {
                globalSnackbarManager.show(
                    match {
                        val res = it.message as? UiText.Resource ?: return@match false
                        res.resId == R.string.snackbar_connection_check_failed &&
                            res.args == listOf<Any>("Localized unverified notice") &&
                            it.style == GlobalToastStyle.Error
                    },
                )
            }
            providerJob.cancel()
        } finally {
            org.koin.core.context.stopKoin()
        }
    }

    @Test
    fun `resync emits warning toast on unverified soft failure`() = runTest {
        // Unverified: status stays Connected (still usable) and the soft notice is carried by lastError, matching the iOS warning toast
        val providerState = MutableStateFlow(sampleProvider())
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.resyncProvider("provider-1") } coAnswers {
            providerState.value = providerState.value.copy(
                status = ProviderConnectionState.Connected,
                lastError = ProviderRepository.PROVIDER_UNVERIFIED_MESSAGE,
            )
        }

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.resync()
        advanceUntilIdle()

        io.mockk.verify(exactly = 1) {
            globalSnackbarManager.show(match { it.style == GlobalToastStyle.Warning })
        }
        providerJob.cancel()
    }

    @Test
    fun `startChatModelID follows this connection's new chat chain and ignores isDefault`() = runTest {
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-legacy","retiredModels":[{"id":"gpt-legacy","displayName":"GPT Legacy","retiredAt":"2026-07-24T00:00:00Z","routedTo":"gpt-next"}],"resolveMap":{"gpt-next":"gpt-next"},"models":{"gpt-next":{"canonicalModelId":"gpt-next","displayName":"GPT Next"},"gpt-x":{"canonicalModelId":"gpt-x","displayName":"GPT X"}}}}}""")
        // gpt-x must be in the catalog to count as available (enabled but missing from the catalog is unavailable).
        val provider = sampleProvider(
            models = listOf(
                AIModel(id = "gpt-legacy", name = "GPT Legacy", isDefault = true),
                AIModel(id = "gpt-x", name = "GPT X"),
                AIModel(id = "gpt-next", name = "GPT Next"),
            ),
        ).copy(apiKey = "sk-test") // a new chat drops connections missing a credential
        val providerState = MutableStateFlow(provider)
        val viewModel = createViewModel(providerState)

        // Last used points at another connection: ignored; the catalog default is retired, so the first available one wins.
        every { appPreferencesRepository.lastUsedModelRefSnapshot } returns
            ai.oriveo.community.core.model.LastUsedModelRef("provider-other", "gpt-next")
        assertEquals("gpt-x", viewModel.startChatModelID(provider))
        // Last used points at this connection and is available: use it.
        every { appPreferencesRepository.lastUsedModelRefSnapshot } returns
            ai.oriveo.community.core.model.LastUsedModelRef("provider-1", "gpt-next")
        assertEquals("gpt-next", viewModel.startChatModelID(provider))
        // Every enabled model retired: no model is offered.
        every { appPreferencesRepository.lastUsedModelRefSnapshot } returns null
        assertNull(viewModel.startChatModelID(provider.copy(models = provider.models.take(1))))
    }

    @Test
    fun `canStartChat follows startChatModelID so all retired disables the button`() = runTest {
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-legacy","retiredModels":[{"id":"gpt-legacy","displayName":"GPT Legacy","retiredAt":"2026-07-24T00:00:00Z","routedTo":"gpt-next"}],"resolveMap":{"gpt-next":"gpt-next"},"models":{"gpt-next":{"canonicalModelId":"gpt-next","displayName":"GPT Next"},"gpt-x":{"canonicalModelId":"gpt-x","displayName":"GPT X"}}}}}""")
        // gpt-x must be in the catalog to count as available (enabled but missing from the catalog is unavailable).
        val provider = sampleProvider(
            models = listOf(
                AIModel(id = "gpt-legacy", name = "GPT Legacy", isDefault = true),
                AIModel(id = "gpt-x", name = "GPT X"),
            ),
        ).copy(apiKey = "sk-test") // a new chat drops connections missing a credential
        val viewModel = createViewModel(MutableStateFlow(provider))
        every { appPreferencesRepository.lastUsedModelRefSnapshot } returns null

        // A model is available: the button is enabled and shares its source with the model the tap selects.
        assertTrue(viewModel.canStartChat(provider))
        assertEquals("gpt-x", viewModel.startChatModelID(provider))
        // Every enabled model retired: isDefault is still set (the old criterion would let it through), but the button is disabled.
        val allRetired = provider.copy(models = provider.models.take(1))
        assertNotNull(allRetired.defaultModel)
        assertFalse(viewModel.canStartChat(allRetired))
    }

    @Test
    fun `model row start chat is blocked by missing credential like canStartChat`() = runTest {
        MetadataTestFixtures.applyRaw("""{"version":1,"contractVersion":1,"providers":{"openAI":{"defaultModelId":"gpt-x","resolveMap":{"gpt-x":"gpt-x"},"models":{"gpt-x":{"canonicalModelId":"gpt-x","displayName":"GPT X"}}}}}""")
        val model = AIModel(id = "gpt-x", name = "GPT X", isDefault = true)
        val withKey = sampleProvider(models = listOf(model)).copy(apiKey = "sk-test")
        val viewModel = createViewModel(MutableStateFlow(withKey))
        every { appPreferencesRepository.lastUsedModelRefSnapshot } returns null

        // With a credential: the model row opens the model that was tapped, and can start just like the Hero button.
        assertTrue(viewModel.canStartChat(withKey))
        assertEquals("gpt-x", viewModel.modelRowStartChatID(withKey, model))
        // Missing key: the Hero button is disabled and the model row does not start either, by the same criterion.
        val missingKey = withKey.copy(apiKey = "")
        assertFalse(viewModel.canStartChat(missingKey))
        assertNull(viewModel.modelRowStartChatID(missingKey, model))
    }

    @Test
    fun `setDefaultModel updates provider and last used model preference`() = runTest {
        val secondaryModel = AIModel(id = "gpt-4.1-mini", name = "GPT-4.1 Mini")
        val provider = sampleProvider(
            models = listOf(
                AIModel(id = "gpt-4.1", name = "GPT-4.1", isDefault = true),
                secondaryModel,
            ),
        )
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.updateProvider(any()) } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel("provider-1", secondaryModel, any()) } returns Unit

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.setDefaultModel(secondaryModel)
        advanceUntilIdle()

        coVerify(exactly = 1) {
            providerRepository.updateProvider(
                match {
                    it.models.first { model -> model.id == "gpt-4.1-mini" }.isDefault &&
                        !it.models.first { model -> model.id == "gpt-4.1" }.isDefault
                },
            )
        }
        coVerify(exactly = 1) { appPreferencesRepository.setLastUsedModel("provider-1", secondaryModel, any()) }
        providerJob.cancel()
    }

    @Test
    fun `RL2-IDENT-07 relay disable removes literal key and canonical key only when no longer shared`() = runTest {
        val base = AIModel(id = "gpt-4o", name = "GPT-4o", canonicalModelId = "gpt-4o")
        val dated = AIModel(id = "gpt-4o-2024-08-06", name = "GPT-4o", canonicalModelId = "gpt-4o")
        val claude = AIModel(id = "claude-sonnet-4-5", name = "Claude", canonicalModelId = "claude-sonnet-4-5")
        var payload: String? = null
        val store = ai.oriveo.community.core.model.CapabilityPreferenceStore(read = { payload }, write = { payload = it })
        val values = ai.oriveo.community.core.model.CapabilityPreferenceValues(reasoningIntent = "high")
        val transport = "r1.b3BlbmFpX3Jlc3BvbnNlcw.cnVudGltZS1yNw"
        listOf("gpt-4o", "gpt-4o-2024-08-06").forEach { store.setConnectionModel(values, "provider-1", it, transport) }
        fun has(key: String) = store.scopeValues("provider-1", key, null, null, transport).connectionModel != null

        // Disabling dated: its literal key is deleted; base stays canonical as gpt-4o, the old canonical key is kept, and base is not disabled with it (RL2-IDENT-03).
        val providerState = MutableStateFlow(
            sampleProvider(kind = ProviderKind.Relay, models = listOf(base, dated, claude), catalogModels = listOf(base, dated, claude)),
        )
        coEvery { providerRepository.updateProvider(any()) } answers { providerState.value = firstArg() }
        val viewModel = createViewModel(providerState, capabilityPreferenceStore = store)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.toggleModelEnabled(dated)
        advanceUntilIdle()
        assertEquals(listOf("gpt-4o", "claude-sonnet-4-5"), providerState.value.models.map { it.id })
        assertFalse(has("gpt-4o-2024-08-06"))
        assertTrue(has("gpt-4o"))

        // When only dated (canonical gpt-4o) is left, disabling it deletes the old canonical key with it.
        store.setConnectionModel(values, "provider-1", "gpt-4o-2024-08-06", transport)
        providerState.value = providerState.value.copy(models = listOf(dated, claude))
        advanceUntilIdle()
        viewModel.toggleModelEnabled(dated)
        advanceUntilIdle()
        assertEquals(listOf("claude-sonnet-4-5"), providerState.value.models.map { it.id })
        assertFalse(has("gpt-4o-2024-08-06"))
        assertFalse(has("gpt-4o"))

        // The canonical key is exactly the literal key of a model that is still enabled (that model has no canonical): not deleted, or it would delete its own record.
        val bareBase = AIModel(id = "gpt-4o", name = "GPT-4o")
        store.setConnectionModel(values, "provider-1", "gpt-4o", transport)
        store.setConnectionModel(values, "provider-1", "gpt-4o-2024-08-06", transport)
        providerState.value = providerState.value.copy(models = listOf(bareBase, dated, claude))
        advanceUntilIdle()
        viewModel.toggleModelEnabled(dated)
        advanceUntilIdle()
        assertEquals(listOf("gpt-4o", "claude-sonnet-4-5"), providerState.value.models.map { it.id })
        assertFalse(has("gpt-4o-2024-08-06"))
        assertTrue(has("gpt-4o"))
        providerJob.cancel()
    }

    @Test
    fun `RL2-PROBE-04 single Relay enable persists first then lazily probes only that model`() = runTest {
        val enabled = AIModel(id = "gpt-4o-mini", name = "GPT-4o mini", isDefault = true)
        val target = AIModel(id = "o3-pro", name = "o3-pro")
        val extra = AIModel(id = "claude-sonnet-4-5", name = "Claude Sonnet 4.5")
        val providerState = MutableStateFlow(
            sampleProvider(kind = ProviderKind.Relay, models = listOf(enabled), catalogModels = listOf(enabled, target, extra)),
        )
        coEvery { providerRepository.updateProvider(any()) } returns Unit
        coEvery { providerRepository.probeEnabledRelayModel(any(), any()) } returns Unit

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.toggleModelEnabled(target)
        advanceUntilIdle()
        io.mockk.coVerifyOrder {
            providerRepository.updateProvider(match { provider -> provider.models.any { it.id == "o3-pro" } })
            providerRepository.probeEnabledRelayModel("provider-1", "o3-pro")
        }

        // Disabling is not a single enable action: no probe (no background batch probing; adding a whole group probes nothing, see BOARD-CATALOG-19).
        viewModel.toggleModelEnabled(enabled)
        advanceUntilIdle()
        coVerify(exactly = 1) { providerRepository.probeEnabledRelayModel(any(), any()) }
        providerJob.cancel()
    }

    @Test
    fun `single Relay enable with two or more keys lands on the key that lists the model`() = runTest {
        val enabled = AIModel(id = "gpt-4o-mini", name = "GPT-4o mini", relayKeyID = "k1")
        val target = AIModel(id = "only-on-backup", name = "only-on-backup", relayListedByKeyIDs = listOf("k2"))
        val providerState = MutableStateFlow(
            sampleProvider(kind = ProviderKind.Relay, models = listOf(enabled), catalogModels = listOf(enabled, target)).copy(
                relayKeys = listOf(
                    ai.oriveo.community.core.model.RelayKey(id = "k1"),
                    ai.oriveo.community.core.model.RelayKey(id = "k2", apiKey = "sk-k2-0000000000000002"),
                ),
            ),
        )
        coEvery { providerRepository.updateProvider(any()) } returns Unit
        coEvery { providerRepository.probeEnabledRelayModel(any(), any()) } returns Unit
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.toggleModelEnabled(target)
        advanceUntilIdle()
        coVerify {
            providerRepository.updateProvider(match { provider -> provider.models.single { it.id == "only-on-backup" }.relayKeyID == "k2" })
        }
        providerJob.cancel()
    }

    @Test
    fun `relay key operation releases the optimistic provider so later repository writes reach the detail page`() = runTest {
        val target = AIModel(id = "gpt-5", name = "GPT-5", relayKeyID = "k1")
        val base = sampleProvider(kind = ProviderKind.Relay, models = listOf(target), catalogModels = listOf(target)).copy(
            relayKeys = listOf(ai.oriveo.community.core.model.RelayKey(id = "k1"), ai.oriveo.community.core.model.RelayKey(id = "k2", apiKey = "sk-k2-0000000000000002")),
        )
        val providerState = MutableStateFlow(base)
        val rebound = base.copy(models = listOf(target.copy(relayKeyID = "k2")))
        coEvery { providerRepository.rebindRelayModelKey("provider-1", "gpt-5", "k2") } coAnswers {
            providerState.value = rebound
            rebound
        }
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.rebindRelayModelKey(target, "k2")
        advanceUntilIdle()
        assertEquals("k2", viewModel.provider.value?.models?.single()?.relayKeyID)

        // The lazy verification / chat after a rebind is written back to relayDeniedKeyID by the repository: the detail page must see it and not be masked by the optimistic value.
        providerState.value = rebound.copy(models = listOf(target.copy(relayKeyID = "k2", relayDeniedKeyID = "k2")))
        advanceUntilIdle()
        assertEquals("k2", viewModel.provider.value?.models?.single()?.relayDeniedKeyID)
        providerJob.cancel()
    }

    @Test
    fun `single enable on an official provider never probes`() = runTest {
        val target = AIModel(id = "gpt-4.1-mini", name = "GPT-4.1 Mini")
        val providerState = MutableStateFlow(
            sampleProvider(
                models = listOf(AIModel(id = "gpt-4.1", name = "GPT-4.1", isDefault = true)),
                catalogModels = listOf(AIModel(id = "gpt-4.1", name = "GPT-4.1"), target),
            ),
        )
        coEvery { providerRepository.updateProvider(any()) } returns Unit

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.toggleModelEnabled(target)
        advanceUntilIdle()
        coVerify(exactly = 0) { providerRepository.probeEnabledRelayModel(any(), any()) }
        providerJob.cancel()
    }

    @Test
    fun `saveRelaySettings never persists a connection level model id`() = runTest {
        val provider = sampleProvider(
            kind = ProviderKind.Relay,
            models = listOf(AIModel(id = "old-model", name = "Old model", isDefault = true)),
            catalogModels = listOf(AIModel(id = "old-model", name = "Old model", isDefault = true)),
        )
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery {
            providerRepository.verifyAndPersistRelayEdit(any(), null, any(), any(), any())
        } coAnswers {
            ProviderRepository.RelayEditOutcome(
                provider = firstArg(),
                persisted = true,
                verificationSucceeded = true,
                catalogState = ProviderRepository.RelayCatalogRefreshState.Available,
            )
        }

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.saveRelaySettings(
            provider = provider,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIResponses,
                modelID = "new-relay-model",
                codexCompatIdentity = false,
            ),
            baseUrlText = " https://relay.example.com/v1 ",
        )
        advanceUntilIdle()

        coVerify(exactly = 1) {
            providerRepository.verifyAndPersistRelayEdit(
                match { updated ->
                    // relayKind is no longer a user option; it is derived from the default protocol (Responses -> codex_style).
                    updated.relayKind == RelayKind.CodexStyle &&
                        // A relay does not persist a connection-level modelID; the verification sample stays only in the in-memory draft.
                        updated.relayRequested?.modelID == null &&
                        updated.relayRequested?.codexCompatIdentity == false &&
                        updated.models.none { it.id == "new-relay-model" } &&
                        updated.customName == provider.customName &&
                        updated.baseUrlText == "https://relay.example.com/v1"
                },
                null,
                true,
                any(),
                any(),
            )
        }
        providerJob.cancel()
    }

    @Test
    fun `verified relay edit calls onSaved before revision bound catalog refresh completes`() = runTest {
        val provider = sampleProvider(
            kind = ProviderKind.Relay,
            models = listOf(AIModel(id = "model-a", name = "model-a", isDefault = true)),
            catalogModels = listOf(AIModel(id = "model-a", name = "model-a", isDefault = true)),
        ).copy(
            baseUrlText = "https://old.example/v1",
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(
                authMode = RelayAuthMode.None,
                modelID = "model-a",
            ),
        )
        val providerState = MutableStateFlow(provider)
        val revision = ProviderRepository.RelayEditRevision(provider.toEntity("account-test"))
        val catalogGate = CompletableDeferred<Unit>()
        var onSavedCalled = false
        coEvery {
            providerRepository.verifyAndPersistRelayEdit(any(), null, true, any(), any())
        } coAnswers {
            ProviderRepository.RelayEditOutcome(
                provider = firstArg(),
                persisted = true,
                verificationSucceeded = true,
                persistedRevision = revision,
                // Whether the catalog is cleared and whether it is refreshed after saving is decided by the repository at the moment of persisting.
                catalogInvalidated = true,
            )
        }
        coEvery {
            providerRepository.refreshRelayCatalogOnly("provider-1", revision)
        } coAnswers {
            assertTrue(onSavedCalled)
            catalogGate.await()
            ProviderRepository.ProviderResyncOutcome(
                provider = provider.copy(catalogModels = emptyList()),
                catalogSucceeded = true,
            )
        }
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.saveRelaySettings(
            provider = provider,
            relayRequested = provider.relayRequested!!,
            baseUrlText = "https://new.example/v1",
            onSaved = { onSavedCalled = true },
        )
        runCurrent()

        assertTrue(onSavedCalled)
        assertFalse(catalogGate.isCompleted)
        coVerify(exactly = 1) { providerRepository.refreshRelayCatalogOnly("provider-1", revision) }

        catalogGate.complete(Unit)
        advanceUntilIdle()
        providerJob.cancel()
    }

    @Test
    fun `security mode transaction persists only mode T2 endpoint and reconnect evidence`() = runTest {
        val persistedRequested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIResponses,
            authMode = RelayAuthMode.Bearer,
            securityMode = RelayConnectionSecurityMode.RemoteHttps,
            modelID = "saved-model",
            serviceTier = "saved-tier",
            headers = listOf(
                RelayKeyValue("Authorization", "Bearer persisted-secret"),
                RelayKeyValue("X-Trace", "keep-only-without-credentials"),
            ),
            queryParams = listOf(RelayKeyValue("api_key", "persisted-secret")),
            resolvedAPIBaseURL = "https://old.example/v1",
        )
        val provider = sampleProvider(kind = ProviderKind.Relay).copy(
            apiKey = "sk-persisted",
            baseUrlText = "127.0.0.1:8080/v1",
            relayKind = RelayKind.Custom,
            relayRequested = persistedRequested,
        )
        val providerState = MutableStateFlow(provider)
        val pingGate = CompletableDeferred<Unit>()
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.updateApiKey("provider-1", "") } returns Unit
        coEvery { providerRepository.updateProvider(any()) } coAnswers {
            providerState.value = firstArg()
        }
        coEvery { providerRepository.pingRelayConnection(any(), any(), any(), any(), any()) } coAnswers {
            pingGate.await()
        }
        coEvery { providerRepository.resyncProviderForModeTransition("provider-1", any()) } coAnswers {
            providerState.value = providerState.value.copy(status = ProviderConnectionState.Connected, lastError = null)
            ProviderRepository.ProviderResyncOutcome(providerState.value, catalogSucceeded = true)
        }
        coEvery { providerRepository.getById("provider-1") } coAnswers { providerState.value }

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.changeRelaySecurityMode(
            provider = provider,
            mode = RelayConnectionSecurityMode.LocalHttp,
            normalizedEndpoint = "http://127.0.0.1:8080/v1",
        )
        runCurrent()

        val pending = providerState.value
        assertTrue(pending.status is ProviderConnectionState.Issue)
        assertEquals("http://127.0.0.1:8080/v1", pending.baseUrlText)
        assertEquals(RelayConnectionSecurityMode.LocalHttp, pending.relayRequested?.securityMode)
        assertEquals(RelayAuthMode.None, pending.relayRequested?.authMode)
        assertNull(pending.relayRequested?.headers)
        assertNull(pending.relayRequested?.queryParams)
        assertNull(pending.relayRequested?.resolvedAPIBaseURL)
        // The unsaved advanced draft is not among this method's inputs at all; the saved transport / model / tier are kept as they are.
        assertEquals(RelayTransport.OpenAIResponses, pending.relayRequested?.transport)
        assertEquals("saved-model", pending.relayRequested?.modelID)
        assertEquals("saved-tier", pending.relayRequested?.serviceTier)
        // A reconnect in flight is its own state (BOARD-EDIT-09 in-progress style) and does not borrow a test hook.
        assertTrue(viewModel.isReconnectingRelaySecurity)
        assertFalse(viewModel.isTestingRelayConnection)

        pingGate.complete(Unit)
        advanceUntilIdle()

        assertEquals(ProviderConnectionState.Connected, providerState.value.status)
        assertTrue(viewModel.relayConnectionTestResult?.isSuccess == true)
        coVerify(exactly = 1) { providerRepository.updateApiKey("provider-1", "") }
        coVerify(exactly = 1) { providerRepository.resyncProviderForModeTransition("provider-1", any()) }
        providerJob.cancel()
    }

    @Test
    fun `editing relay draft cancels an in flight detail connection test`() = runTest {
        val provider = sampleProvider(kind = ProviderKind.Relay).copy(
            apiKey = "sk-test",
            relayKind = RelayKind.Custom,
            baseUrlText = "https://relay.example/v1",
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                authMode = RelayAuthMode.Bearer,
                modelID = "model-a",
            ),
        )
        val providerState = MutableStateFlow(provider)
        val pingGate = CompletableDeferred<Unit>()
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.verifyRelayGeneration(any(), any(), any(), any(), any()) } coAnswers {
            pingGate.await()
        }
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.testRelayConnection(
            provider = provider,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIResponses,
                authMode = RelayAuthMode.Bearer,
                securityMode = RelayConnectionSecurityMode.RemoteHttps,
            ),
            endpoint = "https://relay.example/v1",
            modelID = "model-a",
        )
        runCurrent()
        assertTrue(viewModel.isTestingRelayConnection)

        viewModel.invalidateRelayConnectionTest()
        pingGate.complete(Unit)
        advanceUntilIdle()

        assertFalse(viewModel.isTestingRelayConnection)
        assertNull(viewModel.relayConnectionTestResult)
        providerJob.cancel()
    }

    @Test
    fun `testing an unsaved relay draft never writes its result to persisted status`() = runTest {
        val provider = sampleProvider(kind = ProviderKind.Relay).copy(
            apiKey = "sk-test",
            relayKind = RelayKind.Custom,
            baseUrlText = "https://relay.example/v1",
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                authMode = RelayAuthMode.Bearer,
                modelID = "saved-model",
            ),
            status = ProviderConnectionState.Issue("previous failure"),
        )
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.verifyRelayGeneration(any(), any(), any(), any(), any()) } returns Unit
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.testRelayConnection(
            provider = provider,
            relayRequested = provider.relayRequested!!.copy(modelID = "draft-model"),
            endpoint = provider.baseUrlText!!,
            modelID = "draft-model",
        )
        advanceUntilIdle()

        coVerify(exactly = 0) { providerRepository.verifyPersistedRelayGeneration(any()) }
        assertTrue(viewModel.relayConnectionTestResult?.isSuccess == true)
        assertTrue(providerState.value.status is ProviderConnectionState.Issue)
        providerJob.cancel()
    }

    @Test
    fun `successful relay test writes generation evidence into persisted status`() = runTest {
        // A persisted connection is identified by its verification sample (the first enabled model) and no longer reads relayRequested.modelID.
        val provider = sampleProvider(kind = ProviderKind.Relay, models = listOf(AIModel(id = "model-a", name = "model-a"))).copy(
            apiKey = "sk-test",
            relayKind = RelayKind.Custom,
            baseUrlText = "https://relay.example/v1",
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                authMode = RelayAuthMode.Bearer,
                modelID = "model-a",
            ),
        )
        val providerState = MutableStateFlow(provider.copy(status = ProviderConnectionState.Issue("stale")))
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.verifyPersistedRelayGeneration("provider-1") } coAnswers {
            providerState.value = providerState.value.copy(
                status = ProviderConnectionState.Connected,
                lastError = null,
            )
            ProviderRepository.RelayGenerationVerificationOutcome(
                provider = providerState.value,
                attemptedProvider = provider,
                verificationSucceeded = true,
            )
        }
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.testRelayConnection(
            provider = providerState.value,
            relayRequested = providerState.value.relayRequested!!,
            endpoint = "https://relay.example/v1",
            modelID = "model-a",
        )
        advanceUntilIdle()

        coVerify(exactly = 0) { providerRepository.verifyRelayGeneration(any(), any(), any(), any(), any()) }
        coVerify(exactly = 1) { providerRepository.verifyPersistedRelayGeneration("provider-1") }
        assertEquals(ProviderConnectionState.Connected, providerState.value.status)
        assertTrue(viewModel.relayConnectionTestResult?.isSuccess == true)
        providerJob.cancel()
    }

    @Test
    fun `codex default identity test writes persisted status`() = runTest {
        // A persisted connection is identified by its verification sample (the first enabled model) and no longer reads relayRequested.modelID.
        val provider = sampleProvider(kind = ProviderKind.Relay, models = listOf(AIModel(id = "model-a", name = "model-a"))).copy(
            apiKey = "sk-test",
            relayKind = RelayKind.CodexStyle,
            baseUrlText = "https://relay.example/v1",
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIResponses,
                authMode = RelayAuthMode.Bearer,
                modelID = "model-a",
                codexCompatIdentity = null,
            ),
            status = ProviderConnectionState.Issue("stale"),
        )
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.verifyPersistedRelayGeneration("provider-1") } returns
            ProviderRepository.RelayGenerationVerificationOutcome(
                provider = provider,
                attemptedProvider = provider,
                verificationSucceeded = true,
            )
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.testRelayConnection(
            provider = providerState.value,
            // The Codex identity is kept as is; the draft is no longer normalized to true.
            relayRequested = providerState.value.relayRequested!!,
            endpoint = "https://relay.example/v1",
            modelID = "model-a",
        )
        advanceUntilIdle()

        coVerify(exactly = 1) { providerRepository.verifyPersistedRelayGeneration("provider-1") }
        assertTrue(viewModel.relayConnectionTestResult?.isSuccess == true)
        providerJob.cancel()
    }

    @Test
    fun `persisted relay test failure renders redacted 4xx evidence including short credentials`() = runTest {
        val apiKey = "k1"
        val headerSecret = "h1"
        val querySecret = "q1"
        val requested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            authMode = RelayAuthMode.Bearer,
            modelID = "model-a",
            headers = listOf(RelayKeyValue("Authorization", "Bearer $headerSecret")),
            queryParams = listOf(RelayKeyValue("api_key", querySecret)),
        )
        val provider = sampleProvider(kind = ProviderKind.Relay).copy(
            apiKey = apiKey,
            relayKind = RelayKind.Custom,
            baseUrlText = "https://relay.example/v1",
            relayRequested = requested,
            models = listOf(AIModel("model-a", "model-a", isDefault = true)),
            catalogModels = listOf(AIModel("model-a", "model-a", isDefault = true)),
        )
        val error = ProviderServiceError.RelayUpstream(
            statusCode = 401,
            guidance = "unauthorized",
            detail = """{"api":"$apiKey","header":"$headerSecret","query":"$querySecret"}""",
        )
        val providerState = MutableStateFlow(provider)
        coEvery { providerRepository.verifyPersistedRelayGeneration("provider-1") } returns
            ProviderRepository.RelayGenerationVerificationOutcome(
                provider = provider.copy(status = ProviderConnectionState.Issue("failed")),
                attemptedProvider = provider,
                verificationSucceeded = false,
                error = error,
            )
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.testRelayConnection(
            provider = provider,
            relayRequested = requested,
            endpoint = provider.baseUrlText!!,
            modelID = "model-a",
        )
        advanceUntilIdle()

        val presentation = requireNotNull(viewModel.relayConnectionTestResult?.failurePresentation)
        assertEquals(401, presentation.statusCode)
        assertEquals(0, presentation.automaticRetryCount)
        assertTrue(presentation.endpoint.startsWith("https://relay.example/v1"))
        val rendered = presentation.endpoint + "\n" + presentation.upstreamJson.orEmpty()
        listOf(apiKey, headerSecret, querySecret).forEach { secret ->
            assertFalse(rendered.contains(secret))
        }
        providerJob.cancel()
    }

    @Test
    fun `invalidated mode transaction cannot persist its initial boundary`() = runTest {
        val provider = sampleProvider(kind = ProviderKind.Relay).copy(
            apiKey = "sk-test",
            baseUrlText = "https://relay.example/v1",
            relayRequested = RelayRequestedConfig(
                authMode = RelayAuthMode.Bearer,
                securityMode = RelayConnectionSecurityMode.RemoteHttps,
            ),
        )
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.changeRelaySecurityMode(
            provider,
            RelayConnectionSecurityMode.LocalHttp,
            "http://127.0.0.1:11434/v1",
        )
        viewModel.invalidateRelayConnectionTest()
        advanceUntilIdle()

        coVerify(exactly = 0) { providerRepository.updateApiKey(any(), any()) }
        coVerify(exactly = 0) { providerRepository.updateProvider(any()) }
        coVerify(exactly = 0) { providerRepository.pingRelayConnection(any(), any(), any(), any(), any()) }
        providerJob.cancel()
    }

    @Test
    fun `cleartext mode preserves non sensitive kv when no credential material exists`() = runTest {
        val provider = sampleProvider(kind = ProviderKind.Relay).copy(
            baseUrlText = "127.0.0.1:8080/v1",
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(
                authMode = RelayAuthMode.None,
                headers = listOf(RelayKeyValue("X-Trace", "trace-value")),
                queryParams = listOf(RelayKeyValue("tenant", "alpha")),
            ),
        )
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.updateProvider(any()) } coAnswers { providerState.value = firstArg() }
        coEvery { providerRepository.pingRelayConnection(any(), any(), any(), any(), any()) } returns Unit
        coEvery { providerRepository.resyncProviderForModeTransition("provider-1", any()) } coAnswers {
            providerState.value = providerState.value.copy(status = ProviderConnectionState.Connected, lastError = null)
            ProviderRepository.ProviderResyncOutcome(providerState.value, catalogSucceeded = true)
        }
        coEvery { providerRepository.getById("provider-1") } coAnswers { providerState.value }
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.changeRelaySecurityMode(
            provider,
            RelayConnectionSecurityMode.LocalHttp,
            "http://127.0.0.1:8080/v1",
        )
        advanceUntilIdle()

        assertEquals(listOf(RelayKeyValue("X-Trace", "trace-value")), providerState.value.relayRequested?.headers)
        assertEquals(listOf(RelayKeyValue("tenant", "alpha")), providerState.value.relayRequested?.queryParams)
        coVerify(exactly = 0) { providerRepository.updateApiKey(any(), any()) }
        providerJob.cancel()
    }

    @Test
    fun `catalog success cannot overwrite a failed mode switch ping`() = runTest {
        val provider = sampleProvider(kind = ProviderKind.Relay).copy(
            baseUrlText = "127.0.0.1:8080/v1",
            relayRequested = RelayRequestedConfig(authMode = RelayAuthMode.None),
        )
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.updateProvider(any()) } coAnswers { providerState.value = firstArg() }
        coEvery { providerRepository.pingRelayConnection(any(), any(), any(), any(), any()) } throws
            IllegalStateException("generation probe failed")
        coEvery { providerRepository.resyncProviderForModeTransition("provider-1", any()) } coAnswers {
            providerState.value = providerState.value.copy(status = ProviderConnectionState.Connected, lastError = null)
            ProviderRepository.ProviderResyncOutcome(providerState.value, catalogSucceeded = true)
        }
        coEvery { providerRepository.getById("provider-1") } coAnswers { providerState.value }
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.changeRelaySecurityMode(
            provider,
            RelayConnectionSecurityMode.LocalHttp,
            "http://127.0.0.1:8080/v1",
        )
        advanceUntilIdle()

        assertTrue(providerState.value.status is ProviderConnectionState.Issue)
        assertFalse(viewModel.relayConnectionTestResult?.isSuccess ?: true)
        coVerify(exactly = 1) { providerRepository.resyncProviderForModeTransition("provider-1", any()) }
        providerJob.cancel()
    }

    @Test
    fun `renameProvider delegates to repository rename path`() = runTest {
        val provider = sampleProvider().copy(customName = "OpenAI")
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.renameProvider(any(), any()) } returns Unit

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.renameProvider(provider, " Work OpenAI ")
        advanceUntilIdle()

        coVerify(exactly = 1) {
            providerRepository.renameProvider(provider, "Work OpenAI")
        }
        providerJob.cancel()
    }

    @Test
    fun `saveRelaySettings does not add the draft sample model to the enabled list`() = runTest {
        // The edit page has no model field: the verification sample in the draft is neither written to the enabled list nor persisted.
        val provider = sampleProvider(
            kind = ProviderKind.Relay,
            models = emptyList(),
            catalogModels = emptyList(),
        )
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery {
            providerRepository.verifyAndPersistRelayEdit(any(), null, any(), any(), any())
        } coAnswers {
            ProviderRepository.RelayEditOutcome(
                provider = firstArg(),
                persisted = true,
                verificationSucceeded = true,
                catalogState = ProviderRepository.RelayCatalogRefreshState.Available,
            )
        }

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.saveRelaySettings(
            provider = provider,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                modelID = "gpt-5.4",
            ),
            baseUrlText = "https://relay.example.com/v1",
        )
        advanceUntilIdle()

        coVerify(exactly = 1) {
            providerRepository.verifyAndPersistRelayEdit(
                match { updated ->
                    updated.models.none { it.id == "gpt-5.4" } && updated.relayRequested?.modelID == null
                },
                null,
                true,
                any(),
                any(),
            )
        }
        providerJob.cancel()
    }

    @Test
    fun `saveApiKey requires non blank trimmed value`() = runTest {
        val providerState = MutableStateFlow(sampleProvider())
        every { providerRepository.observeById("provider-1") } returns providerState

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()
        viewModel.startEditApiKey()
        viewModel.editingApiKey = "   "

        viewModel.saveApiKey()
        advanceUntilIdle()

        assertEquals(R.string.provider_detail_api_key_required, viewModel.apiKeyEditErrorRes)
        assertNull(viewModel.apiKeyEditError)
        assertTrue(viewModel.showApiKeyEditor)
        assertFalse(viewModel.isUpdatingApiKey)
        coVerify(exactly = 0) { providerRepository.updateApiKey(any(), any()) }
        providerJob.cancel()
    }

    @Test
    fun `saveApiKey trims key and closes editor on success`() = runTest {
        val providerState = MutableStateFlow(sampleProvider())
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.updateApiKey("provider-1", "sk-test") } returns Unit

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()
        viewModel.startEditApiKey()
        viewModel.editingApiKey = "  sk-test  "

        viewModel.saveApiKey()
        advanceUntilIdle()

        assertFalse(viewModel.showApiKeyEditor)
        assertFalse(viewModel.isUpdatingApiKey)
        assertNull(viewModel.apiKeyEditError)
        assertNull(viewModel.apiKeyEditErrorRes)
        coVerify(exactly = 1) { providerRepository.updateApiKey("provider-1", "sk-test") }
        providerJob.cancel()
    }

    @Test
    fun `saveApiKey exposes repository error and keeps editor open`() = runTest {
        val providerState = MutableStateFlow(
            relayProvider(authMode = RelayAuthMode.Bearer, apiKey = "sk-old-secret-value"),
        )
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery { providerRepository.updateApiKey("provider-1", "sk-new-secret-value") } throws
            ProviderServiceError.RelayUpstream(
                401,
                "unauthorized",
                """{"echo":"sk-new-secret-value"}""",
            )

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()
        viewModel.startEditApiKey()
        viewModel.editingApiKey = "sk-new-secret-value"

        viewModel.saveApiKey()
        advanceUntilIdle()

        assertTrue(viewModel.showApiKeyEditor)
        assertFalse(viewModel.isUpdatingApiKey)
        assertEquals("unauthorized", viewModel.apiKeyEditError)
        assertNull(viewModel.apiKeyEditErrorRes)
        val presentation = viewModel.relayConnectionTestResult?.failurePresentation
        assertEquals(401, presentation?.statusCode)
        assertFalse(presentation.toString().contains("sk-new-secret-value"))
        providerJob.cancel()
    }

    @Test
    fun `saveEndpoint requires a known endpoint option`() = runTest {
        val provider = sampleProvider().copy(kind = ProviderKind.Qwen)
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.saveEndpoint()
        advanceUntilIdle()

        assertEquals(R.string.provider_detail_endpoint_required, viewModel.endpointEditErrorRes)
        assertNull(viewModel.endpointEditError)
        assertFalse(viewModel.isUpdatingEndpoint)
        coVerify(exactly = 0) { providerRepository.updateBaseUrl(any(), any()) }
        providerJob.cancel()
    }

    @Test
    fun `E2_TRUST_04 opening the endpoint editor on an untrusted stored region and saving keeps the address`() = runTest {
        // minimaxi.com is not delivered: the mainland site is not among the options, but a value the user already saved is still the current value, and saving does not change the address
        MetadataTestFixtures.clear()
        val provider = sampleProvider().copy(kind = ProviderKind.MiniMax, baseUrlText = "api.minimaxi.com/v1")
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()
        viewModel.startEditEndpoint()
        assertEquals("cn", viewModel.selectedEndpointId)

        viewModel.saveEndpoint()
        advanceUntilIdle()

        assertFalse(viewModel.showEndpointEditor)
        assertNull(viewModel.endpointEditErrorRes)
        coVerify(exactly = 0) { providerRepository.updateBaseUrl(any(), any()) }
        assertEquals("api.minimaxi.com/v1", providerState.value.baseUrlText)
        providerJob.cancel()
    }

    @Test
    fun `saveEndpoint persists selected option and closes editor on success`() = runTest {
        val provider = sampleProvider().copy(kind = ProviderKind.Qwen)
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery {
            providerRepository.updateBaseUrl(
                "provider-1",
                "https://dashscope.aliyuncs.com",
            )
        } returns Unit

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()
        viewModel.startEditEndpoint()
        viewModel.selectEndpoint("bj")

        viewModel.saveEndpoint()
        advanceUntilIdle()

        assertFalse(viewModel.showEndpointEditor)
        assertFalse(viewModel.isUpdatingEndpoint)
        assertNull(viewModel.endpointEditError)
        assertNull(viewModel.endpointEditErrorRes)
        coVerify(exactly = 1) {
            providerRepository.updateBaseUrl(
                "provider-1",
                "https://dashscope.aliyuncs.com",
            )
        }
        providerJob.cancel()
    }

    @Test
    fun `saveEndpoint exposes repository error and keeps editor open`() = runTest {
        val provider = sampleProvider().copy(kind = ProviderKind.Qwen)
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState
        coEvery {
            providerRepository.updateBaseUrl(
                "provider-1",
                "https://dashscope.aliyuncs.com",
            )
        } throws IllegalStateException("endpoint rejected")

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()
        viewModel.startEditEndpoint()
        viewModel.selectEndpoint("bj")

        viewModel.saveEndpoint()
        advanceUntilIdle()

        assertTrue(viewModel.showEndpointEditor)
        assertFalse(viewModel.isUpdatingEndpoint)
        assertEquals("endpoint rejected", viewModel.endpointEditError)
        assertNull(viewModel.endpointEditErrorRes)
        providerJob.cancel()
    }

    @Test
    fun `filteredCatalogModels applies current search query to relay catalog`() = runTest {
        // A relay groups by family (family = server family, then heuristic; groupKey is not read), and catalog ids are the original ids without a vendor prefix.
        val provider = sampleProvider(
            models = listOf(
                AIModel(
                    id = "gpt-4.1",
                    name = "GPT-4.1",
                    isDefault = true,
                    groupKey = "openai",
                    groupName = "OpenAI",
                ),
            ),
            catalogModels = listOf(
                AIModel(
                    id = "gpt-4.1",
                    name = "GPT-4.1",
                    groupKey = "openai",
                    groupName = "OpenAI",
                ),
                AIModel(
                    id = "claude-3.7-sonnet",
                    name = "Claude 3.7 Sonnet",
                    groupKey = "anthropic",
                    groupName = "Anthropic",
                ),
                AIModel(
                    id = "claude-3.5-haiku",
                    name = "Claude 3.5 Haiku",
                    groupKey = "anthropic",
                    groupName = "Anthropic",
                ),
            ),
        ).copy(kind = ProviderKind.Relay)
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()
        viewModel.modelSearchQuery = "anthropic"

        val groups = viewModel.filteredCatalogModels()

        assertEquals(1, groups.size)
        assertEquals("anthropic", groups.first().id)
        assertEquals(
            listOf("claude-3.5-haiku", "claude-3.7-sonnet"),
            groups.first().models.map { it.id }.sorted(),
        )
        providerJob.cancel()
    }

    /**
     * First-open jank regression: the whole catalogGroups chain (dedupe + group + sort) runs under
     * `flowOn(defaultDispatcher)`, off Main.
     *
     * The computation is handed to a dispatcher with its own **independent virtual clock**: push Main's
     * clock to the end and the groups still must not be computable (removing flowOn would finish them at
     * that step and turn the assertion red); after the compute-side clock is advanced, the output must match
     * the real output of the production function `buildProviderCatalogGroups` group by group and model by
     * model, so moving the dispatcher never changes the semantics.
     */
    @Test
    fun `catalogGroups computes off the main dispatcher without changing the grouping`() = runTest {
        // A relay groups by family (groupKey is not read), and catalog ids are the original ids without a vendor prefix.
        val offMainScheduler = TestCoroutineScheduler()
        val offMainDispatcher = StandardTestDispatcher(offMainScheduler)
        val provider = sampleProvider(
            models = emptyList(),
            catalogModels = listOf(
                AIModel(
                    id = "claude-sonnet",
                    name = "Claude Sonnet",
                    isAvailable = true,
                    groupKey = "anthropic",
                    groupName = "Anthropic",
                    sortRank = 200,
                ),
                AIModel(
                    id = "gpt-4.1",
                    name = "GPT-4.1",
                    isAvailable = true,
                    groupKey = "openai",
                    groupName = "OpenAI",
                    sortRank = 190,
                ),
                AIModel(
                    id = "claude-haiku",
                    name = "Claude Haiku",
                    isAvailable = true,
                    groupKey = "anthropic",
                    groupName = "Anthropic",
                    sortRank = 120,
                ),
            ),
        ).copy(kind = ProviderKind.Relay)
        val providerState = MutableStateFlow(provider)
        every { providerRepository.observeById("provider-1") } returns providerState

        val viewModel = createViewModel(providerState, defaultDispatcher = offMainDispatcher)
        val groupsJob = backgroundScope.launch(dispatcher) { viewModel.catalogGroups.collect {} }
        advanceUntilIdle()

        assertNull("grouping must not be computed on Main", viewModel.catalogGroups.value)

        // The compute side and Main run on two clocks: upstream subscribes to provider (stateIn on Main), then computes, then publishes back on Main,
        // which takes a few alternating advances to converge.
        repeat(4) {
            offMainScheduler.advanceUntilIdle()
            advanceUntilIdle()
        }

        val actual = viewModel.catalogGroups.value
        assertNotNull(actual)

        val expected = buildProviderCatalogGroups(
            provider = provider,
            resolvedCatalog = ProviderCatalogResolver.resolve(provider),
            searchQuery = "",
        )
        assertEquals(expected.map { it.id }, actual!!.map { it.id })
        assertEquals(expected.map { it.title }, actual.map { it.title })
        assertEquals(
            expected.map { group -> group.models.map { it.id } },
            actual.map { group -> group.models.map { it.id } },
        )

        // The production function itself must really group (a relay groups by family, with group order and in-group order both following the catalog order), or the assertions above would pass falsely together
        assertEquals(listOf("anthropic", "openai"), actual.map { it.id })
        assertEquals(
            listOf("claude-sonnet", "claude-haiku"),
            actual.first().models.map { it.id },
        )
        groupsJob.cancel()
    }

    @Test
    fun `official providers preserve provider management entry capabilities`() = runTest {
        val openAIProvider = sampleProvider().copy(kind = ProviderKind.OpenAI)
        val qwenProvider = sampleProvider().copy(kind = ProviderKind.Qwen)
        val providerState = MutableStateFlow(openAIProvider)
        every { providerRepository.observeById("provider-1") } returns providerState

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        assertTrue(viewModel.canEditApiKey(openAIProvider))
        assertFalse(viewModel.canEditEndpoint(openAIProvider))
        assertTrue(viewModel.canAccessAdvancedSettings(openAIProvider))
        assertTrue(viewModel.canAddManualModel(openAIProvider))
        assertTrue(viewModel.canDeleteProvider(openAIProvider))

        assertTrue(viewModel.canEditApiKey(qwenProvider))
        assertTrue(viewModel.canEditEndpoint(qwenProvider))
        assertTrue(viewModel.canAccessAdvancedSettings(qwenProvider))
        assertTrue(viewModel.canAddManualModel(qwenProvider))
        assertTrue(viewModel.canDeleteProvider(qwenProvider))
        providerJob.cancel()
    }

    @Test
    fun `deleting custom relay clears all provider parameter scopes after repository deletion`() = runTest {
        // RelayKindDefaults is the production config factory; the real detail-page path must clear the local scopes only after the repository succeeds.
        val provider = relayProvider(authMode = RelayAuthMode.Bearer)
        val providerState = MutableStateFlow(provider)
        var settingsPayload: String? = null
        var presetsPayload: String? = null
        val settingsStore = GenerationParameterSettingsStore(
            readPayload = { settingsPayload },
            writePayload = { settingsPayload = it },
        )
        val presetStore = GenerationParameterPresetStore(
            readPayload = { presetsPayload },
            writePayload = { presetsPayload = it },
        )
        val values = GenerationParameterOverrides(
            mapOf("temperature" to GenerationParameterOverride(
                state = GenerationOverrideState.Value,
                value = JsonPrimitive(0.4),
            )),
        )
        settingsStore.setConnectionDefaults(values, provider.id)
        settingsStore.setModelDefaults(values, provider.id, "relay-model")
        settingsStore.setSessionOverrides(values, provider.id, "relay-model", "conversation-1")
        presetStore.save(
            name = "Relay default",
            providerID = provider.id,
            modelID = "relay-model",
            profileFingerprint = "production-relay-profile",
            values = values,
        )
        coEvery { providerRepository.deleteProvider(provider.id) } returns Unit

        val viewModel = createViewModel(
            providerState = providerState,
            generationParameterSettingsStore = settingsStore,
            generationParameterPresetStore = presetStore,
        )
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()
        var deleted = false

        viewModel.deleteProvider { deleted = true }
        advanceUntilIdle()

        assertTrue(deleted)
        coVerify(exactly = 1) { providerRepository.deleteProvider(provider.id) }
        assertNull(settingsStore.connectionDefaults(provider.id))
        assertNull(settingsStore.modelDefaults(provider.id, "relay-model"))
        assertNull(settingsStore.sessionOverrides(provider.id, "relay-model", "conversation-1"))
        assertTrue(
            presetStore.list(
                providerID = provider.id,
                modelID = "relay-model",
                profileFingerprint = "production-relay-profile",
            ).isEmpty(),
        )
        providerJob.cancel()
    }

    // -- Contract tests --

    @Test
    fun `viewmodel construction requires non-null metadata refresh bus and application scope`() = runTest {
        val providerState = MutableStateFlow(sampleProvider())
        every { providerRepository.observeById("provider-1") } returns providerState
        val bus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus()
        val appScope = kotlinx.coroutines.CoroutineScope(
            kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Unconfined
        )

        // Construction should compile and not throw: parameter order and types are checked strictly
        val vm = ProviderDetailViewModel(
            savedStateHandle = SavedStateHandle(mapOf("providerID" to "provider-1")),
            providerRepository = providerRepository,
            appPreferencesRepository = appPreferencesRepository,
            metadataRefreshEventBus = bus,
            applicationScope = appScope,
            globalSnackbarManager = globalSnackbarManager,
        )
        assertNotNull(vm)
    }

    /**
     * The title branches on provider kind: a relay shows the generic models title, official
     * providers show the added models title. Comparing only OpenAI vs Qwen would be a false green
     * (both fall into the else branch), so a Relay case is required.
     */
    @Test
    fun `enabledModelsTitle branches on provider kind to match iOS`() = runTest {
        val providerState = MutableStateFlow(sampleProvider(kind = ProviderKind.OpenAI))
        every { providerRepository.observeById("provider-1") } returns providerState
        val vm = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()

        listOf(ProviderKind.Relay).forEach { kind ->
            assertEquals(
                "$kind should show the generic models title",
                R.string.provider_detail_models_title,
                vm.enabledModelsTitle(sampleProvider(kind = kind)),
            )
        }
        listOf(ProviderKind.OpenAI, ProviderKind.Qwen).forEach { kind ->
            assertEquals(
                "$kind should show the added models title",
                R.string.added_models,
                vm.enabledModelsTitle(sampleProvider(kind = kind)),
            )
        }
        providerJob.cancel()
    }

    @Test
    fun `canAddManualModel closes official write path when pruning flag is enabled`() = runTest {
        ManualRetainedPruner.flagOverrideForTesting = true
        val providerState = MutableStateFlow(sampleProvider().copy(kind = ProviderKind.OpenAI))
        every { providerRepository.observeById("provider-1") } returns providerState
        val vm = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()

        assertFalse(vm.canAddManualModel(providerState.value))
        assertTrue(vm.canAddManualModel(sampleProvider().copy(kind = ProviderKind.Relay)))
        providerJob.cancel()
    }

    @Test
    fun `CatalogViewState enum includes UsingCachedMetadata`() {
        // All four states must be present: Normal / UsingCachedMetadata / Offline / ManualRetainedOnly
        val states = ProviderDetailViewModel.CatalogViewState.entries.map { it.name }.toSet()
        assertTrue(
            "CatalogViewState must expose UsingCachedMetadata state; got $states",
            states.contains("UsingCachedMetadata"),
        )
        assertTrue(states.contains("Normal"))
        assertTrue(states.contains("Offline"))
        assertTrue(states.contains("ManualRetainedOnly"))
    }

    @Test
    fun `catalogViewState re-reads metadata source on every refresh signal`() {
        // After a 304 the catalog content is unchanged and resolvedCatalog de-duplicates, emitting nothing; without following the refresh signal directly it would stay on the CachedOffline frame forever.
        val source = java.io.File(
            "src/main/java/ai/oriveo/community/feature/providers/detail/ProviderDetailViewModel.kt",
        ).readText()
        val block = source.substringAfter("val catalogViewState: StateFlow<CatalogViewState> = combine(")
            .substringBefore(".stateIn(")
        assertTrue(block.contains("metadataRefreshSignal.onStart { emit(Unit) }"))
    }

    // -- catalogViewState same-frame read (combine vs map) --

    @Test
    fun `catalogViewState never reads stale provider across rapid updates`() = runTest {
        // Scenario: when provider switches quickly from Relay to OpenAI, the provider.value that catalogViewState depends on
        // must be read in the same frame as resolvedCatalog, or a Normal judged under Relay would be mismatched with OpenAI's empty catalog -> Offline
        val relayProvider = sampleProvider().copy(
            kind = ProviderKind.Relay,
            models = listOf(AIModel(id = "manual", name = "Manual", isDefault = true)),
            catalogModels = listOf(AIModel(id = "manual", name = "Manual")),
        )
        val openAIProvider = sampleProvider().copy(
            kind = ProviderKind.OpenAI,
            models = emptyList(),
            catalogModels = emptyList(),
        )
        val providerState = MutableStateFlow<Provider>(relayProvider)
        every { providerRepository.observeById("provider-1") } returns providerState

        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        val resolvedJob = backgroundScope.launch(dispatcher) { viewModel.resolvedCatalog.collect {} }
        val stateJob = backgroundScope.launch(dispatcher) { viewModel.catalogViewState.collect {} }
        advanceUntilIdle()

        // Relay starting state
        assertEquals(ProviderDetailViewModel.CatalogViewState.Normal, viewModel.catalogViewState.value)

        // Consecutive switches: Relay -> OpenAI -> Relay, quickly triggering provider + resolvedCatalog updates
        repeat(5) {
            providerState.value = openAIProvider
            providerState.value = relayProvider
        }
        advanceUntilIdle()

        // The final state must follow the latest provider (Relay Normal) and not get stuck at Offline through a cross-frame mismatch
        assertEquals(
            "catalogViewState must converge to provider.value after rapid updates",
            ProviderDetailViewModel.CatalogViewState.Normal,
            viewModel.catalogViewState.value,
        )

        providerJob.cancel()
        resolvedJob.cancel()
        stateJob.cancel()
    }

    @Test
    fun `resolvedCatalog initial subscription resolves provider only once`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "gpt-4.1"),
                    MetadataTestFixtures.ModelSpec(id = "gpt-4.1-mini"),
                ),
            ),
        )
        val providerState = MutableStateFlow(sampleProvider(catalogModels = emptyList()))
        every { providerRepository.observeById("provider-1") } returns providerState

        val viewModel = createViewModel(
            providerState = providerState,
            metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val resolvedJob = backgroundScope.launch(dispatcher) { viewModel.resolvedCatalog.collect {} }
        advanceUntilIdle()

        assertEquals(1, ProviderCatalogResolver.debugResolveCallCount)

        resolvedJob.cancel()
    }

    @Test
    fun `catalogGroups refresh when metadata changes without provider mutation`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "gpt-4.1"),
                    MetadataTestFixtures.ModelSpec(id = "gpt-4.1-mini"),
                ),
            ),
        )
        val providerState = MutableStateFlow(
            sampleProvider(
                models = listOf(AIModel(id = "gpt-4.1", name = "GPT-4.1", isDefault = true)),
                catalogModels = emptyList(),
            ),
        )
        every { providerRepository.observeById("provider-1") } returns providerState
        val bus = MetadataRefreshEventBus(debounceMillis = 0)
        val viewModel = createViewModel(
            providerState = providerState,
            metadataRefreshEventBus = bus,
        )
        val catalogJob = backgroundScope.launch(dispatcher) { viewModel.catalogGroups.collect {} }
        advanceUntilIdle()

        assertEquals(
            listOf("gpt-4.1-mini"),
            viewModel.catalogGroups.value?.flatMap { group -> group.models }?.map { it.id },
        )

        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "gpt-4.1"),
                    MetadataTestFixtures.ModelSpec(id = "gpt-4.1-mini"),
                    MetadataTestFixtures.ModelSpec(id = "o4-mini"),
                ),
            ),
        )
        bus.dispatch(
            MetadataClient.RefreshEvent(
                version = 2,
                contractVersion = 1,
            ),
        )
        advanceUntilIdle()

        assertEquals(
            listOf("gpt-4.1-mini", "o4-mini"),
            viewModel.catalogGroups.value?.flatMap { group -> group.models }?.map { it.id }?.sorted(),
        )

        catalogJob.cancel()
    }

    // -- Credential states S0-S4 / transition guards T1, T3, T4, T5 --
    // The criterion is always requiresCredential = (authMode != none); these cases lock that whether a connection needs a key
    // must no longer be inferred from whether apiKey is empty, which was the root cause of local engines being impossible to edit.

    private fun relayProvider(
        authMode: RelayAuthMode,
        securityMode: RelayConnectionSecurityMode = RelayConnectionSecurityMode.RemoteHttps,
        apiKey: String = "",
    ) = sampleProvider(
        kind = ProviderKind.Relay,
        models = listOf(AIModel(id = "relay-model", name = "Relay model", isDefault = true)),
        catalogModels = listOf(AIModel(id = "relay-model", name = "Relay model", isDefault = true)),
    ).copy(
        apiKey = apiKey,
        apiKeyPreview = SecureKeyStore.maskApiKey(apiKey),
        baseUrlText = "https://relay.example.com/v1",
        relayKind = RelayKind.Custom,
        // A config produced by the production factory, not hand-made in the test: authMode comes out of it
        relayRequested = RelayKindDefaults.makeRequested(
            RelayKind.Custom,
            preserving = RelayRequestedConfig(authMode = authMode, modelID = "relay-model"),
        ).copy(securityMode = securityMode),
    )

    @Test
    fun `T5 auth none relay keeps the key editor out of the way and never demands a key`() = runTest {
        val provider = relayProvider(authMode = RelayAuthMode.None)
        val providerState = MutableStateFlow(provider)
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        assertFalse(viewModel.requiresCredential(provider))
        // S0: no key needed and none stored -> no "enter key" entry, so a re-entry can never be demanded
        assertFalse(viewModel.canEditApiKey(provider))
        // Legacy dirty data (auth=none yet a key is stored) still keeps the entry, or removing the key would have no path
        assertTrue(viewModel.canEditApiKey(provider.copy(apiKey = "sk-legacy-key-value")))

        providerJob.cancel()
    }

    @Test
    fun `relay edit plan uses the production requested config and explicit verification allowlist`() {
        val productionProvider = relayProvider(authMode = RelayAuthMode.Bearer).copy(
            catalogModels = listOf(
                AIModel(id = "relay-model", name = "Relay model", isDefault = true),
                AIModel(id = "catalog-model", name = "Catalog model"),
            ),
        )

        // The edit page has no model field: the model does not take part in grading.
        val modelOnly = RelayEditPlan.classify(
            persisted = productionProvider,
            candidateRequested = productionProvider.relayRequested!!.copy(modelID = "outside-catalog"),
            candidateBaseUrl = productionProvider.baseUrlText,
        )
        assertFalse(modelOnly.requiresVerification)
        assertFalse(modelOnly.refreshCatalog)

        val displayBehaviorOnly = RelayEditPlan.classify(
            persisted = productionProvider,
            candidateRequested = productionProvider.relayRequested!!.copy(serviceTier = "priority"),
            candidateBaseUrl = productionProvider.baseUrlText,
        )
        assertFalse(displayBehaviorOnly.requiresVerification)

        val endpointChange = RelayEditPlan.classify(
            persisted = productionProvider,
            candidateRequested = productionProvider.relayRequested!!,
            candidateBaseUrl = "https://other.example/v1",
        )
        assertTrue(endpointChange.requiresVerification)
        assertTrue(endpointChange.refreshCatalog)

        val transportChange = RelayEditPlan.classify(
            persisted = productionProvider,
            candidateRequested = productionProvider.relayRequested!!.copy(transport = RelayTransport.AnthropicMessages),
            candidateBaseUrl = productionProvider.baseUrlText,
        )
        assertTrue(transportChange.requiresVerification)
    }

    @Test
    fun `catalog failure remains failed after view model recreation even with old catalog`() {
        val persisted = relayProvider(authMode = RelayAuthMode.None).copy(
            status = ProviderConnectionState.Connected,
            lastError = ProviderRepository.RELAY_CATALOG_UNAVAILABLE_MESSAGE,
        )
        val first = createViewModel(MutableStateFlow(persisted))
        val recreated = createViewModel(MutableStateFlow(persisted))

        assertEquals(ProviderDetailViewModel.RelayCatalogUiState.Failed, first.relayCatalogUiState(persisted))
        assertEquals(ProviderDetailViewModel.RelayCatalogUiState.Failed, recreated.relayCatalogUiState(persisted))
    }

    @Test
    fun `T5 blank key is treated as no change when a credential already exists`() = runTest {
        val provider = relayProvider(authMode = RelayAuthMode.Bearer, apiKey = "sk-live-key-value")
        val providerState = MutableStateFlow(provider)
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.startEditApiKey()
        viewModel.editingApiKey = "   "
        viewModel.saveApiKey()
        advanceUntilIdle()

        assertNull(viewModel.apiKeyEditErrorRes)
        assertFalse(viewModel.showApiKeyEditor)

        // And S1 (credential needed and none stored) with an empty value must still report a visible reason, never silently do nothing
        val missing = relayProvider(authMode = RelayAuthMode.Bearer)
        providerState.value = missing
        advanceUntilIdle()
        viewModel.startEditApiKey()
        viewModel.editingApiKey = ""
        viewModel.saveApiKey()
        advanceUntilIdle()

        assertEquals(R.string.provider_detail_api_key_required, viewModel.apiKeyEditErrorRes)
        providerJob.cancel()
    }

    @Test
    fun `T1 saving a key onto a cleartext connection is refused with a routed reason`() = runTest {
        val provider = relayProvider(
            authMode = RelayAuthMode.Bearer,
            securityMode = RelayConnectionSecurityMode.LocalHttp,
        )
        val providerState = MutableStateFlow(provider)
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.startEditApiKey()
        viewModel.editingApiKey = "sk-should-not-be-stored"
        viewModel.saveApiKey()
        advanceUntilIdle()

        assertEquals(R.string.relay_credentials_cleartext_blocked, viewModel.apiKeyEditErrorRes)
        coVerify(exactly = 0) { providerRepository.updateApiKey(any(), any()) }
        providerJob.cancel()
    }

    @Test
    fun `T3 removing the credential does not change the auth mode`() = runTest {
        val provider = relayProvider(authMode = RelayAuthMode.Bearer, apiKey = "sk-live-key-value")
        val providerState = MutableStateFlow(provider)
        coEvery { providerRepository.removeRelayApiKey(any(), any()) } returns
            ProviderRepository.RelayEditOutcome(provider, true, false)
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.startEditApiKey()
        viewModel.removeApiKey()
        advanceUntilIdle()

        coVerify(exactly = 1) { providerRepository.removeRelayApiKey("provider-1", any()) }
        coVerify(exactly = 0) { providerRepository.updateApiKey(any(), any()) }
        // authMode must not be changed to none in passing: that would escalate an accidental deletion into a security-boundary change
        coVerify(exactly = 0) { providerRepository.updateProvider(any()) }
        assertFalse(viewModel.showApiKeyEditor)
        providerJob.cancel()
    }

    @Test
    fun `T4 switching to no auth deletes the stored key in the same round`() = runTest {
        val provider = relayProvider(authMode = RelayAuthMode.Bearer, apiKey = "sk-live-key-value")
        val providerState = MutableStateFlow(provider)
        coEvery {
            providerRepository.verifyAndPersistRelayEdit(any(), null, true, any(), any())
        } coAnswers {
            ProviderRepository.RelayEditOutcome(
                provider = firstArg(),
                persisted = true,
                verificationSucceeded = true,
                catalogState = ProviderRepository.RelayCatalogRefreshState.Available,
            )
        }
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.saveRelaySettings(
            provider = provider,
            relayRequested = provider.relayRequested!!.copy(authMode = RelayAuthMode.None),
            baseUrlText = provider.baseUrlText,
        )
        advanceUntilIdle()

        coVerify(exactly = 0) { providerRepository.updateApiKey(any(), any()) }
        coVerify(exactly = 1) {
            providerRepository.verifyAndPersistRelayEdit(
                match { it.relayRequested?.authMode == RelayAuthMode.None },
                null,
                true,
                any(),
                any(),
            )
        }
        providerJob.cancel()
    }

    @Test
    fun `save time interlock blocks a cleartext connection that still carries a credential`() = runTest {
        val provider = relayProvider(authMode = RelayAuthMode.Bearer, apiKey = "sk-live-key-value")
        val providerState = MutableStateFlow(provider)
        coEvery { providerRepository.updateProvider(any()) } returns Unit
        val viewModel = createViewModel(providerState)
        val providerJob = backgroundScope.launch(dispatcher) { viewModel.provider.collect {} }
        advanceUntilIdle()

        viewModel.saveRelaySettings(
            provider = provider,
            relayRequested = provider.relayRequested!!.copy(
                securityMode = RelayConnectionSecurityMode.LocalHttp,
            ),
            baseUrlText = "http://192.168.1.10:1234/v1",
        )
        advanceUntilIdle()

        // Block at save time; otherwise what gets stored is a zombie connection that saves successfully and is hard-rejected at send time on every request
        coVerify(exactly = 0) { providerRepository.updateProvider(any()) }
        // A rejected save must give a visible reason; a silent return is forbidden
        verify(exactly = 1) {
            globalSnackbarManager.show(
                match { it.message == UiText.Resource(R.string.relay_credentials_cleartext_blocked) },
            )
        }
        providerJob.cancel()
    }

    private fun createViewModel(
        providerState: MutableStateFlow<Provider>,
        metadataRefreshEventBus: MetadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
        generationParameterSettingsStore: GenerationParameterSettingsStore? = null,
        generationParameterPresetStore: GenerationParameterPresetStore? = null,
        defaultDispatcher: CoroutineDispatcher = dispatcher,
        capabilityPreferenceStore: ai.oriveo.community.core.model.CapabilityPreferenceStore? = null,
    ) = ProviderDetailViewModel(
        savedStateHandle = SavedStateHandle(mapOf("providerID" to "provider-1")),
        providerRepository = providerRepository.also {
            every { it.observeById("provider-1") } returns providerState
        },
        appPreferencesRepository = appPreferencesRepository,
        metadataRefreshEventBus = metadataRefreshEventBus,
        applicationScope = kotlinx.coroutines.CoroutineScope(
            kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Unconfined
        ),
        globalSnackbarManager = globalSnackbarManager,
        // catalogGroups is already flowOn(defaultDispatcher); inject this class's TestDispatcher by default so its
        // debounce(120ms) keeps running on runTest's virtual clock and advanceUntilIdle() can reach that chain.
        defaultDispatcher = defaultDispatcher,
        generationParameterSettingsStore = generationParameterSettingsStore,
        generationParameterPresetStore = generationParameterPresetStore,
        capabilityPreferenceStore = capabilityPreferenceStore,
    )

    private fun sampleProvider(
        kind: ProviderKind = ProviderKind.OpenAI,
        models: List<AIModel> = listOf(
            AIModel(id = "gpt-4.1", name = "GPT-4.1", isDefault = true),
            AIModel(id = "gpt-4.1-mini", name = "GPT-4.1 Mini"),
        ),
        catalogModels: List<AIModel> = models,
    ) = Provider(
        id = "provider-1",
        kind = kind,
        status = ProviderConnectionState.Connected,
        models = models,
        catalogModels = catalogModels,
    )

}
