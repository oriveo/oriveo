package ai.oriveo.community.feature.chat

import android.content.SharedPreferences
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.context.ContextBudgetLimit
import ai.oriveo.community.core.context.ContextCheckpoint
import ai.oriveo.community.core.context.ContextContractFixture
import ai.oriveo.community.core.context.ContextContractFixture.bool
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.intOrNull
import ai.oriveo.community.core.context.ContextContractFixture.objOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.data.repository.ContextCheckpointKind
import ai.oriveo.community.core.data.repository.ContextCheckpointRecord
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.notice.ContextPriceLineAcknowledgement
import ai.oriveo.community.core.notice.ContextPriceLineConfirmState
import ai.oriveo.community.core.notice.ContextPriceLineConfirmStore
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.feature.settings.ContextSettingsViewModel
import io.mockk.Runs
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.JsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.math.abs

/** Pre-send confirmation verdicts run case by case through the shared fixture context-cap-confirm.v1, plus dialog copy assembly and the local confirmation state. */
@OptIn(ExperimentalCoroutinesApi::class)
class ContextCapConfirmPresentationTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("context-cap-confirm.v1.json") }
    private val dispatcher = UnconfinedTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        MetadataTestFixtures.clear()
    }

    @Test
    fun confirm_matches_fixture() {
        val cases = ContextContractFixture.cases(fixture, "cases")
        assertTrue(cases.size >= 30)
        cases.forEach { case ->
            val id = case.id()
            val decision = ContextCapConfirmPresentation.decide(input(case.objOrNull("input")!!))
            val e = case.objOrNull("expected")!!
            assertEquals(id, e.stringOrNull("kind"), decision.kind.wire)
            assertEquals(id, e.bool("showDontAsk"), decision.showDontAsk)
            val cost = e.objOrNull("cost")
            if (cost == null) {
                assertNull(id, decision.cost)
            } else {
                val actual = assertNotNullAndGet(id, decision.cost)
                assertTrue("$id long ${actual.long}", abs(actual.long - cost.stringOrNull("long")!!.toDouble()) <= 1e-9)
                assertTrue("$id base ${actual.base}", abs(actual.base - cost.stringOrNull("base")!!.toDouble()) <= 1e-9)
            }
            assertEquals(
                id,
                e.objOrNull("multiplier")?.let { listOf(it.intOrNull("input"), it.intOrNull("output")) },
                decision.multiplier?.let { listOf(it.inputTenths, it.outputTenths) },
            )
            assertEquals(
                id,
                e.objOrNull("acknowledgeOnConfirm")?.let { listOf(it.stringOrNull("model"), it.intOrNull("T")) },
                decision.acknowledgeOnConfirm?.let { listOf(it.model, it.T) },
            )
        }
    }

    @Test
    fun confirm_text_variants() {
        val zh = strings("values-zh-rCN")
        val strings = ContextConfirmStrings(zh::getValue)
        val panelStrings = ContextCapPanelStrings(zh::getValue)

        val priceLine = case("price_line_first_cross")
        val priceText = ContextCapConfirmPresentation.text(
            decision = ContextCapConfirmPresentation.decide(priceLine),
            input = priceLine,
            modelName = "Grok 4.7",
            strings = strings,
            panelStrings = panelStrings,
            locale = "zh-Hans",
        )!!
        assertEquals("\u8fd9\u6761\u6d88\u606f\u4f1a\u6309\u957f\u4e0a\u4e0b\u6587\u4ef7\u8ba1\u8d39", priceText.title)
        assertEquals(
            "\u8fd9\u6b21\u7ea6 21.3\u4e07 token，\u8d85\u8fc7 Grok 4.7 \u7684 20\u4e07 \u52a0\u4ef7\u7ebf，\u6574\u4e2a\u8bf7\u6c42\u6309\u957f\u4e0a\u4e0b\u6587\u4ef7\u8ba1\u8d39：\u7ea6 \$0.85，\u4e0d\u8d8a\u7ebf\u7ea6 \$0.43。",
            stripIsolates(priceText.body),
        )
        assertEquals("\u672c\u5bf9\u8bdd\u4e0d\u518d\u63d0\u793a", priceText.dontAsk)
        // {model} is isolated with FSI...PDI just like numbers and amounts
        assertTrue(priceText.body, priceText.body.contains("\u2068Grok 4.7\u2069"))
        assertEquals("\u4ecd\u7136\u53d1\u9001", priceText.confirm)
        assertEquals(zh.getValue("cancel"), priceText.cancel)

        val overCap = case("over_cap_custom")
        val overText = ContextCapConfirmPresentation.text(
            decision = ContextCapConfirmPresentation.decide(overCap),
            input = overCap,
            modelName = "Grok 4.7",
            strings = strings,
            panelStrings = panelStrings,
            locale = "zh-Hans",
        )!!
        assertEquals("\u8fd9\u6761\u6d88\u606f\u4f1a\u8d85\u8fc7\u4e0a\u4e0b\u6587\u4e0a\u9650", overText.title)
        assertEquals("\u8fd9\u6b21\u7ea6 15.2\u4e07 token，\u8d85\u8fc7\u6b64\u5bf9\u8bdd\u4e0a\u9650 12.8\u4e07。", stripIsolates(overText.body))
        // Over the cap it asks every time: no checkbox
        assertNull(overText.dontAsk)

        // Both: the over-cap title, and the body over_cap_body followed by also_cost on a new line
        val both = case("over_cap_and_price_line")
        val bothText = ContextCapConfirmPresentation.text(
            ContextCapConfirmPresentation.decide(both), both, "Grok 4.7", strings, panelStrings, "zh-Hans",
        )!!
        assertEquals("\u8fd9\u6761\u6d88\u606f\u4f1a\u8d85\u8fc7\u4e0a\u4e0b\u6587\u4e0a\u9650", bothText.title)
        assertEquals(
            "\u8fd9\u6b21\u7ea6 26\u4e07 token，\u8d85\u8fc7\u6b64\u5bf9\u8bdd\u4e0a\u9650 24\u4e07。\n" +
                "\u8fd9\u6b21\u8fd8\u4f1a\u8d8a\u8fc7 Grok 4.7 \u7684 20\u4e07 \u52a0\u4ef7\u7ebf，\u6574\u4e2a\u8bf7\u6c42\u6309\u957f\u4e0a\u4e0b\u6587\u4ef7\u8ba1\u8d39：\u7ea6 \$1.04，\u4e0d\u8d8a\u7ebf\u7ea6 \$0.52。",
            stripIsolates(bothText.body),
        )
        assertEquals("\u672c\u5bf9\u8bdd\u4e0d\u518d\u63d0\u793a", bothText.dontAsk)
        assertTrue(bothText.body, bothText.body.contains("\u2068Grok 4.7\u2069"))

        // Multiplier only: body_mult, and the multiplier sentence goes through multiplierText
        val mult = case("price_line_base_prompt_zero")
        val multDecision = ContextCapConfirmPresentation.decide(mult)
        val multText = ContextCapConfirmPresentation.text(multDecision, mult, "Grok 4.7", strings, panelStrings, "zh-Hans")!!
        val multSentence = ContextCapPresentation.multiplierText(multDecision.multiplier!!, panelStrings, "zh-Hans")
        assertEquals(
            "\u8fd9\u6b21\u7ea6 21.3\u4e07 token，\u8d85\u8fc7 Grok 4.7 \u7684 20\u4e07 \u52a0\u4ef7\u7ebf，\u6574\u4e2a\u8bf7\u6c42\u6309\u957f\u4e0a\u4e0b\u6587\u4ef7\u8ba1\u8d39（${stripIsolates(multSentence)}）。",
            stripIsolates(multText.body),
        )

        // Neither amount nor multiplier: plain
        val plain = case("price_line_no_pricing")
        val plainText = ContextCapConfirmPresentation.text(
            ContextCapConfirmPresentation.decide(plain), plain, "Grok 4.7", strings, panelStrings, "zh-Hans",
        )!!
        assertEquals("\u8fd9\u6b21\u7ea6 21.3\u4e07 token，\u8d85\u8fc7 Grok 4.7 \u7684 20\u4e07 \u52a0\u4ef7\u7ebf，\u6574\u4e2a\u8bf7\u6c42\u6309\u957f\u4e0a\u4e0b\u6587\u4ef7\u8ba1\u8d39。", stripIsolates(plainText.body))
        assertTrue(plainText.body, plainText.body.contains("\u2068Grok 4.7\u2069"))
        assertTrue(multText.body, multText.body.contains("\u2068Grok 4.7\u2069"))

        // Both + multiplier only / neither: also_mult / also
        val bothMult = both.copy(pricing = ContextCapPricing(0.0, 6.0, 4.0, 12.0))
        val bothMultText = ContextCapConfirmPresentation.text(
            ContextCapConfirmPresentation.decide(bothMult), bothMult, "Grok 4.7", strings, panelStrings, "zh-Hans",
        )!!
        assertEquals(
            "\u8fd9\u6b21\u7ea6 26\u4e07 token，\u8d85\u8fc7\u6b64\u5bf9\u8bdd\u4e0a\u9650 24\u4e07。\n" +
                "\u8fd9\u6b21\u8fd8\u4f1a\u8d8a\u8fc7 Grok 4.7 \u7684 20\u4e07 \u52a0\u4ef7\u7ebf，\u6574\u4e2a\u8bf7\u6c42\u6309\u957f\u4e0a\u4e0b\u6587\u4ef7\u8ba1\u8d39（${stripIsolates(multSentence)}）。",
            stripIsolates(bothMultText.body),
        )
        val bothPlain = both.copy(pricing = null)
        val bothPlainText = ContextCapConfirmPresentation.text(
            ContextCapConfirmPresentation.decide(bothPlain), bothPlain, "Grok 4.7", strings, panelStrings, "zh-Hans",
        )!!
        assertEquals(
            "\u8fd9\u6b21\u7ea6 26\u4e07 token，\u8d85\u8fc7\u6b64\u5bf9\u8bdd\u4e0a\u9650 24\u4e07。\n\u8fd9\u6b21\u8fd8\u4f1a\u8d8a\u8fc7 Grok 4.7 \u7684 20\u4e07 \u52a0\u4ef7\u7ebf，\u6574\u4e2a\u8bf7\u6c42\u6309\u957f\u4e0a\u4e0b\u6587\u4ef7\u8ba1\u8d39。",
            stripIsolates(bothPlainText.body),
        )

        // No copy when it does not ask
        val none = case("price_line_one_below")
        assertNull(ContextCapConfirmPresentation.text(ContextCapConfirmPresentation.decide(none), none, "Grok 4.7", strings, panelStrings, "zh-Hans"))

        // Model name: AIModel.name, falling back to the id when empty
        assertEquals("Grok 4.7", ContextCapConfirmPresentation.modelDisplayName(AIModel(id = "grok-4.7", name = "Grok 4.7"), "grok-4.7"))
        assertEquals("grok-4.7", ContextCapConfirmPresentation.modelDisplayName(AIModel(id = "grok-4.7", name = " "), "grok-4.7"))
        assertEquals("grok-4.7", ContextCapConfirmPresentation.modelDisplayName(null, "grok-4.7"))
    }

    @Test
    fun confirm_text_from_production_metadata() = runTest(dispatcher) {
        // grok-4.7: pricing 2 / 6, longContext 4 / 12 @ 200000, entered only through production metadata decoding and ContextCapViewModel.
        MetadataTestFixtures.applyRaw(GROK_METADATA)
        val viewModel = ContextCapViewModel(
            conversation = MutableStateFlow(GROK_CONVERSATION),
            defaultCap = MutableStateFlow(ContextBudgetCap.Auto),
            providers = MutableStateFlow(listOf(GROK_PROVIDER)),
            requestOptions = { _, _ -> ChatRequestOptions() },
        )
        val collector = launch { viewModel.inputs.collect {} }
        advanceUntilIdle()

        val inputs = viewModel.inputs.value!!
        val budget = ContextBudget.window(inputs.window.copy(budgetCap = inputs.effectiveCap))
        val input = ContextConfirmInput(
            attempt = ContextConfirmAttempt.SEND,
            model = GROK_MODEL_ID,
            reminderEnabled = true,
            state = ContextPriceLineConfirmState.DEFAULT,
            pricing = inputs.pricing,
            estimatedInput = 213_000,
            B = budget.B,
            limitedBy = budget.limitedBy,
            priceLineTokens = inputs.window.priceLineTokens,
        )
        val decision = ContextCapConfirmPresentation.decide(input)
        assertEquals(ContextConfirmKind.PRICE_LINE, decision.kind)
        assertEquals(ContextPriceLineAcknowledgement(GROK_MODEL_ID, 200_000), decision.acknowledgeOnConfirm)
        val cost = decision.cost!!
        assertTrue(abs(cost.long - 0.852) <= 1e-9 && abs(cost.base - 0.426) <= 1e-9)

        val zh = strings("values-zh-rCN")
        val text = ContextCapConfirmPresentation.text(
            decision, input, inputs.modelName, ContextConfirmStrings(zh::getValue), ContextCapPanelStrings(zh::getValue), "zh-Hans",
        )!!
        assertEquals(
            "\u8fd9\u6b21\u7ea6 21.3\u4e07 token，\u8d85\u8fc7 Grok 4.7 \u7684 20\u4e07 \u52a0\u4ef7\u7ebf，\u6574\u4e2a\u8bf7\u6c42\u6309\u957f\u4e0a\u4e0b\u6587\u4ef7\u8ba1\u8d39：\u7ea6 \$0.85，\u4e0d\u8d8a\u7ebf\u7ea6 \$0.43。",
            stripIsolates(text.body),
        )
        collector.cancel()
    }

    @Test
    fun confirm_state_store_roundtrip() {
        val map = mutableMapOf<String, String>()
        val store = ContextPriceLineConfirmStore(prefsProvider = { fakePrefs(map) })
        // Default {false, null}
        assertEquals(ContextPriceLineConfirmState(suppressed = false, acknowledged = null), store.state("c1"))

        val priceLine = case("price_line_first_cross")
        val decision = ContextCapConfirmPresentation.decide(priceLine)
        // Confirm without ticking: only acknowledged is recorded
        store.confirm("c1", decision, dontAskChecked = false)
        assertEquals(
            ContextPriceLineConfirmState(suppressed = false, acknowledged = ContextPriceLineAcknowledgement("grok-4.7", 200_000)),
            store.state("c1"),
        )
        assertTrue(map.keys.single().startsWith("context_price_line_confirm:"))
        assertEquals(setOf("context_price_line_confirm:c1"), map.keys)
        // Once recorded, the same model with the same T is not asked again
        assertEquals(ContextConfirmKind.NONE, ContextCapConfirmPresentation.decide(priceLine.copy(state = store.state("c1"))).kind)

        // Ticked: suppressed = true
        store.confirm("c2", decision, dontAskChecked = true)
        assertEquals(
            ContextPriceLineConfirmState(suppressed = true, acknowledged = ContextPriceLineAcknowledgement("grok-4.7", 200_000)),
            store.state("c2"),
        )
        // Over the cap only: confirming does not change the state
        store.confirm("c3", ContextCapConfirmPresentation.decide(case("over_cap_custom")), dontAskChecked = true)
        assertEquals(ContextPriceLineConfirmState.DEFAULT, store.state("c3"))
        assertTrue("context_price_line_confirm:c3" !in map)
        // Conversations do not affect each other; a bad value reads as the default
        map["context_price_line_confirm:c4"] = "{not json"
        assertEquals(ContextPriceLineConfirmState.DEFAULT, store.state("c4"))
        assertEquals(true, store.state("c2").suppressed)
        assertEquals(false, store.state("c1").suppressed)

        // Pure function: that a cancel changes nothing is guaranteed by the caller not calling confirm; this covers the state transition of a confirm
        val start = ContextPriceLineConfirmState.DEFAULT
        assertEquals(start, ContextCapConfirmPresentation.afterConfirm(start, ContextCapConfirmPresentation.decide(case("over_cap_custom")), true))
        assertEquals(
            ContextPriceLineConfirmState(true, ContextPriceLineAcknowledgement("grok-4.7", 200_000)),
            ContextCapConfirmPresentation.afterConfirm(start, ContextCapConfirmPresentation.decide(case("over_cap_and_price_line")), true),
        )
    }

    @Test
    fun confirm_strings_present_in_16_locales() {
        assertEquals(16, LOCALE_DIRS.size)
        val missing = mutableListOf<String>()
        LOCALE_DIRS.forEach { dir ->
            val res = strings(dir)
            CONFIRM_STRING_KEYS.forEach { (key, placeholders) ->
                val text = res[key]
                when {
                    text.isNullOrBlank() -> missing += "$dir:$key"
                    (1..placeholders).any { "%$it\$s" !in text } -> missing += "$dir:$key(placeholder)"
                    "%${placeholders + 1}\$s" in text -> missing += "$dir:$key(extra placeholder)"
                    "{" in text -> missing += "$dir:$key(raw placeholder)"
                }
            }
            if (res["cancel"].isNullOrBlank()) missing += "$dir:cancel"
        }
        assertEquals(emptyList<String>(), missing)
        assertEquals("Send anyway", strings("values").getValue("context_confirm_send"))
        assertEquals("Ask before long-context pricing", strings("values").getValue("settings_context_price_line_reminder"))
        assertEquals("\u8d8a\u8fc7\u52a0\u4ef7\u7ebf\u65f6\u63d0\u9192", strings("values-zh-rCN").getValue("settings_context_price_line_reminder"))
        assertEquals("Don't ask again in this chat", strings("values").getValue("context_confirm_dont_ask"))
    }

    @Test
    fun settings_price_line_reminder_roundtrip() = runTest(dispatcher) {
        val repository = AppPreferencesRepository(FakePreferenceDao())
        val viewModel = ContextSettingsViewModel(repository)
        val collector = launch { viewModel.priceLineReminderEnabled.collect {} }

        // On by default
        assertTrue(viewModel.priceLineReminderEnabled.value)
        assertTrue(repository.getContextPriceLineReminderEnabled())

        viewModel.setPriceLineReminderEnabled(false)
        advanceUntilIdle()
        assertFalse(repository.getContextPriceLineReminderEnabled())
        assertFalse(repository.contextPriceLineReminderEnabled.first())
        assertFalse(viewModel.priceLineReminderEnabled.value)

        viewModel.setPriceLineReminderEnabled(true)
        advanceUntilIdle()
        assertTrue(repository.getContextPriceLineReminderEnabled())
        assertTrue(viewModel.priceLineReminderEnabled.value)
        collector.cancel()
    }

    @Test
    fun separator_summary_uses_model_display_name() {
        val messages = listOf(
            chatMessage("m0", ChatRole.User),
            chatMessage("m1", ChatRole.Assistant),
            chatMessage("m2", ChatRole.User),
        )
        val row = ContextCheckpointRecord(
            conversationId = "c1",
            checkpointId = "cp-m1",
            kind = ContextCheckpointKind.SUMMARY,
            coversFrom = "m0",
            coversTo = "m1",
            coversDigest = "digest",
            messagesCovered = 2,
            userMessageIds = listOf("m0"),
            text = "summary text",
            summary = "summary",
            language = null,
            model = GROK_MODEL_ID,
            packerVersion = ContextCheckpoint.PACKER_VERSION,
            createdAt = 1_760_000_000_000L,
            cost = null,
        )
        // Look up the display name in the catalog by the model id of the record
        val catalog = mapOf(GROK_MODEL_ID to "Grok 4.7")
        val named = ContextCompactionPresentation.separator(row, messages, ContextBudget.RHO0) { catalog[it] }!!
        assertEquals("Grok 4.7", named.model)
        assertEquals(ContextCheckpointKind.SUMMARY, named.kind)
        assertEquals("m1", named.anchorMessageId)
        // Not found or empty name: use the id
        assertEquals(GROK_MODEL_ID, ContextCompactionPresentation.separator(row, messages, ContextBudget.RHO0) { null }!!.model)
        assertEquals(GROK_MODEL_ID, ContextCompactionPresentation.separator(row, messages, ContextBudget.RHO0) { " " }!!.model)
        assertEquals(GROK_MODEL_ID, ContextCompactionPresentation.separator(row, messages, ContextBudget.RHO0)!!.model)

        // Name lookup: provider.models first, then the production metadata catalog displayName, and finally the separator falls back to the id
        MetadataTestFixtures.applyRaw(GROK_METADATA)
        val renamed = GROK_PROVIDER.copy(models = listOf(AIModel(id = GROK_MODEL_ID, name = "My Grok")))
        assertEquals("My Grok", ChatCompactionUiCoordinator.catalogModelName(listOf(renamed), GROK_CONVERSATION, GROK_MODEL_ID))
        val bare = GROK_PROVIDER.copy(models = emptyList())
        val blank = GROK_PROVIDER.copy(models = listOf(AIModel(id = GROK_MODEL_ID, name = " ")))
        assertEquals("Grok 4.7", ChatCompactionUiCoordinator.catalogModelName(listOf(blank), GROK_CONVERSATION, GROK_MODEL_ID))
        val fromCatalog = ContextCompactionPresentation.separator(row, messages, ContextBudget.RHO0) {
            ChatCompactionUiCoordinator.catalogModelName(listOf(bare), GROK_CONVERSATION, it)
        }!!
        assertEquals("Grok 4.7", fromCatalog.model)
        val unknown = row.copy(model = "grok-unlisted")
        assertEquals(
            "grok-unlisted",
            ContextCompactionPresentation.separator(unknown, messages, ContextBudget.RHO0) {
                ChatCompactionUiCoordinator.catalogModelName(listOf(bare), GROK_CONVERSATION, it) { _, _ -> null }
            }!!.model,
        )
    }

    private fun chatMessage(id: String, role: ChatRole) = ChatMessage(
        id = id,
        role = role,
        text = "message $id",
        providerID = GROK_PROVIDER.id,
        providerKind = GROK_PROVIDER.kind,
        providerName = GROK_PROVIDER.displayName,
        modelID = GROK_MODEL_ID,
        modelName = "Grok 4.7",
        state = ChatMessageState.Delivered,
    )

    private class FakePreferenceDao : PreferenceDao {
        private val values = linkedMapOf<String, MutableStateFlow<String?>>()

        override fun observe(key: String): Flow<String?> = values.getOrPut(key) { MutableStateFlow(null) }

        override suspend fun get(key: String): String? = values[key]?.value

        override suspend fun set(entity: PreferenceEntity) {
            values.getOrPut(entity.key) { MutableStateFlow(null) }.value = entity.value
        }

        override suspend fun delete(key: String) {
            values.getOrPut(key) { MutableStateFlow(null) }.value = null
        }
    }

    private fun case(id: String): ContextConfirmInput =
        input(ContextContractFixture.cases(fixture, "cases").single { it.id() == id }.objOrNull("input")!!)

    /** Fixture input -> production arguments; limitedBy goes through ContextBudgetLimit.wire and attempt through ContextConfirmAttempt.fromWire. */
    private fun input(json: JsonObject): ContextConfirmInput {
        val state = json.objOrNull("conversationState")!!
        val ack = state.objOrNull("acknowledged")
        return ContextConfirmInput(
            attempt = ContextConfirmAttempt.fromWire(json.stringOrNull("attempt")!!)!!,
            model = json.stringOrNull("model")!!,
            reminderEnabled = json.bool("reminderEnabled"),
            state = ContextPriceLineConfirmState(
                suppressed = state.bool("suppressed"),
                acknowledged = ack?.let { ContextPriceLineAcknowledgement(it.stringOrNull("model")!!, it.intOrNull("T")!!) },
            ),
            pricing = json.objOrNull("pricing")?.let(::pricing),
            estimatedInput = json.intOrNull("estimatedInput")!!,
            B = json.intOrNull("B"),
            limitedBy = json.stringOrNull("limitedBy")?.let { wire -> ContextBudgetLimit.entries.single { it.wire == wire } },
            priceLineTokens = json.intOrNull("priceLineTokens"),
        )
    }

    private fun pricing(json: JsonObject): ContextCapPricing {
        fun side(group: String, key: String): Double? = json.objOrNull(group)?.stringOrNull(key)?.toDouble()
        return ContextCapPricing(
            basePrompt = side("base", "prompt"),
            baseCompletion = side("base", "completion"),
            longPrompt = side("long", "prompt"),
            longCompletion = side("long", "completion"),
        )
    }

    private fun <T> assertNotNullAndGet(message: String, value: T?): T {
        assertNotNull(message, value)
        return value!!
    }

    private fun stripIsolates(text: String): String = text.replace(Regex("[⁦-⁩]"), "")

    private fun strings(dir: String): Map<String, String> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File("src/main/res/$dir/strings.xml"))
        val nodes = doc.getElementsByTagName("string")
        return (0 until nodes.length).map { nodes.item(it) as Element }
            .associate { it.getAttribute("name") to it.textContent.replace("\\'", "'").replace("\\\"", "\"") }
    }

    private fun fakePrefs(map: MutableMap<String, String>): SharedPreferences {
        val editor = mockk<SharedPreferences.Editor>()
        every { editor.putString(any(), any()) } answers {
            map[firstArg()] = secondArg()
            editor
        }
        every { editor.remove(any()) } answers {
            map.remove(firstArg<String>())
            editor
        }
        every { editor.apply() } just Runs
        val prefs = mockk<SharedPreferences>()
        every { prefs.getString(any(), any()) } answers { map[firstArg()] ?: secondArg() }
        every { prefs.edit() } returns editor
        return prefs
    }

    private companion object {
        val LOCALE_DIRS = listOf(
            "values", "values-ar", "values-de", "values-es", "values-fr", "values-hi", "values-in",
            "values-ja", "values-ko", "values-pt-rBR", "values-ru", "values-th", "values-tr",
            "values-vi", "values-zh-rCN", "values-zh-rTW",
        )

        /** chat / settings group keys -> number of placeholders (%1$s...). */
        val CONFIRM_STRING_KEYS = listOf(
            "context_confirm_over_cap_title" to 0,
            "context_confirm_over_cap_body" to 2,
            "context_confirm_price_line_title" to 0,
            "context_confirm_price_line_body_cost" to 5,
            "context_confirm_price_line_body_mult" to 4,
            "context_confirm_price_line_body" to 3,
            "context_confirm_also_price_line_cost" to 4,
            "context_confirm_also_price_line_mult" to 3,
            "context_confirm_also_price_line" to 2,
            "context_confirm_dont_ask" to 0,
            "context_confirm_send" to 0,
            // settings group
            "settings_context_price_line_reminder" to 0,
            "settings_context_price_line_reminder_footer" to 0,
        )

        const val GROK_MODEL_ID = "grok-4.7"
        val GROK_PROVIDER = Provider(
            id = "grok-1",
            kind = ProviderKind.Grok,
            apiKey = "byok-key",
            models = listOf(AIModel(id = GROK_MODEL_ID, name = "Grok 4.7", contextLength = 2_000_000)),
        )
        val GROK_CONVERSATION = Conversation(
            id = "conversation-cap-confirm",
            title = "Cap confirm",
            providerID = GROK_PROVIDER.id,
            providerKind = ProviderKind.Grok,
            modelID = GROK_MODEL_ID,
        )
        val GROK_METADATA: String = run {
            val model = """
                "$GROK_MODEL_ID": {
                  "canonicalModelId": "$GROK_MODEL_ID",
                  "displayName": "Grok 4.7",
                  "contextLength": 2000000,
                  "pricingStatus": "paid",
                  "pricing": {"promptPerMToken": 2, "completionPerMToken": 6,
                    "longContext": {"thresholdTokens": 200000, "promptPerMToken": 4, "completionPerMToken": 12}}
                }
            """.trimIndent()
            """{"version": 1, "contractVersion": 1, "providers": {"grok": {"displayName": "grok", "resolveMap": {"$GROK_MODEL_ID": "$GROK_MODEL_ID"}, "models": {$model}}}}"""
        }
    }
}
