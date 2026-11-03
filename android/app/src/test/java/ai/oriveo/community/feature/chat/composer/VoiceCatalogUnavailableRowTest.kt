package ai.oriveo.community.feature.chat.composer

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import ai.oriveo.community.R
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
 * When the realtime voice model is waiting for the voice catalog, or the catalog load fails, a row "Realtime voice model unavailable" + "Retry" appears above the input field;
 * tapping retry calls refresh, and the button is disabled while retry is in progress to prevent repeated taps.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class VoiceCatalogUnavailableRowTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun failed_row_shows_unavailable_and_retry_invokes_refresh() {
        var retrying by mutableStateOf(false)
        var refreshCalls = 0
        val context = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        context.setContent {
            OriveoTheme(darkTheme = false) {
                VoiceCatalogUnavailableRow(
                    retrying = retrying,
                    onRetry = {
                        refreshCalls++
                        retrying = true
                    },
                )
            }
        }
        composeRule.waitForIdle()

        composeRule.onNodeWithText(context.getString(R.string.voice_realtime_catalog_unavailable)).assertExists()
        val retry = composeRule.onNodeWithText(context.getString(R.string.retry))
        retry.assertIsEnabled()
        retry.performClick()
        composeRule.waitForIdle()
        assertEquals(1, refreshCalls)

        // Retry in progress: button disabled, tapping again does not trigger refresh
        retry.assertIsNotEnabled()
        retry.performClick()
        composeRule.waitForIdle()
        assertEquals(1, refreshCalls)
    }

    /**
     * Follows iOS realtimeCatalogRetryRowView: the row is a warning-tinted banner (light 0.08 / dark 0.14), not a transparent single gray text line.
     * The sample point is 5dp inside the 16dp left-edge margin: past the 1dp stroke, not yet at the icon.
     */
    @Test
    fun catalogUnavailableRowHasWarningSurface() {
        assertSurface(darkTheme = false, base = Color.White, alpha = 0.08f)
        assertSurface(darkTheme = true, base = Color.Black, alpha = 0.14f)
    }

    private fun assertSurface(darkTheme: Boolean, base: Color, alpha: Float) {
        var warning = Color.Unspecified
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            OriveoTheme(darkTheme = darkTheme) {
                warning = OriveoTheme.colors.warning
                Box(Modifier.background(base)) {
                    VoiceCatalogUnavailableRow(retrying = false, onRetry = {})
                }
            }
        }
        composeRule.waitForIdle()
        val pixels = composeRule.onRoot().captureToImage().toPixelMap()
        val density = activity.resources.displayMetrics.density
        val sample = pixels[((16 + 5) * density).toInt(), pixels.height / 2]
        val label = if (darkTheme) "dark" else "light"
        assertEquals("$label red", base.red * (1 - alpha) + warning.red * alpha, sample.red, 0.02f)
        assertEquals("$label green", base.green * (1 - alpha) + warning.green * alpha, sample.green, 0.02f)
        assertEquals("$label blue", base.blue * (1 - alpha) + warning.blue * alpha, sample.blue, 0.02f)
        activity.finish()
    }
}
