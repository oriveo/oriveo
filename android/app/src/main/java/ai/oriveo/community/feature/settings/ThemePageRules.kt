package ai.oriveo.community.feature.settings

import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.ui.theme.DarkPaletteId

/** One user action on the theme page (matches tap / toggleFollow in the contract's `themePageCases`). */
internal sealed interface ThemePageAction {
    /** Tap the "Light" swatch. */
    data object TapLight : ThemePageAction

    /** Tap a dark swatch (including "Dark" = [DarkPaletteId.Dark]). */
    data class TapPalette(val palette: DarkPaletteId) : ThemePageAction

    /** Toggle the "Follow System" switch. */
    data class ToggleFollow(val on: Boolean) : ThemePageAction
}

/** The two preferences the theme page reads and writes; darkPalette is the raw stored value (may be an unknown id, null = unset). */
internal data class ThemePageState(
    val theme: ThemeOption,
    val darkPalette: String?,
)

/** The swatch currently selected on the theme page. */
internal sealed interface ThemeSwatchSelection {
    data object Light : ThemeSwatchSelection

    data class Palette(val palette: DarkPaletteId) : ThemeSwatchSelection
}

internal object ThemePageRules {

    /**
     * Pure function: current preferences + system appearance + action -> new preferences.
     * - tap light: theme=light, darkPalette untouched;
     * - tap a palette: follow off -> theme=dark + darkPalette=id; follow on -> only darkPalette is written;
     * - turn follow on: theme=system; turn follow off: theme=the current system appearance.
     */
    fun apply(state: ThemePageState, systemDark: Boolean, action: ThemePageAction): ThemePageState = when (action) {
        ThemePageAction.TapLight -> state.copy(theme = ThemeOption.Light)
        is ThemePageAction.TapPalette -> ThemePageState(
            theme = if (state.theme == ThemeOption.System) ThemeOption.System else ThemeOption.Dark,
            darkPalette = action.palette.id,
        )
        is ThemePageAction.ToggleFollow -> state.copy(
            theme = when {
                action.on -> ThemeOption.System
                systemDark -> ThemeOption.Dark
                else -> ThemeOption.Light
            },
        )
    }

    /** Selected swatch: the light theme selects "Light"; follow system or the dark theme selects resolve(darkPalette). */
    fun selection(theme: ThemeOption, darkPalette: String?): ThemeSwatchSelection = when (theme) {
        ThemeOption.Light -> ThemeSwatchSelection.Light
        ThemeOption.Dark, ThemeOption.System -> ThemeSwatchSelection.Palette(DarkPaletteId.fromId(darkPalette))
    }
}
