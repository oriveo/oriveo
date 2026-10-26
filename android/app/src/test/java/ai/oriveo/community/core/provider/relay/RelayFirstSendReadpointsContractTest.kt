package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.capability.InputNegativeCache
import ai.oriveo.community.core.capability.truth.relayInputIdentity
import ai.oriveo.community.core.capability.truth.relayInputNegativeCacheTarget
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.ToolCallTransportResolver
import ai.oriveo.community.core.provider.transport.TransportKind
import ai.oriveo.community.feature.providers.detail.RelayAdvancedCapability
import ai.oriveo.community.feature.providers.detail.RelayAdvancedSource
import ai.oriveo.community.feature.providers.detail.RelayCatalogCapabilityFacts
import ai.oriveo.community.feature.providers.detail.RelayModelAdvancedBoard
import ai.oriveo.community.feature.providers.relay.RelayBoardProtocol
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * When no Relay protocol has been chosen, every read point uses the first-send protocol (shared fixture relay/first-send-readpoints.v1.json):
 * the input entry and evidence identity, the advanced page's catalog source row and "Auto =", the negative cache key, and the tool final transport all read [RelayFirstSendTransport.resolve];
 * a rejection is recorded under the protocol actually sent this time. inputRevisionCases asserts the Relay input key revision equals the hash of the facade's composed verdict.
 * fileFallbackCases asserts the only condition under which a first-send Messages falls back to the effective protocol because of files (production [RelayFirstSendTransport.forSend]).
 * Case names are `RELAY_FIRST_SEND_<id>`; the first candidate is injected through the production catalog endpoint types cache.
 */
class RelayFirstSendReadpointsContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val fixture = readFixture("shared/test-fixtures/relay/first-send-readpoints.v1.json")
    private val root = "https://first-send-readpoints.example.com/v1"
    private val nowSeconds = 1_760_000_000L

    private val transports = mapOf(
        "chat" to RelayTransport.OpenAIChatCompletions,
        "responses" to RelayTransport.OpenAIResponses,
        "messages" to RelayTransport.AnthropicMessages,
    )
    private val toolWire = mapOf(
        RelayTransport.OpenAIChatCompletions to TransportKind.OpenAIChat.wireValue,
        RelayTransport.OpenAIResponses to TransportKind.OpenAIResponses.wireValue,
        RelayTransport.AnthropicMessages to TransportKind.AnthropicMessages.wireValue,
    )
    private val endpointTypes = mapOf("messages" to listOf("anthropic", "openai"), "chat" to listOf("openai"))

    @After
    fun tearDown() {
        RelayCatalogEndpointTypes.record(root, emptyMap())
    }

    private fun cases(name: String) = fixture.getValue(name).jsonArray.map { it.jsonObject }

    private fun case(name: String, id: String) = cases(name).single { it.getValue("id").jsonPrimitive.content == id }

    private fun JsonObject.text(key: String): String? = this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content

    private fun relay(connection: String) = Provider(
        id = "relay-first-send-readpoints",
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        baseUrlText = "https://first-send-readpoints.example.com",
        relayRequested = RelayRequestedConfig(
            transport = if (connection == "auto") RelayTransport.Auto else transports.getValue(connection),
            resolvedAPIBaseURL = root,
        ),
    )

    private fun identity(provider: Provider) = CapabilityEvidenceIdentity(
        partitionId = "partition",
        connectionInstanceId = provider.id,
        connectionGeneration = "generation",
        credentialEpoch = "epoch",
        providerKind = provider.kind.rawValue,
        authMode = provider.authMode.rawValue,
    )

    /** Builds the connection and model from the fixture and writes the first candidate into this session's catalog endpoint types (the same cache a catalog refresh uses). */
    private fun setUp(case: JsonObject): Pair<Provider, AIModel> {
        val id = case.getValue("id").jsonPrimitive.content
        val provider = relay(case.getValue("connectionProtocol").jsonPrimitive.content)
        val model = AIModel(
            id = "rfs-$id",
            name = id,
            capabilities = listOf(ModelCapability.Text, ModelCapability.Image),
            relayTransport = case.text("modelProtocol")?.let(transports::getValue),
            // Source of the model's own protocol: user = chosen on the advanced page; detected = left by a probe (Observed), which still counts as an automatic result, so the advanced page still shows "Auto = that protocol".
            relayTransportSource = case.text("modelProtocol")?.let {
                when (val source = case.text("modelProtocolSource")) {
                    "user" -> RelayTransportSource.User
                    "detected" -> RelayTransportSource.Observed
                    else -> error("$id: unknown modelProtocolSource $source")
                }
            },
        )
        val first = case.text("firstCandidate")
        RelayCatalogEndpointTypes.record(root, first?.let { mapOf(model.id to endpointTypes.getValue(it)) } ?: emptyMap())
        return provider to model
    }

    private fun board(provider: Provider, model: AIModel): RelayModelAdvancedBoard {
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { nowSeconds })
        return RelayModelAdvancedBoard.build(
            provider = provider,
            model = model,
            nowSeconds = nowSeconds,
            probe = null,
            facts = RelayCatalogCapabilityFacts(
                metadata = MetadataClient(),
                negativeCache = cache,
                identityFor = { identity(provider) },
            ),
            negativeCache = cache,
            toolMemory = null,
            automaticReasoning = emptyList(),
            identity = identity(provider),
        )
    }

    private fun assertFirstSendCase(id: String) {
        val case = case("firstSendCases", id)
        val expect = case.getValue("expect").jsonObject
        val (provider, model) = setUp(case)
        val local = identity(provider)
        fun expected(key: String) = expect.text(key)?.let(transports::getValue)

        assertEquals(id, expected("firstSend"), RelayFirstSendTransport.resolve(provider, model))

        // Input entry: the connection identity used for the projection follows the first-send protocol.
        val input = relayInputIdentity(provider, model, local)
        expected("inputEntry")?.let { assertEquals(id, it.value, input!!.effectiveTransport) }
        // Evidence identity: the same one as the outbound identity chosen after resolving the first-send protocol (including the endpoint fingerprint).
        expected("evidenceIdentity")?.let {
            val pinned = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(provider, model.copy(relayTransport = it), local)
            assertEquals(id, pinned, input)
        }

        val board = board(provider, model)
        if (expect.containsKey("boardAutoEquals")) {
            val row = board.protocol!!
            val autoLine = row.autoEquals.takeUnless { row.autoFollowsConnection }
            // Fixture null = no "Auto = first send" line: the protocol is already chosen, or it follows the chosen connection (row 1 shows the connection-default line).
            assertEquals(id, expected("boardAutoEquals")?.let(RelayBoardProtocol::of), autoLine)
        }
        // Catalog source row: the vision source is the facade's declaration under the first-send protocol identity.
        expected("boardCatalogSource")?.let {
            val declared = CapabilityEvidenceProductionAdapter.capabilityProjection(
                provider = provider,
                model = model,
                identity = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(provider, model.copy(relayTransport = it), local),
                keys = setOf(CapabilityEvidenceFacade.VISION_INPUT),
            ).decision(CapabilityEvidenceFacade.VISION_INPUT)?.visible == true
            assertEquals(
                id,
                if (declared) RelayAdvancedSource.Catalog else null,
                board.capabilities.single { row -> row.capability == RelayAdvancedCapability.Image }.source,
            )
        }

        expected("negativeCacheKey")?.let { assertEquals(id, it.value, RelayNegativeCache.keyFor(provider, model)!!.transport) }
        expected("toolFinalTransport")?.let {
            assertEquals(id, toolWire.getValue(it), ToolCallTransportResolver.declaredTransport(provider, model))
        }

        // Attachment fallback: this turn actually goes via Chat, so the rejection is recorded under the protocol actually sent.
        if (case["turnFellBackToChatForFiles"]?.jsonPrimitive?.boolean == true) {
            val scanned = Attachment(
                id = "f1", kind = AttachmentKind.File, fileName = "scan.pdf", mimeType = "application/pdf",
                extractionErrorCode = "no_text",
            )
            val turn = listOf(
                ChatMessage(
                    id = "u1", role = ChatRole.User, text = "read", providerKind = ProviderKind.Relay,
                    providerName = "relay", modelName = model.id, state = ChatMessageState.Delivered,
                    attachments = listOf(scanned),
                ),
            )
            val sent = RelayFirstSendTransport.forSend(provider, model, turn)
            assertEquals(id, expected("turnSentWith"), sent)
            assertEquals(id, expected("rejectionRecordedUnder")!!.value, RelayNegativeCache.keyFor(provider, model, sent)!!.transport)
        }
    }

    private fun assertInputRevisionCase(id: String) {
        val case = case("inputRevisionCases", id)
        val first = case.getValue("firstSend").jsonPrimitive.content
        val evidence = case.text("connectionEvidence")
        val provider = relay("auto")
        val model = AIModel(
            id = "rfs-$id",
            name = id,
            capabilities = listOf(ModelCapability.Text),
            relayCapabilityOverrides = evidence?.let {
                RelayCapabilityOverrides(image = it == "supported", testedKeys = setOf("image"))
            },
        )
        RelayCatalogEndpointTypes.record(root, mapOf(model.id to endpointTypes.getValue(first)))
        val transport = RelayFirstSendTransport.resolve(provider, model)
        assertEquals(id, transports.getValue(first), transport)
        val target = relayInputNegativeCacheTarget(
            provider = provider,
            model = model,
            transport = transport.value,
            key = case.getValue("key").jsonPrimitive.content,
            relayIdentity = relayInputIdentity(provider, model, identity(provider)),
            metadataClient = MetadataClient(),
        )!!
        val verdict = requireNotNull(target.verdict) { "$id: the revision never hashes a missing verdict" }
        assertEquals(id, case.getValue("canonical").jsonPrimitive.content, InputNegativeCache.canonicalVerdictJson(verdict))
        assertEquals(id, case.getValue("revision").jsonPrimitive.content, InputNegativeCache.verdictRevision(verdict))
    }

    /**
     * fileFallbackCases: a first-send Messages turn falls back to the effective protocol only when it carries files, none has extracted text,
     * and none can be sent natively over Messages; images never trigger it. It goes through production [RelayFirstSendTransport.forSend], and whether a file is native is decided by the production attachment plan:
     * messagesNative = the model's file override is On (PDF allowlist + native by default) and the PDF carries its original content; otherwise the catalog has no such model and the file can only be extracted.
     */
    private fun assertFileFallbackCase(id: String) {
        val case = case("fileFallbackCases", id)
        val provider = relay("auto")
        val files = case.getValue("files").jsonArray.map { it.jsonObject }
        // "Carries files or not" is judged over the whole outbound history: historyFiles hang on the previous user message.
        val historyFiles = case["historyFiles"]?.jsonArray?.map { it.jsonObject }.orEmpty()
        val native = (files + historyFiles).any { it.getValue("messagesNative").jsonPrimitive.boolean }
        val model = AIModel(
            id = "rfs-$id",
            name = id,
            capabilities = listOf(ModelCapability.Text, ModelCapability.Image),
            relayCapabilityOverrides = if (native) RelayCapabilityOverrides(file = true) else null,
        )
        RelayCatalogEndpointTypes.record(root, mapOf(model.id to endpointTypes.getValue("messages")))
        assertEquals(id, transports.getValue(case.getValue("firstSend").jsonPrimitive.content), RelayFirstSendTransport.resolve(provider, model))
        assertEquals(
            id,
            transports.getValue(case.getValue("effectiveTransport").jsonPrimitive.content),
            ai.oriveo.community.core.provider.RelayEndpointResolver.effectiveTransport(provider, model),
        )
        fun fileAttachments(prefix: String, specs: List<JsonObject>) = specs.mapIndexed { index, file ->
            if (file.getValue("hasExtractedText").jsonPrimitive.boolean) {
                Attachment(
                    id = "${prefix}t$index", kind = AttachmentKind.File, fileName = "notes$index.txt", mimeType = "text/plain",
                    base64Data = "aGk=",
                )
            } else {
                Attachment(
                    id = "${prefix}s$index", kind = AttachmentKind.File, fileName = "scan$index.pdf", mimeType = "application/pdf",
                    extractionErrorCode = "no_text", originalBase64Data = "JVBERi0=",
                )
            }
        }
        val attachments = fileAttachments("", files) + (0 until (case["images"]?.jsonPrimitive?.content?.toInt() ?: 0)).map { index ->
            Attachment(id = "i$index", kind = AttachmentKind.Image, fileName = "photo$index.png", mimeType = "image/png", base64Data = "iVBORw0K")
        }
        fun message(id: String, role: ChatRole, attached: List<Attachment>) = ChatMessage(
            id = id, role = role, text = "read", providerKind = ProviderKind.Relay,
            providerName = "relay", modelName = model.id, state = ChatMessageState.Delivered,
            attachments = attached,
        )
        val history = if (historyFiles.isEmpty()) {
            emptyList()
        } else {
            listOf(message("u0", ChatRole.User, fileAttachments("h", historyFiles)), message("a0", ChatRole.Assistant, emptyList()))
        }
        val turn = history + message("u1", ChatRole.User, attachments)
        val expected = transports.getValue(case.getValue("expect").jsonObject.getValue("turnSentWith").jsonPrimitive.content)
        assertEquals(id, expected, RelayFirstSendTransport.forSend(provider, model, turn))
    }

    @Test
    fun `RELAY_FIRST_SEND ids cover the fixture`() {
        assertEquals(
            setOf(
                "auto_claude_family_messages", "auto_other_family_chat", "auto_no_candidate_chat",
                "model_protocol_wins", "model_protocol_detected_auto_equals", "connection_protocol_wins", "attachment_fallback_records_under_sent",
            ),
            cases("firstSendCases").map { it.getValue("id").jsonPrimitive.content }.toSet(),
        )
        assertEquals(
            setOf(
                "relay_vision_supported_chat", "relay_vision_unsupported_chat", "relay_vision_unknown_chat",
                "relay_vision_unknown_messages", "relay_file_silent_chat", "relay_video_silent_chat",
            ),
            cases("inputRevisionCases").map { it.getValue("id").jsonPrimitive.content }.toSet(),
        )
        assertEquals(
            setOf(
                "all_files_textless_messages_cannot_native_falls_back", "file_with_text_stays_on_messages",
                "messages_sends_file_natively_stays", "one_textless_one_with_text_stays", "history_textless_file_falls_back",
                "images_only_never_fall_back",
            ),
            cases("fileFallbackCases").map { it.getValue("id").jsonPrimitive.content }.toSet(),
        )
        assertNull(RelayCatalogEndpointTypes.lookup(root, "rfs-unrecorded"))
    }

    @Test fun `RELAY_FIRST_SEND_auto_claude_family_messages`() = assertFirstSendCase("auto_claude_family_messages")
    @Test fun `RELAY_FIRST_SEND_auto_other_family_chat`() = assertFirstSendCase("auto_other_family_chat")
    @Test fun `RELAY_FIRST_SEND_auto_no_candidate_chat`() = assertFirstSendCase("auto_no_candidate_chat")
    @Test fun `RELAY_FIRST_SEND_model_protocol_wins`() = assertFirstSendCase("model_protocol_wins")
    @Test fun `RELAY_FIRST_SEND_model_protocol_detected_auto_equals`() = assertFirstSendCase("model_protocol_detected_auto_equals")
    @Test fun `RELAY_FIRST_SEND_connection_protocol_wins`() = assertFirstSendCase("connection_protocol_wins")
    @Test fun `RELAY_FIRST_SEND_attachment_fallback_records_under_sent`() = assertFirstSendCase("attachment_fallback_records_under_sent")

    @Test fun `RELAY_FIRST_SEND_relay_vision_supported_chat`() = assertInputRevisionCase("relay_vision_supported_chat")
    @Test fun `RELAY_FIRST_SEND_relay_vision_unsupported_chat`() = assertInputRevisionCase("relay_vision_unsupported_chat")
    @Test fun `RELAY_FIRST_SEND_relay_vision_unknown_chat`() = assertInputRevisionCase("relay_vision_unknown_chat")
    @Test fun `RELAY_FIRST_SEND_relay_vision_unknown_messages`() = assertInputRevisionCase("relay_vision_unknown_messages")
    @Test fun `RELAY_FIRST_SEND_relay_file_silent_chat`() = assertInputRevisionCase("relay_file_silent_chat")
    @Test fun `RELAY_FIRST_SEND_relay_video_silent_chat`() = assertInputRevisionCase("relay_video_silent_chat")

    @Test fun `RELAY_FIRST_SEND_all_files_textless_messages_cannot_native_falls_back`() = assertFileFallbackCase("all_files_textless_messages_cannot_native_falls_back")
    @Test fun `RELAY_FIRST_SEND_file_with_text_stays_on_messages`() = assertFileFallbackCase("file_with_text_stays_on_messages")
    @Test fun `RELAY_FIRST_SEND_messages_sends_file_natively_stays`() = assertFileFallbackCase("messages_sends_file_natively_stays")
    @Test fun `RELAY_FIRST_SEND_one_textless_one_with_text_stays`() = assertFileFallbackCase("one_textless_one_with_text_stays")
    @Test fun `RELAY_FIRST_SEND_history_textless_file_falls_back`() = assertFileFallbackCase("history_textless_file_falls_back")
    @Test fun `RELAY_FIRST_SEND_images_only_never_fall_back`() = assertFileFallbackCase("images_only_never_fall_back")

    private fun readFixture(relative: String): JsonObject {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val file = File(dir, relative)
            if (file.isFile) return json.parseToJsonElement(file.readText()).jsonObject
            dir = dir.parentFile
        }
        error("fixture not found: $relative")
    }
}
