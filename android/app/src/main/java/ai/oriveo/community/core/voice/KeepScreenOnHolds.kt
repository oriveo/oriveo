package ai.oriveo.community.core.voice

import android.view.View
import java.util.WeakHashMap

/**
 * Per-target keep-screen-on hold count shared by dictation recording and read aloud (V-AD contract rule 1).
 * The first hold remembers the target's original value and turns keep-screen-on on; the value is restored
 * only when the last hold ends. Acquire / release are idempotent per holder. Main thread only, no timers.
 */
class KeepScreenOnHolds<T : Any>(
    private val read: (T) -> Boolean,
    private val write: (T, Boolean) -> Unit,
) {
    private class Entry(val original: Boolean) {
        val holders = mutableSetOf<Any>()
    }

    private val entries = WeakHashMap<T, Entry>()

    fun acquire(target: T, holder: Any) {
        val entry = entries.getOrPut(target) { Entry(read(target)) }
        if (!entry.holders.add(holder)) return
        if (!read(target)) write(target, true)
    }

    fun release(target: T, holder: Any) {
        val entry = entries[target] ?: return
        if (!entry.holders.remove(holder)) return
        if (entry.holders.isEmpty()) {
            entries.remove(target)
            if (read(target) != entry.original) write(target, entry.original)
        }
    }

    companion object {
        /** Process-wide holds on [View.setKeepScreenOn]; read and written on the main thread only. */
        val views: KeepScreenOnHolds<View> by lazy {
            KeepScreenOnHolds(read = { it.keepScreenOn }, write = { view, on -> view.keepScreenOn = on })
        }
    }
}
