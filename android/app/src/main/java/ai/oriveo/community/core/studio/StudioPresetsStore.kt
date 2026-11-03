package ai.oriveo.community.core.studio

import android.content.Context
import ai.oriveo.community.BuildConfig
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * Local store of studio_presets.v1: the last replaced Server body plus its cache record
 * (locale, revision, etag, checkedAtMs) in one file, `noBackupFilesDir/studio/presets.json`
 * shaped `{cache, body}`, falling back to the bundled offline snapshot.
 * Refresh decisions come from [StudioPresets.planRefresh] / [StudioPresets.applyResponse]:
 * replaced persists body + cache, not_modified / unchanged only checkedAtMs, failed / invalid
 * write nothing. A persisted body that is missing or no longer decodes counts as no cache
 * (fetch at once, no If-None-Match). At most one request is in flight per store; concurrent
 * callers for the same locale share its outcome. Not wired to any entry point yet.
 */
class StudioPresetsStore private constructor(
    fileProvider: () -> File,
    /** `GET {base}/api/studio/presets?locale={tag}`; may throw IOException (treated as status 0). */
    private val transport: suspend (locale: String, ifNoneMatch: String?) -> StudioPresets.Response,
    private val snapshot: () -> String?,
    private val clock: () -> Long,
) {
    internal constructor(
        file: File,
        transport: suspend (locale: String, ifNoneMatch: String?) -> StudioPresets.Response,
        snapshot: () -> String?,
        clock: () -> Long,
    ) : this({ file }, transport, snapshot, clock)

    constructor(context: Context) : this(
        fileProvider = context.applicationContext.let { app -> { File(app.noBackupFilesDir, FILE_PATH) } },
        transport = HttpStudioPresetsTransport { BuildConfig.METADATA_BASE_URL.ifBlank { "http://10.0.2.2:8080" } }::fetch,
        snapshot = StudioPresets.assetReader(context.applicationContext),
        clock = System::currentTimeMillis,
    )

    private class Stored(val cache: StudioPresets.Cache, val body: String)

    // Construction never touches disk; the file is resolved and read on first use.
    private val file: File by lazy(LazyThreadSafetyMode.PUBLICATION, fileProvider)

    private val lock = Any()
    private var loaded = false
    private var stored: Stored? = null

    /** Decode result of the last body seen, keyed by that body. */
    private var bodyMemo: Pair<String, StudioPresets.DecodeResult>? = null
    private var snapshotLoaded = false
    private var snapshotText: String? = null
    private val offlineMemo = HashMap<String, StudioPresets.Presets>()

    /** Serialises refreshes so at most one request is in flight. */
    private val refreshMutex = Mutex()
    private val inFlight = HashMap<String, CompletableDeferred<StudioPresets.Outcome>>()

    /**
     * Cached body when the cache belongs to [locale] and still decodes, otherwise the offline
     * snapshot for [locale]; null only when the snapshot itself is unreadable.
     */
    suspend fun current(locale: String): StudioPresets.Presets? = withContext(Dispatchers.IO) {
        val s = loadStored()
        if (s != null && s.cache.locale == locale) {
            val cached = decodeBody(s.body) as? StudioPresets.DecodeResult.Success
            if (cached != null) return@withContext cached.presets
        }
        offline(locale)
    }

    /**
     * Fetches at most every 6 hours per locale; returns [StudioPresets.Outcome.THROTTLED] when it
     * did not fetch. A call arriving while the same locale is in flight awaits that outcome.
     */
    suspend fun refreshIfNeeded(locale: String, nowMs: Long = clock()): StudioPresets.Outcome {
        while (true) {
            val (deferred, owner) = synchronized(lock) {
                val running = inFlight[locale]
                if (running != null) {
                    running to false
                } else {
                    CompletableDeferred<StudioPresets.Outcome>().also { inFlight[locale] = it } to true
                }
            }
            if (!owner) {
                try {
                    return deferred.await()
                } catch (e: CancellationException) {
                    // The owning caller was cancelled; retry unless this caller was cancelled too.
                    currentCoroutineContext().ensureActive()
                    continue
                }
            }
            val result = runCatching { refreshMutex.withLock { refreshOnce(locale, nowMs) } }
            synchronized(lock) { inFlight.remove(locale) }
            result.onSuccess { deferred.complete(it) }.onFailure { deferred.completeExceptionally(it) }
            return result.getOrThrow()
        }
    }

    private suspend fun refreshOnce(locale: String, nowMs: Long): StudioPresets.Outcome {
        val previous = withContext(Dispatchers.IO) {
            // Self-heal: a body that no longer decodes is planned as no cache at all.
            loadStored()?.takeIf { decodeBody(it.body) is StudioPresets.DecodeResult.Success }
        }
        val cache = previous?.cache
        val plan = StudioPresets.planRefresh(cache, locale, nowMs)
        if (!plan.fetch) return StudioPresets.Outcome.THROTTLED
        val fetched = try {
            transport(locale, plan.ifNoneMatch)
        } catch (_: IOException) {
            StudioPresets.Response(status = 0, etag = null, body = null)
        }
        // Bodies above the cap decode as nothing, so applyResponse reports invalid.
        val response = fetched.body
            ?.takeIf { it.toByteArray(Charsets.UTF_8).size > MAX_BODY_BYTES }
            ?.let { fetched.copy(body = null) }
            ?: fetched
        val result = StudioPresets.applyResponse(cache, locale, nowMs, response)
        when (result.outcome) {
            StudioPresets.Outcome.REPLACED -> withContext(Dispatchers.IO) { write(Stored(result.cache!!, response.body!!)) }
            StudioPresets.Outcome.NOT_MODIFIED, StudioPresets.Outcome.UNCHANGED -> withContext(Dispatchers.IO) {
                write(Stored(result.cache!!, previous!!.body))
            }
            StudioPresets.Outcome.FAILED, StudioPresets.Outcome.INVALID, StudioPresets.Outcome.THROTTLED -> Unit
        }
        return result.outcome
    }

    private fun decodeBody(body: String): StudioPresets.DecodeResult {
        synchronized(lock) {
            bodyMemo?.let { (key, value) -> if (key === body || key == body) return value }
        }
        val decoded = StudioPresets.decode(body)
        synchronized(lock) { bodyMemo = body to decoded }
        return decoded
    }

    private fun offline(locale: String): StudioPresets.Presets? = synchronized(lock) {
        offlineMemo[locale]?.let { return it }
        if (!snapshotLoaded) {
            snapshotLoaded = true
            snapshotText = runCatching { snapshot() }.getOrNull()
        }
        val raw = snapshotText ?: return null
        val presets = (StudioPresets.parseSnapshot(raw, locale) as? StudioPresets.DecodeResult.Success)?.presets ?: return null
        offlineMemo[locale] = presets
        presets
    }

    private fun loadStored(): Stored? = synchronized(lock) {
        if (!loaded) {
            loaded = true
            stored = readFile()
        }
        stored
    }

    private fun readFile(): Stored? {
        if (!file.isFile) return null
        val root = runCatching { Json.parseToJsonElement(file.readText(Charsets.UTF_8)) }.getOrNull() as? JsonObject ?: return null
        val cache = root["cache"] as? JsonObject ?: return null
        val locale = (cache["locale"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        val revision = (cache["revision"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        val etag = (cache["etag"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        val checkedAtMs = (cache["checkedAtMs"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: return null
        val body = (root["body"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        return Stored(StudioPresets.Cache(locale, revision, etag, checkedAtMs), body)
    }

    /** Atomic replace (temp file + rename); a failed write only affects the next cold start. */
    private fun write(next: Stored) {
        synchronized(lock) {
            stored = next
            loaded = true
        }
        val text = buildJsonObject {
            putJsonObject("cache") {
                put("locale", next.cache.locale)
                put("revision", next.cache.revision)
                put("etag", next.cache.etag)
                put("checkedAtMs", next.cache.checkedAtMs)
            }
            put("body", next.body)
        }.toString()
        try {
            val dir = file.parentFile ?: return
            dir.mkdirs()
            val tmp = File(dir, file.name + ".tmp")
            tmp.writeText(text, Charsets.UTF_8)
            Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } catch (_: IOException) {
            // Memory keeps the new state.
        }
    }

    companion object {
        const val FILE_PATH = "studio/presets.json"

        /** Response bodies above 1 MiB are treated as invalid. */
        const val MAX_BODY_BYTES = 1 shl 20
    }
}

/**
 * Plain GET bypassing the HTTP cache; keeps only status, the ETag (verbatim) and the 200 body
 * (null when it exceeds [StudioPresetsStore.MAX_BODY_BYTES]).
 */
internal class HttpStudioPresetsTransport(private val baseUrl: () -> String) {
    suspend fun fetch(locale: String, ifNoneMatch: String?): StudioPresets.Response = withContext(Dispatchers.IO) {
        val base = baseUrl().trimEnd('/')
        val connection = URL("$base/api/studio/presets?locale=${encodeQueryValue(locale)}").openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "GET"
            connection.useCaches = false
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.setRequestProperty("Accept", "application/json")
            ifNoneMatch?.let { connection.setRequestProperty("If-None-Match", it) }
            val status = connection.responseCode
            val body = if (status == HttpURLConnection.HTTP_OK) connection.inputStream.use(::readCapped) else null
            StudioPresets.Response(status, connection.getHeaderField("ETag"), body)
        } finally {
            connection.disconnect()
        }
    }

    private fun readCapped(input: InputStream): String? {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            out.write(buffer, 0, n)
            if (out.size() > StudioPresetsStore.MAX_BODY_BYTES) return null
        }
        return out.toString(Charsets.UTF_8.name())
    }

    companion object {
        const val TIMEOUT_MS = 15_000
        private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

        /** RFC 3986: keeps only unreserved ASCII, percent-encodes every other UTF-8 byte. */
        fun encodeQueryValue(value: String): String = buildString {
            for (byte in value.toByteArray(Charsets.UTF_8)) {
                val c = byte.toInt() and 0xFF
                if (c < 0x80 && UNRESERVED.indexOf(c.toChar()) >= 0) {
                    append(c.toChar())
                } else {
                    append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 0xF])
                }
            }
        }
    }
}
