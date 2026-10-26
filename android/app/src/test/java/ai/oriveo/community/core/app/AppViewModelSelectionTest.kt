package ai.oriveo.community.core.app

import ai.oriveo.community.core.data.database.DatabaseHealthProbe
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.repository.SkillRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AppViewModelSelectionTest {

    private val dispatcher = StandardTestDispatcher()
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val providerRepository = mockk<ProviderRepository>()
    private val skillRepository = mockk<SkillRepository>()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { appPreferencesRepository.hasCompletedOnboarding } returns MutableStateFlow(true)
        // initialOnboardingCompleted is read synchronously as the initial value of the hasCompletedOnboarding StateFlow
        every { appPreferencesRepository.initialOnboardingCompleted } returns true
        every { appPreferencesRepository.theme } returns MutableStateFlow(ThemeOption.System)
        every { appPreferencesRepository.language } returns MutableStateFlow(LanguageOption.System)
        every { appPreferencesRepository.lastUsedModelRef } returns MutableStateFlow(null)
        every { appPreferencesRepository.primeLastUsedModel(any(), any()) } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<AIModel>(), any()) } returns Unit
        coEvery { appPreferencesRepository.setLastUsedModel(any<String>(), any<String>()) } returns Unit
        coEvery { appPreferencesRepository.clearLastUsedModel() } returns Unit

        coEvery { skillRepository.refreshAll() } returns Unit
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        Dispatchers.resetMain()
    }

    @Test
    fun `setActiveModel stores matched snapshot model without catalog projection`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                resolveMap = mapOf(
                    "gpt-5.4" to "gpt-5.4",
                    "gpt-5.4-2026-03-05" to "gpt-5.4",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(
                        id = "gpt-5.4",
                        canonicalModelId = "gpt-5.4",
                        displayName = "GPT-5.4",
                    ),
                ),
            ),
        )
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "gpt-5.4-2026-03-05",
                    name = "GPT-5.4",
                    canonicalModelId = "gpt-5.4",
                ),
            ),
        )
        every { providerRepository.observeAll() } returns flowOf(listOf(provider))

        val viewModel = newViewModel()
        advanceUntilIdle()

        ProviderCatalogResolver.debugResolveCallCount = 0
        viewModel.setActiveModel("provider-1", "gpt-5.4")
        advanceUntilIdle()

        coVerify {
            appPreferencesRepository.setLastUsedModel(
                "provider-1",
                match<AIModel> {
                    it.id == "gpt-5.4-2026-03-05" && it.canonicalModelId == "gpt-5.4"
                },
                any(),
            )
        }
        assertEquals(0, ProviderCatalogResolver.debugResolveCallCount)
    }

    /**
     * The provider detail "Chat" button goes through AppViewModel.setActiveModel (OriveoNavHost), which must
     * prime the override synchronously just like HomeViewModel: writing only to Room would let the
     * `override ?: stored` read in lastUsedModelRef keep an earlier in-process pick stuck, and a new chat would
     * show the old model forever.
     */
    @Test
    fun `setActiveModel primes override synchronously so provider detail chat wins over sticky selection`() = runTest {
        val provider = Provider(
            id = "provider-1",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-5.4", name = "GPT-5.4", canonicalModelId = "gpt-5.4")),
        )
        every { providerRepository.observeAll() } returns flowOf(listOf(provider))

        val viewModel = newViewModel()
        advanceUntilIdle()

        viewModel.setActiveModel("provider-1", "gpt-5.4")
        // No advance: the override must take effect in the same frame as the navigation, not wait for the coroutine
        verify { appPreferencesRepository.primeLastUsedModel("provider-1", "gpt-5.4") }
    }

    private fun newViewModel() = AppViewModel(
        appPreferencesRepository = appPreferencesRepository,
        providerRepository = providerRepository,
        globalSnackbarManager = GlobalSnackbarManager(),
        skillRepository = skillRepository,
        databaseHealthProbe = healthyDatabaseProbe(),
    )
}

/** The database always counts as healthy here: these tests are about model selection, not storage degradation. */
private fun healthyDatabaseProbe() = DatabaseHealthProbe(
    openAndQuery = {},
    usableSpaceBytes = { Long.MAX_VALUE },
)
