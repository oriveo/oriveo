package ai.oriveo.community.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.app.AppLanguageManager
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.app.FeatureBadges
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class SettingsViewModel(
    private val appPreferencesRepository: AppPreferencesRepository,
    private val voiceEngineSettings: VoiceEngineSettings? = null,
) : ViewModel() {

    val theme: StateFlow<ThemeOption> = appPreferencesRepository.theme
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ThemeOption.Dark)

    /** Raw darkPalette preference (the theme row summary resolves it to show the palette name). */
    val darkPalette: StateFlow<String?> = appPreferencesRepository.darkPalette
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

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

    private val _voiceEngineLabel = MutableStateFlow<UiText?>(null)

    /** Value of the "Voice" cell: the display name of the read-aloud (TTS) engine, from the same function as the engine row of the voice settings page; null = not read yet. */
    val voiceEngineLabel: StateFlow<UiText?> = _voiceEngineLabel.asStateFlow()

    /** Called every time the settings home returns to the foreground: the engine may have been changed on the voice page (the choice lives in SharedPreferences and has no change flow). */
    fun refreshVoiceEngineLabel() {
        val settings = voiceEngineSettings ?: return
        viewModelScope.launch {
            _voiceEngineLabel.value = withContext(Dispatchers.IO) {
                voiceEngineLabel(settings.selection(VoiceDirection.Tts))
            }
        }
    }

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
