package ai.oriveo.community.feature.chat.components

import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.unit.dp
import ai.oriveo.community.ui.theme.OriveoTypography
import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Layout cost of folding a very long user message, at the scale of a pasted single-paragraph
 * Arabic text of 200,000 characters.
 *
 * In NATIVE graphics mode Text goes through real minikin shaping, so the cost is on the same order
 * as a device. Both the bubble body and the full-text sheet compose what the production code
 * produces ([UserMessageFold.preview] / [UserMessageFold.readingChunks]) in a host shaped like
 * production, with the production chat body font, timed from setContent until the main Looper is
 * idle (composition, measure and layout). The production composables use stringResource and Koin
 * injection and this module's unit tests do not enable includeAndroidResources, so the wiring is
 * pinned by the last, structural test.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class UserMessageFoldLayoutCostTest {

    private val text: String = run {
        val sentence = "بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ، لَا إِلَٰهَ إِلَّا اللَّهُ وَالسَّلَامُ عَلَيْكُمْ؛ هَٰذَا نَصٌّ طَوِيلٌ جِدًّا. "
        buildString { while (length < 200_000) append(sentence) }
    }

    private fun layOut(content: @androidx.compose.runtime.Composable () -> Unit): Double {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val start = System.nanoTime()
        activity.setContent { MaterialTheme { content() } }
        shadowOf(Looper.getMainLooper()).idle()
        return (System.nanoTime() - start) / 1_000_000.0
    }

    /** Same width as a UserBubble (maxBubbleWidth is about 280dp on a phone, minus 16dp padding on each side). */
    private fun bubble(body: String, folded: Boolean): Double = layOut {
        Box(modifier = Modifier.width(248.dp)) {
            Text(
                text = body,
                style = OriveoTypography.chatBody,
                modifier = if (folded) {
                    Modifier.heightIn(max = UserMessageFold.CollapsedTextHeight).clipToBounds()
                } else {
                    Modifier
                },
            )
        }
    }

    @Test
    fun `folded bubble lays out a bounded prefix instead of the whole message`() {
        val preview = UserMessageFold.preview(text)
        repeat(2) { bubble(preview, folded = true) }
        val folded = (1..3).minOf { bubble(preview, folded = true) }
        val full = bubble(text, folded = false)
        println("UserMessageFoldLayoutCostTest bubble utf16=${text.length} folded=${"%.1f".format(folded)}ms full=${"%.1f".format(full)}ms")
        assertTrue("folded bubble layout took ${"%.1f".format(folded)}ms, over the 50ms budget", folded < 50.0)
        assertTrue("folding must cost far less than laying out the whole text (${"%.1f".format(folded)} vs ${"%.1f".format(full)}ms)", folded * 5 < full)
    }

    @Test
    fun `full text sheet composes only the visible chunks`() {
        val chunks = UserMessageFold.readingChunks(text)
        var composed = 0
        val run = {
            composed = 0
            layOut {
                LazyColumn(modifier = Modifier.height(800.dp).fillMaxWidth()) {
                    itemsIndexed(chunks, key = { index, _ -> index }) { _, chunk ->
                        composed += 1
                        Text(text = chunk, style = OriveoTypography.chatBody, modifier = Modifier.fillMaxWidth())
                    }
                }
            }
        }
        run()
        val ms = (1..3).minOf { run() }
        println("UserMessageFoldLayoutCostTest sheet chunks=${chunks.size} composed=$composed best=${"%.1f".format(ms)}ms")
        assertTrue("the full-text sheet should compose only one screen of chunks, got $composed / ${chunks.size}", composed in 1..6)
        assertTrue("opening the full-text sheet took ${"%.1f".format(ms)}ms, over the 100ms budget", ms < 100.0)
    }

    @Test
    fun `user bubble routes overlong text through the fold and the sheet reads chunks lazily`() {
        val bubbleSource = File("src/main/java/ai/oriveo/community/feature/chat/components/MessageBubble.kt").readText()
        val userBubble = bubbleSource.substringAfter("private fun UserBubble(").substringBefore("private fun SelectableUserMessageText(")
        assertTrue("UserBubble must take the prefix through UserMessageFold.shouldFold", userBubble.contains("UserMessageFold.shouldFold(displayText)"))
        assertTrue("the folded state must render FoldedUserMessageText", userBubble.contains("FoldedUserMessageText("))
        assertTrue("the folded body must cap its height", bubbleSource.contains("heightIn(max = UserMessageFold.CollapsedTextHeight)"))

        val sheetSource = File("src/main/java/ai/oriveo/community/feature/chat/components/UserMessageFullTextSheet.kt").readText()
        assertTrue("the full-text sheet must compose chunks lazily", sheetSource.contains("LazyColumn(") && sheetSource.contains("UserMessageFold.readingChunks(text)"))
    }
}
