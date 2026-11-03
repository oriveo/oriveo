package ai.oriveo.community.core.studio

import ai.oriveo.community.core.studio.StudioByokTasks.ReconcileAction
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * BYOK in-flight marker store on Android: mark / clear round trip, path-safe round ids, and launch
 * reconciliation of leftover markers into interrupted / failed_timeout.
 */
class StudioByokInflightStoreTest {
    private fun tempDir(): File = Files.createTempDirectory("byok-inflight").toFile().resolve("markers")

    private fun files(dir: File): List<String> = dir.listFiles()?.map { it.name }?.sorted() ?: emptyList()

    @Test
    fun markThenClearLeavesNothing() = runBlocking {
        val dir = tempDir()
        val store = StudioByokInflightStore(dir)

        assertTrue(store.mark("round_1-A", startedAtMs = 1_000L, timeoutSeconds = 60))
        assertEquals(listOf("round_1-A.json"), files(dir))

        store.clear("round_1-A")
        assertEquals(emptyList<String>(), files(dir))
        assertEquals(emptyList<Pair<String, ReconcileAction>>(), store.reconcileInterrupted(nowMs = 10_000_000L))

        val parent = dir.parentFile!!
        assertFalse(store.mark("../escape", startedAtMs = 1_000L, timeoutSeconds = 60))
        assertFalse(store.mark("a/b", startedAtMs = 1_000L, timeoutSeconds = 60))
        assertFalse(store.mark("", startedAtMs = 1_000L, timeoutSeconds = 60))
        assertEquals(listOf("markers"), files(parent))
        assertEquals(emptyList<String>(), files(dir))
    }

    @Test
    fun reconcileMarksInterruptedOrTimedOut() = runBlocking {
        val dir = tempDir()
        val store = StudioByokInflightStore(dir)
        val now = 200_000L

        assertTrue(store.mark("expired", startedAtMs = 0L, timeoutSeconds = 60))
        assertTrue(store.mark("fresh", startedAtMs = now - 20_000L, timeoutSeconds = 60))
        assertTrue(store.mark("defaultTimeout", startedAtMs = now - 179_000L, timeoutSeconds = null))
        assertTrue(store.mark("future", startedAtMs = now + 5_000L, timeoutSeconds = 60))

        val result = store.reconcileInterrupted(nowMs = now)

        assertEquals(
            listOf(
                "defaultTimeout" to ReconcileAction.INTERRUPTED,
                "expired" to ReconcileAction.FAILED_TIMEOUT,
                "fresh" to ReconcileAction.INTERRUPTED,
                "future" to ReconcileAction.INTERRUPTED,
            ),
            result,
        )
        assertEquals(emptyList<String>(), files(dir))
        assertEquals(emptyList<Pair<String, ReconcileAction>>(), store.reconcileInterrupted(nowMs = now))
    }

    @Test
    fun corruptMarkerIsInterrupted() = runBlocking {
        val dir = tempDir()
        dir.mkdirs()
        File(dir, "garbage.json").writeText("not json", Charsets.UTF_8)
        File(dir, "noStart.json").writeText("{\"timeoutSeconds\":60}", Charsets.UTF_8)
        File(dir, "wrongType.json").writeText("[1,2,3]", Charsets.UTF_8)
        val store = StudioByokInflightStore(dir)
        assertTrue(store.mark("timedOut", startedAtMs = 0L, timeoutSeconds = 30))

        val result = store.reconcileInterrupted(nowMs = 1_000_000L)

        assertEquals(
            listOf(
                "garbage" to ReconcileAction.INTERRUPTED,
                "noStart" to ReconcileAction.INTERRUPTED,
                "timedOut" to ReconcileAction.FAILED_TIMEOUT,
                "wrongType" to ReconcileAction.INTERRUPTED,
            ),
            result,
        )
        assertEquals(emptyList<String>(), files(dir))
    }
}
