package ai.oriveo.community.core.search

import android.content.Context
import android.content.SharedPreferences
import ai.oriveo.community.BuildConfig
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

data class SearchCatalogFetch(val statusCode: Int, val eTag: String?, val body: String?)


/** An adopted catalog: the original text (signature re-verifiable) + the adoption result. */
data class AdoptedSearchCatalog(val document: JsonObject, val snapshot: CatalogSnapshot, val source: String)

/**
 * Local sources for the external search catalog: cache → built-in snapshot → network, all three go through [SearchCatalog.acceptSearchCatalog],
 * and a failure on any path keeps the previous one. The cache stores the adopted original text and maxSeenRevision (rollback protection).
 */
class SearchCatalogRepository internal constructor(
    private val prefs: SharedPreferences,
    /** `GET /api/metadata?view=search`; the parameter is the ETag from the last adoption. */
    private val transport: suspend (ifNoneMatch: String?) -> SearchCatalogFetch,
    private val builtin: () -> String?,
    private val trustedKeys: Map<String, String>,
) {
    constructor(context: Context) : this(
        prefs = context.applicationContext.getSharedPreferences(PREFS_FILE_NAME, Context.MODE_PRIVATE),
        transport = HttpSearchCatalogTransport::fetch,
        builtin = assetReader(context.applicationContext),
        trustedKeys = SearchCatalogKeys.production,
    )

    private val lock = Any()

    @Volatile
    private var adopted: AdoptedSearchCatalog? = null

    @Volatile
    private var localLoaded = false

    fun current(): AdoptedSearchCatalog? = adopted

    fun maxSeenRevision(): Long = prefs.getLong(KEY_MAX_SEEN, 0L)

    /** Returns only entries that passed validation and are active: entries that failed validation or were withdrawn can never be obtained or executed (the allowlist cannot be bypassed). */
    fun entry(serviceId: String): JsonObject? {
        val current = adopted ?: return null
        if (current.snapshot.services.firstOrNull { it.id == serviceId }?.status != "active") return null
        return SearchCatalog.entryById(current.document, serviceId)?.takeIf { SearchCatalog.validateCatalogEntry(it) == null }
    }

    /** Server returned 404: the whole preset block is unavailable (cache and built-in snapshot included), persists across launches until a 200 is received and adopted. */
    fun presetsWithdrawn(): Boolean = prefs.getBoolean(KEY_WITHDRAWN, false)

    fun serviceState(serviceId: String): CatalogServiceState? = adopted?.snapshot?.services?.firstOrNull { it.id == serviceId }

    /** Read the cache and built-in snapshot (each read once). The caller invokes this on an IO thread. */
    fun loadLocal(): AdoptedSearchCatalog? = synchronized(lock) {
        if (!localLoaded) {
            localLoaded = true
            if (presetsWithdrawn()) return@synchronized null
            prefs.getString(KEY_RAW, null)?.let { adoptText(it, SOURCE_CACHE) }
            runCatching { builtin() }.getOrNull()?.let { adoptText(it, SOURCE_BUILTIN) }
        }
        adopted
    }

    /**
     * Fetch the network catalog once and handle it per [SearchCatalog.catalogFetchAction]: 200 adopt; 404 withdraw presets (set the flag);
     * 304 / anything else / network error / not adopted all keep the previous one. Returns the adoption result for a 200, null otherwise.
     */
    suspend fun refresh(): CatalogAcceptResult? {
        withContext(Dispatchers.IO) { loadLocal() }
        // Only send If-None-Match when an adopted catalog is in hand, otherwise a 304 would leave us stuck with "no catalog"
        val ifNoneMatch = if (adopted != null) prefs.getString(KEY_ETAG, null) else null
        val fetched = runCatching { transport(ifNoneMatch) }
        val response = fetched.getOrNull()
        val action = SearchCatalog.catalogFetchAction(
            status = response?.statusCode,
            transportFailure = if (fetched.isFailure) "network" else null,
        )
        if (action == "withdraw_presets") {
            synchronized(lock) {
                adopted = null
                if (!presetsWithdrawn()) prefs.edit().putBoolean(KEY_WITHDRAWN, true).apply()
            }
            return null
        }
        if (action != "adopt" || response?.body == null) return null
        val result = synchronized(lock) {
            adoptText(response.body, SOURCE_NETWORK)?.also {
                // A signature-verified 200 (adopted, or unchanged with the same revision as in hand) restores the presets
                if ((it.accepted || it.reason == "unchanged") && presetsWithdrawn()) prefs.edit().remove(KEY_WITHDRAWN).apply()
            }
        } ?: return null
        if (result.accepted || result.reason == "unchanged") {
            val tag = response.eTag
            if (tag != null && tag != prefs.getString(KEY_ETAG, null)) prefs.edit().putString(KEY_ETAG, tag).apply()
        }
        return result
    }

    /** The caller holds the lock. */
    private fun adoptText(text: String, source: String): CatalogAcceptResult? {
        val root = runCatching { Json.parseToJsonElement(text) }.getOrNull() ?: return null
        val doc = unwrap(root)
        val state = CatalogAdoptionState(maxSeenRevision(), adopted?.snapshot)
        val result = SearchCatalog.acceptSearchCatalog(state, doc, source, trustedKeys)
        if (!result.accepted) return result
        val accepted = doc as JsonObject
        adopted = AdoptedSearchCatalog(accepted, result.current!!, source)
        val raw = accepted.toString()
        val edit = prefs.edit()
        var dirty = false
        if (prefs.getString(KEY_RAW, null) != raw) {
            edit.putString(KEY_RAW, raw)
            dirty = true
        }
        if (prefs.getLong(KEY_MAX_SEEN, 0L) != result.maxSeenRevision) {
            edit.putLong(KEY_MAX_SEEN, result.maxSeenRevision)
            dirty = true
        }
        if (dirty) edit.apply()
        return result
    }

    companion object {
        const val PREFS_FILE_NAME = "oriveo_search_catalog.v1"
        const val BUILTIN_ASSET = "model-contracts/search_catalog_view.v1.json"
        const val SOURCE_NETWORK = "network"
        const val SOURCE_CACHE = "cache"
        const val SOURCE_BUILTIN = "builtin"
        private const val KEY_RAW = "catalog.raw"
        private const val KEY_MAX_SEEN = "catalog.maxSeenRevision"
        private const val KEY_ETAG = "catalog.etag"
        private const val KEY_WITHDRAWN = "catalog.presetsWithdrawn"

        /** `?view=search` and the built-in snapshot are `{ code, data, message }` envelopes; the body is in data. */
        internal fun unwrap(root: JsonElement): JsonElement =
            (root as? JsonObject)?.get("data")?.takeIf { it is JsonObject } ?: root

        internal fun assetReader(context: Context): () -> String? = {
            context.assets.open(BUILTIN_ASSET).bufferedReader().use { it.readText() }
        }
    }
}

/** Goes through METADATA_BASE_URL (same backend as MetadataClient), takes only the body and ETag; the body limit equals the search response limit. */
private object HttpSearchCatalogTransport {
    suspend fun fetch(ifNoneMatch: String?): SearchCatalogFetch = withContext(Dispatchers.IO) {
        val baseUrl = BuildConfig.METADATA_BASE_URL.trimEnd('/').ifBlank { "http://10.0.2.2:8080" }
        val connection = URL("$baseUrl/api/metadata?view=search").openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "GET"
            connection.setRequestProperty("Accept", "application/json")
            ifNoneMatch?.let { connection.setRequestProperty("If-None-Match", it) }
            connection.connectTimeout = 10_000
            connection.readTimeout = 15_000
            val status = connection.responseCode
            val body = if (status == HttpURLConnection.HTTP_OK) {
                connection.inputStream.use { input ->
                    val out = ByteArrayOutputStream()
                    val buf = ByteArray(16 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        require(out.size() <= SearchHardLimits.MAX_RESPONSE_BYTES) { "search catalog too large" }
                    }
                    out.toString(Charsets.UTF_8.name())
                }
            } else {
                null
            }
            SearchCatalogFetch(status, connection.getHeaderField("ETag")?.trim()?.takeIf { it.isNotEmpty() }, body)
        } finally {
            connection.disconnect()
        }
    }
}
