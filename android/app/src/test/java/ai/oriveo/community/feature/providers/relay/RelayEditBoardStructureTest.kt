package ai.oriveo.community.feature.providers.relay

import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayWebSearchToolName
import ai.oriveo.community.core.provider.RelayFormDraft
import ai.oriveo.community.core.provider.RelayFormValidation
import ai.oriveo.community.feature.providers.detail.ProviderDetailViewModel
import ai.oriveo.community.feature.providers.detail.RelayDetailIconTone
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.w3c.dom.Element

/**
 * Edit-connection board (EditConnection) structure test: the platform-neutral criteria BOARD-EDIT-01 to 19 finalized on iOS.
 * Asserts the output of the row model [RelayEditBoardModel]; save assertions go through the production save path [ProviderDetailViewModel.saveRelaySettings].
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RelayEditBoardStructureTest {

    private val dispatcher = StandardTestDispatcher()
    private val providerRepository = mockk<ProviderRepository>()

    @Before
    fun setUp() = Dispatchers.setMain(dispatcher)

    @After
    fun tearDown() = Dispatchers.resetMain()

    // ── Fixtures ──

    private fun relay(
        requested: RelayRequestedConfig = RelayRequestedConfig(
            transport = RelayTransport.Auto,
            authMode = RelayAuthMode.Bearer,
        ),
        baseUrl: String = "https://relay.example.com/v1",
        relayKind: RelayKind? = RelayKind.Custom,
        keys: List<RelayKey>? = null,
    ) = Provider(
        id = "provider-1",
        kind = ProviderKind.Relay,
        customName = "My Relay",
        status = ProviderConnectionState.Connected,
        baseUrlText = baseUrl,
        relayKind = relayKind,
        relayRequested = requested,
        relayKeys = keys,
    )

    private fun local(engine: String = "llamacpp", mode: RelayConnectionSecurityMode = RelayConnectionSecurityMode.LocalHttp) = relay(
        requested = RelayRequestedConfig(
            transport = RelayTransport.OpenAIChatCompletions,
            authMode = if (mode == RelayConnectionSecurityMode.RemoteHttps) RelayAuthMode.Bearer else RelayAuthMode.None,
            securityMode = mode,
            engineProfile = engine,
        ),
        baseUrl = if (mode == RelayConnectionSecurityMode.RemoteHttps) "https://studio.local:8443/v1" else "http://127.0.0.1:8080/v1",
        relayKind = RelayKind.OpenAICompatible,
    )

    private fun board(
        provider: Provider,
        draft: RelayEditDraft = RelayEditDraft.from(provider, null),
        status: RelayEditStatus? = null,
        isSaving: Boolean = false,
        issues: List<RelayFormValidation.FieldIssue> = emptyList(),
        shown: Set<RelayEditRowId> = emptySet(),
        headersExpanded: Boolean = false,
    ) = RelayEditBoardModel.make(provider, draft, status, isSaving, issues, shown, headersExpanded)

    private fun RelayEditBoard.group(id: RelayEditGroupId) = groups.single { it.id == id }

    private fun RelayEditBoard.rowIds(id: RelayEditGroupId) = group(id).rows.map { it.id }

    /** The edit page and the save path use the same validation: take the output of the production validation function. */
    private fun issuesOf(provider: Provider, draft: RelayEditDraft) = RelayFormValidation.validate(
        RelayFormDraft(
            requested = draft.requested.copy(
                headers = draft.headers.cleanRelayAdvancedPairs(),
                queryParams = draft.queryParams.cleanRelayAdvancedPairs(),
            ),
            endpoint = draft.endpoint,
            hasSavedCredential = !provider.apiKey.isNullOrBlank(),
        ),
        RelayFormValidation.FormMode.Edit,
    )

    // ── BOARD-EDIT-01 ──

    @Test
    fun `BOARD-EDIT-01 relay groups rows icons and header`() {
        val provider = relay()
        val draft = RelayEditDraft.from(provider, null).copy(
            headers = listOf(RelayKeyValue("X-Trace", "1")),
            queryParams = listOf(RelayKeyValue("tenant", "a")),
        )
        val b = board(provider, draft)

        assertEquals(R.string.relay_detail_edit_connection, b.titleRes)
        assertEquals("My Relay", b.subtitle)
        assertEquals(
            listOf(RelayEditGroupId.Connection, RelayEditGroupId.ProtocolAuth, RelayEditGroupId.Headers, RelayEditGroupId.Compatibility),
            b.groups.map { it.id },
        )
        assertEquals(
            listOf(R.string.relay_section_connection, R.string.relay_edit_section_protocol_auth, R.string.relay_section_headers_query, R.string.relay_section_request_behavior),
            b.groups.map { it.titleRes },
        )
        assertEquals(listOf(RelayEditRowId.RequestUrl, RelayEditRowId.ConnectionSecurity), b.rowIds(RelayEditGroupId.Connection))
        assertEquals(listOf(RelayEditRowId.DefaultProtocol, RelayEditRowId.Authentication), b.rowIds(RelayEditGroupId.ProtocolAuth))
        listOf(RelayEditGroupId.Connection, RelayEditGroupId.ProtocolAuth).forEach {
            assertFalse(b.group(it).collapsible)
            assertTrue(b.group(it).expanded)
        }
        listOf(RelayEditGroupId.Headers, RelayEditGroupId.Compatibility).forEach {
            assertTrue(b.group(it).collapsible)
            assertFalse("$it is collapsed by default", b.group(it).expanded)
        }

        val rows = b.groups.flatMap { it.rows }.associateBy { it.id }
        val url = rows.getValue(RelayEditRowId.RequestUrl)
        assertEquals(R.string.relay_field_endpoint, url.titleRes)
        assertEquals(R.drawable.ph_link_duotone to RelayDetailIconTone.Cyan, url.icon to url.tone)
        assertEquals(
            RelayEditText(R.string.relay_setup_will_request, listOf(RelayEditBoardModel.willRequest(provider.baseUrlText!!, RelayConnectionSecurityMode.RemoteHttps)!!)),
            url.footnote,
        )
        val security = rows.getValue(RelayEditRowId.ConnectionSecurity)
        assertEquals(R.string.relay_security_mode_label, security.titleRes)
        assertEquals(R.drawable.ph_shield_check_duotone to RelayDetailIconTone.Teal, security.icon to security.tone)
        assertEquals(R.string.relay_security_mode_remote_https, security.valueRes)
        assertEquals(RelayEditText(R.string.relay_edit_security_footnote), security.footnote)
        val protocol = rows.getValue(RelayEditRowId.DefaultProtocol)
        assertEquals(R.string.relay_edit_default_protocol, protocol.titleRes)
        assertEquals(R.drawable.ph_hard_drives_duotone to RelayDetailIconTone.Indigo, protocol.icon to protocol.tone)
        assertTrue(protocol.hasMenu)
        val auth = rows.getValue(RelayEditRowId.Authentication)
        assertEquals(R.string.relay_advanced_auth_mode, auth.titleRes)
        assertEquals(R.drawable.ph_key_duotone to RelayDetailIconTone.Orange, auth.icon to auth.tone)

        val headers = b.group(RelayEditGroupId.Headers).rows
        assertEquals(
            listOf(RelayEditRowId.UserAgent, RelayEditRowId.Header, RelayEditRowId.QueryParam, RelayEditRowId.AddEntry),
            headers.map { it.id },
        )
        assertEquals(R.string.relay_edit_user_agent, headers[0].titleRes)
        assertEquals(R.string.relay_edit_headers to true, headers[1].titleRes to headers[1].masked)
        assertEquals(R.string.relay_edit_query_params to false, headers[2].titleRes to headers[2].masked)
        assertEquals(R.string.add, headers[3].titleRes)

        // Not shown when the preview cannot be computed.
        val blank = board(provider, RelayEditDraft.from(provider, null).copy(endpoint = "   "))
        assertNull(blank.group(RelayEditGroupId.Connection).rows.first().footnote)
    }

    // ── BOARD-EDIT-02 ──

    @Test
    fun `BOARD-EDIT-02 local template uses engine address and channel and hides compatibility`() {
        val llama = board(local("llamacpp"))
        assertEquals(listOf(RelayEditGroupId.Connection, RelayEditGroupId.Channel), llama.groups.map { it.id })
        assertEquals(R.string.local_setup_tile_channel, llama.group(RelayEditGroupId.Channel).titleRes)
        assertEquals(listOf(RelayEditRowId.EngineAddress, RelayEditRowId.ConnectionSecurity), llama.rowIds(RelayEditGroupId.Connection))
        val address = llama.group(RelayEditGroupId.Connection).rows.first()
        assertEquals(R.string.relay_detail_engine_address, address.titleRes)
        assertEquals(R.drawable.ph_link_duotone to RelayDetailIconTone.Cyan, address.icon to address.tone)
        assertNull("local has no preview row", address.footnote)
        val channel = llama.group(RelayEditGroupId.Channel).rows.single()
        assertEquals(RelayEditRowId.Channel, channel.id)
        assertEquals(R.drawable.ph_hard_drives_duotone to RelayDetailIconTone.Indigo, channel.icon to channel.tone)
        assertEquals(R.string.relay_transport_openai_chat_completions, channel.valueRes)
        assertTrue("llama.cpp offers two selectable channels", channel.hasMenu)

        val ollama = board(local("ollama"))
        assertFalse("read-only when there is only one channel", ollama.group(RelayEditGroupId.Channel).rows.single().hasMenu)

        val privateVpn = board(local("ollama", RelayConnectionSecurityMode.PrivateVpn))
        assertEquals(listOf(RelayEditGroupId.Connection, RelayEditGroupId.Channel), privateVpn.groups.map { it.id })

        val encrypted = board(local("ollama", RelayConnectionSecurityMode.RemoteHttps))
        assertEquals(listOf(RelayEditGroupId.Connection, RelayEditGroupId.Channel, RelayEditGroupId.Headers), encrypted.groups.map { it.id })
        assertEquals(listOf(RelayEditRowId.Channel, RelayEditRowId.Authentication), encrypted.rowIds(RelayEditGroupId.Channel))
        listOf(llama, ollama, privateVpn, encrypted).forEach { b ->
            assertTrue(b.groups.none { it.id == RelayEditGroupId.Compatibility || it.id == RelayEditGroupId.ProtocolAuth })
        }
    }

    // ── BOARD-EDIT-03 ──

    @Test
    fun `BOARD-EDIT-03 default protocol and authentication footnotes`() {
        val auto = board(relay()).group(RelayEditGroupId.ProtocolAuth).rows
        assertEquals(RelayEditText(R.string.relay_edit_protocol_auto_footnote), auto[0].footnote)
        assertEquals(
            RelayEditText(R.string.relay_edit_auth_footnote, listOf(RelayEditText(R.string.api_key))),
            auto[1].footnote,
        )
        val chat = board(relay(RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions)))
            .group(RelayEditGroupId.ProtocolAuth).rows[0]
        assertEquals(
            RelayEditText(R.string.relay_edit_protocol_selected_footnote, listOf(RelayEditText(R.string.relay_transport_openai_chat_completions))),
            chat.footnote,
        )
        // With multiple keys the detail page key row is called "API Keys", and the footnote takes that row's own key.
        val twoKeys = relay(keys = listOf(RelayKey("a"), RelayKey("b")))
        assertEquals(
            RelayEditText(R.string.relay_edit_auth_footnote, listOf(RelayEditText(R.string.relay_keys_title))),
            board(twoKeys).group(RelayEditGroupId.ProtocolAuth).rows[1].footnote,
        )
    }

    // ── BOARD-EDIT-04 ──

    @Test
    fun `BOARD-EDIT-04 compatibility rows are trimmed by the default protocol`() {
        val all = listOf(RelayEditRowId.Stream, RelayEditRowId.ServiceTier, RelayEditRowId.DisableResponseStorage)
        val expected = mapOf(
            RelayTransport.Auto to all,
            RelayTransport.OpenAIResponses to all,
            RelayTransport.OpenAIChatCompletions to listOf(RelayEditRowId.Stream, RelayEditRowId.ServiceTier),
            RelayTransport.AnthropicMessages to listOf(RelayEditRowId.Stream),
            RelayTransport.GeminiGenerateContent to listOf(RelayEditRowId.Stream),
        )
        expected.forEach { (transport, rows) ->
            val b = board(relay(RelayRequestedConfig(transport = transport)))
            assertEquals("$transport", rows, b.rowIds(RelayEditGroupId.Compatibility))
        }
        val rows = board(relay()).group(RelayEditGroupId.Compatibility).rows
        assertEquals(
            listOf(R.string.relay_advanced_stream, R.string.relay_advanced_service_tier, R.string.relay_disable_response_storage_short),
            rows.map { it.titleRes },
        )
        assertEquals(RelayEditText(R.string.relay_disable_response_storage_footnote), rows[2].footnote)
    }

    // ── BOARD-EDIT-05 ──

    @Test
    fun `BOARD-EDIT-05 headers group counts filled entries and stays collapsed`() {
        val provider = relay()
        val draft = RelayEditDraft.from(provider, null).copy(
            requested = provider.relayRequested!!.copy(customUserAgent = "Bot/1"),
            headers = listOf(RelayKeyValue("X-A", ""), RelayKeyValue("  ", "v")),
            queryParams = listOf(RelayKeyValue("q", "1")),
        )
        val group = board(provider, draft).group(RelayEditGroupId.Headers)
        assertEquals(3, group.filledCount)
        assertFalse("collapsed by default regardless of count", group.expanded)
        assertNull(board(provider).group(RelayEditGroupId.Headers).filledCount)
        assertNull(
            board(provider, draft.copy(requested = draft.requested.copy(customUserAgent = "  "), headers = emptyList(), queryParams = emptyList()))
                .group(RelayEditGroupId.Headers).filledCount,
        )
    }

    // ── BOARD-EDIT-06 ──

    @Test
    fun `BOARD-EDIT-06 action bar titles and enable matrix`() {
        val provider = relay(baseUrl = "https://relay.example.com/v1")
        val draft = RelayEditDraft.from(provider, null)
        fun bar(
            d: RelayEditDraft = draft,
            status: RelayEditStatus? = null,
            saving: Boolean = false,
            p: Provider = provider,
        ) = board(p, d, status, saving, issuesOf(p, d)).actionBar

        assertEquals(R.string.save, bar().primaryTitleRes)
        assertEquals(R.string.relay_validate_and_save, bar(draft.copy(endpoint = "https://other.example.com/v1")).primaryTitleRes)
        assertEquals(R.string.relay_validate_and_save, bar(draft.copy(requested = draft.requested.copy(transport = RelayTransport.AnthropicMessages))).primaryTitleRes)
        assertEquals(R.string.relay_validate_and_save, bar(draft.copy(requested = draft.requested.copy(authMode = RelayAuthMode.XApiKey))).primaryTitleRes)
        assertEquals(R.string.save, bar(draft.copy(requested = draft.requested.copy(customUserAgent = "Bot/2"))).primaryTitleRes)
        // Stored relayKind differs from what the default transport implies: still Save.
        val legacy = relay(relayKind = RelayKind.CodexStyle)
        assertEquals(R.string.save, bar(RelayEditDraft.from(legacy, null), p = legacy).primaryTitleRes)

        fun matrix(b: RelayEditActionBar) = b.testEnabled to b.primaryEnabled
        assertEquals(true to true, matrix(bar()))
        assertEquals(false to false, matrix(bar(status = RelayEditStatus.Reconnecting)))
        assertEquals(false to false, matrix(bar(saving = true)))
        assertEquals(false to true, matrix(bar(status = RelayEditStatus.Testing)))
        assertEquals(true to true, matrix(bar(status = RelayEditStatus.Verified)))
        assertEquals(true to true, matrix(bar(status = RelayEditStatus.Failed("x", null, false))))
        assertEquals(true to false, matrix(bar(draft.copy(endpoint = "https://relay.example.com/v1?key=1"))))
        // With the real validation path an empty address is silently required and also blocks the primary button -> [no, no]; only with empty model-input issues is it [no, yes].
        val blank = draft.copy(endpoint = "   ")
        assertEquals(false to false, matrix(bar(blank)))
        assertTrue(issuesOf(provider, blank).isNotEmpty())
        assertEquals(false to true, matrix(board(provider, blank, issues = emptyList()).actionBar))
    }

    @Test
    fun `BOARD-EDIT-06 save is refused while the security reconnect is in flight and the reconnect only writes status`() = runTest(dispatcher) {
        val provider = relay(
            requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None),
            baseUrl = "127.0.0.1:8080/v1",
        )
        val renamedDuringReconnect = provider.copy(customName = "Renamed while reconnecting")
        val pingGate = CompletableDeferred<Unit>()
        val written = mutableListOf<Provider>()
        coEvery { providerRepository.updateProvider(any()) } coAnswers { written += firstArg<Provider>() }
        coEvery { providerRepository.pingRelayConnection(any(), any(), any(), any(), any()) } coAnswers {
            pingGate.await()
            error("upstream down")
        }
        coEvery { providerRepository.resyncProviderForModeTransition("provider-1", any()) } returns
            ProviderRepository.ProviderResyncOutcome(null, catalogSucceeded = true)
        coEvery { providerRepository.getById("provider-1") } returns renamedDuringReconnect
        val vm = viewModel(provider)
        val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()

        vm.changeRelaySecurityMode(provider, RelayConnectionSecurityMode.LocalHttp, "http://127.0.0.1:8080/v1")
        runCurrent()
        assertTrue(vm.isReconnectingRelaySecurity)
        vm.saveRelaySettings(provider, provider.relayRequested!!.copy(customUserAgent = "Bot"), "https://relay.example.com/v1")
        runCurrent()
        assertFalse("a save while reconnecting is not accepted", vm.isSavingRelaySettings)

        pingGate.complete(Unit)
        advanceUntilIdle()
        val last = written.last()
        assertEquals("after reconnecting, write onto the connection currently in the store", "Renamed while reconnecting", last.customName)
        assertTrue(last.status is ProviderConnectionState.Issue)
        assertFalse(vm.isReconnectingRelaySecurity)
        job.cancel()
    }

    // ── BOARD-EDIT-07 ──

    @Test
    fun `BOARD-EDIT-07 no type layer and only the listed rows`() {
        val autoBoards = RelayKind.entries.map { kind ->
            val p = relay(relayKind = kind)
            board(p, RelayEditDraft.from(p, null))
        }
        assertTrue("an auto connection yields the same groups and rows for any stored type", autoBoards.all { it == autoBoards.first() })
        val selected = RelayKind.entries.map { kind ->
            val p = relay(RelayRequestedConfig(transport = RelayTransport.OpenAIResponses), relayKind = kind)
            board(p, RelayEditDraft.from(p, null)).groups
        }
        assertTrue(selected.all { it == selected.first() })

        val allowed = setOf(
            RelayEditRowId.RequestUrl, RelayEditRowId.ConnectionSecurity, RelayEditRowId.DefaultProtocol,
            RelayEditRowId.Authentication, RelayEditRowId.UserAgent, RelayEditRowId.Header, RelayEditRowId.QueryParam,
            RelayEditRowId.AddEntry, RelayEditRowId.Stream, RelayEditRowId.ServiceTier, RelayEditRowId.DisableResponseStorage,
        )
        assertTrue(autoBoards.first().groups.flatMap { it.rows }.all { it.id in allowed })

        val sheet = repoFile("feature/providers/relay/RelayAdvancedSettingsSheet.kt").readText()
        listOf(
            "RelayEditorHeroCard", "RelayKindPicker", "RelayPresetModeInfoCard", "RelayKindSuggestionBanner",
            "relay_advanced_reasoning_effort", "reasoningEffort", "relayKind",
        ).forEach { assertFalse("edit connection still contains $it", sheet.contains(it)) }
        listOf("RelayEditorHeroCard.kt", "RelayPresetModeInfoCard.kt", "RelayAdvancedHttpDisclosure.kt", "RelayKvSection.kt").forEach {
            assertFalse("component files used only by this page should be deleted: $it", repoFileOrNull("feature/providers/relay/$it") != null)
        }
        // Manual settings page: reasoning controls and write-point removal.
        val setupVm = repoFile("feature/providers/relay/RelaySetupViewModel.kt").readText()
        assertFalse(setupVm.contains("customReasoningEffort"))
    }

    // ── BOARD-EDIT-08 ──

    @Test
    fun `BOARD-EDIT-08 production save derives relay kind clears reasoning and keeps every other field`() = runTest(dispatcher) {
        listOf<Boolean?>(null, true, false).forEach { identity ->
            val persistedRequested = RelayRequestedConfig(
                transport = RelayTransport.Auto,
                authMode = RelayAuthMode.Bearer,
                securityMode = RelayConnectionSecurityMode.RemoteHttps,
                reasoningEffort = RelayReasoningEffort.High,
                modelID = "legacy-default",
                serviceTier = "flex",
                stream = null,
                disableResponseStorage = true,
                headers = listOf(RelayKeyValue("X-Trace", "1")),
                codexCompatIdentity = identity,
                customUserAgent = "Bot/1",
                imageSize = "1024x1024",
                webSearchToolName = RelayWebSearchToolName.WebSearch,
                transportKind = "openai_chat",
                resolvedAPIBaseURL = "https://relay.example.com/v1",
                resolvedAPIBaseURLs = mapOf("openai_chat_completions" to "https://relay.example.com/v1"),
                certificateFingerprint = "AB:CD",
            )
            val provider = relay(persistedRequested, relayKind = RelayKind.OpenAICompatible)
            val captured = slot<Provider>()
            coEvery { providerRepository.persistRelayEditWithoutVerification(capture(captured), any(), any()) } coAnswers {
                ProviderRepository.RelayEditOutcome(provider = firstArg(), persisted = true, verificationSucceeded = false)
            }
            val vm = viewModel(provider)
            val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
            advanceUntilIdle()

            val draft = RelayEditDraft.from(provider, "sample-model")
            vm.saveRelaySettings(provider, draft.cleanedRequested(), "https://relay.example.com/v1")
            advanceUntilIdle()

            val saved = captured.captured
            assertEquals("auto → custom", RelayKind.Custom, saved.relayKind)
            assertEquals(RelayTransport.Auto, saved.relayRequested?.transport)
            assertEquals("no field changed: everything is unchanged except reasoningEffort and modelID being cleared", persistedRequested.copy(reasoningEffort = null, modelID = null), saved.relayRequested)
            assertEquals(identity, saved.relayRequested?.codexCompatIdentity)
            coVerify(exactly = 0) { providerRepository.verifyAndPersistRelayEdit(any(), any(), any(), any(), any()) }
            job.cancel()
        }
    }

    // ── BOARD-EDIT-09 ──

    @Test
    fun `BOARD-EDIT-09 status line states`() {
        assertEquals(RelayEditStatus.Reconnecting, RelayEditStatus.of(true, true, RelayConnectionTestResult(false, "x"), true))
        assertEquals(RelayEditStatus.Testing, RelayEditStatus.of(false, true, null, false))
        assertEquals(RelayEditStatus.Verified, RelayEditStatus.of(false, false, RelayConnectionTestResult(true, ""), false))
        assertEquals(RelayEditStatus.Failed("boom", null, true), RelayEditStatus.of(false, false, RelayConnectionTestResult(false, "boom"), true))
        assertNull(RelayEditStatus.of(false, false, null, false))

        val sheet = repoFile("feature/providers/relay/RelayAdvancedSettingsSheet.kt").readText()
        listOf(
            "R.string.relay_edit_status_reconnecting", "R.string.relay_edit_status_testing",
            "R.string.snackbar_connection_verified", "R.string.relay_save_unverified",
            // The failure card uses the shared OriveoErrorCard (technical details are collapsed inside the component); when unusable the primary button = close.
            "OriveoErrorCard(", "R.string.close",
        ).forEach { assertTrue("status row / failure card is missing $it", sheet.contains(it)) }
        // A failed verification shows only the failure card, with no confirmation dialog: the only dialog on the page is discarding unsaved changes.
        assertEquals(1, Regex("AlertDialog\\(").findAll(sheet).count())
    }

    @Test
    fun `BOARD-EDIT-09 testing an unchanged legacy connection writes back its status`() = runTest(dispatcher) {
        // A stored auto connection carries another relayKind and a connection-level tier: with an unchanged draft the test result should be written back to the connection (previously always judged different).
        val provider = relay(
            requested = RelayRequestedConfig(transport = RelayTransport.Auto, authMode = RelayAuthMode.None, reasoningEffort = RelayReasoningEffort.High),
            relayKind = RelayKind.OpenAICompatible,
        ).copy(models = listOf(AIModel(id = "model-a", name = "model-a")))
        coEvery { providerRepository.verifyPersistedRelayGeneration("provider-1") } returns
            ProviderRepository.RelayGenerationVerificationOutcome(provider, provider, verificationSucceeded = true)
        val vm = viewModel(provider)
        val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()

        val sample = vm.relaySampleModelID(provider)
        val draft = RelayEditDraft.from(provider, sample)
        vm.testRelayConnection(provider, draft.cleanedRequested(), "relay.example.com/v1/", sample.orEmpty())
        advanceUntilIdle()

        coVerify(exactly = 1) { providerRepository.verifyPersistedRelayGeneration("provider-1") }
        assertEquals(true, vm.relayConnectionTestResult?.isSuccess)
        job.cancel()
    }

    // ── BOARD-EDIT-10 ──

    @Test
    fun `BOARD-EDIT-10 every key the board and action bar emit is localized in 16 languages`() {
        val providers = listOf(
            relay(),
            relay(RelayRequestedConfig(transport = RelayTransport.OpenAIResponses), keys = listOf(RelayKey("a"), RelayKey("b"))),
            local("llamacpp"),
            local("ollama", RelayConnectionSecurityMode.RemoteHttps),
        )
        val keys = mutableSetOf<Int>()
        fun collect(text: RelayEditText?) {
            text ?: return
            keys += text.res
            text.args.filterIsInstance<RelayEditText>().forEach(::collect)
        }
        providers.forEach { p ->
            val d = RelayEditDraft.from(p, null).copy(headers = listOf(RelayKeyValue("A", "1")), queryParams = listOf(RelayKeyValue("b", "2")))
            val b = board(p, d)
            keys += b.titleRes
            b.groups.forEach { g ->
                keys += g.titleRes
                g.rows.forEach { r ->
                    keys += r.titleRes
                    r.valueRes?.let(keys::add)
                    collect(r.footnote)
                }
            }
        }
        keys += listOf(
            R.string.save, R.string.relay_validate_and_save, R.string.relay_test_connection,
            R.string.relay_edit_status_reconnecting, R.string.relay_edit_status_testing, R.string.snackbar_connection_verified,
            R.string.relay_save_unverified, R.string.technical_details, R.string.relay_discard_changes_title,
            R.string.relay_edit_unsaved_body, R.string.relay_discard_changes_confirm, R.string.relay_discard_changes_keep,
        )
        val names = R.string::class.java.fields.associate { it.getInt(null) to it.name }
        val wanted = keys.map { names.getValue(it) }.toSet() + "plurals:relay_edit_headers_set_count"
        val dirs = File(resRoot()).listFiles { f -> f.name == "values" || (f.name.startsWith("values-") && File(f, "strings.xml").exists() && f.name != "values-night") }!!
        assertEquals(16, dirs.size)
        val en = stringsIn(File(resRoot(), "values/strings.xml"))
        dirs.forEach { dir ->
            val strings = stringsIn(File(dir, "strings.xml"))
            wanted.forEach { name ->
                assertTrue("${dir.name} is missing $name", strings.containsKey(name))
                if (dir.name != "values" && name in setOf("save", "relay_validate_and_save")) {
                    assertTrue("$name in ${dir.name} fell back to English", strings[name] != en[name] || dir.name == "values")
                }
            }
        }
    }

    // ── BOARD-EDIT-11 ──

    @Test
    fun `BOARD-EDIT-11 primary title and save path agree on normalized address`() = runTest(dispatcher) {
        val provider = relay(
            requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None),
            baseUrl = "https://relay.example.com/v1/",
        )
        listOf(" relay.example.com/v1 ", "https://relay.example.com/v1", "relay.example.com/v1/").forEach { endpoint ->
            val d = RelayEditDraft.from(provider, null).copy(endpoint = endpoint)
            assertEquals(endpoint, R.string.save, board(provider, d).actionBar.primaryTitleRes)
        }
        val changed = RelayEditDraft.from(provider, null).copy(endpoint = "https://other.example.com/v1")
        assertEquals(R.string.relay_validate_and_save, board(provider, changed).actionBar.primaryTitleRes)
        // Local is untouched: Save.
        assertEquals(R.string.save, board(local("ollama")).actionBar.primaryTitleRes)

        coEvery { providerRepository.persistRelayEditWithoutVerification(any(), any(), any()) } coAnswers {
            ProviderRepository.RelayEditOutcome(provider = firstArg(), persisted = true, verificationSucceeded = false)
        }
        val vm = viewModel(provider)
        val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()
        vm.saveRelaySettings(provider, provider.relayRequested!!, "relay.example.com/v1")
        advanceUntilIdle()
        coVerify(exactly = 1) { providerRepository.persistRelayEditWithoutVerification(any(), any(), any()) }
        coVerify(exactly = 0) { providerRepository.verifyAndPersistRelayEdit(any(), any(), any(), any(), any()) }
        job.cancel()
    }

    @Test
    fun `BOARD-EDIT-11 unverified save is bound to the normalized draft`() = runTest(dispatcher) {
        val provider = relay(
            requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None),
        )
        val revision = ProviderRepository.RelayEditRevision(with(ProviderMapper) { provider.toEntity("account-test") })
        coEvery { providerRepository.verifyAndPersistRelayEdit(any(), null, any(), any(), any()) } returns ProviderRepository.RelayEditOutcome(
            provider = null,
            persisted = false,
            verificationSucceeded = false,
            error = IllegalStateException(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
            failureRevision = revision,
        )
        val unverified = slot<Provider>()
        coEvery { providerRepository.persistRelayEditUnverified(capture(unverified), any(), any(), any(), any()) } coAnswers {
            ProviderRepository.RelayEditOutcome(provider = firstArg(), persisted = true, verificationSucceeded = false)
        }
        val vm = viewModel(provider)
        val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()

        vm.saveRelaySettings(provider, provider.relayRequested!!, " other.example.com/v2/ ")
        advanceUntilIdle()
        assertTrue(vm.canSaveRelaySettingsUnverified)
        vm.saveRelaySettingsUnverified()
        advanceUntilIdle()
        assertEquals("https://other.example.com/v2", unverified.captured.baseUrlText)
        job.cancel()
    }

    // ── BOARD-EDIT-12 ──

    @Test
    fun `BOARD-EDIT-12 header issues sit under the last header row and open the group`() {
        val provider = relay(
            requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None,
                securityMode = RelayConnectionSecurityMode.LocalHttp),
            baseUrl = "http://127.0.0.1:8080/v1",
        )
        val draft = RelayEditDraft.from(provider, null).copy(
            headers = listOf(RelayKeyValue("X-Trace", "1"), RelayKeyValue("Authorization", "Bearer x")),
        )
        val issues = issuesOf(provider, draft)
        assertTrue(issues.any { it.field == RelayFormValidation.Field.Headers })
        val b = board(provider, draft, issues = issues, headersExpanded = false)
        val headers = b.group(RelayEditGroupId.Headers)
        assertTrue("a collapsed group is also expanded when it has a hint", headers.expanded)
        val headerRows = headers.rows.filter { it.id == RelayEditRowId.Header }
        assertTrue(headerRows.first().issues.isEmpty())
        assertEquals(RelayFormValidation.Field.Headers, headerRows.last().issues.single().field)
        assertTrue(b.connectionIssues.none { it.field == RelayFormValidation.Field.Headers })
        assertFalse("primary button is disabled while a hint exists", b.actionBar.primaryEnabled)

        // Required-type issues show no text.
        val silent = board(provider, draft.copy(headers = emptyList(), endpoint = ""), issues = listOf(
            RelayFormValidation.FieldIssue(RelayFormValidation.Field.Endpoint, RelayFormValidation.IssueCode.EndpointRequired),
        ))
        assertTrue(silent.connectionIssues.isEmpty())

        // The page has no request-header group (local plaintext): the hint stays under the connection card.
        val localProvider = local("ollama")
        val localIssue = RelayFormValidation.FieldIssue(RelayFormValidation.Field.Headers, RelayFormValidation.IssueCode.CleartextCredentials)
        val localBoard = board(localProvider, issues = listOf(localIssue))
        assertEquals(listOf(localIssue), localBoard.connectionIssues)
    }

    // ── BOARD-EDIT-13 ──

    @Test
    fun `BOARD-EDIT-13 probed roots survive an unchanged address and clear on a real change`() {
        listOf(
            Triple("https://relay.example.com/v1/", RelayConnectionSecurityMode.RemoteHttps, " relay.example.com/v1 "),
            Triple("http://localhost:11434/v1", RelayConnectionSecurityMode.LocalHttp, "localhost:11434/v1/"),
            Triple("http://studio.local:1234/v1", RelayConnectionSecurityMode.LocalHttp, "http://studio.local:1234/v1"),
        ).forEach { (stored, mode, edited) ->
            val provider = relay(
                requested = RelayRequestedConfig(
                    securityMode = mode,
                    resolvedAPIBaseURL = "$stored/root",
                    resolvedAPIBaseURLs = mapOf("openai_chat_completions" to "$stored/root"),
                ),
                baseUrl = stored,
            )
            val kept = RelayEditSavePolicy.savedRequested(provider, provider.relayRequested!!, edited)
            assertEquals(stored, "$stored/root", kept.resolvedAPIBaseURL)
            assertEquals(stored, mapOf("openai_chat_completions" to "$stored/root"), kept.resolvedAPIBaseURLs)
            val cleared = RelayEditSavePolicy.savedRequested(provider, provider.relayRequested!!, "https://elsewhere.example.com/v1")
            assertNull(cleared.resolvedAPIBaseURL)
            assertNull(cleared.resolvedAPIBaseURLs)
        }
    }

    // ── BOARD-EDIT-14 / 16 ──

    @Test
    fun `BOARD-EDIT-14 status and failure card reveal only when they appear`() {
        val failed = RelayEditStatus.Failed("x", null, false)
        assertTrue(RelayEditBoardModel.revealsStatus(null, RelayEditStatus.Testing))
        assertFalse(RelayEditBoardModel.revealsStatus(RelayEditStatus.Verified, RelayEditStatus.Verified))
        assertFalse(RelayEditBoardModel.revealsStatus(failed, null))
    }

    @Test
    fun `BOARD-EDIT-16 a late result replacing the in flight line does not reveal`() {
        val failed = RelayEditStatus.Failed("x", null, false)
        listOf(RelayEditStatus.Testing, RelayEditStatus.Reconnecting).forEach { inFlight ->
            assertFalse(RelayEditBoardModel.revealsStatus(inFlight, RelayEditStatus.Verified))
            assertFalse(RelayEditBoardModel.revealsStatus(inFlight, failed))
        }
        assertTrue(RelayEditBoardModel.revealsStatus(null, RelayEditStatus.Testing))
        assertTrue(RelayEditBoardModel.revealsStatus(RelayEditStatus.Verified, RelayEditStatus.Testing))
        assertTrue(RelayEditBoardModel.revealsStatus(failed, RelayEditStatus.Testing))
        assertTrue(RelayEditBoardModel.revealsStatus(null, failed))
        assertTrue(RelayEditBoardModel.revealsStatus(null, RelayEditStatus.Reconnecting))
        assertFalse(RelayEditBoardModel.revealsStatus(RelayEditStatus.Verified, null))
        assertFalse(RelayEditBoardModel.revealsStatus(RelayEditStatus.Testing, RelayEditStatus.Testing))
    }

    // ── BOARD-EDIT-15 ──

    @Test
    fun `BOARD-EDIT-15 compatibility values still in effect stay visible`() {
        val stored = relay(RelayRequestedConfig(transport = RelayTransport.AnthropicMessages, disableResponseStorage = true, serviceTier = "flex"))
        assertEquals(
            listOf(RelayEditRowId.Stream, RelayEditRowId.ServiceTier, RelayEditRowId.DisableResponseStorage),
            board(stored).rowIds(RelayEditGroupId.Compatibility),
        )
        val plain = relay(RelayRequestedConfig(transport = RelayTransport.GeminiGenerateContent))
        val draftOn = RelayEditDraft.from(plain, null).let { it.copy(requested = it.requested.copy(serviceTier = "priority")) }
        assertEquals(listOf(RelayEditRowId.Stream, RelayEditRowId.ServiceTier), board(plain, draftOn).rowIds(RelayEditGroupId.Compatibility))
        // No longer effective after save (cleared in the store) -> trimmed per the transport rules.
        assertEquals(listOf(RelayEditRowId.Stream), board(plain).rowIds(RelayEditGroupId.Compatibility))
    }

    // ── BOARD-EDIT-17 ──

    @Test
    fun `BOARD-EDIT-17 tapping a group opened by issues records expanded`() {
        assertTrue(RelayEditBoardModel.toggledExpansion(current = false, forcedOpen = true))
        assertTrue(RelayEditBoardModel.toggledExpansion(current = true, forcedOpen = true))
        assertTrue(RelayEditBoardModel.toggledExpansion(current = false, forcedOpen = false))
        assertFalse(RelayEditBoardModel.toggledExpansion(current = true, forcedOpen = false))
        // After correcting it stays expanded: the user's choice is already recorded as expanded.
        val provider = relay()
        assertTrue(board(provider, headersExpanded = true).group(RelayEditGroupId.Headers).expanded)
    }

    // ── BOARD-EDIT-18 ──

    @Test
    fun `BOARD-EDIT-18 rows the draft turned on stay until the page closes`() {
        val provider = relay(RelayRequestedConfig(transport = RelayTransport.OpenAIResponses))
        val base = RelayEditDraft.from(provider, null)
        val on = base.copy(requested = base.requested.copy(disableResponseStorage = true))
        val sticky = RelayEditBoardModel.draftTouchedCompatRows(on)
        assertEquals(setOf(RelayEditRowId.DisableResponseStorage), sticky)
        // After closing and switching to Messages: the row that was opened stays, and service tiers that never appeared are trimmed by transport.
        val offAndSwitched = base.copy(requested = base.requested.copy(disableResponseStorage = null, transport = RelayTransport.AnthropicMessages))
        assertEquals(
            listOf(RelayEditRowId.Stream, RelayEditRowId.DisableResponseStorage),
            board(provider, offAndSwitched, shown = sticky).rowIds(RelayEditGroupId.Compatibility),
        )
    }

    // ── BOARD-EDIT-19 ──

    /**
     * When the draft changes while "Verify and save" is in flight: this verification result is discarded -- nothing is written, no failure card, the page does not close.
     * Upstream ignores cancellation and returns as usual (once success, once failure); persistence only honors the commitGuard passed in by production, same as the real repository.
     */
    @Test
    fun `BOARD-EDIT-19 draft edited while validate and save is in flight discards the result`() = runTest(dispatcher) {
        val provider = relay(
            requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None),
        )
        val revision = ProviderRepository.RelayEditRevision(with(ProviderMapper) { provider.toEntity("account-test") })
        listOf(true, false).forEach { upstreamSucceeds ->
            val gate = CompletableDeferred<Unit>()
            val written = mutableListOf<Provider>()
            coEvery { providerRepository.updateProvider(any()) } coAnswers { written += firstArg<Provider>() }
            coEvery { providerRepository.verifyAndPersistRelayEdit(any(), any(), any(), any(), any()) } coAnswers {
                val commitGuard = arg<() -> Boolean>(3)
                withContext(NonCancellable) { gate.await() }
                when {
                    !upstreamSucceeds -> ProviderRepository.RelayEditOutcome(
                        provider = null,
                        persisted = false,
                        verificationSucceeded = false,
                        error = IllegalStateException(ProviderRepository.RELAY_UNVERIFIED_MESSAGE),
                        failureRevision = revision,
                    )
                    commitGuard() -> {
                        written += firstArg<Provider>()
                        ProviderRepository.RelayEditOutcome(provider = firstArg(), persisted = true, verificationSucceeded = true)
                    }
                    else -> ProviderRepository.RelayEditOutcome(null, persisted = false, verificationSucceeded = false, stale = true)
                }
            }
            val vm = viewModel(provider)
            val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
            advanceUntilIdle()

            var saved = 0
            vm.saveRelaySettings(provider, provider.relayRequested!!, "https://other.example.com/v1") { saved += 1 }
            runCurrent()
            assertTrue("verification in flight", vm.isSavingRelaySettings)
            // The draft changed: the same entry point the edit page uses on every change.
            vm.invalidateRelayDraftEvidence()
            gate.complete(Unit)
            advanceUntilIdle()

            assertTrue("upstream=$upstreamSucceeds: the discarded result is not written", written.isEmpty())
            coVerify(exactly = 0) { providerRepository.updateProvider(any()) }
            coVerify(exactly = 0) { providerRepository.persistRelayEditUnverified(any(), any(), any(), any(), any()) }
            assertNull("upstream=$upstreamSucceeds: no failure card", vm.relayConnectionTestResult)
            assertFalse(vm.canSaveRelaySettingsUnverified)
            assertEquals("upstream=$upstreamSucceeds: the page does not close", 0, saved)
            assertFalse(vm.isSavingRelaySettings)
            job.cancel()
        }
    }

    @Test
    fun `BOARD-EDIT-19 draft unchanged while validate and save is in flight saves and closes`() = runTest(dispatcher) {
        val provider = relay(
            requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None),
        )
        val gate = CompletableDeferred<Unit>()
        val written = mutableListOf<Provider>()
        coEvery { providerRepository.verifyAndPersistRelayEdit(any(), any(), any(), any(), any()) } coAnswers {
            val commitGuard = arg<() -> Boolean>(3)
            gate.await()
            if (commitGuard()) {
                written += firstArg<Provider>()
                ProviderRepository.RelayEditOutcome(provider = firstArg(), persisted = true, verificationSucceeded = true)
            } else {
                ProviderRepository.RelayEditOutcome(null, persisted = false, verificationSucceeded = false, stale = true)
            }
        }
        val vm = viewModel(provider)
        val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()

        var saved = 0
        vm.saveRelaySettings(provider, provider.relayRequested!!, "https://other.example.com/v1") { saved += 1 }
        runCurrent()
        assertTrue(vm.isSavingRelaySettings)
        gate.complete(Unit)
        advanceUntilIdle()

        assertEquals("https://other.example.com/v1", written.single().baseUrlText)
        assertEquals(true, vm.relayConnectionTestResult?.isSuccess)
        assertEquals("draft unchanged: save and close as usual", 1, saved)
        assertFalse(vm.isSavingRelaySettings)
        job.cancel()
    }

    // ── RL2-PROBESTATE-10 / 11: an edit save colliding with changes elsewhere merges per field ──

    @Test
    fun `RL2-PROBESTATE-10 merged save persisted without verification state still closes the page`() = runTest(dispatcher) {
        val provider = relay(
            requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None),
        )
        coEvery { providerRepository.verifyAndPersistRelayEdit(any(), any(), any(), any(), any()) } returns
            ProviderRepository.RelayEditOutcome(provider = null, persisted = true, verificationSucceeded = false)
        val vm = viewModel(provider)
        val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()

        var saved = 0
        vm.saveRelaySettings(provider, provider.relayRequested!!, "https://other.example.com/v1") { saved += 1 }
        advanceUntilIdle()

        assertEquals("do not stay silently on the page: close as usual", 1, saved)
        assertNull("without a written verification state there is no \"Connected\"", vm.relayConnectionTestResult)
        assertFalse(vm.canSaveRelaySettingsUnverified)
        assertFalse(vm.isSavingRelaySettings)
        job.cancel()
    }

    @Test
    fun `RL2-PROBESTATE-11 save hands the page-open baseline and a baseline-built candidate to the repository`() = runTest(dispatcher) {
        val baseline = relay(
            requested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                authMode = RelayAuthMode.None,
                headers = listOf(RelayKeyValue("X-Team", "a")),
            ),
        )
        // After the page is opened and before Save is tapped: synchronously change the request headers and name the user did not touch.
        val live = baseline.copy(
            customName = "Synced",
            relayRequested = baseline.relayRequested!!.copy(headers = listOf(RelayKeyValue("X-Team", "synced"))),
        )
        val candidate = slot<Provider>()
        val passedBaseline = slot<Provider>()
        coEvery {
            providerRepository.verifyAndPersistRelayEdit(capture(candidate), any(), any(), any(), capture(passedBaseline))
        } coAnswers { ProviderRepository.RelayEditOutcome(provider = null, persisted = true, verificationSucceeded = true) }
        val vm = viewModel(live)
        val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()

        vm.beginRelayEdit(baseline)
        val draft = RelayEditDraft.from(baseline, null)
        vm.saveRelaySettings(live, draft.cleanedRequested(), "https://other.example.com/v1")
        advanceUntilIdle()

        assertEquals(baseline, passedBaseline.captured)
        assertEquals("https://other.example.com/v1", candidate.captured.baseUrlText)
        assertEquals("the candidate is built from the baseline: untouched headers equal the baseline, the repository takes the live value", listOf(RelayKeyValue("X-Team", "a")), candidate.captured.relayRequested?.headers)
        assertEquals("My Relay", candidate.captured.customName)
        job.cancel()
    }

    @Test
    fun `RL2-PROBESTATE-11 a field changed elsewhere but untouched by the user does not trigger verification`() = runTest(dispatcher) {
        val baseline = relay(
            requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None),
        )
        // After the page is opened the auth scheme is synchronously changed to Bearer; the user changed only the UA.
        val live = baseline.copy(relayRequested = baseline.relayRequested!!.copy(authMode = RelayAuthMode.Bearer))
        val passedBaseline = slot<Provider>()
        coEvery { providerRepository.persistRelayEditWithoutVerification(any(), capture(passedBaseline), any()) } coAnswers {
            ProviderRepository.RelayEditOutcome(provider = firstArg(), persisted = true, verificationSucceeded = false)
        }
        val vm = viewModel(live)
        val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()

        vm.beginRelayEdit(baseline)
        val draft = RelayEditDraft.from(baseline, null)
        var saved = 0
        vm.saveRelaySettings(
            live,
            draft.cleanedRequested().copy(customUserAgent = "Bot/2"),
            "https://relay.example.com/v1",
        ) { saved += 1 }
        advanceUntilIdle()

        coVerify(exactly = 0) { providerRepository.verifyAndPersistRelayEdit(any(), any(), any(), any(), any()) }
        assertEquals(baseline, passedBaseline.captured)
        assertEquals(1, saved)
        job.cancel()
    }

    /**
     * A single key writing state, materializing the list into one entry, or merely a state change does not count as a verification-relevant change -- when the user changed only non-connection fields
     * the save goes without verification (the Android connection identity does not include relayKeys).
     */
    @Test
    fun `RL2-KEYSTATUS-11 a key status write or one-entry materialization is not a verification change`() = runTest(dispatcher) {
        val baseline = relay(keys = null)
        // After the page is opened a real request wrote the primary key state: the list is materialized into one entry; another one then sets the state to invalid.
        val materialized = baseline.copy(relayKeys = listOf(RelayKey("initial", status = ai.oriveo.community.core.model.RelayKeyStatus("ok"))))
        val restated = materialized.copy(relayKeys = listOf(RelayKey("initial", status = ai.oriveo.community.core.model.RelayKeyStatus("invalid", 401))))
        for (live in listOf(materialized, restated)) {
            io.mockk.clearMocks(providerRepository)
            coEvery { providerRepository.persistRelayEditWithoutVerification(any(), any(), any()) } coAnswers {
                ProviderRepository.RelayEditOutcome(provider = firstArg(), persisted = true, verificationSucceeded = false)
            }
            val vm = viewModel(live)
            val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
            advanceUntilIdle()

            vm.beginRelayEdit(baseline)
            val draft = RelayEditDraft.from(baseline, null)
            var saved = 0
            vm.saveRelaySettings(
                live,
                draft.cleanedRequested().copy(customUserAgent = "Bot/2"),
                "https://relay.example.com/v1",
            ) { saved += 1 }
            advanceUntilIdle()

            coVerify(exactly = 0) { providerRepository.verifyAndPersistRelayEdit(any(), any(), any(), any(), any()) }
            coVerify(exactly = 1) { providerRepository.persistRelayEditWithoutVerification(any(), any(), any()) }
            assertEquals(1, saved)
            job.cancel()
        }
    }

    @Test
    fun `RL2-PROBESTATE-11 sync changed an unedited verification field before tap and the user edited only a non-connection field`() = runTest(dispatcher) {
        val baseline = relay(
            requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None),
        )
        // After the page is opened the auth scheme is synchronously changed to Bearer; the user changed only the service tier (a non-connection field).
        val live = baseline.copy(relayRequested = baseline.relayRequested!!.copy(authMode = RelayAuthMode.Bearer))
        val draft = RelayEditDraft.from(baseline, null).let { it.copy(requested = it.requested.copy(serviceTier = "flex")) }

        val board = RelayEditBoardModel.make(
            provider = live,
            draft = draft,
            status = null,
            isSaving = false,
            issues = emptyList(),
            baseline = baseline,
        )
        assertEquals("button and save use the same rule: only connection fields the user changed and that differ from live count", R.string.save, board.actionBar.primaryTitleRes)
        assertFalse(board.actionBar.primaryValidates)

        val candidate = slot<Provider>()
        coEvery { providerRepository.persistRelayEditWithoutVerification(capture(candidate), any(), any()) } coAnswers {
            ProviderRepository.RelayEditOutcome(provider = firstArg(), persisted = true, verificationSucceeded = false)
        }
        val vm = viewModel(live)
        val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
        advanceUntilIdle()
        vm.beginRelayEdit(baseline)
        var saved = 0
        vm.saveRelaySettings(live, draft.cleanedRequested(), "https://relay.example.com/v1") { saved += 1 }
        advanceUntilIdle()

        coVerify(exactly = 0) { providerRepository.verifyAndPersistRelayEdit(any(), any(), any(), any(), any()) }
        assertEquals("flex", candidate.captured.relayRequested?.serviceTier)
        assertEquals(1, saved)
        job.cancel()
    }

    @Test
    fun `RL2-PROBESTATE-10 catalog refresh after save follows the repository's commit-time decision`() = runTest(dispatcher) {
        val provider = relay(
            requested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, authMode = RelayAuthMode.None),
        )
        val revision = ProviderRepository.RelayEditRevision(with(ProviderMapper) { provider.toEntity("account-test") })
        coEvery { providerRepository.refreshRelayCatalogOnly(any(), any()) } returns
            ProviderRepository.ProviderResyncOutcome(provider, catalogSucceeded = true)
        listOf(
            // The address changed at Save time, but at persist time the live record already has the same address: the catalog is not refreshed.
            ProviderRepository.RelayEditOutcome(provider, persisted = true, verificationSucceeded = true, persistedRevision = revision, catalogInvalidated = false) to 0,
            // Second collision: no verification state is written, but the connection changed at persist time, so the catalog is refreshed anyway.
            ProviderRepository.RelayEditOutcome(provider, persisted = true, verificationSucceeded = false, persistedRevision = revision, catalogInvalidated = true) to 1,
        ).forEach { (outcome, refreshes) ->
            io.mockk.clearMocks(providerRepository, answers = false, recordedCalls = true, childMocks = false, verificationMarks = true, exclusionRules = false)
            coEvery { providerRepository.verifyAndPersistRelayEdit(any(), any(), any(), any(), any()) } returns outcome
            val vm = viewModel(provider)
            val job = backgroundScope.launch(dispatcher) { vm.provider.collect {} }
            advanceUntilIdle()

            vm.saveRelaySettings(provider, provider.relayRequested!!, "https://other.example.com/v1")
            advanceUntilIdle()

            coVerify(exactly = refreshes) { providerRepository.refreshRelayCatalogOnly(any(), any()) }
            job.cancel()
        }
    }

    // ── helpers ──

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

    private fun resRoot(): String = "src/main/res"

    private fun stringsIn(file: File): Map<String, String> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val out = mutableMapOf<String, String>()
        val strings = doc.getElementsByTagName("string")
        for (i in 0 until strings.length) {
            val e = strings.item(i) as Element
            out[e.getAttribute("name")] = e.textContent
        }
        val plurals = doc.getElementsByTagName("plurals")
        for (i in 0 until plurals.length) {
            val e = plurals.item(i) as Element
            out["plurals:" + e.getAttribute("name")] = e.textContent
        }
        return out
    }

    private fun repoFileOrNull(relative: String): File? {
        val direct = File("src/main/java/ai/oriveo/community/$relative")
        return direct.takeIf { it.exists() }
    }

    private fun repoFile(relative: String): File = repoFileOrNull(relative) ?: error("cannot find $relative")

    /** Request header / query parameter values are saved as is (a space may be part of the value); keys are still trimmed and empty keys dropped. */
    @Test
    fun `cleanRelayAdvancedPairs does not trim values, trims keys, drops empty keys`() {
        val cleaned = listOf(
            RelayKeyValue(" X-Token ", "  Bearer abc  "),
            RelayKeyValue("   ", "orphan"),
            RelayKeyValue("q", " "),
        ).cleanRelayAdvancedPairs()
        assertEquals(listOf(RelayKeyValue("X-Token", "  Bearer abc  "), RelayKeyValue("q", " ")), cleaned)
        assertEquals(null, listOf(RelayKeyValue(" ", "v")).cleanRelayAdvancedPairs())
    }
}
