package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.DeepSeekService
import ai.oriveo.community.core.provider.FireworksService
import ai.oriveo.community.core.provider.GeminiService
import ai.oriveo.community.core.provider.GrokService
import ai.oriveo.community.core.provider.GroqService
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ManualRetainedPruner
import ai.oriveo.community.core.provider.MiniMaxService
import ai.oriveo.community.core.provider.MistralService
import ai.oriveo.community.core.provider.MoonshotService
import ai.oriveo.community.core.provider.OpenAIService
import ai.oriveo.community.core.provider.OpenRouterService
import ai.oriveo.community.core.provider.QwenService
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.SiliconFlowService
import ai.oriveo.community.core.provider.TogetherService
import ai.oriveo.community.core.provider.ZhipuService
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.core.util.normalizeUuid
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.coVerifyOrder
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.runs
import io.mockk.slot
import io.mockk.unmockkObject
import io.mockk.verify
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test


class ProviderRepositoryMetadataAuthoritativeTest {

    private val dao = mockk<ProviderDao>()
    private val conversationDao = mockk<ConversationDao>()
    private val secureKeyStore = mockk<SecureKeyStore>()
    private val openRouterService = mockk<OpenRouterService>()
    private val openAIService = mockk<OpenAIService>()
    private val deepSeekService = mockk<DeepSeekService>()
    private val grokService = mockk<GrokService>()
    private val anthropicService = mockk<AnthropicService>()
    private val geminiService = mockk<GeminiService>()
    private val groqService = mockk<GroqService>()
    private val togetherService = mockk<TogetherService>()
    private val fireworksService = mockk<FireworksService>()
    private val miniMaxService = mockk<MiniMaxService>()
    private val zhipuService = mockk<ZhipuService>()
    private val qwenService = mockk<QwenService>()
    private val moonshotService = mockk<MoonshotService>()
    private val mistralService = mockk<MistralService>()
    private val siliconFlowService = mockk<SiliconFlowService>()
    private val relayService = mockk<RelayService>()

    private lateinit var repository: ProviderRepository
    private lateinit var accountIdFlow: MutableStateFlow<String>
    private val accountId = LOCAL_PARTITION_ID

    @Before
    fun setUp() {
        accountIdFlow = MutableStateFlow(accountId)
        coEvery { dao.getAll(any()) } returns emptyList()
        coEvery { conversationDao.getAll(any()) } returns emptyList()
        coEvery { secureKeyStore.getApiKey(any(), any()) } returns ""
        coEvery { secureKeyStore.saveApiKey(any(), any(), any()) } returns Unit
        every { secureKeyStore.beginCapabilityConnection(any(), any()) } returns SecureKeyStore.CapabilityEpochs("cg-test", "ce-test")
        every { secureKeyStore.advanceCapabilityConnection(any(), any()) } returns SecureKeyStore.CapabilityEpochs("cg-next", "ce-next")
        coEvery { dao.upsert(any()) } returns Unit

        
        
        mockkObject(ai.oriveo.community.core.data.remote.MetadataClient)
        mockkObject(ai.oriveo.community.core.data.remote.MetadataClient.instance)
        coEvery { ai.oriveo.community.core.data.remote.MetadataClient.refresh() } returns Unit
        repository = ProviderRepository(
            dao = dao,
            conversationDao = conversationDao,
            secureKeyStore = secureKeyStore,
            openRouterService = openRouterService,
            openAIService = openAIService,
            deepSeekService = deepSeekService,
            grokService = grokService,
            anthropicService = anthropicService,
            geminiService = geminiService,
            groqService = groqService,
            togetherService = togetherService,
            fireworksService = fireworksService,
            miniMaxService = miniMaxService,
            zhipuService = zhipuService,
            qwenService = qwenService,
            moonshotService = moonshotService,
            mistralService = mistralService,
            siliconFlowService = siliconFlowService,
            relayService = relayService,
            metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
            
            httpClient = HttpClient(
                MockEngine { respond("""{"data":[]}""", HttpStatusCode.OK) }
            ),
        )
    }

    @After
    fun tearDown() {
        ManualRetainedPruner.flagOverrideForTesting = null
        unmockkObject(ai.oriveo.community.core.data.remote.MetadataClient.instance)
        unmockkObject(ai.oriveo.community.core.data.remote.MetadataClient)
        MetadataTestFixtures.clear()
    }

    

    @Test
    fun `registerProvider for official provider builds models from metadata not sync result`() = runTest {
        
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o"),
                ),
            ),
        )

        val upserted = slot<ProviderEntity>()
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        val result = repository.registerProvider(
            kind = ProviderKind.OpenAI,
            apiKey = "sk-test",
        )

        
        assertFalse(
            "official provider must not use service.syncProvider().models",
            result.models.any { it.id == "hacked-rogue-model" },
        )
        assertTrue(
            "official provider enabled models should come from metadata",
            result.models.any { it.id == "gpt-4o" },
        )
        
        assertTrue(
            "official provider catalogModels must persist as empty",
            result.catalogModels.isEmpty(),
        )
        val persisted = upserted.captured.toDomain()
        assertTrue(persisted.catalogModels.isEmpty())
        assertTrue(persisted.models.any { it.id == "gpt-4o" })
        coVerify(exactly = 0) {
            openAIService.syncProvider(apiKey = any(), preferredModelID = any(), baseUrl = any())
        }
    }

    @Test
    fun `register then resync produces identical enabled models for official provider`() = runTest {
        
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o")),
            ),
        )

        val first = repository.registerProvider(
            kind = ProviderKind.OpenAI,
            apiKey = "sk-test",
        )
        val firstEnabledIds = first.models.map { it.id }.toSet()

        
        
        val existingEntity = first.toEntity(accountId)
        coEvery { dao.getAll(accountId) } returns listOf(existingEntity)
        coEvery { secureKeyStore.getApiKey(any(), first.id) } returns "sk-test"
        coEvery { dao.getById(any(), first.id) } returns existingEntity

        
        val second = repository.registerProvider(kind = ProviderKind.OpenAI, apiKey = "sk-test")
        val secondEnabledIds = second.models.map { it.id }.toSet()

        assertEquals(normalizeUuid(first.id), second.id)
        assertEquals(firstEnabledIds, secondEnabledIds)
        coVerify(exactly = 0) {
            openAIService.syncProvider(apiKey = any(), preferredModelID = any(), baseUrl = any())
        }
    }

    @Test
    fun `registerProvider prunes manual retained entries when pruning flag enabled`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Qwen,
                defaultModelId = "qwen3.6-plus",
                resolveMap = mapOf("qwen3.6-plus" to "qwen3.6-plus"),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "qwen3.6-plus", canonicalModelId = "qwen3.6-plus"),
                ),
            ),
        )
        ManualRetainedPruner.flagOverrideForTesting = true

        val existingProvider = provider(
            id = "123e4567-e89b-12d3-a456-426614174010",
            kind = ProviderKind.Qwen,
            models = listOf(
                model("qwen-legacy-ghost", isDefault = true),
                model("qwen3.6-plus"),
            ),
        )
        coEvery { dao.getAll(accountId) } returns listOf(existingProvider.toEntity(accountId))
        coEvery { secureKeyStore.getApiKey(any(), existingProvider.id) } returns "sk-qwen-old"
        val result = repository.registerProvider(
            kind = ProviderKind.Qwen,
            apiKey = "sk-qwen-new",
        )

        assertEquals(listOf("qwen3.6-plus"), result.models.map { it.id })
        assertEquals("qwen3.6-plus", result.defaultModel?.id)
        coVerify(exactly = 0) {
            qwenService.syncProvider(apiKey = any(), preferredModelID = any(), baseUrl = any())
        }
    }

    @Test
    fun `resync for official provider preserves existing enabled subset instead of auto enabling full metadata catalog`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenRouter,
                defaultModelId = "openai/gpt-4o",
                resolveMap = mapOf(
                    "openai/gpt-4o" to "openai/gpt-4o",
                    "anthropic/claude-sonnet-4" to "anthropic/claude-sonnet-4",
                    "qwen/qwen3-32b" to "qwen/qwen3-32b",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "openai/gpt-4o", canonicalModelId = "openai/gpt-4o"),
                    MetadataTestFixtures.ModelSpec(id = "anthropic/claude-sonnet-4", canonicalModelId = "anthropic/claude-sonnet-4"),
                    MetadataTestFixtures.ModelSpec(id = "qwen/qwen3-32b", canonicalModelId = "qwen/qwen3-32b"),
                ),
            ),
        )

        val existingProvider = provider(
            id = "123e4567-e89b-12d3-a456-426614174099",
            kind = ProviderKind.OpenRouter,
            models = listOf(model("openai/gpt-4o", isDefault = true)),
        )
        coEvery { dao.getById(any(), existingProvider.id) } returns existingProvider.toEntity(accountId)
        coEvery { secureKeyStore.getApiKey(any(), existingProvider.id) } returns "sk-or-test"
        val upserted = mutableListOf<ProviderEntity>()
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        repository.resyncProvider(existingProvider.id)

        val finalProvider = upserted.last().toDomain(apiKey = "sk-or-test")
        assertEquals(listOf("openai/gpt-4o"), finalProvider.models.map { it.id })
        assertEquals("openai/gpt-4o", finalProvider.defaultModel?.id)
        coVerify(exactly = 0) {
            openRouterService.syncProvider(apiKey = any(), preferredModelID = any(), baseUrl = any())
        }
    }

    @Test
    fun `resync for official provider repairs legacy full-catalog enabled state back to initial default`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenRouter,
                defaultModelId = "openai/gpt-4o",
                resolveMap = mapOf(
                    "openai/gpt-4o" to "openai/gpt-4o",
                    "anthropic/claude-sonnet-4" to "anthropic/claude-sonnet-4",
                    "qwen/qwen3-32b" to "qwen/qwen3-32b",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "openai/gpt-4o", canonicalModelId = "openai/gpt-4o"),
                    MetadataTestFixtures.ModelSpec(id = "anthropic/claude-sonnet-4", canonicalModelId = "anthropic/claude-sonnet-4"),
                    MetadataTestFixtures.ModelSpec(id = "qwen/qwen3-32b", canonicalModelId = "qwen/qwen3-32b"),
                ),
            ),
        )

        val pollutedProvider = provider(
            id = "123e4567-e89b-12d3-a456-426614174100",
            kind = ProviderKind.OpenRouter,
            models = listOf(
                model("openai/gpt-4o", isDefault = true),
                model("anthropic/claude-sonnet-4"),
                model("qwen/qwen3-32b"),
            ),
            catalogModels = listOf(
                model("openai/gpt-4o", isDefault = true),
                model("anthropic/claude-sonnet-4"),
                model("qwen/qwen3-32b"),
            ),
        )
        
        
        var persistedEntity = pollutedProvider.toEntity(accountId)
        coEvery { dao.getById(any(), pollutedProvider.id) } answers { persistedEntity }
        coEvery { secureKeyStore.getApiKey(any(), pollutedProvider.id) } returns "sk-or-test"
        val upserted = mutableListOf<ProviderEntity>()
        coEvery { dao.upsert(capture(upserted)) } answers {
            persistedEntity = upserted.last()
        }

        repository.resyncProvider(pollutedProvider.id)

        val finalProvider = upserted.last().toDomain(apiKey = "sk-or-test")
        assertEquals(listOf("openai/gpt-4o"), finalProvider.models.map { it.id })
        assertEquals("openai/gpt-4o", finalProvider.defaultModel?.id)
        coVerify(exactly = 0) {
            openRouterService.syncProvider(apiKey = any(), preferredModelID = any(), baseUrl = any())
        }
    }

    @Test
    fun `registerProvider repairs legacy full-catalog enabled state when reusing existing official provider`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenRouter,
                defaultModelId = "openai/gpt-4o",
                resolveMap = mapOf(
                    "openai/gpt-4o" to "openai/gpt-4o",
                    "anthropic/claude-sonnet-4" to "anthropic/claude-sonnet-4",
                    "qwen/qwen3-32b" to "qwen/qwen3-32b",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "openai/gpt-4o", canonicalModelId = "openai/gpt-4o"),
                    MetadataTestFixtures.ModelSpec(id = "anthropic/claude-sonnet-4", canonicalModelId = "anthropic/claude-sonnet-4"),
                    MetadataTestFixtures.ModelSpec(id = "qwen/qwen3-32b", canonicalModelId = "qwen/qwen3-32b"),
                ),
            ),
        )

        val pollutedProvider = provider(
            id = "123e4567-e89b-12d3-a456-426614174102",
            kind = ProviderKind.OpenRouter,
            models = listOf(
                model("openai/gpt-4o", isDefault = true),
                model("anthropic/claude-sonnet-4"),
                model("qwen/qwen3-32b"),
            ),
            catalogModels = listOf(
                model("openai/gpt-4o", isDefault = true),
                model("anthropic/claude-sonnet-4"),
                model("qwen/qwen3-32b"),
            ),
        )
        coEvery { dao.getAll(accountId) } returns listOf(pollutedProvider.toEntity(accountId))
        coEvery { secureKeyStore.getApiKey(any(), pollutedProvider.id) } returns "sk-old"
        coEvery { secureKeyStore.deleteApiKey(any(), pollutedProvider.id) } returns Unit
        val upserted = mutableListOf<ProviderEntity>()
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        val result = repository.registerProvider(
            kind = ProviderKind.OpenRouter,
            apiKey = "sk-new",
        )

        assertEquals(listOf("openai/gpt-4o"), result.models.map { it.id })
        assertEquals("openai/gpt-4o", result.defaultModel?.id)
        assertTrue(result.catalogModels.isEmpty())

        val finalProvider = upserted.last().toDomain(apiKey = "sk-new")
        assertEquals(listOf("openai/gpt-4o"), finalProvider.models.map { it.id })
        assertTrue(finalProvider.catalogModels.isEmpty())
        coVerify(exactly = 0) {
            openRouterService.syncProvider(apiKey = any(), preferredModelID = any(), baseUrl = any())
        }
    }

    @Test
    fun `refreshProviderMetadata repairs legacy full-catalog enabled state on app re-entry`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenRouter,
                defaultModelId = "openai/gpt-4o",
                resolveMap = mapOf(
                    "openai/gpt-4o" to "openai/gpt-4o",
                    "anthropic/claude-sonnet-4" to "anthropic/claude-sonnet-4",
                    "qwen/qwen3-32b" to "qwen/qwen3-32b",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "openai/gpt-4o", canonicalModelId = "openai/gpt-4o"),
                    MetadataTestFixtures.ModelSpec(id = "anthropic/claude-sonnet-4", canonicalModelId = "anthropic/claude-sonnet-4"),
                    MetadataTestFixtures.ModelSpec(id = "qwen/qwen3-32b", canonicalModelId = "qwen/qwen3-32b"),
                ),
            ),
        )

        val pollutedProvider = provider(
            id = "123e4567-e89b-12d3-a456-426614174101",
            kind = ProviderKind.OpenRouter,
            models = listOf(
                model("openai/gpt-4o", isDefault = true),
                model("anthropic/claude-sonnet-4"),
                model("qwen/qwen3-32b"),
            ),
            catalogModels = listOf(
                model("openai/gpt-4o", isDefault = true),
                model("anthropic/claude-sonnet-4"),
                model("qwen/qwen3-32b"),
            ),
        )
        coEvery { dao.getAll(accountId) } returns listOf(pollutedProvider.toEntity(accountId))

        val upserted = mutableListOf<ProviderEntity>()
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        repository.refreshProviderMetadata()

        val finalProvider = upserted.last().toDomain()
        assertEquals(listOf("openai/gpt-4o"), finalProvider.models.map { it.id })
        assertEquals("openai/gpt-4o", finalProvider.defaultModel?.id)
        assertTrue(finalProvider.catalogModels.isEmpty())
    }

    @Test
    fun `refreshProviderMetadata preserves a full-catalog enabled state that has no legacy catalog signal`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenRouter,
                defaultModelId = "openai/gpt-4o",
                resolveMap = mapOf(
                    "openai/gpt-4o" to "openai/gpt-4o",
                    "anthropic/claude-sonnet-4" to "anthropic/claude-sonnet-4",
                    "qwen/qwen3-32b" to "qwen/qwen3-32b",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "openai/gpt-4o", canonicalModelId = "openai/gpt-4o"),
                    MetadataTestFixtures.ModelSpec(id = "anthropic/claude-sonnet-4", canonicalModelId = "anthropic/claude-sonnet-4"),
                    MetadataTestFixtures.ModelSpec(id = "qwen/qwen3-32b", canonicalModelId = "qwen/qwen3-32b"),
                ),
            ),
        )

        val recentProvider = provider(
            id = "123e4567-e89b-12d3-a456-426614174104",
            kind = ProviderKind.OpenRouter,
            models = listOf(
                model("openai/gpt-4o", isDefault = true),
                model("anthropic/claude-sonnet-4"),
                model("qwen/qwen3-32b"),
            ),
            updatedAt = 1_776_643_200_000L,
        )
        coEvery { dao.getAll(accountId) } returns listOf(recentProvider.toEntity(accountId))

        val upserted = mutableListOf<ProviderEntity>()
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        repository.refreshProviderMetadata()

        if (upserted.isNotEmpty()) {
            val finalProvider = upserted.last().toDomain()
            assertEquals(
                listOf("openai/gpt-4o", "anthropic/claude-sonnet-4", "qwen/qwen3-32b"),
                finalProvider.models.map { it.id },
            )
        }
    }

    @Test
    fun `refreshProviderMetadata prunes manual retained entries when pruning flag enabled`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o"),
                ),
            ),
        )
        ManualRetainedPruner.flagOverrideForTesting = true

        val providerWithManualRetained = provider(
            id = "123e4567-e89b-12d3-a456-426614174105",
            kind = ProviderKind.OpenAI,
            models = listOf(
                model("legacy-model", isDefault = true),
                model("gpt-4o"),
            ),
        )
        coEvery { dao.getAll(accountId) } returns listOf(providerWithManualRetained.toEntity(accountId))

        val upserted = mutableListOf<ProviderEntity>()
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        repository.refreshProviderMetadata()

        val finalProvider = upserted.last().toDomain()
        assertEquals(listOf("gpt-4o"), finalProvider.models.map { it.id })
        assertEquals("gpt-4o", finalProvider.defaultModel?.id)
    }

    @Test
    fun `alias resolves to canonical for old enabled model id`() = runTest {
        
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Qwen,
                defaultModelId = "qwen3.6-plus",
                resolveMap = mapOf(
                    "qwen3.6-plus" to "qwen3.6-plus",
                    "qwen3.6-plus-2026-04-02" to "qwen3.6-plus",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "qwen3.6-plus", canonicalModelId = "qwen3.6-plus"),
                ),
            ),
        )

        
        val oldProvider = provider(
            id = "123e4567-e89b-12d3-a456-426614174050",
            kind = ProviderKind.Qwen,
            models = listOf(model("qwen3.6-plus-2026-04-02", isDefault = true)),
        )
        coEvery { dao.getAll(accountId) } returns listOf(oldProvider.toEntity(accountId))
        coEvery { secureKeyStore.getApiKey(any(), oldProvider.id) } returns "sk-qwen"
        coEvery { secureKeyStore.deleteApiKey(any(), oldProvider.id) } returns Unit
        val result = repository.registerProvider(
            kind = ProviderKind.Qwen,
            apiKey = "sk-qwen",
        )

        
        assertTrue(
            "canonical model should be enabled after alias resolution",
            result.models.any { it.id == "qwen3.6-plus" || it.canonicalModelId == "qwen3.6-plus" },
        )
        coVerify(exactly = 0) {
            qwenService.syncProvider(apiKey = any(), preferredModelID = any(), baseUrl = any())
        }
    }

    @Test
    fun `relay register retains syncProvider models as catalog`() = runTest {
        
        coEvery {
            relayService.syncProvider(apiKey = any(), preferredModelID = any(), baseUrl = any())
        } returns ProviderSyncResult(
            models = listOf(
                model("custom-model-a", isDefault = true),
                model("custom-model-b"),
            ),
        )
        val upserted = slot<ProviderEntity>()
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        val result = repository.registerProvider(
            kind = ProviderKind.Relay,
            apiKey = "sk-relay",
            baseUrl = "https://relay.example.com/v1",
        )

        val persisted = upserted.captured.toDomain()
        assertTrue(
            "Relay must keep syncProvider models in catalogModels",
            persisted.catalogModels.any { it.id == "custom-model-a" },
        )
        assertTrue(persisted.catalogModels.any { it.id == "custom-model-b" })
        assertEquals(result.id, persisted.id)
    }

    @Test
    fun `updateApiKey for relay keeps new key and records issue when generation verification fails`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174099",
            kind = ProviderKind.Relay,
            models = listOf(model("manual-relay-model", isDefault = true)),
            catalogModels = listOf(model("manual-relay-model", isDefault = true)),
        ).copy(
            apiKey = "",
            apiKeyPreview = SecureKeyStore.maskApiKey("sk-old-relay"),
            baseUrlText = "https://relay.example.com/v1",
        )
        var storedEntity = provider.toEntity(accountId)
        var storedKey = "sk-old-relay"
        coEvery { dao.getById(any(), provider.id) } answers { storedEntity }
        coEvery { secureKeyStore.getApiKey(any(), provider.id) } answers { storedKey }
        coEvery { secureKeyStore.saveApiKey(any(), provider.id, "sk-new-relay") } answers { storedKey = "sk-new-relay" }
        coEvery {
            relayService.verifyGeneration(any(), any(), any(), any(), any())
        } throws IllegalStateException("https://relay.example/?key=secret must not persist")

        val upserted = mutableListOf<ProviderEntity>()
        coEvery { dao.upsert(capture(upserted)) } answers {
            storedEntity = upserted.last()
            Unit
        }

        val thrown = runCatching {
            repository.updateApiKey(provider.id, "sk-new-relay")
        }.exceptionOrNull()

        val newKeyWrites = upserted
            .map { it.toDomain() }
            .filter { it.apiKeyPreview == SecureKeyStore.maskApiKey("sk-new-relay") }
        assertTrue("Relay rotation must have an observable fail-closed first write", newKeyWrites.isNotEmpty())
        assertTrue("Relay rotation must invalidate the old catalog immediately", newKeyWrites.first().catalogModels.isEmpty())
        val persisted = newKeyWrites.last()
        assertEquals(SecureKeyStore.maskApiKey("sk-new-relay"), persisted.apiKeyPreview)
        assertTrue(persisted.status is ProviderConnectionState.Issue)
        assertNull(persisted.lastCheckedAt)
        assertTrue(newKeyWrites.first().status is ProviderConnectionState.Issue)
        assertNull(newKeyWrites.first().lastCheckedAt)
        assertFalse(
            "New key must never be persisted alongside stale Connected evidence",
            newKeyWrites.any { it.status == ProviderConnectionState.Connected },
        )
        assertFalse(persisted.status.toString().contains("secret"))
        assertNotNull("generation failure must reach the key sheet", thrown)
        coVerify(exactly = 1) { secureKeyStore.saveApiKey(any(), provider.id, "sk-new-relay") }
        coVerify(exactly = 0) { relayService.syncProvider(any(), any(), any(), any()) }
    }

    @Test
    fun `updateApiKey for official provider does not rewrite unchanged credential material`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174198",
            kind = ProviderKind.OpenAI,
            models = listOf(model("gpt-4o", isDefault = true)),
        ).copy(apiKey = "", apiKeyPreview = SecureKeyStore.maskApiKey("sk-same"))
        coEvery { dao.getById(accountId, provider.id) } returns provider.toEntity(accountId)
        coEvery { secureKeyStore.getApiKey(accountId, provider.id) } returns "sk-same"

        repository.updateApiKey(provider.id, "sk-same")

        coVerify(exactly = 0) { secureKeyStore.saveApiKey(accountId, provider.id, any()) }
        coVerify(exactly = 0) { secureKeyStore.deleteApiKey(accountId, provider.id) }
    }

    @Test
    fun `updateApiKey for official provider writes changed credential material once`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174199",
            kind = ProviderKind.OpenAI,
            models = listOf(model("gpt-4o", isDefault = true)),
        ).copy(apiKey = "", apiKeyPreview = SecureKeyStore.maskApiKey("sk-old"))
        coEvery { dao.getById(accountId, provider.id) } returns provider.toEntity(accountId)
        coEvery { secureKeyStore.getApiKey(accountId, provider.id) } returns "sk-old"

        repository.updateApiKey(provider.id, "sk-new")

        coVerify(exactly = 1) { secureKeyStore.saveApiKey(accountId, provider.id, "sk-new") }
        coVerify(exactly = 0) { secureKeyStore.deleteApiKey(accountId, provider.id) }
    }

    @Test
    fun `capability identity consumes wire kind and same-publication revisions`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174197",
            kind = ProviderKind.OpenRouter,
            models = listOf(model("alias-model", isDefault = true)),
        )
        every { secureKeyStore.capabilityEpochs(accountId, provider.id) } returns
            SecureKeyStore.CapabilityEpochs("cg-1", "ce-1")
        every {
            ai.oriveo.community.core.data.remote.MetadataClient.instance.currentCapabilityEvidenceModel(
                "alias-model",
                ProviderKind.OpenRouter,
            )
        } returns ai.oriveo.community.core.data.remote.MetadataClient.CurrentCapabilityEvidenceModel(
            metadata = ai.oriveo.community.core.data.remote.MetadataClient.ResolvedModelMetadata(
                canonicalModelId = "canonical-model",
            ),
            metadataRevision = "etag-7",
            generationRevision = "generation-9",
            declaredReasoningLevels = emptySet(),
            contentRevision = 11,
        )

        val identity = repository.capabilityEvidenceIdentity(provider, "alias-model", accountId)

        assertEquals("openRouter", identity?.providerKind)
        assertEquals("canonical-model", identity?.canonicalModelId)
        assertEquals("etag-7", identity?.metadataRevision)
        assertEquals("generation-9", identity?.generationRevision)
        assertEquals("cg-1", identity?.connectionGeneration)
        assertEquals("ce-1", identity?.credentialEpoch)
    }

    @Test
    fun `captured capability partition survives account switch before identity epoch read`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174196",
            kind = ProviderKind.OpenAI,
            models = listOf(model("gpt-4o", isDefault = true)),
        )
        val capturedPartition = repository.currentCapabilityPartitionId()
        accountIdFlow.value = "next-account"
        every { secureKeyStore.capabilityEpochs(capturedPartition, provider.id) } returns
            SecureKeyStore.CapabilityEpochs("cg-old-account", "ce-old-account")
        every {
            ai.oriveo.community.core.data.remote.MetadataClient.instance.currentCapabilityEvidenceModel(any(), any())
        } returns null

        val identity = repository.capabilityEvidenceIdentity(provider, "gpt-4o", capturedPartition)

        assertEquals(accountId, identity?.partitionId)
        assertEquals("cg-old-account", identity?.connectionGeneration)
        verify(exactly = 1) { secureKeyStore.capabilityEpochs(accountId, provider.id) }
        verify(exactly = 0) { secureKeyStore.capabilityEpochs("next-account", provider.id) }
    }

    @Test
    fun `updateApiKey for relay verifies before catalog sync then records connected`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174100",
            kind = ProviderKind.Relay,
            models = listOf(model("relay-model", isDefault = true)),
            catalogModels = listOf(model("relay-model", isDefault = true)),
        ).copy(apiKey = "", baseUrlText = "https://relay.example/v1")
        var storedEntity = provider.toEntity(accountId)
        coEvery { dao.getById(any(), provider.id) } answers { storedEntity }
        coEvery { secureKeyStore.getApiKey(any(), provider.id) } returns "sk-old"
        coEvery { secureKeyStore.saveApiKey(any(), provider.id, "sk-new") } returns Unit
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } returns Unit
        coEvery { relayService.syncProvider(any(), any(), any(), any()) } returns ProviderSyncResult(
            models = listOf(model("relay-model", isDefault = true)),
        )
        val upserted = mutableListOf<ProviderEntity>()
        coEvery { dao.upsert(capture(upserted)) } answers { storedEntity = upserted.last(); Unit }

        repository.updateApiKey(provider.id, "sk-new")

        assertEquals(ProviderConnectionState.Connected, upserted.last().toDomain().status)
        assertNull(upserted.last().toDomain().lastError)
        coVerifyOrder {
            relayService.verifyGeneration(any(), any(), any(), any(), any())
            relayService.syncProvider(any(), any(), any(), any())
        }
    }

    @Test
    fun `relay key rotation keeps generation connected when catalog refresh fails`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174104",
            kind = ProviderKind.Relay,
            models = listOf(model("relay-model", isDefault = true)),
            catalogModels = listOf(model("old-catalog")),
        ).copy(
            baseUrlText = "https://relay.example/v1",
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(
                authMode = RelayAuthMode.Bearer,
                modelID = "relay-model",
            ),
        )
        var storedEntity = provider.toEntity(accountId)
        var storedKey = "sk-old"
        coEvery { dao.getById(accountId, provider.id) } answers { storedEntity }
        coEvery { secureKeyStore.getApiKey(accountId, provider.id) } answers { storedKey }
        coEvery { secureKeyStore.saveApiKey(accountId, provider.id, "sk-new") } answers {
            storedKey = "sk-new"
        }
        coEvery { dao.upsert(any()) } answers { storedEntity = firstArg(); Unit }
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } returns Unit
        coEvery { relayService.syncProvider(any(), any(), any(), any()) } throws
            IllegalStateException("catalog unavailable secret-catalog-detail")

        repository.updateApiKey(provider.id, "sk-new")

        val persisted = storedEntity.toDomain(storedKey)
        assertEquals(ProviderConnectionState.Connected, persisted.status)
        assertEquals(ProviderRepository.RELAY_CATALOG_UNAVAILABLE_MESSAGE, persisted.lastError)
        assertTrue(persisted.catalogModels.isEmpty())
        assertFalse(storedEntity.toString().contains("secret-catalog-detail"))
    }

    @Test
    fun `relay key rotation rolls back the just written key when provider is deleted during key store await`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174106",
            kind = ProviderKind.Relay,
            models = listOf(model("relay-model", isDefault = true)),
        ).copy(
            baseUrlText = "https://relay.example/v1",
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(authMode = RelayAuthMode.Bearer, modelID = "relay-model"),
        )
        var storedEntity: ProviderEntity? = provider.toEntity(accountId)
        var storedKey = ""
        coEvery { dao.getById(accountId, provider.id) } answers { storedEntity }
        coEvery { secureKeyStore.getApiKey(accountId, provider.id) } answers { storedKey }
        coEvery { secureKeyStore.saveApiKey(accountId, provider.id, "sk-new") } answers {
            storedKey = "sk-new"
            storedEntity = null
        }
        coEvery { secureKeyStore.deleteApiKey(accountId, provider.id) } answers { storedKey = "" }

        val thrown = runCatching { repository.updateApiKey(provider.id, "sk-new") }.exceptionOrNull()

        assertNotNull(thrown)
        assertNull(storedEntity)
        assertEquals("", storedKey)
        coVerify(exactly = 0) { dao.upsert(any()) }
        coVerify(exactly = 0) { relayService.verifyGeneration(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `relay key rotation never restores the previous key after provider deletion during key store await`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174110",
            kind = ProviderKind.Relay,
            models = listOf(model("relay-model", isDefault = true)),
        ).copy(
            baseUrlText = "https://relay.example/v1",
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(authMode = RelayAuthMode.Bearer, modelID = "relay-model"),
        )
        var storedEntity: ProviderEntity? = provider.toEntity(accountId)
        var storedKey = "sk-old"
        coEvery { dao.getById(accountId, provider.id) } answers { storedEntity }
        coEvery { secureKeyStore.getApiKey(accountId, provider.id) } answers { storedKey }
        coEvery { secureKeyStore.saveApiKey(accountId, provider.id, "sk-new") } answers {
            storedKey = "sk-new"
            storedEntity = null
        }
        coEvery { secureKeyStore.deleteApiKey(accountId, provider.id) } answers { storedKey = "" }

        val thrown = runCatching { repository.updateApiKey(provider.id, "sk-new") }.exceptionOrNull()

        assertNotNull(thrown)
        assertNull(storedEntity)
        assertEquals("", storedKey)
        coVerify(exactly = 0) { secureKeyStore.saveApiKey(accountId, provider.id, "sk-old") }
        coVerify(exactly = 0) { dao.upsert(any()) }
        coVerify(exactly = 0) { relayService.verifyGeneration(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `relay key generation response cannot overwrite a concurrent connection edit`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174107",
            kind = ProviderKind.Relay,
            models = listOf(model("relay-model", isDefault = true)),
        ).copy(
            baseUrlText = "https://old.example/v1",
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(authMode = RelayAuthMode.Bearer, modelID = "relay-model"),
        )
        var storedEntity = provider.toEntity(accountId)
        var storedKey = "sk-old"
        coEvery { dao.getById(accountId, provider.id) } answers { storedEntity }
        coEvery { secureKeyStore.getApiKey(accountId, provider.id) } answers { storedKey }
        coEvery { secureKeyStore.saveApiKey(accountId, provider.id, "sk-new") } answers { storedKey = "sk-new" }
        coEvery { dao.upsert(any()) } answers { storedEntity = firstArg(); Unit }
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } answers {
            storedEntity = storedEntity.copy(
                baseUrlText = "https://concurrent.example/v1",
                updatedAt = storedEntity.updatedAt + 1,
            )
        }

        val thrown = runCatching { repository.updateApiKey(provider.id, "sk-new") }.exceptionOrNull()

        assertNotNull(thrown)
        assertEquals("https://concurrent.example/v1", storedEntity.baseUrlText)
        assertTrue(storedEntity.toDomain().status is ProviderConnectionState.Issue)
        coVerify(exactly = 0) { relayService.syncProvider(any(), any(), any(), any()) }
    }

    @Test
    fun `ordinary relay reverify response cannot overwrite a concurrent connection edit`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174108",
            kind = ProviderKind.Relay,
            models = listOf(model("relay-model", isDefault = true)),
        ).copy(
            baseUrlText = "https://old.example/v1",
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(authMode = RelayAuthMode.None, modelID = "relay-model"),
        )
        var storedEntity = provider.toEntity(accountId)
        coEvery { dao.getById(accountId, provider.id) } answers { storedEntity }
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } answers {
            storedEntity = storedEntity.copy(
                baseUrlText = "https://concurrent.example/v1",
                updatedAt = storedEntity.updatedAt + 1,
            )
        }

        val result = repository.reverifyRelayProvider(provider.id)

        assertEquals("https://concurrent.example/v1", storedEntity.baseUrlText)
        assertEquals("https://concurrent.example/v1", result?.baseUrlText)
        coVerify(exactly = 0) { dao.upsert(any()) }
    }

    @Test
    fun `persisted relay test response cannot overwrite a concurrent endpoint and key edit`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174111",
            kind = ProviderKind.Relay,
            models = listOf(model("relay-model", isDefault = true)),
        ).copy(
            baseUrlText = "https://old.example/v1",
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(authMode = RelayAuthMode.Bearer, modelID = "relay-model"),
        )
        var storedEntity = provider.toEntity(accountId)
        var storedKey = "sk-old"
        coEvery { dao.getById(accountId, provider.id) } answers { storedEntity }
        coEvery { secureKeyStore.getApiKey(accountId, provider.id) } answers { storedKey }
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } answers {
            storedKey = "sk-new"
            storedEntity = storedEntity.copy(
                baseUrlText = "https://concurrent.example/v1",
                updatedAt = storedEntity.updatedAt + 1,
            )
        }

        val outcome = repository.verifyPersistedRelayGeneration(provider.id)

        assertTrue(outcome.verificationSucceeded)
        assertTrue(outcome.stale)
        assertEquals("https://old.example/v1", outcome.attemptedProvider?.baseUrlText)
        assertEquals("https://concurrent.example/v1", outcome.provider?.baseUrlText)
        assertEquals("sk-new", storedKey)
        coVerify(exactly = 0) { dao.upsert(any()) }
        coVerify(exactly = 0) { relayService.syncProvider(any(), any(), any(), any()) }
    }

    @Test
    fun `revision stale catalog refresh sends zero network requests`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174112",
            kind = ProviderKind.Relay,
            models = listOf(model("relay-model", isDefault = true)),
        ).copy(
            baseUrlText = "https://old.example/v1",
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(authMode = RelayAuthMode.None, modelID = "relay-model"),
        )
        var storedEntity = provider.toEntity(accountId)
        val revision = ProviderRepository.RelayEditRevision(storedEntity)
        storedEntity = storedEntity.copy(
            baseUrlText = "https://new.example/v1",
            updatedAt = storedEntity.updatedAt + 1,
        )
        coEvery { dao.getById(accountId, provider.id) } answers { storedEntity }

        val outcome = repository.refreshRelayCatalogOnly(provider.id, revision)

        assertTrue(outcome.stale)
        coVerify(exactly = 0) { relayService.syncProvider(any(), any(), any(), any()) }
    }

    @Test
    fun `removing relay key sends no generation or catalog request`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174101",
            kind = ProviderKind.Relay,
            models = listOf(model("relay-model", isDefault = true)),
        ).copy(apiKey = "", baseUrlText = "https://relay.example/v1")
        var storedEntity = provider.toEntity(accountId)
        coEvery { dao.getById(any(), provider.id) } answers { storedEntity }
        coEvery { secureKeyStore.getApiKey(any(), provider.id) } returns "sk-old"
        coEvery { secureKeyStore.deleteApiKey(any(), provider.id) } returns Unit
        coEvery { dao.upsert(any()) } answers { storedEntity = firstArg(); Unit }

        repository.updateApiKey(provider.id, "")

        coVerify(exactly = 0) { relayService.verifyGeneration(any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { relayService.syncProvider(any(), any(), any(), any()) }
        assertTrue(storedEntity.toDomain().status is ProviderConnectionState.Issue)
    }

    @Test
    fun `relay edit downgrade is rejected after the persisted entity changes`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174102",
            kind = ProviderKind.Relay,
            models = listOf(model("relay-model", isDefault = true)),
            updatedAt = 100,
        ).copy(
            baseUrlText = "https://relay.example/v1",
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(
                authMode = RelayAuthMode.None,
                modelID = "relay-model",
            ),
        )
        var storedEntity = provider.toEntity(accountId)
        coEvery { dao.getById(accountId, provider.id) } answers { storedEntity }
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } throws
            ProviderServiceError.RelayUpstream(401, "unauthorized", "secret-should-not-persist")

        val candidate = provider.copy(customName = "Draft")
        val failed = repository.verifyAndPersistRelayEdit(
            candidate = candidate,
            refreshCatalog = false,
            commitGuard = { true },
        )
        assertFalse(failed.persisted)
        val revision = requireNotNull(failed.failureRevision)

        
        storedEntity = storedEntity.copy(customName = "Concurrent", updatedAt = 101)
        val downgraded = repository.persistRelayEditUnverified(
            candidate = candidate,
            failureRevision = revision,
            commitGuard = { true },
        )

        assertTrue(downgraded.stale)
        coVerify(exactly = 0) { dao.upsert(match { it.customName == "Draft" }) }
        assertEquals("Concurrent", storedEntity.customName)
    }

    @Test
    fun `relay edit persists before catalog and catalog failure survives as canonical soft state`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174103",
            kind = ProviderKind.Relay,
            models = listOf(model("relay-model", isDefault = true)),
            catalogModels = listOf(model("old-catalog", isDefault = true)),
        ).copy(
            baseUrlText = "https://relay.example/v1",
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(
                authMode = RelayAuthMode.None,
                modelID = "relay-model",
            ),
        )
        var storedEntity = provider.toEntity(accountId)
        coEvery { dao.getById(accountId, provider.id) } answers { storedEntity }
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } returns Unit
        coEvery { relayService.syncProvider(any(), any(), any(), any()) } throws
            IllegalStateException("https://relay.example/?key=secret-should-not-persist")
        coEvery { dao.upsert(any()) } answers { storedEntity = firstArg(); Unit }

        val outcome = repository.verifyAndPersistRelayEdit(
            candidate = provider.copy(customName = "Verified edit", catalogModels = emptyList()),
            refreshCatalog = true,
            commitGuard = { true },
        )

        assertTrue(outcome.persisted)
        assertEquals(ProviderConnectionState.Connected, storedEntity.toDomain().status)
        assertNull(storedEntity.toDomain().lastError)
        assertTrue(storedEntity.toDomain().catalogModels.isEmpty())
        coVerify(exactly = 0) { relayService.syncProvider(any(), any(), any(), any()) }

        val catalogOutcome = repository.refreshRelayCatalogOnly(
            provider.id,
            requireNotNull(outcome.persistedRevision),
        )
        val persisted = storedEntity.toDomain()
        assertFalse(catalogOutcome.catalogSucceeded)
        assertEquals(ProviderRepository.RELAY_CATALOG_UNAVAILABLE_MESSAGE, persisted.lastError)
        assertFalse(storedEntity.toString().contains("secret-should-not-persist"))
    }

    @Test
    fun `unverified relay edit clears stale catalog then catalog retry preserves issue`() = runTest {
        val provider = provider(
            id = "123e4567-e89b-12d3-a456-426614174105",
            kind = ProviderKind.Relay,
            models = listOf(model("relay-model", isDefault = true)),
            catalogModels = listOf(model("stale-catalog")),
        ).copy(
            baseUrlText = "https://relay.example/v1",
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(authMode = RelayAuthMode.None, modelID = "relay-model"),
        )
        var storedEntity = provider.toEntity(accountId)
        coEvery { dao.getById(accountId, provider.id) } answers { storedEntity }
        coEvery { dao.upsert(any()) } answers { storedEntity = firstArg(); Unit }
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } throws
            ProviderServiceError.RelayUpstream(503, "unavailable", "secret-upstream-detail")

        val candidate = provider.copy(catalogModels = emptyList(), customName = "Draft")
        val failed = repository.verifyAndPersistRelayEdit(
            candidate = candidate,
            refreshCatalog = true,
            commitGuard = { true },
        )
        val persisted = repository.persistRelayEditUnverified(
            candidate = candidate,
            failureRevision = requireNotNull(failed.failureRevision),
            commitGuard = { true },
        )
        assertTrue(persisted.persisted)
        assertTrue(storedEntity.toDomain().catalogModels.isEmpty())
        assertTrue(storedEntity.toDomain().status is ProviderConnectionState.Issue)
        assertFalse(storedEntity.toString().contains("secret-upstream-detail"))

        coEvery { relayService.syncProvider(any(), any(), any(), any()) } throws
            IllegalStateException("catalog still unavailable")
        repository.refreshRelayCatalogOnly(
            provider.id,
            requireNotNull(persisted.persistedRevision),
        )

        val afterRetry = storedEntity.toDomain()
        assertTrue(afterRetry.status is ProviderConnectionState.Issue)
        assertEquals(ProviderRepository.RELAY_CATALOG_UNAVAILABLE_MESSAGE, afterRetry.lastError)
        assertTrue(afterRetry.catalogModels.isEmpty())
    }

    

    @Test
    fun `zhipu image gen model surfaces through metadata`() = runTest {
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.Zhipu,
                defaultModelId = "glm-4-plus",
                resolveMap = mapOf(
                    "glm-4-plus" to "glm-4-plus",
                    "cogview-4" to "cogview-4",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "glm-4-plus", canonicalModelId = "glm-4-plus"),
                    MetadataTestFixtures.ModelSpec(id = "cogview-4", canonicalModelId = "cogview-4"),
                ),
            ),
        )

        val result = repository.registerProvider(
            kind = ProviderKind.Zhipu,
            apiKey = "sk-zhipu",
        )

        
        assertTrue(result.models.any { it.id == "glm-4-plus" })
        assertTrue(result.catalogModels.isEmpty())

        
        val resolved = ai.oriveo.community.core.provider.ProviderCatalogResolver.resolve(result)
        assertTrue(
            "cogview-4 image gen model must be discoverable via metadata catalog",
            resolved.catalog.any { it.model.id == "cogview-4" },
        )
        coVerify(exactly = 0) {
            zhipuService.syncProvider(apiKey = any(), preferredModelID = any(), baseUrl = any())
        }
    }

    // ── Helpers ──

    private fun provider(
        id: String,
        kind: ProviderKind,
        models: List<AIModel>,
        catalogModels: List<AIModel> = emptyList(),
        updatedAt: Long = 0L,
    ): Provider = Provider(
        id = normalizeUuid(id),
        kind = kind,
        status = ProviderConnectionState.Connected,
        models = models,
        catalogModels = catalogModels,
        apiKey = "",
        apiKeyPreview = "sk-***",
        updatedAt = updatedAt,
    )

    private fun model(
        id: String,
        isDefault: Boolean = false,
        canonicalModelId: String? = null,
    ): AIModel = AIModel(
        id = id,
        name = id,
        isAvailable = true,
        isDefault = isDefault,
        canonicalModelId = canonicalModelId,
    )
}
