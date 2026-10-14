package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
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
import ai.oriveo.community.core.provider.prepareProviderForUpsert
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.core.util.normalizeUuid
import io.ktor.client.HttpClient
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
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
import io.mockk.mockkStatic
import io.mockk.runs
import io.mockk.slot
import io.mockk.unmockkObject
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
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
        // Writing the key state for a single key materializes a list and persists non-primary key values as usual: with a one-entry list there is no value to store.
        every { secureKeyStore.saveRelayKeySecrets(any(), any(), any()) } returns Unit
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
        // Changing only the Key does not clear the catalog (the earlier "changing the Key immediately invalidates the catalog" rule was overturned).
        assertEquals(listOf("manual-relay-model"), newKeyWrites.first().catalogModels.map { it.id })
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
        // Changing the Key does not clear the catalog, and a failed catalog refresh does not empty the existing catalog either.
        assertEquals(listOf("old-catalog"), persisted.catalogModels.map { it.id })
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

    /**
     * Relay enrichment, catalog resolution and JSON encoding are pure O(catalog) work, and the
     * callers (RelaySetupViewModel / ProviderDetailViewModel) run on viewModelScope (Main). This
     * stage must leave the calling thread, or saving a relay with thousands of models, or
     * switching its model, stalls the main thread in proportion to the catalog size.
     */
    // ── RL2-PROBESTATE-09/10/11: when an edit-save collides with changes elsewhere, fields are merged per field ──

    /** The connection when the edit page was opened (baseline); the key used for probing is read by the repository from the live KeyStore. */
    private fun relayEditBaseline(id: String): Provider = provider(
        id = id,
        kind = ProviderKind.Relay,
        models = listOf(model("relay-model")),
    ).copy(
        customName = "My Relay",
        baseUrlText = "https://relay.example/v1",
        relayKind = RelayKind.Custom,
        lastCheckedAt = 111L,
        relayRequested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            authMode = RelayAuthMode.Bearer,
            headers = listOf(RelayKeyValue("X-Team", "a")),
        ),
    )

    private fun stubRelayEditStore(baseline: Provider): () -> ProviderEntity {
        var stored = baseline.toEntity(accountId)
        coEvery { dao.getById(accountId, baseline.id) } answers { stored }
        coEvery { dao.upsert(any()) } answers { stored = firstArg(); Unit }
        coEvery { secureKeyStore.getApiKey(any(), baseline.id) } returns "sk-live"
        every { secureKeyStore.advanceCapabilityConnectionGeneration(any(), any()) } returns
            SecureKeyStore.CapabilityEpochs("cg-next", "ce-next")
        storedRelayEditSetter = { stored = it }
        return { stored }
    }

    private var storedRelayEditSetter: (ProviderEntity) -> Unit = {}

    private fun syncWrite(current: ProviderEntity, change: (Provider) -> Provider) {
        storedRelayEditSetter(change(current.toDomain()).toEntity(accountId))
    }

    @Test
    fun `RL2-PROBESTATE-09 sync renaming and adding a model during verification merges and still writes the verified state`() = runTest {
        val baseline = relayEditBaseline("123e4567-e89b-12d3-a456-426614174201")
        val stored = stubRelayEditStore(baseline)
        var probes = 0
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } answers {
            probes += 1
            // Cloud sync changed the name and models (non-verification fields) while verification was in flight.
            syncWrite(stored()) { it.copy(customName = "Synced name", models = it.models + model("synced-model")) }
        }
        val edited = baseline.copy(baseUrlText = "https://relay-two.example/v1")

        val outcome = repository.verifyAndPersistRelayEdit(
            candidate = edited,
            refreshCatalog = false,
            commitGuard = { true },
            baseline = baseline,
        )

        assertFalse("not silently invalidated", outcome.stale)
        assertTrue(outcome.persisted)
        assertTrue(outcome.verificationSucceeded)
        assertEquals("only non-verification fields collided: no further probing", 1, probes)
        val persisted = stored().toDomain()
        assertEquals("address edited by the user", "https://relay-two.example/v1", persisted.baseUrlText)
        assertEquals("name changed by sync", "Synced name", persisted.customName)
        assertTrue("model added by sync", persisted.models.any { it.id == "synced-model" })
        assertEquals(ProviderConnectionState.Connected, persisted.status)
        assertTrue("this verification result is written", (persisted.lastCheckedAt ?: 0L) > 111L)
    }

    @Test
    fun `RL2-PROBESTATE-10 sync changing an untouched auth mode and header during verification re-probes the merged record`() = runTest {
        val baseline = relayEditBaseline("123e4567-e89b-12d3-a456-426614174202")
        val stored = stubRelayEditStore(baseline)
        val probed = mutableListOf<Pair<String?, RelayRequestedConfig>>()
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } answers {
            probed += secondArg<String?>() to arg<RelayRequestedConfig>(3)
            if (probed.size == 1) {
                syncWrite(stored()) {
                    it.copy(
                        relayRequested = it.relayRequested!!.copy(
                            authMode = RelayAuthMode.XApiKey,
                            headers = listOf(RelayKeyValue("X-Team", "b")),
                        ),
                    )
                }
            }
        }
        val edited = baseline.copy(baseUrlText = "https://relay-two.example/v1")

        val outcome = repository.verifyAndPersistRelayEdit(
            candidate = edited,
            refreshCatalog = false,
            commitGuard = { true },
            baseline = baseline,
        )

        assertEquals("the first verification is voided and the merged values are verified once more", 2, probed.size)
        val (secondUrl, secondRequested) = probed[1]
        assertEquals("https://relay-two.example/v1", secondUrl)
        assertEquals(RelayAuthMode.XApiKey, secondRequested.authMode)
        assertEquals(listOf(RelayKeyValue("X-Team", "b")), secondRequested.headers)
        assertTrue(outcome.persisted)
        assertTrue(outcome.verificationSucceeded)
        val persisted = stored().toDomain()
        assertEquals("https://relay-two.example/v1", persisted.baseUrlText)
        assertEquals(RelayAuthMode.XApiKey, persisted.relayRequested?.authMode)
        assertEquals(listOf(RelayKeyValue("X-Team", "b")), persisted.relayRequested?.headers)
        assertEquals(ProviderConnectionState.Connected, persisted.status)
    }

    @Test
    fun `RL2-PROBESTATE-10 a second collision persists the merged record without writing verification state`() = runTest {
        val baseline = relayEditBaseline("123e4567-e89b-12d3-a456-426614174203")
        val stored = stubRelayEditStore(baseline)
        var probes = 0
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } answers {
            probes += 1
            syncWrite(stored()) {
                it.copy(relayRequested = it.relayRequested!!.copy(headers = listOf(RelayKeyValue("X-Team", "v$probes"))))
            }
        }
        val edited = baseline.copy(baseUrlText = "https://relay-two.example/v1")

        val outcome = repository.verifyAndPersistRelayEdit(
            candidate = edited,
            refreshCatalog = false,
            commitGuard = { true },
            baseline = baseline,
        )

        assertEquals("verified at most once more", 2, probes)
        assertFalse(outcome.stale)
        assertTrue("persisted as merged", outcome.persisted)
        assertFalse("verification state is not written", outcome.verificationSucceeded)
        assertNull(outcome.error)
        val persisted = stored().toDomain()
        assertEquals("https://relay-two.example/v1", persisted.baseUrlText)
        assertEquals(listOf(RelayKeyValue("X-Team", "v2")), persisted.relayRequested?.headers)
        assertEquals("the live verification time is kept", 111L, persisted.lastCheckedAt)
    }

    @Test
    fun `RL2-PROBESTATE-11 a sync change landing between opening the page and saving keeps the synced value`() = runTest {
        val baseline = relayEditBaseline("123e4567-e89b-12d3-a456-426614174204")
        val stored = stubRelayEditStore(baseline)
        // After opening the page and before tapping save: sync changed the request headers and name the user did not edit.
        syncWrite(stored()) {
            it.copy(
                customName = "Synced name",
                relayRequested = it.relayRequested!!.copy(headers = listOf(RelayKeyValue("X-Team", "synced"))),
            )
        }
        val probedHeaders = mutableListOf<List<RelayKeyValue>?>()
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } answers {
            probedHeaders += arg<RelayRequestedConfig>(3).headers
        }
        val edited = baseline.copy(baseUrlText = "https://relay-two.example/v1")

        val outcome = repository.verifyAndPersistRelayEdit(
            candidate = edited,
            refreshCatalog = false,
            commitGuard = { true },
            baseline = baseline,
        )

        assertTrue(outcome.persisted)
        assertEquals("the probe is sent with the merged values", listOf(listOf(RelayKeyValue("X-Team", "synced"))), probedHeaders)
        val persisted = stored().toDomain()
        assertEquals("https://relay-two.example/v1", persisted.baseUrlText)
        assertEquals(listOf(RelayKeyValue("X-Team", "synced")), persisted.relayRequested?.headers)
        assertEquals("Synced name", persisted.customName)
    }

    @Test
    fun `RL2-PROBESTATE-11 zero network save merges the user's field onto the live record`() = runTest {
        val baseline = relayEditBaseline("123e4567-e89b-12d3-a456-426614174205")
        val stored = stubRelayEditStore(baseline)
        syncWrite(stored()) {
            it.copy(
                customName = "Synced name",
                relayRequested = it.relayRequested!!.copy(headers = listOf(RelayKeyValue("X-Team", "synced"))),
            )
        }
        val edited = baseline.copy(relayRequested = baseline.relayRequested!!.copy(customUserAgent = "Bot/2"))

        val outcome = repository.persistRelayEditWithoutVerification(
            candidate = edited,
            baseline = baseline,
            commitGuard = { true },
        )

        assertTrue(outcome.persisted)
        coVerify(exactly = 0) { relayService.verifyGeneration(any(), any(), any(), any(), any()) }
        val persisted = stored().toDomain()
        assertEquals("Bot/2", persisted.relayRequested?.customUserAgent)
        assertEquals(listOf(RelayKeyValue("X-Team", "synced")), persisted.relayRequested?.headers)
        assertEquals("Synced name", persisted.customName)
        assertEquals(ProviderConnectionState.Connected, persisted.status)
    }

    @Test
    fun `RL2-PROBESTATE-11 save anyway after a failed verification merges instead of going stale`() = runTest {
        val baseline = relayEditBaseline("123e4567-e89b-12d3-a456-426614174206")
        val stored = stubRelayEditStore(baseline)
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } throws
            ProviderServiceError.RelayUpstream(503, "unavailable", "upstream-detail")
        val edited = baseline.copy(baseUrlText = "https://relay-two.example/v1")
        val failed = repository.verifyAndPersistRelayEdit(
            candidate = edited,
            refreshCatalog = false,
            commitGuard = { true },
            baseline = baseline,
        )
        assertFalse(failed.persisted)
        // Sync changed the name while the failure card was shown.
        syncWrite(stored()) { it.copy(customName = "Synced name") }

        val outcome = repository.persistRelayEditUnverified(
            candidate = edited,
            failureRevision = requireNotNull(failed.failureRevision),
            commitGuard = { true },
            baseline = baseline,
        )

        assertFalse(outcome.stale)
        assertTrue(outcome.persisted)
        val persisted = stored().toDomain()
        assertEquals("https://relay-two.example/v1", persisted.baseUrlText)
        assertEquals("Synced name", persisted.customName)
        assertTrue(persisted.status is ProviderConnectionState.Issue)
    }

    @Test
    fun `RL2-PROBESTATE-12 a failed first probe re-verifies once when an unedited verification field changed meanwhile`() = runTest {
        val baseline = relayEditBaseline("123e4567-e89b-12d3-a456-426614174207")
        val stored = stubRelayEditStore(baseline)
        val probedAuth = mutableListOf<RelayAuthMode>()
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } answers {
            probedAuth += arg<RelayRequestedConfig>(3).authMode
            if (probedAuth.size == 1) {
                // During the first probe failure, sync changed the auth mode the user did not edit.
                syncWrite(stored()) { it.copy(relayRequested = it.relayRequested!!.copy(authMode = RelayAuthMode.XApiKey)) }
                throw ProviderServiceError.RelayUpstream(401, "unauthorized", "first-probe")
            }
        }
        val edited = baseline.copy(baseUrlText = "https://relay-two.example/v1")

        val outcome = repository.verifyAndPersistRelayEdit(
            candidate = edited,
            refreshCatalog = false,
            commitGuard = { true },
            baseline = baseline,
        )

        assertEquals("the first failure does not show the failure card directly: verify once more with the merged values", listOf(RelayAuthMode.Bearer, RelayAuthMode.XApiKey), probedAuth)
        assertTrue("the result follows the second attempt", outcome.persisted)
        assertTrue(outcome.verificationSucceeded)
        assertNull(outcome.error)
        val persisted = stored().toDomain()
        assertEquals(RelayAuthMode.XApiKey, persisted.relayRequested?.authMode)
        assertEquals("https://relay-two.example/v1", persisted.baseUrlText)
        assertEquals(ProviderConnectionState.Connected, persisted.status)
    }

    @Test
    fun `RL2-PROBESTATE-12 the second probe failing shows the failure and writes nothing`() = runTest {
        val baseline = relayEditBaseline("123e4567-e89b-12d3-a456-426614174208")
        val stored = stubRelayEditStore(baseline)
        var probes = 0
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } answers {
            probes += 1
            if (probes == 1) {
                syncWrite(stored()) { it.copy(relayRequested = it.relayRequested!!.copy(authMode = RelayAuthMode.XApiKey)) }
            }
            throw ProviderServiceError.RelayUpstream(401, "unauthorized", "probe-$probes")
        }
        val edited = baseline.copy(baseUrlText = "https://relay-two.example/v1")

        val outcome = repository.verifyAndPersistRelayEdit(
            candidate = edited,
            refreshCatalog = false,
            commitGuard = { true },
            baseline = baseline,
        )

        assertEquals(2, probes)
        assertFalse(outcome.persisted)
        assertNotNull(outcome.error)
        assertNotNull("after a failure \"Save anyway\" is still available", outcome.failureRevision)
        assertEquals("https://relay.example/v1", stored().toDomain().baseUrlText)
    }

    @Test
    fun `RL2-PROBESTATE-10 a second collision still clears the catalog when the connection changed at commit`() = runTest {
        val baseline = relayEditBaseline("123e4567-e89b-12d3-a456-426614174209")
            .copy(catalogModels = listOf(model("old-catalog")))
        val stored = stubRelayEditStore(baseline)
        var probes = 0
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } answers {
            probes += 1
            syncWrite(stored()) {
                it.copy(relayRequested = it.relayRequested!!.copy(headers = listOf(RelayKeyValue("X-Team", "v$probes"))))
            }
        }
        val edited = baseline.copy(baseUrlText = "https://relay-two.example/v1")

        val outcome = repository.verifyAndPersistRelayEdit(
            candidate = edited,
            refreshCatalog = true,
            commitGuard = { true },
            baseline = baseline,
        )

        assertTrue(outcome.persisted)
        assertFalse(outcome.verificationSucceeded)
        assertTrue("the address changed at persist time: clear the catalog and require a refresh", outcome.catalogInvalidated)
        assertTrue(stored().toDomain().catalogModels.isEmpty())
    }

    @Test
    fun `RL2-PROBESTATE-11 catalog is kept when the live record already carries the user's endpoint at commit`() = runTest {
        val baseline = relayEditBaseline("123e4567-e89b-12d3-a456-426614174210")
            .copy(catalogModels = listOf(model("old-catalog")))
        val stored = stubRelayEditStore(baseline)
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } answers {
            // During verification sync already changed the address to the same value the user entered: the connection identity did not change at persist time.
            syncWrite(stored()) { it.copy(baseUrlText = "https://relay-two.example/v1") }
        }
        val edited = baseline.copy(baseUrlText = "https://relay-two.example/v1")

        val outcome = repository.verifyAndPersistRelayEdit(
            candidate = edited,
            refreshCatalog = true,
            commitGuard = { true },
            baseline = baseline,
        )

        assertTrue(outcome.persisted)
        assertFalse("judged by merged-at-persist vs live: unchanged so the catalog is not cleared", outcome.catalogInvalidated)
        assertEquals(listOf("old-catalog"), stored().toDomain().catalogModels.map { it.id })
    }

    @Test
    fun `RL2-PROBESTATE-13 a failing second probe that collides again saves the merged record without verification state`() = runTest {
        val baseline = relayEditBaseline("123e4567-e89b-12d3-a456-426614174211")
        val stored = stubRelayEditStore(baseline)
        var probes = 0
        coEvery { relayService.verifyGeneration(any(), any(), any(), any(), any()) } answers {
            probes += 1
            // Sync changed the request headers the user did not edit during every probe; the second probe itself also fails.
            syncWrite(stored()) {
                it.copy(relayRequested = it.relayRequested!!.copy(headers = listOf(RelayKeyValue("X-Team", "v$probes"))))
            }
            if (probes == 2) throw ProviderServiceError.RelayUpstream(401, "unauthorized", "second-probe")
        }
        val edited = baseline.copy(baseUrlText = "https://relay-two.example/v1")

        val outcome = repository.verifyAndPersistRelayEdit(
            candidate = edited,
            refreshCatalog = false,
            commitGuard = { true },
            baseline = baseline,
        )

        assertEquals(2, probes)
        assertFalse(outcome.stale)
        assertTrue("collision takes precedence: persisted as merged", outcome.persisted)
        assertFalse(outcome.verificationSucceeded)
        assertNull("no failure card", outcome.error)
        val persisted = stored().toDomain()
        assertEquals("https://relay-two.example/v1", persisted.baseUrlText)
        assertEquals(listOf(RelayKeyValue("X-Team", "v2")), persisted.relayRequested?.headers)
        assertEquals("verification state is not written", 111L, persisted.lastCheckedAt)
        assertEquals(ProviderConnectionState.Connected, persisted.status)
    }


    @Test
    fun `relay writes finalize the catalog off the calling thread`() = runTest {
        val callerExecutor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "fake-main") }
        val caller = callerExecutor.asCoroutineDispatcher()
        val finalizeThreads = CopyOnWriteArrayList<String>()
        var persisted: ProviderEntity? = null
        coEvery { dao.getById(any(), any()) } coAnswers {
            persisted?.takeIf { entity ->
                entity.accountId == firstArg<String>() && entity.id == secondArg<String>()
            }
        }
        coEvery { dao.upsert(any()) } coAnswers { persisted = firstArg() }
        mockkStatic(PROVIDER_CATALOG_RESOLVER_KT)
        try {
            every { prepareProviderForUpsert(any(), any()) } answers {
                finalizeThreads += Thread.currentThread().name
                callOriginal()
            }
            val catalogIDs = (0 until 1_500).map { "vendor-${it % 7}/relay-model-$it" }

            withContext(caller) {
                val registered = repository.registerRelayProvider(
                    apiKey = "sk-large",
                    baseUrl = "https://relay.example.com/v1",
                    customName = "Large Relay",
                    relayKind = RelayKind.OpenAICompatible,
                    relayRequested = RelayRequestedConfig(
                        transport = RelayTransport.OpenAIChatCompletions,
                        resolvedAPIBaseURL = "https://relay.example.com/v1",
                    ),
                    catalogModelIDs = catalogIDs,
                    preferredModelID = catalogIDs.first(),
                )
                repository.updateProvider(registered.copy(models = registered.catalogModels))
            }

            assertTrue("precondition: both register and update must reach the pre-write finalize", finalizeThreads.size >= 2)
            assertTrue(
                "finalize ran on the calling thread: $finalizeThreads",
                finalizeThreads.none { it == "fake-main" },
            )
        } finally {
            unmockkStatic(PROVIDER_CATALOG_RESOLVER_KT)
            caller.close()
        }
    }

    /**
     * Selecting or enabling a model in the Home model picker goes through HomeViewModel's
     * viewModelScope (Main) into [ProviderRepository.getById]. Some public relays list tens of
     * thousands of models; if decoding the catalog JSON stays on the calling thread, its cost lands
     * on the main thread unchanged.
     *
     * Method: CPU time actually consumed by the calling thread (fake-main) during one getById
     * (ThreadMXBean), median of 5 runs after 2 warmups. Only the caller is measured: once decoding
     * moves elsewhere, all that is left there is the suspend/resume overhead.
     */
    @Test
    fun `getById decodes a large relay catalog off the calling thread`() = runTest {
        val catalog = (0 until 22_000).map { index ->
            AIModel(
                id = "org-${index % 3_000}/gemma-4-31B-it-variant-$index",
                name = "org-${index % 3_000}/gemma-4-31B-it-variant-$index",
                capabilities = listOf(ModelCapability.Text),
                contextLength = 32_768,
            )
        }
        val relay = provider(
            id = "6F1C7C52-5A8E-4A0E-9D7E-3B1F0A9C2E22",
            kind = ProviderKind.Relay,
            models = listOf(catalog.first().copy(isDefault = true)),
            catalogModels = catalog,
        ).copy(baseUrlText = "https://relay.example.com/v1")
        coEvery { dao.getById(accountId, relay.id) } returns relay.toEntity(accountId)
        coEvery { secureKeyStore.getApiKey(any(), relay.id) } returns "sk-relay"

        val callerExecutor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "fake-main") }
        val caller = callerExecutor.asCoroutineDispatcher()
        val threadMx = java.lang.management.ManagementFactory.getThreadMXBean()
        try {
            val samples = (1..7).map {
                withContext(caller) {
                    val cpuBefore = threadMx.currentThreadCpuTime
                    val loaded = repository.getById(relay.id)
                    val cpuMs = (threadMx.currentThreadCpuTime - cpuBefore) / 1_000_000.0
                    assertEquals("precondition: production decoding must yield the whole catalog", 22_000, loaded?.catalogModels?.size)
                    cpuMs
                }
            }.drop(2).sorted()
            val medianMs = samples[samples.size / 2]
            println("ProviderRepositoryMetadataAuthoritativeTest getById relay catalog=22000 callerCpuMedian=${"%.2f".format(medianMs)}ms samples=$samples")
            assertTrue(
                "getById used ${"%.2f".format(medianMs)}ms of CPU on the calling thread: catalog decoding still runs on the caller (Main on Home)",
                medianMs < 5.0,
            )
        } finally {
            caller.close()
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

/** The top-level file class holding prepareProviderForUpsert; mockkStatic intercepts through it. */
private const val PROVIDER_CATALOG_RESOLVER_KT = "ai.oriveo.community.core.provider.ProviderCatalogResolverKt"
