package ai.oriveo.community.core.model

import android.content.Context
import android.os.Handler
import android.os.Looper
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

/** Additive `capabilityPreferenceSettings` sync field; never alters generation_parameter_sync.v1. */
class CapabilityPreferenceSyncCoordinator(context: Context) {
    private val appContext = context.applicationContext
    private val store = CapabilityPreferenceStore.from(appContext)
    
    
    
    
    
    
    
    private val json = Json {
        ignoreUnknownKeys = true; coerceInputValues = true; encodeDefaults = true; explicitNulls = false
    }
    private val handler = Handler(Looper.getMainLooper())
    
    
    @Volatile
    private var writer: ((Map<String, Any>) -> Unit)? = null
    private var publishQueued = false
    private val listener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> queuePublish() }

    init { appContext.getSharedPreferences("capability_preference_settings", Context.MODE_PRIVATE).registerOnSharedPreferenceChangeListener(listener) }

    fun bind(writer: (Map<String, Any>) -> Unit) { this.writer = writer; queuePublish() }
    fun unbind() { writer = null }
    fun convergeRemote(raw: Any?): Map<String, Any>? {
        val remote = raw.toJsonElement().let { runCatching { json.decodeFromJsonElement(CapabilityPreferenceSyncPayload.serializer(), it) }.getOrNull() }
            ?.takeIf { it.schemaVersion == 2 } ?: return null
        val merged = store.merge(remote)
        return if (merged != remote) foundationValue(merged) else null
    }
    fun foundationValue(payload: CapabilityPreferenceSyncPayload): Map<String, Any> =
        json.encodeToJsonElement(CapabilityPreferenceSyncPayload.serializer(), payload).toFoundation() as Map<String, Any>
    
    private fun queuePublish() {
        if (publishQueued) return
        publishQueued = true
        handler.post {
            publishQueued = false
            val payload = store.exportPayload()
            if (payload.records.isEmpty() && payload.tombstones.isEmpty()) return@post
            writer?.invoke(foundationValue(payload))
        }
    }
}

private fun Any?.toJsonElement(): JsonElement = when (this) {
    null -> JsonNull
    is JsonElement -> this
    is Map<*, *> -> JsonObject(entries.mapNotNull { (key, value) -> (key as? String)?.let { it to value.toJsonElement() } }.toMap())
    is List<*> -> JsonArray(map { it.toJsonElement() })
    is Boolean -> JsonPrimitive(this)
    is Number -> JsonPrimitive(this)
    else -> JsonPrimitive(toString())
}
private fun JsonElement.toFoundation(): Any? = when (this) {
    JsonNull -> null
    is JsonObject -> entries.mapNotNull { (key, value) -> value.toFoundation()?.let { key to it } }.toMap()
    is JsonArray -> mapNotNull { it.toFoundation() }
    is JsonPrimitive -> booleanOrNull ?: longOrNull ?: doubleOrNull ?: content
}
