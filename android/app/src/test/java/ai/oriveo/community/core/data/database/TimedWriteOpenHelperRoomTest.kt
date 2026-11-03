package ai.oriveo.community.core.data.database

import android.content.Context
import androidx.room.Room
import androidx.room.withTransaction
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** Production-path proof: real Room with the wrapped open helper; withTransaction writes really pass through the timer. */
@RunWith(RobolectricTestRunner::class)
class TimedWriteOpenHelperRoomTest {

    @Test
    fun `room write transactions go through the timer and keep working`() = runBlocking {
        var now = 0L
        val reports = mutableListOf<Pair<Double, String>>()
        val timer = WriteTransactionTimer(
            nanoTime = { now += 600_000_000L; now },
            report = { ms, label -> reports += ms to label },
        )
        val context = ApplicationProvider.getApplicationContext<Context>()
        val db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .openHelperFactory(TimedWriteOpenHelperFactory(FrameworkSQLiteOpenHelperFactory(), timer))
            .build()
        try {
            withDatabaseWriteLabel("sync.batch") {
                db.withTransaction { db.openHelper.writableDatabase.execSQL("CREATE TEMP TABLE IF NOT EXISTS timing_probe(x INTEGER)") }
            }
            assertTrue("withTransaction did not pass through the timer: $reports", reports.any { it.second == "sync.batch" })
            assertEquals(600.0, reports.first { it.second == "sync.batch" }.first, 0.0)
        } finally {
            db.close()
        }
    }
}
