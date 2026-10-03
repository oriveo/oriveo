package ai.oriveo.community.feature.chat.composer

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Build
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import ai.oriveo.community.ui.theme.OriveoTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The Tools chip is dimmed but still tappable when the current model cannot use tools: tapping opens a panel that explains why, rather than being a dead button.
 * With servers enabled it carries a count.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ComposerControlChipDimmedTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun `a dimmed chip still opens its panel and announces why it is unavailable`() {
        var clicks = 0
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                ComposerControlChip(
                    title = "Tools",
                    icon = Icons.Outlined.Build,
                    accent = composerModelBehaviorAccent(),
                    emphasized = false,
                    disabled = false,
                    badgeText = null,
                    accessory = ComposerControlChipAccessory.None,
                    accessibilityState = "Not available for this model",
                    dimmed = true,
                    onClick = { clicks += 1 },
                )
            }
        }
        composeRule.waitForIdle()

        composeRule.onNodeWithText("Tools")
            .assertIsEnabled()
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Not available for this model"))
            .performClick()
        composeRule.waitForIdle()
        assertEquals(1, clicks)
    }

    @Test
    fun `an active chip carries the number of servers that are on`() {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                ComposerControlChip(
                    title = "Tools",
                    icon = Icons.Outlined.Build,
                    accent = composerModelBehaviorAccent(),
                    emphasized = true,
                    disabled = false,
                    badgeText = "2",
                    accessory = ComposerControlChipAccessory.None,
                    onClick = {},
                )
            }
        }
        composeRule.waitForIdle()
        composeRule.onNodeWithText("2", useUnmergedTree = true).assertExists()
    }
}
