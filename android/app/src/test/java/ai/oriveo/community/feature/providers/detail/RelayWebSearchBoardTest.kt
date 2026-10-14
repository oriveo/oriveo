package ai.oriveo.community.feature.providers.detail

import androidx.compose.ui.unit.LayoutDirection
import androidx.lifecycle.SavedStateHandle
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.data.remote.MetadataRefreshEventBus
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.RelayWebFragmentStore
import ai.oriveo.community.core.provider.relay.RelayWebFragments
import ai.oriveo.community.core.provider.relay.RelayCapabilityTestReason
import ai.oriveo.community.core.provider.relay.RelayWebProbe
import ai.oriveo.community.core.provider.relay.RelayWebProbeOutcome
import ai.oriveo.community.core.provider.relay.RelayWebProbeRecord
import ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore
import ai.oriveo.community.core.provider.relay.RelayWebProbeResult
import ai.oriveo.community.core.provider.relay.RelayWebProbeSource
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Board model of the web search settings page (aligned with the iOS final cases). */
@OptIn(ExperimentalCoroutinesApi::class)
class RelayWebSearchBoardTest {
    private val dispatcher = StandardTestDispatcher()
    private val chat = RelayTransport.OpenAIChatCompletions
    private val responses = RelayTransport.OpenAIResponses
    private val messages = RelayTransport.AnthropicMessages
    private val gemini = RelayTransport.GeminiGenerateContent

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun relay(requested: RelayRequestedConfig) = Provider(
        id = "provider-1",
        kind = ProviderKind.Relay,
        customName = "My Relay",
        baseUrlText = "https://relay.test/v1",
        relayRequested = requested,
    )

    /** A connection (auto) whose detail page "Base paths" lists only Responses. */
    private val responsesOnly = relay(
        RelayRequestedConfig(transport = RelayTransport.Auto, resolvedAPIBaseURLs = mapOf(responses.value to "https://relay.test/v1")),
    )

    private fun empty() = RelayWebSearchBoardModel.emptyTexts()

    private fun board(
        provider: Provider,
        texts: Map<RelayTransport, String>,
        baseline: Map<RelayTransport, String> = empty(),
        otherExpanded: Boolean = false,
    ) = RelayWebSearchBoardModel.build(provider, baseline, texts, otherExpanded)

    private fun template(transport: RelayTransport) = RelayWebSearchPageModel.templateText(transport)

    @Test
    fun `use template inserts the compact single line json`() {
        val expected = mapOf(
            RelayTransport.OpenAIResponses to """{"tools":[{"type":"web_search"}]}""",
            RelayTransport.OpenAIChatCompletions to """{"web_search_options":{}}""",
            RelayTransport.AnthropicMessages to """{"tools":[{"type":"web_search_20250305","name":"web_search","max_uses":5}]}""",
            RelayTransport.GeminiGenerateContent to """{"tools":[{"googleSearch":{}}]}""",
        )
        for ((transport, text) in expected) {
            assertEquals(transport.value, text, RelayWebSearchPageModel.templateText(transport))
            // This is exactly what the production "Use template" action fills into the input.
            assertEquals(RelayWebSearchBoardModel.TemplateAction.Fill(text), RelayWebSearchBoardModel.templateAction(transport, ""))
            assertFalse("single line", '\n' in RelayWebSearchPageModel.templateText(transport))
        }
    }

    @Test
    fun `header shows back, Web Search and the connection name as subtitle, with intro, footer and a bottom Save that is disabled without changes or with a wrong section`() {
        val base = board(responsesOnly, empty())
        assertEquals(R.string.web_search, base.titleRes)
        assertEquals("My Relay", base.subtitle)
        assertEquals(R.string.relay_web_page_intro, base.introRes)
        assertEquals(R.string.relay_model_advanced_local_only, base.footerRes)
        assertEquals(R.string.save, base.saveRes)
        assertFalse("not tappable without changes", base.canSave)

        val edited = empty() + (responses to template(responses))
        assertTrue(board(responsesOnly, edited).hasChanges)
        assertTrue(board(responsesOnly, edited).canSave)

        val wrong = empty() + (responses to "{")
        assertTrue(board(responsesOnly, wrong).hasChanges)
        assertFalse("not tappable with a wrong section", board(responsesOnly, wrong).canSave)

        // Reverting to the original means no changes.
        val reverted = board(responsesOnly, empty())
        assertFalse(reverted.hasChanges)
        assertFalse(reverted.canSave)
    }

    @Test
    fun `section order is fixed, the expanded group is the Base paths protocols plus the selected protocol, the rest go to Other protocols, and auto with no base path expands all four`() {
        // Only a Responses base path (auto): the primary group is Responses and the other three sections go into the collapsed group in fixed order.
        val split = board(responsesOnly, empty())
        assertEquals(listOf(responses), split.primary.map { it.transport })
        assertEquals(R.string.relay_web_other_protocols, split.other?.titleRes)
        assertEquals(listOf(chat, messages, gemini), split.other?.sections?.map { it.transport })

        // Messages selected on the connection plus a Chat base path: the primary group is the union of both, still in fixed order.
        val explicit = relay(
            RelayRequestedConfig(transport = messages, resolvedAPIBaseURLs = mapOf(chat.value to "https://relay.test/v1")),
        )
        val explicitBoard = board(explicit, empty())
        assertEquals(listOf(chat, messages), explicitBoard.primary.map { it.transport })
        assertEquals(listOf(responses, gemini), explicitBoard.other?.sections?.map { it.transport })

        // Protocol selected but no base path yet: the primary group contains at least the selected protocol.
        val selectedOnly = board(relay(RelayRequestedConfig(transport = gemini)), empty())
        assertEquals(listOf(gemini), selectedOnly.primary.map { it.transport })

        // Auto with no base path: all four sections expanded and no collapsed group.
        val bare = board(relay(RelayRequestedConfig(transport = RelayTransport.Auto)), empty())
        assertEquals(listOf(chat, responses, messages, gemini), bare.primary.map { it.transport })
        assertNull(bare.other)

        // A section title is the protocol name; only the Chat section carries the "no generic web search field" note.
        assertEquals(
            listOf(
                R.string.relay_transport_openai_chat_completions,
                R.string.relay_transport_openai_responses,
                R.string.relay_transport_anthropic_messages,
                R.string.relay_transport_gemini_generate_content,
            ),
            bare.primary.map { it.titleRes },
        )
        assertEquals(listOf(R.string.relay_web_chat_note, null, null, null), bare.primary.map { it.noteRes })
    }

    @Test
    fun `the collapsed group starts collapsed, shows a count, treats whitespace as unset, force-expands on a wrong section, remembers header taps, does not collapse right after a fix, and the primary group cannot collapse`() {
        val collapsed = board(responsesOnly, empty())
        assertEquals(false, collapsed.other?.expanded)
        assertEquals(0, collapsed.other?.setCount)

        val counted = empty() + mapOf(chat to "   \n", messages to template(messages), gemini to template(gemini))
        assertEquals("whitespace only means unset", 2, board(responsesOnly, counted).other?.setCount)
        assertEquals(false, board(responsesOnly, counted).other?.expanded)

        // The user expands, then enters something wrong: force-expanded; a header tap during that time still records expanded.
        var expanded = RelayWebSearchBoardModel.tappingOtherHeader(false, responsesOnly, empty())
        assertTrue(expanded)
        val wrong = empty() + (messages to "{")
        expanded = RelayWebSearchBoardModel.otherExpandedAfterEdit(expanded, responsesOnly, wrong)
        assertEquals(true, board(responsesOnly, wrong, otherExpanded = false).other?.expanded)
        expanded = RelayWebSearchBoardModel.tappingOtherHeader(expanded, responsesOnly, wrong)
        assertTrue("a header tap while a section is wrong records expanded", expanded)

        // After the fix it does not collapse in front of the user; only a later header tap collapses it.
        val fixed = empty() + (messages to template(messages))
        expanded = RelayWebSearchBoardModel.otherExpandedAfterEdit(expanded, responsesOnly, fixed)
        assertEquals(true, board(responsesOnly, fixed, otherExpanded = expanded).other?.expanded)
        expanded = RelayWebSearchBoardModel.tappingOtherHeader(expanded, responsesOnly, fixed)
        assertEquals(false, board(responsesOnly, fixed, otherExpanded = expanded).other?.expanded)

        // An error inside the group also forces it open while collapsed (Save is greyed out, so the error must not be hidden).
        assertEquals(true, board(responsesOnly, wrong, otherExpanded = false).other?.expanded)
        // The primary group has no collapsed state.
        assertFalse(board(responsesOnly, empty()).primaryCollapsible)
    }

    @Test
    fun `use template fills directly when empty, whitespace only or already the template, and confirms first when other content is there, per protocol`() {
        for (transport in RelayWebFragments.TRANSPORTS) {
            val filled = RelayWebSearchBoardModel.TemplateAction.Fill(template(transport))
            assertEquals(filled, RelayWebSearchBoardModel.templateAction(transport, ""))
            assertEquals(filled, RelayWebSearchBoardModel.templateAction(transport, "  \n "))
            assertEquals(filled, RelayWebSearchBoardModel.templateAction(transport, template(transport)))
            // A template that only differs in whitespace layout still counts as the template.
            assertEquals(filled, RelayWebSearchBoardModel.templateAction(transport, template(transport).replace("\n", "")))
            assertEquals(
                RelayWebSearchBoardModel.TemplateAction.Confirm,
                RelayWebSearchBoardModel.templateAction(transport, """{"x":1}"""),
            )
        }
        // Another protocol's template counts as "other content" for this section.
        assertEquals(
            RelayWebSearchBoardModel.TemplateAction.Confirm,
            RelayWebSearchBoardModel.templateAction(messages, template(responses)),
        )
        val confirm = RelayWebSearchBoardModel.replaceConfirm
        assertEquals(R.string.additional_body_paste_replace_title, confirm.titleRes)
        assertEquals(R.string.relay_web_template_replace_body, confirm.bodyRes)
        assertEquals(R.string.replace, confirm.confirmRes)
        assertEquals(R.string.cancel, confirm.cancelRes)
    }

    @Test
    fun `back with changes shows the unsaved prompt, back without changes returns directly, edits inside the collapsed group count, whitespace-only typing does not, and the legacy field mapping does not`() {
        val prompt = RelayWebSearchBoardModel.discardPrompt
        assertEquals(R.string.relay_discard_changes_title, prompt.titleRes)
        assertEquals(R.string.relay_edit_unsaved_body, prompt.bodyRes)
        assertEquals(R.string.relay_discard_changes_keep, prompt.keepRes)
        assertEquals(R.string.relay_discard_changes_confirm, prompt.discardRes)

        assertEquals(RelayWebSearchBoardModel.BackAction.Pop, RelayWebSearchBoardModel.backAction(board(responsesOnly, empty())))

        // An edit inside the collapsed group (Gemini is not in the primary group) also counts as a change.
        val hidden = board(responsesOnly, empty() + (gemini to template(gemini)))
        assertEquals(false, hidden.other?.expanded)
        assertEquals(RelayWebSearchBoardModel.BackAction.ConfirmDiscard, RelayWebSearchBoardModel.backAction(hidden))

        // Whitespace-only typing does not count: neither whitespace in an empty section nor extra whitespace in existing content.
        val baseline = empty() + (responses to template(responses))
        val spaced = baseline + mapOf(chat to "  \n", responses to template(responses).replace("\n", "\n\n  "))
        assertFalse(board(responsesOnly, spaced, baseline).hasChanges)
        assertEquals(RelayWebSearchBoardModel.BackAction.Pop, RelayWebSearchBoardModel.backAction(board(responsesOnly, spaced, baseline)))

        // Content mapped from the legacy hasWebSearch field is what the page started with, so it is not a change.
        val legacy = relay(
            RelayRequestedConfig(
                transport = responses,
                resolvedAPIBaseURLs = mapOf(responses.value to "https://relay.test/v1"),
                hasWebSearch = true,
                webSearchProfile = "oai_responses_web",
            ),
        )
        val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        // Baseline: built from the legacy fields through the production mapping (the store is empty).
        val legacyBaseline = RelayWebSearchPageModel.initialTexts(legacy, store)
        assertTrue(legacyBaseline.getValue(responses).contains("web_search"))
        // Draft: the same content built independently (the baseline is compact; re-encoding by value gives an indented layout, so it is a different object and different text).
        val pretty = kotlinx.serialization.json.Json { prettyPrint = true }
        val draft = legacyBaseline.mapValues { (_, text) ->
            if (text.isBlank()) "" else pretty.encodeToString(
                kotlinx.serialization.json.JsonElement.serializer(),
                pretty.parseToJsonElement(text),
            )
        }
        assertTrue(draft !== legacyBaseline)
        assertTrue(draft.getValue(responses) != legacyBaseline.getValue(responses))
        assertFalse(board(legacy, draft, legacyBaseline).hasChanges)
        assertEquals(RelayWebSearchBoardModel.BackAction.Pop, RelayWebSearchBoardModel.backAction(board(legacy, draft, legacyBaseline)))
        // Contrast: only a draft that really changes a section counts as a change.
        assertTrue(board(legacy, draft + (messages to template(messages)), legacyBaseline).hasChanges)
    }

    @Test
    fun `in-page header plus bottom action bar with a single primary button`() {
        val board = board(responsesOnly, empty())
        assertTrue(board.showsInPageHeader)
        assertEquals(listOf(R.string.save), board.actionBarButtons)
    }

    @Test
    fun `re-entering after saving shows no changes, and content in another group only shows a count without auto-expanding`() = runTest(dispatcher) {
        val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        val provider = responsesOnly
        val viewModel = viewModel(provider)
        val texts = RelayWebSearchPageModel.initialTexts(provider, store) + (gemini to template(gemini))
        assertTrue(viewModel.saveRelayWebSearch(provider, texts, store))
        advanceUntilIdle()

        val reentered = RelayWebSearchPageModel.initialTexts(provider, store)
        val again = board(provider, reentered, reentered)
        assertFalse(again.hasChanges)
        assertEquals(false, again.other?.expanded)
        assertEquals(1, again.other?.setCount)
    }

    @Test
    fun `a draft generated from a stored fragment is compact single line JSON identical to the template`() {
        val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        val provider = responsesOnly
        store.replace(
            provider.id,
            mapOf(chat to RelayWebFragments.template(chat)!!, messages to RelayWebFragments.template(messages)!!),
        )
        val texts = RelayWebSearchPageModel.initialTexts(provider, store)
        assertEquals("""{"web_search_options":{}}""", texts.getValue(chat))
        assertEquals(template(messages), texts.getValue(messages))
        assertFalse("single line", '\n' in texts.getValue(messages))
        assertEquals("", texts.getValue(gemini))
    }

    @Test
    fun `save writes nothing when a section is wrong, otherwise writes the fragments, clears the legacy fields and persists once, reads back what was stored, and becomes the new baseline`() = runTest(dispatcher) {
        val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        val provider = relay(
            RelayRequestedConfig(transport = responses, hasWebSearch = true, webSearchProfile = "oai_responses_web"),
        )
        val repository = mockk<ProviderRepository>(relaxed = true)
        every { repository.observeById("provider-1") } returns MutableStateFlow(provider)
        val saved = slot<Provider>()
        coEvery { repository.updateProvider(capture(saved)) } returns Unit
        val viewModel = viewModel(provider, repository)
        val baseline = RelayWebSearchPageModel.initialTexts(provider, store)

        // With a wrong section: nothing is written to the store or persisted.
        assertFalse(viewModel.saveRelayWebSearch(provider, baseline + (chat to """{"model":"x"}"""), store))
        advanceUntilIdle()
        assertTrue(store.stored("provider-1").isEmpty())
        coVerify(exactly = 0) { repository.updateProvider(any()) }

        // Clear the sections mapped from the legacy fields (Responses / Gemini) and fill Messages with the template: the store keeps only Messages; the connection drops the legacy web search fields, the protocol is unchanged, and it is persisted once.
        val edited = baseline + mapOf(responses to "", gemini to "", messages to template(messages))
        assertTrue(viewModel.saveRelayWebSearch(provider, edited, store))
        advanceUntilIdle()
        assertEquals(setOf(messages.value), store.stored("provider-1").keys)
        coVerify(exactly = 1) { repository.updateProvider(any()) }
        val requested = saved.captured.relayRequested!!
        assertFalse(requested.hasWebSearch)
        assertNull(requested.webSearchProfile)
        assertEquals(responses, requested.transport)

        // Read back equals what was stored; it becomes the new baseline (re-entering shows no changes).
        val readBack = RelayWebSearchPageModel.initialTexts(saved.captured, store)
        // Insertion is compact single line, while a stored section is still shown indented on re-entry, so compare by JSON content.
        assertEquals(
            kotlinx.serialization.json.Json.parseToJsonElement(template(messages)),
            kotlinx.serialization.json.Json.parseToJsonElement(readBack.getValue(messages)),
        )
        assertEquals("", readBack.getValue(responses))
        assertFalse(board(saved.captured, edited, readBack).hasChanges)
    }

    @Test
    fun `the JSON editor is forced to LTR`() {
        assertEquals(LayoutDirection.Ltr, board(responsesOnly, empty()).editorLayoutDirection)
    }

    @Test
    fun `RL2-WEBPROBE-12 RETEST rejected group lists enabled rejected models in order, retests by manual probe one at a time, and clears after searched or silent`() =
        runTest(dispatcher) {
            // The disclosure row sits above the Save button.
            assertEquals(R.string.relay_web_search_probe_disclosure, board(responsesOnly, empty()).disclosureRes)

            val fragments = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
            val records = RelayWebProbeRecordStore(RelayWebProbeRecordStore.MemoryStore()) { 5_000L }
            val chatFragment = RelayWebFragments.template(chat)!!
            fun model(id: String, transport: RelayTransport = chat) = AIModel(id = id, name = "Name $id", relayTransport = transport)
            val provider = relay(
                RelayRequestedConfig(transport = chat, resolvedAPIBaseURLs = mapOf(chat.value to "https://relay.test/v1")),
            ).copy(
                // Enabled order: m-b comes before m-a; m-x is only in the catalog (not enabled); m-e is sent over Responses first (no stored fragment).
                models = listOf(model("m-b"), model("m-a"), model("m-c"), model("m-d"), model("m-e", responses)),
                catalogModels = listOf(model("m-x")),
            )
            fragments.replace(provider.id, mapOf(chat to chatFragment))
            val current = RelayWebProbe.fragmentHash(chatFragment)
            fun put(id: String, result: RelayWebProbeResult, transport: RelayTransport = chat, hash: String = current) {
                records.record(
                    RelayWebProbeRecordStore.Key(provider.id, id, transport.value),
                    RelayWebProbeRecord(result, RelayWebProbeSource.Tested, 1L, hash),
                )
            }
            put("m-b", RelayWebProbeResult.Rejected)
            put("m-a", RelayWebProbeResult.Searched)
            put("m-c", RelayWebProbeResult.Rejected)
            put("m-d", RelayWebProbeResult.Rejected, hash = "stale")
            put("m-x", RelayWebProbeResult.Rejected)
            put("m-e", RelayWebProbeResult.Rejected, transport = responses, hash = RelayWebProbe.fragmentHash(RelayWebFragments.template(responses)!!))

            val listed = RelayWebSearchBoardModel.rejectedModels(provider, fragments, records)
            assertEquals(listOf("m-b", "m-c"), listed.map { it.id })
            // The draft does not count: only stored fragments matter. Editing the Chat section in the draft leaves the rejected group unchanged.
            val withRows = RelayWebSearchBoardModel.build(
                provider, empty(), empty() + (chat to "{}"), otherExpanded = false, rejected = listed, retestingModelID = "m-c",
            )
            val group = withRows.rejected!!
            assertEquals(R.string.relay_web_search_rejected_title, group.titleRes)
            assertEquals(R.string.relay_web_search_retest, group.retestRes)
            assertEquals(listOf("m-b" to "Name m-b", "m-c" to "Name m-c"), group.rows.map { it.modelId to it.name })
            assertEquals("the running row swaps to a spinner", listOf(false, true), group.rows.map { it.running })
            assertEquals("only one runs at a time: other rows are not tappable while it runs", listOf(false, false), group.rows.map { it.retestEnabled })
            assertTrue(RelayWebSearchBoardModel.build(provider, empty(), empty(), false, listed, null).rejected!!.rows.all { it.retestEnabled })
            assertNull("no rejected group without rejected models", board(provider, empty()).rejected)

            // A retest is the production manual probe (repository.runRelayWebProbe), not the automatic trigger (it does not enter the automatic history).
            val repository = mockk<ProviderRepository>(relaxed = true)
            every { repository.observeById("provider-1") } returns MutableStateFlow(provider)
            val gate = CompletableDeferred<Unit>()
            coEvery { repository.runRelayWebProbe("provider-1", "m-b", any()) } coAnswers {
                gate.await()
                put("m-b", RelayWebProbeResult.Searched)
                RelayWebProbeOutcome.Completed(RelayWebProbeResult.Searched, RelayCapabilityTestReason.Ok, 200, emptyList(), current, 5_000L)
            }
            coEvery { repository.runRelayWebProbe("provider-1", "m-c", any()) } coAnswers {
                put("m-c", RelayWebProbeResult.Silent)
                RelayWebProbeOutcome.Completed(RelayWebProbeResult.Silent, RelayCapabilityTestReason.Ok, 200, emptyList(), current, 5_000L)
            }
            val viewModel = viewModel(provider, repository)
            val revision = viewModel.relayWebProbeRevision
            assertTrue(viewModel.retestRelayWebModel("m-b"))
            advanceUntilIdle()
            assertEquals("m-b", viewModel.relayWebRetestingModelID)
            assertFalse("a second one is not accepted while one runs", viewModel.retestRelayWebModel("m-c"))
            gate.complete(Unit)
            advanceUntilIdle()
            assertNull(viewModel.relayWebRetestingModelID)
            assertTrue("the rejected group refreshes when it finishes", viewModel.relayWebProbeRevision > revision)
            coVerify(exactly = 1) { repository.runRelayWebProbe("provider-1", "m-b", any()) }
            coVerify(exactly = 0) { repository.runRelayWebProbe("provider-1", "m-c", any()) }
            coVerify(exactly = 0) { repository.relayWebFragmentsSaved(any(), any()) }
            assertEquals("the row disappears after searched", listOf("m-c"), RelayWebSearchBoardModel.rejectedModels(provider, fragments, records).map { it.id })

            assertTrue(viewModel.retestRelayWebModel("m-c"))
            advanceUntilIdle()
            assertTrue("the row disappears after silent", RelayWebSearchBoardModel.rejectedModels(provider, fragments, records).isEmpty())
        }

    private fun viewModel(
        provider: Provider,
        repository: ProviderRepository = mockk<ProviderRepository>(relaxed = true).also {
            every { it.observeById("provider-1") } returns MutableStateFlow(provider)
        },
    ) = ProviderDetailViewModel(
        savedStateHandle = SavedStateHandle(mapOf("providerID" to "provider-1")),
        providerRepository = repository,
        appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true),
        metadataRefreshEventBus = MetadataRefreshEventBus(debounceMillis = 0),
        applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
        globalSnackbarManager = mockk<GlobalSnackbarManager>(relaxed = true),
        defaultDispatcher = dispatcher,
    )
}
