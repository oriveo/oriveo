package ai.oriveo.community.feature.chat

import java.io.File
import ai.oriveo.community.feature.chat.composer.modelControlOwnerOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatScreenEffectStructureTest {

    @Test
    fun `chat screen keeps lifecycle and metrics effects in effect-only composables`() {
        val screenSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenContent.kt").readText()
        val effectsSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenEffects.kt").readText()

        assertTrue(effectsSource.contains("internal fun ChatMissingConversationExitEffect("))
        assertTrue(effectsSource.contains("internal fun ChatMetricsEffect("))
        assertTrue(effectsSource.contains("internal fun ChatScreenLeavingEffect("))
        assertTrue(screenSource.contains("ChatMetricsEffect("))
        assertTrue(screenSource.contains("ChatScreenLeavingEffect("))
    }

    @Test
    fun `chat screen delegates scroll and prewarm side effects`() {
        val screenSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenContent.kt").readText()
        val effectsSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenEffects.kt").readText()

        listOf(
            "ChatPinToTopEffect",
            "ChatFollowToBottomEffect",
            "ChatStreamingModeEffect",
            "ChatInitialScrollToBottomEffect",
            "ChatImeLatestTrackingEffect",
            "ChatImeFollowEffect",
            "ChatAnchorTransitionEffect",
            "ChatLoadMoreAboveEffect",
            "ChatLoadMoreBelowEffect",
            "ChatMarkdownPrewarmEffect",
        ).forEach { effectName ->
            assertTrue(screenSource.contains("$effectName("))
            assertTrue(effectsSource.contains("internal fun $effectName("))
        }

        assertTrue(screenSource.countOccurrences("LaunchedEffect(") <= 1)
    }

    @Test
    fun `chat screen delegates messages list rendering`() {
        val screenSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreen.kt").readText()
        val contentSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenContent.kt").readText()
        val messagesListSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatMessagesList.kt").readText()

        assertTrue(screenSource.contains("ChatScreenContent("))
        assertTrue(contentSource.contains("ChatMessagesList("))
        assertTrue(messagesListSource.contains("internal fun BoxScope.ChatMessagesList("))
        assertTrue(screenSource.lineSequence().count() <= 500)
    }

    @Test
    fun `chat list has no artificial streaming tail space`() {
        val messagesListSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatMessagesList.kt").readText()

        assertTrue(!messagesListSource.contains("STREAMING_RUNWAY_ITEM_KEY"))
        assertTrue(!messagesListSource.contains("StreamingRunway"))
        assertTrue(!messagesListSource.contains("streamingRunwayPx"))
        assertTrue(!messagesListSource.contains("animateDpAsState"))
        assertTrue(!messagesListSource.contains("item(key ="))
    }

    @Test
    fun `initial bottom settle effect observes latest message count and composer height`() {
        val effectsSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenEffects.kt").readText()

        assertTrue(effectsSource.contains("rememberUpdatedState(latestMessages)"))
        assertTrue(effectsSource.contains("latestMessagesState.value.indexOfFirst"))
        assertTrue(effectsSource.contains("rememberUpdatedState(latestMessageCount)"))
        assertTrue(effectsSource.contains("rememberUpdatedState(composerOverlayHeightPx)"))
        assertTrue(effectsSource.contains("latestMessageCountState.value to composerOverlayHeightPxState.value"))
    }

    @Test
    fun `note source focus waits for initial load and hydrates missing target instead of showing gone toast`() {
        val contentSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenContent.kt").readText()
        val effectsSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenEffects.kt").readText()
        val coordinatorSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatNoteCoordinator.kt").readText()

        assertTrue(contentSource.contains("val hasNavigationTarget = !searchQuery.isNullOrBlank() || viewModel.noteCoordinator.focusMessageId != null"))
        assertTrue(contentSource.contains("hideInitialListUntilBottomSettled = !hasNavigationTarget"))
        assertTrue(contentSource.contains("enabled = !hasNavigationTarget"))
        assertTrue(contentSource.contains("val isInitialLoading by viewModel.isInitialLoading.collectAsStateWithLifecycle()"))
        assertTrue(contentSource.contains("isInitialLoading = isInitialLoading"))
        assertTrue(effectsSource.contains("isInitialLoading: Boolean"))
        assertTrue(effectsSource.contains("focusMessageId, conversationId, messages, hasMoreAbove, isLoadingAbove, isInitialLoading"))
        assertTrue(effectsSource.contains("if (isInitialLoading) return@LaunchedEffect"))
        assertTrue(effectsSource.contains("onLoadFocusMessageWindow(target)"))
        val focusWindowCall = effectsSource.indexOf("onLoadFocusMessageWindow(target)")
        val loadMoreAboveCall = effectsSource.indexOf("onLoadMoreAbove()")
        assertTrue(
            "Focus miss must enter the anchor window path before paging through local history.",
            loadMoreAboveCall == -1 || focusWindowCall < loadMoreAboveCall,
        )
        assertTrue(
            "Focus miss should not prefer incremental history paging over the anchor lookup/hydration path.",
            !effectsSource.contains("hasMoreAbove && !isLoadingAbove -> onLoadMoreAbove()"),
        )
        assertTrue(
            "Focus must keep waiting after remote hydration is requested; otherwise a slow hydrate can be consumed before the target enters the local window.",
            !effectsSource.contains("else -> {\n                focusHandled = true\n            }"),
        )
        assertTrue("The old missing-message toast path must be removed from note focus.", !effectsSource.contains("onFocusMissing"))
        assertTrue("The old missing-message toast helper must be removed.", !coordinatorSource.contains("notifyFocusMessageMissing"))
    }

    @Test
    fun `note return to conversation retires continue ask and linked conversation paths`() {
        val navRouteSource = File("src/main/java/ai/oriveo/community/core/navigation/AppRoute.kt").readText()
        val navHostSource = File("src/main/java/ai/oriveo/community/core/navigation/OriveoNavHost.kt").readText()
        val detailSource = File("src/main/java/ai/oriveo/community/feature/notes/NoteDetailScreen.kt").readText()
        val componentsSource = File("src/main/java/ai/oriveo/community/feature/notes/NotesComponents.kt").readText()
        val contentSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenContent.kt").readText()
        val coordinatorSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatNoteCoordinator.kt").readText()
        val composerSource = File("src/main/java/ai/oriveo/community/feature/chat/composer/EnhancedComposer.kt").readText()
        val noteRepositorySource = File("src/main/java/ai/oriveo/community/core/data/repository/NoteRepository.kt").readText()

        assertTrue(detailSource.contains("onReturnToConversation"))
        assertTrue(componentsSource.contains("notes_source_back_to_conversation"))
        assertTrue(componentsSource.contains("if (canReturn)"))
        assertTrue(componentsSource.contains("if (!note.hasSource && !canReturn) return"))
        assertTrue(!componentsSource.contains("if (!note.hasSource) return"))
        assertTrue(!componentsSource.contains("notes_source_continue_ask"))
        assertTrue(!componentsSource.contains("notes_source_jump"))

        listOf(
            "onNavigateToContinueAsk",
            "composeFromNote",
            "continueNoteId",
            "maybeBeginContinueAsk",
            "continueAskNoteTitle",
            "canAppendLatestAnswerToNote",
            "appendLatestAnswerToNote",
            "appendToBody",
            "notes_chat_update_note_from_chat",
            "setLinkedConversation",
        ).forEach { retired ->
            assertTrue("Retired note continue-ask path remains: $retired", !detailSource.contains(retired))
            assertTrue("Retired note continue-ask path remains: $retired", !contentSource.contains(retired))
            assertTrue("Retired note continue-ask path remains: $retired", !coordinatorSource.contains(retired))
            assertTrue("Retired note continue-ask path remains: $retired", !navHostSource.contains(retired))
            assertTrue("Retired note continue-ask path remains: $retired", !composerSource.contains(retired))
            assertTrue("Retired note continue-ask path remains: $retired", !noteRepositorySource.contains(retired))
        }

        assertTrue(!navRouteSource.contains("val compose: Boolean"))
        assertTrue(!navRouteSource.contains("val noteId: String?"))
        assertTrue("Pinned notes are a general attached-note feature and must stay.", coordinatorSource.contains("pinnedNoteIds"))
    }

    @Test
    fun `replace current note selection wires an unconditional callback and gates only returnToNoteId`() {
        val contentSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenContent.kt").readText()
        val coordinatorSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatNoteCoordinator.kt").readText()

        assertTrue(coordinatorSource.contains("val canReplaceCurrentNote: StateFlow<Boolean>"))
        assertTrue(coordinatorSource.contains("notes.any { normalizeUuid(it.id) == noteId }"))
        assertTrue(contentSource.contains("val canReplaceCurrentNote by viewModel.noteCoordinator.canReplaceCurrentNote.collectAsStateWithLifecycle()"))
        // The callback always takes all three parameters (aligned with iOS canShowReplaceSelection /
        // Web replaceTargetNoteId). Whether the replace entry is visible is decided by
        // ChatMessagesList's replacementNoteId(returnToNoteId ?: savedNoteLinks.first) -- both
        // "arrived from a note" and "this message is already saved as a note" show the entry;
        // canReplaceCurrentNote only gates the returnToNoteId argument, never the callback itself
        // (gating the callback would cut off the saved-note-link-only path and diverge from iOS/Web).
        assertTrue(contentSource.contains("onReplaceSelectionInCurrentNote = { message, text, noteId ->"))
        assertTrue(contentSource.contains("returnToNoteId = if (canReplaceCurrentNote) viewModel.noteCoordinator.returnToNoteId else null"))
        assertTrue(!contentSource.contains("onReplaceSelectionInCurrentNote = if (canReplaceCurrentNote)"))
        assertTrue(!contentSource.contains("onReplaceSelectionInCurrentNote = viewModel.noteCoordinator.returnToNoteId?.let"))
    }

    @Test
    fun `composer has one model controls entry and does not reintroduce legacy capability gates`() {
        val contentSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenContent.kt").readText()
        val composerSource = File("src/main/java/ai/oriveo/community/feature/chat/composer/EnhancedComposer.kt").readText()
        // The panel itself lives inline in `ModelControlsSheet.kt` (a single page pushed onto the
        // same container), so the layout-shape assertions all moved to
        // ModelControlsSheetStructureTest; this test only keeps the composer-side assertions --
        // a single entry point, reads and writes sharing the same source, and the old capability
        // gates never coming back.
        val sheetSource = File(
            "src/main/java/ai/oriveo/community/feature/chat/composer/ModelControlsSheet.kt",
        ).readText()

        assertTrue(!contentSource.contains("supportsWebControl ="))
        assertTrue(!contentSource.contains("supportsReasoningControl ="))
        assertTrue(!composerSource.contains("supportsWebControl"))
        assertTrue(!composerSource.contains("supportsReasoningControl"))
        assertTrue(composerSource.countOccurrences("title = stringResource(R.string.model_controls)") == 1)
        assertTrue(composerSource.countOccurrences("ModelControlsEntrySheet(") == 1)
        // both the draft-conversation and the real-conversation write branches must exist, split by isExistingConversation.
        assertTrue(composerSource.contains("if (isExistingConversation) {"))
        assertTrue(composerSource.contains("capabilityPreferenceStore.setConversation("))
        assertTrue(composerSource.contains("capabilityPreferenceStore.setDraftConversation("))
        // the "set as this model's default" write path, previously dead code, is now actually wired up.
        assertTrue(composerSource.contains("capabilityPreferenceStore.setConnectionModel("))
        // the three-item order still has exactly one declaration, and the panel reads from it.
        assertTrue(
            "Model Options order must stay web → reasoning → advanced settings",
            sheetSource.contains("""modelControlOwnerOrder: List<String> = listOf("web", "reasoning", "generation")"""),
        )
        assertEquals(listOf("web", "reasoning", "generation"), modelControlOwnerOrder)
        // `force` is no longer a flattened tier; the "using it every time needs an official
        // configuration" copy only appears in the advanced-settings page header (the `!isConfigurable` case).
        assertTrue(!composerSource.contains("model_control_force_unavailable"))
        // the global developer-mode toggle has been retired entirely, and its settings-page group removed.
        // the only condition left for outbound requests and restored state is "this owner's custom fields are enabled."
        assertFalse(
            "the settings page must not keep a global developer-mode toggle",
            File("src/main/java/ai/oriveo/community/feature/settings/SettingsScreen.kt")
                .readText()
                .contains("DeveloperModeEnabled("),
        )
        assertFalse(
            "the composer must not query the global toggle",
            composerSource.contains("isDeveloperModeEnabled()"),
        )
        // chip highlighting, panel restored state, and outbound requests all walk the same scope ladder.
        // the UI reads a display projection (no final collapsing), outbound reads resolve -- both
        // share the same `scopeValues` query; neither may keep its own single-layer read.
        assertTrue(composerSource.contains("capabilityPreferenceStore.displayedForUi("))
        assertTrue(!composerSource.contains("capabilityPreferenceStore.draftConversation("))
        assertTrue(!composerSource.contains("capabilityPreferenceStore.resolved("))
        // the skill_agent scope must carry a real skill id; hardcoding null would make it fully invisible in the UI.
        assertTrue(composerSource.contains("skillID = conversationSkillId"))
        val storeSource = File("src/main/java/ai/oriveo/community/core/model/CapabilityPreferenceStore.kt").readText()
        assertTrue(storeSource.contains("fun CapabilityPreferenceStore.resolvedForRequest("))
        assertTrue(storeSource.contains("fun CapabilityPreferenceStore.displayedForUi("))
        // both entry points must land on that one shared query, and the draft layer is part of the ladder too (no longer "read-only draft layer").
        assertEquals(2, storeSource.countOccurrences("isDraftConversation = !isExistingConversation"))
        assertTrue(storeSource.contains("fun scopeValues("))
        assertTrue(storeSource.contains("forwardPortIfNeeded("))
        val displayEntry = storeSource.substringAfter("fun displaySelection(").substringBefore("fun resolved(")
        assertTrue("the display projection must go through the shared query", displayEntry.contains("scopeValues("))
        val resolveEntry = storeSource.substringAfter("fun resolved(").substringBefore("fun setConversation(")
        assertTrue("outbound must also go through the same shared query", resolveEntry.contains("val scopes = scopeValues("))
    }

    @Test
    fun `developer control copy has every locale and does not fall back to English`() {
        val base = File("src/main/res/values/strings.xml").readText()
        // a batch of entries that only served the old panel and its three-toggle gating (the global
        // toggle, the "automatic / custom" two-way choice, the "Apply" button, the single "this JSON
        // is invalid" line) have been retired; the ones below are consumed by the custom fields editor page.
        val keys = listOf(
            "model_control_custom_request_fields", "model_control_custom_json_placeholder",
            "model_control_redacted_delta_preview", "model_control_custom_invalid_json",
            "model_control_custom_too_large", "model_control_custom_conflicts_managed",
            "model_control_custom_fields_need_schema", "model_control_custom_empty_but_selected",
            "model_control_switch_back_to_automatic", "model_control_remove_custom_fields",
            "model_control_remove_custom_fields_title", "model_control_keep_custom_fields",
            "model_control_open_official_docs", "model_control_relay_docs",
            "model_control_reason_external_connector_only",
        )
        File("src/main/res").listFiles().orEmpty().filter { it.name.startsWith("values-") && it.name != "values-night" }.forEach { dir ->
            val copy = File(dir, "strings.xml").readText()
            keys.forEach { key ->
                assertTrue("${dir.name} missing $key", copy.contains("name=\"$key\""))
                assertTrue("$key must actually be translated in ${dir.name}", !copy.contains(englishRow(base, key)))
            }
        }
    }

    /** The full line for a key in the English baseline. If a translation file contains that same line, it was never translated. */
    private fun englishRow(base: String, key: String): String =
        base.lines().first { it.contains("name=\"$key\"") }.trim()

    private fun String.countOccurrences(needle: String): Int =
        split(needle).size - 1
}
