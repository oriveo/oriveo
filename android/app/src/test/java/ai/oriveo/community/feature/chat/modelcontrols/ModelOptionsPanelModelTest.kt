package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.R
import ai.oriveo.community.feature.chat.composer.ComposerAttachmentEntryModel
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.AttachmentInputGate
import ai.oriveo.community.core.capability.truth.InputCapabilityProjections
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.AdditionalBody
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.core.provider.CapabilityControlPresentationResolver
import ai.oriveo.community.core.provider.GenerationParameterOutboundContractTest
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.ConnectionCategory
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.CustomProtocol
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelOptionsPanelModelTest {
    @After
    fun clearGlobalMetadata() = MetadataTestFixtures.clear()

    private fun root(raw: String): JsonObject = Json.parseToJsonElement(raw).jsonObject

    // -- chat-template thinking switch of a custom connection --

    private fun written(body: AdditionalBody, enable: Boolean) =
        ChatTemplateThinking.write(body, enable) as ChatTemplateThinking.Write.Written

    @Test
    fun `state covers off on blocked and not sending`() {
        val s = ChatTemplateThinking::state
        assertEquals(ChatTemplateThinking.State.Off, s(AdditionalBody.Empty))
        assertEquals(ChatTemplateThinking.State.On, s(AdditionalBody("""{"chat_template_kwargs":{"enable_thinking":true}}""", true)))
        // true but sending is off and there are no other fields: off
        assertEquals(ChatTemplateThinking.State.Off, s(AdditionalBody("""{"chat_template_kwargs":{"enable_thinking":true}}""", false)))
        assertEquals(ChatTemplateThinking.State.Off, s(AdditionalBody("""{"chat_template_kwargs":{"enable_thinking":"true"}}""", true)))
        assertEquals(ChatTemplateThinking.State.Blocked, s(AdditionalBody("""{"chat_template_kwargs": {""", true)))
        assertEquals(ChatTemplateThinking.State.Blocked, s(AdditionalBody("""{"chat_template_kwargs": "on"}""", true)))
        assertEquals(ChatTemplateThinking.State.Blocked, s(AdditionalBody("""[1]""", true)))
        // Rejected by local validation (protected field)
        assertEquals(ChatTemplateThinking.State.Blocked, s(AdditionalBody("""{"model":"x"}""", true)))
        assertEquals(ChatTemplateThinking.State.NotSending, s(AdditionalBody("""{"min_p":0.05}""", false)))
        assertEquals(ChatTemplateThinking.State.NotSending, s(AdditionalBody("""{"chat_template_kwargs":{"enable_thinking":true,"x":1}}""", false)))
        assertEquals(ChatTemplateThinking.State.Off, s(AdditionalBody("""{"min_p":0.05}""", true)))
    }

    @Test
    fun `blocked and not sending replace the switch note`() {
        assertEquals(R.string.additional_body_switch_blocked_invalid,
            ModelOptionsRender.templateThinkingBlockedNoteRes(ChatTemplateThinking.State.Blocked))
        assertEquals(R.string.additional_body_switch_blocked_off,
            ModelOptionsRender.templateThinkingBlockedNoteRes(ChatTemplateThinking.State.NotSending))
        assertNull(ModelOptionsRender.templateThinkingBlockedNoteRes(ChatTemplateThinking.State.On))
        assertNull(ModelOptionsRender.templateThinkingBlockedNoteRes(ChatTemplateThinking.State.Off))
    }

    @Test
    fun `blocked and not sending writes nothing`() {
        listOf(
            AdditionalBody("""{"chat_template_kwargs": {""", true),
            AdditionalBody("""{"chat_template_kwargs": "on"}""", true),
            AdditionalBody("""{"min_p":0.05}""", false),
        ).forEach { body ->
            assertEquals(ChatTemplateThinking.Write.Unavailable, ChatTemplateThinking.write(body, true))
            assertEquals(ChatTemplateThinking.Write.Unavailable, ChatTemplateThinking.write(body, false))
        }
    }

    @Test
    fun `from blank writes the indented object and turns sending on`() {
        val on = written(AdditionalBody.Empty, true)
        assertEquals("{\n  \"chat_template_kwargs\": {\n    \"enable_thinking\": true\n  }\n}", on.body.rawJSON)
        assertTrue(on.body.sendWithRequest)
        val off = written(AdditionalBody("", sendWithRequest = false), false)
        assertEquals("{\n  \"chat_template_kwargs\": {\n    \"enable_thinking\": false\n  }\n}", off.body.rawJSON)
        assertTrue(off.body.sendWithRequest)
    }

    @Test
    fun `turning off writes false in place and keeps every other byte`() {
        val raw = "{\n    \"top_k\": 20,\n    \"chat_template_kwargs\": {\n        \"foo\": 1.50,\n        \"enable_thinking\":   true\n    },\n    \"stop\": [\"a\", \"b\"]\n}"
        val result = written(AdditionalBody(raw, sendWithRequest = true), false)
        assertEquals(raw.replace("\"enable_thinking\":   true", "\"enable_thinking\":   false"), result.body.rawJSON)
        assertTrue(result.body.sendWithRequest)
    }

    @Test
    fun `turning on inserts the flag with the surrounding indentation`() {
        // Sending off with only this field counts as off; turning it on also turns sending on
        val inKwargs = "{\n    \"chat_template_kwargs\": {\n        \"foo\": 1\n    }\n}"
        val r1 = written(AdditionalBody(inKwargs, sendWithRequest = true), true)
        assertEquals("{\n    \"chat_template_kwargs\": {\n        \"foo\": 1,\n        \"enable_thinking\": true\n    }\n}", r1.body.rawJSON)

        val noKwargs = "{\n  \"top_k\": 20,\n  \"stop\": [\"a\"]\n}"
        val r2 = written(AdditionalBody(noKwargs, sendWithRequest = true), true)
        assertEquals("{\n  \"top_k\": 20,\n  \"stop\": [\"a\"],\n  \"chat_template_kwargs\": {\n    \"enable_thinking\": true\n  }\n}", r2.body.rawJSON)

        val oneLine = """{"top_k": 20}"""
        val r3 = written(AdditionalBody(oneLine, sendWithRequest = true), true)
        assertEquals("""{"top_k": 20, "chat_template_kwargs": {"enable_thinking": true}}""", r3.body.rawJSON)

        val onlyFlagNotSending = AdditionalBody("""{"chat_template_kwargs":{"enable_thinking":false}}""", sendWithRequest = false)
        val r4 = written(onlyFlagNotSending, true)
        assertEquals("""{"chat_template_kwargs":{"enable_thinking":true}}""", r4.body.rawJSON)
        assertTrue(r4.body.sendWithRequest)
    }

    @Test
    fun `escaped key names fall back to the sorted indented format without losing content`() {
        val raw = """{"z": 1, "chat\u005ftemplate_kwargs": {"enable_thinking": false, "b": [1, 2]}, "a": {"y": 2, "x": 1}}"""
        val result = written(AdditionalBody(raw, sendWithRequest = true), true)
        assertEquals(
            "{\n  \"a\": {\n    \"x\": 1,\n    \"y\": 2\n  },\n  \"chat_template_kwargs\": {\n    \"b\": [\n      1,\n      2\n    ],\n" +
                "    \"enable_thinking\": true\n  },\n  \"z\": 1\n}",
            result.body.rawJSON,
        )
    }

    @Test
    fun `writes on top of the effective model default into the conversation layer`() {
        var raw: String? = null
        val store = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        // The model default carries other fields; the conversation layer has no record
        store.setAdditionalBody(AdditionalBody("{\n  \"min_p\": 0.05\n}", sendWithRequest = true), "p1", "m1", null)
        val effective = store.additionalBody("p1", "m1", "c1")
        assertEquals(ChatTemplateThinking.State.Off, ChatTemplateThinking.state(effective))
        store.setAdditionalBody(written(effective, true).body, "p1", "m1", "c1")
        val conversation = store.additionalBody("p1", "m1", "c1")
        assertEquals(ChatTemplateThinking.State.On, ChatTemplateThinking.state(conversation))
        assertEquals("0.05", root(conversation.rawJSON)["min_p"].toString())
        // The model default stays untouched
        assertEquals("{\n  \"min_p\": 0.05\n}", store.additionalBody("p1", "m1", null).rawJSON)
    }

    // -- status mark --

    @Test
    fun `status mark follows connection category and capability evidence`() {
        val auto = listOf(CapabilityControlPresentation.AutomaticAvailable, CapabilityControlPresentation.Unknown)
        val none = listOf(CapabilityControlPresentation.Unknown, CapabilityControlPresentation.Pending)
        assertEquals(ModelOptionsStatusMark.Unverified, ModelOptionsStatusMark.resolve(ConnectionCategory.CustomLLM, auto))
        assertEquals(ModelOptionsStatusMark.Official, ModelOptionsStatusMark.resolve(ConnectionCategory.Other, auto))
        assertEquals(ModelOptionsStatusMark.None, ModelOptionsStatusMark.resolve(ConnectionCategory.Other, none))
        assertEquals(R.string.generation_parameter_source_official, ModelOptionsStatusMark.Official.labelRes)
        assertEquals(R.string.generation_parameter_unverified_badge, ModelOptionsStatusMark.Unverified.labelRes)
        assertNull(ModelOptionsStatusMark.None.labelRes)
    }

    @Test
    fun `production official recipe gives the official mark`() {
        MetadataTestFixtures.applyRaw(GenerationParameterOutboundContractTest().officialMetadata().toString())
        val provider = Provider(id = "anthropic-mark", kind = ProviderKind.Anthropic)
        val model = AIModel(id = GenerationParameterOutboundContractTest.OFFICIAL_MODEL, name = GenerationParameterOutboundContractTest.OFFICIAL_MODEL)
        val presentations = listOf("web", "reasoning").map { CapabilityControlPresentationResolver.presentation(provider, model, it) }
        assertEquals(
            ModelOptionsStatusMark.Official,
            ModelOptionsStatusMark.resolve(ModelOptionsPanelInput.connectionCategory(provider.kind), presentations),
        )
    }

    // -- connection facts to shape inputs --

    @Test
    fun `connection facts map to shape inputs without looking at names`() {
        assertEquals(ConnectionCategory.CustomLLM, ModelOptionsPanelInput.connectionCategory(ProviderKind.Relay))
        assertEquals(ConnectionCategory.Other, ModelOptionsPanelInput.connectionCategory(ProviderKind.OpenAI))
        fun relay(transport: RelayTransport?) = Provider(
            id = "r", kind = ProviderKind.Relay, baseUrlText = "http://127.0.0.1:8080/v1",
            relayRequested = transport?.let { RelayRequestedConfig(transport = it) },
        )
        assertTrue(ModelOptionsPanelInput.protocolUndecided(relay(RelayTransport.Auto)))
        assertTrue(ModelOptionsPanelInput.protocolUndecided(relay(null)))
        assertFalse(ModelOptionsPanelInput.protocolUndecided(relay(RelayTransport.OpenAIChatCompletions)))
        assertFalse(ModelOptionsPanelInput.protocolUndecided(Provider(id = "o", kind = ProviderKind.OpenAI)))
        assertEquals(CustomProtocol.ChatCompletions, ModelOptionsPanelInput.customProtocol(relay(RelayTransport.OpenAIChatCompletions)))
        assertEquals(CustomProtocol.Other, ModelOptionsPanelInput.customProtocol(relay(RelayTransport.AnthropicMessages)))
        assertNull(ModelOptionsPanelInput.customProtocol(Provider(id = "o", kind = ProviderKind.OpenAI)))
        ai.oriveo.community.core.model.CapabilityWebPreference.entries.forEach { preference ->
            val roundTrip = ModelOptionsPanelInput.webPreference(ModelOptionsPanelInput.webIntent(preference))
            val expected = if (preference == ai.oriveo.community.core.model.CapabilityWebPreference.Custom) {
                ai.oriveo.community.core.model.CapabilityWebPreference.Automatic
            } else {
                preference
            }
            assertEquals(expected, roundTrip)
        }
    }

    // -- external search web card --

    private fun webSearchSnapshot(
        services: Int,
        oneTap: Boolean = false,
        stored: ai.oriveo.community.core.search.SearchSourceStored? = null,
    ): WebSearchPanelSnapshot {
        val items = (1..services).map { n ->
            val saved = ai.oriveo.community.core.search.SavedSearchService(id = "s$n", kind = "custom", name = "DeepSeek", keySource = "none")
            ai.oriveo.community.feature.settings.websearch.WebSearchServiceItem(
                saved, "DeepSeek", ai.oriveo.community.core.search.SearchRowState("ready", "custom", "none", null), n == 1, false, null, null,
            )
        }
        val target = ai.oriveo.community.core.search.OneTapReuseTarget("deepseek", "cn", "c-deepseek", "DeepSeek").takeIf { oneTap }
        return WebSearchPanelSnapshot(items, items.firstOrNull()?.saved?.id, stored, target, "DeepSeek".takeIf { oneTap }, "supported")
    }

    /** Same path as the panel: facts -> resolveWebSearchState -> shape resolver. */
    private fun webShape(
        provider: Provider,
        presentation: CapabilityControlPresentation,
        snapshot: WebSearchPanelSnapshot?,
        intents: List<String> = emptyList(),
        web: ai.oriveo.community.core.model.CapabilityWebPreference = ai.oriveo.community.core.model.CapabilityWebPreference.Off,
        rejected: Boolean = false,
        writable: Boolean = true,
        model: AIModel = AIModel(id = "m1", name = "M1"),
    ): ModelOptionCapabilityShape {
        val state = snapshot?.let {
            ai.oriveo.community.core.search.resolveWebSearchState(
                it.stateInput(
                    ModelOptionsPanelInput.webSearchFacts(provider, model, presentation, rejected, null, it.toolCall),
                    writable,
                    web != ai.oriveo.community.core.model.CapabilityWebPreference.Off,
                    webSearchModelKey(provider, model),
                ),
            )
        }
        return ModelOptionCapabilityShape.resolve(
            ModelOptionCapabilityShape.Input(
                capability = ModelOptionCapabilityShape.Capability.Web,
                presentation = presentation,
                availableIntents = intents,
                selectedIntent = ModelOptionsPanelInput.webIntent(web),
                connection = ModelOptionsPanelInput.connectionCategory(provider.kind),
                isWritable = writable,
                rejectedIntents = if (rejected) setOf(ModelOptionCapabilityShape.AUTOMATIC) else emptySet(),
                webSearch = state,
            ),
        )
    }

    private val on = ai.oriveo.community.core.model.CapabilityWebPreference.Automatic

    @Test
    fun `one selectable service on a model that cannot search gives the external toggle reading Search with DeepSeek once armed`() {
        val provider = Provider(id = "c1", kind = ProviderKind.OpenAI)
        val model = AIModel(id = "m1", name = "M1")
        // Row state goes through the production functions (searchServiceRowState -> searchServiceSelectable)
        val row = ai.oriveo.community.core.search.SearchSettings.searchServiceRowState(
            service = ai.oriveo.community.core.search.SearchRowServiceInput(
                kind = "custom", serviceId = null, regionId = null, boundHost = null, keySource = "own", connectionRef = null, hasKey = true,
            ),
            catalogAvailable = true, entry = null, withdrawn = false, connections = emptyList(),
        )
        assertTrue(ai.oriveo.community.core.search.searchServiceSelectable(row.status))
        // External was picked once for this conversation x this model (pick_service)
        val armed = ai.oriveo.community.core.search.updateSearchSource(
            null, webSearchModelKey(provider, model), ai.oriveo.community.core.search.SearchSourceEvent.PickService("s1", "DeepSeek"),
        )
        val shape = webShape(provider, CapabilityControlPresentation.Unsupported, webSearchSnapshot(1, stored = armed), web = on)
        val toggle = shape as ModelOptionCapabilityShape.ToggleWithSource
        assertTrue(toggle.isOn)
        assertEquals("external_tool", toggle.route.path)
        val status = toggle.card.status!!
        assertEquals("Search with DeepSeek", englishText(ModelOptionsRender.searchCardTextRes(status.key), ModelOptionsRender.searchCardArgs(status.key, status.args)))
        assertEquals(ModelOptionCapabilityShape.Escape.PickSearchSource, ModelOptionsRender.searchCardEscape(toggle.card.link!!.action))
    }

    @Test
    fun `web on from a native model then switching to a model that cannot search shows the card off and sends nothing`() {
        val provider = Provider(id = "c1", kind = ProviderKind.OpenAI)
        val auto = listOf(ModelOptionCapabilityShape.AUTOMATIC)
        // Native model: conversation web is on and uses the model's own search
        val native = webShape(provider, CapabilityControlPresentation.AutomaticAvailable, webSearchSnapshot(1), auto, web = on)
            as ModelOptionCapabilityShape.ToggleWithSource
        assertTrue(native.isOn)
        assertEquals("native", native.route.path)
        // Switch to a model that cannot search natively: conversation web is still on, but external was never picked on this model -> the card shows off and this turn does not search
        val other = AIModel(id = "m2", name = "M2")
        val state = ai.oriveo.community.core.search.resolveWebSearchState(
            webSearchSnapshot(1).stateInput(
                ModelOptionsPanelInput.webSearchFacts(provider, other, CapabilityControlPresentation.Unsupported, false, null, "supported"),
                true, true, webSearchModelKey(provider, other),
            ),
        )
        assertTrue(state.armHint)
        assertFalse(state.toggleOn)
        assertEquals("none", state.route.path)
        assertFalse("not external; outbound request unchanged (a model without native search carries no web fields anyway)", state.nativeFieldsSuppressed)
        val card = webShape(provider, CapabilityControlPresentation.Unsupported, webSearchSnapshot(1), web = on, model = other)
            as ModelOptionCapabilityShape.ToggleWithSource
        assertFalse(card.isOn)
        assertEquals("card.offUseService", card.card.status!!.key)
    }

    @Test
    fun `panel that cannot persist keeps toggle rows as before but still offers actions on no-service rows`() {
        val byok = Provider(id = "c1", kind = ProviderKind.OpenAI)
        assertEquals(
            ModelOptionCapabilityShape.Disclosure(ModelOptionCapabilityShape.DisclosureStatus.ModelCannotSearch),
            webShape(byok, CapabilityControlPresentation.Unsupported, webSearchSnapshot(1), writable = false),
        )
        val none = webShape(byok, CapabilityControlPresentation.Unsupported, webSearchSnapshot(0), writable = false)
            as ModelOptionCapabilityShape.Disclosure
        assertEquals("add_search_service", none.searchCard!!.cta!!.action)
    }

    @Test
    fun `no service and native rejected keeps the original toggle and its status, only adding actions`() {
        val byok = Provider(id = "c1", kind = ProviderKind.OpenAI)
        val auto = listOf(ModelOptionCapabilityShape.AUTOMATIC)
        val before = webShape(byok, CapabilityControlPresentation.AutomaticAvailable, null, auto, web = on, rejected = true)
        val shape = webShape(byok, CapabilityControlPresentation.AutomaticAvailable, webSearchSnapshot(0), auto, web = on, rejected = true)
        val toggle = shape as ModelOptionCapabilityShape.Toggle
        assertEquals((before as ModelOptionCapabilityShape.Toggle).copy(searchCard = toggle.searchCard), toggle)
        assertNull("status copy is not rewritten", toggle.searchCard!!.status)
        assertEquals("add_search_service", toggle.searchCard!!.cta!!.action)
    }

    @Test
    fun `one tap detail replaces the card body instead of stacking`() {
        val byok = Provider(id = "c1", kind = ProviderKind.OpenAI)
        val shape = webShape(byok, CapabilityControlPresentation.Unknown, webSearchSnapshot(0, oneTap = true))
        val tile = ModelOptionsTiles.capabilityTile(ModelOptionCapabilityShape.Capability.Web, shape)
        assertNull(tile.searchCard!!.status)
        assertEquals("card.reuseDetail", tile.searchCard!!.notes.single().key)
        assertEquals("DeepSeek", tile.searchCard!!.notes.single().args["name"])
        assertTrue(tile.bodyRes != null)
    }

    @Test
    fun `draft conversation keeps its source in memory and writes it once under the real id`() = kotlinx.coroutines.test.runTest {
        val store = ai.oriveo.community.core.search.SearchServiceStore(ai.oriveo.community.testing.TestSharedPreferences())
        store.save(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID, ai.oriveo.community.core.search.SavedSearchService(id = "s1", kind = "custom", name = "DeepSeek", keySource = "none"))
        val webSearch = StoreModelControlsWebSearch(
            store, ai.oriveo.community.core.search.SearchCatalogRepository(ai.oriveo.community.testing.TestSharedPreferences(), { error("no fetch") }, { null }, emptyMap()),
            { emptyList() }, { _, _ -> null },
        )
        val provider = Provider(id = "c1", kind = ProviderKind.OpenAI)
        val model = AIModel(id = "m1", name = "M1")
        webSearch.update(provider, model, "draft-1", true, ai.oriveo.community.core.search.SearchSourceEvent.PickService("s1", "DeepSeek"))
        assertNull("draft id is not persisted", store.conversationSource(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID, "draft-1"))
        assertEquals("external", webSearch.snapshot(provider, model, "draft-1", draft = true).stored?.methods?.get("c1:m1"))
        webSearch.adoptDraft("draft-1", "conv-1")
        assertEquals("s1", store.conversationSource(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID, "conv-1")?.serviceId)
        // Turning the external switch off: disarm clears only the external choice for this model and keeps the service
        webSearch.update(provider, model, "conv-1", false, ai.oriveo.community.core.search.SearchSourceEvent.Disarm)
        assertNull(store.conversationSource(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID, "conv-1")?.methods?.get("c1:m1"))
        assertEquals("s1", store.conversationSource(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID, "conv-1")?.serviceId)
    }

    private fun stateFor(
        snapshot: WebSearchPanelSnapshot,
        presentation: CapabilityControlPresentation = CapabilityControlPresentation.Unsupported,
        webOn: Boolean = false,
        model: AIModel = AIModel(id = "m1", name = "M1"),
    ): ai.oriveo.community.core.search.WebSearchState {
        val provider = Provider(id = "c1", kind = ProviderKind.OpenAI)
        return ai.oriveo.community.core.search.resolveWebSearchState(
            snapshot.stateInput(
                ModelOptionsPanelInput.webSearchFacts(provider, model, presentation, false, null, snapshot.toolCall),
                true, webOn, webSearchModelKey(provider, model),
            ),
        )
    }

    private val armedOnM1 = ai.oriveo.community.core.search.SearchSourceStored(mapOf("c1:m1" to "external"), "s1", "DeepSeek")

    @Test
    fun `external armed on a model that cannot search goes external with the chip lit even when conversation web is off`() {
        val state = stateFor(webSearchSnapshot(1, stored = armedOnM1), webOn = false)
        assertEquals("external_tool", state.route.path)
        assertTrue("send goes external: native / relay fields are suppressed", state.nativeFieldsSuppressed)
        assertEquals(true, state.chipLit)
    }

    @Test
    fun `closing the external switch only disarms this model and leaves conversation web alone`() {
        val state = stateFor(webSearchSnapshot(1, stored = armedOnM1), webOn = true)
        // The panel takes the toggleControls = external branch: it only sends disarm and does not persist (conversation web unchanged)
        assertEquals("external", state.toggleControls)
        val next = ai.oriveo.community.core.search.updateSearchSource(armedOnM1, "c1:m1", ai.oriveo.community.core.search.SearchSourceEvent.Disarm)
        assertNull(next?.methods?.get("c1:m1"))
        val after = stateFor(webSearchSnapshot(1, stored = next), webOn = true)
        assertFalse(after.toggleOn)
        assertTrue("conversation web is still on; the card hints that external is not turned on yet", after.armHint)
    }

    @Test
    fun `deleting the chosen service turns external off and shows the fallback note`() {
        val gone = ai.oriveo.community.core.search.SearchSourceStored(mapOf("c1:m1" to "external"), "s-gone", "Exa")
        val state = stateFor(webSearchSnapshot(1, stored = gone), webOn = false)
        assertEquals("default", state.source.method)
        assertFalse(state.toggleOn)
        assertEquals("card.fallbackNotice", state.card.notes.first().key)
        assertEquals("Exa", state.card.notes.first().args["from"])
    }

    @Test
    fun `catalog unavailable keeps the chosen service and explains it in a note`() {
        val saved = ai.oriveo.community.core.search.SavedSearchService(id = "s1", kind = "preset", serviceId = "deepseek", name = "DeepSeek")
        val item = ai.oriveo.community.feature.settings.websearch.WebSearchServiceItem(
            saved, "DeepSeek", ai.oriveo.community.core.search.SearchRowState("catalog_unavailable", "preset", "own", null), true, true, null, null,
        )
        val snapshot = WebSearchPanelSnapshot(listOf(item), "s1", armedOnM1, null, null, "supported")
        val state = stateFor(snapshot)
        assertEquals("external", state.source.method)
        assertTrue(state.toggleOn)
        assertTrue(state.card.notes.any { it.key == "row.catalogUnavailable" })
        assertEquals(R.string.web_search_row_catalog_unavailable, ModelOptionsRender.searchCardTextRes("row.catalogUnavailable"))
    }

    private fun storeBackedWebSearch(): Pair<ai.oriveo.community.core.search.SearchServiceStore, StoreModelControlsWebSearch> {
        val store = ai.oriveo.community.core.search.SearchServiceStore(ai.oriveo.community.testing.TestSharedPreferences())
        return store to StoreModelControlsWebSearch(
            store, ai.oriveo.community.core.search.SearchCatalogRepository(ai.oriveo.community.testing.TestSharedPreferences(), { error("no fetch") }, { null }, emptyMap()),
            { emptyList() }, { _, _ -> null },
        )
    }

    private fun customService(id: String) =
        ai.oriveo.community.core.search.SavedSearchService(id = id, kind = "custom", name = "Svc $id", keySource = "none")

    @Test
    fun `adding from the model options panel picks the new service and writes external for this model`() = kotlinx.coroutines.test.runTest {
        val (store, webSearch) = storeBackedWebSearch()
        val returns = ai.oriveo.community.core.search.WebSearchChatReturn
        val provider = Provider(id = "c1", kind = ProviderKind.OpenAI)
        val model = AIModel(id = "m1", name = "M1")
        store.save(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID, customService("s-old"))
        // Leave via "Add search service" in the panel -> add one in settings -> settle on leaving settings -> picked up back in chat
        returns.leave(ai.oriveo.community.core.search.WebSearchChatReturn.Pending("conv-1", false, true, setOf("s-old")))
        store.save(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID, customService("s-new"))
        returns.finish(store.services(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID).map { it.id })
        val back = requireNotNull(returns.consume("conv-1"))
        assertEquals("s-new", back.addedServiceId)
        webSearch.pickAdded(provider, model, "conv-1", false, back.addedServiceId!!)
        val stored = store.conversationSource(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID, "conv-1")
        assertEquals("external", stored?.methods?.get("c1:m1"))
        assertEquals("s-new", stored?.serviceId)
    }

    @Test
    fun `adding directly in settings does not change the conversation choice`() {
        val (store, _) = storeBackedWebSearch()
        val returns = ai.oriveo.community.core.search.WebSearchChatReturn
        returns.consume("conv-1")
        store.save(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID, customService("s-new"))
        // Adding directly in settings: there is no record started from the panel, so settling does nothing
        returns.finish(store.services(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID).map { it.id })
        assertNull(returns.consume("conv-1"))
        assertNull(store.conversationSource(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID, "conv-1"))
    }

    @Test
    fun `leaving settings before adding voids the record so a later direct add is not picked`() {
        val (store, _) = storeBackedWebSearch()
        val returns = ai.oriveo.community.core.search.WebSearchChatReturn
        returns.leave(ai.oriveo.community.core.search.WebSearchChatReturn.Pending("conv-1", true, true, emptySet()))
        // Leaving settings before adding: settles as "no new service" and the record is voided
        returns.finish(store.services(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID).map { it.id })
        assertNull(returns.consume("conv-1")?.addedServiceId)
        // Then add directly in settings
        store.save(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID, customService("s-later"))
        returns.finish(store.services(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID).map { it.id })
        assertNull(returns.consume("conv-1"))
        assertNull(store.conversationSource(ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID, "conv-1"))
    }

    /** English copy: R.string id -> resource name -> the entry in res/values/strings_web_search.xml, with %n$s substituted. */
    private fun englishText(resId: Int, args: List<String>): String {
        val name = R.string::class.java.fields.first { it.getInt(null) == resId }.name
        val xml = java.io.File("src/main/res/values/strings_web_search.xml").readText()
        val raw = Regex("""<string name="$name">(.*?)</string>""").find(xml)!!.groupValues[1].replace("\\'", "'")
        return String.format(raw, *args.toTypedArray())
    }

    // -- shape to copy slots --

    @Test
    fun `shape semantics map to the registered copy`() {
        assertEquals(
            // The auto tier uses "Automatic" (model_control_supplier_default), no longer "Auto".
            listOf(R.string.model_control_supplier_default, R.string.model_control_off, R.string.reasoning_fast, R.string.reasoning_balanced, R.string.reasoning_deep, R.string.reasoning_max),
            listOf("automatic", "off", "low", "balanced", "deep", "max").map(ModelOptionsRender::tierLabelRes),
        )
        assertEquals(R.string.model_control_reasoning_note_automatic, ModelOptionsRender.tierNoteRes("automatic"))
        assertEquals(R.string.model_control_reasoning_note_fast, ModelOptionsRender.tierNoteRes("low"))
        assertTrue(ModelOptionsRender.appendsHigherLevelsNote("balanced"))
        assertFalse(ModelOptionsRender.appendsHigherLevelsNote("automatic"))
        assertEquals(R.string.model_options_web_when_needed, ModelOptionsRender.timingLabelRes("automatic"))
        assertEquals(R.string.model_options_web_every_message, ModelOptionsRender.timingLabelRes("force"))
        assertEquals(
            R.string.model_options_template_thinking_note,
            ModelOptionsRender.toggleNoteRes(ModelOptionCapabilityShape.Capability.Reasoning, ModelOptionCapabilityShape.ToggleKind.ChatTemplateThinking),
        )
        assertEquals(
            R.string.model_options_web_note,
            ModelOptionsRender.toggleNoteRes(ModelOptionCapabilityShape.Capability.Web, ModelOptionCapabilityShape.ToggleKind.Capability),
        )
        assertEquals(R.string.model_options_see_adjustable_models, ModelOptionsRender.escapeRes(ModelOptionCapabilityShape.Escape.SupportedModels))
        assertEquals(R.string.model_options_open_additional_body, ModelOptionsRender.escapeRes(ModelOptionCapabilityShape.Escape.AdditionalBody))
        assertEquals(
            R.string.model_options_connection_cannot,
            ModelOptionsRender.disclosureRes(ModelOptionCapabilityShape.DisclosureStatus.ConnectionCannotSearch),
        )
        assertTrue(ModelOptionsRender.disclosureOffersSupportedModels(ModelOptionCapabilityShape.DisclosureStatus.ModelDoesNotThink))
        assertFalse(ModelOptionsRender.disclosureOffersSupportedModels(ModelOptionCapabilityShape.DisclosureStatus.ConnectionCannotSearch))
    }

    private fun input(state: String?, reasonCode: String? = null, wireFamily: String = "openai_chat.image_url") =
        CapabilityEvidenceFacade.projectInputCapability(
            key = CapabilityEvidenceFacade.VISION_INPUT,
            verdict = state?.let { CapabilityEvidenceFacade.InputCapabilityVerdict(it, reasonCode, wireFamily) },
            endImplements = true,
            override = null,
            negativeCacheHit = false,
            connection = CapabilityEvidenceFacade.InputCapabilityConnection.OFFICIAL,
        )

    private fun entry(vision: String?, file: String?, visionReason: String? = null, fileReason: String? = null): ComposerAttachmentEntryModel {
        val projections = InputCapabilityProjections(
            vision = input(vision, visionReason),
            file = input(file, fileReason, "openai_chat.file"),
            video = input("unknown"),
        )
        return ComposerAttachmentEntryModel.from(
            projections,
            AttachmentInputGate(
                image = projections.vision.editable,
                nativeFile = projections.file.editable,
                textFileInline = true,
                video = projections.video.editable,
            ),
        )
    }

    @Test
    fun `vision tile follows the projection three values and writes the reason when unavailable`() {
        assertEquals(ModelOptionsTiles.Vision.Available, ModelOptionsTiles.vision(entry("auto_available", "unknown").image))
        // unknown: the entry is open, but the card does not say "available".
        assertEquals(ModelOptionsTiles.Vision.Unknown, ModelOptionsTiles.vision(entry(null, "unknown").image))
        val absent = entry("unavailable", "unknown", visionReason = "model_capability_absent")
        assertEquals(ModelOptionsTiles.Vision.Hidden, ModelOptionsTiles.vision(absent.image))
        val tiles = ModelOptionsTiles.board(
            web = ModelOptionCapabilityShape.Toggle(isOn = false, kind = ModelOptionCapabilityShape.ToggleKind.Capability),
            reasoning = ModelOptionCapabilityShape.Toggle(isOn = false, kind = ModelOptionCapabilityShape.ToggleKind.Capability),
            vision = ModelOptionsTiles.vision(absent.image),
            file = ModelOptionsTiles.FileDelivery.NativeWhenSupported,
            visionReasonRes = absent.image.disabledReasonRes,
            fileReasonRes = absent.file.nativeDisabledReasonRes,
        )
        val visionTile = tiles.single { it.kind == ModelOptionsTiles.Kind.Vision }
        // The status row is the disabled reason itself, no longer "photo picker hidden".
        assertEquals(R.string.capability_input_disabled_model_absent_image, visionTile.statusRes)
        assertNull(visionTile.bodyRes)
        // Available / unknown carry no reason; the status row keeps its own line.
        assertEquals(R.string.model_options_vision_unknown, ModelOptionsTiles.visionTile(ModelOptionsTiles.Vision.Unknown, R.string.capability_input_disabled_model_absent_image).statusRes)
        assertNull(tiles.single { it.kind == ModelOptionsTiles.Kind.File }.bodyRes)
    }

    @Test
    fun `file tile drops to text with the reason when the native file projection is unavailable`() {
        val unavailable = entry("auto_available", "unavailable", fileReason = "transport_not_supported")
        // Inline text stays tappable, but the native-file reason must be spelled out.
        assertTrue(unavailable.file.enabled)
        assertEquals("capability_input_disabled_wire_not_implemented_file", unavailable.file.nativeDisabledReasonKey)
        val provider = Provider(id = "deepseek", kind = ProviderKind.DeepSeek)
        val model = AIModel(id = "deepseek-flash", name = "deepseek-flash")
        val delivery = ModelOptionsPanelInput.fileDelivery(
            provider = provider,
            model = model,
            webSearchEnabled = false,
            reasoningMode = ai.oriveo.community.core.model.ReasoningMode.Automatic,
            nativeFileUnavailable = unavailable.file.nativeDisabledReasonKey != null,
        )
        assertEquals(ModelOptionsTiles.FileDelivery.Text, delivery)
        val tile = ModelOptionsTiles.fileTile(delivery, unavailable.file.nativeDisabledReasonRes)
        assertEquals(R.string.capability_input_disabled_wire_not_implemented_file, tile.bodyRes)
        assertNull(entry("auto_available", "unknown").file.nativeDisabledReasonKey)
    }
}
