package ai.oriveo.community.feature.settings

import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.context.ContextBudgetCap
import ai.oriveo.community.core.context.ContextContractFixture
import ai.oriveo.community.core.context.ContextContractFixture.id
import ai.oriveo.community.core.context.ContextContractFixture.intOrNull
import ai.oriveo.community.core.context.ContextContractFixture.objOrNull
import ai.oriveo.community.core.context.ContextContractFixture.stringOrNull
import ai.oriveo.community.core.context.ContextMaxOutput
import ai.oriveo.community.core.context.ContextWindowInput
import ai.oriveo.community.core.context.ContextWindowKind
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.feature.chat.ContextCapPanel
import ai.oriveo.community.feature.chat.ContextCapPanelStrings
import ai.oriveo.community.feature.chat.ContextCapViewModel
import ai.oriveo.community.feature.chat.ContextCapWindowLine
import ai.oriveo.community.feature.chat.ContextCapPicker
import ai.oriveo.community.feature.chat.ContextCapPresentation
import ai.oriveo.community.feature.chat.ContextCapPricing
import ai.oriveo.community.feature.chat.ContextCapSelection
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/** The cap presentation pure functions run case by case against the shared fixture context-cap-presentation.v1, plus reading / writing the settings page default cap and its copy. */
@OptIn(ExperimentalCoroutinesApi::class)
class ContextCapSettingsPresentationTest {

    private val fixture: JsonObject by lazy { ContextContractFixture.load("context-cap-presentation.v1.json") }
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
    fun presentation_matches_fixture() {
        val pickers = ContextContractFixture.cases(fixture, "pickerCases")
        val panels = ContextContractFixture.cases(fixture, "panelCases")
        val settings = ContextContractFixture.cases(fixture, "settingsCases")
        assertTrue(pickers.isNotEmpty() && panels.isNotEmpty() && settings.isNotEmpty())

        pickers.forEach { case ->
            val input = case["input"]!!.jsonObject
            val got = ContextCapPresentation.picker(
                window = windowInput(input),
                conversationCap = cap(input["conversationCap"]),
                globalCap = cap(input["globalCap"])!!,
            )
            assertEquals(case.id(), pickerJson(case["expected"]!!.jsonObject), pickerOf(got))
        }

        panels.forEach { case ->
            val input = case["input"]!!.jsonObject
            val got = ContextCapPresentation.panel(
                window = windowInput(input),
                conversationCap = cap(input["conversationCap"]),
                globalCap = cap(input["globalCap"])!!,
                used = input.intOrNull("used")!!,
                pricing = input.objOrNull("pricing")?.let(::pricing),
            )
            assertEquals(case.id(), panelJson(case["expected"]!!.jsonObject), panelOf(got))
        }

        settings.forEach { case ->
            val stored = cap(case["input"]!!.jsonObject["stored"])
            val expected = case["expected"]!!.jsonObject
            val got = ContextCapPresentation.settings(stored)
            assertEquals(
                case.id(),
                listOf(expected.stringOrNull("selected"), expected.intOrNull("customPrefill")),
                listOf(got.selected.wire, got.customPrefill),
            )
        }
    }

    @Test
    fun commit_matches_fixture() {
        val cases = ContextContractFixture.cases(fixture, "commitCases")
        assertTrue(cases.isNotEmpty())
        cases.forEach { case ->
            val input = case["input"]!!.jsonObject
            val expected = case["expected"]!!.jsonObject
            val got = ContextCapPresentation.commit(
                text = input.stringOrNull("text")!!,
                u = input.intOrNull("U"),
                previous = input.intOrNull("previous")!!,
            )
            assertEquals(
                case.id(),
                listOf<Any?>(
                    expected.intOrNull("value"),
                    expected["adjusted"]!!.jsonPrimitive.content.toBooleanStrict(),
                    expected["restored"]!!.jsonPrimitive.content.toBooleanStrict(),
                ),
                listOf<Any?>(got.value, got.adjusted, got.restored),
            )
            // Input echo = the clamped value that will be stored; hidden when it cannot be parsed
            assertEquals(
                case.id(),
                if (got.restored) null else expected.intOrNull("value"),
                ContextCapPresentation.echoValue(input.stringOrNull("text")!!, input.intOrNull("U")),
            )
        }
    }

    @Test
    fun settings_default_cap_roundtrip() = runTest(dispatcher) {
        val repository = AppPreferencesRepository(FakePreferenceDao())
        val viewModel = ContextSettingsViewModel(repository)
        val collector = launch { viewModel.defaultCap.collect {} }

        // Default is Auto; Custom prefills 256000
        assertEquals(ContextBudgetCap.Auto, viewModel.defaultCap.value)
        assertEquals(256_000, ContextCapPresentation.settings(viewModel.defaultCap.value).customPrefill)

        // Choosing Custom writes the prefilled 256000 immediately
        viewModel.selectCustomDefaultCap()
        advanceUntilIdle()
        assertEquals(ContextBudgetCap.Custom(256_000), repository.getContextDefaultCap())

        val committed = viewModel.commitDefaultCap("190000")
        advanceUntilIdle()
        assertEquals(190_000, committed.value)
        assertEquals(false, committed.adjusted)
        assertEquals(ContextBudgetCap.Custom(190_000), repository.getContextDefaultCap())
        assertEquals(ContextBudgetCap.Custom(190_000), viewModel.defaultCap.value)
        assertEquals(190_000, ContextCapPresentation.settings(viewModel.defaultCap.value).customPrefill)

        // Clamp: below 32000 is submitted as 32000 and flagged as adjusted
        val clamped = viewModel.commitDefaultCap("1000")
        advanceUntilIdle()
        assertEquals(32_000, clamped.value)
        assertTrue(clamped.adjusted)
        assertEquals(ContextBudgetCap.Custom(32_000), repository.getContextDefaultCap())

        // Cannot parse: restore the previous value, do not write storage
        val restored = viewModel.commitDefaultCap("abc")
        advanceUntilIdle()
        assertTrue(restored.restored)
        assertEquals(32_000, restored.value)
        assertEquals(ContextBudgetCap.Custom(32_000), repository.getContextDefaultCap())

        viewModel.setDefaultCap(ContextBudgetCap.Unlimited)
        advanceUntilIdle()
        assertEquals(ContextBudgetCap.Unlimited, repository.getContextDefaultCap())
        assertEquals(ContextBudgetCap.Unlimited, viewModel.defaultCap.value)
        collector.cancel()
    }

    @Test
    fun settings_row_value_text() {
        val en = strings("values")
        val zh = strings("values-zh-rCN")
        fun row(res: Map<String, String>, cap: ContextBudgetCap, mode: String, locale: String): String =
            ContextCapPresentation.settingsRowValue(
                template = res.getValue("settings_context_row_value"),
                cap = cap,
                mode = res.getValue(mode),
                autoLabel = res.getValue("context_cap_auto"),
                unlimitedLabel = res.getValue("context_cap_unlimited"),
                locale = locale,
            )

        assertEquals("Automatic · Your messages only", row(en, ContextBudgetCap.Auto, "settings_context_row_value_fallback", "en"))
        assertEquals("No limit · AI summary", row(en, ContextBudgetCap.Unlimited, "settings_context_mode_ai", "en"))
        assertEquals(
            "\u2068190K\u2069 · AI summary",
            row(en, ContextBudgetCap.Custom(190_000), "settings_context_mode_ai", "en"),
        )
        assertEquals(
            "\u206819\u4e07\u2069 · ${zh.getValue("settings_context_row_value_fallback")}",
            row(zh, ContextBudgetCap.Custom(190_000), "settings_context_row_value_fallback", "zh-Hans"),
        )
        assertEquals(
            "\u81ea\u52a8 · ${zh.getValue("settings_context_mode_ai")}",
            row(zh, ContextBudgetCap.Auto, "settings_context_mode_ai", "zh-Hans"),
        )
    }

    @Test
    fun panel_cap_row_from_production_metadata() = runTest(dispatcher) {
        // grok-4.7: W 2000000, pricing 2 / 6, longContext 4 / 12 @ 200000, entering only through production metadata decoding.
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
        assertEquals(200_000, inputs.window.priceLineTokens)
        assertEquals(2_000_000, inputs.window.W)
        val panel = inputs.panel(used = 1_000)
        // Follow + global Auto: B stops at the surcharge line, T >= B
        assertEquals(200_000, panel.capValue)
        assertEquals(false, panel.limitedByModel)
        assertEquals(ContextCapWindowLine.WINDOW_PRICE_LINE, panel.windowLine)
        assertEquals(listOf(20, 20), panel.multiplier?.let { listOf(it.inputTenths, it.outputTenths) })

        val en = strings("values")
        val text = ContextCapPresentation.windowLineText(panel, inputs.window, ContextCapPanelStrings(en::getValue), "en")
        assertEquals(
            "Model window \u20682M\u2069 · past \u2068200K\u2069, billed at long-context prices (input and output ×2)",
            text,
        )
        assertTrue(text!!.contains("×2"))
        collector.cancel()
    }

    @Test
    fun picker_writes_conversation_cap() = runTest(dispatcher) {
        MetadataTestFixtures.applyRaw(GROK_METADATA)
        val conversation = MutableStateFlow(GROK_CONVERSATION)
        val writes = mutableListOf<ContextBudgetCap?>()
        // Through the same DI factory: the write goes via ConversationRepository.updateContextCap(conversationId, cap) and is read back through the conversation flow
        val conversations = mockk<ConversationRepository>()
        every { conversations.observeMetadata(GROK_CONVERSATION.id) } returns conversation
        coEvery { conversations.updateContextCap(GROK_CONVERSATION.id, any()) } answers {
            val cap = secondArg<ContextBudgetCap?>()
            writes += cap
            conversation.value = conversation.value.copy(contextCap = cap)
            true
        }
        val preferences = mockk<AppPreferencesRepository>()
        every { preferences.contextDefaultCap } returns MutableStateFlow(ContextBudgetCap.Auto)
        val providers = mockk<ProviderRepository>()
        every { providers.observeAll() } returns MutableStateFlow(listOf(GROK_PROVIDER))
        val viewModel = ContextCapViewModel.forConversation(
            conversationId = GROK_CONVERSATION.id,
            conversations = conversations,
            preferences = preferences,
            providers = providers,
            generationParameters = GenerationParameterSettingsStore(readPayload = { null }, writePayload = {}),
        )
        val collector = launch { viewModel.inputs.collect {} }
        advanceUntilIdle()
        assertEquals(ContextCapSelection.FOLLOW, viewModel.inputs.value!!.picker().selected)

        // Choosing Custom writes the starting point immediately: with follow + global Auto, effective.B = surcharge line 200000
        assertEquals(200_000, viewModel.inputs.value!!.picker().customStart)
        viewModel.selectCustom()
        advanceUntilIdle()
        assertEquals(ContextBudgetCap.Custom(200_000), viewModel.inputs.value!!.conversationCap)

        // An option is written immediately
        viewModel.select(ContextBudgetCap.Unlimited)
        advanceUntilIdle()
        assertEquals(ContextBudgetCap.Unlimited, viewModel.inputs.value!!.conversationCap)
        assertEquals(ContextCapSelection.UNLIMITED, viewModel.inputs.value!!.picker().selected)
        // Unlimited: B = U > T, the label under the ring shows the distance to the surcharge line; with unknown used no distance is shown
        assertEquals(ContextCapWindowLine.ABOVE_LINE, viewModel.inputs.value!!.panel(used = 1_000).windowLine)
        assertEquals(199_000, viewModel.inputs.value!!.panel(used = 1_000).priceLineDistance)
        assertEquals(null, viewModel.inputs.value!!.panel(used = null).priceLineDistance)

        // Follow writes null
        viewModel.select(null)
        advanceUntilIdle()
        assertEquals(null, viewModel.inputs.value!!.conversationCap)
        assertEquals(ContextCapSelection.FOLLOW, viewModel.inputs.value!!.picker().selected)

        // Input submit
        val committed = viewModel.commitCustom("190000")
        advanceUntilIdle()
        assertEquals(listOf<Any?>(190_000, false, false), listOf<Any?>(committed?.value, committed?.adjusted, committed?.restored))
        assertEquals(ContextBudgetCap.Custom(190_000), viewModel.inputs.value!!.conversationCap)
        val picker = viewModel.inputs.value!!.picker()
        assertEquals(ContextCapSelection.CUSTOM, picker.selected)
        assertEquals(190_000, picker.customStart)

        // A slider tap without dragging (index unchanged) writes nothing: the nearest tick to 190000 is the surcharge line 200000, and it must not be rewritten by snapping
        assertEquals(picker.priceLineTickIndex, picker.sliderIndex)
        viewModel.releaseSlider(pressedIndex = picker.sliderIndex, index = picker.sliderIndex)
        advanceUntilIdle()
        assertEquals(ContextBudgetCap.Custom(190_000), viewModel.inputs.value!!.conversationCap)

        // Writes only when released on the next tick
        viewModel.releaseSlider(pressedIndex = picker.sliderIndex, index = picker.sliderIndex + 1)
        advanceUntilIdle()
        assertEquals(ContextBudgetCap.Custom(256_000), viewModel.inputs.value!!.conversationCap)

        // Cannot parse: no write
        val restored = viewModel.commitCustom("abc")
        advanceUntilIdle()
        assertEquals(true, restored?.restored)
        assertEquals(
            listOf(
                ContextBudgetCap.Custom(200_000),
                ContextBudgetCap.Unlimited,
                null,
                ContextBudgetCap.Custom(190_000),
                ContextBudgetCap.Custom(256_000),
            ),
            writes,
        )
        collector.cancel()
    }

    @Test
    fun cap_strings_present_in_16_locales() {
        assertEquals(16, LOCALE_DIRS.size)
        val missing = mutableListOf<String>()
        LOCALE_DIRS.forEach { dir ->
            val res = strings(dir)
            CAP_STRING_KEYS.forEach { (key, placeholders) ->
                val text = res[key]
                when {
                    text.isNullOrBlank() -> missing += "$dir:$key"
                    (1..placeholders).any { "%$it\$s" !in text } -> missing += "$dir:$key(placeholder)"
                    "{" in text -> missing += "$dir:$key(raw placeholder)"
                }
            }
        }
        assertEquals(emptyList<String>(), missing)
        // Existing key reworded: restore the sentence-boundary sentence
        assertTrue(strings("values").getValue("settings_context_mode_fallback_hint").endsWith("any cut ends at a sentence boundary."))
        assertTrue(strings("values-zh-rCN").getValue("settings_context_mode_fallback_hint").endsWith("\u622a\u65ad\u5904\u505c\u5728\u53e5\u5b50\u7ed3\u5c3e\u3002"))
    }

    private fun windowInput(input: JsonObject): ContextWindowInput = ContextWindowInput(
        W = input.intOrNull("W"),
        windowKind = ContextWindowKind.fromWire(input.stringOrNull("windowKind")!!),
        maxOutput = ContextMaxOutput(model = input.objOrNull("maxOutput")?.intOrNull("model")),
        priceLineTokens = input.intOrNull("priceLineTokens"),
    )

    /** Raw fixture values go through production ContextBudgetCap.parse; JSON null = follow (null). */
    private fun cap(el: JsonElement?): ContextBudgetCap? {
        if (el == null || el is JsonNull) return null
        val p = el as JsonPrimitive
        val raw: Any = when {
            p.isString -> p.content
            p.content.contains('.') || p.content.contains('e', ignoreCase = true) -> p.content.toDouble()
            else -> p.content.toLong()
        }
        return ContextBudgetCap.parse(raw)
    }

    private fun pricing(json: JsonObject): ContextCapPricing {
        fun side(group: String, key: String): Double? =
            json.objOrNull(group)?.stringOrNull(key)?.toDouble()
        return ContextCapPricing(
            basePrompt = side("base", "prompt"),
            baseCompletion = side("base", "completion"),
            longPrompt = side("long", "prompt"),
            longCompletion = side("long", "completion"),
        )
    }

    private fun budgetJson(json: JsonObject): List<Any?> = listOf(json.intOrNull("B"), json.stringOrNull("limitedBy"))

    private fun pickerJson(e: JsonObject): List<Any?> = listOf(
        e.stringOrNull("selected"),
        budgetJson(e["effective"]!!.jsonObject),
        budgetJson(e["auto"]!!.jsonObject),
        budgetJson(e["unlimited"]!!.jsonObject),
        e["ticks"]!!.jsonArray.map { it.jsonPrimitive.content.toInt() },
        e.intOrNull("customStart"),
        e.intOrNull("sliderIndex"),
        e.intOrNull("priceLineTickIndex"),
        e["unlimitedCrossesPriceLine"]!!.jsonPrimitive.content.toBooleanStrict(),
        e["customHint"]!!.jsonObject.let { listOf(it.stringOrNull("kind"), it.intOrNull("gap")) },
    )

    private fun pickerOf(p: ContextCapPicker): List<Any?> = listOf(
        p.selected.wire,
        listOf(p.effective.B, p.effective.limitedBy?.wire),
        listOf(p.auto.B, p.auto.limitedBy?.wire),
        listOf(p.unlimited.B, p.unlimited.limitedBy?.wire),
        p.ticks,
        p.customStart,
        p.sliderIndex,
        p.priceLineTickIndex,
        p.unlimitedCrossesPriceLine,
        listOf(p.customHint.kind.wire, p.customHint.gap),
    )

    private fun panelJson(e: JsonObject): List<Any?> = listOf(
        e.intOrNull("capValue"),
        e["limitedByModel"]!!.jsonPrimitive.content.toBooleanStrict(),
        e.intOrNull("actual"),
        e.stringOrNull("windowLine"),
        e.intOrNull("priceLineDistance"),
        e.objOrNull("multiplier")?.let { listOf(it.intOrNull("input"), it.intOrNull("output")) },
    )

    private fun panelOf(p: ContextCapPanel): List<Any?> = listOf(
        p.capValue,
        p.limitedByModel,
        p.actual,
        p.windowLine.wire,
        p.priceLineDistance,
        p.multiplier?.let { listOf(it.inputTenths, it.outputTenths) },
    )

    private fun strings(dir: String): Map<String, String> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(File("src/main/res/$dir/strings.xml"))
        val nodes = doc.getElementsByTagName("string")
        return (0 until nodes.length).map { nodes.item(it) as Element }
            .associate { it.getAttribute("name") to it.textContent.replace("\\'", "'").replace("\\\"", "\"") }
    }

    private class FakePreferenceDao : PreferenceDao {
        private val values = linkedMapOf<String, MutableStateFlow<String?>>()

        override fun observe(key: String): Flow<String?> =
            values.getOrPut(key) { MutableStateFlow(null) }

        override suspend fun get(key: String): String? = values[key]?.value

        override suspend fun set(entity: PreferenceEntity) {
            values.getOrPut(entity.key) { MutableStateFlow(null) }.value = entity.value
        }

        override suspend fun delete(key: String) {
            values.getOrPut(key) { MutableStateFlow(null) }.value = null
        }
    }

    private companion object {
        val LOCALE_DIRS = listOf(
            "values", "values-ar", "values-de", "values-es", "values-fr", "values-hi", "values-in",
            "values-ja", "values-ko", "values-pt-rBR", "values-ru", "values-th", "values-tr",
            "values-vi", "values-zh-rCN", "values-zh-rTW",
        )

        /** Key -> number of placeholders (%1$s...). The settings group plus the option and input keys used by the settings page. */
        val CAP_STRING_KEYS = listOf(
            "settings_context_cap_header" to 0,
            "settings_context_hero_label" to 0,
            "settings_context_hero_caption_auto" to 0,
            "settings_context_hero_caption_unlimited" to 0,
            "settings_context_hero_caption_custom" to 0,
            "settings_context_hero_full_window" to 0,
            "settings_context_scale_price_line" to 0,
            "settings_context_scale_window" to 0,
            "settings_context_cost_none" to 0,
            "settings_context_cost_extra" to 0,
            "settings_context_custom_min" to 1,
            "settings_context_per_chat" to 0,
            "settings_context_row_value" to 2,
            "settings_context_mode_fallback_hint" to 0,
            "context_cap_auto" to 0,
            "context_cap_unlimited" to 0,
            "context_cap_custom" to 0,
            "context_cap_input_label" to 0,
            "context_cap_input_unit" to 0,
            "context_cap_input_echo" to 1,
            "context_cap_adjusted" to 1,
            // Panel: this conversation's cap row, window row, multiplier sentence and the ring surcharge line
            "context_cap_title" to 0,
            "context_cap_row_limited" to 1,
            "context_cap_window_line" to 1,
            "context_cap_window_line_price" to 3,
            "context_cap_window_line_price_plain" to 2,
            "context_cap_above_line" to 1,
            "context_cap_mult_both" to 1,
            "context_cap_mult_input" to 1,
            "context_cap_mult_output" to 1,
            "context_cap_mult_split" to 2,
            "context_usage_legend_price_line" to 0,
            "context_usage_measured_price_line" to 1,
            "context_usage_estimated_price_line" to 1,
            "context_usage_measured_price_line_crossed" to 0,
            "context_usage_estimated_price_line_crossed" to 0,
            // Selection page: follow, header row, option descriptions, ticks, custom hint, footnote and screen reader
            "context_cap_follow" to 0,
            "context_cap_follow_hint" to 1,
            "context_cap_head" to 3,
            "context_cap_head_price_line" to 2,
            "context_cap_head_unknown" to 1,
            "context_cap_auto_hint_price_line" to 1,
            "context_cap_auto_hint_default" to 2,
            "context_cap_auto_hint_default_below_line" to 2,
            "context_cap_auto_hint_window" to 1,
            "context_cap_hint_window_unknown" to 0,
            "context_cap_unlimited_hint" to 1,
            "context_cap_unlimited_hint_price_line" to 2,
            "context_cap_price_line_tick" to 1,
            "context_cap_custom_over" to 2,
            "context_cap_custom_over_plain" to 1,
            "context_cap_custom_at" to 0,
            "context_cap_custom_under" to 1,
            "context_cap_footer" to 0,
            "context_cap_slider_a11y" to 1,
        )

        const val GROK_MODEL_ID = "grok-4.7"
        val GROK_PROVIDER = Provider(
            id = "grok-1",
            kind = ProviderKind.Grok,
            apiKey = "byok-key",
            models = listOf(AIModel(id = GROK_MODEL_ID, name = "Grok 4.7", contextLength = 2_000_000)),
        )
        val GROK_CONVERSATION = Conversation(
            id = "conversation-cap-panel",
            title = "Cap panel",
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
