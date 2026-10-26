package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.EntityMapper.toDomain
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderEffectiveStatusKind
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.ProviderSyncResult
import ai.oriveo.community.core.model.effectiveStatusKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
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
import ai.oriveo.community.core.provider.MiniMaxService
import ai.oriveo.community.core.provider.MistralService
import ai.oriveo.community.core.provider.MoonshotService
import ai.oriveo.community.core.provider.OpenAIService
import ai.oriveo.community.core.provider.OpenRouterService
import ai.oriveo.community.core.provider.QwenService
import ai.oriveo.community.core.provider.RelayErrorMapper
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
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.runs
import io.mockk.slot
import io.mockk.unmockkObject
import io.mockk.verify
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

// The repository constructor takes no ConversationDao, so not writing conversations is guaranteed by the signature.
class ProviderRepositoryTest {

    private val dao = mockk<ProviderDao>()
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

    private val accountId = LOCAL_PARTITION_ID

    @Before
    fun setUp() {
        coEvery { dao.getAll(any()) } returns emptyList()
        coEvery { secureKeyStore.getApiKey(any(), any()) } returns ""
        // Writing a single key status materializes a list and persists the non-primary key values as usual: with a one-entry list there is nothing to store.
        every { secureKeyStore.saveRelayKeySecrets(any(), any(), any()) } returns Unit
        every { secureKeyStore.beginCapabilityConnection(any(), any()) } returns SecureKeyStore.CapabilityEpochs("cg-test", "ce-test")
        every { secureKeyStore.advanceCapabilityConnection(any(), any()) } returns SecureKeyStore.CapabilityEpochs("cg-next", "ce-next")

        repository = createRepository()
    }

    private fun createRepository(
        transaction: suspend (suspend () -> Unit) -> Unit = { block -> block() },
        capabilityPreferenceStore: ai.oriveo.community.core.model.CapabilityPreferenceStore? = null,
        localCapabilityCustomFragmentStore: ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore? = null,
    ) = ProviderRepository(
            dao = dao,
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
            // BYOK validation probe stub: official register/resync use the default contract (/models + bearer), 200 -> VALID.
            // These cases only care about Connected/Issue and catalog building; VALID does not change existing assertions.
            httpClient = HttpClient(
                MockEngine { respond("""{"data":[]}""", HttpStatusCode.OK) }
            ),
            runInTransaction = transaction,
            capabilityPreferenceStore = capabilityPreferenceStore,
            localCapabilityCustomFragmentStore = localCapabilityCustomFragmentStore,
        )

    /**
     * The generation guard reads back the entity just written inside the same logical transaction. Faking the DAO with a capture list
     * only covers the "was written" side and cannot express the real visible state after commit, so a correct CAS rejection would be
     * misjudged as stale. Here the mock keeps the same minimal read/write semantics as Room.
     */
    private fun mockStatefulProviderDao(
        initial: ProviderEntity?,
        writes: MutableList<ProviderEntity>,
    ) {
        var persisted = initial
        coEvery { dao.getById(any(), any()) } coAnswers {
            persisted?.takeIf { entity ->
                entity.accountId == firstArg<String>() && entity.id == secondArg<String>()
            }
        }
        coEvery { dao.upsert(any()) } coAnswers {
            val entity = firstArg<ProviderEntity>()
            persisted = entity
            writes += entity
        }
    }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        runCatching { unmockkObject(MetadataClient) }
    }

    @Test
    fun `registerProvider default official instance uses deterministic stable id`() = runTest {
        // The default/first instance (isAdditionalInstance=false) gets a deterministic UUIDv5(NS,"openAI|"),
        // so adding the same official provider always derives the same id.
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o")),
            ),
        )
        val upserted = slot<ProviderEntity>()

        coEvery { dao.getAll(accountId) } returns emptyList()
        coEvery { secureKeyStore.saveApiKey(any(), any(), "sk-new") } returns Unit
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        val result = repository.registerProvider(
            kind = ProviderKind.OpenAI,
            apiKey = "sk-new",
        )

        // golden: openAI has no region -> name="openAI|"
        val deterministicId = "CEE693BC-01B3-5542-A639-D3263AF0D47A"
        assertEquals(deterministicId, result.id)
        // The default instance name is the displayName (no suffix)
        assertEquals("OpenAI", result.customName)
        assertTrue(result.catalogModels.isEmpty())
        assertTrue(result.models.any { it.isDefault })

        // Stable under the same algorithm: a second call yields the same deterministic id (idempotent overwrite of the same record)
        val again = ai.oriveo.community.core.util.DeterministicProviderId.forProvider(ProviderKind.OpenAI, "")
        assertEquals(deterministicId, again)

        coVerify(exactly = 1) { secureKeyStore.saveApiKey(any(), deterministicId, "sk-new") }
        verify(exactly = 1) { secureKeyStore.beginCapabilityConnection(accountId, deterministicId) }
    }

    @Test
    fun `registerProvider additional official instance uses random id and generated name`() = runTest {
        // "Add another account" (isAdditionalInstance=true) -> random id + generated name "OpenAI 2".
        MetadataTestFixtures.applyProviders(
            MetadataTestFixtures.ProviderSpec(
                providerKind = ProviderKind.OpenAI,
                defaultModelId = "gpt-4o",
                resolveMap = mapOf("gpt-4o" to "gpt-4o"),
                models = listOf(MetadataTestFixtures.ModelSpec(id = "gpt-4o", canonicalModelId = "gpt-4o")),
            ),
        )
        // The default deterministic instance already exists (customName="OpenAI")
        val deterministicId = "CEE693BC-01B3-5542-A639-D3263AF0D47A"
        val existingProvider = provider(
            id = deterministicId,
            kind = ProviderKind.OpenAI,
            models = listOf(model("gpt-4o", isDefault = true)),
        ).copy(customName = "OpenAI")
        val upserted = slot<ProviderEntity>()

        coEvery { dao.getAll(accountId) } returns listOf(existingProvider.toEntity(accountId))
        coEvery { secureKeyStore.saveApiKey(any(), any(), "sk-new") } returns Unit
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        val result = repository.registerProvider(
            kind = ProviderKind.OpenAI,
            apiKey = "sk-new",
            isAdditionalInstance = true,
        )

        // Random id: never equal to the deterministic id
        assertNotEquals(deterministicId, result.id)
        assertEquals("OpenAI 2", result.customName)
        assertTrue(result.catalogModels.isEmpty())
        assertTrue(result.models.any { it.isDefault })

        val persisted = upserted.captured.toDomain(apiKey = "sk-new")
        assertEquals(ProviderConnectionState.Connected, persisted.status)
        assertEquals("OpenAI 2", persisted.customName)

        coVerify(exactly = 0) { secureKeyStore.deleteApiKey(any(), normalizeUuid(deterministicId)) }
        coVerify(exactly = 1) { secureKeyStore.saveApiKey(any(), result.id, "sk-new") }
    }

    @Test
    fun `registerProvider keeps relay shell when relay catalog is empty`() = runTest {
        val upserted = slot<ProviderEntity>()

        coEvery { secureKeyStore.saveApiKey(any(), any(), "sk-relay") } returns Unit
        coEvery {
            relayService.syncProvider(
                apiKey = "sk-relay",
                preferredModelID = null,
                baseUrl = "https://relay.example.com/v1",
            )
        } throws ProviderServiceError.EmptyModelCatalog
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        val result = repository.registerProvider(
            kind = ProviderKind.Relay,
            apiKey = "sk-relay",
            baseUrl = "https://relay.example.com/v1",
            customName = "My Relay",
        )

        assertEquals(ProviderKind.Relay, result.kind)
        assertTrue(result.models.isEmpty())
        assertTrue(result.catalogModels.isEmpty())
        assertEquals("My Relay", result.customName)
        assertEquals("https://relay.example.com/v1", result.baseUrlText)

        val persisted = upserted.captured.toDomain(apiKey = "sk-relay")
        assertTrue(persisted.models.isEmpty())
        assertTrue(persisted.catalogModels.isEmpty())
        assertEquals("My Relay", persisted.customName)

    }

    @Test
    fun `registerRelayProvider keeps full catalog and enables only preferred model`() = runTest {
        val upserts = mutableListOf<ProviderEntity>()
        coEvery { secureKeyStore.saveApiKey(any(), any(), "sk-catalog") } returns Unit
        mockStatefulProviderDao(initial = null, writes = upserts)

        val result = repository.registerRelayProvider(
            apiKey = "sk-catalog",
            baseUrl = "https://relay.example.com/v1",
            customName = "Catalog Relay",
            relayKind = RelayKind.OpenAICompatible,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                resolvedAPIBaseURL = "https://relay.example.com/v1",
            ),
            catalogModelIDs = listOf(" model-first ", "model-second", "model-first"),
            preferredModelID = "model-second",
            connectionVerified = false,
        )

        assertEquals(listOf("model-first", "model-second"), result.catalogModels.map { it.id })
        assertEquals(listOf("model-second"), result.models.map { it.id })
        // A relay has no default model: registration no longer writes isDefault.
        assertFalse(result.models.single().isDefault)
        assertEquals(listOf(ModelCapability.Text), result.catalogModels.first().capabilities)
        assertEquals(
            ProviderConnectionState.Issue(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
            result.status,
        )
        assertEquals(ProviderRepository.RELAY_UNVERIFIED_MESSAGE, result.lastError)

        val persisted = upserts.single().toDomain(apiKey = "sk-catalog")
        assertEquals(result.catalogModels.map { it.id }, persisted.catalogModels.map { it.id })
        assertEquals(result.models.map { it.id }, persisted.models.map { it.id })
        verify(exactly = 1) { secureKeyStore.beginCapabilityConnection(accountId, result.id) }
    }

    @Test
    fun `registerRelayProvider writes the local engine declaration onto each model and keeps it on device`() = runTest {
        val upserts = mutableListOf<ProviderEntity>()
        coEvery { secureKeyStore.saveApiKey(any(), any(), "") } returns Unit
        mockStatefulProviderDao(initial = null, writes = upserts)
        val vision = ai.oriveo.community.core.model.EngineDeclaration(image = true, toolCall = false, thinking = false)

        val result = repository.registerRelayProvider(
            apiKey = "",
            baseUrl = "http://127.0.0.1:11434",
            customName = "Ollama",
            relayKind = RelayKind.OpenAICompatible,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                resolvedAPIBaseURL = "http://127.0.0.1:11434/v1",
                engineProfile = "ollama",
            ),
            catalogModelIDs = listOf("smolvlm", "undeclared"),
            preferredModelID = "smolvlm",
            engineDeclarations = mapOf("smolvlm" to vision),
        )

        assertEquals(vision, result.catalogModels.single { it.id == "smolvlm" }.engineDeclaration)
        assertNull(result.catalogModels.single { it.id == "undeclared" }.engineDeclaration)
        assertEquals(vision, result.models.single().engineDeclaration)
        val persisted = upserts.single().toDomain(apiKey = "")
        assertEquals(vision, persisted.catalogModels.single { it.id == "smolvlm" }.engineDeclaration)
    }

    @Test
    fun `registerRelayProvider writes the default model probe as reachable and only that root`() = runTest {
        val upserts = mutableListOf<ProviderEntity>()
        coEvery { secureKeyStore.saveApiKey(any(), any(), "sk-probe") } returns Unit
        mockStatefulProviderDao(initial = null, writes = upserts)

        repository.registerRelayProvider(
            apiKey = "sk-probe",
            baseUrl = "https://relay.example.com",
            customName = "Probe Relay",
            relayKind = RelayKind.OpenAICompatible,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.Auto,
                resolvedAPIBaseURL = "https://relay.example.com/v1",
                resolvedAPIBaseURLs = mapOf("gemini_generate_content" to "https://relay.example.com/v1beta"),
            ),
            catalogModelIDs = listOf("claude-sonnet-4-5", "gpt-4o-mini"),
            preferredModelID = "claude-sonnet-4-5",
            preferredModelProbe = ai.oriveo.community.core.provider.relay.RelayModelProbePass(
                RelayTransport.AnthropicMessages,
                "https://relay.example.com/v1",
            ),
        )

        val persisted = upserts.single().toDomain(apiKey = "sk-probe")
        val requested = requireNotNull(persisted.relayRequested)
        assertEquals(RelayTransport.Auto, requested.transport)
        assertEquals("https://relay.example.com/v1", requested.resolvedAPIBaseURL)
        assertEquals(
            mapOf(
                "gemini_generate_content" to "https://relay.example.com/v1beta",
                "anthropic_messages" to "https://relay.example.com/v1",
            ),
            requested.resolvedAPIBaseURLs,
        )
        val pinned = persisted.models.single { it.id == "claude-sonnet-4-5" }
        assertEquals(RelayTransport.AnthropicMessages, pinned.relayTransport)
        assertEquals(ai.oriveo.community.core.model.RelayTransportSource.Reachable, pinned.relayTransportSource)
        val other = persisted.catalogModels.single { it.id == "gpt-4o-mini" }
        assertEquals(null, other.relayTransport)
        assertEquals(null, other.relayTransportSource)
    }

    /**
     * Relay enrichment + catalog resolution + JSON encoding is pure O(catalog) computation, and the callers
     * (RelaySetupViewModel / ProviderDetailViewModel) run on viewModelScope (Main).
     * This work must leave the calling thread, otherwise saving / switching models with a catalog of thousands of entries blocks the main thread in proportion to catalog size.
     */
    @Test
    fun `relay writes finalize the catalog off the calling thread`() = runTest {
        val callerExecutor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "fake-main") }
        val caller = callerExecutor.asCoroutineDispatcher()
        val finalizeThreads = CopyOnWriteArrayList<String>()
        mockkStatic(PROVIDER_CATALOG_RESOLVER_KT)
        try {
            every { prepareProviderForUpsert(any(), any()) } answers {
                finalizeThreads += Thread.currentThread().name
                callOriginal()
            }
            coEvery { secureKeyStore.saveApiKey(any(), any(), "sk-large") } returns Unit
            mockStatefulProviderDao(initial = null, writes = mutableListOf())
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

            assertTrue("Precondition: both register and update must actually reach the finalize step before the database write", finalizeThreads.size >= 2)
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
     * Field report (a Featherless relay with a 22,014-entry catalog): selecting / enabling a model in the home model picker goes through
     * HomeViewModel's viewModelScope (Main) -> [ProviderRepository.getById].
     * If decoding the whole catalog JSON stays on the calling thread, it lands on the main thread in proportion to catalog size.
     *
     * Measure: the CPU time the calling thread (fake-main) actually spends during one getById (ThreadMXBean),
     * median of 5 runs after 2 warm-ups. Only the calling thread is measured: once decoding moves elsewhere it only pays suspend/resume scheduling overhead.
     */
    @Test
    fun `getById decodes a large relay catalog off the calling thread`() = runTest {
        val relayId = "6F1C7C52-5A8E-4A0E-9D7E-3B1F0A9C2E22"
        val catalog = (0 until 22_000).map { index ->
            AIModel(
                id = "org-${index % 3_000}/gemma-4-31B-it-variant-$index",
                name = "org-${index % 3_000}/gemma-4-31B-it-variant-$index",
                capabilities = listOf(ModelCapability.Text),
                contextLength = 32_768,
            )
        }
        val relay = provider(
            id = relayId,
            kind = ProviderKind.Relay,
            models = listOf(catalog.first().copy(isDefault = true)),
            catalogModels = catalog,
            baseUrlText = "https://api.featherless.ai/v1",
        )
        coEvery { dao.getById(accountId, relayId) } returns relay.toEntity(accountId)
        coEvery { secureKeyStore.getApiKey(any(), relayId) } returns "sk-relay"

        val callerExecutor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "fake-main") }
        val caller = callerExecutor.asCoroutineDispatcher()
        val threadMx = java.lang.management.ManagementFactory.getThreadMXBean()
        try {
            val samples = (1..7).map {
                withContext(caller) {
                    val cpuBefore = threadMx.currentThreadCpuTime
                    val loaded = repository.getById(relayId)
                    val cpuMs = (threadMx.currentThreadCpuTime - cpuBefore) / 1_000_000.0
                    assertEquals("Precondition: production decoding must really produce the whole catalog", 22_000, loaded?.catalogModels?.size)
                    cpuMs
                }
            }.drop(2).sorted()
            val medianMs = samples[samples.size / 2]
            println("ProviderRepositoryTest getById relay catalog=22000 callerCpuMedian=${"%.2f".format(medianMs)}ms samples=$samples")
            assertTrue(
                "getById spent ${"%.2f".format(medianMs)}ms CPU on the calling thread: catalog decoding still runs on the caller (Main on the home screen)",
                medianMs < 5.0,
            )
        } finally {
            caller.close()
        }
    }

    @Test
    fun `registerRelayProvider derives and deduplicates the name when Quick Setup omits it`() = runTest {
        val existingRelay = provider(
            id = "11111111-1111-1111-1111-111111111111",
            kind = ProviderKind.Relay,
            models = emptyList(),
            baseUrlText = "https://aa.bb.cc/v1",
        ).copy(customName = "bb.cc")
        val writes = mutableListOf<ProviderEntity>()

        coEvery { dao.getAll(accountId) } returns listOf(existingRelay.toEntity(accountId))
        coEvery { secureKeyStore.saveApiKey(any(), any(), "sk-relay") } returns Unit
        mockStatefulProviderDao(initial = null, writes = writes)

        val result = repository.registerRelayProvider(
            apiKey = "sk-relay",
            baseUrl = "https://aa.bb.cc/v1",
            customName = null,
            relayKind = RelayKind.OpenAICompatible,
            relayRequested = RelayRequestedConfig(),
        )

        assertEquals("bb.cc 2", result.customName)
        assertEquals("bb.cc 2", writes.single().customName)
    }

    @Test
    fun `registerProvider for relay uses endpoint domain default name and deduplicates`() = runTest {
        val existingRelay = provider(
            id = "11111111-1111-1111-1111-111111111111",
            kind = ProviderKind.Relay,
            models = emptyList(),
            baseUrlText = "https://aa.bb.cc/v1",
        ).copy(customName = "bb.cc")
        val upserted = slot<ProviderEntity>()

        coEvery { dao.getAll(accountId) } returns listOf(existingRelay.toEntity(accountId))
        coEvery { secureKeyStore.saveApiKey(any(), any(), "sk-relay") } returns Unit
        coEvery {
            relayService.syncProvider(
                apiKey = "sk-relay",
                preferredModelID = null,
                baseUrl = "https://aa.bb.cc/v1",
            )
        } throws ProviderServiceError.EmptyModelCatalog
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        val result = repository.registerProvider(
            kind = ProviderKind.Relay,
            apiKey = "sk-relay",
            baseUrl = "https://aa.bb.cc/v1",
            customName = null,
        )

        assertEquals("bb.cc 2", result.customName)
        assertEquals("bb.cc 2", upserted.captured.customName)
    }

    @Test
    fun `renameProvider deduplicates by kind while excluding normalized current id`() = runTest {
        val currentId = "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"
        val currentProvider = provider(
            id = currentId,
            kind = ProviderKind.Relay,
            models = emptyList(),
            baseUrlText = "https://aa.bb.cc/v1",
        ).copy(customName = "bb.cc")
        val conflictingProvider = provider(
            id = "22222222-2222-4222-8222-222222222222",
            kind = ProviderKind.Relay,
            models = emptyList(),
            baseUrlText = "https://other.example.com/v1",
        ).copy(customName = "  BB.CC 2  ")
        val otherKindProvider = provider(
            id = "33333333-3333-4333-8333-333333333333",
            kind = ProviderKind.OpenAI,
            models = emptyList(),
        ).copy(customName = "bb.cc")
        val upserted = slot<ProviderEntity>()

        coEvery { dao.getAll(accountId) } returns listOf(
            currentProvider.toEntity(accountId).copy(id = currentId),
            conflictingProvider.toEntity(accountId),
            otherKindProvider.toEntity(accountId),
        )
        coEvery { dao.getById(accountId, normalizeUuid(currentId)) } returns
            currentProvider.toEntity(accountId).copy(id = normalizeUuid(currentId))
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        repository.renameProvider(currentProvider, " bb.cc 2 ")

        assertEquals(normalizeUuid(currentId), upserted.captured.id)
        assertEquals("bb.cc 3", upserted.captured.customName)
    }

    @Test
    fun `registerProvider for relay does not reuse existing relay id`() = runTest {
        val existingRelay = provider(
            id = "11111111-1111-1111-1111-111111111111",
            kind = ProviderKind.Relay,
            models = emptyList(),
        )
        val existingEntity = existingRelay.toEntity(accountId)
        val upserted = slot<ProviderEntity>()

        // dao.getAll returns an existing relay; registerProvider must skip the existing lookup for a Relay
        // and neither read nor overwrite that entity.
        coEvery { dao.getAll(accountId) } returns listOf(existingEntity)
        coEvery { secureKeyStore.saveApiKey(any(), any(), "sk-new-relay") } returns Unit
        coEvery {
            relayService.syncProvider(
                apiKey = "sk-new-relay",
                preferredModelID = null,
                baseUrl = "https://relay-2.example.com/v1",
            )
        } returns ProviderSyncResult(models = listOf(model("gpt-4")))
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        val result = repository.registerProvider(
            kind = ProviderKind.Relay,
            apiKey = "sk-new-relay",
            baseUrl = "https://relay-2.example.com/v1",
            customName = "Relay 2",
        )

        // The new Relay must get a different id and must not trigger secureKeyStore.deleteApiKey(any(), existing)
        assertNotEquals(normalizeUuid(existingRelay.id), result.id)
        assertEquals("Relay 2", result.customName)
        assertEquals("https://relay-2.example.com/v1", result.baseUrlText)
        coVerify(exactly = 0) { secureKeyStore.deleteApiKey(any(), normalizeUuid(existingRelay.id)) }
        coVerify(exactly = 1) { secureKeyStore.saveApiKey(any(), result.id, "sk-new-relay") }
    }

    @Test
    fun `resyncProvider for official provider preserves manual-retained enabled subset`() = runTest {
        // Metadata-authoritative:
        // - resync of an official Provider no longer auto-enables the metadata default;
        // - when the user's old model "legacy-model" does not match metadata, it is kept as manual-retained;
        // - because legacy-model is still in the enabled set, the default selection stays unchanged.
        mockkObject(MetadataClient)
        coEvery { MetadataClient.refresh() } returns Unit
        every { MetadataClient.providerModelIds(ProviderKind.OpenAI) } returns listOf("gpt-4o")
        every { MetadataClient.defaultModelId(ProviderKind.OpenAI) } returns "gpt-4o"
        every { MetadataClient.resolveCatalogModel(any(), ProviderKind.OpenAI) } returns null

        val providerId = "123e4567-e89b-12d3-a456-426614174001"
        val existingProvider = provider(
            id = providerId,
            kind = ProviderKind.OpenAI,
            models = listOf(model("legacy-model", isDefault = true)),
            lastError = "old-error",
            lastCheckedAt = 1000L,
            apiKey = "sk-openai",
        )
        val upserts = mutableListOf<ProviderEntity>()

        val existingEntity = existingProvider.toEntity(accountId)
        mockStatefulProviderDao(initial = existingEntity, writes = upserts)
        coEvery { secureKeyStore.getApiKey(any(), normalizeUuid(providerId)) } returns "sk-openai"

        repository.resyncProvider(providerId)

        assertEquals(2, upserts.size)
        val finalProvider = upserts.last().toDomain(apiKey = "sk-openai")
        assertEquals(ProviderConnectionState.Connected, finalProvider.status)
        assertNull(finalProvider.lastError)
        // Manual-retained fallback: legacy-model is kept and is still the default selection (flag off)
        assertEquals("legacy-model", finalProvider.defaultModel?.id)
        assertTrue(finalProvider.models.any { it.id == "legacy-model" })

        coVerify(exactly = 0) {
            openAIService.syncProvider(apiKey = any(), preferredModelID = any(), baseUrl = any())
        }
    }

    @Test
    fun `resyncProvider preserves connected status when non fatal error happens with cached models`() = runTest {
        mockkObject(MetadataClient)
        coEvery { MetadataClient.refresh() } returns Unit

        val providerId = "123e4567-e89b-12d3-a456-426614174002"
        val existingProvider = provider(
            id = providerId,
            kind = ProviderKind.Relay,
            models = listOf(model("cached-model", isDefault = true)),
            catalogModels = listOf(model("cached-model", isDefault = true)),
            lastError = "previous-error",
            lastCheckedAt = 1000L,
            apiKey = "sk-relay",
            baseUrlText = "relay.example.com/v1",
        )
        val upserts = mutableListOf<ProviderEntity>()

        val existingEntity = existingProvider.toEntity(accountId)
        mockStatefulProviderDao(initial = existingEntity, writes = upserts)
        coEvery { secureKeyStore.getApiKey(any(), normalizeUuid(providerId)) } returns "sk-relay"
        coEvery {
            relayService.syncProvider(
                apiKey = "sk-relay",
                preferredModelID = null,
                baseUrl = "relay.example.com/v1",
                relayRequested = any(),
            )
        } throws ProviderServiceError.Network("timeout")

        repository.resyncProvider(providerId)

        assertEquals(2, upserts.size)
        val fallbackProvider = upserts.last().toDomain(apiKey = "sk-relay")
        assertEquals(ProviderConnectionState.Connected, fallbackProvider.status)
        // While the generation connection is still valid, a catalog failure is an independent persistable soft state; the previous arbitrary error must not keep showing.
        assertEquals(ProviderRepository.RELAY_CATALOG_UNAVAILABLE_MESSAGE, fallbackProvider.lastError)

    }

    @Test
    fun `mode transition persists stable issue key instead of relay guidance`() = runTest {
        mockkObject(MetadataClient)
        coEvery { MetadataClient.refresh() } returns Unit

        val providerId = "123e4567-e89b-12d3-a456-426614174102"
        val existingProvider = provider(
            id = providerId,
            kind = ProviderKind.Relay,
            models = listOf(model("cached-model", isDefault = true)),
            catalogModels = listOf(model("cached-model", isDefault = true)),
            apiKey = "sk-relay",
            baseUrlText = "https://relay.example.com/v1",
        )
        val upserts = mutableListOf<ProviderEntity>()
        val existingEntity = existingProvider.toEntity(accountId)
        mockStatefulProviderDao(initial = existingEntity, writes = upserts)
        coEvery { secureKeyStore.getApiKey(any(), normalizeUuid(providerId)) } returns "sk-relay"
        coEvery {
            relayService.syncProvider(
                apiKey = "sk-relay",
                preferredModelID = null,
                baseUrl = "https://relay.example.com/v1",
                relayRequested = any(),
            )
        } throws checkNotNull(
            RelayErrorMapper.classify(
                status = 502,
                body = """{"error":{"message":"upstream_error"}}""",
            ),
        )

        val outcome = repository.resyncProviderForModeTransition(providerId) { true }

        assertFalse(outcome.catalogSucceeded)
        assertFalse(outcome.stale)
        assertEquals(2, upserts.size)
        val failed = upserts.last().toDomain(apiKey = "sk-relay")
        assertTrue(failed.status is ProviderConnectionState.Issue)
        assertEquals(ProviderRepository.RELAY_UNVERIFIED_MESSAGE, failed.lastError)
        assertFalse(failed.lastError.orEmpty().contains("custom LLM"))
    }

    @Test
    fun `stale mode transition cannot persist a post sync boundary`() = runTest {
        mockkObject(MetadataClient)
        coEvery { MetadataClient.refresh() } returns Unit

        val providerId = "123e4567-e89b-12d3-a456-426614174103"
        val existingProvider = provider(
            id = providerId,
            kind = ProviderKind.Relay,
            models = emptyList(),
            catalogModels = emptyList(),
            apiKey = "sk-relay",
            baseUrlText = "https://relay.example.com/v1",
        )
        val upserts = mutableListOf<ProviderEntity>()
        var current = true
        val existingEntity = existingProvider.toEntity(accountId)
        mockStatefulProviderDao(initial = existingEntity, writes = upserts)
        coEvery { secureKeyStore.getApiKey(any(), normalizeUuid(providerId)) } returns "sk-relay"
        coEvery {
            relayService.syncProvider(
                apiKey = "sk-relay",
                preferredModelID = null,
                baseUrl = "https://relay.example.com/v1",
                relayRequested = any(),
            )
        } coAnswers {
            current = false
            ProviderSyncResult(models = listOf(model("fresh-model", isDefault = true)))
        }

        val outcome = repository.resyncProviderForModeTransition(providerId) { current }

        assertTrue(outcome.stale)
        assertFalse(outcome.catalogSucceeded)
        assertEquals(1, upserts.size)
        assertTrue(upserts.single().status.contains("syncing"))
    }

    @Test
    fun `guard invalidation during final dao write exits the Room transaction for rollback`() = runTest {
        mockkObject(MetadataClient)
        coEvery { MetadataClient.refresh() } returns Unit
        var transactionRolledBack = false
        repository = createRepository(transaction = { block ->
            try {
                block()
            } catch (error: Exception) {
                transactionRolledBack = true
                throw error
            }
        })
        val providerId = "123e4567-e89b-12d3-a456-426614174104"
        val existingProvider = provider(
            id = providerId,
            kind = ProviderKind.Relay,
            models = listOf(model("old", isDefault = true)),
            catalogModels = listOf(model("old", isDefault = true)),
            apiKey = "sk-relay",
            baseUrlText = "https://relay.example.com/v1",
        )
        val upserts = mutableListOf<ProviderEntity>()
        val existingEntity = existingProvider.toEntity(accountId)
        var current = true
        coEvery { dao.getById(accountId, normalizeUuid(providerId)) } coAnswers {
            upserts.lastOrNull() ?: existingEntity
        }
        coEvery { secureKeyStore.getApiKey(accountId, normalizeUuid(providerId)) } returns "sk-relay"
        coEvery { dao.upsert(capture(upserts)) } coAnswers {
            if (upserts.size == 2) current = false
        }
        coEvery {
            relayService.syncProvider("sk-relay", null, "https://relay.example.com/v1", any())
        } returns ProviderSyncResult(models = listOf(model("fresh", isDefault = true)))

        val outcome = repository.resyncProviderForModeTransition(providerId) { current }

        assertTrue(outcome.stale)
        assertTrue(transactionRolledBack)
    }

    @Test
    fun `stale relay registration rolls back transaction and deletes its KeyStore entry`() = runTest {
        var current = true
        var transactionRolledBack = false
        repository = createRepository(transaction = { block ->
            try {
                block()
            } catch (error: Exception) {
                transactionRolledBack = true
                throw error
            }
        })
        coEvery { dao.getById(accountId, any()) } returns null
        coEvery { secureKeyStore.saveApiKey(accountId, any(), "sk-stale") } returns Unit
        coEvery { secureKeyStore.deleteApiKey(accountId, any()) } returns Unit
        coEvery { dao.upsert(any()) } coAnswers { current = false }

        try {
            repository.registerRelayProvider(
                apiKey = "sk-stale",
                baseUrl = "https://relay.example/v1",
                customName = "Stale",
                relayKind = RelayKind.OpenAICompatible,
                relayRequested = RelayRequestedConfig(),
                preferredModelID = "model",
                commitGuard = { current },
            )
            fail("expected stale registration cancellation")
        } catch (_: kotlinx.coroutines.CancellationException) {
            // A guard failure verified after the transaction must exit via cancellation semantics and not be reported to the UI as an ordinary connection error.
        }

        assertTrue(transactionRolledBack)
        coVerify(exactly = 1) { secureKeyStore.saveApiKey(accountId, any(), "sk-stale") }
        coVerify(exactly = 1) { secureKeyStore.deleteApiKey(accountId, any()) }
    }

    @Test
    fun `resyncProvider marks issue when fatal error happens and no cached models exist`() = runTest {
        mockkObject(MetadataClient)
        coEvery { MetadataClient.refresh() } returns Unit

        val providerId = "123e4567-e89b-12d3-a456-426614174003"
        val existingProvider = provider(
            id = providerId,
            kind = ProviderKind.Relay,
            models = emptyList(),
            catalogModels = emptyList(),
            lastCheckedAt = null,
            apiKey = "sk-relay",
            baseUrlText = "relay.example.com/v1",
        )
        val upserts = mutableListOf<ProviderEntity>()

        val existingEntity = existingProvider.toEntity(accountId)
        mockStatefulProviderDao(initial = existingEntity, writes = upserts)
        coEvery { secureKeyStore.getApiKey(any(), normalizeUuid(providerId)) } returns "sk-relay"
        coEvery {
            relayService.syncProvider(
                apiKey = "sk-relay",
                preferredModelID = null,
                baseUrl = "relay.example.com/v1",
                relayRequested = any(),
            )
        } throws ProviderServiceError.InvalidAPIKey("bad-key")

        repository.resyncProvider(providerId)

        assertEquals(2, upserts.size)
        val fallbackProvider = upserts.last().toDomain(apiKey = "sk-relay")
        val issue = fallbackProvider.status as ProviderConnectionState.Issue
        assertEquals(
            "The API key could not be validated. Check the value or generate a new key.",
            issue.message,
        )
        assertEquals(issue.message, fallbackProvider.lastError)
    }

    @Test
    fun `saveManualModel preserves issue state and does not rewrite conversation model selection`() = runTest {
        val providerId = "123e4567-e89b-12d3-a456-426614174004"
        val existingProvider = provider(
            id = providerId,
            kind = ProviderKind.Relay,
            models = listOf(model("known-model", isDefault = true)),
            catalogModels = listOf(model("known-model", isDefault = true)),
            status = ProviderConnectionState.Issue("old"),
            lastError = "old",
            apiKey = "sk-relay",
        )
        val upserted = slot<ProviderEntity>()

        coEvery { dao.getById(any(), normalizeUuid(providerId)) } returns existingProvider.toEntity(accountId)
        coEvery { secureKeyStore.getApiKey(any(), normalizeUuid(providerId)) } returns "sk-relay"
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        repository.saveManualModel(providerID = providerId, modelID = "manual-model")

        val updated = upserted.captured.toDomain(apiKey = "sk-relay")
        assertEquals(ProviderConnectionState.Issue("old"), updated.status)
        assertEquals("old", updated.lastError)
        assertEquals(listOf("manual-model"), updated.models.map { it.id })
        assertEquals("manual-model", updated.defaultModel?.id)
        assertTrue(updated.catalogModels.any { it.id == "known-model" })
        assertTrue(updated.catalogModels.any { it.id == "manual-model" })
    }

    @Test
    fun `saveManualModel throws invalid configuration when provider does not exist`() = runTest {
        coEvery { dao.getById(any(), any()) } returns null

        try {
            repository.saveManualModel("missing-provider", "manual-model")
            fail("Expected ProviderServiceError.InvalidConfiguration")
        } catch (error: ProviderServiceError.InvalidConfiguration) {
            assertTrue(error.detail.contains("missing-provider"))
        }
    }

    @Test
    fun `observeAll hydrates apiKey from SecureKeyStore so list page sees same status as detail`() = runTest {
        // Regression: observeAll used to go through entity.toDomain() with the default apiKey="", so effectiveStatusKind
        // was always NeedsKey and the list page disagreed with the detail page (observeById fills in apiKey).
        val providerId = "123e4567-e89b-12d3-a456-426614174099"
        val storedProvider = provider(
            id = providerId,
            kind = ProviderKind.OpenAI,
            models = listOf(model("gpt-4o", isDefault = true)),
        )
        every { dao.observeAll(accountId) } returns flowOf(listOf(storedProvider.toEntity(accountId)))
        coEvery { secureKeyStore.getApiKey(any(), normalizeUuid(providerId)) } returns "sk-real-key"

        val observed = repository.observeAll().first()

        assertEquals(1, observed.size)
        assertEquals("sk-real-key", observed[0].apiKey)
        assertNotEquals(ProviderEffectiveStatusKind.NeedsKey, observed[0].effectiveStatusKind)
    }

    @Test
    fun `deleting a connection clears its local avatar choice`() = runTest {
        val store = ai.oriveo.community.core.model.RelayAvatarChoiceStore
        val written = mutableMapOf<String, String?>()
        store.configurePersistenceForTesting(emptyMap()) { key, value -> written[key] = value }
        try {
            val providerId = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
            val other = "relay-keep"
            val existing = provider(id = providerId, kind = ProviderKind.Relay, models = emptyList())
            coEvery { dao.getById(accountId, normalizeUuid(providerId)) } returns existing.toEntity(accountId)
            coEvery { dao.deleteById(accountId, normalizeUuid(providerId)) } just runs
            coEvery { secureKeyStore.deleteApiKey(accountId, normalizeUuid(providerId)) } just runs
            store.select(providerId, "kite")
            store.select(other, "letter")

            repository.deleteProvider(providerId)

            assertNull(store.choice(providerId))
            assertEquals("letter", store.choice(other))
            assertEquals(null, written[ai.oriveo.community.core.model.RelayAvatarResolver.choiceKey(providerId)])
            assertTrue(written.containsKey(ai.oriveo.community.core.model.RelayAvatarResolver.choiceKey(providerId)))
        } finally {
            store.resetForTesting()
        }
    }

    @Test
    fun `production provider delete tombstones all runtime preferences and clears rejection cache`() = runTest {
        val providerId = "9a1195de-3af9-5888-abc8-b8177c458c07"
        val runtimeR7 = "r1.b3BlbmFpX3Jlc3BvbnNlcw.cnVudGltZS1yNw"
        val runtimeR8 = "r1.b3BlbmFpX3Jlc3BvbnNlcw.cnVudGltZS1yOA"
        var preferenceRaw: String? = null
        var draftRaw: String? = null
        val store = ai.oriveo.community.core.model.CapabilityPreferenceStore(
            read = { preferenceRaw },
            write = { preferenceRaw = it },
            readDrafts = { draftRaw },
            writeDrafts = { draftRaw = it },
        )
        store.setConnectionModel(
            ai.oriveo.community.core.model.CapabilityPreferenceValues(
                ai.oriveo.community.core.model.CapabilityWebPreference.Automatic, "deep",
            ), providerId, "gpt", runtimeR7,
        )
        store.setConnectionModel(
            ai.oriveo.community.core.model.CapabilityPreferenceValues(
                ai.oriveo.community.core.model.CapabilityWebPreference.Force, "max",
            ), providerId, "gpt", runtimeR8,
        )
        store.setDraftConversation(
            ai.oriveo.community.core.model.CapabilityPreferenceValues(
                ai.oriveo.community.core.model.CapabilityWebPreference.Automatic, "deep",
            ), providerId, "gpt", "draft-session", runtimeR7,
        )
        var customRaw: String? = null
        val customStore = ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore(
            read = { customRaw },
            write = { customRaw = it },
        )
        customStore.setFragment(
            rawJSON = "{\"temperature\":0.2}",
            providerID = providerId,
            modelID = "gpt",
            conversationID = "draft-session",
            transportIdentity = runtimeR7,
        )
        var cacheRaw: String? = null
        ai.oriveo.community.core.provider.ModelControlRejectionCache.configurePersistenceForTesting(
            read = { cacheRaw }, write = { cacheRaw = it },
        )
        val identity = ai.oriveo.community.core.provider.ModelControlRuntimeIdentity(
            providerId, "gpt", "openai_responses", "runtime-r7",
        )
        ai.oriveo.community.core.provider.ModelControlRejectionCache.record(
            identity, "web", "provider_recipe", "/web_search_options", recipeRef = "fixture.web.v1",
        )
        val existing = provider(id = providerId, kind = ProviderKind.OpenAI, models = emptyList())
        val normalizedProviderId = normalizeUuid(providerId)
        coEvery { dao.getById(accountId, normalizedProviderId) } returns existing.toEntity(accountId)
        coEvery { dao.deleteById(accountId, normalizedProviderId) } just runs
        coEvery { secureKeyStore.deleteApiKey(accountId, normalizedProviderId) } just runs

        createRepository(
            capabilityPreferenceStore = store,
            localCapabilityCustomFragmentStore = customStore,
        ).deleteProvider(providerId)

        assertTrue(store.exportPayload().records.isEmpty())
        assertEquals(2, store.exportPayload().tombstones.size)
        assertEquals(null, store.draftConversation(providerId, "gpt", "draft-session", runtimeR7))
        assertEquals(
            null,
            customStore.fragment(providerId, "gpt", "draft-session", runtimeR7),
        )
        assertFalse(
            ai.oriveo.community.core.provider.ModelControlRejectionCache.isRejected(
                identity, "web", "provider_recipe",
            ),
        )
        ai.oriveo.community.core.provider.ModelControlRejectionCache.clearForTesting()
    }

    @Test
    fun `delete custom relay removes its persisted models and key without touching conversations`() = runTest {
        // Deliberately start from the persisted object produced by the production EntityMapper instead of hand-written JSON: the relay's models,
        // default model and connection config all live in the same ProviderEntity and must all become invisible together after deletion.
        val providerId = "6A81E8D1-9B20-4CB3-8D22-01B5D7187F91"
        val customRelay = provider(
            id = providerId,
            kind = ProviderKind.Relay,
            models = listOf(
                model("relay-primary", isDefault = true),
                model("relay-secondary"),
            ),
            catalogModels = listOf(
                model("relay-primary", isDefault = true),
                model("relay-secondary"),
                model("relay-catalog-only"),
            ),
            apiKey = "sk-custom-relay",
            baseUrlText = "https://relay.example.test/v1",
        ).copy(
            relayKind = RelayKind.Custom,
            relayRequested = RelayRequestedConfig(modelID = "relay-primary"),
        )
        var persistedProvider: ProviderEntity? = customRelay.toEntity(accountId)
        val storedKeys = mutableSetOf(providerId)

        // `toEntity` is the output of the production persistence path; first lock that the default model was really persisted, then run the real deleteProvider.
        assertEquals("relay-primary", persistedProvider!!.toDomain("sk-custom-relay").defaultModel?.id)
        assertEquals(2, persistedProvider!!.toDomain("sk-custom-relay").models.size)
        coEvery { dao.getById(accountId, providerId) } coAnswers { persistedProvider }
        coEvery { dao.deleteById(accountId, providerId) } coAnswers { persistedProvider = null }
        coEvery { secureKeyStore.deleteApiKey(accountId, providerId) } coAnswers {
            storedKeys.remove(providerId)
        }

        repository.deleteProvider(providerId)

        // Deleting the Provider row removes the model catalog, enabled state and default model with it; the credential must not be left orphaned either.
        assertNull(persistedProvider)
        assertFalse(storedKeys.contains(providerId))
        coVerify(exactly = 1) { dao.deleteById(accountId, providerId) }
        coVerify(exactly = 1) { secureKeyStore.deleteApiKey(accountId, providerId) }
    }

    @Test
    fun `llama cpp native connections move to chat once per account through the guarded write`() = runTest {
        val llama = provider(
            id = "11111111-1111-1111-1111-111111111111",
            kind = ProviderKind.Relay,
            models = listOf(model("local-model", isDefault = true).copy(
                generationProfile = ai.oriveo.community.core.provider.LocalEngineGenerationProfiles
                    .profile("llamacpp", RelayTransport.LlamaCppNative),
            )),
            baseUrlText = "http://127.0.0.1:8080",
        ).copy(
            relayKind = RelayKind.OpenAICompatible,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.LlamaCppNative,
                resolvedAPIBaseURL = "http://127.0.0.1:8080",
                engineProfile = "llamacpp",
            ),
        )
        val ollama = llama.copy(
            id = "22222222-2222-2222-2222-222222222222",
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                resolvedAPIBaseURL = "http://127.0.0.1:11434/v1",
                engineProfile = "ollama",
            ),
        )
        val stored = mutableMapOf(llama.id to llama.toEntity(accountId), ollama.id to ollama.toEntity(accountId))
        coEvery { dao.getAll(accountId) } coAnswers { stored.values.toList() }
        coEvery { dao.getById(any(), any()) } coAnswers { stored[secondArg()] }
        coEvery { dao.upsert(any()) } coAnswers { stored[firstArg<ProviderEntity>().id] = firstArg() }
        every { secureKeyStore.advanceCapabilityConnectionGeneration(any(), any()) } returns SecureKeyStore.CapabilityEpochs("cg-next", "ce-next")
        val flags = mutableMapOf<String, String>()
        val preferenceDao = mockk<ai.oriveo.community.core.data.dao.PreferenceDao>()
        coEvery { preferenceDao.get(any()) } coAnswers { flags[firstArg()] }
        coEvery { preferenceDao.set(any()) } coAnswers { flags[firstArg<ai.oriveo.community.core.data.entity.PreferenceEntity>().key] = "1" }
        val repo = ProviderRepository(
            dao = dao, secureKeyStore = secureKeyStore,
            openRouterService = openRouterService, openAIService = openAIService, deepSeekService = deepSeekService,
            grokService = grokService, anthropicService = anthropicService, geminiService = geminiService,
            groqService = groqService, togetherService = togetherService, fireworksService = fireworksService,
            miniMaxService = miniMaxService, zhipuService = zhipuService, qwenService = qwenService,
            moonshotService = moonshotService, mistralService = mistralService, siliconFlowService = siliconFlowService,
            relayService = relayService,
            metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
            httpClient = HttpClient(MockEngine { respond("""{"data":[]}""", HttpStatusCode.OK) }),
            preferenceDao = preferenceDao,
        )

        repo.migrateLlamaCppConnectionsOnce(accountId)

        val migrated = stored.getValue(llama.id).toDomain("")
        assertEquals(RelayTransport.OpenAIChatCompletions, migrated.relayRequested?.transport)
        assertEquals("http://127.0.0.1:8080/v1", migrated.relayRequested?.resolvedAPIBaseURL)
        assertEquals("openai_chat_completions", migrated.models.single().generationProfile?.template)
        assertEquals(ollama.toEntity(accountId), stored.getValue(ollama.id))
        assertEquals(1, flags.size)

        // The user later picks the native channel again: the marker is already set, so it is not rewritten.
        stored[llama.id] = llama.toEntity(accountId)
        repo.migrateLlamaCppConnectionsOnce(accountId)
        assertEquals(RelayTransport.LlamaCppNative, stored.getValue(llama.id).toDomain("").relayRequested?.transport)
    }

    // -- saveManualModel must not backfill the catalog --

    @Test
    fun `saveManualModel for official provider must not write catalogModels`() = runTest {
        // Simulate an official Provider (OpenAI) where the user triggers saveManualModel via "Add model ID manually"
        val providerId = "123e4567-e89b-12d3-a456-426614174777"
        val existingProvider = provider(
            id = providerId,
            kind = ProviderKind.OpenAI,
            models = listOf(model("gpt-4o", isDefault = true)),
            catalogModels = emptyList(), // An official Provider persists an empty catalog
            apiKey = "sk-test",
        )
        val upserted = slot<ProviderEntity>()
        coEvery { dao.getById(any(), normalizeUuid(providerId)) } returns existingProvider.toEntity(accountId)
        coEvery { secureKeyStore.getApiKey(any(), normalizeUuid(providerId)) } returns "sk-test"
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        repository.saveManualModel(providerID = providerId, modelID = "custom-manual-model")

        val persisted = upserted.captured.toDomain(apiKey = "sk-test")
        // An official Provider's catalogModels must stay empty; backfilling is forbidden
        assertTrue(
            "official provider catalogModels must stay empty; manual model belongs in models only",
            persisted.catalogModels.isEmpty(),
        )
        assertEquals(listOf("custom-manual-model"), persisted.models.map { it.id })
    }

    @Test
    fun `saveManualModel for relay may keep manual model in catalogModels`() = runTest {
        // Relay is the client-side catalog exception: a manual model may still be written into catalogModels
        val providerId = "123e4567-e89b-12d3-a456-426614174778"
        val existingProvider = provider(
            id = providerId,
            kind = ProviderKind.Relay,
            models = listOf(model("known", isDefault = true)),
            catalogModels = listOf(model("known", isDefault = true)),
            apiKey = "sk-relay",
        )
        val upserted = slot<ProviderEntity>()
        coEvery { dao.getById(any(), normalizeUuid(providerId)) } returns existingProvider.toEntity(accountId)
        coEvery { secureKeyStore.getApiKey(any(), normalizeUuid(providerId)) } returns "sk-relay"
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        repository.saveManualModel(providerID = providerId, modelID = "relay-custom-model")

        val persisted = upserted.captured.toDomain(apiKey = "sk-relay")
        assertTrue(persisted.catalogModels.any { it.id == "relay-custom-model" })
    }

    @Test
    fun `saveManualModel for relay defaults to text capability only`() = runTest {
        // Capabilities not verified by a server catalog or a real call must not be guessed; a manually entered Relay model only declares Text.
        val providerId = "223e4567-e89b-12d3-a456-426614174001"
        val existingProvider = provider(
            id = providerId,
            kind = ProviderKind.Relay,
            models = emptyList(),
            catalogModels = emptyList(),
            apiKey = "sk-relay",
        )
        val upserted = slot<ProviderEntity>()
        coEvery { dao.getById(any(), normalizeUuid(providerId)) } returns existingProvider.toEntity(accountId)
        coEvery { secureKeyStore.getApiKey(any(), normalizeUuid(providerId)) } returns "sk-relay"
        coEvery { dao.upsert(capture(upserted)) } returns Unit

        repository.saveManualModel(providerID = providerId, modelID = "claude-opus-4-6")

        val persisted = upserted.captured.toDomain(apiKey = "sk-relay")
        val manualModel = persisted.models.first { it.id == "claude-opus-4-6" }
        assertEquals(listOf(ModelCapability.Text), manualModel.capabilities)
        assertTrue(ModelCapability.ImageGen !in manualModel.capabilities)
        assertEquals(null, manualModel.imageGenProfile)
    }

    // Regression (observed on a real device): a local engine's authMode / securityMode /
    // resolvedAPIBaseURL all live in relayRequested and the refresh path must pass them through unchanged; otherwise the catalog sync is
    // blocked up front as a "public HTTPS relay that needs credentials" and the provider is marked Issue.
    @Test
    fun `resyncProvider forwards relayRequested so a local engine keeps syncing`() = runTest {
        mockkObject(MetadataClient)
        coEvery { MetadataClient.refresh() } returns Unit

        val providerId = "123e4567-e89b-12d3-a456-426614174780"
        val localEngineRequested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            authMode = RelayAuthMode.None,
            securityMode = RelayConnectionSecurityMode.LocalHttp,
            resolvedAPIBaseURL = "http://192.168.31.250:1234/v1",
            engineProfile = "lmstudio",
        )
        val existingProvider = provider(
            id = providerId,
            kind = ProviderKind.Relay,
            models = emptyList(),
            catalogModels = emptyList(),
            apiKey = "",
            baseUrlText = "http://192.168.31.250:1234",
        ).copy(relayRequested = localEngineRequested)
        val upserts = mutableListOf<ProviderEntity>()

        val existingEntity = existingProvider.toEntity(accountId)
        mockStatefulProviderDao(initial = existingEntity, writes = upserts)
        coEvery { secureKeyStore.getApiKey(any(), normalizeUuid(providerId)) } returns ""
        coEvery {
            relayService.syncProvider(
                apiKey = "",
                preferredModelID = null,
                baseUrl = "http://192.168.31.250:1234",
                relayRequested = localEngineRequested,
            )
        } returns ProviderSyncResult(models = listOf(model("qwen/qwen3-0.6b", isDefault = true)))

        repository.resyncProvider(providerId)

        // Only if relayRequested is passed through unchanged does the exact stub above match and return the catalog
        val synced = upserts.last().toDomain(apiKey = "")
        assertEquals(ProviderConnectionState.Connected, synced.status)
        assertTrue(synced.catalogModels.any { it.id == "qwen/qwen3-0.6b" })
    }

    // -- resyncProvider must not swallow CancellationException --

    @Test
    fun `resyncProvider rethrows CancellationException instead of swallowing it`() = runTest {
        val providerId = "123e4567-e89b-12d3-a456-426614174779"
        val existingProvider = provider(
            id = providerId,
            kind = ProviderKind.Relay,
            models = listOf(model("gpt-4o", isDefault = true)),
            apiKey = "sk-test",
            baseUrlText = "https://relay.example.com/v1",
        )
        coEvery { dao.getById(any(), normalizeUuid(providerId)) } returns existingProvider.toEntity(accountId)
        coEvery { secureKeyStore.getApiKey(any(), normalizeUuid(providerId)) } returns "sk-test"
        coEvery { dao.upsert(any()) } returns Unit
        coEvery {
            relayService.syncProvider(
                apiKey = any(),
                preferredModelID = any(),
                baseUrl = any(),
                relayRequested = any(),
            )
        } throws kotlinx.coroutines.CancellationException("scope cancelled")

        try {
            repository.resyncProvider(providerId)
            fail("expected CancellationException to propagate")
        } catch (expected: kotlinx.coroutines.CancellationException) {
            // Expected: CancellationException must propagate to structured concurrency and not be swallowed by catch(Exception)
            assertTrue(expected.message?.contains("scope cancelled") == true)
        }
    }

    private fun provider(
        id: String,
        kind: ProviderKind,
        models: List<AIModel>,
        catalogModels: List<AIModel> = emptyList(),
        status: ProviderConnectionState = ProviderConnectionState.Connected,
        lastError: String? = null,
        lastCheckedAt: Long? = null,
        apiKey: String = "",
        baseUrlText: String? = kind.defaultBaseUrl,
    ): Provider = Provider(
        id = id,
        kind = kind,
        status = status,
        models = models,
        catalogModels = catalogModels,
        lastCheckedAt = lastCheckedAt,
        apiKey = apiKey,
        apiKeyPreview = "sk-***",
        lastError = lastError,
        baseUrlText = baseUrlText,
    )

    private fun model(
        id: String,
        isDefault: Boolean = false,
    ): AIModel = AIModel(
        id = id,
        name = id,
        isAvailable = true,
        isDefault = isDefault,
    )

}

/** The top-level file class that holds prepareProviderForUpsert; mockkStatic intercepts by it. */
private const val PROVIDER_CATALOG_RESOLVER_KT = "ai.oriveo.community.core.provider.ProviderCatalogResolverKt"
