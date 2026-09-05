package ai.oriveo.community.core.model

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
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
import ai.oriveo.community.core.util.canonicalSyncId
import ai.oriveo.community.core.util.normalizeUuid
import java.time.Instant
import java.util.UUID

@Serializable
data class GenerationParameterSyncRecord(
    val recordId: String,
    val scope: String,
    val providerId: String,
    val modelId: String? = null,
    val conversationId: String? = null,
    val profileKey: String? = null,
    val values: Map<String, GenerationParameterOverride>,
    val revision: Int,
    val mutationId: String,
)

@Serializable
data class GenerationParameterSyncPreset(
    val id: String,
    val name: String,
    val providerId: String,
    val modelId: String,
    val profileKey: String,
    val values: Map<String, GenerationParameterOverride>,
    val createdAt: String,
    val revision: Int,
    val mutationId: String,
)

@Serializable
data class GenerationParameterSyncTombstone(
    val recordId: String,
    val revision: Int,
    val mutationId: String,
)

@Serializable
data class GenerationParameterSyncPayload(
    val schemaVersion: Int = 1,
    val records: List<GenerationParameterSyncRecord> = emptyList(),
    val presets: List<GenerationParameterSyncPreset> = emptyList(),
    val tombstones: List<GenerationParameterSyncTombstone> = emptyList(),
)

class GenerationParameterSyncLedger internal constructor(
    private val readPayload: () -> String?,
    private val writePayload: (String) -> Unit,
) {
    private val json = Json { ignoreUnknownKeys = true }

    @Synchronized
    fun all(): List<GenerationParameterSyncTombstone> = readPayload()?.let {
        runCatching { json.decodeFromString<List<GenerationParameterSyncTombstone>>(it) }.getOrDefault(emptyList())
    } ?: emptyList()

    @Synchronized
    fun replace(values: List<GenerationParameterSyncTombstone>) {
        writePayload(json.encodeToString(values.takeLast(300)))
    }

    @Synchronized
    fun put(recordID: String, revision: Int) {
        val next = all().filterNot { it.recordId == recordID } + GenerationParameterSyncTombstone(
            recordId = recordID,
            revision = revision.coerceAtLeast(1),
            mutationId = UUID.randomUUID().toString().lowercase(),
        )
        replace(next)
    }

    @Synchronized
    fun clear(recordID: String) = replace(all().filterNot { it.recordId == recordID })

    
    @Synchronized
    fun clearAll() = replace(emptyList())

    companion object {
        internal const val PREFS_NAME = "generation_parameter_sync"
        private const val KEY = "tombstones.v1"
        fun from(context: Context): GenerationParameterSyncLedger {
            val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return GenerationParameterSyncLedger(
                readPayload = { prefs.getString(KEY, null) },
                writePayload = { payload -> prefs.edit().putString(KEY, payload).apply() },
            )
        }
    }
}

/** Three-client v1 mapping. Only canonical non-sensitive scalar intent can leave the device. */
class GenerationParameterSyncContract(
    private val settings: GenerationParameterSettingsStore,
    private val presets: GenerationParameterPresetStore,
    private val ledger: GenerationParameterSyncLedger,
    
    
    
    private val json: Json = Json {
        ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false; prettyPrint = true
    },
) {
    private data class TimestampSnapshot(val updatedAt: Long?)

    private sealed interface Candidate {
        val revision: Int
        val mutationID: String
        data class Record(val value: GenerationParameterSyncRecord) : Candidate {
            override val revision = value.revision; override val mutationID = value.mutationId
        }
        data class Preset(val value: GenerationParameterSyncPreset) : Candidate {
            override val revision = value.revision; override val mutationID = value.mutationId
        }
        data class Tombstone(val value: GenerationParameterSyncTombstone) : Candidate {
            override val revision = value.revision; override val mutationID = value.mutationId
        }
    }

    fun exportPayload(): GenerationParameterSyncPayload {
        val records = settings.syncRecords().mapNotNull { record ->
            val values = safeValues(record.values.values)
            if (values.isEmpty()) null else GenerationParameterSyncRecord(
                recordId = settings.recordID(record),
                scope = record.scope ?: if (record.conversationID == null) "model_default" else "conversation_override",
                providerId = record.providerID.lowercase(),
                modelId = record.modelID.takeUnless { record.scope == "connection_default" },
                conversationId = record.conversationID?.lowercase(),
                profileKey = record.syncProfileKey ?: GenerationParameterSettingsStore.portableProfileKey(record.profileFingerprint),
                values = values,
                revision = (record.revision ?: 1).coerceAtLeast(1),
                mutationId = record.mutationID ?: "legacy",
            )
        }
        val presetValues = presets.syncRecords().mapNotNull { preset ->
            val values = safeValues(preset.values.values)
            val profileKey = preset.syncProfileKey ?: GenerationParameterSettingsStore.portableProfileKey(preset.profileFingerprint)
            if (values.isEmpty() || profileKey.isNullOrEmpty()) null else GenerationParameterSyncPreset(
                id = preset.id.lowercase(),
                name = preset.name.take(80),
                providerId = preset.providerID.lowercase(),
                modelId = preset.modelID,
                profileKey = profileKey,
                values = values,
                createdAt = Instant.ofEpochMilli(preset.createdAt).toString(),
                revision = (preset.revision ?: 1).coerceAtLeast(1),
                mutationId = preset.mutationID ?: "legacy",
            )
        }
        return GenerationParameterSyncPayload(
            records = records.sortedBy { it.recordId }.take(200),
            presets = presetValues.sortedBy { it.id }.take(100),
            tombstones = ledger.all().sortedBy { it.recordId }.takeLast(300),
        )
    }

    fun exportJSON(): String = json.encodeToString(exportPayload())

    fun importJSON(raw: String): GenerationParameterSyncPayload {
        val payload = json.decodeFromString<GenerationParameterSyncPayload>(raw)
        require(payload.schemaVersion == 1) { "Unsupported generation parameter settings schema" }
        return merge(payload)
    }

    fun merge(remote: GenerationParameterSyncPayload): GenerationParameterSyncPayload {
        
        
        val previousRecordTimestamps = settings.rawSyncRecords().associate { record ->
            syncVersionKey(
                settings.recordID(record),
                (record.revision ?: 1).coerceAtLeast(1),
                record.mutationID ?: "legacy",
            ) to TimestampSnapshot(record.updatedAt)
        }
        val previousPresetTimestamps = presets.syncRecords().associate { preset ->
            syncVersionKey(
                "preset:${preset.id.lowercase()}",
                (preset.revision ?: 1).coerceAtLeast(1),
                preset.mutationID ?: "legacy",
            ) to preset.updatedAt
        }
        val candidates = linkedMapOf<String, Candidate>()
        fun put(id: String, value: Candidate) {
            val current = candidates[id]
            if (current == null || value.revision > current.revision ||
                (value.revision == current.revision && value.mutationID > current.mutationID)
            ) candidates[id] = value
        }
        fun add(payload: GenerationParameterSyncPayload) {
            
            
            payload.records.mapNotNull(::normalized).forEach { put(it.recordId, Candidate.Record(it)) }
            payload.presets.mapNotNull(::normalized).forEach { put("preset:${it.id}", Candidate.Preset(it)) }
            payload.tombstones.filter { it.recordId.isNotBlank() && it.revision > 0 && it.mutationId.isNotBlank() }
                .map { it.copy(recordId = canonicalSyncId(it.recordId)) }
                .forEach { put(it.recordId, Candidate.Tombstone(it)) }
        }
        add(exportPayload()); add(remote)
        val merged = GenerationParameterSyncPayload(
            records = candidates.values.mapNotNull { (it as? Candidate.Record)?.value }.sortedBy { it.recordId }.take(200),
            presets = candidates.values.mapNotNull { (it as? Candidate.Preset)?.value }.sortedBy { it.id }.take(100),
            tombstones = candidates.values.mapNotNull { (it as? Candidate.Tombstone)?.value }.sortedBy { it.recordId }.takeLast(300),
        )
        val mergedAt = System.currentTimeMillis()
        
        
        settings.replaceSyncRecords(merged.records.map { record ->
            val timestampKey = syncVersionKey(record.recordId, record.revision, record.mutationId)
            val updatedAt = if (previousRecordTimestamps.containsKey(timestampKey)) {
                previousRecordTimestamps.getValue(timestampKey).updatedAt
            } else {
                mergedAt
            }
            GenerationParameterSettingsStore.Record(
                scope = record.scope,
                providerID = normalizeUuid(record.providerId),
                modelID = record.modelId ?: "*",
                conversationID = record.conversationId?.let(::normalizeUuid),
                syncProfileKey = record.profileKey,
                values = GenerationParameterOverrides(record.values),
                updatedAt = updatedAt,
                revision = record.revision,
                mutationID = record.mutationId,
            )
        })
        presets.replaceSyncRecords(merged.presets.map { preset ->
            val timestampKey = syncVersionKey("preset:${preset.id}", preset.revision, preset.mutationId)
            GenerationParameterPreset(
                id = preset.id,
                name = preset.name,
                providerID = normalizeUuid(preset.providerId),
                modelID = preset.modelId,
                profileFingerprint = "",
                syncProfileKey = preset.profileKey,
                values = GenerationParameterOverrides(preset.values),
                createdAt = runCatching { Instant.parse(preset.createdAt).toEpochMilli() }.getOrDefault(System.currentTimeMillis()),
                updatedAt = previousPresetTimestamps[timestampKey] ?: mergedAt,
                revision = preset.revision,
                mutationID = preset.mutationId,
            )
        })
        ledger.replace(merged.tombstones)
        return merged
    }

    fun decodeRemote(raw: Any?): GenerationParameterSyncPayload? = runCatching {
        json.decodeFromJsonElement<GenerationParameterSyncPayload>(raw.toJsonElement())
    }.getOrNull()?.takeIf { it.schemaVersion == 1 }

    fun foundationValue(payload: GenerationParameterSyncPayload): Map<String, Any> =
        json.parseToJsonElement(json.encodeToString(payload)).toFoundation() as Map<String, Any>

    private fun normalized(value: GenerationParameterSyncRecord): GenerationParameterSyncRecord? {
        if (value.scope !in VALID_SCOPES || value.providerId.isBlank() || value.revision < 1 || value.mutationId.isBlank()) return null
        if (value.scope != "connection_default" && value.modelId.isNullOrBlank()) return null
        if (value.scope == "conversation_override" && value.conversationId.isNullOrBlank()) return null
        val values = safeValues(value.values)
        return value.copy(
            recordId = canonicalSyncId(value.recordId),
            providerId = value.providerId.lowercase(),
            conversationId = value.conversationId?.lowercase(),
            values = values,
        ).takeIf { values.isNotEmpty() }
    }

    private fun normalized(value: GenerationParameterSyncPreset): GenerationParameterSyncPreset? {
        if (value.id.isBlank() || value.providerId.isBlank() || value.modelId.isBlank() || value.profileKey.isBlank() ||
            value.revision < 1 || value.mutationId.isBlank()
        ) return null
        val values = safeValues(value.values)
        return value.copy(
            id = value.id.lowercase(),
            name = value.name.trim().take(80),
            providerId = value.providerId.lowercase(),
            values = values,
        ).takeIf { values.isNotEmpty() }
    }

    private fun safeValues(values: Map<String, GenerationParameterOverride>): Map<String, GenerationParameterOverride> =
        values.filter { (id, override) ->
            if (!CANONICAL_ID.matches(id) || id.startsWith("custom_") || id in EXCLUDED_IDS) return@filter false
            if (override.state != GenerationOverrideState.Value) return@filter true
            val primitive = override.value as? JsonPrimitive ?: return@filter false
            primitive.booleanOrNull != null || primitive.doubleOrNull != null ||
                (primitive.isString && primitive.content.length <= 64 && SAFE_STRING.matches(primitive.content))
        }

    private fun syncVersionKey(recordID: String, revision: Int, mutationID: String): String =
        "${canonicalSyncId(recordID)}\u0000$revision\u0000$mutationID"

    companion object {
        private val VALID_SCOPES = setOf("connection_default", "model_default", "conversation_override")
        private val CANONICAL_ID = Regex("^[a-z][a-z0-9_]{0,63}$")
        private val SAFE_STRING = Regex("^[a-zA-Z0-9_.:-]+$")
        private val EXCLUDED_IDS = setOf(
            "context_length", "keep_alive", "speculative_decoding", "prompt_cache", "cache_reuse", "stop", "json_schema",
        )

        fun from(context: Context) = GenerationParameterSyncContract(
            settings = GenerationParameterSettingsStore.from(context),
            presets = GenerationParameterPresetStore.from(context),
            ledger = GenerationParameterSyncLedger.from(context),
        )
    }
}

class GenerationParameterSyncCoordinator(context: Context) {
    private val appContext = context.applicationContext
    private val contract = GenerationParameterSyncContract.from(appContext)
    private val handler = Handler(Looper.getMainLooper())
    
    
    @Volatile
    private var writer: ((Map<String, Any>) -> Unit)? = null
    private var publishQueued = false
    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> queuePublish() }

    init {
        listOf(
            GenerationParameterSettingsStore.PREFS_NAME,
            GenerationParameterPresetStore.PREFS_NAME,
            GenerationParameterSyncLedger.PREFS_NAME,
        ).forEach { name ->
            appContext.getSharedPreferences(name, Context.MODE_PRIVATE).registerOnSharedPreferenceChangeListener(listener)
        }
    }

    fun bind(writer: (Map<String, Any>) -> Unit) {
        this.writer = writer
        queuePublish()
    }

    fun unbind() { writer = null }

    fun mergeRemote(raw: Any?): GenerationParameterSyncPayload? =
        contract.decodeRemote(raw)?.let(contract::merge)

    fun convergeRemote(raw: Any?): Map<String, Any>? {
        val remote = contract.decodeRemote(raw) ?: return null
        val merged = contract.merge(remote)
        return contract.foundationValue(merged).takeIf { merged != remote }
    }

    fun exportJSON(): String = contract.exportJSON()
    fun importJSON(raw: String): GenerationParameterSyncPayload = contract.importJSON(raw)
    fun foundationValue(payload: GenerationParameterSyncPayload): Map<String, Any> = contract.foundationValue(payload)

    
    private fun queuePublish() {
        if (publishQueued) return
        publishQueued = true
        handler.post {
            publishQueued = false
            val payload = contract.exportPayload()
            if (payload.records.isEmpty() && payload.presets.isEmpty() && payload.tombstones.isEmpty()) {
                return@post
            }
            writer?.invoke(contract.foundationValue(payload))
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
