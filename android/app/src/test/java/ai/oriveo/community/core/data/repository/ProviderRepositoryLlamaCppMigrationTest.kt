package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.mapper.ProviderMapper.toDomain
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.LocalEngineGenerationProfiles
import ai.oriveo.community.core.security.SecureKeyStore
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/** Existing llama.cpp native-channel connections move to the chat channel once, through the guarded write. */
class ProviderRepositoryLlamaCppMigrationTest {

    private val accountId = LOCAL_PARTITION_ID

    @Test
    fun `llama cpp native connections move to chat once through the guarded write`() = runTest {
        val dao = mockk<ProviderDao>()
        val secureKeyStore = mockk<SecureKeyStore>()
        val conversationDao = mockk<ConversationDao>()
        coEvery { conversationDao.getAll(any()) } returns emptyList()
        val llama = provider(
            id = "11111111-1111-1111-1111-111111111111",
            transport = RelayTransport.LlamaCppNative,
            baseUrl = "http://127.0.0.1:8080",
            engineProfile = "llamacpp",
        )
        val ollama = provider(
            id = "22222222-2222-2222-2222-222222222222",
            transport = RelayTransport.OpenAIChatCompletions,
            baseUrl = "http://127.0.0.1:11434/v1",
            engineProfile = "ollama",
        )
        val stored = mutableMapOf(llama.id to llama.toEntity(accountId), ollama.id to ollama.toEntity(accountId))
        coEvery { dao.getAll(accountId) } coAnswers { stored.values.toList() }
        coEvery { dao.getById(any(), any()) } coAnswers { stored[secondArg()] }
        coEvery { dao.upsert(any()) } coAnswers { stored[firstArg<ProviderEntity>().id] = firstArg() }
        coEvery { secureKeyStore.getApiKey(any(), any()) } returns ""
        every { secureKeyStore.advanceCapabilityConnectionGeneration(any(), any()) } returns
            SecureKeyStore.CapabilityEpochs("cg-next", "ce-next")
        val flags = mutableMapOf<String, String>()
        val preferenceDao = mockk<PreferenceDao>()
        coEvery { preferenceDao.get(any()) } coAnswers { flags[firstArg()] }
        coEvery { preferenceDao.set(any()) } coAnswers { flags[firstArg<PreferenceEntity>().key] = "1" }
        val repository = ProviderRepository(
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
            preferenceDao = preferenceDao,
        )

        repository.migrateLlamaCppConnectionsOnce(accountId)

        val migrated = stored.getValue(llama.id).toDomain("")
        assertEquals(RelayTransport.OpenAIChatCompletions, migrated.relayRequested?.transport)
        assertEquals("http://127.0.0.1:8080/v1", migrated.relayRequested?.resolvedAPIBaseURL)
        assertEquals("openai_chat_completions", migrated.models.single().generationProfile?.template)
        assertEquals(ollama.toEntity(accountId), stored.getValue(ollama.id))
        assertEquals(1, flags.size)

        // The user picks the native channel again later: the marker is set, so it is not rewritten.
        stored[llama.id] = llama.toEntity(accountId)
        repository.migrateLlamaCppConnectionsOnce(accountId)
        assertEquals(RelayTransport.LlamaCppNative, stored.getValue(llama.id).toDomain("").relayRequested?.transport)
    }

    private fun provider(id: String, transport: RelayTransport, baseUrl: String, engineProfile: String): Provider = Provider(
        id = id,
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        models = listOf(
            AIModel(
                id = "local-model",
                name = "local-model",
                isDefault = true,
                generationProfile = LocalEngineGenerationProfiles.profile(engineProfile, transport),
            ),
        ),
        apiKey = "",
        apiKeyPreview = "",
        baseUrlText = baseUrl,
        relayKind = RelayKind.OpenAICompatible,
        relayRequested = RelayRequestedConfig(transport = transport, resolvedAPIBaseURL = baseUrl, engineProfile = engineProfile),
    )
}
