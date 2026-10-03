package ai.oriveo.community.core.mcp

import android.content.SharedPreferences
import java.io.IOException
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonElement

// Fake media for the authorization tests: in-memory SharedPreferences (writes / deletes can be made to fail),
// a fake OAuth transport and a fake browser. The medium changes, the semantics do not, and the code under test is
// still the production code.

/** In-memory prefs. With [failWrites] / [failDeletes] set, `commit()` returns false (simulating encrypted prefs that cannot be written). */
class InMemoryPrefs : SharedPreferences {
    private val lock = Any()
    private val items = linkedMapOf<String, Any?>()

    @Volatile var failWrites = false

    @Volatile var failDeletes = false

    /** Called after each commit that wrote something (lets a test act at the moment a credential has just been stored, e.g. cancel the coroutine that started it). */
    @Volatile var onWriteCommitted: (() -> Unit)? = null

    override fun getAll(): MutableMap<String, *> = synchronized(lock) { LinkedHashMap(items) }

    override fun getString(key: String?, defValue: String?): String? = synchronized(lock) { items[key] as? String ?: defValue }

    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? = defValues

    override fun getInt(key: String?, defValue: Int): Int = defValue

    override fun getLong(key: String?, defValue: Long): Long = defValue

    override fun getFloat(key: String?, defValue: Float): Float = defValue

    override fun getBoolean(key: String?, defValue: Boolean): Boolean = defValue

    override fun contains(key: String?): Boolean = synchronized(lock) { items.containsKey(key) }

    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    override fun edit(): SharedPreferences.Editor = Editor()

    private inner class Editor : SharedPreferences.Editor {
        private val puts = linkedMapOf<String, String?>()
        private val removes = mutableSetOf<String>()

        override fun putString(key: String, value: String?) = apply { puts[key] = value }
        override fun putStringSet(key: String?, values: MutableSet<String>?) = this
        override fun putInt(key: String?, value: Int) = this
        override fun putLong(key: String?, value: Long) = this
        override fun putFloat(key: String?, value: Float) = this
        override fun putBoolean(key: String?, value: Boolean) = this
        override fun remove(key: String) = apply { removes += key }
        override fun clear() = apply { removes += synchronized(lock) { items.keys.toList() } }

        override fun commit(): Boolean = synchronized(lock) {
            if (puts.isNotEmpty() && failWrites) return false
            if (removes.isNotEmpty() && failDeletes) return false
            removes.forEach { items.remove(it) }
            items.putAll(puts)
            if (puts.isNotEmpty()) onWriteCommitted?.invoke()
            true
        }

        override fun apply() {
            commit()
        }
    }
}

class FakeMcpAuthTransport : McpAuthTransport {
    private class Stub(val status: Int, val body: ByteArray)

    private val lock = Any()
    private val stubs = mutableMapOf<String, Stub>()
    private val queued = mutableMapOf<String, ArrayDeque<Stub>>()
    private val unreachable = mutableSetOf<String>()
    private val getLog = mutableListOf<String>()
    private val formLog = mutableListOf<Pair<String, List<McpFormField>>>()
    private val jsonLog = mutableListOf<Pair<String, JsonElement>>()

    /** Artificial delay on the token endpoint, used to open a concurrency window. */
    @Volatile var postFormDelayMillis = 0L

    val getUrls: List<String> get() = synchronized(lock) { getLog.toList() }
    val formRequests: List<Pair<String, List<McpFormField>>> get() = synchronized(lock) { formLog.toList() }
    val jsonRequests: List<Pair<String, JsonElement>> get() = synchronized(lock) { jsonLog.toList() }

    fun stub(status: Int, json: JsonElement, at: String) = synchronized(lock) {
        stubs[at] = Stub(status, McpJson.ordered(json).toByteArray())
    }

    fun stub(status: Int, raw: String, at: String) = synchronized(lock) { stubs[at] = Stub(status, raw.toByteArray()) }

    fun enqueue(status: Int, json: JsonElement, at: String) = synchronized(lock) {
        queued.getOrPut(at) { ArrayDeque() }.addLast(Stub(status, McpJson.ordered(json).toByteArray()))
    }

    fun setUnreachable(value: Boolean, at: String) = synchronized(lock) { if (value) unreachable += at else unreachable -= at }

    private fun take(url: String): Stub? {
        if (url in unreachable) throw IOException("not connected")
        queued[url]?.removeFirstOrNull()?.let { return it }
        return stubs[url]
    }

    private fun response(stub: Stub?) = if (stub == null) {
        McpHttpResponse(404, emptyMap(), ByteArray(0))
    } else {
        McpHttpResponse(stub.status, mapOf("content-type" to "application/json"), stub.body)
    }

    override suspend fun get(url: String): McpHttpResponse {
        val stub = synchronized(lock) {
            getLog += url
            runCatching { take(url) }
        }
        return response(stub.getOrThrow())
    }

    override suspend fun postForm(url: String, form: List<McpFormField>): McpHttpResponse {
        val stub = synchronized(lock) {
            formLog += url to form
            runCatching { take(url) }
        }
        if (postFormDelayMillis > 0) delay(postFormDelayMillis)
        return response(stub.getOrThrow())
    }

    override suspend fun postJson(url: String, body: JsonElement): McpHttpResponse {
        val stub = synchronized(lock) {
            jsonLog += url to body
            runCatching { take(url) }
        }
        return response(stub.getOrThrow())
    }
}

class FakeMcpBrowserSession : McpBrowserSession {
    private val opened = mutableListOf<String>()

    /** The test decides the redirect URL; when null this throws (simulating the user cancelling). */
    @Volatile var callbackBuilder: ((authorizeUrl: String, redirectUri: String) -> String)? = null

    val openedUrls: List<String> get() = synchronized(opened) { opened.toList() }

    override suspend fun authorize(url: String, redirectUri: String): String {
        synchronized(opened) { opened += url }
        val builder = callbackBuilder ?: throw IllegalStateException("user cancelled")
        return builder(url, redirectUri)
    }
}
