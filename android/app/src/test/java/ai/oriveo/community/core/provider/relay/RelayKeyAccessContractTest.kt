package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKeyAccessOutcome
import ai.oriveo.community.core.model.RelayKeyAccessSignal
import ai.oriveo.community.core.model.RelayKeyStatus
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Driven by the fixture `shared/test-fixtures/relay/key-access.v1.json`: the decision pure function runs per caseId,
 * sendCases go through the production ChatRepository -> production RelayTransportCoordinator (upstream MockEngine) and assert the request count, negative-cache writes,
 * the write-back call and the result of the production write-back function.
 */
class RelayKeyAccessContractTest {

    private val fixture: JsonObject = Json.parseToJsonElement(
        generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .map { File(it, "shared/test-fixtures/relay/key-access.v1.json") }
            .first { it.isFile }
            .readText(Charsets.UTF_8),
    ).jsonObject

    private fun classifyCase(id: String): JsonObject = fixture.getValue("classifyCases").jsonArray
        .map { it.jsonObject }
        .single { it.getValue("caseId").jsonPrimitive.content == id }

    private fun outcome(raw: String) = RelayKeyAccessOutcome.entries.single { it.value == raw }

    private fun assertClassify(id: String) {
        val c = classifyCase(id)
        assertEquals(
            id,
            outcome(c.getValue("expect").jsonPrimitive.content),
            RelayKeyAccess.classify(c.getValue("status").jsonPrimitive.int, c.getValue("body").jsonPrimitive.content),
        )
    }

    @Test
    fun `KEY-ACCESS-new_api_token_model_forbidden_403`() = assertClassify("new_api_token_model_forbidden_403")

    @Test
    fun `KEY-ACCESS-one_api_token_model_forbidden_403`() = assertClassify("one_api_token_model_forbidden_403")

    @Test
    fun `KEY-ACCESS-one_hub_model_not_supported_for_token_404`() = assertClassify("one_hub_model_not_supported_for_token_404")

    @Test
    fun `KEY-ACCESS-sub2api_group_allowlist_openai_404`() = assertClassify("sub2api_group_allowlist_openai_404")

    @Test
    fun `KEY-ACCESS-sub2api_group_allowlist_anthropic_404`() = assertClassify("sub2api_group_allowlist_anthropic_404")

    @Test
    fun `KEY-ACCESS-done_hub_group_permission_403`() = assertClassify("done_hub_group_permission_403")

    @Test
    fun `KEY-ACCESS-cliproxy_unknown_model_400`() = assertClassify("cliproxy_unknown_model_400")

    @Test
    fun `KEY-ACCESS-litellm_key_model_access_denied_403`() = assertClassify("litellm_key_model_access_denied_403")

    @Test
    fun `KEY-ACCESS-openai_model_not_found_404`() = assertClassify("openai_model_not_found_404")

    @Test
    fun `KEY-ACCESS-done_hub_folded_503_is_none`() = assertClassify("done_hub_folded_503_is_none")

    @Test
    fun `KEY-ACCESS-new_api_no_channel_503_is_none`() = assertClassify("new_api_no_channel_503_is_none")

    @Test
    fun `KEY-ACCESS-capability_rejection_400_is_none`() = assertClassify("capability_rejection_400_is_none")

    @Test
    fun `KEY-ACCESS-route_not_found_404_is_none`() = assertClassify("route_not_found_404_is_none")

    @Test
    fun `KEY-ACCESS-anthropic_route_not_found_404_is_none`() = assertClassify("anthropic_route_not_found_404_is_none")

    @Test
    fun `KEY-ACCESS-sub2api_messages_dispatch_403_is_none`() = assertClassify("sub2api_messages_dispatch_403_is_none")

    @Test
    fun `KEY-ACCESS-litellm_route_not_allowed_403_is_none`() = assertClassify("litellm_route_not_allowed_403_is_none")

    @Test
    fun `KEY-ACCESS-invalid_key_401`() = assertClassify("invalid_key_401")

    @Test
    fun `KEY-ACCESS-invalid_key_plain_string_401`() = assertClassify("invalid_key_plain_string_401")

    @Test
    fun `KEY-ACCESS-sub2api_key_expired_403`() = assertClassify("sub2api_key_expired_403")

    @Test
    fun `KEY-ACCESS-sub2api_insufficient_balance_403`() = assertClassify("sub2api_insufficient_balance_403")

    @Test
    fun `KEY-ACCESS-new_api_insufficient_user_quota_403`() = assertClassify("new_api_insufficient_user_quota_403")

    @Test
    fun `KEY-ACCESS-openrouter_payment_required_402`() = assertClassify("openrouter_payment_required_402")

    @Test
    fun `KEY-ACCESS-quota_exhausted_429`() = assertClassify("quota_exhausted_429")

    @Test
    fun `KEY-ACCESS-litellm_budget_exceeded_422_is_none`() = assertClassify("litellm_budget_exceeded_422_is_none")

    @Test
    fun `KEY-ACCESS-official_claude_cli_gate_403_is_none`() = assertClassify("official_claude_cli_gate_403_is_none")

    @Test
    fun `KEY-ACCESS-plain_403_without_signal_is_none`() = assertClassify("plain_403_without_signal_is_none")

    @Test
    fun `KEY-ACCESS-server_error_500_is_none`() = assertClassify("server_error_500_is_none")

    @Test
    fun `KEY-ACCESS-empty_body_404_is_none`() = assertClassify("empty_body_404_is_none")

    @Test
    fun `fixture vocabulary and case count match what this class covers`() {
        assertEquals(
            fixture.getValue("outcomes").jsonArray.map { it.jsonPrimitive.content },
            RelayKeyAccessOutcome.entries.map { it.value },
        )
        assertEquals(28, fixture.getValue("classifyCases").jsonArray.size)
        assertEquals(4, fixture.getValue("sendCases").jsonArray.size)
        assertEquals(11, fixture.getValue("generationCases").jsonObject.getValue("cases").jsonArray.size)
    }

    // ── generationCases: key state of generation requests, pure function ──

    private fun assertGeneration(id: String) {
        val c = fixture.getValue("generationCases").jsonObject.getValue("cases").jsonArray
            .map { it.jsonObject }
            .single { it.getValue("caseId").jsonPrimitive.content == id }
        val status = c.getValue("status").let { if (it is JsonNull) null else it.jsonPrimitive.int }
        val actual = RelayKeyAccess.generationStatus(status, c.getValue("body").jsonPrimitive.content)
        val expect = c.getValue("expect")
        if (expect is JsonNull) {
            assertNull(id, actual)
            return
        }
        assertEquals(id, expect.jsonPrimitive.content, actual?.state)
        // Invalid / restricted carry the HTTP status code (the "last" row on the key page); normal carries none, same shape as ok in catalog fetch, avoiding back-and-forth rewrites.
        assertEquals(id, if (actual?.state == "ok") null else status, actual?.httpStatus)
    }

    @Test
    fun `KEY-ACCESS-GEN-success_200_is_ok`() = assertGeneration("success_200_is_ok")

    @Test
    fun `KEY-ACCESS-GEN-invalid_key_401_is_invalid`() = assertGeneration("invalid_key_401_is_invalid")

    @Test
    fun `KEY-ACCESS-GEN-insufficient_balance_403_is_limited`() = assertGeneration("insufficient_balance_403_is_limited")

    @Test
    fun `KEY-ACCESS-GEN-quota_exhausted_429_is_limited`() = assertGeneration("quota_exhausted_429_is_limited")

    @Test
    fun `KEY-ACCESS-GEN-model_denied_404_leaves_key`() = assertGeneration("model_denied_404_leaves_key")

    @Test
    fun `KEY-ACCESS-GEN-client_gate_403_leaves_key`() = assertGeneration("client_gate_403_leaves_key")

    @Test
    fun `KEY-ACCESS-GEN-plain_403_leaves_key`() = assertGeneration("plain_403_leaves_key")

    @Test
    fun `KEY-ACCESS-GEN-route_404_leaves_key`() = assertGeneration("route_404_leaves_key")

    @Test
    fun `KEY-ACCESS-GEN-capability_400_leaves_key`() = assertGeneration("capability_400_leaves_key")

    @Test
    fun `KEY-ACCESS-GEN-server_503_leaves_key`() = assertGeneration("server_503_leaves_key")

    @Test
    fun `KEY-ACCESS-GEN-network_leaves_key`() = assertGeneration("network_leaves_key")

    /** The decision is computed at the production error mapping where the raw response body is available and attached to the error object (detail is a redacted snippet, not parsed afterwards). */
    @Test
    fun `KEY-ACCESS production error mapping attaches the decision`() {
        val c = classifyCase("sub2api_group_allowlist_openai_404")
        val mapped = ai.oriveo.community.core.provider.RelayErrorMapper.mapOrDefault(
            c.getValue("status").jsonPrimitive.int,
            c.getValue("body").jsonPrimitive.content,
        )
        assertEquals(RelayKeyAccessSignal(404, RelayKeyAccessOutcome.ModelAccessDenied), mapped.relayKeyAccess)
        assertTrue(RelayKeyAccess.isModelAccessDenied(mapped))
        val invalid = ai.oriveo.community.core.provider.RelayErrorMapper.mapOrDefault(401, "{\"error\":\"Invalid API key\"}")
        assertEquals(RelayKeyAccessOutcome.KeyInvalid, RelayKeyAccess.signalOf(invalid)?.outcome)
    }

    private fun sendCase(id: String): JsonObject = fixture.getValue("sendCases").jsonArray
        .map { it.jsonObject }
        .single { it.getValue("caseId").jsonPrimitive.content == id }

    @Test
    fun `KEY-ACCESS-SEND-denied_404_skips_negative_cache_and_protocol_fallback`() = runTest {
        val c = sendCase("SEND-denied_404_skips_negative_cache_and_protocol_fallback")
        val expect = c.getValue("expect").jsonObject
        val harness = SendHarness(c.getValue("boundKeyID").jsonPrimitive.content, c.getValue("status").jsonPrimitive.int, c.getValue("body").jsonPrimitive.content)
        val failed = harness.send()

        assertEquals(expect.getValue("requestsSent").jsonPrimitive.int, harness.authorizations.size)
        assertEquals("the request is sent with the bound key", listOf("Bearer sk-claude"), harness.authorizations)
        assertEquals(expect.getValue("negativeCacheWrites").jsonPrimitive.int, harness.cache.entries().size)
        coVerify(exactly = 0) { harness.providerRepository.recordRelayProtocolFallback(any(), any(), any(), any()) }
        assertEquals(ChatMessageState.Failed, failed.state)
        assertTrue(failed.errorDetail != ChatRepository.RELAY_IMAGE_UNSUPPORTED_DETAIL)

        val written = harness.writtenProvider()
        assertEquals(expect.getValue("deniedKeyID").jsonPrimitive.content, written.models.single { it.id == MODEL }.relayDeniedKeyID)
        assertEquals("no-access does not touch key state", harness.provider.relayKeys, written.relayKeys)
    }

    @Test
    fun `KEY-ACCESS-SEND-invalid_401_marks_key_status`() = runTest {
        val c = sendCase("SEND-invalid_401_marks_key_status")
        val expect = c.getValue("expect").jsonObject
        val boundKeyID = c.getValue("boundKeyID").jsonPrimitive.content
        val harness = SendHarness(boundKeyID, c.getValue("status").jsonPrimitive.int, c.getValue("body").jsonPrimitive.content)
        val failed = harness.send()

        assertEquals(ChatMessageState.Failed, failed.state)
        assertEquals(expect.getValue("negativeCacheWrites").jsonPrimitive.int, harness.cache.entries().size)
        val written = harness.writtenProvider()
        val status = written.relayKeys!!.single { it.id == boundKeyID }.status!!
        assertEquals(expect.getValue("keyStatus").jsonPrimitive.content, status.state)
        assertEquals(expect.getValue("keyHTTPStatus").jsonPrimitive.int, status.httpStatus)
        assertEquals(NOW, status.checkedAt)
        assertTrue(expect.getValue("deniedKeyID") is JsonNull)
        assertNull(written.models.single { it.id == MODEL }.relayDeniedKeyID)
        assertNull("primary key state is untouched", written.relayKeys!!.first().status)
    }

    /** Single-key connection: no-access is also recorded on the model (id = initial). */
    @Test
    fun `KEY-ACCESS-SEND single key records denial as initial`() = runTest {
        val denied = SendHarness(null, 404, sendCase("SEND-denied_404_skips_negative_cache_and_protocol_fallback").getValue("body").jsonPrimitive.content)
        denied.send()
        assertEquals(1, denied.authorizations.size)
        assertEquals("initial", denied.writtenProvider().models.single { it.id == MODEL }.relayDeniedKeyID)
    }

    /** Single-key connection send succeeds: the primary key state is recorded as ok and the list is materialized into one entry. */
    @Test
    fun `KEY-ACCESS-SEND-delivered_single_key_materializes_ok`() = runTest {
        val c = sendCase("SEND-delivered_single_key_materializes_ok")
        val expect = c.getValue("expect").jsonObject
        val harness = SendHarness(null, c.getValue("status").jsonPrimitive.int, CHAT_OK)
        assertEquals(ChatMessageState.Delivered, harness.send().state)
        assertEquals(expect.getValue("negativeCacheWrites").jsonPrimitive.int, harness.cache.entries().size)
        val keyID = slot<String>()
        coVerify(exactly = 1) { harness.providerRepository.recordRelayKeyAccessSuccess(PROVIDER_ID, MODEL, capture(keyID), harness.provider) }
        assertEquals(c.getValue("boundKeyID").jsonPrimitive.content, keyID.captured)
        val written = RelayKeyAccess.applyingSuccess(harness.provider, MODEL, keyID.captured, NOW)
        assertSingleEntryList(expect, written)
        assertEquals(expect.getValue("keyStatus").jsonPrimitive.content, written.relayKeys!!.single().status?.state)
        assertEquals(NOW, written.relayKeys!!.single().status?.checkedAt)
    }

    /** Single-key connection 401: the primary key is recorded invalid and the list is materialized into one entry. */
    @Test
    fun `KEY-ACCESS-SEND-invalid_401_single_key_materializes`() = runTest {
        val c = sendCase("SEND-invalid_401_single_key_materializes")
        val expect = c.getValue("expect").jsonObject
        val harness = SendHarness(null, c.getValue("status").jsonPrimitive.int, c.getValue("body").jsonPrimitive.content)
        assertEquals(ChatMessageState.Failed, harness.send().state)
        assertEquals(expect.getValue("negativeCacheWrites").jsonPrimitive.int, harness.cache.entries().size)
        val written = harness.writtenProvider()
        assertSingleEntryList(expect, written)
        val status = written.relayKeys!!.single().status!!
        assertEquals(expect.getValue("keyStatus").jsonPrimitive.content, status.state)
        assertEquals(expect.getValue("keyHTTPStatus").jsonPrimitive.int, status.httpStatus)
    }

    private fun assertSingleEntryList(expect: JsonObject, written: Provider) {
        val keys = written.relayKeys
        assertEquals(
            expect.getValue("relayKeys").jsonArray.map { it.jsonObject.getValue("id").jsonPrimitive.content to it.jsonObject.getValue("apiKey").jsonPrimitive.content },
            keys?.map { it.id to it.apiKey },
        )
        assertTrue(expect.getValue("deniedKeyID") is JsonNull)
        val model = written.models.single { it.id == MODEL }
        assertNull("no model-level key field written", model.relayKeyID)
        assertNull(model.relayDeniedKeyID)
        assertNull(model.relayListedByKeyIDs)
    }

    /** A successful send with the same key clears the no-access mark and writes ok for that key; with a single key and no mark, storage is not touched. */
    @Test
    fun `KEY-ACCESS-SEND success clears denial for the same key and marks it ok`() = runTest {
        val harness = SendHarness("k-claude", 200, CHAT_OK, deniedKeyID = "k-claude")
        val delivered = harness.send()
        assertEquals(ChatMessageState.Delivered, delivered.state)
        val keyID = slot<String>()
        coVerify(exactly = 1) { harness.providerRepository.recordRelayKeyAccessSuccess(PROVIDER_ID, MODEL, capture(keyID), harness.provider) }
        val written = RelayKeyAccess.applyingSuccess(harness.provider, MODEL, keyID.captured, NOW)
        assertNull(written.models.single { it.id == MODEL }.relayDeniedKeyID)
        assertEquals("ok", written.relayKeys!!.single { it.id == "k-claude" }.status?.state)

        // A single-entry list that is already ok: nothing to change, storage is not touched.
        val single = SendHarness(null, 200, CHAT_OK, primaryStatus = RelayKeyStatus("ok"))
        single.send()
        coVerify(exactly = 0) { single.providerRepository.recordRelayKeyAccessSuccess(any(), any(), any(), any()) }
    }

    /** A successful send clearing the model's "unreachable" is not short-circuited by successChanges: it is also cleared when a single key has nothing to write. */
    @Test
    fun `RL2-PROBESTATE-04 delivered send clears that model's unreachable even when nothing is written back`() = runTest {
        val single = SendHarness(null, 200, CHAT_OK, primaryStatus = RelayKeyStatus("ok"))
        assertEquals(ChatMessageState.Delivered, single.send().state)
        io.mockk.verify(exactly = 1) { single.providerRepository.clearRelayModelProbeFailure(PROVIDER_ID, MODEL) }
        coVerify(exactly = 0) { single.providerRepository.recordRelayKeyAccessSuccess(any(), any(), any(), any()) }

        val failed = SendHarness("k-claude", 401, "{\"error\":{\"message\":\"Invalid API key\"}}")
        failed.send()
        io.mockk.verify(exactly = 0) { failed.providerRepository.clearRelayModelProbeFailure(any(), any()) }
    }

    /** No-access does not use the file-to-text fallback: after the first rejection with a native file it does not resend as text, and does not record a file negative cache. */
    @Test
    fun `KEY-ACCESS model access denied skips the native file text fallback`() = runTest {
        val denied = ai.oriveo.community.core.provider.RelayErrorMapper.mapOrDefault(
            404,
            sendCase("SEND-denied_404_skips_negative_cache_and_protocol_fallback").getValue("body").jsonPrimitive.content,
        )
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 2_000L })
        val attempts = mutableListOf<Boolean>()
        val thrown = runCatching {
            ai.oriveo.community.core.attachments.NativeFileFallback.run<Unit>(
                lane = ai.oriveo.community.core.attachments.NativeFileFallback.Lane("c-file", ProviderKind.Relay, "openai_responses"),
                recoverable = { true },
                relayMemory = ai.oriveo.community.core.attachments.NativeFileFallback.RelayMemory(
                    cache,
                    RelayNegativeCache.Key("c-file", MODEL, "openai_responses"),
                ),
            ) { textOnly ->
                attempts += textOnly
                throw denied
            }
        }.exceptionOrNull()
        assertEquals(denied, thrown)
        assertEquals(listOf(false), attempts)
        assertTrue(cache.entries().isEmpty())
    }

    /** Production ChatRepository + production RelayTransportCoordinator; [boundKeyID] null = single-key connection. */
    private inner class SendHarness(
        boundKeyID: String?,
        private val status: Int,
        private val body: String,
        deniedKeyID: String? = null,
        primaryStatus: RelayKeyStatus? = null,
    ) {
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 2_000L })
        val authorizations = mutableListOf<String?>()
        private val model = AIModel(
            id = MODEL,
            name = MODEL,
            capabilities = listOf(ModelCapability.Text),
            relayKeyID = boundKeyID,
            relayDeniedKeyID = deniedKeyID,
        )
        val provider = Provider(
            id = PROVIDER_ID,
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            apiKey = "sk-primary",
            baseUrlText = "https://relay.example.com/v1",
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                resolvedAPIBaseURL = "https://relay.example.com/v1",
            ),
            relayKeys = boundKeyID?.let { listOf(RelayKey(id = "initial"), RelayKey(id = it, apiKey = "sk-claude")) }
                ?: primaryStatus?.let { listOf(RelayKey(id = "initial", status = it)) },
            models = listOf(model),
        )
        val providerRepository = mockk<ProviderRepository>(relaxed = true)
        private val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        private val updates = mutableListOf<ChatMessage>()
        private val json = Json { ignoreUnknownKeys = true }
        private val coordinator = RelayTransportCoordinator(
            client = HttpClient(
                MockEngine { request ->
                    authorizations += request.headers[HttpHeaders.Authorization]
                    if (status == 200) {
                        respond(body, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
                    } else {
                        respond(body, HttpStatusCode.fromValue(status), headersOf(HttpHeaders.ContentType, "application/json"))
                    }
                },
            ),
            json = json,
            transportRegistry = TransportRegistry(json),
            negativeCache = cache,
            // With a second candidate: without a decision a 404 would switch transport and resend (proving "no transport-level fallback").
            protocolCandidates = { _, _, _ -> listOf(RelayTransport.OpenAIChatCompletions, RelayTransport.OpenAIResponses) },
        )

        suspend fun send(): ChatMessage {
            every { providerRepository.serviceFor(any<Provider>(), any()) } returns coordinator
            every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
            coEvery { conversationRepository.updateMessage(any(), capture(updates)) } returns Unit
            ChatRepository(
                conversationRepository = conversationRepository,
                providerRepository = providerRepository,
                attachmentStore = mockk<AttachmentStore>(relaxed = true),
                relayNegativeCache = cache,
            ).sendMessage(
                conversation = Conversation(
                    id = "conversation-1", title = "t", providerID = provider.id,
                    providerKind = ProviderKind.Relay, modelID = MODEL,
                ),
                text = "what is this",
                provider = provider,
                modelID = MODEL,
                existingMessages = emptyList(),
                attachments = listOf(
                    Attachment(id = "img", kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png", base64Data = IMAGE_BASE64),
                ),
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
            return updates.last()
        }

        /** Takes the write-back parameters the production send path hands to the repository and applies them to the connection through the production write-back function. */
        fun writtenProvider(): Provider {
            val modelID = slot<String>()
            val keyID = slot<String>()
            val signal = slot<RelayKeyAccessSignal>()
            coVerify(exactly = 1) {
                // Carries the connection at initiation time, which the repository uses to verify identity on write-back.
                providerRepository.recordRelayKeyAccess(PROVIDER_ID, capture(modelID), capture(keyID), capture(signal), provider)
            }
            return RelayKeyAccess.applyingFailure(provider, modelID.captured, keyID.captured, signal.captured, NOW)
        }
    }

    private companion object {
        const val PROVIDER_ID = "c1"
        const val MODEL = "gpt-5"
        const val NOW = 9_000L
        const val IMAGE_BASE64 = "iVBORw0KGgo="
        const val CHAT_OK = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
    }
}
