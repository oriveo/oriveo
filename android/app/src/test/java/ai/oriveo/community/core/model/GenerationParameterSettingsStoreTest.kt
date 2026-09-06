package ai.oriveo.community.core.model

import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import ai.oriveo.community.core.provider.LocalEngineGenerationProfiles
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.nio.file.Files
import java.nio.file.Path

private const val UPPER_PROVIDER = "9A1195DE-3AF9-5888-ABC8-B8177C458C07"
private const val UPPER_CONVERSATION = "7C9E6679-7425-40DE-944B-E07FC1F90AE7"

class GenerationParameterSettingsStoreTest {

    /** One instance for the whole class: building a Json format per call is measurably slow. */
    private val lenientJson = Json { ignoreUnknownKeys = true }

    @Test
    fun `connection scoped reasoning defaults merge only while the chip stays automatic`() {
        var payload: String? = null
        val store = GenerationParameterSettingsStore(readPayload = { payload }, writePayload = { payload = it })
        store.setModelDefaults(
            GenerationParameterOverrides(mapOf(
                "reasoning_effort" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive("high")),
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4)),
            )),
            providerID = "provider-a",
            modelID = "model-a",
        )

        val automatic = store.resolve(null, "provider-a", "model-a", "conversation-a", reasoningMode = ReasoningMode.Automatic)
        assertEquals(JsonPrimitive("high"), automatic?.values?.get("reasoning_effort")?.value)
        assertEquals(JsonPrimitive(0.4), automatic?.values?.get("temperature")?.value)

        val explicitChip = store.resolve(null, "provider-a", "model-a", "conversation-a", reasoningMode = ReasoningMode.Deep)
        assertNull(explicitChip?.values?.get("reasoning_effort"))
        assertEquals(JsonPrimitive(0.4), explicitChip?.values?.get("temperature")?.value)
    }

    @Test
    fun `session scoped reasoning never merges into generation overrides`() {
        var payload: String? = null
        val store = GenerationParameterSettingsStore(readPayload = { payload }, writePayload = { payload = it })
        store.setSessionOverrides(
            GenerationParameterOverrides(mapOf(
                "reasoning_effort" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive("high")),
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4)),
            )),
            providerID = "provider-a",
            modelID = "model-a",
            conversationID = "conversation-a",
        )

        val resolved = store.resolve(null, "provider-a", "model-a", "conversation-a", reasoningMode = ReasoningMode.Automatic)
        assertNull(resolved?.values?.get("reasoning_effort"))
        assertEquals(JsonPrimitive(0.4), resolved?.values?.get("temperature")?.value)
    }

    @Test
    fun `ordinary Relay exposes only current transport parameters as unknown explicit attempts`() {
        val profile = LocalEngineGenerationProfiles.profile(null, RelayTransport.AnthropicMessages)
        assertEquals("anthropic_messages", profile?.template)
        assertEquals("unknown", profile?.parameters?.firstOrNull { it.id == "temperature" }?.support)
        assertEquals("temperature", profile?.wire?.get("temperature"))
        assertNull(profile?.wire?.get("reasoning_effort"))
    }

    @Test
    fun `session model overrides do not leak and omit blocks model default`() {
        var payload: String? = null
        val store = GenerationParameterSettingsStore(readPayload = { payload }, writePayload = { payload = it })
        store.setModelDefaults(
            GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0)),
                "top_p" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.9)),
            )),
            providerID = "provider-a",
            modelID = "model-a",
        )
        store.setSessionOverrides(
            GenerationParameterOverrides(mapOf("top_p" to GenerationParameterOverride(GenerationOverrideState.Omit))),
            providerID = "provider-a",
            modelID = "model-a",
            conversationID = "conversation-a",
        )

        val first = store.resolve(null, "provider-a", "model-a", "conversation-a")
        assertEquals(JsonPrimitive(0), first?.values?.get("temperature")?.value)
        assertEquals(GenerationOverrideState.Omit, first?.values?.get("top_p")?.state)
        val second = store.resolve(null, "provider-a", "model-a", "conversation-b")
        assertEquals(JsonPrimitive(0.9), second?.values?.get("top_p")?.value)
        assertNull(store.modelDefaults("provider-a", "model-b"))

        store.setModelDefaults(
            GenerationParameterOverrides(mapOf("temperature" to GenerationParameterOverride(GenerationOverrideState.Inherit))),
            providerID = "provider-a",
            modelID = "model-a",
        )
        assertNull(store.modelDefaults("provider-a", "model-a"))

        store.setModelDefaults(
            GenerationParameterOverrides(mapOf("temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4)))),
            providerID = "provider-a",
            modelID = "model-a",
            profileFingerprint = "endpoint-a|openai_chat_completions",
        )

        assertEquals(
            JsonPrimitive(0.4),
            store.modelDefaults("provider-a", "model-a", "endpoint-b|anthropic_messages")
                ?.values?.get("temperature")?.value,
        )

        store.setSessionOverrides(
            GenerationParameterOverrides(mapOf("temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.3)))),
            providerID = "provider-a",
            modelID = "model-a",
            conversationID = "draft-a",
            profileFingerprint = "environment-a",
        )
        store.migrateSession("provider-a", "model-a", "draft-a", "conversation-a", "environment-a")
        assertNull(store.sessionOverrides("provider-a", "model-a", "draft-a", "environment-a"))
        assertEquals(
            JsonPrimitive(0.3),
            store.sessionOverrides("provider-a", "model-a", "conversation-a", "environment-a")
                ?.values?.get("temperature")?.value,
        )
        store.removeScopes(conversationID = "conversation-a")
        assertNull(store.sessionOverrides("provider-a", "model-a", "conversation-a", "environment-a"))
    }

    @Test
    fun `connection defaults are portable and lower priority than model defaults`() {
        var payload: String? = null
        val store = GenerationParameterSettingsStore(readPayload = { payload }, writePayload = { payload = it })
        store.setConnectionDefaults(
            GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.6)),
                "top_p" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.8)),
            )),
            providerID = "provider-a",
        )
        store.setModelDefaults(
            GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.2)),
            )),
            providerID = "provider-a",
            modelID = "model-a",
        )

        assertEquals(JsonPrimitive(0.2), store.resolve(null, "provider-a", "model-a", "conversation-a")?.values?.get("temperature")?.value)
        assertEquals(JsonPrimitive(0.8), store.resolve(null, "provider-a", "model-a", "conversation-a")?.values?.get("top_p")?.value)
        assertEquals(JsonPrimitive(0.6), store.resolve(null, "provider-a", "model-b", "conversation-a")?.values?.get("temperature")?.value)
    }

    @Test
    fun `presets remain model profile bound and exclude runtime settings`() {
        var payload: String? = null
        val store = GenerationParameterPresetStore(readPayload = { payload }, writePayload = { payload = it })
        val preset = store.save(
            name = "Precise",
            providerID = "provider-a",
            modelID = "model-a",
            profileFingerprint = "profile-a",
            values = GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.2)),
                "context_length" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(32768)),
            )),
        )
        assertNull(preset.values.values["context_length"])
        assertEquals(1, store.list("provider-a", "model-a", "profile-a").size)
        assertNull(store.apply(preset, "provider-a", "model-b", "profile-b"))
        assertEquals(
            JsonPrimitive(0.2),
            store.apply(preset, "provider-a", "model-b", "profile-b", mapOf("temperature" to "sampling_temperature"))
                ?.values?.get("sampling_temperature")?.value,
        )
        assertEquals(listOf(preset), store.list("provider-a", "model-b", "profile-b", setOf("temperature")))
        assertEquals(emptyList<GenerationParameterPreset>(), store.list("provider-a", "model-b", "profile-b", setOf("top_p")))
        store.removeScopes(providerID = "provider-a", modelID = "model-a")
        assertEquals(emptyList<GenerationParameterPreset>(), store.list("provider-a", "model-a", "profile-a"))
    }

    @Test
    fun `shared sync fixture merges deterministically and export excludes sensitive values`() {
        var settingsPayload: String? = null
        var presetPayload: String? = null
        var tombstonePayload: String? = null
        val settings = GenerationParameterSettingsStore(
            readPayload = { settingsPayload },
            writePayload = { settingsPayload = it },
        )
        val presets = GenerationParameterPresetStore(
            readPayload = { presetPayload },
            writePayload = { presetPayload = it },
        )
        val ledger = GenerationParameterSyncLedger(
            readPayload = { tombstonePayload },
            writePayload = { tombstonePayload = it },
        )
        val contract = GenerationParameterSyncContract(settings, presets, ledger)
        val fixture = Json.parseToJsonElement(String(Files.readAllBytes(findSharedFixture()))).jsonObject
        val remote = lenientJson.decodeFromJsonElement<GenerationParameterSyncPayload>(fixture.getValue("payload"))

        val merged = contract.merge(remote)
        assertEquals(2, merged.records.size)
        assertEquals(1, merged.presets.size)
        assertEquals(JsonPrimitive(0.4), settings.modelDefaults(
            "00000000-0000-0000-0000-000000000001",
            "gpt-test",
            "different|openai_chat_completions||gpt-test",
        )?.values?.get("temperature")?.value)

        settings.setModelDefaults(
            GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.3)),
                "context_length" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(32768)),
                "stop" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive("private prompt")),
                "json_schema" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive("private")),
                "custom_secret" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive("secret")),
            )),
            providerID = "provider-b",
            modelID = "model-b",
            profileFingerprint = "ep_private|openai_chat_completions||model-b",
        )
        val exported = contract.exportJSON()
        assertTrue(exported.contains("temperature"))
        assertFalse(exported.contains("ep_private"))
        assertFalse(exported.contains("context_length"))
        assertFalse(exported.contains("private prompt"))
        assertFalse(exported.contains("json_schema"))
        assertFalse(exported.contains("custom_secret"))

        val recordID = remote.records.first().recordId
        val deleted = contract.merge(GenerationParameterSyncPayload(
            tombstones = listOf(GenerationParameterSyncTombstone(recordID, 4, "device-z")),
        ))
        assertFalse(deleted.records.any { it.recordId == recordID })
        assertFalse(contract.merge(remote).records.any { it.recordId == recordID })
    }

    private class SyncHarness {
        var settingsPayload: String? = null
        var presetPayload: String? = null
        var tombstonePayload: String? = null
        val settings = GenerationParameterSettingsStore(
            readPayload = { settingsPayload },
            writePayload = { settingsPayload = it },
            putTombstone = { recordID, revision -> ledger.put(recordID, revision) },
            clearTombstone = { recordID -> ledger.clear(recordID) },
        )
        val presets = GenerationParameterPresetStore(
            readPayload = { presetPayload },
            writePayload = { presetPayload = it },
        )
        val ledger = GenerationParameterSyncLedger(
            readPayload = { tombstonePayload },
            writePayload = { tombstonePayload = it },
        )
        val contract = GenerationParameterSyncContract(settings, presets, ledger)
    }

    @Test
    fun `export merge writeback loop keeps local settings readable by uppercase provider id`() {
        val harness = SyncHarness()
        val providerID = UPPER_PROVIDER
        val conversationID = UPPER_CONVERSATION
        harness.settings.setModelDefaults(
            GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4)),
            )),
            providerID = providerID,
            modelID = "gpt-test",
        )
        harness.settings.setConnectionDefaults(
            GenerationParameterOverrides(mapOf(
                "top_p" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.8)),
            )),
            providerID = providerID,
        )
        harness.settings.setSessionOverrides(
            GenerationParameterOverrides(mapOf(
                "top_k" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(40)),
            )),
            providerID = providerID,
            modelID = "gpt-test",
            conversationID = conversationID,
        )

        val wire = harness.contract.exportPayload()
        assertTrue(wire.records.all { it.providerId == providerID.lowercase() })
        assertTrue(wire.records.all { it.recordId == it.recordId.lowercase() })
        harness.contract.merge(wire)

        assertEquals(
            JsonPrimitive(0.4),
            harness.settings.modelDefaults(providerID, "gpt-test")?.values?.get("temperature")?.value,
        )
        assertEquals(
            JsonPrimitive(0.8),
            harness.settings.connectionDefaults(providerID)?.values?.get("top_p")?.value,
        )
        val resolved = harness.settings.resolve(null, providerID, "gpt-test", conversationID)
        assertEquals(JsonPrimitive(40), resolved?.values?.get("top_k")?.value)
        assertEquals(JsonPrimitive(0.4), resolved?.values?.get("temperature")?.value)
        assertEquals(JsonPrimitive(0.8), resolved?.values?.get("top_p")?.value)
    }

    @Test
    fun `no-op sync preserves scope and preset updatedAt while a new remote winner advances it`() {
        val harness = SyncHarness()
        harness.settings.setModelDefaults(
            GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4)),
            )),
            providerID = "provider-a",
            modelID = "gpt-test",
            profileFingerprint = "endpoint|openai_chat_completions||gpt-test",
        )
        harness.presets.save(
            name = "Precise",
            providerID = "provider-a",
            modelID = "gpt-test",
            profileFingerprint = "endpoint|openai_chat_completions||gpt-test",
            values = GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4)),
            )),
        )
        val oldButLive = System.currentTimeMillis() - 179L * 24 * 60 * 60 * 1000
        harness.settings.replaceSyncRecords(harness.settings.syncRecords().map { it.copy(updatedAt = oldButLive) })
        harness.presets.replaceSyncRecords(harness.presets.syncRecords().map { it.copy(updatedAt = oldButLive - 1) })

        val wire = harness.contract.exportPayload()
        harness.contract.merge(wire)
        assertEquals(oldButLive, harness.settings.syncRecords().single().updatedAt)
        assertEquals(oldButLive - 1, harness.presets.syncRecords().single().updatedAt)
        assertEquals(
            JsonPrimitive(0.4),
            harness.settings.modelDefaults("provider-a", "gpt-test")?.values?.get("temperature")?.value,
        )

        val current = wire.records.single()
        harness.contract.merge(GenerationParameterSyncPayload(records = listOf(
            current.copy(
                values = mapOf(
                    "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.9)),
                ),
                revision = current.revision + 1,
                mutationId = "remote-newer",
            ),
        )))
        assertTrue((harness.settings.syncRecords().single().updatedAt ?: 0L) > oldButLive)
        assertEquals(
            JsonPrimitive(0.9),
            harness.settings.modelDefaults("provider-a", "gpt-test")?.values?.get("temperature")?.value,
        )
    }

    @Test
    fun `day 181 same-version replay stays expired while a higher revision refreshes TTL`() {
        val harness = SyncHarness()
        harness.settings.setModelDefaults(
            GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4)),
            )),
            providerID = "provider-a",
            modelID = "gpt-test",
            profileFingerprint = "endpoint|openai_chat_completions||gpt-test",
        )

        val sameVersionRemote = harness.contract.exportPayload()
        val expiredAt = System.currentTimeMillis() - 181L * 24 * 60 * 60 * 1000
        harness.settings.replaceSyncRecords(
            harness.settings.syncRecords().map { it.copy(updatedAt = expiredAt) },
        )

        assertNull(harness.settings.modelDefaults("provider-a", "gpt-test"))
        assertTrue(harness.contract.exportPayload().records.isEmpty())
        harness.contract.merge(sameVersionRemote)
        assertEquals(expiredAt, harness.settings.rawSyncRecords().single().updatedAt)
        assertNull(harness.settings.modelDefaults("provider-a", "gpt-test"))
        assertTrue(harness.contract.exportPayload().records.isEmpty())

        val current = sameVersionRemote.records.single()
        harness.contract.merge(GenerationParameterSyncPayload(records = listOf(
            current.copy(
                values = mapOf(
                    "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.9)),
                ),
                revision = current.revision + 1,
                mutationId = "remote-new-fact",
            ),
        )))
        assertEquals(
            JsonPrimitive(0.9),
            harness.settings.modelDefaults("provider-a", "gpt-test")?.values?.get("temperature")?.value,
        )
        assertTrue((harness.settings.syncRecords().single().updatedAt ?: 0L) > expiredAt)
    }

    @Test
    fun `record ids match the shared cross client fixture byte for byte`() {
        val fixture = Json.parseToJsonElement(String(Files.readAllBytes(findSharedFixture()))).jsonObject
        val idCasing = fixture.getValue("idCasing").jsonObject

        idCasing.getValue("canonicalCases").jsonArray.forEach { element ->
            val case = element.jsonObject
            val caseID = case.getValue("caseId").jsonPrimitive.content
            val merged = SyncHarness().contract.merge(GenerationParameterSyncPayload(
                tombstones = listOf(GenerationParameterSyncTombstone(
                    case.getValue("input").jsonPrimitive.content, 1, "device-canonical",
                )),
            ))
            assertEquals(caseID, listOf(case.getValue("canonical").jsonPrimitive.content), merged.tombstones.map { it.recordId })
        }

        idCasing.getValue("recordIdCases").jsonArray.forEach { element ->
            val case = element.jsonObject
            val caseID = case.getValue("caseId").jsonPrimitive.content
            val harness = SyncHarness()
            val providerID = case.getValue("providerId").jsonPrimitive.content
            val values = GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.5)),
            ))
            when (case.getValue("scope").jsonPrimitive.content) {
                "connection_default" -> harness.settings.setConnectionDefaults(values, providerID)
                "conversation_override" -> harness.settings.setSessionOverrides(
                    values,
                    providerID,
                    case.getValue("modelId").jsonPrimitive.content,
                    case.getValue("conversationId").jsonPrimitive.content,
                )
                else -> harness.settings.setModelDefaults(
                    values, providerID, case.getValue("modelId").jsonPrimitive.content,
                )
            }
            assertEquals(
                caseID,
                listOf(case.getValue("recordId").jsonPrimitive.content),
                harness.contract.exportPayload().records.map { it.recordId },
            )
        }
    }

    @Test
    fun `legacy uppercase remote record converges into one and tombstone still suppresses it`() {
        val harness = SyncHarness()
        harness.settings.setModelDefaults(
            GenerationParameterOverrides(mapOf(
                "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.4)),
            )),
            providerID = UPPER_PROVIDER,
            modelID = "gpt-test",
        )
        val canonicalRecordID = harness.contract.exportPayload().records.single().recordId
        val legacyRecordID = "scope:model:$UPPER_PROVIDER:gpt-test"
        assertTrue(legacyRecordID != canonicalRecordID)

        fun legacyRemote(revision: Int) = GenerationParameterSyncPayload(
            records = listOf(GenerationParameterSyncRecord(
                recordId = legacyRecordID,
                scope = "model_default",
                providerId = UPPER_PROVIDER,
                modelId = "gpt-test",
                values = mapOf(
                    "temperature" to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(0.9)),
                ),
                revision = revision,
                mutationId = "device-legacy",
            )),
        )

        val merged = harness.contract.merge(legacyRemote(5))
        assertEquals(1, merged.records.size)
        assertEquals(canonicalRecordID, merged.records.single().recordId)
        assertEquals(
            JsonPrimitive(0.9),
            harness.settings.modelDefaults(UPPER_PROVIDER, "gpt-test")?.values?.get("temperature")?.value,
        )

        val deleted = harness.contract.merge(GenerationParameterSyncPayload(
            tombstones = listOf(GenerationParameterSyncTombstone(legacyRecordID, 6, "device-legacy-delete")),
        ))
        assertEquals(emptyList<GenerationParameterSyncRecord>(), deleted.records)
        assertNull(harness.settings.modelDefaults(UPPER_PROVIDER, "gpt-test"))

        assertEquals(emptyList<GenerationParameterSyncRecord>(), harness.contract.merge(legacyRemote(5)).records)
    }

    private fun findSharedFixture(): Path = generateSequence(Path.of(System.getProperty("user.dir"))) { it.parent }
        .map { it.resolve("shared/model-contracts/generation_parameter_sync.v1.json") }
        .first(Files::exists)
}
