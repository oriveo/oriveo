package ai.oriveo.community.e2e

import android.content.Context
import android.graphics.Rect
import android.os.SystemClock
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.MainActivity
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppPreferenceKeys
import ai.oriveo.community.core.data.EntityMapper.toEntity
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.dao.ProviderDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.prepareProviderForUpsert
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.core.voice.VoiceCatalogClient
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceDisclosureStore
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.smoke.SmokeSeed
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TestName
import org.junit.runner.RunWith
import org.koin.mp.KoinPlatform

/**
 * Realtime voice E2E (shared/voice-contracts/e2e/realtime-e2e.v1.json): switching the answering
 * model while a voice conversation is running, ≋ (cascade on the text model) → realtime and back, on the same
 * conversation and the same voice surface. Fake Gemini Live server + injected PCM for realtime, injected STT and a
 * counting TTS for ≋, a loopback fake text provider. Soft checks per step, screenshots and results.json.
 * Also the home realtime full flow (home_full_flow) and re-entering that conversation from the home list
 * (reenter_from_list): empty library, Gemini connected, realtime disclosure not accepted.
 */
@RunWith(AndroidJUnit4::class)
class VoiceRealtimeE2ETest {
    @get:Rule
    val compose = createEmptyComposeRule()

    @get:Rule
    val microphone = SmokeSeed.microphonePermission()

    @get:Rule
    val testName = TestName()

    private val app = E2EApp(compose)
    private val lang: String get() = E2EArgs.locale
    private val realtimeModel: String get() = E2EFixture.model

    /** Home scenarios: their own activity (E2EApp.start seeds a conversation and accepts the disclosure). */
    private var homeActivity: ActivityScenario<MainActivity>? = null
    private val homeSessions = AtomicInteger(0)

    @Volatile
    private var homeAudio: InjectedPcmRealtimeAudio? = null

    @Before
    fun setUp() = if (testName.methodName in HOME_SCENARIOS) startHome() else app.start()

    @After
    fun tearDown() {
        app.finish(homeActivity)
        homeActivity = null
    }

    @Test
    fun home_full_flow() {
        val scenario = E2EScenario("home_full_flow")
        homeFullFlow { name, block -> scenario.step(name, block) }
        scenario.finish()
    }

    @Test
    fun reenter_from_list() {
        val scenario = E2EScenario("reenter_from_list")
        // Entry = after home_full_flow: drive it again without recording its checks.
        val entry = mutableListOf<String>()
        homeFullFlow { name, block ->
            val step = E2EStep()
            runCatching { step.block() }.onFailure { entry += "$name threw ${it.message}" }
            step.checks.filterNot { it.ok }.forEach { entry += "$name: ${it.detail}" }
        }
        val homeIds = app.conversationIds()
        scenario.step("orb-speak") {
            val reached = homeIds.size == 1 && homeDb(homeIds.single()) == (5 to 5)
            check(reached, "entry (after home_full_flow, 1 conversation with 5 + 5 rows): ids $homeIds, " +
                "home_full_flow misses ${entry.size}${entry.firstOrNull()?.let { ", first: $it" }.orEmpty()}")
            val id = homeIds.firstOrNull()
            if (app.exists(hasTestTag("chat_back_button"))) {
                compose.onNode(hasTestTag("chat_back_button"), useUnmergedTree = true).performClick()
            }
            val listed = app.waitUntil(E2EApp.STEP_MS) { app.exists(hasTestTag("home_conversation_item")) }
            check(listed, "home list item (home_conversation_item) on screen")
            if (listed) {
                app.clickFirstConversationItem()
                check(app.waitUntil(E2EApp.STEP_MS) { app.exists(hasTestTag("chat_screen")) }, "chat page opened from the home list")
            }
            val sessionsBefore = homeSessions.get()
            check(tapOrb(), "orb (${ORB_TAGS.joinToString(" / ")}) tapped")
            val spoke = speakHome("$lang-short", sessionsBefore)
            check(spoke, "a new realtime session started and spoken into (sessions ${homeSessions.get()}, connections ${app.gemini.connections.get()})")
            app.waitUntil(TURN_MS) { id != null && homeDb(id) == (6 to 6) && app.bubbles() == (6 to 6) }
            val ids = app.conversationIds()
            expectEquals("conversations", 1, ids.size)
            check(id != null && ids == listOf(id), "sameConversation: conversation ids $ids, home_full_flow's $homeIds")
            val shown = app.currentConversationId()
            check(id != null && shown == id, "sameConversation: chat page shows conversation $shown, home_full_flow's $id")
            check(app.exists(hasTestTag("chat_screen")), "sameConversation: on the chat page")
            expectEquals("db (user, assistant)", 6 to 6, id?.let { homeDb(it) })
            expectEquals("bubbles (user, assistant)", 6 to 6, app.bubbles())
        }
        scenario.step("end") {
            tapEnd(this)
            status(this, "tap_to_start", R.string.voice_realtime_tap_to_start)
        }
        scenario.finish()
    }

    /** home_full_flow's steps; [step] runs them recorded (a scenario) or unrecorded (another scenario's entry). */
    private fun homeFullFlow(step: (String, E2EStep.() -> Unit) -> Unit) {
        val agree = hasText(homeString(R.string.voice_disclosure_agree)) and hasClickAction()
        step("pick-realtime") {
            check(app.conversationIds().isEmpty(), "entry: empty library, ids ${app.conversationIds()}")
            val failure = pickHomeRealtime()
            check(failure == null, "picked the $realtimeModel realtime row on the home pill: ${failure ?: "ok"}")
            val shown = app.waitUntil(E2EApp.STEP_MS) { app.nodes(agree, unmerged = false).isNotEmpty() }
            check(shown, "visible disclosure: agree button \"${homeString(R.string.voice_disclosure_agree)}\"")
        }
        step("agree") {
            if (app.nodes(agree, unmerged = false).isNotEmpty()) {
                compose.onAllNodes(agree).onFirst().performClick()
            } else {
                check(false, "disclosure agree button not on screen")
            }
            if (app.waitUntil(E2EApp.NOTICE_MS) { !app.exists(agree) } && app.exists(hasTestTag("model_picker"))) Espresso.pressBack()
            app.waitUntil(E2EApp.STEP_MS) { !app.exists(hasTestTag("model_picker")) }
            val orb = app.waitUntil(E2EApp.STEP_MS) { orbNode() != null }
            check(orb, "visible orb (${ORB_TAGS.joinToString(" / ")})")
            val keyboard = app.nodes(hasTestTag(KEYBOARD_TAG)).firstOrNull()
            check(keyboard != null, "visible keyboard ($KEYBOARD_TAG)")
            status(this, "tap_to_start", R.string.voice_realtime_tap_to_start)
            val orbNode = orbNode()
            if (keyboard != null && orbNode != null) {
                val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
                verdict("layout homeIdleKeyboardPillCentredUnderOrb", E2ELayout.keyboardPillCentredUnderOrb(rect(keyboard), rect(orbNode), density))
            } else {
                check(false, "layout homeIdleKeyboardPillCentredUnderOrb: keyboard or orb node missing")
            }
        }
        step("tap-orb") {
            val sessionsBefore = homeSessions.get()
            check(tapOrb(), "orb (${ORB_TAGS.joinToString(" / ")}) tapped")
            status(this, "listening", R.string.voice_conversation_status_listening)
            check(app.exists(hasTestTag("voice_conversation_end_button")), "visible end (voice_conversation_end_button)")
            check(app.exists(hasTestTag("voice_conversation_mute_button")), "visible mute (voice_conversation_mute_button)")
            app.waitUntil(E2EApp.STEP_MS) { homeSessions.get() > sessionsBefore && app.gemini.setup != null }
            val language = app.gemini.setupLanguage
            val ok = language != null && if (lang == "zh") language == "zh-Hans" else language.startsWith("en")
            check(ok, "setupLanguage: setup.inputAudioTranscription.languageCodes[0] = $language (locale $lang)")
        }
        step("speak-short") {
            check(speakHome("$lang-short", 0), "realtime session started and spoken into (sessions ${homeSessions.get()})")
            turn(this, 1, listOf("$lang-short"))
            expectEquals("connections", 1, app.gemini.connections.get())
        }
        step("speak-pause") {
            check(speakHome("$lang-pause", 0), "realtime session alive (sessions ${homeSessions.get()})")
            turn(this, 2, listOf("$lang-short", "$lang-pause"))
        }
        step("speak-long-barge") {
            val audio = homeAudio
            if (audio == null) {
                check(false, "no realtime session to speak into")
            } else {
                val voice = E2EVoice(app.gemini, audio)
                val long = voice.speak("$lang-long")
                val barge = voice.speakAfterReplyStart("$lang-barge")
                waitTurn(4)
                expectEquals("bubbles (user, assistant)", 4 to 4, app.bubbles())
                expectEquals("db (user, assistant)", 4 to 4, homeDb())
                val messages = homeMessages()
                val users = messages.filter { it.role == ChatRole.User }
                expectEquals("lastUserText", barge.transcript, users.lastOrNull()?.text)
                // The reply interrupted by the barge-in = the third assistant row, persisted as a prefix of the full reply.
                val interrupted = messages.filter { it.role == ChatRole.Assistant }.getOrNull(2)?.text
                val full = E2EFixture.replyText(lang, long.transcript)
                check(interrupted != null && full.startsWith(interrupted), "interruptedAssistantIsPrefix: \"$interrupted\" of \"$full\"")
            }
        }
        step("type-send") {
            // A live session only offers mute and end, with no text entry: end it to return to the idle stage, then tap the bottom-row "type" capsule.
            tapEnd(this)
            status(this, "tap_to_start", R.string.voice_realtime_tap_to_start)
            val keyboard = hasTestTag(KEYBOARD_TAG)
            if (app.waitUntil(E2EApp.STEP_MS) { app.exists(keyboard) }) {
                compose.onAllNodes(keyboard, useUnmergedTree = true).onFirst().performClick()
            } else {
                check(false, "keyboard ($KEYBOARD_TAG) not on the idle stage after end")
            }
            val input = COMPOSER_INPUT_TAGS.map(::hasTestTag).firstOrNull { app.waitUntil(E2EApp.NOTICE_MS) { app.exists(it) } }
            if (input == null) {
                check(false, "composer input (${COMPOSER_INPUT_TAGS.joinToString(" / ")}) not on screen")
            } else {
                compose.onAllNodes(input, useUnmergedTree = true).onFirst().performTextInput(TYPED_TEXT)
                val send = SEND_TAGS.map(app::tagged).firstOrNull { app.waitUntil(E2EApp.NOTICE_MS) { app.exists(it) } }
                if (send == null) {
                    check(false, "send button (${SEND_TAGS.joinToString(" / ")}) not on screen")
                } else {
                    // performTextInput focuses the input and raises the IME, so the composer moves up with imePadding.
                    // If the button moves between press and release, clickable treats the release as out of bounds
                    // and silently cancels, leaving the draft in place with the keyboard still open.
                    // Wait until the button is clickable, then until its position is stable for 200 ms, and record the wait.
                    val t0 = SystemClock.uptimeMillis()
                    val enabledAtOnce = app.exists(send and isEnabled())
                    val enabled = enabledAtOnce || app.waitUntil(E2EApp.NOTICE_MS) { app.exists(send and isEnabled()) }
                    check(enabled, "send enabled before tap: at once=$enabledAtOnce, waited ${SystemClock.uptimeMillis() - t0} ms")
                    var lastBounds: Any? = null
                    var stableSince = SystemClock.uptimeMillis()
                    val t1 = SystemClock.uptimeMillis()
                    val settled = app.waitUntil(E2EApp.NOTICE_MS) {
                        val now = app.nodes(send).firstOrNull()?.boundsInRoot
                        if (now != lastBounds) { lastBounds = now; stableSince = SystemClock.uptimeMillis() }
                        now != null && SystemClock.uptimeMillis() - stableSince >= SEND_SETTLE_MS
                    }
                    check(settled, "send button settled before tap: waited ${SystemClock.uptimeMillis() - t1} ms, bounds $lastBounds")
                    compose.onAllNodes(send, useUnmergedTree = true).onFirst().performClick()
                }
            }
            waitTurn(5)
            if (input != null) check(!app.exists(input and hasText(TYPED_TEXT, substring = true)), "composer cleared after send (draft \"$TYPED_TEXT\" gone)")
            expectEquals("bubbles (user, assistant)", 5 to 5, app.bubbles())
            expectEquals("db (user, assistant)", 5 to 5, homeDb())
            val back = app.waitUntil(E2EApp.STEP_MS) { BACK_TO_STAGE_TAGS.any { app.exists(app.tagged(it)) } }
            check(back, "visible backToStage (${BACK_TO_STAGE_TAGS.joinToString(" / ")})")
            // The composer state must also be seamless: capture the same pixel column after sending.
            compose.waitForIdle()
            val shot = screen()
            val list = app.nodes(hasTestTag("chat_messages_list")).firstOrNull()
            when {
                shot == null -> check(false, "layout composer: no screenshot")
                list == null -> check(false, "layout composer stageListBandContinuity: chat_messages_list not on screen")
                else -> {
                    // The column at x = 4% crosses the left edge of the bottom-row model-picker capsule. Pixels that go
                    // from 239 to 245 starting at y = 2015 are the capsule fill, not a seam. The column stops at the input's top edge.
                    val column = (shot.width * 0.04).toInt().let { it..it + 40 }
                    val chip = InstrumentationRegistry.getInstrumentation().targetContext.getString(R.string.model_controls)
                    val controls = app.nodes(hasText(chip), unmerged = false) + COMPOSER_INPUT_TAGS.flatMap { app.nodes(hasTestTag(it), unmerged = false) }
                    val bottom = controls.map(::rect)
                        .filter { it.top > rect(list).top && it.left <= column.last && it.right >= column.first }
                        .minOfOrNull { it.top } ?: shot.height
                    verdict("layout composer stageListBandContinuity", E2ELayout.stageListBandContinuity(shot, rect(list).top, bottom))
                }
            }
        }
        step("back-to-stage") {
            val back = BACK_TO_STAGE_TAGS.map(app::tagged).firstOrNull { app.exists(it) }
            if (back == null) {
                check(false, "backToStage not on screen")
            } else {
                compose.onAllNodes(back, useUnmergedTree = true).onFirst().performClick()
            }
            check(app.waitUntil(E2EApp.STEP_MS) { orbNode() != null }, "visible orb (${ORB_TAGS.joinToString(" / ")})")
            // The playback-only session opened by typing is still running. Returning to the voice stage reopens capture
            // on the same connection and goes straight to the stage. A live session only offers mute and end.
            status(this, "listening", R.string.voice_conversation_status_listening)
            check(app.exists(hasTestTag("voice_conversation_end_button")), "visible end (voice_conversation_end_button)")
            check(app.exists(hasTestTag("voice_conversation_mute_button")), "visible mute (voice_conversation_mute_button)")
            app.waitUntil(E2EApp.STEP_MS) { app.bubbles() == (5 to 5) }
            expectEquals("bubbles (user, assistant)", 5 to 5, app.bubbles())
            expectEquals("db (user, assistant)", 5 to 5, homeDb())
            compose.waitForIdle()
            val shot = screen()
            val list = app.nodes(hasTestTag("chat_messages_list")).firstOrNull()
            when {
                shot == null -> check(false, "layout: no screenshot")
                list == null -> check(false, "layout stageListBandContinuity: chat_messages_list not on screen")
                else -> verdict("layout stageListBandContinuity", E2ELayout.stageListBandContinuity(shot, rect(list).top))
            }
        }
    }

    // ---- home helpers ----

    /** As E2EApp.start, minus the seeded conversation and the cascade override, and the disclosure not accepted. */
    private fun startHome() {
        E2EApp.closeParked()
        E2ECorpus.verify()
        app.text.start()
        runBlocking {
            SmokeSeed.reset(InstrumentationRegistry.getInstrumentation().targetContext, app.text.baseUrl)
            geminiConnectionNotAccepted()
            revokeGeminiDisclosures()
        }
        SmokeSeed.overrideRealtime(app.sockets) {
            homeSessions.incrementAndGet()
            InjectedPcmRealtimeAudio.production().also { homeAudio = it }
        }
        homeActivity = ActivityScenario.launch(MainActivity::class.java)
    }

    /**
     * Withdraws consent left by earlier runs (SmokeSeed.geminiConnection accepts both): the Gemini realtime voice
     * disclosure (VoiceDisclosureStore, in the voice settings prefs) and the Gemini provider disclosure (device-scoped
     * Room preference), so the home flow shows the disclosure again.
     */
    private suspend fun revokeGeminiDisclosures() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val voice = context.getSharedPreferences(VoiceEngineSettings.PREFS_NAME, Context.MODE_PRIVATE)
        val realtime = "${ProviderKind.Gemini.rawValue}/${VoiceDirection.Realtime.rawValue}"
        val accepted = voice.getStringSet(VoiceDisclosureStore.KEY_ACCEPTED, null)?.toSet().orEmpty()
        voice.edit().putStringSet(VoiceDisclosureStore.KEY_ACCEPTED, (accepted - realtime).toMutableSet()).commit()
        val dao = KoinPlatform.getKoin().get<PreferenceDao>()
        val key = AppPreferenceKeys.PROVIDER_DISCLOSURE_ACCEPTED_LIST
        val providers = dao.get(key).orEmpty().split(',').map { it.trim() }.filter { it.isNotEmpty() }
        val kept = providers.filter { it != ProviderKind.Gemini.rawValue }
        if (kept.isEmpty()) dao.delete(key) else dao.set(PreferenceEntity(key, kept.joinToString(",")))
    }

    /** SmokeSeed.geminiConnection without markAccepted: key, Gemini provider row and the voice catalog cache. */
    private suspend fun geminiConnectionNotAccepted() {
        val koin = KoinPlatform.getKoin()
        koin.get<SecureKeyStore>().saveApiKey(SmokeSeed.ACCOUNT_ID, SmokeSeed.GEMINI_PROVIDER_ID, GEMINI_KEY)
        val gemini = Provider(
            id = SmokeSeed.GEMINI_PROVIDER_ID,
            kind = ProviderKind.Gemini,
            status = ProviderConnectionState.Connected,
            apiKey = GEMINI_KEY,
            baseUrlText = "https://generativelanguage.googleapis.com/v1beta",
            updatedAt = System.currentTimeMillis(),
        )
        koin.get<ProviderDao>().upsert(prepareProviderForUpsert(gemini).toEntity(SmokeSeed.ACCOUNT_ID))
        val realtime = SmokeSeed.realtimeEntry
        val entry = JSONObject()
            .put("model", realtime.model)
            .put("transport", realtime.transport.rawValue)
            .put("path", realtime.path)
            .put("contextWindow", realtime.contextWindow)
            .put("voices", JSONArray(realtime.voices.map { JSONObject().put("id", it.id).put("isDefault", it.isDefault) }))
            .put("isDefault", realtime.isDefault)
        val data = JSONObject()
            .put("view", "voice")
            .put("schemaVersion", 2)
            .put("providers", JSONObject().put(ProviderKind.Gemini.rawValue, JSONObject().put("realtime", JSONArray().put(entry))))
        val dir = File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir, "voice").apply { mkdirs() }
        File(dir, VoiceCatalogClient.CACHE_FILE_NAME).writeText(JSONObject().put("data", data).toString())
        val state = koin.get<VoiceCatalogClient>().refresh()
        val listed = (state as? VoiceCatalogState.Available)?.catalog?.providers?.get(ProviderKind.Gemini)?.realtime.orEmpty()
        // refresh() may merge the live catalog (the E2E run has no network guard), so only require the seeded model to be listed.
        assertTrue("seeded voice catalog realtime models $listed", listed.any { it.model == realtime.model })
    }

    /** A string in the home activity's language. */
    private fun homeString(id: Int): String {
        var value = ""
        homeActivity?.onActivity { value = it.getString(id) }
            ?: run { value = InstrumentationRegistry.getInstrumentation().targetContext.getString(id) }
        return value
    }

    /** Home pill → picker → Gemini section → realtime row (as SmokeSeed.selectHomeRealtime); null = row tapped. */
    private fun pickHomeRealtime(): String? {
        val pill = hasTestTag("model_picker_button")
        if (!app.waitUntil(E2EApp.STEP_MS) { app.exists(pill) }) return "home pill (model_picker_button) not on screen"
        compose.onNode(pill, useUnmergedTree = true).performClick()
        if (!app.waitUntil(E2EApp.STEP_MS) { app.exists(hasTestTag("model_picker_list")) }) return "model picker list did not open"
        val row = app.realtimeRow()
        app.revealPickerRow(row, app.geminiSection, realtime = true)
        if (!app.waitUntil(E2EApp.STEP_MS) { app.exists(row) }) return "picker row model_picker_realtime_row not found"
        compose.onAllNodes(row, useUnmergedTree = true).onFirst().performClick()
        return null
    }

    private fun orbMatcher(): SemanticsMatcher = ORB_TAGS.map(::hasTestTag).reduce { a, b -> a or b }

    private fun orbNode(): SemanticsNode? = app.nodes(orbMatcher()).firstOrNull()

    private fun tapOrb(): Boolean {
        if (!app.waitUntil(E2EApp.STEP_MS) { orbNode() != null }) return false
        compose.onAllNodes(orbMatcher(), useUnmergedTree = true).onFirst().performClick()
        return true
    }

    private fun tapEnd(step: E2EStep) = with(step) {
        val end = hasTestTag("voice_conversation_end_button")
        if (app.exists(end)) {
            compose.onNode(end, useUnmergedTree = true).performClick()
            check(app.waitUntil(E2EApp.STEP_MS) { !app.exists(end) }, "voice surface gone after end")
        } else {
            check(false, "voice_conversation_end_button not on screen")
        }
    }

    /** Status word of copy key [key] (resource [id]) shown as text or content description. */
    private fun status(step: E2EStep, key: String, id: Int) = with(step) {
        val value = homeString(id)
        check(app.waitUntil(E2EApp.STEP_MS) { app.onScreen(value) }, "status $key (\"$value\") on screen")
    }

    /**
     * Speaks [clipId] into the current home realtime session, waiting first for a session newer than [after] sessions
     * and its setup; false when none started.
     */
    private fun speakHome(clipId: String, after: Int): Boolean {
        val connected = app.waitUntil(E2EApp.STEP_MS) {
            homeSessions.get() > after && homeAudio != null && app.gemini.setup != null && app.gemini.connections.get() >= homeSessions.get()
        }
        if (!connected) return false
        // setupComplete follows the setup after fakeServer.setupCompleteAfterMs; speech before it would be dropped.
        SystemClock.sleep(SETUP_SETTLE_MS)
        E2EVoice(app.gemini, homeAudio!!).speak(clipId)
        return true
    }

    private fun turn(step: E2EStep, count: Int, clips: List<String>) = with(step) {
        waitTurn(count)
        expectEquals("bubbles (user, assistant)", count to count, app.bubbles())
        expectEquals("userTexts", clips.map { E2EFixture.clip(it).transcript }, homeMessages().filter { it.role == ChatRole.User }.map { it.text })
        expectEquals("db (user, assistant)", count to count, homeDb())
    }

    private fun waitTurn(count: Int) = app.waitUntil(TURN_MS) { homeDb() == (count to count) && app.bubbles() == (count to count) }

    /** Rows of the single conversation home created (empty while there is none). */
    private fun homeMessages(id: String? = app.conversationIds().singleOrNull()): List<ChatMessage> = runBlocking {
        id ?: return@runBlocking emptyList()
        KoinPlatform.getKoin().get<ConversationRepository>().getWithMessages(id)?.messages.orEmpty()
    }

    private fun homeDb(id: String? = app.conversationIds().singleOrNull()): Pair<Int, Int> {
        val messages = homeMessages(id)
        return messages.count { it.role == ChatRole.User } to messages.count { it.role == ChatRole.Assistant }
    }

    private fun rect(node: SemanticsNode): Rect = node.boundsInWindow.let {
        Rect(it.left.toInt(), it.top.toInt(), it.right.toInt(), it.bottom.toInt())
    }

    @Test
    fun text_to_realtime_midway() {
        val scenario = E2EScenario("text_to_realtime_midway")
        val opened = app.openSeededChat()
        scenario.step("voice-speak") {
            check(opened, "entry: seeded conversation chat page opened")
            cascadeTurn(this, tts = 1, textRequests = 1, db = 2 to 2)
        }
        scenario.step("switch-to-realtime") { switchToRealtime(this) }
        scenario.step("realtime-speak") { realtimeTurn(this) }
        scenario.finish()
    }

    @Test
    fun realtime_to_text_midway() {
        val scenario = E2EScenario("realtime_to_text_midway")
        val entry = enterRealtimeMidway()
        scenario.step("switch-to-text") {
            check(entry == null, "entry (after text_to_realtime_midway, realtime session active): ${entry ?: "reached"}")
            val sessions = app.realtimeSessions.get()
            val (failure, notice) = app.pickModel(app.textRow(), SmokeSeed.PROVIDER_NAME, SmokeSeed.MODEL_NAME)
            check(failure == null, "picked the text model row: ${failure ?: "ok"}")
            val ended = app.waitUntil(E2EApp.STEP_MS) { app.sockets.closed.get() > 0 }
            check(ended, "realtimeEnded: realtime sockets closed by the app ${app.sockets.closed.get()} (sessions $sessions)")
            switchNotice(this, SmokeSeed.MODEL_NAME, notice)
            topBar(this, SmokeSeed.MODEL_NAME)
            realtimeDot(this, expected = false)
            sameConversation(this)
        }
        scenario.step("voice-speak") {
            app.stt.say(E2EFixture.clip("$lang-short").transcript)
            app.waitUntil(TURN_MS) { app.db() == (4 to 4) && app.tts.started.get() >= 2 }
            expectEquals("realtimeSessions", 1, app.realtimeSessions.get())
            expectEquals("connections", 1, app.gemini.connections.get())
            expectEquals("textRequests", 2, app.text.requests)
            expectEquals("lastTextRequestModel", SmokeSeed.MODEL_ID, app.text.models.lastOrNull())
            expectEquals("tts", 2, app.tts.started.get())
            sameConversation(this)
            expectEquals("db (user, assistant)", 4 to 4, app.db())
        }
        scenario.step("end-voice") {
            val end = hasTestTag("voice_conversation_end_button")
            if (app.exists(end)) {
                compose.onNode(end, useUnmergedTree = true).performClick()
                check(app.waitUntil(E2EApp.STEP_MS) { !app.exists(end) }, "voice surface gone after end")
            } else {
                check(false, "voice_conversation_end_button not on screen")
            }
            topBar(this, SmokeSeed.MODEL_NAME)
            app.waitUntil(E2EApp.STEP_MS) { app.bubbles() == (4 to 4) }
            expectEquals("bubbles (user, assistant)", 4 to 4, app.bubbles())
            expectEquals("db (user, assistant)", 4 to 4, app.db())
        }
        scenario.finish()
    }

    /** text_to_realtime_midway driven without checks; null = reached, otherwise where it stopped. */
    private fun enterRealtimeMidway(): String? {
        if (!app.openSeededChat()) return "seeded chat page not opened"
        if (!startCascade()) return "≋ voice surface did not appear"
        app.stt.say(E2EFixture.clip("$lang-short").transcript)
        if (!app.waitUntil(TURN_MS) { app.db() == (2 to 2) }) return "≋ turn not persisted: db ${app.db()}"
        val (failure, _) = app.pickModel(app.realtimeRow(), app.geminiSection, null)
        if (failure != null) return failure
        if (!speakRealtime()) return "realtime session not started (sessions ${app.realtimeSessions.get()})"
        if (!app.waitUntil(TURN_MS) { app.db() == (3 to 3) }) return "realtime turn not persisted: db ${app.db()}"
        return null
    }

    private fun startCascade(): Boolean {
        val voice = app.tagged("chat_voice_conversation_button")
        if (!app.waitUntil(E2EApp.STEP_MS) { app.exists(voice) }) return false
        compose.onAllNodes(voice, useUnmergedTree = true).onFirst().performClick()
        return app.waitUntil(E2EApp.STEP_MS) { app.exists(hasTestTag("voice_conversation_end_button")) }
    }

    private fun cascadeTurn(step: E2EStep, tts: Int, textRequests: Int, db: Pair<Int, Int>) = with(step) {
        check(startCascade(), "≋ voice surface (voice_conversation_end_button) after tapping chat_voice_conversation_button")
        app.stt.say(E2EFixture.clip("$lang-short").transcript)
        app.waitUntil(TURN_MS) { app.db() == db && app.tts.started.get() >= tts }
        expectEquals("tts", tts, app.tts.started.get())
        expectEquals("textRequests", textRequests, app.text.requests)
        expectEquals("realtimeSessions", 0, app.realtimeSessions.get())
        expectEquals("db (user, assistant)", db, app.db())
    }

    private fun switchToRealtime(step: E2EStep) = with(step) {
        val (failure, notice) = app.pickModel(app.realtimeRow(), app.geminiSection, realtimeModel)
        check(failure == null, "picked the $realtimeModel realtime row: ${failure ?: "ok"}")
        val ended = app.waitUntil(E2EApp.STEP_MS) { !app.cascade.active.value }
        check(ended, "cascadeEnded: ≋ controller active=${app.cascade.active.value}")
        switchNotice(this, realtimeModel, notice)
        topBar(this, realtimeModel)
        realtimeDot(this, expected = true)
        sameConversation(this)
    }

    private fun realtimeTurn(step: E2EStep) = with(step) {
        val spoke = speakRealtime()
        check(spoke, "realtime session started and spoken into (sessions ${app.realtimeSessions.get()}, connections ${app.gemini.connections.get()})")
        app.waitUntil(TURN_MS) { app.db() == (3 to 3) && app.bubbles() == (3 to 3) }
        expectEquals("realtimeSessions", 1, app.realtimeSessions.get())
        expectEquals("connections", 1, app.gemini.connections.get())
        expectEquals("tts", 1, app.tts.started.get())
        expectEquals("textRequests", 1, app.text.requests)
        check(realtimeModel !in app.text.models, "textRequestModels exclude $realtimeModel: ${app.text.models.toList()}")
        sameConversation(this)
        val listening = app.string(R.string.voice_conversation_status_listening)
        check(app.waitUntil(E2EApp.STEP_MS) { app.onScreen(listening) }, "status listening (\"$listening\") on screen")
        expectEquals("bubbles (user, assistant)", 3 to 3, app.bubbles())
        expectEquals("db (user, assistant)", 3 to 3, app.db())
    }

    /** Waits for the realtime session's setup, then speaks {lang}-short into it; false when no session started. */
    private fun speakRealtime(): Boolean {
        if (!app.waitUntil(E2EApp.STEP_MS) { app.realtimeAudio != null && app.gemini.setup != null }) return false
        // setupComplete follows the setup after fakeServer.setupCompleteAfterMs; speech before it would be dropped.
        SystemClock.sleep(SETUP_SETTLE_MS)
        E2EVoice(app.gemini, app.realtimeAudio!!).speak("$lang-short")
        return true
    }

    /** [latched]: the switch notice latch after the pick (VoiceSwitchNoticeLatch), not the briefly shown status line. */
    private fun switchNotice(step: E2EStep, name: String, latched: String?) = with(step) {
        val expected = app.copy(SWITCH_KEY, name)
        if (expected == null) {
            check(false, "switchNotice: copy key $SWITCH_KEY not in the app resources")
        } else {
            val copy = latched?.let { app.copy(SWITCH_KEY, it) }
            check(copy == expected, "switchNotice: latched notice \"${copy ?: "none"}\" == \"$expected\" (latched model: ${latched ?: "null"})")
        }
        val surfaces = app.nodes(hasTestTag("voice_conversation_end_button")).size
        expectEquals("switchNotice: one voice surface, stage not collapsed (end buttons)", 1, surfaces)
    }

    private fun topBar(step: E2EStep, name: String) = with(step) {
        val shown = app.topBarModel()
        if (shown == null) check(false, "testability gap: topBarModel, chat top bar model row not found") else expectEquals("topBarModel", name, shown)
    }

    private fun realtimeDot(step: E2EStep, expected: Boolean) = with(step) {
        val shown = app.exists(app.tagged("realtime_model_dot"))
        check(shown == expected, "realtimeDot: realtime_model_dot on screen expected $expected, actual $shown")
    }

    private fun sameConversation(step: E2EStep) = with(step) {
        val ids = app.conversationIds()
        expectEquals("conversations", 1, ids.size)
        check(ids == listOf(SmokeSeed.SEEDED_CONVERSATION_ID), "sameConversation: conversation ids $ids")
        val shown = app.currentConversationId()
        check(shown == SmokeSeed.SEEDED_CONVERSATION_ID, "sameConversation: chat page shows conversation $shown (seeded ${SmokeSeed.SEEDED_CONVERSATION_ID})")
        check(app.exists(hasTestTag("chat_screen")), "sameConversation: still on the chat page")
    }

    private companion object {
        val HOME_SCENARIOS = setOf("home_full_flow", "reenter_from_list")
        val ORB_TAGS = listOf("realtime_voice_dock_orb_button", "voice_conversation_orb_button")
        const val KEYBOARD_TAG = "realtime_voice_dock_keyboard_button"
        val COMPOSER_INPUT_TAGS = listOf("chat_composer_input", "home_composer_input")
        val SEND_TAGS = listOf("chat_send_button", "home_send_button")
        val BACK_TO_STAGE_TAGS = listOf("chat_voice_back_to_stage_button", "home_voice_back_to_stage_button")
        const val TYPED_TEXT = "typed hello"
        const val SEND_SETTLE_MS = 200L

        /** Same placeholder key as SmokeSeed: realtime turns go to the fake server, the key never leaves the device. */
        const val GEMINI_KEY = "AIza-smoke-replay"
        const val SWITCH_KEY = "voice_realtime_switched_to"
        const val TURN_MS = 40_000L
        const val SETUP_SETTLE_MS = 800L
    }
}
