package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.remote.RelayModelFamilyLookup
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.model.displayedForUi
import ai.oriveo.community.core.model.resolvedForRequest
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.core.provider.RelayWebPreferenceIdentity
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import java.io.File
import java.util.Collections
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * One relay web send (fixture `web-probe.v1.json` chatCases + scenario, same-named RL2-WEBPROBE-SEND-<caseId> on all three platforms).
 * Goes through the production [ai.oriveo.community.core.data.repository.ChatRepository.sendMessage] -> the production [RelayService] (builder, protocol fallback, resend without the fragment)
 * against a fake upstream; the protocol-fallback write-back goes through the production [ProviderRepository] (the DAO keeps only minimal reads and writes), and fragments / records / preferences use the production stores (in-memory backend).
 */
class RelayWebSendContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val fixture: JsonObject by lazy { readJson("shared/test-fixtures/relay/web-probe.v1.json") }
    private val evidence: Map<String, JsonObject> by lazy {
        fixture.getValue("evidenceCases").jsonArray.map { it.jsonObject }.associateBy { it.string("caseId") }
    }

    private val familiesField = RelayModelFamilyLookup::class.java.getDeclaredField("families").apply { isAccessible = true }
    private var previousFamilies: Any? = null

    @Before
    fun setUp() {
        previousFamilies = familiesField.get(RelayModelFamilyLookup.shared)
        // An unverified Claude family: the first send on an auto connection is Messages, with candidates Messages -> Chat.
        familiesField.set(RelayModelFamilyLookup.shared, mapOf(MODEL_ID to "anthropic"))
    }

    @After
    fun tearDown() {
        familiesField.set(RelayModelFamilyLookup.shared, previousFamilies)
    }

    @Test
    fun `RL2-WEBPROBE-SEND fixture caseIds map one-to-one to the per-case tests here`() {
        assertEquals(SEND_CASE_IDS, chatCases().map { it.string("caseId") })
    }

    @Test fun `RL2-WEBPROBE-SEND-fallback_carries_target_template`() = sendCase("fallback_carries_target_template")
    @Test fun `RL2-WEBPROBE-SEND-fallback_carries_target_saved`() = sendCase("fallback_carries_target_saved")
    @Test fun `RL2-WEBPROBE-SEND-fallback_target_rejected_skips_with_notice`() = sendCase("fallback_target_rejected_skips_with_notice")
    @Test fun `RL2-WEBPROBE-SEND-fallback_with_citation_writes_searched`() = sendCase("fallback_with_citation_writes_searched")
    @Test fun `RL2-WEBPROBE-SEND-fragment_400_resends_without_fragment`() = sendCase("fragment_400_resends_without_fragment")
    @Test fun `RL2-WEBPROBE-SEND-fragment_400_resend_also_fails`() = sendCase("fragment_400_resend_also_fails")
    @Test fun `RL2-WEBPROBE-SEND-access_denied_never_resends`() = sendCase("access_denied_never_resends")
    @Test fun `RL2-WEBPROBE-SEND-known_rejected_skips_with_notice`() = sendCase("known_rejected_skips_with_notice")
    @Test fun `RL2-WEBPROBE-SEND-user_override_true_sends_despite_rejected`() = sendCase("user_override_true_sends_despite_rejected")
    @Test fun `RL2-WEBPROBE-SEND-web_off_sends_nothing_no_notice`() = sendCase("web_off_sends_nothing_no_notice")

    private fun sendCase(caseId: String) {
        val case = chatCases().single { it.string("caseId") == caseId }
        val message = "RL2-WEBPROBE-SEND-$caseId"
        val expect = case.getValue("expect").jsonObject
        val userOverride = (case.getValue("userOverride") as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content?.toBooleanStrict()
        val harness = SendHarness(
            userOverride = userOverride,
            saved = case.getValue("savedFragments").jsonArray.map { transportOf(it.jsonPrimitive.content) },
            rejected = case.getValue("records").jsonObject
                .filterValues { it.jsonPrimitive.content == "rejected" }.keys.map(::transportOf),
        )
        assertEquals(
            "$message precondition: first-send protocol",
            transportOf(case.string("firstTransport")),
            RelayFirstSendTransport.resolve(harness.current(), harness.current().models.single()),
        )
        val expectedAttempts = expect.getValue("attempts").jsonArray.map { it.jsonObject }
        case.getValue("attempts").jsonArray.map { it.jsonObject }.forEachIndexed { index, attempt ->
            val transport = expectedAttempts.getOrNull(index)?.string("transport")?.let(::transportOf)
                ?: RelayTransport.OpenAIChatCompletions
            harness.enqueue(replyFor(attempt, transport))
        }
        val webOn = case.string("webOn").toBooleanStrict()
        harness.send(webOn)

        val attempts = harness.chatRequests()
        assertEquals(
            "$message attempts ${attempts.map { it.path }}",
            expectedAttempts.map { it.string("transport") to it.nullableString("fragment") },
            attempts.map { it.transport.value to harness.fragmentKind(it) },
        )
        assertEquals("$message replyNotice", expect.nullableString("replyNotice"), harness.replyNotice())
        assertEquals(
            "$message recordWrites",
            expect.getValue("recordWrites").jsonArray.map { it.jsonObject }
                .map { Triple(it.string("transport"), it.string("result"), it.string("source")) },
            harness.recordWrites(),
        )
        val sendFails = expect["sendFails"]?.jsonPrimitive?.content?.toBooleanStrict() ?: false
        assertEquals("$message sendFails", sendFails, harness.assistantState() == ChatMessageState.Failed)
        if (!sendFails) assertEquals("$message delivered", ChatMessageState.Delivered, harness.assistantState())
        val panel = expect.getValue("panelAfter").jsonObject
        val row = harness.panelRow(if (webOn) CapabilityWebPreference.Automatic else CapabilityWebPreference.Off)
        assertEquals("$message panelAfter row", panel.string("row"), if (row.enabled) "toggle" else "toggleDisabled")
        assertEquals("$message panelAfter isOn", panel.string("isOn").toBooleanStrict(), row.isOn)
    }

    /**
     * The reported scenario (chatCases.scenario): a new conversation, an auto connection, an unverified Claude family; turn on web search in the model options before sending -> first send Messages 404 ->
     * fall back to Chat and deliver, the model protocol is written as Chat -> the switch is still on in the panel after sending and after reopening the conversation, and the second first-send goes out as Chat with the template.
     * The panel and preferences use the same production entry points as the composer / send coordinator: identity [ModelControlRuntimeIdentityResolver], web row
     * [ModelOptionsPanelInput.relayWeb] + [ModelOptionCapabilityShape.resolve], draft write / migration / read [CapabilityPreferenceStore].
     */
    @Test
    fun `RL2-WEBPROBE-SEND-first_chat_toggle_survives`() {
        val scenario = fixture.getValue("chatCases").jsonObject.getValue("scenario").jsonObject.getValue("expect").jsonObject
        val harness = SendHarness(userOverride = null, saved = emptyList(), rejected = emptyList())
        toggleSurvives(harness, scenario, firstAttemptTransport = RelayTransport.AnthropicMessages)
    }

    /**
     * Another entry to the same root cause: a model already lazily verified as Messages (reachable), with web search on; after Messages 404 falls back to Chat
     * the model protocol is written as Chat (observed) -- the switch must not turn off because of that.
     */
    @Test
    fun `RL2-WEBPROBE-SEND-first_chat_toggle_survives reachable model`() {
        val scenario = fixture.getValue("chatCases").jsonObject.getValue("scenario").jsonObject.getValue("expect").jsonObject
        val harness = SendHarness(
            userOverride = null,
            saved = emptyList(),
            rejected = emptyList(),
            modelTransport = RelayTransport.AnthropicMessages,
        )
        toggleSurvives(harness, scenario, firstAttemptTransport = RelayTransport.AnthropicMessages)
    }

    private fun toggleSurvives(harness: SendHarness, scenario: JsonObject, firstAttemptTransport: RelayTransport) {
        val metadata = MetadataClient()
        var backing: String? = null
        var drafts: String? = null
        fun store() = CapabilityPreferenceStore(read = { backing }, write = { backing = it }, readDrafts = { drafts }, writeDrafts = { drafts = it })
        val draftId = "draft-session"
        val conversationId = CONVERSATION_ID

        // Before sending: the composer resolves the identity, the panel web row is an operable switch, and the user turns it on -> the draft layer is written.
        val before = harness.current()
        val beforeModel = before.models.single()
        val identity = ModelControlRuntimeIdentityResolver.resolve(before, beforeModel, metadata)
        assertNotNull("the identity is resolvable before sending (the panel can write)", identity)
        // The web switch lives under the fixed identity, the same one the composer writes.
        val webIdentity = RelayWebPreferenceIdentity.resolve(before, beforeModel)!!
        val webDefault = RelayWebChat.of(before, beforeModel, harness.fragments, harness.records)?.defaultPreference
        val rowBefore = webRow(before, beforeModel, harness, identity != null, CapabilityWebPreference.Off)
        assertTrue("the web row is a switch before sending: $rowBefore", rowBefore is ModelOptionCapabilityShape.RelayWebToggle)
        store().setDraftConversation(
            CapabilityPreferenceValues(web = CapabilityWebPreference.Automatic),
            before.id, webIdentity.canonicalModelId, draftId, webIdentity.storageIdentity,
        )

        // Send: when the conversation is created the draft moves to the conversation layer (ChatSendCommandCoordinator), and the send coordinator resolves web search under the same identity.
        store().migrateDraftConversation(before.id, webIdentity.canonicalModelId, draftId, conversationId, webIdentity.storageIdentity)
        val sentWeb = store().resolvedForRequest(
            providerID = before.id,
            providerKind = before.kind,
            modelID = webIdentity.canonicalModelId,
            conversationID = conversationId,
            skillID = null,
            transportIdentity = webIdentity.storageIdentity,
            webDefault = webDefault,
        ).web
        assertTrue("web search is on at the first send", sentWeb != CapabilityWebPreference.Off)
        harness.enqueue(Reply(404, "application/json", """{"error":{"message":"Invalid URL (POST /v1/messages)"}}"""))
        harness.enqueue(replyFor(JsonObject(mapOf("status" to JsonPrimitive(200), "sse" to JsonPrimitive("plain_text"))), RelayTransport.OpenAIChatCompletions))
        harness.send(webOn = true)
        assertEquals(
            "first-chat attempts",
            listOf(firstAttemptTransport.value to "template", RelayTransport.OpenAIChatCompletions.value to "template"),
            harness.chatRequests().map { it.transport.value to harness.fragmentKind(it) },
        )
        val after = harness.current()
        val afterModel = after.models.single()
        assertEquals("the model protocol is written as Chat after the fallback", RelayTransport.OpenAIChatCompletions, afterModel.relayTransport)

        // Open the panel after sending, and reopen the conversation (a new store instance reads the same backend): the switch is still on.
        val panel = scenario.getValue("panelAfter").jsonObject
        repeat(2) { reopen ->
            assertNotNull("the identity is resolvable after sending", ModelControlRuntimeIdentityResolver.resolve(after, afterModel, metadata))
            val afterWebIdentity = RelayWebPreferenceIdentity.resolve(after, afterModel)!!
            assertEquals("the web identity does not change with the protocol", webIdentity, afterWebIdentity)
            val displayed = store().displayedForUi(
                providerID = after.id,
                providerKind = after.kind,
                modelID = afterWebIdentity.canonicalModelId,
                conversationID = conversationId,
                skillID = null,
                transportIdentity = afterWebIdentity.storageIdentity,
                webDefault = RelayWebChat.of(after, afterModel, harness.fragments, harness.records)?.defaultPreference,
            ).web
            val row = webRow(after, afterModel, harness, true, displayed)
            val toggle = row as? ModelOptionCapabilityShape.RelayWebToggle ?: error("reopen=$reopen the web row is not a switch after sending: $row")
            assertEquals("reopen=$reopen row", panel.string("row"), if (toggle.enabled) "toggle" else "toggleDisabled")
            assertEquals("reopen=$reopen isOn (preference=$displayed)", panel.string("isOn").toBooleanStrict(), toggle.isOn)
        }

        // Second send: the first send goes out as Chat with the template.
        val secondIdentity = RelayWebPreferenceIdentity.resolve(after, afterModel)!!
        val secondWeb = store().resolvedForRequest(
            providerID = after.id,
            providerKind = after.kind,
            modelID = secondIdentity.canonicalModelId,
            conversationID = conversationId,
            skillID = null,
            transportIdentity = secondIdentity.storageIdentity,
            webDefault = RelayWebChat.of(after, afterModel, harness.fragments, harness.records)?.defaultPreference,
        ).web
        harness.reset()
        harness.enqueue(replyFor(JsonObject(mapOf("status" to JsonPrimitive(200), "sse" to JsonPrimitive("plain_text"))), RelayTransport.OpenAIChatCompletions))
        harness.send(webOn = secondWeb != CapabilityWebPreference.Off)
        val second = scenario.getValue("secondSendFirstAttempt").jsonObject
        assertEquals(
            "second first-send",
            second.string("transport") to second.string("fragment"),
            harness.chatRequests().first().let { it.transport.value to harness.fragmentKind(it) },
        )
    }

    private fun webRow(
        provider: Provider,
        model: AIModel,
        harness: SendHarness,
        writable: Boolean,
        preference: CapabilityWebPreference,
    ): ModelOptionCapabilityShape = ModelOptionCapabilityShape.resolve(
        ModelOptionCapabilityShape.Input(
            capability = ModelOptionCapabilityShape.Capability.Web,
            presentation = CapabilityControlPresentation.Unknown,
            availableIntents = emptyList(),
            selectedIntent = ModelOptionsPanelInput.webIntent(preference),
            connection = ModelOptionCapabilityShape.ConnectionCategory.CustomLLM,
            isWritable = writable,
            protocolUndecided = ModelOptionsPanelInput.webProtocolUndecided(provider, model),
            relayWeb = ModelOptionsPanelInput.relayWeb(provider, model, harness.fragments, harness.records, preference),
        ),
    )

    // -- upstream replies --

    private fun replyFor(attempt: JsonObject, transport: RelayTransport): Reply {
        val status = attempt.getValue("status").jsonPrimitive.content.toInt()
        attempt["classification"]?.jsonPrimitive?.content?.let { classification ->
            check(classification == "model_access_denied") { classification }
            return Reply(status, "application/json", """{"error":{"code":"key_model_access_denied","message":"no access to this model"}}""")
        }
        attempt["sse"]?.jsonPrimitive?.content?.let { sse ->
            val sample = when (sse) {
                "plain_text" -> when (transport) {
                    RelayTransport.OpenAIChatCompletions -> "chat_text_only_silent"
                    RelayTransport.AnthropicMessages -> "messages_text_only_silent"
                    RelayTransport.OpenAIResponses -> "responses_text_only_silent"
                    RelayTransport.GeminiGenerateContent -> "gemini_text_only_silent"
                    else -> error("no plain text sample for $transport")
                }
                "chat_url_citation" -> "chat_url_citation_searched"
                else -> error("unknown sse $sse")
            }
            val lines = evidence.getValue(sample).getValue("sse").jsonArray.map { it.jsonPrimitive.content }
            return Reply(status, "text/event-stream", (lines + "").joinToString("\n"))
        }
        return Reply(status, "application/json", attempt.getValue("body").jsonPrimitive.content)
    }

    private class Reply(val status: Int, val contentType: String, val body: String)

    private class SentRequest(val path: String, val text: String) {
        val body: JsonObject by lazy { Json.parseToJsonElement(text).jsonObject }
        val transport: RelayTransport
            get() = when {
                path.endsWith("/messages") -> RelayTransport.AnthropicMessages
                path.endsWith("/chat/completions") -> RelayTransport.OpenAIChatCompletions
                path.endsWith("/responses") -> RelayTransport.OpenAIResponses
                path.contains("GenerateContent") -> RelayTransport.GeminiGenerateContent
                else -> error("not a chat request: $path")
            }
        val isChat: Boolean
            get() = runCatching { transport }.isSuccess
    }

    /** Production ChatRepository + production ProviderRepository (protocol-fallback write-back) + production RelayService against a fake upstream. */
    private inner class SendHarness(
        userOverride: Boolean?,
        saved: List<RelayTransport>,
        rejected: List<RelayTransport>,
        modelTransport: RelayTransport? = null,
    ) {
        private val sent: MutableList<SentRequest> = Collections.synchronizedList(mutableListOf())
        private val replies = ArrayDeque<Reply>()
        private val messages: MutableList<ChatMessage> = Collections.synchronizedList(mutableListOf())
        val notices = RelayWebReplyNotices()
        val records = RelayWebProbeRecordStore(RelayWebProbeRecordStore.MemoryStore()) { NOW }
        private val savedFragments: Map<RelayTransport, JsonObject> = saved.associateWith { savedFragmentFor(it) }
        val fragments = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore()).also { store ->
            if (savedFragments.isNotEmpty()) store.replace(CONNECTION_ID, savedFragments)
        }

        private val initial: Provider = AIModel(
            id = MODEL_ID,
            name = MODEL_ID,
            relayCapabilityOverrides = userOverride?.let { RelayCapabilityOverrides(web = it) },
            relayTransport = modelTransport,
            relayTransportSource = modelTransport?.let { RelayTransportSource.Reachable },
        ).let { model ->
            Provider(
                id = CONNECTION_ID,
                kind = ProviderKind.Relay,
                status = ai.oriveo.community.core.model.ProviderConnectionState.Connected,
                apiKey = "sk-test",
                baseUrlText = "https://relay.example.com",
                relayKind = RelayKind.OpenAICompatible,
                relayRequested = RelayRequestedConfig(transport = RelayTransport.Auto),
                models = listOf(model.copy(isDefault = true)),
                catalogModels = listOf(model),
            )
        }

        init {
            rejected.forEach { transport ->
                records.record(
                    RelayWebProbeRecordStore.Key(CONNECTION_ID, MODEL_ID, transport.value),
                    RelayWebProbeRecord(RelayWebProbeResult.Rejected, RelayWebProbeSource.Tested, SEEDED_AT, RelayWebProbe.fragmentHash(effectiveFor(transport))),
                )
            }
        }

        @Volatile var stored: ai.oriveo.community.core.data.entity.ProviderEntity? = with(ProviderMapper) { initial.toEntity(ACCOUNT_ID) }

        fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain("sk-test") }

        fun enqueue(reply: Reply) = synchronized(replies) { replies.addLast(reply) }

        fun reset() {
            sent.clear()
            messages.clear()
        }

        fun chatRequests(): List<SentRequest> = sent.filter { it.isChat }

        private fun savedFragmentFor(transport: RelayTransport): JsonObject = when (transport) {
            RelayTransport.OpenAIChatCompletions ->
                JsonObject(mapOf("web_search_options" to JsonObject(mapOf("search_context_size" to JsonPrimitive("low")))))
            else -> error("no saved sample for $transport")
        }

        private fun effectiveFor(transport: RelayTransport): JsonObject =
            savedFragments[transport] ?: requireNotNull(RelayWebFragments.template(transport))

        /** The fragment this attempt carried: saved / template / null (no fragment key at all). */
        fun fragmentKind(request: SentRequest): String? {
            val body = request.body
            fun carries(fragment: JsonObject) = fragment.all { (key, value) -> body[key] == value }
            savedFragments[request.transport]?.let { if (carries(it)) return "saved" }
            val template = requireNotNull(RelayWebFragments.template(request.transport))
            if (carries(template)) return "template"
            check(template.keys.none(body::containsKey)) { "unexpected fragment shape in $body" }
            return null
        }

        fun replyNotice(): String? = notices.all.value.values.singleOrNull()?.wire
            .also { check(notices.all.value.size <= 1) { notices.all.value.toString() } }

        fun recordWrites(): List<Triple<String, String, String>> = RelayTransport.entries.mapNotNull { transport ->
            records.read(RelayWebProbeRecordStore.Key(CONNECTION_ID, MODEL_ID, transport.value))
                ?.takeIf { it.at == NOW }
                ?.let { Triple(transport.value, it.result.wire, it.source.wire) }
        }

        fun assistantState(): ChatMessageState? = messages.lastOrNull { it.role == ChatRole.Assistant }?.state

        fun panelRow(preference: CapabilityWebPreference): ModelOptionCapabilityShape.RelayWebToggle {
            val provider = current()
            val shape = ModelOptionsPanelInput.relayWeb(provider, provider.models.single(), fragments, records, preference)
            return shape as? ModelOptionCapabilityShape.RelayWebToggle ?: error("not a toggle: $shape")
        }

        private val engine = MockEngine { request ->
            val entry = SentRequest(request.url.encodedPath, (request.body as? TextContent)?.text.orEmpty())
            sent += entry
            val reply = if (entry.isChat) synchronized(replies) { replies.removeFirstOrNull() } else null
            reply ?: return@MockEngine respond("{}", HttpStatusCode.NotFound, headersOf(HttpHeaders.ContentType, "application/json"))
            respond(reply.body, HttpStatusCode.fromValue(reply.status), headersOf(HttpHeaders.ContentType, reply.contentType))
        }

        private val providerRepository: ProviderRepository = run {
            val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
            coEvery { dao.getById(any(), any()) } coAnswers {
                stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
            }
            coEvery { dao.upsert(any()) } coAnswers { stored = firstArg() }
            coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
            val keys = mockk<ai.oriveo.community.core.security.SecureKeyStore>(relaxed = true)
            every { keys.getApiKey(any(), any()) } answers { "sk-test" }
            every { keys.getRelayKeySecret(any(), any(), any()) } answers { "sk-test" }
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
                metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
                httpClient = HttpClient(MockEngine { respond("", HttpStatusCode.NotFound) }),
                relayNegativeCache = RelayNegativeCache(RelayNegativeCache.MemoryStore()),
                relayWebFragmentStore = fragments,
                relayWebProbeRecords = records,
                relayWebProbeAutoHistory = RelayWebProbeAutoHistory(RelayWebProbeRecordStore.MemoryStore()),
                relayModelFamily = { null },
            )
        }

        fun send(webOn: Boolean) = runBlocking {
            val conversations = mockk<ai.oriveo.community.core.data.repository.ConversationRepository>(relaxed = true)
            coEvery { conversations.updateMessage(any(), any()) } coAnswers { messages += secondArg<ChatMessage>() }
            coEvery { conversations.addMessage(any(), any()) } coAnswers { messages += secondArg<ChatMessage>() }
            val repository = ai.oriveo.community.core.data.repository.ChatRepository(
                conversationRepository = conversations,
                providerRepository = providerRepository,
                attachmentStore = mockk<ai.oriveo.community.core.data.attachment.AttachmentStore>(relaxed = true),
                relayNegativeCache = RelayNegativeCache(RelayNegativeCache.MemoryStore()),
                relayWebFragmentStore = fragments,
                relayWebProbeRecords = records,
                relayWebReplyNotices = notices,
            )
            val provider = current()
            runCatching {
                repository.sendMessage(
                    conversation = ai.oriveo.community.core.model.Conversation(
                        id = CONVERSATION_ID,
                        title = "Relay",
                        providerID = provider.id,
                        providerKind = provider.kind,
                        modelID = MODEL_ID,
                    ),
                    text = "What is today's top story?",
                    provider = provider,
                    modelID = MODEL_ID,
                    existingMessages = emptyList(),
                    reasoningMode = ai.oriveo.community.core.model.ReasoningMode.Automatic,
                    webSearchEnabled = webOn,
                    requestOptions = ai.oriveo.community.core.model.ChatRequestOptions(),
                    outputs = ai.oriveo.community.core.streaming.ConversationStreamingOutputs(
                        streamingText = MutableStateFlow(""),
                        streamingMessageId = MutableStateFlow(null),
                    ),
                )
            }
        }
    }

    // -- fixtures --

    private fun chatCases(): List<JsonObject> =
        fixture.getValue("chatCases").jsonObject.getValue("cases").jsonArray.map { it.jsonObject }

    private fun transportOf(wire: String): RelayTransport = RelayTransport.entries.single { it.value == wire }

    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content

    private fun JsonObject.nullableString(key: String): String? =
        (get(key) as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content

    private fun readJson(relative: String): JsonObject {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val file = File(dir, relative)
            if (file.isFile) return json.parseToJsonElement(file.readText()).jsonObject
            dir = dir.parentFile
        }
        error("fixture not found: $relative")
    }

    private companion object {
        const val CONNECTION_ID = "55555555-5555-4555-8555-555555555555"
        const val ACCOUNT_ID = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
        const val MODEL_ID = "claude-sonnet-4-5"
        const val CONVERSATION_ID = "66666666-6666-4666-8666-666666666666"
        const val NOW = 1_791_900_000_000L
        const val SEEDED_AT = 1L
        val SEND_CASE_IDS = listOf(
            "fallback_carries_target_template",
            "fallback_carries_target_saved",
            "fallback_target_rejected_skips_with_notice",
            "fallback_with_citation_writes_searched",
            "fragment_400_resends_without_fragment",
            "fragment_400_resend_also_fails",
            "access_denied_never_resends",
            "known_rejected_skips_with_notice",
            "user_override_true_sends_despite_rejected",
            "web_off_sends_nothing_no_notice",
        )
    }
}
