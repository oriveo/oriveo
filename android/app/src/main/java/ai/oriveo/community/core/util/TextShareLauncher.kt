package ai.oriveo.community.core.util

import android.content.ClipData
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Shares unbounded text through a cache file instead of a Binder-backed Intent extra.
 *
 * Android's activity launch transaction has a process-wide Binder buffer. Conversation exports can
 * exceed it even when the receiving app supports large text, so export-sized payloads must travel as
 * a content URI. Small message shares keep their inline-text behavior for recipient compatibility.
 */
internal object TextShareLauncher {
    private const val CACHE_DIRECTORY = "shared_text"
    private const val MAX_INLINE_TEXT_BYTES = 64 * 1024
    private const val STALE_FILE_AGE_MS = 24 * 60 * 60 * 1000L

    suspend fun shareText(
        context: Context,
        text: String,
        fileName: String,
    ): Result<Unit> = if (shouldShareInline(text)) {
        launch(
            context = context,
            intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
            },
        )
    } else {
        shareTextFile(context, text, fileName, "text/plain")
    }

    suspend fun shareTextFile(
        context: Context,
        text: String,
        fileName: String,
        mimeType: String,
    ): Result<Unit> {
        val shareFile = try {
            withContext(Dispatchers.IO) {
                createShareFile(context.cacheDir, fileName, text)
            }
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (exception: Exception) {
            return Result.failure(exception)
        }

        val shareIntent = try {
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                shareFile,
            )
            Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                clipData = ClipData.newRawUri(shareFile.name, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } catch (exception: Exception) {
            return Result.failure(exception)
        }

        return launch(context, shareIntent)
    }

    internal fun shouldShareInline(text: String): Boolean =
        text.toByteArray(Charsets.UTF_8).size <= MAX_INLINE_TEXT_BYTES

    internal fun createShareFile(
        cacheDir: File,
        requestedFileName: String,
        text: String,
        shareId: String = UUID.randomUUID().toString(),
        nowMillis: Long = System.currentTimeMillis(),
    ): File {
        val root = File(cacheDir, CACHE_DIRECTORY)
        if (!root.isDirectory && !root.mkdirs()) {
            throw IOException("Could not create text share cache directory")
        }
        pruneStaleFiles(root, nowMillis)

        val shareDirectory = File(root, shareId)
        if (!shareDirectory.isDirectory && !shareDirectory.mkdirs()) {
            throw IOException("Could not create text share directory")
        }
        val shareFile = File(shareDirectory, sanitizeFileName(requestedFileName))
        shareFile.writeText(text, Charsets.UTF_8)
        return shareFile
    }

    private suspend fun launch(context: Context, intent: Intent): Result<Unit> = try {
        withContext(Dispatchers.Main.immediate) {
            val chooser = Intent.createChooser(intent, null).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(chooser)
        }
        Result.success(Unit)
    } catch (cancellation: CancellationException) {
        throw cancellation
    } catch (exception: Exception) {
        Result.failure(exception)
    }

    private fun sanitizeFileName(fileName: String): String {
        val sanitized = fileName
            .replace(Regex("""[\\/:*?"<>|\u0000-\u001F]"""), "_")
            .trim()
            .take(120)
        return sanitized.takeUnless { it.isBlank() || it == "." || it == ".." } ?: "Oriveo.txt"
    }

    private fun pruneStaleFiles(root: File, nowMillis: Long) {
        root.listFiles()
            ?.filter { nowMillis - it.lastModified() > STALE_FILE_AGE_MS }
            ?.forEach { stale -> runCatching { stale.deleteRecursively() } }
    }
}
