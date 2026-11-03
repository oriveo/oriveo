package ai.oriveo.community.testing

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import java.io.File
import java.util.Collections
import kotlin.concurrent.thread
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * On device, the E2E home LazyColumn occasionally threw `IndexOutOfBoundsException: Index 5, size 5`.
 * Root cause: the v1 `junit4.createEmptyComposeRule` installs an UnconfinedTestDispatcher on the process-wide window Recomposer.
 * When a background thread (Default / Room / test thread) woke a LaunchedEffect or collectAsStateWithLifecycle, it wrote snapshot state on that thread,
 * so the LazyColumn being measured on the main thread read a list that had been shortened under it. The v2 rule uses StandardTestDispatcher, so wake-ups are queued back to the main thread.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ComposeTestRuleEffectThreadTest {
    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun effectResumedByBackgroundWriterWritesSnapshotStateOnMainThread() {
        val rows = MutableStateFlow(List(6) { "row-$it" })
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        activity.setContent {
            val items by rows.collectAsState()
            LazyColumn { items(items, key = { it }) { Text(it) } }
        }
        composeRule.waitForIdle()

        val writerThreads = Collections.synchronizedList(mutableListOf<String>())
        val handle = Snapshot.registerGlobalWriteObserver { writerThreads += Thread.currentThread().name }
        try {
            thread(name = BACKGROUND_WRITER) { rows.value = List(5) { "row-$it" } }.join()
            composeRule.waitForIdle()
        } finally {
            handle.dispose()
        }

        assertTrue("collectAsState wrote nothing after the background emit", writerThreads.isNotEmpty())
        assertEquals("snapshot writes on the background writer thread", emptyList<String>(), writerThreads.filter { it == BACKGROUND_WRITER })
    }

    @Test
    fun androidTestsUseTheStandardDispatcherRules() {
        val v1 = Regex("""^import androidx\.compose\.ui\.test\.junit4\.create(Empty|Android)?ComposeRule$""", RegexOption.MULTILINE)
        val offenders = File("src/androidTest").walk().filter { it.isFile && it.extension == "kt" && v1.containsMatchIn(it.readText()) }
            .map { it.path }.sorted().toList()
        assertEquals("androidTest must import compose rules from junit4.v2 (StandardTestDispatcher)", emptyList<String>(), offenders)
    }

    private companion object {
        const val BACKGROUND_WRITER = "a14-background-writer"
    }
}
