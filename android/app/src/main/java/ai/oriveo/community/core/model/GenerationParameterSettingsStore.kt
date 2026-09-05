package ai.oriveo.community.core.model

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import ai.oriveo.community.core.provider.GenerationParameterAvailability
import ai.oriveo.community.core.util.canonicalSyncId
import ai.oriveo.community.core.util.sameNormalizedUuid
import java.net.URI
import java.security.MessageDigest
import java.util.UUID


class GenerationParameterSettingsStore(
    private val readPayload: () -> String?,
    private val writePayload: (String?) -> Unit,
    private val json: Json = Json { ignoreUnknownKeys = true; coerceInputValues = true },
    private val putTombstone: (String, Int) -> Unit = { _, _ -> },
    private val clearTombstone: (String) -> Unit = {},
) {
    @Serializable
    internal data class Record(
        val scope: String? = null,
        val providerID: String,
        val modelID: String,
        val conversationID: String? = null,
        val profileFingerprint: String? = null,
        val syncProfileKey: String? = null,
        val values: GenerationParameterOverrides,
        val updatedAt: Long? = null,
        val revision: Int? = null,
        val mutationID: String? = null,
    )

    
    
    
    
    
    
    
    
    
    @Suppress("UNUSED_PARAMETER")
    fun modelDefaults(providerID: String, modelID: String, profileFingerprint: String? = null): GenerationParameterOverrides? = synchronized(this) {
        latest(records()) { it.scope != CONNECTION_DEFAULT && sameNormalizedUuid(it.providerID, providerID) && it.modelID == modelID && it.conversationID == null }?.values
    }

    fun connectionDefaults(providerID: String): GenerationParameterOverrides? = synchronized(this) {
        latest(records()) { it.scope == CONNECTION_DEFAULT && sameNormalizedUuid(it.providerID, providerID) }?.values
    }

    @Suppress("UNUSED_PARAMETER")
    fun sessionOverrides(providerID: String, modelID: String, conversationID: String, profileFingerprint: String? = null): GenerationParameterOverrides? = synchronized(this) {
        latest(records()) { sameNormalizedUuid(it.providerID, providerID) && it.modelID == modelID && sameNormalizedUuid(it.conversationID, conversationID) }?.values
    }

    fun setModelDefaults(values: GenerationParameterOverrides?, providerID: String, modelID: String, profileFingerprint: String? = null) =
        replace(values, providerID, modelID, null, profileFingerprint, MODEL_DEFAULT)

    fun setConnectionDefaults(values: GenerationParameterOverrides?, providerID: String) =
        replace(values, providerID, "*", null, null, CONNECTION_DEFAULT)

    fun setSessionOverrides(values: GenerationParameterOverrides?, providerID: String, modelID: String, conversationID: String, profileFingerprint: String? = null) =
        replace(values, providerID, modelID, conversationID, profileFingerprint, CONVERSATION_OVERRIDE)

    
    fun migrateSession(
        providerID: String,
        modelID: String,
        fromConversationID: String,
        toConversationID: String,
        profileFingerprint: String? = null,
    ) = synchronized(this) {
        if (sameNormalizedUuid(fromConversationID, toConversationID)) return@synchronized
        val next = records().toMutableList()
        val sourceIndex = next.indexOfFirst {
            sameNormalizedUuid(it.providerID, providerID) && it.modelID == modelID &&
                sameNormalizedUuid(it.conversationID, fromConversationID)
        }
        if (sourceIndex < 0) return@synchronized
        val source = next.removeAt(sourceIndex)
        val destination = next.firstOrNull {
            sameNormalizedUuid(it.providerID, providerID) && it.modelID == modelID &&
                sameNormalizedUuid(it.conversationID, toConversationID)
        }
        next.removeAll { it == destination }
        putTombstone(recordID(source), (source.revision ?: 0) + 1)
        next += source.copy(
            scope = CONVERSATION_OVERRIDE,
            conversationID = toConversationID,
            
            profileFingerprint = profileFingerprint ?: source.profileFingerprint,
            updatedAt = System.currentTimeMillis(),
            revision = (destination?.revision ?: 0) + 1,
            mutationID = UUID.randomUUID().toString(),
        )
        clearTombstone(recordID(next.last()))
        writePayload(json.encodeToString(capped(next)))
    }

    fun removeScopes(providerID: String? = null, modelID: String? = null, conversationID: String? = null) = synchronized(this) {
        if (providerID == null && modelID == null && conversationID == null) return@synchronized
        val current = records()
        val removed = current.filter {
            (providerID == null || sameNormalizedUuid(it.providerID, providerID)) &&
                (modelID == null || it.modelID == modelID) &&
                (conversationID == null || sameNormalizedUuid(it.conversationID, conversationID))
        }
        removed.forEach { putTombstone(recordID(it), (it.revision ?: 0) + 1) }
        val next = current.filterNot { it in removed }
        writePayload(json.encodeToString(next))
    }

    
    fun clearForAccountBoundary() = synchronized(this) { writePayload(null) }

    
    fun resolve(
        transient: GenerationParameterOverrides?,
        providerID: String,
        modelID: String,
        conversationID: String,
        profileFingerprint: String? = null,
        reasoningMode: ReasoningMode? = null,
        activeParameterIds: Set<String>? = null,
    ): GenerationParameterOverrides? {
        val allowConnectionReasoning = reasoningMode == null || reasoningMode == ReasoningMode.Automatic
        val result = linkedMapOf<String, GenerationParameterOverride>()
        
        
        
        
        
        
        
        listOf(
            Triple(transient, false, false),
            Triple(sessionOverrides(providerID, modelID, conversationID, profileFingerprint), false, true),
            Triple(modelDefaults(providerID, modelID, profileFingerprint), allowConnectionReasoning, true),
            Triple(connectionDefaults(providerID), allowConnectionReasoning, true),
        )
            .forEach { (layer, allowReasoning, dropDormant) ->
                layer?.values?.forEach { (key, value) ->
                    if (!allowReasoning && key in REASONING_PARAMETER_IDS) return@forEach
                    if (dropDormant && activeParameterIds?.contains(key) == false) return@forEach
                    if (key !in result && value.state != GenerationOverrideState.Inherit) result[key] = value
                }
            }
        return result.takeIf { it.isNotEmpty() }?.let(::GenerationParameterOverrides)
    }

    private fun replace(
        values: GenerationParameterOverrides?,
        providerID: String,
        modelID: String,
        conversationID: String?,
        profileFingerprint: String?,
        scope: String,
    ) = synchronized(this) {
        val current = records()
        
        
        val matches = current.filter {
            sameNormalizedUuid(it.providerID, providerID) && it.modelID == modelID &&
                sameNormalizedUuid(it.conversationID, conversationID) &&
                effectiveScope(it) == scope
        }
        val existing = latest(matches) { true }
        
        
        val baseRevision = matches.maxOfOrNull { it.revision ?: 0 } ?: 0
        val next = current.filterNot { it in matches }.toMutableList()
        values?.takeIf { overrides ->
            overrides.values.any { it.value.state != GenerationOverrideState.Inherit }
        }?.let { overrides ->
            val record = Record(
                scope = scope,
                providerID = providerID,
                modelID = modelID,
                conversationID = conversationID,
                profileFingerprint = profileFingerprint,
                values = overrides,
                updatedAt = System.currentTimeMillis(),
                revision = baseRevision + 1,
                mutationID = UUID.randomUUID().toString(),
            )
            next += record
            clearTombstone(recordID(record))
        } ?: existing?.let {
            putTombstone(recordID(it), baseRevision + 1)
        }
        writePayload(json.encodeToString(capped(next)))
    }

    private fun rawRecords(): List<Record> = readPayload()?.let { payload ->
        runCatching { json.decodeFromString<List<Record>>(payload) }.getOrDefault(emptyList())
    } ?: emptyList()

    private fun records(): List<Record> = rawRecords()
        .filter { it.updatedAt == null || it.updatedAt >= System.currentTimeMillis() - RECORD_TTL_MILLIS }

    private fun capped(records: List<Record>): List<Record> =
        records.sortedByDescending { it.updatedAt ?: Long.MIN_VALUE }.take(MAX_RECORDS)

    internal fun syncRecords(): List<Record> = synchronized(this) { records() }

    internal fun rawSyncRecords(): List<Record> = synchronized(this) { rawRecords() }

    internal fun replaceSyncRecords(records: List<Record>) = synchronized(this) {
        writePayload(json.encodeToString(capped(records)))
    }

    
    private fun latest(records: List<Record>, predicate: (Record) -> Boolean): Record? =
        records.filter(predicate).maxByOrNull { it.updatedAt ?: Long.MIN_VALUE }

    private fun effectiveScope(record: Record): String = record.scope
        ?: if (record.conversationID == null) MODEL_DEFAULT else CONVERSATION_OVERRIDE

    
    internal fun recordID(record: Record): String = canonicalSyncId(
        when (effectiveScope(record)) {
            CONNECTION_DEFAULT -> "scope:connection:${record.providerID}"
            CONVERSATION_OVERRIDE -> "scope:conversation:${record.providerID}:${record.modelID}:${record.conversationID.orEmpty()}"
            else -> "scope:model:${record.providerID}:${record.modelID}"
        },
    )

    companion object {
        internal const val PREFS_NAME = "generation_parameter_settings"
        internal const val KEY_PAYLOAD = "v1"
        private const val MAX_RECORDS = 200
        private const val RECORD_TTL_MILLIS = 180L * 24 * 60 * 60 * 1000
        private const val CONNECTION_DEFAULT = "connection_default"
        private const val MODEL_DEFAULT = "model_default"
        private const val CONVERSATION_OVERRIDE = "conversation_override"
        private val REASONING_PARAMETER_IDS = setOf("reasoning_effort", "reasoning_budget", "reasoning_mode")

        fun from(context: Context): GenerationParameterSettingsStore {
            val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return GenerationParameterSettingsStore(
                readPayload = { prefs.getString(KEY_PAYLOAD, null) },
                writePayload = { payload -> prefs.edit().putString(KEY_PAYLOAD, payload).apply() },
                putTombstone = { recordID, revision -> GenerationParameterSyncLedger.from(context).put(recordID, revision) },
                clearTombstone = { recordID -> GenerationParameterSyncLedger.from(context).clear(recordID) },
            )
        }

        internal fun portableProfileKey(fingerprint: String?): String? {
            if (fingerprint.isNullOrEmpty()) return null
            return fingerprint.split('|').drop(1).joinToString("|").ifEmpty { fingerprint }
        }
    }
}

object GenerationParameterProfileFingerprint {
    fun make(provider: Provider, model: AIModel): String {
        val endpoint = if (provider.kind == ProviderKind.Relay) {
            provider.relayRequested?.resolvedAPIBaseURL ?: provider.baseUrlText.orEmpty()
        } else ""
        val endpointHash = sanitizedEndpoint(endpoint)?.let { "ep_${sha256(it).take(16)}" }.orEmpty()
        val transport = GenerationParameterAvailability.profile(provider, model)?.template.orEmpty()
        return listOf(endpointHash, transport, provider.relayRequested?.engineProfile.orEmpty(), model.canonicalModelId ?: model.id).joinToString("|")
    }

    private fun sanitizedEndpoint(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        return runCatching {
            val uri = URI(trimmed)
            URI(uri.scheme, null, uri.host, uri.port, uri.path.trimEnd('/').ifEmpty { "/" }, null, null).toString()
        }.getOrElse { trimmed.substringBefore('?').substringBefore('#') }
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
}
