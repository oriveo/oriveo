package ai.oriveo.community.core.provider

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.feature.providers.local.LocalComputeSecurityModeChangeResult
import ai.oriveo.community.feature.providers.local.LocalComputeScenario
import ai.oriveo.community.feature.providers.local.LocalComputeSetupViewModel
import ai.oriveo.community.feature.providers.local.automaticPairingCandidates
import ai.oriveo.community.feature.providers.CustomLLMConnectionMethod
import ai.oriveo.community.feature.providers.CustomLLMSetupCoordinator
import io.mockk.coEvery
import io.mockk.coVerify
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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/** Phase-0 shared address/engine fixtures; address cases drive the production policy. */
class LocalComputeContractFixtureTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `local address fixture proves current HTTPS-only policy red`() {
        val contract = decode<AddressContract>("shared/test-fixtures/relay/local-address-classifier.v1.json")
        assertEquals(1, contract.version)
        assertEquals(20, contract.cases.size)

        val failures = contract.cases.mapNotNull { item ->
            val result = RelayEndpointPolicy.classify(
                raw = item.input,
                securityMode = RelayConnectionSecurityMode.entries.first { it.value == item.securityMode },
                resolvedIPs = item.resolvedIPs,
                recheckResolvedIPs = item.recheckResolvedIPs,
                redirects = item.redirects,
                credentials = item.credentials?.let {
                    RelayEndpointPolicy.Credentials(
                        authMode = it.authMode?.let { raw -> RelayAuthMode.entries.firstOrNull { mode -> mode.value == raw } },
                        hasKey = it.hasKey,
                        sensitiveHeaders = it.sensitiveHeaders,
                    )
                },
            )
            when {
                result.allowed != item.expect.allowed ->
                    "${item.caseId}: allowed=${result.allowed}, want ${item.expect.allowed} (${result.reason})"
                result.reason != item.expect.reason ->
                    "${item.caseId}: reason=${result.reason}, want ${item.expect.reason}"
                item.expect.normalized != null && result.normalized != item.expect.normalized ->
                    "${item.caseId}: normalized=${result.normalized}, want ${item.expect.normalized}"
                else -> null
            }
        }
        if (failures.isNotEmpty()) fail(failures.joinToString("\n"))
    }

    @Test
    fun `local engine scenarios cover every release engine`() {
        val fixture = decode<EngineFixture>("shared/test-fixtures/local-engine/scenarios.v1.json")
        assertEquals(1, fixture.version)
        assertEquals(15, fixture.scenarios.size)
        assertEquals(
            setOf("llamacpp", "ollama", "lmstudio", "vllm", "openwebui"),
            fixture.scenarios.map { it.engine }
                .filter { it in setOf("llamacpp", "ollama", "lmstudio", "vllm", "openwebui") }
                .toSet(),
        )
    }

    @Test
    fun `Open WebUI preset keeps bearer credentials on HTTPS`() {
        val viewModel = newViewModel()
        viewModel.selectEngine(LocalEngineKind.OpenWebUI)
        viewModel.updateEndpoint("https://openwebui.example")
        val mode = viewModel.securityMode

        assertEquals(RelayConnectionSecurityMode.RemoteHttps, mode)
        assertEquals(true, LocalEngineConnector.supportsSecurityMode(mode))
        assertEquals(
            "https://openwebui.example",
            RelayEndpointPolicy.requireConfigured(
                baseUrl = "https://openwebui.example",
                securityMode = mode,
                credentials = RelayEndpointPolicy.Credentials(
                    authMode = RelayAuthMode.Bearer,
                    hasKey = true,
                ),
            ),
        )
    }

    @Test
    fun `open webui http requires affirmative downgrade and clears its bearer key`() {
        val viewModel = newViewModel()
        viewModel.selectEngine(LocalEngineKind.OpenWebUI)
        viewModel.updateEndpoint("192.168.1.20:3000")
        viewModel.updateApiKey("open-webui-key")
        val assessment = RelaySecurityModePolicy.assess(
            rawEndpoint = viewModel.endpoint,
            resolvedIPs = listOf("192.168.1.20"),
        )

        assertEquals(
            LocalComputeSecurityModeChangeResult.NeedsConfirmation,
            viewModel.setSecurityMode(RelayConnectionSecurityMode.LocalHttp, assessment),
        )
        assertEquals(RelayConnectionSecurityMode.RemoteHttps, viewModel.securityMode)
        assertEquals("open-webui-key", viewModel.apiKey)
        assertEquals(
            LocalComputeSecurityModeChangeResult.Applied,
            viewModel.setSecurityMode(
                RelayConnectionSecurityMode.LocalHttp,
                assessment,
                confirmDowngrade = true,
            ),
        )
        assertEquals(RelayConnectionSecurityMode.LocalHttp, viewModel.securityMode)
        assertEquals(0..6, viewModel.endpointHighlightRange)
        assertEquals("", viewModel.apiKey)
        assertEquals(LocalEngineConnectionFailure.CleartextCredentials, viewModel.failure)

        val error = runCatching {
            RelayEndpointPolicy.requireConfigured(
                baseUrl = "http://192.168.1.20:3000",
                securityMode = viewModel.securityMode,
                credentials = RelayEndpointPolicy.Credentials(
                    authMode = RelayAuthMode.Bearer,
                    hasKey = true,
                ),
            )
        }.exceptionOrNull()
        assertEquals(
            "cleartext_credentials",
            (error as? ai.oriveo.community.core.model.ProviderServiceError.InvalidConfiguration)?.detail,
        )
        assertEquals(
            LocalEngineConnectionFailure.CleartextCredentials,
            LocalEngineConnector.configurationFailure(requireNotNull(error)),
        )
    }

    @Test
    fun `engine presets keep Open WebUI on HTTPS and clear credentials for local engines`() {
        val viewModel = newViewModel()

        viewModel.selectEngine(LocalEngineKind.OpenWebUI)
        assertEquals(RelayConnectionSecurityMode.RemoteHttps, viewModel.securityMode)
        viewModel.updateApiKey("open-webui-key")

        viewModel.selectEngine(LocalEngineKind.Ollama)
        assertEquals(RelayConnectionSecurityMode.RemoteHttps, viewModel.securityMode)
        assertEquals("", viewModel.apiKey)
    }

    @Test
    fun `only a pairing event with a supplied fingerprint produces tofu mode`() {
        val withoutFingerprint = newViewModel().apply {
            updatePairingCode("""{"v":1,"urls":["http://192.168.1.20:3000"],"engine":"OpenWebUI","auth":"none"}""")
            applyPairingCode()
        }
        assertEquals(RelayConnectionSecurityMode.RemoteHttps, withoutFingerprint.securityMode)

        val withFingerprint = newViewModel().apply {
            updatePairingCode("""{"v":1,"urls":["https://openwebui.example"],"engine":"OpenWebUI","auth":"none","fingerprint":"sha256:fixture"}""")
            applyPairingCode()
        }
        assertEquals(RelayConnectionSecurityMode.TofuHttps, withFingerprint.securityMode)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun `a verified local connection is persisted only after the second explicit action`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(dispatcher)
        try {
            val connector = mockk<LocalEngineConnector>()
            val repository = mockk<ProviderRepository>()
            coEvery { connector.connect(any(), any(), any(), any(), any(), any()) } returns LocalEngineConnection(
                engine = LocalEngineKind.Ollama,
                endpoint = "http://192.168.1.20:11434/v1",
                apiBaseUrl = "http://192.168.1.20:11434/v1",
                modelIds = listOf("local-model"),
                runtimeMetadata = emptyMap(),
                selectedModelId = "local-model",
                requested = RelayRequestedConfig(
                    transport = RelayTransport.OpenAIChatCompletions,
                    authMode = RelayAuthMode.None,
                    securityMode = RelayConnectionSecurityMode.LocalHttp,
                ),
            )
            coEvery {
                repository.registerRelayProvider(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any())
            } returns mockk(relaxed = true)
            val viewModel = LocalComputeSetupViewModel(
                connector = connector,
                providerRepository = repository,
                runtimeClient = mockk(relaxed = true),
            ).also { it.attachCoordinator(CustomLLMSetupCoordinator(CustomLLMConnectionMethod.Local)) }
            viewModel.updateEndpoint("192.168.1.20:11434/v1")
            viewModel.setSecurityMode(
                mode = RelayConnectionSecurityMode.LocalHttp,
                assessment = RelaySecurityModePolicy.assess("192.168.1.20:11434/v1", listOf("192.168.1.20")),
                confirmDowngrade = true,
            )

            viewModel.connect()
            advanceUntilIdle()

            assertTrue(viewModel.isConnectionVerified)
            coVerify(exactly = 0) {
                repository.registerRelayProvider(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any())
            }

            viewModel.connect()
            advanceUntilIdle()

            coVerify(exactly = 1) {
                repository.registerRelayProvider(any(), any(), any(), any(), any(), any(), any(), any(), any(), any(), any())
            }
        } finally {
            Dispatchers.resetMain()
        }
    }

    @Test
    fun `mixed fingerprint pairing cannot fall back from tofu to cleartext`() {
        val payload = LocalPairingPayload.decode(
            """{"v":1,"urls":["http://192.168.1.20:3000","https://openwebui.example"],"engine":"OpenWebUI","auth":"none","fingerprint":"sha256:fixture"}""",
        )
        val automatic = automaticPairingCandidates(payload.candidates, payload.fingerprint)
        assertEquals(listOf(RelayConnectionSecurityMode.TofuHttps), automatic.map { it.securityMode })

        val viewModel = newViewModel().apply {
            updatePairingCode("""{"v":1,"urls":["http://192.168.1.20:3000","https://openwebui.example"],"engine":"OpenWebUI","auth":"none","fingerprint":"sha256:fixture"}""")
            applyPairingCode()
        }
        assertEquals("https://openwebui.example", viewModel.endpoint)
        assertEquals(RelayConnectionSecurityMode.TofuHttps, viewModel.securityMode)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun `editing connection input cancels the old request before it can register`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(dispatcher)
        try {
            val connector = mockk<LocalEngineConnector>()
            val repository = mockk<ProviderRepository>(relaxed = true)
            val gate = CompletableDeferred<LocalEngineConnection>()
            coEvery { connector.connect(any(), any(), any(), any(), any(), any()) } coAnswers { gate.await() }
            val viewModel = LocalComputeSetupViewModel(
                connector = connector,
                providerRepository = repository,
                runtimeClient = mockk(relaxed = true),
            ).also { it.attachCoordinator(CustomLLMSetupCoordinator(CustomLLMConnectionMethod.Local)) }
            viewModel.selectScenario(LocalComputeScenario.FullAddress)
            viewModel.updateEndpoint("192.168.1.20:11434/v1")
            assertEquals(
                LocalComputeSecurityModeChangeResult.Applied,
                viewModel.setSecurityMode(
                    mode = RelayConnectionSecurityMode.LocalHttp,
                    assessment = RelaySecurityModePolicy.assess("192.168.1.20:11434/v1", listOf("192.168.1.20")),
                    confirmDowngrade = true,
                ),
            )
            assertEquals("http://192.168.1.20:11434/v1", viewModel.endpoint)
            assertEquals(0..6, viewModel.endpointHighlightRange)

            viewModel.connect()
            assertEquals("http://192.168.1.20:11434/v1", viewModel.endpoint)
            runCurrent()
            assertTrue(viewModel.isConnecting)

            viewModel.updateEndpoint("192.168.1.21:11434/v1")
            gate.complete(
                LocalEngineConnection(
                    engine = LocalEngineKind.Ollama,
                    endpoint = "http://192.168.1.20:11434/v1",
                    apiBaseUrl = "http://192.168.1.20:11434/v1",
                    modelIds = listOf("old-model"),
                    runtimeMetadata = emptyMap(),
                    selectedModelId = "old-model",
                    requested = RelayRequestedConfig(
                        transport = RelayTransport.OpenAIChatCompletions,
                        authMode = RelayAuthMode.None,
                        securityMode = RelayConnectionSecurityMode.RemoteHttps,
                    ),
                ),
            )
            advanceUntilIdle()

            assertFalse(viewModel.isConnecting)
            assertNull(viewModel.completedProvider)
            coVerify(exactly = 0) {
                repository.registerRelayProvider(any(), any(), any(), any(), any(), any(), any(), any(), any(), any())
            }
        } finally {
            Dispatchers.resetMain()
        }
    }

    private fun newViewModel() = LocalComputeSetupViewModel(
        connector = mockk(relaxed = true),
        providerRepository = mockk<ProviderRepository>(relaxed = true),
        runtimeClient = mockk(relaxed = true),
    ).also { it.attachCoordinator(CustomLLMSetupCoordinator(CustomLLMConnectionMethod.Local)) }

    private inline fun <reified T> decode(relativePath: String): T {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(relativePath) }
            .firstOrNull(Files::exists)
            ?: error("fixture not found: $relativePath")
        return json.decodeFromString(String(Files.readAllBytes(path), Charsets.UTF_8))
    }

    @Serializable
    private data class AddressContract(val version: Int, val cases: List<AddressCase>)

    @Serializable
    private data class AddressCase(
        val caseId: String,
        val input: String,
        val securityMode: String,
        val resolvedIPs: List<String> = emptyList(),
        val recheckResolvedIPs: List<String>? = null,
        val redirects: List<String> = emptyList(),
        val credentials: AddressCredentials? = null,
        val expect: AddressExpectation,
    )

    @Serializable
    private data class AddressCredentials(
        val authMode: String? = null,
        val hasKey: Boolean = false,
        val sensitiveHeaders: List<String> = emptyList(),
    )

    @Serializable
    private data class AddressExpectation(
        val allowed: Boolean,
        val reason: String,
        val normalized: String? = null,
    )

    @Serializable
    private data class EngineFixture(val version: Int, val scenarios: List<EngineScenario>)

    @Serializable
    private data class EngineScenario(val engine: String)
}
