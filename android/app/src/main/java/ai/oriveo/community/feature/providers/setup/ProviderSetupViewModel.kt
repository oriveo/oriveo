package ai.oriveo.community.feature.providers.setup

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.model.OriveoError
import ai.oriveo.community.core.model.OriveoErrorSeverity
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.grok.GrokSubscriptionAuthConfig
import ai.oriveo.community.core.provider.grok.GrokSubscriptionAvailability
import ai.oriveo.community.core.provider.grok.GrokSubscriptionTokens
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionAuthConfig
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionAvailability
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionTokens
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RegionOption
import ai.oriveo.community.core.provider.ProviderKeyInput
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class ProviderSetupViewModel(
    private val context: Context,
    private val providerRepository: ProviderRepository,
    private val appPreferencesRepository: AppPreferencesRepository,
    private val globalSnackbarManager: GlobalSnackbarManager,
    private val catalogProvider: () -> ProviderSetupCatalog = ProviderSetupCatalogResolver::current,
) : ViewModel() {
    val setupCatalog: ProviderSetupCatalog
        get() = catalogProvider()

    var selectedKind: ProviderKind? by mutableStateOf(null)
        private set

    var apiKey: String by mutableStateOf("")

    var isLoading: Boolean by mutableStateOf(false)
        private set

    var error: OriveoError? by mutableStateOf(null)
        private set

    val regionOptions: List<RegionOption>
        get() = selectedKind?.let { setupCatalog.regionOptions(it) } ?: emptyList()

    var selectedRegion: RegionOption? by mutableStateOf(null)
        private set

    var isAdditionalInstance: Boolean by mutableStateOf(false)

    var grokAuthMode: ProviderAuthMode by mutableStateOf(ProviderAuthMode.ApiKey)

    val grokSubscriptionConfig: GrokSubscriptionAuthConfig?
        get() = (MetadataClient.grokSubscriptionAvailability() as? GrokSubscriptionAvailability.Available)
            ?.config

    val usesGrokSubscriptionFlow: Boolean
        get() = selectedKind == ProviderKind.Grok &&
            grokAuthMode == ProviderAuthMode.Subscription &&
            grokSubscriptionConfig != null

    var openAIAuthMode: ProviderAuthMode by mutableStateOf(ProviderAuthMode.ApiKey)

    val openAISubscriptionConfig: OpenAISubscriptionAuthConfig?
        get() = (MetadataClient.openAISubscriptionAvailability() as? OpenAISubscriptionAvailability.Available)
            ?.config

    val usesOpenAISubscriptionFlow: Boolean
        get() = selectedKind == ProviderKind.OpenAI &&
            openAIAuthMode == ProviderAuthMode.Subscription &&
            openAISubscriptionConfig != null

    var showGrokSubscriptionSheet: Boolean by mutableStateOf(false)

    var showOpenAISubscriptionSheet: Boolean by mutableStateOf(false)

    val usesSubscriptionFlow: Boolean
        get() = usesGrokSubscriptionFlow || usesOpenAISubscriptionFlow

    var registeredProvider: Provider? by mutableStateOf(null)
        private set

    val connectedProviders: StateFlow<Map<ProviderKind, String>> = providerRepository.observeAll()
        .map { providers ->
            providers
                .filter { it.kind != ProviderKind.Relay }

                .groupBy { it.kind }
                .mapValues { (_, group) -> group.first().id }
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000L), emptyMap())

    fun selectKind(kind: ProviderKind) {
        selectedKind = kind
        apiKey = ""
        selectedRegion = setupCatalog.regionOptions(kind).firstOrNull()

        isAdditionalInstance = false

        grokAuthMode = ProviderAuthMode.ApiKey
        openAIAuthMode = ProviderAuthMode.ApiKey
        clearError()
    }

    fun selectKindPreservingInput(kind: ProviderKind?) {
        val previousKind = selectedKind
        selectedKind = kind
        if (previousKind != kind) {
            selectedRegion = kind?.let { setupCatalog.regionOptions(it).firstOrNull() }

            isAdditionalInstance = false
            grokAuthMode = ProviderAuthMode.ApiKey
            openAIAuthMode = ProviderAuthMode.ApiKey
        }
        clearError()
    }

    fun selectRegion(region: RegionOption) {
        selectedRegion = region
    }

    fun updateApiKey(value: String, allowAutoDetect: Boolean) {
        apiKey = value
        if (allowAutoDetect) {
            val inferredKind = ProviderKind.inferredFromApiKey(value)
            if (selectedKind != inferredKind) {
                selectedRegion = inferredKind?.let { setupCatalog.regionOptions(it).firstOrNull() }

                isAdditionalInstance = false

                grokAuthMode = ProviderAuthMode.ApiKey
                openAIAuthMode = ProviderAuthMode.ApiKey
            }
            selectedKind = inferredKind
        }
        clearError()
    }

    val canSubmit: Boolean
        get() {
            val kind = selectedKind ?: return false

            if (usesSubscriptionFlow) return false
            val hasRequiredApiKey = if (kind == ProviderKind.OpenAI) {
                true
            } else {
                apiKey.trim().isNotEmpty()
            }
            return hasRequiredApiKey && !isLoading
        }

    fun submitApiKey() {
        val kind = selectedKind ?: return
        val trimmedKey = apiKey.trim()
        if (trimmedKey.isEmpty()) return

        if (!ProviderKeyInput.isPrintableAsciiKey(trimmedKey)) {
            error = OriveoError(
                title = context.getString(R.string.provider_api_key_illegal_chars_title),
                message = context.getString(R.string.provider_api_key_illegal_chars),
                detail = "",
                severity = OriveoErrorSeverity.Warning,
            )

            return
        }

        viewModelScope.launch {
            isLoading = true
            clearError()

            val baseUrl = selectedRegion?.baseURL ?: setupCatalog.defaultBaseUrl(kind)

            try {
                val provider = providerRepository.registerProvider(
                    kind = kind,
                    apiKey = trimmedKey,
                    baseUrl = baseUrl,
                    isAdditionalInstance = isAdditionalInstance,
                )
                registeredProvider = provider

                val isIssue = provider.status is ProviderConnectionState.Issue

                appPreferencesRepository.completeOnboarding()

                val softError = provider.lastError?.trim()?.takeIf { it.isNotEmpty() }
                val snackbarText: UiText = when {
                    isIssue -> UiText.Resource(R.string.provider_saved_but_invalid)
                    softError == ProviderRepository.PROVIDER_UNVERIFIED_MESSAGE ->
                        UiText.Resource(R.string.provider_connection_unverified)
                    else -> UiText.Resource(R.string.snackbar_provider_ready)
                }
                globalSnackbarManager.show(GlobalSnackbarMessage(message = snackbarText))
            } catch (e: ProviderServiceError) {
                error = mapProviderError(e)
            } catch (e: Exception) {
                error = mapProviderError(
                    ProviderServiceError.Network(
                        detail = e.localizedMessage ?: context.getString(R.string.error_generic_message),
                    ),
                )
            } finally {
                isLoading = false
            }
        }
    }

    fun completeGrokSubscriptionSetup(tokens: GrokSubscriptionTokens) {
        viewModelScope.launch {
            isLoading = true
            clearError()
            try {
                val provider = providerRepository.registerProvider(
                    kind = ProviderKind.Grok,
                    apiKey = tokens.accessToken,
                    baseUrl = setupCatalog.defaultBaseUrl(ProviderKind.Grok),
                    isAdditionalInstance = isAdditionalInstance,
                    authMode = ProviderAuthMode.Subscription,
                    subscriptionTokens = tokens,
                )
                registeredProvider = provider
                appPreferencesRepository.completeOnboarding()

                val snackbarText: UiText =
                    if (provider.lastError == ProviderRepository.SUBSCRIPTION_CATALOG_UNAVAILABLE_MESSAGE) {
                        UiText.Resource(R.string.provider_catalog_unavailable)
                    } else {
                        UiText.Resource(R.string.snackbar_provider_ready)
                    }
                globalSnackbarManager.show(GlobalSnackbarMessage(message = snackbarText))
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: ProviderServiceError) {
                error = mapProviderError(e)
            } catch (e: Exception) {
                error = mapProviderError(
                    ProviderServiceError.Network(
                        detail = e.localizedMessage ?: context.getString(R.string.error_generic_message),
                    ),
                )
            } finally {
                isLoading = false
            }
        }
    }

    fun completeOpenAISubscriptionSetup(tokens: OpenAISubscriptionTokens) {
        viewModelScope.launch {
            isLoading = true
            clearError()
            try {
                val provider = providerRepository.registerProvider(
                    kind = ProviderKind.OpenAI,
                    apiKey = tokens.accessToken,
                    baseUrl = setupCatalog.defaultBaseUrl(ProviderKind.OpenAI),
                    isAdditionalInstance = isAdditionalInstance,
                    authMode = ProviderAuthMode.Subscription,
                    openAISubscriptionTokens = tokens,
                )
                registeredProvider = provider
                appPreferencesRepository.completeOnboarding()

                val snackbarText: UiText =
                    if (provider.lastError == ProviderRepository.CODEX_CATALOG_UNAVAILABLE_MESSAGE) {
                        UiText.Resource(R.string.openai_subscription_catalog_unavailable)
                    } else {
                        UiText.Resource(R.string.snackbar_provider_ready)
                    }
                globalSnackbarManager.show(GlobalSnackbarMessage(message = snackbarText))
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: ProviderServiceError) {
                error = mapProviderError(e)
            } catch (e: Exception) {
                error = mapProviderError(
                    ProviderServiceError.Network(
                        detail = e.localizedMessage ?: context.getString(R.string.error_generic_message),
                    ),
                )
            } finally {
                isLoading = false
            }
        }
    }

    fun dismissError(clearApiKey: Boolean = false) {
        if (clearApiKey) {
            apiKey = ""
        }
        clearError()
    }

    private fun mapProviderError(error: ProviderServiceError): OriveoError = OriveoError(

        title = ErrorMapper.localizeProviderErrorTitle(error.title, context),
        message = ErrorMapper.localizeProviderErrorMessage(error, context),
        actionTitle = context.getString(R.string.retry),
        detail = error.technicalDetail,
        severity = if (error is ProviderServiceError.InvalidAPIKey) {
            OriveoErrorSeverity.Critical
        } else {
            OriveoErrorSeverity.Warning
        },
    )

    private fun clearError() {
        error = null
    }

}
