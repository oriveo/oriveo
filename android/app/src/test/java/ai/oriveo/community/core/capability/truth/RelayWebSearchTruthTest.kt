package ai.oriveo.community.core.capability.truth

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Relay web_search truth is judged by the local probe record (fixture `web-probe.v1.json` presentationCases,
 * same-named RL2-WEBPROBE-STATE-<caseId> on all three platforms). Segments and records are written to the production shared store (no Context in unit tests, so in process memory),
 * state is fetched via the production [RelayTruthAdapter]; whether a control is sent per segment goes through the same filter function as chat, [RelayWebProbeRecordStore.sendable].
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
    fun `RL2-WEBPROBE-STATE fixture caseId maps one to one to the per-case tests on this platform`() {
        assertEquals(CASE_IDS, cases().map { it.string("caseId") })
    }

    @Test fun `RL2-WEBPROBE-STATE-fragment_searched_supported`() = stateCase("fragment_searched_supported")
    @Test fun `RL2-WEBPROBE-STATE-fragment_rejected_unsupported`() = stateCase("fragment_rejected_unsupported")
    @Test fun `RL2-WEBPROBE-STATE-fragment_silent_unknown`() = stateCase("fragment_silent_unknown")
    @Test fun `RL2-WEBPROBE-STATE-fragment_untested_unknown`() = stateCase("fragment_untested_unknown")
    @Test fun `RL2-WEBPROBE-STATE-fragment_stale_record_is_untested`() = stateCase("fragment_stale_record_is_untested")
    @Test fun `RL2-WEBPROBE-STATE-no_fragment_needs_setup`() = stateCase("no_fragment_needs_setup")

    private fun stateCase(caseId: String) {
        val case = cases().single { it.string("caseId") == caseId }
        val expect = case.getValue("expect").jsonObject
        val transport = RelayTransport.OpenAIChatCompletions
        val fragment = RelayWebFragments.template(transport)!!
        val model = AIModel(id = "truth-model", name = "truth-model")
        val provider = Provider(
            id = "relay-truth-$caseId",
            kind = ProviderKind.Relay,
            relayRequested = RelayRequestedConfig(transport = transport),
            models = listOf(model),
        )
        usedProviderIds += provider.id
        val fragments = RelayWebFragmentStore.shared
        val records = RelayWebProbeRecordStore.shared
        if (case.getValue("hasFragment").jsonPrimitive.content == "true") {
            assertTrue(fragments.save(provider.id, transport, fragment.toString()) is RelayWebFragments.Validation.Ok)
        }
        (case["record"] as? JsonObject)?.let { record ->
            val written = records.record(
                RelayWebProbeRecordStore.Key(provider.id, model.id, transport.value),
                RelayWebProbeRecord(
                    result = RelayWebProbeResult.entries.single { it.wire == record.string("result") },
                    source = RelayWebProbeSource.Tested,
                    at = 1L,
                    fragmentHash = if (record.string("fragmentHash") == "current") {
                        RelayWebProbe.fragmentHash(fragment)
                    } else {
                        RelayWebProbe.fragmentHash(RelayWebFragments.template(RelayTransport.AnthropicMessages)!!)
                    },
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
        val message = "RL2-WEBPROBE-STATE-$caseId candidates=$candidates"
        assertEquals("$message state", expect.string("state"), state)
        val sends = records.sendable(provider.id, model.id, fragments.effective(provider)).containsKey(transport.value)
        assertEquals("$message sendsFragment", expect.string("sendsFragment") == "true", sends)
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
            "fragment_searched_supported",
            "fragment_rejected_unsupported",
            "fragment_silent_unknown",
            "fragment_untested_unknown",
            "fragment_stale_record_is_untested",
            "no_fragment_needs_setup",
        )
    }
}
