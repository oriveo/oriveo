package ai.oriveo.community.core.voice

import ai.oriveo.community.core.mcp.mcpSha256Hex
import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Cache key for a piece of cloud speech audio; [effectiveSpeed] is the effective speaking rate (kept to two decimals in the key). */
data class SpeechCacheKey(
    val text: String,
    val providerKind: ProviderKind,
    val model: String,
    val voice: String?,
    val effectiveSpeed: Double,
    val language: String,
    val outputFormat: String,
) {
    /** File name = sha256hex(text digest, provider, model, voice, speed, language joined by newlines) + "." + format. */
    val fileName: String
        get() {
            val parts = listOf(
                mcpSha256Hex(text),
                providerKind.rawValue,
                model,
                voice.orEmpty(),
                String.format(Locale.ROOT, "%.2f", effectiveSpeed),
                language,
            )
            return mcpSha256Hex(parts.joinToString("\n")) + "." + outputFormat
        }
}

/**
 * Disk cache for speech audio: a hit refreshes mtime; writes go to a temp file first and are then renamed, and after a write the oldest entries by mtime are deleted until the total is within [maxBytes].
 * Any read or write error is treated as a miss. The production directory is `cacheDir/voice-tts/`.
 */
class SpeechAudioCache(
    private val dir: File,
    private val maxBytes: Long = DEFAULT_MAX_BYTES,
    private val now: () -> Long = System::currentTimeMillis,
) {
    suspend fun read(key: SpeechCacheKey): File? = withContext(Dispatchers.IO) {
        runCatching {
            val file = File(dir, key.fileName)
            if (!file.isFile || file.length() <= 0L) return@runCatching null
            file.setLastModified(now())
            file
        }.getOrNull()
    }

    suspend fun write(key: SpeechCacheKey, bytes: ByteArray): File? = withContext(Dispatchers.IO) {
        if (bytes.isEmpty() || bytes.size.toLong() > maxBytes) return@withContext null
        runCatching {
            if (!dir.isDirectory && !dir.mkdirs()) return@runCatching null
            val target = File(dir, key.fileName)
            val temp = File.createTempFile(TEMP_PREFIX, null, dir)
            try {
                temp.writeBytes(bytes)
                if (!temp.renameTo(target)) {
                    target.delete()
                    if (!temp.renameTo(target)) return@runCatching null
                }
            } finally {
                if (temp.exists()) temp.delete()
            }
            target.setLastModified(now())
            trim(keep = target)
            target.takeIf { it.isFile }
        }.getOrNull()
    }

    /**
     * Creates a temporary audio file under the cache directory that is not part of the cache (`voice-tts-*`); the caller deletes it when done, and any left behind by a killed process are cleaned up by [trim].
     * May throw an IO exception.
     */
    fun createAudioTempFile(suffix: String): File {
        if (!dir.isDirectory) dir.mkdirs()
        return File.createTempFile(AUDIO_TEMP_PREFIX, suffix, dir)
    }

    /**
     * First deletes `.tmp-*` / `voice-tts-*` files whose mtime is older than [STALE_TEMP_MS] (leftovers from a killed process),
     * then deletes cache entries oldest-first by mtime until the total is within the limit; the entry just written is kept, and temp files are neither counted nor deleted by the limit.
     */
    private fun trim(keep: File) {
        val all = dir.listFiles()?.filter { it.isFile } ?: return
        val (temps, files) = all.partition { isTemp(it) }
        val staleBefore = now() - STALE_TEMP_MS
        temps.filter { it.lastModified() < staleBefore }.forEach { it.delete() }
        var total = files.sumOf { it.length() }
        if (total <= maxBytes) return
        for (file in files.filter { it != keep }.sortedBy { it.lastModified() }) {
            if (total <= maxBytes) break
            val size = file.length()
            if (file.delete()) total -= size
        }
    }

    companion object {
        const val DEFAULT_MAX_BYTES = 52_428_800L
        const val DIRECTORY_NAME = "voice-tts"
        private const val TEMP_PREFIX = ".tmp-"
        private const val AUDIO_TEMP_PREFIX = "voice-tts-"
        private const val STALE_TEMP_MS = 60 * 60 * 1000L

        private fun isTemp(file: File): Boolean =
            file.name.startsWith(TEMP_PREFIX) || file.name.startsWith(AUDIO_TEMP_PREFIX)
    }
}
