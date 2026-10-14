package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.entity.ProviderEntity
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import java.util.Collections
import kotlinx.serialization.json.Json

/**
 * Production repository harness for key status write-back: production [ProviderRepository] + production [RelayService], with an upstream MockEngine
 * that answers per Authorization with each key's catalog (GET) and generation result (POST); persisted objects are encoded and decoded through the production [ProviderMapper].
 */
internal class RelayKeyStatusRepositoryHarness(
    initial: Provider,
    primarySecret: String,
    /** Key value -> model ids in the catalog (requests without a key look up ""); catalog requests with a key not in the table get 401. */
    var catalogs: Map<String, List<String>> = emptyMap(),
) {
    var apiKey = primarySecret
    val secrets: MutableMap<String, String> = initial.relayKeys.orEmpty().drop(1).associate { it.id to it.apiKey }.toMutableMap()
    var stored: ProviderEntity? = with(ProviderMapper) { initial.toEntity(ACCOUNT) }
    /** Every request reaching the upstream: method + Authorization. */
    val requests: MutableList<Pair<HttpMethod, String?>> = Collections.synchronizedList(mutableListOf())
    /** Responses to generation requests (POST): (status, body) by key value; defaults to a 200 Chat Completions JSON. */
    var generation: (secret: String?) -> Pair<Int, String> = { 200 to CHAT_OK }
    /** Content-Type of generation responses. */
    var generationContentType: String = ContentType.Application.Json.toString()
    /** Hook after each database read returns: used to cancel the caller between obtaining the response and writing back. */
    var onRead: (suspend () -> Unit)? = null
    /** Hook when a generation request reaches the upstream (before the response): used to modify the connection mid-request. */
    var onGeneration: (suspend () -> Unit)? = null
    private val json = Json { ignoreUnknownKeys = true }

    private val engine = MockEngine { request ->
        val auth = request.headers[HttpHeaders.Authorization]
        requests += request.method to auth
        val secret = auth?.removePrefix("Bearer ") ?: ""
        if (request.method == HttpMethod.Get) {
            val ids = catalogs[secret]
                ?: return@MockEngine respond("{\"error\":\"Invalid API key\"}", HttpStatusCode.Unauthorized)
            respond(
                "{\"data\":[" + ids.joinToString(",") { "{\"id\":\"$it\"}" } + "]}",
                HttpStatusCode.OK,
                headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        } else {
            onGeneration?.invoke()
            val (status, body) = generation(secret)
            respond(body, HttpStatusCode.fromValue(status), headersOf(HttpHeaders.ContentType, generationContentType))
        }
    }

    val repository: ProviderRepository = run {
        val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
        coEvery { dao.getById(any(), any()) } coAnswers {
            val read = stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
            onRead?.invoke()
            read
        }
        coEvery { dao.upsert(any()) } coAnswers { stored = firstArg() }
        coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
        val keys = mockk<ai.oriveo.community.core.security.SecureKeyStore>(relaxed = true)
        every { keys.getApiKey(any(), any()) } answers { apiKey }
        every { keys.saveApiKey(any(), any(), any()) } answers { apiKey = thirdArg() }
        every { keys.getRelayKeySecret(any(), any(), any()) } answers { secrets[thirdArg()] }
        every { keys.saveRelayKeySecrets(any(), any(), any()) } answers {
            thirdArg<List<RelayKey>?>().orEmpty().drop(1).filter { it.apiKey.isNotEmpty() }.forEach { secrets[it.id] = it.apiKey }
        }
        ProviderRepository(
            dao = dao,
            conversationDao = mockk(relaxed = true),
            secureKeyStore = keys,
            openRouterService = mockk(relaxed = true),
            openAIService = mockk(relaxed = true),
            deepSeekService = mockk(relaxed = true),
            grokService = mockk(relaxed = true),
            anthropicService = mockk(relaxed = true),
            geminiService = mockk(relaxed = true),
            groqService = mockk(relaxed = true),
            togetherService = mockk(relaxed = true),
            fireworksService = mockk(relaxed = true),
            miniMaxService = mockk(relaxed = true),
            zhipuService = mockk(relaxed = true),
            qwenService = mockk(relaxed = true),
            moonshotService = mockk(relaxed = true),
            mistralService = mockk(relaxed = true),
            siliconFlowService = mockk(relaxed = true),
            relayService = RelayService(client = HttpClient(engine), json = json, transportRegistry = TransportRegistry(json)),
            metadataRefreshEventBus = ai.oriveo.community.core.data.remote.MetadataRefreshEventBus(debounceMillis = 0),
            httpClient = HttpClient(MockEngine { respond("", HttpStatusCode.NotFound) }),
            relayModelFamily = { null },
        )
    }

    fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain(apiKey) { secrets[it] } }

    /** Whether the persisted row has a key list (`relayKeysJson`). */
    fun relayKeysPersisted(): Boolean = stored?.relayKeysJson != null

    companion object {
        const val ACCOUNT = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
        const val CHAT_OK = "{\"id\":\"x\",\"choices\":[{\"message\":{\"content\":\"p\"}}]}"
    }
}
