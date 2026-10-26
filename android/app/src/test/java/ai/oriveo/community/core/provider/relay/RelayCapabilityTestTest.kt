package ai.oriveo.community.core.provider.relay

import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayCapabilityOverridesSerializer
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.RelayRuntimeSupport
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.feature.providers.detail.ProviderDetailViewModel
import ai.oriveo.community.feature.providers.detail.RelayCapTestButton
import ai.oriveo.community.feature.providers.detail.RelayCapTestHeader
import ai.oriveo.community.feature.providers.detail.RelayCapTestPhase
import ai.oriveo.community.feature.providers.detail.RelayCapabilityTestPanelModel
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.ktor.utils.io.ByteChannel
import io.ktor.utils.io.ClosedWriteChannelException
import io.ktor.utils.io.writeStringUtf8
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Paths
import java.util.Collections
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * User-initiated Relay "test capability" (`shared/test-fixtures/relay/capability-test.v1.json`).
 * Verdicts are driven case by case from the fixture; scenarios hit a fake server through the production
 * [ProviderRepository] + production [RelayService] (same builders as chat). Requests are asserted by
 * `requestShapes` subset + mustContain, and overrides assertions use the model written back by the
 * repository and round-tripped through [ProviderMapper].
 */
class RelayCapabilityTestTest {
    private val json = Json { ignoreUnknownKeys = true }

    private val fixture: JsonObject by lazy {
        var dir = Paths.get("").toAbsolutePath()
        repeat(8) {
            val candidate = dir.resolve("shared/test-fixtures/relay/capability-test.v1.json")
            if (Files.exists(candidate)) {
                return@lazy Json.parseToJsonElement(String(Files.readAllBytes(candidate), Charsets.UTF_8)).jsonObject
            }
            dir = dir.parent ?: return@repeat
        }
        throw IllegalStateException("capability-test.v1.json not found")
    }

    private val shortToTransport: Map<String, RelayTransport> by lazy {
        fixture.getValue("transports").jsonObject.mapValues { (_, wire) ->
            RelayTransport.entries.single { it.value == wire.jsonPrimitive.content }
        }
    }
    private val builtins: JsonObject get() = fixture.getValue("builtins").jsonObject
    private val imageBase64: String get() = builtins.getValue("imagePNGBase64").jsonPrimitive.content
    private val toolName: String get() = builtins.getValue("tool").jsonObject.getValue("name").jsonPrimitive.content

    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content

    private fun overrides(element: JsonElement?): RelayCapabilityOverrides? =
        element?.let { json.decodeFromJsonElement(RelayCapabilityOverridesSerializer, it) }?.takeUnless { it.isEmpty }

    /** Appears verbatim, or in its JSON-escaped `\/` form. */
    private fun String.containsVerbatim(needle: String): Boolean =
        contains(needle) || contains(needle.replace("/", "\\/"))

    private val dripScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Before
    fun setUp() {
    }

    /**
     * Orchestration coroutines the VM runs on viewModelScope (test Main). After cancellation they may still sit inside the repository's
     * withContext(Dispatchers.Default / IO); when the block finishes they must return to Main, and if @After has already called resetMain,
     * a "Dispatchers.Main was accessed…" error is thrown on a DefaultDispatcher thread and gets attributed to the next
     * runTest in the same JVM (UncaughtExceptionsBeforeTest). So wait for all of them to finish before resetMain.
     */
    private val vmRuns: MutableList<Job> = Collections.synchronizedList(mutableListOf())

    @After
    fun tearDown() {
        runBlocking { withTimeout(10_000L) { synchronized(vmRuns) { vmRuns.toList() }.forEach { it.join() } } }
        dripScope.cancel()
        Dispatchers.resetMain()
    }

    // ── T1 verdicts (including SSE rules and reason) ──

    @Test
    fun `RL2-PROBE-06 classify cases`() {
        val cases = fixture.getValue("classifyCases").jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val result = RelayCapabilityTest.classify(
                status = case.string("status").toInt(),
                contentType = case.string("contentType"),
                body = case.string("body"),
            )
            val caseId = case.string("caseId")
            assertEquals("$caseId: verdict", case.string("expect"), result.verdict.wire)
            assertEquals("$caseId: reason", case.string("reason"), result.reason.wire)
        }
    }

    // ── T2 executor (production repository + production send primitives) ──

    @Test
    fun `RL2-PROBE-06 scenarios`() = runBlocking {
        val scenarios = fixture.getValue("scenarios").jsonArray.map { it.jsonObject }
        assertTrue(scenarios.isNotEmpty())
        for (scenario in scenarios) runScenario(scenario)
    }

    @Test
    fun `RD4-DEADLINE-01 hang times out and production deadline is 30 seconds`() = runBlocking {
        val perItem = fixture.getValue("deadline").jsonObject.string("perItemSeconds").toInt()
        assertEquals(30, perItem)
        assertEquals(perItem, RelayCapabilityTest.PER_ITEM_DEADLINE_SECONDS)
        assertEquals(perItem * 1_000L, RelayCapabilityTest.PER_ITEM_DEADLINE_MILLIS)
        runScenario(scenario("text_hang_times_out_and_stops"))
    }

    @Test
    fun `RD4-DEADLINE-02 drip is cut by the total deadline`() = runBlocking {
        runScenario(scenario("image_drip_is_cut_by_total_deadline"))
    }

    @Test
    fun `RD4-PATH-02 text 404 sends one request without protocol fallback`() = runBlocking {
        runScenario(scenario("text_404_sends_one_request_without_protocol_fallback"))
    }

    private fun scenario(caseId: String): JsonObject =
        fixture.getValue("scenarios").jsonArray.map { it.jsonObject }.single { it.string("caseId") == caseId }

    private suspend fun runScenario(scenario: JsonObject) {
        val caseId = scenario.string("caseId")
        val short = scenario.string("transport")
        val modelID = scenario.string("model")
        val responses = scenario.getValue("responses").jsonObject.mapValues { it.value.jsonPrimitive.content }
        val existing = overrides(scenario["existingOverrides"])
        val slow = responses.values.any { it == "hang" || it == "drip" }
        val harness = Harness(initial = withConnectionOverrides(caseId, connection(short, modelID, existing), scenario["connection"])) { kind ->
            responses.getValue(kind)
        }

        val started = System.nanoTime()
        val run = harness.repository.runRelayCapabilityTest(
            connectionID,
            modelID,
            deadlineMillis = if (slow) SHORT_DEADLINE_MILLIS else RelayCapabilityTest.PER_ITEM_DEADLINE_MILLIS,
        )
        val wallMillis = (System.nanoTime() - started) / 1_000_000L

        val expect = scenario.getValue("expect").jsonObject
        val expectedKinds = expect.getValue("requests").jsonArray.map { it.jsonPrimitive.content }
        // Every testable relay model lists the 4th web item (a built-in template when no fragment is stored); scenarios only measure the first three items,
        // and the web item is measured by RD4-WEB / RL2-WEBPROBE. Here we only require that the web request (if any) comes last.
        val capabilitySent = harness.sent.filter { it.kind != "web" }
        assertTrue("$caseId: web item comes last only", harness.sent.dropWhile { it.kind != "web" }.all { it.kind == "web" })
        assertEquals("$caseId: requests", expectedKinds, capabilitySent.map { it.kind })
        expect["totalHttpRequests"]?.let { assertEquals("$caseId: total HTTP requests", it.jsonPrimitive.content.toInt(), capabilitySent.size) }
        if (slow) assertTrue("$caseId: cut off by overall deadline ($wallMillis ms)", wallMillis < 5_000L)

        val shape = fixture.getValue("requestShapes").jsonObject.getValue(short).jsonObject
        val expectedPath = shape.string("path").replace("{{model}}", modelID)
        val bodyExtra = expect["bodyExtra"]?.jsonObject.orEmpty()
        val mustContain = fixture.getValue("mustContain").jsonObject
        val mustNotContain = fixture.getValue("mustNotContain").jsonObject
        for (sent in capabilitySent) {
            val label = "$caseId/${sent.kind}"
            assertEquals("$label: path", expectedPath, sent.path)
            shape["query"]?.jsonObject?.forEach { (key, value) ->
                assertEquals("$label: query $key", value.jsonPrimitive.content, sent.query[key])
            }
            val subset = JsonObject(shape.getValue("bodySubset").jsonObject + bodyExtra)
            assertSubset("$label: bodySubset", withModel(subset, modelID), sent.body)
            shape["bodySubsetByKind"]?.jsonObject?.get(sent.kind)?.let { assertSubset("$label: bodySubsetByKind", it, sent.body) }
            mustContain[sent.kind]?.jsonArray?.forEach { item ->
                val needle = item.jsonPrimitive.content.replace("{{png}}", imageBase64)
                assertTrue("$label: must contain ${item.jsonPrimitive.content}", sent.text.containsVerbatim(needle))
            }
            mustNotContain[sent.kind]?.jsonArray?.forEach { item ->
                val needle = item.jsonPrimitive.content.replace("{{png}}", imageBase64)
                assertFalse("$label: must not contain ${item.jsonPrimitive.content}", sent.text.containsVerbatim(needle))
            }
        }
        assertNull("$caseId: not interrupted", run.stopReason)
        assertEquals("$caseId: outcome", expect.string("outcome"), if (run.textFailed) "text_failed" else "completed")
        val items = expect.getValue("items").jsonObject.mapValues { it.value.jsonPrimitive.content }
        assertEquals("$caseId: image", items["image"], run.image?.wire)
        assertEquals("$caseId: toolCall", items["toolCall"], run.toolCall?.wire)
        expect["reasons"]?.jsonObject?.forEach { (key, reason) ->
            val kind = if (key == "toolCall") RelayCapabilityTestKind.Tool else RelayCapabilityTestKind.entries.single { it.wire == key }
            assertEquals("$caseId: reason $key", reason.jsonPrimitive.content, run.items.single { it.kind == kind }.reason.wire)
        }
        expect["text"]?.jsonObject?.let { text ->
            val item = run.items.single { it.kind == RelayCapabilityTestKind.Text }
            assertEquals("$caseId: text verdict", text.string("verdict"), item.verdict.wire)
            assertEquals("$caseId: text reason", text.string("reason"), item.reason.wire)
        }

        val expectedOverrides = overrides(expect.getValue("overrides"))
        val stored = harness.current()
        assertEquals("$caseId: enabled-list overrides", expectedOverrides, stored.models.single { it.id == modelID }.relayCapabilityOverrides)
        assertEquals("$caseId: catalog overrides", expectedOverrides, stored.catalogModels.single { it.id == modelID }.relayCapabilityOverrides)
        assertEquals("$caseId: connection default transport unchanged", shortToTransport.getValue(short), stored.relayRequested?.transport)
        assertNull("$caseId: model transport unchanged", stored.models.single().relayTransport)
    }

    private fun withModel(element: JsonElement, modelID: String): JsonElement =
        Json.parseToJsonElement(element.toString().replace("{{model}}", modelID))

    /** Fixture subset matching: objects key by key, arrays same length element by element, scalars equal. */
    private fun assertSubset(label: String, expected: JsonElement, actual: JsonElement?) {
        when (expected) {
            is JsonObject -> {
                val obj = actual as? JsonObject ?: throw AssertionError("$label: expected object, actual $actual")
                expected.forEach { (key, value) ->
                    assertTrue("$label: missing $key ($obj)", key in obj)
                    assertSubset("$label.$key", value, obj[key])
                }
            }
            is JsonArray -> {
                val array = actual as? JsonArray ?: throw AssertionError("$label: expected array, actual $actual")
                assertEquals("$label: array length ($array)", expected.size, array.size)
                expected.forEachIndexed { index, item -> assertSubset("$label[$index]", item, array[index]) }
            }
            else -> assertEquals(label, expected, actual)
        }
    }

    /** A scenario's `connection` overrides default connection fields; only keys used by the fixture are recognized here, unknown keys fail immediately. */
    private fun withConnectionOverrides(caseId: String, provider: Provider, overrides: JsonElement?): Provider {
        var next = provider
        for ((key, value) in overrides?.jsonObject.orEmpty()) {
            next = when (key) {
                "disableResponseStorage" -> next.copy(
                    relayRequested = next.relayRequested?.copy(disableResponseStorage = value.jsonPrimitive.content.toBooleanStrict()),
                )
                else -> throw AssertionError("$caseId: unknown connection key $key")
            }
        }
        return next
    }

    // ── Same path as chat ──

    @Test
    fun `RD4-PATH-01 text request equals the chat builder output for the same message and options`() = runBlocking {
        for ((short, transport) in shortToTransport) {
            val modelID = "path-model"
            val base = connection(short, modelID, null)
            // Two keys, the model is bound to the second one: auth must use the second key.
            val provider = base.copy(
                relayKeys = listOf(RelayKey(id = "k1", name = "Main"), RelayKey(id = "k2", name = "Second")),
                models = base.models.map { it.copy(relayKeyID = "k2") },
                catalogModels = base.catalogModels.map { it.copy(relayKeyID = "k2") },
            )
            val harness = Harness(initial = provider, relayKeySecret = { id -> if (id == "k2") "sk-second" else "sk-other" }) { "ok" }
            val run = harness.repository.runRelayCapabilityTest(connectionID, modelID)
            assertFalse("$short: text passed", run.textFailed)
            val testRequest = harness.sent.first { it.kind == "text" }

            // Chat send path: the same synthetic message, ChatRepository's Relay request options, chat's streaming outbound.
            val latest = harness.current()
            val model = latest.models.single()
            val options = ChatRequestOptions(
                relayRequested = latest.relayRequested,
                relayImage = latest.relayImage,
                relayRouteTransport = RelayEndpointResolver.effectiveTransport(latest, model),
                relayRouteAPIRoot = RelayEndpointResolver.effectiveAPIRoot(latest, model),
                activeModel = model,
                capabilityEvidenceIdentity = harness.repository.capabilityEvidenceIdentity(latest, modelID),
            )
            harness.sent.clear()
            runCatching {
                harness.relayService.sendMessageStream(
                    apiKey = "sk-second",
                    modelID = modelID,
                    messages = listOf(RelayCapabilityTest.message(RelayCapabilityTestKind.Text, modelID)),
                    baseUrl = latest.baseUrlText,
                    supportsImageGen = false,
                    reasoningMode = ReasoningMode.Automatic,
                    webSearchEnabled = false,
                    requestOptions = options,
                ).toList()
            }
            val chatRequest = harness.sent.first()

            assertEquals("$short: transport", transport, RelayEndpointResolver.effectiveTransport(latest, model))
            assertEquals("$short: URL", chatRequest.url, testRequest.url)
            // Request body: equal to the chat send except for the output cap; the cap goes through the builder's own channel, with value 16.
            val capPath = MAX_TOKENS_PATH.getValue(short)
            assertEquals("$short: output cap", RelayCapabilityTest.MAX_OUTPUT_TOKENS.toString(), testRequest.body.at(capPath)?.toString())
            assertEquals("$short: request body (excluding the cap)", chatRequest.body.withoutPath(capPath), testRequest.body.withoutPath(capPath))
            // With the same options (including the output cap argument), the chat builder's output equals the bytes the test actually sent.
            val builtWithCap = harness.relayService.chatStreamWireRequest(
                apiKey = "sk-second",
                modelID = modelID,
                message = RelayCapabilityTest.message(RelayCapabilityTestKind.Text, modelID),
                baseUrl = latest.baseUrlText,
                requestOptions = options,
                extras = RelayCapabilityTest.buildExtras(RelayCapabilityTestKind.Text),
            )
            assertEquals("$short: builder output URL", builtWithCap.url, testRequest.url)
            assertEquals("$short: builder output request body", builtWithCap.body, testRequest.text)
            val random = setOf("session_id")
            assertEquals("$short: request headers", chatRequest.headers - random, testRequest.headers - random)
            random.forEach { name ->
                assertEquals("$short: $name presence matches", name in chatRequest.headers, name in testRequest.headers)
            }
            val auth = testRequest.headers["Authorization"] ?: testRequest.headers["x-api-key"] ?: testRequest.headers["x-goog-api-key"]
            assertTrue("$short: auth uses the second key ($auth)", auth?.contains("sk-second") == true)
        }
    }

    @Test
    fun `RD4-PATH-03 chat builders without the new inputs produce the same bytes as before`() {
        val png = imageBase64
        val messages = listOf(
            ChatMessage(
                id = "u1",
                role = ChatRole.User,
                text = "Hi",
                providerKind = ProviderKind.Relay,
                providerName = "Relay",
                modelID = "m",
                modelName = "m",
                state = ChatMessageState.Delivered,
                attachments = listOf(Attachment(id = "a1", kind = AttachmentKind.Image, fileName = "i.png", mimeType = "image/png", base64Data = png)),
            ),
        )
        fun options(transport: RelayTransport) = ChatRequestOptions(
            relayRequested = RelayRequestedConfig(transport = transport),
            activeModel = AIModel(id = "m", name = "m"),
        )
        // Output before the change (no capability projection -> vision not allowed, images still stripped).
        assertEquals(
            """{"model":"m","stream":true,"messages":[{"role":"user","content":"Hi"}],"stream_options":{"include_usage":true}}""",
            buildOpenAIChatBody("m", messages, true, ReasoningMode.Automatic, options(RelayTransport.OpenAIChatCompletions)),
        )
        // Responses carries the Codex identity header by default, so the request body gains a prompt_cache_key (appended last, other bytes unchanged).
        assertEquals(
            """{"model":"m","input":[{"role":"user","content":[{"type":"input_text","text":"Hi"}]}],"stream":true,"tools":[{"type":"image_generation"}],"reasoning":{"summary":"auto"},"prompt_cache_key":"${RelayRuntimeSupport.promptCacheKey("m", "", "Hi")}"}""",
            buildResponsesBody("m", messages, true, false, ReasoningMode.Automatic, false, options(RelayTransport.OpenAIResponses)),
        )
        // Relay Anthropic puts the only cache breakpoint on the last content block of the last user message (a text-only user becomes a single text block).
        assertEquals(
            """{"model":"m","max_tokens":8192,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"Hi","cache_control":{"type":"ephemeral"}}]}]}""",
            buildAnthropicBody("m", messages, true, ReasoningMode.Automatic, options(RelayTransport.AnthropicMessages)),
        )
        assertEquals(
            """{"contents":[{"role":"user","parts":[{"text":"Hi"}]}]}""",
            buildGeminiBody(messages, "m", false, ReasoningMode.Automatic, false, options(RelayTransport.GeminiGenerateContent)),
        )
        // With the new argument: image kept, output cap 16, tools contains only that one function tool.
        val extras = RelayChatBuildExtras(maxOutputTokens = 16, functionTool = RelayCapabilityTest.tool, keepImageAttachments = true)
        val responses = buildResponsesBody(
            "m", messages, true, false, ReasoningMode.Automatic, false, options(RelayTransport.OpenAIResponses), extras = extras,
        )
        assertTrue(responses.containsVerbatim(png))
        assertTrue(responses.contains(""""max_output_tokens":16"""))
        assertFalse("built-in tools are not merged in", responses.contains("image_generation"))
    }

    // ── Every interruption is accounted for ──

    @Test
    fun `RD4-STOP-01 cancel keeps finished items and writes nothing`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val toolStarted = CompletableDeferred<Unit>()
        // A vision reply must carry evidence to be accepted.
        val harness = Harness(initial = connection("chat", "gpt-4o-mini", null)) { kind ->
            when (kind) {
                "tool" -> "hang"
                "image" -> "image_ok"
                else -> "ok"
            }
        }
        harness.onRequest = { kind -> if (kind == "tool") toolStarted.complete(Unit) }
        val vm = detailViewModel(harness)
        val model = harness.current().models.single()

        vm.requestRelayCapabilityTest(model, RelayTransport.OpenAIChatCompletions, keyName = null)
        withTimeout(10_000L) { toolStarted.await() }
        vm.cancelRelayCapabilityTest()

        val state = requireNotNull(vm.relayCapabilityTest)
        assertEquals(RelayCapTestPhase.Stopped, state.phase)
        assertEquals(RelayCapabilityTestStopReason.Cancelled, state.stopReason)
        assertEquals(
            listOf(RelayCapabilityTestKind.Text to RelayCapabilityVerdict.Accepted, RelayCapabilityTestKind.Image to RelayCapabilityVerdict.Accepted),
            state.results.map { it.kind to it.verdict },
        )
        val presentation = RelayCapabilityTestPanelModel.present(state.panelInput(0L))
        assertEquals(RelayCapTestHeader.Stopped, presentation.header)
        assertEquals(RelayCapTestButton.Done, presentation.button)
        delay(200L)
        assertNull("no write after cancel", harness.current().models.single().relayCapabilityOverrides)
    }

    @Test
    fun `RD4-STOP-02 connection change before the next item or before write stops with connection`() = runBlocking {
        for (changeOn in listOf("image", "tool")) {
            val harness = Harness(initial = connection("chat", "gpt-4o-mini", null)) { "ok" }
            harness.onRequest = { kind -> if (kind == changeOn) harness.apiKey = "sk-rotated" }
            val run = harness.repository.runRelayCapabilityTest(connectionID, "gpt-4o-mini")
            assertEquals("$changeOn: stop reason", RelayCapabilityTestStopReason.Connection, run.stopReason)
            val expectedSent = if (changeOn == "image") listOf("text", "image") else listOf("text", "image", "tool")
            assertEquals("$changeOn: requests", expectedSent, harness.sent.map { it.kind })
            assertEquals("$changeOn: completed items kept", expectedSent.size, run.items.size)
            assertFalse(run.written)
            assertNull("$changeOn: no write", harness.current().models.single().relayCapabilityOverrides)
        }
    }

    @Test
    fun `RD4-STOP-03 protocol change stops with protocol`() = runBlocking {
        val harness = Harness(initial = connection("chat", "gpt-4o-mini", null)) { "ok" }
        harness.onRequest = { kind ->
            if (kind == "text") {
                harness.stored = with(ProviderMapper) {
                    harness.current().let { p ->
                        p.copy(models = p.models.map { it.copy(relayTransport = RelayTransport.OpenAIResponses, relayTransportSource = RelayTransportSource.User) })
                    }.toEntity(accountID)
                }
            }
        }
        val run = harness.repository.runRelayCapabilityTest(connectionID, "gpt-4o-mini")
        assertEquals(RelayCapabilityTestStopReason.Protocol, run.stopReason)
        assertEquals(listOf("text"), harness.sent.map { it.kind })
        assertEquals(listOf(RelayCapabilityTestKind.Text), run.items.map { it.kind })
        assertNull(harness.current().catalogModels.single().relayCapabilityOverrides)
    }

    @Test
    fun `RD4-STOP-04 removed or untestable model stops with unavailable`() = runBlocking {
        val harness = Harness(initial = connection("chat", "gpt-4o-mini", null)) { "ok" }
        harness.onRequest = { kind ->
            if (kind == "image") {
                harness.stored = with(ProviderMapper) {
                    harness.current().copy(models = listOf(AIModel(id = "other", name = "other", isDefault = true))).toEntity(accountID)
                }
            }
        }
        val run = harness.repository.runRelayCapabilityTest(connectionID, "gpt-4o-mini")
        assertEquals(RelayCapabilityTestStopReason.Unavailable, run.stopReason)
        assertEquals(listOf("text", "image"), harness.sent.map { it.kind })
        assertNull(harness.current().catalogModels.single { it.id == "gpt-4o-mini" }.relayCapabilityOverrides)

        // Untestable at open time (local engine): stops at unavailable directly, 0 requests.
        val local = connection("chat", "gpt-4o-mini", null).let { it.copy(relayRequested = it.relayRequested?.copy(engineProfile = "llama_cpp")) }
        val localHarness = Harness(initial = local) { "ok" }
        val localRun = localHarness.repository.runRelayCapabilityTest(connectionID, "gpt-4o-mini")
        assertEquals(RelayCapabilityTestStopReason.Unavailable, localRun.stopReason)
        assertEquals(emptyList<String>(), localHarness.sent.map { it.kind })
    }

    @Test
    fun `RD4-STOP-02 connection and protocol changing together reports connection`() = runBlocking {
        val harness = Harness(initial = connection("chat", "gpt-4o-mini", null)) { "ok" }
        harness.onRequest = { kind ->
            if (kind == "text") {
                harness.apiKey = "sk-rotated"
                harness.stored = with(ProviderMapper) {
                    harness.current().let { p ->
                        p.copy(models = p.models.map { it.copy(relayTransport = RelayTransport.OpenAIResponses, relayTransportSource = RelayTransportSource.User) })
                    }.toEntity(accountID)
                }
            }
        }
        val run = harness.repository.runRelayCapabilityTest(connectionID, "gpt-4o-mini")
        assertEquals(RelayCapabilityTestStopReason.Connection, run.stopReason)
        assertEquals(listOf("text"), harness.sent.map { it.kind })
    }

    @Test
    fun `RD4-STOP-05 orchestration error stops the panel with unavailable`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val harness = Harness(initial = connection("chat", "gpt-4o-mini", null)) { "ok" }
        val repository = mockk<ProviderRepository>()
        every { repository.observeById(connectionID) } returns MutableStateFlow(harness.current())
        coEvery { repository.runRelayCapabilityTest(any(), any(), any(), any()) } throws IOException("keystore unavailable")
        val vm = detailViewModel(repository)

        vm.requestRelayCapabilityTest(harness.current().models.single(), RelayTransport.OpenAIChatCompletions, keyName = null)
        withTimeout(10_000L) { while (vm.relayCapabilityTest?.phase == RelayCapTestPhase.Running) delay(10L) }
        val state = requireNotNull(vm.relayCapabilityTest)
        assertEquals(RelayCapTestPhase.Stopped, state.phase)
        assertEquals(RelayCapabilityTestStopReason.Unavailable, state.stopReason)
        assertEquals(RelayCapTestHeader.Stopped, RelayCapabilityTestPanelModel.present(state.panelInput(0L)).header)
    }

    // ── Advanced page "test capability" opens the panel at once, first state is already in progress ──

    @Test
    fun `BOARD-CAPTEST-01 test button opens the panel already running`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val harness = Harness(initial = connection("messages", "claude-sonnet-4-5", null)) { kind ->
            // Vision / tool replies carry evidence; only then is there a writable result.
            when (kind) {
                "image" -> "image_ok"
                "tool" -> "tool_ok"
                else -> "ok"
            }
        }
        val vm = detailViewModel(harness)
        val model = harness.current().models.single()

        vm.requestRelayCapabilityTest(model, RelayTransport.AnthropicMessages, keyName = "Claude \u5206\u7ec4")
        val first = requireNotNull(vm.relayCapabilityTest) { "tapping the button opens the panel" }
        assertEquals(RelayCapTestPhase.Running, first.phase)
        val presentation = RelayCapabilityTestPanelModel.present(first.panelInput(first.runningStartedAtMillis))
        // The 4th web item is listed even without a stored fragment.
        assertEquals(RelayCapTestHeader.Progress(1, 4), presentation.header)
        assertEquals(RelayCapTestButton.Cancel, presentation.button)
        assertFalse("cannot dismiss while running", presentation.dismissible)
        assertEquals("Claude \u5206\u7ec4", presentation.keyName)
        vm.dismissRelayCapabilityTest()
        assertNotNull("cannot be closed while running", vm.relayCapabilityTest)

        withTimeout(10_000L) { while (vm.relayCapabilityTest?.phase == RelayCapTestPhase.Running) delay(10L) }
        val done = requireNotNull(vm.relayCapabilityTest)
        assertEquals(RelayCapTestPhase.Completed, done.phase)
        assertTrue(done.written)
        vm.dismissRelayCapabilityTest()
        assertNull(vm.relayCapabilityTest)
    }

    @Test
    fun `RL2-PROBE-06 local engines and unsupported transports are not testable`() {
        val remote = connection("chat", "gpt-4o-mini", null)
        assertTrue(RelayCapabilityTest.isTestable(remote, remote.models.single()))
        val local = remote.copy(relayRequested = remote.relayRequested?.copy(engineProfile = "llama_cpp"))
        assertFalse(RelayCapabilityTest.isTestable(local, local.models.single()))
        val native = remote.copy(relayRequested = remote.relayRequested?.copy(transport = RelayTransport.LlamaCppNative))
        assertFalse(RelayCapabilityTest.isTestable(native, native.models.single()))
        val notRelay = remote.copy(kind = ProviderKind.OpenAI)
        assertFalse(RelayCapabilityTest.isTestable(notRelay, notRelay.models.single()))
        assertNull(RelayCapabilityTest.shortName(RelayTransport.LlamaCppNative))

        // Entry conditions: no entry when both vision and tools already have user overrides; still shown when only one is set manually; not shown for unsupported transports.
        assertTrue(RelayCapabilityTest.offersTest(remote, remote.models.single()))
        assertFalse(RelayCapabilityTest.offersTest(native, native.models.single()))
        fun userSet(text: String) = remote.models.single().copy(relayCapabilityOverrides = overrides(Json.parseToJsonElement(text)))
        assertTrue(RelayCapabilityTest.offersTest(remote, userSet("""{"image":{"value":true,"source":"user"}}""")))
        // Vision and tools both set manually: the web item is listed as soon as the first-send transport is known (a stored fragment is no longer required), so the entry is still shown.
        val bothUser = userSet("""{"image":{"value":true,"source":"user"},"toolCall":{"value":false,"source":"user"}}""")
        assertTrue(RelayCapabilityTest.listsWeb(remote, bothUser))
        assertTrue(RelayCapabilityTest.offersTest(remote, bothUser))
        assertFalse(RelayCapabilityTest.listsWeb(native, native.models.single()))
        assertTrue(RelayCapabilityTest.offersTest(remote, userSet("""{"image":{"value":true,"source":"user"},"toolCall":{"value":false,"source":"tested"}}""")))

        // "Restore automatic" entry: Relay form, no engineProfile, has tested items; the effective transport need not be one of the four.
        val tested = """{"image":{"value":true,"source":"tested"}}"""
        assertTrue(RelayCapabilityTest.offersRestore(remote, userSet(tested)))
        assertTrue("transport not one of the four + has tested items", RelayCapabilityTest.offersRestore(native, userSet(tested)))
        assertFalse(RelayCapabilityTest.offersRestore(native, native.models.single()))
        assertFalse(RelayCapabilityTest.offersRestore(remote, userSet("""{"image":{"value":true,"source":"user"}}""")))
        assertFalse(RelayCapabilityTest.offersRestore(local, userSet(tested)))
        assertFalse(RelayCapabilityTest.offersRestore(notRelay, userSet(tested)))
    }

    // ── T4 restore automatic ──

    @Test
    fun `RL2-PROBE-06 restore automatic`() = runBlocking {
        val cases = fixture.getValue("restoreAutomatic").jsonObject.getValue("cases").jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        for (case in cases) {
            val caseId = case.string("caseId")
            val before = overrides(case.getValue("before"))
            val after = overrides(case.getValue("after"))
            assertEquals("$caseId: pure function", after, RelayCapabilityTest.restoringAutomatic(before))
            assertTrue("$caseId: has tested items", RelayCapabilityTest.hasTestedResults(AIModel(id = "m", name = "m", relayCapabilityOverrides = before)))

            val harness = Harness(initial = connection("chat", "m", before)) { "ok" }
            harness.repository.restoreRelayCapabilityAutomatic(connectionID, "m")
            val stored = harness.current()
            assertEquals("$caseId: enabled list", after, stored.models.single().relayCapabilityOverrides)
            assertEquals("$caseId: catalog", after, stored.catalogModels.single().relayCapabilityOverrides)
            assertFalse("$caseId: no tested items after restore", RelayCapabilityTest.hasTestedResults(stored.models.single()))
            assertEquals("$caseId: 0 requests", emptyList<String>(), harness.sent.map { it.kind })
        }
    }

    // ── CAPTEST-FIRSTSEND: capability test shares chat's path, all by first-send transport ──

    private fun <T> withCachedFamilies(families: Map<String, String>, block: () -> T): T {
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

    @Test
    fun `CAPTEST-FIRSTSEND-01 auto connection unverified Claude family test sends via Messages clears Messages key leaves Chat key`() {
        val claude = "claude-sonnet-4"
        withCachedFamilies(mapOf(claude to "anthropic")) {
            runBlocking {
                val base = connection("chat", claude, null)
                val auto = base.copy(relayRequested = base.relayRequested?.copy(transport = RelayTransport.Auto))
                val model = auto.models.single()
                // Precondition: first-send Messages, effective Chat.
                assertEquals(RelayTransport.AnthropicMessages, RelayFirstSendTransport.resolve(auto, model))
                assertEquals(RelayTransport.OpenAIChatCompletions, RelayEndpointResolver.effectiveTransport(auto, model))
                assertTrue("eligibility follows the first-send transport", RelayCapabilityTest.isTestable(auto, model))

                val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 1_000L })
                val messagesKey = RelayNegativeCache.Key(connectionID, claude, RelayTransport.AnthropicMessages.value)
                val chatKey = RelayNegativeCache.Key(connectionID, claude, RelayTransport.OpenAIChatCompletions.value)
                for (key in listOf(messagesKey, chatKey)) {
                    cache.record(key, RelayNegativeCache.Kind.Image)
                    cache.record(key, RelayNegativeCache.Kind.ToolCall)
                }
                val harness = Harness(initial = auto, negativeCache = cache) { "ok" }

                val run = harness.repository.runRelayCapabilityTest(connectionID, claude)

                assertNull(run.stopReason)
                assertFalse(run.textFailed)
                // The 4th web item also follows the first-send transport and carries the Messages template.
                assertEquals(listOf("text", "image", "tool", "web"), harness.sent.map { it.kind })
                assertTrue("test request sent via Messages: ${harness.sent.map { it.path }}", harness.sent.all { it.path == "/v1/messages" })
                assertTrue("Messages key cleared", cache.entries().none { it.key == messagesKey })
                assertEquals(
                    "Chat key unchanged",
                    setOf(RelayNegativeCache.Kind.Image, RelayNegativeCache.Kind.ToolCall),
                    cache.entries().filter { it.key == chatKey }.map { it.kind }.toSet(),
                )
            }
        }
    }

    @Test
    fun `CAPTEST-FIRSTSEND-02 behavior unchanged when first-send equals effective transport`() = runBlocking {
        val modelID = "gpt-4o-mini"
        val provider = connection("chat", modelID, null)
        val model = provider.models.single()
        assertEquals(RelayEndpointResolver.effectiveTransport(provider, model), RelayFirstSendTransport.resolve(provider, model))
        val cache = RelayNegativeCache(RelayNegativeCache.MemoryStore(), clock = { 1_000L })
        val chatKey = RelayNegativeCache.Key(connectionID, modelID, RelayTransport.OpenAIChatCompletions.value)
        cache.record(chatKey, RelayNegativeCache.Kind.Image)
        cache.record(chatKey, RelayNegativeCache.Kind.ToolCall)
        val harness = Harness(initial = provider, negativeCache = cache) { "ok" }

        val run = harness.repository.runRelayCapabilityTest(connectionID, modelID)

        assertNull(run.stopReason)
        assertEquals(listOf("text", "image", "tool", "web"), harness.sent.map { it.kind })
        assertTrue(harness.sent.all { it.path == "/v1/chat/completions" })
        assertTrue("effective = first-send key cleared", cache.entries().none { it.key == chatKey })
    }

    /** Vision evidence excludes Gemini thought summaries: parts with thought == true do not count as visible text. */
    @Test
    fun `CAPTEST-EVIDENCE-01 Gemini thought part contains red body does not vision notObserved`() = runBlocking {
        val modelID = "gemini-2.5-flash"
        fun geminiImageReply(parts: String) = kotlinx.serialization.json.buildJsonObject {
            put("status", JsonPrimitive(200))
            put("contentType", JsonPrimitive("text/event-stream"))
            put(
                "body",
                JsonPrimitive(
                    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":$parts},\"finishReason\":\"STOP\"}]}\n\n",
                ),
            )
        }
        suspend fun imageVerdict(parts: String): RelayCapabilityVerdict {
            val harness = Harness(
                initial = connection("gemini", modelID, null),
                negativeCache = RelayNegativeCache(RelayNegativeCache.MemoryStore()),
            ) { kind -> if (kind == "image") "gemini_image" else "ok" }
            harness.extraResponses["gemini_image"] = geminiImageReply(parts)
            return harness.repository.runRelayCapabilityTest(connectionID, modelID)
                .items.single { it.kind == RelayCapabilityTestKind.Image }.verdict
        }
        assertEquals(
            RelayCapabilityVerdict.NotObserved,
            imageVerdict("""[{"text":"The square is red.","thought":true},{"text":"It is a small square."}]"""),
        )
        // Control: the same word in the body -> accepted, showing the above was not caused by the reply failing to parse.
        assertEquals(
            RelayCapabilityVerdict.Accepted,
            imageVerdict("""[{"text":"Thinking about the colour.","thought":true},{"text":"It is red."}]"""),
        )
    }

    // ── Web item 4: manual probe, not counted against the cap, not deduplicated, not added to auto history ──

    private val webProbeFixture: JsonObject by lazy {
        var dir = Paths.get("").toAbsolutePath()
        repeat(8) {
            val candidate = dir.resolve("shared/test-fixtures/relay/web-probe.v1.json")
            if (Files.exists(candidate)) {
                return@lazy Json.parseToJsonElement(String(Files.readAllBytes(candidate), Charsets.UTF_8)).jsonObject
            }
            dir = dir.parent ?: return@repeat
        }
        throw IllegalStateException("web-probe.v1.json not found")
    }

    /** Replies from the web-probe fixture's evidenceCases, converted to this class's `responses` shape. */
    private fun webProbeReply(caseId: String): JsonObject {
        val case = webProbeFixture.getValue("evidenceCases").jsonArray.map { it.jsonObject }.single { it.string("caseId") == caseId }
        val sse = case["sse"]?.jsonArray?.map { it.jsonPrimitive.content }
        return kotlinx.serialization.json.buildJsonObject {
            put("status", case.getValue("status"))
            put("contentType", JsonPrimitive(if (sse != null) "text/event-stream" else "application/json"))
            put("body", JsonPrimitive(sse?.plus("")?.joinToString("\n") ?: case.getValue("body").toString()))
        }
    }

    private fun webHarness(fragment: JsonObject?, responseFor: (String) -> String): Harness = Harness(
        initial = connection("chat", WEB_MODEL, null),
        negativeCache = RelayNegativeCache(RelayNegativeCache.MemoryStore()),
        webFragment = fragment,
        responseFor = responseFor,
    )

    private fun Harness.webRecord(): RelayWebProbeResult? =
        records.read(RelayWebProbeRecordStore.Key(connectionID, WEB_MODEL, RelayTransport.OpenAIChatCompletions.value))?.result

    @Test
    fun `RD4-WEB-01 listed web runs the manual probe as the 4th step, ignoring and not counting the cap`() = runBlocking {
        val fragment = requireNotNull(RelayWebFragments.template(RelayTransport.OpenAIChatCompletions))
        val hash = RelayWebProbe.fragmentHash(fragment)
        val harness = webHarness(fragment) { kind -> if (kind == "web") "web_searched" else "ok" }
        harness.extraResponses["web_searched"] = webProbeReply("chat_url_citation_searched")
        // Auto quota is full and the same model+hash was already auto-probed: manual still sends, history unchanged.
        val auto = (0 until 10).map { RelayWebProbeAutoEntry(connectionID, if (it == 0) WEB_MODEL else "m$it", RelayTransport.OpenAIChatCompletions.value, hash, WEB_NOW) }
        auto.forEach(harness.history::add)
        val progress = Collections.synchronizedList(mutableListOf<RelayCapabilityTestProgress>())

        val run = harness.repository.runRelayCapabilityTest(connectionID, WEB_MODEL, onProgress = { progress += it })

        assertNull(run.stopReason)
        assertEquals(listOf("text", "image", "tool", "web"), run.planned.map { it.wire })
        assertEquals(listOf("text", "image", "tool", "web"), harness.sent.map { it.kind })
        assertEquals("panel lists web from the start", listOf("text", "image", "tool", "web"), progress.first().planned.map { it.wire })
        assertTrue("web has a running frame", progress.any { it.running?.wire == "web" })
        val web = run.items.single { it.kind.wire == "web" }
        assertEquals("searched", web.verdict.wire)
        assertEquals(200, web.status)
        assertTrue("web override write counts as written", run.written)
        assertEquals(auto.toSet(), harness.history.entries().toSet())
        assertEquals(RelayWebProbeResult.Searched, harness.webRecord())
        assertEquals(true, harness.current().models.single().relayCapabilityOverrides?.web)
    }

    @Test
    fun `RD4-WEB-02 silent and rejected map to the item verdict, written only for the override write`() = runBlocking {
        val fragment = requireNotNull(RelayWebFragments.template(RelayTransport.OpenAIChatCompletions))
        val silent = webHarness(fragment) { kind -> if (kind == "web") "web_silent" else "ok" }
        silent.extraResponses["web_silent"] = webProbeReply("chat_text_only_silent")
        val silentRun = silent.repository.runRelayCapabilityTest(connectionID, WEB_MODEL)
        assertEquals("silent", silentRun.items.single { it.kind.wire == "web" }.verdict.wire)
        assertFalse("silent does not write overrides", silentRun.written)
        assertEquals(RelayWebProbeResult.Silent, silent.webRecord())

        val rejected = webHarness(fragment) { kind -> if (kind == "web") "http_400" else "ok" }
        val rejectedRun = rejected.repository.runRelayCapabilityTest(connectionID, WEB_MODEL)
        val item = rejectedRun.items.single { it.kind.wire == "web" }
        assertEquals("rejected", item.verdict.wire)
        assertEquals(400, item.status)
        assertTrue(rejectedRun.written)
        assertEquals(false, rejected.current().models.single().relayCapabilityOverrides?.web)
    }

    @Test
    fun `RD4-WEB-06 fragment changed or removed while web runs stops the panel with protocol and writes nothing`() = runBlocking {
        val chat = RelayTransport.OpenAIChatCompletions
        val fragment = requireNotNull(RelayWebFragments.template(chat))
        val changed = webHarness(fragment) { kind -> if (kind == "web") "web_searched" else "ok" }
        changed.extraResponses["web_searched"] = webProbeReply("chat_url_citation_searched")
        changed.onRequest = { kind ->
            if (kind == "web") changed.fragments.replace(connectionID, mapOf(chat to JsonObject(fragment + ("x-variant" to JsonPrimitive("b")))))
        }
        val changedRun = changed.repository.runRelayCapabilityTest(connectionID, WEB_MODEL)
        assertEquals(RelayCapabilityTestStopReason.Protocol, changedRun.stopReason)
        assertNull(changed.webRecord())
        assertNull(changed.current().models.single().relayCapabilityOverrides?.web)

        // First three items done, fragment deleted before web is sent: web is no longer listed, and the panel likewise stops as the transport changed.
        val removed = webHarness(fragment) { "ok" }
        removed.onRequest = { kind -> if (kind == "tool") removed.fragments.remove(connectionID) }
        val removedRun = removed.repository.runRelayCapabilityTest(connectionID, WEB_MODEL)
        assertEquals(RelayCapabilityTestStopReason.Protocol, removedRun.stopReason)
        assertEquals(listOf("text", "image", "tool"), removed.sent.map { it.kind })
        assertNull(removed.webRecord())
    }

    @Test
    fun `RD4-WEB-07 user-set web plus searched probe is not written, footer nothing`() = runBlocking {
        val fragment = requireNotNull(RelayWebFragments.template(RelayTransport.OpenAIChatCompletions))
        val userSet = overrides(
            Json.parseToJsonElement("""{"image":{"value":true,"source":"user"},"toolCall":{"value":false,"source":"user"},"web":{"value":false,"source":"user"}}"""),
        )
        val harness = Harness(
            initial = connection("chat", WEB_MODEL, userSet),
            negativeCache = RelayNegativeCache(RelayNegativeCache.MemoryStore()),
            webFragment = fragment,
            responseFor = { kind -> if (kind == "web") "web_searched" else "ok" },
        )
        harness.extraResponses["web_searched"] = webProbeReply("chat_url_citation_searched")

        val run = harness.repository.runRelayCapabilityTest(connectionID, WEB_MODEL)

        assertNull(run.stopReason)
        assertEquals("searched", run.items.single { it.kind.wire == "web" }.verdict.wire)
        assertFalse("web set by user was not written, not counted as a write", run.written)
        assertEquals(RelayWebProbeResult.Searched, harness.webRecord())
        assertEquals(false, harness.current().models.single().relayCapabilityOverrides?.web)
        assertEquals("user", harness.current().models.single().relayCapabilityOverrides?.sourceOf("web"))
    }

    @Test
    fun `RL2-WEBPROBE-01 no fragment lists web and probes with the transport template and writes the override like a saved fragment, a saved fragment wins`() = runBlocking {
        val chat = RelayTransport.OpenAIChatCompletions
        val template = requireNotNull(RelayWebFragments.template(chat))
        val harness = webHarness(fragment = null) { kind -> if (kind == "web") "web_searched" else "ok" }
        harness.extraResponses["web_searched"] = webProbeReply("chat_url_citation_searched")
        val model = harness.current().models.single()
        // Listing condition: a relay + testable + the first-send protocol is known; a stored fragment is no longer required.
        assertTrue("web is listed even without a fragment", RelayCapabilityTest.listsWeb(harness.current(), model))
        assertEquals(RelayWebSource.Template, RelayCapabilityTest.webSource(harness.current(), model, harness.fragments))

        val run = harness.repository.runRelayCapabilityTest(connectionID, WEB_MODEL)

        assertNull(run.stopReason)
        assertEquals(listOf("text", "image", "tool", "web"), run.planned.map { it.wire })
        assertEquals(listOf("text", "image", "tool", "web"), harness.sent.map { it.kind })
        assertEquals(RelayWebSource.Template, run.webSource)
        val body = harness.sent.single { it.kind == "web" }.body.jsonObject
        assertEquals("the request body carries the protocol template via the production builder", template.getValue("web_search_options"), body["web_search_options"])
        assertEquals("searched", run.items.single { it.kind.wire == "web" }.verdict.wire)
        // The template is the effective fragment: the web override (tested) is written as usual and counts as written.
        assertTrue("a template probe writes the web override, written = true", run.written)
        assertEquals(true, harness.current().models.single().relayCapabilityOverrides?.web)
        assertEquals("tested", harness.current().models.single().relayCapabilityOverrides?.sourceOf("web"))
        val record = harness.records.read(RelayWebProbeRecordStore.Key(connectionID, WEB_MODEL, chat.value))
        assertEquals(RelayWebProbeResult.Searched, record?.result)
        assertEquals("record hash = canonical hash of the template", RelayWebProbe.fragmentHash(template), record?.fragmentHash)
        assertTrue("a temporary probe does not save a fragment", harness.fragments.stored(connectionID).isEmpty())
        assertTrue("a manual probe does not enter the automatic history", harness.history.entries().isEmpty())

        // The first-send protocol has a stored fragment: use it instead of the template.
        val saved = JsonObject(template + ("x-variant" to JsonPrimitive("saved")))
        val withSaved = webHarness(saved) { kind -> if (kind == "web") "web_searched" else "ok" }
        withSaved.extraResponses["web_searched"] = webProbeReply("chat_url_citation_searched")
        val savedRun = withSaved.repository.runRelayCapabilityTest(connectionID, WEB_MODEL)
        assertNull(savedRun.stopReason)
        assertEquals(RelayWebSource.Saved, savedRun.webSource)
        assertEquals(JsonPrimitive("saved"), withSaved.sent.single { it.kind == "web" }.body.jsonObject["x-variant"])
        assertTrue(savedRun.written)
        assertEquals(true, withSaved.current().models.single().relayCapabilityOverrides?.web)
    }

    @Test
    fun `RD4-WEB-04 failed text check sends no web request`() = runBlocking {
        val fragment = requireNotNull(RelayWebFragments.template(RelayTransport.OpenAIChatCompletions))
        val harness = webHarness(fragment) { kind -> if (kind == "text") "http_404" else "ok" }
        val run = harness.repository.runRelayCapabilityTest(connectionID, WEB_MODEL)
        assertTrue(run.textFailed)
        assertEquals(listOf("text", "image", "tool", "web"), run.planned.map { it.wire })
        assertEquals(listOf("text"), harness.sent.map { it.kind })
        assertTrue(run.items.none { it.kind.wire == "web" })
        assertNull(harness.webRecord())
    }

    @Test
    fun `RD4-WEB-05 panel lists web and the web disclosure from the first frame`() = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val transport = RelayTransport.OpenAIChatCompletions
        val fragment = requireNotNull(RelayWebFragments.template(transport))
        // The production VM reads the shared fragment store (same as the production repository default); the whole key is cleared when the test ends.
        RelayWebFragmentStore.shared.replace(connectionID, mapOf(transport to fragment))
        try {
            val harness = webHarness(fragment) { "ok" }
            val vm = detailViewModel(harness)
            val subscription = launch(Dispatchers.Main) { vm.provider.collect {} }
            val model = harness.current().models.single()

            vm.requestRelayCapabilityTest(model, transport, keyName = null)
            val first = requireNotNull(vm.relayCapabilityTest)
            assertEquals("first frame already lists web", listOf("text", "image", "tool", "web"), first.items.map { it.wire })
            val presentation = RelayCapabilityTestPanelModel.present(first.panelInput(first.runningStartedAtMillis))
            assertEquals(RelayCapTestHeader.Progress(1, 4), presentation.header)
            assertEquals("first frame footer already announces web", ai.oriveo.community.R.plurals.relay_cap_test_info_web, presentation.footer.res)
            assertEquals(4, presentation.footer.count)
            vm.cancelRelayCapabilityTest()
            subscription.cancel()
        } finally {
            RelayWebFragmentStore.shared.remove(connectionID)
        }
    }

    // ── Scenario setup ──

    private val connectionID = "33333333-3333-4333-8333-333333333333"
    private val accountID = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID

    private fun connection(short: String, modelID: String, existing: RelayCapabilityOverrides?): Provider {
        val model = AIModel(id = modelID, name = modelID, relayCapabilityOverrides = existing)
        return Provider(
            id = connectionID,
            kind = ProviderKind.Relay,
            baseUrlText = "https://relay.example.com",
            relayKind = RelayKind.OpenAICompatible,
            relayRequested = RelayRequestedConfig(transport = shortToTransport.getValue(short)),
            models = listOf(model.copy(isDefault = true)),
            catalogModels = listOf(model),
        )
    }

    private fun detailViewModel(harness: Harness, saves: MutableList<Job>? = null): ProviderDetailViewModel {
        val repository = mockk<ProviderRepository>()
        every { repository.observeById(connectionID) } returns MutableStateFlow(harness.current())
        every { repository.relayWebFragmentsSaved(any(), any()) } answers {
            harness.repository.relayWebFragmentsSaved(arg(0), arg(1)).also { saves?.add(it) }
        }
        coEvery { repository.runRelayCapabilityTest(any(), any(), any(), any()) } coAnswers {
            vmRuns += currentCoroutineContext().job
            harness.repository.runRelayCapabilityTest(arg(0), arg(1), arg(2), arg(3))
        }
        return detailViewModel(repository)
    }

    private fun detailViewModel(repository: ProviderRepository): ProviderDetailViewModel {
        return ProviderDetailViewModel(
            savedStateHandle = SavedStateHandle(mapOf("providerID" to connectionID)),
            providerRepository = repository,
            appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true),
            metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
            applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true),
        )
    }

    private class SentRequest(
        val kind: String,
        val url: String,
        val path: String,
        val query: Map<String, String>,
        val headers: Map<String, String>,
        val text: String,
    ) {
        val body: JsonElement = Json.parseToJsonElement(text)
    }

    /** Production [ProviderRepository] + production [RelayService] against a fake server; the DAO keeps only Room's minimal read/write semantics. */
    private inner class Harness(
        initial: Provider,
        relayKeySecret: (String) -> String = { "sk-test" },
        negativeCache: RelayNegativeCache = RelayNegativeCache.shared,
        /** Saved web fragment on the model's first-send transport; null = no fragment. */
        webFragment: JsonObject? = null,
        responseFor: (String) -> String,
    ) {
        val sent: MutableList<SentRequest> = Collections.synchronizedList(mutableListOf())
        val records = RelayWebProbeRecordStore(RelayWebProbeRecordStore.MemoryStore()) { WEB_NOW }
        val history = RelayWebProbeAutoHistory(RelayWebProbeRecordStore.MemoryStore())
        val fragments = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore()).also { store ->
            webFragment?.let { store.replace(initial.id, mapOf(RelayFirstSendTransport.resolve(initial, initial.models.firstOrNull()) to it)) }
        }
        @Volatile var stored: ai.oriveo.community.core.data.entity.ProviderEntity? = with(ProviderMapper) { initial.toEntity(accountID) }
        @Volatile var apiKey = "sk-test"
        @Volatile var onRequest: (String) -> Unit = {}
        /** Replies outside the fixture (same shape as `responses`); looked up by name before the fixture. */
        val extraResponses: MutableMap<String, JsonObject> = java.util.concurrent.ConcurrentHashMap()
        // The test request is sent by the first-send transport; the fake upstream replies with the same transport.
        private val short = RelayCapabilityTest.shortName(
            RelayFirstSendTransport.resolve(initial, initial.models.firstOrNull()),
        )

        private val engine = MockEngine { request ->
            val text = (request.body as? TextContent)?.text.orEmpty()
            val kind = when {
                RelayWebProbe.PROMPT in text -> "web"
                text.containsVerbatim(imageBase64) -> "image"
                toolName in text -> "tool"
                else -> "text"
            }
            val headers = buildMap {
                request.headers.names().forEach { name -> put(name, request.headers.getAll(name).orEmpty().joinToString(",")) }
                request.body.contentType?.let { put(HttpHeaders.ContentType, it.toString()) }
            }
            sent += SentRequest(
                kind = kind,
                url = request.url.toString(),
                path = request.url.encodedPath,
                query = request.url.parameters.names().associateWith { request.url.parameters[it].orEmpty() },
                headers = headers,
                text = text,
            )
            onRequest(kind)
            val name = responseFor(kind)
            val response = extraResponses[name] ?: fixture.getValue("responses").jsonObject.getValue(name).jsonObject
            when {
                response["network"] != null -> throw IOException("connection reset")
                response["hang"] != null -> awaitCancellation()
                response["drip"] != null -> {
                    val channel = ByteChannel(autoFlush = true)
                    dripScope.launch {
                        // After the code under test hits a read timeout it cancels the response body, and the writer then throws ClosedWriteChannelException --
                        // this is the normal end of drip. Unless caught it becomes an uncaught exception, which kotlinx-coroutines-test
                        // attributes to the next runTest in the same JVM (UncaughtExceptionsBeforeTest).
                        try {
                            while (isActive) {
                                channel.writeStringUtf8(": ping\n\n")
                                delay(100L)
                            }
                        } catch (_: ClosedWriteChannelException) {
                        }
                    }
                    respond(channel, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
                }
                else -> {
                    val body = response["bodyByTransport"]?.jsonObject?.getValue(requireNotNull(short))
                        ?: response.getValue("body")
                    respond(
                        if (body is JsonPrimitive && body.isString) body.content else body.toString(),
                        HttpStatusCode.fromValue(response.string("status").toInt()),
                        headersOf(HttpHeaders.ContentType, response.string("contentType")),
                    )
                }
            }
        }

        val relayService = RelayService(client = HttpClient(engine), json = json, transportRegistry = TransportRegistry(json))

        val repository: ProviderRepository = run {
            val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
            coEvery { dao.getById(any(), any()) } coAnswers {
                stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
            }
            coEvery { dao.upsert(any()) } coAnswers { stored = firstArg() }
            coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
            val keys = mockk<ai.oriveo.community.core.security.SecureKeyStore>(relaxed = true)
            every { keys.getApiKey(any(), any()) } answers { apiKey }
            every { keys.getRelayKeySecret(any(), any(), any()) } answers { relayKeySecret(thirdArg()) }
            ProviderRepository(
                dao = dao,
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
                relayService = relayService,
                metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
                httpClient = HttpClient(MockEngine { respond("", HttpStatusCode.NotFound) }),
                relayNegativeCache = negativeCache,
                relayWebFragmentStore = fragments,
                relayWebProbeRecords = records,
                relayWebProbeAutoHistory = history,
            )
        }

        fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain(apiKey) }
    }

    private fun JsonElement.at(path: List<String>): JsonElement? =
        path.fold<String, JsonElement?>(this) { node, key -> (node as? JsonObject)?.get(key) }

    private fun JsonElement.withoutPath(path: List<String>): JsonElement {
        val obj = this as? JsonObject ?: return this
        val head = path.first()
        if (path.size == 1) return JsonObject(obj - head)
        val child = obj[head] ?: return this
        val next = child.withoutPath(path.drop(1))
        return JsonObject(if ((next as? JsonObject)?.isEmpty() == true) obj - head else obj + (head to next))
    }

    private companion object {
        /** Location of the output cap in each transport's request body (fixture requestShapes.bodySubset). */
        val MAX_TOKENS_PATH = mapOf(
            "chat" to listOf("max_tokens"),
            "responses" to listOf("max_output_tokens"),
            "messages" to listOf("max_tokens"),
            "gemini" to listOf("generationConfig", "maxOutputTokens"),
        )

        /** Short deadline injected for hang / drip scenarios (fixture $comment: e.g. 300 ms). */
        const val SHORT_DEADLINE_MILLIS = 300L

        const val WEB_MODEL = "gpt-4o-mini"
        const val WEB_NOW = 1_791_900_000_000L
    }
}
