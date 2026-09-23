package ai.oriveo.community.feature.chat

import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.metrics.performance.PerformanceMetricsState
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import io.mockk.verifyOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * PerformanceMetricsState belongs to the whole window hierarchy. When the chat screen leaves
 * composition, [ChatMetricsEffect]'s LaunchedEffects are simply cancelled and never reach
 * removeState, so a jank frame on Home seconds later could still carry
 * `chat_generation=streaming` from a stream that had already failed, pointing any investigation
 * at background streaming. The assertions run against the production [ChatMetricsEffect] itself.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ChatMetricsEffectStateCleanupTest {

    @Test
    fun `leaving the chat screen while generating clears the window scoped generation state`() {
        val metricsState = mockk<PerformanceMetricsState>(relaxed = true)
        val holder = mockk<PerformanceMetricsState.Holder> {
            every { state } returns metricsState
        }
        var chatVisible by mutableStateOf(true)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            if (chatVisible) {
                ChatMetricsEffect(
                    metricsStateHolder = holder,
                    listState = rememberLazyListState(),
                    isGenerating = true,
                )
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
        verify(exactly = 1) { metricsState.putState("chat_generation", "streaming") }

        // Leave the chat screen (back to Home) while still generating: isGenerating never turns false.
        chatVisible = false
        shadowOf(Looper.getMainLooper()).idle()

        verifyOrder {
            metricsState.putState("chat_generation", "streaming")
            metricsState.removeState("chat_generation")
        }
        verify { metricsState.removeState("chat_list") }
    }
}
