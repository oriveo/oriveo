package ai.oriveo.community.feature.settings

import ai.oriveo.community.ui.theme.DarkPaletteChoice
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.model.ThemeOption
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

/**
 * Settings > Theme page: reads the theme / darkPalette / darkPaletteCustom preferences; an action goes through [ThemePageRules.apply] to compute the new values and only the changed ones are written
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

    /** Raw stored custom seed (`#RRGGBB`; null = never picked). */
    val darkPaletteCustom: StateFlow<String?> = appPreferencesRepository.darkPaletteCustom
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    internal fun onAction(action: ThemePageAction) {
        val before = ThemePageState(theme = theme.value, darkPalette = darkPalette.value, seed = darkPaletteCustom.value)
        val after = ThemePageRules.apply(before, action)
        viewModelScope.launch {
            if (after.theme != before.theme) {
                appPreferencesRepository.setTheme(after.theme)
            }
            if (after.darkPalette != before.darkPalette || after.seed != before.seed) {
                appPreferencesRepository.setDarkPalette(DarkPaletteChoice.resolve(after.darkPalette, after.seed))
            }
        }
    }
}
