package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.model.ModelCapability
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
import ai.oriveo.community.core.model.RelayRequestedConfig
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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.mapLatest
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
) {

    private val accountId: String get() = LOCAL_PARTITION_ID

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

        const val PROVIDER_INVALID_KEY_MESSAGE =
            "The API key could not be validated. Check the value or generate a new key."
        const val PROVIDER_UNVERIFIED_MESSAGE =
            "We couldn't verify the connection. You can retry from the provider details."
        const val RELAY_UNVERIFIED_MESSAGE = "relay_connection_unverified"

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
        ) { entities, _ -> entities }.mapLatest { entities ->
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
                normalizeProviderIds(entity.toDomain(secureKeyStore.getApiKey(entity.accountId, entity.id).orEmpty()))
            }
        }.flowOn(Dispatchers.IO)
            .shareIn(externalScope, SharingStarted.WhileSubscribed(5_000L), replay = 1)
    }

    fun observeAll(): Flow<List<Provider>> = providersSharedFlow

    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeById(id: String): Flow<Provider?> =
        dao.observeById(accountId, normalizeUuid(id)).mapLatest { entity ->
            withContext(Dispatchers.IO) {
                entity?.takeIf { it.kind in ProviderKind.entries.map { kind -> kind.name } }?.let {
                    normalizeProviderIds(it.toDomain(loadApiKey(it.accountId, it.id)))
                }
            }
        }

    suspend fun getProviderByKind(kind: ProviderKind): Provider? {
        val entity = dao.getAll(accountId).firstOrNull { it.kind == kind.name } ?: return null
        val apiKey = loadApiKey(entity.accountId, entity.id)
        return normalizeProviderIds(entity.toDomain(apiKey))
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
        return normalizeProviderIds(entity.toDomain(apiKey))
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

            val regionId = kind.resolveRegionOption(baseUrl)?.id ?: ""
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

        val enrichedProvider = upsertProviderEntity(provider, targetAccountId)
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

    private fun relayDomainNameFromEndpoint(endpoint: String): String? {
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
    ): Provider {
        if (!commitGuard()) throw kotlinx.coroutines.CancellationException("stale relay registration")
        val targetAccountId = accountId
        val providerID = normalizeUuid(generateUuidString())
        secureKeyStore.beginCapabilityConnection(targetAccountId, providerID)

        val uniqueCatalogIDs = catalogModelIDs.map(String::trim).filter(String::isNotEmpty).distinct()
        val discoveredCatalog = uniqueCatalogIDs.map { modelID ->
            val runtime = runtimeMetadata[modelID]
            ai.oriveo.community.core.model.AIModel(
                id = modelID,
                name = modelID,
                capabilities = listOf(ModelCapability.Text),
                reasoningModeAvailable = false,
                isAvailable = true,
                isDefault = false,
                isManual = false,
                generationProfile = ai.oriveo.community.core.provider.LocalEngineGenerationProfiles.profile(relayRequested.engineProfile),
                localLoadState = runtime?.loadState,
                executionLocality = runtime?.executionLocality,
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
        )

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

        withContext(Dispatchers.IO) { MetadataClient.refresh() }

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
            ModelSelectionUtils.initialEnabledModels(canonicalCatalogModels)
        } else if (resolverEnabled.isNotEmpty() || manualModels.isNotEmpty()) {

            (resolverEnabled + manualModels).distinctBy { it.id }
        } else if (canonicalCatalogModels.isNotEmpty()) {

            ModelSelectionUtils.initialEnabledModels(canonicalCatalogModels)
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
            originalEntity.toDomain(loadApiKey(originalEntity.accountId, originalEntity.id)),
        )

        MetadataClient.refresh()
        val isRelay = provider.kind == ProviderKind.Relay
        var expectedEntity = originalEntity

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
                resyncRelay(provider, targetAccountId, expectedEntity, commitGuard)
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
            val failed = provider.copy(
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
            ModelSelectionUtils.initialEnabledModels(canonicalCatalogModels)
        } else if (metadataEnabled.isNotEmpty() || manualRetained.isNotEmpty()) {
            (metadataEnabled + manualRetained).distinctBy { it.id }
        } else if (canonicalCatalogModels.isNotEmpty()) {
            ModelSelectionUtils.initialEnabledModels(canonicalCatalogModels)
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
            apiKey = provider.apiKey,
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
    ): Provider? {
        val service = serviceFor(provider.kind)

        val syncResult = service.syncProvider(
            apiKey = provider.apiKey,
            preferredModelID = null,
            baseUrl = provider.baseUrlText,
            relayRequested = provider.relayRequested,
        )

        val mergedCatalog = ModelSelectionUtils.replaceRelayCatalog(
            existingModels = provider.catalogModels, syncedModels = syncResult.models, providerKind = provider.kind,
        )
        val enabledModels = ModelSelectionUtils.retainRelayEnabledModels(
            existingEnabledModels = provider.models, catalogModels = mergedCatalog, providerKind = provider.kind,
        )

        val updated = ModelSelectionUtils.synchronizeDefaultSelection(
            provider = provider.copy(
                status = ProviderConnectionState.Connected, models = enabledModels,
                catalogModels = mergedCatalog, lastCheckedAt = System.currentTimeMillis(), lastError = null,
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

    private suspend fun refreshRelayCatalogOnly(
        id: String,
        expectedRevision: ProviderEntity?,
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
            expectedEntity.toDomain(loadApiKey(targetAccountId, normalizedId)),
        )
        if (provider.kind != ProviderKind.Relay) {
            return ProviderResyncOutcome(provider, catalogSucceeded = false, stale = true)
        }
        return try {
            val syncResult = serviceFor(ProviderKind.Relay).syncProvider(
                apiKey = provider.apiKey,
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
                provider = provider.copy(
                    models = enabled,
                    catalogModels = catalog,
                    lastError = null,
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
            val updated = provider.copy(catalogModels = emptyList(), lastError = null)
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
            val failed = provider.copy(
                status = provider.status,
                lastError = RELAY_CATALOG_UNAVAILABLE_MESSAGE,
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

    suspend fun refreshProviderMetadata() {
        val targetAccountId = accountId
        val entities = withContext(Dispatchers.IO) { dao.getAll(targetAccountId) }
        if (entities.isEmpty()) return

        for (entity in entities) {
            val provider = entity.toDomain()
            if (provider.kind == ProviderKind.Relay) continue

            var updatedProvider = provider
            val resolvedCatalog = ProviderCatalogResolver.resolve(provider)
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
                    ModelSelectionUtils.initialEnabledModels(canonicalCatalogModels)
                } else if (metadataEnabled.isNotEmpty() || manualRetained.isNotEmpty()) {
                    (metadataEnabled + manualRetained).distinctBy { it.id }
                } else {
                    ModelSelectionUtils.initialEnabledModels(canonicalCatalogModels)
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
        val finalized = prepareProviderForUpsert(provider)
        val entity = finalized.toEntity(targetAccountId)
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
        val finalized = prepareProviderForUpsert(provider)
        val entity = finalized.toEntity(targetAccountId)
        return try {
            runInTransaction {
                if (!commitGuard()) throw StaleProviderMutation()
                if (dao.getById(targetAccountId, entity.id) != null) throw StaleProviderMutation()
                dao.upsert(entity)
                normalizeConversationSelections(finalized, targetAccountId)
                if (!commitGuard()) throw StaleProviderMutation()
            }
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
        val existingProvider = normalizeProviderIds(expectedEntity.toDomain(previousApiKey))
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
    ): RelayEditOutcome {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(candidate.id)
        if (!commitGuard()) return RelayEditOutcome(null, false, false, stale = true)
        val expectedEntity = dao.getById(targetAccountId, normalizedId)
            ?: return RelayEditOutcome(null, false, false, stale = true)
        val previousApiKey = loadApiKey(targetAccountId, normalizedId)
        val current = normalizeProviderIds(expectedEntity.toDomain(previousApiKey))
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

        val modelID = normalizedCandidate.defaultModel?.id
            ?: requested.modelID
            ?: normalizedCandidate.models.firstOrNull()?.id
            ?: normalizedCandidate.catalogModels.firstOrNull()?.id
        try {
            verifyRelayGeneration(
                apiKey = nextApiKey,
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
                failureRevision = RelayEditRevision(expectedEntity),
            )
        }
        if (!commitGuard()) return RelayEditOutcome(null, false, true, stale = true)

        val verified = ModelSelectionUtils.synchronizeDefaultSelection(
            provider = normalizedCandidate.copy(
                status = ProviderConnectionState.Connected,
                lastCheckedAt = System.currentTimeMillis(),
                lastError = null,
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
    ): RelayEditOutcome {
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
            provider = unverified,
            expectedEntity = expectedEntity,
            previousApiKey = previousApiKey,
            nextApiKey = nextApiKey,
            targetAccountId = targetAccountId,
            commitGuard = commitGuard,
        ) ?: return RelayEditOutcome(null, false, false, stale = true)
        dispatchProviderSyncIfCurrent(write, targetAccountId, commitGuard)
        return RelayEditOutcome(
            provider = write.provider,
            persisted = true,
            verificationSucceeded = false,
            error = null,
            persistedRevision = RelayEditRevision(write.entity),
        )
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
        val provider = normalizeProviderIds(entity.toDomain(key))
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
        val finalized = prepareProviderForUpsert(provider)
        val normalizedId = normalizeUuid(finalized.id)
        val targetAccountId = expectedAccountId
        dao.upsert(finalized.toEntity(targetAccountId))
        return finalized
    }

    suspend fun updateApiKey(id: String, newKey: String) {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val initialEntity = dao.getById(targetAccountId, normalizedId) ?: return
        val previousApiKey = loadApiKey(targetAccountId, normalizedId)
        val provider = normalizeProviderIds(initialEntity.toDomain(previousApiKey))

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

            val unverified = updated.copy(
                status = ProviderConnectionState.Issue(RELAY_UNVERIFIED_MESSAGE),
                lastCheckedAt = null,
                lastError = RELAY_UNVERIFIED_MESSAGE,
                catalogModels = emptyList(),
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

            if (newKey.isBlank()) return

            val modelID = provider.defaultModel?.id
                ?: provider.relayRequested?.modelID
                ?: provider.models.firstOrNull()?.id
                ?: provider.catalogModels.firstOrNull()?.id
            try {
                verifyRelayGeneration(
                    apiKey = newKey,
                    baseUrl = provider.baseUrlText,
                    modelID = modelID.orEmpty(),
                    relayRequested = provider.relayRequested ?: RelayRequestedConfig(),
                    relayKind = provider.relayKind,
                )

                val connected = unverifiedWrite.provider.copy(
                    status = ProviderConnectionState.Connected,
                    lastCheckedAt = System.currentTimeMillis(),
                    lastError = null,
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
                    expectedRevision = RelayEditRevision(connectedWrite.entity),
                )
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e

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

    suspend fun updateBaseUrl(id: String, newBaseUrl: String?) {
        val targetAccountId = accountId
        val normalizedId = normalizeUuid(id)
        val provider = getById(targetAccountId, normalizedId) ?: return
        val trimmedBaseUrl = newBaseUrl?.trim().takeUnless { it.isNullOrEmpty() }
        val updated = provider.copy(
            baseUrlText = if (provider.kind.usesConfigurableBaseUrl) {
                trimmedBaseUrl ?: provider.kind.defaultBaseUrl
            } else {
                provider.baseUrlText
            },
        )
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
        )
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
        val defaultModel = provider.defaultModel ?: return
        withContext(Dispatchers.IO) {
            val defaultStoredModelId = ModelSelectionUtils.preferredStoredModelIdentifier(defaultModel)
            val availableModelIds = provider.allModels.map { it.id }.toSet()
            val conversations = conversationDao.getAll(targetAccountId)

            val toUpdate = conversations
                .filter { sameNormalizedUuid(it.providerID, provider.id) }
                .mapNotNull { entity ->
                    val resolvedModelId = ModelSelectionUtils.matchingModel(
                        models = provider.allModels,
                        targetId = entity.modelID,
                    )?.let(ModelSelectionUtils::preferredStoredModelIdentifier)
                        ?: if (availableModelIds.contains(entity.modelID)) {
                            entity.modelID
                        } else {
                            defaultStoredModelId
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

    fun serviceFor(provider: Provider): ProviderService = when (provider.kind) {
        ProviderKind.Relay -> relayService
        else -> serviceFor(provider.kind)
    }

    suspend fun pingRelayConnection(
        apiKey: String,
        baseUrl: String?,
        modelID: String,
        relayRequested: RelayRequestedConfig,
        relayKind: RelayKind? = null,
    ) {
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
        val provider = normalizeProviderIds(expectedEntity.toDomain(expectedApiKey))
        if (provider.kind != ProviderKind.Relay) {
            return RelayGenerationVerificationOutcome(
                provider = provider,
                attemptedProvider = provider,
                verificationSucceeded = false,
                error = ProviderServiceError.InvalidConfiguration("Provider is not a Relay connection."),
            )
        }
        val modelID = relayGenerationVerificationModelID(provider)
        val error = try {
            verifyRelayGeneration(
                apiKey = expectedApiKey,
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
        if (loadApiKey(targetAccountId, normalizedId) != expectedApiKey) {
            return RelayGenerationVerificationOutcome(
                provider = getById(targetAccountId, normalizedId),
                attemptedProvider = provider,
                verificationSucceeded = verified,
                stale = true,
                error = error,
            )
        }
        val updated = provider.copy(
            status = if (verified) {
                ProviderConnectionState.Connected
            } else {
                ProviderConnectionState.Issue(RELAY_UNVERIFIED_MESSAGE)
            },

            lastCheckedAt = if (verified) System.currentTimeMillis() else provider.lastCheckedAt,
            lastError = if (verified) null else RELAY_UNVERIFIED_MESSAGE,
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

    private fun relayGenerationVerificationModelID(provider: Provider): String =
        provider.defaultModel?.id
            ?: provider.relayRequested?.modelID
            ?: provider.models.firstOrNull()?.id
            ?: provider.catalogModels.firstOrNull()?.id
            .orEmpty()

    private suspend fun loadApiKey(expectedAccountId: String, providerId: String): String = withContext(Dispatchers.IO) {
        secureKeyStore.getApiKey(expectedAccountId, providerId).orEmpty()
    }

    /** Capture once at a request or UI boundary; callers must not substitute another identifier. */
    fun currentCapabilityPartitionId(): String = LOCAL_PARTITION_ID

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
                ModelSelectionUtils.matchingModel(canonicalCatalogModels, model.id)?.id
            }
            .distinct()
        if (resolvedEnabledIds.isEmpty() || resolvedEnabledIds.size != provider.models.size) {
            return false
        }

        if (provider.kind != ProviderKind.Relay && provider.catalogModels.isNotEmpty()) {
            val resolvedLegacyCatalogIds = provider.catalogModels
                .mapNotNull { model ->
                    ModelSelectionUtils.matchingModel(canonicalCatalogModels, model.id)?.id
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
