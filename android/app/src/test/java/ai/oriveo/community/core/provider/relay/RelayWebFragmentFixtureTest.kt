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
            val message = "RELAY-WEBFRAG-presentation-$caseId：$shape"
            when (expect.string("shape")) {
                "protocolUndecided" -> assertEquals(message, ModelOptionCapabilityShape.ProtocolUndecided, shape)
                "disclosure" -> {
                    val disclosure = shape as? ModelOptionCapabilityShape.Disclosure
                    assertEquals(message, statusRes(expect.string("status")), disclosure?.status?.let(ModelOptionsRender::disclosureRes))
                    if (expect["action"] != null) {
                        assertTrue(message, disclosure != null && ModelOptionsRender.disclosureTappable(disclosure.status))
                        assertEquals(message, ModelOptionCapabilityShape.DisclosureStatus.RelayWebUnverified, disclosure?.status)
                    }
                }
                "notice" -> {
                    val notice = shape as? ModelOptionCapabilityShape.Notice
                    assertEquals(message, statusRes(expect.string("status")), notice?.status?.let(ModelOptionsRender::noticeStatusRes))
                    assertEquals(message, R.string.model_options_relay_web_manual_body, notice?.body?.let(ModelOptionsRender::noticeBodyRes))
                    assertEquals(message, ModelOptionCapabilityShape.Escape.ConnectionWebSearch, notice?.escape)
                    assertEquals(message, R.string.model_options_relay_web_open_settings, notice?.escape?.let(ModelOptionsRender::escapeRes))
                }
                else -> error("unknown shape in $caseId")
            }
        }
    }

    /**
     * Fixture `web-probe.v1.json` presentationCases: the web-search row shows 4 states based on the local probe record,
     * records are written through the production record store and read through the production panel entry by the current fragment hash; sendsFragment uses the same filter function as chat.
     */
    @Test
    fun `RL2-WEBPROBE-PRES fixture caseIds map one-to-one to the per-case tests here`() {
        assertEquals(PRES_CASE_IDS, presCases().map { it.string("caseId") })
    }

    @Test fun `RL2-WEBPROBE-PRES-fragment_searched_supported`() = presCase("fragment_searched_supported")
    @Test fun `RL2-WEBPROBE-PRES-fragment_rejected_unsupported`() = presCase("fragment_rejected_unsupported")
    @Test fun `RL2-WEBPROBE-PRES-fragment_silent_unknown`() = presCase("fragment_silent_unknown")
    @Test fun `RL2-WEBPROBE-PRES-fragment_untested_unknown`() = presCase("fragment_untested_unknown")
    @Test fun `RL2-WEBPROBE-PRES-fragment_stale_record_is_untested`() = presCase("fragment_stale_record_is_untested")
    @Test fun `RL2-WEBPROBE-PRES-no_fragment_needs_setup`() = presCase("no_fragment_needs_setup")

    private fun presCases(): List<JsonObject> = readJson("shared/test-fixtures/relay/web-probe.v1.json")
        .getValue("presentationCases").jsonObject.getValue("cases").jsonArray.map { it.jsonObject }

    private fun presCase(caseId: String) {
        val transport = RelayTransport.OpenAIChatCompletions
        val fragment = RelayWebFragments.template(transport)!!
        val case = presCases().single { it.string("caseId") == caseId }
        val message = "RL2-WEBPROBE-PRES-$caseId"
        run {
            val model = AIModel(id = "probe-model", name = "probe-model")
            val provider = Provider(
                id = "relay-pres-$caseId",
                kind = ProviderKind.Relay,
                relayRequested = RelayRequestedConfig(transport = transport),
                models = listOf(model),
            )
            val fragments = RelayWebFragmentStore(RelayWebFragmentStore.MemoryStore())
            if (case.getValue("hasFragment").jsonPrimitive.content == "true") {
                assertTrue(fragments.save(provider.id, transport, fragment.toString()) is RelayWebFragments.Validation.Ok)
            }
            val records = RelayWebProbeRecordStore(RelayWebProbeRecordStore.MemoryStore()) { 1L }
            (case["record"] as? JsonObject)?.let { record ->
                records.record(
                    RelayWebProbeRecordStore.Key(provider.id, model.id, transport.value),
                    RelayWebProbeRecord(
                        result = RelayWebProbeResult.entries.single { it.wire == record.string("result") },
                        source = RelayWebProbeSource.Tested,
                        at = 1L,
                        fragmentHash = if (record.string("fragmentHash") == "current") RelayWebProbe.fragmentHash(fragment) else "0".repeat(64),
                    ),
                )
            }
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
            val expect = case.getValue("expect").jsonObject
            val detail = "$message：$shape"
            val sends = records.sendable(provider.id, model.id, fragments.effective(provider)).containsKey(transport.value)
            assertEquals("$detail sendsFragment", expect.string("sendsFragment") == "true", sends)
            when (val statusId = expect.string("statusId")) {
                "web_probe_searched", "web_probe_silent", "web_probe_unverified" -> {
                    val disclosure = shape as? ModelOptionCapabilityShape.Disclosure
                    val res = mapOf(
                        "web_probe_searched" to R.string.model_options_relay_web_search_confirmed,
                        "web_probe_silent" to R.string.model_options_relay_web_no_search_in_test,
                        "web_probe_unverified" to R.string.model_options_relay_web_set_unverified,
                    ).getValue(statusId)
                    assertEquals(detail, res, disclosure?.status?.let(ModelOptionsRender::disclosureRes))
                    // Has a fragment and not rejected: the whole row is tappable and goes to that connection's web-search settings page.
                    assertTrue(detail, disclosure != null && ModelOptionsRender.disclosureTappable(disclosure.status))
                }
                "web_probe_rejected" -> {
                    val notice = shape as? ModelOptionCapabilityShape.Notice
                    assertEquals(detail, R.string.model_options_relay_web_rejected, notice?.status?.let(ModelOptionsRender::noticeStatusRes))
                    assertEquals(detail, R.string.model_options_relay_web_retest, notice?.body?.let(ModelOptionsRender::noticeBodyRes))
                    assertEquals(detail, "openConnectionWebSearch", expect.string("retestLink"))
                    // The only destination: tapping the row opens that connection's web-search settings page, and there is no separate "Open web search settings" entry.
                    assertEquals(detail, ModelOptionCapabilityShape.Escape.RelayWebRetest, notice?.escape)
                    assertEquals(detail, R.string.model_options_relay_web_retest, notice?.escape?.let(ModelOptionsRender::escapeRes))
                    assertTrue(detail, ModelOptionsTiles.capabilityTile(ModelOptionCapabilityShape.Capability.Web, shape).tappable)
                }
                "needs_manual_setup" -> {
                    val notice = shape as? ModelOptionCapabilityShape.Notice
                    assertEquals(detail, R.string.model_options_needs_manual_setup, notice?.status?.let(ModelOptionsRender::noticeStatusRes))
                    assertEquals(detail, ModelOptionCapabilityShape.Escape.ConnectionWebSearch, notice?.escape)
                }
                else -> error("unknown statusId $statusId")
            }
        }
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
                "RL2-WEBPROBE-PRES-auto_first_send_messages：$shape",
                R.string.model_options_relay_web_search_confirmed,
                (shape as? ModelOptionCapabilityShape.Disclosure)?.status?.let(ModelOptionsRender::disclosureRes),
            )
        } finally {
            field.set(lookup, previous)
        }
    }

    private companion object {
        val PRES_CASE_IDS = listOf(
            "fragment_searched_supported",
            "fragment_rejected_unsupported",
            "fragment_silent_unknown",
            "fragment_untested_unknown",
            "fragment_stale_record_is_untested",
            "no_fragment_needs_setup",
        )
    }

    private fun statusRes(english: String): Int = when (english) {
        "This connection can’t do this" -> R.string.model_options_connection_cannot
        "Set · not verified" -> R.string.model_options_relay_web_set_unverified
        "Needs manual setup" -> R.string.model_options_needs_manual_setup
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
