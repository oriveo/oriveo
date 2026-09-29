package ai.oriveo.community.feature.modelpicker

import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * What the user sees after tapping "+" in a model picker. The Home, chat and notes pickers used to
 * carry separate copies of this logic: success showed nothing, and a missing or already-present
 * model returned silently, so the tap looked dead and the list did not change.
 */
class EnableCatalogModelTest {

    private val providerRepository = mockk<ProviderRepository>()
    private val snackbar = mockk<GlobalSnackbarManager>(relaxed = true)

    private fun model(id: String, name: String = id) = AIModel(id = id, name = name, isAvailable = true)

    private fun relay(enabled: List<AIModel>, catalog: List<AIModel>) = Provider(
        id = "relay-1",
        kind = ProviderKind.Relay,
        models = enabled,
        catalogModels = catalog,
    )

    @Test
    fun `adding a catalog model persists it and shows the success toast`() = runTest {
        val provider = relay(
            enabled = listOf(model("gpt-4o-mini")),
            catalog = listOf(model("gpt-4o-mini"), model("gpt-4.1", name = "GPT-4.1")),
        )
        coEvery { providerRepository.getById("relay-1") } returns provider
        coEvery { providerRepository.updateProvider(any()) } returns Unit

        enableCatalogModelWithFeedback(providerRepository, snackbar, "relay-1", "gpt-4.1")

        coVerify(exactly = 1) {
            providerRepository.updateProvider(
                match { it.models.map(AIModel::id) == listOf("gpt-4o-mini", "gpt-4.1") },
            )
        }
        verify(exactly = 1) {
            snackbar.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.snackbar_model_added, listOf("GPT-4.1")),
                    style = GlobalToastStyle.Success,
                ),
            )
        }
    }

    @Test
    fun `a model missing from the catalog shows the failure toast instead of silently returning`() = runTest {
        coEvery { providerRepository.getById("relay-1") } returns relay(
            enabled = listOf(model("gpt-4o-mini")),
            catalog = listOf(model("gpt-4o-mini")),
        )

        enableCatalogModelWithFeedback(providerRepository, snackbar, "relay-1", "does-not-exist")

        coVerify(exactly = 0) { providerRepository.updateProvider(any()) }
        verify(exactly = 1) {
            snackbar.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.snackbar_model_enable_failed),
                    style = GlobalToastStyle.Error,
                ),
            )
        }
    }

    @Test
    fun `a provider that no longer exists shows the failure toast`() = runTest {
        coEvery { providerRepository.getById("gone") } returns null

        enableCatalogModelWithFeedback(providerRepository, snackbar, "gone", "gpt-4.1")

        verify(exactly = 1) {
            snackbar.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.snackbar_model_enable_failed),
                    style = GlobalToastStyle.Error,
                ),
            )
        }
    }

    @Test
    fun `a write failure shows the failure toast`() = runTest {
        coEvery { providerRepository.getById("relay-1") } returns relay(
            enabled = listOf(model("gpt-4o-mini")),
            catalog = listOf(model("gpt-4o-mini"), model("gpt-4.1")),
        )
        coEvery { providerRepository.updateProvider(any()) } throws IllegalStateException("disk full")

        enableCatalogModelWithFeedback(providerRepository, snackbar, "relay-1", "gpt-4.1")

        verify(exactly = 1) {
            snackbar.show(
                GlobalSnackbarMessage(
                    message = UiText.Resource(R.string.snackbar_model_enable_failed),
                    style = GlobalToastStyle.Error,
                ),
            )
        }
    }

    @Test
    fun `a model that already has an equivalent enabled one is idempotent and not reported as a failure`() = runTest {
        // The snapshot suffix points at the same remote model as the enabled gpt-4.1.
        val provider = relay(
            enabled = listOf(model("gpt-4.1")),
            catalog = listOf(model("gpt-4.1"), model("gpt-4.1-2025-04-14")),
        )
        coEvery { providerRepository.getById("relay-1") } returns provider

        val result = enableCatalogModel(providerRepository, "relay-1", "gpt-4.1-2025-04-14")

        assertEquals(EnableCatalogModelResult.AlreadyEnabled, result)
        coVerify(exactly = 0) { providerRepository.updateProvider(any()) }
        verify(exactly = 0) { snackbar.show(any()) }
    }
}
