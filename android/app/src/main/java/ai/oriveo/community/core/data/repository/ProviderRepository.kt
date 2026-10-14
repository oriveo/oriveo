package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.transport.OfficialEndpointSource
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.RelayImageConfig
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayKindDefaults
import ai.oriveo.community.core.model.RelayCredentialPolicy
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.provider.LlamaCppChannelMigration
import ai.oriveo.community.core.provider.LocalEngineGenerationProfiles
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.provider.wireName
import kotlinx.coroutines.CancellationException
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.RelayOfficialCatalogResolver
import ai.oriveo.community.core.provider.prepareProviderForUpsert
import ai.oriveo.community.core.provider.DeepSeekService
import ai.oriveo.community.core.provider.FireworksService
import ai.oriveo.community.core.provider.GeminiService
import ai.oriveo.community.core.provider.GrokService
import ai.oriveo.community.core.provider.grok.GrokSubscriptionAvailability
import ai.oriveo.community.core.provider.grok.GrokSubscriptionCredentialStore
import ai.oriveo.community.core.provider.grok.GrokSubscriptionOAuthClient
import ai.oriveo.community.core.provider.grok.GrokSubscriptionRuntime
import ai.oriveo.community.core.provider.grok.GrokSubscriptionTokens
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionAvailability
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionCredentialStore
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionException
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionOAuthClient
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionRuntime
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionTokens
import ai.oriveo.community.core.provider.openai.toProviderServiceError
import ai.oriveo.community.core.provider.grok.toProviderServiceError
import ai.oriveo.community.core.provider.GroqService
import ai.oriveo.community.core.provider.ManualRetainedPruner
import ai.oriveo.community.core.provider.MiniMaxService
import ai.oriveo.community.core.provider.MistralService
import ai.oriveo.community.core.provider.MoonshotService
import ai.oriveo.community.core.provider.SiliconFlowService
import ai.oriveo.community.core.provider.ZhipuService
import ai.oriveo.community.core.provider.QwenService
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.RelayModelFallback
import ai.oriveo.community.core.provider.OpenAICompatibleService
import ai.oriveo.community.core.provider.OpenAIService
import ai.oriveo.community.core.provider.OpenRouterService
import ai.oriveo.community.core.provider.ProviderCatalogResolver
import ai.oriveo.community.core.provider.ProviderKeyValidator
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.TogetherService
import ai.oriveo.community.core.provider.ToolCallMemoryStore
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.core.util.DeterministicProviderId
import ai.oriveo.community.core.util.dedupeByNormalizedId
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.util.normalizeProviderIds
import ai.oriveo.community.core.util.normalizeUuid
import java.net.URI
import ai.oriveo.community.core.util.sameNormalizedUuid
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.shareIn
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

class ProviderRepository(
    private val dao: ProviderDao,
    private val conversationDao: ConversationDao,
    private val secureKeyStore: SecureKeyStore,
    private val openRouterService: OpenRouterService,
    private val openAIService: OpenAIService,
    private val deepSeekService: DeepSeekService,
    private val grokService: GrokService,
    private val anthropicService: AnthropicService,
    private val geminiService: GeminiService,
    private val groqService: GroqService,
    private val togetherService: TogetherService,
    private val fireworksService: FireworksService,
    private val miniMaxService: MiniMaxService,
    private val zhipuService: ZhipuService,
    private val qwenService: QwenService,
    private val moonshotService: MoonshotService,
    private val mistralService: MistralService,
    private val siliconFlowService: SiliconFlowService,
    private val relayService: RelayService,
    private val metadataRefreshEventBus: MetadataRefreshEventBus,
    private val httpClient: io.ktor.client.HttpClient,
    private val externalScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val runInTransaction: suspend (suspend () -> Unit) -> Unit = { block -> block() },
    private val capabilityPreferenceStore: ai.oriveo.community.core.model.CapabilityPreferenceStore? = null,
    private val localCapabilityCustomFragmentStore: ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore? = null,
    private val toolCallMemoryStore: ToolCallMemoryStore? = null,
    private val preferenceDao: ai.oriveo.community.core.data.dao.PreferenceDao? = null,
    // Dispatcher for the pre-write enrichment, catalog resolution and JSON encoding; injectable for tests.
    private val cpuDispatcher: CoroutineDispatcher = Dispatchers.Default,
    // Per-model relay family probe lookup (by-model view, fetched lazily and cached in memory); tests inject a fake service.
    private val relayModelFamily: suspend (String) -> String? = {
        ai.oriveo.community.core.data.remote.RelayModelFamilyLookup.shared.family(it)
    },
    // Local engine connector: re-reads the per-model capability declarations on re-detection.
    private val localEngineConnector: ai.oriveo.community.core.provider.LocalEngineConnector? = null,
    /** Negative cache for relay upstream rejections: re-detection and deleting a connection clear the whole connection. */
    private val relayNegativeCache: ai.oriveo.community.core.provider.relay.RelayNegativeCache =
        ai.oriveo.community.core.provider.relay.RelayNegativeCache.shared,
    /** Connection-level web search fragments of a relay: the whole key is deleted when the connection is deleted. */
    private val relayWebFragmentStore: ai.oriveo.community.core.provider.relay.RelayWebFragmentStore =
        ai.oriveo.community.core.provider.relay.RelayWebFragmentStore.shared,
    /** Local records of relay web search probes: cleared for the whole connection when it is deleted. */
    private val relayWebProbeRecords: ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore =
        ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore.shared,
    /** The relay fallback model looks at "last used"; DI injects the read from AppPreferencesRepository. */
    private val lastUsedModelRef: suspend () -> ai.oriveo.community.core.model.LastUsedModelRef? = { null },
    /** Background re-probe after a key is confirmed usable; tests inject a scope so they can wait for it to finish. */
    private val relayProbeScope: CoroutineScope = externalScope,
    /** Local automatic history of web search probes: de-duplication and a rolling cap; cleared for the whole connection when it is deleted. */
    private val relayWebProbeAutoHistory: ai.oriveo.community.core.provider.relay.RelayWebProbeAutoHistory =
        ai.oriveo.community.core.provider.relay.RelayWebProbeAutoHistory.shared,
) {

    private val accountId: String get() = LOCAL_PARTITION_ID

    /**
     * Session state of the lazy verification after a single model is enabled in the model library: in memory only, never persisted.
     * Success / rebinding / re-detection clear it; a changed value of the effective key or a successful send also clears "not connected"
     * ("verifying" is closed out by the in-flight lazy verification itself). A successful catalog fetch or a key status written as ok does not clear it:
     */
    sealed interface RelayModelProbeState {
        data object InFlight : RelayModelProbeState

        /** [error] is the last failure (classified into one sentence by the existing failure classification); [httpStatus] is the upstream status code when available. */
        data class Failed(val error: Throwable?, val httpStatus: Int?) : RelayModelProbeState
    }

    /** Key = (connection id, model id). */
    private val relayModelProbeStatesFlow = MutableStateFlow<Map<Pair<String, String>, RelayModelProbeState>>(emptyMap())
    val relayModelProbeStateFlow: StateFlow<Map<Pair<String, String>, RelayModelProbeState>> = relayModelProbeStatesFlow.asStateFlow()

    /** Lazy verification states of the models under one connection (model id to state). */
    fun relayModelProbeStates(providerID: String): Map<String, RelayModelProbeState> =
        relayModelProbeStatesOf(relayModelProbeStatesFlow.value, providerID)

    private fun setRelayModelProbeState(providerID: String, modelID: String, state: RelayModelProbeState?) {
        val key = normalizeUuid(providerID) to modelID
        relayModelProbeStatesFlow.update { if (state == null) it - key else it + (key to state) }
    }

    private fun clearRelayModelProbeStates(providerID: String) {
        val id = normalizeUuid(providerID)
        relayModelProbeStatesFlow.update { states -> states.filterKeys { it.first != id } }
    }

    /** After the primary key (the only key, when there is one) gets a new value, handle the models whose effective key it is; an unchanged value or removing a key does not count as a new value. */
    private fun onRelayPrimaryKeyReplaced(provider: Provider, previousApiKey: String, nextApiKey: String) {
        if (previousApiKey == nextApiKey || nextApiKey.isBlank()) return
        onRelayKeysReplaced(provider, setOf(ai.oriveo.community.core.provider.relay.RelayKeyBinding.keyIDs(provider).first()))
    }

    /** A send was delivered: clear that model's "not connected" without sending a lazy verification. */
    fun clearRelayModelProbeFailure(providerID: String, modelID: String) {
        val key = normalizeUuid(providerID) to modelID
        relayModelProbeStatesFlow.update { if (it[key] is RelayModelProbeState.Failed) it - key else it }
    }

    /**
     * The keys [keyIDs] got new values: on the latest connection [provider], clear the "not connected" state of the enabled models whose effective key is among them,
     * and re-verify in the background, one by one and through the same entry as the lazy verification after enabling, those that still have no model-level protocol.
     */
    private fun onRelayKeysReplaced(provider: Provider, keyIDs: Set<String>) {
        if (keyIDs.isEmpty()) return
        val id = normalizeUuid(provider.id)
        val bound = provider.models
            .filter { ai.oriveo.community.core.provider.relay.RelayKeyBinding.effectiveKeyID(provider, it.id) in keyIDs }
            .map { it.id }
            .toSet()
        var cleared: List<String> = emptyList()
        relayModelProbeStatesFlow.update { states ->
            val failed = states.filter { (key, state) ->
                key.first == id && key.second in bound && state is RelayModelProbeState.Failed
            }.keys
            cleared = failed.map { it.second }
            states - failed
        }
        val reprobe = provider.models.filter { it.id in cleared && it.relayTransport == null }.map { it.id }
        if (reprobe.isEmpty()) return
        relayProbeScope.launch {
            for (modelID in reprobe) probeEnabledRelayModel(id, modelID)
        }
    }

    /**
     * The CPU stage shared by every write path: relay enrichment (matching each model
     * against the official catalogs), catalog resolution, and JSON encoding of both model
     * lists, all pure O(catalog) work. Most callers run on viewModelScope (Main), and a
     * relay catalog comes from the user's own server and can hold thousands of entries,
     * so leaving this on the main thread turns into dropped frames on save or model switch
     * that grow with the catalog size.
     */
    private suspend fun finalizeForUpsert(
        provider: Provider,
        targetAccountId: String,
    ): Pair<Provider, ProviderEntity> = withContext(cpuDispatcher) {
        // A new relay write carries no default marker and does not persist relayRequested.modelID; the decoding side is untouched.
        val finalized = prepareProviderForUpsert(RelayModelFallback.clearingDefaults(provider))
        finalized to finalized.toEntity(targetAccountId)
    }

    val grokSubscriptionRuntime: GrokSubscriptionRuntime by lazy {
        GrokSubscriptionRuntime(
            credentialStore = GrokSubscriptionCredentialStore(secureKeyStore),
            oauthClient = GrokSubscriptionOAuthClient(httpClient),
            availabilityProvider = { MetadataClient.grokSubscriptionAvailability() },
        )
    }

    suspend fun prepareGrokSubscription(providerId: String): GrokSubscriptionRuntime.PrepareResult =
        grokSubscriptionRuntime.prepare(accountId, normalizeUuid(providerId))

    suspend fun updateGrokSubscriptionCredential(
        providerId: String,
        tokens: GrokSubscriptionTokens,
    ): Provider? {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(providerId)
        grokSubscriptionRuntime.persist(targetAccountId, normalizedId, tokens)
        secureKeyStore.advanceCapabilityConnectionGeneration(targetAccountId, normalizedId)

        saveApiKey(targetAccountId, normalizedId, tokens.accessToken)
        return resyncProvider(normalizedId, targetAccountId).provider
    }

    val openAISubscriptionRuntime: OpenAISubscriptionRuntime by lazy {
        OpenAISubscriptionRuntime(
            credentialStore = OpenAISubscriptionCredentialStore(secureKeyStore),
            oauthClient = OpenAISubscriptionOAuthClient(httpClient),
            availabilityProvider = { MetadataClient.openAISubscriptionAvailability() },
        )
    }

    suspend fun prepareOpenAISubscription(providerId: String): OpenAISubscriptionRuntime.PrepareResult =
        openAISubscriptionRuntime.prepare(accountId, normalizeUuid(providerId))

    suspend fun updateOpenAISubscriptionCredential(
        providerId: String,
        tokens: OpenAISubscriptionTokens,
    ): Provider? {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(providerId)
        openAISubscriptionRuntime.persist(targetAccountId, normalizedId, tokens)
        secureKeyStore.advanceCapabilityConnectionGeneration(targetAccountId, normalizedId)
        saveApiKey(targetAccountId, normalizedId, tokens.accessToken)
        return resyncProvider(normalizedId, targetAccountId).provider
    }
    companion object {
        fun relayModelProbeStatesOf(
            states: Map<Pair<String, String>, RelayModelProbeState>,
            providerID: String,
        ): Map<String, RelayModelProbeState> {
            val id = normalizeUuid(providerID)
            return states.filterKeys { it.first == id }.mapKeys { it.key.second }
        }


        /** Default name of an unnamed connection (the domain); the ungrouped group name in step 2 of the two-step add comes from the same source as the model library after registration. */
        fun relayDomainNameFromEndpoint(endpoint: String): String? {
            val trimmed = endpoint.trim()
            if (trimmed.isEmpty()) return null
            val candidate = if (Regex("^[a-zA-Z][a-zA-Z0-9+\\-.]*://").containsMatchIn(trimmed)) {
                trimmed
            } else {
                "https://$trimmed"
            }
            val host = runCatching { URI(candidate).host?.lowercase() }.getOrNull() ?: return null
            if (host == "localhost" || host.contains(":") || host.matches(Regex("^\\d{1,3}(\\.\\d{1,3}){3}$"))) {
                return host
            }
            val parts = host.split('.').filter { it.isNotEmpty() }
            return if (parts.size <= 2) host else parts.takeLast(2).joinToString(".")
        }

        /**
         * A relay catalog row: the grouping projection of step 2 of the two-step add and the persistence at registration share it, and the grouping matches the catalog refresh ([RelayFamilyHeuristics]),
         * so both sides agree with the model library character for character.
         */
        fun relayCatalogRow(modelID: String): ai.oriveo.community.core.model.AIModel {
            val group = ai.oriveo.community.core.provider.RelayFamilyHeuristics.infer(modelID)
                ?.let(ai.oriveo.community.core.provider.RelayFamilyHeuristics::groupMetadata)
            return ai.oriveo.community.core.model.AIModel(
                id = modelID,
                name = modelID,
                capabilities = listOf(ModelCapability.Text),
                reasoningModeAvailable = false,
                isAvailable = true,
                isDefault = false,
                isManual = false,
                groupKey = group?.first,
                groupName = group?.second,
            )
        }

        const val PROVIDER_INVALID_KEY_MESSAGE =
            "The API key could not be validated. Check the value or generate a new key."
        const val PROVIDER_UNVERIFIED_MESSAGE =
            "We couldn't verify the connection. You can retry from the provider details."
        const val RELAY_UNVERIFIED_MESSAGE = "relay_connection_unverified"

        /** A merged save probes at most twice: if the second probe collides again, the merge is persisted as it is and no verification state is written. */
        private const val RELAY_EDIT_MAX_PROBES = 2

        /** How many times to re-read and re-merge when a concurrent write wins the in-transaction CAS, so continuous writes cannot hang a save. */
        private const val RELAY_EDIT_MERGE_WRITE_ATTEMPTS = 3
        /** How many times to re-read and rewrite when a model-level field write-back collides with a concurrent edit; beyond that the write-back is abandoned. */
        private const val RELAY_MODEL_WRITE_ATTEMPTS = 3
        /**
         * Persistable soft-state key for a failed relay catalog refresh. Only this canonical value may be compared exactly;
         * upstream payloads, URLs and localized text never go into the Provider entity or cloud sync.
         */
        const val RELAY_CATALOG_UNAVAILABLE_MESSAGE = "Could not load the model list."

        const val SUBSCRIPTION_CATALOG_UNAVAILABLE_MESSAGE = "Couldn't load the model list"

        const val CODEX_CATALOG_UNAVAILABLE_MESSAGE =
            "The Codex model list could not be loaded. Refresh the connection from provider details."

        val DEFAULT_MANUAL_MODEL_CAPABILITIES: List<ModelCapability> = listOf(ModelCapability.Text)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private val metadataRefreshSignal: Flow<Unit> = metadataRefreshEventBus.events.mapLatest { Unit }

    @OptIn(ExperimentalCoroutinesApi::class)
    private val providersSharedFlow: SharedFlow<List<Provider>> by lazy {
        combine(
            dao.observeAll(accountId),
            metadataRefreshSignal,
        ) { entities, _ -> entities }.onStart {
            // Must finish before the UI receives its first list, otherwise it flashes the old native channel for one frame.
            try {
                migrateLlamaCppConnectionsOnce(accountId)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                // No marker is stored when a write failed, so the next launch retries.
            }
        }.mapLatest { entities ->
            val knownKinds = ProviderKind.entries.map { it.name }.toSet()
            val sanitizedEntities = entities.filter { entity ->
                entity.kind in knownKinds
            }
            dedupeByNormalizedId(
                items = sanitizedEntities,
                idSelector = { it.id },
                pickPreferred = { existing, incoming ->
                    if (incoming.updatedAt >= existing.updatedAt) incoming else existing
                },
            ).map { entity ->
                normalizeProviderIds(entity.toDomainWithKeys(secureKeyStore.getApiKey(entity.accountId, entity.id).orEmpty()))
            }.map { provider -> backfillEndpointSource(provider, accountId) }
        }.flowOn(Dispatchers.IO)
            .shareIn(externalScope, SharingStarted.WhileSubscribed(5_000L), replay = 1)
    }

    fun observeAll(): Flow<List<Provider>> = providersSharedFlow

    /**
     * Backfill of the address source of official records and the lazy migration, written back to this device: only the source and literal-address columns are written,
     * updatedAt is not changed and no upload is triggered; already-classified records run too. For the rules see [OfficialEndpointSource.startupBackfill].
     */
    private suspend fun backfillEndpointSource(provider: Provider, expectedAccountId: String): Provider {
        val next = OfficialEndpointSource.startupBackfill(provider) ?: return provider
        val source = next.endpointSource ?: return provider
        try {
            dao.reconcileEndpointSource(
                accountId = expectedAccountId,
                id = normalizeUuid(provider.id),
                expectedSource = provider.endpointSource,
                expectedBaseUrlText = provider.baseUrlText,
                source = source,
                baseUrlText = next.baseUrlText,
            )
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // A failed write-back only affects whether it needs computing again next time; this read still uses the migrated result.
        }
        return next
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeById(id: String): Flow<Provider?> =
        dao.observeById(accountId, normalizeUuid(id)).mapLatest { entity ->
            withContext(Dispatchers.IO) {
                entity?.takeIf { it.kind in ProviderKind.entries.map { kind -> kind.name } }?.let {
                    normalizeProviderIds(it.toDomainWithKeys(loadApiKey(it.accountId, it.id)))
                }
            }
        }

    suspend fun getProviderByKind(kind: ProviderKind): Provider? {
        val entity = dao.getAll(accountId).firstOrNull { it.kind == kind.name } ?: return null
        val apiKey = loadApiKey(entity.accountId, entity.id)
        return normalizeProviderIds(entity.toDomainWithKeys(apiKey))
    }

    suspend fun getById(id: String): Provider? {
        val targetAccountId = accountId
        return getById(targetAccountId, id)
    }

    private suspend fun getById(targetAccountId: String, id: String): Provider? {
        val normalizedId = normalizeUuid(id)
        val entity = dao.getById(targetAccountId, normalizedId) ?: return null
        if (entity.kind !in ProviderKind.entries.map { it.name }) return null
        val apiKey = loadApiKey(entity.accountId, entity.id)
        // Decoding the whole model catalog is pure O(catalog) work: a relay catalog comes from the user's own
        // server (tens of thousands of entries on some public relays), and selecting or enabling a model in the
        // Home model picker calls this from viewModelScope (Main).
        return withContext(cpuDispatcher) { normalizeProviderIds(entity.toDomainWithKeys(apiKey)) }
    }

    suspend fun registerProvider(
        kind: ProviderKind,
        apiKey: String,
        preferredModelID: String? = null,
        baseUrl: String? = null,
        customName: String? = null,
        relayKind: RelayKind? = null,
        relayRequested: RelayRequestedConfig? = null,
        relayImage: RelayImageConfig? = null,

        preferredCapabilities: Set<ai.oriveo.community.core.model.ModelCapability> = emptySet(),

        isAdditionalInstance: Boolean = false,

        authMode: ProviderAuthMode = ProviderAuthMode.ApiKey,

        subscriptionTokens: GrokSubscriptionTokens? = null,

        openAISubscriptionTokens: OpenAISubscriptionTokens? = null,
        // Address source and extra field values of the official setup page. When omitted, the classification function before persisting derives
        // default / region:<id> from the literal address, matching what the setup page would write explicitly; the setup page passes them explicitly only for address templates (with setupFields).
        endpointSource: String? = null,
        setupValues: Map<String, String>? = null,
    ): Provider {
        val targetAccountId = accountId
        val isRelay = kind == ProviderKind.Relay
        val service = serviceFor(kind)
        val syncResult = if (isRelay) {

            try {
                withContext(Dispatchers.IO) {
                    service.syncProvider(
                        apiKey = apiKey,
                        preferredModelID = preferredModelID,
                        baseUrl = baseUrl ?: kind.defaultBaseUrl,
                    )
                }
            } catch (_: ProviderServiceError) {
                ProviderSyncResult(models = emptyList())
            }
        } else {
            ProviderSyncResult(models = emptyList())
        }

        val resolvedRelayRequested = if (isRelay) {
            relayRequested ?: RelayKindDefaults.makeRequested(
                relayKind ?: RelayKind.OpenAICompatible,
                preserving = RelayRequestedConfig(modelID = preferredModelID?.trim()?.takeIf { it.isNotEmpty() }),
            )
        } else {
            null
        }

        val providerID = if (!isRelay && !isAdditionalInstance) {
            // The region segment only consults the frozen identity table: a region source wins, otherwise it is looked up from the base URL at registration; homes outside the table get an empty string.
            val regionId = DeterministicProviderId.identityRegionId(kind, baseUrl, endpointSource)
            DeterministicProviderId.forProvider(kind, regionId)
        } else {
            normalizeUuid(generateUuidString())
        }

        secureKeyStore.beginCapabilityConnection(targetAccountId, providerID)
        saveApiKey(targetAccountId, providerID, apiKey)
        subscriptionTokens?.let { tokens ->
            grokSubscriptionRuntime.persist(targetAccountId, providerID, tokens)
        }
        openAISubscriptionTokens?.let { tokens ->
            openAISubscriptionRuntime.persist(targetAccountId, providerID, tokens)
        }

        val subscriptionInstanceName = if (!isRelay && authMode == ProviderAuthMode.Subscription) {
            customName?.let {
                makeUniqueProviderInstanceName(
                    desiredName = it,
                    kind = kind,
                    fallbackName = kind.displayName,
                    expectedAccountId = targetAccountId,
                )
            } ?: makeDefaultProviderInstanceName(kind, targetAccountId)
        } else {
            null
        }

        val provider = if (!isRelay && authMode == ProviderAuthMode.Subscription &&
            kind == ProviderKind.OpenAI
        ) {
            buildOpenAISubscriptionEnabled(
                providerID = providerID,
                kind = kind,
                accessToken = apiKey,

                accountId = openAISubscriptionTokens?.accountId,
                baseUrl = baseUrl,
                customName = subscriptionInstanceName,
                existingEnabledModels = emptyList(),
                preferredModelID = preferredModelID,
            )
        } else if (!isRelay && authMode == ProviderAuthMode.Subscription) {
            buildSubscriptionEnabled(
                providerID = providerID,
                kind = kind,
                accessToken = apiKey,
                baseUrl = baseUrl,
                customName = subscriptionInstanceName,
                existingEnabledModels = emptyList(),
                preferredModelID = preferredModelID,
            )
        } else if (isRelay) {

            val catalogModels = ModelSelectionUtils.mergeManualModels(
                existingModels = emptyList(),
                syncedModels = ensurePreferredRelayModel(
                    syncResult.models,
                    preferredModelID,
                    preferredCapabilities,
                ),
                providerKind = kind,
            )
            val enabledModels = ModelSelectionUtils.makeEnabledModels(
                existingEnabledModels = emptyList(),
                catalogModels = catalogModels,
                providerKind = kind,
            )
            ModelSelectionUtils.synchronizeDefaultSelection(
                provider = buildPersistedProvider(
                    providerID = providerID,
                    kind = kind,
                    apiKey = apiKey,
                    baseUrl = baseUrl,
                    customName = makeUniqueProviderInstanceName(
                        desiredName = customName,
                        kind = kind,
                        fallbackName = relayDomainNameFromEndpoint(baseUrl.orEmpty()) ?: kind.displayName,
                        expectedAccountId = targetAccountId,
                    ),
                    models = enabledModels,
                    catalogModels = catalogModels,
                    relayKind = relayKind ?: RelayKind.OpenAICompatible,
                    relayRequested = resolvedRelayRequested,
                    relayImage = relayImage,
                ),
                preferredModelId = preferredModelID ?: enabledModels.firstOrNull { it.isDefault }?.id,
            )
        } else {

            buildOfficialEnabled(
                providerID = providerID,
                kind = kind,
                apiKey = apiKey,
                baseUrl = baseUrl,
                customName = customName?.let {
                    makeUniqueProviderInstanceName(
                        desiredName = it,
                        kind = kind,
                        fallbackName = kind.displayName,
                        expectedAccountId = targetAccountId,
                    )
                } ?: makeDefaultProviderInstanceName(kind, targetAccountId),
                existingEnabledModels = emptyList(),
                existingCatalogModels = emptyList(),
                preferredModelID = preferredModelID,
            )
        }

        val sourcedProvider = if (!isRelay && (endpointSource != null || setupValues != null)) {
            provider.copy(endpointSource = endpointSource, setupValues = setupValues)
        } else {
            provider
        }
        val enrichedProvider = upsertProviderEntity(sourcedProvider, targetAccountId)
        val normalizedProvider = normalizeProviderIds(enrichedProvider)
        normalizeConversationSelections(normalizedProvider, targetAccountId)

        metadataRefreshEventBus.dispatch(
            ai.oriveo.community.core.data.remote.MetadataClient.RefreshEvent(
                version = MetadataClient.version,
                contractVersion = MetadataClient.contractVersion,
            )
        )

        return normalizedProvider
    }

    private suspend fun makeDefaultProviderInstanceName(
        kind: ProviderKind,
        expectedAccountId: String,
    ): String? {
        return makeUniqueProviderInstanceName(
            desiredName = kind.displayName,
            kind = kind,
            fallbackName = kind.displayName,
            expectedAccountId = expectedAccountId,
        )
    }

    private suspend fun makeUniqueProviderInstanceName(
        desiredName: String?,
        kind: ProviderKind,
        excludingId: String? = null,
        fallbackName: String,
        expectedAccountId: String,
    ): String {
        val baseName = desiredName?.trim()?.takeIf { it.isNotEmpty() } ?: fallbackName
        val existingNames = dao.getAll(expectedAccountId)
            .filter { it.kind == kind.name }
            .filter { excludingId == null || !sameNormalizedUuid(it.id, excludingId) }
            .map { entity ->
                entity.customName?.trim()?.takeIf { it.isNotEmpty() } ?: kind.displayName
            }
            .map { normalizeProviderName(it) }
            .toSet()

        if (normalizeProviderName(baseName) !in existingNames) {
            return baseName
        }

        val suffixBaseName = baseName.replace(Regex("\\s+\\d+$"), "")
        var suffix = 2
        while (normalizeProviderName("$suffixBaseName $suffix") in existingNames) {
            suffix += 1
        }
        return "$suffixBaseName $suffix"
    }

    private fun normalizeProviderName(name: String): String =
        name.trim().replace(Regex("\\s+"), " ").lowercase()

    suspend fun registerRelayProvider(
        apiKey: String,
        baseUrl: String,
        customName: String?,
        relayKind: RelayKind,
        relayRequested: RelayRequestedConfig,
        catalogModelIDs: List<String> = emptyList(),
        preferredModelID: String? = null,
        preferredCapabilities: Set<ai.oriveo.community.core.model.ModelCapability> = emptySet(),
        runtimeMetadata: Map<String, ai.oriveo.community.core.model.LocalModelRuntimeMetadata> = emptyMap(),
        connectionVerified: Boolean = true,
        commitGuard: () -> Boolean = { true },
        /** The first probe that passed for the default model at add time; it is written in the same write as registration, onto the default model and resolvedAPIBaseURLs. */
        preferredModelProbe: ai.oriveo.community.core.provider.relay.RelayModelProbePass? = null,
        /** Per-model capability declarations resolved by the local engine connector, written into [AIModel.engineDeclaration] by model id. */
        engineDeclarations: Map<String, ai.oriveo.community.core.model.EngineDeclaration> = emptyMap(),
        /** Two-step add: keys other than the primary key, added one after another after registration. */
        extraKeys: List<ai.oriveo.community.core.model.RelayKey> = emptyList(),
        /** Name of the primary key when there are 2 or more keys; not written when there is only one. */
        primaryKeyName: String? = null,
        /** Catalogs fetched per key in step 1 (key = key id, the primary key has the implicit id); with 2 or more keys they are merged to write the listing keys and statuses. */
        keyCatalogs: Map<String, ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch> = emptyMap(),
        /** Every model ticked in step 2 of the two-step add (display order); when non-null, exactly these are enabled and bound to keys one by one, and ones not in the catalog are stored as manual models. */
        enabledModelIDs: List<String>? = null,
    ): Provider {
        if (!commitGuard()) throw kotlinx.coroutines.CancellationException("stale relay registration")
        val targetAccountId = accountId
        val providerID = normalizeUuid(generateUuidString())
        secureKeyStore.beginCapabilityConnection(targetAccountId, providerID)

        val uniqueCatalogIDs = catalogModelIDs.map(String::trim).filter(String::isNotEmpty).distinct()
        // The catalog rows of a remote relay carry groups (same as the catalog refresh), so the model library does not put everything in one group before the first refresh; a local engine is unchanged.
        val groupsCatalog = relayRequested.engineProfile == null
        val discoveredCatalog = uniqueCatalogIDs.map { modelID ->
            val runtime = runtimeMetadata[modelID]
            val group = if (groupsCatalog) relayCatalogRow(modelID) else null
            ai.oriveo.community.core.model.AIModel(
                groupKey = group?.groupKey,
                groupName = group?.groupName,
                id = modelID,
                name = modelID,
                capabilities = listOf(ModelCapability.Text),
                reasoningModeAvailable = false,
                isAvailable = true,
                isDefault = false,
                isManual = false,
                generationProfile = ai.oriveo.community.core.provider.LocalEngineGenerationProfiles.profile(relayRequested.engineProfile, relayRequested.transport),
                localLoadState = runtime?.loadState,
                executionLocality = runtime?.executionLocality,
                engineDeclaration = engineDeclarations[modelID],
            )
        }
        val preferredID = preferredModelID?.trim()?.takeIf(String::isNotEmpty)
            ?: uniqueCatalogIDs.firstOrNull()
        val catalogModels = ensurePreferredRelayModel(
            models = discoveredCatalog,
            preferredModelID = preferredID,
            preferredCapabilities = preferredCapabilities,
        ).map { model -> model.copy(isDefault = model.id == preferredID) }
        val enabledModels = ModelSelectionUtils.makeEnabledModels(
            existingEnabledModels = emptyList(),
            catalogModels = catalogModels,
            providerKind = ProviderKind.Relay,
        )
        val provider = ModelSelectionUtils.synchronizeDefaultSelection(
            provider = buildPersistedProvider(
                providerID = providerID,
                kind = ProviderKind.Relay,
                apiKey = apiKey,
                baseUrl = baseUrl,
                customName = makeUniqueProviderInstanceName(
                    desiredName = customName,
                    kind = ProviderKind.Relay,
                    fallbackName = relayDomainNameFromEndpoint(baseUrl) ?: ProviderKind.Relay.displayName,
                    expectedAccountId = targetAccountId,
                ),
                models = enabledModels,
                catalogModels = catalogModels,
                relayKind = relayKind,
                relayRequested = relayRequested,
            ).copy(
                status = if (connectionVerified) {
                    ProviderConnectionState.Connected
                } else {
                    ProviderConnectionState.Issue(RELAY_UNVERIFIED_MESSAGE)
                },
                lastError = RELAY_UNVERIFIED_MESSAGE.takeUnless { connectionVerified },
            ),
            preferredModelId = preferredID ?: enabledModels.firstOrNull { it.isDefault }?.id,
        ).let { built ->
            if (enabledModelIDs == null) {
                built
            } else {
                withRelaySetupSelection(built, uniqueCatalogIDs, extraKeys, primaryKeyName, keyCatalogs, enabledModelIDs)
            }
        }.let { built ->
            if (preferredModelProbe == null || preferredID == null) {
                built
            } else {
                ai.oriveo.community.core.provider.relay.RelayModelProbe.applyingPass(built, preferredID, preferredModelProbe)
            }
        }

        if (!commitGuard()) throw kotlinx.coroutines.CancellationException("stale relay registration")
        saveApiKey(targetAccountId, providerID, apiKey)
        if (!commitGuard()) {
            deleteApiKey(targetAccountId, providerID)
            throw kotlinx.coroutines.CancellationException("stale relay registration")
        }
        val write = guardedInsertRelayProvider(provider, targetAccountId, commitGuard)
        if (write == null) {
            deleteApiKey(targetAccountId, providerID)
            throw kotlinx.coroutines.CancellationException("stale relay registration")
        }
        if (!commitGuard()) {
            rollbackRelayRegistrationIfUnchanged(write, targetAccountId)
            throw kotlinx.coroutines.CancellationException("stale relay registration")
        }
        val normalizedProvider = normalizeProviderIds(write.provider)
        if (!commitGuard()) {

            return normalizedProvider
        }
        metadataRefreshEventBus.dispatch(
            ai.oriveo.community.core.data.remote.MetadataClient.RefreshEvent(
                version = MetadataClient.version,
                contractVersion = MetadataClient.contractVersion,
            )
        )

        return normalizedProvider
    }

    /**
     * Persisted shape of the two-step add: add the remaining keys, merge each key's catalog to write the listing keys and statuses, then enable every ticked model in display order and bind keys one by one.
     * The key binding is the same [ai.oriveo.community.core.provider.relay.RelayKeyBinding.bindInOrder] as the key chip in step 2.
     */
    private fun withRelaySetupSelection(
        provider: Provider,
        catalogIDs: List<String>,
        extraKeys: List<ai.oriveo.community.core.model.RelayKey>,
        primaryKeyName: String?,
        keyCatalogs: Map<String, ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch>,
        enabledModelIDs: List<String>,
    ): Provider {
        val binding = ai.oriveo.community.core.provider.relay.RelayKeyBinding
        var keyed = provider
        extraKeys.forEach { key -> keyed = binding.add(keyed, key.id, key.name, key.apiKey) ?: keyed } // key-choke: stored-field
        if (extraKeys.isNotEmpty()) {
            primaryKeyName?.trim()?.takeIf(String::isNotEmpty)?.let { name ->
                keyed = binding.rename(keyed, binding.keyIDs(keyed).first(), name) ?: keyed
            }
        }
        val keyIDs = binding.keyIDs(keyed)
        val catalogSet = catalogIDs.toSet()
        // Keep only the rows the catalog really lists (if the first ticked model was typed by hand, it does not go into the catalog).
        val baseCatalog = keyed.catalogModels.filter { it.id in catalogSet }
        val merge = if (keyIDs.size >= 2) binding.mergeCatalog(keyIDs, emptyList(), keyCatalogs) else null
        val listing = merge?.catalog?.associate { it.id to it.relayListedByKeyIDs }
        val catalog = if (listing == null) baseCatalog else baseCatalog.map { it.copy(relayListedByKeyIDs = listing[it.id]) }
        // Enabling and de-duplication use the same criterion: equal after trim and ignoring case counts as the same one, and the spelling that came first wins.
        val uniqueEnabledIDs = enabledModelIDs.map(String::trim).filter(String::isNotEmpty).distinctBy { it.lowercase() }
        val bound = binding.bindInOrder(keyIDs, catalog, uniqueEnabledIDs, binding::cachedFamily)
        val enabled = uniqueEnabledIDs.map { id ->
            val model = catalog.firstOrNull { it.id == id } ?: relayCatalogRow(id).copy(isManual = true)
            model.copy(relayKeyID = bound[id])
        }
        val selected = keyed.copy(models = enabled, catalogModels = catalog)
        return if (merge == null) {
            selected
        } else {
            ai.oriveo.community.core.provider.relay.RelayKeyAccess.withKeyStatuses(selected, merge.statuses, System.currentTimeMillis())
        }
    }

    private suspend fun buildSubscriptionEnabled(
        providerID: String,
        kind: ProviderKind,
        accessToken: String,
        baseUrl: String?,
        customName: String?,
        existingEnabledModels: List<ai.oriveo.community.core.model.AIModel>,
        preferredModelID: String? = null,
    ): Provider {
        withContext(Dispatchers.IO) { MetadataClient.refresh() }
        withContext(Dispatchers.IO) { MetadataClient.refreshModelFacts() }

        val seed = Provider(
            id = providerID,
            kind = kind,
            status = ProviderConnectionState.Connected,
            models = existingEnabledModels,
            catalogModels = emptyList(),
            lastCheckedAt = System.currentTimeMillis(),
            apiKey = accessToken,

            apiKeyPreview = "",
            baseUrlText = baseUrl ?: kind.defaultBaseUrl,
            customName = customName,
            authMode = ProviderAuthMode.Subscription,
        )

        val availability = MetadataClient.grokSubscriptionAvailability()
        val config = (availability as? GrokSubscriptionAvailability.Available)?.config
            ?: return seed.copy(lastError = SUBSCRIPTION_CATALOG_UNAVAILABLE_MESSAGE)

        val descriptors = runCatching {
            withContext(Dispatchers.IO) {
                GrokSubscriptionOAuthClient(httpClient).fetchModels(config, accessToken)
            }
        }.getOrElse { error ->
            if (error is kotlinx.coroutines.CancellationException) throw error
            return seed.copy(lastError = SUBSCRIPTION_CATALOG_UNAVAILABLE_MESSAGE)
        }
        if (descriptors.isEmpty()) return seed.copy(lastError = SUBSCRIPTION_CATALOG_UNAVAILABLE_MESSAGE)

        val catalogModels = descriptors.map { descriptor ->
            val base = ai.oriveo.community.core.provider.CatalogModelBuilder.buildCatalogModel(
                providerKind = kind,
                runtimeModelId = descriptor.id,
                fallbackName = descriptor.displayName ?: descriptor.id,
                fallbackContextLength = descriptor.contextWindow,
            )
            val capabilities = buildList {
                add(ai.oriveo.community.core.model.ModelCapability.Text)
                if (descriptor.supportsWebSearch) add(ai.oriveo.community.core.model.ModelCapability.Web)
                if (descriptor.supportsReasoning) add(ai.oriveo.community.core.model.ModelCapability.Reasoning)
            }
            base.copy(
                capabilities = capabilities,
                reasoningModeAvailable = descriptor.supportsReasoning,

                upstreamReasoningLevels = descriptor.reasoningEfforts,
                upstreamDefaultReasoningLevel = descriptor.defaultReasoningEffort,
                upstreamApiBackend = descriptor.apiBackend,
            )
        }
        val preferredDefaultId = preferredModelID?.takeIf { candidate ->
            catalogModels.any { it.id == candidate }
        } ?: existingEnabledModels.firstOrNull { it.isDefault }?.id?.takeIf { candidate ->
            catalogModels.any { it.id == candidate }
        } ?: catalogModels.firstOrNull()?.id

        return ModelSelectionUtils.synchronizeDefaultSelection(
            provider = seed.copy(models = catalogModels, catalogModels = catalogModels),
            preferredModelId = preferredDefaultId,
        )
    }

    private suspend fun buildOpenAISubscriptionEnabled(
        providerID: String,
        kind: ProviderKind,
        accessToken: String,
        accountId: String?,
        baseUrl: String?,
        customName: String?,
        existingEnabledModels: List<ai.oriveo.community.core.model.AIModel>,
        preferredModelID: String? = null,
    ): Provider {
        withContext(Dispatchers.IO) { MetadataClient.refresh() }
        withContext(Dispatchers.IO) { MetadataClient.refreshModelFacts() }

        val seed = Provider(
            id = providerID,
            kind = kind,
            status = ProviderConnectionState.Connected,
            models = existingEnabledModels,
            catalogModels = emptyList(),
            lastCheckedAt = System.currentTimeMillis(),
            apiKey = accessToken,

            apiKeyPreview = "",
            baseUrlText = baseUrl ?: kind.defaultBaseUrl,
            customName = customName,
            authMode = ProviderAuthMode.Subscription,
        )

        val availability = MetadataClient.openAISubscriptionAvailability()
        val config = (availability as? OpenAISubscriptionAvailability.Available)?.config
            ?: return seed.copy(lastError = CODEX_CATALOG_UNAVAILABLE_MESSAGE)

        val resolvedAccountId = accountId?.trim()?.takeIf { it.isNotEmpty() }

            ?: return seed.copy(lastError = CODEX_CATALOG_UNAVAILABLE_MESSAGE)

        val descriptors = runCatching {
            withContext(Dispatchers.IO) {
                OpenAISubscriptionOAuthClient(httpClient)
                    .fetchModels(config, accessToken, resolvedAccountId)
            }
        }.getOrElse { error ->
            if (error is kotlinx.coroutines.CancellationException) throw error
            return seed.copy(lastError = codexCatalogFailureMessage(error))
        }
        if (descriptors.isEmpty()) return seed.copy(lastError = CODEX_CATALOG_UNAVAILABLE_MESSAGE)

        val catalogModels = descriptors.map { descriptor ->
            val base = ai.oriveo.community.core.provider.CatalogModelBuilder.buildCatalogModel(
                providerKind = kind,
                runtimeModelId = descriptor.slug,
                fallbackName = descriptor.displayName ?: descriptor.slug,
                fallbackContextLength = descriptor.contextWindow,
            )
            val capabilities = buildList {
                add(ai.oriveo.community.core.model.ModelCapability.Text)
                if (descriptor.supportsWebSearch) add(ai.oriveo.community.core.model.ModelCapability.Web)
                if (descriptor.supportsReasoning) add(ai.oriveo.community.core.model.ModelCapability.Reasoning)
                if (descriptor.supportsImageInput) add(ai.oriveo.community.core.model.ModelCapability.Image)
            }
            base.copy(
                capabilities = capabilities,
                reasoningModeAvailable = descriptor.supportsReasoning,
                upstreamReasoningLevels = descriptor.supportedReasoningLevels,
            )
        }

        val preferredDefaultId = preferredModelID?.takeIf { candidate ->
            catalogModels.any { it.id == candidate }
        } ?: existingEnabledModels.firstOrNull { it.isDefault }?.id?.takeIf { candidate ->
            catalogModels.any { it.id == candidate }
        } ?: catalogModels.firstOrNull()?.id

        return ModelSelectionUtils.synchronizeDefaultSelection(
            provider = seed.copy(models = catalogModels, catalogModels = catalogModels),
            preferredModelId = preferredDefaultId,
        )
    }

    private fun codexCatalogFailureMessage(error: Throwable): String =
        (error as? OpenAISubscriptionException)?.error?.toProviderServiceError()?.userMessage
            ?: CODEX_CATALOG_UNAVAILABLE_MESSAGE

    private suspend fun buildOfficialEnabled(
        providerID: String,
        kind: ProviderKind,
        apiKey: String,
        baseUrl: String?,
        customName: String?,
        existingEnabledModels: List<ai.oriveo.community.core.model.AIModel>,
        existingCatalogModels: List<ai.oriveo.community.core.model.AIModel>,
        preferredModelID: String? = null,
    ): Provider {
        // Conditionally refresh the index plus this provider's catalog: a provider being added
        // may not be in the needed catalog set yet.
        withContext(Dispatchers.IO) { MetadataClient.refresh(setOf(kind)) }

        val seedProvider = Provider(
            id = providerID,
            kind = kind,
            status = ProviderConnectionState.Connected,
            models = existingEnabledModels,
            catalogModels = existingCatalogModels,
            lastCheckedAt = System.currentTimeMillis(),
            apiKey = apiKey,
            apiKeyPreview = SecureKeyStore.maskApiKey(apiKey),
            baseUrlText = baseUrl ?: kind.defaultBaseUrl,
            customName = customName,
        )

        val resolved = ProviderCatalogResolver.resolve(seedProvider)
        val canonicalCatalogModels = resolved.catalog
            .filter { !it.isManual }
            .map { it.model }
        val resolverEnabled = resolved.enabledModels.map { it.model }
        val manualModels = resolved.catalog.filter { it.isManual }.map { it.model }
        val hasLegacyAutoEnabledAll = looksLikeLegacyAutoEnabledAll(seedProvider, canonicalCatalogModels)

        val enabledModels = if (hasLegacyAutoEnabledAll) {
            ModelSelectionUtils.initialEnabledModels(canonicalCatalogModels, seedProvider.kind)
        } else if (resolverEnabled.isNotEmpty() || manualModels.isNotEmpty()) {

            (resolverEnabled + manualModels).distinctBy { it.id }
        } else if (canonicalCatalogModels.isNotEmpty()) {
            ModelSelectionUtils.initialEnabledModels(canonicalCatalogModels, seedProvider.kind)
        } else {
            emptyList()
        }

        val preferredDefaultId = preferredModelID
            ?: existingEnabledModels.firstOrNull { it.isDefault }?.id
            ?: resolved.defaultModel?.model?.id
            ?: enabledModels.firstOrNull()?.id

        val updated = ModelSelectionUtils.synchronizeDefaultSelection(
            provider = seedProvider.copy(models = enabledModels, catalogModels = emptyList()),
            preferredModelId = preferredDefaultId,
        )
        val pruned = ManualRetainedPruner.prune(updated)

        val validation = ProviderKeyValidator.validate(
            provider = pruned,
            apiKey = apiKey,
            client = httpClient,
        )
        return applyValidationOutcome(validation, pruned)
    }

    private fun applyValidationOutcome(
        result: ProviderKeyValidator.Result,
        provider: Provider,
    ): Provider {
        val checkedAt = System.currentTimeMillis()
        return when (result) {
            is ProviderKeyValidator.Result.Valid -> provider.copy(
                status = ProviderConnectionState.Connected,
                lastCheckedAt = checkedAt,
                lastError = null,
            )
            is ProviderKeyValidator.Result.Invalid -> {
                val key = PROVIDER_INVALID_KEY_MESSAGE
                provider.copy(
                    status = ProviderConnectionState.Issue(key),
                    lastCheckedAt = checkedAt,
                    lastError = key,
                )
            }
            is ProviderKeyValidator.Result.Unverified -> provider.copy(

                status = ProviderConnectionState.Connected,
                lastCheckedAt = checkedAt,
                lastError = PROVIDER_UNVERIFIED_MESSAGE,
            )
        }
    }

    private fun buildPersistedProvider(
        providerID: String,
        kind: ProviderKind,
        apiKey: String,
        baseUrl: String?,
        customName: String?,
        models: List<ai.oriveo.community.core.model.AIModel>,
        catalogModels: List<ai.oriveo.community.core.model.AIModel>,
        relayRequested: ai.oriveo.community.core.model.RelayRequestedConfig? = null,
        relayImage: ai.oriveo.community.core.model.RelayImageConfig? = null,
        relayKind: RelayKind? = null,
    ): Provider = Provider(
        id = providerID,
        kind = kind,
        status = ProviderConnectionState.Connected,
        models = models,
        catalogModels = catalogModels,
        lastCheckedAt = System.currentTimeMillis(),
        apiKey = apiKey,
        apiKeyPreview = SecureKeyStore.maskApiKey(apiKey),
        baseUrlText = baseUrl ?: kind.defaultBaseUrl,
        customName = customName,
        relayKind = relayKind,
        relayRequested = relayRequested,
        relayImage = relayImage,
    )

    private fun ensurePreferredRelayModel(
        models: List<ai.oriveo.community.core.model.AIModel>,
        preferredModelID: String?,
        preferredCapabilities: Set<ai.oriveo.community.core.model.ModelCapability> = emptySet(),
    ): List<ai.oriveo.community.core.model.AIModel> {
        val id = preferredModelID?.trim()?.takeIf { it.isNotEmpty() } ?: return models
        val orderedCaps = listOf(
            ai.oriveo.community.core.model.ModelCapability.Reasoning,
            ai.oriveo.community.core.model.ModelCapability.Text,
            ai.oriveo.community.core.model.ModelCapability.Image,
            ai.oriveo.community.core.model.ModelCapability.File,
            ai.oriveo.community.core.model.ModelCapability.Web,
            ai.oriveo.community.core.model.ModelCapability.ImageGen,
        )

        val mergedCaps = orderedCaps.filter {
            it in (preferredCapabilities + ai.oriveo.community.core.model.ModelCapability.Text)
        }
        if (models.any { it.id == id }) {
            if (preferredCapabilities.isEmpty()) return models
            return models.map { existing ->
                if (existing.id != id) existing
                else existing.copy(
                    capabilities = mergedCaps,
                    reasoningModeAvailable = existing.reasoningModeAvailable ||
                        ai.oriveo.community.core.model.ModelCapability.Reasoning in preferredCapabilities,
                    imageGenProfile = existing.imageGenProfile
                        ?: if (ai.oriveo.community.core.model.ModelCapability.ImageGen in mergedCaps) "default" else null,
                )
            }
        }
        return models + ai.oriveo.community.core.model.AIModel(
            id = id,
            name = id,
            capabilities = mergedCaps,
            reasoningModeAvailable = ai.oriveo.community.core.model.ModelCapability.Reasoning in preferredCapabilities,
            isDefault = models.none { it.isDefault },
            imageGenProfile = if (ai.oriveo.community.core.model.ModelCapability.ImageGen in mergedCaps) "default" else null,
            isManual = true,
        )
    }

    suspend fun resyncProvider(id: String) {
        val targetAccountId = accountId
        resyncProvider(
            id = id,
            targetAccountId = targetAccountId,
            commitGuard = { true },
            failClosed = false,
        )
    }

    suspend fun resyncProviderForModeTransition(
        id: String,
        commitGuard: () -> Boolean,
    ): ProviderResyncOutcome = resyncProvider(
        id = id,
        targetAccountId = accountId,
        commitGuard = commitGuard,
        failClosed = true,
    )

    data class ProviderResyncOutcome(
        val provider: Provider?,
        val catalogSucceeded: Boolean,
        val stale: Boolean = false,
        val error: Throwable? = null,
    )

    enum class RelayCatalogRefreshState {
        NotRequested,
        Available,
        Empty,
        Failed,
    }

    data class RelayEditOutcome(
        val provider: Provider?,
        val persisted: Boolean,
        val verificationSucceeded: Boolean,
        val catalogState: RelayCatalogRefreshState = RelayCatalogRefreshState.NotRequested,
        val stale: Boolean = false,
        val error: Throwable? = null,
        val failureRevision: RelayEditRevision? = null,
        val persistedRevision: RelayEditRevision? = null,
        /** At the moment of persisting, the connection identity of "merged vs live record" had changed: the catalog has been cleared, and after saving the caller refreshes the catalog from [persistedRevision]. */
        val catalogInvalidated: Boolean = false,
    )

    data class RelayGenerationVerificationOutcome(
        val provider: Provider?,
        val attemptedProvider: Provider?,
        val verificationSucceeded: Boolean,
        val stale: Boolean = false,
        val error: Throwable? = null,
    )

    class RelayEditRevision internal constructor(
        internal val expectedEntity: ProviderEntity,
        /** The verdict of this failed verification request on the key, the key it was sent with and the value used; on "Save anyway" it is written only if that key's value is unchanged. In memory only. */
        internal val failedKeyStatus: ai.oriveo.community.core.model.RelayKeyStatus? = null,
        internal val failedKeyID: String? = null,
        internal val failedApiKey: String? = null,
    )

    private suspend fun resyncProvider(
        id: String,
        targetAccountId: String,
        commitGuard: () -> Boolean = { true },
        failClosed: Boolean = false,
    ): ProviderResyncOutcome {
        if (!commitGuard()) return ProviderResyncOutcome(null, catalogSucceeded = false, stale = true)
        val normalizedId = normalizeUuid(id)
        val originalEntity = dao.getById(targetAccountId, normalizedId)
            ?: return ProviderResyncOutcome(null, catalogSucceeded = false)
        // A catalog resync is a D5 lifecycle boundary. The next decision must learn again from
        // the newly fetched model list instead of reviving an observation from the old catalog.
        toolCallMemoryStore?.clearConnection(targetAccountId, normalizedId)
        val provider = normalizeProviderIds(
            originalEntity.toDomainWithKeys(loadApiKey(originalEntity.accountId, originalEntity.id)),
        )

        // Only the index and this provider's catalog are fetched.
        MetadataClient.refresh(setOf(provider.kind))
        val isRelay = provider.kind == ProviderKind.Relay
        var expectedEntity = originalEntity
        // Statuses of each key when fetching failed for all of a multi-key relay; they are persisted together with the failure write-back.
        var failedKeyStatuses: Map<String, ai.oriveo.community.core.model.RelayKeyStatus> = emptyMap()

        try {
            val syncingWrite = guardedPersistExistingProvider(
                provider = provider.copy(status = ProviderConnectionState.Syncing),
                expectedEntity = expectedEntity,
                targetAccountId = targetAccountId,
                commitGuard = commitGuard,
                normalizeConversations = false,
            ) ?: return ProviderResyncOutcome(null, false, stale = true)
            expectedEntity = syncingWrite.entity

            val persisted = if (isRelay) {
                resyncRelay(provider, targetAccountId, expectedEntity, commitGuard) { failedKeyStatuses = it }
            } else if (provider.authMode == ProviderAuthMode.Subscription &&
                provider.kind == ProviderKind.OpenAI
            ) {

                resyncOpenAISubscriptionProvider(provider, targetAccountId, expectedEntity, commitGuard)
            } else if (provider.authMode == ProviderAuthMode.Subscription) {

                resyncSubscriptionProvider(provider, targetAccountId, expectedEntity, commitGuard)
            } else {
                resyncOfficialProvider(provider, targetAccountId, expectedEntity, commitGuard)
            }
            return if (persisted == null) {
                ProviderResyncOutcome(null, catalogSucceeded = false, stale = true)
            } else {
                ProviderResyncOutcome(persisted, catalogSucceeded = true)
            }
        } catch (e: Exception) {

            if (e is kotlinx.coroutines.CancellationException) throw e

            val providerError = e as? ProviderServiceError
            val errorMsg = when (e) {

                is ProviderServiceError.RelayUpstream -> RELAY_UNVERIFIED_MESSAGE
                is ProviderServiceError -> e.userMessage
                else -> if (failClosed) RELAY_UNVERIFIED_MESSAGE else e.message ?: "Unknown error"
            }
            val isFatalError = providerError is ProviderServiceError.InvalidAPIKey ||
                providerError is ProviderServiceError.InvalidConfiguration
            val hasCachedModels = provider.allModels.isNotEmpty() || provider.lastCheckedAt != null
            val preserveAvailability = !failClosed && hasCachedModels && !isFatalError
            val failed = ai.oriveo.community.core.provider.relay.RelayKeyAccess.withKeyStatuses(provider, failedKeyStatuses, System.currentTimeMillis()).copy(
                status = if (preserveAvailability) {
                    ProviderConnectionState.Connected
                } else {
                    ProviderConnectionState.Issue(errorMsg)
                },
                lastError = when {
                    preserveAvailability && isRelay -> RELAY_CATALOG_UNAVAILABLE_MESSAGE
                    preserveAvailability -> provider.lastError
                    else -> errorMsg
                },
            )
            val failedWrite = guardedPersistExistingProvider(
                provider = failed,
                expectedEntity = expectedEntity,
                targetAccountId = targetAccountId,
                commitGuard = commitGuard,
                normalizeConversations = false,
            ) ?: return ProviderResyncOutcome(null, false, stale = true, error = e)
            return ProviderResyncOutcome(failedWrite.provider, catalogSucceeded = false, error = e)
        }
    }

    private suspend fun resyncOfficialProvider(
        provider: Provider,
        targetAccountId: String,
        expectedEntity: ProviderEntity,
        commitGuard: () -> Boolean,
    ): Provider? {
        val resolvedCatalog = ProviderCatalogResolver.resolve(provider)
        // The catalog is still missing after the refresh (the fetch failed), which is not an
        // empty catalog: never rewrite the enabled models from it. Take the failure path so the
        // existing models and availability are kept (pending is not a miss).
        if (resolvedCatalog.catalogPending) {
            throw ProviderServiceError.Network("metadata catalog not loaded")
        }
        val metadataEnabled = resolvedCatalog.enabledModels
            .filter { !it.isManual }
            .map { it.model }
        val manualRetained = resolvedCatalog.enabledModels
            .filter { it.isManual }
            .map { it.model }
        val canonicalCatalogModels = resolvedCatalog.catalog
            .filter { !it.isManual }
            .map { it.model }
        val enabledModels = if (looksLikeLegacyAutoEnabledAll(provider, canonicalCatalogModels)) {
            ModelSelectionUtils.initialEnabledModels(canonicalCatalogModels, provider.kind)
        } else if (metadataEnabled.isNotEmpty() || manualRetained.isNotEmpty()) {
            (metadataEnabled + manualRetained).distinctBy { it.id }
        } else if (canonicalCatalogModels.isNotEmpty()) {
            ModelSelectionUtils.initialEnabledModels(canonicalCatalogModels, provider.kind)
        } else {
            emptyList()
        }

        val userDefault = provider.defaultModel?.id
        val userDefaultStillValid = userDefault != null && enabledModels.any { it.id == userDefault }
        val metadataDefault = MetadataClient.defaultModelId(provider.kind)
            ?.takeIf { def -> enabledModels.any { it.id == def } }
        val preferredDefaultId = when {
            userDefaultStillValid -> userDefault
            metadataDefault != null -> metadataDefault
            else -> enabledModels.firstOrNull()?.id
        }

        val updated = ModelSelectionUtils.synchronizeDefaultSelection(
            provider = provider.copy(
                status = ProviderConnectionState.Connected, models = enabledModels,
                catalogModels = emptyList(), lastCheckedAt = System.currentTimeMillis(), lastError = null,
            ),
            preferredModelId = preferredDefaultId,
        )

        val finalized = ManualRetainedPruner.prune(updated)

        val validation = ProviderKeyValidator.validate(
            provider = finalized,
            apiKey = ProviderCredentialResolver.apiKey(provider, null),
            client = httpClient,
        )
        val validated = applyValidationOutcome(validation, finalized)

        val write = guardedPersistExistingProvider(
            provider = validated,
            expectedEntity = expectedEntity,
            targetAccountId = targetAccountId,
            commitGuard = commitGuard,
            normalizeConversations = true,
        ) ?: return null
        dispatchProviderSyncIfCurrent(write, targetAccountId, commitGuard)
        return write.provider
    }

    private suspend fun resyncSubscriptionProvider(
        provider: Provider,
        targetAccountId: String,
        expectedEntity: ProviderEntity,
        commitGuard: () -> Boolean,
    ): Provider? {
        val prepared = grokSubscriptionRuntime.prepare(targetAccountId, provider.id)
        if (prepared is GrokSubscriptionRuntime.PrepareResult.Failure) {
            val message = prepared.error.toProviderServiceError().userMessage
            val failed = provider.copy(
                status = ProviderConnectionState.Issue(message),
                lastError = message,
                lastCheckedAt = System.currentTimeMillis(),
            )
            return guardedPersistExistingProvider(
                provider = failed,
                expectedEntity = expectedEntity,
                targetAccountId = targetAccountId,
                commitGuard = commitGuard,
                normalizeConversations = false,
            )?.provider
        }

        val accessToken = (prepared as GrokSubscriptionRuntime.PrepareResult.Success).prepared.accessToken
        val rebuilt = buildSubscriptionEnabled(
            providerID = provider.id,
            kind = provider.kind,
            accessToken = accessToken,
            baseUrl = provider.baseUrlText,
            customName = provider.customName,
            existingEnabledModels = provider.models,
            preferredModelID = provider.defaultModel?.id,
        )

        val merged = provider.copy(
            status = rebuilt.status,
            models = rebuilt.models,
            catalogModels = rebuilt.catalogModels,
            lastCheckedAt = rebuilt.lastCheckedAt,
            lastError = rebuilt.lastError,
            apiKeyPreview = "",
        )
        val write = guardedPersistExistingProvider(
            provider = merged,
            expectedEntity = expectedEntity,
            targetAccountId = targetAccountId,
            commitGuard = commitGuard,
            normalizeConversations = true,
        ) ?: return null
        dispatchProviderSyncIfCurrent(write, targetAccountId, commitGuard)
        return write.provider
    }

    private suspend fun resyncOpenAISubscriptionProvider(
        provider: Provider,
        targetAccountId: String,
        expectedEntity: ProviderEntity,
        commitGuard: () -> Boolean,
    ): Provider? {
        val prepared = openAISubscriptionRuntime.prepare(targetAccountId, provider.id)
        if (prepared is OpenAISubscriptionRuntime.PrepareResult.Failure) {
            val message = prepared.error.toProviderServiceError().userMessage
            val failed = provider.copy(
                status = ProviderConnectionState.Issue(message),
                lastError = message,
                lastCheckedAt = System.currentTimeMillis(),
            )
            return guardedPersistExistingProvider(
                provider = failed,
                expectedEntity = expectedEntity,
                targetAccountId = targetAccountId,
                commitGuard = commitGuard,
                normalizeConversations = false,
            )?.provider
        }

        val success = (prepared as OpenAISubscriptionRuntime.PrepareResult.Success).prepared
        val rebuilt = buildOpenAISubscriptionEnabled(
            providerID = provider.id,
            kind = provider.kind,
            accessToken = success.accessToken,
            accountId = success.context.accountId,
            baseUrl = provider.baseUrlText,
            customName = provider.customName,
            existingEnabledModels = provider.models,
            preferredModelID = provider.defaultModel?.id,
        )

        val merged = provider.copy(
            status = rebuilt.status,
            models = rebuilt.models,
            catalogModels = rebuilt.catalogModels,
            lastCheckedAt = rebuilt.lastCheckedAt,
            lastError = rebuilt.lastError,
            apiKeyPreview = "",
        )
        val write = guardedPersistExistingProvider(
            provider = merged,
            expectedEntity = expectedEntity,
            targetAccountId = targetAccountId,
            commitGuard = commitGuard,
            normalizeConversations = true,
        ) ?: return null
        dispatchProviderSyncIfCurrent(write, targetAccountId, commitGuard)
        return write.provider
    }

    private suspend fun resyncRelay(
        provider: Provider,
        targetAccountId: String,
        expectedEntity: ProviderEntity,
        commitGuard: () -> Boolean,
        onKeyStatuses: (Map<String, ai.oriveo.community.core.model.RelayKeyStatus>) -> Unit = {},
    ): Provider? {
        val service = serviceFor(provider.kind)
        // With two or more keys, fetch per key and merge per key; if all fail, throw the first key's error the way a single key would.
        var keyStatuses: Map<String, ai.oriveo.community.core.model.RelayKeyStatus> = emptyMap()
        val syncedModels = if (ai.oriveo.community.core.provider.relay.RelayKeyBinding.keys(provider).size >= 2) {
            val (results, firstError) = fetchRelayKeyCatalogs(provider, onlyKeyID = null, preferredModelID = null)
            val merge = ai.oriveo.community.core.provider.relay.RelayKeyBinding.mergeCatalog(
                ai.oriveo.community.core.provider.relay.RelayKeyBinding.keyIDs(provider),
                provider.catalogModels.filterNot { it.isManual },
                results,
            )
            if (results.values.none { it is ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch.Ok }) {
                // All failed: the catalog is untouched, the statuses of the keys go to the failure write-back, and the error is thrown the way a single key would.
                onKeyStatuses(merge.statuses)
                throw firstError ?: ProviderServiceError.EmptyModelCatalog
            }
            keyStatuses = merge.statuses
            merge.catalog.sortedWith(ai.oriveo.community.core.provider.relay.RelayTransportCoordinator.CATALOG_ORDER)
        } else {
            // A single key also writes that key's status (same mapping as the single-key path of refreshRelayCatalogOnly): success / an empty 2xx catalog -> ok,
            // a failure goes to the failure write-back by catalogCases and is then thrown as it was.
            val keyID = ai.oriveo.community.core.provider.relay.RelayKeyBinding.keyIDs(provider).first()
            try {
                service.syncProvider(
                    apiKey = ProviderCredentialResolver.apiKey(provider, null),
                    preferredModelID = null,
                    baseUrl = provider.baseUrlText,
                    relayRequested = provider.relayRequested,
                ).models.also {
                    keyStatuses = mapOf(keyID to ai.oriveo.community.core.model.RelayKeyStatus("ok"))
                }
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (error: ProviderServiceError.EmptyModelCatalog) {
                onKeyStatuses(mapOf(keyID to ai.oriveo.community.core.model.RelayKeyStatus("ok")))
                throw error
            } catch (error: Exception) {
                val signal = ai.oriveo.community.core.provider.relay.RelayKeyAccess.signalOf(error)
                ai.oriveo.community.core.provider.relay.RelayKeyBinding.statusOf(
                    ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch.Failed(
                        signal?.status,
                        signal?.outcome ?: ai.oriveo.community.core.model.RelayKeyAccessOutcome.None,
                    ),
                )?.let { onKeyStatuses(mapOf(keyID to it)) }
                throw error
            }
        }

        val mergedCatalog = ModelSelectionUtils.replaceRelayCatalog(
            existingModels = provider.catalogModels, syncedModels = syncedModels, providerKind = provider.kind,
        )
        val enabledModels = ModelSelectionUtils.retainRelayEnabledModels(
            existingEnabledModels = provider.models, catalogModels = mergedCatalog, providerKind = provider.kind,
        )

        val now = System.currentTimeMillis()
        val updated = ModelSelectionUtils.synchronizeDefaultSelection(
            provider = ai.oriveo.community.core.provider.relay.RelayKeyAccess.withKeyStatuses(
                provider.copy(
                    status = ProviderConnectionState.Connected, models = enabledModels,
                    catalogModels = mergedCatalog, lastCheckedAt = now, lastError = null,
                ),
                keyStatuses,
                now,
            ),
            preferredModelId = provider.defaultModel?.id ?: enabledModels.firstOrNull()?.id,
        )
        val write = guardedPersistExistingProvider(
            provider = updated,
            expectedEntity = expectedEntity,
            targetAccountId = targetAccountId,
            commitGuard = commitGuard,
            normalizeConversations = true,
        ) ?: return null
        dispatchProviderSyncIfCurrent(write, targetAccountId, commitGuard)
        return write.provider
    }

    suspend fun refreshRelayCatalogOnly(id: String): ProviderResyncOutcome =
        refreshRelayCatalogOnly(id, expectedRevision = null)

    suspend fun refreshRelayCatalogOnly(
        id: String,
        expectedRevision: RelayEditRevision,
    ): ProviderResyncOutcome = refreshRelayCatalogOnly(id, expectedRevision.expectedEntity)

    /** [stampCheckedAt]: write the last-checked time when the catalog refresh succeeds (the "Re-detect" of the detail page); never written on failure. */
    private suspend fun refreshRelayCatalogOnly(
        id: String,
        expectedRevision: ProviderEntity?,
        stampCheckedAt: Boolean = false,
        onlyKeyID: String? = null,
    ): ProviderResyncOutcome {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val currentEntity = dao.getById(targetAccountId, normalizedId)
            ?: return ProviderResyncOutcome(null, catalogSucceeded = false, stale = true)
        if (expectedRevision != null && currentEntity != expectedRevision) {
            return ProviderResyncOutcome(null, catalogSucceeded = false, stale = true)
        }
        val expectedEntity = currentEntity
        val provider = normalizeProviderIds(
            expectedEntity.toDomainWithKeys(loadApiKey(targetAccountId, normalizedId)),
        )
        if (provider.kind != ProviderKind.Relay) {
            return ProviderResyncOutcome(provider, catalogSucceeded = false, stale = true)
        }
        if (ai.oriveo.community.core.provider.relay.RelayKeyBinding.keys(provider).size >= 2) {
            return refreshRelayCatalogPerKey(provider, targetAccountId, normalizedId, stampCheckedAt, onlyKeyID)
        }
        return try {
            val syncResult = serviceFor(ProviderKind.Relay).syncProvider(
                apiKey = ProviderCredentialResolver.apiKey(provider, null),
                preferredModelID = provider.defaultModel?.id,
                baseUrl = provider.baseUrlText,
                relayRequested = provider.relayRequested,
            )
            val catalog = ModelSelectionUtils.replaceRelayCatalog(
                existingModels = provider.catalogModels,
                syncedModels = syncResult.models,
                providerKind = ProviderKind.Relay,
            )
            val enabled = ModelSelectionUtils.retainRelayEnabledModels(
                existingEnabledModels = provider.models,
                catalogModels = catalog,
                providerKind = ProviderKind.Relay,
            )
            val updated = ModelSelectionUtils.synchronizeDefaultSelection(
                provider = withSingleKeyStatus(
                    provider.copy(
                        models = enabled,
                        catalogModels = catalog,
                        lastError = null,
                        lastCheckedAt = if (stampCheckedAt) System.currentTimeMillis() else provider.lastCheckedAt,
                    ),
                    ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch.Ok(syncResult.models),
                ),
                preferredModelId = provider.defaultModel?.id,
            )
            val write = guardedPersistExistingProvider(
                provider = updated,
                expectedEntity = expectedEntity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = true,
            ) ?: return ProviderResyncOutcome(null, false, stale = true)
            dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
            ProviderResyncOutcome(write.provider, catalogSucceeded = true)
        } catch (error: ProviderServiceError.EmptyModelCatalog) {
            val updated = withSingleKeyStatus(
                provider.copy(
                    catalogModels = emptyList(),
                    lastError = null,
                    lastCheckedAt = if (stampCheckedAt) System.currentTimeMillis() else provider.lastCheckedAt,
                ),
                ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch.Ok(emptyList()),
            )
            val write = guardedPersistExistingProvider(
                provider = updated,
                expectedEntity = expectedEntity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = false,
            ) ?: return ProviderResyncOutcome(null, false, stale = true)
            dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
            ProviderResyncOutcome(write.provider, catalogSucceeded = true)
        } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            val signal = ai.oriveo.community.core.provider.relay.RelayKeyAccess.signalOf(error)
            val failed = withSingleKeyStatus(
                provider.copy(
                    status = provider.status,
                    lastError = RELAY_CATALOG_UNAVAILABLE_MESSAGE,
                ),
                ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch.Failed(
                    signal?.status,
                    signal?.outcome ?: ai.oriveo.community.core.model.RelayKeyAccessOutcome.None,
                ),
            )
            val write = guardedPersistExistingProvider(
                provider = failed,
                expectedEntity = expectedEntity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = false,
            ) ?: return ProviderResyncOutcome(null, false, stale = true, error = error)
            dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
            ProviderResyncOutcome(write.provider, catalogSucceeded = false, error = error)
        }
    }

    /**
     * A single-key refresh also writes the status of that key: after deleting down to one key the list is still explicit, and not writing would leave the status empty after the key is replaced
     * (the keys page would wrongly report "fetch interrupted"); the first write for an implicit single key materializes it into a list.
     */
    private fun withSingleKeyStatus(
        provider: Provider,
        result: ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch,
    ): Provider {
        val key = ai.oriveo.community.core.provider.relay.RelayKeyBinding.keys(provider).singleOrNull() ?: return provider
        val status = ai.oriveo.community.core.provider.relay.RelayKeyBinding.statusOf(result) ?: return provider
        return ai.oriveo.community.core.provider.relay.RelayKeyAccess.withKeyStatuses(
            provider,
            mapOf(key.id to status),
            System.currentTimeMillis(),
        )
    }

    /**
     * Each key goes through the existing refresh request with its own value (sent in order, headers unchanged); when [onlyKeyID] is set, the other keys are recorded as skipped.
     * Returns each key's result and the first failure (handed back to the caller when all fail).
     */
    private suspend fun fetchRelayKeyCatalogs(
        provider: Provider,
        onlyKeyID: String?,
        preferredModelID: String?,
    ): Pair<Map<String, ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch>, Exception?> {
        var firstError: Exception? = null
        val results = ai.oriveo.community.core.provider.relay.RelayKeyBinding.keyIDs(provider).associateWith { keyID ->
            if (onlyKeyID != null && keyID != onlyKeyID) {
                return@associateWith ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch.Skipped
            }
            val (result, error) = fetchOneRelayKeyCatalog(
                apiKey = ProviderCredentialResolver.keySecret(provider, keyID),
                preferredModelID = preferredModelID,
                baseUrl = provider.baseUrlText,
                relayRequested = provider.relayRequested,
            )
            if (firstError == null) firstError = error
            result
        }
        return results to firstError
    }

    /**
     * The row of an extra key in step 1 "Fetch catalog" of the two-step add: the same catalog refresh request (catalogAPIRoot + /models, auth header by authMode),
     * only with a different key value; the result is not persisted.
     */
    suspend fun fetchRelayKeyCatalog(
        apiKey: String,
        baseUrl: String,
        relayRequested: RelayRequestedConfig,
    ): ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch =
        fetchOneRelayKeyCatalog(apiKey, null, baseUrl, relayRequested).first

    private suspend fun fetchOneRelayKeyCatalog(
        apiKey: String,
        preferredModelID: String?,
        baseUrl: String?,
        relayRequested: RelayRequestedConfig?,
    ): Pair<ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch, Exception?> = try {
        ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch.Ok(
            serviceFor(ProviderKind.Relay).syncProvider(
                apiKey = apiKey,
                preferredModelID = preferredModelID,
                baseUrl = baseUrl,
                relayRequested = relayRequested,
            ).models,
        ) to null
    } catch (error: kotlinx.coroutines.CancellationException) {
        throw error
    } catch (_: ProviderServiceError.EmptyModelCatalog) {
        // A 2xx where this key listed no model at all: counted as success, and it no longer lists any entry.
        ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch.Ok(emptyList()) to null
    } catch (error: Exception) {
        val signal = ai.oriveo.community.core.provider.relay.RelayKeyAccess.signalOf(error)
        ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch.Failed(
            signal?.status,
            signal?.outcome ?: ai.oriveo.community.core.model.RelayKeyAccessOutcome.None,
        ) to error
    }

    /**
     * Catalog refresh with two or more keys: after fetching key by key, re-read the latest connection; results whose connection identity changed in flight, whose key was deleted or whose value changed
     * are treated as skipped, then merge per key and write each key's status, going through the existing manual / enabled model retention. No failure clears the existing catalog.
     */
    private suspend fun refreshRelayCatalogPerKey(
        provider: Provider,
        targetAccountId: String,
        normalizedId: String,
        stampCheckedAt: Boolean,
        onlyKeyID: String?,
    ): ProviderResyncOutcome {
        val keyIDs = ai.oriveo.community.core.provider.relay.RelayKeyBinding.keyIDs(provider)
        val secrets = keyIDs.associateWith { ProviderCredentialResolver.keySecret(provider, it) }
        val (fetched, firstError) = fetchRelayKeyCatalogs(provider, onlyKeyID, provider.defaultModel?.id)
        val latestEntity = dao.getById(targetAccountId, normalizedId)
            ?: return ProviderResyncOutcome(null, catalogSucceeded = false, stale = true)
        val latest = normalizeProviderIds(latestEntity.toDomainWithKeys(loadApiKey(targetAccountId, normalizedId)))
        if (latest.kind != ProviderKind.Relay) return ProviderResyncOutcome(null, catalogSucceeded = false, stale = true)
        val connectionChanged = relayConnectionSemanticsChanged(provider, latest)
        val latestKeyIDs = ai.oriveo.community.core.provider.relay.RelayKeyBinding.keyIDs(latest)
        val results = fetched.mapValues { (keyID, result) ->
            val unchanged = !connectionChanged && keyID in latestKeyIDs &&
                ProviderCredentialResolver.keySecret(latest, keyID) == secrets[keyID]
            if (unchanged) result else ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch.Skipped
        }
        if (results.values.all { it == ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch.Skipped }) {
            return ProviderResyncOutcome(null, catalogSucceeded = false, stale = true)
        }
        val succeeded = results.values.any { it is ai.oriveo.community.core.provider.relay.RelayKeyBinding.CatalogFetch.Ok }
        val merge = ai.oriveo.community.core.provider.relay.RelayKeyBinding.mergeCatalog(
            latestKeyIDs,
            latest.catalogModels.filterNot { it.isManual },
            results,
        )
        val now = System.currentTimeMillis()
        // All failed: the catalog and enabled models stay as they are, and only the key statuses and the failure are written (same as a single-key failure).
        val merged = if (succeeded) {
            val catalog = ModelSelectionUtils.replaceRelayCatalog(
                existingModels = latest.catalogModels,
                syncedModels = merge.catalog.sortedWith(ai.oriveo.community.core.provider.relay.RelayTransportCoordinator.CATALOG_ORDER),
                providerKind = ProviderKind.Relay,
            )
            val enabled = ModelSelectionUtils.retainRelayEnabledModels(
                existingEnabledModels = latest.models,
                catalogModels = catalog,
                providerKind = ProviderKind.Relay,
            )
            ai.oriveo.community.core.provider.relay.RelayKeyAccess.withKeyStatuses(
                latest.copy(models = enabled, catalogModels = catalog),
                merge.statuses,
                now,
            )
        } else {
            ai.oriveo.community.core.provider.relay.RelayKeyAccess.withKeyStatuses(latest, merge.statuses, now)
        }
        val updated = if (succeeded) {
            ModelSelectionUtils.synchronizeDefaultSelection(
                provider = merged.copy(
                    lastError = null,
                    lastCheckedAt = if (stampCheckedAt) now else latest.lastCheckedAt,
                ),
                preferredModelId = latest.defaultModel?.id,
            )
        } else {
            merged.copy(lastError = RELAY_CATALOG_UNAVAILABLE_MESSAGE)
        }
        val write = guardedPersistExistingProvider(
            provider = updated,
            expectedEntity = latestEntity,
            targetAccountId = targetAccountId,
            commitGuard = { true },
            normalizeConversations = succeeded,
        ) ?: return ProviderResyncOutcome(null, false, stale = true, error = firstError.takeUnless { succeeded })
        dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
        return ProviderResyncOutcome(write.provider, catalogSucceeded = succeeded, error = firstError.takeUnless { succeeded })
    }

    /** The configured providers, so MetadataClient knows which catalogs it needs. */
    suspend fun catalogDemand(): MetadataClient.CatalogDemand {
        val kinds = withContext(Dispatchers.IO) { dao.getAll(accountId) }
            .map { it.toDomain().kind }
            .toSet()
        return MetadataClient.CatalogDemand(
            providerKinds = kinds - ProviderKind.Relay,
            hasRelay = ProviderKind.Relay in kinds,
        )
    }

    suspend fun refreshProviderMetadata() {
        val targetAccountId = accountId
        val entities = withContext(Dispatchers.IO) { dao.getAll(targetAccountId) }
        if (entities.isEmpty()) return

        for (entity in entities) {
            val provider = entity.toDomain()
            if (provider.kind == ProviderKind.Relay) continue

            var updatedProvider = provider
            val resolvedCatalog = ProviderCatalogResolver.resolve(provider)
            // Catalog not loaded yet: change nothing (resolve already started fetching just this
            // provider); the refresh event after it arrives enriches the models.
            if (resolvedCatalog.catalogPending) continue
            val canonicalCatalogModels = resolvedCatalog.catalog
                .filter { !it.isManual }
                .map { it.model }
            val shouldRepairLegacyEnabledState = canonicalCatalogModels.isNotEmpty() &&
                (
                    updatedProvider.catalogModels.isNotEmpty() ||
                        looksLikeLegacyAutoEnabledAll(updatedProvider, canonicalCatalogModels)
                    )

            if (shouldRepairLegacyEnabledState) {
                val metadataEnabled = resolvedCatalog.enabledModels
                    .filter { !it.isManual }
                    .map { it.model }
                val manualRetained = resolvedCatalog.enabledModels
                    .filter { it.isManual }
                    .map { it.model }
                val rebuiltModels = if (looksLikeLegacyAutoEnabledAll(updatedProvider, canonicalCatalogModels)) {
                    ModelSelectionUtils.initialEnabledModels(canonicalCatalogModels, updatedProvider.kind)
                } else if (metadataEnabled.isNotEmpty() || manualRetained.isNotEmpty()) {
                    (metadataEnabled + manualRetained).distinctBy { it.id }
                } else {
                    ModelSelectionUtils.initialEnabledModels(canonicalCatalogModels, updatedProvider.kind)
                }
                val userDefault = updatedProvider.defaultModel?.id
                val userDefaultStillValid = userDefault != null && rebuiltModels.any { it.id == userDefault }
                val metadataDefault = MetadataClient.defaultModelId(updatedProvider.kind)
                    ?.takeIf { defaultId -> rebuiltModels.any { it.id == defaultId } }
                val preferredDefaultId = when {
                    userDefaultStillValid -> userDefault
                    metadataDefault != null -> metadataDefault
                    else -> rebuiltModels.firstOrNull()?.id
                }

                updatedProvider = ModelSelectionUtils.synchronizeDefaultSelection(
                    provider = updatedProvider.copy(
                        models = rebuiltModels,
                        catalogModels = emptyList(),
                    ),
                    preferredModelId = preferredDefaultId,
                )
            }

            val enrichedModels = updatedProvider.models.map { model ->
                ai.oriveo.community.core.provider.CatalogModelBuilder.enrichStoredModel(model, updatedProvider.kind)
            }
            if (enrichedModels != updatedProvider.models) {
                updatedProvider = updatedProvider.copy(models = enrichedModels)
            }
            updatedProvider = ManualRetainedPruner.prune(updatedProvider)
            if (updatedProvider == provider) continue

            val persisted = upsertProviderEntity(updatedProvider, targetAccountId)
            normalizeConversationSelections(persisted, targetAccountId)
        }

        metadataRefreshEventBus.dispatch(
            ai.oriveo.community.core.data.remote.MetadataClient.RefreshEvent(
                version = MetadataClient.version,
                contractVersion = MetadataClient.contractVersion,
            )
        )
    }

    /** Deletes a provider connection, its stored key, and everything scoped to it. */
    suspend fun deleteProvider(id: String) {
        val currentAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val existing = dao.getById(currentAccountId, normalizedId)
        dao.deleteById(currentAccountId, normalizedId)
        deleteApiKey(currentAccountId, normalizedId)
        // The values of a relay's non-primary keys are deleted together with the primary key; rows without a key list are left alone.
        if (existing?.relayKeysJson != null) {
            withContext(Dispatchers.IO) { secureKeyStore.deleteRelayKeySecrets(currentAccountId, normalizedId) }
        }
        // Dispatch by kind rather than calling both: the two subscription runtimes share one
        // credential slot, so revoking with the wrong one sends a ChatGPT token to xAI. When the
        // kind is unknown the row is already gone, so only the local copy is cleared.
        runCatching {
            when (existing?.kind) {
                ProviderKind.OpenAI.name ->
                    openAISubscriptionRuntime.disconnect(currentAccountId, normalizedId)
                ProviderKind.Grok.name ->
                    grokSubscriptionRuntime.disconnect(currentAccountId, normalizedId)
                else -> secureKeyStore.deleteSubscriptionCredential(currentAccountId, normalizedId)
            }
        }
        secureKeyStore.advanceCapabilityConnection(currentAccountId, normalizedId)
        // Deletion is a model-control lifecycle boundary, not a ViewModel concern. Tombstone all
        // known runtime variants before any later cloud merge can replay them, and clear exact
        // local rejection evidence for the removed connection.
        capabilityPreferenceStore?.removeScopes(providerID = normalizedId)
        localCapabilityCustomFragmentStore?.removeScopes(providerID = normalizedId)
        ai.oriveo.community.core.provider.ModelControlRejectionCache.removeConnection(normalizedId)
        toolCallMemoryStore?.clearConnection(currentAccountId, normalizedId)
        relayNegativeCache.clearConnection(normalizedId)
        relayWebProbeRecords.clearConnection(normalizedId)
        relayWebProbeAutoHistory.clearConnection(normalizedId)
        relayWebFragmentStore.remove(normalizedId)
    }

    /**
     * Moves existing llama.cpp native-channel connections to the chat channel once. The marker is
     * stored per device so a native channel the user picks later is not rewritten, and the write goes
     * through the same guarded entry point as a user edit (including the connection generation bump).
     */
    internal suspend fun migrateLlamaCppConnectionsOnce(targetAccountId: String) {
        val preferences = preferenceDao ?: return
        val flagKey = AppPreferenceKeys.LLAMACPP_CHAT_CHANNEL_MIGRATION
        if (preferences.get(flagKey) != null) return
        var allWritten = true
        for (entity in dao.getAll(targetAccountId)) {
            if (entity.kind != ProviderKind.Relay.name) continue
            val apiKey = loadApiKey(targetAccountId, entity.id)
            val provider = normalizeProviderIds(entity.toDomainWithKeys(apiKey))
            val requested = provider.relayRequested ?: continue
            val outcome = LlamaCppChannelMigration.migrate(
                engineProfile = requested.engineProfile,
                transport = requested.transport,
                resolvedAPIBaseURL = requested.resolvedAPIBaseURL,
                alreadyMigrated = false,
            )
            if (!outcome.changed) continue
            val chatProfile = LocalEngineGenerationProfiles.profile("llamacpp", RelayTransport.OpenAIChatCompletions)
            fun refresh(models: List<ai.oriveo.community.core.model.AIModel>) = models.map {
                if (it.generationProfile?.template == "llamacpp_native") it.copy(generationProfile = chatProfile) else it
            }
            val migrated = provider.copy(
                relayRequested = requested.copy(transport = outcome.transport, resolvedAPIBaseURL = outcome.resolvedAPIBaseURL),
                models = refresh(provider.models),
                catalogModels = refresh(provider.catalogModels),
            )
            val write = guardedPersistRelayEdit(
                provider = migrated,
                expectedEntity = entity,
                previousApiKey = apiKey,
                nextApiKey = apiKey,
                targetAccountId = targetAccountId,
                commitGuard = { true },
            )
            if (write == null) {
                allWritten = false
            } else {
                dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
            }
        }
        if (allWritten) preferences.set(ai.oriveo.community.core.data.entity.PreferenceEntity(flagKey, "1"))
    }

    /** Updates a stored provider connection. */
    suspend fun updateProvider(provider: Provider) {
        val targetAccountId = accountId
        updateProvider(provider, targetAccountId)
    }

    private suspend fun updateProvider(provider: Provider, targetAccountId: String) {
        val normalizedProvider = normalizeProviderIds(provider)
        val previousProvider = withContext(Dispatchers.IO) {
            dao.getById(targetAccountId, normalizedProvider.id)?.toDomain("")
        }
        if (previousProvider != null && toolCallMemoryScopeChanged(previousProvider, normalizedProvider)) {
            toolCallMemoryStore?.clearConnection(targetAccountId, normalizedProvider.id)
        }

        // (ProviderManager.swift:643-654)
        val persisted = upsertProviderEntity(normalizedProvider, targetAccountId)
        normalizeConversationSelections(persisted, targetAccountId)

    }

    suspend fun renameProvider(provider: Provider, name: String) {
        val targetAccountId = accountId
        val normalizedProvider = normalizeProviderIds(provider)
        updateProvider(
            normalizedProvider.copy(
                customName = makeUniqueProviderInstanceName(
                    desiredName = name,
                    kind = normalizedProvider.kind,
                    excludingId = normalizedProvider.id,
                    fallbackName = if (normalizedProvider.kind == ProviderKind.Relay) {
                        relayDomainNameFromEndpoint(normalizedProvider.baseUrlText.orEmpty())
                            ?: ProviderKind.Relay.displayName
                    } else {
                        normalizedProvider.kind.displayName
                    },
                    expectedAccountId = targetAccountId,
                ),
            ),
            targetAccountId,
        )
    }

    private data class GuardedProviderWrite(
        val provider: Provider,
        val entity: ProviderEntity,
    )

    private class StaleProviderMutation : IllegalStateException("stale_provider_mutation")

    private suspend fun guardedPersistExistingProvider(
        provider: Provider,
        expectedEntity: ProviderEntity,
        targetAccountId: String,
        commitGuard: () -> Boolean,
        normalizeConversations: Boolean,
    ): GuardedProviderWrite? {
        val (finalized, entity) = finalizeForUpsert(provider, targetAccountId)
        return try {
            runInTransaction {
                if (!commitGuard()) throw StaleProviderMutation()
                val current = dao.getById(targetAccountId, entity.id)
                if (current != expectedEntity) throw StaleProviderMutation()
                dao.upsert(entity)
                if (normalizeConversations) {
                    normalizeConversationSelections(finalized, targetAccountId)
                }
                if (!commitGuard()) throw StaleProviderMutation()
            }
            persistRelayKeySecrets(finalized, entity)
            GuardedProviderWrite(finalized, entity)
        } catch (_: StaleProviderMutation) {
            null
        }
    }

    private suspend fun dispatchProviderSyncIfCurrent(
        write: GuardedProviderWrite,
        targetAccountId: String,
        commitGuard: () -> Boolean,
    ): Boolean {
        var current = false
        runInTransaction {
            current = commitGuard() && dao.getById(targetAccountId, write.entity.id) == write.entity
        }
        if (current && commitGuard()) {
            return true
        }
        return false
    }

    private suspend fun guardedInsertRelayProvider(
        provider: Provider,
        targetAccountId: String,
        commitGuard: () -> Boolean,
    ): GuardedProviderWrite? {
        val (finalized, entity) = finalizeForUpsert(provider, targetAccountId)
        return try {
            runInTransaction {
                if (!commitGuard()) throw StaleProviderMutation()
                if (dao.getById(targetAccountId, entity.id) != null) throw StaleProviderMutation()
                dao.upsert(entity)
                normalizeConversationSelections(finalized, targetAccountId)
                if (!commitGuard()) throw StaleProviderMutation()
            }
            persistRelayKeySecrets(finalized, entity)
            GuardedProviderWrite(finalized, entity)
        } catch (_: StaleProviderMutation) {
            null
        }
    }

    private suspend fun rollbackRelayRegistrationIfUnchanged(
        write: GuardedProviderWrite,
        targetAccountId: String,
    ) {
        runInTransaction {
            if (dao.getById(targetAccountId, write.entity.id) == write.entity) {
                dao.deleteById(targetAccountId, write.entity.id)
            }
        }
        deleteApiKey(targetAccountId, write.entity.id)
    }

    private suspend fun guardedPersistRelayEdit(
        provider: Provider,
        expectedEntity: ProviderEntity,
        previousApiKey: String,
        nextApiKey: String,
        targetAccountId: String,
        commitGuard: () -> Boolean,
    ): GuardedProviderWrite? {
        if (!commitGuard()) return null
        val existingProvider = normalizeProviderIds(expectedEntity.toDomainWithKeys(previousApiKey))
        val connectionSemanticsChanged = relayConnectionSemanticsChanged(existingProvider, provider)
        val keyChanged = previousApiKey != nextApiKey
        if (keyChanged) {
            if (nextApiKey.isBlank()) {
                deleteApiKey(targetAccountId, expectedEntity.id)
            } else {
                saveApiKey(targetAccountId, expectedEntity.id, nextApiKey)
            }
        }
        val write = guardedPersistExistingProvider(
            provider = provider,
            expectedEntity = expectedEntity,
            targetAccountId = targetAccountId,
            commitGuard = commitGuard,
            normalizeConversations = true,
        )
        if (write == null && keyChanged && loadApiKey(targetAccountId, expectedEntity.id) == nextApiKey) {
            val currentEntity = dao.getById(targetAccountId, expectedEntity.id)
            if (currentEntity == null || previousApiKey.isBlank()) {
                deleteApiKey(targetAccountId, expectedEntity.id)
            } else {
                saveApiKey(targetAccountId, expectedEntity.id, previousApiKey)
            }
        }

        if (write != null && connectionSemanticsChanged) {
            secureKeyStore.advanceCapabilityConnectionGeneration(targetAccountId, expectedEntity.id)
        }
        return write
    }

    suspend fun verifyAndPersistRelayEdit(
        candidate: Provider,
        replacementApiKey: String? = null,
        refreshCatalog: Boolean,
        commitGuard: () -> Boolean,
        baseline: Provider? = null,
    ): RelayEditOutcome {
        if (baseline != null) {
            return verifyAndPersistMergedRelayEdit(candidate, replacementApiKey, baseline, commitGuard)
        }
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(candidate.id)
        if (!commitGuard()) return RelayEditOutcome(null, false, false, stale = true)
        val expectedEntity = dao.getById(targetAccountId, normalizedId)
            ?: return RelayEditOutcome(null, false, false, stale = true)
        val previousApiKey = loadApiKey(targetAccountId, normalizedId)
        val current = normalizeProviderIds(expectedEntity.toDomainWithKeys(previousApiKey))
        if (current.kind != ProviderKind.Relay || candidate.kind != ProviderKind.Relay) {
            return RelayEditOutcome(
                provider = null,
                persisted = false,
                verificationSucceeded = false,
                error = ProviderServiceError.InvalidConfiguration("Relay edit target is not a relay provider."),
                failureRevision = RelayEditRevision(expectedEntity),
            )
        }
        val requested = candidate.relayRequested ?: RelayRequestedConfig()
        val nextApiKey = if (RelayCredentialPolicy.requiresCredential(requested)) {
            replacementApiKey ?: previousApiKey
        } else {
            ""
        }
        val normalizedCandidate = normalizeProviderIds(
            candidate.copy(
                apiKey = nextApiKey,
                apiKeyPreview = SecureKeyStore.maskApiKey(nextApiKey),
            ),
        )
        if (!commitGuard()) return RelayEditOutcome(null, false, false, stale = true)

        val modelID = relayVerificationSampleID(normalizedCandidate)
        // Same as re-verification: send with the effective key of the sample model.
        val sentKeyID = ai.oriveo.community.core.provider.relay.RelayKeyBinding.effectiveKeyID(normalizedCandidate, modelID)
        val sentApiKey = relayEditSentApiKey(normalizedCandidate, modelID)
        try {
            verifyRelayGeneration(
                apiKey = sentApiKey,
                baseUrl = normalizedCandidate.baseUrlText,
                modelID = modelID.orEmpty(),
                relayRequested = requested.copy(modelID = modelID),
                relayKind = normalizedCandidate.relayKind,
            )
        } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            return RelayEditOutcome(
                provider = null,
                persisted = false,
                verificationSucceeded = false,
                error = error,
                failureRevision = RelayEditRevision(expectedEntity, ai.oriveo.community.core.provider.relay.RelayKeyAccess.generationStatusOf(error), sentKeyID, sentApiKey),
            )
        }
        if (!commitGuard()) return RelayEditOutcome(null, false, true, stale = true)

        val verified = ModelSelectionUtils.synchronizeDefaultSelection(
            provider = withRelayEditKeyStatus(
                normalizedCandidate.copy(
                    status = ProviderConnectionState.Connected,
                    lastCheckedAt = System.currentTimeMillis(),
                    lastError = null,
                ),
                previousApiKey,
                nextApiKey,
                sentKeyID,
                ai.oriveo.community.core.model.RelayKeyStatus("ok"),
            ),
            preferredModelId = modelID,
        )
        val write = guardedPersistRelayEdit(
            provider = verified,
            expectedEntity = expectedEntity,
            previousApiKey = previousApiKey,
            nextApiKey = nextApiKey,
            targetAccountId = targetAccountId,
            commitGuard = commitGuard,
        ) ?: return RelayEditOutcome(null, false, true, stale = true)
        dispatchProviderSyncIfCurrent(write, targetAccountId, commitGuard)
        onRelayPrimaryKeyReplaced(write.provider, previousApiKey, nextApiKey)
        return RelayEditOutcome(
            provider = write.provider,
            persisted = true,
            verificationSucceeded = true,
            catalogState = RelayCatalogRefreshState.NotRequested,
            persistedRevision = RelayEditRevision(write.entity),
        )
    }

    suspend fun persistRelayEditUnverified(
        candidate: Provider,
        replacementApiKey: String? = null,
        failureRevision: RelayEditRevision,
        commitGuard: () -> Boolean,
        baseline: Provider? = null,
    ): RelayEditOutcome {
        if (baseline != null) {
            return persistMergedRelayEditUnverified(candidate, replacementApiKey, baseline, commitGuard, failureRevision)
        }
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(candidate.id)
        if (!commitGuard()) return RelayEditOutcome(null, false, false, stale = true)
        val expectedEntity = failureRevision.expectedEntity
        if (expectedEntity.id != normalizedId || expectedEntity.accountId != targetAccountId) {
            return RelayEditOutcome(null, false, false, stale = true)
        }
        if (dao.getById(targetAccountId, normalizedId) != expectedEntity) {
            return RelayEditOutcome(null, false, false, stale = true)
        }
        val previousApiKey = loadApiKey(targetAccountId, normalizedId)
        val requested = candidate.relayRequested ?: RelayRequestedConfig()
        val nextApiKey = if (RelayCredentialPolicy.requiresCredential(requested)) {
            replacementApiKey ?: previousApiKey
        } else {
            ""
        }
        val unverified = normalizeProviderIds(
            candidate.copy(
                apiKey = nextApiKey,
                apiKeyPreview = SecureKeyStore.maskApiKey(nextApiKey),
                status = ProviderConnectionState.Issue(RELAY_UNVERIFIED_MESSAGE),
                lastCheckedAt = null,
                lastError = RELAY_UNVERIFIED_MESSAGE,
            ),
        )
        val write = guardedPersistRelayEdit(
            provider = withRelayEditKeyStatus(unverified, previousApiKey, nextApiKey, failureRevision.failedKeyID, failureRevision.failedStatusFor(unverified)),
            expectedEntity = expectedEntity,
            previousApiKey = previousApiKey,
            nextApiKey = nextApiKey,
            targetAccountId = targetAccountId,
            commitGuard = commitGuard,
        ) ?: return RelayEditOutcome(null, false, false, stale = true)
        dispatchProviderSyncIfCurrent(write, targetAccountId, commitGuard)
        onRelayPrimaryKeyReplaced(write.provider, previousApiKey, nextApiKey)
        return RelayEditOutcome(
            provider = write.provider,
            persisted = true,
            verificationSucceeded = false,
            error = null,
            persistedRevision = RelayEditRevision(write.entity),
        )
    }

    /**
     * A save from the edit page that needs no verification (only fields that do not affect the connection identity changed): zero network, merged field by field into the live record,
     * and the verification state is not changed.
     */
    suspend fun persistRelayEditWithoutVerification(
        candidate: Provider,
        baseline: Provider,
        commitGuard: () -> Boolean,
    ): RelayEditOutcome {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(candidate.id)
        val base = normalizeProviderIds(baseline)
        val edited = normalizeProviderIds(candidate)
        repeat(RELAY_EDIT_MERGE_WRITE_ATTEMPTS) {
            if (!commitGuard()) return RelayEditOutcome(null, false, false, stale = true)
            val live = readRelayEditLive(targetAccountId, normalizedId)
                ?: return RelayEditOutcome(null, false, false, stale = true)
            val merged = normalizeProviderIds(RelayEditMerge.merge(live.provider, base, edited))
            val catalogInvalidated = RelayEditMerge.connectionIdentityChanged(live.provider, merged)
            val write = guardedPersistExistingProvider(
                provider = if (catalogInvalidated) merged.clearingRelayCatalog() else merged,
                expectedEntity = live.entity,
                targetAccountId = targetAccountId,
                commitGuard = commitGuard,
                normalizeConversations = true,
            ) ?: return@repeat
            if (toolCallMemoryScopeChanged(live.provider, write.provider)) {
                toolCallMemoryStore?.clearConnection(targetAccountId, normalizedId)
            }
            dispatchProviderSyncIfCurrent(write, targetAccountId, commitGuard)
            return RelayEditOutcome(
                provider = write.provider,
                persisted = true,
                verificationSucceeded = false,
                persistedRevision = RelayEditRevision(write.entity),
                catalogInvalidated = catalogInvalidated,
            )
        }
        return RelayEditOutcome(null, false, false, stale = true)
    }

    /** The connection identity changed: the old catalog is invalidated immediately and the enabled models are kept, so re-entering the page does not mistake the old catalog for Available. */
    private fun Provider.clearingRelayCatalog(): Provider =
        copy(catalogModels = emptyList(), cachedAvailableModelCount = null)

    /** The live record at the moment of persisting: the entity is for the in-transaction CAS, and the key is the live KeyStore value. */
    private class RelayEditLiveRecord(
        val entity: ProviderEntity,
        val apiKey: String,
        val provider: Provider,
    )

    private suspend fun readRelayEditLive(targetAccountId: String, id: String): RelayEditLiveRecord? {
        val entity = dao.getById(targetAccountId, id) ?: return null
        val apiKey = loadApiKey(targetAccountId, id)
        return RelayEditLiveRecord(entity, apiKey, normalizeProviderIds(entity.toDomainWithKeys(apiKey)))
    }

    /** The live record plus the fields the user changed; if the user replaced the primary key the new value is used, otherwise the live one. Returns the merged connection and the primary key to write. */
    private fun mergedRelayEditCandidate(
        live: RelayEditLiveRecord,
        baseline: Provider,
        edited: Provider,
        replacementApiKey: String?,
    ): Pair<Provider, String> {
        val merged = RelayEditMerge.merge(live.provider, baseline, edited)
        val requested = merged.relayRequested ?: RelayRequestedConfig()
        val nextApiKey = if (RelayCredentialPolicy.requiresCredential(requested)) {
            replacementApiKey ?: live.apiKey
        } else {
            ""
        }
        val withKey = normalizeProviderIds(
            merged.copy(apiKey = nextApiKey, apiKeyPreview = SecureKeyStore.maskApiKey(nextApiKey)),
        )
        return withKey to nextApiKey
    }

    /**
     * Verified save: before every write, re-read the live record and merge the fields the user changed. If the live record differs from the value used by the probe on verification-related fields,
     * this verification does not count and verifies again with the merged value; if the second one collides again, the merge is persisted as it is and no verification state is written.
     * If only non-verification fields collided, merge directly and write this result. The write still goes through commitGuard + the in-transaction CAS, and when the CAS is lost it re-reads and re-merges.
     */
    private suspend fun verifyAndPersistMergedRelayEdit(
        candidate: Provider,
        replacementApiKey: String?,
        baseline: Provider,
        commitGuard: () -> Boolean,
    ): RelayEditOutcome {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(candidate.id)
        val base = normalizeProviderIds(baseline)
        val edited = normalizeProviderIds(candidate)
        var probedIdentity: RelayEditMerge.ProbeIdentity? = null
        var probedModelID: String? = null
        // The failure of the latest probe; when non-null, probedIdentity is the value that failing probe used.
        var probeFailure: Exception? = null
        var probes = 0
        var writeAttempts = 0
        while (true) {
            if (!commitGuard()) return RelayEditOutcome(null, false, probes > 0, stale = true)
            val live = readRelayEditLive(targetAccountId, normalizedId)
                ?: return RelayEditOutcome(null, false, false, stale = true)
            if (live.provider.kind != ProviderKind.Relay || edited.kind != ProviderKind.Relay) {
                return RelayEditOutcome(
                    provider = null,
                    persisted = false,
                    verificationSucceeded = false,
                    error = ProviderServiceError.InvalidConfiguration("Relay edit target is not a relay provider."),
                    failureRevision = RelayEditRevision(live.entity),
                )
            }
            val (merged, nextApiKey) = mergedRelayEditCandidate(live, base, edited, replacementApiKey)
            // Same as re-verification: send with the effective key of the sample model; the key in the identity is the value actually sent this time.
            val sampleID = relayVerificationSampleID(merged)
            val sentApiKey = relayEditSentApiKey(merged, sampleID)
            val identity = RelayEditMerge.probeIdentity(merged, sentApiKey)
            val failure = probeFailure
            // A failure counts only if the live record has not changed again; if the second probe collides again (success or failure), fall through to persist the merge as it is below, without writing a verification state.
            if (failure != null && identity == probedIdentity) {
                return RelayEditOutcome(
                    provider = null,
                    persisted = false,
                    verificationSucceeded = false,
                    error = failure,
                    failureRevision = RelayEditRevision(
                        live.entity,
                        ai.oriveo.community.core.provider.relay.RelayKeyAccess.generationStatusOf(failure),
                        ai.oriveo.community.core.provider.relay.RelayKeyBinding.effectiveKeyID(merged, sampleID),
                        sentApiKey,
                    ),
                )
            }
            if (identity != probedIdentity && probes < RELAY_EDIT_MAX_PROBES) {
                val modelID = sampleID
                try {
                    verifyRelayGeneration(
                        apiKey = sentApiKey,
                        baseUrl = merged.baseUrlText,
                        modelID = modelID.orEmpty(),
                        relayRequested = (merged.relayRequested ?: RelayRequestedConfig()).copy(modelID = modelID),
                        relayKind = merged.relayKind,
                    )
                } catch (error: Exception) {
                    if (error is kotlinx.coroutines.CancellationException) throw error
                    // A failure may also be caused by someone changing a verification field elsewhere: go back to the loop and re-read the live record, and if it changed, verify again with the merged value.
                    probes += 1
                    probedIdentity = identity
                    probeFailure = error
                    continue
                }
                probes += 1
                probedIdentity = identity
                probedModelID = modelID
                probeFailure = null
                continue
            }
            val verified = identity == probedIdentity
            val catalogInvalidated = RelayEditMerge.connectionIdentityChanged(live.provider, merged)
            val committed = if (catalogInvalidated) merged.clearingRelayCatalog() else merged
            val toWrite = if (verified) {
                ModelSelectionUtils.synchronizeDefaultSelection(
                    provider = withRelayEditKeyStatus(
                        committed.copy(
                            status = ProviderConnectionState.Connected,
                            lastCheckedAt = System.currentTimeMillis(),
                            lastError = null,
                        ),
                        live.apiKey, // key-choke: stored-field
                        nextApiKey,
                        ai.oriveo.community.core.provider.relay.RelayKeyBinding.effectiveKeyID(committed, probedModelID),
                        ai.oriveo.community.core.model.RelayKeyStatus("ok"),
                    ),
                    preferredModelId = probedModelID,
                )
            } else {
                // Collided again on the second time: no verification state is written, and if the primary key value changed, that key is still cleared first.
                withRelayEditKeyStatus(committed, live.apiKey, nextApiKey, null, null) // key-choke: stored-field
            }
            val write = guardedPersistRelayEdit(
                provider = toWrite,
                expectedEntity = live.entity,
                previousApiKey = live.apiKey,
                nextApiKey = nextApiKey,
                targetAccountId = targetAccountId,
                commitGuard = commitGuard,
            )
            if (write == null) {
                writeAttempts += 1
                if (writeAttempts >= RELAY_EDIT_MERGE_WRITE_ATTEMPTS) {
                    return RelayEditOutcome(null, false, probes > 0, stale = true)
                }
                continue
            }
            dispatchProviderSyncIfCurrent(write, targetAccountId, commitGuard)
            onRelayPrimaryKeyReplaced(write.provider, live.apiKey, nextApiKey)
            return RelayEditOutcome(
                provider = write.provider,
                persisted = true,
                verificationSucceeded = verified,
                catalogState = RelayCatalogRefreshState.NotRequested,
                persistedRevision = RelayEditRevision(write.entity),
                catalogInvalidated = catalogInvalidated,
            )
        }
    }

    /** The key value actually sent by the edit-save verification: the effective key of the sample model when credentials are required, none otherwise. */
    private fun relayEditSentApiKey(provider: Provider, sampleModelID: String?): String =
        if (RelayCredentialPolicy.requiresCredential(provider.relayRequested)) {
            ProviderCredentialResolver.apiKey(provider, sampleModelID)
        } else {
            ""
        }

    /**
     * The edit save writes key statuses along with persisting: if the primary key value changed, first clear the old status of the primary key, then write the verdict of this verification onto the key actually sent
     * [keyID] (the effective key of the sample model; [status] null = no verdict to write). A save that is not persisted does not come through here.
     */
    private fun withRelayEditKeyStatus(
        provider: Provider,
        previousApiKey: String,
        nextApiKey: String,
        keyID: String?,
        status: ai.oriveo.community.core.model.RelayKeyStatus?,
    ): Provider {
        val cleared = if (previousApiKey != nextApiKey && provider.relayKeys != null) {
            provider.copy(relayKeys = provider.relayKeys.mapIndexed { index, key -> if (index == 0) key.copy(status = null) else key })
        } else {
            provider
        }
        if (status == null || keyID == null) return cleared
        return ai.oriveo.community.core.provider.relay.RelayKeyAccess.withKeyStatuses(cleared, mapOf(keyID to status), System.currentTimeMillis())
    }

    private fun primaryKeyIDOf(provider: Provider): String =
        ai.oriveo.community.core.provider.relay.RelayKeyBinding.keyIDs(provider).first()

    /** The verdict of this failed verification for "Save anyway": it counts only if the value of that key on the connection being persisted equals the one used for verification. */
    private fun RelayEditRevision.failedStatusFor(saved: Provider): ai.oriveo.community.core.model.RelayKeyStatus? {
        val keyID = failedKeyID ?: return null
        return failedKeyStatus?.takeIf { ProviderCredentialResolver.keySecret(saved, keyID) == failedApiKey }
    }

    /** The merged version of "Save anyway (unverified)": zero network, merged into the live record, then the unverified state is written unconditionally. */
    private suspend fun persistMergedRelayEditUnverified(
        candidate: Provider,
        replacementApiKey: String?,
        baseline: Provider,
        commitGuard: () -> Boolean,
        failureRevision: RelayEditRevision,
    ): RelayEditOutcome {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(candidate.id)
        val base = normalizeProviderIds(baseline)
        val edited = normalizeProviderIds(candidate)
        repeat(RELAY_EDIT_MERGE_WRITE_ATTEMPTS) {
            if (!commitGuard()) return RelayEditOutcome(null, false, false, stale = true)
            val live = readRelayEditLive(targetAccountId, normalizedId)
                ?: return RelayEditOutcome(null, false, false, stale = true)
            val (merged, nextApiKey) = mergedRelayEditCandidate(live, base, edited, replacementApiKey)
            val catalogInvalidated = RelayEditMerge.connectionIdentityChanged(live.provider, merged)
            val unverified = (if (catalogInvalidated) merged.clearingRelayCatalog() else merged).copy(
                status = ProviderConnectionState.Issue(RELAY_UNVERIFIED_MESSAGE),
                lastCheckedAt = null,
                lastError = RELAY_UNVERIFIED_MESSAGE,
            )
            val write = guardedPersistRelayEdit(
                provider = withRelayEditKeyStatus(unverified, live.apiKey, nextApiKey, failureRevision.failedKeyID, failureRevision.failedStatusFor(unverified)), // key-choke: stored-field
                expectedEntity = live.entity,
                previousApiKey = live.apiKey,
                nextApiKey = nextApiKey,
                targetAccountId = targetAccountId,
                commitGuard = commitGuard,
            ) ?: return@repeat
            dispatchProviderSyncIfCurrent(write, targetAccountId, commitGuard)
            onRelayPrimaryKeyReplaced(write.provider, live.apiKey, nextApiKey)
            return RelayEditOutcome(
                provider = write.provider,
                persisted = true,
                verificationSucceeded = false,
                error = null,
                persistedRevision = RelayEditRevision(write.entity),
                catalogInvalidated = catalogInvalidated,
            )
        }
        return RelayEditOutcome(null, false, false, stale = true)
    }

    suspend fun removeRelayApiKey(
        id: String,
        commitGuard: () -> Boolean = { true },
    ): RelayEditOutcome {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val entity = dao.getById(targetAccountId, normalizedId)
            ?: return RelayEditOutcome(null, false, false, stale = true)
        val key = loadApiKey(targetAccountId, normalizedId)
        val provider = normalizeProviderIds(entity.toDomainWithKeys(key))
        return persistRelayEditUnverified(
            candidate = provider,
            replacementApiKey = "",
            failureRevision = RelayEditRevision(entity),
            commitGuard = commitGuard,
        )
    }

    private suspend fun upsertProviderEntity(
        provider: Provider,
        expectedAccountId: String,
    ): Provider {
        val targetAccountId = expectedAccountId
        val (finalized, entity) = finalizeForUpsert(provider, targetAccountId)
        val normalizedId = normalizeUuid(finalized.id)
        dao.upsert(entity)
        persistRelayKeySecrets(finalized, entity)
        return finalized
    }

    suspend fun updateApiKey(id: String, newKey: String) {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val initialEntity = dao.getById(targetAccountId, normalizedId) ?: return
        val previousApiKey = loadApiKey(targetAccountId, normalizedId)
        val provider = normalizeProviderIds(initialEntity.toDomainWithKeys(previousApiKey))

        val switchesBackToApiKey =
            provider.authMode == ProviderAuthMode.Subscription && newKey.isNotBlank()
        val updated = provider.copy(
            apiKey = newKey,
            apiKeyPreview = SecureKeyStore.maskApiKey(newKey),
            authMode = if (switchesBackToApiKey) ProviderAuthMode.ApiKey else provider.authMode,
            catalogModels = if (switchesBackToApiKey) emptyList() else provider.catalogModels,
        )
        if (switchesBackToApiKey) {

            if (provider.kind == ProviderKind.OpenAI) {
                openAISubscriptionRuntime.disconnect(targetAccountId, normalizedId)
            } else {
                grokSubscriptionRuntime.disconnect(targetAccountId, normalizedId)
            }
        }
        if (provider.kind == ProviderKind.Relay) {
            // The new credential is now the only stored fact. The first observable write must fail closed: the new key must not be written together with the old
            // Connected state and check time followed by an Issue, which would briefly show a false green in the UI.
            // Replacing only the key does not clear the catalog: the catalog and enabled models are kept, and after a successful verification it refreshes as usual.
            // With several keys the primary key is the one replaced: like replaceSecret, its status and no-access markers are cleared, and afterwards only that key is re-fetched.
            val primaryKeyID = provider.relayKeys?.firstOrNull()?.id
            val rotated = primaryKeyID?.let {
                ai.oriveo.community.core.provider.relay.RelayKeyBinding.replaceSecret(updated, it, newKey)
            } ?: updated
            val unverified = rotated.copy(
                status = ProviderConnectionState.Issue(RELAY_UNVERIFIED_MESSAGE),
                lastCheckedAt = null,
                lastError = RELAY_UNVERIFIED_MESSAGE,
                cachedAvailableModelCount = null,
            )
            val unverifiedWrite = guardedPersistRelayEdit(
                provider = unverified,
                expectedEntity = initialEntity,
                previousApiKey = previousApiKey,
                nextApiKey = newKey,
                targetAccountId = targetAccountId,
                commitGuard = { true },
            ) ?: throw StaleProviderMutation()
            dispatchProviderSyncIfCurrent(unverifiedWrite, targetAccountId) { true }
            onRelayPrimaryKeyReplaced(unverifiedWrite.provider, previousApiKey, newKey)

            if (newKey.isBlank()) return

            val modelID = relayVerificationSampleID(provider)
            try {
                verifyRelayGeneration(
                    apiKey = newKey,
                    baseUrl = provider.baseUrlText,
                    modelID = modelID.orEmpty(),
                    relayRequested = provider.relayRequested ?: RelayRequestedConfig(),
                    relayKind = provider.relayKind,
                )
                // A successful 1-token request is already evidence of a connection: persist Connected on its own first, then run catalog-only.
                // A catalog failure writes only the canonical soft error and never overturns the generation evidence.
                // This verification was sent with the new primary key value, and its verdict lands on the primary key in the same write.
                val now = System.currentTimeMillis()
                val connected = ai.oriveo.community.core.provider.relay.RelayKeyAccess.withKeyStatuses(
                    unverifiedWrite.provider.copy(
                        status = ProviderConnectionState.Connected,
                        lastCheckedAt = now,
                        lastError = null,
                    ),
                    mapOf(primaryKeyIDOf(unverifiedWrite.provider) to ai.oriveo.community.core.model.RelayKeyStatus("ok")),
                    now,
                )
                val connectedWrite = guardedPersistExistingProvider(
                    provider = connected,
                    expectedEntity = unverifiedWrite.entity,
                    targetAccountId = targetAccountId,
                    commitGuard = { true },
                    normalizeConversations = false,
                ) ?: throw StaleProviderMutation()
                dispatchProviderSyncIfCurrent(connectedWrite, targetAccountId) { true }
                refreshRelayCatalogOnly(
                    normalizedId,
                    expectedRevision = connectedWrite.entity,
                    onlyKeyID = primaryKeyID,
                )
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                // A failed verification also writes the primary key status: only if the connection has not changed again since the fail-closed write, and a failed write does not affect throwing.
                if (e !is StaleProviderMutation) {
                    ai.oriveo.community.core.provider.relay.RelayKeyAccess.generationStatusOf(e)?.let { status ->
                        val failed = ai.oriveo.community.core.provider.relay.RelayKeyAccess.withKeyStatuses(
                            unverifiedWrite.provider,
                            mapOf(primaryKeyIDOf(unverifiedWrite.provider) to status),
                            System.currentTimeMillis(),
                        )
                        if (failed != unverifiedWrite.provider) {
                            guardedPersistExistingProvider(
                                provider = failed,
                                expectedEntity = unverifiedWrite.entity,
                                targetAccountId = targetAccountId,
                                commitGuard = { true },
                                normalizeConversations = false,
                            )?.let { dispatchProviderSyncIfCurrent(it, targetAccountId) { true } }
                        }
                    }
                }
                // The new key is already persisted and is not rolled back; but the failure must be handed back to the UI to show the redacted details, not close the sheet as if it had succeeded.
                throw e
            }
            return
        }
        // SecureKeyStore.saveApiKey advances credentialEpoch. Persisting an unchanged
        // credential must not invalidate runtime evidence or self-heal cache entries.
        if (previousApiKey != newKey) {
            if (newKey.isBlank()) {
                deleteApiKey(targetAccountId, normalizedId)
            } else {
                saveApiKey(targetAccountId, normalizedId, newKey)
            }
        }
        upsertProviderEntity(updated, targetAccountId)
        normalizeConversationSelections(updated, targetAccountId)
        resyncProvider(normalizedId, targetAccountId)
    }

    // Multi-key relay operations: each writes the plain result of a RelayKeyBinding operation; the primary key's value travels with provider.apiKey through the existing key store.
    // (called by the key management UI)

    /**
     * Add a key and re-fetch the catalogs of all keys (the existing keys also get a status and listing keys); returns null if the id collides with an existing key.
     * The key is accepted once persisted: when the fetch write-back is discarded because of a concurrent change (stale), the latest connection in the store is still returned, and that key's status stays cleared.
     */
    suspend fun addRelayKey(id: String, keyID: String, name: String?, apiKey: String): Provider? {
        val written = applyRelayKeyOperation(id) {
            ai.oriveo.community.core.provider.relay.RelayKeyBinding.add(it, keyID, name, apiKey)
        } ?: return null
        return refreshRelayCatalogOnly(normalizeUuid(id), expectedRevision = null).provider
            ?: getById(id) ?: written
    }

    /** Replace the value of one key: clear its status and no-access markers, leave the catalog alone, then re-fetch only that key; accepted the same way as [addRelayKey]. */
    suspend fun replaceRelayKeySecret(id: String, keyID: String, apiKey: String): Provider? {
        var valueChanged = false
        val written = applyRelayKeyOperation(id) {
            valueChanged = apiKey.isNotBlank() && ProviderCredentialResolver.keySecret(it, keyID) != apiKey
            ai.oriveo.community.core.provider.relay.RelayKeyBinding.replaceSecret(it, keyID, apiKey)
        } ?: return null
        if (valueChanged) onRelayKeysReplaced(written, setOf(keyID))
        return refreshRelayCatalogOnly(normalizeUuid(id), expectedRevision = null, onlyKeyID = keyID).provider
            ?: getById(id) ?: written
    }

    /** "Retry" of the key status bar in the model library: re-fetch only that key's catalog and mark the other keys skipped (a failure does not clear the entries that key listed last time). */
    suspend fun refreshRelayKeyCatalog(id: String, keyID: String): Provider? =
        refreshRelayCatalogOnly(normalizeUuid(id), expectedRevision = null, onlyKeyID = keyID).provider

    suspend fun renameRelayKey(id: String, keyID: String, name: String?): Provider? =
        applyRelayKeyOperation(id) { ai.oriveo.community.core.provider.relay.RelayKeyBinding.rename(it, keyID, name) }

    suspend fun moveRelayKey(id: String, keyID: String, toIndex: Int): Provider? =
        applyRelayKeyOperation(id) { ai.oriveo.community.core.provider.relay.RelayKeyBinding.move(it, keyID, toIndex) }

    /** Delete one key; refuses (null) for the last key. */
    suspend fun deleteRelayKey(id: String, keyID: String): Provider? =
        applyRelayKeyOperation(id) { ai.oriveo.community.core.provider.relay.RelayKeyBinding.delete(it, keyID) }

    /** Rebind a model to another key; rebinding clears the reachable protocol, and if the model has no protocol, sends a 1-token lazy verification as it does when enabling. */
    suspend fun rebindRelayModelKey(id: String, modelID: String, keyID: String): Provider? {
        val written = applyRelayKeyOperation(id) {
            ai.oriveo.community.core.provider.relay.RelayKeyBinding.rebind(it, modelID, keyID)
        } ?: return null
        // The key changed, so the previous key's "not connected" no longer holds.
        setRelayModelProbeState(id, modelID, null)
        if (written.models.firstOrNull { it.id == modelID }?.relayTransport == null) probeEnabledRelayModel(id, modelID)
        return written
    }

    /** Persisting a key operation: if the primary key's value changed (replace / reorder / delete the primary key) it goes through [guardedPersistRelayEdit] so the key store is written together. */
    private suspend fun applyRelayKeyOperation(id: String, operation: (Provider) -> Provider?): Provider? {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val entity = dao.getById(targetAccountId, normalizedId) ?: return null
        val previousApiKey = loadApiKey(targetAccountId, normalizedId)
        val provider = normalizeProviderIds(entity.toDomainWithKeys(previousApiKey))
        if (provider.kind != ProviderKind.Relay) return null
        val operated = operation(provider) ?: return null
        if (operated == provider) return provider
        val next = if (operated.apiKey == previousApiKey) { // key-choke: stored-field
            operated
        } else {
            operated.copy(apiKeyPreview = SecureKeyStore.maskApiKey(operated.apiKey)) // key-choke: stored-field
        }
        val write = guardedPersistRelayEdit(
            provider = next,
            expectedEntity = entity,
            previousApiKey = previousApiKey,
            nextApiKey = next.apiKey, // key-choke: stored-field
            targetAccountId = targetAccountId,
            commitGuard = { true },
        ) ?: throw StaleProviderMutation()
        dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
        return write.provider
    }

    suspend fun updateBaseUrl(
        id: String,
        newBaseUrl: String?,
        endpointSource: String? = null,
        setupValues: Map<String, String>? = null,
    ) {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val provider = getById(targetAccountId, normalizedId) ?: return
        val trimmedBaseUrl = newBaseUrl?.trim().takeUnless { it.isNullOrEmpty() }
        // The address changed, so clear the source; it is recomputed from the new address before persisting.
        val rebased = OfficialEndpointSource.withBaseUrlText(
            provider,
            if (ai.oriveo.community.feature.providers.setup.ProviderSetupCatalogResolver.current()
                    .usesConfigurableBaseUrl(provider.kind)
            ) {
                trimmedBaseUrl ?: provider.kind.defaultBaseUrl
            } else {
                provider.baseUrlText
            },
        )
        // The detail page picked an address template: the source and setup values are written with the address in one write, stored only on this device, the same way as registerProvider on the setup page.
        val updated = if (provider.kind != ProviderKind.Relay && (endpointSource != null || setupValues != null)) {
            rebased.copy(endpointSource = endpointSource, setupValues = setupValues)
        } else {
            rebased
        }
        updateProvider(updated, targetAccountId)
        if (provider.kind == ProviderKind.Relay && provider.baseUrlText?.trim() != updated.baseUrlText?.trim()) {
            // Endpoint changes alter connection scope, never credential material.
            secureKeyStore.advanceCapabilityConnectionGeneration(targetAccountId, normalizedId)
        }
        resyncProvider(normalizedId, targetAccountId)
    }

    suspend fun saveManualModel(providerID: String, modelID: String) {
        val targetAccountId = accountId
        val normalizedProviderId = normalizeUuid(providerID)
        val provider = getById(targetAccountId, normalizedProviderId)
            ?: throw ProviderServiceError.InvalidConfiguration(
                detail = "Provider $normalizedProviderId not found in database",
            )
        val manualCapabilities = DEFAULT_MANUAL_MODEL_CAPABILITIES
        val manualModel = ai.oriveo.community.core.model.AIModel(
            id = modelID,
            name = modelID,
            capabilities = manualCapabilities,
            reasoningModeAvailable = ModelCapability.Reasoning in manualCapabilities,
            isDefault = true,
            isAvailable = true,
            imageGenProfile = if (ModelCapability.ImageGen in manualCapabilities) "default" else null,
            isManual = true,
        ).let { ai.oriveo.community.core.provider.relay.RelayKeyBinding.withBinding(provider, it) }
        val isRelay = provider.kind == ProviderKind.Relay
        val nextCatalogModels = if (isRelay) {
            (provider.catalogModels + manualModel).distinctBy { it.id }
        } else {

            emptyList()
        }
        val updated = ModelSelectionUtils.synchronizeDefaultSelection(
            provider = provider.copy(
                models = listOf(manualModel),
                catalogModels = nextCatalogModels,
                status = provider.status,
                lastError = provider.lastError,
            ),
            preferredModelId = manualModel.id,
        )

        val persisted = upsertProviderEntity(updated, targetAccountId)
        // A manual identifier is a new runtime identity even when the connection itself is unchanged.
        // Drop learned outcomes before the new row can be selected; otherwise an old model with the same
        // normalized id can lend its positive/negative verdict to a user-edited definition.
        toolCallMemoryStore?.clearConnection(targetAccountId, normalizedProviderId)
        normalizeConversationSelections(persisted, targetAccountId)
    }

    /** Connection edits invalidate observations; cosmetic rename/default-selection changes do not. */
    private fun toolCallMemoryScopeChanged(previous: Provider, next: Provider): Boolean {
        if (previous.authMode != next.authMode || previous.kind != next.kind) return true
        if (previous.baseUrlText?.trim() != next.baseUrlText?.trim()) return true
        if (previous.relayRequested != next.relayRequested) return true

        fun manualIdentity(provider: Provider): Set<String> = provider.allModels
            .asSequence()
            .filter { it.isManual }
            .map { MetadataClient.normalizeModelFactsID(it.id) }
            .toSet()

        return manualIdentity(previous) != manualIdentity(next)
    }

    private suspend fun normalizeConversationSelections(provider: Provider, targetAccountId: String) {
        // A relay conversation's model is neither replaced nor rewritten: when it is removed, the chat page asks the user to choose again.
        if (provider.kind == ProviderKind.Relay) return
        val defaultModel = provider.defaultModel ?: return
        withContext(Dispatchers.IO) {
            val defaultStoredModelId = ModelSelectionUtils.preferredStoredModelIdentifier(defaultModel, provider.kind)
            // Read the catalog once and index it once: every read of allModels on a built-in provider is a full
            // resolve, and a relay catalog comes from the user's own server (up to tens of thousands of models).
            // Reading and scanning it per conversation cost conversations x catalog size.
            val allModels by lazy { provider.allModels }
            val availableModelIds by lazy { allModels.map { it.id }.toSet() }
            val catalogIndex by lazy { ModelSelectionUtils.catalogMatchIndex(allModels, provider.kind) }
            val resolvedByStoredId = HashMap<String, String>()
            val conversations = conversationDao.getAll(targetAccountId)

            val toUpdate = conversations
                .filter { sameNormalizedUuid(it.providerID, provider.id) }
                .mapNotNull { entity ->
                    val resolvedModelId = resolvedByStoredId.getOrPut(entity.modelID) {
                        catalogIndex.match(entity.modelID)
                            ?.let { ModelSelectionUtils.preferredStoredModelIdentifier(it, provider.kind) }
                            ?: if (availableModelIds.contains(entity.modelID)) {
                                entity.modelID
                            } else {
                                defaultStoredModelId
                            }
                    }

                    if (resolvedModelId != entity.modelID) {
                        entity.copy(modelID = resolvedModelId)
                    } else {
                        null
                    }
                }

            if (toUpdate.isNotEmpty()) {

                conversationDao.updateAll(toUpdate)
            }
        }
    }

    /** Resolves the [ProviderService] that speaks to a given provider kind. */
    fun serviceFor(kind: ProviderKind): ProviderService = when (kind) {
        ProviderKind.OpenRouter -> openRouterService
        ProviderKind.OpenAI -> openAIService
        ProviderKind.DeepSeek -> deepSeekService
        ProviderKind.Grok -> grokService
        ProviderKind.Anthropic -> anthropicService
        ProviderKind.Gemini -> geminiService
        ProviderKind.Groq -> groqService
        ProviderKind.Together -> togetherService
        ProviderKind.Fireworks -> fireworksService
        ProviderKind.MiniMax -> miniMaxService
        ProviderKind.Zhipu -> zhipuService
        ProviderKind.Qwen -> qwenService
        ProviderKind.Moonshot -> moonshotService
        ProviderKind.Mistral -> mistralService
        ProviderKind.SiliconFlow -> siliconFlowService
        ProviderKind.Relay -> relayService
    }

    /**
     * Pick the outbound service by (connection, model). A relay uses RelayService, and the protocol and root are resolved per model by the outbound layer;
     * an official home looks at the apiProtocol sent down by metadata: a native family / not sent / unrecognized goes to the per-home service,
     * any other protocol goes to the relay's per-protocol builders, and providerKind only decides authentication and extra headers.
     */
    @Suppress("UNUSED_PARAMETER")
    fun serviceFor(provider: Provider, model: AIModel?): ProviderService = when (provider.kind) {
        ProviderKind.Relay -> relayService
        else -> ai.oriveo.community.core.provider.OfficialProtocolDispatch.service(
            kind = provider.kind,
            native = serviceFor(provider.kind),
            relay = relayService,
        )
    }

    /** [modelTransport]: the candidate protocol of the per-model probe (null = follow the connection default), see RelayModelProbe. */
    suspend fun pingRelayConnection(
        apiKey: String,
        baseUrl: String?,
        modelID: String,
        relayRequested: RelayRequestedConfig,
        relayKind: RelayKind? = null,
        modelTransport: RelayTransport? = null,
    ) {
        withContext(Dispatchers.IO) {
            relayService.verifyGeneration(
                apiKey = apiKey,
                baseUrl = baseUrl,
                modelID = modelID,
                relayRequested = relayRequested,
                relayKind = relayKind,
                modelTransport = modelTransport,
            )
        }
    }

    suspend fun verifyRelayGeneration(
        apiKey: String,
        baseUrl: String?,
        modelID: String,
        relayRequested: RelayRequestedConfig,
        relayKind: RelayKind? = null,
    ) {
        if (modelID.isBlank()) {
            throw ProviderServiceError.InvalidConfiguration(
                detail = "A model is required for generation verification.",
            )
        }
        withContext(Dispatchers.IO) {
            relayService.verifyGeneration(
                apiKey = apiKey,
                baseUrl = baseUrl,
                modelID = modelID,
                relayRequested = relayRequested,
                relayKind = relayKind,
            )
        }
    }

    suspend fun verifyPersistedRelayGeneration(id: String): RelayGenerationVerificationOutcome {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val expectedEntity = dao.getById(targetAccountId, normalizedId)
            ?: return RelayGenerationVerificationOutcome(
                provider = null,
                attemptedProvider = null,
                verificationSucceeded = false,
                stale = true,
            )
        val expectedApiKey = loadApiKey(targetAccountId, normalizedId)
        val provider = normalizeProviderIds(expectedEntity.toDomainWithKeys(expectedApiKey))
        if (provider.kind != ProviderKind.Relay) {
            return RelayGenerationVerificationOutcome(
                provider = provider,
                attemptedProvider = provider,
                verificationSucceeded = false,
                error = ProviderServiceError.InvalidConfiguration("Provider is not a Relay connection."),
            )
        }
        val modelID = relayGenerationVerificationModelID(provider)
        val sentApiKey = ProviderCredentialResolver.apiKey(provider, modelID.ifEmpty { null })
        val error = try {
            verifyRelayGeneration(
                apiKey = sentApiKey,
                baseUrl = provider.baseUrlText,
                modelID = modelID,
                relayRequested = provider.relayRequested ?: RelayRequestedConfig(),
                relayKind = provider.relayKind,
            )
            null
        } catch (caught: Exception) {
            if (caught is kotlinx.coroutines.CancellationException) throw caught
            caught
        }
        val verified = error == null
        // Written onto the effective key of the sample model; persisted in the same CAS as the connection state, and discarded together if the identity changed.
        val keyStatus = ai.oriveo.community.core.provider.relay.RelayKeyAccess.generationStatusOf(error)
            .takeIf { modelID.isNotEmpty() }
        // Both the primary key value and the value of the key actually sent must be unchanged (a non-primary key's new value does not change the entity, so the CAS cannot catch it).
        val latestSentApiKey = dao.getById(targetAccountId, normalizedId)
            ?.let { normalizeProviderIds(it.toDomainWithKeys(loadApiKey(targetAccountId, normalizedId))) }
            ?.let { ProviderCredentialResolver.apiKey(it, modelID.ifEmpty { null }) }
        if (loadApiKey(targetAccountId, normalizedId) != expectedApiKey || latestSentApiKey != sentApiKey) {
            return RelayGenerationVerificationOutcome(
                provider = getById(targetAccountId, normalizedId),
                attemptedProvider = provider,
                verificationSucceeded = verified,
                stale = true,
                error = error,
            )
        }
        val now = System.currentTimeMillis()
        val updated = ai.oriveo.community.core.provider.relay.RelayKeyAccess.withKeyStatuses(
            provider.copy(
                status = if (verified) {
                    ProviderConnectionState.Connected
                } else {
                    ProviderConnectionState.Issue(RELAY_UNVERIFIED_MESSAGE)
                },
                lastCheckedAt = if (verified) now else provider.lastCheckedAt,
                lastError = if (verified) null else RELAY_UNVERIFIED_MESSAGE,
            ),
            keyStatus?.let { mapOf(ai.oriveo.community.core.provider.relay.RelayKeyBinding.effectiveKeyID(provider, modelID) to it) }.orEmpty(),
            now,
        )
        val write = guardedPersistExistingProvider(
            provider = updated,
            expectedEntity = expectedEntity,
            targetAccountId = targetAccountId,
            commitGuard = { true },
            normalizeConversations = false,
        ) ?: return RelayGenerationVerificationOutcome(
            provider = getById(targetAccountId, normalizedId),
            attemptedProvider = provider,
            verificationSucceeded = verified,
            stale = true,
            error = error,
        )
        dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
        return RelayGenerationVerificationOutcome(
            provider = write.provider,
            attemptedProvider = provider,
            verificationSucceeded = verified,
            error = error,
        )
    }

    suspend fun reverifyRelayProvider(id: String): Provider? {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val provider = getById(targetAccountId, normalizedId) ?: return null
        if (provider.kind != ProviderKind.Relay) {
            resyncProvider(normalizedId, targetAccountId)
            return getById(targetAccountId, normalizedId)
        }
        return verifyPersistedRelayGeneration(normalizedId).provider
    }

    /**
     * Lazy verification after a single relay model is enabled from the model library: the caller writes the enablement to the store first, then calls this.
     * Relay shape only, not a local engine; a model that already has a protocol (from any source) is not probed; if the user chose the connection protocol it is neither probed nor written.
     * A failed probe neither revokes the enablement nor throws. Callers that enable several at once (enable all / batch) do not call this: no background batch probing.
     */
    suspend fun probeEnabledRelayModel(id: String, modelID: String) {
        var started = false
        try {
            val targetAccountId = accountId
            val provider = getById(targetAccountId, normalizeUuid(id)) ?: return
            if (!acceptsRelayAutoProbe(provider)) return
            val model = provider.models.firstOrNull { it.id == modelID } ?: return
            if (model.relayTransport != null) return
            started = true
            setRelayModelProbeState(id, modelID, RelayModelProbeState.InFlight)
            var passed = false
            probeAndPinRelayModel(provider, modelID, targetAccountId) { outcome ->
                passed = outcome.pass != null
                // Record "not connected + reason" only if a 1-token request was really sent and none passed (in memory only); clear it on a pass or when none was sent.
                setRelayModelProbeState(
                    id,
                    modelID,
                    if (outcome.pass == null && outcome.attempted.isNotEmpty()) relayProbeFailure(outcome.lastError) else null,
                )
            }
            // The lazy verification really ran and passed: afterwards run one web search probe in the background according to the selection; none if it did not run or failed.
            if (passed) launchRelayWebProbeAfterEnable(id, modelID)
            if (relayModelProbeStates(id)[modelID] == RelayModelProbeState.InFlight) {
                setRelayModelProbeState(id, modelID, null)
            }
        } catch (error: kotlinx.coroutines.CancellationException) {
            if (started) setRelayModelProbeState(id, modelID, null)
            throw error
        } catch (error: Exception) {
            // Lazy verification is a nice-to-have: a failure neither revokes the enablement nor throws. What reaches here is a failure outside the request (reading the store / the key / writing back);
            // a failure of the request itself was already recorded by onOutcome; here only "verifying" is cleared, without posing as not connected.
            if (started && relayModelProbeStates(id)[modelID] == RelayModelProbeState.InFlight) {
                setRelayModelProbeState(id, modelID, null)
            }
        }
    }

    private fun relayProbeFailure(error: Throwable?): RelayModelProbeState.Failed =
        RelayModelProbeState.Failed(error, (error as? ProviderServiceError)?.relayKeyAccess?.status)

    /**
     * The user's explicit "Test capabilities": send text, then image input, then tools on the model's current effective protocol,
     * one streaming request per item, built by the same builders as chat (the key is taken per model), with a total time limit of [deadlineMillis] per item.
     * Results are written into relayCapabilityOverrides (source tested), through the same write-back path as the per-model probe.
     * Before each item is sent and before write-back, the latest entity is re-read and judged in this order: the model is no longer testable (deleted / out of scope) -> unavailable,
     * the connection identity (same as [sameRelayProbeConnection]) changed -> connection, the effective protocol changed -> protocol;
     * on interruption the verdicts of the items already finished stay in the result and none is written. Per-item progress is reported to the caller through [onProgress].
     */
    suspend fun runRelayCapabilityTest(
        id: String,
        modelID: String,
        deadlineMillis: Long = ai.oriveo.community.core.provider.relay.RelayCapabilityTest.PER_ITEM_DEADLINE_MILLIS,
        onProgress: (ai.oriveo.community.core.provider.relay.RelayCapabilityTestProgress) -> Unit = {},
    ): ai.oriveo.community.core.provider.relay.RelayCapabilityTestRun {
        val capabilityTest = ai.oriveo.community.core.provider.relay.RelayCapabilityTest
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val provider = getById(targetAccountId, normalizedId)
        val model = provider?.models?.firstOrNull { it.id == modelID }
        if (provider == null || model == null || !capabilityTest.isTestable(provider, model)) {
            return ai.oriveo.community.core.provider.relay.RelayCapabilityTestRun(
                textFailed = false,
                sent = emptyList(),
                image = null,
                toolCall = null,
                planned = capabilityTest.plannedKinds(model?.relayCapabilityOverrides),
                stopReason = ai.oriveo.community.core.provider.relay.RelayCapabilityTestStopReason.Unavailable,
            )
        }
        // The same path as chat: send with the first-send protocol (the no-attachment version) rather than effectiveTransport.
        val transport = ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(provider, model)
        // When the first send changed the protocol, the root is taken for the first-send protocol (the same way as the first send in ChatRepository).
        val rootModel = model.takeIf { transport != ai.oriveo.community.core.provider.RelayEndpointResolver.effectiveTransport(provider, it) }
            ?.copy(relayTransport = transport) ?: model
        // The fourth item, web search, is listed only if the first-send protocol has a stored fragment (the same criterion as runRelayWebProbe).
        val webListed = capabilityTest.listsWeb(provider, model, relayWebFragmentStore)
        // The same request options as a relay send in ChatRepository: the connection copy, the protocol and root resolved per model, the evidence model and the connection identity.
        val requestOptions = ai.oriveo.community.core.model.ChatRequestOptions(
            relayRequested = provider.relayRequested,
            relayImage = provider.relayImage,
            relayRouteTransport = transport,
            relayRouteAPIRoot = ai.oriveo.community.core.provider.RelayEndpointResolver.effectiveAPIRoot(provider, rootModel),
            activeModel = model,
            capabilityEvidenceIdentity = capabilityEvidenceIdentity(provider, modelID),
        )

        /** Re-read the latest connection and judge whether this can continue; null = yes, [target] returns the latest entity and connection. */
        suspend fun stopReason(): Pair<ai.oriveo.community.core.provider.relay.RelayCapabilityTestStopReason?, Pair<ProviderEntity, Provider>?> {
            val entity = dao.getById(targetAccountId, provider.id)
                ?: return ai.oriveo.community.core.provider.relay.RelayCapabilityTestStopReason.Unavailable to null
            val latest = normalizeProviderIds(entity.toDomainWithKeys(loadApiKey(targetAccountId, provider.id)))
            val target = latest.models.firstOrNull { it.id == modelID }
            val reason = when {
                target == null || !capabilityTest.isTestable(latest, target) ->
                    ai.oriveo.community.core.provider.relay.RelayCapabilityTestStopReason.Unavailable
                !sameRelayProbeConnection(provider, latest, modelID) ->
                    ai.oriveo.community.core.provider.relay.RelayCapabilityTestStopReason.Connection
                ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(latest, target) != transport ->
                    ai.oriveo.community.core.provider.relay.RelayCapabilityTestStopReason.Protocol
                else -> null
            }
            return reason to (entity to latest)
        }

        val run = capabilityTest.run(
            existing = model.relayCapabilityOverrides,
            web = webListed,
            deadlineMillis = deadlineMillis,
            beforeSend = { stopReason().first },
            onProgress = onProgress,
        ) { kind ->
            val response = withContext(Dispatchers.IO) {
                relayService.sendCapabilityTest(
                    apiKey = ProviderCredentialResolver.apiKey(provider, modelID),
                    modelID = modelID,
                    message = capabilityTest.message(kind, modelID),
                    baseUrl = provider.baseUrlText,
                    requestOptions = requestOptions,
                    extras = capabilityTest.buildExtras(kind),
                )
            }
            // Every request writes the key status from its HTTP result; a timeout / network failure has no HTTP status, so nothing is written.
            // A 2xx counts as ok only when this side judges it a true success (not a web page, and no rejection in the body).
            (response as? ai.oriveo.community.core.provider.relay.RelayCapabilityTestResponse.Http)?.let {
                val status = if (it.status in 200..299) {
                    ai.oriveo.community.core.model.RelayKeyStatus("ok").takeIf { _ ->
                        capabilityTest.classify(it.status, it.contentType, it.body).reason ==
                            ai.oriveo.community.core.provider.relay.RelayCapabilityTestReason.Ok
                    }
                } else {
                    ai.oriveo.community.core.provider.relay.RelayKeyAccess.generationStatus(it.status, it.body)
                }
                recordRelayGenerationKeyStatus(provider, modelID, status, targetAccountId)
            }
            response
        }
        if (run.textFailed || run.stopReason != null) return run

        /** Write back the image / tool verdicts; on interruption returns a result carrying stopReason. */
        suspend fun writeBack(): ai.oriveo.community.core.provider.relay.RelayCapabilityTestRun {
            repeat(RELAY_MODEL_WRITE_ATTEMPTS) {
                val (reason, latestPair) = stopReason()
                if (reason != null) return run.copy(stopReason = reason)
                val (entity, latest) = requireNotNull(latestPair)
                val next = capabilityTest.applyingResult(latest, modelID, run, relayNegativeCache)
                if (next == latest) return run.copy(written = run.hasWritableResult)
                guardedPersistExistingProvider(
                    provider = next,
                    expectedEntity = entity,
                    targetAccountId = targetAccountId,
                    commitGuard = { true },
                    normalizeConversations = false,
                )?.let { write ->
                    // Already persisted: a later error while dispatching the sync does not change "written", and the panel must not report an interruption.
                    try {
                        dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
                    } catch (error: kotlinx.coroutines.CancellationException) {
                        throw error
                    } catch (_: Exception) {
                    }
                    return run.copy(written = run.hasWritableResult)
                }
            }
            return run
        }
        val afterWrite = writeBack()
        if (!webListed || afterWrite.stopReason != null) return afterWrite

        // The fourth item, web search: after the first three it runs the manual web search probe, with no cap, no de-duplication and not entered into the automatic history.
        val web = ai.oriveo.community.core.provider.relay.RelayCapabilityTestKind.Web
        stopReason().first?.let { return afterWrite.copy(stopReason = it) }
        onProgress(ai.oriveo.community.core.provider.relay.RelayCapabilityTestProgress(afterWrite.planned, afterWrite.items, web))
        val started = System.nanoTime()
        val outcome = runRelayWebProbe(id, modelID, deadlineMillis)
        val elapsed = ((System.nanoTime() - started) / 1_000_000L).coerceAtLeast(0L)
        // The probe did not finish or the pre-write re-check failed (fragment changed / deleted, connection / protocol changed): the panel is interrupted, first with the re-check reason, otherwise with "protocol changed" (same as iOS / Web).
        val protocolStop = ai.oriveo.community.core.provider.relay.RelayCapabilityTestStopReason.Protocol
        val completed = outcome as? ai.oriveo.community.core.provider.relay.RelayWebProbeOutcome.Completed
            ?: return afterWrite.copy(stopReason = stopReason().first ?: protocolStop)
        // Undetermined does not go through the pre-write re-check: check once more here, and if the configuration already changed, do not report this item's result.
        stopReason().first?.let { return afterWrite.copy(stopReason = it) }
        val currentFragment = getById(targetAccountId, normalizedId)
            ?.let { relayWebFragmentStore.effective(it)[transport.value] }
            ?.takeIf { it.isNotEmpty() }
        if (currentFragment == null || ai.oriveo.community.core.provider.relay.RelayWebProbe.fragmentHash(currentFragment) != completed.fragmentHash) {
            return afterWrite.copy(stopReason = protocolStop)
        }
        val verdict = when (completed.result) {
            ai.oriveo.community.core.provider.relay.RelayWebProbeResult.Searched -> ai.oriveo.community.core.provider.relay.RelayCapabilityVerdict.Searched
            ai.oriveo.community.core.provider.relay.RelayWebProbeResult.Silent -> ai.oriveo.community.core.provider.relay.RelayCapabilityVerdict.Silent
            ai.oriveo.community.core.provider.relay.RelayWebProbeResult.Rejected -> ai.oriveo.community.core.provider.relay.RelayCapabilityVerdict.Rejected
            ai.oriveo.community.core.provider.relay.RelayWebProbeResult.Undetermined -> ai.oriveo.community.core.provider.relay.RelayCapabilityVerdict.Undetermined
        }
        val items = afterWrite.items + ai.oriveo.community.core.provider.relay.RelayCapabilityTestItemResult(
            web, verdict, completed.reason, completed.status, elapsed,
        )
        onProgress(ai.oriveo.community.core.provider.relay.RelayCapabilityTestProgress(afterWrite.planned, items, null))
        // written includes the web override write: only an actual rewrite of the web override counts (a web set by the user is left alone and does not count as written).
        return afterWrite.copy(sent = afterWrite.sent + web, items = items, written = afterWrite.written || completed.overrideWritten)
    }

    /**
     * Relay web search probe: sent only for a relay whose model is testable and whose first-send protocol has a fragment; otherwise it is not listed and zero requests are made.
     * The result is written to the local probe record (connection x model x protocol); searched / rejected also write the web override (source tested, user entries untouched).
     * silent / undetermined remove the tested web. For the automatic triggers see [relayWebFragmentsSaved] and [probeEnabledRelayModel].
     */
    suspend fun runRelayWebProbe(
        id: String,
        modelID: String,
        deadlineMillis: Long = ai.oriveo.community.core.provider.relay.RelayWebProbe.TIMEOUT_MILLIS,
    ): ai.oriveo.community.core.provider.relay.RelayWebProbeOutcome {
        val probe = ai.oriveo.community.core.provider.relay.RelayWebProbe
        val notListed = ai.oriveo.community.core.provider.relay.RelayWebProbeOutcome.NotListed
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val provider = getById(targetAccountId, normalizedId) ?: return notListed
        val model = provider.models.firstOrNull { it.id == modelID } ?: return notListed
        if (!probe.isProbeForm(provider) || !ai.oriveo.community.core.provider.relay.RelayCapabilityTest.isTestable(provider, model)) {
            return notListed
        }
        // The same way as capability testing: the model's first-send protocol, with the root taken for it.
        val transport = ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(provider, model)
        // No fragment = not listed, zero requests.
        val fragment = relayWebFragmentStore.effective(provider)[transport.value] ?: return notListed
        val rootModel = model.takeIf { transport != ai.oriveo.community.core.provider.RelayEndpointResolver.effectiveTransport(provider, it) }
            ?.copy(relayTransport = transport) ?: model
        val requestOptions = ai.oriveo.community.core.model.ChatRequestOptions(
            relayRequested = provider.relayRequested,
            relayImage = provider.relayImage,
            relayRouteTransport = transport,
            relayRouteAPIRoot = ai.oriveo.community.core.provider.RelayEndpointResolver.effectiveAPIRoot(provider, rootModel),
            activeModel = model,
            capabilityEvidenceIdentity = capabilityEvidenceIdentity(provider, modelID),
            relayWebFragments = mapOf(transport.value to fragment),
        )
        val outcome = probe.run(fragment, deadlineMillis, relayWebProbeRecords::now) {
            withContext(Dispatchers.IO) {
                relayService.sendWebProbe(
                    apiKey = ProviderCredentialResolver.apiKey(provider, modelID),
                    modelID = modelID,
                    baseUrl = provider.baseUrlText,
                    requestOptions = requestOptions,
                )
            }
        }
        val completed = outcome as? ai.oriveo.community.core.provider.relay.RelayWebProbeOutcome.Completed ?: return outcome
        // Undetermined writes no record and changes no override; otherwise mirror the tested web by the merged current record.
        val record = probe.recordOf(completed) ?: return completed
        var merged: ai.oriveo.community.core.provider.relay.RelayWebProbeResult? = null
        var recorded = false
        // Re-check failed: if no record was written yet, interrupt with the reason (same as Web / iOS); if a record was already written in a retry round, report only that the record was written.
        fun stopped(reason: ai.oriveo.community.core.provider.relay.RelayWebProbeStopReason) =
            if (recorded) completed.copy(written = true) else ai.oriveo.community.core.provider.relay.RelayWebProbeOutcome.Stopped(reason)
        repeat(RELAY_MODEL_WRITE_ATTEMPTS) {
            // Re-read before writing: if the model is gone, or the connection identity, the first-send protocol or that protocol's fragment changed, this result does not belong to the current configuration and nothing is written.
            val entity = dao.getById(targetAccountId, provider.id)
                ?: return stopped(ai.oriveo.community.core.provider.relay.RelayWebProbeStopReason.Unavailable)
            val latest = normalizeProviderIds(entity.toDomainWithKeys(loadApiKey(targetAccountId, provider.id)))
            val target = latest.models.firstOrNull { it.id == modelID }
                ?: return stopped(ai.oriveo.community.core.provider.relay.RelayWebProbeStopReason.Unavailable)
            if (!sameRelayProbeConnection(provider, latest, modelID)) {
                return stopped(ai.oriveo.community.core.provider.relay.RelayWebProbeStopReason.Connection)
            }
            if (ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(latest, target) != transport) {
                return stopped(ai.oriveo.community.core.provider.relay.RelayWebProbeStopReason.Protocol)
            }
            val latestFragment = relayWebFragmentStore.effective(latest)[transport.value]?.takeIf { it.isNotEmpty() }
            if (latestFragment == null || probe.fragmentHash(latestFragment) != completed.fragmentHash) {
                return stopped(ai.oriveo.community.core.provider.relay.RelayWebProbeStopReason.Fragment)
            }
            if (!recorded) {
                merged = relayWebProbeRecords.record(
                    ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore.Key(provider.id, modelID, transport.value),
                    record,
                )?.result
                recorded = true
            }
            val applied = merged ?: record.result
            val next = probe.applyingResult(latest, modelID, applied)
            if (next == latest) return completed.copy(written = recorded)
            guardedPersistExistingProvider(
                provider = next,
                expectedEntity = entity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = false,
            )?.let { write ->
                try {
                    dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
                } catch (error: kotlinx.coroutines.CancellationException) {
                    throw error
                } catch (_: Exception) {
                }
                // silent only removes the tested web and does not count as "written" (same as Web overrideWritten).
                return completed.copy(
                    written = recorded,
                    overrideWritten = applied != ai.oriveo.community.core.provider.relay.RelayWebProbeResult.Silent,
                )
            }
        }
        return completed.copy(written = recorded)
    }

    /**
     * After the Web Search page is saved successfully: [changedTransports] = the protocols whose fragment hash changed (`RelayTransport.value`).
     * Run serially in the repository scope (closing the page does not cancel it): clear the tested web of models whose first-send protocol's fragment changed, prune the automatic history, then auto-probe one by one by selection.
     */
    fun relayWebFragmentsSaved(id: String, changedTransports: Set<String>): kotlinx.coroutines.Job =
        relayProbeScope.launch {
            relayWebAutoProbeMutex.withLock {
                val targetAccountId = accountId
                val normalizedId = normalizeUuid(id)
                clearRelayTestedWeb(normalizedId, changedTransports, targetAccountId)
                val provider = getById(targetAccountId, normalizedId) ?: return@withLock
                val current = relayWebFragmentStore.effective(provider)
                    .filterValues { it.isNotEmpty() }
                    .mapValues { ai.oriveo.community.core.provider.relay.RelayWebProbe.fragmentHash(it.value) }
                relayWebProbeAutoHistory.prune(normalizedId, relayWebProbeRecords.now(), current)
                val candidates = provider.models.mapNotNull { model ->
                    if (!ai.oriveo.community.core.provider.relay.RelayCapabilityTest.isTestable(provider, model)) return@mapNotNull null
                    val transport = ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(provider, model).value
                    current[transport]?.let { ai.oriveo.community.core.provider.relay.RelayWebProbeCandidate(model.id, transport, it) }
                }
                runRelayWebAutoProbes(
                    provider,
                    ai.oriveo.community.core.provider.relay.RelayWebProbeTriggerEvent.SaveFragment,
                    candidates,
                )
            }
        }

    /** Serializes automatic probes: save and enable events run one after another, so selection always sees the history written by the previous event. */
    private val relayWebAutoProbeMutex = Mutex()

    /** After a lazy verification really ran and passed: if the first-send protocol has a non-empty fragment, probe this one model by selection. */
    private fun launchRelayWebProbeAfterEnable(id: String, modelID: String) {
        relayProbeScope.launch {
            relayWebAutoProbeMutex.withLock {
                val provider = getById(accountId, normalizeUuid(id)) ?: return@withLock
                val model = provider.models.firstOrNull { it.id == modelID } ?: return@withLock
                if (!ai.oriveo.community.core.provider.relay.RelayCapabilityTest.isTestable(provider, model)) return@withLock
                val transport = ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(provider, model).value
                val fragment = relayWebFragmentStore.effective(provider)[transport]?.takeIf { it.isNotEmpty() } ?: return@withLock
                runRelayWebAutoProbes(
                    provider,
                    ai.oriveo.community.core.provider.relay.RelayWebProbeTriggerEvent.EnableModel(lazyVerifyPassed = true),
                    listOf(
                        ai.oriveo.community.core.provider.relay.RelayWebProbeCandidate(
                            modelID,
                            transport,
                            ai.oriveo.community.core.provider.relay.RelayWebProbe.fragmentHash(fragment),
                        ),
                    ),
                )
            }
        }
    }

    /** Send one by one by selection: write the automatic history before sending, then go through the production probe (the result writes the record and the override). One failure does not affect the ones after it. */
    private suspend fun runRelayWebAutoProbes(
        provider: Provider,
        event: ai.oriveo.community.core.provider.relay.RelayWebProbeTriggerEvent,
        candidates: List<ai.oriveo.community.core.provider.relay.RelayWebProbeCandidate>,
    ) {
        val selection = ai.oriveo.community.core.provider.relay.RelayWebProbeTrigger.select(
            isRelayForm = ai.oriveo.community.core.provider.relay.RelayWebProbe.isProbeForm(provider),
            event = event,
            candidates = candidates,
            history = relayWebProbeAutoHistory.entries(),
            now = relayWebProbeRecords.now(),
            connectionId = provider.id,
        )
        val byModel = candidates.associateBy { it.modelId }
        for (modelID in selection.probe) {
            val candidate = byModel[modelID] ?: continue
            // The model was disabled while queued, or the first-send protocol or fragment changed (for example another one was saved right after): this one is no longer sent and no history is written.
            if (relayWebAutoCandidate(provider.id, modelID) != candidate) continue
            relayWebProbeAutoHistory.add(
                ai.oriveo.community.core.provider.relay.RelayWebProbeAutoEntry(
                    connectionId = provider.id,
                    modelId = modelID,
                    transport = candidate.transport,
                    fragmentHash = candidate.fragmentHash,
                    sentAt = relayWebProbeRecords.now(),
                ),
            )
            try {
                runRelayWebProbe(provider.id, modelID)
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (_: Exception) {
                // Automatic probing is a background supplement: a read / write-back failure loses only this one, and the next one runs as usual.
            }
        }
    }

    /** Recompute the automatic probe candidate of a model from the current configuration (still enabled and testable, first-send protocol, that protocol's fragment hash); null when it cannot be probed. */
    private suspend fun relayWebAutoCandidate(id: String, modelID: String): ai.oriveo.community.core.provider.relay.RelayWebProbeCandidate? {
        val latest = getById(accountId, id) ?: return null
        if (!ai.oriveo.community.core.provider.relay.RelayWebProbe.isProbeForm(latest)) return null
        val model = latest.models.firstOrNull { it.id == modelID } ?: return null
        if (!ai.oriveo.community.core.provider.relay.RelayCapabilityTest.isTestable(latest, model)) return null
        val transport = ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(latest, model).value
        val fragment = relayWebFragmentStore.effective(latest)[transport]?.takeIf { it.isNotEmpty() } ?: return null
        return ai.oriveo.community.core.provider.relay.RelayWebProbeCandidate(
            modelID,
            transport,
            ai.oriveo.community.core.provider.relay.RelayWebProbe.fragmentHash(fragment),
        )
    }

    /** A save changed the fragment of some protocol: remove the tested web from the enabled models whose first-send protocol is that one (user entries untouched). */
    private suspend fun clearRelayTestedWeb(normalizedId: String, changedTransports: Set<String>, targetAccountId: String) {
        if (changedTransports.isEmpty()) return
        repeat(RELAY_MODEL_WRITE_ATTEMPTS) {
            val entity = dao.getById(targetAccountId, normalizedId) ?: return
            val latest = normalizeProviderIds(entity.toDomainWithKeys(loadApiKey(targetAccountId, normalizedId)))
            if (!ai.oriveo.community.core.provider.relay.RelayWebProbe.isProbeForm(latest)) return
            val affected = latest.models.filter {
                ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.resolve(latest, it).value in changedTransports
            }.map { it.id }.toSet()
            val next = ai.oriveo.community.core.provider.relay.RelayWebProbe.clearingTestedWeb(latest, affected)
            if (next == latest) return
            guardedPersistExistingProvider(
                provider = next,
                expectedEntity = entity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = false,
            )?.let { write ->
                try {
                    dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
                } catch (error: kotlinx.coroutines.CancellationException) {
                    throw error
                } catch (_: Exception) {
                }
                return
            }
        }
    }

    /** "Restore automatic": clear only the override entries of that model whose source is tested (the enabled list and the catalog share the same id); user entries are untouched. */
    suspend fun restoreRelayCapabilityAutomatic(id: String, modelID: String): Provider? {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        repeat(RELAY_MODEL_WRITE_ATTEMPTS) {
            val entity = dao.getById(targetAccountId, normalizedId) ?: return null
            val latest = normalizeProviderIds(entity.toDomainWithKeys(loadApiKey(targetAccountId, normalizedId)))
            if (latest.kind != ProviderKind.Relay) return latest
            val next = ai.oriveo.community.core.provider.relay.RelayCapabilityTest.restoringAutomatic(latest, modelID)
            if (next == latest) return latest
            val write = guardedPersistExistingProvider(
                provider = next,
                expectedEntity = entity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = false,
            ) ?: return@repeat
            dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
            return write.provider
        }
        return getById(targetAccountId, normalizedId)
    }

    /**
     * Re-detect (the detail page's "Re-detect"): clear every model's reachable (protocol and source together),
     * clear this connection's negative caches (capability rejections + tool-call memory) and refresh the catalog; when the connection protocol is auto, after clearing, enabled models that still have no protocol
     * are re-probed one by one in enabling order, each by the standard candidate order; if the user chose the connection protocol, no probing is done.
     * user / observed / tested entries are untouched, no enabled model is deleted, and the connection protocol is not changed.
     */
    suspend fun redetectRelayModels(id: String): Provider? {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        clearRelayModelProbeStates(normalizedId)
        var cleared: Provider? = null
        repeat(RELAY_MODEL_WRITE_ATTEMPTS) {
            if (cleared != null) return@repeat
            val entity = dao.getById(targetAccountId, normalizedId) ?: return null
            val provider = normalizeProviderIds(entity.toDomainWithKeys(loadApiKey(targetAccountId, normalizedId)))
            if (provider.kind != ProviderKind.Relay) return provider
            fun List<AIModel>.withoutReachable() = map { model ->
                if (model.relayTransportSource == ai.oriveo.community.core.model.RelayTransportSource.Reachable) {
                    model.copy(relayTransport = null, relayTransportSource = null)
                } else {
                    model
                }
            }
            val next = provider.copy(
                models = provider.models.withoutReachable(),
                catalogModels = provider.catalogModels.withoutReachable(),
            )
            if (next == provider) {
                cleared = provider
                return@repeat
            }
            val write = guardedPersistExistingProvider(
                provider = next,
                expectedEntity = entity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = false,
            ) ?: return@repeat
            dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
            cleared = write.provider
        }
        if (cleared == null) return getById(targetAccountId, normalizedId)
        toolCallMemoryStore?.clearConnection(targetAccountId, normalizedId)
        relayNegativeCache.clearConnection(normalizedId)
        ai.oriveo.community.core.provider.ModelControlRejectionCache.removeConnection(normalizedId)

        refreshRelayCatalogOnly(normalizedId, expectedRevision = null, stampCheckedAt = true)
        refreshLocalEngineDeclarations(normalizedId, targetAccountId)
        val refreshed = getById(targetAccountId, normalizedId) ?: return null
        // The connection protocol was chosen by the user: models whose reachable was cleared follow the connection, with no re-probe.
        if (!acceptsRelayAutoProbe(refreshed)) return refreshed
        // A relay has no default model: after clearing reachable, re-probe in enabling order every enabled model whose protocol is empty;
        // those from user / observed sources still have a protocol and are not probed. Each model is probed on its own, and one failure does not block the ones after it.
        val pending = refreshed.models.filter { it.relayTransport == null }.map { it.id }
        for (modelID in pending) {
            val latest = getById(targetAccountId, normalizedId) ?: return null
            if (!acceptsRelayAutoProbe(latest)) break
            val model = latest.models.firstOrNull { it.id == modelID } ?: continue
            if (model.relayTransport != null) continue
            try {
                probeAndPinRelayModel(latest, modelID, targetAccountId)
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (_: Exception) {
                // If a single model's probe fails its protocol stays empty, left to the fallback chain at send time.
            }
        }
        return getById(targetAccountId, normalizedId)
    }

    /**
     * Re-detection of a local engine connection: call the connector to re-read the declarations and replace them by model id (a declaration is replaced only if given this time, otherwise the old one is kept).
     * relayCapabilityOverrides is untouched and no generation request is sent; if the connector fails, the old declarations are kept as a whole.
     */
    private suspend fun refreshLocalEngineDeclarations(id: String, targetAccountId: String) {
        val connector = localEngineConnector ?: return
        val provider = getById(targetAccountId, id) ?: return
        val requested = provider.relayRequested ?: return
        val engineProfile = requested.engineProfile?.takeIf(String::isNotBlank) ?: return
        val engine = ai.oriveo.community.core.provider.LocalEngineKind.entries
            .firstOrNull { it.wireName == engineProfile } ?: return
        val endpoint = provider.baseUrlText?.takeIf(String::isNotBlank) ?: return
        val declarations = try {
            connector.declarations(
                engine = engine,
                rawEndpoint = endpoint,
                securityMode = requested.securityMode,
                modelHint = RelayModelFallback.fallbackModel(provider, lastUsedModelRef())?.id,
                apiKey = ProviderCredentialResolver.apiKey(provider, null),
                certificateFingerprint = requested.certificateFingerprint,
            )
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (_: Exception) {
            return
        }
        if (declarations.isEmpty()) return
        repeat(RELAY_MODEL_WRITE_ATTEMPTS) {
            val entity = dao.getById(targetAccountId, id) ?: return
            val current = normalizeProviderIds(entity.toDomainWithKeys(loadApiKey(targetAccountId, id)))
            // The connection switched engine while the declarations were being read: this batch does not belong to it.
            if (current.relayRequested?.engineProfile != engineProfile) return
            fun List<AIModel>.redeclared() = map { model ->
                declarations[model.id]?.let { model.copy(engineDeclaration = it) } ?: model
            }
            val next = current.copy(models = current.models.redeclared(), catalogModels = current.catalogModels.redeclared())
            if (next == current) return
            val write = guardedPersistExistingProvider(
                provider = next,
                expectedEntity = entity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = false,
            ) ?: return@repeat
            dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
            return
        }
    }

    /**
     * After a protocol-level fallback switched protocol and this send succeeded: write the new protocol onto the model as observed; user sources are left alone.
     * The same CAS write-back path as [promoteRelayModelToObserved]; if the effective protocol changed meanwhile, it is discarded.
     */
    suspend fun recordRelayProtocolFallback(id: String, modelID: String, sentTransport: RelayTransport, transport: RelayTransport) {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        repeat(RELAY_MODEL_WRITE_ATTEMPTS) {
            val entity = dao.getById(targetAccountId, normalizedId) ?: return
            val provider = normalizeProviderIds(entity.toDomainWithKeys(loadApiKey(targetAccountId, normalizedId)))
            if (provider.kind != ProviderKind.Relay) return
            val next = ai.oriveo.community.core.provider.relay.RelayProtocolFallback.applyingObserved(provider, modelID, sentTransport, transport)
            if (next == provider) return
            val write = guardedPersistExistingProvider(
                provider = next,
                expectedEntity = entity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = false,
            ) ?: return@repeat
            dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
            return
        }
    }

    /** Write back the key-access verdict of a request rejected before any output, through the same CAS path as the protocol-fallback write-back. */
    suspend fun recordRelayKeyAccess(
        id: String,
        modelID: String,
        keyID: String,
        signal: ai.oriveo.community.core.model.RelayKeyAccessSignal,
        sent: Provider,
    ) = updateRelayKeyAccess(id, sent, keyID) { provider ->
        ai.oriveo.community.core.provider.relay.RelayKeyAccess.applyingFailure(provider, modelID, keyID, signal, System.currentTimeMillis())
    }

    /** A send succeeded on the same key: clear the no-access marker and write that key back as ok. */
    suspend fun recordRelayKeyAccessSuccess(
        id: String,
        modelID: String,
        keyID: String,
        sent: Provider,
    ) = updateRelayKeyAccess(id, sent, keyID) { provider ->
        ai.oriveo.community.core.provider.relay.RelayKeyAccess.applyingSuccess(provider, modelID, keyID, System.currentTimeMillis())
    }

    /**
     * Send write-back: bound to the connection [sent] the send started with; if any of that key's [keyID] value, the address, the auth mode or the security mode
     * differs from the latest, it is discarded (the result of a send whose key value changed in flight does not belong to the current key).
     */
    private suspend fun updateRelayKeyAccess(id: String, sent: Provider, keyID: String, transform: (Provider) -> Provider) {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        repeat(RELAY_MODEL_WRITE_ATTEMPTS) {
            val entity = dao.getById(targetAccountId, normalizedId) ?: return
            val provider = normalizeProviderIds(entity.toDomainWithKeys(loadApiKey(targetAccountId, normalizedId)))
            if (provider.kind != ProviderKind.Relay) return
            if (!sameRelayKeyRequestIdentity(sent, provider, keyID)) return
            val next = transform(provider)
            if (next == provider) return
            val write = guardedPersistExistingProvider(
                provider = next,
                expectedEntity = entity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = false,
            ) ?: return@repeat
            dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
            return
        }
    }

    /**
     * After a real send was delivered, promote reachable to observed: written only if the model is still
     * reachable at that moment and its protocol still equals the one at send start; in every other case (following the connection, user, already changed) nothing is written.
     */
    suspend fun promoteRelayModelToObserved(id: String, modelID: String, sentTransport: RelayTransport) {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        repeat(RELAY_MODEL_WRITE_ATTEMPTS) {
            val entity = dao.getById(targetAccountId, normalizedId) ?: return
            val provider = normalizeProviderIds(entity.toDomainWithKeys(loadApiKey(targetAccountId, normalizedId)))
            if (provider.kind != ProviderKind.Relay) return
            fun List<AIModel>.promoted() = map { model ->
                if (
                    model.id == modelID &&
                    model.relayTransport == sentTransport &&
                    model.relayTransportSource == ai.oriveo.community.core.model.RelayTransportSource.Reachable
                ) {
                    model.copy(relayTransportSource = ai.oriveo.community.core.model.RelayTransportSource.Observed)
                } else {
                    model
                }
            }
            val next = provider.copy(models = provider.models.promoted(), catalogModels = provider.catalogModels.promoted())
            if (next == provider) return
            val write = guardedPersistExistingProvider(
                provider = next,
                expectedEntity = entity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = false,
            ) ?: return@repeat
            dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
            return
        }
    }

    /**
     * Whether the connection is unchanged during the probe: the address, the effective key of the probed model, the auth mode, the security mode and the connection default protocol must all be the same for the probe result to be written back.
     * resolvedAPIBaseURLs does not take part in the comparison (the write-back itself changes it); neither do the names and statuses in the key list.
     */
    private fun sameRelayProbeConnection(probed: Provider, latest: Provider, modelID: String): Boolean =
        latest.baseUrlText?.trim() == probed.baseUrlText?.trim() &&
            ProviderCredentialResolver.apiKey(latest, modelID) == ProviderCredentialResolver.apiKey(probed, modelID) &&
            latest.authMode == probed.authMode &&
            latest.relayRequested?.authMode == probed.relayRequested?.authMode &&
            latest.relayRequested?.securityMode == probed.relayRequested?.securityMode &&
            ai.oriveo.community.core.provider.RelayEndpointResolver.effectiveTransport(latest.relayRequested, null) ==
            ai.oriveo.community.core.provider.RelayEndpointResolver.effectiveTransport(probed.relayRequested, null)

    /** The value of the key [keyID] the request was sent with, and the connection address / auth mode / security mode, are all unchanged. */
    private fun sameRelayKeyRequestIdentity(sent: Provider, latest: Provider, keyID: String): Boolean =
        latest.baseUrlText?.trim() == sent.baseUrlText?.trim() &&
            ProviderCredentialResolver.keySecret(latest, keyID) == ProviderCredentialResolver.keySecret(sent, keyID) &&
            latest.authMode == sent.authMode &&
            latest.relayRequested?.authMode == sent.relayRequested?.authMode &&
            latest.relayRequested?.securityMode == sent.relayRequested?.securityMode

    /** Per-model probing applies only to the user's own remote relay: a local engine (non-empty engineProfile) is not probed. */
    // Model > Advanced page: writes land only on that model (the enabled list and the catalog share the same id), with a CAS the same as [restoreRelayCapabilityAutomatic].

    /** Choosing a protocol writes user; null (choosing Auto) clears the model-level protocol and source. */
    suspend fun setRelayModelTransport(id: String, modelID: String, transport: ai.oriveo.community.core.model.RelayTransport?): Provider? =
        updateRelayModel(id) {
            ai.oriveo.community.feature.providers.detail.RelayModelAdvancedEdits.settingTransport(it, modelID, transport)
        }

    /** On / Off writes user and clears the negative cache of the same kind (at the effective protocol); null deletes the key. */
    suspend fun setRelayCapabilityOverride(
        id: String,
        modelID: String,
        capability: ai.oriveo.community.feature.providers.detail.RelayAdvancedCapability,
        value: Boolean?,
    ): Provider? = updateRelayModel(id) {
        ai.oriveo.community.feature.providers.detail.RelayModelAdvancedEdits
            .settingCapabilityOverride(it, modelID, capability, value, relayNegativeCache)
    }

    /** Thinking tier override (already narrowed and normalized by the caller; pass null when it equals the automatic set). */
    suspend fun setRelayReasoningLevels(id: String, modelID: String, levels: List<String>?): Provider? =
        updateRelayModel(id) {
            ai.oriveo.community.feature.providers.detail.RelayModelAdvancedEdits.settingReasoningLevels(it, modelID, levels)
        }?.also { saved ->
            ai.oriveo.community.feature.providers.detail.RelayModelAdvancedEdits
                .clearingReasoningTierRecords(saved, modelID, relayNegativeCache)
        }

    /** Restore everything to automatic: clear all overrides and the user protocol, and leave the negative caches alone. */
    suspend fun restoreRelayModelAutomatic(id: String, modelID: String): Provider? =
        updateRelayModel(id) {
            ai.oriveo.community.feature.providers.detail.RelayModelAdvancedEdits.restoringAllAutomatic(it, modelID)
        }

    /**
     * After a protocol is chosen by hand, run the existing per-model 1-token probe once for that protocol: only returns the result and writes no field.
     * true passed / false failed / null undetermined (outside the probe scope, model not enabled, or the root cannot be resolved for that protocol).
     */
    suspend fun probeRelayModelTransportOnce(
        id: String,
        modelID: String,
        transport: ai.oriveo.community.core.model.RelayTransport,
    ): Boolean? {
        val provider = getById(accountId, normalizeUuid(id)) ?: return null
        if (!acceptsRelayModelProbe(provider)) return null
        provider.models.firstOrNull { it.id == modelID } ?: return null
        val requested = provider.relayRequested ?: RelayRequestedConfig()
        val outcome = ai.oriveo.community.core.provider.relay.RelayModelProbe.probe(provider, modelID, listOf(transport)) { candidate, _ ->
            pingRelayConnection(
                apiKey = ProviderCredentialResolver.apiKey(provider, modelID),
                baseUrl = provider.baseUrlText,
                modelID = modelID,
                relayRequested = requested,
                relayKind = provider.relayKind,
                modelTransport = candidate,
            )
        }
        recordRelayGenerationKeyStatus(provider, modelID, relayProbeKeyStatus(outcome), accountId)
        return when {
            outcome.pass != null -> true
            outcome.attempted.isEmpty() -> null
            else -> false
        }
    }

    private suspend fun updateRelayModel(id: String, transform: (Provider) -> Provider): Provider? {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        repeat(RELAY_MODEL_WRITE_ATTEMPTS) {
            val entity = dao.getById(targetAccountId, normalizedId) ?: return null
            val latest = normalizeProviderIds(entity.toDomainWithKeys(loadApiKey(targetAccountId, normalizedId)))
            if (latest.kind != ProviderKind.Relay) return latest
            val next = transform(latest)
            if (next == latest) return latest
            val write = guardedPersistExistingProvider(
                provider = next,
                expectedEntity = entity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = false,
            ) ?: return@repeat
            dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
            return write.provider
        }
        return getById(targetAccountId, normalizedId)
    }

    private fun acceptsRelayModelProbe(provider: Provider): Boolean =
        ai.oriveo.community.core.capability.truth.ProviderForm.of(provider) ==
            ai.oriveo.community.core.capability.truth.ProviderForm.Relay &&
            provider.relayRequested?.engineProfile.isNullOrBlank()

    /**
     * Probe for automatically choosing a protocol (lazy verification on enabling / re-detection): besides [acceptsRelayModelProbe], the connection protocol must also be Auto.
     * If the user chose the connection protocol, no protocol is hunted for a model that has none of its own; the single probe after choosing a model protocol by hand is not subject to this.
     */
    private fun acceptsRelayAutoProbe(provider: Provider): Boolean =
        acceptsRelayModelProbe(provider) &&
            !ai.oriveo.community.core.provider.relay.RelayProbeCandidates.connectionIsExplicit(provider.relayRequested)

    /**
     * Probe [modelID] by the standard candidate order and write back the first that passes (CAS: re-read the latest entity, write only if the model is still there, still has no protocol,
     * and the connection address and default protocol are unchanged). If no candidate passes, returns null and writes nothing.
     */
    private suspend fun probeAndPinRelayModel(
        provider: Provider,
        modelID: String,
        targetAccountId: String,
        onOutcome: (ai.oriveo.community.core.provider.relay.RelayModelProbeOutcome) -> Unit = {},
    ): Provider? {
        val requested = provider.relayRequested ?: RelayRequestedConfig()
        val catalogRoot = ai.oriveo.community.core.provider.relay.RelayCatalogEndpointTypes.catalogRoot(
            provider.relayRequested,
            provider.baseUrlText,
        )
        val candidates = ai.oriveo.community.core.provider.relay.RelayProbeCandidates.candidates(
            ai.oriveo.community.core.provider.relay.RelayCatalogEndpointTypes.lookup(catalogRoot, modelID),
            modelID,
            relayModelFamily,
        )
        val outcome = ai.oriveo.community.core.provider.relay.RelayModelProbe.probe(provider, modelID, candidates) { candidate, _ ->
            pingRelayConnection(
                apiKey = ProviderCredentialResolver.apiKey(provider, modelID),
                baseUrl = provider.baseUrlText,
                modelID = modelID,
                relayRequested = requested,
                relayKind = provider.relayKind,
                modelTransport = candidate,
            )
        }
        // Check the connection identity (including the effective key value) before handing over the result: if the value / address etc. changed in flight, this result is discarded as a whole and no "not connected" is recorded.
        // Once an upstream response has been obtained, the key status is key-level evidence and is unrelated to the lazy verification being cancelled; the identity check and write-back are not interrupted by cancellation.
        val sameConnection = withContext(kotlinx.coroutines.NonCancellable) {
            val current = dao.getById(targetAccountId, provider.id)
                ?.let { normalizeProviderIds(it.toDomainWithKeys(loadApiKey(targetAccountId, provider.id))) }
            val same = current != null && sameRelayProbeConnection(provider, current, modelID)
            if (same) recordRelayGenerationKeyStatus(provider, modelID, relayProbeKeyStatus(outcome), targetAccountId)
            same
        }
        if (!sameConnection) return null
        // The model-level "verifying / not connected" and the protocol pinning are still handled as cancellation as before.
        kotlinx.coroutines.currentCoroutineContext().ensureActive()
        onOutcome(outcome)
        val pass = outcome.pass ?: return null
        repeat(RELAY_MODEL_WRITE_ATTEMPTS) {
            val entity = dao.getById(targetAccountId, provider.id) ?: return null
            val latest = normalizeProviderIds(entity.toDomainWithKeys(loadApiKey(targetAccountId, provider.id)))
            val target = latest.models.firstOrNull { it.id == modelID } ?: return null
            if (target.relayTransport != null || !sameRelayProbeConnection(provider, latest, modelID)) return null
            val write = guardedPersistExistingProvider(
                provider = ai.oriveo.community.core.provider.relay.RelayModelProbe.applyingPass(latest, modelID, pass),
                expectedEntity = entity,
                targetAccountId = targetAccountId,
                commitGuard = { true },
                normalizeConversations = false,
            ) ?: return@repeat
            dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
            return write.provider
        }
        return null
    }

    /** The key status of one per-model probe: passed -> ok; none sent -> null; otherwise look at the last failure. */
    private fun relayProbeKeyStatus(
        outcome: ai.oriveo.community.core.provider.relay.RelayModelProbeOutcome,
    ): ai.oriveo.community.core.model.RelayKeyStatus? = when {
        outcome.pass != null -> ai.oriveo.community.core.model.RelayKeyStatus("ok")
        outcome.attempted.isEmpty() -> null
        else -> outcome.lastError?.let(ai.oriveo.community.core.provider.relay.RelayKeyAccess::generationStatusOf)
    }

    /**
     * Key-status write-back of generation requests (lazy verification / re-probe / capability test): written onto the effective key of [modelID] on the connection [requested] the request used;
     * re-read the latest connection, and if the identity (same as [sameRelayProbeConnection]) changed, discard; write only when state / httpStatus changed.
     * A failed write-back does not affect the request's own result.
     */
    private suspend fun recordRelayGenerationKeyStatus(
        requested: Provider,
        modelID: String,
        status: ai.oriveo.community.core.model.RelayKeyStatus?,
        targetAccountId: String,
    ) {
        status ?: return
        val keyID = ai.oriveo.community.core.provider.relay.RelayKeyBinding.effectiveKeyID(requested, modelID)
        val normalizedId = normalizeUuid(requested.id)
        try {
            repeat(RELAY_MODEL_WRITE_ATTEMPTS) {
                val entity = dao.getById(targetAccountId, normalizedId) ?: return
                val latest = normalizeProviderIds(entity.toDomainWithKeys(loadApiKey(targetAccountId, normalizedId)))
                if (latest.kind != ProviderKind.Relay || !sameRelayProbeConnection(requested, latest, modelID)) return
                val next = ai.oriveo.community.core.provider.relay.RelayKeyAccess.withKeyStatuses(
                    latest,
                    mapOf(keyID to status),
                    System.currentTimeMillis(),
                )
                if (next == latest) return
                val write = guardedPersistExistingProvider(
                    provider = next,
                    expectedEntity = entity,
                    targetAccountId = targetAccountId,
                    commitGuard = { true },
                    normalizeConversations = false,
                ) ?: return@repeat
                dispatchProviderSyncIfCurrent(write, targetAccountId) { true }
                return
            }
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (_: Exception) {
            // The next real request will write it again.
        }
    }

    private suspend fun relayGenerationVerificationModelID(provider: Provider): String =
        relayVerificationSampleID(provider).orEmpty()

    /** Relay verification sample: fallback model -> first catalog model -> null (null falls to the existing missing-model error). */
    private suspend fun relayVerificationSampleID(provider: Provider): String? =
        RelayModelFallback.verificationSampleModelID(provider, lastUsedModelRef())

    private suspend fun loadApiKey(expectedAccountId: String, providerId: String): String = withContext(Dispatchers.IO) {
        secureKeyStore.getApiKey(expectedAccountId, providerId).orEmpty()
    }

    /** Capture once at a request or UI boundary; callers must not substitute another identifier. */
    fun currentCapabilityPartitionId(): String = LOCAL_PARTITION_ID

    /** Reads a Provider for requests / probes: the primary key is supplied by the caller, and the values of the other keys of a multi-key relay are filled in from this row. */
    private fun ProviderEntity.toDomainWithKeys(apiKey: String): Provider =
        toDomain(apiKey) { keyID -> secureKeyStore.getRelayKeySecret(accountId, id, keyID) }

    /** The values of the non-primary keys are written back to SecureKeyStore together with the Provider; rows without a key list (including every existing single-key connection) are left alone. */
    private suspend fun persistRelayKeySecrets(provider: Provider, entity: ProviderEntity) {
        val keys = provider.relayKeys ?: return
        withContext(Dispatchers.IO) { secureKeyStore.saveRelayKeySecrets(entity.accountId, entity.id, keys) }
    }

    fun toolCallMemoryVerdict(provider: Provider, model: ai.oriveo.community.core.model.AIModel): Boolean? =
        toolCallMemoryStore?.lookup(currentCapabilityPartitionId(), provider, model)

    suspend fun capabilityEvidenceIdentity(provider: Provider, modelId: String): CapabilityEvidenceIdentity? =
        capabilityEvidenceIdentity(provider, modelId, currentCapabilityPartitionId())

    suspend fun capabilityEvidenceIdentity(
        provider: Provider,
        modelId: String,
        partitionId: String,
    ): CapabilityEvidenceIdentity? {
        if (provider.id.isBlank() || modelId.isBlank() || partitionId.isBlank()) return null
        // Capture model + revision from one immutable metadata publication before suspension.
        val currentEvidence = MetadataClient.instance.currentCapabilityEvidenceModel(modelId, provider.kind)

        val publicationRevision = if (provider.kind == ProviderKind.Relay) {
            MetadataClient.instance.currentMetadataRevision()
        } else {
            null
        }
        return withContext(Dispatchers.IO) {
            val epochs = secureKeyStore.capabilityEpochs(partitionId, provider.id)
            val metadataRevision = currentEvidence?.metadataRevision ?: publicationRevision
            CapabilityEvidenceIdentity(
                partitionId = partitionId,
                connectionInstanceId = provider.id,
                connectionGeneration = epochs.connectionGeneration,
                credentialEpoch = epochs.credentialEpoch,
                providerKind = provider.kind.rawValue,
                authMode = provider.authMode.rawValue,
                canonicalModelId = currentEvidence?.metadata?.canonicalModelId,
                metadataRevision = metadataRevision,
                generationRevision = currentEvidence?.generationRevision ?: metadataRevision,
            )
        }
    }

    private suspend fun saveApiKey(expectedAccountId: String, providerId: String, apiKey: String) {
        withContext(Dispatchers.IO) {
            secureKeyStore.saveApiKey(expectedAccountId, providerId, apiKey)
        }
    }

    private suspend fun deleteApiKey(expectedAccountId: String, providerId: String) {
        withContext(Dispatchers.IO) {
            secureKeyStore.deleteApiKey(expectedAccountId, providerId)
        }
    }

    private fun looksLikeLegacyAutoEnabledAll(
        provider: Provider,
        canonicalCatalogModels: List<ai.oriveo.community.core.model.AIModel>,
    ): Boolean {
        if (canonicalCatalogModels.isEmpty()) return false

        val resolvedEnabledIds = provider.models
            .mapNotNull { model ->
                ModelSelectionUtils.matchingModel(canonicalCatalogModels, model.id, provider.kind)?.id
            }
            .distinct()
        if (resolvedEnabledIds.isEmpty() || resolvedEnabledIds.size != provider.models.size) {
            return false
        }

        if (provider.kind != ProviderKind.Relay && provider.catalogModels.isNotEmpty()) {
            val resolvedLegacyCatalogIds = provider.catalogModels
                .mapNotNull { model ->
                    ModelSelectionUtils.matchingModel(canonicalCatalogModels, model.id, provider.kind)?.id
                }
                .distinct()
            if (
                resolvedLegacyCatalogIds.isNotEmpty() &&
                resolvedLegacyCatalogIds.size == provider.catalogModels.size &&
                resolvedEnabledIds == resolvedLegacyCatalogIds
            ) {
                return true
            }
        }

        return false
    }
}
