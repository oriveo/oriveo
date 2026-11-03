package ai.oriveo.community.feature.chat.components

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onRoot
import ai.oriveo.community.core.model.SearchMessageErrorCard
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
 * Like iOS UIKitSearchErrorCard, the search failure card sits on the warning-soft fill instead of the
 * neutral inset fill.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SearchErrorCardSurfaceTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    /**
     * Sample point is about 6dp in from the bottom and end edges: past the stroke, and where the
     * card highlight gradient (top-start to bottom-end) has faded out.
     */
    @Test
    fun searchErrorCardHasWarningSurface() {
        assertSurface(darkTheme = false, base = Color.White)
        assertSurface(darkTheme = true, base = Color.Black)
    }

    private fun assertSurface(darkTheme: Boolean, base: Color) {
        var soft = Color.Unspecified
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = darkTheme) {
                soft = OriveoTheme.colors.warningSoft
                Box(Modifier.background(base)) {
                    SearchErrorCardView(
                        messageId = "m1",
                        card = SearchMessageErrorCard("x", "no_response", "something_new", null, "DeepSeek"),
                        isLastMessage = false,
                    )
                }
            }
        }
        composeRule.waitForIdle()
        val pixels = composeRule.onRoot().captureToImage().toPixelMap()
        val inset = (6 * activity.resources.displayMetrics.density).toInt()
        val sample = pixels[pixels.width - inset, pixels.height - inset]
        val a = soft.alpha
        val label = if (darkTheme) "dark" else "light"
        assertEquals("$label red", base.red * (1 - a) + soft.red * a, sample.red, 0.02f)
        assertEquals("$label green", base.green * (1 - a) + soft.green * a, sample.green, 0.02f)
        assertEquals("$label blue", base.blue * (1 - a) + soft.blue * a, sample.blue, 0.02f)
        activity.finish()
    }
}
