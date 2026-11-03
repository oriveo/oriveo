package ai.oriveo.community.core.data.database

import android.database.sqlite.SQLiteTransactionListener
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import ai.oriveo.community.core.observability.Observability
import kotlinx.coroutines.asContextElement
import kotlinx.coroutines.withContext

/** Only write transactions that reach this duration are recorded as `db.long_write_ms` (fixture metrics); short writes do not take up metric volume. */
internal const val LONG_WRITE_THRESHOLD_MS = 500L

internal const val LONG_WRITE_METRIC = "db.long_write_ms"
internal const val WRITE_LABEL_TAG = "db.write_label"
internal const val UNLABELED_WRITE = "unlabeled"

/**
 * Caller label for a write transaction (fixture `heavy_write_labels`). The transaction starts on Room's transaction thread, so the label
 * lives in a thread-local and travels with the coroutine across dispatchers through a coroutine-context element ([withDatabaseWriteLabel]).
 */
object DatabaseWriteLabel {
    internal val current = ThreadLocal<String?>()

    fun currentOrUnlabeled(): String = current.get() ?: UNLABELED_WRITE
}

/** Labels the write transactions opened inside [block]. Room `withTransaction` inherits the coroutine context, so the label lands on the transaction thread. */
suspend fun <T> withDatabaseWriteLabel(label: String, block: suspend () -> T): T =
    withContext(DatabaseWriteLabel.current.asContextElement(label)) { block() }

/**
 * Write-transaction timer (nesting depth counted per thread; only the outermost transaction is timed). SupportSQLite transactions are bound to a thread: begin and end of the same transaction always run on the same thread.
 * It only times and never touches SQL; the cost per call is two nanoTime reads plus one ThreadLocal read.
 */
internal class WriteTransactionTimer(
    private val nanoTime: () -> Long = System::nanoTime,
    private val currentLabel: () -> String = DatabaseWriteLabel::currentOrUnlabeled,
    private val report: (durationMs: Double, label: String) -> Unit = { ms, label ->
        Observability.sink.distribution(LONG_WRITE_METRIC, ms, "millisecond", mapOf(WRITE_LABEL_TAG to label))
    },
) {
    private class Frame(val write: Boolean, val startedAt: Long, val label: String) {
        var depth = 1
    }

    private val frame = ThreadLocal<Frame?>()

    fun begin(write: Boolean) {
        val active = frame.get()
        if (active != null) {
            active.depth++
            return
        }
        frame.set(Frame(write, nanoTime(), if (write) currentLabel() else ""))
    }

    fun end() {
        val active = frame.get() ?: return
        if (--active.depth > 0) return
        frame.set(null)
        if (!active.write) return
        val ms = (nanoTime() - active.startedAt) / 1_000_000.0
        if (ms >= LONG_WRITE_THRESHOLD_MS) report(ms, active.label)
    }
}

/**
 * Wraps the [SupportSQLiteOpenHelper.Factory]: only the transaction begin / end are intercepted (Room's withTransaction and DAO transactions
 * both land on these methods; verified against room-runtime 2.8.4 PassthroughConnection -> sqlite-framework 2.6.2
 * SupportSQLiteStatement.TransactionSQLiteStatement). Read-only transactions (DEFERRED -> beginTransactionReadOnly) are not counted.
 */
internal class TimedWriteOpenHelperFactory(
    private val delegate: SupportSQLiteOpenHelper.Factory,
    private val timer: WriteTransactionTimer = WriteTransactionTimer(),
) : SupportSQLiteOpenHelper.Factory {
    override fun create(configuration: SupportSQLiteOpenHelper.Configuration): SupportSQLiteOpenHelper =
        TimedOpenHelper(delegate.create(configuration), timer)
}

private class TimedOpenHelper(
    private val delegate: SupportSQLiteOpenHelper,
    private val timer: WriteTransactionTimer,
) : SupportSQLiteOpenHelper by delegate {
    // The underlying helper returns the same database object on every call (the framework SQLiteOpenHelper caches it), so the wrapper is cached by reference rather than newly created each time.
    @Volatile
    private var wrapped: Pair<SupportSQLiteDatabase, SupportSQLiteDatabase>? = null

    override val writableDatabase: SupportSQLiteDatabase get() = wrap(delegate.writableDatabase)
    override val readableDatabase: SupportSQLiteDatabase get() = wrap(delegate.readableDatabase)

    private fun wrap(db: SupportSQLiteDatabase): SupportSQLiteDatabase {
        wrapped?.let { (raw, timed) -> if (raw === db) return timed }
        val timed = TimedWriteDatabase(db, timer)
        wrapped = db to timed
        return timed
    }
}

internal class TimedWriteDatabase(
    private val delegate: SupportSQLiteDatabase,
    private val timer: WriteTransactionTimer,
) : SupportSQLiteDatabase by delegate {
    override fun beginTransaction() {
        delegate.beginTransaction()
        timer.begin(write = true)
    }

    override fun beginTransactionNonExclusive() {
        delegate.beginTransactionNonExclusive()
        timer.begin(write = true)
    }

    override fun beginTransactionReadOnly() {
        delegate.beginTransactionReadOnly()
        timer.begin(write = false)
    }

    override fun beginTransactionWithListener(transactionListener: SQLiteTransactionListener) {
        delegate.beginTransactionWithListener(transactionListener)
        timer.begin(write = true)
    }

    override fun beginTransactionWithListenerNonExclusive(transactionListener: SQLiteTransactionListener) {
        delegate.beginTransactionWithListenerNonExclusive(transactionListener)
        timer.begin(write = true)
    }

    override fun beginTransactionWithListenerReadOnly(transactionListener: SQLiteTransactionListener) {
        delegate.beginTransactionWithListenerReadOnly(transactionListener)
        timer.begin(write = false)
    }

    // Kotlin's `by` does not forward Java default methods (they fall back to the interface default), so methods the framework implementation overrides must be forwarded explicitly.
    override val isExecPerConnectionSQLSupported: Boolean get() = delegate.isExecPerConnectionSQLSupported

    override fun execPerConnectionSQL(sql: String, bindArgs: Array<out Any?>?) =
        delegate.execPerConnectionSQL(sql, bindArgs)

    override fun endTransaction() {
        try {
            delegate.endTransaction()
        } finally {
            timer.end()
        }
    }
}
