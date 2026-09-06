package ai.oriveo.community.feature.providers

import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import ai.oriveo.community.core.usage.MonthlyCostSummary
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
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
class ProvidersViewModelBehaviorTest {

    private val dispatcher = StandardTestDispatcher()
    private val providerRepository = mockk<ProviderRepository>()
    private val conversationRepository = mockk<ConversationRepository>()
    private val monthlyCostSummaryFlow = MutableStateFlow(MonthlyCostSummary())
    private val metadataRefreshEventBus = MetadataRefreshEventBus()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { providerRepository.observeAll() } returns flowOf(emptyList())
        every { conversationRepository.observeCount() } returns flowOf(0)
        every { conversationRepository.observeMonthlyCostByConversationProvider() } returns flowOf(emptyMap())
        every { conversationRepository.observeMonthlyCostSummary() } returns monthlyCostSummaryFlow
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        MetadataTestFixtures.clear()
    }

    @Test
    fun `providers screen refresh pipeline uses lightweight conversation count flow`() = runTest {
        val viewModel = ProvidersViewModel(
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            metadataRefreshEventBus = metadataRefreshEventBus,
            defaultDispatcher = dispatcher,
        )

        val collectionJob = backgroundScope.launch {
            viewModel.monthlyCostSummary.collect()
        }
        advanceUntilIdle()

        verify(exactly = 0) { conversationRepository.observeAll() }

        collectionJob.cancel()
    }

    @Test
    fun `availableModelCounts resolves official providers off the UI path`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "gpt-4o"),
                    MetadataTestFixtures.ModelSpec(id = "gpt-4.1"),
                    MetadataTestFixtures.ModelSpec(id = "o4-mini"),
                ),
            ),
        )
        every { providerRepository.observeAll() } returns flowOf(
            listOf(
                Provider(
                    id = "provider-1",
                    kind = ProviderKind.OpenAI,
                    status = ProviderConnectionState.Connected,
                    models = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)),
                ),
                Provider(
                    id = "provider-2",
                    kind = ProviderKind.Relay,
                    status = ProviderConnectionState.Connected,
                    models = listOf(AIModel(id = "custom-1", name = "Custom-1", isDefault = true)),
                    catalogModels = listOf(
                        AIModel(id = "custom-1", name = "Custom-1", isAvailable = true),
                        AIModel(id = "custom-2", name = "Custom-2", isAvailable = true),
                    ),
                ),
            ),
        )

        val viewModel = ProvidersViewModel(
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            metadataRefreshEventBus = metadataRefreshEventBus,
            defaultDispatcher = dispatcher,
        )
        val collectionJob = backgroundScope.launch {
            viewModel.availableModelCounts.collect()
        }
        advanceUntilIdle()

        assertEquals(3, viewModel.availableModelCounts.value["provider-1"])
        assertEquals(2, viewModel.availableModelCounts.value["provider-2"])

        collectionJob.cancel()
    }

    @Test
    fun `availableModelCounts initial subscription resolves official provider only once`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "gpt-4o"),
                    MetadataTestFixtures.ModelSpec(id = "gpt-4.1"),
                ),
            ),
        )
        every { providerRepository.observeAll() } returns flowOf(
            listOf(
                Provider(
                    id = "provider-1",
                    kind = ProviderKind.OpenAI,
                    status = ProviderConnectionState.Connected,
                    models = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)),
                ),
            ),
        )

        val viewModel = ProvidersViewModel(
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
            defaultDispatcher = dispatcher,
        )

        ProviderCatalogResolver.debugResolveCallCount = 0
        val collectionJob = backgroundScope.launch {
            viewModel.availableModelCounts.collect()
        }
        advanceUntilIdle()

        assertEquals(1, ProviderCatalogResolver.debugResolveCallCount)

        collectionJob.cancel()
    }

}
