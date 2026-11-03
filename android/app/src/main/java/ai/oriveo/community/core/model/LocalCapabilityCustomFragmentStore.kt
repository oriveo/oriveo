package ai.oriveo.community.core.model

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class LocalCapabilityCustomFragmentStore internal constructor(
    read: () -> String?,
    write: (String?) -> Unit,
    /** Retired global developer gate. Returns null once the legacy key is gone (or never existed). */
    private val readRetiredDeveloperGate: () -> Boolean? = { null },
    private val clearRetiredDeveloperGate: () -> Unit = {},
    private val json: Json = Json { ignoreUnknownKeys = true; coerceInputValues = true },
    readAdditionalBody: (() -> String?)? = null,
    writeAdditionalBody: ((String?) -> Unit)? = null,
) {
    // A constructor given only the two older lambdas (storage unit tests) falls back to process memory, so the additional request body is never dropped silently.
    private var memoryAdditionalBody: String? = null
    private val rawRead: () -> String? = read
    private val rawWrite: (String?) -> Unit = write
    private val rawReadAdditional: () -> String? = readAdditionalBody ?: { memoryAdditionalBody }
    private val rawWriteAdditional: (String?) -> Unit = writeAdditionalBody ?: { memoryAdditionalBody = it }

    /**
     * The two one-time migrations are deferred until the first read or write of storage (not at construction): the DI viewModel{} factory
     * constructs this object on the main thread, and reading disk during construction would be synchronous IO on the main thread. Every read and write goes
     * through the four entry points below, which first run [ensureMigrated], so whatever data a caller first sees has already been migrated, with the same result
     * as migrating at construction.
     */
    @Volatile private var migrated = false
    /** Read and written only on the thread holding the lock; the migration itself also goes through the read/write entry points, which keeps it from re-entering. */
    private var migrating = false

    private fun ensureMigrated() {
        if (migrated) return
        synchronized(this) {
            if (migrated || migrating) return
            migrating = true
            try {
                migrateRetiredDeveloperGate()
                migrateLegacyGenerationFragments()
                migrated = true
            } finally {
                migrating = false
            }
        }
    }

    private fun read(): String? {
        ensureMigrated()
        return rawRead()
    }

    private fun write(payload: String?) {
        ensureMigrated()
        rawWrite(payload)
    }

    private fun readAdditional(): String? {
        ensureMigrated()
        return rawReadAdditional()
    }

    private fun writeAdditional(payload: String?) {
        ensureMigrated()
        rawWriteAdditional(payload)
    }

    /**
     * In-process decode cache, **keyed by the raw string that [read] returns** (ASM-12).
     *
     * One discrete event (opening the panel, switching models, sending) calls `records()` a dozen times:
     * three `fragmentsByOwner` namespaces, each going through `effectiveConfiguration` plus a forward probe and two `latestRecord`
     * calls. The full JSON decode runs on the main thread, while this data does not change within a single event.
     *
     * Comparing raw strings is used instead of an invalidate-on-write flag: a write can come from this object or from
     * another store instance built on the same SharedPreferences, and a flag would only catch the first case. `apply()` updates the
     * in-memory map synchronously, so `read()` gets the new string immediately, and the comparison covers both kinds of write.
     */
    private var cachedRaw: String? = null
    private var cachedRecords: List<Record> = emptyList()
    private var hasCachedRecords = false

    /**
     * Additional request body: the content is stored apart from the "send with request" switch, so it survives being turned off.
     * Keyed by connection x model x conversation (or the model default); the transport and recipe version are not part of the key.
     */
    data class AdditionalBody(val rawJSON: String, val sendWithRequest: Boolean) {
        companion object {
            val Empty = AdditionalBody(rawJSON = "", sendWithRequest = false)
        }
    }

    @Serializable
    internal data class AdditionalBodyRecord(
        val providerID: String,
        val modelID: String,
        val conversationID: String,
        val rawJSON: String,
        val sendWithRequest: Boolean,
        val updatedAt: Long,
    )

    /**
     * Falls back to the model-default layer when the conversation layer has no record; a conversation record, even a disabled one, wins.
     * [legacyModelID]: for layers the relay's literal key misses, the old canonical key is read as well.
     */
    fun additionalBody(
        providerID: String,
        modelID: String,
        conversationID: String?,
        legacyModelID: String? = null,
    ): AdditionalBody {
        migrateLegacyGenerationFragments()
        return synchronized(this) {
            val scope = conversationID ?: MODEL_DEFAULT_CONVERSATION
            val records = additionalBodyRecords()
            val legacy = legacyModelID?.takeIf { it.isNotBlank() && it != modelID }
            fun findKey(key: String, conversation: String) = records.firstOrNull {
                it.providerID.equals(providerID, ignoreCase = true) && it.modelID == key &&
                    it.conversationID == conversation
            }
            fun find(conversation: String) = findKey(modelID, conversation)
                ?: legacy?.let { findKey(it, conversation) }
            (find(scope) ?: find(MODEL_DEFAULT_CONVERSATION).takeIf { scope != MODEL_DEFAULT_CONVERSATION })
                ?.let { AdditionalBody(it.rawJSON, it.sendWithRequest) }
                ?: AdditionalBody.Empty
        }
    }

    /** The text that is really sent with this request; null when it is switched off or blank. */
    fun outboundAdditionalBody(
        providerID: String,
        modelID: String,
        conversationID: String?,
        legacyModelID: String? = null,
    ): String? =
        additionalBody(providerID, modelID, conversationID, legacyModelID)
            .takeIf { it.sendWithRequest && it.rawJSON.isNotBlank() }?.rawJSON

    fun setAdditionalBody(body: AdditionalBody, providerID: String, modelID: String, conversationID: String?) =
        synchronized(this) {
            val scope = conversationID ?: MODEL_DEFAULT_CONVERSATION
            val next = additionalBodyRecords().filterNot {
                it.providerID.equals(providerID, ignoreCase = true) && it.modelID == modelID && it.conversationID == scope
            }.toMutableList()
            if (body.sendWithRequest || body.rawJSON.isNotBlank()) {
                next += AdditionalBodyRecord(
                    providerID = providerID,
                    modelID = modelID,
                    conversationID = scope,
                    rawJSON = body.rawJSON,
                    sendWithRequest = body.sendWithRequest,
                    updatedAt = System.currentTimeMillis(),
                )
            }
            writeAdditionalBodyRecords(next)
        }

    /**
     * Moves legacy generation custom fields into the additional request body: per scope the most recently edited text is taken; one that was being sent and is valid under the new rules
     * keeps being sent, and the rest (disabled, half-written JSON, protected fields) stays as a draft that is not sent. The old records are deleted afterwards,
     * so running it again has no effect, and an existing additional request body in the target scope is never overwritten.
     */
    private fun migrateLegacyGenerationFragments() = synchronized(this) {
        val legacy = records().filter { it.namespace == GENERATION_NAMESPACE }
        if (legacy.isEmpty()) return@synchronized
        val existing = additionalBodyRecords()
        val migrated = legacy
            .filter { it.rawJSON.isNotBlank() }
            .groupBy { Triple(it.providerID.lowercase(), it.modelID, it.conversationID) }
            .values
            .mapNotNull { group -> group.maxByOrNull { it.updatedAt } }
            .filter { record ->
                existing.none {
                    it.providerID.equals(record.providerID, ignoreCase = true) && it.modelID == record.modelID &&
                        it.conversationID == record.conversationID
                }
            }
            .map { record ->
                val valid = ai.oriveo.community.core.provider.AdditionalRequestBody.validate(record.rawJSON) is
                    ai.oriveo.community.core.provider.AdditionalRequestBody.Validation.Accepted
                AdditionalBodyRecord(
                    providerID = record.providerID,
                    modelID = record.modelID,
                    conversationID = record.conversationID,
                    rawJSON = record.rawJSON,
                    sendWithRequest = record.enabled && valid,
                    updatedAt = record.updatedAt,
                )
            }
        writeAdditionalBodyRecords(existing + migrated)
        write(json.encodeToString(records().filterNot { it.namespace == GENERATION_NAMESPACE }))
    }

    private fun additionalBodyRecords(): List<AdditionalBodyRecord> = readAdditional()?.let {
        runCatching { json.decodeFromString<List<AdditionalBodyRecord>>(it) }.getOrDefault(emptyList())
    }.orEmpty()

    private fun writeAdditionalBodyRecords(records: List<AdditionalBodyRecord>) {
        writeAdditional(json.encodeToString(records.sortedByDescending { it.updatedAt }.take(MAX_RECORDS)))
    }

    /**
     * 2026-08-16 decision: the developer master switch for custom request fields is retired; outbound now only checks [Configuration.enabled].
     *
     * Why migrate instead of simply deleting the key: on installs where the master switch is off, storage can still hold records
     * with `enabled = true` (they were written while the switch was on, and drafts are kept by design). Once the master switch disappears,
     * those fragments would **suddenly start going out**, which decides something for the user that they never chose, and the first symptom
     * would be a message that fails to send or behaves differently. Here they are rewritten as disabled; `rawJSON` is kept as is, so the user can
     * still see what they wrote in the editor and re-enable it. If the master switch was on, nothing is rewritten and only the key is cleared.
     *
     * Idempotent: when the old key is absent nothing happens ([readRetiredDeveloperGate] returns null), so several store instances
     * each reading it first do not rewrite twice. An absent key likewise does **not** get a marker key written (spec appendix 3 L8).
     */
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
        legacyModelID: String? = null,
    ): Configuration {
        if (!isSupported(namespace) || transportIdentity.isBlank()) return Configuration.Empty
        val scope = conversationID ?: MODEL_DEFAULT_CONVERSATION
        val legacy = legacyModelID?.takeIf { it.isNotBlank() && it != modelID }
        // For layers the relay's literal key misses, fall back to the old canonical key.
        fun latest(conversation: String) = latestRecord(providerID, modelID, conversation, transportIdentity, namespace)
            ?: legacy?.let { latestRecord(providerID, it, conversation, transportIdentity, namespace) }
        if (forwardPort != null) {
            forwardPortIfNeeded(providerID, modelID, scope, transportIdentity, namespace, forwardPort)
            if (scope != MODEL_DEFAULT_CONVERSATION) {
                forwardPortIfNeeded(
                    providerID, modelID, MODEL_DEFAULT_CONVERSATION, transportIdentity, namespace, forwardPort,
                )
            }
        }
        return synchronized(this) {
            latest(scope)
                ?.let { return@synchronized Configuration(it.enabled, it.rawJSON) }
            if (scope == MODEL_DEFAULT_CONVERSATION) return@synchronized Configuration.Empty
            latest(MODEL_DEFAULT_CONVERSATION)
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
        legacyModelID: String? = null,
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
            effectiveConfiguration(providerID, modelID, conversationID, transportIdentity, namespace, forwardPort, legacyModelID)
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
        if (fromConversationID == toConversationID) return@synchronized
        additionalBodyRecords().firstOrNull {
            it.providerID.equals(providerID, ignoreCase = true) && it.modelID == modelID &&
                it.conversationID == fromConversationID
        }?.let { source ->
            setAdditionalBody(AdditionalBody(source.rawJSON, source.sendWithRequest), providerID, modelID, toConversationID)
            setAdditionalBody(AdditionalBody.Empty, providerID, modelID, fromConversationID)
        }
        if (transportIdentity.isBlank()) return@synchronized
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
        writeAdditionalBodyRecords(
            additionalBodyRecords().filterNot {
                (providerID == null || it.providerID.equals(providerID, ignoreCase = true)) &&
                    (modelID == null || it.modelID == modelID) &&
                    (conversationID == null || it.conversationID == conversationID)
            },
        )
    }

    /** Raw developer fields must not survive an account boundary. */
    fun clearAll() = synchronized(this) {
        write(null)
        writeAdditional(null)
    }

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
        private const val KEY_ADDITIONAL_BODY = "additional_body_v1"

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
            val app = context.applicationContext
            // The SharedPreferences handle is taken only on the first read or write; the migration is deferred to that point too, so construction does no disk I/O.
            val prefs by lazy(LazyThreadSafetyMode.PUBLICATION) { app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) }
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
                readAdditionalBody = { prefs.getString(KEY_ADDITIONAL_BODY, null) },
                writeAdditionalBody = { payload -> prefs.edit().putString(KEY_ADDITIONAL_BODY, payload).apply() },
            )
        }
    }
}
