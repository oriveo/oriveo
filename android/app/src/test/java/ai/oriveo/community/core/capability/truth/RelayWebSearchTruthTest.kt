package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayCapabilityOverrides
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.relay.RelayWebFragmentStore
import ai.oriveo.community.core.provider.relay.RelayWebFragments
import ai.oriveo.community.core.provider.relay.RelayWebProbe
import ai.oriveo.community.core.provider.relay.RelayWebProbeRecord
import ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore
import ai.oriveo.community.core.provider.relay.RelayWebProbeResult
import ai.oriveo.community.core.provider.relay.RelayWebProbeSource
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Relay web_search truth = user override > the current record under the first-send transport's effective fragment (stored ?? template) > unknown
 * (fixture `web-probe.v1.json` presentationCases `truth`, same-named RL2-WEBPROBE-STATE-<caseId> on all three platforms). Fragments and records are written to the production shared store
 * (no Context in unit tests, so in process memory), overrides are written on the model, and state is fetched via the production [RelayTruthAdapter].
 */
class RelayWebSearchTruthTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val usedProviderIds = mutableListOf<String>()

    @After
    fun tearDown() {
        usedProviderIds.forEach {
            RelayWebFragmentStore.shared.remove(it)
            RelayWebProbeRecordStore.shared.clearConnection(it)
        }
    }

    @Test
    fun `RL2-WEBPROBE-08 STATE fixture caseId maps one to one to the per-case tests on this platform`() {
        assertEquals(CASE_IDS, cases().map { it.string("caseId") })
    }

    @Test fun `RL2-WEBPROBE-STATE-template_untested_default_off`() = stateCase("template_untested_default_off")
    @Test fun `RL2-WEBPROBE-STATE-template_untested_toggled_on_sends_template`() = stateCase("template_untested_toggled_on_sends_template")
    @Test fun `RL2-WEBPROBE-STATE-template_searched_is_current`() = stateCase("template_searched_is_current")
    @Test fun `RL2-WEBPROBE-STATE-template_silent_unknown`() = stateCase("template_silent_unknown")
    @Test fun `RL2-WEBPROBE-STATE-template_rejected_keeps_toggle_on`() = stateCase("template_rejected_keeps_toggle_on")
    @Test fun `RL2-WEBPROBE-STATE-saved_default_on_keeps_old_behaviour`() = stateCase("saved_default_on_keeps_old_behaviour")
    @Test fun `RL2-WEBPROBE-STATE-saved_toggled_off_sends_nothing`() = stateCase("saved_toggled_off_sends_nothing")
    @Test fun `RL2-WEBPROBE-STATE-saved_rejected_links_web_search_page`() = stateCase("saved_rejected_links_web_search_page")
    @Test fun `RL2-WEBPROBE-STATE-stale_record_is_untested`() = stateCase("stale_record_is_untested")
    @Test fun `RL2-WEBPROBE-STATE-user_off_wins`() = stateCase("user_off_wins")
    @Test fun `RL2-WEBPROBE-STATE-user_on_wins_over_rejected`() = stateCase("user_on_wins_over_rejected")
    @Test fun `RL2-WEBPROBE-STATE-template_rejected_toggled_off_no_notice`() = stateCase("template_rejected_toggled_off_no_notice")

    private fun stateCase(caseId: String) {
        val case = cases().single { it.string("caseId") == caseId }
        val expect = case.getValue("expect").jsonObject
        val transport = RelayTransport.OpenAIChatCompletions
        val template = RelayWebFragments.template(transport)!!
        val saved = JsonObject(mapOf("web_search_options" to JsonObject(mapOf("search_context_size" to JsonPrimitive("low")))))
        val hasSaved = case.string("savedFragment") == "true"
        val effective = if (hasSaved) saved else template
        val userOverride = (case.getValue("userOverride") as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content?.toBooleanStrict()
        val model = AIModel(
            id = "truth-model",
            name = "truth-model",
            relayCapabilityOverrides = userOverride?.let { RelayCapabilityOverrides(web = it) },
        )
        val provider = Provider(
            id = "relay-truth-$caseId",
            kind = ProviderKind.Relay,
            relayRequested = RelayRequestedConfig(transport = transport),
            models = listOf(model),
        )
        usedProviderIds += provider.id
        val fragments = RelayWebFragmentStore.shared
        val records = RelayWebProbeRecordStore.shared
        if (hasSaved) assertTrue(fragments.save(provider.id, transport, saved.toString()) is RelayWebFragments.Validation.Ok)
        (case["record"] as? JsonObject)?.let { record ->
            val written = records.record(
                RelayWebProbeRecordStore.Key(provider.id, model.id, transport.value),
                RelayWebProbeRecord(
                    result = RelayWebProbeResult.entries.single { it.wire == record.string("result") },
                    source = RelayWebProbeSource.Tested,
                    at = 1L,
                    fragmentHash = if (record.string("fragmentHash") == "current") RelayWebProbe.fragmentHash(effective) else "0".repeat(64),
                ),
            )
            assertTrue("RL2-WEBPROBE-STATE-$caseId record written", written != null)
        }
        val candidates = RelayTruthAdapter.candidates(
            CapabilityTruthAdapter.Input(
                provider = provider,
                model = model,
                key = "web_search",
                queryIdentity = null,
                current = null,
                finalTransport = null,
                metadataClient = MetadataClient(),
            ),
        )
        val state = candidates.singleOrNull()?.support ?: "unknown"
        assertEquals("RL2-WEBPROBE-STATE-$caseId candidates=$candidates", expect.string("truth"), state)
    }

    private fun cases(): List<JsonObject> = readJson("shared/test-fixtures/relay/web-probe.v1.json")
        .getValue("presentationCases").jsonObject.getValue("cases").jsonArray.map { it.jsonObject }

    private fun JsonObject.string(name: String): String = getValue(name).jsonPrimitive.content

    private fun readJson(relative: String): JsonObject {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val file = File(dir, relative)
            if (file.isFile) return json.parseToJsonElement(file.readText()).jsonObject
            dir = dir.parentFile
        }
        error("fixture not found: $relative")
    }

    private companion object {
        val CASE_IDS = listOf(
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
}
