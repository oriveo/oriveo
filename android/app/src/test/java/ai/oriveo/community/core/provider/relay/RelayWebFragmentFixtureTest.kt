package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsPanelInput
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsRender
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionsTiles
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.R
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fixture `shared/test-fixtures/relay/web-fragment.v1.json`, case by case (shared names across platforms: RELAY-WEBFRAG-<section>-<caseId>).
 * The profile table for the legacy field mapping is fed in through the production metadata loading entry point (loadNetworkPayloadForTesting).
 */
class RelayWebFragmentFixtureTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val fixture by lazy { readJson("shared/test-fixtures/relay/web-fragment.v1.json") }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
    }

    @Test
    fun RELAY_WEBFRAG_validate_cases() {
        val cases = fixture.getValue("validateCases").jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 16)
        cases.forEach { case ->
            val caseId = case.string("caseId")
            val raw = case["rawPadTo"]?.jsonPrimitive?.int?.let { n -> "{\"x\":\"" + "a".repeat(n - 8) + "\"}" }
                ?: case.string("raw")
            val expect = case.getValue("expect").jsonObject
            val result = RelayWebFragments.validate(raw)
            if (expect.getValue("ok").jsonPrimitive.content == "true") {
                assertTrue("RELAY-WEBFRAG-validate-$caseId -> ok, actual $result", result is RelayWebFragments.Validation.Ok)
            } else {
                val error = result as? RelayWebFragments.Validation.Error
                assertEquals("RELAY-WEBFRAG-validate-$caseId error code", expect.string("error"), error?.code)
                expect["key"]?.let { assertEquals("RELAY-WEBFRAG-validate-$caseId key name", it.jsonPrimitive.content, error?.key) }
            }
        }
    }

    @Test
    fun RELAY_WEBFRAG_merge_cases() {
        fixture.getValue("mergeCases").jsonArray.map { it.jsonObject }.forEach { case ->
            val transport = transport(case.string("transport"))
            val merged = RelayWebFragments.merge(
                transport,
                case.getValue("builderBody").jsonObject,
                case.getValue("fragment").jsonObject,
            )
            assertEquals("RELAY-WEBFRAG-merge-${case.string("caseId")}", case.getValue("expect").jsonObject, merged)
        }
    }

    @Test
    fun RELAY_WEBFRAG_legacy_cases() {
        loadLegacyProfiles()
        fixture.getValue("legacyCases").jsonArray.map { it.jsonObject }.forEach { case ->
            val caseId = case.string("caseId")
            val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
            val provider = Provider(
                id = "relay-$caseId",
                kind = ProviderKind.Relay,
                relayRequested = json.decodeFromJsonElement(RelayRequestedConfig.serializer(), case.getValue("relayRequested")),
            )
            case.getValue("stored").jsonObject.forEach { (wire, fragment) ->
                assertTrue(store.save(provider.id, transport(wire), fragment.toString()) is RelayWebFragments.Validation.Ok)
            }
            val before = provider.relayRequested
            assertEquals("RELAY-WEBFRAG-legacy-$caseId", case.getValue("expect").jsonObject, JsonObject(store.effective(provider)))
            assertEquals("RELAY-WEBFRAG-legacy-$caseId mapping is not written back", before, provider.relayRequested)
            if (case.getValue("stored").jsonObject.isEmpty()) {
                assertEquals("RELAY-WEBFRAG-legacy-$caseId store was not written", emptyMap<String, JsonObject>(), store.stored(provider.id))
            }
        }
    }

    /** Outside the fixture: the metadata has this profile but the profileTransport table does not -> no mapping and no fallback to the default. */
    @Test
    fun RELAY_WEBFRAG_legacy_profile_in_metadata_but_not_in_the_transport_table_is_not_mapped() {
        val payload = buildJsonObject {
            put("version", 1)
            put("providers", JsonObject(emptyMap()))
            put("profiles", buildJsonObject {
                put("webSearch", buildJsonObject {
                    put("future_web", buildJsonObject { put("mergeParams", Json.parseToJsonElement("""{"web":{"on":true}}""")) })
                })
            })
        }
        MetadataTestFixtures.applyRaw(payload.toString())
        val provider = Provider(
            id = "relay-future",
            kind = ProviderKind.Relay,
            relayRequested = RelayRequestedConfig(hasWebSearch = true, webSearchProfile = "future_web"),
        )
        val store = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        assertEquals(emptyMap<String, JsonObject>(), store.effective(provider))
    }

    @Test
    fun RELAY_WEBFRAG_citation_cases() {
        fixture.getValue("citationCases").jsonArray.map { it.jsonObject }.forEach { case ->
            val fragment = case.getValue("fragment").takeUnless { it is JsonNull }?.jsonObject
            val expected = case.getValue("expect").takeUnless { it is JsonNull }?.jsonPrimitive?.content
            assertEquals(
                "RELAY-WEBFRAG-citation-${case.string("caseId")}",
                expected,
                RelayWebFragments.citationProfile(transport(case.string("transport")), fragment),
            )
        }
    }

    @Test
    fun RELAY_WEBFRAG_presentation_cases() {
        fixture.getValue("presentationCases").jsonArray.map { it.jsonObject }.forEach { case ->
            val caseId = case.string("caseId")
            val fragments = case.getValue("fragments").jsonObject.mapValues { it.value.jsonObject }
            val shape = ModelOptionCapabilityShape.resolve(
                ModelOptionCapabilityShape.Input(
                    capability = ModelOptionCapabilityShape.Capability.Web,
                    presentation = CapabilityControlPresentation.Unknown,
                    availableIntents = emptyList(),
                    selectedIntent = null,
                    connection = ModelOptionCapabilityShape.ConnectionCategory.CustomLLM,
                    protocolUndecided = case.getValue("protocolUndecided").jsonPrimitive.content == "true",
                    relayWeb = ModelOptionsPanelInput.relayWeb(
                        localEngine = case.getValue("engineProfile") !is JsonNull,
                        effectiveTransport = case.string("effectiveTransport"),
                        fragments = fragments,
                    ),
                ),
            )
            val expect = case.getValue("expect").jsonObject
            val message = "RELAY-WEBFRAG-presentation-$caseId: $shape"
            when (expect.string("shape")) {
                "protocolUndecided" -> assertEquals(message, ModelOptionCapabilityShape.ProtocolUndecided, shape)
                "disclosure" -> {
                    val disclosure = shape as? ModelOptionCapabilityShape.Disclosure
                    assertEquals(message, statusRes(expect.string("status")), disclosure?.status?.let(ModelOptionsRender::disclosureRes))
                }
                else -> error("unknown shape in $caseId")
            }
        }
    }

    /**
     * Fixture `web-probe.v1.json` presentationCases: relay web search = a chat switch.
     * Fragments and records are written through the production stores and read through the production panel entry [ModelOptionsPanelInput.relayWeb] (RL2-WEBPROBE-14: row / isOn default /
     * statusId / retestLink); sendsFragment / sentFragment go through the same [RelayWebChat.sentFragment] as chat (RL2-WEBPROBE-08).
     */
    @Test
    fun `RL2-WEBPROBE-08 PRES fixture caseIds map one-to-one to the per-case tests here`() {
        assertEquals(PRES_CASE_IDS, presCases().map { it.string("caseId") })
    }

    @Test fun `RL2-WEBPROBE-PRES-template_untested_default_off`() = presCase("template_untested_default_off")
    @Test fun `RL2-WEBPROBE-PRES-template_untested_toggled_on_sends_template`() = presCase("template_untested_toggled_on_sends_template")
    @Test fun `RL2-WEBPROBE-PRES-template_searched_is_current`() = presCase("template_searched_is_current")
    @Test fun `RL2-WEBPROBE-PRES-template_silent_unknown`() = presCase("template_silent_unknown")
    @Test fun `RL2-WEBPROBE-PRES-template_rejected_keeps_toggle_on`() = presCase("template_rejected_keeps_toggle_on")
    @Test fun `RL2-WEBPROBE-PRES-saved_default_on_keeps_old_behaviour`() = presCase("saved_default_on_keeps_old_behaviour")
    @Test fun `RL2-WEBPROBE-PRES-saved_toggled_off_sends_nothing`() = presCase("saved_toggled_off_sends_nothing")
    @Test fun `RL2-WEBPROBE-PRES-saved_rejected_links_web_search_page`() = presCase("saved_rejected_links_web_search_page")
    @Test fun `RL2-WEBPROBE-PRES-stale_record_is_untested`() = presCase("stale_record_is_untested")
    @Test fun `RL2-WEBPROBE-PRES-user_off_wins`() = presCase("user_off_wins")
    @Test fun `RL2-WEBPROBE-PRES-user_on_wins_over_rejected`() = presCase("user_on_wins_over_rejected")
    @Test fun `RL2-WEBPROBE-PRES-template_rejected_toggled_off_no_notice`() = presCase("template_rejected_toggled_off_no_notice")

    private fun presCases(): List<JsonObject> = readJson("shared/test-fixtures/relay/web-probe.v1.json")
        .getValue("presentationCases").jsonObject.getValue("cases").jsonArray.map { it.jsonObject }

    private fun presCase(caseId: String) {
        val transport = RelayTransport.OpenAIChatCompletions
        val template = RelayWebFragments.template(transport)!!
        val saved = buildJsonObject { put("web_search_options", buildJsonObject { put("search_context_size", "low") }) }
        val case = presCases().single { it.string("caseId") == caseId }
        val message = "RL2-WEBPROBE-PRES-$caseId"
        val hasSaved = case.getValue("savedFragment").jsonPrimitive.content == "true"
        val effective = if (hasSaved) saved else template
        val userOverride = (case.getValue("userOverride") as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content?.toBooleanStrict()
        val model = AIModel(
            id = "probe-model",
            name = "probe-model",
            relayCapabilityOverrides = userOverride?.let { ai.oriveo.community.core.model.RelayCapabilityOverrides(web = it) },
        )
        val provider = Provider(
            id = "relay-pres-$caseId",
            kind = ProviderKind.Relay,
            relayRequested = RelayRequestedConfig(transport = transport),
            models = listOf(model),
        )
        val fragments = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
        if (hasSaved) assertTrue(fragments.save(provider.id, transport, saved.toString()) is RelayWebFragments.Validation.Ok)
        val records = RelayWebProbeRecordStore(RelayWebProbeRecordStore.MemoryStore()) { 1L }
        (case["record"] as? JsonObject)?.let { record ->
            records.record(
                RelayWebProbeRecordStore.Key(provider.id, model.id, transport.value),
                RelayWebProbeRecord(
                    result = RelayWebProbeResult.entries.single { it.wire == record.string("result") },
                    source = RelayWebProbeSource.Tested,
                    at = 1L,
                    fragmentHash = if (record.string("fragmentHash") == "current") RelayWebProbe.fragmentHash(effective) else "0".repeat(64),
                ),
            )
        }
        val webPreference = when ((case.getValue("webPreference") as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content) {
            "on" -> ai.oriveo.community.core.model.CapabilityWebPreference.Automatic
            "off" -> ai.oriveo.community.core.model.CapabilityWebPreference.Off
            else -> null
        }
        val shape = ModelOptionCapabilityShape.resolve(
            ModelOptionCapabilityShape.Input(
                capability = ModelOptionCapabilityShape.Capability.Web,
                presentation = CapabilityControlPresentation.Unknown,
                availableIntents = emptyList(),
                selectedIntent = null,
                connection = ModelOptionCapabilityShape.ConnectionCategory.CustomLLM,
                relayWeb = ModelOptionsPanelInput.relayWeb(provider, model, fragments, records, webPreference),
            ),
        )
        val expect = case.getValue("expect").jsonObject
        val detail = "$message: $shape"
        val row = shape as? ModelOptionCapabilityShape.RelayWebToggle ?: error("$detail is not a web switch")
        // RL2-WEBPROBE-14: row / isOn / statusId / retestLink.
        assertEquals("$detail row", expect.string("row"), if (row.enabled) "toggle" else "toggleDisabled")
        assertEquals("$detail isOn", expect.string("isOn").toBooleanStrict(), row.isOn)
        assertEquals("$detail statusId", expect.string("statusId"), row.status.wire)
        assertEquals("$detail retestLink", (expect["retestLink"] as? JsonPrimitive)?.content, row.retest?.wire)
        // Status line copy: the four existing ones + two new ones + the source badge "Set by you".
        val statusRes = mapOf(
            "web_probe_searched" to R.string.model_options_relay_web_search_confirmed,
            "web_probe_silent" to R.string.model_options_relay_web_no_search_in_test,
            "web_probe_rejected" to R.string.model_options_relay_web_rejected,
            "web_probe_unverified" to R.string.model_options_relay_web_set_unverified,
            "web_probe_untested" to R.string.model_options_relay_web_untested,
            "web_user_off" to R.string.model_options_relay_web_user_off,
            "web_user_on" to R.string.relay_catalog_status_set_by_you,
        ).getValue(expect.string("statusId"))
        val tile = ModelOptionsTiles.capabilityTile(ModelOptionCapabilityShape.Capability.Web, shape)
        assertEquals(detail, statusRes, tile.statusRes)
        assertEquals(detail, ModelOptionsTiles.Corner.Switch, tile.corner)
        assertEquals("$detail no longer has \"Needs manual setup\"", null, tile.bodyRes)
        // The default layer when unset is the same one as in the preference store (provider_default): a stored fragment -> on.
        val chat = RelayWebChat.of(provider, model, fragments, records)!!
        if (webPreference == null) {
            val resolved = ai.oriveo.community.core.model.CapabilityScopeValues().displaySelection(chat.defaultPreference).web
            assertEquals("$detail default layer", row.isOn, chat.isOn(resolved))
        }
        // RL2-WEBPROBE-08: whether the request carries a fragment, and which one, go through the same function as chat.
        val sent = chat.sentFragment(row.isOn)
        assertEquals("$detail sendsFragment", expect.string("sendsFragment").toBooleanStrict(), sent != null)
        (expect["sentFragment"] as? JsonPrimitive)?.content?.let { which ->
            assertEquals("$detail sentFragment", if (which == "saved") saved else template, sent)
        }
        // Switch on but this request carries no fragment -> reply notice web_not_used; switch off or a fragment carried -> none.
        assertEquals("$detail replyNotice", (expect["replyNotice"] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content, chat.replyNotice(row.isOn)?.wire)
    }

    /** The panel's record lookup and the probe's record write use the same protocol resolution: for a model whose first send on an auto connection is Messages, a Messages record of searched -> Search confirmed. */
    @Test
    fun `RL2-WEBPROBE-PRES-auto_first_send_messages panel reads the Messages record by the first-send protocol`() {
        val field = ai.oriveo.community.core.data.remote.RelayModelFamilyLookup::class.java.getDeclaredField("families")
            .apply { isAccessible = true }
        val lookup = ai.oriveo.community.core.data.remote.RelayModelFamilyLookup.shared
        val previous = field.get(lookup)
        field.set(lookup, mapOf("claude-sonnet-4" to "anthropic"))
        try {
            val model = AIModel(id = "claude-sonnet-4", name = "claude-sonnet-4")
            val provider = Provider(
                id = "relay-auto-claude",
                kind = ProviderKind.Relay,
                baseUrlText = "https://relay.example.com",
                relayRequested = RelayRequestedConfig(transport = RelayTransport.Auto),
                models = listOf(model),
            )
            val messages = RelayTransport.AnthropicMessages
            assertEquals(messages, RelayFirstSendTransport.resolve(provider, model))
            val fragment = RelayWebFragments.template(messages)!!
            val fragments = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
            assertTrue(fragments.save(provider.id, messages, fragment.toString()) is RelayWebFragments.Validation.Ok)
            val records = RelayWebProbeRecordStore(RelayWebProbeRecordStore.MemoryStore()) { 1L }
            records.record(
                RelayWebProbeRecordStore.Key(provider.id, model.id, messages.value),
                RelayWebProbeRecord(RelayWebProbeResult.Searched, RelayWebProbeSource.Tested, 1L, RelayWebProbe.fragmentHash(fragment)),
            )
            val shape = ModelOptionCapabilityShape.resolve(
                ModelOptionCapabilityShape.Input(
                    capability = ModelOptionCapabilityShape.Capability.Web,
                    presentation = CapabilityControlPresentation.Unknown,
                    availableIntents = emptyList(),
                    selectedIntent = null,
                    connection = ModelOptionCapabilityShape.ConnectionCategory.CustomLLM,
                    relayWeb = ModelOptionsPanelInput.relayWeb(provider, model, fragments, records),
                ),
            )
            assertEquals(
                "RL2-WEBPROBE-PRES-auto_first_send_messages: $shape",
                RelayWebChat.Status.Searched,
                (shape as? ModelOptionCapabilityShape.RelayWebToggle)?.status,
            )
        } finally {
            field.set(lookup, previous)
        }
    }

    private companion object {
        val PRES_CASE_IDS = listOf(
            "template_untested_default_off",
            "template_untested_toggled_on_sends_template",
            "template_searched_is_current",
            "template_silent_unknown",
            "template_rejected_keeps_toggle_on",
            "saved_default_on_keeps_old_behaviour",
            "saved_toggled_off_sends_nothing",
            "saved_rejected_links_web_search_page",
            "stale_record_is_untested",
            "user_off_wins",
            "user_on_wins_over_rejected",
            "template_rejected_toggled_off_no_notice",
        )
    }

    private fun statusRes(english: String): Int = when (english) {
        "This connection can’t do this" -> R.string.model_options_connection_cannot
        else -> error("unmapped status $english")
    }

    /** Wraps the fixture legacyProfiles into the metadata's `profiles.webSearch.<name>.mergeParams` and goes through the production loading entry point. */
    private fun loadLegacyProfiles() {
        val profiles = fixture.getValue("legacyProfiles").jsonObject
        val payload = buildJsonObject {
            put("version", 1)
            put("providers", JsonObject(emptyMap()))
            put("profiles", buildJsonObject {
                put("webSearch", JsonObject(profiles.mapValues { (_, params) -> buildJsonObject { put("mergeParams", params) } }))
            })
        }
        MetadataTestFixtures.applyRaw(payload.toString())
        assertEquals(JsonObject(emptyMap()), MetadataClient.webSearchDeclaredMergeParams("oai_web_tool"))
    }

    private fun transport(wire: String): RelayTransport = RelayTransport.entries.single { it.value == wire }

    private fun readJson(relativePath: String): JsonObject {
        val repoRoot = File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!
        return json.parseToJsonElement(File(repoRoot, relativePath).readText()).jsonObject
    }

    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content
}
