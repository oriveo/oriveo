package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.error.ErrorMapper
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.feature.chat.recovery.MessageRecoveryActionKind
import ai.oriveo.community.feature.chat.recovery.isRelayImageUnsupportedDetail
import ai.oriveo.community.feature.chat.recovery.relayRecoveryOffersModelSwitch
import ai.oriveo.community.feature.chat.recovery.resolveMessageRecoveryCardActionLayout
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.EngineDeclaration
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.feature.chat.ChatModelCapabilityResolver
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Driven by caseId from the fixture `shared/test-fixtures/relay/negative-cache.v1.json`. */
class RelayNegativeCacheContractTest {

    private val fixture: JsonObject = Json.parseToJsonElement(
        generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .map { File(it, "shared/test-fixtures/relay/negative-cache.v1.json") }
            .first { it.isFile }
            .readText(Charsets.UTF_8),
    ).jsonObject

    private val transports = fixture.getValue("transports").jsonObject
        .mapValues { it.value.jsonPrimitive.content }

    private fun kind(raw: String) = RelayNegativeCache.Kind.entries.single { it.value == raw }

    private fun key(obj: JsonObject) = RelayNegativeCache.Key(
        obj.getValue("connectionId").jsonPrimitive.content,
        obj.getValue("modelId").jsonPrimitive.content,
        transports.getValue(obj.getValue("transport").jsonPrimitive.content),
    )

    private fun tuple(raw: JsonArray): Pair<RelayNegativeCache.Key, RelayNegativeCache.Kind> {
        val parts = raw.map { it.jsonPrimitive.content }
        return RelayNegativeCache.Key(parts[0], parts[1], transports.getValue(parts[2])) to kind(parts[3])
    }

    @Test
    fun `RL2_NEGCACHE_01 keyCases hit by connection model protocol and tier and expire after 7 days`() {
        assertEquals(RelayNegativeCache.TTL_SECONDS, fixture.getValue("ttlSeconds").jsonPrimitive.long)
        assertEquals(
            fixture.getValue("kinds").jsonArray.map { it.jsonPrimitive.content },
            // The thinking-tier bucket `reasoningTier:<tier>` is governed by reasoning-tier.v1.json and is not in this fixture's bucket table.
            RelayNegativeCache.Kind.entries.filter { it.reasoningTier == null }.map { it.value },
        )
        fixture.getValue("keyCases").jsonArray.map { it.jsonObject }.forEach { case ->
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val record = case.getValue("record").jsonObject
            val query = case.getValue("query").jsonObject
            val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { error("clock must not be read") })
            cache.record(key(record), kind(record.getValue("kind").jsonPrimitive.content), record.getValue("at").jsonPrimitive.long)
            assertEquals(
                caseId,
                case.getValue("expectHit").jsonPrimitive.boolean,
                cache.isRejected(key(query), kind(query.getValue("kind").jsonPrimitive.content), query.getValue("at").jsonPrimitive.long),
            )
        }
    }

    @Test
    fun `RL2_NEGCACHE_01 clearCases test result user override and re-detect each clear their own`() {
        fixture.getValue("clearCases").jsonArray.map { it.jsonObject }.forEach { case ->
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val now = 5_000L
            val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { now })
            case.getValue("before").jsonArray.forEach { raw ->
                val (k, kind) = tuple(raw.jsonArray)
                cache.record(k, kind)
            }
            val target = case.getValue("target").jsonObject
            when (val action = case.getValue("action").jsonPrimitive.content) {
                "testedResult" -> cache.clear(key(target), listOf(RelayNegativeCache.Kind.Image, RelayNegativeCache.Kind.ToolCall))
                "userOverride" -> cache.clear(key(target), listOf(kind(case.getValue("kind").jsonPrimitive.content)))
                "redetect" -> cache.clearConnection(target.getValue("connectionId").jsonPrimitive.content)
                else -> error("unknown action $action")
            }
            val expected = case.getValue("after").jsonArray.map { tuple(it.jsonArray) }.toSet()
            assertEquals(caseId, expected, cache.entries().map { it.key to it.kind }.toSet())
        }
    }

    @Test
    fun `RL2_NEGCACHE_01 toolCall negative cache yields false via production toolCallVerdict and override wins`() {
        val provider = relayProvider(engineProfile = null)
        val model = AIModel(id = "m1", name = "m1", capabilities = listOf(ModelCapability.Text))
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 2_000L })
        assertNull(CapabilityEvidenceProductionAdapter.toolCallVerdict(provider, model, negativeCache = cache))
        cache.record(RelayNegativeCache.keyFor(provider, model)!!, RelayNegativeCache.Kind.ToolCall, 1_000L)
        assertEquals(false, CapabilityEvidenceProductionAdapter.toolCallVerdict(provider, model, negativeCache = cache))
        assertEquals(
            false,
            CapabilityEvidenceProductionAdapter.toolCallVerdict(provider, model.copy(toolCall = true), negativeCache = cache),
        )
        // The override value is the highest source and beats the negative cache and the engine declaration.
        val overridden = model.copy(
            relayCapabilityOverrides = RelayCapabilityOverrides(toolCall = true, testedKeys = setOf("toolCall")),
            engineDeclaration = EngineDeclaration(toolCall = false),
        )
        assertEquals(
            true,
            CapabilityEvidenceProductionAdapter.toolCallVerdict(relayProvider("ollama"), overridden, negativeCache = cache),
        )
        // Other protocols are unaffected.
        val otherTransport = model.copy(relayTransport = RelayTransport.OpenAIResponses)
        assertNull(CapabilityEvidenceProductionAdapter.toolCallVerdict(provider, otherTransport, negativeCache = cache))
    }

    @Test
    fun `RL2_NEGCACHE_01 toolCall negative cache beats engine declaration and declared Relay memory only counts true`() {
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 2_000L })
        val engine = relayProvider("ollama")
        val declared = AIModel(
            id = "m1",
            name = "m1",
            capabilities = listOf(ModelCapability.Text),
            toolCall = true,
            engineDeclaration = EngineDeclaration(toolCall = true),
        )
        assertEquals(true, CapabilityEvidenceProductionAdapter.toolCallVerdict(engine, declared, negativeCache = cache))
        cache.record(RelayNegativeCache.keyFor(engine, declared)!!, RelayNegativeCache.Kind.ToolCall, 1_000L)
        // 1. The negative cache beats an engine declaration of true.
        assertEquals(false, CapabilityEvidenceProductionAdapter.toolCallVerdict(engine, declared, negativeCache = cache))

        // 2. Model with toolCall declared + negative cache: toolCallProjection and toolCallVerdict both yield false.
        val provider = relayProvider(engineProfile = null)
        val model = declared.copy(engineDeclaration = null)
        val identity = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(provider, model, identity(provider))!!
        val before = CapabilityEvidenceProductionAdapter.toolCallProjection(
            provider, model, identity, negativeCache = RelayNegativeCache(RelayNegativeCache.MemoryStore()),
        ).decision("tool_call")!!
        assertTrue(before.resolution.support != "unsupported")
        val after = CapabilityEvidenceProductionAdapter.toolCallProjection(provider, model, identity, negativeCache = cache)
            .decision("tool_call")!!
        assertEquals("unsupported", after.resolution.support)
        assertFalse(after.permitsOutbound)

        // 3. Relay tool memory of false is treated as no value; true still applies.
        val bare = AIModel(id = "m2", name = "m2", capabilities = listOf(ModelCapability.Text))
        val empty = RelayNegativeCache(RelayNegativeCache.MemoryStore())
        assertNull(CapabilityEvidenceProductionAdapter.toolCallVerdict(provider, bare, memoryVerdict = false, negativeCache = empty))
        assertEquals(true, CapabilityEvidenceProductionAdapter.toolCallVerdict(provider, bare, memoryVerdict = true, negativeCache = empty))
        val bareIdentity = CapabilityEvidenceProductionAdapter.uiDispatchIdentity(provider, bare, identity(provider))!!
        val memoryFalse = CapabilityEvidenceProductionAdapter.toolCallProjection(
            provider, bare, bareIdentity, memoryVerdict = false, negativeCache = empty,
        ).decision("tool_call")!!
        assertTrue(memoryFalse.resolution.support != "unsupported")
    }

    @Test
    fun `RL2_NEGCACHE_01 key protocol uses the effective protocol and is chat when the connection is auto and the model has none`() {
        val auto = relayProvider(engineProfile = null).let {
            it.copy(relayRequested = it.relayRequested!!.copy(transport = RelayTransport.Auto))
        }
        val model = AIModel(id = "m1", name = "m1", capabilities = listOf(ModelCapability.Text))
        assertEquals(
            RelayNegativeCache.Key("c1", "m1", transports.getValue("chat")),
            RelayNegativeCache.keyFor(auto, model),
        )
    }

    @Test
    fun `RL2_NEGCACHE_03 visionEntryCases decide the photo-library entry via production ChatModelCapabilityResolver`() {
        fixture.getValue("visionEntryCases").jsonArray.map { it.jsonObject }.forEach { case ->
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val engineImage = case["engineDeclarationImage"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.booleanOrNull
            val override = case["override"]?.takeUnless { it is JsonNull }?.jsonObject
            val envelopeAllowsImage = case.getValue("envelopeAllowsImage").jsonPrimitive.boolean
            val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 2_000L })
            val resolver = ChatModelCapabilityResolver(
                metadata = MetadataClient(),
                runtimeConfigProvider = { runtimeConfig(envelopeAllowsImage) },
                negativeCache = cache,
            )
            val visible = when (case.getValue("form").jsonPrimitive.content) {
                "relay" -> {
                    val provider = relayProvider(engineProfile = engineImage?.let { "ollama" })
                    val model = AIModel(
                        id = "m1",
                        name = "m1",
                        capabilities = listOf(ModelCapability.Text),
                        engineDeclaration = engineImage?.let { EngineDeclaration(image = it) },
                        relayCapabilityOverrides = override?.let {
                            RelayCapabilityOverrides(
                                image = it.getValue("value").jsonPrimitive.boolean,
                                testedKeys = if (it.getValue("source").jsonPrimitive.content == "tested") setOf("image") else emptySet(),
                            )
                        },
                    )
                    if (case.getValue("imageNegCached").jsonPrimitive.boolean) {
                        cache.record(RelayNegativeCache.keyFor(provider, model)!!, RelayNegativeCache.Kind.Image, 1_000L)
                    }
                    resolver.supportsImage(provider, model, identity(provider))
                }
                "official" -> {
                    val provider = Provider(id = "official", kind = ProviderKind.OpenAI, status = ProviderConnectionState.Connected)
                    val model = AIModel(id = "m1", name = "m1", capabilities = listOf(ModelCapability.Text))
                    resolver.supportsImage(provider, model, identity(provider))
                }
                else -> error("unknown form")
            }
            assertEquals(caseId, case.getValue("expectVisible").jsonPrimitive.boolean, visible)
        }
    }

    @Test
    fun `RL2_NEGCACHE_03 Relay vision unknown still fails closed without a connection identity`() {
        val resolver = ChatModelCapabilityResolver(
            metadata = MetadataClient(),
            runtimeConfigProvider = { runtimeConfig(true) },
            negativeCache = RelayNegativeCache(RelayNegativeCache.MemoryStore()),
        )
        val provider = relayProvider(engineProfile = null)
        val model = AIModel(id = "m1", name = "m1", capabilities = listOf(ModelCapability.Text))
        assertTrue(resolver.supportsImage(provider, model, identity(provider)))
        assertFalse(resolver.supportsImage(provider, model, null))
    }

    @Test
    fun `RL2_NEGCACHE_03 auto connection model without protocol vision unknown uses chat key entry visible then hidden after negative cache is recorded`() {
        // auto / no config is not an incomplete identity; the key is taken from effectiveTransport (auto -> Chat).
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 2_000L })
        val resolver = ChatModelCapabilityResolver(
            metadata = MetadataClient(),
            runtimeConfigProvider = { runtimeConfig(true) },
            negativeCache = cache,
        )
        val auto = relayProvider(engineProfile = null).let {
            it.copy(relayRequested = it.relayRequested!!.copy(transport = RelayTransport.Auto))
        }
        val model = AIModel(id = "m1", name = "m1", capabilities = listOf(ModelCapability.Text))
        assertTrue(resolver.supportsImage(auto, model, identity(auto)))
        cache.record(RelayNegativeCache.Key("c1", "m1", transports.getValue("chat")), RelayNegativeCache.Kind.Image, 1_000L)
        assertFalse(resolver.supportsImage(auto, model, identity(auto)))
    }

    private val capabilityFixture: JsonObject = Json.parseToJsonElement(
        generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .map { File(it, "shared/test-fixtures/relay/capability-test.v1.json") }
            .first { it.isFile }
            .readText(Charsets.UTF_8),
    ).jsonObject

    @Test
    fun `RL2_NEGCACHE_01 classifyCases only rejected is written`() {
        val key = RelayNegativeCache.Key("c1", "m1", transports.getValue("chat"))
        capabilityFixture.getValue("classifyCases").jsonArray.map { it.jsonObject }.forEach { case ->
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 1_000L })
            val wrote = cache.recordIfRejected(
                key,
                RelayNegativeCache.Kind.Image,
                status = case.getValue("status").jsonPrimitive.int,
                contentType = case["contentType"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content,
                body = case.getValue("body").jsonPrimitive.content,
            )
            val expected = case.getValue("expect").jsonPrimitive.content == "rejected"
            assertEquals(caseId, expected, wrote)
            assertEquals(caseId, expected, cache.isRejected(key, RelayNegativeCache.Kind.Image))
        }
        // In-stream error frames (which can only appear after output has started) are never written.
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 1_000L })
        assertFalse(cache.recordIfRejected(key, RelayNegativeCache.Kind.Image, ProviderServiceError.Upstream(400, "x", streamErrorFrame = true)))
        assertFalse(cache.recordIfRejected(key, RelayNegativeCache.Kind.Image, ProviderServiceError.Upstream(500, "x")))
        assertTrue(cache.recordIfRejected(key, RelayNegativeCache.Kind.Image, ProviderServiceError.Upstream(400, "x")))
    }

    @Test
    fun `RL2_NEGCACHE_01 capability test write-back clears image and toolCall of the model's current protocol`() {
        val model = AIModel(id = "m1", name = "m1", capabilities = listOf(ModelCapability.Text))
        val provider = relayProvider(engineProfile = null).copy(models = listOf(model))
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 2_000L })
        val key = RelayNegativeCache.keyFor(provider, model)!!
        RelayNegativeCache.Kind.entries.forEach { cache.record(key, it, 1_000L) }
        val run = RelayCapabilityTestRun(
            textFailed = false,
            sent = RelayCapabilityTestKind.entries.toList(),
            image = RelayCapabilityVerdict.Accepted,
            toolCall = RelayCapabilityVerdict.Undetermined,
        )
        RelayCapabilityTest.applyingResult(provider, "m1", run, negativeCache = cache)
        // The capability test clears only image + toolCall; thinking-tier records are cleared by re-detection and tier-override changes.
        assertEquals(
            setOf(RelayNegativeCache.Kind.File) + RelayNegativeCache.Kind.entries.filter { it.reasoningTier != null },
            cache.entries().map { it.kind }.toSet(),
        )
    }

    @Test
    fun `RL2_NEGCACHE_02 error frame after output fails the message keeps text and thinking no resend no write`() = runTest {
        // Production outbound layer: an error frame after the text has streamed does not fall back or switch protocol; only one request is sent.
        val frame = SendHarness(
            candidates = listOf(RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions),
        ) { _, _ ->
            SseReply(
                "data: {\"choices\":[{\"delta\":{\"content\":\"partial answer\"}}]}\n\n" +
                    "data: {\"error\":{\"message\":\"image not supported\",\"code\":400}}\n\n",
            )
        }
        val frameFailed = frame.send(image = true)
        assertEquals(ChatMessageState.Failed, frameFailed.state)
        assertEquals("partial answer", frameFailed.text)
        assertEquals("no resend, no protocol switch", 1, frame.requests.size)
        assertTrue(frame.cache.entries().toString(), frame.cache.entries().isEmpty())
        assertTrue(frameFailed.errorDetail != ChatRepository.RELAY_IMAGE_UNSUPPORTED_DETAIL)

        // Production ChatRepository: a 400 after both thinking and text have arrived is likewise not written, and the thinking is kept.
        var calls = 0
        val service = mockk<ai.oriveo.community.core.provider.ProviderService>()
        every {
            service.sendMessageStream(any(), any(), any(), any(), any(), any(), any(), any())
        } answers {
            calls += 1
            kotlinx.coroutines.flow.flow {
                emit(ai.oriveo.community.core.model.StreamEvent.Reasoning("thinking"))
                emit(ai.oriveo.community.core.model.StreamEvent.Delta("partial answer"))
                throw ProviderServiceError.Upstream(400, "image not supported")
            }
        }
        val late = SendHarness(service = service) { _, _ -> error("no HTTP expected") }
        val lateFailed = late.send(image = true)
        assertEquals(ChatMessageState.Failed, lateFailed.state)
        assertEquals("partial answer", lateFailed.text)
        assertEquals("thinking", lateFailed.reasoningText)
        assertEquals(1, calls)
        assertTrue(late.cache.entries().isEmpty())
        assertTrue(lateFailed.errorDetail != ChatRepository.RELAY_IMAGE_UNSUPPORTED_DETAIL)
    }

    @Test
    fun `RL2_NEGCACHE_03 Relay vision unknown image send 400 stores image entry hidden failed message shows a hint card`() = runTest {
        val harness = SendHarness { _, _ -> JsonReply(400, """{"error":{"message":"image input is not supported"}}""") }
        val failed = harness.send(image = true)

        // The image is sent as usual: assertions come from the production request body.
        assertEquals(1, harness.requests.size)
        assertTrue(harness.requests[0].second, harness.requests[0].second.contains("data:image/png;base64,$IMAGE_BASE64"))
        // The store has an image entry; the key is the same keyFor as the read side.
        val key = RelayNegativeCache.keyFor(harness.provider, harness.model)!!
        assertEquals(listOf(key to RelayNegativeCache.Kind.Image), harness.cache.entries().map { it.key to it.kind })
        // Entry hidden (the production ChatModelCapabilityResolver reads the same store).
        val resolver = ChatModelCapabilityResolver(
            metadata = MetadataClient(),
            runtimeConfigProvider = { runtimeConfig(true) },
            negativeCache = harness.cache,
        )
        assertFalse(resolver.supportsImage(harness.provider, harness.model, identity(harness.provider)))
        // The failed message shows a hint card: the body is a copy-table key and the card carries Switch Model.
        assertEquals(ChatMessageState.Failed, failed.state)
        assertEquals(ChatRepository.RELAY_IMAGE_UNSUPPORTED_DETAIL, failed.errorDetail)
        assertTrue(ErrorMapper.hasLocalizedProviderMessage(failed.errorDetail))
        assertTrue(relayRecoveryOffersModelSwitch(isRateLimitError = false, errorDetail = failed.errorDetail))
        assertFalse(relayRecoveryOffersModelSwitch(isRateLimitError = false, errorDetail = "other"))
        // The primary action is Switch Model; other failure card layouts are unchanged.
        val layout = resolveMessageRecoveryCardActionLayout(
            state = ChatMessageState.Failed,
            shouldOfferModelSwitch = true,
            relayAttachmentUnsupported = isRelayImageUnsupportedDetail(failed.errorDetail),
        )
        assertEquals(MessageRecoveryActionKind.SwitchModel, layout.primary)
        assertEquals(MessageRecoveryActionKind.EditMessage, layout.secondary)
        assertEquals(MessageRecoveryActionKind.Retry, layout.tertiary)
        assertEquals(
            MessageRecoveryActionKind.Retry,
            resolveMessageRecoveryCardActionLayout(ChatMessageState.Failed, shouldOfferModelSwitch = true).primary,
        )
    }

    @Test
    fun `RL2_NEGCACHE_03 rejection when vision is declared supported does not record image and 5xx is not written`() = runTest {
        val declared = SendHarness(modelCapabilities = listOf(ModelCapability.Text, ModelCapability.Image)) { _, _ ->
            JsonReply(400, """{"error":{"message":"bad request"}}""")
        }
        val declaredFailed = declared.send(image = true)
        assertTrue(declared.cache.entries().isEmpty())
        assertTrue(declaredFailed.errorDetail != ChatRepository.RELAY_IMAGE_UNSUPPORTED_DETAIL)

        val serverError = SendHarness { _, _ -> JsonReply(500, """{"error":{"message":"boom"}}""") }
        val serverFailed = serverError.send(image = true)
        assertTrue(serverError.cache.entries().isEmpty())
        assertTrue(serverFailed.errorDetail != ChatRepository.RELAY_IMAGE_UNSUPPORTED_DETAIL)
    }

    @Test
    fun `RL2_NEGCACHE_04 protocolFallbackCases pure function`() {
        fun transport(short: String) = RelayTransport.entries.single { it.value == transports.getValue(short) }
        // Each rule-table entry matches the production criterion: plain status codes count directly; phrase status codes count only with the phrase (case-insensitive).
        val rules = fixture.getValue("protocolFallbackRules").jsonObject
        val phrases = rules.getValue("phrases").jsonArray.map { it.jsonPrimitive.content }
        assertTrue(phrases.isNotEmpty())
        rules.getValue("statuses").jsonArray.map { it.jsonPrimitive.int }.forEach { status ->
            assertTrue("status $status", RelayProtocolFallback.isRouteRejection(status, ""))
        }
        rules.getValue("phraseStatuses").jsonArray.map { it.jsonPrimitive.int }.forEach { status ->
            assertFalse("status $status without a phrase", RelayProtocolFallback.isRouteRejection(status, """{"error":{"message":"forbidden"}}"""))
            phrases.forEach { phrase ->
                assertTrue("status $status + $phrase", RelayProtocolFallback.isRouteRejection(status, "x ${phrase.uppercase()} y"))
                assertFalse("a phrase only applies to registered status codes", RelayProtocolFallback.isRouteRejection(401, phrase))
            }
        }
        // A 2xx HTML page is also a route-level rejection; the same status code returning normal JSON is not.
        assertEquals(true, rules.getValue("htmlSuccessIsRouteRejection").jsonPrimitive.boolean)
        assertTrue(RelayProtocolFallback.isRouteRejection(200, "", "text/html; charset=utf-8"))
        assertFalse(RelayProtocolFallback.isRouteRejection(200, """{"id":"x"}""", "application/json"))
        val cases = fixture.getValue("protocolFallbackCases").jsonArray.map { it.jsonObject }
        assertEquals(18, cases.size)
        assertTrue(cases.any { it.getValue("caseId").jsonPrimitive.content == "html_page_with_200_tries_next_candidate" })
        assertTrue(cases.any { it.getValue("caseId").jsonPrimitive.content == "status_403_with_escaped_route_phrase_tries_next_candidate" })
        assertTrue(cases.any { it.getValue("caseId").jsonPrimitive.content == "status_403_client_gate_does_not_switch" })
        cases.forEach { case ->
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val next = RelayProtocolFallback.nextTransport(
                current = transport(case.getValue("current").jsonPrimitive.content),
                source = case["source"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
                    ?.let { raw -> RelayTransportSource.entries.single { it.value == raw } },
                candidates = case.getValue("candidates").jsonArray.map { transport(it.jsonPrimitive.content) },
                // A case without a body is treated as an empty body; one without contentType is treated as application/json.
                routeRejected = RelayProtocolFallback.isRouteRejection(
                    case.getValue("status").jsonPrimitive.int,
                    case["body"]?.jsonPrimitive?.content.orEmpty(),
                    case["contentType"]?.jsonPrimitive?.content ?: "application/json",
                ),
                outputStarted = case.getValue("outputStarted").jsonPrimitive.boolean,
                alreadySwitched = case.getValue("alreadySwitched").jsonPrimitive.boolean,
            )
            val expected = case["expectNext"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content?.let(::transport)
            assertEquals(caseId, expected, next)
        }
    }

    /**
     * clientGateRules / clientGateCases: decided via the production error mapping (RelayErrorMapper.mapOrDefault);
     * a gated 403 shows the CLI gate guidance, key access is recorded as none, no protocol switch happens as for a route-level rejection; the rule table's phrases match the production criterion one by one.
     */
    @Test
    fun `RL2-CLIGATE clientGateRules and clientGateCases all cases`() {
        fun gated(status: Int, body: String): Boolean {
            val error = ai.oriveo.community.core.provider.RelayErrorMapper.mapOrDefault(status, body, "https://relay.example.com/v1/messages")
            return (error as? ProviderServiceError.RelayUpstream)?.guidanceCode?.stableKey == "client_gated"
        }
        val rules = fixture.getValue("clientGateRules").jsonObject
        val statuses = rules.getValue("statuses").jsonArray.map { it.jsonPrimitive.int }
        assertEquals(listOf(403), statuses)
        val phrases = rules.getValue("phrases").jsonArray.map { it.jsonPrimitive.content }
        assertTrue(phrases.isNotEmpty())
        phrases.forEach { phrase ->
            assertTrue("403 + $phrase", gated(403, """{"error":{"message":"x ${phrase.uppercase()} y"}}"""))
            assertFalse("401 + $phrase", gated(401, """{"error":{"message":"$phrase"}}"""))
        }
        val cases = fixture.getValue("clientGateCases").jsonArray.map { it.jsonObject }
        assertEquals(8, cases.size)
        cases.forEach { case ->
            val name = "RL2-CLIGATE-" + case.getValue("caseId").jsonPrimitive.content
            val status = case.getValue("status").jsonPrimitive.int
            val body = case.getValue("body").jsonPrimitive.content
            val expected = case.getValue("expect").jsonPrimitive.content == "client_gated"
            assertEquals(name, expected, gated(status, body))
            if (expected) {
                val error = ai.oriveo.community.core.provider.RelayErrorMapper.mapOrDefault(status, body, "https://relay.example.com/v1/messages")
                assertEquals(name, "none", error.relayKeyAccess?.outcome?.value)
                assertFalse(name, RelayProtocolFallback.isRouteRejection(error))
                assertFalse(name, RelayProtocolFallback.isRouteRejection(status, body))
            }
        }
    }

    @Test
    fun `RL2_NEGCACHE_04 production send HTML 200 before output switches candidate and succeeds writing observed`() = runTest {
        val page = fixture.getValue("protocolFallbackCases").jsonArray.map { it.jsonObject }
            .single { it.getValue("caseId").jsonPrimitive.content == "html_page_with_200_tries_next_candidate" }
            .getValue("body").jsonPrimitive.content
        val harness = SendHarness(
            modelTransport = RelayTransport.OpenAIResponses to RelayTransportSource.Reachable,
            candidates = listOf(RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions),
        ) { url, _ -> if (url.endsWith("/responses")) HtmlReply(page) else SseReply(CHAT_OK) }
        val delivered = harness.send(image = false)

        assertEquals(ChatMessageState.Delivered, delivered.state)
        assertEquals("ok", delivered.text)
        assertEquals(listOf("/responses", "/chat/completions"), harness.requests.map { "/" + it.first.substringAfter("/v1/") })
        coVerify(exactly = 1) {
            harness.providerRepository.recordRelayProtocolFallback(
                "c1", "m1", RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions,
            )
        }
        assertTrue(harness.cache.entries().isEmpty())
    }

    @Test
    fun `RL2_NEGCACHE_04 production send 404 switches candidate and succeeds writing observed`() = runTest {
        val harness = SendHarness(
            modelTransport = RelayTransport.OpenAIResponses to RelayTransportSource.Reachable,
            candidates = listOf(RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions),
        ) { url, _ ->
            if (url.endsWith("/responses")) JsonReply(404, """{"error":{"message":"not found"}}""") else SseReply(CHAT_OK)
        }
        val delivered = harness.send(image = false)

        assertEquals(ChatMessageState.Delivered, delivered.state)
        assertEquals("ok", delivered.text)
        assertEquals(2, harness.requests.size)
        assertTrue(harness.requests[1].first, harness.requests[1].first.endsWith("/chat/completions"))
        coVerify(exactly = 1) {
            harness.providerRepository.recordRelayProtocolFallback(
                "c1", "m1", RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions,
            )
        }
        assertTrue(harness.cache.entries().isEmpty())
        // Write-back path: the model's protocol becomes the new protocol with source observed.
        val written = RelayProtocolFallback.applyingObserved(
            harness.provider, "m1", RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions,
        )
        val model = written.models.single { it.id == "m1" }
        assertEquals(RelayTransport.OpenAIChatCompletions, model.relayTransport)
        assertEquals(RelayTransportSource.Observed, model.relayTransportSource)
        // A user source is not overwritten by the write-back.
        val user = harness.provider.copy(
            models = harness.provider.models.map { it.copy(relayTransportSource = RelayTransportSource.User) },
        )
        assertEquals(
            user,
            RelayProtocolFallback.applyingObserved(user, "m1", RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions),
        )
        // If the model's effective protocol changed during the send (e.g. the user changed the protocol / re-detected), the write-back is void.
        val changed = harness.provider.copy(
            models = harness.provider.models.map { it.copy(relayTransport = RelayTransport.AnthropicMessages) },
        )
        assertEquals(
            changed,
            RelayProtocolFallback.applyingObserved(changed, "m1", RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions),
        )
    }

    @Test
    fun `RL2_NEGCACHE_03 imageRecordCases driven by caseId`() {
        fixture.getValue("imageRecordCases").jsonArray.map { it.jsonObject }.forEach { case ->
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val engineImage = case["engineDeclarationImage"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.booleanOrNull
            val override = case["override"]?.takeUnless { it is JsonNull }?.jsonObject
            val provider = relayProvider(engineProfile = engineImage?.let { "ollama" })
            val model = AIModel(
                id = "m1",
                name = "m1",
                capabilities = if (case.getValue("modelDeclaresImage").jsonPrimitive.boolean) {
                    listOf(ModelCapability.Text, ModelCapability.Image)
                } else {
                    listOf(ModelCapability.Text)
                },
                engineDeclaration = engineImage?.let { EngineDeclaration(image = it) },
                relayCapabilityOverrides = override?.let {
                    RelayCapabilityOverrides(
                        image = it.getValue("value").jsonPrimitive.boolean,
                        testedKeys = if (it.getValue("source").jsonPrimitive.content == "tested") setOf("image") else emptySet(),
                    )
                },
            )
            assertEquals(
                caseId,
                case.getValue("expectRecord").jsonPrimitive.boolean,
                ai.oriveo.community.core.data.repository.relayImageRejectionRecords(
                    provider = provider,
                    model = model,
                    rejected = case.getValue("rejected").jsonPrimitive.boolean,
                    outputStarted = case.getValue("outputStarted").jsonPrimitive.boolean,
                    protocolSwitched = case.getValue("protocolSwitched").jsonPrimitive.boolean,
                ),
            )
        }
    }

    @Test
    fun `RL2_NEGCACHE_03 image rejected again after a protocol switch records no image and shows no hint card`() = runTest {
        val harness = SendHarness(
            modelTransport = RelayTransport.OpenAIResponses to RelayTransportSource.Reachable,
            candidates = listOf(RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions),
        ) { url, _ ->
            if (url.endsWith("/responses")) {
                JsonReply(404, """{"error":{"message":"not found"}}""")
            } else {
                JsonReply(400, """{"error":{"message":"image input is not supported"}}""")
            }
        }
        val failed = harness.send(image = true)

        assertEquals(2, harness.requests.size)
        assertEquals(ChatMessageState.Failed, failed.state)
        assertTrue(harness.cache.entries().toString(), harness.cache.entries().isEmpty())
        assertTrue(failed.errorDetail != ChatRepository.RELAY_IMAGE_UNSUPPORTED_DETAIL)
    }

    @Test
    fun `RL2_NEGCACHE_04 user source does not switch and switching happens only once`() = runTest {
        val user = SendHarness(
            modelTransport = RelayTransport.OpenAIResponses to RelayTransportSource.User,
            candidates = listOf(RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions),
        ) { _, _ -> JsonReply(404, """{"error":{"message":"not found"}}""") }
        assertEquals(ChatMessageState.Failed, user.send(image = false).state)
        assertEquals(1, user.requests.size)

        val twice = SendHarness(
            modelTransport = RelayTransport.OpenAIResponses to RelayTransportSource.Reachable,
            candidates = listOf(RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions),
        ) { _, _ -> JsonReply(404, """{"error":{"message":"not found"}}""") }
        assertEquals(ChatMessageState.Failed, twice.send(image = false).state)
        assertEquals("at most one protocol switch per message", 2, twice.requests.size)
        coVerify(exactly = 0) { twice.providerRepository.recordRelayProtocolFallback(any(), any(), any(), any()) }
        assertTrue(twice.cache.entries().isEmpty())
    }

    // ── First send of an unverified model (RL2-FIRSTSEND): production ChatRepository + production outbound layer + fake upstream; the family table reads cached entries only ──

    /** Cached by-model family table (production first send reads the cache only and sends no request); the test puts it directly into the shared lookup and restores it afterwards. */
    private inline fun <T> withCachedFamilies(families: Map<String, String>?, block: () -> T): T {
        val field = ai.oriveo.community.core.data.remote.RelayModelFamilyLookup::class.java.getDeclaredField("families")
            .apply { isAccessible = true }
        val shared = ai.oriveo.community.core.data.remote.RelayModelFamilyLookup.shared
        val previous = field.get(shared)
        field.set(shared, families)
        try {
            return block()
        } finally {
            field.set(shared, previous)
        }
    }

    private fun path(url: String) = "/" + url.substringAfter("/v1/")

    private fun turn(vararg attachments: Attachment) = listOf(
        ChatMessage(
            id = "u1", role = ai.oriveo.community.core.model.ChatRole.User, text = "read",
            providerKind = ProviderKind.Relay, providerName = "relay", modelName = CLAUDE, state = ChatMessageState.Delivered,
            attachments = attachments.toList(),
        ),
    )

    @Test
    fun `RL2-FIRSTSEND-01 Claude family auto one request via messages with max_tokens succeeds writing Messages observed`() = runTest {
        withCachedFamilies(mapOf(CLAUDE to "anthropic")) {
            val harness = SendHarness(
                connectionTransport = RelayTransport.Auto,
                modelID = CLAUDE,
                candidates = listOf(RelayTransport.AnthropicMessages, RelayTransport.OpenAIChatCompletions),
            ) { _, _ -> SseReply(MESSAGES_OK) }
            val delivered = harness.send(image = false)

            assertEquals(ChatMessageState.Delivered, delivered.state)
            assertEquals(listOf("/messages"), harness.requests.map { path(it.first) })
            val body = Json.parseToJsonElement(harness.requests.single().second).jsonObject
            assertTrue(body.toString(), body.getValue("max_tokens").jsonPrimitive.int > 0)
            coVerify(exactly = 1) {
                harness.providerRepository.recordRelayProtocolFallback(
                    "c1", CLAUDE, RelayTransport.OpenAIChatCompletions, RelayTransport.AnthropicMessages,
                )
            }
            val written = RelayProtocolFallback.applyingObserved(
                harness.provider, CLAUDE, RelayTransport.OpenAIChatCompletions, RelayTransport.AnthropicMessages,
            ).models.single()
            assertEquals(RelayTransport.AnthropicMessages, written.relayTransport)
            assertEquals(RelayTransportSource.Observed, written.relayTransportSource)
        }
    }

    @Test
    fun `RL2-FIRSTSEND-02 messages returns 404 switches to next candidate chat succeeds 2 requests total records observed Chat and 400 does not fall back`() = runTest {
        withCachedFamilies(mapOf(CLAUDE to "anthropic")) {
            val harness = SendHarness(
                connectionTransport = RelayTransport.Auto,
                modelID = CLAUDE,
                candidates = listOf(RelayTransport.AnthropicMessages, RelayTransport.OpenAIChatCompletions),
            ) { url, _ ->
                if (url.endsWith("/messages")) JsonReply(404, """{"error":{"message":"not found"}}""") else SseReply(CHAT_OK)
            }
            val delivered = harness.send(image = false)

            assertEquals(ChatMessageState.Delivered, delivered.state)
            assertEquals(listOf("/messages", "/chat/completions"), harness.requests.map { path(it.first) })
            // The write-back after the protocol switch = observed Chat; the Messages write-back for a successful first send no longer happens.
            coVerify(exactly = 1) {
                harness.providerRepository.recordRelayProtocolFallback(
                    "c1", CLAUDE, RelayTransport.OpenAIChatCompletions, RelayTransport.OpenAIChatCompletions,
                )
            }
            coVerify(exactly = 0) {
                harness.providerRepository.recordRelayProtocolFallback(any(), any(), any(), RelayTransport.AnthropicMessages)
            }
            val written = RelayProtocolFallback.applyingObserved(
                harness.provider, CLAUDE, RelayTransport.OpenAIChatCompletions, RelayTransport.OpenAIChatCompletions,
            ).models.single()
            assertEquals(RelayTransport.OpenAIChatCompletions, written.relayTransport)
            assertEquals(RelayTransportSource.Observed, written.relayTransportSource)

            val badRequest = SendHarness(
                connectionTransport = RelayTransport.Auto,
                modelID = CLAUDE,
                candidates = listOf(RelayTransport.AnthropicMessages, RelayTransport.OpenAIChatCompletions),
            ) { _, _ -> JsonReply(400, """{"error":{"message":"bad request"}}""") }
            assertEquals(ChatMessageState.Failed, badRequest.send(image = false).state)
            assertEquals("400 does not switch protocol", listOf("/messages"), badRequest.requests.map { path(it.first) })
            coVerify(exactly = 0) { badRequest.providerRepository.recordRelayProtocolFallback(any(), any(), any(), any()) }
        }
    }

    @Test
    fun `RL2-FIRSTSEND-03 unknown family uses chat completions and success writes no protocol`() = runTest {
        withCachedFamilies(null) {
            val harness = SendHarness(connectionTransport = RelayTransport.Auto, modelID = CLAUDE) { _, _ -> SseReply(CHAT_OK) }
            val delivered = harness.send(image = false)

            assertEquals(ChatMessageState.Delivered, delivered.state)
            assertEquals(listOf("/chat/completions"), harness.requests.map { path(it.first) })
            coVerify(exactly = 0) { harness.providerRepository.recordRelayProtocolFallback(any(), any(), any(), any()) }
            coVerify(exactly = 0) { harness.providerRepository.setRelayModelTransport(any(), any(), any()) }
        }
    }

    @Test
    fun `RL2-FIRSTSEND-04 OpenAI family one chat completions request writes no protocol`() = runTest {
        withCachedFamilies(mapOf(GPT to "openai")) {
            val harness = SendHarness(
                connectionTransport = RelayTransport.Auto,
                modelID = GPT,
                candidates = listOf(RelayTransport.OpenAIResponses, RelayTransport.OpenAIChatCompletions),
            ) { _, _ -> SseReply(CHAT_OK) }
            val delivered = harness.send(image = false)

            assertEquals(ChatMessageState.Delivered, delivered.state)
            assertEquals(listOf("/chat/completions"), harness.requests.map { path(it.first) })
            coVerify(exactly = 0) { harness.providerRepository.recordRelayProtocolFallback(any(), any(), any(), any()) }
        }
    }

    @Test
    fun `RL2-FIRSTSEND-06 Claude family image send fails with 400 image negative cache uses the Messages key records no observed vision entry hidden and advanced page vision row detected`() = runTest {
        withCachedFamilies(mapOf(CLAUDE to "anthropic")) {
            val harness = SendHarness(
                connectionTransport = RelayTransport.Auto,
                modelID = CLAUDE,
                candidates = listOf(RelayTransport.AnthropicMessages, RelayTransport.OpenAIChatCompletions),
            ) { _, _ -> JsonReply(400, """{"error":{"message":"image input is not supported"}}""") }
            val failed = harness.send(image = true)

            assertEquals(ChatMessageState.Failed, failed.state)
            assertEquals(listOf("/messages"), harness.requests.map { path(it.first) })
            val messagesKey = RelayNegativeCache.Key("c1", CLAUDE, RelayTransport.AnthropicMessages.value)
            assertEquals(listOf(messagesKey to RelayNegativeCache.Kind.Image), harness.cache.entries().map { it.key to it.kind })
            assertEquals(messagesKey, RelayNegativeCache.keyFor(harness.provider, harness.model))
            coVerify(exactly = 0) { harness.providerRepository.recordRelayProtocolFallback(any(), any(), any(), any()) }

            // The vision entry reads by Messages: both the envelope key and the negative-cache key are anthropic_messages, so this image rejection is read.
            assertEquals(RelayTransport.AnthropicMessages.value, ai.oriveo.community.core.provider.RelayRuntimeSupport.envelopeKey(harness.provider, harness.model))
            assertTrue(harness.cache.isRejected(RelayNegativeCache.keyFor(harness.provider, harness.model)!!, RelayNegativeCache.Kind.Image))
            // Vision entry: same store, same key reads the rejection -> hidden; with an empty store it is visible (the hiding is indeed caused by this negative cache).
            val resolver = { cache: RelayNegativeCache ->
                ChatModelCapabilityResolver(
                    metadata = MetadataClient(),
                    runtimeConfigProvider = { runtimeConfig(true) },
                    negativeCache = cache,
                )
            }
            assertFalse(resolver(harness.cache).supportsImage(harness.provider, harness.model, identity(harness.provider)))
            val empty = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 2_000L })
            assertTrue(resolver(empty).supportsImage(harness.provider, harness.model, identity(harness.provider)))

            // The advanced page's vision row source = detected (same-protocol read).
            val board = ai.oriveo.community.feature.providers.detail.RelayModelAdvancedBoard.build(
                provider = harness.provider,
                model = harness.model,
                nowSeconds = 2_000L,
                probe = null,
                facts = ai.oriveo.community.feature.providers.detail.RelayCatalogCapabilityFacts(
                    metadata = MetadataClient(),
                    negativeCache = harness.cache,
                    identityFor = { identity(harness.provider) },
                ),
                negativeCache = harness.cache,
                toolMemory = null,
                automaticReasoning = emptyList(),
            )
            assertEquals(
                ai.oriveo.community.feature.providers.detail.RelayAdvancedSource.Detected,
                board.capabilities.single { it.capability == ai.oriveo.community.feature.providers.detail.RelayAdvancedCapability.Image }.source,
            )
        }
    }

    @Test
    fun `RL2-FIRSTSEND-05 attachments first send Messages while no file has extracted text and Messages cannot send natively so first send is unchanged`() {
        withCachedFamilies(mapOf(CLAUDE to "anthropic")) {
            val provider = relayProvider(engineProfile = null, transport = RelayTransport.Auto)
            val model = AIModel(id = CLAUDE, name = CLAUDE, capabilities = listOf(ModelCapability.Text))
            val scanned = Attachment(
                id = "f1", kind = AttachmentKind.File, fileName = "scan.pdf", mimeType = "application/pdf",
                extractionErrorCode = "no_text",
            )
            val extracted = Attachment(
                id = "f2", kind = AttachmentKind.File, fileName = "notes.txt", mimeType = "text/plain", base64Data = "aGk=",
            )
            assertEquals(RelayTransport.AnthropicMessages, RelayFirstSendTransport.forSend(provider, model, emptyList()))
            assertEquals(RelayTransport.OpenAIChatCompletions, RelayFirstSendTransport.forSend(provider, model, turn(scanned)))
            assertEquals(RelayTransport.AnthropicMessages, RelayFirstSendTransport.forSend(provider, model, turn(scanned, extracted)))
            // Only the first send is affected: the negative-cache read key and the advanced page still read the one that ignores attachments.
            assertEquals(RelayTransport.AnthropicMessages, RelayFirstSendTransport.resolve(provider, model))
        }
    }

    private sealed interface Reply
    private data class JsonReply(val status: Int, val body: String) : Reply
    private data class SseReply(val body: String) : Reply
    /** Gateway SPA fallback page: 200 + text/html. */
    private data class HtmlReply(val body: String) : Reply

    /** Production ChatRepository + production RelayTransportCoordinator; the upstream is a MockEngine. */
    private inner class SendHarness(
        modelCapabilities: List<ModelCapability> = listOf(ModelCapability.Text),
        modelTransport: Pair<RelayTransport, RelayTransportSource>? = null,
        candidates: List<RelayTransport> = listOf(RelayTransport.OpenAIChatCompletions),
        private val service: ai.oriveo.community.core.provider.ProviderService? = null,
        connectionTransport: RelayTransport = RelayTransport.OpenAIChatCompletions,
        modelID: String = "m1",
        private val reply: (url: String, body: String) -> Reply,
    ) {
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 2_000L })
        val requests = mutableListOf<Pair<String, String>>()
        val model = AIModel(
            id = modelID,
            name = modelID,
            capabilities = modelCapabilities,
            relayTransport = modelTransport?.first,
            relayTransportSource = modelTransport?.second,
        )
        val provider = relayProvider(engineProfile = null, transport = connectionTransport).copy(
            apiKey = "sk-relay",
            baseUrlText = "https://relay.example.com/v1",
            models = listOf(model),
        )
        val providerRepository = mockk<ProviderRepository>(relaxed = true)
        private val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        private val updates = mutableListOf<ChatMessage>()
        private val json = Json { ignoreUnknownKeys = true }
        private val coordinator = RelayTransportCoordinator(
            client = HttpClient(
                MockEngine { request ->
                    val body = when (val content = request.body) {
                        is TextContent -> content.text
                        is OutgoingContent.ByteArrayContent -> content.bytes().decodeToString()
                        else -> ""
                    }
                    val url = request.url.toString()
                    requests += url to body
                    when (val r = reply(url, body)) {
                        is JsonReply -> respond(
                            r.body,
                            HttpStatusCode.fromValue(r.status),
                            headersOf(HttpHeaders.ContentType, "application/json"),
                        )
                        is SseReply -> respond(r.body, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
                        is HtmlReply -> respond(r.body, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/html; charset=utf-8"))
                    }
                },
            ),
            json = json,
            transportRegistry = TransportRegistry(json),
            negativeCache = cache,
            protocolCandidates = { _, _, _ -> candidates },
        )

        suspend fun send(image: Boolean): ChatMessage {
            every { providerRepository.serviceFor(any<Provider>(), any()) } returns (service ?: coordinator)
            every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
            coEvery { conversationRepository.updateMessage(any(), capture(updates)) } returns Unit
            val repository = ChatRepository(
                conversationRepository = conversationRepository,
                providerRepository = providerRepository,
                attachmentStore = mockk<AttachmentStore>(relaxed = true),
                relayNegativeCache = cache,
            )
            repository.sendMessage(
                conversation = Conversation(
                    id = "conversation-1", title = "t", providerID = provider.id,
                    providerKind = ProviderKind.Relay, modelID = model.id,
                ),
                text = "what is this",
                provider = provider,
                modelID = model.id,
                existingMessages = emptyList(),
                attachments = if (image) {
                    listOf(Attachment(id = "img", kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png", base64Data = IMAGE_BASE64))
                } else {
                    null
                },
                requestOptions = ChatRequestOptions(
                    activeModel = model,
                    capabilityEvidenceIdentity = identity(provider),
                ),
                outputs = ConversationStreamingOutputs(
                    streamingText = MutableStateFlow(""),
                    streamingMessageId = MutableStateFlow(null),
                ),
            )
            return updates.last()
        }
    }

    private fun relayProvider(engineProfile: String?, transport: RelayTransport = RelayTransport.OpenAIChatCompletions) = Provider(
        id = "c1",
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        relayRequested = RelayRequestedConfig(
            transport = transport,
            resolvedAPIBaseURL = "https://relay.example.com/v1",
            engineProfile = engineProfile,
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

    private fun runtimeConfig(image: Boolean) = MetadataClient.RelayRuntimeConfig(
        version = "test",
        officialProviderWhitelist = emptyList(),
        transportEnvelopes = mapOf(
            "openai_chat_completions" to MetadataClient.RelayTransportEnvelope(image = image, textFileInline = true),
            "openai_responses" to MetadataClient.RelayTransportEnvelope(image = image, nativeFile = true, textFileInline = true),
            "anthropic_messages" to MetadataClient.RelayTransportEnvelope(image = image, nativeFile = true, textFileInline = true),
        ),
        transportRules = emptyMap(),
        verificationPolicy = MetadataClient.RelayVerificationPolicy(),
        featureGatingPolicy = MetadataClient.RelayFeatureGatingPolicy(),
    )

    private companion object {
        const val IMAGE_BASE64 = "iVBORw0KGgo="
        const val CHAT_OK = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
        const val MESSAGES_OK =
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n" +
                "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" +
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" +
                "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n" +
                "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" +
                "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        const val CLAUDE = "claude-sonnet-4"
        const val GPT = "gpt-4.1"
    }
}
