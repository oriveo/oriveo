package ai.oriveo.community.core.model

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class LocalCapabilityCustomFragmentStore internal constructor(
    private val read: () -> String?,
    private val write: (String?) -> Unit,
    /** Retired global developer gate. Returns null once the legacy key is gone (or never existed). */
    private val readRetiredDeveloperGate: () -> Boolean? = { null },
    private val clearRetiredDeveloperGate: () -> Unit = {},
    private val json: Json = Json { ignoreUnknownKeys = true; coerceInputValues = true },
) {

    private var cachedRaw: String? = null
    private var cachedRecords: List<Record> = emptyList()
    private var hasCachedRecords = false

    init {
        migrateRetiredDeveloperGate()
    }

    private fun migrateRetiredDeveloperGate() {
        val wasEnabled = readRetiredDeveloperGate() ?: return
        clearRetiredDeveloperGate()
        if (wasEnabled) return
        synchronized(this) {
            val records = records()
            if (records.none { it.enabled }) return@synchronized
            write(json.encodeToString(records.map { if (it.enabled) it.copy(enabled = false) else it }))
        }
    }

    data class Configuration(val enabled: Boolean, val rawJSON: String) {
        companion object {
            val Empty = Configuration(enabled = false, rawJSON = "")
        }
    }

    data class ForwardPortContext(
        val providerKind: ProviderKind,

        val schemaModelID: String,
        val activeProfile: GenerationProfileRef? = null,
    )

    @Serializable
    internal data class Record(
        val providerID: String,
        val modelID: String,
        val conversationID: String,
        /** Complete selected connection/model/transport identity, never a model-id guess. */
        val transportIdentity: String,
        val namespace: String,
        val rawJSON: String,
        /** A stale raw value is never enough to activate a developer fragment. */
        val enabled: Boolean = true,
        val updatedAt: Long,
    )

    fun fragment(
        providerID: String,
        modelID: String,
        conversationID: String,
        transportIdentity: String,
        namespace: String = GENERATION_NAMESPACE,
    ): String? = synchronized(this) {
        if (!isSupported(namespace) || transportIdentity.isBlank()) return@synchronized null
        latestRecord(providerID, modelID, conversationID, transportIdentity, namespace)
            ?.takeIf { it.enabled }?.rawJSON
    }

    /** Writes only to the private local store.  In particular, do not notify a sync publisher. */
    fun setFragment(
        rawJSON: String?,
        providerID: String,
        modelID: String,
        conversationID: String,
        transportIdentity: String,
        namespace: String = GENERATION_NAMESPACE,
    ) = setConfiguration(
        Configuration(enabled = !rawJSON.isNullOrBlank(), rawJSON = rawJSON.orEmpty()),
        providerID = providerID,
        modelID = modelID,
        conversationID = conversationID,
        transportIdentity = transportIdentity,
        namespace = namespace,
    )

    private fun clearCustomRejections(
        providerID: String,
        modelID: String,
        transportIdentity: String,
        namespace: String,
    ) {
        val owner = ownerNamespaces().entries.firstOrNull { it.value == namespace }?.key ?: return
        val decoded = ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
            .decodeStorageIdentity(transportIdentity) ?: return
        ai.oriveo.community.core.provider.ModelControlRejectionCache.clear(
            ai.oriveo.community.core.provider.ModelControlRuntimeIdentity(
                connectionId = providerID,
                canonicalModelId = modelID,
                finalTransport = decoded.first,
                runtimeRevision = decoded.second,
            ),
            owner = owner,
            source = "custom",
        )
    }

    fun configuration(
        providerID: String,
        modelID: String,
        conversationID: String,
        transportIdentity: String,
        namespace: String = GENERATION_NAMESPACE,
    ): Configuration = synchronized(this) {
        if (!isSupported(namespace) || transportIdentity.isBlank()) return@synchronized Configuration.Empty
        latestRecord(providerID, modelID, conversationID, transportIdentity, namespace)
            ?.let { Configuration(it.enabled, it.rawJSON) }
            ?: Configuration.Empty
    }

    fun effectiveConfiguration(
        providerID: String,
        modelID: String,
        conversationID: String?,
        transportIdentity: String,
        namespace: String = GENERATION_NAMESPACE,
        forwardPort: ForwardPortContext? = null,
    ): Configuration {
        if (!isSupported(namespace) || transportIdentity.isBlank()) return Configuration.Empty
        val scope = conversationID ?: MODEL_DEFAULT_CONVERSATION
        if (forwardPort != null) {
            forwardPortIfNeeded(providerID, modelID, scope, transportIdentity, namespace, forwardPort)
            if (scope != MODEL_DEFAULT_CONVERSATION) {
                forwardPortIfNeeded(
                    providerID, modelID, MODEL_DEFAULT_CONVERSATION, transportIdentity, namespace, forwardPort,
                )
            }
        }
        return synchronized(this) {
            latestRecord(providerID, modelID, scope, transportIdentity, namespace)
                ?.let { return@synchronized Configuration(it.enabled, it.rawJSON) }
            if (scope == MODEL_DEFAULT_CONVERSATION) return@synchronized Configuration.Empty
            latestRecord(providerID, modelID, MODEL_DEFAULT_CONVERSATION, transportIdentity, namespace)
                ?.let { Configuration(it.enabled, it.rawJSON) }
                ?: Configuration.Empty
        }
    }

    fun setConfiguration(
        configuration: Configuration,
        providerID: String,
        modelID: String,
        conversationID: String?,
        transportIdentity: String,
        namespace: String = GENERATION_NAMESPACE,
    ) = synchronized(this) {
        if (!isSupported(namespace) || transportIdentity.isBlank()) return@synchronized
        val scope = conversationID ?: MODEL_DEFAULT_CONVERSATION
        val next = records().filterNot {
            it.matches(providerID, modelID, scope, transportIdentity, namespace)
        }.toMutableList()
        if (configuration.enabled || configuration.rawJSON.isNotBlank()) {
            next += Record(
                providerID = providerID,
                modelID = modelID,
                conversationID = scope,
                transportIdentity = transportIdentity,
                namespace = namespace,
                rawJSON = configuration.rawJSON,
                enabled = configuration.enabled,
                updatedAt = System.currentTimeMillis(),
            )
        }
        write(json.encodeToString(next.sortedByDescending { it.updatedAt }.take(MAX_RECORDS)))
        if (configuration.enabled && configuration.rawJSON.isNotBlank()) {
            clearCustomRejections(providerID, modelID, transportIdentity, namespace)
        }
    }

    private fun forwardPortIfNeeded(
        providerID: String,
        modelID: String,
        scope: String,
        transportIdentity: String,
        namespace: String,
        context: ForwardPortContext,
    ) = synchronized(this) {
        val decoded = ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
            .decodeStorageIdentity(transportIdentity) ?: return@synchronized
        val owner = ownerNamespaces().entries.firstOrNull { it.value == namespace }?.key ?: return@synchronized
        val records = records()
        val matches = { record: Record ->
            record.providerID.equals(providerID, ignoreCase = true) && record.modelID == modelID &&
                record.conversationID == scope && record.namespace == namespace
        }
        if (records.any { matches(it) && it.transportIdentity == transportIdentity }) return@synchronized
        val candidate = records
            .filter { matches(it) && isSameTransportLineage(transportIdentity, it.transportIdentity) }
            .maxByOrNull { it.updatedAt } ?: return@synchronized
        if (candidate.rawJSON.isBlank()) return@synchronized
        val staysEnabled = candidate.enabled &&
            ai.oriveo.community.core.provider.previewCapabilityRuntimeCustomFragment(
                raw = candidate.rawJSON,
                providerKind = context.providerKind,
                modelID = context.schemaModelID,
                finalTransport = decoded.first,
                activeProfile = context.activeProfile,
                owner = owner,
            ).accepted
        setConfiguration(
            Configuration(enabled = staysEnabled, rawJSON = candidate.rawJSON),
            providerID, modelID, scope, transportIdentity, namespace,
        )
    }

    private fun isSameTransportLineage(current: String, candidate: String): Boolean {
        if (current == candidate) return false
        val currentIdentity = ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
            .decodeStorageIdentity(current) ?: return false
        val candidateIdentity = ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
            .decodeStorageIdentity(candidate) ?: return false
        return currentIdentity.first == candidateIdentity.first &&
            currentIdentity.second != candidateIdentity.second
    }

    fun fragmentsByOwner(
        providerID: String,
        modelID: String,
        conversationID: String?,
        transportIdentity: String,
        forwardPort: ForwardPortContext? = null,
    ): Map<String, String> {
        val finalTransport = forwardPort?.let {
            ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
                .decodeStorageIdentity(transportIdentity)?.first
        }
        return ownerNamespaces().mapNotNull { (owner, namespace) ->
            if (forwardPort != null && !ai.oriveo.community.core.provider.capabilityCustomFragmentAvailable(
                    providerKind = forwardPort.providerKind,
                    modelID = forwardPort.schemaModelID,
                    finalTransport = finalTransport,
                    activeProfile = forwardPort.activeProfile,
                    owner = owner,
                )
            ) {
                return@mapNotNull null
            }
            effectiveConfiguration(providerID, modelID, conversationID, transportIdentity, namespace, forwardPort)
                .takeIf { it.enabled }
                ?.let { owner to it.rawJSON }
        }.toMap()
    }

    /** The unsaved composer session becomes a real conversation after the first send. */
    fun migrateConversation(
        providerID: String,
        modelID: String,
        fromConversationID: String,
        toConversationID: String,
        transportIdentity: String,
    ) = synchronized(this) {
        if (fromConversationID == toConversationID || transportIdentity.isBlank()) return@synchronized
        supportedNamespaces().forEach { namespace ->

            val source = latestRecord(providerID, modelID, fromConversationID, transportIdentity, namespace)
                ?: return@forEach
            setConfiguration(
                Configuration(source.enabled, source.rawJSON),
                providerID, modelID, toConversationID, transportIdentity, namespace,
            )
            setConfiguration(
                Configuration.Empty, providerID, modelID, fromConversationID, transportIdentity, namespace,
            )
        }
    }

    fun removeScopes(
        providerID: String? = null,
        modelID: String? = null,
        conversationID: String? = null,
    ) = synchronized(this) {
        if (providerID == null && modelID == null && conversationID == null) return@synchronized
        val next = records().filterNot {
            (providerID == null || it.providerID.equals(providerID, ignoreCase = true)) &&
                (modelID == null || it.modelID == modelID) &&
                (conversationID == null || it.conversationID == conversationID)
        }
        write(json.encodeToString(next))
    }

    /** Raw developer fields must not survive an account boundary. */
    fun clearAll() = synchronized(this) { write(null) }

    private fun records(): List<Record> = synchronized(this) {
        val raw = read()
        if (hasCachedRecords && raw == cachedRaw) return@synchronized cachedRecords
        val decoded = raw?.let {
            runCatching { json.decodeFromString<List<Record>>(it) }.getOrDefault(emptyList())
        }.orEmpty()
        cachedRaw = raw
        cachedRecords = decoded
        hasCachedRecords = true
        decoded
    }

    private fun Record.matches(
        providerID: String,
        modelID: String,
        conversationID: String,
        transportIdentity: String,
        namespace: String,
    ): Boolean = this.providerID.equals(providerID, ignoreCase = true) && this.modelID == modelID &&
        this.conversationID == conversationID && this.transportIdentity == transportIdentity &&
        this.namespace == namespace

    private fun latestRecord(
        providerID: String,
        modelID: String,
        conversationID: String,
        transportIdentity: String,
        namespace: String,
    ): Record? = records()
        .filter { it.matches(providerID, modelID, conversationID, transportIdentity, namespace) }
        .maxByOrNull { it.updatedAt }

    private fun isSupported(namespace: String): Boolean = namespace in supportedNamespaces()

    companion object {
        const val GENERATION_NAMESPACE = "generationPatch"
        const val WEB_NAMESPACE = "webPatch"
        const val REASONING_NAMESPACE = "reasoningPatch"

        const val MODEL_DEFAULT_CONVERSATION = ""
        private const val PREFS_NAME = "local_capability_custom_fragments"
        private const val KEY_PAYLOAD = "v1"

        private const val KEY_RETIRED_DEVELOPER_MODE = "developer_mode"
        private const val MAX_RECORDS = 100

        private val OWNER_NAMESPACES = linkedMapOf(
            "web" to WEB_NAMESPACE,
            "reasoning" to REASONING_NAMESPACE,
            "generation" to GENERATION_NAMESPACE,
        )

        fun ownerNamespaces(): Map<String, String> = OWNER_NAMESPACES

        fun namespaceForOwner(owner: String): String? = OWNER_NAMESPACES[owner]

        fun supportedNamespaces(): Set<String> = OWNER_NAMESPACES.values.toSet()

        fun from(context: Context): LocalCapabilityCustomFragmentStore {
            val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return LocalCapabilityCustomFragmentStore(
                read = { prefs.getString(KEY_PAYLOAD, null) },
                write = { payload -> prefs.edit().putString(KEY_PAYLOAD, payload).apply() },

                readRetiredDeveloperGate = {
                    if (prefs.contains(KEY_RETIRED_DEVELOPER_MODE)) {
                        prefs.getBoolean(KEY_RETIRED_DEVELOPER_MODE, false)
                    } else {
                        null
                    }
                },
                clearRetiredDeveloperGate = {
                    prefs.edit().remove(KEY_RETIRED_DEVELOPER_MODE).apply()
                },
            )
        }
    }
}
