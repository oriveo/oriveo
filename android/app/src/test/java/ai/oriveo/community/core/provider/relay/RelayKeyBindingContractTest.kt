package ai.oriveo.community.core.provider.relay

import android.content.Context
import ai.oriveo.community.core.data.backup.BackupService
import ai.oriveo.community.core.data.mapper.ProviderMapper
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKeyStatus
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.feature.modelpicker.EnableCatalogModelResult
import ai.oriveo.community.feature.modelpicker.enableCatalogModel
import ai.oriveo.community.testing.TestSharedPreferences
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.zip.ZipInputStream

/**
 * Driven by the shared fixture `relay/key-binding.v1.json`: binding / key operations / read model / zero migration,
 * and the outbound exclusion of `connectionFields` in `portable-config.v1.json` (KEY-SYNC).
 * Fixture providers are all obtained through production storage decoding ([ProviderMapper]); zero migration and outbound exclusion go through production enabling, production catalog merge,
 * production Firestore write-out and production backup export.
 */
class RelayKeyBindingContractTest {

    private val fixture: JsonObject = Json.parseToJsonElement(
        generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .map { File(it, "shared/test-fixtures/relay/key-binding.v1.json") }
            .first { it.isFile }
            .readText(Charsets.UTF_8),
    ).jsonObject

    private val providerID = "22222222-2222-4222-8222-222222222222"

    private fun section(name: String): List<JsonObject> =
        fixture.getValue(name).jsonObject.getValue("cases").jsonArray.map { it.jsonObject }

    private fun case(section: String, id: String): JsonObject =
        section(section).single { it.getValue("caseId").jsonPrimitive.content == id }

    private fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun withName(models: JsonArray?): String =
        JsonArray(models.orEmpty().map { m -> JsonObject(mapOf("name" to m.jsonObject.getValue("id")) + m.jsonObject) }).toString()

    /** Fixture provider to production storage row to production decode; non-primary key values are filled from the fixture (simulating SecureKeyStore). */
    private fun decode(stored: JsonObject): Provider = with(ProviderMapper) {
        val base = Provider(id = providerID, kind = ProviderKind.Relay, baseUrlText = "https://relay.example.com/v1").toEntity()
        val keys = stored["relayKeys"]?.jsonArray?.map { it.jsonObject }
        val secrets = keys.orEmpty().associate { it.getValue("id").str()!! to it.getValue("apiKey").str()!! }
        base.copy(
            modelsJson = withName(stored["models"]?.jsonArray),
            catalogModelsJson = withName(stored["catalog"]?.jsonArray),
            relayKeysJson = keys?.let { list -> JsonArray(list.map { JsonObject(it - "apiKey") }).toString() },
        ).toDomain(stored.getValue("apiKey").str()!!) { secrets[it] }
    }

    private fun view(provider: Provider): JsonObject = buildJsonObject {
        put("apiKey", provider.apiKey)
        provider.relayKeys?.let { keys ->
            put("relayKeys", JsonArray(keys.map { key ->
                buildJsonObject {
                    put("id", key.id)
                    key.name?.let { put("name", it) }
                    put("apiKey", key.apiKey)
                    key.status?.let { status ->
                        put("status", buildJsonObject {
                            put("state", status.state)
                            status.httpStatus?.let { put("httpStatus", it) }
                        })
                    }
                }
            }))
        }
        put("models", JsonArray(provider.models.map { m ->
            buildJsonObject {
                put("id", m.id)
                m.relayKeyID?.let { put("relayKeyID", it) }
                m.relayDeniedKeyID?.let { put("relayDeniedKeyID", it) }
                m.relayTransport?.let { put("relayTransport", it.value) }
                m.relayTransportSource?.let { put("relayTransportSource", it.value) }
            }
        }))
        put("catalog", JsonArray(provider.catalogModels.map { m ->
            buildJsonObject {
                put("id", m.id)
                m.relayListedByKeyIDs?.let { ids -> put("relayListedByKeyIDs", JsonArray(ids.map { JsonPrimitive(it) })) }
            }
        }))
    }

    private fun assertBind(id: String) {
        val c = case("bindCases", id)
        val families = c.getValue("families").jsonObject.mapValues { it.value.str() }
        fun models(key: String) = c.getValue(key).jsonArray.map { e ->
            val o = e.jsonObject
            AIModel(
                id = o.getValue("id").str()!!,
                name = o.getValue("id").str()!!,
                relayKeyID = o["relayKeyID"].str(),
                relayListedByKeyIDs = o["relayListedByKeyIDs"]?.jsonArray?.map { it.str()!! },
            )
        }
        val actual = RelayKeyBinding.bind(
            keyIDs = c.getValue("keys").jsonArray.map { it.str()!! },
            catalog = models("catalog"),
            enabled = models("enabled"),
            targetModelID = c.getValue("target").str()!!,
            family = { families[it] },
        )
        assertEquals(id, c.getValue("expect").str(), actual)
    }

    private fun assertOps(id: String) {
        val c = case("opsCases", id)
        val op = c.getValue("op").jsonObject
        val provider = decode(c.getValue("provider").jsonObject)
        val result: Provider? = when (op.getValue("type").str()) {
            "add" -> RelayKeyBinding.add(provider, op.getValue("id").str()!!, op["name"].str(), op.getValue("apiKey").str()!!)
            "rename" -> RelayKeyBinding.rename(provider, op.getValue("id").str()!!, op["name"].str())
            "replaceSecret" -> RelayKeyBinding.replaceSecret(provider, op.getValue("id").str()!!, op.getValue("apiKey").str()!!)
            "move" -> RelayKeyBinding.move(provider, op.getValue("id").str()!!, op.getValue("toIndex").jsonPrimitive.intOrNull!!)
            "delete" -> RelayKeyBinding.delete(provider, op.getValue("id").str()!!)
            "rebind" -> RelayKeyBinding.rebind(provider, op.getValue("modelID").str()!!, op.getValue("keyID").str()!!)
            else -> error("unknown op")
        }
        val expect = c.getValue("expect")
        if (expect.str() == "refused") {
            assertNull(id, result)
            return
        }
        assertEquals(id, expect.jsonObject, view(result!!))
        // Invariant: the first key in the list stores an empty value; the primary key value lives in provider.apiKey.
        result.relayKeys?.let { assertEquals("$id: primary key entry is stored empty", "", it.first().apiKey) }
    }

    private fun assertRead(id: String) {
        val c = case("readCases", id)
        val provider = decode(c.getValue("provider").jsonObject)
        val expect = c.getValue("expect").jsonObject
        assertEquals(id, expect.getValue("showsKeyUI").jsonPrimitive.booleanOrNull, RelayKeyBinding.showsKeyUI(provider))
        val rows = RelayKeyBinding.rows(provider).map { row ->
            buildJsonObject {
                put("id", row.id)
                put("name", row.name?.let { JsonPrimitive(it) } ?: JsonNull)
                put("isPrimary", row.isPrimary)
                put("status", row.status?.let { JsonPrimitive(it) } ?: JsonNull)
                put("catalogCount", row.catalogCount)
                put("enabledCount", row.enabledCount)
            }
        }
        assertEquals("$id: rows", expect.getValue("rows").jsonArray.toList(), rows)
        for ((modelID, model) in expect.getValue("models").jsonObject) {
            val state = RelayKeyBinding.modelState(provider, modelID)
            val o = model.jsonObject
            assertEquals("$id/$modelID", o.getValue("boundKeyID").str(), state.boundKeyID)
            assertEquals("$id/$modelID", o.getValue("alternateKeyIDs").jsonArray.map { it.str() }, state.alternateKeyIDs)
            assertEquals("$id/$modelID", o.getValue("deniedOnCurrentKey").jsonPrimitive.booleanOrNull, state.deniedOnCurrentKey)
        }
    }

    @Test
    fun `KEY-BIND-single_key_writes_nothing`() = assertBind("single_key_writes_nothing")

    @Test
    fun `KEY-BIND-only_one_key_lists_target`() = assertBind("only_one_key_lists_target")

    @Test
    fun `KEY-BIND-several_keys_follow_enabled_same_family`() = assertBind("several_keys_follow_enabled_same_family")

    @Test
    fun `KEY-BIND-several_keys_no_family_enabled_first_in_key_order`() = assertBind("several_keys_no_family_enabled_first_in_key_order")

    @Test
    fun `KEY-BIND-family_key_not_listing_target_is_ignored`() = assertBind("family_key_not_listing_target_is_ignored")

    @Test
    fun `KEY-BIND-other_family_enabled_is_ignored`() = assertBind("other_family_enabled_is_ignored")

    @Test
    fun `KEY-BIND-manual_id_follows_same_family`() = assertBind("manual_id_follows_same_family")

    @Test
    fun `KEY-BIND-manual_id_no_family_uses_primary`() = assertBind("manual_id_no_family_uses_primary")

    @Test
    fun `KEY-BIND-enabled_without_key_id_counts_as_primary`() = assertBind("enabled_without_key_id_counts_as_primary")

    @Test
    fun `KEY-BIND-enabled_dangling_key_id_counts_as_primary`() = assertBind("enabled_dangling_key_id_counts_as_primary")

    @Test
    fun `KEY-BIND-unknown_target_family_never_matches`() = assertBind("unknown_target_family_never_matches")

    @Test
    fun `KEY-BIND-legacy_catalog_entry_counts_as_primary_listing`() = assertBind("legacy_catalog_entry_counts_as_primary_listing")

    @Test
    fun `KEY-OPS-add_key_materializes_list_and_pins_models`() = assertOps("add_key_materializes_list_and_pins_models")

    @Test
    fun `KEY-OPS-rename_key`() = assertOps("rename_key")

    @Test
    fun `KEY-OPS-replace_secret_clears_status_and_denial_keeps_catalog`() = assertOps("replace_secret_clears_status_and_denial_keeps_catalog")

    @Test
    fun `KEY-OPS-replace_primary_secret_writes_api_key`() = assertOps("replace_primary_secret_writes_api_key")

    @Test
    fun `KEY-OPS-reorder_moves_primary_secret`() = assertOps("reorder_moves_primary_secret")

    @Test
    fun `KEY-OPS-delete_key_rebinds_to_primary_and_prunes_catalog`() = assertOps("delete_key_rebinds_to_primary_and_prunes_catalog")

    @Test
    fun `KEY-OPS-delete_primary_promotes_next`() = assertOps("delete_primary_promotes_next")

    @Test
    fun `KEY-OPS-delete_last_key_is_refused`() = assertOps("delete_last_key_is_refused")

    @Test
    fun `KEY-OPS-add_empty_id_is_refused`() = assertOps("add_empty_id_is_refused")

    @Test
    fun `KEY-OPS-add_duplicate_id_is_refused`() = assertOps("add_duplicate_id_is_refused")

    @Test
    fun `KEY-OPS-rename_unknown_id_is_refused`() = assertOps("rename_unknown_id_is_refused")

    @Test
    fun `KEY-OPS-replace_unknown_id_is_refused`() = assertOps("replace_unknown_id_is_refused")

    @Test
    fun `KEY-OPS-delete_unknown_id_is_refused`() = assertOps("delete_unknown_id_is_refused")

    @Test
    fun `KEY-OPS-move_out_of_range_is_refused`() = assertOps("move_out_of_range_is_refused")

    @Test
    fun `KEY-OPS-rebind_unknown_key_is_refused`() = assertOps("rebind_unknown_key_is_refused")

    @Test
    fun `KEY-OPS-rebind_model_not_enabled_is_refused`() = assertOps("rebind_model_not_enabled_is_refused")

    @Test
    fun `KEY-OPS-implicit_rename_is_refused`() = assertOps("implicit_rename_is_refused")

    @Test
    fun `KEY-OPS-implicit_move_is_refused`() = assertOps("implicit_move_is_refused")

    @Test
    fun `KEY-OPS-implicit_rebind_is_refused`() = assertOps("implicit_rebind_is_refused")

    @Test
    fun `KEY-OPS-rebind_clears_denial_and_reachable_transport`() = assertOps("rebind_clears_denial_and_reachable_transport")

    @Test
    fun `KEY-OPS-rebind_keeps_user_transport`() = assertOps("rebind_keeps_user_transport")

    @Test
    fun `KEY-OPS-add_to_single_entry_list_keeps_primary_status`() = assertOps("add_to_single_entry_list_keeps_primary_status")

    @Test
    fun `KEY-OPS-replace_secret_single_entry_list_clears_status`() = assertOps("replace_secret_single_entry_list_clears_status")

    @Test
    fun `KEY-READ-single_entry_list_with_status`() = assertRead("single_entry_list_with_status")

    @Test
    fun `KEY-READ-legacy_single_key`() = assertRead("legacy_single_key")

    @Test
    fun `KEY-READ-two_keys_with_denial`() = assertRead("two_keys_with_denial")


    @Test
    fun `fixture case count matches what this class covers`() {
        assertEquals(RelayKeyBinding.IMPLICIT_KEY_ID, fixture.getValue("implicitKeyID").str())
        assertEquals(RelayKeyStatus.STATES, fixture.getValue("keyStatusStates").jsonArray.map { it.str() })
        assertEquals(12, section("bindCases").size)
        assertEquals(23, section("opsCases").size)
        assertEquals(3, section("readCases").size)
        assertEquals(4, section("legacyCases").size)
    }

    /** Supplementary rule shared by all platforms: add is rejected on an existing id; delete also removes the deleted id from the listers of enabled models. */
    @Test
    fun `KEY-OPS add duplicate id is refused and delete prunes enabled listings`() {
        val provider = decode(case("opsCases", "rename_key").getValue("provider").jsonObject)
        assertNull(RelayKeyBinding.add(provider, "k-b", "dup", "sk-x"))
        assertNull(RelayKeyBinding.add(provider, "initial", null, "sk-x"))

        val withListing = provider.copy(
            models = listOf(
                AIModel(id = "gpt-4o", name = "gpt-4o", relayKeyID = "initial", relayListedByKeyIDs = listOf("initial", "k-b")),
                AIModel(id = "claude-opus-4", name = "claude-opus-4", relayKeyID = "k-b", relayListedByKeyIDs = listOf("k-b")),
            ),
        )
        val deleted = RelayKeyBinding.delete(withListing, "k-b")!!
        assertEquals(listOf("initial"), deleted.models.single { it.id == "gpt-4o" }.relayListedByKeyIDs)
        assertNull(deleted.models.single { it.id == "claude-opus-4" }.relayListedByKeyIDs)
        assertEquals("initial", deleted.models.single { it.id == "claude-opus-4" }.relayKeyID)
    }

    /** Ruling shared by all platforms: with an implicit single key (no key list), rename / move / rebind are always rejected without writing fields; a nonexistent id is rejected too. */
    @Test
    fun `KEY-OPS implicit single key refuses rename move rebind and unknown ids`() {
        val single = decode(case("legacyCases", "decode_has_one_implicit_key").getValue("stored").jsonObject)
        assertNull(single.relayKeys)
        val model = single.models.firstOrNull()?.id ?: "gpt-4o"
        assertNull(RelayKeyBinding.rename(single, "initial", "x"))
        assertNull(RelayKeyBinding.move(single, "initial", 0))
        assertNull(RelayKeyBinding.rebind(single, model, "initial"))

        val multi = decode(case("opsCases", "rebind_keeps_user_transport").getValue("provider").jsonObject)
        assertNull(RelayKeyBinding.rename(multi, "k-missing", "x"))
        assertNull(RelayKeyBinding.move(multi, "k-missing", 0))
        assertNull(RelayKeyBinding.rebind(multi, "gpt-4o", "k-missing"))
        assertNull(RelayKeyBinding.rebind(multi, "model-missing", "k-b"))
    }

    // ── Zero migration (legacyCases): production decode + production enabling / production catalog merge, persisted without any new fields ──

    private val newModelKeys = listOf("relayKeyID", "relayListedByKeyIDs", "relayDeniedKeyID")

    private fun assertNothingNewPersisted(id: String, provider: Provider) {
        val entity = with(ProviderMapper) { provider.toEntity() }
        assertNull("$id: relayKeysPersisted", entity.relayKeysJson)
        for (stored in listOf(entity.modelsJson, entity.catalogModelsJson)) {
            for (model in Json.parseToJsonElement(stored).jsonArray) {
                val leaked = model.jsonObject.keys intersect newModelKeys.toSet()
                assertTrue("$id: modelKeyFieldsPersisted $leaked", leaked.isEmpty())
            }
        }
    }

    @Test
    fun `KEY-LEGACY-decode_has_one_implicit_key`() {
        val c = case("legacyCases", "decode_has_one_implicit_key")
        val provider = decode(c.getValue("stored").jsonObject)
        val expect = c.getValue("expect").jsonObject
        assertNull(provider.relayKeys)
        assertEquals(expect.getValue("keyIDs").jsonArray.map { it.str() }, RelayKeyBinding.keyIDs(provider))
        for ((model, secret) in expect.getValue("resolve").jsonObject) {
            assertEquals(model, secret.str(), ProviderCredentialResolver.apiKey(provider, model.takeIf { it != "null" }))
        }
    }

    @Test
    fun `KEY-LEGACY-enable_writes_no_key_id`() = runTest {
        val c = case("legacyCases", "enable_writes_no_key_id")
        val provider = decode(c.getValue("stored").jsonObject)
        val repository = mockk<ProviderRepository>()
        val written = slot<Provider>()
        coEvery { repository.getById(providerID) } returns provider
        coEvery { repository.updateProvider(capture(written)) } returns Unit
        val result = enableCatalogModel(repository, providerID, c.getValue("enable").str()!!)
        assertTrue(result is EnableCatalogModelResult.Added)
        assertEquals(listOf("gpt-4o", "gpt-4.1"), written.captured.models.map { it.id })
        assertNothingNewPersisted("enable_writes_no_key_id", written.captured)
    }

    @Test
    fun `KEY-LEGACY-catalog_refresh_writes_no_listing`() = assertLegacyRefresh("catalog_refresh_writes_no_listing")

    @Test
    fun `KEY-LEGACY-catalog_refresh_failure_writes_status_only`() = assertLegacyRefresh("catalog_refresh_failure_writes_status_only")

    /**
     * Production catalog refresh ([ProviderRepository.refreshRelayCatalogOnly], upstream MockEngine): even a single key writes the primary key status as a list entry
     * , and no model-level key field is written; on failure the catalog stays as it was.
     */
    private fun assertLegacyRefresh(id: String) = runTest {
        val c = case("legacyCases", id)
        val stored = c.getValue("stored").jsonObject
        val provider = decode(stored).copy(
            relayRequested = ai.oriveo.community.core.model.RelayRequestedConfig(
                transport = ai.oriveo.community.core.model.RelayTransport.OpenAIChatCompletions,
                resolvedAPIBaseURL = "https://relay.example.com/v1",
            ),
        )
        val secret = stored.getValue("apiKey").str()!!
        val refresh = c.getValue("refresh").jsonObject
        val harness = ai.oriveo.community.core.data.repository.RelayKeyStatusRepositoryHarness(
            initial = provider,
            primarySecret = secret,
            catalogs = refresh["ok"]?.jsonArray?.let { ids -> mapOf(secret to ids.map { it.str()!! }) }.orEmpty(),
        )
        refresh["status"]?.let { status ->
            assertEquals("$id: fixture failure shape matches the fake upstream", 401, status.jsonPrimitive.intOrNull)
        }
        harness.repository.refreshRelayCatalogOnly(providerID)

        val expect = c.getValue("expect").jsonObject
        val written = harness.current()
        // Catalog order is each platform's display sort, not part of the zero-migration rule: compare as sets.
        assertEquals("$id: catalogIDs", expect.getValue("catalogIDs").jsonArray.map { it.str() }.sortedBy { it }, written.catalogModels.map { it.id }.sorted())
        assertEquals("$id: relayKeysPersisted", expect.getValue("relayKeysPersisted").jsonPrimitive.booleanOrNull, harness.relayKeysPersisted())
        val keys = written.relayKeys.orEmpty()
        val expectedKeys = expect.getValue("relayKeys").jsonArray.map { it.jsonObject }
        assertEquals("$id: relayKeys ids", expectedKeys.map { it.getValue("id").str() to it.getValue("apiKey").str() }, keys.map { it.id to it.apiKey })
        expectedKeys.zip(keys).forEach { (e, key) ->
            val status = e.getValue("status").jsonObject
            assertEquals("$id: state", status.getValue("state").str(), key.status?.state)
            status["httpStatus"]?.let { assertEquals("$id: httpStatus", it.jsonPrimitive.intOrNull, key.status?.httpStatus) }
        }
        val entity = harness.stored!!
        for (json in listOf(entity.modelsJson, entity.catalogModelsJson)) {
            for (model in Json.parseToJsonElement(json).jsonArray) {
                val leaked = model.jsonObject.keys intersect newModelKeys.toSet()
                assertTrue("$id: modelKeyFieldsPersisted $leaked", leaked.isEmpty())
            }
        }
    }

    /** With 2+ keys production enabling writes relayKeyID by the binding rule (the enabling wiring itself, not a fixture case). */
    @Test
    fun `KEY-BIND enable on a multi-key connection writes the bound key`() = runTest {
        val provider = decode(case("opsCases", "delete_key_rebinds_to_primary_and_prunes_catalog").getValue("provider").jsonObject)
        val repository = mockk<ProviderRepository>()
        val written = slot<Provider>()
        coEvery { repository.getById(providerID) } returns provider
        coEvery { repository.updateProvider(capture(written)) } returns Unit
        enableCatalogModel(repository, providerID, "gpt-4o")
        assertEquals("initial", written.captured.models.single { it.id == "gpt-4o" }.relayKeyID)
    }

    // ── Outbound exclusion (portable-config connectionFields)──

    @Test
    fun `KEY-SYNC-relay_keys_local_only`() = runTest {
        val provider = decode(case("opsCases", "rename_key").getValue("provider").jsonObject).copy(
            models = listOf(AIModel(id = "claude-opus-4", name = "claude-opus-4", relayKeyID = "k-b", relayDeniedKeyID = "k-b")),
            catalogModels = listOf(AIModel(id = "claude-opus-4", name = "claude-opus-4", relayListedByKeyIDs = listOf("k-b"))),
        )
        // First confirm the subject really carries the list and non-primary key values, otherwise the not-present checks below are vacuous.
        assertEquals("sk-b", provider.relayKeys!![1].apiKey)


        val account = "account-a"
        val backup = BackupService(
            providerDao = mockk(relaxed = true),
            conversationDao = mockk(relaxed = true),
            messageDao = mockk(relaxed = true),
            folderDao = mockk(relaxed = true),
            skillDao = mockk(relaxed = true),
            noteDao = mockk(relaxed = true),
            noteFolderDao = mockk(relaxed = true),
            json = Json { ignoreUnknownKeys = true; encodeDefaults = true },
            secureKeyStore = mockk(relaxed = true),
            attachmentStore = mockk(relaxed = true),
            preferenceDao = mockk(relaxed = true),
            metadataRefresh = {},
            runInTransaction = { it() },
        ).exportSyntheticBackup(providers = listOf(provider), folders = emptyList(), conversations = emptyList())
        val archive = buildString {
            ZipInputStream(backup.inputStream()).use { zip ->
                while (zip.nextEntry != null) append(String(zip.readBytes(), Charsets.UTF_8))
            }
        }
        assertTrue("The backup should contain this connection", archive.contains(providerID))
        assertFalse("The backup contains relayKeys", archive.contains("relayKeys"))
        assertFalse("The backup contains a non-primary key value", archive.contains("sk-b"))

        // Local storage round trip: the Room row holds no key values, and non-primary key values come back unchanged through SecureKeyStore.
        val context = mockk<Context> { every { applicationContext } returns this@mockk }
        val store = SecureKeyStore(context, TestSharedPreferences(), Unit)
        val entity = with(ProviderMapper) { provider.toEntity(account) }
        assertNotNull(entity.relayKeysJson)
        assertFalse("The Room row contains a key value", entity.toString().contains("sk-b") || entity.toString().contains("sk-a"))
        store.saveRelayKeySecrets(account, entity.id, provider.relayKeys)
        val restored = with(ProviderMapper) {
            entity.toDomain(provider.apiKey) { store.getRelayKeySecret(account, entity.id, it) }
        }
        assertEquals(provider.relayKeys, restored.relayKeys)
        assertEquals(provider.models, restored.models)
        assertEquals(provider.catalogModels, restored.catalogModels)

        // Deleting a provider deletes them together; after deleting a key its value no longer stays in storage.
        store.saveRelayKeySecrets(account, entity.id, listOf(RelayKey(id = "initial")))
        assertNull(store.getRelayKeySecret(account, entity.id, "k-b"))
        store.saveRelayKeySecrets(account, entity.id, provider.relayKeys)
        store.deleteRelayKeySecrets(account, entity.id)
        assertNull(store.getRelayKeySecret(account, entity.id, "k-b"))
    }

    /** A malformed list drops the bad entries instead of failing the whole connection decode. */
    @Test
    fun `stored relay keys decode leniently`() {
        val decoded = ProviderMapper.decodeRelayKeys(
            """[{"id":"initial"},{"id":7},{"name":"x"},{"id":"k-b","name":3,"status":{"state":"weird"}},""" +
                """{"id":"k-b"},{"id":"k-c","status":{"state":"limited","httpStatus":429}}]""",
        )
        assertEquals(
            listOf(RelayKey("initial"), RelayKey("k-b"), RelayKey("k-c", status = RelayKeyStatus("limited", 429))),
            decoded,
        )
        assertNull(ProviderMapper.decodeRelayKeys("{\"id\":\"initial\"}"))
        assertNull(ProviderMapper.decodeRelayKeys("not json"))
    }
}
