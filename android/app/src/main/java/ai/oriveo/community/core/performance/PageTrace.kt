package ai.oriveo.community.core.performance

import android.util.Log
import java.util.concurrent.ConcurrentHashMap

object PageTrace {
    private const val TAG = "PageTrace"
    private val starts = ConcurrentHashMap<String, Long>()

    internal fun resetForTesting() {
        starts.clear()
    }

    internal fun activeTraceCountForTesting(): Int = starts.size

    fun begin(page: String) {
        starts[page] = System.nanoTime()
    }

    fun end(page: String, detail: String = "") {
        val start = starts.remove(page) ?: return
        val ms = (System.nanoTime() - start) / 1_000_000
        val flag = when {
            ms > 500 -> "🔴"
            ms > 100 -> "🟡"
            else -> "🟢"
        }
        val d = if (detail.isEmpty()) "" else " | $detail"
        runCatching {
            Log.d(TAG, "[PAGE] $flag $page ${ms}ms$d")
        }
    }
}
