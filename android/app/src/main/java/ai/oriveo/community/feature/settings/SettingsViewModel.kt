package ai.oriveo.community.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.app.AppLanguageManager
import ai.oriveo.community.core.app.AppPreferencesRepository
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
