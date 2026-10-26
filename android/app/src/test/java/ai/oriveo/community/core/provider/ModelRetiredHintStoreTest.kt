package ai.oriveo.community.core.provider

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import org.junit.Test

class ModelRetiredHintStoreTest {

    @Test
    fun `same provider and model is consumed only once`() {
        var payload: String? = null
        val store = ModelRetiredHintStore(readPayload = { payload }, writePayload = { payload = it })

        assertTrue(store.consume("provider-openai", "gpt-legacy"))
        assertFalse(store.consume("provider-openai", "gpt-legacy"))
        assertTrue(store.consume("provider-openai", "gpt-older"))
        assertTrue(store.consume("provider-other", "gpt-legacy"))
        assertFalse(store.consume("provider-openai", ""))
        assertEquals("provider-openai|gpt-legacy", payload?.split("\n")?.first())
    }

    @Test
    fun `consume_reads_prefs_off_main`() {
        lateinit var ioThread: Thread
        val io = java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it, "hint-io").also { thread -> ioThread = thread } }
        try {
            var payload: String? = null
            val readThreads = mutableListOf<Thread>()
            val store = ModelRetiredHintStore(
                readPayload = { readThreads += Thread.currentThread(); payload },
                writePayload = { payload = it },
                ioDispatcher = io.asCoroutineDispatcher(),
            )
            val callerThread = Thread.currentThread()
            assertTrue(runBlocking { store.consumeOffMain("p1", "m1") })
            assertFalse(runBlocking { store.consumeOffMain("p1", "m1") })
            assertEquals(listOf(ioThread, ioThread), readThreads)
            assertFalse(callerThread in readThreads)
            assertEquals("p1|m1", payload)
        } finally {
            io.shutdown()
        }
    }
}
