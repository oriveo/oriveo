package ai.oriveo.community.feature.providers.manual

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.model.OriveoError
import ai.oriveo.community.core.model.OriveoErrorSeverity
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch


class ManualModelEntryViewModel(
    savedStateHandle: SavedStateHandle,
    private val context: Context,
    private val providerRepository: ProviderRepository,
) : ViewModel() {

    private val providerID: String = savedStateHandle["providerID"] ?: ""

    val provider: StateFlow<Provider?> = providerRepository.observeById(providerID)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    var modelID: String by mutableStateOf("")

    var isSaving: Boolean by mutableStateOf(false)
        private set

    var isRetrying: Boolean by mutableStateOf(false)
        private set

    var error: OriveoError? by mutableStateOf(null)
        private set

    var saveCompleted: Boolean by mutableStateOf(false)
        private set

    val canSave: Boolean
        get() = modelID.trim().isNotEmpty() &&
            !isSaving &&
            provider.value?.kind != ProviderKind.OpenAI

    fun saveManualModel() {
        val trimmed = modelID.trim()
        if (trimmed.isEmpty()) return
        if (provider.value?.kind == ProviderKind.OpenAI) {
            val blockedError = ProviderServiceError.InvalidConfiguration(
                detail = "This provider does not support saving a manual model.",
            )
            error = localizedProviderError(blockedError, OriveoErrorSeverity.Warning)
            return
        }

        viewModelScope.launch {
            isSaving = true
            error = null
            try {
                providerRepository.saveManualModel(providerID, trimmed)
                saveCompleted = true
            } catch (e: ProviderServiceError) {
                error = localizedProviderError(e, OriveoErrorSeverity.Critical)
            } catch (e: Exception) {
                error = OriveoError(
                    title = context.getString(R.string.manual_model_save_failed_title),
                    message = e.message ?: context.getString(R.string.error_generic_message),
                    severity = OriveoErrorSeverity.Critical,
                )
            } finally {
                isSaving = false
            }
        }
    }

    fun retrySync() {
        val p = provider.value ?: return
        if (!p.kind.supportsAutomaticSync) {
            error = OriveoError(
                title = context.getString(R.string.manual_model_sync_not_supported_title),
                message = context.getString(R.string.manual_model_sync_not_supported_message),
                severity = OriveoErrorSeverity.Warning,
            )
            return
        }

        viewModelScope.launch {
            isRetrying = true
            error = null
            try {
                providerRepository.resyncProvider(providerID)
                
                val updated = providerRepository.getById(providerID)
                if (updated != null && updated.models.isNotEmpty()) {
                    saveCompleted = true
                }
            } catch (e: ProviderServiceError) {
                error = localizedProviderError(e, OriveoErrorSeverity.Critical)
            } catch (e: Exception) {
                error = OriveoError(
                    title = context.getString(R.string.manual_model_sync_failed_title),
                    message = e.message ?: context.getString(R.string.error_generic_message),
                    severity = OriveoErrorSeverity.Critical,
                )
            } finally {
                isRetrying = false
            }
        }
    }

    
    private fun localizedProviderError(
        error: ProviderServiceError,
        severity: OriveoErrorSeverity,
    ): OriveoError = OriveoError(
        title = ErrorMapper.localizeProviderErrorTitle(error.title, context),
        message = ErrorMapper.localizeProviderErrorMessage(error, context),
        detail = error.technicalDetail,
        severity = severity,
    )
}
