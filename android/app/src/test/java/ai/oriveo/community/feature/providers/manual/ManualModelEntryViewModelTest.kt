package ai.oriveo.community.feature.providers.manual

import android.content.Context
import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.OriveoErrorSeverity
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.launch
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ManualModelEntryViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val context = mockk<Context>()
    private val providerRepository = mockk<ProviderRepository>()
    private val providerFlow = MutableStateFlow<Provider?>(sampleProvider(kind = ProviderKind.OpenAI))

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)

        every { providerRepository.observeById("provider-1") } returns providerFlow

        every { context.getString(R.string.manual_model_save_failed_title) } returns "Save failed"
        every { context.getString(R.string.manual_model_sync_failed_title) } returns "Sync failed"
        every { context.getString(R.string.manual_model_sync_not_supported_title) } returns "Sync not supported"
        every { context.getString(R.string.manual_model_sync_not_supported_message) } returns "Relay does not support automatic sync."
        every { context.getString(R.string.error_generic_message) } returns "Something went wrong."

        every { context.getString(R.string.error_config) } returns "Localized Config Error"
        every { context.getString(R.string.error_config_message) } returns "Localized config message."
        every { context.getString(R.string.error_invalid_api_key) } returns "Localized Invalid Key"
        every { context.getString(R.string.error_invalid_api_key_message) } returns "Localized invalid key message."
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `saveManualModel ignores blank model id`() = runTest {
        val viewModel = createViewModel()
        viewModel.modelID = "   "

        assertFalse(viewModel.canSave)
        viewModel.saveManualModel()
        advanceUntilIdle()

        assertFalse(viewModel.isSaving)
        assertFalse(viewModel.saveCompleted)
        assertNull(viewModel.error)
        coVerify(exactly = 0) { providerRepository.saveManualModel(any(), any()) }
    }

    @Test
    fun `saveManualModel trims model id and marks saveCompleted`() = runTest {
        coEvery { providerRepository.saveManualModel("provider-1", "gpt-4.1") } returns Unit
        val viewModel = createViewModel()
        viewModel.modelID = "  gpt-4.1  "

        viewModel.saveManualModel()
        advanceUntilIdle()

        assertFalse(viewModel.isSaving)
        assertTrue(viewModel.saveCompleted)
        assertNull(viewModel.error)
        coVerify(exactly = 1) { providerRepository.saveManualModel("provider-1", "gpt-4.1") }
    }

    @Test
    fun `saveManualModel keeps isSaving true while request in flight`() = runTest {
        val gate = CompletableDeferred<Unit>()
        coEvery { providerRepository.saveManualModel("provider-1", "model-a") } coAnswers {
            gate.await()
        }
        val viewModel = createViewModel()
        viewModel.modelID = "model-a"

        viewModel.saveManualModel()
        runCurrent()
        assertTrue(viewModel.isSaving)
        assertFalse(viewModel.canSave)

        gate.complete(Unit)
        advanceUntilIdle()
        assertFalse(viewModel.isSaving)
    }

    @Test
    fun `saveManualModel maps ProviderServiceError to critical OriveoError`() = runTest {
        coEvery {
            providerRepository.saveManualModel("provider-1", "broken-model")
        } throws ProviderServiceError.InvalidAPIKey("bad key")
        val viewModel = createViewModel()
        viewModel.modelID = "broken-model"

        viewModel.saveManualModel()
        advanceUntilIdle()

        assertFalse(viewModel.saveCompleted)
        assertEquals("Localized Invalid Key", viewModel.error?.title)
        assertEquals("Localized invalid key message.", viewModel.error?.message)

        assertEquals("bad key", viewModel.error?.detail)
        assertEquals(OriveoErrorSeverity.Critical, viewModel.error?.severity)
    }

    @Test
    fun `retrySync maps ProviderServiceError to localized critical OriveoError`() = runTest {
        providerFlow.value = sampleProvider(kind = ProviderKind.OpenAI)
        coEvery {
            providerRepository.resyncProvider("provider-1")
        } throws ProviderServiceError.InvalidAPIKey("bad key")
        val viewModel = createViewModel()
        val providerJob = backgroundScope.launch(dispatcher) {
            viewModel.provider.collect {}
        }
        advanceUntilIdle()

        viewModel.retrySync()
        advanceUntilIdle()

        assertFalse(viewModel.isRetrying)
        assertFalse(viewModel.saveCompleted)
        assertEquals("Localized Invalid Key", viewModel.error?.title)
        assertEquals("Localized invalid key message.", viewModel.error?.message)
        assertEquals(OriveoErrorSeverity.Critical, viewModel.error?.severity)
        providerJob.cancel()
    }

    @Test
    fun `retrySync reports warning for providers without automatic sync`() = runTest {
        providerFlow.value = sampleProvider(kind = ProviderKind.Relay)
        val viewModel = createViewModel()
        val providerJob = backgroundScope.launch(dispatcher) {
            viewModel.provider.collect {}
        }
        advanceUntilIdle()

        viewModel.retrySync()

        assertFalse(viewModel.isRetrying)
        assertEquals("Sync not supported", viewModel.error?.title)
        assertEquals("Relay does not support automatic sync.", viewModel.error?.message)
        assertEquals(OriveoErrorSeverity.Warning, viewModel.error?.severity)
        coVerify(exactly = 0) { providerRepository.resyncProvider(any()) }
        providerJob.cancel()
    }

    @Test
    fun `retrySync marks saveCompleted when resync returns models`() = runTest {
        providerFlow.value = sampleProvider(kind = ProviderKind.OpenAI)
        coEvery { providerRepository.resyncProvider("provider-1") } returns Unit
        coEvery { providerRepository.getById("provider-1") } returns sampleProvider(
            kind = ProviderKind.OpenAI,
            models = listOf(AIModel(id = "gpt-4.1", name = "GPT-4.1")),
        )
        val viewModel = createViewModel()
        val providerJob = backgroundScope.launch(dispatcher) {
            viewModel.provider.collect {}
        }
        advanceUntilIdle()

        viewModel.retrySync()
        advanceUntilIdle()

        assertFalse(viewModel.isRetrying)
        assertTrue(viewModel.saveCompleted)
        assertNull(viewModel.error)
        providerJob.cancel()
    }

    private fun createViewModel() = ManualModelEntryViewModel(
        savedStateHandle = SavedStateHandle(mapOf("providerID" to "provider-1")),
        context = context,
        providerRepository = providerRepository,
    )

    private fun sampleProvider(
        kind: ProviderKind,
        models: List<AIModel> = emptyList(),
    ) = Provider(
        id = "provider-1",
        kind = kind,
        models = models,
    )
}
