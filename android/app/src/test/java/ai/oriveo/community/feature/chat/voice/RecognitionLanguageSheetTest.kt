package ai.oriveo.community.feature.chat.voice

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import ai.oriveo.community.R
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.testing.TestSharedPreferences
import ai.oriveo.community.ui.theme.OriveoTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Recognition language sheet in voice conversation: rows are Automatic plus every language with a localeTag, the current one is checked; picking writes the setting and reports whether it changed. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class RecognitionLanguageSheetTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val prefs = TestSharedPreferences()
    private val settings = VoiceEngineSettings { prefs }

    private fun show(onPicked: (Boolean) -> Unit): ComponentActivity {
        RuntimeEnvironment.setQualifiers("+en")
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                RecognitionLanguageOptions(settings = settings, onPicked = onPicked)
            }
        }
        composeRule.waitForIdle()
        return activity
    }

    private fun selectedLabels(): List<String> = composeRule
        .onAllNodes(SemanticsMatcher.expectValue(SemanticsProperties.Selected, true), useUnmergedTree = false)
        .fetchSemanticsNodes()
        .map { node -> node.config.getOrNull(SemanticsProperties.Text).orEmpty().joinToString("") { it.text } }

    @Test
    fun `rows are automatic plus every language with a locale tag and the saved one is checked`() {
        settings.setRecognitionLanguage(LanguageOption.Japanese.localeTag)
        val activity = show {}
        composeRule.onNodeWithText(activity.getString(R.string.voice_recognition_language)).assertExists()
        val tagged = LanguageOption.entries.filter { it.localeTag != null }
        val rows = composeRule
            .onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.Selected))
            .fetchSemanticsNodes()
        assertEquals(1 + tagged.size, rows.size)
        composeRule.onNodeWithText(activity.getString(R.string.voice_language_automatic)).assertExists()
        tagged.forEach { composeRule.onNodeWithText(it.displayName).assertExists() }
        assertEquals(listOf(LanguageOption.Japanese.displayName), selectedLabels())
        activity.finish()
    }

    @Test
    fun `automatic is checked when nothing is saved`() {
        val activity = show {}
        assertEquals(listOf(activity.getString(R.string.voice_language_automatic)), selectedLabels())
        activity.finish()
    }

    @Test
    fun `picking another language saves it and reports a change`() {
        val picked = mutableListOf<Boolean>()
        val activity = show { picked += it }
        val french = LanguageOption.French
        composeRule.onNodeWithText(french.displayName).performScrollTo().performClick()
        composeRule.waitForIdle()
        assertEquals(french.localeTag, settings.recognitionLanguage())
        assertEquals(listOf(true), picked)
        activity.finish()
    }

    @Test
    fun `picking the saved language reports no change and keeps the setting`() {
        settings.setRecognitionLanguage(LanguageOption.German.localeTag)
        val picked = mutableListOf<Boolean>()
        val activity = show { picked += it }
        composeRule.onNodeWithText(LanguageOption.German.displayName).performScrollTo().performClick()
        composeRule.waitForIdle()
        assertEquals(LanguageOption.German.localeTag, settings.recognitionLanguage())
        assertEquals(listOf(false), picked)
        activity.finish()
    }

    @Test
    fun `picking automatic clears the saved language`() {
        settings.setRecognitionLanguage(LanguageOption.Korean.localeTag)
        val picked = mutableListOf<Boolean>()
        val activity = show { picked += it }
        composeRule.onNodeWithText(activity.getString(R.string.voice_language_automatic)).performClick()
        composeRule.waitForIdle()
        assertEquals(null, settings.recognitionLanguage())
        assertEquals(listOf(true), picked)
        activity.finish()
    }
}
