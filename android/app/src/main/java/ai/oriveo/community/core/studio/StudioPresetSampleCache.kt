package ai.oriveo.community.core.studio

import android.content.Context
import ai.oriveo.community.BuildConfig
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

/**
 * Disk cache for style sample images, keyed by sample.sha256 and stored at `<dir>/<sha256>`
 * (production: `cacheDir/studio-samples/`). A hit returns the stored bytes without network; a
 * miss resolves the URL against the backend base, downloads it, and stores the bytes only when
 * their lowercase-hex SHA-256 equals the key. Concurrent misses for one key share one download
 * that runs in the cache-owned [scope], so cancelling any caller (including the first) does not
 * cancel it for the others; an entry that cannot be read is deleted and fetched again. File IO
 * runs on [Dispatchers.IO].
 */
class StudioPresetSampleCache(
    private val dir: File,
    private val baseUrl: () -> String = ::defaultBaseUrl,
    private val download: suspend (String) -> ByteArray? = fetcherDownload(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    constructor(context: Context) : this(File(context.applicationContext.cacheDir, DIRECTORY_NAME))

    private val inFlight = ConcurrentHashMap<String, Deferred<ByteArray?>>()

    /** Sample bytes, or null when the URL is unresolvable, the download fails or the digest differs. */
    suspend fun data(sample: StudioPresets.Sample): ByteArray? {
        val key = sample.sha256
        if (!KEY_PATTERN.matches(key)) return null
        read(key)?.let { return it }
        val created = scope.async(start = CoroutineStart.LAZY) {
            try {
                read(key) ?: fetch(key, sample.url)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // A failed download is a miss for every caller sharing it; it is not retried here.
                null
            }
        }
        val existing = inFlight.putIfAbsent(key, created)
        if (existing != null) {
            created.cancel()
            return existing.await()
        }
        created.invokeOnCompletion { inFlight.remove(key, created) }
        created.start()
        return created.await()
    }

    /** Deletes every entry whose key is not in [keep], plus temp files left by interrupted writes. */
    suspend fun prune(keep: Set<String>) = withContext(Dispatchers.IO) {
        val staleBefore = System.currentTimeMillis() - STALE_TEMP_MS
        dir.listFiles()?.forEach { file ->
            runCatching {
                when {
                    file.name.startsWith(TEMP_PREFIX) -> if (file.lastModified() < staleBefore) file.delete()
                    file.name !in keep -> file.deleteRecursively()
                }
            }
        }
        Unit
    }

    private suspend fun fetch(key: String, url: String): ByteArray? {
        val resolved = resolveSampleUrl(baseUrl(), url) ?: return null
        val bytes = download(resolved) ?: return null
        if (!verify(bytes, key)) return null
        write(key, bytes)
        return bytes
    }

    private suspend fun read(key: String): ByteArray? = withContext(Dispatchers.IO) {
        val file = File(dir, key)
        if (!file.exists()) return@withContext null
        val bytes = runCatching { file.readBytes() }.getOrNull()?.takeIf { it.isNotEmpty() }
        if (bytes == null) runCatching { file.deleteRecursively() }
        bytes
    }

    private suspend fun write(key: String, bytes: ByteArray) = withContext(Dispatchers.IO) {
        runCatching {
            if (!dir.isDirectory && !dir.mkdirs()) return@runCatching
            val target = File(dir, key)
            val temp = File.createTempFile(TEMP_PREFIX, null, dir)
            try {
                temp.writeBytes(bytes)
                if (!temp.renameTo(target)) {
                    target.deleteRecursively()
                    temp.renameTo(target)
                }
            } finally {
                if (temp.exists()) temp.delete()
            }
        }
        Unit
    }

    companion object {
        /** Mirrors studio_presets.v1 clientCases.sampleCache.policy.maxBytes. */
        const val MAX_BYTES = 2_097_152L
        const val DIRECTORY_NAME = "studio-samples"
        private const val TEMP_PREFIX = ".tmp-"
        private const val STALE_TEMP_MS = 60 * 60 * 1000L
        private const val HTTPS_PREFIX = "https://"
        private const val HTTP_PREFIX = "http://"
        private const val HOST_TERMINATORS = "/?#\\"
        private val KEY_PATTERN = Regex("^[0-9a-f]{64}$")

        /**
         * Absolute lowercase `https://host…` URLs are kept verbatim; `/path` joins a base that is an
         * `http(s)://host…` URL, with its trailing slashes trimmed. Everything else (other schemes,
         * `//host`, bare relative, a missing host, a base without scheme or host) is null.
         */
        fun resolveSampleUrl(base: String, url: String): String? {
            if (url.startsWith(HTTPS_PREFIX)) return url.takeIf { hasHost(it, HTTPS_PREFIX) }
            if (!url.startsWith("/") || url.startsWith("//")) return null
            if (!hasHost(base, HTTPS_PREFIX) && !hasHost(base, HTTP_PREFIX)) return null
            return base.trimEnd('/') + url
        }

        /** True when [value] starts with [prefix] and the first character after it begins a host. */
        private fun hasHost(value: String, prefix: String): Boolean {
            if (!value.startsWith(prefix)) return false
            val first = value.getOrNull(prefix.length) ?: return false
            return first !in HOST_TERMINATORS
        }

        /** True when the lowercase-hex SHA-256 of [bytes] equals [sha256]. */
        fun verify(bytes: ByteArray, sha256: String): Boolean =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) } == sha256

        private fun defaultBaseUrl(): String = BuildConfig.METADATA_BASE_URL.ifBlank { "http://10.0.2.2:8080" }

        /** Production downloader: [StudioImageFetcher] capped at [MAX_BYTES]; only decodable images yield bytes. */
        private fun fetcherDownload(): suspend (String) -> ByteArray? {
            val fetcher by lazy { StudioImageFetcher(OkHttpClient(), MAX_BYTES) }
            return { url -> (fetcher.fetch(url) as? StudioImageResponse.Outcome.Ok)?.image?.bytes }
        }
    }
}
