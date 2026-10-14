package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityPreferenceStore
import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.model.displayedForUi
import ai.oriveo.community.core.provider.relay.RelayWebChat
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The fixed identity of the relay web switch preference (fixture `web-probe.v1.json` preferenceIdentity, same-named RL2-WEBPROBE-KEY-<caseId> on all three platforms).
 * The identity goes through the production [RelayWebPreferenceIdentity], reads and writes through the production [CapabilityPreferenceStore] (the same entry points as the composer / send coordinator / first-send migration).
 */
class RelayWebPreferenceIdentityTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val block: JsonObject by lazy { readJson("shared/test-fixtures/relay/web-probe.v1.json").getValue("preferenceIdentity").jsonObject }

    private var backing: String? = null
    private var drafts: String? = null
    private fun store() = CapabilityPreferenceStore(read = { backing }, write = { backing = it }, readDrafts = { drafts }, writeDrafts = { drafts = it })

    @Test
    fun `RL2-WEBPROBE-KEY fixture caseIds map one-to-one to the per-case tests here`() {
        assertEquals(
            listOf("identity_ignores_transport", "write_before_transport_decided_reads_after", "legacy_transport_record_is_read_and_moved", "fixed_record_wins_over_legacy"),
            cases().map { it.string("caseId") },
        )
        assertEquals(block.string("wire"), RelayWebPreferenceIdentity.STORAGE_IDENTITY)
        assertEquals(block.string("fixedTransport"), RelayWebPreferenceIdentity.FINAL_TRANSPORT)
        assertEquals(block.string("fixedRevision"), RelayWebPreferenceIdentity.RUNTIME_REVISION)
    }

    @Test
    fun `RL2-WEBPROBE-KEY-identity_ignores_transport`() {
        val case = case("identity_ignores_transport")
        val expect = case.getValue("expect").jsonObject
        val identities = case.getValue("transports").jsonArray.map { transport ->
            val (provider, model) = relay(case.string("modelId"), transport.nullableString())
            RelayWebPreferenceIdentity.resolve(provider, model)!!
        }
        identities.forEach {
            assertEquals(expect.string("wire"), it.storageIdentity)
            assertEquals(expect.string("canonicalModelId"), it.canonicalModelId)
        }
        // The same record: written with the identity of an undecided protocol, it reads back the same value under every protocol.
        val (provider, _) = relay(case.string("modelId"), null)
        store().setConnectionModel(CapabilityPreferenceValues(web = CapabilityWebPreference.Automatic), provider.id, identities.first().canonicalModelId, identities.first().storageIdentity)
        val reads = identities.map { read(provider, it, conversationID = "c1", existing = true) }
        assertEquals(expect.string("sameRecordForAll").toBooleanStrict(), reads.all { it == CapabilityWebPreference.Automatic })
    }

    @Test
    fun `RL2-WEBPROBE-KEY-write_before_transport_decided_reads_after`() {
        val case = case("write_before_transport_decided_reads_after")
        val steps = case.getValue("steps").jsonArray.map { it.jsonObject }
        val (provider, model) = relay(case.string("modelId"), steps[0].nullableString("transport"))
        val draft = "draft-session"
        // Before sending (protocol undecided): the composer writes the draft layer.
        val before = RelayWebPreferenceIdentity.resolve(provider, model)!!
        store().setDraftConversation(CapabilityPreferenceValues(web = CapabilityWebPreference.Automatic), provider.id, before.canonicalModelId, draft, before.storageIdentity)
        // First send: the draft record moves to the real conversation when it is created (ChatSendCommandCoordinator), after which the model protocol is written as Chat.
        val conversation = steps[1].string("conversation")
        store().migrateDraftConversation(provider.id, before.canonicalModelId, draft, conversation, before.storageIdentity)
        val (afterProvider, afterModel) = relay(case.string("modelId"), steps[1].string("transportAfter"))
        val after = RelayWebPreferenceIdentity.resolve(afterProvider, afterModel)!!
        val expect = case.getValue("expect").jsonObject
        val web = read(afterProvider, after, expect.string("readConversation"), existing = true)
        val isOn = RelayWebChat.of(afterProvider, afterModel)!!.isOn(web)
        assertEquals(expect.string("isOn").toBooleanStrict(), isOn)
    }

    @Test fun `RL2-WEBPROBE-KEY-legacy_transport_record_is_read_and_moved`() = legacyCase("legacy_transport_record_is_read_and_moved")
    @Test fun `RL2-WEBPROBE-KEY-fixed_record_wins_over_legacy`() = legacyCase("fixed_record_wins_over_legacy")

    private fun legacyCase(caseId: String) {
        val case = case(caseId)
        val expect = case.getValue("expect").jsonObject
        val (provider, model) = relay(case.string("modelId"), null)
        val fixed = RelayWebPreferenceIdentity.resolve(provider, model)!!
        val legacy = case.getValue("legacyRecord").jsonObject
        check(legacy.string("scope") == "connection_model")
        val legacyIdentity = ModelControlRuntimeIdentity(provider.id, fixed.canonicalModelId, legacy.string("finalTransport"), legacy.string("runtimeRevision"))
        // The record under the old identity carries a thinking tier: forwarding carries only web.
        store().setConnectionModel(
            CapabilityPreferenceValues(web = preference(legacy.string("web")), reasoningIntent = "deep"),
            provider.id, fixed.canonicalModelId, legacyIdentity.storageIdentity,
        )
        (case["fixedRecord"] as? JsonObject)?.let { record ->
            check(record.string("scope") == "connection_model")
            store().setConnectionModel(CapabilityPreferenceValues(web = preference(record.string("web"))), provider.id, fixed.canonicalModelId, fixed.storageIdentity)
        }
        val fixedBefore = fixedRecords()
        val web = read(provider, fixed, conversationID = "c1", existing = true)
        assertEquals("$caseId isOn", expect.string("isOn").toBooleanStrict(), RelayWebChat.of(provider, model)!!.isOn(web))
        val fixedAfter = fixedRecords()
        assertEquals("$caseId fixedRecordWritten", expect.string("fixedRecordWritten").toBooleanStrict(), fixedAfter != fixedBefore)
        if (fixedAfter != fixedBefore) {
            val written = fixedAfter.single()
            assertEquals("connection_model", written.scope)
            assertEquals(legacy.string("web"), written.web)
            assertNull("only web is forwarded", written.reasoningIntent)
        }
        // The old record stays in place and the thinking tier remains under the protocol-bearing identity.
        assertTrue(store().exportPayload().records.any { it.transportIdentity == legacyIdentity.storageIdentity && it.reasoningIntent == "deep" })
    }

    private fun fixedRecords() = store().exportPayload().records.filter { it.transportIdentity == RelayWebPreferenceIdentity.STORAGE_IDENTITY }

    /** The same entry the composer panel reads through (displayedForUi). */
    private fun read(provider: Provider, identity: ModelControlRuntimeIdentity, conversationID: String, existing: Boolean): CapabilityWebPreference =
        store().displayedForUi(
            providerID = provider.id,
            providerKind = provider.kind,
            modelID = identity.canonicalModelId,
            conversationID = conversationID,
            skillID = null,
            transportIdentity = identity.storageIdentity,
            isExistingConversation = existing,
        ).web

    private fun preference(wire: String): CapabilityWebPreference = CapabilityWebPreference.entries.single { it.name.equals(wire, true) }

    private fun relay(modelId: String, transport: String?): Pair<Provider, AIModel> {
        val model = AIModel(
            id = modelId,
            name = modelId,
            relayTransport = transport?.let { wire -> RelayTransport.entries.single { it.value == wire } },
            relayTransportSource = transport?.let { RelayTransportSource.Observed },
        )
        return Provider(
            id = CONNECTION_ID,
            kind = ProviderKind.Relay,
            baseUrlText = "https://relay.example.com",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.Auto),
            models = listOf(model),
        ) to model
    }

    private fun cases(): List<JsonObject> = block.getValue("cases").jsonArray.map { it.jsonObject }
    private fun case(caseId: String): JsonObject = cases().single { it.string("caseId") == caseId }
    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content
    private fun JsonObject.nullableString(key: String): String? = get(key)?.nullableString()
    private fun kotlinx.serialization.json.JsonElement.nullableString(): String? =
        (this as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content

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
        const val CONNECTION_ID = "77777777-7777-4777-8777-777777777777"
    }
}
