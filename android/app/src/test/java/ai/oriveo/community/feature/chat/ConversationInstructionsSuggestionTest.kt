package ai.oriveo.community.feature.chat

import android.content.SharedPreferences
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.context.DirectiveDetection
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.memory.MemoryCandidateRepository
import ai.oriveo.community.core.memory.MemoryItemRepository
import ai.oriveo.community.core.context.MemoryCandidateStatus
import ai.oriveo.community.core.data.database.OriveoDatabase
import androidx.room.Room
import kotlinx.coroutines.Dispatchers
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.notice.DirectiveSuggestionStore
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The "Set as instruction" suggestion bar: detection, accept / undo, and ignore counting. */
@RunWith(RobolectricTestRunner::class)
@OptIn(ExperimentalCoroutinesApi::class)
class ConversationInstructionsSuggestionTest {
    // The lexical path only raises the bar for languages in suggestionLanguages, so the sample sentence uses a gated language (zh-Hans).
    private val directive = "\u4ee5\u540e\u90fd\u7528\u82f1\u6587\u56de\u7b54\u3002 "
    private val span = "\u4ee5\u540e\u90fd\u7528\u82f1\u6587\u56de\u7b54\u3002"

    private val instructions = mutableMapOf<String, String>()
    private val writes = mutableListOf<Pair<String, String>>()
    private val toasts = mutableListOf<GlobalSnackbarMessage>()
    private val prefsMap = mutableMapOf<String, Int>()
    private val store = DirectiveSuggestionStore(prefsProvider = { fakePrefs(prefsMap) })

    private fun TestScope.controller(scope: CoroutineScope = this) = DirectiveSuggestionController(
        scope = scope,
        store = store,
        instructionsOf = { instructions[it] },
        writeInstructions = { id, text ->
            writes += id to text
            instructions[id] = text
        },
        showToast = { toasts += it },
        ioContext = EmptyCoroutineContext,
    )

    @Test
    fun suggestion_shown_for_directive_message() = runTest {
        instructions["conversation-1"] = ""
        val controller = controller()
        val provider = provider()
        val providerRepository = mockk<ProviderRepository>()
        val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
        val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        coEvery { providerRepository.getById(provider.id) } returns provider
        // The real propose_memory mode decision reads the connection's tool-call verdict.
        io.mockk.every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
        coEvery { providerRepository.capabilityEvidenceIdentity(any(), any<String>()) } returns null
        coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
        coEvery { conversationRepository.getWithMessages("conversation-1") } returns conversation("conversation-1")
        var attemptKind = ContextConfirmAttempt.SEND
        var plainLaunches = 0
        var userLaunches = 0
        val coordinator = ChatSendCommandCoordinator(
            viewModelScope = this,
            appPreferencesRepository = appPreferencesRepository,
            providerRepository = providerRepository,
            conversationRepository = conversationRepository,
            currentConversation = { conversation("conversation-1") },
            currentConversationId = { "conversation-1" },
            onProviderSelectionError = {},
            onProviderResolutionError = {},
            onModelSelectionError = {},
            onDisclosureRequired = { _, _ -> },
            onConversationActivated = {},
            onComposerConsumed = {},
            requestPin = {},
            onSendSettled = {},
            launchSend = ChatSendLauncher { _, _, _, _, _, _, _, _, _, _, _ -> plainLaunches++ },
            attemptKind = { attemptKind },
            directiveSuggestions = controller,
            launchUserSend = ChatUserSendLauncher { _, _, _, text, _, _, _, _, onUserMessageCreated, _ ->
                userLaunches++
                onUserMessageCreated("message-${userLaunches}", text)
            },
        )

        coordinator.sendMessage(directive, null, provider.id, "m-1")
        advanceUntilIdle()

        assertEquals(1, userLaunches)
        assertEquals(
            DirectiveSuggestion(conversationId = "conversation-1", messageId = "message-1", sentence = span),
            controller.pending.value["conversation-1"],
        )

        // An edit-resend does not use the fresh-send entry and is not evaluated; the next user message clears the pending bar without counting an ignore.
        attemptKind = ContextConfirmAttempt.EDIT
        coordinator.sendMessage(directive, null, provider.id, "m-1")
        advanceUntilIdle()
        assertEquals(1, plainLaunches)
        assertEquals(1, userLaunches)

        controller.onUserMessageCreated("conversation-1", "message-9", "What time is it?")
        advanceUntilIdle()
        assertNull(controller.pending.value["conversation-1"])
        assertEquals(0, store.ignoreCount("conversation-1"))

        // Switching conversations clears the pending bar.
        controller.onUserMessageCreated("conversation-1", "message-10", directive)
        advanceUntilIdle()
        assertNotNull(controller.pending.value["conversation-1"])
        controller.retainOnly("conversation-2")
        assertNull(controller.pending.value["conversation-1"])
    }

    /** After a new user send a memory candidate is generated, but not on edit-resend; nothing is persisted when memory is off for the conversation. */
    @Test
    fun memory_candidate_generated_on_fresh_send() = runTest {
        val context = RuntimeEnvironment.getApplication()
        val db = Room.inMemoryDatabaseBuilder(context, OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .setQueryExecutor { it.run() }
            .setTransactionExecutor { it.run() }
            .build()
        try {
            val preferences = AppPreferencesRepository(
                preferenceDao = db.preferenceDao(),
            )
            val items = MemoryItemRepository(dao = db.memoryItemDao(), preferenceDao = db.preferenceDao(), preferences = preferences)
            val memoryCandidates = MemoryCandidateRepository(
                dao = db.memoryCandidateDao(),
                items = items,
                io = Dispatchers.Unconfined,
            )
            val text = "\u8bb0\u4f4f\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54"
            val provider = provider()
            val providerRepository = mockk<ProviderRepository>()
            val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
            val conversationRepository = mockk<ConversationRepository>(relaxed = true)
            var conv = conversation("conversation-1").copy(folderID = "folder-1", useMemory = false)
            coEvery { providerRepository.getById(provider.id) } returns provider
            // The real propose_memory mode decision reads the connection's tool-call verdict.
            io.mockk.every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
            coEvery { providerRepository.capabilityEvidenceIdentity(any(), any<String>()) } returns null
            coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
            coEvery { conversationRepository.getWithMessages("conversation-1") } answers { conv }
            var attemptKind = ContextConfirmAttempt.SEND
            var userLaunches = 0
            val coordinator = ChatSendCommandCoordinator(
                viewModelScope = this,
                appPreferencesRepository = appPreferencesRepository,
                providerRepository = providerRepository,
                conversationRepository = conversationRepository,
                currentConversation = { conv },
                currentConversationId = { "conversation-1" },
                onProviderSelectionError = {},
                onProviderResolutionError = {},
                onModelSelectionError = {},
                onDisclosureRequired = { _, _ -> },
                onConversationActivated = {},
                onComposerConsumed = {},
                requestPin = {},
                onSendSettled = {},
                launchSend = ChatSendLauncher { _, _, _, _, _, _, _, _, _, _, _ -> },
                attemptKind = { attemptKind },
                directiveSuggestions = controller(),
                launchUserSend = ChatUserSendLauncher { _, _, _, sent, _, _, _, _, onUserMessageCreated, _ ->
                    userLaunches++
                    onUserMessageCreated("message-$userLaunches", sent)
                },
                memoryCandidates = memoryCandidates,
                memoryAccountId = { "account-1" },
                memoryScope = this,
            )

            // Memory is off for the conversation: the send proceeds as usual and the candidate table gets no row.
            coordinator.sendMessage(text, null, provider.id, "m-1")
            advanceUntilIdle()
            assertEquals(1, userLaunches)
            assertTrue(db.memoryCandidateDao().list("account-1").isEmpty())

            conv = conv.copy(useMemory = true)
            coordinator.sendMessage(text, null, provider.id, "m-1")
            advanceUntilIdle()
            val pending = memoryCandidates.pending("account-1")
            assertEquals(1, pending.size)
            assertEquals(MemoryCandidateStatus.PENDING, pending.single().status)
            assertEquals("\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54", pending.single().content)
            assertEquals("conversation-1", pending.single().source.conversationId)
            assertEquals(listOf("message-2"), pending.single().source.messageIds)

            // An edit-resend does not use the fresh-send entry, so nothing is generated.
            attemptKind = ContextConfirmAttempt.EDIT
            coordinator.sendMessage(text, null, provider.id, "m-1")
            advanceUntilIdle()
            assertEquals(2, userLaunches)
            assertEquals(pending, memoryCandidates.pending("account-1"))
        } finally {
            db.close()
        }
    }

    @Test
    fun suggestion_not_shown_after_three_ignores() = runTest {
        instructions["c"] = ""
        val controller = controller()
        repeat(3) { index ->
            controller.onUserMessageCreated("c", "m-$index", directive)
            advanceUntilIdle()
            assertNotNull(controller.pending.value["c"])
            controller.ignore("c")
            advanceUntilIdle()
            assertNull(controller.pending.value["c"])
        }
        assertEquals(3, prefsMap["directive_suggestion_ignores:c"])
        controller.onUserMessageCreated("c", "m-4", directive)
        advanceUntilIdle()
        assertNull(controller.pending.value["c"])
        // Counting is per conversation: other conversations are unaffected.
        instructions["other"] = ""
        controller.onUserMessageCreated("other", "m-5", directive)
        advanceUntilIdle()
        assertNotNull(controller.pending.value["other"])
    }

    @Test
    fun suggestion_accept_appends_and_undo_restores() = runTest {
        instructions["c"] = "Be brief"
        val controller = controller()
        controller.onUserMessageCreated("c", "m-1", directive)
        advanceUntilIdle()
        controller.accept("c")
        advanceUntilIdle()

        assertNull(controller.pending.value["c"])
        assertEquals(listOf("c" to "Be brief\n$span"), writes)
        val toast = toasts.single()
        assertEquals(UiText.Resource(R.string.directive_suggestion_added), toast.message)
        assertEquals(5000L, toast.durationMs)
        val action = toast.action!!
        assertEquals(UiText.Resource(R.string.undo), action.label)

        action.onClick()
        advanceUntilIdle()
        assertEquals("c" to "Be brief", writes.last())
        assertEquals("Be brief", instructions["c"])

        // Empty instructions: the appended text is the sentence itself.
        instructions["d"] = ""
        controller.onUserMessageCreated("d", "m-2", directive)
        advanceUntilIdle()
        controller.accept("d")
        advanceUntilIdle()
        assertEquals("d" to span, writes.last())
    }

    @Test
    fun suggestion_skipped_when_already_in_instructions() = runTest {
        val controller = controller()
        instructions["c"] = "Rules:\n$span\nBe brief"
        controller.onUserMessageCreated("c", "m-1", directive)
        advanceUntilIdle()
        assertNull(controller.pending.value["c"])

        // No bar when the result would exceed 8000 code points; exactly 8000 still shows.
        val spanLength = span.codePointCount(0, span.length)
        instructions["long"] = "x".repeat(8000 - spanLength)
        controller.onUserMessageCreated("long", "m-2", directive)
        advanceUntilIdle()
        assertNull(controller.pending.value["long"])
        instructions["fits"] = "x".repeat(8000 - spanLength - 1)
        controller.onUserMessageCreated("fits", "m-3", directive)
        advanceUntilIdle()
        assertNotNull(controller.pending.value["fits"])

        // A non-persistent request shows no bar.
        instructions["plain"] = ""
        controller.onUserMessageCreated("plain", "m-4", "Can you reply in English?")
        advanceUntilIdle()
        assertNull(controller.pending.value["plain"])
        assertTrue(writes.isEmpty())
    }

    @Test
    fun suggestion_accept_resets_ignore_streak() = runTest {
        instructions["c"] = ""
        val controller = controller()
        repeat(2) { index ->
            controller.onUserMessageCreated("c", "m-$index", directive)
            advanceUntilIdle()
            controller.ignore("c")
            advanceUntilIdle()
        }
        assertEquals(2, store.ignoreCount("c"))
        controller.onUserMessageCreated("c", "m-2", directive)
        advanceUntilIdle()
        controller.accept("c")
        advanceUntilIdle()
        assertEquals(0, store.ignoreCount("c"))

        instructions["c"] = ""
        repeat(2) { index ->
            controller.onUserMessageCreated("c", "m-${index + 3}", directive)
            advanceUntilIdle()
            assertNotNull(controller.pending.value["c"])
            controller.ignore("c")
            advanceUntilIdle()
        }
        controller.onUserMessageCreated("c", "m-9", directive)
        advanceUntilIdle()
        assertNotNull(controller.pending.value["c"])
    }

    @Test
    fun suggestion_original_sentence_is_trimmed() = runTest {
        instructions["c"] = ""
        var span: String? = null
        val controller = DirectiveSuggestionController(
            scope = this,
            store = store,
            instructionsOf = { instructions[it] },
            writeInstructions = { id, text -> instructions[id] = text },
            showToast = {},
            ioContext = EmptyCoroutineContext,
            detect = { DirectiveDetection(isDirective = true, span = span, lang = "ja") },
            classify = { ai.oriveo.community.core.context.MemoryIntentSuggestion.CONVERSATION_INSTRUCTION },
        )
        suspend fun sentenceFor(text: String): String? {
            controller.onUserMessageCreated("c", "m-${text.hashCode()}", text)
            advanceUntilIdle()
            return controller.pending.value["c"]?.sentence
        }
        // Unicode White_Space at both ends of the span (including ideographic space / NBSP) is trimmed.
        span = "\u3000 Reply in English.\u00A0\n"
        assertEquals("Reply in English.", sentenceFor("whatever"))
        // A whitespace-only span counts as empty and falls back to the trimmed full text.
        span = " \u3000\t"
        assertEquals("Write in Arabic.", sentenceFor("\u3000Write in Arabic.\u2003"))
        span = null
        assertEquals("Be brief.", sentenceFor("\n Be brief.\u00A0"))
        // Both the span and the trimmed full text are empty: no bar.
        span = "\u3000"
        assertNull(sentenceFor(" \u3000 "))
    }

    /** The model calls propose_memory with scope=conversation; the host sends the sourceQuote to the "set as this conversation's instruction" bar and generates no memory candidate. */
    @Test
    fun instruct_from_conversation_scope_shows_instruction_bar() = runTest {
        val text = "\u4ee5\u540e\u56de\u7b54\u90fd\u5148\u7ed9\u7ed3\u8bba\uff0c\u518d\u5c55\u5f00\u7ec6\u8282"
        val outcome = proposeTurn(text, listOf(proposeArgs("\u56de\u7b54\u5148\u7ed9\u7ed3\u8bba\uff0c\u518d\u5c55\u5f00\u7ec6\u8282", "instruction", text)))
        assertEquals(
            DirectiveSuggestion(conversationId = "conversation-1", messageId = "message-1", sentence = text),
            outcome.pending,
        )
        assertTrue(outcome.candidates.isEmpty())
    }

    @Test
    fun instruct_with_non_instruction_kind_is_skipped() = runTest {
        val text = "\u8bb0\u4f4f\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54"
        val outcome = proposeTurn(text, listOf(proposeArgs("\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54", "preference", "\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54")))
        assertNull(outcome.pending)
        assertTrue(outcome.candidates.isEmpty())
    }

    @Test
    fun instruct_quote_not_in_user_message_is_skipped() = runTest {
        val outcome = proposeTurn("\u4ee5\u540e\u56de\u7b54\u90fd\u5148\u7ed9\u7ed3\u8bba", listOf(proposeArgs("\u56de\u7b54\u90fd\u7528\u82f1\u6587", "instruction", "\u4ee5\u540e\u56de\u7b54\u90fd\u7528\u82f1\u6587")))
        assertNull(outcome.pending)
        assertTrue(outcome.candidates.isEmpty())
    }

    @Test
    fun instruct_already_in_instructions_is_skipped() = runTest {
        instructions["conversation-1"] = "\u8bed\u6c14\u8f7b\u677e\u3002\n\u4ee5\u540e\u56de\u7b54\u90fd\u5148\u7ed9\u7ed3\u8bba\uff0c\u518d\u5c55\u5f00\u7ec6\u8282"
        val outcome = proposeTurn("\u4ee5\u540e\u56de\u7b54\u90fd\u5148\u7ed9\u7ed3\u8bba", listOf(proposeArgs("\u56de\u7b54\u90fd\u5148\u7ed9\u7ed3\u8bba", "instruction", "\u56de\u7b54\u90fd\u5148\u7ed9\u7ed3\u8bba")))
        assertNull(outcome.pending)
    }

    @Test
    fun instruct_second_in_turn_is_skipped() = runTest {
        val text = "From now on, reply in English. Also, never use emojis."
        val outcome = proposeTurn(
            text,
            listOf(
                proposeArgs("Reply in English.", "instruction", "From now on, reply in English."),
                proposeArgs("Never use emojis.", "instruction", "never use emojis."),
            ),
        )
        assertEquals("From now on, reply in English.", outcome.pending?.sentence)
        assertTrue(outcome.candidates.isEmpty())
    }

    /** Tool mode does not run the lexical path (no model call means no bar); after a tools-rejected downgrade resend the fallback runs the lexical path plus the language gate. */
    @Test
    fun tool_mode_does_not_run_lexical_suggestion() = runTest {
        val outcome = proposeTurn(directive, emptyList())
        assertNull(outcome.pending)
        outcome.hook.onToolsRejected()
        advanceUntilIdle()
        assertEquals(span, outcome.controller.pending.value["conversation-1"]?.sentence)
    }

    @Test
    fun fallback_lexical_suggestion_only_for_gated_languages() = runTest {
        instructions["c"] = ""
        val controller = controller()
        // English is outside suggestionLanguages: a detector hit still raises no bar.
        val english = "From now on, reply in English."
        assertEquals("en", ai.oriveo.community.core.context.DirectiveDetector.detect(english).lang)
        controller.onUserMessageCreated("c", "m-1", english)
        advanceUntilIdle()
        assertNull(controller.pending.value["c"])
        assertEquals("zh-Hans", ai.oriveo.community.core.context.DirectiveDetector.detect(directive).lang)
        controller.onUserMessageCreated("c", "m-2", directive)
        advanceUntilIdle()
        assertEquals(span, controller.pending.value["c"]?.sentence)
        val german = "Antworte ab jetzt immer auf Deutsch."
        assertEquals("de", ai.oriveo.community.core.context.DirectiveDetector.detect(german).lang)
    }

    /** Same rule through the real coordinator in tool mode when the exit did not attach tools (onToolsNotAttached): the lexical bar still only appears for gated languages. */
    @Test
    fun fallback_lexical_suggestion_only_for_gated_languages_via_coordinator_fallback() = runTest {
        ai.oriveo.community.core.memory.ProposeMemoryRuntime.clearForTest()
        val english = proposeTurn("From now on, reply in English.", emptyList())
        english.hook.onToolsNotAttached()
        advanceUntilIdle()
        assertNull("en is outside suggestionLanguages", english.controller.pending.value["conversation-1"])

        val chinese = proposeTurn(directive, emptyList())
        assertNull("tool mode shows no lexical bar up front", chinese.pending)
        chinese.hook.onToolsNotAttached()
        advanceUntilIdle()
        assertEquals(span, chinese.controller.pending.value["conversation-1"]?.sentence)
        assertTrue(
            "not attached does not degrade the connection",
            !ai.oriveo.community.core.memory.ProposeMemoryRuntime.isDegraded("relay-1", "m-1"),
        )
        // At most once per message: a later rejection callback only records the downgrade and does not rerun (a dismissed bar does not reappear).
        chinese.controller.ignore("conversation-1")
        advanceUntilIdle()
        chinese.hook.onToolsRejected()
        advanceUntilIdle()
        assertNull(chinese.controller.pending.value["conversation-1"])
        ai.oriveo.community.core.memory.ProposeMemoryRuntime.clearForTest()
    }

    /** MiniMax web through the Anthropic Messages route carries no client tools: propose falls back for this send. */
    @Test
    fun minimax_anthropic_web_route_falls_back_to_lexical_suggestion() = runTest {
        ai.oriveo.community.core.memory.ProposeMemoryRuntime.clearForTest()
        applyMiniMaxWebFixture()
        try {
            val minimax = miniMaxProvider()
            assertTrue(
                ai.oriveo.community.core.provider.MiniMaxService.routesWebThroughAnthropic(
                    minimax.models.first().id, true, ai.oriveo.community.core.model.ReasoningMode.Automatic,
                ),
            )
            val webOn = proposeTurn(directive, emptyList(), provider = minimax, webSearch = true)
            assertNull("fallback hands the send no propose hook", webOn.proposeHook)
            assertEquals(span, webOn.pending?.sentence)

            val webOff = proposeTurn(directive, emptyList(), provider = minimax, webSearch = false)
            assertNotNull("web off keeps tool mode", webOff.proposeHook)
            assertNull("tool mode shows no lexical bar up front", webOff.pending)
        } finally {
            ai.oriveo.community.core.provider.MetadataTestFixtures.clear()
            ai.oriveo.community.core.memory.ProposeMemoryRuntime.clearForTest()
        }
    }

    private fun miniMaxProvider(): Provider {
        val model = AIModel(
            id = "MiniMax-M3",
            name = "MiniMax-M3",
            isDefault = true,
            capabilities = listOf(ModelCapability.Text, ModelCapability.Web),
        )
        return Provider(
            id = "minimax-1",
            kind = ProviderKind.MiniMax,
            status = ProviderConnectionState.Connected,
            apiKey = "local-key",
            models = listOf(model),
            catalogModels = listOf(model),
        )
    }

    private fun applyMiniMaxWebFixture() {
        ai.oriveo.community.core.provider.MetadataTestFixtures.applyRaw(
            """
            {
              "version":1,
              "providers":{"miniMax":{"resolveMap":{"MiniMax-M3":"MiniMax-M3"},"models":{
                "MiniMax-M3":{"canonicalModelId":"MiniMax-M3","transport":"openai_chat","capabilities":["text","web"],"capabilityControls":{"web":{"state":"auto_available","recipeRef":"minimax.messages.web.v1"}}}
              }}},
              "capabilityRuntime":{"schemaVersion":2,"revision":"minimax-web-test","generatedAt":"2026-08-23T00:00:00Z","controlDefinitions":{},
                "sourceIndex":{"minimax.server_tools":{"kind":"official_doc","url":"https://platform.minimax.io/docs/guides/server-tools","reviewedAt":"2026-08-23"}},
                "recipes":{"minimax.messages.web.v1":{"id":"minimax.messages.web.v1","providerKind":"miniMax","transport":{"protocol":"openai_chat"},"capability":"web","executionKind":"endpoint_route","requestOps":[{"op":"append","pointer":"/tools/-","value":{"type":"web_search_20250305","name":"web_search"}}],"route":{"sourceProtocol":"openai_chat","protocol":"anthropic_messages","endpointClass":"messages","path":"/anthropic/v1/messages","method":"POST","authMode":"x_api_key","authHeader":"x-api-key","headers":{"Content-Type":"application/json","anthropic-version":"2023-06-01"},"requestMapper":"minimax_anthropic_messages_v1"},"responseParserKind":"minimax_anthropic_web_v1","continuationKind":"replay_blocks","fallbackPolicy":"remove_auto_patch_once_pre_token","sourceRefs":["minimax.server_tools"]}}
              }
            }
            """.trimIndent(),
        )
    }

    private class ProposeOutcome(
        val controller: DirectiveSuggestionController,
        val proposeHook: ai.oriveo.community.core.memory.MemoryProposeSendHook?,
        val pending: DirectiveSuggestion?,
        val candidates: List<ai.oriveo.community.core.data.entity.MemoryCandidateEntity>,
    ) {
        /** Tool mode only: the coordinator hands the send a propose hook. */
        val hook: ai.oriveo.community.core.memory.MemoryProposeSendHook get() = requireNotNull(proposeHook)
    }

    private fun proposeArgs(proposition: String, kind: String, quote: String): String =
        kotlinx.serialization.json.buildJsonObject {
            put("proposition", kotlinx.serialization.json.JsonPrimitive(proposition))
            put("kind", kotlinx.serialization.json.JsonPrimitive(kind))
            put("scope", kotlinx.serialization.json.JsonPrimitive("conversation"))
            put("sourceQuote", kotlinx.serialization.json.JsonPrimitive(quote))
        }.toString()

    /** Sends one fresh message through the real coordinator in tool mode and replays the model's propose_memory calls in order (arguments verbatim). */
    private suspend fun TestScope.proposeTurn(
        text: String,
        calls: List<String>,
        provider: Provider = provider(),
        // null: the injected TOOL mode; non-null: the coordinator's own mode resolution with this web switch.
        webSearch: Boolean? = null,
    ): ProposeOutcome {
        instructions.putIfAbsent("conversation-1", "")
        val db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), OriveoDatabase::class.java)
            .allowMainThreadQueries()
            .setQueryExecutor { it.run() }
            .setTransactionExecutor { it.run() }
            .build()
        try {
            val preferences = AppPreferencesRepository(
                preferenceDao = db.preferenceDao(),
            )
            val items = MemoryItemRepository(dao = db.memoryItemDao(), preferenceDao = db.preferenceDao(), preferences = preferences)
            val memoryCandidates = MemoryCandidateRepository(dao = db.memoryCandidateDao(), items = items, io = Dispatchers.Unconfined)
            val modelId = provider.models.first().id
            val providerRepository = mockk<ProviderRepository>()
            every { providerRepository.toolCallMemoryVerdict(any(), any()) } returns null
            coEvery { providerRepository.capabilityEvidenceIdentity(any(), any<String>()) } returns null
            val appPreferencesRepository = mockk<AppPreferencesRepository>(relaxed = true)
            val conversationRepository = mockk<ConversationRepository>(relaxed = true)
            val conv = conversation("conversation-1").copy(
                useMemory = true, providerID = provider.id, providerKind = provider.kind, modelID = modelId,
            )
            coEvery { providerRepository.getById(provider.id) } returns provider
            coEvery { appPreferencesRepository.hasAcceptedProviderDisclosure(any()) } returns true
            coEvery { conversationRepository.getWithMessages("conversation-1") } returns conv
            val controller = controller()
            var hook: ai.oriveo.community.core.memory.MemoryProposeSendHook? = null
            val coordinator = ChatSendCommandCoordinator(
                viewModelScope = this,
                appPreferencesRepository = appPreferencesRepository,
                providerRepository = providerRepository,
                conversationRepository = conversationRepository,
                currentConversation = { conv },
                currentConversationId = { "conversation-1" },
                onProviderSelectionError = {},
                onProviderResolutionError = {},
                onModelSelectionError = {},
                onDisclosureRequired = { _, _ -> },
                onConversationActivated = {},
                onComposerConsumed = {},
                requestPin = {},
                onSendSettled = {},
                launchSend = ChatSendLauncher { _, _, _, _, _, _, _, _, _, _, _ -> },
                attemptKind = { ContextConfirmAttempt.SEND },
                directiveSuggestions = controller,
                launchUserSend = ChatUserSendLauncher { _, _, _, sent, _, _, _, _, onUserMessageCreated, propose ->
                    onUserMessageCreated("message-1", sent)
                    hook = propose
                },
                memoryCandidates = memoryCandidates,
                memoryAccountId = { "account-1" },
                memoryScope = this,
                memoryProposeMode = if (webSearch == null) {
                    { _, _, _ -> ai.oriveo.community.core.context.MemoryProposeMode.TOOL }
                } else {
                    null
                },
                resolveAttachmentSendOptions = { _, _ ->
                    webSearch?.let {
                        ai.oriveo.community.core.provider.AttachmentSendPreflight.SendOptions(
                            reasoningMode = ai.oriveo.community.core.model.ReasoningMode.Automatic,
                            webSearchEnabled = it,
                            toolLoopPossible = false,
                        )
                    }
                },
            )
            coordinator.sendMessage(text, null, provider.id, modelId)
            advanceUntilIdle()
            val turn = hook
            calls.forEach { requireNotNull(turn).onProposeCall(it) }
            advanceUntilIdle()
            return ProposeOutcome(
                controller = controller,
                proposeHook = turn,
                pending = controller.pending.value["conversation-1"],
                candidates = db.memoryCandidateDao().list("account-1"),
            )
        } finally {
            db.close()
        }
    }

    private fun provider(): Provider {
        val model = AIModel(id = "m-1", name = "Model", isDefault = true, capabilities = listOf(ModelCapability.Text))
        return Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            apiKey = "local-key",
            baseUrlText = "https://relay.test/v1",
            models = listOf(model),
            catalogModels = listOf(model),
        )
    }

    private fun conversation(id: String) = Conversation(
        id = id,
        title = "t",
        providerID = "relay-1",
        providerKind = ProviderKind.Relay,
        modelID = "m-1",
        messages = emptyList(),
        updatedAt = 1L,
    )

    private fun fakePrefs(map: MutableMap<String, Int>): SharedPreferences {
        val editor = mockk<SharedPreferences.Editor>()
        every { editor.putInt(any(), any()) } answers {
            map[firstArg()] = secondArg()
            editor
        }
        every { editor.remove(any()) } answers {
            map.remove(firstArg<String>())
            editor
        }
        every { editor.apply() } just Runs
        val prefs = mockk<SharedPreferences>()
        every { prefs.getInt(any(), any()) } answers { map[firstArg()] ?: secondArg() }
        every { prefs.edit() } returns editor
        return prefs
    }
}
