package ai.oriveo.community.core.storage

import android.content.Context
import java.io.File

/**
 * Cold-start background prewarm: loads every *.xml under shared_prefs into the in-process cache.
 *
 * The system loads each SharedPreferences name only once per process. Reading it in the background first means the
 * main thread's first read hits memory and no longer triggers StrictMode DiskRead. Read-only; non-xml files such as *.bak
 * are skipped (the system handles .bak files itself when loading).
 * Must be called on a background thread.
 */
object SharedPreferencesPrewarmer {
    private const val PREFS_SUFFIX = ".xml"

    /** Returns the prewarmed prefs names (without the .xml suffix), sorted by file name. */
    fun prewarm(context: Context): List<String> {
        val app = context.applicationContext
        val dir = File(app.applicationInfo.dataDir, "shared_prefs")
        val names = dir.listFiles()
            ?.asSequence()
            ?.filter { it.isFile && it.name.endsWith(PREFS_SUFFIX) }
            ?.map { it.name.removeSuffix(PREFS_SUFFIX) }
            ?.filter { it.isNotEmpty() }
            ?.sorted()
            ?.toList()
            .orEmpty()
        for (name in names) {
            // .all waits for loading to finish, so the data is in memory when this returns
            app.getSharedPreferences(name, Context.MODE_PRIVATE).all
        }
        return names
    }
}
