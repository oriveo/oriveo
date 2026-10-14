package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
import ai.oriveo.community.core.provider.relay.RelayTransportCoordinator
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Driven by the shared fixture `relay/credential-resolve.v1.json`: the single entry point for picking a key per model. */
class ProviderCredentialResolveContractTest {

    private val fixture: JsonObject = Json.parseToJsonElement(
        generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .map { File(it, "shared/test-fixtures/relay/credential-resolve.v1.json") }
            .first { it.isFile }
            .readText(Charsets.UTF_8),
    ).jsonObject

    private fun case(id: String): JsonObject = fixture.getValue("cases").jsonArray
        .map { it.jsonObject }
        .single { it.getValue("id").jsonPrimitive.content == id }

    private fun provider(obj: JsonObject): Provider {
        val rawKind = obj.getValue("kind").jsonPrimitive.content
        return Provider(
            id = obj.getValue("id").jsonPrimitive.content,
            kind = ProviderKind.entries.single { it.rawValue == rawKind },
            apiKey = obj.getValue("apiKey").jsonPrimitive.content,
            baseUrlText = obj["baseURL"]?.jsonPrimitive?.content,
            models = obj.getValue("models").jsonArray.map {
                val id = it.jsonPrimitive.content
                AIModel(id = id, name = id, capabilities = listOf(ModelCapability.Text))
            },
        )
    }

    private fun assertCase(id: String) {
        val c = case(id)
        val modelId = c.getValue("modelId").let { if (it is JsonNull) null else it.jsonPrimitive.content }
        assertEquals(
            id,
            c.getValue("expect").jsonPrimitive.content,
            ProviderCredentialResolver.apiKey(provider(c.getValue("provider").jsonObject), modelId),
        )
    }

    @Test
    fun `CREDENTIAL-RESOLVE-single_key_no_model`() = assertCase("single_key_no_model")

    @Test
    fun `CREDENTIAL-RESOLVE-single_key_enabled_model`() = assertCase("single_key_enabled_model")

    @Test
    fun `CREDENTIAL-RESOLVE-single_key_unknown_model`() = assertCase("single_key_unknown_model")

    @Test
    fun `CREDENTIAL-RESOLVE-single_key_whitespace_preserved`() = assertCase("single_key_whitespace_preserved")

    @Test
    fun `CREDENTIAL-RESOLVE-empty_key_stays_empty`() = assertCase("empty_key_stays_empty")

    @Test
    fun `CREDENTIAL-RESOLVE-official_provider_same_key`() = assertCase("official_provider_same_key")

    @Test
    fun `fixture case count matches what this class covers`() {
        assertEquals(6, fixture.getValue("cases").jsonArray.size)
        assertEquals(9, fixture.getValue("multiKeyCases").jsonArray.size)
    }

    /** Multi-key fixture providers are decoded through production storage (the list and bindings both go through [ProviderMapper]); non-primary key values are filled from the fixture. */
    private fun multiKeyProvider(obj: JsonObject): Provider = with(ProviderMapper) {
        val rawKind = obj.getValue("kind").jsonPrimitive.content
        val keys = obj.getValue("relayKeys").jsonArray.map { it.jsonObject }
        val secrets = keys.associate { it.getValue("id").jsonPrimitive.content to it.getValue("apiKey").jsonPrimitive.content }
        Provider(
            id = obj.getValue("id").jsonPrimitive.content,
            kind = ProviderKind.entries.single { it.rawValue == rawKind },
            baseUrlText = obj["baseURL"]?.jsonPrimitive?.content,
        ).toEntity().copy(
            modelsJson = JsonArray(
                obj.getValue("models").jsonArray.map { JsonObject(mapOf("name" to it.jsonObject.getValue("id")) + it.jsonObject) },
            ).toString(),
            relayKeysJson = JsonArray(keys.map { JsonObject(it - "apiKey") }).toString(),
        ).toDomain(obj.getValue("apiKey").jsonPrimitive.content) { secrets[it] }
    }

    private fun assertMultiKeyCase(id: String) {
        val c = fixture.getValue("multiKeyCases").jsonArray.map { it.jsonObject }
            .single { it.getValue("id").jsonPrimitive.content == id }
        val modelId = c.getValue("modelId").let { if (it is JsonNull) null else it.jsonPrimitive.content }
        val provider = multiKeyProvider(c.getValue("provider").jsonObject)
        assertEquals(id, c.getValue("expect").jsonPrimitive.content, ProviderCredentialResolver.apiKey(provider, modelId))
    }

    @Test
    fun `CREDENTIAL-RESOLVE-multi_bound_second_key`() = assertMultiKeyCase("multi_bound_second_key")

    @Test
    fun `CREDENTIAL-RESOLVE-multi_bound_primary`() = assertMultiKeyCase("multi_bound_primary")

    @Test
    fun `CREDENTIAL-RESOLVE-multi_no_key_id_uses_primary`() = assertMultiKeyCase("multi_no_key_id_uses_primary")

    @Test
    fun `CREDENTIAL-RESOLVE-multi_dangling_key_id_uses_primary`() = assertMultiKeyCase("multi_dangling_key_id_uses_primary")

    @Test
    fun `CREDENTIAL-RESOLVE-multi_unknown_model_uses_primary`() = assertMultiKeyCase("multi_unknown_model_uses_primary")

    @Test
    fun `CREDENTIAL-RESOLVE-multi_null_model_uses_primary`() = assertMultiKeyCase("multi_null_model_uses_primary")

    @Test
    fun `CREDENTIAL-RESOLVE-multi_primary_slot_secret_ignored`() = assertMultiKeyCase("multi_primary_slot_secret_ignored")

    @Test
    fun `CREDENTIAL-RESOLVE-multi_bound_secret_not_trimmed`() = assertMultiKeyCase("multi_bound_secret_not_trimmed")

    @Test
    fun `CREDENTIAL-RESOLVE-official_provider_ignores_relay_keys`() = assertMultiKeyCase("official_provider_ignores_relay_keys")


    /** Production ChatRepository.sendMessage to production RelayTransportCoordinator with MockEngine upstream, asserting the Authorization actually sent. */
    @Test
    fun `CREDENTIAL-RESOLVE-SEND-relay_single_key_authorization`() = runTest {
        val send = fixture.getValue("sendCase").jsonObject
        assertEquals("SEND-relay_single_key_authorization", send.getValue("id").jsonPrimitive.content)
        val modelId = send.getValue("modelId").jsonPrimitive.content
        val authorizations = sendAuthorizations(provider(send.getValue("provider").jsonObject), modelId)
        assertEquals(listOf(send.getValue("expectAuthorization").jsonPrimitive.content), authorizations)
    }

    /** Multiple keys: on the same connection, a model bound to k-claude carries that key, and a model bound to the primary key carries provider.apiKey. */
    @Test
    fun `CREDENTIAL-RESOLVE-SEND-relay_bound_key_authorization`() = runTest {
        val send = fixture.getValue("multiKeySendCase").jsonObject
        assertEquals("SEND-relay_bound_key_authorization", send.getValue("id").jsonPrimitive.content)
        val provider = multiKeyProvider(send.getValue("provider").jsonObject)
        val expect = send.getValue("expect").jsonObject
        assertEquals(2, expect.size)
        for ((modelId, authorization) in expect) {
            assertEquals(modelId, listOf(authorization.jsonPrimitive.content), sendAuthorizations(provider, modelId))
        }
    }

    private suspend fun sendAuthorizations(base: Provider, modelId: String): List<String?> {
        val provider = base.copy(
            status = ProviderConnectionState.Connected,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                resolvedAPIBaseURL = base.baseUrlText,
            ),
        )
        val model = provider.models.single { it.id == modelId }
        val authorizations = mutableListOf<String?>()
        val json = Json { ignoreUnknownKeys = true }
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 2_000L })
        val coordinator = RelayTransportCoordinator(
            client = HttpClient(
                MockEngine { request ->
                    authorizations += request.headers[HttpHeaders.Authorization]
                    respond(
                        "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n",
                        HttpStatusCode.OK,
                        headersOf(HttpHeaders.ContentType, "text/event-stream"),
                    )
                },
            ),
            json = json,
            transportRegistry = TransportRegistry(json),
            negativeCache = cache,
            protocolCandidates = { _, _, _ -> listOf(RelayTransport.OpenAIChatCompletions) },
        )
        val providerRepository = mockk<ProviderRepository>(relaxed = true)
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        every { providerRepository.serviceFor(any<Provider>(), any()) } returns coordinator
        every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        coEvery { conversationRepository.updateMessage(any(), any()) } returns Unit

        ChatRepository(
            conversationRepository = conversationRepository,
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
            relayNegativeCache = cache,
        ).sendMessage(
            conversation = Conversation(
                id = "conversation-1", title = "t", providerID = provider.id,
                providerKind = ProviderKind.Relay, modelID = model.id,
            ),
            text = "hello",
            provider = provider,
            modelID = model.id,
            existingMessages = emptyList(),
            requestOptions = ChatRequestOptions(
                activeModel = model,
                capabilityEvidenceIdentity = CapabilityEvidenceIdentity(
                    partitionId = "partition",
                    connectionInstanceId = provider.id,
                    connectionGeneration = "generation",
                    credentialEpoch = "epoch",
                    providerKind = provider.kind.rawValue,
                    authMode = provider.authMode.rawValue,
                ),
            ),
            outputs = ConversationStreamingOutputs(
                streamingText = MutableStateFlow(""),
                streamingMessageId = MutableStateFlow(null),
            ),
        )

        return authorizations
    }
}
