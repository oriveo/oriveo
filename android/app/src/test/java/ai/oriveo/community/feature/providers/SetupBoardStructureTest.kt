package ai.oriveo.community.feature.providers

import android.content.Context
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.LocalEngineConnector
import ai.oriveo.community.core.provider.LocalEngineKind
import ai.oriveo.community.core.provider.RelayDetectedConfiguration
import ai.oriveo.community.core.provider.RelayDetectionEvidence
import ai.oriveo.community.core.provider.RelayDiscoveryAttempt
import ai.oriveo.community.core.provider.RelayDiscoveryFailureKind
import ai.oriveo.community.core.provider.RelayDiscoveryResult
import ai.oriveo.community.core.provider.RelayDiscoveryService
import ai.oriveo.community.core.provider.RelayEndpointCandidateEvidence
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.core.provider.RelaySecurityModePolicy
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import ai.oriveo.community.feature.providers.local.LocalComputeSetupViewModel
import ai.oriveo.community.feature.providers.local.LocalPrimaryAction
import ai.oriveo.community.feature.providers.local.LocalSetupFailure
import ai.oriveo.community.feature.providers.local.LocalThinkingValue
import ai.oriveo.community.feature.providers.local.compactContextLength
import ai.oriveo.community.feature.providers.relay.RelayCheckKind
import ai.oriveo.community.feature.providers.relay.RelayCheckState
import ai.oriveo.community.feature.providers.relay.RelaySetupFailureKind
import ai.oriveo.community.feature.providers.relay.RelaySetupStep
import ai.oriveo.community.feature.providers.relay.RelaySetupViewModel
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.ConnectException
import java.nio.file.Files
import java.nio.file.Paths
import java.util.Collections

/**
 * Structure snapshots of the two add-page boards (Setup / LocalSetup): assert the board state objects produced by the ViewModel,
 * without image snapshots. The three relay detection card items are driven by the production ViewModel (zero 1-token requests); the local detection card comes from the production
 * [LocalEngineConnector] against fake servers recorded from real engines (shared local-engine fixtures).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SetupBoardStructureTest {
    private val dispatcher = StandardTestDispatcher()
    private val context = mockk<Context>()
    private val providerRepository = mockk<ProviderRepository>(relaxed = true)
    private val discoveryService = mockk<RelayDiscoveryService>()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { context.getString(any()) } answers { "string-${firstArg<Int>()}" }
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    // ── Relay (step 1: address -> key -> "add another", three detection card items, zero 1-token requests)──

    @Test
    fun `BOARD-SETUP-01 relay structure slot order without default model and request preview`() {
        val viewModel = relayViewModel()
        val board = viewModel.board

        assertEquals(R.string.relay_setup_hero_label, board.heroLabel)
        assertEquals(R.string.relay_setup_hero_title, board.heroTitle)
        assertEquals(R.string.relay_setup_hero_subtitle_two_step, board.heroSubtitle)
        assertEquals(R.string.relay_setup_manual_protocol, board.secondaryRow)
        assertEquals(R.string.relay_setup_keys_local, board.keysFootnote)
        // No default model slot: address -> key -> "add another key".
        assertEquals(listOf(SetupBoardSlot.Address, SetupBoardSlot.ApiKey, SetupBoardSlot.AddKey), board.slots)
        assertNull(board.detection)
        assertNull(board.willRequest)
        // Only one key: no name input is shown and the primary key cannot be deleted.
        assertEquals(1, board.keys.size)
        assertFalse(board.keys.single().showsName)
        assertFalse(board.keys.single().removable)

        // Preview row = production previewAPIRoot(input) + "/…".
        viewModel.updateEndpoint("relay.example")
        val preview = requireNotNull(RelayEndpointResolver.previewAPIRoot("relay.example"))
        assertEquals("$preview/…", viewModel.board.willRequest)
        assertEquals("https://relay.example/v1/…", viewModel.board.willRequest)

        // After adding a second key: every key (including the primary) shows a name input, and only the added key can be deleted.
        viewModel.addKey()
        val keys = viewModel.board.keys
        assertEquals(2, keys.size)
        assertTrue(keys.all { it.showsName })
        assertEquals(listOf(false, true), keys.map { it.removable })
        assertEquals(listOf(SetupBoardSlot.Address, SetupBoardSlot.ApiKey, SetupBoardSlot.AddKey), viewModel.board.slots)
        viewModel.removeKey(keys[1].id)
        assertFalse(viewModel.board.keys.single().showsName)
    }

    @Test
    fun `BOARD-SETUP-02 relay detection card three checks with progress timing and cancel`() = runTest(dispatcher) {
        var now = 1_000L
        val gate = CompletableDeferred<RelayDiscoveryResult>()
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } coAnswers { gate.await() }
        coEvery { providerRepository.fetchRelayKeyCatalog(any(), any(), any()) } coAnswers {
            now += 700
            RelayKeyBinding.CatalogFetch.Ok(listOf("gpt-b1", "gpt-b2").map { ProviderRepository.relayCatalogRow(it) })
        }

        val viewModel = readyRelayViewModel(clock = { now })
        viewModel.addKey()
        val second = viewModel.board.keys[1].id
        viewModel.updateKeySecret(second, "sk-second")
        viewModel.updateKeyName(second, "OpenAI group")
        viewModel.next()
        runCurrent()

        val running = requireNotNull(viewModel.board.detection)
        assertEquals(
            listOf(RelayCheckKind.Connection, RelayCheckKind.Catalog, RelayCheckKind.Protocols),
            running.rows.map { it.kind },
        )
        assertEquals(listOf(RelayCheckState.Running, RelayCheckState.Pending, RelayCheckState.Pending), running.rows.map { it.state })
        assertEquals(0, running.completed)
        assertEquals(3, running.total)
        assertTrue(viewModel.board.showsCancelDetection)
        assertFalse(viewModel.board.isPrimaryEnabled)
        assertEquals(0L, running.rows[0].elapsedMs(now))
        now += 400
        assertEquals(400L, running.rows[0].elapsedMs(now))

        gate.complete(catalogResult(detection(listOf("gpt-a", "claude-b", "gem-c"), mapOf("gem-c" to listOf("gemini")))))
        advanceUntilIdle()

        // Non-empty catalog -> automatically go to step 2; the detection card is kept (still visible when returning to step 1).
        assertEquals(RelaySetupStep.Models, viewModel.step)
        viewModel.backToAddress()
        val done = requireNotNull(viewModel.board.detection)
        assertEquals(List(3) { RelayCheckState.Done }, done.rows.map { it.state })
        assertEquals(3, done.completed)
        assertFalse(viewModel.board.showsCancelDetection)
        assertEquals(400L, done.rows[0].elapsedMs(now + 9_999))
        assertEquals(1_100L, done.rows[1].elapsedMs(now + 9_999))
        assertEquals("/v1/models", done.rows[0].reachablePath)
        assertEquals(listOf(3, 2), done.keyLines.map { it.modelCount })
        assertEquals(listOf(RelayCheckState.Done, RelayCheckState.Done), done.keyLines.map { it.state })
        assertEquals("OpenAI group", done.keyLines[1].label)
        // The step 2 preview row switches to the root address obtained by detection.
        assertEquals("https://relay.example/v1/…", viewModel.board.willRequest)
        // Step 1 sends zero 1-token requests.
        coVerify(exactly = 0) { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) }

        // Changing only the name does not invalidate; changing the address does.
        viewModel.updateKeyName(second, "renamed")
        assertTrue(viewModel.board.detection != null)
        viewModel.updateKeySecret(second, "sk-third")
        assertNull(viewModel.board.detection)

        // Cancel while running: the card disappears and the generation is invalidated.
        val pending = CompletableDeferred<RelayDiscoveryResult>()
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } coAnswers { pending.await() }
        viewModel.next()
        runCurrent()
        assertTrue(viewModel.board.showsCancelDetection)
        viewModel.cancelDetection()
        pending.complete(catalogResult(detection(listOf("late"), emptyMap())))
        advanceUntilIdle()
        assertNull(viewModel.board.detection)
        assertEquals(RelaySetupStep.Address, viewModel.step)

        // Connectivity failure: one sentence + the other two items skipped.
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } returns failedResult(401)
        viewModel.next()
        advanceUntilIdle()
        val failed = requireNotNull(viewModel.board.detection)
        assertEquals(listOf(RelayCheckState.Failed, RelayCheckState.Skipped, RelayCheckState.Skipped), failed.rows.map { it.state })
        assertEquals(RelaySetupFailureKind.InvalidKey, failed.rows[0].failure)
        assertEquals(3, failed.completed)
        assertEquals(RelaySetupStep.Address, viewModel.step)
    }

    @Test
    fun `BOARD-SETUP-03 relay primary button is always Next`() = runTest(dispatcher) {
        val viewModel = relayViewModel()
        assertEquals(R.string.relay_setup_next, viewModel.board.primaryLabel)
        assertFalse(viewModel.board.isPrimaryEnabled)

        viewModel.updateEndpoint("https://relay.example/v1")
        viewModel.updateApiKey("sk-test")
        assertTrue(viewModel.board.isPrimaryEnabled)
        // An empty extra key row does not block Next and is ignored during detection (same as iOS).
        viewModel.addKey()
        assertTrue(viewModel.board.isPrimaryEnabled)

        // Not tappable while detecting.
        val gate = CompletableDeferred<RelayDiscoveryResult>()
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } coAnswers { gate.await() }
        viewModel.next()
        runCurrent()
        assertEquals(R.string.relay_setup_next, viewModel.board.primaryLabel)
        assertFalse(viewModel.board.isPrimaryEnabled)

        // Success with a non-empty catalog -> automatically go to step 2.
        gate.complete(catalogResult(detection(listOf("plain-d"), emptyMap())))
        advanceUntilIdle()
        assertEquals(RelaySetupStep.Models, viewModel.step)
        // Empty rows did not take part in detection: "fetch catalog" has only the primary key row, no extra catalogs were fetched, and step 2 counts one key.
        assertEquals(1, viewModel.board.detection?.keyLines?.size)
        assertEquals(1, viewModel.modelsBoard.keyCount)
        coVerify(exactly = 0) { providerRepository.fetchRelayKeyCatalog(any(), any(), any()) }
        viewModel.backToAddress()
        assertTrue(viewModel.board.isPrimaryEnabled)
        viewModel.next()
        assertEquals(RelaySetupStep.Models, viewModel.step)

        // Empty catalog: stay on step 1 with one sentence (the step 2 empty-state sentence), then tapping Next opens step 2 in manual-add mode.
        val empty = detection(emptyList(), emptyMap()).copy(detectionEvidence = RelayDetectionEvidence.GenerationProbe)
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } returns catalogResult(empty)
        viewModel.backToAddress()
        viewModel.updateApiKey("sk-other")
        viewModel.next()
        advanceUntilIdle()
        assertEquals(RelaySetupStep.Address, viewModel.step)
        val stopped = requireNotNull(viewModel.board.detection)
        assertEquals(RelayCheckState.Done, stopped.rows[0].state)
        assertEquals(RelayCheckState.Failed, stopped.rows[1].state)
        assertEquals(RelaySetupFailureKind.ModelsEmpty, stopped.keyLines.single().failure)
        assertTrue(viewModel.board.isPrimaryEnabled)
        viewModel.next()
        assertEquals(RelaySetupStep.Models, viewModel.step)
        assertTrue(viewModel.modelsBoard.isCatalogEmpty)
        coVerify(exactly = 0) { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `BOARD-SETUP-08 the action bar loading indicator in the primary button uses palette onPrimary`() {
        val buttons = File("src/main/java/ai/oriveo/community/ui/component/OriveoButtons.kt").readText()
        val primary = buttons.substringAfter("fun OriveoPrimaryButton(").substringBefore("\n}\n")
        val loading = primary.substringAfter("if (loading) {").substringBefore("} else")
        // The foreground on the gradient primary button uses the palette onPrimary; a white spinner on the light gradient lacks contrast
        assertTrue("the primary button spinner uses the palette onPrimary", loading.contains("CircularProgressIndicator(") && loading.contains("color = OriveoGradients.onPrimary"))
        // The step 2 save and manual-setup primary buttons both go through this primary button via the primaryLoading of SetupActionBar.
        val actionBar = File("src/main/java/ai/oriveo/community/feature/providers/relay/SetupBoardComponents.kt").readText()
            .substringAfter("internal fun SetupActionBar(")
        assertTrue(actionBar.contains("OriveoPrimaryButton(") && actionBar.contains("loading = primaryLoading"))
        val screen = File("src/main/java/ai/oriveo/community/feature/providers/relay/RelaySetupScreen.kt").readText()
        assertTrue(screen.contains("primaryLoading = board.isSaving"))
        assertTrue(screen.contains("primaryLoading = board.primary.loading"))
    }

    @Test
    fun `LOCAL-ADDR local address field title is the edit connection engine address`() {
        val screen = File("src/main/java/ai/oriveo/community/feature/providers/local/LocalComputeSetupScreen.kt").readText()
        assertTrue(screen.contains("R.string.relay_detail_engine_address"))
        assertFalse(screen.contains("R.string.local_compute_address"))
    }

    // ── Local ──

    @Test
    fun `BOARD-SETUP-04 local structure has no default model slot`() {
        val viewModel = localViewModel(connector(emptyMap()))
        val board = viewModel.board

        assertEquals(R.string.local_setup_hero_label, board.heroLabel)
        assertEquals(R.string.local_setup_hero_title, board.heroTitle)
        assertEquals(R.string.local_setup_hero_subtitle, board.heroSubtitle)
        assertEquals(R.string.local_setup_manual_engine, board.secondaryRow)
        // The key slot keeps its existing visibility: only Open WebUI needs a key; there is no default model slot any more.
        assertEquals(listOf(SetupBoardSlot.Address), board.slots)
        assertEquals(SetupDetectionCard.Hidden, board.card)
        assertFalse(board.showsManualPicker)
        assertTrue(board.networkChips.isEmpty())

        viewModel.toggleManualPicker()
        viewModel.selectEngine(LocalEngineKind.OpenWebUI)
        assertEquals(listOf(SetupBoardSlot.Address, SetupBoardSlot.ApiKey), viewModel.board.slots)
        assertTrue(viewModel.board.showsManualPicker)
        assertFalse(viewModel.board.showsChannelPicker)
        viewModel.selectEngine(LocalEngineKind.LlamaCpp)
        assertTrue(viewModel.board.showsChannelPicker)

        viewModel.addDiscoveredEndpoint("http://192.168.1.20:8080")
        viewModel.addDiscoveredEndpoint("http://192.168.1.20:8080")
        viewModel.addDiscoveredEndpoint("http://192.168.1.30:11434")
        assertEquals(listOf("http://192.168.1.20:8080", "http://192.168.1.30:11434"), viewModel.board.networkChips)

        // The selector and the "change model" entry are removed together, leaving no dead button.
        val screen = File("src/main/java/ai/oriveo/community/feature/providers/local/LocalComputeSetupScreen.kt").readText()
        assertFalse(screen.contains("LocalDefaultModelPicker"))
        assertFalse(screen.contains("updateModelId"))
        assertFalse(screen.contains("local_compute_model_optional"))
    }

    @Test
    fun `BOARD-SETUP-05 local detection card tiles from production connector`() = runTest(dispatcher) {
        // llama.cpp: channel chat, context taken from n_ctx of /props, thinking writable -> follows the chat template.
        val llama = localViewModel(connector(routes(listOf(pointer("llamacpp", "text_only")))))
        llama.readyLoopback()
        llama.runPrimaryAction()
        runCurrent()
        assertEquals(SetupDetectionCard.Detecting, llama.board.card)
        assertEquals(R.string.relay_setup_detecting, llama.board.detectingLabel)
        settle { !llama.isConnecting }
        val llamaBoard = llama.board
        assertEquals(SetupDetectionCard.Succeeded, llamaBoard.card)
        val llamaSummary = requireNotNull(llamaBoard.summary)
        assertEquals(LocalEngineKind.LlamaCpp, llamaSummary.engine)
        assertEquals(RelayTransport.OpenAIChatCompletions, llamaSummary.channel)
        assertEquals(2048, llamaSummary.contextLength)
        assertEquals("2K", compactContextLength(requireNotNull(llamaSummary.contextLength)))
        assertEquals(LocalThinkingValue.ChatTemplate, llamaSummary.thinking)
        assertEquals(R.string.local_setup_thinking_template, llamaSummary.thinking.label)
        assertNull(llamaBoard.failure)

        // LM Studio: context taken from max_context_length of the default model's catalog row, thinking not writable -> decided by the model.
        val lmstudio = localViewModel(connector(routes(listOf(pointer("lmstudio", null)))))
        lmstudio.readyLoopback()
        lmstudio.runPrimaryAction()
        settle { !lmstudio.isConnecting }
        val lmSummary = requireNotNull(lmstudio.board.summary)
        assertEquals(LocalEngineKind.LmStudio, lmSummary.engine)
        assertEquals(8192, lmSummary.contextLength)
        assertEquals(LocalThinkingValue.SetByModel, lmSummary.thinking)

        // Ollama: the model declares no thinking -> unsupported; context cannot be measured -> null (shown as "N/A", not 0).
        val ollama = localViewModel(connector(routes(listOf(pointer("ollama", null)))))
        ollama.readyLoopback(endpoint = "127.0.0.1:11434")
        ollama.updateModelId("tinyllama:latest")
        ollama.runPrimaryAction()
        settle { !ollama.isConnecting }
        val ollamaSummary = requireNotNull(ollama.board.summary)
        assertEquals(LocalEngineKind.Ollama, ollamaSummary.engine)
        assertNull(ollamaSummary.contextLength)
        assertEquals(LocalThinkingValue.Unsupported, ollamaSummary.thinking)
        assertEquals(R.string.local_setup_value_unsupported, ollamaSummary.thinking.label)

        // Failure: engine unreachable -> fingerprint manual -> not recognized.
        val down = localViewModel(connector(emptyMap(), unreachable = true))
        down.readyLoopback()
        down.runPrimaryAction()
        settle { !down.isConnecting }
        assertEquals(SetupDetectionCard.Failed, down.board.card)
        assertEquals(LocalSetupFailure.Unrecognized, down.board.failure)
        assertNull(down.board.summary)
    }

    @Test
    fun `BOARD-SETUP-06 local fingerprint drives the engine for every fixture case`() = runTest(dispatcher) {
        val cases = expectations.getValue("fingerprint").jsonObject.getValue("cases").jsonArray.map { it.jsonObject }
        var ran = 0
        for (case in cases) {
            if (case.string("status") == "pending") continue
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val pointers = case.getValue("responses").jsonArray.map { it.jsonObject }
            val unreachable = case["unreachable"]?.jsonPrimitive?.booleanOrNull == true
            val requested = Collections.synchronizedList(mutableListOf<String>())
            val viewModel = localViewModel(connector(routes(pointers), unreachable, requested))
            viewModel.readyLoopback()
            viewModel.runPrimaryAction()
            settle { !viewModel.isConnecting }
            val expect = case.getValue("expect").jsonObject
            val board = viewModel.board
            if (expect.string("outcome") == "engine") {
                val kind = LocalEngineKind.entries.single { it.wire == expect.string("engineProfile") }
                assertEquals(caseId, kind, viewModel.engine)
                assertEquals(caseId, SetupDetectionCard.Succeeded, board.card)
                assertEquals(caseId, kind, board.summary?.engine)
                assertFalse(caseId, board.showsManualPicker)
            } else {
                assertEquals(caseId, SetupDetectionCard.Failed, board.card)
                assertEquals(caseId, LocalSetupFailure.Unrecognized, board.failure)
                assertTrue(caseId, board.showsManualPicker)
                assertEquals(caseId, LocalPrimaryAction.Detect, board.primaryButton)

                // Manual selection expanded: pressing again skips the fingerprint and connects directly with the selected engine (default Ollama); if it cannot connect the existing failure row is used.
                requested.clear()
                viewModel.runPrimaryAction()
                settle { !viewModel.isConnecting }
                assertFalse(caseId, "/version" in requested)
                assertFalse(caseId, "/api/v0/models" in requested)
                assertEquals(caseId, LocalSetupFailure.Connection, viewModel.board.failure)
            }
            ran += 1
        }
        assertEquals(8, ran)
    }

    @Test
    fun `BOARD-SETUP-07 local primary button three states`() = runTest(dispatcher) {
        val viewModel = localViewModel(connector(routes(listOf(pointer("llamacpp", "vision")))))
        assertEquals(LocalPrimaryAction.Detect, viewModel.board.primaryButton)
        assertFalse(viewModel.board.isPrimaryEnabled)

        viewModel.readyLoopback()
        assertTrue(viewModel.board.isPrimaryEnabled)

        viewModel.runPrimaryAction()
        runCurrent()
        assertEquals(LocalPrimaryAction.Detect, viewModel.board.primaryButton)
        assertTrue(viewModel.board.isPrimaryLoading)
        assertFalse(viewModel.board.isPrimaryEnabled)

        settle { !viewModel.isConnecting }
        assertEquals(LocalPrimaryAction.ConnectAndSave, viewModel.board.primaryButton)
        assertFalse(viewModel.board.isPrimaryLoading)
        assertTrue(viewModel.board.isPrimaryEnabled)
    }

    // ── helpers ──

    private fun relayViewModel(
        family: (String) -> String? = { null },
        cachedFamily: (String) -> String? = { null },
        clock: () -> Long = { 0L },
    ) = RelaySetupViewModel(
        context = context,
        providerRepository = providerRepository,
        discoveryService = discoveryService,
        modelFamily = { family(it) },
        cachedModelFamily = cachedFamily,
        clock = clock,
    )

    private fun readyRelayViewModel(
        family: (String) -> String? = { null },
        cachedFamily: (String) -> String? = { null },
        clock: () -> Long = { 0L },
    ) = relayViewModel(family, cachedFamily, clock).apply {
        updateEndpoint("https://relay.example/v1")
        updateApiKey("sk-test")
    }

    private fun detection(models: List<String>, endpointTypes: Map<String, List<String>>) = RelayDetectedConfiguration(
        transport = RelayTransport.OpenAIChatCompletions,
        authMode = RelayAuthMode.Bearer,
        apiBaseUrl = "https://relay.example/v1",
        modelIDs = models,
        endpointEvidence = RelayEndpointCandidateEvidence.DefaultVersion,
        generationVerified = false,
        supportedEndpointTypes = endpointTypes,
    )

    private val candidate by lazy {
        RelayEndpointResolver.candidates(
            RelayEndpointResolver.describe("https://relay.example/v1"),
            RelayTransport.OpenAIChatCompletions,
        ).first()
    }

    private fun catalogResult(vararg detections: RelayDetectedConfiguration) = RelayDiscoveryResult(
        descriptor = RelayEndpointResolver.describe("https://relay.example/v1"),
        detections = detections.toList(),
        attempts = listOf(
            RelayDiscoveryAttempt(candidate, "https://relay.example/v1/models", if (detections.isEmpty()) 404 else 200, null),
        ),
        blockingFailure = if (detections.isEmpty()) RelayDiscoveryFailureKind.RouteUnavailable else null,
    )

    private fun failedResult(status: Int) = RelayDiscoveryResult(
        descriptor = RelayEndpointResolver.describe("https://relay.example/v1"),
        detections = emptyList(),
        attempts = listOf(
            RelayDiscoveryAttempt(candidate, "https://relay.example/v1/models", status, RelayDiscoveryFailureKind.AuthenticationRejected),
        ),
        blockingFailure = RelayDiscoveryFailureKind.AuthenticationRejected,
    )

    private fun localViewModel(connector: LocalEngineConnector) = LocalComputeSetupViewModel(
        connector = connector,
        providerRepository = providerRepository,
        runtimeClient = mockk(relaxed = true),
    ).also { it.attachCoordinator(CustomLLMSetupCoordinator(CustomLLMConnectionMethod.Local)) }

    private fun LocalComputeSetupViewModel.readyLoopback(endpoint: String = "127.0.0.1:8080") {
        updateEndpoint(endpoint)
        setSecurityMode(
            mode = RelayConnectionSecurityMode.LocalHttp,
            assessment = RelaySecurityModePolicy.assess(endpoint, listOf("127.0.0.1")),
            confirmDowngrade = true,
        )
    }

    /** The connector goes through the Ktor MockEngine (IO thread); here we advance the test scheduler while waiting for it to land. */
    private fun TestScope.settle(done: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 10_000
        while (true) {
            advanceUntilIdle()
            if (done()) return
            check(System.currentTimeMillis() < deadline) { "local connection did not settle" }
            Thread.sleep(5)
        }
    }

    private val LocalEngineKind.wire: String
        get() = when (this) {
            LocalEngineKind.LlamaCpp -> "llamacpp"
            LocalEngineKind.Ollama -> "ollama"
            LocalEngineKind.LmStudio -> "lmstudio"
            LocalEngineKind.Vllm -> "vllm"
            LocalEngineKind.OpenWebUI -> "openwebui"
        }

    // ── Fake servers recorded from real engines (same routing as LocalEngineDeclarationContractTest) ──

    private val json = Json { ignoreUnknownKeys = true }

    private fun fixture(relativePath: String): JsonObject {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(relativePath) }
            .firstOrNull(Files::exists)
            ?: error("fixture not found: $relativePath")
        return Json.parseToJsonElement(String(Files.readAllBytes(path), Charsets.UTF_8)).jsonObject
    }

    private val expectations by lazy { fixture("shared/test-fixtures/local-engine/engine-expectations.v1.json") }
    private val recordings by lazy { fixture("shared/test-fixtures/local-engine/engine-declarations.v1.json") }

    private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

    private fun pointer(engine: String, instance: String?) = JsonObject(
        buildMap {
            put("engine", JsonPrimitive(engine))
            instance?.let { put("instance", JsonPrimitive(it)) }
            put("all", JsonPrimitive(true))
        },
    )

    private fun records(engine: String, instance: String?): List<JsonObject> {
        val recording = recordings.getValue("engines").jsonObject.getValue(engine).jsonObject
        val holder = if (instance == null) recording else recording.getValue("instances").jsonObject.getValue(instance).jsonObject
        return holder.getValue("records").jsonArray.map { it.jsonObject }
    }

    private data class Recorded(val status: Int, val contentType: String, val body: String)

    private fun recorded(record: JsonObject): Recorded {
        val response = record.getValue("response").jsonObject
        val body = response["body"]
        return Recorded(
            status = response.getValue("status").jsonPrimitive.content.toInt(),
            contentType = response.string("contentType") ?: "application/json",
            body = if (body == null || body is JsonNull) "404 page not found" else body.toString(),
        )
    }

    private fun recordKey(method: String, path: String, model: String?): String = "$method $path ${model.orEmpty()}"

    private fun recordKey(record: JsonObject): String {
        val request = record.getValue("request").jsonObject
        val model = (request["body"] as? JsonObject)?.string("model")
        return recordKey(request.getValue("method").jsonPrimitive.content, request.getValue("path").jsonPrimitive.content, model)
    }

    private fun routes(pointers: List<JsonObject>): Map<String, Recorded> = buildMap {
        pointers.forEach { pointer ->
            val all = records(pointer.getValue("engine").jsonPrimitive.content, pointer.string("instance"))
            if (pointer["all"]?.jsonPrimitive?.booleanOrNull == true) {
                all.forEach { put(recordKey(it), recorded(it)) }
            } else {
                val path = pointer.getValue("path").jsonPrimitive.content
                val record = all.single { recordKey(it) == recordKey("GET", path, null) }
                put(recordKey(record), recorded(record))
            }
        }
    }

    private fun showModel(request: HttpRequestData): String? {
        if (request.method != HttpMethod.Post) return null
        val text = (request.body as? TextContent)?.text ?: return null
        return runCatching { json.parseToJsonElement(text).jsonObject.string("model") }.getOrNull()
    }

    private fun connector(
        routes: Map<String, Recorded>,
        unreachable: Boolean = false,
        requested: MutableList<String> = Collections.synchronizedList(mutableListOf()),
    ): LocalEngineConnector {
        val client = HttpClient(
            MockEngine { request ->
                if (unreachable) throw ConnectException("Connection refused")
                val path = request.url.encodedPath
                if (request.method == HttpMethod.Get) requested += path
                val hit = routes[recordKey(request.method.value, path, showModel(request))]
                    ?: Recorded(404, "text/plain", "404 page not found")
                respond(
                    content = hit.body,
                    status = HttpStatusCode.fromValue(hit.status),
                    headers = headersOf(HttpHeaders.ContentType, hit.contentType),
                )
            },
        )
        val relayService = mockk<RelayService>()
        coEvery { relayService.pingRelay(any(), any(), any(), any(), any()) } returns Unit
        return LocalEngineConnector(client, json, relayService)
    }
}
