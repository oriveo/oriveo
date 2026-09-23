package ai.oriveo.community.feature.providers.relay

import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The options of the default-model menu are the whole relay catalog.
 *
 * DropdownMenu's content is a non-lazy Column (plus IntrinsicSize.Max width measurement), so
 * rendering every option eagerly composes and measures all of them as soon as the menu opens:
 * 60-140ms for 1500 entries on a desktop JVM, several times that on a device.
 *
 * Method: the production [RelayMenuOptions] is placed in a host shaped like the DropdownMenu
 * content area, and timed from setContent until the main Looper is idle (composition, measure
 * and layout all done). The number of composed rows is counted through label calls, which is
 * deterministic; wall-clock time is secondary.
 *
 * Why the host is not DropdownMenu itself: its Popup reads compose-ui accessibility string
 * resources, and this module's unit tests do not enable includeAndroidResources. The cost is
 * decided by the two constraints of the content area, `width(IntrinsicSize.Max)` and
 * `verticalScroll` (children get an unbounded max height), and the host reproduces material3's
 * `DropdownMenuContent` exactly, so if the lazy branch crashed under those constraints
 * (LazyColumn does not support intrinsic measurement) it would crash here too.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class RelayMenuOptionsScaleTest {

    private val catalog = (0 until 1_500).map { "vendor-${it % 9}/relay-model-$it-instruct-2025" }

    private fun openMenu(options: List<String>): Pair<Int, Double> {
        var labelCalls = 0
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val start = System.nanoTime()
        activity.setContent {
            MaterialTheme {
                Column(
                    modifier = Modifier
                        .width(IntrinsicSize.Max)
                        .verticalScroll(rememberScrollState()),
                ) {
                    RelayMenuOptions(
                        options = options,
                        label = { option -> labelCalls += 1; option },
                        onSelect = {},
                        maxLines = 1,
                    )
                }
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
        return labelCalls to (System.nanoTime() - start) / 1_000_000.0
    }

    @Test
    fun `opening a 1500 model menu composes only the visible rows`() {
        repeat(2) { openMenu(catalog) }
        val runs = (1..3).map { openMenu(catalog) }
        val labelCalls = runs.first().first
        val bestMs = runs.minOf { it.second }
        println("RelayMenuOptionsScaleTest options=1500 composedRows=$labelCalls best=${"%.1f".format(bestMs)}ms")

        assertTrue("1500 options should compose only the visible screenful, composed $labelCalls rows", labelCalls in 1..64)
        assertTrue("opening a 1500 option menu took ${"%.1f".format(bestMs)}ms, over the 40ms budget", bestMs < 40.0)
    }

    @Test
    fun `small enumerations keep the native eager menu`() {
        val (labelCalls, _) = openMenu(catalog.take(RelayMenuLazyThreshold))
        assertEquals(RelayMenuLazyThreshold, labelCalls)
    }
}
