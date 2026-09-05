package ai.oriveo.community.feature.providers.setup

import android.content.Context
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.OriveoErrorSeverity
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.model.ProviderServiceError
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.runs
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ProviderSetupViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val context = mockk<Context>(relaxed = true)
    private val providerRepository = mockk<ProviderRepository>()
    private val appPreferencesRepository = mockk<AppPreferencesRepository>()
    private val globalSnackbarManager = mockk<GlobalSnackbarManager>()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { context.getString(R.string.retry) } returns "Retry"
        every { context.getString(R.string.error_generic_message) } returns "Something went wrong."
        every { globalSnackbarManager.show(any()) } just runs
        every { providerRepository.observeAll() } returns flowOf(emptyList())
        coEvery { appPreferencesRepository.completeOnboarding() } returns Unit
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun createViewModel(
        catalog: ProviderSetupCatalog = ProviderSetupCatalog.fallback(),
    ) = ProviderSetupViewModel(
        context = context,
        providerRepository = providerRepository,
        appPreferencesRepository = appPreferencesRepository,
        globalSnackbarManager = globalSnackbarManager,
        catalogProvider = { catalog },
    )

    @Test
    fun `submitApiKey trims key and completes setup`() = runTest {
        val provider = Provider(id = "provider-1", kind = ProviderKind.OpenAI)
        coEvery {
            providerRepository.registerProvider(
                kind = ProviderKind.OpenAI,
                apiKey = "sk-live",
                preferredModelID = null,
                baseUrl = "api.openai.com/v1",
                customName = null,
            )
        } returns provider

        val viewModel = createViewModel()
        viewModel.selectKind(ProviderKind.OpenAI)
        viewModel.apiKey = "  sk-live  "

        viewModel.submitApiKey()
        advanceUntilIdle()

        assertEquals(provider, viewModel.registeredProvider)
        coVerify(exactly = 1) {
            providerRepository.registerProvider(
                kind = ProviderKind.OpenAI,
                apiKey = "sk-live",
                preferredModelID = null,
                baseUrl = "api.openai.com/v1",
                customName = null,
            )
        }
        coVerify(exactly = 1) {
            appPreferencesRepository.completeOnboarding()
        }
        verify(exactly = 1) {
            globalSnackbarManager.show(
                match { message ->
                    val uiText = message.message
                    uiText is UiText.Resource && uiText.resId == R.string.snackbar_provider_ready
                },
            )
        }
    }

    @Test
    fun `submitApiKey with INVALID validation still saves provider and shows saved-but-invalid snackbar`() = runTest {
        // When key validation is INVALID, the provider is still saved (an escape hatch),
        // with a red "saved, but the key appears to be invalid..." snackbar.
        val provider = Provider(
            id = "provider-invalid",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Issue(
                ProviderRepository.PROVIDER_INVALID_KEY_MESSAGE,
            ),
            lastError = ProviderRepository.PROVIDER_INVALID_KEY_MESSAGE,
        )
        coEvery {
            providerRepository.registerProvider(
                kind = ProviderKind.OpenAI,
                apiKey = "sk-bad",
                preferredModelID = null,
                baseUrl = "api.openai.com/v1",
                customName = null,
            )
        } returns provider

        val viewModel = createViewModel()
        viewModel.selectKind(ProviderKind.OpenAI)
        viewModel.apiKey = "sk-bad"

        viewModel.submitApiKey()
        advanceUntilIdle()

        // Still saved (the escape hatch) with no blocking error.
        assertEquals(provider, viewModel.registeredProvider)
        assertNull(viewModel.error)
        // Onboarding is still marked complete (registration succeeded; a validation failure doesn't block it).
        coVerify(exactly = 1) {
            appPreferencesRepository.completeOnboarding()
        }
        verify(exactly = 1) {
            globalSnackbarManager.show(
                match { message ->
                    val uiText = message.message
                    uiText is UiText.Resource && uiText.resId == R.string.provider_saved_but_invalid
                },
            )
        }
    }

    @Test
    fun `submitApiKey with UNVERIFIED validation saves provider and shows connection-unverified snackbar`() = runTest {
        // When key validation is UNVERIFIED (status Connected with a soft lastError), a gray
        // "couldn't verify the connection..." snackbar is shown.
        val provider = Provider(
            id = "provider-unverified",
            kind = ProviderKind.OpenAI,
            status = ProviderConnectionState.Connected,
            lastError = ProviderRepository.PROVIDER_UNVERIFIED_MESSAGE,
        )
        coEvery {
            providerRepository.registerProvider(
                kind = ProviderKind.OpenAI,
                apiKey = "sk-maybe",
                preferredModelID = null,
                baseUrl = "api.openai.com/v1",
                customName = null,
            )
        } returns provider

        val viewModel = createViewModel()
        viewModel.selectKind(ProviderKind.OpenAI)
        viewModel.apiKey = "sk-maybe"

        viewModel.submitApiKey()
        advanceUntilIdle()

        assertEquals(provider, viewModel.registeredProvider)
        assertNull(viewModel.error)
        verify(exactly = 1) {
            globalSnackbarManager.show(
                match { message ->
                    val uiText = message.message
                    uiText is UiText.Resource && uiText.resId == R.string.provider_connection_unverified
                },
            )
        }
    }

    @Test
    fun `oriveo free can submit without api key`() = runTest {
        val viewModel = createViewModel()
        viewModel.selectKind(ProviderKind.OpenAI)

        assertEquals(true, viewModel.canSubmit)
    }

    @Test
    fun `selectKind resets stale input and error state`() = runTest {
        coEvery {
            providerRepository.registerProvider(any(), any(), any(), any(), any())
        } throws ProviderServiceError.InvalidAPIKey("invalid")

        val viewModel = createViewModel()
        viewModel.selectKind(ProviderKind.OpenAI)
        viewModel.apiKey = "bad-key"

        viewModel.submitApiKey()
        advanceUntilIdle()

        viewModel.apiKey = "should-reset"
        viewModel.selectKind(ProviderKind.Gemini)

        assertEquals("", viewModel.apiKey)
        assertNull(viewModel.error)
        assertEquals(ProviderKind.Gemini, viewModel.selectedKind)
    }

    @Test
    fun `invalid api key becomes critical error and dismissError clears key`() = runTest {
        // The error card's title/message must come back through ErrorMapper's localization
        // lookup (locale-independent: compare against the getString stub value, not an English
        // keyword)
        every { context.getString(R.string.error_invalid_api_key) } returns "Localized Title"
        every { context.getString(R.string.error_invalid_api_key_message) } returns "Localized Message"
        coEvery {
            providerRepository.registerProvider(any(), any(), any(), any(), any())
        } throws ProviderServiceError.InvalidAPIKey("bad key")

        val viewModel = createViewModel()
        viewModel.selectKind(ProviderKind.OpenAI)
        viewModel.apiKey = "bad-key"

        viewModel.submitApiKey()
        advanceUntilIdle()

        assertEquals("Localized Title", viewModel.error?.title)
        assertEquals("Localized Message", viewModel.error?.message)
        assertEquals(OriveoErrorSeverity.Critical, viewModel.error?.severity)
        assertEquals("Retry", viewModel.error?.actionTitle)

        viewModel.dismissError(clearApiKey = true)

        assertNull(viewModel.error)
        assertEquals("", viewModel.apiKey)
    }

    @Test
    fun `dismissError preserves api key by default`() = runTest {
        coEvery {
            providerRepository.registerProvider(any(), any(), any(), any(), any())
        } throws ProviderServiceError.InvalidAPIKey("bad key")

        val viewModel = createViewModel()
        viewModel.selectKind(ProviderKind.OpenAI)
        viewModel.apiKey = "bad-key"

        viewModel.submitApiKey()
        advanceUntilIdle()

        viewModel.dismissError()

        assertNull(viewModel.error)
        assertEquals("bad-key", viewModel.apiKey)
    }

    @Test
    fun `submitApiKey passes selected MiniMax endpoint baseUrl to repository`() = runTest {
        val provider = Provider(id = "provider-2", kind = ProviderKind.MiniMax)
        coEvery {
            providerRepository.registerProvider(
                kind = ProviderKind.MiniMax,
                apiKey = "sk-api-live",
                preferredModelID = null,
                baseUrl = "https://api.minimaxi.com/v1",
                customName = null,
            )
        } returns provider

        val viewModel = createViewModel()
        viewModel.selectKind(ProviderKind.MiniMax)
        val chinaEndpoint = viewModel.regionOptions.lastOrNull()
        assertNotNull(chinaEndpoint)
        viewModel.selectRegion(chinaEndpoint!!)
        viewModel.apiKey = "sk-api-live"

        viewModel.submitApiKey()
        advanceUntilIdle()

        coVerify(exactly = 1) {
            providerRepository.registerProvider(
                kind = ProviderKind.MiniMax,
                apiKey = "sk-api-live",
                preferredModelID = null,
                baseUrl = "https://api.minimaxi.com/v1",
                customName = null,
            )
        }
    }

    @Test
    fun `submitApiKey uses setup catalog default endpoint when no region is selected`() = runTest {
        val provider = Provider(id = "provider-3", kind = ProviderKind.OpenAI)
        coEvery {
            providerRepository.registerProvider(
                kind = ProviderKind.OpenAI,
                apiKey = "sk-live",
                preferredModelID = null,
                baseUrl = "https://metadata-openai.example/v1",
                customName = null,
            )
        } returns provider

        val catalog = ProviderSetupCatalog(
            directProviders = listOf(ProviderKind.OpenAI),
            aggregatorProviders = emptyList(),
            defaultsByKind = mapOf(
                ProviderKind.OpenAI to ProviderSetupDefaults(
                    displayName = "OpenAI",
                    shortName = "OpenAI",
                    apiKeyPlaceholder = "sk-meta",
                    defaultBaseUrl = "https://metadata-openai.example/v1",
                    autoFillNote = null,
                ),
            ),
            regionsByKind = mapOf(ProviderKind.OpenAI to emptyList()),
        )

        val viewModel = createViewModel(catalog)
        viewModel.selectKind(ProviderKind.OpenAI)
        viewModel.apiKey = "sk-live"

        viewModel.submitApiKey()
        advanceUntilIdle()

        coVerify(exactly = 1) {
            providerRepository.registerProvider(
                kind = ProviderKind.OpenAI,
                apiKey = "sk-live",
                preferredModelID = null,
                baseUrl = "https://metadata-openai.example/v1",
                customName = null,
            )
        }
    }

    // -- submit result tracking regression tests --
    // Background: the success path used to report only provider_kind+success, and the failure
    // path only added one more error_code, so "tapped add and it failed" couldn't be traced back
    // to an endpoint, entry point, or attempt count. Now all three branches (success, failure,
    // and local validation rejection) must emit the same set of diagnostic fields.

    @Test
    fun `when the subscription config is not delivered no choice appears and it still uses the api key flow`() = runTest {
        MetadataTestFixtures.applyRaw("""{"version":1,"providers":{},"providerConfigs":[]}""")
        val viewModel = createViewModel()
        viewModel.selectKind(ProviderKind.Grok)

        assertNull(viewModel.grokSubscriptionConfig)
        assertEquals(false, viewModel.usesGrokSubscriptionFlow)

        MetadataTestFixtures.clear()
    }

    @Test
    fun `when delivered selecting subscription disables the bottom continue button and completion happens on the auth page`() = runTest {
        MetadataTestFixtures.applyRaw(SUBSCRIPTION_METADATA)
        val viewModel = createViewModel()
        viewModel.selectKind(ProviderKind.Grok)

        assertNotNull(viewModel.grokSubscriptionConfig)
        // The default is still API Key: the subscription is opt-in and doesn't change the
        // existing default path.
        assertEquals(ProviderAuthMode.ApiKey, viewModel.grokAuthMode)
        assertEquals(false, viewModel.usesGrokSubscriptionFlow)

        viewModel.grokAuthMode = ProviderAuthMode.Subscription
        assertEquals(true, viewModel.usesGrokSubscriptionFlow)
        // In subscription mode the bottom "Continue" button never lights up; leaving it active
        // would just make people think it's stuck.
        assertEquals(false, viewModel.canSubmit)

        MetadataTestFixtures.clear()
    }

    /** Switching providers must reset the connection method back to the default, or the next provider's bottom button would mysteriously disappear. */
    @Test
    fun `switching to another provider reverts the connection method to api key`() = runTest {
        MetadataTestFixtures.applyRaw(SUBSCRIPTION_METADATA)
        val viewModel = createViewModel()
        viewModel.selectKind(ProviderKind.Grok)
        viewModel.grokAuthMode = ProviderAuthMode.Subscription

        viewModel.selectKind(ProviderKind.OpenAI)

        assertEquals(ProviderAuthMode.ApiKey, viewModel.grokAuthMode)
        assertEquals(false, viewModel.usesGrokSubscriptionFlow)

        MetadataTestFixtures.clear()
    }

    private companion object {
        val SUBSCRIPTION_METADATA = """
        {
          "version": 1,
          "providers": {},
          "providerConfigs": [
            {
              "kind": "grok",
              "displayName": "Grok",
              "defaultBaseURL": "https://api.x.ai/v1",
              "protocolFeatures": {
                "subscriptionAuth": {
                  "enabled": true,
                  "flow": "oauth_device_code",
                  "clientId": "b1a00492-073a-47ea-816f-4c329264a828",
                  "scopes": "openid profile email",
                  "deviceAuthorizationEndpoint": "https://auth.x.ai/oauth2/device/code",
                  "tokenEndpoint": "https://auth.x.ai/oauth2/token",
                  "trustedAuthHosts": ["auth.x.ai"],
                  "trustedVerificationHosts": ["accounts.x.ai"],
                  "resourceBaseURL": "https://cli-chat-proxy.grok.com/v1"
                }
              }
            }
          ]
        }
        """.trimIndent()
    }
}
