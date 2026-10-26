package ai.oriveo.community.core.provider

import ai.oriveo.community.core.data.remote.ModelLifecycle
import ai.oriveo.community.core.data.remote.RetiredModel
import java.io.File
import java.time.Instant
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Shared fixture `shared/test-fixtures/provider-catalog/model-retired.v1.json`, case by case:
 * retired-model status of a conversation, display-name fallback, and model selection fallback for a new conversation (the rules follow the fixture `$comment`).
 */
class ModelRetiredFixtureTest {

    // -- Fixture --

    private val fixture: JsonObject by lazy {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "shared/test-fixtures/provider-catalog/model-retired.v1.json")
            if (candidate.exists()) return@lazy Json.parseToJsonElement(candidate.readText()).jsonObject
            dir = dir.parentFile
        }
        throw IllegalStateException("model-retired.v1.json not found")
    }

    private val decoder = Json { ignoreUnknownKeys = true }

    private val now: Instant by lazy { Instant.parse(fixture["now"]!!.jsonPrimitive.content) }

    private fun case(group: String, id: String): JsonObject =
        fixture[group]!!.jsonArray.map { it.jsonObject }.first { it["id"]!!.jsonPrimitive.content == id }

    private fun JsonObject.str(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeUnless { this[key] is JsonNull }?.contentOrNull

    private fun catalogOf(raw: JsonObject): ModelRetirement.Catalog? {
        val catalog = raw["catalog"]?.takeUnless { it is JsonNull }?.jsonObject ?: return null
        val models = catalog["models"]!!.jsonArray.map { element ->
            val model = element.jsonObject
            ModelRetirement.CatalogModel(
                id = model.str("id")!!,
                displayName = model.str("displayName"),
                // Goes through production parsing: the same helper MetadataClient uses to read the lifecycle JsonObject.
                lifecycle = ModelLifecycle.from(model["lifecycle"] as? JsonObject),
            )
        }
        val retired = decoder.decodeFromJsonElement(
            ListSerializer(RetiredModel.serializer()),
            catalog["retiredModels"]!!,
        )
        val resolveMap = catalog["resolveMap"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content }
        return ModelRetirement.Catalog(
            models = models,
            retiredModels = retired,
            resolveMap = resolveMap,
            defaultModelId = catalog.str("defaultModelId"),
        )
    }

    private fun userModels(raw: JsonObject): List<String> =
        raw["userModels"]!!.jsonArray.map { it.jsonPrimitive.content }

    private fun assertConversationCase(id: String) {
        val raw = case("conversationCases", id)
        val conversation = raw["conversation"]!!.jsonObject
        val expect = raw["expect"]!!.jsonObject
        val modelId = conversation.str("modelId")!!
        val result = ModelRetirement.conversationStatus(
            catalog = catalogOf(raw),
            userModels = userModels(raw),
            modelId = modelId,
            storedName = conversation.str("storedName"),
            now = now,
            bundled = false,
        )
        assertEquals("$id status", expect.str("status"), result.status.wire)
        assertEquals("$id successorId", expect.str("successorId"), result.successorId)
        assertEquals("$id displayName", expect.str("displayName"), result.displayName)
        assertEquals("$id sendBlocked", expect["sendBlocked"]!!.jsonPrimitive.booleanOrNull, result.sendBlocked)
        assertEquals("$id modelIdAfter", expect.str("modelIdAfter"), result.modelIdAfter)
    }

    private fun assertNewChatCase(id: String) {
        val raw = case("newChatCases", id)
        val expect = raw["expect"]!!.jsonObject
        val result = ModelRetirement.newChatModel(
            catalog = catalogOf(raw),
            userModels = userModels(raw),
            preferredModelId = raw.str("preferredModelId"),
            now = now,
            canonicalIds = raw["userModelCanonicalIds"]?.takeUnless { it is JsonNull }?.jsonObject
                ?.mapValues { it.value.jsonPrimitive.content }
                .orEmpty(),
        )
        assertEquals("$id modelId", expect.str("modelId"), result.modelId)
        assertEquals("$id hint", expect.str("hint"), result.hint?.wire)
    }

    @Test
    fun `fixture lists exactly the cases covered here`() {
        val conversationIds = fixture["conversationCases"]!!.jsonArray.map { it.jsonObject.str("id") }.toSet()
        val newChatIds = fixture["newChatCases"]!!.jsonArray.map { it.jsonObject.str("id") }.toSet()
        assertEquals(CONVERSATION_IDS, conversationIds)
        assertEquals(NEW_CHAT_IDS, newChatIds)
    }

    // ── conversationCases ──

    @Test fun RETIRED_tombstone_with_successor() = assertConversationCase("tombstone_with_successor")
    @Test fun RETIRED_tombstone_without_retired_at() = assertConversationCase("tombstone_without_retired_at")
    @Test fun RETIRED_tombstone_without_successor() = assertConversationCase("tombstone_without_successor")
    @Test fun RETIRED_tombstone_successor_not_in_catalog() = assertConversationCase("tombstone_successor_not_in_catalog")
    @Test fun RETIRED_stored_name_wins() = assertConversationCase("stored_name_wins")
    @Test fun RETIRED_deprecated_past_shutdown() = assertConversationCase("deprecated_past_shutdown")
    @Test fun RETIRED_deprecated_future_shutdown() = assertConversationCase("deprecated_future_shutdown")
    @Test fun RETIRED_missing_from_catalog() = assertConversationCase("missing_from_catalog")
    @Test fun RETIRED_hand_entered_model() = assertConversationCase("hand_entered_model")
    @Test fun RETIRED_canonical_alias_resolves() = assertConversationCase("canonical_alias_resolves")
    @Test fun RETIRED_catalog_not_loaded() = assertConversationCase("catalog_not_loaded")
    @Test fun RETIRED_active_model() = assertConversationCase("active_model")

    // ── newChatCases ──

    @Test fun RETIRED_preferred_available() = assertNewChatCase("preferred_available")
    @Test fun RETIRED_preferred_retired_falls_to_default() = assertNewChatCase("preferred_retired_falls_to_default")
    @Test fun RETIRED_default_not_enabled_falls_to_first_available() =
        assertNewChatCase("default_not_enabled_falls_to_first_available")
    @Test fun RETIRED_no_preferred_uses_default() = assertNewChatCase("no_preferred_uses_default")
    @Test fun RETIRED_alias_dated_default_matches_undated_enabled() = assertNewChatCase("alias_dated_default_matches_undated_enabled")
    @Test fun RETIRED_alias_undated_default_matches_dated_enabled() = assertNewChatCase("alias_undated_default_matches_dated_enabled")
    @Test fun RETIRED_alias_canonical_matches_enabled() = assertNewChatCase("alias_canonical_matches_enabled")
    @Test fun RETIRED_alias_exact_undated_beats_other_snapshot() = assertNewChatCase("alias_exact_undated_beats_other_snapshot")
    @Test fun RETIRED_alias_case_insensitive() = assertNewChatCase("alias_case_insensitive")
    @Test fun RETIRED_alias_prefix_near_miss_not_matched() = assertNewChatCase("alias_prefix_near_miss_not_matched")
    @Test fun RETIRED_alias_compact_mmdd_suffix_not_matched() = assertNewChatCase("alias_compact_mmdd_suffix_not_matched")
    @Test fun RETIRED_alias_match_retired_enabled_skipped() = assertNewChatCase("alias_match_retired_enabled_skipped")
    @Test fun RETIRED_alias_match_retired_enabled_with_canonical_skipped() =
        assertNewChatCase("alias_match_retired_enabled_with_canonical_skipped")

    @Test
    fun RETIRED_ANDROID_default_match_not_in_catalog_retries_next() {
        // The catalog default itself is not in the catalog; the first alias hit is not in the catalog, and after dropping it the second hit is in the catalog -> pick the second (do not fall to the first available).
        val catalog = ModelRetirement.Catalog(
            models = listOf(
                ModelRetirement.CatalogModel("gpt-4o-mini", "GPT-4o mini", null),
                ModelRetirement.CatalogModel("gpt-4o-2024-08-06", "GPT-4o (2024-08-06)", null),
            ),
            retiredModels = emptyList(),
            resolveMap = emptyMap(),
            defaultModelId = "gpt-4o",
        )
        val result = ModelRetirement.newChatModel(
            catalog = catalog,
            userModels = listOf("gpt-4o-mini", "gpt-4o-2024-05-13", "gpt-4o-2024-08-06"),
            preferredModelId = null,
            now = now,
        )
        assertEquals("gpt-4o-2024-08-06", result.modelId)
        assertEquals(null, result.hint)
    }

    // -- Android only: built-in snapshot state --

    @Test
    fun RETIRED_ANDROID_bundled_missing() {
        // The built-in snapshot may lag behind the server: a model not in the snapshot is not judged missing but available; tombstones are still retired.
        val missingRaw = case("conversationCases", "missing_from_catalog")
        val missing = ModelRetirement.conversationStatus(
            catalog = catalogOf(missingRaw),
            userModels = userModels(missingRaw),
            modelId = "glm-4-air",
            storedName = null,
            now = now,
            bundled = true,
        )
        assertEquals(ModelRetirement.Status.Available, missing.status)
        assertFalse(missing.sendBlocked)
        assertEquals("glm-4-air", missing.modelIdAfter)

        val tombstoneRaw = case("conversationCases", "tombstone_with_successor")
        val tombstone = ModelRetirement.conversationStatus(
            catalog = catalogOf(tombstoneRaw),
            userModels = userModels(tombstoneRaw),
            modelId = "deepseek-chat",
            storedName = null,
            now = now,
            bundled = true,
        )
        assertEquals(ModelRetirement.Status.Retired, tombstone.status)
        assertEquals("deepseek-flash", tombstone.successorId)
        assertTrue(tombstone.sendBlocked)
    }

    @Test
    fun `shutdownAt accepts plain date and RFC3339`() {
        assertEquals(Instant.parse("2026-10-01T00:00:00Z"), ModelRetirement.parseInstant("2026-10-01"))
        assertEquals(Instant.parse("2026-10-01T06:00:00Z"), ModelRetirement.parseInstant("2026-10-01T08:00:00+02:00"))
        assertEquals(null, ModelRetirement.parseInstant("soon"))
    }

    private companion object {
        val CONVERSATION_IDS = setOf(
            "tombstone_with_successor", "tombstone_without_retired_at", "tombstone_without_successor", "tombstone_successor_not_in_catalog",
            "stored_name_wins", "deprecated_past_shutdown", "deprecated_future_shutdown", "missing_from_catalog",
            "hand_entered_model", "canonical_alias_resolves", "catalog_not_loaded", "active_model",
        )
        val NEW_CHAT_IDS = setOf(
            "preferred_available", "preferred_retired_falls_to_default",
            "default_not_enabled_falls_to_first_available", "no_preferred_uses_default",
            "alias_dated_default_matches_undated_enabled",
            "alias_undated_default_matches_dated_enabled",
            "alias_canonical_matches_enabled",
            "alias_exact_undated_beats_other_snapshot",
            "alias_case_insensitive",
            "alias_prefix_near_miss_not_matched",
            "alias_compact_mmdd_suffix_not_matched",
            "alias_match_retired_enabled_skipped",
            "alias_match_retired_enabled_with_canonical_skipped",
        )
    }
}
