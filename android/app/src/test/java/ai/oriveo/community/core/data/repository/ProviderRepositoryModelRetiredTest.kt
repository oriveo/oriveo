package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.AnthropicService
import ai.oriveo.community.core.provider.DeepSeekService
import ai.oriveo.community.core.provider.FireworksService
import ai.oriveo.community.core.provider.GeminiService
import ai.oriveo.community.core.provider.GrokService
import ai.oriveo.community.core.provider.GroqService
import ai.oriveo.community.core.provider.MetadataTestFixtures
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
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * A conversation's modelID is only written when the user switches models: after a catalog refresh, a provider update or a manual model
 * entry, a conversation pointing at a model that is no longer listed (or is only an alias) is not rewritten; a retired or missing model
 * is shown by the conversation state instead. The repository constructor takes no ConversationDao, so not writing conversations is
 * guaranteed by the signature; these tests only lock that the provider is still persisted as usual.
 */
class ProviderRepositoryModelRetiredTest {

    private val dao = mockk<ProviderDao>()
    private val secureKeyStore = mockk<SecureKeyStore>()

    private lateinit var repository: ProviderRepository

    private val accountId = LOCAL_PARTITION_ID
    private val providerId = normalizeUuid("123e4567-e89b-12d3-a456-426614174301")
    private val upserts = mutableListOf<ProviderEntity>()

    @Before
    fun setUp() {
        coEvery { dao.getAll(any()) } returns emptyList()
        coEvery { secureKeyStore.getApiKey(any(), any()) } returns ""
        every { secureKeyStore.saveRelayKeySecrets(any(), any(), any()) } returns Unit
        every { secureKeyStore.beginCapabilityConnection(any(), any()) } returns SecureKeyStore.CapabilityEpochs("cg-test", "ce-test")
        every { secureKeyStore.advanceCapabilityConnection(any(), any()) } returns SecureKeyStore.CapabilityEpochs("cg-next", "ce-next")
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenRouter,
                defaultModelId = "openai/gpt-4o",
                resolveMap = mapOf(
                    "openai/gpt-4o" to "openai/gpt-4o",
                    "openai/gpt-4o-latest" to "openai/gpt-4o",
                    "anthropic/claude-sonnet-4" to "anthropic/claude-sonnet-4",
                ),
                models = listOf(
                    MetadataTestFixtures.ModelSpec(id = "openai/gpt-4o", canonicalModelId = "openai/gpt-4o"),
                    MetadataTestFixtures.ModelSpec(id = "anthropic/claude-sonnet-4", canonicalModelId = "anthropic/claude-sonnet-4"),
                ),
            ),
        )
        repository = ProviderRepository(
            dao = dao,
            secureKeyStore = secureKeyStore,
            openRouterService = mockk<OpenRouterService>(),
            openAIService = mockk<OpenAIService>(),
            deepSeekService = mockk<DeepSeekService>(),
            grokService = mockk<GrokService>(),
            anthropicService = mockk<AnthropicService>(),
            geminiService = mockk<GeminiService>(),
            groqService = mockk<GroqService>(),
            togetherService = mockk<TogetherService>(),
            fireworksService = mockk<FireworksService>(),
            miniMaxService = mockk<MiniMaxService>(),
            zhipuService = mockk<ZhipuService>(),
            qwenService = mockk<QwenService>(),
            moonshotService = mockk<MoonshotService>(),
            mistralService = mockk<MistralService>(),
            siliconFlowService = mockk<SiliconFlowService>(),
            relayService = mockk<RelayService>(),
            metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
            httpClient = HttpClient(MockEngine { respond("""{"data":[]}""", HttpStatusCode.OK) }),
            runInTransaction = { block -> block() },
        )
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }


    /** Minimal read/write with the same semantics as Room: the guard transaction reads back the entity just written. */
    private fun mockStatefulProviderDao(initial: ProviderEntity) {
        var persisted: ProviderEntity? = initial
        coEvery { dao.getById(any(), any()) } coAnswers {
            persisted?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
        }
        coEvery { dao.upsert(any()) } coAnswers {
            val entity = firstArg<ProviderEntity>()
            persisted = entity
            upserts += entity
        }
    }

    @Test
    fun `refreshProviderMetadata does not rewrite conversations pointing at retired or alias models`() = runTest {
        // Legacy full-catalog enablement with non-empty catalogModels: a refresh always rebuilds the list and persists it.
        val polluted = officialProvider(
            models = listOf(model("openai/gpt-4o", isDefault = true), model("anthropic/claude-sonnet-4")),
            catalogModels = listOf(model("openai/gpt-4o", isDefault = true), model("anthropic/claude-sonnet-4")),
        )
        coEvery { dao.getAll(accountId) } returns listOf(polluted.toEntity(accountId))
        mockStatefulProviderDao(polluted.toEntity(accountId))

        repository.refreshProviderMetadata()

        assertTrue("Precondition: the refresh persisted the provider", upserts.isNotEmpty())
    }

    @Test
    fun `updateProvider does not rewrite conversations pointing at retired or alias models`() = runTest {
        val existing = officialProvider(models = listOf(model("openai/gpt-4o", isDefault = true)))
        mockStatefulProviderDao(existing.toEntity(accountId))

        repository.updateProvider(
            existing.copy(models = listOf(model("anthropic/claude-sonnet-4", isDefault = true))),
        )

        assertTrue("Precondition: the provider was persisted", upserts.isNotEmpty())
    }

    @Test
    fun `saveManualModel does not rewrite conversations pointing at retired or alias models`() = runTest {
        val existing = officialProvider(models = listOf(model("openai/gpt-4o", isDefault = true)))
        mockStatefulProviderDao(existing.toEntity(accountId))

        repository.saveManualModel(providerID = providerId, modelID = "my-manual-model")

        assertTrue("Precondition: the provider was persisted", upserts.isNotEmpty())
    }

    private fun officialProvider(
        models: List<AIModel>,
        catalogModels: List<AIModel> = emptyList(),
    ): Provider = Provider(
        id = providerId,
        kind = ProviderKind.OpenRouter,
        status = ProviderConnectionState.Connected,
        models = models,
        catalogModels = catalogModels,
        apiKey = "",
        apiKeyPreview = "sk-***",
        baseUrlText = ProviderKind.OpenRouter.defaultBaseUrl,
    )

    private fun model(id: String, isDefault: Boolean = false): AIModel =
        AIModel(id = id, name = id, isAvailable = true, isDefault = isDefault)

}
