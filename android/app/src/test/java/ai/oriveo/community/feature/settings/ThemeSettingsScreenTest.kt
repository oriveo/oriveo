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
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
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

/** Swipeable palette cards on the theme page: selected state / accessibility name, taps write the preference through the production ViewModel, tap target >= 44dp. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w390dp-h1400dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ThemeSettingsScreenTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val themeFlow = MutableStateFlow(ThemeOption.Dark)
    private val paletteFlow = MutableStateFlow<String?>(null)
    private val repository = mockk<AppPreferencesRepository>().also { repo ->
        every { repo.theme } returns themeFlow
        every { repo.darkPalette } returns paletteFlow
        coEvery { repo.setTheme(any()) } coAnswers { themeFlow.value = firstArg() }
        coEvery { repo.setDarkPalette(any()) } coAnswers { paletteFlow.value = firstArg<DarkPaletteId>().id }
    }

    private fun render(theme: ThemeOption, darkPalette: String?) {
        themeFlow.value = theme
        paletteFlow.value = darkPalette
        val viewModel = ThemeSettingsViewModel(repository)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = true) {
                val currentTheme by viewModel.theme.collectAsStateWithLifecycle()
                val currentPalette by viewModel.darkPalette.collectAsStateWithLifecycle()
                ThemeSettingsContent(
                    theme = currentTheme,
                    darkPalette = currentPalette,
                    onAction = { viewModel.onAction(it, systemDark = true) },
                )
            }
        }
        composeRule.waitForIdle()
    }

    /** The palette cards live in a horizontal LazyRow and off-screen cards are not composed: scroll to it first, then fetch it. */
    private fun card(tag: String): SemanticsNodeInteraction {
        composeRule.onNodeWithTag("theme_palette_row").performScrollToNode(hasTestTag(tag))
        return composeRule.onNodeWithTag(tag)
    }

    private fun description(text: String) =
        SemanticsMatcher.expectValue(SemanticsProperties.ContentDescription, listOf(text))

    @Test
    fun `swatches expose selection and palette name`() {
        render(ThemeOption.Dark, "dark-ocean")

        card("theme_swatch_dark-ocean").assertIsSelected().assert(description("Ocean"))
        card("theme_swatch_light").assertIsNotSelected().assert(description("Light"))
        card("theme_swatch_dark").assertIsNotSelected().assert(description("Dark"))
        composeRule.onNodeWithTag("theme_follow_system_switch").assertIsOff()
    }

    @Test
    fun `follow system selects the resolved palette and never light`() {
        render(ThemeOption.System, "dark-unknown")

        card("theme_swatch_dark").assertIsSelected()
        card("theme_swatch_light").assertIsNotSelected()
        composeRule.onNodeWithTag("theme_follow_system_switch").assertIsOn()
    }

    @Test
    fun `tapping a palette with follow off writes dark theme and palette`() {
        render(ThemeOption.Light, null)

        card("theme_swatch_dark-forest").performClick()
        composeRule.waitForIdle()

        coVerify { repository.setTheme(ThemeOption.Dark) }
        coVerify { repository.setDarkPalette(DarkPaletteId.Forest) }
        card("theme_swatch_dark-forest").assertIsSelected()

        card("theme_swatch_light").performClick()
        composeRule.waitForIdle()
        coVerify { repository.setTheme(ThemeOption.Light) }
        coVerify(exactly = 1) { repository.setDarkPalette(any()) }
        card("theme_swatch_light").assertIsSelected()
    }

    @Test
    fun `tapping a palette with follow on only writes the palette`() {
        render(ThemeOption.System, "dark")

        card("theme_swatch_dark-sunset").performClick()
        composeRule.waitForIdle()

        coVerify { repository.setDarkPalette(DarkPaletteId.Sunset) }
        coVerify(exactly = 0) { repository.setTheme(any()) }
    }

    @Test
    fun `toggling follow system writes theme`() {
        render(ThemeOption.Dark, "dark-black")

        composeRule.onNodeWithTag("theme_follow_system_switch").performClick()
        composeRule.waitForIdle()

        coVerify { repository.setTheme(ThemeOption.System) }
        coVerify(exactly = 0) { repository.setDarkPalette(any()) }
    }

    @Test
    fun `every swatch touch target is at least 44dp`() {
        render(ThemeOption.Dark, null)

        val tags = listOf("theme_swatch_light") + DarkPaletteId.entries.map { "theme_swatch_${it.id}" }
        tags.forEach { tag ->
            card(tag).assertWidthIsAtLeast(44.dp).assertHeightIsAtLeast(44.dp)
        }
    }

    @Test
    fun `selected palette card is scrolled into view on first entry`() {
        render(ThemeOption.Dark, "dark-sunset")

        composeRule.onNodeWithTag("theme_swatch_dark-sunset").assertIsDisplayed().assertIsSelected()
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
            val preview = previewMarkdownColors(ThemeSwatchSelection.Palette(palette))
            assertEquals("${palette.id} keyword", chat.syntaxKeyword, preview.syntaxKeyword)
            assertEquals("${palette.id} type", chat.syntaxType, preview.syntaxType)
            assertEquals("${palette.id} string", chat.syntaxString, preview.syntaxString)
            assertEquals("${palette.id} code body", chat.codeBlockFg, preview.codeBlockFg)
        }
        val light = MarkdownTheme.resolveColors(LightOriveoColors, isDark = false)
        assertEquals("light keyword", light.syntaxKeyword, previewMarkdownColors(ThemeSwatchSelection.Light).syntaxKeyword)
    }
}
