package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
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
import java.nio.file.Files
import java.nio.file.Paths
import java.util.Collections
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.job
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Relay web-search probe core (`shared/test-fixtures/relay/web-probe.v1.json`).
 * EV / GW / SHAPE replay the fixture SSE against a fake upstream through the production [ProviderRepository.runRelayWebProbe] + production [RelayService] (the same builder and
 * stream parser as chat); record and override assertions come from the store after the repository write-back and from models round-tripped through [ProviderMapper].
 */
class RelayWebProbeContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    private fun loadFixture(name: String): JsonObject {
        var dir = Paths.get("").toAbsolutePath()
        repeat(8) {
            val candidate = dir.resolve("shared/test-fixtures/relay/$name")
            if (Files.exists(candidate)) {
                return Json.parseToJsonElement(String(Files.readAllBytes(candidate), Charsets.UTF_8)).jsonObject
            }
            dir = dir.parent ?: return@repeat
        }
        error("fixture $name not found")
    }

    private val fixture: JsonObject by lazy { loadFixture("web-probe.v1.json") }
    private val builtins: JsonObject by lazy { loadFixture("capability-test.v1.json").getValue("builtins").jsonObject }

    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content
    private fun JsonObject.cases(key: String): List<JsonObject> = getValue(key).jsonArray.map { it.jsonObject }
    private fun transportOf(wire: String): RelayTransport = RelayTransport.entries.single { it.value == wire }

    /** Runs case by case and reports the failing case names together at the end, so a red run shows how many are still failing. */
    private fun checkAll(prefix: String, cases: List<Pair<String, () -> Unit>>) {
        val failures = mutableListOf<String>()
        cases.forEach { (caseId, body) ->
            try {
                body()
            } catch (error: AssertionError) {
                failures += "$prefix$caseId: ${error.message}"
            } catch (error: Exception) {
                failures += "$prefix$caseId: ${error::class.simpleName} ${error.message}"
            }
        }
        assertTrue("${failures.size}/${cases.size} failed\n" + failures.joinToString("\n"), failures.isEmpty())
    }

    // ── SHAPE ──

    @Test
    fun `RL2-WEBPROBE-SHAPE probe request body = chat builder + fragment + fixed prompt + output cap`() {
        val request = fixture.getValue("request").jsonObject
        val prompt = request.string("prompt")
        val limit = request.getValue("outputLimit").jsonPrimitive.content.toInt()
        assertEquals(prompt, RelayWebProbe.PROMPT)
        assertEquals(limit, RelayWebProbe.OUTPUT_LIMIT)
        assertEquals(request.getValue("timeoutSeconds").jsonPrimitive.content.toInt(), RelayWebProbe.TIMEOUT_SECONDS)
        checkAll(
            "RL2-WEBPROBE-SHAPE-",
            fixture.cases("requestShapes").map { case ->
                case.string("caseId") to {
                    val transport = transportOf(case.string("transport"))
                    val harness = Harness(transport, case.getValue("fragment").jsonObject)
                    harness.respondWith(sseResponse(listOf("data: [DONE]", "")))
                    runBlocking { harness.repository.runRelayWebProbe(connectionID, modelID) }
                    assertEquals("attempts", 1, harness.sent.size)
                    val body = harness.sent.single().body.jsonObject
                    case.getValue("mustContain").jsonObject.forEach { (key, expected) ->
                        val actual = body[key]
                        if (expected is JsonArray) {
                            val items = (actual as? JsonArray).orEmpty()
                            expected.forEach { assertTrue("$key contains $it in $actual", it in items) }
                        } else {
                            assertEquals(key, expected, actual)
                        }
                    }
                    val text = harness.sent.single().text
                    if (case.getValue("mustContainPrompt").jsonPrimitive.content.toBoolean()) {
                        assertEquals("prompt once", 1, text.split(prompt).size - 1)
                    }
                    case.getValue("mustNotContain").jsonArray.map { it.jsonPrimitive.content }.forEach { path ->
                        val value = path.removePrefix("builtins.").split('.')
                            .fold<String, JsonElement?>(builtins) { node, segment -> (node as? JsonObject)?.get(segment) }
                            ?.jsonPrimitive?.content
                        assertTrue("$path resolves", !value.isNullOrEmpty())
                        assertFalse("$path absent", text.contains(value!!))
                    }
                    val limitPath = MAX_TOKENS_PATH.getValue(transport)
                    val sentLimit = limitPath.fold<String, JsonElement?>(body) { node, segment -> (node as? JsonObject)?.get(segment) }
                    assertEquals("output limit", JsonPrimitive(limit), sentLimit)
                }
            },
        )
    }

    // ── EV / GW ──

    @Test
    fun `RL2-WEBPROBE-EV verdict depends only on evidence from the production parser`() {
        checkAll(
            "RL2-WEBPROBE-EV-",
            fixture.cases("evidenceCases").map { case ->
                case.string("caseId") to {
                    val transport = transportOf(case.string("transport"))
                    val harness = Harness(transport, RelayWebFragments.template(transport)!!)
                    harness.respondWith(evidenceResponse(case))
                    val outcome = runBlocking {
                        harness.repository.runRelayWebProbe(connectionID, modelID, deadlineMillis = SHORT_DEADLINE_MILLIS)
                    }
                    assertExpect(case.getValue("expect").jsonObject, outcome, harness)
                }
            },
        )
    }

    @Test
    fun `RL2-WEBPROBE-GW recorded gateway traffic through the production parser`() {
        checkAll(
            "RL2-WEBPROBE-GW-",
            fixture.getValue("gatewayRecordings").jsonObject.entries.map { (key, value) ->
                key to {
                    val recording = value.jsonObject
                    val expect = recording.getValue("expect").jsonObject
                    val transport = transportOf(expect.string("transport"))
                    val response = recording.getValue("response").jsonObject
                    val harness = Harness(transport, RelayWebFragments.template(transport)!!)
                    harness.respondWith(
                        Reply(
                            status = response.getValue("status").jsonPrimitive.content.toInt(),
                            contentType = response.string("contentType"),
                            body = response.getValue("sse").jsonArray.joinToString("") { it.jsonPrimitive.content + "\n\n" },
                        ),
                    )
                    val outcome = runBlocking { harness.repository.runRelayWebProbe(connectionID, modelID) }
                    val sentBody = harness.sent.single().body.jsonObject
                    recording.getValue("request").jsonObject.getValue("body").jsonObject
                        .filterKeys { it != "model" }
                        .forEach { (k, v) -> assertEquals("request.$k", v, sentBody[k]) }
                    assertExpect(expect, outcome, harness)
                }
            },
        )
    }

    private fun assertExpect(expect: JsonObject, outcome: RelayWebProbeOutcome, harness: Harness) {
        val completed = outcome as? RelayWebProbeOutcome.Completed
            ?: throw AssertionError("expected a completed probe, got $outcome")
        val result = expect.string("result")
        assertEquals("result", result, completed.result.wire)
        expect["evidenceUrls"]?.let { urls ->
            assertEquals("evidenceUrls", urls.jsonArray.map { it.jsonPrimitive.content }, completed.evidenceUrls)
        }
        val record = harness.records.read(harness.key)
        val override = harness.current().models.single().relayCapabilityOverrides
        when (result) {
            "searched", "rejected" -> {
                assertEquals("record", result, record?.result?.wire)
                assertEquals("record source", "tested", record?.source?.wire)
                assertEquals("record at", NOW, record?.at)
                assertEquals("record hash", RelayWebProbe.fragmentHash(harness.fragment!!), record?.fragmentHash)
                assertEquals("override web", result == "searched", override?.web)
                assertTrue("override source tested", "web" in override?.testedKeys.orEmpty())
            }
            "silent" -> {
                assertEquals("record", "silent", record?.result?.wire)
                assertNull("no override", override?.web)
            }
            else -> {
                assertNull("nothing recorded", record)
                assertNull("no override", override?.web)
            }
        }
        assertEquals("one attempt", 1, harness.sent.size)
    }

    // ── HASH ──

    @Test
    fun `RL2-WEBPROBE-HASH fragment hash = SHA-256 of the canonical JSON`() {
        checkAll(
            "RL2-WEBPROBE-HASH-",
            fixture.getValue("fragmentHash").jsonObject.cases("cases").map { case ->
                case.string("caseId") to {
                    val fragment = case.getValue("fragment").jsonObject
                    assertEquals("canonical", case.string("canonical"), RelayWebProbe.canonicalJson(fragment))
                    assertEquals("sha256", case.string("sha256"), RelayWebProbe.fragmentHash(fragment))
                }
            },
        )
    }

    // ── MERGE ──

    @Test
    fun `RL2-WEBPROBE-MERGE same hash merges by rule and a different hash replaces the whole record`() {
        fun recordOf(element: JsonObject, at: Long) = RelayWebProbeRecord(
            result = RelayWebProbeResult.entries.single { it.wire == element.string("result") },
            source = RelayWebProbeSource.entries.single { it.wire == element.string("source") },
            at = at,
            fragmentHash = element.string("fragmentHash"),
        )
        checkAll(
            "RL2-WEBPROBE-MERGE-",
            fixture.getValue("record").jsonObject.cases("mergeCases").map { case ->
                case.string("caseId") to {
                    val store = RelayWebProbeRecordStore(RelayWebProbeRecordStore.MemoryStore()) { NOW }
                    val key = RelayWebProbeRecordStore.Key(connectionID, modelID, RelayTransport.AnthropicMessages.value)
                    (case["existing"] as? JsonObject)?.let { store.record(key, recordOf(it, 1L)) }
                    val incoming = recordOf(case.getValue("incoming").jsonObject, 2L)
                    store.record(key, incoming)
                    val stored = store.read(key)
                    val expect = case.getValue("expect").jsonObject
                    assertEquals("result", expect.string("result"), stored?.result?.wire)
                    assertEquals("source", expect.string("source"), stored?.source?.wire)
                    // Read side: hash != current fragment = untested.
                    assertEquals(stored, store.current(key, incoming.fragmentHash))
                    assertNull(store.current(key, "0".repeat(64)))
                }
            },
        )
        // Deleted together with the connection.
        val store = RelayWebProbeRecordStore(RelayWebProbeRecordStore.MemoryStore()) { NOW }
        val key = RelayWebProbeRecordStore.Key(connectionID, modelID, RelayTransport.OpenAIChatCompletions.value)
        val other = key.copy(connectionId = "other")
        val record = RelayWebProbeRecord(RelayWebProbeResult.Searched, RelayWebProbeSource.Tested, NOW, "h")
        store.record(key, record)
        store.record(other, record)
        store.clearConnection(connectionID)
        assertNull(store.read(key))
        assertEquals(record, store.read(other))
    }

    // ── FORMS ──

    @Test
    fun `RL2-WEBPROBE-FORMS only RELAY is probed and without a fragment nothing is listed and zero requests are sent`() {
        val forms = fixture.getValue("forms").jsonObject
        assertEquals(listOf("RELAY"), forms.getValue("probe").jsonArray.map { it.jsonPrimitive.content })
        val byForm = mapOf(
            "RELAY" to Provider(id = connectionID, kind = ProviderKind.Relay),
            "BYOK" to Provider(id = connectionID, kind = ProviderKind.OpenAI),
            "SUB" to Provider(id = connectionID, kind = ProviderKind.OpenAI, authMode = ProviderAuthMode.Subscription),
        )
        forms.getValue("probe").jsonArray.forEach { assertTrue(it.toString(), RelayWebProbe.isProbeForm(byForm.getValue(it.jsonPrimitive.content))) }
        // The community edition has no FREE / MANAGED connection kinds, so only the forms it can build are checked.
        forms.getValue("never").jsonArray.filter { it.jsonPrimitive.content in byForm }.forEach { assertFalse(it.toString(), RelayWebProbe.isProbeForm(byForm.getValue(it.jsonPrimitive.content))) }

        // Relay connection but the current protocol has no fragment: not listed, zero requests, nothing written.
        val harness = Harness(RelayTransport.OpenAIChatCompletions, fragment = null)
        harness.respondWith(sseResponse(listOf("data: [DONE]", "")))
        val outcome = runBlocking { harness.repository.runRelayWebProbe(connectionID, modelID) }
        assertEquals(RelayWebProbeOutcome.NotListed, outcome)
        assertTrue(harness.sent.isEmpty())
        assertNull(harness.records.read(harness.key))

        // Non-relay connection: likewise not listed, zero requests.
        val official = Harness(RelayTransport.OpenAIChatCompletions, RelayWebFragments.template(RelayTransport.OpenAIChatCompletions)) {
            it.copy(kind = ProviderKind.OpenAI, relayRequested = null, relayKind = null)
        }
        official.respondWith(sseResponse(listOf("data: [DONE]", "")))
        assertEquals(RelayWebProbeOutcome.NotListed, runBlocking { official.repository.runRelayWebProbe(connectionID, modelID) })
        assertTrue(official.sent.isEmpty())
    }

    // ── OVERRIDE ──

    @Test
    fun `RL2-WEBPROBE-OVERRIDE searched and rejected write web (tested) and a user-set web is untouched`() {
        fun probe(result: RelayWebProbeResult) =
            RelayWebProbeOutcome.Completed(result, RelayCapabilityTestReason.Ok, 200, emptyList(), "h", NOW)

        val searched = RelayWebProbe.applyingResult(null, probe(RelayWebProbeResult.Searched))
        assertEquals(true, searched?.web)
        assertEquals("tested", searched?.sourceOf("web"))
        val rejected = RelayWebProbe.applyingResult(RelayCapabilityOverrides(image = true), probe(RelayWebProbeResult.Rejected))
        assertEquals(false, rejected?.web)
        assertEquals(true, rejected?.image)
        assertEquals("tested", rejected?.sourceOf("web"))
        listOf(RelayWebProbeResult.Silent, RelayWebProbeResult.Undetermined).forEach {
            assertNull(it.wire, RelayWebProbe.applyingResult(null, probe(it))?.web)
        }
        val user = RelayCapabilityOverrides(web = false)
        assertEquals(user, RelayWebProbe.applyingResult(user, probe(RelayWebProbeResult.Searched)))
        // A previously tested value is overwritten by the new result.
        assertEquals(false, RelayWebProbe.applyingResult(searched, probe(RelayWebProbeResult.Rejected))?.web)
        // Restoring auto clears the tested web.
        assertNull(RelayCapabilityTest.restoringAutomatic(searched))

        // Production path: a model with user-set web=false probes as searched; the override is untouched and the record is still written.
        val harness = Harness(RelayTransport.OpenAIChatCompletions, RelayWebFragments.template(RelayTransport.OpenAIChatCompletions)) {
            it.copy(models = it.models.map { m -> m.copy(relayCapabilityOverrides = user) }, catalogModels = it.catalogModels.map { m -> m.copy(relayCapabilityOverrides = user) })
        }
        val searchedCase = fixture.cases("evidenceCases").single { it.string("caseId") == "chat_url_citation_searched" }
        harness.respondWith(evidenceResponse(searchedCase))
        runBlocking { harness.repository.runRelayWebProbe(connectionID, modelID) }
        assertEquals(user, harness.current().models.single().relayCapabilityOverrides)
        assertEquals(RelayWebProbeResult.Searched, harness.records.read(harness.key)?.result)

        // The override key web round-trips through local storage.
        val roundTrip = with(ProviderMapper) {
            Provider(id = connectionID, kind = ProviderKind.Relay, models = listOf(AIModel(id = modelID, name = modelID, relayCapabilityOverrides = searched)))
                .toEntity(accountID).toDomain("sk")
        }
        assertEquals(searched, roundTrip.models.single().relayCapabilityOverrides)
    }

    // ── CHAT ──

    @Test
    fun `RL2-WEBPROBE-CHAT-01 chat does not attach the fragment when the record is rejected under the current fragment and attaches it otherwise`() {
        val transport = RelayTransport.OpenAIChatCompletions
        val fragment = RelayWebFragments.template(transport)!!
        val currentHash = RelayWebProbe.fragmentHash(fragment)
        fun record(result: RelayWebProbeResult, hash: String = currentHash) =
            RelayWebProbeRecord(result, RelayWebProbeSource.Tested, NOW, hash)
        val cases: List<Triple<String, RelayWebProbeRecord?, Boolean>> = listOf(
            Triple("rejected", record(RelayWebProbeResult.Rejected), false),
            Triple("silent", record(RelayWebProbeResult.Silent), true),
            Triple("searched", record(RelayWebProbeResult.Searched), true),
            Triple("untested", null, true),
            Triple("stale_rejected", record(RelayWebProbeResult.Rejected, "0".repeat(64)), true),
        )
        checkAll(
            "RL2-WEBPROBE-CHAT-01-",
            cases.map { (caseId, existing, sendsFragment) ->
                caseId to {
                    val chat = ChatHarness(transport, fragment)
                    existing?.let { chat.records.record(chat.key, it) }
                    chat.respondWith(sseResponse(listOf("data: [DONE]", "")))
                    chat.send()
                    val body = chat.sent.first().body.jsonObject
                    fragment.forEach { (key, value) ->
                        if (sendsFragment) {
                            assertEquals("$key in $body", value, body[key])
                        } else {
                            assertFalse("$key absent in $body", body.containsKey(key))
                        }
                    }
                }
            },
        )
    }

    @Test
    fun `RL2-WEBPROBE-CHAT-02 relay chat delivered with citations writes searched observed and without citations or on error writes nothing`() {
        val evidence = fixture.cases("evidenceCases").associateBy { it.string("caseId") }
        val transport = RelayTransport.OpenAIChatCompletions
        val fragment = RelayWebFragments.template(transport)!!
        checkAll(
            "RL2-WEBPROBE-CHAT-02-",
            listOf(
                "chat_url_citation_searched" to {
                    val chat = ChatHarness(transport, fragment)
                    chat.respondWith(evidenceResponse(evidence.getValue("chat_url_citation_searched")))
                    chat.send()
                    val record = chat.records.read(chat.key)
                    assertEquals("result", RelayWebProbeResult.Searched, record?.result)
                    assertEquals("source", RelayWebProbeSource.Observed, record?.source)
                    assertEquals("at", NOW, record?.at)
                    assertEquals("hash", RelayWebProbe.fragmentHash(fragment), record?.fragmentHash)
                },
                "chat_text_only_silent" to {
                    val chat = ChatHarness(transport, fragment)
                    chat.respondWith(evidenceResponse(evidence.getValue("chat_text_only_silent")))
                    chat.send()
                    assertTrue("sent", chat.sent.isNotEmpty())
                    assertNull("nothing recorded", chat.records.read(chat.key))
                },
                "chat_503_undetermined" to {
                    val chat = ChatHarness(transport, fragment)
                    chat.respondWith(evidenceResponse(evidence.getValue("chat_503_undetermined")))
                    chat.send()
                    assertTrue("sent", chat.sent.isNotEmpty())
                    assertNull("nothing recorded", chat.records.read(chat.key))
                },
                "no_fragment_with_citation" to {
                    // This turn carried no fragment: citations are not probe evidence.
                    val chat = ChatHarness(transport, fragment = null)
                    chat.respondWith(evidenceResponse(evidence.getValue("chat_url_citation_searched")))
                    chat.send()
                    assertTrue("sent", chat.sent.isNotEmpty())
                    assertNull("nothing recorded", chat.records.read(chat.key))
                },
            ),
        )
    }

    /** Production [ChatRepository.sendMessage] -> production [RelayService] against a fake upstream; fragments and probe records use the production store (in-memory backend). */
    private inner class ChatHarness(transport: RelayTransport, fragment: JsonObject?) {
        val sent: MutableList<SentRequest> = Collections.synchronizedList(mutableListOf())
        private val model = AIModel(id = modelID, name = modelID, isDefault = true)
        val provider = Provider(
            id = connectionID,
            kind = ProviderKind.Relay,
            status = ai.oriveo.community.core.model.ProviderConnectionState.Connected,
            apiKey = "sk-test",
            baseUrlText = "https://relay.example.com",
            relayKind = RelayKind.OpenAICompatible,
            relayRequested = RelayRequestedConfig(transport = transport),
            models = listOf(model),
            catalogModels = listOf(model),
        )
        val records = RelayWebProbeRecordStore(RelayWebProbeRecordStore.MemoryStore()) { NOW }
        private val fragments = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore()).also { store ->
            fragment?.let { store.replace(connectionID, mapOf(transport to it)) }
        }
        val key = RelayWebProbeRecordStore.Key(connectionID, modelID, transport.value)
        @Volatile private var reply: Reply = sseResponse(emptyList())

        fun respondWith(next: Reply) { reply = next }

        private val client = HttpClient(MockEngine { request ->
            sent += SentRequest(request.url.encodedPath, (request.body as? TextContent)?.text.orEmpty())
            val current = reply
            respond(current.body, HttpStatusCode.fromValue(current.status), headersOf(HttpHeaders.ContentType, current.contentType))
        })

        fun send() = runBlocking {
            val providerRepository = mockk<ProviderRepository>(relaxed = true).also {
                every { it.serviceFor(any<Provider>(), any()) } returns RelayService(client, json, TransportRegistry(json))
                every { it.toolCallMemoryVerdict(any(), any()) } returns null
                every { it.currentCapabilityPartitionId() } returns "u1"
            }
            val repository = ai.oriveo.community.core.data.repository.ChatRepository(
                conversationRepository = mockk<ai.oriveo.community.core.data.repository.ConversationRepository>(relaxed = true),
                providerRepository = providerRepository,
                attachmentStore = mockk<ai.oriveo.community.core.data.attachment.AttachmentStore>(relaxed = true),
                relayNegativeCache = RelayNegativeCache(RelayNegativeCache.MemoryStore()),
                relayWebFragmentStore = fragments,
                relayWebProbeRecords = records,
            )
            runCatching {
                repository.sendMessage(
                    conversation = ai.oriveo.community.core.model.Conversation(
                        id = "conversation-web-probe",
                        title = "Relay",
                        providerID = provider.id,
                        providerKind = provider.kind,
                        modelID = modelID,
                    ),
                    text = "What is today's top story?",
                    provider = provider,
                    modelID = modelID,
                    existingMessages = emptyList(),
                    reasoningMode = ai.oriveo.community.core.model.ReasoningMode.Automatic,
                    webSearchEnabled = false,
                    requestOptions = ai.oriveo.community.core.model.ChatRequestOptions(),
                    outputs = ai.oriveo.community.core.streaming.ConversationStreamingOutputs(
                        streamingText = MutableStateFlow(""),
                        streamingMessageId = MutableStateFlow(null),
                    ),
                )
            }
            client.close()
        }
    }

    // ── WIRE / OVERRIDE-clear (wire override clear)──

    private fun evidenceCase(caseId: String): JsonObject = fixture.cases("evidenceCases").single { it.string("caseId") == caseId }

    private fun withModels(provider: Provider, ids: List<String>, overrides: Map<String, RelayCapabilityOverrides> = emptyMap()): Provider =
        provider.copy(
            models = ids.mapIndexed { index, id -> AIModel(id = id, name = id, isDefault = index == 0, relayCapabilityOverrides = overrides[id]) },
            catalogModels = ids.map { AIModel(id = it, name = it, relayCapabilityOverrides = overrides[it]) },
        )

    private fun Harness.overridesOf(id: String): RelayCapabilityOverrides? = current().models.single { it.id == id }.relayCapabilityOverrides
    private fun Harness.catalogOverridesOf(id: String): RelayCapabilityOverrides? = current().catalogModels.single { it.id == id }.relayCapabilityOverrides

    @Test
    fun `RL2-WEBPROBE-WIRE-save after saving probes serially by selection and writes records and history and untested sends zero requests`() {
        val transport = RelayTransport.OpenAIChatCompletions
        val fragment = requireNotNull(RelayWebFragments.template(transport))
        val hash = RelayWebProbe.fragmentHash(fragment)
        val ids = (1..7).map { "m$it" }
        val harness = Harness(transport, fragment) { withModels(it, ids) }
        harness.respondWith(evidenceResponse(evidenceCase("chat_url_citation_searched")))

        runBlocking { harness.repository.relayWebFragmentsSaved(connectionID, setOf(transport.value)).join() }
        assertEquals("first save probes perSave in enabled order", ids.take(5), harness.probedModels())
        ids.take(5).forEach { id ->
            assertEquals(id, RelayWebProbeResult.Searched, harness.records.read(RelayWebProbeRecordStore.Key(connectionID, id, transport.value))?.result)
            assertEquals(id, true, harness.overridesOf(id)?.web)
            assertEquals(id, "tested", harness.overridesOf(id)?.sourceOf("web"))
        }
        ids.drop(5).forEach { id ->
            assertNull(id, harness.records.read(RelayWebProbeRecordStore.Key(connectionID, id, transport.value)))
            assertNull(id, harness.overridesOf(id)?.web)
        }
        assertEquals(
            ids.take(5).map { RelayWebProbeAutoEntry(connectionID, it, transport.value, hash, NOW) }.toSet(),
            harness.history.entries().toSet(),
        )

        // Saving the same fragment again: already-probed models are deduplicated and take no quota; the remaining two are probed.
        harness.sent.clear()
        runBlocking { harness.repository.relayWebFragmentsSaved(connectionID, emptySet()).join() }
        assertEquals(ids.drop(5), harness.probedModels())

        // All probed: saving again sends zero requests.
        harness.sent.clear()
        runBlocking { harness.repository.relayWebFragmentsSaved(connectionID, emptySet()).join() }
        assertTrue(harness.sent.isEmpty())

        // Deleting the connection also clears the automatic history.
        runBlocking { harness.repository.deleteProvider(connectionID) }
        assertTrue(harness.history.entries().isEmpty())
    }

    @Test
    fun `RELAY-AVATAR-STORE-03 deleting a connection clears its local avatar choice`() {
        val store = ai.oriveo.community.core.model.RelayAvatarChoiceStore
        val written = mutableMapOf<String, String?>()
        store.configurePersistenceForTesting(emptyMap()) { key, value -> written[key] = value }
        try {
            val harness = Harness(RelayTransport.OpenAIChatCompletions, null)
            val other = "relay-keep"
            store.select(connectionID, "kite")
            store.select(other, "letter")

            runBlocking { harness.repository.deleteProvider(connectionID) }

            assertNull(store.choice(connectionID))
            assertEquals("letter", store.choice(other))
            val key = ai.oriveo.community.core.model.RelayAvatarResolver.choiceKey(connectionID)
            assertTrue(written.containsKey(key))
            assertNull(written[key])
        } finally {
            store.resetForTesting()
        }
    }

    @Test
    fun `RL2-WEBPROBE-WIRE-enable probes once after lazy verification passes and does not probe on failure or if it did not run`() {
        val transport = RelayTransport.OpenAIChatCompletions

        fun enableHarness(pin: RelayTransport?, pingOk: Boolean): Harness {
            val harness = Harness(transport, RelayWebFragments.template(transport)) {
                withModels(it, listOf(modelID)).let { p ->
                    p.copy(
                        relayRequested = RelayRequestedConfig(),
                        models = p.models.map { m -> m.copy(relayTransport = pin, relayTransportSource = pin?.let { RelayTransportSource.User }) },
                        catalogModels = p.catalogModels.map { m -> m.copy(relayTransport = pin, relayTransportSource = pin?.let { RelayTransportSource.User }) },
                    )
                }
            }
            // Every protocol has a fragment: whichever protocol lazy verification pins, the first-send protocol has a fragment.
            harness.fragments.replace(
                connectionID,
                RelayTransport.entries.mapNotNull { t -> RelayWebFragments.template(t)?.let { t to it } }.toMap(),
            )
            harness.pingOk = pingOk
            harness.respondWith(evidenceResponse(evidenceCase("chat_url_citation_searched")))
            return harness
        }

        val passed = enableHarness(pin = null, pingOk = true)
        runBlocking { passed.repository.probeEnabledRelayModel(connectionID, modelID) }
        passed.awaitProbes()
        assertTrue("lazy verify ran", passed.pings().isNotEmpty())
        assertEquals("passed lazy verify probes once", listOf(modelID), passed.probedModels())
        assertEquals(1, passed.history.entries().size)

        val failed = enableHarness(pin = null, pingOk = false)
        runBlocking { failed.repository.probeEnabledRelayModel(connectionID, modelID) }
        failed.awaitProbes()
        assertTrue("lazy verify ran", failed.pings().isNotEmpty())
        assertEquals("failed lazy verify does not probe", emptyList<String>(), failed.probedModels())
        assertTrue(failed.history.entries().isEmpty())

        val notRun = enableHarness(pin = transport, pingOk = true)
        runBlocking { notRun.repository.probeEnabledRelayModel(connectionID, modelID) }
        notRun.awaitProbes()
        assertEquals("no lazy verify, no probe", emptyList<String>(), notRun.sent.map { "${it.path} probe=${it.isProbe}" })
    }

    /** Another fragment for the same protocol (different hash). */
    private fun variantOf(fragment: JsonObject): JsonObject = JsonObject(fragment + ("x-variant" to JsonPrimitive("b")))

    @Test
    fun `RL2-WEBPROBE-REFRAG-01 fragment changed mid-run so the result writes no record or override and returns stopped fragment`() {
        val transport = RelayTransport.OpenAIChatCompletions
        val fragment = requireNotNull(RelayWebFragments.template(transport))
        val harness = Harness(transport, fragment)
        harness.respondWith(evidenceResponse(evidenceCase("chat_url_citation_searched")))
        harness.onProbe = { harness.fragments.replace(connectionID, mapOf(transport to variantOf(fragment))) }

        val outcome = runBlocking { harness.repository.runRelayWebProbe(connectionID, modelID) }

        assertEquals(RelayWebProbeOutcome.Stopped(RelayWebProbeStopReason.Fragment), outcome)
        assertEquals(listOf(modelID), harness.probedModels())
        assertNull(harness.records.read(harness.key))
        assertNull(harness.overridesOf(modelID)?.web)
    }

    @Test
    fun `RL2-WEBPROBE-REFRAG-02 saving A then B means A's remaining models are not sent and write no history and B probes with the new fragment`() {
        val transport = RelayTransport.OpenAIChatCompletions
        val fragmentA = requireNotNull(RelayWebFragments.template(transport))
        val fragmentB = variantOf(fragmentA)
        val hashA = RelayWebProbe.fragmentHash(fragmentA)
        val hashB = RelayWebProbe.fragmentHash(fragmentB)
        val ids = (1..7).map { "m$it" }
        val harness = Harness(transport, fragmentA) { withModels(it, ids) }
        harness.respondWith(evidenceResponse(evidenceCase("chat_url_citation_searched")))
        var saveB: kotlinx.coroutines.Job? = null
        harness.onProbe = {
            // The user saved B while A's first probe was in flight.
            harness.onProbe = {}
            harness.fragments.replace(connectionID, mapOf(transport to fragmentB))
            saveB = harness.repository.relayWebFragmentsSaved(connectionID, setOf(transport.value))
        }

        runBlocking {
            harness.repository.relayWebFragmentsSaved(connectionID, setOf(transport.value)).join()
            requireNotNull(saveB).join()
        }

        assertEquals("A sent only the in-flight m1, B probes the first 5 by selection", listOf("m1") + ids.take(5), harness.probedModels())
        assertEquals(
            "A's remaining models write no history",
            emptyList<String>(),
            harness.history.entries().filter { it.fragmentHash == hashA && it.modelId != "m1" }.map { it.modelId },
        )
        assertEquals(
            ids.take(5).toSet(),
            harness.history.entries().filter { it.fragmentHash == hashB }.map { it.modelId }.toSet(),
        )
        ids.take(5).forEach { id ->
            assertEquals(id, RelayWebProbeResult.Searched, harness.records.read(RelayWebProbeRecordStore.Key(connectionID, id, transport.value))?.result)
        }
    }

    @Test
    fun `RL2-WEBPROBE-OVERRIDE-clear after a fragment change or merge silent clears tested web and undetermined is kept and user is untouched`() {
        val transport = RelayTransport.OpenAIChatCompletions
        val tested = RelayCapabilityOverrides(web = true, image = true, testedKeys = setOf("web"))
        val user = RelayCapabilityOverrides(web = false)

        // Pure function (post-merge record mirror): silent removes the tested web and leaves other items alone; undetermined keeps the original value; a user-set web is untouched.
        RelayWebProbe.applyingResult(tested, RelayWebProbeResult.Silent).let { next ->
            assertNull(next?.web)
            assertFalse("web" in next?.testedKeys.orEmpty())
            assertEquals(true, next?.image)
        }
        assertEquals(tested, RelayWebProbe.applyingResult(tested, RelayWebProbeResult.Undetermined))
        RelayWebProbeResult.entries.forEach { assertEquals(it.wire, user, RelayWebProbe.applyingResult(user, it)) }

        // Saving changed this protocol's fragment (deleted here): models whose first-send protocol is it clear the tested web, user is untouched, zero requests.
        val changed = Harness(transport, fragment = null) { withModels(it, listOf("m1", "m2"), mapOf("m1" to tested, "m2" to user)) }
        runBlocking { changed.repository.relayWebFragmentsSaved(connectionID, setOf(transport.value)).join() }
        assertNull(changed.overridesOf("m1")?.web)
        assertNull(changed.catalogOverridesOf("m1")?.web)
        assertEquals(true, changed.overridesOf("m1")?.image)
        assertEquals(user, changed.overridesOf("m2"))
        assertTrue(changed.sent.isEmpty())

        // A different protocol changed: the tested web is untouched.
        val other = Harness(transport, fragment = null) { withModels(it, listOf("m1"), mapOf("m1" to tested)) }
        runBlocking { other.repository.relayWebFragmentsSaved(connectionID, setOf(RelayTransport.AnthropicMessages.value)).join() }
        assertEquals(tested, other.overridesOf("m1"))

        // Production probe: with no old record silent clears the tested web and undetermined is kept; anything user-set is untouched.
        listOf("chat_text_only_silent" to null, "chat_503_undetermined" to true).forEach { (caseId, expectedWeb) ->
            val harness = Harness(transport, RelayWebFragments.template(transport)) { withModels(it, listOf(modelID), mapOf(modelID to tested)) }
            harness.respondWith(evidenceResponse(evidenceCase(caseId)))
            runBlocking { harness.repository.runRelayWebProbe(connectionID, modelID) }
            assertEquals(caseId, expectedWeb, harness.overridesOf(modelID)?.web)
            assertEquals(caseId, expectedWeb, harness.catalogOverridesOf(modelID)?.web)
            assertEquals(caseId, true, harness.overridesOf(modelID)?.image)

            val kept = Harness(transport, RelayWebFragments.template(transport)) { withModels(it, listOf(modelID), mapOf(modelID to user)) }
            kept.respondWith(evidenceResponse(evidenceCase(caseId)))
            runBlocking { kept.repository.runRelayWebProbe(connectionID, modelID) }
            assertEquals(caseId, user, kept.overridesOf(modelID))
        }

        // silent after searched: the merged record is still searched and the tested web is still true.
        val searchedThenSilent = Harness(transport, RelayWebFragments.template(transport))
        searchedThenSilent.respondWith(evidenceResponse(evidenceCase("chat_url_citation_searched")))
        runBlocking { searchedThenSilent.repository.runRelayWebProbe(connectionID, modelID) }
        searchedThenSilent.respondWith(evidenceResponse(evidenceCase("chat_text_only_silent")))
        runBlocking { searchedThenSilent.repository.runRelayWebProbe(connectionID, modelID) }
        assertEquals(RelayWebProbeResult.Searched, searchedThenSilent.records.read(searchedThenSilent.key)?.result)
        assertEquals("searched then silent", true, searchedThenSilent.overridesOf(modelID)?.web)
        assertEquals("tested", searchedThenSilent.overridesOf(modelID)?.sourceOf("web"))

        // undetermined after rejected: no record written, override unchanged, still false.
        val rejectedThenUndetermined = Harness(transport, RelayWebFragments.template(transport))
        rejectedThenUndetermined.respondWith(evidenceResponse(evidenceCase("chat_400_rejected")))
        runBlocking { rejectedThenUndetermined.repository.runRelayWebProbe(connectionID, modelID) }
        rejectedThenUndetermined.respondWith(evidenceResponse(evidenceCase("chat_503_undetermined")))
        runBlocking { rejectedThenUndetermined.repository.runRelayWebProbe(connectionID, modelID) }
        assertEquals(RelayWebProbeResult.Rejected, rejectedThenUndetermined.records.read(rejectedThenUndetermined.key)?.result)
        assertEquals("rejected then undetermined", false, rejectedThenUndetermined.overridesOf(modelID)?.web)
        assertEquals("tested", rejectedThenUndetermined.overridesOf(modelID)?.sourceOf("web"))
    }

    // ── Scenario setup ──

    private data class Reply(
        val status: Int,
        val contentType: String,
        val body: String,
        val hang: Boolean = false,
    )

    private fun sseResponse(lines: List<String>, status: Int = 200) =
        Reply(status, "text/event-stream", lines.joinToString("\n"))

    private fun evidenceResponse(case: JsonObject): Reply {
        if (case["failure"]?.jsonPrimitive?.content == "timeout") return Reply(0, "", "", hang = true)
        val status = case.getValue("status").jsonPrimitive.content.toInt()
        case["sse"]?.let { sse -> return sseResponse(sse.jsonArray.map { it.jsonPrimitive.content } + "", status) }
        return Reply(status, "application/json", case.getValue("body").toString())
    }

    private class SentRequest(val path: String, val text: String) {
        val body: JsonElement by lazy { Json.parseToJsonElement(text) }
        val isProbe: Boolean get() = text.contains(RelayWebProbe.PROMPT)
    }

    private val connectionID = "44444444-4444-4444-8444-444444444444"
    private val accountID = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
    private val modelID = "probe-model"

    /** Production [ProviderRepository] + production [RelayService] against a fake upstream; the DAO keeps only Room's minimal read/write semantics. */
    private inner class Harness(
        transport: RelayTransport,
        val fragment: JsonObject?,
        customize: (Provider) -> Provider = { it },
    ) {
        val sent: MutableList<SentRequest> = Collections.synchronizedList(mutableListOf())
        private val initial: Provider = customize(
            AIModel(id = modelID, name = modelID).let { model ->
                Provider(
                    id = connectionID,
                    kind = ProviderKind.Relay,
                    baseUrlText = "https://relay.example.com",
                    relayKind = RelayKind.OpenAICompatible,
                    relayRequested = RelayRequestedConfig(transport = transport),
                    models = listOf(model.copy(isDefault = true)),
                    catalogModels = listOf(model),
                )
            },
        )
        @Volatile var stored: ai.oriveo.community.core.data.entity.ProviderEntity? = with(ProviderMapper) { initial.toEntity(accountID) }
        @Volatile private var reply: Reply = sseResponse(emptyList())

        val records = RelayWebProbeRecordStore(RelayWebProbeRecordStore.MemoryStore()) { NOW }
        val history = RelayWebProbeAutoHistory(RelayWebProbeRecordStore.MemoryStore())
        val fragments = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore()).also { store ->
            fragment?.let { store.replace(connectionID, mapOf(transport to it)) }
        }
        /** The repository's background work (automatic probing after lazy verification, etc.) runs here; tests wait for it to finish. */
        private val probeScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        /** Lazy verification's 1-token generation request: true = chat completions passes, everything else returns 404. */
        @Volatile var pingOk: Boolean = true

        fun pings(): List<SentRequest> = sent.filterNot { it.isProbe }

        /** Models of the probe requests, in send order. */
        fun probedModels(): List<String> = sent.filter { it.isProbe }.map { it.body.jsonObject.string("model") }

        fun awaitProbes() = runBlocking {
            while (true) {
                val children = probeScope.coroutineContext.job.children.toList()
                if (children.isEmpty()) break
                children.joinAll()
            }
        }
        val key = RelayWebProbeRecordStore.Key(connectionID, modelID, RelayFirstSendTransport.resolve(initial, initial.models.first()).value)

        fun respondWith(next: Reply) { reply = next }

        /** Called after a probe request reaches the fake upstream and before it responds (simulates the user editing the fragment / saving again mid-run). */
        @Volatile var onProbe: () -> Unit = {}

        private val engine = MockEngine { request ->
            val request0 = SentRequest(request.url.encodedPath, (request.body as? TextContent)?.text.orEmpty())
            sent += request0
            if (!request0.isProbe) {
                return@MockEngine if (pingOk && request0.path.endsWith("/chat/completions")) {
                    respond("""{"id":"x","choices":[{"message":{"content":"p"}}]}""", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
                } else {
                    respond("{}", HttpStatusCode.NotFound, headersOf(HttpHeaders.ContentType, "application/json"))
                }
            }
            onProbe()
            val current = reply
            if (current.hang) awaitCancellation()
            respond(current.body, HttpStatusCode.fromValue(current.status), headersOf(HttpHeaders.ContentType, current.contentType))
        }

        val repository: ProviderRepository = run {
            val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
            coEvery { dao.getById(any(), any()) } coAnswers {
                stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
            }
            coEvery { dao.upsert(any()) } coAnswers { stored = firstArg() }
            coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
            coEvery { dao.deleteById(any(), any()) } coAnswers { stored = null }
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
                relayWebProbeAutoHistory = history,
                relayModelFamily = { null },
                relayProbeScope = probeScope,
            )
        }

        fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain("sk-test") }
    }

    private companion object {
        /** Location of the output cap in each protocol's request body (same as the capability-test fixture's requestShapes.bodySubset). */
        val MAX_TOKENS_PATH = mapOf(
            RelayTransport.OpenAIChatCompletions to listOf("max_tokens"),
            RelayTransport.OpenAIResponses to listOf("max_output_tokens"),
            RelayTransport.AnthropicMessages to listOf("max_tokens"),
            RelayTransport.GeminiGenerateContent to listOf("generationConfig", "maxOutputTokens"),
        )
        const val SHORT_DEADLINE_MILLIS = 300L
        const val NOW = 1_791_900_000_000L
    }
}
