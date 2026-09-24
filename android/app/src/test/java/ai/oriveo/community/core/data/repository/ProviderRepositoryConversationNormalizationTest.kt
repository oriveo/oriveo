package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.prepareProviderForUpsert
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.core.util.normalizeUuid
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import io.mockk.coEvery
import io.mockk.mockk
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Conversation model normalization after a provider write, at relay catalog scale.
 *
 * Kept apart from the metadata-authoritative suite on purpose: that suite spies on MetadataClient for every test,
 * and a spy records every call, which at 22,000 models per write runs the test JVM out of heap. Nothing here needs
 * a spy.
 */
class ProviderRepositoryConversationNormalizationTest {

    private val dao = mockk<ProviderDao>()
    private val conversationDao = mockk<ConversationDao>()
    private val secureKeyStore = mockk<SecureKeyStore>()
    private val accountId = LOCAL_PARTITION_ID
    private lateinit var repository: ProviderRepository

    @Before
    fun setUp() {
        coEvery { dao.getAll(any()) } returns emptyList()
        coEvery { dao.upsert(any()) } returns Unit
        coEvery { secureKeyStore.getApiKey(any(), any()) } returns ""
        repository = ProviderRepository(
            dao = dao,
            conversationDao = conversationDao,
            secureKeyStore = secureKeyStore,
            openRouterService = mockk(),
            openAIService = mockk(),
            deepSeekService = mockk(),
            grokService = mockk(),
            anthropicService = mockk(),
            geminiService = mockk(),
            groqService = mockk(),
            togetherService = mockk(),
            fireworksService = mockk(),
            miniMaxService = mockk(),
            zhipuService = mockk(),
            qwenService = mockk(),
            moonshotService = mockk(),
            mistralService = mockk(),
            siliconFlowService = mockk(),
            relayService = mockk(),
            metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
            httpClient = HttpClient(MockEngine { respond("""{"data":[]}""", HttpStatusCode.OK) }),
        )
    }

    /**
     * Every provider write normalizes the conversations of that provider against the new catalog. Each
     * conversation used to read `provider.allModels` and scan the whole catalog with matchingModel, so with a
     * 22,000-model relay catalog the write cost grew with the number of conversations.
     *
     * Measures the process CPU time of the production `updateProvider` (finalize, normalize), on the same 22k
     * catalog with 15 vs 1,500 conversations, median of three after one warmup. Conversation model ids come from
     * the production [ProviderSelectionSnapshot.persistedSelection], and one in 100 points at a retired model
     * (forcing the fuzzy pass and the default fallback). The written results are compared one by one with the
     * per-conversation scan they replace.
     */
    @Test
    fun `updateProvider normalizes relay conversations without rescanning the catalog per conversation`() = runTest {
        val relayId = normalizeUuid("7A1C7C52-5A8E-4A0E-9D7E-3B1F0A9C2E33")
        val catalog = (0 until 22_000).map { index ->
            AIModel(
                id = "org-${index % 3_000}/gemma-4-31B-it-variant-$index",
                name = "org-${index % 3_000}/gemma-4-31B-it-variant-$index",
                capabilities = listOf(ModelCapability.Text),
                contextLength = 32_768,
            )
        }
        val enabled = catalog.filterIndexed { index, _ -> index % 14 == 0 }.take(1_500)
            .mapIndexed { index, model -> model.copy(isDefault = index == 0) }
        val relay = provider(
            id = relayId,
            kind = ProviderKind.Relay,
            models = enabled,
            catalogModels = catalog,
        ).copy(baseUrlText = "https://relay.example.test/v1")
        coEvery { dao.getById(accountId, relayId) } returns relay.toEntity(accountId)

        fun conversations(count: Int): List<ConversationEntity> = (0 until count).map { index ->
            val requested = if (index % 100 == 3) "org-9/retired-$index" else enabled[(index * 7) % enabled.size].id
            val stored = ProviderSelectionSnapshot.persistedSelection(relay, requested)?.storedModelId ?: requested
            ConversationEntity(
                id = "conversation-$index",
                title = "Conversation $index",
                hasCustomTitle = false,
                providerID = relayId,
                providerKind = ProviderKind.Relay.rawValue,
                modelID = stored,
                previewText = "",
                estimatedCost = 0.0,
                isDraft = false,
                draftText = "",
                createdAt = 0L,
                updatedAt = 0L,
                accountId = accountId,
            )
        }

        suspend fun medianUpdateMs(conversations: List<ConversationEntity>): Pair<Double, List<ConversationEntity>> {
            coEvery { conversationDao.getAll(accountId) } returns conversations
            val updates = CopyOnWriteArrayList<ConversationEntity>()
            coEvery { conversationDao.updateAll(any()) } coAnswers { updates += firstArg<List<ConversationEntity>>() }
            // Normalization runs on Dispatchers.IO, not the calling thread, so this measures process CPU time
            // (wall clock stretches when the machine is loaded).
            val os = java.lang.management.ManagementFactory.getOperatingSystemMXBean() as com.sun.management.OperatingSystemMXBean
            val samples = (1..4).map {
                updates.clear()
                val start = os.processCpuTime
                repository.updateProvider(relay)
                (os.processCpuTime - start) / 1_000_000.0
            }.drop(1).sorted()
            return samples[1] to updates.toList()
        }

        val (fewMs, _) = medianUpdateMs(conversations(15))
        val many = conversations(1_500)
        val (manyMs, manyUpdates) = medianUpdateMs(many)
        println(
            "ProviderRepository updateProvider relay catalog=22000 conversations 15=${"%.1f".format(fewMs)}ms " +
                "1500=${"%.1f".format(manyMs)}ms ratio=${"%.2f".format(manyMs / fewMs)}",
        )

        // Reference: the per-conversation matchingModel scan over allModels as it was (normalization sees the
        // finalized provider that was written).
        val persisted = prepareProviderForUpsert(relay)
        val defaultStored = ModelSelectionUtils.preferredStoredModelIdentifier(persisted.defaultModel!!)
        val availableIds = persisted.allModels.map { it.id }.toSet()
        val expected = many.mapNotNull { entity ->
            val resolved = ModelSelectionUtils.matchingModel(persisted.allModels, entity.modelID)
                ?.let(ModelSelectionUtils::preferredStoredModelIdentifier)
                ?: if (entity.modelID in availableIds) entity.modelID else defaultStored
            if (resolved != entity.modelID) entity.copy(modelID = resolved) else null
        }
        assertTrue("precondition: some conversations must be normalized (retired models fall back to the default)", expected.isNotEmpty())
        assertEquals(expected, manyUpdates)
        assertTrue(
            "15 -> 1500 conversations took ${"%.1f".format(fewMs)}ms -> ${"%.1f".format(manyMs)}ms: normalization still scans the catalog per conversation",
            manyMs / fewMs < 1.6,
        )
    }

    private fun provider(
        id: String,
        kind: ProviderKind,
        models: List<AIModel>,
        catalogModels: List<AIModel> = emptyList(),
    ): Provider = Provider(
        id = normalizeUuid(id),
        kind = kind,
        status = ProviderConnectionState.Connected,
        models = models,
        catalogModels = catalogModels,
        apiKey = "",
        apiKeyPreview = "sk-***",
    )
}
