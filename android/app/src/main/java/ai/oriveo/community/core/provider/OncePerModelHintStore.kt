package ai.oriveo.community.core.provider

import android.content.Context
import androidx.annotation.WorkerThread
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Shared ledger for "once per device per model" hints: recorded by `provider|model` as an ordered list (the oldest is dropped past the limit).
 * [ModelRetiredHintStore] and [ai.oriveo.community.core.capability.InputCapabilityHintStore] are just thin wrappers with their own prefs names.
 *
 * [consume] reads SharedPreferences first (the first read waits for disk loading), so call it on a background thread only; main-thread contexts use [consumeOffMain].
 */
open class OncePerModelHintStore(
    private val readPayload: () -> String?,
    private val writePayload: (String?) -> Unit,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    @WorkerThread
    fun hasShown(providerID: String, modelID: String): Boolean = entryKey(providerID, modelID) in entries()

    /** Records the hint once if not shown before and returns true; returns false if already shown (or the model id is empty). */
    @WorkerThread
    fun consume(providerID: String, modelID: String): Boolean {
        if (modelID.isEmpty()) return false
        val key = entryKey(providerID, modelID)
        synchronized(this) {
            val current = entries()
            if (key in current) return false
            // An ordered list rather than a StringSet: drops the oldest when over the limit.
            val next = (current + key).let { if (it.size > MAX_ENTRY_COUNT) it.takeLast(MAX_ENTRY_COUNT) else it }
            writePayload(next.joinToString(SEPARATOR))
            return true
        }
    }

    /** Same as [consume], with reads and writes moved to the IO thread, for main-thread coroutines. */
    suspend fun consumeOffMain(providerID: String, modelID: String): Boolean {
        if (modelID.isEmpty()) return false
        return withContext(ioDispatcher) { consume(providerID, modelID) }
    }

    fun reset() = synchronized(this) { writePayload(null) }

    private fun entries(): List<String> =
        readPayload()?.split(SEPARATOR)?.filter(String::isNotEmpty).orEmpty()

    private fun entryKey(providerID: String, modelID: String): String = "$providerID|$modelID"

    /** SharedPreferences read/write pair; the prefs handle is fetched lazily and the constructor does not touch disk. */
    class PrefsPayload(context: Context, prefsName: String) {
        private val appContext = context.applicationContext
        private val prefs by lazy { appContext.getSharedPreferences(prefsName, Context.MODE_PRIVATE) }
        val read: () -> String? = { prefs.getString(KEY_PAYLOAD, null) }
        val write: (String?) -> Unit = { payload -> prefs.edit().putString(KEY_PAYLOAD, payload).apply() }
    }

    companion object {
        private const val KEY_PAYLOAD = "entries"
        private const val SEPARATOR = "\n"
        const val MAX_ENTRY_COUNT = 300
    }
}
