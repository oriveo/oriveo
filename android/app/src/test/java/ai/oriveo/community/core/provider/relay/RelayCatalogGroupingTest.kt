package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.provider.RelayFamilyHeuristics
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Relay model library grouping: the fixture `shared/test-fixtures/relay/catalog-groups.v1.json`
 * drives the production [RelayCatalogGrouping.groups] per caseId; the family function = fixture serverFamilies -> production [RelayFamilyHeuristics]
 * (same lookup as [RelayKeyBinding.cachedFamily], only replacing the "cached Server family" with the fixture table).
 */
class RelayCatalogGroupingTest {

    private val fixture: JsonObject = Json.parseToJsonElement(
        generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .map { File(it, "shared/test-fixtures/relay/catalog-groups.v1.json") }
            .first { it.isFile }
            .readText(Charsets.UTF_8),
    ).jsonObject

    private fun cases(): List<JsonObject> = fixture.getValue("cases").jsonArray.map { it.jsonObject }

    private data class Expected(val id: String, val label: String?, val models: List<String>)

    private fun assertCase(caseId: String) {
        val case = cases().single { it.getValue("id").jsonPrimitive.content == caseId }
        val models = case.getValue("models").jsonArray.map { it.jsonPrimitive.content }
        val server = case.getValue("serverFamilies").jsonObject.mapValues { it.value.jsonPrimitive.content }
        val family: (String) -> String? = { id -> server[id] ?: RelayFamilyHeuristics.infer(id)?.name?.lowercase() }
        val expected = case.getValue("expected").jsonArray.map { it.jsonObject }.map { group ->
            Expected(
                id = group.getValue("id").jsonPrimitive.content,
                label = group.getValue("label").takeUnless { it is JsonNull }?.jsonPrimitive?.content,
                models = group.getValue("models").jsonArray.map { it.jsonPrimitive.content },
            )
        }
        val actual = RelayCatalogGrouping.groups(models, { it }, family)
            .map { Expected(it.id, it.label, it.items) }
        assertEquals(caseId, expected, actual)
    }

    @Test
    fun `RD3-GROUP-heuristic_families_in_catalog_order`() = assertCase("heuristic_families_in_catalog_order")

    @Test
    fun `RD3-GROUP-server_family_first`() = assertCase("server_family_first")

    @Test
    fun `RD3-GROUP-other_always_last`() = assertCase("other_always_last")

    @Test
    fun `RD3-GROUP-unlabeled_server_family_uses_id`() = assertCase("unlabeled_server_family_uses_id")

    @Test
    fun `RD3-GROUP-vendor_prefixed_ids_use_last_segment`() = assertCase("vendor_prefixed_ids_use_last_segment")

    @Test
    fun `RD3-GROUP-empty_catalog`() = assertCase("empty_catalog")

    @Test
    fun `RD3-GROUP fixture coverage and label table`() {
        // Every new fixture case must have a same-named test here; the group-name table matches the fixture labels word for word.
        val covered = setOf(
            "heuristic_families_in_catalog_order",
            "server_family_first",
            "other_always_last",
            "unlabeled_server_family_uses_id",
            "vendor_prefixed_ids_use_last_segment",
            "empty_catalog",
        )
        assertEquals(covered, cases().map { it.getValue("id").jsonPrimitive.content }.toSet())
        assertEquals(
            fixture.getValue("labels").jsonObject.mapValues { it.value.jsonPrimitive.content },
            RelayCatalogGrouping.LABELS,
        )
        assertEquals("other", RelayCatalogGrouping.OTHER_ID)
    }
}
