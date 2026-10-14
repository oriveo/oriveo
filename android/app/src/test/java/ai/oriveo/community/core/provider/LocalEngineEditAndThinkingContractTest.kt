package ai.oriveo.community.core.provider

import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.EngineDeclaration
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayKindDefaults
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.transport.TransportRegistry
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsRender
import ai.oriveo.community.feature.providers.detail.ProviderDetailViewModel
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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/**
 * Editing of local-engine connections, the thinking row, and re-detection refreshing declarations.
 *
 * Expectations come from channels / edit / thinking in `shared/test-fixtures/local-engine/engine-expectations.v1.json`,
 * driven by caseId; thinking-row assertions use the projection from production [ModelOptionCapabilityShape.resolve], and edit assertions use
 * objects produced by production [ProviderDetailViewModel] / [RelayKindDefaults] / [ProviderRepository].
 */
@OptIn(ExperimentalCoroutinesApi::class)
class LocalEngineEditAndThinkingContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

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
    private fun JsonObject.flag(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull

    private val channels by lazy { expectations.getValue("channels").jsonObject }

    /** Channel short name (chat / native) -> wire transport. */
    private fun channelTransport(short: String): RelayTransport =
        RelayTransport.entries.single { it.value == channels.getValue(short).jsonPrimitive.content }

    private fun transport(wire: String): RelayTransport = RelayTransport.entries.single { it.value == wire }

    // ── Channel candidates ──

    @Test
    fun `RL2-ENGINE-03 channel candidates come from channels byEngine only`() {
        val byEngine = channels.getValue("byEngine").jsonObject
        assertTrue(channels.getValue("selectorShownOnlyWhenMoreThanOne").jsonPrimitive.content.toBoolean())
        for ((engine, shorts) in byEngine) {
            val expected = shorts.jsonArray.map { channelTransport(it.jsonPrimitive.content) }
            assertEquals(engine, expected, LocalEngineChannels.candidates(engine))
            assertEquals("$engine selector", expected.size > 1, LocalEngineChannels.showsSelector(engine))
        }
        // Connections without an engineProfile: not narrowed by engine, keep the existing transport menu.
        assertNull(LocalEngineChannels.candidates(null))
        assertTrue(LocalEngineChannels.showsSelector(null))
    }

    // ── Editing keeps the three engine fields ──

    private val edit by lazy { expectations.getValue("edit").jsonObject }

    private fun editConnection(): Provider {
        val connection = edit.getValue("connection").jsonObject
        val requested = connection.getValue("relayRequested").jsonObject
        return Provider(
            id = "provider-1",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            baseUrlText = connection.string("baseURL"),
            relayKind = RelayKind.OpenAICompatible,
            relayRequested = RelayRequestedConfig(
                transport = transport(requested.string("transport")!!),
                authMode = RelayAuthMode.None,
                securityMode = RelayConnectionSecurityMode.entries.single { it.value == requested.string("securityMode") },
                modelID = "local-model",
                engineProfile = requested.string("engineProfile"),
                certificateFingerprint = requested.string("certificateFingerprint"),
            ),
            models = listOf(AIModel(id = "local-model", name = "local-model", isDefault = true)),
            catalogModels = listOf(AIModel(id = "local-model", name = "local-model", isDefault = true)),
        )
    }

    private fun assertKeepsEngineFields(caseId: String, original: RelayRequestedConfig, edited: RelayRequestedConfig?) {
        assertNotNull(caseId, edited)
        assertEquals("$caseId engineProfile", original.engineProfile, edited!!.engineProfile)
        assertEquals("$caseId securityMode", original.securityMode, edited.securityMode)
        assertEquals("$caseId certificateFingerprint", original.certificateFingerprint, edited.certificateFingerprint)
    }

    private fun editCase(caseId: String): JsonObject =
        edit.getValue("cases").jsonArray.map { it.jsonObject }.single { it.string("caseId") == caseId }

    @Test
    fun `RL2-ENGINE-03 edit cases are all covered`() {
        val ids = edit.getValue("cases").jsonArray.map { it.jsonObject.string("caseId") }.toSet()
        assertEquals(
            setOf(
                "edit_address_keeps_engine_fields",
                "edit_key_keeps_engine_fields",
                "edit_channel_reverifies_default_model",
                "edit_channel_failed_verification_keeps_user_value",
                "relay_kind_change_keeps_engine_fields",
            ),
            ids,
        )
    }

    @Test
    fun `RL2-ENGINE-03 relay kind change keeps engine fields`() {
        val case = editCase("relay_kind_change_keeps_engine_fields")
        assertTrue(case.getValue("expect").jsonObject.flag("keepsEngineFields")!!)
        val original = editConnection().relayRequested!!
        for (kind in RelayKind.entries) {
            // The edit page's type switch uses exactly this production function (both confirm-switch and accept-suggestion).
            assertKeepsEngineFields("relay_kind_change_keeps_engine_fields/$kind", original, RelayKindDefaults.makeRequested(kind, original))
        }
        // Legacy protection: switching type on a connection without an engineProfile still resets the security mode to today's default.
        val cloud = original.copy(engineProfile = null)
        assertEquals(RelayConnectionSecurityMode.RemoteHttps, RelayKindDefaults.makeRequested(RelayKind.OpenAICompatible, cloud).securityMode)
        assertNull(RelayKindDefaults.makeRequested(RelayKind.OpenAICompatible, cloud).certificateFingerprint)
    }

    private val providerRepository = mockk<ProviderRepository>()

    private fun viewModel(provider: Provider): ProviderDetailViewModel {
        every { providerRepository.observeById("provider-1") } returns MutableStateFlow(provider)
        return ProviderDetailViewModel(
            savedStateHandle = SavedStateHandle(mapOf("providerID" to "provider-1")),
            providerRepository = providerRepository,
            appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true),
            metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
            applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
            globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true),
            defaultDispatcher = dispatcher,
        )
    }

    /** Edit page draft: copied from the saved connection, then the fixture's change is applied (same shape as the edit page's copy path). */
    private fun applyChange(provider: Provider, change: JsonObject): Pair<RelayRequestedConfig, String?> {
        var requested = provider.relayRequested!!
        change.string("transport")?.let { requested = requested.copy(transport = transport(it)) }
        return requested to (change.string("baseURL") ?: provider.baseUrlText)
    }

    @Test
    fun `RL2-ENGINE-03 address edit keeps engine fields and verifies as today`() = runTest(dispatcher) {
        val case = editCase("edit_address_keeps_engine_fields")
        val provider = editConnection()
        val (requested, baseUrl) = applyChange(provider, case.getValue("change").jsonObject)
        coEvery { providerRepository.verifyAndPersistRelayEdit(any(), null, any(), any(), any()) } coAnswers {
            ProviderRepository.RelayEditOutcome(provider = firstArg(), persisted = true, verificationSucceeded = true)
        }
        val vm = viewModel(provider)
        val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()

        vm.saveRelaySettings(provider, requested, baseUrl)
        advanceUntilIdle()

        coVerify(exactly = 1) {
            providerRepository.verifyAndPersistRelayEdit(
                match { candidate ->
                    assertKeepsEngineFields("edit_address_keeps_engine_fields", provider.relayRequested!!, candidate.relayRequested)
                    candidate.baseUrlText == "https://192.168.1.21:8443"
                },
                null,
                true,
                any(),
                any(),
            )
        }
        job.cancel()
    }

    @Test
    fun `RL2-ENGINE-03 channel change re-verifies the default model`() = runTest(dispatcher) {
        val case = editCase("edit_channel_reverifies_default_model")
        assertEquals("passes", case.string("verification"))
        val expect = case.getValue("expect").jsonObject
        val provider = editConnection()
        val (requested, baseUrl) = applyChange(provider, case.getValue("change").jsonObject)
        assertTrue(transport(expect.string("transport")!!) in LocalEngineChannels.candidates(provider.relayRequested?.engineProfile)!!)
        coEvery { providerRepository.verifyAndPersistRelayEdit(any(), null, any(), any(), any()) } coAnswers {
            ProviderRepository.RelayEditOutcome(provider = firstArg(), persisted = true, verificationSucceeded = true)
        }
        val vm = viewModel(provider)
        val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()

        vm.saveRelaySettings(provider, requested, baseUrl)
        advanceUntilIdle()

        coVerify(exactly = 1) {
            providerRepository.verifyAndPersistRelayEdit(
                match { candidate ->
                    assertKeepsEngineFields("edit_channel_reverifies_default_model", provider.relayRequested!!, candidate.relayRequested)
                    candidate.relayRequested?.transport == transport(expect.string("transport")!!) &&
                        candidate.defaultModel?.id == "local-model"
                },
                null,
                true,
                any(),
                any(),
            )
        }
        assertEquals(expect.flag("verified"), vm.relayConnectionTestResult?.isSuccess)
        job.cancel()
    }

    @Test
    fun `RL2-ENGINE-03 failed channel verification still saves the user channel as unverified`() = runTest(dispatcher) {
        val case = editCase("edit_channel_failed_verification_keeps_user_value")
        assertEquals("fails", case.string("verification"))
        val expect = case.getValue("expect").jsonObject
        val provider = editConnection()
        val (requested, baseUrl) = applyChange(provider, case.getValue("change").jsonObject)
        val revision = ProviderRepository.RelayEditRevision(with(ProviderMapper) { provider.toEntity("account-test") })
        coEvery { providerRepository.verifyAndPersistRelayEdit(any(), null, any(), any(), any()) } coAnswers {
            ProviderRepository.RelayEditOutcome(
                provider = null,
                persisted = false,
                verificationSucceeded = false,
                error = IllegalStateException(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
                failureRevision = revision,
            )
        }
        coEvery { providerRepository.persistRelayEditUnverified(any(), any(), any(), any(), any()) } coAnswers {
            ProviderRepository.RelayEditOutcome(provider = firstArg(), persisted = true, verificationSucceeded = false)
        }
        val vm = viewModel(provider)
        val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()

        vm.saveRelaySettings(provider, requested, baseUrl)
        advanceUntilIdle()
        assertEquals(expect.flag("verified"), vm.relayConnectionTestResult?.isSuccess)
        // Existing flow: a verification failure does not swallow the user's channel and opens "save as unverified".
        assertTrue(vm.canSaveRelaySettingsUnverified)
        vm.saveRelaySettingsUnverified()
        advanceUntilIdle()

        coVerify(exactly = 1) {
            providerRepository.persistRelayEditUnverified(
                match { candidate ->
                    assertKeepsEngineFields("edit_channel_failed_verification_keeps_user_value", provider.relayRequested!!, candidate.relayRequested)
                    candidate.relayRequested?.transport == transport(expect.string("transport")!!)
                },
                null,
                revision,
                any(),
                any(),
            )
        }
        job.cancel()
    }

    // ── Production ProviderRepository + fake server (key editing, re-detection) ──

    private val accountID = ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID

    private data class Recorded(val status: Int, val contentType: String, val body: String)

    private fun recordKey(method: String, path: String, model: String?): String = "$method $path ${model.orEmpty()}"

    private fun ollamaRoutes(): Map<String, Recorded> =
        recordings.getValue("engines").jsonObject.getValue("ollama").jsonObject.getValue("records").jsonArray.associate { item ->
            val record = item.jsonObject
            val request = record.getValue("request").jsonObject
            val response = record.getValue("response").jsonObject
            val body = response["body"]
            recordKey(
                request.getValue("method").jsonPrimitive.content,
                request.getValue("path").jsonPrimitive.content,
                (request["body"] as? JsonObject)?.string("model"),
            ) to Recorded(
                status = response.getValue("status").jsonPrimitive.content.toInt(),
                contentType = response.string("contentType") ?: "application/json",
                body = if (body == null || body is JsonNull) "404 page not found" else body.toString(),
            )
        }

    private fun showModel(request: HttpRequestData): String? {
        if (request.method != HttpMethod.Post) return null
        val text = (request.body as? TextContent)?.text ?: return null
        return runCatching { json.parseToJsonElement(text).jsonObject.string("model") }.getOrNull()
    }

    private inner class Harness(initial: Provider, routes: Map<String, Recorded>) {
        val requests = mutableListOf<String>()
        var stored: ai.oriveo.community.core.data.entity.ProviderEntity? = with(ProviderMapper) { initial.toEntity(accountID) }
        var apiKey = ""

        private val engine = MockEngine { request ->
            val path = request.url.encodedPath
            requests += "${request.method.value} $path"
            val hit = routes[recordKey(request.method.value, path, showModel(request))]
                ?: Recorded(404, "text/plain", "404 page not found")
            respond(hit.body, HttpStatusCode.fromValue(hit.status), headersOf(HttpHeaders.ContentType, hit.contentType))
        }

        private val relayService = RelayService(client = HttpClient(engine), json = json, transportRegistry = TransportRegistry(json))

        val repository: ProviderRepository = run {
            val dao = mockk<ai.oriveo.community.core.data.dao.ProviderDao>()
            coEvery { dao.getById(any(), any()) } coAnswers {
                stored?.takeIf { it.accountId == firstArg<String>() && it.id == secondArg<String>() }
            }
            coEvery { dao.upsert(any()) } coAnswers { stored = firstArg() }
            coEvery { dao.getAll(any()) } coAnswers { listOfNotNull(stored) }
            val keys = mockk<ai.oriveo.community.core.security.SecureKeyStore>(relaxed = true)
            every { keys.getApiKey(any(), any()) } answers { apiKey }
            every { keys.saveApiKey(any(), any(), any()) } answers { apiKey = thirdArg() }
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
                relayService = relayService,
                metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
                httpClient = HttpClient(MockEngine { respond("", HttpStatusCode.NotFound) }),
                localEngineConnector = LocalEngineConnector(HttpClient(engine), json, relayService),
            )
        }

        fun current(): Provider = with(ProviderMapper) { requireNotNull(stored).toDomain(apiKey) }
    }

    @Test
    fun `RL2-ENGINE-03 key edit keeps engine fields`() = runBlocking {
        val case = editCase("edit_key_keeps_engine_fields")
        val newKey = case.getValue("change").jsonObject.string("apiKey")!!
        val provider = editConnection()
        val harness = Harness(provider, emptyMap())
        // Production key-editing path; when local HTTPS is unreachable verification failure is still thrown as before, but the new key and connection fields are already persisted.
        runCatching { harness.repository.updateApiKey(provider.id, newKey) }
        val stored = harness.current()
        assertEquals(newKey, stored.apiKey)
        assertKeepsEngineFields("edit_key_keeps_engine_fields", provider.relayRequested!!, stored.relayRequested)
        assertEquals(provider.relayRequested?.transport, stored.relayRequested?.transport)
    }

    // ── Re-detection refreshes declarations, leaves overrides alone, does not probe transports ──

    @Test
    fun `RL2-ENGINE-02 redetect refreshes engine declarations and leaves overrides alone`() = runBlocking {
        val override = RelayCapabilityOverrides(image = true)
        fun model(id: String, declaration: EngineDeclaration?, overrides: RelayCapabilityOverrides? = null, isDefault: Boolean = false) = AIModel(
            id = id,
            name = id,
            capabilities = listOf(ModelCapability.Text),
            isDefault = isDefault,
            engineDeclaration = declaration,
            relayCapabilityOverrides = overrides,
        )
        // The stored declaration is the old one (opposite of the recording), qwen3 has a user override; gone is not in the engine catalog.
        val models = listOf(
            model("qwen3:0.6b", EngineDeclaration(image = true, toolCall = false, thinking = false), override, isDefault = true),
            model("oriveo-fixture-smolvlm:latest", EngineDeclaration(image = false)),
            model("gone:latest", EngineDeclaration(image = true)),
        )
        val provider = Provider(
            id = "local-ollama",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            baseUrlText = "http://127.0.0.1:11434",
            relayKind = RelayKind.OpenAICompatible,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                authMode = RelayAuthMode.None,
                securityMode = RelayConnectionSecurityMode.LocalHttp,
                modelID = "qwen3:0.6b",
                resolvedAPIBaseURL = "http://127.0.0.1:11434/v1",
                engineProfile = "ollama",
            ),
            models = models,
            catalogModels = models,
        )
        val harness = Harness(provider, ollamaRoutes())

        harness.repository.redetectRelayModels(provider.id)

        val stored = harness.current()
        val qwen = stored.models.single { it.id == "qwen3:0.6b" }
        assertEquals(EngineDeclaration(image = false, toolCall = true, thinking = true), qwen.engineDeclaration)
        assertEquals(override, qwen.relayCapabilityOverrides)
        assertEquals(
            EngineDeclaration(image = true, toolCall = false, thinking = false),
            stored.catalogModels.single { it.id == "oriveo-fixture-smolvlm:latest" }.engineDeclaration,
        )
        // Models for which the connector gave no declaration this time keep the old declaration.
        assertEquals(EngineDeclaration(image = true), stored.models.single { it.id == "gone:latest" }.engineDeclaration)
        // Local only clears without re-probing: no generation request is sent.
        assertFalse(harness.requests.toString(), harness.requests.any { it.endsWith("/chat/completions") || it.endsWith("/api/chat") })
    }

    // ── Thinking row by write-path table ──

    private val thinking by lazy { expectations.getValue("thinking").jsonObject }

    @Test
    fun `RL2-ENGINE-04 write path table matches the fixture`() {
        val paths = thinking.getValue("writePaths").jsonArray.map { it.jsonObject }
        assertEquals(6, paths.size)
        for (path in paths) {
            val engine = path.string("engineProfile")!!
            val channel = channelTransport(path.string("channel")!!)
            assertEquals("$engine/$channel", path.flag("writable"), LocalEngineChannels.thinkingWritable(engine, channel))
        }
    }

    private fun thinkingShape(engineProfile: String?, channel: RelayTransport, declaredThinking: Boolean?): ModelOptionCapabilityShape {
        val model = AIModel(
            id = "local-model",
            name = "local-model",
            isDefault = true,
            engineDeclaration = declaredThinking?.let { EngineDeclaration(thinking = it) },
        )
        val provider = Provider(
            id = "local-engine",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            baseUrlText = "http://127.0.0.1:8080",
            relayRequested = RelayRequestedConfig(
                transport = channel,
                authMode = RelayAuthMode.None,
                securityMode = RelayConnectionSecurityMode.LocalHttp,
                engineProfile = engineProfile,
            ),
            models = listOf(model),
            catalogModels = listOf(model),
        )
        // Same set of production projections as the model options panel group's thinking card input.
        return ModelOptionCapabilityShape.resolve(
            ModelOptionCapabilityShape.Input(
                capability = ModelOptionCapabilityShape.Capability.Reasoning,
                presentation = CapabilityControlPresentation.Unknown,
                availableIntents = emptyList(),
                selectedIntent = null,
                connection = ModelOptionsPanelInput.connectionCategory(provider.kind),
                protocolUndecided = ModelOptionsPanelInput.protocolUndecided(provider, model),
                customProtocol = ModelOptionsPanelInput.customProtocol(provider, model),
                chatTemplateThinking = false,
                localEngineThinking = ModelOptionsPanelInput.localEngineThinking(provider, model),
            ),
        )
    }

    @Test
    fun `RL2-ENGINE-04 thinking row matches every caseId`() {
        val cases = thinking.getValue("cases").jsonArray.map { it.jsonObject }
        assertEquals(8, cases.size)
        for (case in cases) {
            val caseId = case.string("caseId")!!
            val shape = thinkingShape(
                engineProfile = case.string("engineProfile"),
                channel = channelTransport(case.string("channel")!!),
                declaredThinking = case.flag("declaredThinking"),
            )
            when (case.string("expect")) {
                "toggle" -> assertEquals(
                    caseId,
                    ModelOptionCapabilityShape.Toggle(false, ModelOptionCapabilityShape.ToggleKind.ChatTemplateThinking),
                    shape,
                )
                "nonChatNotice" -> assertEquals(
                    caseId,
                    ModelOptionCapabilityShape.Notice(
                        ModelOptionCapabilityShape.NoticeStatus.NeedsOwnConfiguration,
                        ModelOptionCapabilityShape.NoticeBody.CustomThinkingUseAdditionalBody,
                        ModelOptionCapabilityShape.Escape.AdditionalBody,
                    ),
                    shape,
                )
                "usesModelDefaultNotice" -> {
                    val notice = shape as? ModelOptionCapabilityShape.Notice
                    assertNotNull("$caseId: $shape", notice)
                    assertEquals(caseId, ModelOptionCapabilityShape.NoticeStatus.FollowsModelDefault, notice!!.status)
                    // Only reuses the existing copy "Model default".
                    assertEquals(caseId, R.string.model_options_uses_model_default, ModelOptionsRender.noticeStatusRes(notice.status))
                }
                "unsupported" -> assertEquals(
                    caseId,
                    ModelOptionCapabilityShape.Disclosure(ModelOptionCapabilityShape.DisclosureStatus.ModelDoesNotThink),
                    shape,
                )
                else -> error("unknown expect in $caseId")
            }
        }
    }
}
