package ai.oriveo.community.core.storage

import android.content.Context
import java.io.File

/**
 * Pure path concatenation for the app-private directories. Does not call [Context.getCacheDir] / [Context.getFilesDir],
 * which touch disk (exists / mkdirs) on every call. DI can take the paths while constructing singletons on the main thread;
 * callers create the directories before the first write.
 * Under regular credential-encrypted storage this matches the cacheDir / filesDir the system returns.
 */
object AppStoragePaths {
    fun cacheDir(context: Context): File = File(context.applicationInfo.dataDir, "cache")

    fun filesDir(context: Context): File = File(context.applicationInfo.dataDir, "files")
}
