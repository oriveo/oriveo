package ai.oriveo.community.core.model

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

/**
 * Consumes `localLifecycleInvariants.cases` of the shared capability preference contract: a web /
 * reasoning choice must read back the same value through every read path after every lifecycle
 * event (sync self-echo, wire cap, recipe revision bump, first-send draft migration, local eviction).
 * Reads go through the same store entries the composer and the send path use
 * ([displayedForUi] / [resolvedForRequest]).
 */
class CapabilityPreferenceLocalLifecycleContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    private class Harness {
        var raw: String? = null
        var drafts: String? = null
        val store = CapabilityPreferenceStore({ raw }, { raw = it }, { drafts }, { drafts = it })
    }

    @Test
    fun localLifecycleCaseSetMatchesContract() {
        val fixtureIds = cases().map { it.string("caseId") }.toSet()
        assertEquals(COVERED_CASES, fixtureIds)
    }

    @Test
    fun cpl01MergeKeepsLocalRecordBeyondWireCap() {
        val case = case("CPL-01")
        val identity = case.obj("identity")
        val seed = case.obj("seed")
        val values = values(seed.obj("values"))
        val providerID = identity.string("providerId")
        val modelID = identity.string("canonicalModelId")
        val transport = identity.string("transportIdentity")
        val harness = Harness()
        // Local storage legitimately holds more than the wire cap (e.g. after earlier merges); seed it
        // directly in ascending write order.
        val seeded = (0 until seed.getValue("count").jsonPrimitive.int).map { index ->
            CapabilityPreferenceRecord(
                scope = seed.string("scope"), providerID = providerID, modelID = modelID,
                conversationID = conversationId(seed.string("conversationIdPattern"), index),
                transportIdentity = transport, values = values, revision = 1, mutationID = "seed-$index",
            )
        }
        harness.raw = "{\"records\":${json.encodeToString(ListSerializer(CapabilityPreferenceRecord.serializer()), seeded)}}"

        val exported = harness.store.exportPayload()
        assertEquals(case.obj("expected").getValue("exportedRecordCount").jsonPrimitive.int, exported.records.size)
        harness.store.merge(exported)

        val expected = case.obj("expected")
        assertEquals(
            "a local record beyond the wire head survives the self-echo merge",
            values(expected.obj("lookupValues")),
            sendRead(harness.store, providerID, modelID, expected.string("lookupConversationId"), transport),
        )
    }

    @Test
    fun cpl02SelfEchoKeepsUppercaseConversationLookup() {
        val case = case("CPL-02")
        val identity = case.obj("identity")
        val write = case.obj("write")
        val providerID = identity.string("providerId")
        val modelID = identity.string("canonicalModelId")
        val transport = identity.string("transportIdentity")
        val harness = Harness()
        harness.store.setConversation(values(write.obj("values")), providerID, modelID, write.string("conversationId"), transport)

        val exported = harness.store.exportPayload()
        val expected = case.obj("expected")
        assertEquals(expected.string("exportedConversationId"), exported.records.single().conversationId)
        harness.store.merge(exported)

        expected.getValue("lookups").jsonArray.map { it.jsonObject }.forEach { lookup ->
            val conversationID = lookup.string("conversationId")
            assertEquals(
                "lookup by $conversationID after self-echo (send path)",
                values(lookup.obj("values")),
                sendRead(harness.store, providerID, modelID, conversationID, transport),
            )
            assertEquals(
                "lookup by $conversationID after self-echo (display path)",
                values(lookup.obj("values")),
                displayRead(harness.store, providerID, modelID, conversationID, transport),
            )
        }
    }

    @Test
    fun cpl03SendResolutionForwardPortsSameTransport() {
        val case = case("CPL-03")
        val write = case.obj("write")
        val providerID = write.string("providerId")
        val modelID = write.string("canonicalModelId")
        val conversationID = write.string("conversationId")
        val harness = Harness()
        harness.store.setConversation(values(write.obj("values")), providerID, modelID, conversationID, write.string("transportIdentity"))

        case.getValue("reads").jsonArray.map { it.jsonObject }.forEach { read ->
            val transport = read.string("transportIdentity")
            val actual = when (val path = read.string("path")) {
                "send" -> sendRead(harness.store, providerID, modelID, conversationID, transport)
                "display" -> displayRead(harness.store, providerID, modelID, conversationID, transport)
                else -> error("unknown read path $path")
            }
            assertEquals("${read.string("path")} read under $transport", values(read.obj("expected")), actual)
        }
    }

    @Test
    fun cpl04DraftMigrationForwardPortsSameTransport() {
        val case = case("CPL-04")
        val write = case.obj("write")
        val action = case.obj("action")
        val expected = case.obj("expected")
        val providerID = write.string("providerId")
        val modelID = write.string("canonicalModelId")
        val draftID = write.string("draftId")
        val draftTransport = write.string("transportIdentity")
        val currentTransport = action.string("currentTransportIdentity")
        val harness = Harness()
        harness.store.setDraftConversation(values(write.obj("values")), providerID, modelID, draftID, draftTransport)

        harness.store.migrateDraftConversation(providerID, modelID, draftID, action.string("migrateDraftTo"), currentTransport)

        val lookup = expected.obj("conversationLookup")
        assertEquals(
            "migrated draft reads back on the real conversation",
            values(lookup.obj("values")),
            sendRead(harness.store, providerID, modelID, lookup.string("conversationId"), lookup.string("transportIdentity")),
        )
        assertEquals(false, expected.getValue("draftRemains").jsonPrimitive.content.toBoolean())
        assertNull("source draft is removed", harness.store.draftConversation(providerID, modelID, draftID, draftTransport))
        assertNull("no draft left under the current identity", harness.store.draftConversation(providerID, modelID, draftID, currentTransport))
    }

    @Test
    fun cpl05LocalEvictionByRecencyNotRecordId() {
        val case = case("CPL-05")
        val identity = case.obj("identity")
        val seed = case.obj("seed")
        val write = case.obj("write")
        val expected = case.obj("expected")
        val providerID = identity.string("providerId")
        val modelID = identity.string("canonicalModelId")
        val transport = identity.string("transportIdentity")
        val harness = Harness()
        val seedValues = values(seed.obj("values"))
        (0 until seed.getValue("count").jsonPrimitive.int).forEach { index ->
            harness.store.setConversation(seedValues, providerID, modelID, conversationId(seed.string("conversationIdPattern"), index), transport)
        }
        harness.store.setConversation(values(write.obj("values")), providerID, modelID, write.string("conversationId"), transport)

        val localRecords = json.parseToJsonElement(requireNotNull(harness.raw)).jsonObject.getValue("records").jsonArray
        assertEquals(expected.getValue("localRecordCount").jsonPrimitive.int, localRecords.size)
        val unset = CapabilityPreferenceValues()
        expected.getValue("retained").jsonArray.forEach {
            val conversationID = it.jsonPrimitive.content
            assertTrue(
                "retained $conversationID",
                sendRead(harness.store, providerID, modelID, conversationID, transport) != unset,
            )
        }
        expected.getValue("evicted").jsonArray.forEach {
            val conversationID = it.jsonPrimitive.content
            assertEquals("evicted $conversationID", unset, sendRead(harness.store, providerID, modelID, conversationID, transport))
        }
    }

    @Test
    fun cpl06MergeKeepsLocalRecordPushedOutByRemote() {
        val case = case("CPL-06")
        val identity = case.obj("identity")
        val seed = case.obj("seed")
        val expected = case.obj("expected")
        val providerID = identity.string("providerId")
        val modelID = identity.string("canonicalModelId")
        val transport = identity.string("transportIdentity")
        val harness = Harness()
        val seedValues = values(seed.obj("values"))
        (0 until seed.getValue("count").jsonPrimitive.int).forEach { index ->
            harness.store.setConversation(seedValues, providerID, modelID, conversationId(seed.string("conversationIdPattern"), index), transport)
        }
        val remoteExtra = json.decodeFromJsonElement(CapabilityPreferenceSyncRecord.serializer(), case.getValue("remoteExtraRecord"))
        val local = harness.store.exportPayload()
        val remote = local.copy(records = (local.records + remoteExtra).sortedBy { it.recordId })

        val merged = harness.store.merge(remote)

        val exportedCount = expected.getValue("exportedRecordCount").jsonPrimitive.int
        assertEquals("merged envelope keeps the wire cap", exportedCount, merged.records.size)
        assertEquals("exported envelope keeps the wire cap", exportedCount, harness.store.exportPayload().records.size)
        assertEquals(
            "local record pushed out of the envelope by the remote record still reads back",
            values(expected.obj("lookupValues")),
            sendRead(harness.store, providerID, modelID, expected.string("lookupConversationId"), transport),
        )
        assertEquals(
            "remote connection record is adopted",
            values(expected.obj("connectionValues")),
            harness.store.scopeValues(providerID, modelID, null, null, transport).connection,
        )
    }

    private fun sendRead(
        store: CapabilityPreferenceStore, providerID: String, modelID: String, conversationID: String, transport: String,
    ) = store.resolvedForRequest(providerID, ProviderKind.OpenAI, modelID, conversationID, null, transport)

    private fun displayRead(
        store: CapabilityPreferenceStore, providerID: String, modelID: String, conversationID: String, transport: String,
    ) = store.displayedForUi(providerID, ProviderKind.OpenAI, modelID, conversationID, null, transport)

    private fun values(element: JsonObject) = CapabilityPreferenceValues(
        web = CapabilityWebPreference.entries.first { it.name.equals(element.string("web"), ignoreCase = true) },
        reasoningIntent = element.getValue("reasoningIntent").takeUnless { it is JsonNull }?.jsonPrimitive?.content,
    )

    /** Expands `00000000-0000-4000-8000-{index:012d}`. */
    private fun conversationId(pattern: String, index: Int): String =
        pattern.replace("{index:012d}", index.toString().padStart(12, '0'))

    private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.content
    private fun JsonObject.obj(key: String) = getValue(key).jsonObject

    private fun case(prefix: String): JsonObject =
        cases().single { it.string("caseId").startsWith("${prefix}_") }

    private fun cases(): List<JsonObject> {
        val root: JsonElement = json.parseToJsonElement(contractText())
        return root.jsonObject.getValue("localLifecycleInvariants").jsonObject.getValue("cases").jsonArray.map { it.jsonObject }
    }

    private fun contractText(): String {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve(SHARED_DIR + "/model-contracts/capability_preference_sync.v1.json") }
            .firstOrNull(Files::exists) ?: error("capability preference fixture not found")
        return String(Files.readAllBytes(path), Charsets.UTF_8)
    }

    companion object {
        // Repository shared-contract directory name, built at runtime to keep this source ASCII.
        private val SHARED_DIR = "shared"
        private val COVERED_CASES = setOf(
            "CPL-01_merge_keeps_local_record_beyond_wire_cap",
            "CPL-02_self_echo_keeps_uppercase_conversation_lookup",
            "CPL-03_send_resolution_forward_ports_same_transport",
            "CPL-04_draft_migration_forward_ports_same_transport",
            "CPL-05_local_eviction_by_recency_not_record_id",
            "CPL-06_merge_keeps_local_record_pushed_out_by_remote",
        )
    }
}
