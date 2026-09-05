package ai.oriveo.community.core.data.database

import android.database.sqlite.SQLiteException
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Free-space threshold used to tell the two blocked reasons apart: below it, a failure to open the
 * database is read as "the device is out of space"; above it, as a local fault.
 */
const val STORAGE_FULL_THRESHOLD_BYTES = 10L * 1024 * 1024

private const val TAG = "DatabaseHealthProbe"
private const val MAX_CAUSE_CHAIN_DEPTH = 6

/** Three-state view of the on-device database. The UI only cares whether it is [Blocked]. */
sealed interface DatabaseHealth {
    /**
     * No verdict yet.
     *
     * The first frame deliberately stays here: it renders the nav host without waiting for the
     * probe, which keeps the preferences-first cold start intact. The blocked screen only
     * replaces it once the probe has an answer.
     */
    data object Unknown : DatabaseHealth

    data object Healthy : DatabaseHealth

    data class Blocked(val reason: DatabaseBlockedReason) : DatabaseHealth
}

enum class DatabaseBlockedReason {
    /** The device is out of space. The user can fix this themselves, so the screen says so. */
    StorageFull,

    /** Space is fine and it still will not open: corruption, a failed migration, permissions. */
    Unavailable,
}

/** Verdict for a single failed open: what the UI should show, and how much room was left. */
data class DatabaseProbeVerdict(
    val health: DatabaseHealth.Blocked,
    val freeBytesBucket: String,
)

/**
 * Classifies a failure to open the database.
 *
 * SQLite reports a full disk under several extended result codes, and the framework maps them to
 * different exception types, so the exception class alone cannot decide. The reliable signal is
 * the pair: a SQLite failure anywhere in the cause chain plus `filesDir.usableSpace` below
 * [STORAGE_FULL_THRESHOLD_BYTES].
 *
 * @return null when this is not a database failure at all, in which case the caller must rethrow:
 *         swallowing it would hide a real defect.
 */
internal fun triageDatabaseOpenFailure(
    error: Throwable,
    usableSpaceBytes: Long,
): DatabaseProbeVerdict? {
    if (error is CancellationException) return null
    if (!error.hasSqliteFailureInCauseChain()) return null
    val bucket = freeBytesBucket(usableSpaceBytes)
    return if (usableSpaceBytes < STORAGE_FULL_THRESHOLD_BYTES) {
        DatabaseProbeVerdict(
            health = DatabaseHealth.Blocked(DatabaseBlockedReason.StorageFull),
            freeBytesBucket = bucket,
        )
    } else {
        DatabaseProbeVerdict(
            health = DatabaseHealth.Blocked(DatabaseBlockedReason.Unavailable),
            freeBytesBucket = bucket,
        )
    }
}

/**
 * Whether a `SQLiteException` appears anywhere in the cause chain.
 *
 * The chain has to be walked: Room and the coroutine machinery both wrap the original exception
 * before it reaches a handler, so only inspecting the outermost throwable misses most real cases.
 */
private fun Throwable.hasSqliteFailureInCauseChain(): Boolean {
    var node: Throwable? = this
    var remainingDepth = MAX_CAUSE_CHAIN_DEPTH
    while (node != null && remainingDepth > 0) {
        if (node is SQLiteException) return true
        remainingDepth -= 1
        node = node.cause?.takeIf { it !== node }
    }
    return false
}

/** Buckets rather than exact bytes: the exact figure is device-identifying and adds nothing. */
internal fun freeBytesBucket(usableSpaceBytes: Long): String = when {
    usableSpaceBytes <= 0L -> "0"
    usableSpaceBytes < STORAGE_FULL_THRESHOLD_BYTES -> "<10MB"
    usableSpaceBytes < 100L * 1024 * 1024 -> "<100MB"
    else -> ">=100MB"
}

/**
 * Answers one question before any other code touches storage: can this device open its database?
 *
 * When free space hits zero, opening the database always runs `PRAGMA journal_mode`, WAL has to
 * create or grow the `-shm` file, `ftruncate` fails, and the framework throws
 * `SQLiteDiskIOException`. That exception then escapes from whichever startup path happened to
 * touch Room first, and because those paths run outside any handler, the app dies on every cold
 * start. The user is left unable to open the app, and therefore unable to free space from inside
 * it.
 *
 * So the probe runs the very first SQL statement in the process (one cheap open plus `SELECT 1`)
 * and collapses the answer into a three-state value that startup code can await and the UI can
 * observe:
 * - [DatabaseHealth.Unknown]: still running; the first frame renders as usual.
 * - [DatabaseHealth.Healthy]: startup database work proceeds.
 * - [DatabaseHealth.Blocked]: the UI shows a blocking screen and startup database work is skipped.
 *
 * Deliberately not done: no process-wide `Thread.setDefaultUncaughtExceptionHandler`, and no
 * catch-all wrapper. The only two entry points are [awaitHealthy] (an explicit gate) and
 * [recordEscapedFailure] (scope-level containment), and the latter only accepts `SQLiteException`
 * so every other failure still crashes the way it should.
 *
 * @param openAndQuery in production, opens the writable database and runs one `SELECT 1`. It is a
 *                     parameter so tests can inject a failure without filling a real disk.
 * @param usableSpaceBytes in production, `context.filesDir.usableSpace`.
 */
class DatabaseHealthProbe(
    private val openAndQuery: () -> Unit,
    private val usableSpaceBytes: () -> Long,
) {
    private val _health = MutableStateFlow<DatabaseHealth>(DatabaseHealth.Unknown)
    val health: StateFlow<DatabaseHealth> = _health.asStateFlow()

    /** Serialises probing so that many startup tasks awaiting at once still run one statement. */
    private val probeMutex = Mutex()

    /**
     * The gate every startup database consumer goes through: probes once, then reuses the verdict.
     *
     * @return true when the database is usable; false when the UI has switched to the blocked
     *         screen and the caller should skip its work.
     */
    suspend fun awaitHealthy(): Boolean = ensureProbed() == DatabaseHealth.Healthy

    /** Re-probes from the blocked screen after the user has freed some space. */
    suspend fun retry(): DatabaseHealth = probeMutex.withLock { probeLocked() }

    /**
     * Containment for a failure that escaped a coroutine scope, so it does not become fatal.
     *
     * @return true when the failure was a database failure and has been recorded; false when it
     *         was something else, in which case the caller must let it reach the default handler.
     */
    fun recordEscapedFailure(error: Throwable): Boolean {
        val verdict = triageDatabaseOpenFailure(error, usableSpaceBytes()) ?: return false
        applyBlocked(verdict, error)
        return true
    }

    private suspend fun ensureProbed(): DatabaseHealth {
        _health.value.let { if (it != DatabaseHealth.Unknown) return it }
        return probeMutex.withLock {
            val current = _health.value
            if (current != DatabaseHealth.Unknown) current else probeLocked()
        }
    }

    private suspend fun probeLocked(): DatabaseHealth {
        val failure = try {
            withContext(Dispatchers.IO) { openAndQuery() }
            null
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Throwable) {
            error
        }
        if (failure == null) {
            markHealthy()
            return DatabaseHealth.Healthy
        }
        
        val verdict = triageDatabaseOpenFailure(failure, usableSpaceBytes()) ?: throw failure
        applyBlocked(verdict, failure)
        return verdict.health
    }

    @Synchronized
    private fun markHealthy() {
        _health.value = DatabaseHealth.Healthy
    }

    @Synchronized
    private fun applyBlocked(verdict: DatabaseProbeVerdict, error: Throwable) {
        val previous = _health.value
        _health.value = verdict.health
        // Only log the transition, not every repeated failure behind the same blocked screen.
        if (previous is DatabaseHealth.Blocked) return
        Log.w(TAG, "database blocked: ${verdict.health.reason} (${verdict.freeBytesBucket})", error)
    }
}
