package ai.oriveo.community.feature.settings

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertWidthIsAtLeast
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.height
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.ui.component.markdown.MarkdownTheme
import ai.oriveo.community.ui.theme.DarkPaletteChoice
import ai.oriveo.community.ui.theme.DarkPaletteId
import ai.oriveo.community.ui.theme.LightOriveoColors
import ai.oriveo.community.ui.theme.OriveoTheme
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.performTouchInput
import ai.oriveo.community.ui.theme.OriveoCustomPalette
import org.junit.Assert.assertNotNull

/** Theme page: the three-segment appearance, 8 palette cards (selected state / accessibility name / taps write preferences through the production ViewModel), the custom color picker, and touch targets. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w390dp-h1400dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ThemeSettingsScreenTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val themeFlow = MutableStateFlow(ThemeOption.Dark)
    private val paletteFlow = MutableStateFlow<String?>(null)
    private val seedFlow = MutableStateFlow<String?>(null)
    private val repository = mockk<AppPreferencesRepository>().also { repo ->
        every { repo.theme } returns themeFlow
        every { repo.darkPalette } returns paletteFlow
        every { repo.darkPaletteCustom } returns seedFlow
        coEvery { repo.setTheme(any()) } coAnswers { themeFlow.value = firstArg() }
        coEvery { repo.setDarkPalette(any()) } coAnswers {
            val choice = firstArg<DarkPaletteChoice>()
            if (choice is DarkPaletteChoice.Custom) seedFlow.value = OriveoCustomPalette.format(choice.seed)
            paletteFlow.value = choice.storageId
        }
    }

    private fun render(theme: ThemeOption, darkPalette: String?, seed: String? = null, dark: Boolean = true) {
        themeFlow.value = theme
        paletteFlow.value = darkPalette
        seedFlow.value = seed
        val viewModel = ThemeSettingsViewModel(repository)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = dark) {
                val currentTheme by viewModel.theme.collectAsStateWithLifecycle()
                val currentPalette by viewModel.darkPalette.collectAsStateWithLifecycle()
                val currentSeed by viewModel.darkPaletteCustom.collectAsStateWithLifecycle()
                ThemeSettingsContent(
                    theme = currentTheme,
                    darkPalette = currentPalette,
                    customSeed = currentSeed,
                    onAction = viewModel::onAction,
                )
            }
        }
        composeRule.waitForIdle()
    }

    /** The palette cards sit in a horizontally scrolling LazyRow and off-screen cards are not composed: scroll to one first, then fetch it. */
    private fun card(tag: String): SemanticsNodeInteraction {
        composeRule.onNodeWithTag("theme_palette_row").performScrollToNode(hasTestTag(tag))
        return composeRule.onNodeWithTag(tag)
    }

    private fun description(text: String) =
        SemanticsMatcher.expectValue(SemanticsProperties.ContentDescription, listOf(text))

    @Test
    fun `eight palette cards in order with default first`() {
        assertEquals(
            listOf(
                "theme_swatch_dark", "theme_swatch_dark_purple", "theme_swatch_dark_graphite", "theme_swatch_dark_black",
                "theme_swatch_dark_ocean", "theme_swatch_dark_forest", "theme_swatch_dark_sunset", "theme_swatch_custom",
            ),
            ThemePaletteCardOrder.map(::themeSwatchTestTag),
        )
        render(ThemeOption.Dark, null)
        card("theme_swatch_dark").assertIsSelected().assert(description("Default"))
        card("theme_swatch_custom").assertIsNotSelected().assert(description("Custom"))
        composeRule.onNodeWithTag("theme_swatch_light").assertDoesNotExist()
        composeRule.onNodeWithTag("theme_follow_system_switch").assertDoesNotExist()
        composeRule.onNodeWithTag("theme_custom_section").assertDoesNotExist()
    }

    @Test
    fun `cards expose selection in every appearance`() {
        render(ThemeOption.Light, "dark-ocean", dark = false)
        card("theme_swatch_dark_ocean").assertIsSelected().assert(description("Ocean"))
        card("theme_swatch_dark").assertIsNotSelected()
        composeRule.onNodeWithTag(themeAppearanceTestTag(ThemeOption.Light)).assertIsSelected()
        composeRule.onNodeWithTag(themeAppearanceTestTag(ThemeOption.Dark)).assertIsNotSelected()
    }

    @Test
    fun `tapping a palette card writes only the palette`() {
        render(ThemeOption.Light, null, dark = false)

        card("theme_swatch_dark_forest").performClick()
        composeRule.waitForIdle()

        coVerify { repository.setDarkPalette(DarkPaletteChoice.Preset(DarkPaletteId.Forest)) }
        coVerify(exactly = 0) { repository.setTheme(any()) }
        card("theme_swatch_dark_forest").assertIsSelected()
    }

    @Test
    fun `appearance segment writes only the theme`() {
        render(ThemeOption.Dark, "dark-black")

        composeRule.onNodeWithTag(themeAppearanceTestTag(ThemeOption.System)).performClick()
        composeRule.waitForIdle()

        coVerify { repository.setTheme(ThemeOption.System) }
        coVerify(exactly = 0) { repository.setDarkPalette(any()) }
        composeRule.onNodeWithTag(themeAppearanceTestTag(ThemeOption.System)).assertIsSelected()
    }

    @Test
    fun `tapping custom without a seed writes the default seed and shows the picker`() {
        render(ThemeOption.Dark, "dark-ocean")

        card("theme_swatch_custom").performClick()
        composeRule.waitForIdle()

        coVerify { repository.setDarkPalette(DarkPaletteChoice.Custom(OriveoCustomPalette.DEFAULT_SEED)) }
        coVerify(exactly = 0) { repository.setTheme(any()) }
        card("theme_swatch_custom").assertIsSelected()
        composeRule.onNodeWithTag("theme_custom_section").assertExists()
        composeRule.onNodeWithTag(customPresetTestTag(OriveoCustomPalette.DEFAULT_SEED)).assertIsSelected()
    }

    @Test
    fun `tapping a preset dot writes the seed`() {
        render(ThemeOption.Light, "custom", seed = "#60A5FA", dark = false)
        val green = OriveoCustomPalette.parseSeed("#4ADE80")!!

        composeRule.onNodeWithTag(customPresetTestTag(green)).assert(description("Green")).performClick()
        composeRule.waitForIdle()

        coVerify { repository.setDarkPalette(DarkPaletteChoice.Custom(green)) }
        coVerify(exactly = 0) { repository.setTheme(any()) }
        assertEquals("#4ADE80", seedFlow.value)
        composeRule.onNodeWithTag(customPresetTestTag(green)).assertIsSelected()
    }

    @Test
    fun `dragging the hue bar previews only and writes on release`() {
        render(ThemeOption.Dark, "custom", seed = "#4ADE80")
        val slider = composeRule.onNodeWithTag("theme_hue_slider")

        slider.performTouchInput {
            down(centerLeft + Offset(4f, 0f))
            moveTo(center)
        }
        composeRule.waitForIdle()
        coVerify(exactly = 0) { repository.setDarkPalette(any()) }
        assertEquals("#4ADE80", seedFlow.value)
        val expected = OriveoCustomPalette.hueSliderSeed(180)
        // While dragging, this page's preview already switches to the dragged color
        composeRule.onNodeWithTag("theme_custom_primary", useUnmergedTree = true)
            .assert(hasAnyDescendant(hasText(OriveoCustomPalette.format(DarkPaletteChoice.Custom(expected).colors.primary.toArgb() and 0xFFFFFF))))

        slider.performTouchInput { up() }
        composeRule.waitForIdle()
        coVerify(exactly = 1) { repository.setDarkPalette(DarkPaletteChoice.Custom(expected)) }
        assertEquals(OriveoCustomPalette.format(expected), seedFlow.value)
    }

    @Test
    fun `adjusted notice appears only when the seed was adjusted`() {
        val adjusted = OriveoCustomPalette.presets.firstOrNull { OriveoCustomPalette.derive(it).adjusted != null }
            ?: 0x1E3A8A
        assertNotNull(OriveoCustomPalette.derive(adjusted).adjusted)
        render(ThemeOption.Dark, "custom", seed = OriveoCustomPalette.format(adjusted))
        composeRule.onNodeWithTag("theme_custom_adjusted").assertExists()

        val plain = OriveoCustomPalette.presets.first { OriveoCustomPalette.derive(it).adjusted == null }
        composeRule.onNodeWithTag(customPresetTestTag(plain)).performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithTag("theme_custom_adjusted").assertDoesNotExist()
    }

    @Test
    fun `every card and preset dot touch target is at least 44dp`() {
        render(ThemeOption.Dark, "custom", seed = "#60A5FA")

        ThemePaletteCardOrder.map(::themeSwatchTestTag).forEach { tag ->
            card(tag).assertWidthIsAtLeast(44.dp).assertHeightIsAtLeast(44.dp)
        }
        OriveoCustomPalette.presets.forEach { seed ->
            composeRule.onNodeWithTag(customPresetTestTag(seed)).assertWidthIsAtLeast(44.dp).assertHeightIsAtLeast(44.dp)
        }
        composeRule.onNodeWithTag("theme_hue_slider").assertHeightIsAtLeast(44.dp)
    }

    @Test
    fun `selected palette card is scrolled into view on first entry`() {
        render(ThemeOption.Dark, "custom", seed = "#F472B6")

        composeRule.onNodeWithTag("theme_swatch_custom").assertIsDisplayed().assertIsSelected()
    }

    @Test
    fun `preview card is at least 352dp and grows with large font scale`() {
        render(ThemeOption.Dark, "dark-forest")
        composeRule.onNodeWithTag("theme_preview_card").assertHeightIsAtLeast(352.dp)
    }

    @Test
    @Config(sdk = [34], qualifiers = "w390dp-h1400dp-xxhdpi", fontScale = 2.0f)
    fun `preview card grows instead of clipping at large font scale`() {
        render(ThemeOption.Dark, "dark-forest")
        val height = composeRule.onNodeWithTag("theme_preview_card").getUnclippedBoundsInRoot().height
        assertTrue("the preview card should grow taller at 2x font scale instead of clipping: $height", height > 352.dp)
    }

    @Test
    fun `preview code highlighting reuses chat markdown syntax tokens`() {
        for (palette in listOf(DarkPaletteId.Forest, DarkPaletteId.Sunset)) {
            val chat = MarkdownTheme.resolveColors(palette.colors, isDark = true)
            val preview = previewMarkdownColors(DarkPaletteChoice.Preset(palette), isDark = true)
            assertEquals("${palette.id} keyword", chat.syntaxKeyword, preview.syntaxKeyword)
            assertEquals("${palette.id} type", chat.syntaxType, preview.syntaxType)
            assertEquals("${palette.id} string", chat.syntaxString, preview.syntaxString)
            assertEquals("${palette.id} code body", chat.codeBlockFg, preview.codeBlockFg)
        }
        val light = MarkdownTheme.resolveColors(LightOriveoColors, isDark = false)
        assertEquals("light keyword", light.syntaxKeyword, previewMarkdownColors(DarkPaletteChoice.Default, isDark = false).syntaxKeyword)
    }
}
