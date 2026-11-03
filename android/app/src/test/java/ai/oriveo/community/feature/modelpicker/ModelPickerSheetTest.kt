package ai.oriveo.community.feature.modelpicker

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceDisclosureStore
import ai.oriveo.community.core.voice.VoiceOption
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceTransport
import ai.oriveo.community.testing.TestSharedPreferences
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelPickerSheetTest {

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun `retired models are hidden while missing and unloaded catalog models stay visible`() {
        MetadataTestFixtures.applyRaw(RETIREMENT_CATALOG)
        val provider = retirementProvider()

        val homeIds = buildProviderSections(ModelPickerContext.Home, listOf(provider), null, null, "")
            .single().models.map { it.id }
        assertEquals(setOf("gpt-next", "gpt-vanished"), homeIds.toSet())

        val chatIds = buildProviderSections(ModelPickerContext.Chat, listOf(provider), "provider-openai", null, "")
            .single().models.map { it.id }
        assertEquals(setOf("gpt-next", "gpt-vanished"), chatIds.toSet())

        MetadataTestFixtures.clear()
        val unloadedIds = buildProviderSections(ModelPickerContext.Home, listOf(provider), null, null, "")
            .single().models.map { it.id }
        assertEquals(setOf("gpt-legacy", "gpt-old", "gpt-next", "gpt-vanished"), unloadedIds.toSet())
    }

    // ---- Group headers and the home header counts include realtime rows ----

    private fun headerCounts(entries: List<ModelPickerListEntry>): Map<String, Int> =
        entries.mapNotNull { entry ->
            (entry.content as? ModelPickerListContent.ProviderHeader)?.let { it.provider.id to it.modelCount }
        }.toMap()

    private fun homeResult(
        providers: List<Provider>,
        searchText: String = "",
        realtimeFilterSelected: Boolean = false,
    ): ModelPickerSectionsResult = buildModelPickerSectionsResult(
        context = ModelPickerContext.Home,
        providers = providers,
        activeProviderId = null,
        currentModel = null,
        searchText = searchText,
        selectedCapabilityFilters = emptySet(),
        realtimeCatalog = REALTIME_CATALOG,
        realtimeFilterSelected = realtimeFilterSelected,
    )

    private fun anthropicProvider() = Provider(
        id = "anthropic",
        kind = ProviderKind.Anthropic,
        models = listOf(AIModel(id = "claude-sonnet-4", name = "Claude Sonnet 4", isAvailable = true)),
    )

    @Test
    fun provider_header_count_includes_realtime_rows() {
        val sections = homeResult(listOf(realtimeProvider("openai", ProviderKind.OpenAI))).providerSections
        val entries = buildModelPickerListEntries(
            providerSections = sections,
            searchText = "",
            expandedProviderIds = setOf("openai"),
            isSingleProvider = false,
            isHome = true,
        )
        val visibleRows = entries.count {
            it.content is ModelPickerListContent.ModelRow || it.content is ModelPickerListContent.RealtimeRow
        }
        assertEquals(4, visibleRows)
        assertEquals(mapOf("openai" to 4), headerCounts(entries))
    }

    @Test
    fun realtime_filter_header_counts_realtime_rows() {
        val sections = homeResult(
            listOf(realtimeProvider("openai", ProviderKind.OpenAI)),
            realtimeFilterSelected = true,
        ).providerSections
        assertTrue(sections.single().models.isEmpty())
        // Even when collapsed, "0 models" must not be shown
        val collapsed = buildModelPickerListEntries(
            providerSections = sections,
            searchText = "",
            expandedProviderIds = emptySet(),
            isSingleProvider = false,
            isHome = true,
        )
        assertEquals(mapOf("openai" to 3), headerCounts(collapsed))
    }

    @Test
    fun home_header_total_includes_realtime_rows() {
        val sections = homeResult(
            listOf(realtimeProvider("openai", ProviderKind.OpenAI), realtimeProvider("openai-2", ProviderKind.OpenAI)),
        ).providerSections
        val entries = buildModelPickerListEntries(
            providerSections = sections,
            searchText = "",
            expandedProviderIds = emptySet(),
            isSingleProvider = false,
            isHome = true,
        )
        val counts = modelPickerHomeHeaderCounts(sections)
        assertEquals(ModelPickerHomeHeaderCounts(providerCount = 2, modelCount = 8), counts)
        assertEquals(headerCounts(entries).values.sum(), counts.modelCount)
    }

    @Test
    fun home_header_provider_count_after_filter() {
        val providers = listOf(realtimeProvider("openai", ProviderKind.OpenAI), anthropicProvider())
        assertEquals(
            "Precondition: both groups are present when unfiltered",
            ModelPickerHomeHeaderCounts(providerCount = 2, modelCount = 5),
            modelPickerHomeHeaderCounts(homeResult(providers).providerSections),
        )
        // Search filters out the whole Anthropic group: the provider count and the model count come from the same group set
        assertEquals(
            ModelPickerHomeHeaderCounts(providerCount = 1, modelCount = 4),
            modelPickerHomeHeaderCounts(homeResult(providers, searchText = "gpt").providerSections),
        )
        // The realtime filter keeps only realtime rows: Anthropic does not count, OpenAI counts only its 3 realtime rows
        assertEquals(
            ModelPickerHomeHeaderCounts(providerCount = 1, modelCount = 3),
            modelPickerHomeHeaderCounts(homeResult(providers, realtimeFilterSelected = true).providerSections),
        )
    }

    @Test
    fun realtime_filter_chip_shows_realtime_row_count() {
        val source = File("src/main/java/ai/oriveo/community/feature/modelpicker/ModelPickerSheet.kt").readText()
        val chipSource = source.requiredSlice(
            from = "private fun ModelPickerRealtimeFilterChip(",
            to = "maxLines = 1,",
        )
        // Like the capability chips, carries a hit count: "realtime voice N"
        assertTrue(chipSource.contains("count: Int"))
        assertTrue(chipSource.contains("stringResource(R.string.voice_realtime_filter_count, count)"))
        assertFalse(chipSource.contains("R.string.voice_realtime_model_tag"))
        // N comes from realtimeFilterCount of the same grouping computation
        assertTrue(source.contains("realtimeFilterCount = sectionsResult?.realtimeFilterCount ?: 0"))
        assertTrue(source.contains("count = realtimeCount,"))
    }

    /** Tapping a realtime row collapses the picker; if not accepted, collapse first and then hand off to the page to show the disclosure; select only once accepted; if already accepted, select first and then collapse. */
    @Test
    fun pickerDismissesAfterRealtimeAgree() {
        val store = VoiceDisclosureStore { TestSharedPreferences() }
        val events = mutableListOf<String>()
        val select: (String, String) -> Unit = { providerId, modelId -> events += "select:$providerId/$modelId" }
        var requested: RealtimePickerDisclosure? = null

        pickRealtimeModelAndDismiss(
            providerId = "openai",
            providerKind = ProviderKind.OpenAI,
            modelId = "gpt-realtime-2",
            store = store,
            select = select,
            dismiss = { events += "dismiss" },
            requestDisclosure = { events += "request:${it.modelId}"; requested = it },
        )
        assertEquals(listOf("dismiss", "request:gpt-realtime-2"), events)

        // On the page, tapping accept: record acceptance, then select
        acceptRealtimeDisclosure(requested!!, store, select)
        assertEquals(listOf("dismiss", "request:gpt-realtime-2", "select:openai/gpt-realtime-2"), events)
        assertTrue(store.isAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime))

        // Already accepted: select and collapse directly, without requesting the disclosure again
        events.clear()
        pickRealtimeModelAndDismiss(
            providerId = "openai",
            providerKind = ProviderKind.OpenAI,
            modelId = "gpt-realtime-mini",
            store = store,
            select = select,
            dismiss = { events += "dismiss" },
            requestDisclosure = { events += "request:${it.modelId}" },
        )
        assertEquals(listOf("select:openai/gpt-realtime-mini", "dismiss"), events)

        // The disclosure is not inside the picker; the home / chat page holds it and shows it
        val pickerSource = File("src/main/java/ai/oriveo/community/feature/modelpicker/ModelPickerSheet.kt").readText()
        val realtimeRowSelection = pickerSource.requiredSlice(
            from = "onSelectRealtimeModel = { provider, entry ->",
            to = "isRealtimeModelSelected =",
        )
        assertTrue(realtimeRowSelection.contains("pickRealtimeModelAndDismiss("))
        assertTrue(realtimeRowSelection.contains("dismiss = onDismiss"))
        assertTrue(realtimeRowSelection.contains("requestDisclosure = onRequestRealtimeDisclosure"))
        assertFalse(pickerSource.contains("VoiceDisclosureSheet("))
        assertFalse(pickerSource.contains("pendingRealtimeDisclosure"))
        for (path in listOf(
            "src/main/java/ai/oriveo/community/feature/home/HomeScreen.kt",
            "src/main/java/ai/oriveo/community/feature/chat/ChatScreenContent.kt",
        )) {
            val pageSource = File(path).readText()
            assertTrue(path, pageSource.contains("onRequestRealtimeDisclosure = { pendingRealtimeDisclosure = it }"))
            val agree = pageSource.requiredSlice(from = "VoiceDisclosureSheet(", to = "onDecline =")
            assertTrue(path, agree.contains("acceptRealtimeDisclosure(pending, realtimeDisclosureStore,"))
        }
    }

    /** After collapse, the page disclosure is dismissed with "Not now" or a swipe down: do not select, do not record consent, keep the original model. */
    @Test
    fun pickerDismissesThenDeclinedDisclosureKeepsPreviousModel() {
        val store = VoiceDisclosureStore { TestSharedPreferences() }
        val events = mutableListOf<String>()

        pickRealtimeModelAndDismiss(
            providerId = "gemini",
            providerKind = ProviderKind.Gemini,
            modelId = "gemini-live",
            store = store,
            select = { providerId, modelId -> events += "select:$providerId/$modelId" },
            dismiss = { events += "dismiss" },
            requestDisclosure = { events += "request:${it.modelId}" },
        )

        assertEquals(listOf("dismiss", "request:gemini-live"), events)
        assertFalse(store.isAccepted(ProviderKind.Gemini, VoiceDirection.Realtime))
        for (path in listOf(
            "src/main/java/ai/oriveo/community/feature/home/HomeScreen.kt",
            "src/main/java/ai/oriveo/community/feature/chat/ChatScreenContent.kt",
        )) {
            val decline = File(path).readText().requiredSlice(from = "VoiceDisclosureSheet(", to = "\n        )\n")
                .substringAfter("onDecline =")
            assertTrue(path, decline.contains("pendingRealtimeDisclosure = null"))
            assertFalse(path, decline.contains("acceptRealtimeDisclosure"))
            assertFalse(path, decline.contains("select"))
        }
    }

    @Test
    fun `chat keeps the current conversation model even when retired`() {
        MetadataTestFixtures.applyRaw(RETIREMENT_CATALOG)
        val provider = retirementProvider()
        val current = provider.models.first { it.id == "gpt-legacy" }

        val chatIds = buildProviderSections(ModelPickerContext.Chat, listOf(provider), "provider-openai", current, "")
            .single().models.map { it.id }

        assertTrue("gpt-legacy" in chatIds)
        assertFalse("gpt-old" in chatIds)
    }

    private fun retirementProvider(): Provider {
        val models = listOf("gpt-legacy", "gpt-old", "gpt-next", "gpt-vanished")
            .map { AIModel(id = it, name = it, isAvailable = true) }
        return Provider(id = "provider-openai", kind = ProviderKind.OpenAI, models = models, catalogModels = models)
    }

    private val RETIREMENT_CATALOG = """
        {
          "version": 1,
          "contractVersion": 1,
          "providers": {
            "openAI": {
              "defaultModelId": "gpt-next",
              "retiredModels": [
                { "id": "gpt-legacy", "displayName": "GPT Legacy", "retiredAt": "2026-07-24T00:00:00Z", "routedTo": "gpt-next" }
              ],
              "resolveMap": { "gpt-next": "gpt-next", "gpt-old": "gpt-old" },
              "models": {
                "gpt-next": { "canonicalModelId": "gpt-next", "displayName": "GPT Next" },
                "gpt-old": { "canonicalModelId": "gpt-old", "displayName": "GPT Old", "lifecycle": { "state": "deprecated", "shutdownAt": "2026-01-01" } }
              }
            }
          }
        }
    """.trimIndent()

    @Test
    fun `model picker sections hide models with unsupported metadata transport`() {
        MetadataTestFixtures.applyRaw(
            """
            {
              "version": 1,
              "providers": {
                "openAI": {
                  "defaultModelId": "gpt-known",
                  "resolveMap": {
                    "gpt-known": "gpt-known",
                    "gpt-future": "gpt-future"
                  },
                  "models": {
                    "gpt-known": {
                      "canonicalModelId": "gpt-known",
                      "displayName": "GPT Known",
                      "capabilities": ["text"],
                      "transport": "openai_chat"
                    },
                    "gpt-future": {
                      "canonicalModelId": "gpt-future",
                      "displayName": "GPT Future",
                      "capabilities": ["text"],
                      "transport": "future_kind_v99"
                    }
                  }
                }
              }
            }
            """.trimIndent(),
        )
        val provider = Provider(
            id = "openai",
            kind = ProviderKind.OpenAI,
            models = listOf(
                AIModel(id = "gpt-known", name = "GPT Known"),
                AIModel(id = "gpt-future", name = "GPT Future"),
            ),
        )

        val modelIds = buildProviderSections(
            context = ModelPickerContext.Home,
            providers = listOf(provider),
            currentProviderId = null,
            currentModel = null,
            searchText = "",
        ).single().models.map { it.id }

        assertEquals(listOf("gpt-known"), modelIds)
    }

    @Test
    fun `chat header current model uses two lines`() {
        val source = File("src/main/java/ai/oriveo/community/feature/modelpicker/ModelPickerSheet.kt").readText()
        val headerSource = source.requiredSlice(
            from = "private fun ChatHeader(",
            to = "private fun SearchBar(",
        )
        val currentModelSource = headerSource.requiredSlice(
            from = "R.string.current_model_subtitle",
            to = "                )\n            } else",
        )

        assertTrue(currentModelSource.contains("maxLines = 2"))
    }

    @Test
    fun `home and chat model selection leave dismissal to the picker`() {
        val homeSource = File("src/main/java/ai/oriveo/community/feature/home/HomeScreen.kt").readText()
        val chatSource = File("src/main/java/ai/oriveo/community/feature/chat/ChatScreenContent.kt").readText()
        val homeSelection = homeSource.requiredSlice(
            from = "onModelSelected = { providerId, modelId ->",
            to = "onEnableModel =",
        )
        val chatSelection = chatSource.requiredSlice(
            from = "onModelSelected = { providerId, modelId ->",
            to = "onDismiss =",
        )

        assertTrue(homeSelection.contains("viewModel.setActiveModel(providerId, modelId)"))
        assertFalse(homeSelection.contains("showModelPicker = false"))
        assertTrue(chatSelection.contains("viewModel.selectModel(providerId, modelId)"))
        assertFalse(chatSelection.contains("showModelSwitcher = false"))
    }

    /**
     * Moving the chain to a background thread only works because it is a pure function whose output is
     * decided by its arguments. This recomputes the grouping, counting and filtering steps by hand to
     * show the aggregate function does not change any of the three.
     */
    @Test
    fun `sections result equals the step by step chain`() {
        val providers = pickerFixtureProviders()

        val expectedUnfiltered = buildProviderSections(
            context = ModelPickerContext.Home,
            providers = providers,
            currentProviderId = "openai",
            currentModel = null,
            searchText = "gpt",
        )
        val expected = ModelPickerSectionsResult(
            providerSections = applyModelPickerCapabilityFilter(
                expectedUnfiltered,
                emptySet(),
            ),
            capabilityFilterCounts = modelPickerCapabilityFilterCounts(expectedUnfiltered),
        )

        val actual = buildModelPickerSectionsResult(
            context = ModelPickerContext.Home,
            providers = providers,
            activeProviderId = "openai",
            currentModel = null,
            searchText = "gpt",
            selectedCapabilityFilters = emptySet(),
        )

        assertEquals(expected, actual)
    }

    /**
     * The fix for the long main-thread frame is running this chain on Dispatchers.Default, which is
     * only an equivalent change if switching threads does not switch results. Run the same input on
     * the calling thread and on the default dispatcher and require identical output.
     */
    @Test
    fun `sections result is identical when computed on the default dispatcher`() = runBlocking {
        val providers = pickerFixtureProviders()

        fun compute() = buildModelPickerSectionsResult(
            context = ModelPickerContext.Chat,
            providers = providers,
            activeProviderId = "openai",
            currentModel = null,
            searchText = "",
            selectedCapabilityFilters = emptySet(),
        )

        val onCallerThread = compute()
        val onDefaultDispatcher = withContext(Dispatchers.Default) { compute() }

        assertEquals(onCallerThread, onDefaultDispatcher)
        assertEquals(
            onCallerThread.providerSections.flatMap { section -> section.models.map { it.id } },
            onDefaultDispatcher.providerSections.flatMap { section -> section.models.map { it.id } },
        )
    }

    /**
     * The real regression surface is whether the sheet keeps the chain on the main thread: Compose's
     * `remember {}` is synchronous, so leaving it there puts the whole cost back into one frame. This
     * pins the chain inside `withContext(Dispatchers.Default)` and pins that nothing is drawn for the
     * empty state before the first result arrives, since an empty state would tell the user there are
     * no models when the list is merely not computed yet.
     */
    @Test
    fun `model picker precomputation stays off the main thread`() {
        val source = File("src/main/java/ai/oriveo/community/feature/modelpicker/ModelPickerSheet.kt").readText()
        val sheetSource = source.requiredSlice(
            from = "fun ModelPickerSheet(",
            to = "private fun ColumnScope.ModelPickerContent(",
        )

        assertTrue(sheetSource.contains("produceState<ModelPickerSectionsResult?>("))
        assertTrue(sheetSource.contains("withContext(Dispatchers.Default)"))
        assertTrue(sheetSource.contains("buildModelPickerSectionsResult("))
        // Neither of the two heavy steps may appear in the sheet's synchronous composition again.
        assertFalse(sheetSource.contains("modelPickerCapabilityFilterCounts("))
        assertFalse(sheetSource.contains("applyModelPickerCapabilityFilter("))
        // While computing, draw nothing: no empty state and no fake zero.
        assertTrue(sheetSource.contains("isComputing = sectionsResult == null,"))

        val contentSource = source.requiredSlice(
            from = "private fun ColumnScope.ModelPickerContent(",
            to = "internal fun buildModelPickerListEntries(",
        )
        assertTrue(contentSource.contains("if (isComputing) {"))
        assertTrue(contentSource.contains("capabilityFilterCounts: Map<ModelPickerCapabilityFilterKind, Int>?,"))
    }

    // ---- Realtime voice rows ----

    @Test
    fun `chat and home list realtime rows after text models default first then catalog order`() {
        val openai = realtimeProvider("openai", ProviderKind.OpenAI)
        listOf(ModelPickerContext.Chat, ModelPickerContext.Home).forEach { context ->
            val section = buildProviderSections(context, listOf(openai), "openai", null, "", REALTIME_CATALOG).single()
            assertEquals("$context", listOf("gpt-4o"), section.models.map { it.id })
            assertEquals(
                "$context",
                listOf("gpt-realtime-2", "gpt-realtime-mini", "gpt-realtime-1.5"),
                section.realtimeModels.map { it.model },
            )
            val entries = buildModelPickerListEntries(
                providerSections = listOf(section),
                searchText = "",
                expandedProviderIds = setOf("openai"),
                isSingleProvider = false,
                isHome = context == ModelPickerContext.Home,
            )
            val rowOrder = entries.mapNotNull { entry ->
                when (val content = entry.content) {
                    is ModelPickerListContent.ModelRow -> "text:${content.model.id}"
                    is ModelPickerListContent.RealtimeRow -> "realtime:${content.entry.model}"
                    else -> null
                }
            }
            assertEquals(
                listOf("text:gpt-4o", "realtime:gpt-realtime-2", "realtime:gpt-realtime-mini", "realtime:gpt-realtime-1.5"),
                rowOrder,
            )
        }
    }

    @Test
    fun `crosscheck relay and subscription connections list no realtime rows`() {
        val openai = realtimeProvider("openai", ProviderKind.OpenAI)
        val crosscheck = buildProviderSections(ModelPickerContext.Crosscheck, listOf(openai), "openai", null, "", REALTIME_CATALOG)
        assertTrue(crosscheck.all { it.realtimeModels.isEmpty() })

        val others = listOf(
            realtimeProvider("relay", ProviderKind.Relay),
            realtimeProvider("openai-sub", ProviderKind.OpenAI, ProviderAuthMode.Subscription),
        )
        listOf(ModelPickerContext.Chat, ModelPickerContext.Home).forEach { context ->
            val sections = buildProviderSections(context, others, null, null, "", REALTIME_CATALOG)
            assertTrue("$context", sections.all { it.realtimeModels.isEmpty() })
        }
        val result = buildModelPickerSectionsResult(
            context = ModelPickerContext.Chat,
            providers = others,
            activeProviderId = null,
            currentModel = null,
            searchText = "",
            selectedCapabilityFilters = emptySet(),
            realtimeCatalog = REALTIME_CATALOG,
        )
        assertFalse(result.showsRealtimeFilter)
    }

    @Test
    fun `realtime row is checked by provider id and catalog model`() {
        assertTrue(isModelSelected(activeProviderId = "openai", activeModelId = "gpt-realtime-2", providerId = "openai", realtimeModelId = "gpt-realtime-2"))
        assertFalse(isModelSelected(activeProviderId = "openai-2", activeModelId = "gpt-realtime-2", providerId = "openai", realtimeModelId = "gpt-realtime-2"))
        assertFalse(isModelSelected(activeProviderId = "openai", activeModelId = "gpt-4o", providerId = "openai", realtimeModelId = "gpt-realtime-2"))
    }

    @Test
    fun realtime_selected_unticks_text_rows() {
        val text = AIModel(id = "gpt-4o", name = "GPT-4o", isDefault = true)
        val provider = Provider(id = "openai", kind = ProviderKind.OpenAI, apiKey = "k", models = listOf(text))
        val catalog = VoiceCatalog(
            schemaVersion = 2,
            providers = mapOf(
                ProviderKind.OpenAI to VoiceProviderCatalog(
                    realtime = listOf(
                        VoiceRealtimeEntry(
                            model = "gpt-realtime-2",
                            transport = VoiceTransport.OpenAIRealtime,
                            path = "/v1/realtime",
                            contextWindow = 32_000,
                            voices = listOf(VoiceOption("marin", isDefault = true)),
                            isDefault = true,
                        ),
                    ),
                ),
            ),
        )
        fun textTicked(selectedRealtime: String?) = isModelSelected(
            context = ModelPickerContext.Chat,
            selectedRealtimeModelId = selectedRealtime,
            activeProviderId = "openai",
            activeModelId = "gpt-realtime-2",
            // Writing back the stored value falls through to a text row (for example falling back to the default): when realtime is selected it must not also be checked
            currentModelId = text.id,
            providerId = "openai",
            providerKind = ProviderKind.OpenAI,
            model = text,
        )
        // Realtime selected: only the realtime row is checked
        val selected = modelPickerSelectedRealtimeModel(ModelPickerContext.Chat, provider, "gpt-realtime-2", catalog)
        assertEquals("gpt-realtime-2", selected)
        assertFalse(textTicked(selected))
        // Catalog not ready / cross-check does not list realtime rows: judge by text rows
        assertNull(modelPickerSelectedRealtimeModel(ModelPickerContext.Chat, provider, "gpt-realtime-2", null))
        assertNull(modelPickerSelectedRealtimeModel(ModelPickerContext.Crosscheck, provider, "gpt-realtime-2", catalog))
        assertTrue(textTicked(null))
        // Text model selected: not a realtime row
        assertNull(modelPickerSelectedRealtimeModel(ModelPickerContext.Chat, provider, text.id, catalog))
        // Another connection: not a realtime row
        assertNull(modelPickerSelectedRealtimeModel(ModelPickerContext.Chat, null, "gpt-realtime-2", catalog))
    }

    @Test
    fun `realtime row is 64dp without capability badges or price`() {
        val source = File("src/main/java/ai/oriveo/community/feature/modelpicker/ModelPickerSheet.kt").readText()
        val rowSource = source.requiredSlice(
            from = "internal fun ModelPickerRealtimeRow(",
            to = "private fun ModelPickerRealtimeFilterChip(",
        )
        assertTrue(rowSource.contains(".heightIn(min = 64.dp)"))
        assertTrue(rowSource.contains(".size(36.dp)"))
        assertTrue(rowSource.contains("Icons.Rounded.GraphicEq"))
        assertTrue(rowSource.contains("text = modelIdDisplay(entry.model)"))
        // Inline subtitle; the "realtime voice" tag appears only on the filter capsule, with no badge at the end of the row
        assertTrue(rowSource.contains("R.string.voice_realtime_model_subtitle"))
        assertFalse(rowSource.contains("R.string.voice_realtime_model_tag"))
        assertTrue(rowSource.contains("fontSize = 16.sp"))
        assertTrue(rowSource.contains("fontSize = 13.sp"))
        assertFalse(rowSource.contains("FixedHeroModelCapabilityStrip("))
        assertFalse(rowSource.contains("ModelPickerPriceRow("))
    }

    @Test
    fun realtime_row_uses_text_row_checkmark() {
        val source = File("src/main/java/ai/oriveo/community/feature/modelpicker/ModelPickerSheet.kt").readText()
        val rowSource = source.requiredSlice(
            from = "internal fun ModelPickerRealtimeRow(",
            to = "private fun ModelPickerRealtimeFilterChip(",
        )
        // Same as text rows: a 17dp CheckCircle inside an 18dp slot, primary color (overturns the 24dp brand-gradient circle with a white check)
        assertTrue(rowSource.contains("Icons.Filled.CheckCircle"))
        assertTrue(rowSource.contains("Modifier.size(18.dp)"))
        assertTrue(rowSource.contains("Modifier.size(17.dp)"))
        assertTrue(rowSource.contains("tint = v2.primary"))
        assertFalse(rowSource.contains("Icons.Filled.Check,"))
        assertFalse(rowSource.contains("gradientBrandStops"))
        assertFalse(rowSource.contains("CircleShape"))
    }

    @Test
    fun realtime_row_title_wraps_to_two_lines() {
        val source = File("src/main/java/ai/oriveo/community/feature/modelpicker/ModelPickerSheet.kt").readText()
        val rowSource = source.requiredSlice(
            from = "internal fun ModelPickerRealtimeRow(",
            to = "private fun ModelPickerRealtimeFilterChip(",
        )
        val titleSource = rowSource.requiredSlice(from = "text = modelIdDisplay(entry.model)", to = "R.string.voice_realtime_model_subtitle")
        assertTrue(titleSource.contains("maxLines = 2"))
        assertTrue(titleSource.contains("overflow = TextOverflow.Ellipsis"))
        assertTrue(rowSource.contains(".heightIn(min = 64.dp)"))
        assertFalse(rowSource.contains(".height(64.dp)"))
    }

    /** Tapping a text row = select and collapse, selecting first and then collapsing. */
    @Test
    fun pickerDismissesAfterSelectingTextRow() {
        val events = mutableListOf<String>()

        selectModelAndDismiss(
            providerId = "openai",
            modelId = "gpt-5",
            select = { providerId, modelId -> events += "select:$providerId/$modelId" },
            dismiss = { events += "dismiss" },
        )

        assertEquals(listOf("select:openai/gpt-5", "dismiss"), events)
        val source = File("src/main/java/ai/oriveo/community/feature/modelpicker/ModelPickerSheet.kt").readText()
        val textRowSelection = source.requiredSlice(
            from = "onSelectModel = { providerId, modelId ->",
            to = "onSelectRealtimeModel =",
        )
        assertTrue(textRowSelection.contains("selectModelAndDismiss("))
        assertTrue(textRowSelection.contains("dismiss = onDismiss"))
    }

    @Test
    fun `first realtime pick asks for disclosure and only agreeing selects it`() {
        val store = VoiceDisclosureStore { TestSharedPreferences() }
        val selected = mutableListOf<Pair<String, String>>()
        val select: (String, String) -> Unit = { providerId, modelId -> selected += providerId to modelId }

        // Rejected: do not switch, do not record consent
        val declined = pickRealtimeModel("openai", ProviderKind.OpenAI, "gpt-realtime-2", store, select)
        assertEquals(RealtimePickerDisclosure("openai", ProviderKind.OpenAI, "gpt-realtime-2"), declined)
        assertTrue(selected.isEmpty())
        assertFalse(store.isAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime))

        // Accepted: record consent first, then select
        val pending = pickRealtimeModel("openai", ProviderKind.OpenAI, "gpt-realtime-2", store, select)!!
        acceptRealtimeDisclosure(pending, store, select)
        assertTrue(store.isAccepted(ProviderKind.OpenAI, VoiceDirection.Realtime))
        assertEquals(listOf("openai" to "gpt-realtime-2"), selected)

        // The second time for the same provider, do not show again
        assertNull(pickRealtimeModel("openai", ProviderKind.OpenAI, "gpt-realtime-mini", store, select))
        assertEquals("openai" to "gpt-realtime-mini", selected.last())
        // Other providers still need the disclosure
        assertTrue(pickRealtimeModel("gemini", ProviderKind.Gemini, "gemini-live", store, select) != null)
    }

    /** Accepting the realtime disclosure in the picker also records the provider-level disclosure for that provider (the Samsung home_full_flow shot 07 shows "You are about to use Gemini"). */
    @Test
    fun `agreeing realtime disclosure in picker also records provider disclosure`() {
        val recorded = mutableListOf<ProviderKind>()
        val store = VoiceDisclosureStore(onRealtimeAccepted = { recorded += it }) { TestSharedPreferences() }
        val select: (String, String) -> Unit = { _, _ -> }

        val pending = pickRealtimeModel("gemini", ProviderKind.Gemini, "gemini-live", store, select)!!
        acceptRealtimeDisclosure(pending, store, select)
        assertEquals(listOf(ProviderKind.Gemini), recorded)

        // Only consent for the realtime direction counts as provider disclosure
        store.markAccepted(ProviderKind.OpenAI, VoiceDirection.Stt)
        assertEquals(listOf(ProviderKind.Gemini), recorded)
    }

    private fun realtimeProvider(
        id: String,
        kind: ProviderKind,
        authMode: ProviderAuthMode = ProviderAuthMode.ApiKey,
    ): Provider {
        val models = listOf(AIModel(id = "gpt-4o", name = "GPT-4o", isAvailable = true))
        return Provider(id = id, kind = kind, authMode = authMode, models = models, catalogModels = models)
    }

    private fun realtimeEntry(model: String, isDefault: Boolean = false) = VoiceRealtimeEntry(
        model = model,
        transport = VoiceTransport.OpenAIRealtime,
        path = "/v1/realtime",
        contextWindow = 128_000,
        voices = listOf(VoiceOption("marin", isDefault = true)),
        isDefault = isDefault,
    )

    private val REALTIME_CATALOG: VoiceCatalog by lazy {
        val realtime = VoiceProviderCatalog(
            realtime = listOf(
                realtimeEntry("gpt-realtime-mini"),
                realtimeEntry("gpt-realtime-2", isDefault = true),
                realtimeEntry("gpt-realtime-1.5"),
            ),
        )
        VoiceCatalog(
            providers = listOf(ProviderKind.OpenAI, ProviderKind.Relay)
                .associateWith { realtime },
        )
    }

    private fun pickerFixtureProviders(): List<Provider> = listOf(
        Provider(
            id = "openai",
            kind = ProviderKind.OpenAI,
            models = listOf(
                AIModel(id = "gpt-4o", name = "GPT-4o", isAvailable = true),
                AIModel(id = "gpt-4o-mini", name = "GPT-4o mini", isAvailable = true),
                AIModel(id = "o3", name = "o3", isAvailable = true),
            ),
        ),
        Provider(
            id = "anthropic",
            kind = ProviderKind.Anthropic,
            models = listOf(
                AIModel(id = "claude-sonnet", name = "Claude Sonnet", isAvailable = true),
            ),
        ),
    )
}

private fun String.requiredSlice(from: String, to: String): String {
    val start = indexOf(from)
    require(start >= 0) { "Missing source marker: $from" }
    val end = indexOf(to, start)
    require(end > start) { "Missing source marker: $to" }
    return substring(start, end)
}
