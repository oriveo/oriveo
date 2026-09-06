package ai.oriveo.community.core.model

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import ai.oriveo.community.core.util.sameNormalizedUuid
import java.util.UUID

@Serializable
data class GenerationParameterPreset(
    val id: String,
    val name: String,
    val providerID: String,
    val modelID: String,
    val profileFingerprint: String,
    val syncProfileKey: String? = null,
    val values: GenerationParameterOverrides,
    val createdAt: Long,
    val updatedAt: Long,
    val revision: Int? = null,
    val mutationID: String? = null,
)

class GenerationParameterPresetStore(
    private val readPayload: () -> String?,
    private val writePayload: (String?) -> Unit,
    private val json: Json = Json { ignoreUnknownKeys = true },
    private val putTombstone: (String, Int) -> Unit = { _, _ -> },
    private val clearTombstone: (String) -> Unit = {},
) {

    fun list(
        providerID: String,
        modelID: String,
        profileFingerprint: String,
        portableParameterIDs: Set<String> = emptySet(),
    ): List<GenerationParameterPreset> = records().filter { preset ->

        if (!sameNormalizedUuid(preset.providerID, providerID)) return@filter false
        if (preset.modelID == modelID) return@filter true

        preset.values.values.keys.any(portableParameterIDs::contains)
    }

    fun save(
        name: String,
        providerID: String,
        modelID: String,
        profileFingerprint: String,
        values: GenerationParameterOverrides,
        id: String? = null,
    ): GenerationParameterPreset = synchronized(this) {
        val current = records().toMutableList()
        val old = id?.let { value -> current.firstOrNull { it.id == value } }
        val now = System.currentTimeMillis()
        val preset = GenerationParameterPreset(
            id = old?.id ?: UUID.randomUUID().toString(),
            name = name.trim(),
            providerID = providerID,
            modelID = modelID,
            profileFingerprint = profileFingerprint,
            syncProfileKey = old?.syncProfileKey,
            values = values.withoutRuntimeSettings(),
            createdAt = old?.createdAt ?: now,
            updatedAt = now,
            revision = (old?.revision ?: 0) + 1,
            mutationID = UUID.randomUUID().toString(),
        )
        current.removeAll { it.id == preset.id }
        current += preset
        clearTombstone(recordID(preset.id))
        writePayload(json.encodeToString(current))
        preset
    }

    fun remove(id: String) = synchronized(this) {
        val current = records()
        current.firstOrNull { it.id == id }?.let { putTombstone(recordID(id), (it.revision ?: 0) + 1) }
        writePayload(json.encodeToString(current.filterNot { it.id == id }))
    }

    fun removeScopes(providerID: String? = null, modelID: String? = null) = synchronized(this) {
        if (providerID == null && modelID == null) return@synchronized
        val current = records()
        val removed = current.filter { preset ->
            (providerID == null || sameNormalizedUuid(preset.providerID, providerID)) &&
                (modelID == null || preset.modelID == modelID)
        }
        removed.forEach { putTombstone(recordID(it.id), (it.revision ?: 0) + 1) }
        writePayload(json.encodeToString(current.filterNot { it in removed }))
    }

    fun clearForAccountBoundary() = synchronized(this) { writePayload(null) }

    fun apply(
        preset: GenerationParameterPreset,
        providerID: String,
        modelID: String,
        profileFingerprint: String,
        semanticMapping: Map<String, String>? = null,
    ): GenerationParameterOverrides? {
        if (!sameNormalizedUuid(preset.providerID, providerID)) return null
        if (preset.modelID == modelID) return preset.values.withoutRuntimeSettings()
        val mapping = semanticMapping ?: return null
        val mapped = preset.values.values.mapNotNull { (sourceID, value) -> mapping[sourceID]?.let { it to value } }.toMap()
        return mapped.takeIf { it.isNotEmpty() }?.let(::GenerationParameterOverrides)
    }

    private fun records(): List<GenerationParameterPreset> = readPayload()?.let { payload ->
        runCatching { json.decodeFromString<List<GenerationParameterPreset>>(payload) }.getOrDefault(emptyList())
    } ?: emptyList()

    internal fun syncRecords(): List<GenerationParameterPreset> = synchronized(this) { records() }

    internal fun replaceSyncRecords(records: List<GenerationParameterPreset>) = synchronized(this) {
        writePayload(json.encodeToString(records))
    }

    private fun recordID(id: String): String = "preset:${id.lowercase()}"

    private fun GenerationParameterOverrides.withoutRuntimeSettings() = GenerationParameterOverrides(
        values.filterKeys { it !in RUNTIME_PARAMETER_IDS },
    )

    companion object {
        internal const val PREFS_NAME = "generation_parameter_presets"
        internal const val KEY_PAYLOAD = "v1"
        private val RUNTIME_PARAMETER_IDS = setOf("context_length", "keep_alive", "speculative_decoding", "prompt_cache", "cache_reuse")

        fun from(context: Context): GenerationParameterPresetStore {
            val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return GenerationParameterPresetStore(
                readPayload = { prefs.getString(KEY_PAYLOAD, null) },
                writePayload = { payload -> prefs.edit().putString(KEY_PAYLOAD, payload).apply() },
                putTombstone = { recordID, revision -> GenerationParameterSyncLedger.from(context).put(recordID, revision) },
                clearTombstone = { recordID -> GenerationParameterSyncLedger.from(context).clear(recordID) },
            )
        }
    }
}
