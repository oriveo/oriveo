package ai.oriveo.community.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.app.AppLanguageManager
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.FeatureBadges
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.ThemeOption
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class SettingsViewModel(
    private val appPreferencesRepository: AppPreferencesRepository,
) : ViewModel() {

    val theme: StateFlow<ThemeOption> = appPreferencesRepository.theme
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ThemeOption.Dark)

    val language: StateFlow<LanguageOption> = appPreferencesRepository.language
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), LanguageOption.System)

    val memoryText: StateFlow<String> = appPreferencesRepository.memoryText
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "")

    /** New-feature red dot next to the "Memory" row title; it goes out once the memory settings page has been opened. */
    val memoryFeatureBadgeVisible: StateFlow<Boolean> = appPreferencesRepository
        .featureBadgeUnseen(FeatureBadges.SETTINGS_MEMORY)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    /** Settings > Context row value: true = AI summary, false = keep only the user's messages. */
    val contextAISummaryEnabled: StateFlow<Boolean> = appPreferencesRepository.contextAISummaryEnabled
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    /** Settings > Context row value: the global default cap shown before the mode. */
    val contextDefaultCap: StateFlow<ContextBudgetCap> = appPreferencesRepository.contextDefaultCap
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ContextBudgetCap.Auto)

    fun setTheme(option: ThemeOption) {
        viewModelScope.launch {
            appPreferencesRepository.setTheme(option)
        }
    }

    fun setLanguage(option: LanguageOption) {
        viewModelScope.launch {
            appPreferencesRepository.setLanguage(option)
            AppLanguageManager.apply(option)
        }
    }
}
