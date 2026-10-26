package ai.oriveo.community.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.feature.chat.ContextCapCommit
import ai.oriveo.community.feature.chat.ContextCapPresentation
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * Settings › Context: what happens when the context limit is reached.
 * false (default) = keep only the user's own messages; true = AI summary. Stored on this device only.
 * Also the global default input cap: auto (default), unlimited or a custom count,
 * and the price-line crossing reminder: on by default.
 */
class ContextSettingsViewModel(
    private val appPreferencesRepository: AppPreferencesRepository,
) : ViewModel() {

    val aiSummaryEnabled: StateFlow<Boolean> = appPreferencesRepository.contextAISummaryEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    fun setAISummaryEnabled(enabled: Boolean) {
        viewModelScope.launch {
            appPreferencesRepository.setContextAISummaryEnabled(enabled)
        }
    }

    /** Asks before a chat first crosses a model's long-context price line; global, this device only. */
    val priceLineReminderEnabled: StateFlow<Boolean> = appPreferencesRepository.contextPriceLineReminderEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), true)

    fun setPriceLineReminderEnabled(enabled: Boolean) {
        viewModelScope.launch {
            appPreferencesRepository.setContextPriceLineReminderEnabled(enabled)
        }
    }

    /** Global default cap; the selected option is always read back from storage. */
    val defaultCap: StateFlow<ContextBudgetCap> = appPreferencesRepository.contextDefaultCap
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ContextBudgetCap.Auto)

    fun setDefaultCap(cap: ContextBudgetCap) {
        viewModelScope.launch {
            appPreferencesRepository.setContextDefaultCap(cap)
        }
    }

    /** Choosing Custom stores the prefill right away: the current custom count, otherwise 256000. */
    fun selectCustomDefaultCap() {
        setDefaultCap(ContextBudgetCap.Custom(ContextCapPresentation.settings(defaultCap.value).customPrefill))
    }

    /**
     * Commits the typed custom number. No model applies here, so U is unbounded; unreadable text
     * restores the previous value and writes nothing.
     */
    fun commitDefaultCap(text: String): ContextCapCommit {
        val previous = ContextCapPresentation.settings(defaultCap.value).customPrefill
        val result = ContextCapPresentation.commit(text, u = null, previous = previous)
        if (!result.restored) setDefaultCap(ContextBudgetCap.Custom(result.value))
        return result
    }
}
