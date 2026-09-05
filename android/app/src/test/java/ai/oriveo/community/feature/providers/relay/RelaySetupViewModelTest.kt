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
        assertEquals(RelayConnectionSecurityMode.RemoteHttps, viewModel.securityMode)
        assertEquals(RelayConnectionSecurityMode.RemoteHttps, viewModel.formDraft.securityMode)
        assertEquals(RelayQuickAction.Detect, viewModel.quickAction)
        assertFalse(viewModel.canRunQuickAction)

        viewModel.updateEndpoint("https://relay.example/v1")
        viewModel.updateApiKey("sk-test")
        assertTrue(viewModel.canRunQuickAction)
    }

    @Test
    fun `public relay create flow always rejects cleartext endpoints`() {
        val viewModel = createViewModel()
        viewModel.showManualSetup()
        viewModel.selectRelayKind(RelayKind.Custom)
        viewModel.updateEndpoint("http://192.168.1.20:1234/v1")
        viewModel.updateApiKey("sk-secret")

        assertEquals(RelayConnectionSecurityMode.RemoteHttps, viewModel.securityMode)
        assertEquals(RelayConnectionSecurityMode.RemoteHttps, viewModel.formDraft.securityMode)
        assertFalse(viewModel.canSubmit)

        val relayScreen = File(
            "src/main/java/ai/oriveo/community/feature/providers/relay/RelaySetupScreen.kt",
        ).readText()
        val localScreen = File(
            "src/main/java/ai/oriveo/community/feature/providers/local/LocalComputeSetupScreen.kt",
        ).readText()
        assertFalse(relayScreen.contains("RelaySecurityModeControl("))
        assertTrue(localScreen.contains("RelaySecurityModeControl("))
    }

    @Test
    fun `catalog detection tests real chat paths and selects first protocol that passes`() = runTest {
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
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } returns result
        coEvery {
            providerRepository.pingRelayConnection(
                apiKey = "sk-test",
                baseUrl = "https://relay.example/v1",
                modelID = "model-first",
                relayRequested = match { it.transport == RelayTransport.OpenAIChatCompletions },
                relayKind = RelayKind.OpenAICompatible,
            )
        } throws ProviderServiceError.Upstream(404, "missing")
        coEvery {
            providerRepository.pingRelayConnection(
                apiKey = "sk-test",
                baseUrl = "https://relay.example/v1",
                modelID = "model-first",
                relayRequested = match {
                    it.transport == RelayTransport.OpenAIResponses &&
                        it.resolvedAPIBaseURL == "https://relay.example/v1"
                },
                relayKind = RelayKind.CodexStyle,
            )
        } returns Unit

        val viewModel = readyQuickViewModel()
        viewModel.runQuickAction()
        advanceUntilIdle()

        assertEquals("model-first", viewModel.defaultModel)
        assertEquals(RelayTransport.OpenAIResponses, viewModel.selectedDetection?.transport)
        assertEquals(RelayQuickAction.ConnectAndSave, viewModel.quickAction)
        // The evidence here comes from production discovery plus a 1-token chat path, not a test-authored fixture.
        assertEquals(
            CustomLLMVerificationEvidence.GenerationVerified,
            viewModel.customLLMCoordinator.evidence?.verification,
        )
        assertTrue(viewModel.customLLMCoordinator.canCommit)
        val persistAttempt = requireNotNull(
            viewModel.customLLMCoordinator.beginCommit(CustomLLMConnectionMethod.Relay),
        )
        assertFalse(viewModel.customLLMCoordinator.canCommit)
        assertTrue(viewModel.customLLMCoordinator.canPersist(persistAttempt))
        assertFalse(viewModel.customLLMCoordinator.canNavigate(CustomLLMConnectionMethod.Relay))
        assertTrue(viewModel.customLLMCoordinator.finishCommit(persistAttempt))
        assertTrue(viewModel.customLLMCoordinator.canNavigate(CustomLLMConnectionMethod.Relay))
    }

    @Test
    fun `empty catalog exposes save and continue and persists issue state`() = runTest {
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
        val provider = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Issue(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
        )
        coEvery {
            providerRepository.registerRelayProvider(
                apiKey = "sk-test",
                baseUrl = "https://relay.example/v1",
                customName = null,
                relayKind = RelayKind.CodexStyle,
                relayRequested = match { it.resolvedAPIBaseURL == "https://relay.example/v1" },
                catalogModelIDs = emptyList(),
                preferredModelID = null,
                preferredCapabilities = emptySet(),
                connectionVerified = false,
                commitGuard = any(),
            )
        } returns provider

        val viewModel = readyQuickViewModel()
        viewModel.runQuickAction()
        advanceUntilIdle()
        assertEquals(RelayQuickAction.SaveAndContinue, viewModel.quickAction)

        viewModel.runQuickAction()
        advanceUntilIdle()

        assertEquals(RelaySetupCompletionTarget.ManualModelEntry("relay-1"), viewModel.completionTarget)
        assertTrue(viewModel.customLLMCoordinator.canNavigate(CustomLLMConnectionMethod.Relay))

        // Simulates the user switching to the local scenario after the DB save completed but before the Compose navigation effect has run.
        viewModel.selectLocalMethod()
        assertNull(viewModel.completionTarget)
        assertFalse(viewModel.customLLMCoordinator.canNavigate(CustomLLMConnectionMethod.Relay))
    }

    @Test
    fun `generation verified empty catalog saves connected instead of manual issue`() = runTest {
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
        val provider = Provider(id = "relay-verified-empty", kind = ProviderKind.Relay)
        coEvery {
            providerRepository.registerRelayProvider(
                apiKey = "sk-test",
                baseUrl = "https://relay.example/v1",
                customName = null,
                relayKind = RelayKind.CodexStyle,
                relayRequested = any(),
                catalogModelIDs = emptyList(),
                preferredModelID = null,
                preferredCapabilities = emptySet(),
                connectionVerified = true,
                commitGuard = any(),
            )
        } returns provider

        val viewModel = readyQuickViewModel()
        viewModel.runQuickAction()
        advanceUntilIdle()

        assertEquals(RelayQuickAction.ConnectAndSave, viewModel.quickAction)
        assertEquals(CustomLLMVerificationEvidence.GenerationVerified, viewModel.customLLMCoordinator.evidence?.verification)
        viewModel.runQuickAction()
        advanceUntilIdle()
        // A 2xx on generation is evidence the connection works; an empty catalog only affects the
        // model list shown on the detail page, and must not divert completion to the manual
        // recovery path meant for an unverified connection.
        assertEquals(RelaySetupCompletionTarget.ProviderDetail("relay-verified-empty"), viewModel.completionTarget)
    }

    @Test
    fun `generation probe verified with user model skips duplicate ping`() = runTest {
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
        viewModel.updateDefaultModel("codex-model")
        viewModel.runQuickAction()
        advanceUntilIdle()

        assertEquals(RelayQuickAction.ConnectAndSave, viewModel.quickAction)
        coVerify(exactly = 0) { providerRepository.pingRelayConnection(any(), any(), any(), any(), any()) }
    }

    @Test
    fun `changing input cancels in flight discovery and stale result cannot overwrite state`() = runTest {
        val resultGate = CompletableDeferred<RelayDiscoveryResult>()
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } coAnswers { resultGate.await() }

        val viewModel = readyQuickViewModel()
        viewModel.runQuickAction()
        runCurrent()
        assertTrue(viewModel.isDiscovering)

        viewModel.updateEndpoint("https://new.example")
        resultGate.complete(catalogResult())
        advanceUntilIdle()

        assertFalse(viewModel.isDiscovering)
        assertNull(viewModel.discoveryResult)
        assertNull(viewModel.selectedDetection)
    }

    @Test
    fun `switching from relay to local cancels the production discovery generation`() = runTest {
        val resultGate = CompletableDeferred<RelayDiscoveryResult>()
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } coAnswers { resultGate.await() }

        val viewModel = readyQuickViewModel()
        viewModel.runQuickAction()
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
    fun `changing input cancels in flight connection test and clears stale success`() = runTest {
        val pingGate = CompletableDeferred<Unit>()
        coEvery { providerRepository.pingRelayConnection(any(), any(), any(), any(), any()) } coAnswers {
            pingGate.await()
        }
        val viewModel = createViewModel()
        viewModel.showManualSetup()
        viewModel.selectRelayKind(RelayKind.OpenAICompatible)
        viewModel.updateEndpoint("https://relay.example/v1")
        viewModel.updateApiKey("sk-test")
        viewModel.updateDefaultModel("model-a")

        viewModel.testConnection()
        runCurrent()
        assertTrue(viewModel.isTestingConnection)

        viewModel.updateEndpoint("https://new.example/v1")
        pingGate.complete(Unit)
        advanceUntilIdle()

        assertFalse(viewModel.isTestingConnection)
        assertNull(viewModel.testConnectionResult)
    }

    @Test
    fun `manual protocol save fetches catalog after ping and keeps only text capability`() = runTest {
        val catalog = catalogResult(
            RelayDetectedConfiguration(
                transport = RelayTransport.AnthropicMessages,
                authMode = RelayAuthMode.XApiKey,
                apiBaseUrl = "https://relay.example/v1",
                modelIDs = listOf("claude-model", "claude-other"),
                endpointEvidence = RelayEndpointCandidateEvidence.DefaultVersion,
                generationVerified = false,
            ),
        )
        coEvery { providerRepository.pingRelayConnection(any(), any(), any(), any(), any()) } returns Unit
        coEvery { discoveryService.discover(any(), any(), any(), any(), any(), any()) } returns catalog
        val provider = Provider(
            id = "relay-manual",
            kind = ProviderKind.Relay,
            models = listOf(AIModel(id = "claude-model", name = "claude-model")),
        )
        coEvery {
            providerRepository.registerRelayProvider(
                apiKey = "sk-ant-test",
                baseUrl = "https://relay.example/v1",
                customName = null,
                relayKind = RelayKind.AnthropicCompatible,
                relayRequested = any(),
                catalogModelIDs = listOf("claude-model", "claude-other"),
                preferredModelID = "claude-model",
                preferredCapabilities = setOf(ModelCapability.Text),
                connectionVerified = true,
                commitGuard = any(),
            )
        } returns provider

        val viewModel = createViewModel()
        viewModel.showManualSetup()
        viewModel.selectRelayKind(RelayKind.AnthropicCompatible)
        viewModel.updateEndpoint("https://relay.example/v1")
        viewModel.updateApiKey("sk-ant-test")
        viewModel.updateDefaultModel("claude-model")
        viewModel.submit()
        advanceUntilIdle()

        assertEquals(RelaySetupCompletionTarget.ProviderDetail("relay-manual"), viewModel.completionTarget)
    }

    @Test
    fun `manual protocol rejects embedded query before any request`() = runTest {
        val viewModel = createViewModel()
        viewModel.showManualSetup()
        viewModel.selectRelayKind(RelayKind.OpenAICompatible)
        viewModel.updateEndpoint("https://relay.example/v1?key=must-not-be-tried")
        viewModel.updateApiKey("sk-test")
        viewModel.updateDefaultModel("model")

        // This address is now caught by shared validation at the form layer itself (the save
        // button is disabled outright), rather than waiting for submit() to catch it after the
        // save button is pressed. The reason is still broken out by reason slug rather than
        // collapsed into a generic "enter a valid HTTPS address" message.
        assertFalse(viewModel.canSubmit)
        assertEquals(
            listOf(R.string.relay_quick_embedded_query),
            viewModel.displayableFormIssues.map { it.messageRes },
        )

        viewModel.submit()
        advanceUntilIdle()

        coVerify(exactly = 0) { providerRepository.pingRelayConnection(any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { discoveryService.discover(any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) {
            providerRepository.registerRelayProvider(
                any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any(),
            )
        }
    }

    @Test
    fun `completion uses connected evidence rather than catalog size`() {
        val provider = Provider(id = "relay-empty", kind = ProviderKind.Relay)
        assertEquals(
            RelaySetupCompletionTarget.ProviderDetail("relay-empty"),
            relaySetupCompletionTarget(provider),
        )
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

    private fun readyQuickViewModel(): RelaySetupViewModel = createViewModel().apply {
        updateEndpoint("https://relay.example/v1")
        updateApiKey("sk-test")
    }

    @Test
    fun `an explicit no-auth relay can be tested and saved without an api key`() {
        val viewModel = createViewModel()
        viewModel.showManualSetup()
        viewModel.selectRelayKind(RelayKind.Custom)
        // The address uses HTTPS: the add-connection page has no UI yet for choosing a
        // connection method, so it is always saved as remote_https. Storing a LAN http address
        // here would just create a zombie connection that saves fine but hard-fails on every
        // send, which the form layer now blocks outright (locked down by
        // RelayFormValidationTest). What this case is meant to prove is the credential gate.
        viewModel.updateEndpoint("https://relay.example/v1")

        // Auth mode = none -> this connection never had a key field to fill in, so it shouldn't be blocked by the apiKey-not-empty gate
        viewModel.customAuthMode = RelayAuthMode.None
        assertFalse(viewModel.requiresCredential)
        assertTrue(viewModel.canSubmit)
        assertTrue(viewModel.canTestConnection)

        // Switching back to an auth mode that requires a credential must bring the gate back immediately
        viewModel.customAuthMode = RelayAuthMode.Bearer
        assertTrue(viewModel.requiresCredential)
        assertFalse(viewModel.canSubmit)
        assertFalse(viewModel.canTestConnection)
    }

    @Test
    fun `built-in protocols keep requiring a key and quick setup stays fail-safe`() {
        val viewModel = createViewModel()

        // Quick setup hasn't detected the protocol yet -> auth mode is undetermined, treated as auto, and still requires a key
        viewModel.updateEndpoint("https://relay.example/v1")
        assertTrue(viewModel.requiresCredential)
        assertFalse(viewModel.canRunQuickAction)

        viewModel.showManualSetup()
        // The default configuration the production factory produces uses auth modes such as Bearer/x-api-key that require a credential
        RelayKind.entries.filter { it != RelayKind.Custom }.forEach { kind ->
            viewModel.selectRelayKind(kind)
            viewModel.updateEndpoint("https://relay.example/v1")
            assertTrue("$kind should be judged to require a credential by default", viewModel.requiresCredential)
            assertFalse("$kind should not allow saving without a key", viewModel.canSubmit)
        }
    }

    private fun createViewModel() = RelaySetupViewModel(
        context = context,
        providerRepository = providerRepository,
        discoveryService = discoveryService,
    )

    private fun catalogResult(vararg detections: RelayDetectedConfiguration): RelayDiscoveryResult =
        RelayDiscoveryResult(
            descriptor = RelayEndpointResolver.describe("https://relay.example/v1"),
            detections = detections.toList(),
            attempts = emptyList(),
            blockingFailure = if (detections.isEmpty()) RelayDiscoveryFailureKind.RouteUnavailable else null,
        )
}
