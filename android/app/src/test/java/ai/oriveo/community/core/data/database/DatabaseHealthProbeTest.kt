package ai.oriveo.community.core.data.database

import android.database.sqlite.SQLiteDatabaseCorruptException
import android.database.sqlite.SQLiteDiskIOException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner


@RunWith(RobolectricTestRunner::class)
class DatabaseHealthProbeTest {

    @Test
    fun `disk io failure below the threshold is triaged as storage full and stays out of crash reporting`() {
        val verdict = triageDatabaseOpenFailure(
            error = SQLiteDiskIOException(
                "disk I/O error (code 4874 SQLITE_IOERR_SHMSIZE): , while compiling: PRAGMA journal_mode",
            ),
            usableSpaceBytes = 0L,
        )

        assertEquals(DatabaseHealth.Blocked(DatabaseBlockedReason.StorageFull), verdict?.health)
        assertEquals("0", verdict?.freeBytesBucket)
    }

    @Test
    fun `the very same exception with room to spare is triaged as our own failure`() {
        
        val verdict = triageDatabaseOpenFailure(
            error = SQLiteDiskIOException("disk I/O error (code 4874 SQLITE_IOERR_SHMSIZE)"),
            usableSpaceBytes = 200L * 1024 * 1024,
        )

        assertEquals(DatabaseHealth.Blocked(DatabaseBlockedReason.Unavailable), verdict?.health)
        assertEquals(">=100MB", verdict?.freeBytesBucket)
    }

    @Test
    fun `a corrupt database with plenty of space is our own failure too`() {
        val verdict = triageDatabaseOpenFailure(
            error = SQLiteDatabaseCorruptException("database disk image is malformed"),
            usableSpaceBytes = 50L * 1024 * 1024,
        )

        assertEquals(DatabaseHealth.Blocked(DatabaseBlockedReason.Unavailable), verdict?.health)
        assertEquals("<100MB", verdict?.freeBytesBucket)
    }

    @Test
    fun `the threshold splits at ten mebibytes`() {
        val justUnder = triageDatabaseOpenFailure(
            SQLiteDiskIOException("disk I/O error"),
            STORAGE_FULL_THRESHOLD_BYTES - 1,
        )
        val exactlyAt = triageDatabaseOpenFailure(
            SQLiteDiskIOException("disk I/O error"),
            STORAGE_FULL_THRESHOLD_BYTES,
        )

        assertEquals(DatabaseBlockedReason.StorageFull, justUnder?.health?.reason)
        assertEquals("<10MB", justUnder?.freeBytesBucket)
        assertEquals(DatabaseBlockedReason.Unavailable, exactlyAt?.health?.reason)
        assertEquals("<100MB", exactlyAt?.freeBytesBucket)
    }

    @Test
    fun `a sqlite failure wrapped by room or coroutines is still recognised`() {
        
        val wrapped = RuntimeException(
            "coroutine failed",
            IllegalStateException("room open", SQLiteDiskIOException("disk I/O error")),
        )

        val verdict = triageDatabaseOpenFailure(wrapped, usableSpaceBytes = 0L)

        assertEquals(DatabaseBlockedReason.StorageFull, verdict?.health?.reason)
    }

    @Test
    fun `a non-database failure is never triaged, no matter how full the disk is`() {
        
        assertNull(triageDatabaseOpenFailure(IllegalStateException("real bug"), usableSpaceBytes = 0L))
    }

    

    @Test
    fun `a storage-full open drives the probe into the blocked state`() = runTest {
        val probe = DatabaseHealthProbe(
            openAndQuery = { throw SQLiteDiskIOException("disk I/O error (code 4874 SQLITE_IOERR_SHMSIZE)") },
            usableSpaceBytes = { 0L },
        )

        assertFalse(probe.awaitHealthy())
        assertEquals(DatabaseHealth.Blocked(DatabaseBlockedReason.StorageFull), probe.health.value)
    }

    @Test
    fun `our own open failure blocks the app as unavailable`() = runTest {
        val probe = DatabaseHealthProbe(
            openAndQuery = { throw SQLiteDatabaseCorruptException("malformed") },
            usableSpaceBytes = { 500L * 1024 * 1024 },
        )

        assertFalse(probe.awaitHealthy())
        assertEquals(DatabaseHealth.Blocked(DatabaseBlockedReason.Unavailable), probe.health.value)
    }

    @Test
    fun `a healthy open runs exactly one query however many callers await it`() = runTest {
        var opens = 0
        val probe = DatabaseHealthProbe(
            openAndQuery = { opens += 1 },
            usableSpaceBytes = { 500L * 1024 * 1024 },
        )

        assertTrue(probe.awaitHealthy())
        assertTrue(probe.awaitHealthy())
        assertTrue(probe.awaitHealthy())

        assertEquals(1, opens)
        assertEquals(DatabaseHealth.Healthy, probe.health.value)
    }

    @Test
    fun `freeing space and retrying unblocks the app`() = runTest {
        var diskFull = true
        val probe = DatabaseHealthProbe(
            openAndQuery = { if (diskFull) throw SQLiteDiskIOException("disk I/O error") },
            usableSpaceBytes = { if (diskFull) 0L else 500L * 1024 * 1024 },
        )

        assertFalse(probe.awaitHealthy())

        
        diskFull = false
        assertEquals(DatabaseHealth.Healthy, probe.retry())
    }

    @Test
    fun `a non-database open failure is rethrown instead of being swallowed as blocked`() = runTest {
        val probe = DatabaseHealthProbe(
            openAndQuery = { throw IllegalStateException("real bug") },
            usableSpaceBytes = { 0L },
        )

        val thrown = runCatching { probe.awaitHealthy() }.exceptionOrNull()

        assertTrue(thrown is IllegalStateException)
        assertEquals(DatabaseHealth.Unknown, probe.health.value)
    }

    

    @Test
    fun `an escaped sqlite failure is absorbed into the blocked state`() {
        val probe = DatabaseHealthProbe(
            openAndQuery = {},
            usableSpaceBytes = { 0L },
        )

        assertTrue(probe.recordEscapedFailure(SQLiteDiskIOException("disk I/O error")))
        assertEquals(DatabaseHealth.Blocked(DatabaseBlockedReason.StorageFull), probe.health.value)
    }

    @Test
    fun `an escaped non-database failure is handed back to the caller untouched`() {
        val probe = DatabaseHealthProbe(
            openAndQuery = {},
            usableSpaceBytes = { 0L },
        )

        assertFalse(probe.recordEscapedFailure(IllegalStateException("real bug")))
        assertEquals(DatabaseHealth.Unknown, probe.health.value)
    }
}
