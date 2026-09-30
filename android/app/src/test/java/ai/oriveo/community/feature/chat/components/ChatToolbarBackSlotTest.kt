package ai.oriveo.community.feature.chat.components

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.assertLeftPositionInRootIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.ui.component.OriveoBackButton
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
 * The chat toolbar's shared back button still takes only the original 36dp slot (the toolbar
 * layout does not shift) while its 48dp hit area stays clickable. xxhdpi keeps the dp
 * conversions free of rounding error.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ChatToolbarBackSlotTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun `shared back button keeps the 36dp toolbar slot while its 48dp hit area still clicks`() {
        var clicks = 0
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = false) {
                Row {
                    // A non-clickable spacer first, so the hit area outside the slot stays on screen
                    Box(Modifier.size(20.dp))
                    OriveoBackButton(onClick = { clicks += 1 }, modifier = Modifier.chatToolbarBackSlot())
                    Box(Modifier.size(10.dp).testTag("next"))
                }
            }
        }
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("next").assertLeftPositionInRootIsEqualTo(56.dp)
        val back = composeRule.onNodeWithContentDescription(activity.getString(R.string.back))
        back.assertWidthIsEqualTo(48.dp).assertHeightIsEqualTo(48.dp)
        back.assertLeftPositionInRootIsEqualTo(14.dp)

        // Tap outside the 36dp slot but inside the 48dp hit area (2dp in from the button's left edge)
        back.performTouchInput { click(Offset(2.dp.toPx(), centerY)) }
        composeRule.waitForIdle()
        assertEquals(1, clicks)
    }
}
