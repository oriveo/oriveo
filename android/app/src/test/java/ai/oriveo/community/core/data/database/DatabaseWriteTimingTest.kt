package ai.oriveo.community.core.data.database

import androidx.sqlite.db.SupportSQLiteDatabase
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DatabaseWriteTimingTest {

    private var nowNanos = 0L
    private val reports = mutableListOf<Pair<Double, String>>()
    private var label = UNLABELED_WRITE
    private val timer = WriteTransactionTimer(
        nanoTime = { nowNanos },
        currentLabel = { label },
        report = { ms, l -> reports += ms to l },
    )
    private val raw = mockk<SupportSQLiteDatabase>(relaxed = true)
    private val db = TimedWriteDatabase(raw, timer)

    private fun advanceMs(ms: Long) { nowNanos += ms * 1_000_000 }

    @Test
    fun `write transaction at or over the threshold reports its duration and label`() {
        label = "sync.batch"
        db.beginTransactionNonExclusive()
        advanceMs(LONG_WRITE_THRESHOLD_MS)
        db.setTransactionSuccessful()
        db.endTransaction()
        assertEquals(listOf(500.0 to "sync.batch"), reports)
        verify { raw.beginTransactionNonExclusive(); raw.endTransaction() }
    }

    @Test
    fun `short write is not reported`() {
        db.beginTransaction()
        advanceMs(LONG_WRITE_THRESHOLD_MS - 1)
        db.endTransaction()
        assertTrue(reports.isEmpty())
    }

    @Test
    fun `read only transaction is never reported`() {
        db.beginTransactionReadOnly()
        advanceMs(5_000)
        db.endTransaction()
        assertTrue(reports.isEmpty())
        verify { raw.beginTransactionReadOnly() }
    }

    @Test
    fun `nested transactions are timed once from the outermost begin`() {
        db.beginTransaction()
        advanceMs(300)
        db.beginTransactionWithListener(mockk(relaxed = true))
        advanceMs(300)
        db.endTransaction()
        assertTrue("an inner finish does not count as a write", reports.isEmpty())
        advanceMs(100)
        db.endTransaction()
        assertEquals(listOf(700.0 to UNLABELED_WRITE), reports)
    }

    @Test
    fun `label is captured when the transaction begins`() {
        label = "conversation.replaceAll"
        db.beginTransaction()
        label = "other"
        advanceMs(900)
        db.endTransaction()
        assertEquals("conversation.replaceAll", reports.single().second)
    }

    @Test
    fun `write label follows the coroutine onto another thread`() = runBlocking {
        val seen = withDatabaseWriteLabel("sync.batch") {
            withContext(Dispatchers.IO) { DatabaseWriteLabel.currentOrUnlabeled() }
        }
        assertEquals("sync.batch", seen)
        assertEquals(UNLABELED_WRITE, DatabaseWriteLabel.currentOrUnlabeled())
    }
}
