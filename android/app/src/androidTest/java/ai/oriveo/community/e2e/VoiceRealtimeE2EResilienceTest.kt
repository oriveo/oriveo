package ai.oriveo.community.e2e

import android.content.Context
import android.content.Intent
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import ai.oriveo.community.MainActivity
import ai.oriveo.community.R
import ai.oriveo.community.core.data.dao.ConversationDao
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceCatalogClient
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.feature.chat.voice.RealtimeFailureAction
import ai.oriveo.community.smoke.SmokeSeed
import io.ktor.client.HttpClient
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.json.JSONObject
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.koin.mp.KoinPlatform

/**
 * Realtime voice E2E (shared/voice-contracts/e2e/realtime-e2e.v1.json): resilience and edges —
 * background / cold start of a home realtime session, network and auth failure cards, switching models while idle
 * opens no microphone, and the voice button of a realtime conversation with the voice catalog not ready. Soft checks per step, screenshots and
 * results.json (contract items 4 and 5).
 */
@RunWith(AndroidJUnit4::class)
class VoiceRealtimeE2EResilienceTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    @get:Rule
    val microphone = SmokeSeed.microphonePermission()

    private val app = E2EApp(compose)
    private val lang: String get() = E2EArgs.locale
    private val realtimeModel: String get() = E2EFixture.model
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Before
    fun setUp() = app.start()

    @After
    fun tearDown() = app.finish()

    @Test
    fun background_keeps_session() {
        val scenario = E2EScenario("background_keeps_session")
        scenario.step("background-foreground") {
            val entry = startHomeRealtime()
            check(entry == null, "entry (home, realtime selected, disclosure accepted), orb tapped: ${entry ?: "ok"}")
            val listening = listening()
            check(app.waitUntil(E2EApp.STEP_MS) { app.onScreen(listening) }, "status listening (\"$listening\") before backgrounding")
            backgroundAndReturn()
            check(true, "backgrounded via KEYCODE_HOME for ${BACKGROUND_MS} ms, foregrounded with the launcher intent")
            homeSessionAlive(this)
        }
        scenario.step("speak-short") {
            val spoke = speakRealtime()
            check(spoke, "realtime session started and spoken into (sessions ${app.realtimeSessions.get()}, connections ${app.gemini.connections.get()})")
            app.waitUntil(TURN_MS) { homeDb() == (1 to 1) && app.bubbles() == (1 to 1) }
            expectEquals("bubbles (user, assistant)", 1 to 1, app.bubbles())
            expectEquals("db (user, assistant)", 1 to 1, homeDb())
        }
        scenario.finish()
    }

    @Test
    fun cold_start() {
        val scenario = E2EScenario("cold_start")
        val entry = enterAfterBackground()
        scenario.step("relaunch-open") {
            check(entry == null, "entry (after background_keeps_session: end): ${entry ?: "reached"}")
            relaunchActivity()
            check(true, "cold start is Activity-level only: ActivityScenario closed and relaunched in the same process (Koin, fake servers and db kept)")
            val opened = app.waitUntil(E2EApp.STEP_MS) { app.exists(hasTestTag("home_conversation_item")) } &&
                openHomeConversation()
            check(opened, "opened the home realtime conversation from the home list (newest home_conversation_item)")
            app.waitUntil(E2EApp.STEP_MS) { app.bubbles() == (1 to 1) }
            expectEquals("bubbles (user, assistant)", 1 to 1, app.bubbles())
            expectEquals("db (user, assistant)", 1 to 1, homeDb())
            val tap = app.string(R.string.voice_realtime_tap_to_start)
            check(app.waitUntil(E2EApp.STEP_MS) { app.onScreen(tap) }, "status tap_to_start (\"$tap\") on the chat page")
        }
        scenario.finish()
    }

    @Test
    fun failure_network() {
        val scenario = E2EScenario("failure_network")
        scenario.step("tap-orb") {
            app.gemini.mode = FakeGeminiServer.Mode.NetworkOnce
            val entry = startHomeRealtime()
            check(entry == null, "entry (home, realtime selected, fake server network_once), orb tapped: ${entry ?: "ok"}")
            failureCard(this, R.string.voice_realtime_failure_network, RealtimeFailureAction.Retry)
            expectEquals("db (user, assistant)", 0 to 0, homeDb())
        }
        scenario.step("retry") {
            app.gemini.mode = FakeGeminiServer.Mode.Normal
            val retry = actionTag(RealtimeFailureAction.Retry)
            if (app.exists(retry)) {
                compose.onAllNodes(retry, useUnmergedTree = true).onFirst().performClick()
            } else {
                check(false, "retry action ${retry.description} not on screen")
            }
            val listening = listening()
            check(app.waitUntil(E2EApp.STEP_MS) { app.onScreen(listening) }, "status listening (\"$listening\") after retry")
            check(app.waitUntil(E2EApp.STEP_MS) { !app.exists(CARD) }, "failureCard false: voice_realtime_failure_card gone after retry")
        }
        scenario.finish()
    }

    @Test
    fun failure_auth() {
        val scenario = E2EScenario("failure_auth")
        scenario.step("tap-orb") {
            app.gemini.mode = FakeGeminiServer.Mode.Auth
            val entry = startHomeRealtime()
            check(entry == null, "entry (home, realtime selected, fake server auth), orb tapped: ${entry ?: "ok"}")
            failureCard(this, R.string.voice_realtime_failure_auth, RealtimeFailureAction.OpenConnection)
            expectEquals("db (user, assistant)", 0 to 0, homeDb())
        }
        scenario.finish()
    }

    @Test
    fun idle_switch_no_mic() {
        val scenario = E2EScenario("idle_switch_no_mic")
        val opened = app.openSeededChat()
        val base = Counters.now(app)
        scenario.step("pick-realtime-then-text") {
            check(opened, "entry: seeded text conversation chat page opened")
            val (toRealtime, _) = app.pickModel(app.realtimeRow(), app.geminiSection, null)
            check(toRealtime == null, "picked the $realtimeModel realtime row: ${toRealtime ?: "ok"}")
            val (toText, _) = app.pickModel(app.textRow(), SmokeSeed.PROVIDER_NAME, null)
            check(toText == null, "picked the text model row: ${toText ?: "ok"}")
            // Switching models while idle must not start any engine: wait a while so a wrongly started session would bump the counter.
            SystemClock.sleep(SETTLE_MS)
            val delta = Counters.now(app) - base
            check(
                delta.uplinkMs == 0L && delta.sttTurns == 0,
                "micOpened false: realtime uplink ${delta.uplinkMs} ms, cascade STT turns ${delta.sttTurns}",
            )
            expectEquals("realtimeSessions", 0, delta.realtimeSessions)
            expectEquals("connections", 0, delta.connections)
            expectEquals("tts", 0, delta.tts)
            expectEquals("conversations", 1, app.conversationIds().size)
        }
        scenario.finish()
    }

    @Test
    fun realtime_catalog_not_ready() {
        val scenario = E2EScenario("realtime_catalog_not_ready")
        val seeded = seedRealtimeConversationModel()
        val koin = KoinPlatform.getKoin()
        val original = koin.get<VoiceCatalogClient>()
        val dir = File(context.filesDir, "voice")
        val cache = File(dir, VoiceCatalogClient.CACHE_FILE_NAME)
        val cleared = !cache.exists() || cache.delete()
        // The local catalog service always returns 500, so with no cache the catalog read really fails and the in-process state is LoadFailed.
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                MockResponse().setResponseCode(500).setHeader("Content-Type", "application/json").setBody("{}")
        }
        server.start()
        val failing = VoiceCatalogClient(koin.get<HttpClient>(), "http://127.0.0.1:${server.port}", dir)
        koin.declare(failing, allowOverride = true)
        try {
            val catalog = runBlocking { failing.refresh() }
            relaunchActivity()
            val opened = app.openSeededChat()
            val base = Counters.now(app)
            scenario.step("open-failed") {
                check(seeded, "entry: seeded conversation model written as $realtimeModel (provider ${SmokeSeed.GEMINI_PROVIDER_ID})")
                check(cleared && !cache.exists(), "entry: voice catalog cache cleared after geminiConnection (${cache.path})")
                check(
                    catalog is VoiceCatalogState.LoadFailed,
                    "entry: voice catalog not ready (no cache, 127.0.0.1:${server.port} answered 500), state=${catalog::class.java.simpleName}",
                )
                check(opened, "entry: seeded conversation chat page opened (Activity relaunched after clearing the cache)")
                // The failure must be visible immediately, not hidden behind a tap: after the page opens, judge the failure row without tapping.
                SystemClock.sleep(OPEN_SETTLE_MS)
                catalogFailedRow(this)
                SystemClock.sleep(SETTLE_MS)
                expectEquals("tts", 0, (Counters.now(app) - base).tts)
                check(realtimeModel !in app.text.models, "textRequestModels exclude $realtimeModel: ${app.text.models.toList()}")
            }
        } finally {
            koin.declare(original, allowOverride = true)
            server.shutdown()
        }
        scenario.finish()
    }

    @Test
    fun realtime_conversation_no_delisted_banner_ready() {
        val scenario = E2EScenario("realtime_conversation_no_delisted_banner_ready")
        val seeded = seedRealtimeConversationModel()
        val catalog = KoinPlatform.getKoin().get<VoiceCatalogClient>().state.value
        relaunchActivity()
        val opened = app.openSeededChat()
        scenario.step("open-wait") {
            check(seeded, "entry: seeded conversation model written as $realtimeModel (provider ${SmokeSeed.GEMINI_PROVIDER_ID})")
            check(catalog is VoiceCatalogState.Available, "entry: voice catalog ready (cached before launch), state=${catalog?.javaClass?.simpleName}")
            check(opened, "entry: seeded conversation chat page opened (Activity relaunched)")
            SystemClock.sleep(OPEN_SETTLE_MS)
            noDelistedBanner(this)
            sendEnabled(this)
            topBarRealtime(this)
        }
        scenario.finish()
    }

    @Test
    fun realtime_conversation_no_delisted_banner_late() {
        val scenario = E2EScenario("realtime_conversation_no_delisted_banner_late")
        val seeded = seedRealtimeConversationModel()
        val koin = KoinPlatform.getKoin()
        val original = koin.get<VoiceCatalogClient>()
        val dir = File(context.filesDir, "voice")
        val cache = File(dir, VoiceCatalogClient.CACHE_FILE_NAME)
        // The seeded catalog (the cache written by SmokeSeed.geminiConnection) is served unchanged as the local catalog response; then the cache is deleted so the catalog is not ready.
        val seedData = runCatching { JSONObject(cache.readText()).getJSONObject("data") }.getOrNull()
        val cleared = !cache.exists() || cache.delete()
        val release = CountDownLatch(1)
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                release.await(CATALOG_HOLD_MS, TimeUnit.MILLISECONDS)
                val body = JSONObject().put("code", 0).put("data", seedData ?: JSONObject())
                return MockResponse().setResponseCode(200).setHeader("Content-Type", "application/json").setBody(body.toString())
            }
        }
        server.start()
        val late = VoiceCatalogClient(koin.get<HttpClient>(), "http://127.0.0.1:${server.port}", dir)
        koin.declare(late, allowOverride = true)
        // The request is sent first and held by the local server, released 3 s after the page appears. The page's own refresh queues behind this one.
        val fetch = thread(name = "late-voice-catalog") { runBlocking { late.refresh() } }
        try {
            relaunchActivity()
            val opened = app.openSeededChat()
            val pendingAtOpen = late.state.value
            scenario.step("open-wait") {
                check(seeded, "entry: seeded conversation model written as $realtimeModel (provider ${SmokeSeed.GEMINI_PROVIDER_ID})")
                check(seedData != null && cleared && !cache.exists(), "entry: seed catalog captured and cache cleared (${cache.path})")
                check(opened, "entry: seeded conversation chat page opened (Activity relaunched, catalog served by 127.0.0.1:${server.port})")
                check(pendingAtOpen == null, "entry: voice catalog not arrived when the page appeared, state=${pendingAtOpen?.javaClass?.simpleName}")
                SystemClock.sleep(OPEN_SETTLE_MS)
                noDelistedBanner(this)
                modelLoading(this)
                topBarRealtime(this)
            }
            SystemClock.sleep(CATALOG_LATE_MS - OPEN_SETTLE_MS)
            release.countDown()
            scenario.step("catalog-arrived") {
                fetch.join(CATALOG_HOLD_MS)
                val state = late.state.value
                check(state is VoiceCatalogState.Available, "catalog arrived ${CATALOG_LATE_MS} ms after the page appeared, state=${state?.javaClass?.simpleName}")
                SystemClock.sleep(OPEN_SETTLE_MS)
                noDelistedBanner(this)
                sendEnabled(this)
                check(app.exists(app.tagged("realtime_model_dot")), "realtimeDot true: realtime_model_dot on screen")
            }
        } finally {
            release.countDown()
            fetch.join(CATALOG_HOLD_MS)
            koin.declare(original, allowOverride = true)
            server.shutdown()
        }
        scenario.finish()
    }

    /** delistedBanner false: neither the retired banner nor the model-missing title on screen (expectGlossary.delistedBanner). */
    private fun noDelistedBanner(step: E2EStep) = with(step) {
        val texts = app.screenTexts()
        val (prefix, suffix) = app.string(R.string.chat_model_retired_banner, MARK).split(MARK, limit = 2).let { it[0] to it.getOrElse(1) { "" } }
        val retired = texts.filter { it.startsWith(prefix) && it.endsWith(suffix) && it.length > prefix.length + suffix.length }
        val missing = app.string(R.string.chat_issue_model_missing_title)
        check(retired.isEmpty() && missing !in texts, "delistedBanner false: retired banner $retired, model-missing title ${missing in texts}")
    }

    /** sendEnabled true: the voice dock orb (main entry of a realtime conversation, E-719) is clickable and not disabled. */
    private fun sendEnabled(step: E2EStep) = with(step) {
        val orb = app.tagged(ORB_TAG) and hasClickAction()
        app.waitUntil(E2EApp.STEP_MS) { app.exists(orb) }
        val node = app.nodes(orb).firstOrNull()
        if (node == null) {
            check(false, "sendEnabled true: voice dock orb ($ORB_TAG) with a click action not on screen")
        } else {
            val disabled = node.config.getOrNull(SemanticsProperties.Disabled) != null
            check(!disabled, "sendEnabled true: voice dock orb ($ORB_TAG) ${if (disabled) "disabled" else "enabled"}")
        }
    }

    /** modelLoading true: a node read out as voice_realtime_model_loading and disabled (catalog not arrived yet). */
    private fun modelLoading(step: E2EStep) = with(step) {
        val copy = app.copy("voice_realtime_model_loading")
        if (copy == null) {
            check(false, "modelLoading: copy missing")
            return@with
        }
        val loading = SemanticsMatcher("reads \"$copy\"") { node ->
            node.config.getOrNull(SemanticsProperties.ContentDescription).orEmpty().contains(copy) ||
                node.config.getOrNull(SemanticsProperties.Text).orEmpty().any { it.text == copy }
        }
        // The screen-reader name is on the icon child, and Disabled is on the clickable parent button. In the merged tree both are one node, so query both trees.
        val nodes = app.nodes(loading, unmerged = false) + app.nodes(loading)
        val disabled = nodes.any { it.config.getOrNull(SemanticsProperties.Disabled) != null }
        check(nodes.isNotEmpty() && disabled, "modelLoading true: node reading \"$copy\" found ${nodes.size}, disabled $disabled")
    }

    /**
     * catalogFailedRow true: the catalog_unavailable row and its retry action are on screen without any tap, the main
     * key (chat_send_button / chat_voice_conversation_button / chat_send_loading_button) is disabled, and no node reads
     * voice_realtime_model_loading (no spinner).
     */
    private fun catalogFailedRow(step: E2EStep) = with(step) {
        val unavailable = app.copy("voice_realtime_catalog_unavailable")
        val retry = app.copy("voice_realtime_action_retry")
        val loadingCopy = app.copy("voice_realtime_model_loading")
        if (unavailable == null || retry == null || loadingCopy == null) {
            check(false, "catalogFailedRow: copy missing (unavailable ${unavailable != null}, retry ${retry != null}, loading ${loadingCopy != null})")
            return@with
        }
        fun reads(copy: String) = SemanticsMatcher("reads \"$copy\"") { node ->
            node.config.getOrNull(SemanticsProperties.ContentDescription).orEmpty().contains(copy) ||
                node.config.getOrNull(SemanticsProperties.Text).orEmpty().any { it.text == copy }
        }
        fun both(matcher: SemanticsMatcher) = app.nodes(matcher, unmerged = false) + app.nodes(matcher)
        val rowNodes = both(reads(unavailable))
        val retryNodes = both(reads(retry))
        check(rowNodes.isNotEmpty(), "catalogFailedRow: node reading \"$unavailable\" on screen without a tap, found ${rowNodes.size}")
        check(retryNodes.isNotEmpty(), "catalogFailedRow: retry node reading \"$retry\" on screen without a tap, found ${retryNodes.size}")
        val mainKey = SemanticsMatcher("sentryTag in $MAIN_KEY_TAGS") {
            it.config.firstOrNull { entry -> entry.key.name == "SentryTag" }?.value in MAIN_KEY_TAGS
        }
        val keys = both(mainKey)
        val disabled = keys.any { it.config.getOrNull(SemanticsProperties.Disabled) != null }
        check(keys.isNotEmpty() && disabled, "catalogFailedRow: main key ($MAIN_KEY_TAGS) found ${keys.size}, disabled $disabled")
        val spinners = both(reads(loadingCopy))
        check(spinners.isEmpty(), "catalogFailedRow: no node reading \"$loadingCopy\" (main key not spinning), found ${spinners.size}")
    }

    /** topBarModel: the chat top bar shows the realtime model. */
    private fun topBarRealtime(step: E2EStep) = with(step) {
        val shown = app.topBarModel()
        if (shown == null) check(false, "testability gap: topBarModel, chat top bar model row not found") else expectEquals("topBarModel", realtimeModel, shown)
    }

    /** The seeded conversation's model rewritten to the realtime model (as if picked in an earlier run); false when missing. */
    private fun seedRealtimeConversationModel(): Boolean = runBlocking {
        val dao = KoinPlatform.getKoin().get<ConversationDao>()
        val row = dao.getAll(SmokeSeed.ACCOUNT_ID).firstOrNull { it.id == SmokeSeed.SEEDED_CONVERSATION_ID } ?: return@runBlocking false
        dao.upsert(row.copy(providerID = SmokeSeed.GEMINI_PROVIDER_ID, providerKind = ProviderKind.Gemini.name, modelID = realtimeModel))
        true
    }

    // ---- entries ----

    /** background_keeps_session driven without checks, then the session ended; null = reached. */
    private fun enterAfterBackground(): String? {
        startHomeRealtime()?.let { return it }
        if (!app.waitUntil(E2EApp.STEP_MS) { app.onScreen(listening()) }) return "status listening not shown after tapping the orb"
        backgroundAndReturn()
        if (!speakRealtime()) return "realtime session not started (sessions ${app.realtimeSessions.get()})"
        if (!app.waitUntil(TURN_MS) { homeDb() == (1 to 1) }) return "realtime turn not persisted: db ${homeDb()}"
        val end = hasTestTag("voice_conversation_end_button")
        if (!app.exists(end)) return "voice_conversation_end_button not on screen"
        compose.onAllNodes(end, useUnmergedTree = true).onFirst().performClick()
        if (!app.waitUntil(E2EApp.STEP_MS) { !app.exists(end) }) return "voice surface still shown after end"
        return null
    }

    /** Home → pill picker → Gemini realtime row (as SmokeSeed.selectHomeRealtime), then taps the voice dock orb. */
    private fun startHomeRealtime(): String? {
        val orb = orb()
        // A realtime model picked by an earlier class or case in the same instrumentation process is still in memory (not a cold start), so the home page opens on the realtime idle stage. Skip the picker.
        app.waitUntil(E2EApp.STEP_MS) { app.exists(hasTestTag("home_composer_input")) || app.exists(orb) }
        if (app.exists(orb) && app.exists(app.tagged("realtime_model_dot"))) {
            compose.onAllNodes(orb, useUnmergedTree = true).onFirst().performClick()
            return null
        }
        if (!app.exists(hasTestTag("home_composer_input"))) return "home composer not shown"
        val button = hasTestTag("model_picker_button")
        if (!app.exists(button)) return "testability gap: home model_picker_button not found"
        compose.onAllNodes(button, useUnmergedTree = true).onFirst().performClick()
        if (!app.waitUntil(E2EApp.STEP_MS) { app.exists(hasTestTag("model_picker_list")) }) return "home model picker list did not open"
        val row = app.realtimeRow()
        app.revealPickerRow(row, app.geminiSection, realtime = true)
        if (!app.waitUntil(E2EApp.STEP_MS) { app.exists(row) }) {
            return "home picker realtime row not found; picker texts=${app.screenTexts().take(40)}"
        }
        compose.onAllNodes(row, useUnmergedTree = true).onFirst().performClick()
        if (app.exists(hasTestTag("model_picker"))) Espresso.pressBack()
        app.waitUntil(E2EApp.STEP_MS) { !app.exists(hasTestTag("model_picker")) }
        if (!app.waitUntil(E2EApp.STEP_MS) { app.exists(orb) }) return "home voice orb (${orb.description}) not shown after picking realtime"
        compose.onAllNodes(orb, useUnmergedTree = true).onFirst().performClick()
        return null
    }

    /** The newest home list item (the realtime conversation the home created); true when its chat page opened. */
    private fun openHomeConversation(): Boolean {
        app.clickFirstConversationItem()
        return app.waitUntil(E2EApp.STEP_MS) { app.exists(hasTestTag("chat_screen")) }
    }

    // ---- device ----

    /** Home key for [BACKGROUND_MS], then the launcher intent brings the task back (MainActivity is singleTop). */
    private fun backgroundAndReturn() {
        shell("input keyevent KEYCODE_HOME")
        SystemClock.sleep(BACKGROUND_MS)
        val launch = requireNotNull(context.packageManager.getLaunchIntentForPackage(context.packageName)) { "no launcher intent" }
        context.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    private fun shell(command: String) {
        val output = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
        ParcelFileDescriptor.AutoCloseInputStream(output).use { it.readBytes() }
    }

    /**
     * Activity-level relaunch (as SmokeHost.restart, without reseeding): closes E2EApp's ActivityScenario and launches
     * MainActivity again in the same process. E2ETestSupport stays untouched, so its private scenario is swapped by
     * reflection to keep [E2EApp.string] on the live activity.
     */
    private fun relaunchActivity() {
        val field = E2EApp::class.java.getDeclaredField("scenario").apply { isAccessible = true }
        (field.get(app) as? ActivityScenario<*>)?.close()
        field.set(app, ActivityScenario.launch(MainActivity::class.java))
    }

    // ---- realtime ----

    /** Waits for the realtime session's setup, then speaks {lang}-short into it; false when no session started. */
    private fun speakRealtime(): Boolean {
        if (!app.waitUntil(E2EApp.STEP_MS) { app.realtimeAudio != null && app.gemini.setup != null }) return false
        // setupComplete follows the setup after fakeServer.setupCompleteAfterMs; speech before it would be dropped.
        SystemClock.sleep(SETUP_SETTLE_MS)
        E2EVoice(app.gemini, app.realtimeAudio!!).speak("$lang-short")
        return true
    }

    private fun homeSessionAlive(step: E2EStep) = with(step) {
        val listening = listening()
        check(app.waitUntil(E2EApp.STEP_MS) { app.onScreen(listening) }, "status listening (\"$listening\") after foregrounding")
        check(app.exists(hasTestTag("voice_conversation_end_button")), "visible end: voice_conversation_end_button on screen")
        expectEquals("connections", 1, app.gemini.connections.get())
        check(!app.exists(CARD), "failureCard false: voice_realtime_failure_card ${if (app.exists(CARD)) "shown" else "absent"}")
    }

    private fun failureCard(step: E2EStep, copy: Int, action: RealtimeFailureAction) = with(step) {
        val shown = app.waitUntil(E2EApp.STEP_MS) { app.exists(CARD) }
        val texts = cardTexts()
        check(shown, "failureCard: voice_realtime_failure_card shown (connections ${app.gemini.connections.get()})")
        // Placeholder args follow each failure key's copyArg in the realtime-model.v1.json contract: model is the realtime model name, provider is the provider name.
        val arg = if (copy == R.string.voice_realtime_failure_network) realtimeModel else app.geminiSection
        val expected = app.string(copy, arg)
        check(texts.any { it == expected }, "failureCard kind: copy \"$expected\" on the card; card texts=$texts")
        val tag = actionTag(action)
        check(app.exists(tag), "actions [${action.rawValue}]: ${tag.description} on the card")
    }

    private fun cardTexts(): List<String> = app.nodes(hasAnyAncestor(CARD)).flatMap { node ->
        node.config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text }
    }

    // ---- db / matchers ----

    /** (user, assistant) rows over the conversations the home created (every conversation but the seeded one). */
    private fun homeDb(): Pair<Int, Int> = runBlocking {
        val repository = KoinPlatform.getKoin().get<ConversationRepository>()
        val messages = app.conversationIds().filter { it != SmokeSeed.SEEDED_CONVERSATION_ID }
            .flatMap { repository.getWithMessages(it)?.messages.orEmpty() }
        messages.count { it.role == ChatRole.User } to messages.count { it.role == ChatRole.Assistant }
    }

    private fun orb(): SemanticsMatcher =
        hasContentDescription(app.string(R.string.voice_realtime_tap_to_start)) and hasClickAction()

    private fun listening(): String = app.string(R.string.voice_conversation_status_listening)

    private fun actionTag(action: RealtimeFailureAction): SemanticsMatcher =
        hasTestTag("voice_realtime_failure_action_${action.rawValue}")

    /** Counters of expectGlossary, read at the scenario entry (baseline) and subtracted. */
    private data class Counters(val uplinkMs: Long, val sttTurns: Int, val realtimeSessions: Int, val connections: Int, val tts: Int) {
        operator fun minus(base: Counters) = Counters(
            uplinkMs - base.uplinkMs,
            sttTurns - base.sttTurns,
            realtimeSessions - base.realtimeSessions,
            connections - base.connections,
            tts - base.tts,
        )

        companion object {
            fun now(app: E2EApp) = Counters(
                uplinkMs = app.gemini.uplinkMs,
                sttTurns = app.stt.turns.get(),
                realtimeSessions = app.realtimeSessions.get(),
                connections = app.gemini.connections.get(),
                tts = app.tts.started.get(),
            )
        }
    }

    private companion object {
        val CARD: SemanticsMatcher = hasTestTag("voice_realtime_failure_card")
        const val TURN_MS = 40_000L
        const val SETUP_SETTLE_MS = 800L
        const val BACKGROUND_MS = 5_000L
        const val SETTLE_MS = 2_000L
        const val OPEN_SETTLE_MS = 1_000L
        const val CATALOG_LATE_MS = 3_000L
        const val CATALOG_HOLD_MS = 30_000L
        const val MARK = "\u0001"
        const val ORB_TAG = "realtime_voice_dock_orb_button"
        val MAIN_KEY_TAGS = listOf("chat_send_button", "chat_voice_conversation_button", "chat_send_loading_button")
    }
}
