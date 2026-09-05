package ai.oriveo.community.core.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths

class CapabilityPreferenceSyncContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun r3FixtureDecodesCompleteRuntimeIdentityAndPreservesWireKeys() {
        val fixture = json.parseToJsonElement(contractText()) .jsonObject
        val payload = json.decodeFromJsonElement(CapabilityPreferenceSyncPayload.serializer(), fixture.getValue("payload"))
        assertEquals(2, payload.schemaVersion)
        assertEquals(4, payload.records.size)
        assertEquals(
            "scope:conversation:9a1195de-3af9-5888-abc8-b8177c458c07:gpt-test:$RESPONSES_R7:7c9e6679-7425-40de-944b-e07fc1f90ae7",
            payload.records[2].recordId,
        )
        assertEquals("max", payload.records[2].reasoningIntent)
        payload.records.forEach { record ->
            val local = CapabilityPreferenceRecord(
                scope = record.scope, providerID = record.providerId, modelID = record.canonicalModelId,
                conversationID = record.conversationId, skillID = record.skillId, transportIdentity = record.transportIdentity,
                values = CapabilityPreferenceValues(CapabilityWebPreference.entries.first { it.name.equals(record.web, true) }, record.reasoningIntent),
                revision = record.revision, mutationID = record.mutationId,
            )
            assertEquals(record.recordId, CapabilityPreferenceStore.recordID(local))
        }
        val encoded = json.encodeToJsonElement(CapabilityPreferenceSyncPayload.serializer(), payload).jsonObject
        val record = encoded.getValue("records").jsonArray.first().jsonObject
        assertTrue("flat R3 wire has recordId", "recordId" in record)
        assertTrue("canonical model is a separate identity field", "canonicalModelId" in record)
        assertFalse("nested local values must never sync", "values" in record)
        assertFalse("raw/custom must never sync", record.values.any { it.toString().contains("custom", ignoreCase = true) })
        val tombstone = encoded.getValue("tombstones").jsonArray.first().jsonObject
        assertTrue("tombstone uses canonical camelCase", "recordId" in tombstone && "mutationId" in tombstone)
    }

    @Test
    fun exportRejectsCustomAndImportRejectsInvalidEnums() {
        var raw: String? = null
        val store = CapabilityPreferenceStore({ raw }, { raw = it })
        store.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Custom, "deep"), "9A1195DE-3AF9-5888-ABC8-B8177C458C07", "gpt", RESPONSES_R7,
        )
        assertTrue(store.exportPayload().records.isEmpty())
        val invalid = CapabilityPreferenceSyncPayload(records = listOf(
            CapabilityPreferenceSyncRecord("scope:model:a:model:transport", "connection_model", "a", "model", transportIdentity = "transport", web = "custom", revision = 1, mutationId = "a"),
        ))
        assertTrue(store.merge(invalid).records.isEmpty())
    }

    @Test
    fun tombstoneWinsOlderRecordAndNewerReconfirmationWinsTombstone() {
        var raw: String? = null
        val store = CapabilityPreferenceStore({ raw }, { raw = it })
        val record = CapabilityPreferenceSyncRecord(
            "scope:skill:9a1195de-3af9-5888-abc8-b8177c458c07:gpt:$RESPONSES_R7:3fa85f64-5717-4562-b3fc-2c963f66afa6",
            "skill_agent", "9a1195de-3af9-5888-abc8-b8177c458c07", "gpt", skillId = "3fa85f64-5717-4562-b3fc-2c963f66afa6",
            transportIdentity = RESPONSES_R7, web = "automatic", revision = 6, mutationId = "z",
        )
        val tombstone = CapabilityPreferenceTombstone(record.recordId, 7, "b")
        assertTrue(store.merge(CapabilityPreferenceSyncPayload(records = listOf(record), tombstones = listOf(tombstone))).records.isEmpty())
        assertEquals(1, store.merge(CapabilityPreferenceSyncPayload(records = listOf(record.copy(revision = 8, mutationId = "a")))).records.size)
    }

    @Test
    fun localTombstoneCannotBeRevivedByOlderOrLosingEqualRemoteRecord() {
        val record = validSkillRecord(revision = 6, mutationID = "remote-old")
        var deletedRaw: String? = null
        val deletedStore = CapabilityPreferenceStore({ deletedRaw }, { deletedRaw = it })
        deletedStore.merge(CapabilityPreferenceSyncPayload(
            tombstones = listOf(CapabilityPreferenceTombstone(record.recordId, 7, "local-delete")),
        ))

        assertTrue(deletedStore.merge(CapabilityPreferenceSyncPayload(records = listOf(record))).records.isEmpty())
        assertTrue(deletedStore.merge(CapabilityPreferenceSyncPayload(records = listOf(
            record.copy(revision = 7, mutationId = "a-loses-to-delete"),
        ))).records.isEmpty())
        assertEquals(1, deletedStore.merge(CapabilityPreferenceSyncPayload(records = listOf(
            record.copy(revision = 7, mutationId = "z-explicit-reconfirm"),
        ))).records.size)

        var recordedRaw: String? = null
        val recordedStore = CapabilityPreferenceStore({ recordedRaw }, { recordedRaw = it })
        recordedStore.merge(CapabilityPreferenceSyncPayload(records = listOf(
            record.copy(revision = 7, mutationId = "a-record"),
        )))
        assertTrue(recordedStore.merge(CapabilityPreferenceSyncPayload(tombstones = listOf(
            CapabilityPreferenceTombstone(record.recordId, 7, "z-delete"),
        ))).records.isEmpty())
    }

    /**
     * The composer chip, the model control panel, and the outbound request path must all go
     * through the same [resolvedForRequest], and it must always carry the real
     * `conversation.skillId`. Previously the UI side hard-coded skillID to null, so a
     * skill_agent scope's web/reasoning state was completely invisible in the UI.
     */
    @Test
    fun `skill agent scope is visible only when the real skill id is carried`() {
        var raw: String? = null
        val store = CapabilityPreferenceStore({ raw }, { raw = it })
        val providerID = "9a1195de-3af9-5888-abc8-b8177c458c07"
        val skillID = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
        val conversationID = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
        store.confirmSkillAgent(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID, "gpt-test", skillID, RESPONSES_R7,
        )

        val outbound = store.resolvedForRequest(
            providerID = providerID,
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-test",
            conversationID = conversationID,
            skillID = skillID,
            transportIdentity = RESPONSES_R7,
        )
        assertEquals(CapabilityWebPreference.Automatic, outbound.web)
        assertEquals("deep", outbound.reasoningIntent)

        // Negative check: a plain conversation with no skill must never see the skill_agent
        // record -- otherwise "making it visible" could regress into leaking the skill scope
        // into every conversation.
        val plainConversation = store.resolvedForRequest(
            providerID = providerID,
            providerKind = ProviderKind.OpenAI,
            modelID = "gpt-test",
            conversationID = conversationID,
            skillID = null,
            transportIdentity = RESPONSES_R7,
        )
        assertEquals(CapabilityWebPreference.Off, plainConversation.web)
        // null means "provider default", which is not the same thing as the user explicitly choosing "off" (turning reasoning off).
        assertEquals(null, plainConversation.reasoningIntent)

        // Negative check: when the user really did choose "off", it must still resolve to "off" -- otherwise the guard above would end up swallowing that case too.
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Off, "off"),
            providerID, "gpt-test", conversationID, RESPONSES_R7,
        )
        assertEquals(
            "off",
            store.resolvedForRequest(providerID, ProviderKind.OpenAI, "gpt-test", conversationID, null, RESPONSES_R7)
                .reasoningIntent,
        )

        // A read with no real transport identity always fails closed, rather than silently reusing a stored value.
        assertEquals(
            CapabilityPreferenceValues(),
            store.resolvedForRequest(providerID, ProviderKind.OpenAI, "gpt-test", conversationID, skillID, ""),
        )
    }

    @Test
    fun invalidTombstonesCannotEnterTheLocalLwwLedgerAndColonSegmentsRemainValid() {
        var raw: String? = null
        val store = CapabilityPreferenceStore({ raw }, { raw = it })
        val fixture = json.parseToJsonElement(contractText()).jsonObject
        val invalid = fixture.getValue("invalidTombstoneCases").jsonArray.map { element ->
            val value = element.jsonObject
            CapabilityPreferenceTombstone(
                recordID = value.getValue("recordId").jsonPrimitive.content,
                revision = value.getValue("revision").jsonPrimitive.content.toInt(),
                mutationID = value.getValue("mutationId").jsonPrimitive.content,
            )
        }
        val rejected = store.merge(CapabilityPreferenceSyncPayload(tombstones = invalid))
        assertTrue(rejected.tombstones.isEmpty())

        val validColonRecord = "scope:conversation:9a1195de-3af9-5888-abc8-b8177c458c07:llama3:latest:$RESPONSES_R7:7c9e6679-7425-40de-944b-e07fc1f90ae7"
        val accepted = store.merge(
            CapabilityPreferenceSyncPayload(
                tombstones = listOf(CapabilityPreferenceTombstone(validColonRecord, 8, "remote-valid-colon-delete")),
            ),
        )
        assertEquals(listOf(validColonRecord), accepted.tombstones.map { it.recordID })
    }

    @Test
    fun identitySwitchAndLegacyUpgradeKeepStoredValuesDormant() {
        val providerID = "9a1195de-3af9-5888-abc8-b8177c458c07"
        val conversationID = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
        var raw: String? = null
        val store = CapabilityPreferenceStore({ raw }, { raw = it })
        store.setConversation(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID,
            "model/a",
            conversationID,
            RESPONSES_R7,
        )
        assertEquals(
            CapabilityWebPreference.Automatic,
            store.resolvedForRequest(
                providerID, ProviderKind.OpenAI, "model/a", conversationID, null, RESPONSES_R7,
            ).web,
        )
        assertEquals(
            CapabilityPreferenceValues(),
            store.resolvedForRequest(
                providerID, ProviderKind.OpenAI, "model/b", conversationID, null, RESPONSES_R7,
            ),
        )
        // When only the recipe version changes but the underlying protocol stays the same, a
        // read is no longer treated as dormant -- the read chain now looks further back for a
        // matching lineage. It used to be that any identity change made a read come back empty,
        // which is exactly why pushing a new recipe from the server made a user's web/reasoning
        // choices from the week before look like they'd never been set; the full case-by-case
        // matrix lives in `CapabilityPreferenceReadLadderTest`. A reset back to defaults only
        // happens once the protocol itself actually changes:
        assertEquals(
            CapabilityWebPreference.Automatic,
            store.resolvedForRequest(
                providerID, ProviderKind.OpenAI, "model/a", conversationID, null, RESPONSES_R8,
            ).web,
        )
        assertEquals(
            "switching protocols means switching to a different request contract; carrying old values across would mean guessing on the user's behalf",
            CapabilityPreferenceValues(),
            store.resolvedForRequest(
                providerID, ProviderKind.OpenAI, "model/a", conversationID, null, CHAT_R8,
            ),
        )

        val legacyRaw = """[{"scope":"conversation_connection_model","providerID":"$providerID","canonicalModelId":"model/a","conversationID":"$conversationID","transportIdentity":"openai_responses","values":{"web":"Automatic","reasoningIntent":"deep"},"revision":99,"mutationID":"legacy"}]"""
        val legacyStore = CapabilityPreferenceStore({ legacyRaw }, {})
        assertEquals(
            CapabilityPreferenceValues(),
            legacyStore.resolvedForRequest(
                providerID, ProviderKind.OpenAI, "model/a", conversationID, null, RESPONSES_R7,
            ),
        )
        assertTrue("legacy incomplete runtime identity never re-enters sync", legacyStore.exportPayload().records.isEmpty())
    }

    @Test
    fun coldStartRestoresWinnerAndConnectionDeleteTombstonesEveryIdentityVariant() {
        val providerID = "9a1195de-3af9-5888-abc8-b8177c458c07"
        var raw: String? = null
        val firstProcess = CapabilityPreferenceStore({ raw }, { raw = it })
        firstProcess.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Automatic, "deep"),
            providerID,
            "model/a",
            RESPONSES_R7,
        )
        firstProcess.setConnectionModel(
            CapabilityPreferenceValues(CapabilityWebPreference.Force, "max"),
            providerID,
            "model/a",
            RESPONSES_R8,
        )
        val preDelete = firstProcess.exportPayload().records

        val coldStart = CapabilityPreferenceStore({ raw }, { raw = it })
        assertEquals(
            CapabilityWebPreference.Automatic,
            coldStart.resolved(providerID, "model/a", null, null, RESPONSES_R7).web,
        )
        assertEquals(
            CapabilityWebPreference.Force,
            coldStart.resolved(providerID, "model/a", null, null, RESPONSES_R8).web,
        )
        coldStart.removeScopes(providerID = providerID)
        val deleted = coldStart.exportPayload()
        assertTrue(deleted.records.isEmpty())
        assertEquals(2, deleted.tombstones.size)
        val afterStaleMerge = coldStart.merge(CapabilityPreferenceSyncPayload(records = preDelete))
        assertTrue("deleted identities cannot be resurrected by stale cold-start data", afterStaleMerge.records.isEmpty())
    }

    private fun contractText(): String {
        val path = generateSequence(Paths.get("").toAbsolutePath()) { it.parent }
            .map { it.resolve("shared/model-contracts/capability_preference_sync.v1.json") }
            .firstOrNull(Files::exists) ?: error("capability preference fixture not found")
        return String(Files.readAllBytes(path), Charsets.UTF_8)
    }

    private fun validSkillRecord(revision: Int, mutationID: String) = CapabilityPreferenceSyncRecord(
        recordId = "scope:skill:9a1195de-3af9-5888-abc8-b8177c458c07:gpt:$RESPONSES_R7:3fa85f64-5717-4562-b3fc-2c963f66afa6",
        scope = "skill_agent",
        providerId = "9a1195de-3af9-5888-abc8-b8177c458c07",
        canonicalModelId = "gpt",
        skillId = "3fa85f64-5717-4562-b3fc-2c963f66afa6",
        transportIdentity = RESPONSES_R7,
        web = "automatic",
        revision = revision,
        mutationId = mutationID,
    )

    companion object {
        private const val RESPONSES_R7 = "r1.b3BlbmFpX3Jlc3BvbnNlcw.cnVudGltZS1yNw"
        private const val RESPONSES_R8 = "r1.b3BlbmFpX3Jlc3BvbnNlcw.cnVudGltZS1yOA"

        /** A different protocol (not just another recipe version): the lookback must stop here. */
        private const val CHAT_R8 = "r1.b3BlbmFpX2NoYXQ.cnVudGltZS1yOA"
    }
}
