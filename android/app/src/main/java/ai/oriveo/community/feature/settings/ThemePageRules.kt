package ai.oriveo.community.feature.settings

import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.ui.theme.DarkPaletteChoice
import ai.oriveo.community.ui.theme.DarkPaletteId
import ai.oriveo.community.ui.theme.OriveoCustomPalette

/** One user action on the theme page (matches segment / tap / pickSeed in the contract's `appearancePageCases`). */
internal sealed interface ThemePageAction {
    /** The three-segment appearance control: Light / Dark / Follow System. */
    data class SetAppearance(val theme: ThemeOption) : ThemePageAction

    /** Tap a preset palette card (including "Default" = [DarkPaletteId.Dark]). */
    data class TapPalette(val palette: DarkPaletteId) : ThemePageAction

    /** Tap the "Custom" card. */
    data object TapCustom : ThemePageAction

    /** Pick a preset color in the color picker or release the hue bar; [seed] is `0xRRGGBB`. */
    data class PickSeed(val seed: Int) : ThemePageAction
}

/** The three preferences the theme page reads and writes; darkPalette / seed are raw stored values (may be an unknown id / invalid color, null = unset). */
internal data class ThemePageState(
    val theme: ThemeOption,
    val darkPalette: String?,
    val seed: String?,
)

/** The palette card selected on the theme page. */
internal sealed interface ThemeSwatchSelection {
    data class Palette(val palette: DarkPaletteId) : ThemeSwatchSelection

    data object Custom : ThemeSwatchSelection
}

internal object ThemePageRules {

    /**
     * Pure function: current preferences + action -> new preferences.
     * - the appearance only writes theme;
     * - tapping a palette card only writes darkPalette and keeps the seed;
     * - tapping custom: darkPalette=custom, writing the default seed when none was ever picked (or the stored one is invalid);
     * - picking a seed: darkPalette=custom + the seed.
     */
    fun apply(state: ThemePageState, action: ThemePageAction): ThemePageState = when (action) {
        is ThemePageAction.SetAppearance -> state.copy(theme = action.theme)
        is ThemePageAction.TapPalette -> state.copy(darkPalette = action.palette.id)
        ThemePageAction.TapCustom -> state.copy(
            darkPalette = OriveoCustomPalette.ID,
            seed = state.seed.takeIf { OriveoCustomPalette.parseSeed(it) != null }
                ?: OriveoCustomPalette.format(OriveoCustomPalette.DEFAULT_SEED),
        )
        is ThemePageAction.PickSeed -> state.copy(
            darkPalette = OriveoCustomPalette.ID,
            seed = OriveoCustomPalette.format(action.seed),
        )
    }

    /** Selected card = resolve(darkPalette), independent of the appearance (a selection ring shows under any appearance). */
    fun selection(darkPalette: String?): ThemeSwatchSelection = selection(DarkPaletteChoice.resolve(darkPalette, null))

    fun selection(choice: DarkPaletteChoice): ThemeSwatchSelection = when (choice) {
        is DarkPaletteChoice.Custom -> ThemeSwatchSelection.Custom
        is DarkPaletteChoice.Preset -> ThemeSwatchSelection.Palette(choice.id)
    }
}
