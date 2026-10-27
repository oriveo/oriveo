package ai.oriveo.community.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.ui.theme.DarkPaletteId
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * Settings > Theme page: reads the theme / darkPalette preferences; an action goes through [ThemePageRules.apply] to compute the new values and only the changed one is written
 * (an unchanged value is not written). A write takes effect across the whole app immediately (MainActivity collects the same preference).
 */
class ThemeSettingsViewModel(
    private val appPreferencesRepository: AppPreferencesRepository,
) : ViewModel() {

    val theme: StateFlow<ThemeOption> = appPreferencesRepository.theme
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ThemeOption.Dark)

    /** Raw stored value: null = unset, may be an unknown id; rendering always resolves it. */
    val darkPalette: StateFlow<String?> = appPreferencesRepository.darkPalette
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    internal fun onAction(action: ThemePageAction, systemDark: Boolean) {
        val before = ThemePageState(theme = theme.value, darkPalette = darkPalette.value)
        val after = ThemePageRules.apply(before, systemDark, action)
        viewModelScope.launch {
            if (after.theme != before.theme) {
                appPreferencesRepository.setTheme(after.theme)
            }
            if (after.darkPalette != before.darkPalette) {
                DarkPaletteId.fromIdOrNull(after.darkPalette)?.let { appPreferencesRepository.setDarkPalette(it) }
            }
        }
    }
}
