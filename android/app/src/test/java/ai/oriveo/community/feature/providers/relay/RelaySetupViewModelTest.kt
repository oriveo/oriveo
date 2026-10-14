package ai.oriveo.community.feature.providers.relay

import android.content.Context
import java.io.File
import ai.oriveo.community.R
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayDetectedConfiguration
import ai.oriveo.community.core.provider.RelayDetectionEvidence
import ai.oriveo.community.core.provider.RelayDiscoveryAttempt
import ai.oriveo.community.core.provider.RelayDiscoveryAttemptKind
import ai.oriveo.community.core.provider.RelayDiscoveryFailureKind
import ai.oriveo.community.core.provider.RelayDiscoveryResult
import ai.oriveo.community.core.provider.RelayDiscoveryService
import ai.oriveo.community.core.provider.RelayEndpointCandidateEvidence
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.feature.providers.CustomLLMConnectionMethod
import ai.oriveo.community.feature.providers.CustomLLMVerificationEvidence
import ai.oriveo.community.core.model.RelayKeyAccessOutcome
import ai.oriveo.community.core.provider.relay.RelayKeyBinding
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class RelaySetupViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val context = mockk<Context>()
    private val providerRepository = mockk<ProviderRepository>()
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

    @Test
    fun `quick setup is the default and starts in detect state`() {
        val viewModel = createViewModel()

        assertEquals(RelaySetupMode.Quick, viewModel.mode)
        assertEquals(RelaySetupStep.Address, viewModel.step)
        assertEquals(RelayConnectionSecurityMode.RemoteHttps, viewModel.securityMode)
        assertEquals(RelayConnectionSecurityMode.RemoteHttps, viewModel.formDraft.securityMode)
        assertNull(viewModel.board.detection)
        assertFalse(viewModel.board.isPrimaryEnabled)

        viewModel.updateEndpoint("https://relay.example/v1")
        viewModel.updateApiKey("sk-test")
        assertTrue(viewModel.board.isPrimaryEnabled)
    }

    @Test
    fun `public relay create flow always rejects cleartext endpoints`() {
        val viewModel = createViewModel()
        viewModel.showManualSetup()
        viewModel.updateEndpoint("http://192.168.1.20:1234/v1")
        viewModel.updateApiKey("sk-secret")
        viewModel.updateDefaultModel("model")

        assertEquals(RelayConnectionSecurityMode.RemoteHttps, viewModel.securityMode)
        assertEquals(RelayConnectionSecurityMode.RemoteHttps, viewModel.formDraft.securityMode)
        assertFalse(viewModel.manualBoard.primary.enabled)

        val relayScreen = File(
            "src/main/java/ai/oriveo/community/feature/providers/relay/RelaySetupScreen.kt",
        ).readText()
        val localScreen = File(
            "src/main/java/ai/oriveo/community/feature/providers/local/LocalComputeSetupScreen.kt",
        ).readText()
        assertFalse(relayScreen.contains("RelaySecurityModeControl("))
        assertTrue(localScreen.contains("RelaySecurityModeControl("))
    }

    /**
     * Detection sends no 1-token request; at save time only the first checked model in display order is probed
     * across the candidates, the first protocol that passes is recorded on that model, and the connection
     * protocol stays auto.
     */
    @Test
    fun `save probes the first selected model by candidate order and keeps the first pass`() = runTest {
        val result = catalogResult(
            RelayDetectedConfiguration(
                transport = RelayTransport.OpenAIChatCompletions,
                authMode = RelayAuthMode.Bearer,
                apiBaseUrl = "https://relay.example/v1",
                modelIDs = listOf("model-first", "model-second"),
                endpointEvidence = RelayEndpointCandidateEvidence.DefaultVersion,
                generationVerified = false,
            ),
            RelayDetectedConfiguration(
                transport = RelayTransport.OpenAIResponses,
                authMode = RelayAuthMode.Bearer,
                apiBaseUrl = "https://relay.example/v1",
                modelIDs = listOf("model-first", "model-second"),
                endpointEvidence = RelayEndpointCandidateEvidence.DefaultVersion,
                generationVerified = false,
            ),
        )
        family = { if (it == "model-first") "openai" else null }
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } returns result
        coEvery {
            providerRepository.pingRelayConnection(
                apiKey = "sk-test",
                baseUrl = "https://relay.example/v1",
                modelID = "model-first",
                relayRequested = match {
                    it.transport == RelayTransport.Auto && it.resolvedAPIBaseURL == "https://relay.example/v1"
                },
                relayKind = RelayKind.OpenAICompatible,
                modelTransport = RelayTransport.OpenAIResponses,
            )
        } throws ProviderServiceError.Upstream(404, "missing")
        coEvery {
            providerRepository.pingRelayConnection(
                apiKey = "sk-test",
                baseUrl = "https://relay.example/v1",
                modelID = "model-first",
                relayRequested = match { it.transport == RelayTransport.Auto },
                relayKind = RelayKind.OpenAICompatible,
                modelTransport = RelayTransport.OpenAIChatCompletions,
            )
        } returns Unit
        val registrations = stubRegister { Provider(id = "relay-first", kind = ProviderKind.Relay, status = ProviderConnectionState.Connected) }

        val viewModel = readyQuickViewModel()
        viewModel.next()
        advanceUntilIdle()
        assertEquals(RelaySetupStep.Models, viewModel.step)
        coVerify(exactly = 0) { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) }
        // Only after detection is there evidence to commit (verified at save time); the generation request has not been sent yet.
        assertEquals(
            CustomLLMVerificationEvidence.ManualModelRequired,
            viewModel.customLLMCoordinator.evidence?.verification,
        )

        viewModel.toggleModel("model-second")
        viewModel.toggleModel("model-first")
        viewModel.save()
        advanceUntilIdle()

        coVerify(exactly = 2) { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) }
        val saved = registrations.single()
        assertEquals(listOf("model-first", "model-second"), saved.enabledModelIDs)
        assertEquals("model-first", saved.preferredModelID)
        assertEquals(RelayTransport.OpenAIChatCompletions, saved.pass?.transport)
        assertEquals(RelayTransport.Auto, saved.requested.transport)
        assertTrue(saved.verified)
        assertEquals(RelaySetupCompletionTarget.ProviderDetail("relay-first", addedModelCount = 2), viewModel.completionTarget)
        assertTrue(viewModel.customLLMCoordinator.canNavigate(CustomLLMConnectionMethod.Relay))
    }

    @Test
    fun `empty catalog stops on step one and a manual model is verified before saving`() = runTest {
        val detection = RelayDetectedConfiguration(
            transport = RelayTransport.OpenAIResponses,
            authMode = RelayAuthMode.Bearer,
            apiBaseUrl = "https://relay.example/v1",
            modelIDs = emptyList(),
            endpointEvidence = RelayEndpointCandidateEvidence.DefaultVersion,
            generationVerified = false,
            detectionEvidence = RelayDetectionEvidence.GenerationProbe,
        )
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } returns catalogResult(detection)
        coEvery { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) } returns Unit
        val registrations = stubRegister { Provider(id = "relay-1", kind = ProviderKind.Relay, status = ProviderConnectionState.Connected) }

        val viewModel = readyQuickViewModel()
        viewModel.next()
        advanceUntilIdle()
        assertEquals(RelaySetupStep.Address, viewModel.step)
        assertEquals(RelaySetupFailureKind.ModelsEmpty, viewModel.board.detection?.keyLines?.single()?.failure)

        viewModel.next()
        assertEquals(RelaySetupStep.Models, viewModel.step)
        viewModel.addManualModel("manual-model")
        viewModel.save()
        advanceUntilIdle()

        val saved = registrations.single()
        // An auto connection with no chosen protocol is saved as fully custom by connection protocol; it is not pinned to the Codex preset by the detected protocol.
        assertEquals(RelayKind.Custom, saved.relayKind)
        // The discovered protocol (Responses) differs from the connection's actual default (auto means chat), so the root is recorded only in the per-protocol table.
        assertNull(saved.requested.resolvedAPIBaseURL)
        assertEquals(mapOf("openai_responses" to "https://relay.example/v1"), saved.requested.resolvedAPIBaseURLs)
        assertEquals(emptyList<String>(), saved.catalogIDs)
        assertEquals(listOf("manual-model"), saved.enabledModelIDs)
        assertTrue(saved.verified)
        assertEquals(RelaySetupCompletionTarget.ProviderDetail("relay-1", addedModelCount = 1), viewModel.completionTarget)
        assertTrue(viewModel.customLLMCoordinator.canNavigate(CustomLLMConnectionMethod.Relay))

        // Simulates the user switching to the local scenario after the DB save completed but before the Compose navigation effect has run.
        viewModel.selectLocalMethod()
        assertNull(viewModel.completionTarget)
        assertFalse(viewModel.customLLMCoordinator.canNavigate(CustomLLMConnectionMethod.Relay))
    }

    @Test
    fun `a discovery root on a protocol other than the connection default stays out of the single root`() = runTest {
        val detection = RelayDetectedConfiguration(
            transport = RelayTransport.GeminiGenerateContent,
            authMode = RelayAuthMode.XGoogApiKey,
            apiBaseUrl = "https://relay.example/v1beta",
            modelIDs = listOf("gemini-2.5-pro"),
            endpointEvidence = RelayEndpointCandidateEvidence.DefaultVersion,
            generationVerified = false,
        )
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } returns RelayDiscoveryResult(
            descriptor = RelayEndpointResolver.describe("https://relay.example"),
            detections = listOf(detection),
            attempts = emptyList(),
            blockingFailure = null,
        )
        family = { if (it == "gemini-2.5-pro") "google" else null }
        coEvery { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) } returns Unit
        val registrations = stubRegister { Provider(id = "relay-gemini", kind = ProviderKind.Relay) }

        val viewModel = createViewModel().apply {
            updateEndpoint("https://relay.example")
            updateApiKey("sk-test")
        }
        viewModel.next()
        advanceUntilIdle()
        assertEquals(RelaySetupStep.Models, viewModel.step)
        viewModel.toggleModel("gemini-2.5-pro")
        viewModel.save()
        advanceUntilIdle()

        val saved = registrations.single()
        val requested = saved.requested
        assertEquals(RelayTransport.Auto, requested.transport)
        assertNull(requested.resolvedAPIBaseURL)
        assertEquals("https://relay.example/v1beta", requested.resolvedAPIBaseURLs?.get("gemini_generate_content"))
        assertEquals(RelayTransport.GeminiGenerateContent, saved.pass?.transport)
        // A model that follows the connection (auto means chat) must not pick up Gemini's v1beta root.
        val followRoot = RelayEndpointResolver.effectiveAPIRoot(requested, "https://relay.example", AIModel(id = "gpt-4o-mini", name = "gpt-4o-mini"))
        assertEquals("https://relay.example/v1", followRoot)
    }

    @Test
    fun `an unverified generation route discovery does not count and the default model is probed`() = runTest {
        val detection = RelayDetectedConfiguration(
            transport = RelayTransport.OpenAIResponses,
            authMode = RelayAuthMode.Bearer,
            apiBaseUrl = "https://relay.example/v1",
            modelIDs = emptyList(),
            endpointEvidence = RelayEndpointCandidateEvidence.DefaultVersion,
            generationVerified = false,
            detectionEvidence = RelayDetectionEvidence.GenerationProbe,
        )
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } returns catalogResult(detection)
        coEvery {
            providerRepository.pingRelayConnection(
                apiKey = "sk-test",
                baseUrl = "https://relay.example/v1",
                modelID = "model-x",
                relayRequested = any(),
                relayKind = any(),
                modelTransport = RelayTransport.OpenAIResponses,
            )
        } returns Unit
        val registrations = stubRegister { Provider(id = "relay-x", kind = ProviderKind.Relay) }

        val viewModel = readyQuickViewModel()
        viewModel.next()
        advanceUntilIdle()
        // A working generation route (probed with a sentinel model) does not count as a model passing: step 1 does not probe,
        // and step 2 probes the first checked model at save time.
        coVerify(exactly = 0) { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) }
        viewModel.next()
        viewModel.addManualModel("model-x")
        viewModel.save()
        advanceUntilIdle()

        // The protocol found by the generation route probe (Responses) goes first, so the first attempt passes.
        assertEquals(RelayTransport.OpenAIResponses, registrations.single().pass?.transport)
        coVerify(exactly = 1) { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a failed detection after a successful one leaves no stale key catalogs for the manual save`() = runTest {
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } returns catalogResult(
            RelayDetectedConfiguration(
                transport = RelayTransport.OpenAIChatCompletions,
                authMode = RelayAuthMode.Bearer,
                apiBaseUrl = "https://relay.example/v1",
                modelIDs = listOf("gpt-x"),
                endpointEvidence = RelayEndpointCandidateEvidence.DefaultVersion,
                generationVerified = false,
            ),
        )
        coEvery { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) } returns Unit
        val registrations = stubRegister { Provider(id = "relay-stale", kind = ProviderKind.Relay) }

        val viewModel = readyQuickViewModel()
        viewModel.next()
        advanceUntilIdle()
        assertEquals(RelaySetupStep.Models, viewModel.step)

        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } returns catalogResult()
        viewModel.backToAddress()
        viewModel.updateApiKey("sk-other")
        viewModel.next()
        advanceUntilIdle()
        assertEquals(RelayCheckState.Failed, viewModel.board.detection?.rows?.first()?.state)
        viewModel.next()
        viewModel.addManualModel("manual-only")
        viewModel.save()
        advanceUntilIdle()

        val saved = registrations.single()
        assertTrue("the previous round's per-key catalogs must not carry into the manual-add save", saved.keyCatalogs.isEmpty())
        assertEquals(emptyList<String>(), saved.catalogIDs)
    }

    @Test
    fun `detection never sends a 1-token request even when the generation route answered`() = runTest {
        val detection = RelayDetectedConfiguration(
            transport = RelayTransport.OpenAIResponses,
            authMode = RelayAuthMode.Bearer,
            apiBaseUrl = "https://relay.example/v1",
            modelIDs = emptyList(),
            endpointEvidence = RelayEndpointCandidateEvidence.DefaultVersion,
            generationVerified = true,
            detectionEvidence = RelayDetectionEvidence.GenerationProbe,
        )
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } returns catalogResult(detection)

        val viewModel = readyQuickViewModel()
        viewModel.next()
        advanceUntilIdle()

        // Step 1 carries no model: the discovery service probes the generation endpoint with a sentinel model only (as before), so the model hint is always empty.
        coVerify { discoveryService.discover(any(), any(), modelHint = null, any(), any(), any()) }
        coVerify(exactly = 0) { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) }
        assertEquals(RelayCheckState.Done, viewModel.board.detection?.rows?.first()?.state)
    }

    @Test
    fun `changing input cancels in flight discovery and stale result cannot overwrite state`() = runTest {
        val resultGate = CompletableDeferred<RelayDiscoveryResult>()
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } coAnswers { resultGate.await() }

        val viewModel = readyQuickViewModel()
        viewModel.next()
        runCurrent()
        assertTrue(viewModel.isDiscovering)

        viewModel.updateEndpoint("https://new.example")
        resultGate.complete(catalogResult())
        advanceUntilIdle()

        assertFalse(viewModel.isDiscovering)
        assertNull(viewModel.discoveryResult)
        assertNull(viewModel.board.detection)
        assertEquals(RelaySetupStep.Address, viewModel.step)
    }

    @Test
    fun `switching from relay to local cancels the production discovery generation`() = runTest {
        val resultGate = CompletableDeferred<RelayDiscoveryResult>()
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } coAnswers { resultGate.await() }

        val viewModel = readyQuickViewModel()
        viewModel.next()
        runCurrent()
        assertTrue(viewModel.isDiscovering)

        viewModel.customLLMCoordinator.selectMethod(CustomLLMConnectionMethod.Local)
        resultGate.complete(catalogResult())
        advanceUntilIdle()

        assertEquals(CustomLLMConnectionMethod.Local, viewModel.customLLMCoordinator.method)
        assertNull(viewModel.customLLMCoordinator.evidence)
        assertFalse(viewModel.customLLMCoordinator.canCommit)
        assertNull(viewModel.registeredProvider)
        assertNull(viewModel.completionTarget)
    }

    @Test
    fun `step one failure sentence classes follow the address key permission network split`() {
        val candidate = RelayEndpointResolver.candidates(
            RelayEndpointResolver.describe("https://relay.example/v1"),
            RelayTransport.OpenAIChatCompletions,
        ).first()
        fun result(failure: RelayDiscoveryFailureKind, status: Int?) = RelayDiscoveryResult(
            descriptor = RelayEndpointResolver.describe("https://relay.example/v1"),
            detections = emptyList(),
            attempts = listOf(RelayDiscoveryAttempt(candidate, "https://relay.example/v1/models", status, failure)),
            blockingFailure = failure,
        )
        assertEquals(RelaySetupFailureKind.Address, relaySetupFailureKind(result(RelayDiscoveryFailureKind.RouteUnavailable, 404)))
        assertEquals(RelaySetupFailureKind.Address, relaySetupFailureKind(result(RelayDiscoveryFailureKind.InvalidResponse, 200)))
        assertEquals(RelaySetupFailureKind.InvalidKey, relaySetupFailureKind(result(RelayDiscoveryFailureKind.AuthenticationRejected, 401)))
        assertEquals(RelaySetupFailureKind.Permission, relaySetupFailureKind(result(RelayDiscoveryFailureKind.AuthenticationRejected, 403)))
        assertEquals(RelaySetupFailureKind.Network, relaySetupFailureKind(result(RelayDiscoveryFailureKind.Network, null)))
        assertEquals(RelaySetupFailureKind.Other, relaySetupFailureKind(result(RelayDiscoveryFailureKind.RateLimited, 429)))
        // Failures when fetching the catalog of each extra key go through the same classification.
        assertEquals(RelaySetupFailureKind.InvalidKey, relaySetupFailureKind(RelayKeyBinding.CatalogFetch.Failed(401, RelayKeyAccessOutcome.KeyInvalid)))
        assertEquals(RelaySetupFailureKind.Permission, relaySetupFailureKind(RelayKeyBinding.CatalogFetch.Failed(403, RelayKeyAccessOutcome.None)))
        assertEquals(RelaySetupFailureKind.Network, relaySetupFailureKind(RelayKeyBinding.CatalogFetch.Failed(null, RelayKeyAccessOutcome.None)))
    }

    @Test
    fun `quick save failure stays visible on step two instead of the manual-only error card`() = runTest {
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } returns catalogResult(
            RelayDetectedConfiguration(
                transport = RelayTransport.OpenAIChatCompletions,
                authMode = RelayAuthMode.Bearer,
                apiBaseUrl = "https://relay.example/v1",
                modelIDs = listOf("gpt-x"),
                endpointEvidence = RelayEndpointCandidateEvidence.DefaultVersion,
                generationVerified = false,
            ),
        )
        coEvery { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) } returns Unit
        coEvery {
            providerRepository.registerRelayProvider(
                any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(),
            )
        } throws ProviderServiceError.InvalidAPIKey("bad key")

        val viewModel = readyQuickViewModel()
        viewModel.next()
        advanceUntilIdle()
        viewModel.toggleModel("gpt-x")
        viewModel.save()
        advanceUntilIdle()

        assertEquals(RelaySetupStep.Models, viewModel.step)
        assertTrue(viewModel.modelsBoard.saveFailure != null)
        assertTrue(viewModel.modelsBoard.isSaveEnabled)
        assertNull(viewModel.completionTarget)
    }

    @Test
    fun `changing input cancels in flight manual validation and the stale result is dropped`() = runTest {
        val pingGate = CompletableDeferred<Unit>()
        coEvery { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) } coAnswers {
            pingGate.await()
        }
        val viewModel = createViewModel()
        viewModel.showManualSetup()
        viewModel.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        viewModel.updateEndpoint("https://relay.example/v1")
        viewModel.updateApiKey("sk-test")
        viewModel.updateDefaultModel("model-a")

        viewModel.validateManual()
        runCurrent()
        assertTrue(viewModel.isValidatingManual)

        viewModel.updateEndpoint("https://new.example/v1")
        pingGate.complete(Unit)
        advanceUntilIdle()

        assertFalse(viewModel.isValidatingManual)
        assertNull(viewModel.manualBoard.status)
        assertNull(viewModel.completionTarget)
    }

    @Test
    fun `manual setup with a chosen protocol pings once and registers only the typed model`() = runTest {
        coEvery { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) } returns Unit
        coEvery { providerRepository.refreshRelayCatalogOnly(any()) } returns mockk(relaxed = true)
        val args = mutableListOf<Any?>()
        coEvery {
            providerRepository.registerRelayProvider(
                any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(),
            )
        } answers {
            args.addAll(invocation.args)
            Provider(id = "relay-manual", kind = ProviderKind.Relay, models = listOf(AIModel(id = "claude-model", name = "claude-model")))
        }

        val viewModel = createViewModel()
        viewModel.showManualSetup()
        viewModel.selectManualTransport(RelayTransport.AnthropicMessages)
        viewModel.updateEndpoint("https://relay.example/v1")
        viewModel.updateApiKey("sk-ant-test")
        viewModel.updateDefaultModel("claude-model")
        viewModel.validateManual()
        advanceUntilIdle()

        coVerify(exactly = 1) { providerRepository.pingRelayConnection(any(), any(), "claude-model", any(), any(), any()) }
        coVerify(exactly = 0) { discoveryService.discover(any(), any(), any(), any(), any(), any()) }
        assertEquals(RelayKind.AnthropicCompatible, args[3])
        assertEquals(emptyList<String>(), args[5])
        assertEquals("claude-model", args[6])
        assertEquals(setOf(ModelCapability.Text), args[7])
        assertEquals(true, args[9])
        assertEquals(listOf("claude-model"), args[16])
        assertEquals(RelaySetupCompletionTarget.ProviderDetail("relay-manual", addedModelCount = 1), viewModel.completionTarget)
    }

    @Test
    fun `manual protocol rejects embedded query before any request`() = runTest {
        val viewModel = createViewModel()
        viewModel.showManualSetup()
        viewModel.selectManualTransport(RelayTransport.OpenAIChatCompletions)
        viewModel.updateEndpoint("https://relay.example/v1?key=must-not-be-tried")
        viewModel.updateApiKey("sk-test")
        viewModel.updateDefaultModel("model")

        // This address is caught by shared validation at the form layer itself (the primary button is
        // disabled outright), and the reason is broken out by reason slug.
        assertFalse(viewModel.manualBoard.primary.enabled)
        assertEquals(
            listOf(R.string.relay_quick_embedded_query),
            viewModel.displayableFormIssues.map { it.messageRes },
        )

        viewModel.validateManual()
        advanceUntilIdle()

        coVerify(exactly = 0) { providerRepository.pingRelayConnection(any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { discoveryService.discover(any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) {
            providerRepository.registerRelayProvider(
                any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(),
            )
        }
    }

    @Test
    fun `failure diagnostics keep the full method URL status matrix`() {
        val candidate = RelayEndpointResolver.candidates(
            RelayEndpointResolver.describe("https://relay.example/v1"),
            RelayTransport.OpenAIChatCompletions,
        ).first()
        val attempts = List(13) { index ->
            RelayDiscoveryAttempt(
                candidate = candidate,
                requestUrl = "https://relay.example/v1/${if (index == 12) "responses" else "models-$index"}",
                statusCode = 404,
                failure = RelayDiscoveryFailureKind.RouteUnavailable,
                kind = if (index == 12) {
                    RelayDiscoveryAttemptKind.GenerationProbe
                } else {
                    RelayDiscoveryAttemptKind.Catalog
                },
            )
        }

        val diagnostics = relayAttemptDiagnosticLines(attempts)

        assertEquals(13, diagnostics.size)
        assertEquals("GET https://relay.example/v1/models-0 -> 404", diagnostics.first())
        assertEquals("POST https://relay.example/v1/responses -> 404", diagnostics.last())
    }

    @Test
    fun `failure diagnostics prefer upstream message from 400 or 422`() {
        val candidate = RelayEndpointResolver.candidates(
            RelayEndpointResolver.describe("https://relay.example/v1"),
            RelayTransport.OpenAIResponses,
        ).first()
        val attempts = listOf(
            RelayDiscoveryAttempt(
                candidate = candidate,
                requestUrl = "https://relay.example/v1/responses",
                statusCode = 400,
                failure = null,
                kind = RelayDiscoveryAttemptKind.GenerationProbe,
                upstreamMessage = "current route: Codex API",
            ),
            RelayDiscoveryAttempt(
                candidate = candidate,
                requestUrl = "https://relay.example/responses",
                statusCode = 404,
                failure = RelayDiscoveryFailureKind.RouteUnavailable,
                kind = RelayDiscoveryAttemptKind.GenerationProbe,
                upstreamMessage = "not found",
            ),
        )

        assertEquals("current route: Codex API", relayPreferredUpstreamMessage(attempts))
    }

    @Test
    fun `failure diagnostics expose structured retry count for localized rendering`() {
        val candidate = RelayEndpointResolver.candidates(
            RelayEndpointResolver.describe("https://relay.example/v1"),
            RelayTransport.OpenAIChatCompletions,
        ).first()
        val attempts = listOf(
            RelayDiscoveryAttempt(
                candidate = candidate,
                requestUrl = "https://relay.example/v1/models",
                statusCode = null,
                failure = RelayDiscoveryFailureKind.Network,
                retryCount = 2,
            ),
        )

        assertEquals(2, relayRetryCount(attempts))
    }

    private data class Registration(
        val relayKind: RelayKind,
        val requested: RelayRequestedConfig,
        val catalogIDs: List<String>,
        val preferredModelID: String?,
        val verified: Boolean,
        val pass: ai.oriveo.community.core.provider.relay.RelayModelProbePass?,
        val enabledModelIDs: List<String>?,
        val keyCatalogs: Map<String, RelayKeyBinding.CatalogFetch>,
    )

    private fun stubRegister(answer: () -> Provider): List<Registration> {
        val captured = mutableListOf<Registration>()
        coEvery {
            providerRepository.registerRelayProvider(
                any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(),
            )
        } answers {
            captured += Registration(
                relayKind = arg(3),
                requested = arg(4),
                catalogIDs = arg(5),
                preferredModelID = arg(6),
                verified = arg(9),
                pass = arg(11),
                enabledModelIDs = arg(16),
                keyCatalogs = arg(15),
            )
            answer()
        }
        return captured
    }

    private fun readyQuickViewModel(): RelaySetupViewModel = createViewModel().apply {
        updateEndpoint("https://relay.example/v1")
        updateApiKey("sk-test")
    }

    @Test
    fun `an explicit no-auth relay can be validated without an api key`() {
        val viewModel = createViewModel()
        viewModel.showManualSetup()
        // The address uses HTTPS: the add-connection page always saves as remote_https (locked down by
        // RelayFormValidationTest). What this case is meant to prove is the credential gate.
        viewModel.updateEndpoint("https://relay.example/v1")
        viewModel.updateDefaultModel("model")

        // Auth mode = none -> this connection never had a key field to fill in, so it shouldn't be blocked by the apiKey-not-empty gate
        viewModel.selectManualAuthMode(RelayAuthMode.None)
        assertFalse(viewModel.requiresCredential)
        assertTrue(viewModel.manualBoard.primary.enabled)

        // Switching back to an auth mode that requires a credential must bring the gate back immediately
        viewModel.selectManualAuthMode(RelayAuthMode.Bearer)
        assertTrue(viewModel.requiresCredential)
        assertFalse(viewModel.manualBoard.primary.enabled)
    }

    @Test
    fun `credentialed auth modes keep requiring a key and quick setup stays fail-safe`() {
        val viewModel = createViewModel()

        // Quick setup hasn't detected the protocol yet -> auth mode is undetermined, treated as auto, and still requires a key
        viewModel.updateEndpoint("https://relay.example/v1")
        assertTrue(viewModel.requiresCredential)
        assertFalse(viewModel.board.isPrimaryEnabled)

        viewModel.showManualSetup()
        viewModel.updateDefaultModel("model")
        RelayAuthMode.entries.filter { it != RelayAuthMode.None }.forEach { mode ->
            viewModel.selectManualAuthMode(mode)
            assertTrue("$mode should be judged to require a credential", viewModel.requiresCredential)
            assertFalse("$mode should not allow validation without a key", viewModel.manualBoard.primary.enabled)
        }
    }

    /** The family lookup answers "unknown" by default; cases that need a family supply their own. Unit tests never hit production metadata. */
    private var family: (String) -> String? = { null }

    private fun createViewModel() = RelaySetupViewModel(
        context = context,
        providerRepository = providerRepository,
        discoveryService = discoveryService,
        modelFamily = { family(it) },
    )

    private fun catalogResult(vararg detections: RelayDetectedConfiguration): RelayDiscoveryResult =
        RelayDiscoveryResult(
            descriptor = RelayEndpointResolver.describe("https://relay.example/v1"),
            detections = detections.toList(),
            attempts = emptyList(),
            blockingFailure = if (detections.isEmpty()) RelayDiscoveryFailureKind.RouteUnavailable else null,
        )
}
