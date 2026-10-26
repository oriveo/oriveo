package ai.oriveo.community.core.voice

import io.ktor.client.HttpClient
import io.ktor.client.plugins.expectSuccess
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/** Three voice catalog states: the server explicitly has none (404) / fetch failed with no usable cache / available. */
sealed interface VoiceCatalogState {
    data object Unavailable : VoiceCatalogState
    data object LoadFailed : VoiceCatalogState
    data class Available(val catalog: VoiceCatalog) : VoiceCatalogState
}

/**
 * Fetches and caches `GET /api/metadata?view=voice`.
 * The cache is [cacheDir]/catalog.json (ETag + data), not per account; the production directory is `filesDir/voice/`,
 * baseUrl is passed by the caller (production: BuildConfig.METADATA_BASE_URL).
 * 404 = the server has no voice catalog -> delete the cache; 5xx / network error / bad envelope -> keep the previous cache.
 * [state] publishes the latest conclusion (null = no conclusion yet) so the settings page can follow refreshes.
 */
class VoiceCatalogClient(
    private val httpClient: HttpClient,
    baseUrl: String,
    private val cacheDir: File,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val baseUrl = baseUrl.trimEnd('/')
    private val mutex = Mutex()
    private val freshMutex = Mutex()
    private val cacheFile: File get() = File(cacheDir, CACHE_FILE_NAME)

    private val _state = MutableStateFlow<VoiceCatalogState?>(null)
    val state: StateFlow<VoiceCatalogState?> = _state.asStateFlow()

    @Volatile
    private var lastRefreshAt: Long? = null

    /** Cold-reads the cache; returns null when missing or corrupt. Publishes Available when read (does not override an existing refresh conclusion). */
    suspend fun loadCached(): VoiceCatalog? = mutex.withLock {
        val catalog = readCache()?.let { VoiceCatalogDecoder.decode(it.data) }
        if (catalog != null && lastRefreshAt == null) {
            _state.value = VoiceCatalogState.Available(catalog)
        }
        catalog
    }

    /** Only sends a request when state is null or at least 10 minutes since the last refresh; concurrent calls send it once. */
    suspend fun ensureFresh(): VoiceCatalogState? = freshMutex.withLock {
        val last = lastRefreshAt
        val stale = _state.value == null || last == null || clock() - last >= STALE_AFTER_MS
        if (stale) refresh() else _state.value
    }

    suspend fun refresh(): VoiceCatalogState = mutex.withLock {
        fetch().also {
            lastRefreshAt = clock()
            _state.value = it
        }
    }

    private suspend fun fetch(): VoiceCatalogState {
        val cached = readCache()
        val fallback: VoiceCatalogState = cached
            ?.let { VoiceCatalogState.Available(VoiceCatalogDecoder.decode(it.data)) }
            ?: VoiceCatalogState.LoadFailed

        val response = try {
            httpClient.get("$baseUrl$PATH") {
                expectSuccess = false
                header(HttpHeaders.Accept, "application/json")
                cached?.eTag?.let { header(HttpHeaders.IfNoneMatch, it) }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return fallback
        }

        return when (response.status.value) {
            200 -> {
                val body = try {
                    response.bodyAsText()
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    return fallback
                }
                val data = decodeVoiceData(body) ?: return fallback
                val eTag = response.headers[HttpHeaders.ETag]?.trim()?.takeIf { it.isNotEmpty() }
                writeCache(CacheEntry(eTag, data))
                VoiceCatalogState.Available(VoiceCatalogDecoder.decode(data))
            }
            304 -> fallback
            404 -> {
                deleteCache()
                VoiceCatalogState.Unavailable
            }
            else -> fallback
        }
    }

    /** Envelope `{code: 0, data: {view: "voice", ...}}`; any mismatch counts as failure. */
    private fun decodeVoiceData(body: String): JsonObject? {
        val root = runCatching { json.parseToJsonElement(body) }.getOrNull() as? JsonObject ?: return null
        val code = (root["code"] as? JsonPrimitive)?.intOrNull
        if (code != 0) return null
        val data = root["data"] as? JsonObject ?: return null
        val view = (data["view"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        return data.takeIf { view == VIEW }
    }

    private data class CacheEntry(val eTag: String?, val data: JsonObject)

    private suspend fun readCache(): CacheEntry? = withContext(Dispatchers.IO) {
        val file = cacheFile
        if (!file.isFile) return@withContext null
        val root = runCatching { json.parseToJsonElement(file.readText()) }.getOrNull() as? JsonObject
            ?: return@withContext null
        val data = root[KEY_DATA] as? JsonObject ?: return@withContext null
        if ((data["view"] as? JsonPrimitive)?.contentOrNull != VIEW) return@withContext null
        val eTag = (root[KEY_ETAG] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        CacheEntry(eTag, data)
    }

    private suspend fun writeCache(entry: CacheEntry) = withContext(Dispatchers.IO) {
        runCatching {
            cacheDir.mkdirs()
            val payload = buildJsonObject {
                put(KEY_ETAG, entry.eTag)
                put(KEY_DATA, entry.data as JsonElement)
            }
            // Write a temp file then rename, so a process killed midway never leaves a half-written cache.
            val tmp = File(cacheDir, "$CACHE_FILE_NAME.tmp")
            tmp.writeText(json.encodeToString(JsonElement.serializer(), payload))
            if (!tmp.renameTo(cacheFile)) {
                cacheFile.delete()
                tmp.renameTo(cacheFile)
            }
        }
    }

    private suspend fun deleteCache() = withContext(Dispatchers.IO) {
        cacheFile.delete()
    }

    companion object {
        const val CACHE_FILE_NAME = "catalog.json"
        const val STALE_AFTER_MS = 10 * 60 * 1000L
        private const val PATH = "/api/metadata?view=voice"
        private const val VIEW = "voice"
        private const val KEY_ETAG = "etag"
        private const val KEY_DATA = "data"
        private val json = Json { ignoreUnknownKeys = true }
    }
}
