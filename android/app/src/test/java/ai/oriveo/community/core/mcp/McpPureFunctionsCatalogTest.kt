package ai.oriveo.community.core.mcp

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure functions (replayed case by case from the fixtures) and the tool catalog.
 */
class McpPureFunctionsCatalogTest {

    private fun cases(name: String, section: String? = null): JsonArray {
        val root = McpFixture.json(name)
        return ((if (section != null) root[section] else root)["cases"] as JsonArray)
    }

    @Test
    fun `naming vectors replay`() {
        val all = cases("naming.json")
        assertEquals(6, all.size)
        for (item in all) {
            val id = item["caseId"].stringOrNull
            val outbound = McpToolNaming.outboundName(
                item["slug"].stringOrNull!!, item["serverId"].stringOrNull!!, item["toolName"].stringOrNull!!,
                (item["collidesWith"] as JsonArray).mapNotNull { it.stringOrNull },
            )
            assertEquals(id, item["expect"]["outboundName"].stringOrNull, outbound.name)
            assertEquals(id, item["expect"]["length"].longOrNull, outbound.name.length.toLong())
            assertEquals(id, item["expect"]["hashSuffixed"].booleanOrNull, outbound.hashSuffixed)
        }
    }

    @Test
    fun `sanitize vectors replay by utf16 unit`() {
        val all = cases("identifiers.json", "sanitize")
        assertEquals(7, all.size)
        for (item in all) {
            val name = item["toolName"].stringOrNull!!
            val sanitized = McpToolNaming.sanitized(name)
            assertEquals(item["caseId"].stringOrNull, item["expect"].stringOrNull, sanitized)
            assertEquals(name.length, sanitized.length)
        }
    }

    private fun hashOf(value: JsonElement): String = McpToolHash.contentHash(
        value["name"].stringOrNull.orEmpty(),
        value["description"]?.takeUnless { it is JsonNull }.stringOrNull,
        value["inputSchema"] ?: JsonObject(emptyMap()),
        value["annotations"] ?: JsonObject(emptyMap()),
    )

    @Test
    fun `tool hash vectors replay through both the pure function and the catalog`() {
        val all = cases("tool-hash.json")
        assertEquals(5, all.size)
        for (item in all) {
            val id = item["caseId"].stringOrNull
            val before = item["before"]!!
            val after = item["after"]!!
            assertEquals(id, hashOf(before), McpToolCatalog.contentHash(McpToolDefinition.fromJson(before)!!))
            if (item["expectEqual"].booleanOrNull == true) {
                assertEquals(id, hashOf(before), hashOf(after))
                item["expect"]["hash"].stringOrNull?.let { assertEquals(id, it, hashOf(before)) }
            } else {
                assertEquals(id, item["expect"]["beforeHash"].stringOrNull, hashOf(before))
                assertEquals(id, item["expect"]["afterHash"].stringOrNull, hashOf(after))
            }
        }
    }

    @Test
    fun `args summary local-only and safety prompt replay`() {
        val summaries = cases("args-summary.json")
        assertEquals(7, summaries.size)
        for (item in summaries) {
            val summary = McpArgsSummary.summary(item["inputSchema"] ?: JsonObject(emptyMap()), item["arguments"] ?: JsonObject(emptyMap()))
            assertEquals(item["caseId"].stringOrNull, item["expect"]["summary"].stringOrNull, summary)
            item["expect"]["length"].longOrNull?.let { assertEquals(it, summary.codePointCount(0, summary.length).toLong()) }
        }
        val locals = cases("local-only.json")
        assertEquals(10, locals.size)
        for (item in locals) {
            val verdict = McpLocalOnly.verdict(item["url"].stringOrNull!!)
            assertEquals(item["caseId"].stringOrNull, item["expect"]["localOnly"].booleanOrNull, verdict.isLocalOnly)
            assertEquals(item["caseId"].stringOrNull, item["expect"]["reason"].stringOrNull, verdict.reason.wireValue)
        }
        assertEquals(McpFixture.text("safety-prompt.txt").removeSuffix("\n"), McpSafetyPrompt.TEXT)
    }

    /** For every address in the fixture the display URL no longer looks like it carries a secret, and it is idempotent. */
    @Test
    fun `display url strips every secret trait from the local-only fixture and is idempotent`() {
        for (item in cases("local-only.json")) {
            val url = item["url"].stringOrNull!!
            val display = McpLocalOnly.displayUrl(url)
            assertEquals("${item["caseId"].stringOrNull}: the display URL must no longer be classified as carrying a secret", false, McpLocalOnly.isLocalOnly(display))
            assertEquals("${item["caseId"].stringOrNull}: idempotent", display, McpLocalOnly.displayUrl(display))
            if (item["expect"]["localOnly"].booleanOrNull == false) assertEquals("a clean address only loses its fragment", url.substringBefore('#'), display)
        }
        assertEquals("https://mcp.example.com/mcp", McpLocalOnly.displayUrl("https://user:pw@mcp.example.com/mcp?token=abc123#frag"))
        assertEquals("https://mcp.example.com:8443/…/mcp", McpLocalOnly.displayUrl("https://mcp.example.com:8443/abcdefghij0123456789/mcp"))
        // A percent-encoded placeholder that is parsed back still yields the same display URL.
        assertEquals("https://mcp.example.com/…/mcp", McpLocalOnly.displayUrl("https://mcp.example.com/%E2%80%A6/mcp"))
    }

    // ── Tool catalog ────────────────────────────────────────

    private fun def(name: String, title: String? = null, description: String? = null, readOnly: Boolean? = null, annotationTitle: String? = null): McpToolDefinition {
        val annotations = buildMap<String, JsonElement> {
            readOnly?.let { put("readOnlyHint", JsonPrimitive(it)) }
            annotationTitle?.let { put("title", JsonPrimitive(it)) }
        }
        return McpToolDefinition(name, title, description, JsonObject(mapOf("type" to JsonPrimitive("object"))), JsonObject(annotations))
    }

    private fun settled(definition: McpToolDefinition) =
        McpToolCatalog.snapshots(SERVER, listOf(definition), McpRuntimeConfig.fallback).single().copy(pendingReview = false)

    @Test
    fun `new and changed tools are isolated and only confirmed ones go outbound`() {
        val added = McpToolCatalog.snapshots(SERVER, listOf(def("a", readOnly = true)), McpRuntimeConfig.fallback).single()
        assertTrue(added.pendingReview)
        assertEquals(listOf(McpToolChangeKind.Added), McpToolCatalog.changes(emptyList(), listOf(added)).map { it.kind })
        assertTrue("quarantined tools are not sent out", McpToolCatalog.outboundSnapshots(listOf(added), McpToolCatalog.defaultPermissions(listOf(added))).isEmpty())
        val confirmed = McpToolCatalog.confirmed(added, def("a", readOnly = true), McpRuntimeConfig.fallback)!!
        assertEquals(1, McpToolCatalog.outboundSnapshots(listOf(confirmed), emptyMap()).size)

        val old = settled(def("a", description = "v1"))
        val incoming = McpToolCatalog.snapshots(SERVER, listOf(def("a", description = "v2")), McpRuntimeConfig.fallback, listOf(old)).single()
        assertTrue(incoming.pendingReview)
        assertEquals(listOf(McpToolChangeKind.Changed), McpToolCatalog.changes(listOf(old), listOf(incoming)).map { it.kind })
        assertEquals(listOf(McpToolChangeKind.Removed), McpToolCatalog.changes(listOf(old), emptyList()).map { it.kind })
        assertNull("changed back while confirming: stays quarantined", McpToolCatalog.confirmed(incoming, def("a", description = "v1"), McpRuntimeConfig.fallback))

        val same = McpToolCatalog.snapshots(SERVER, listOf(def("a", description = "v1")), McpRuntimeConfig.fallback, listOf(old)).single()
        assertFalse("no change does not quarantine again", same.pendingReview)
    }

    @Test
    fun `title-only changes are isolated and confirming never loosens permissions`() {
        val before = settled(def("run", title = "Search issues"))
        val after = def("run", title = "Delete everything")
        assertEquals(before.contentHash, McpToolCatalog.contentHash(after))
        val incoming = McpToolCatalog.snapshots(SERVER, listOf(after), McpRuntimeConfig.fallback, listOf(before)).single()
        assertTrue(incoming.pendingReview)
        assertTrue(McpToolCatalog.outboundSnapshots(listOf(incoming), mapOf("run" to McpToolPermission.Auto)).isEmpty())
        assertTrue(McpToolCatalog.snapshots(SERVER, listOf(def("run", annotationTitle = "Write")), McpRuntimeConfig.fallback, listOf(settled(def("run", annotationTitle = "Read")))).single().pendingReview)

        val readOnly = settled(def("sync", description = "r", readOnly = true))
        val writes = def("sync", description = "rw", readOnly = false)
        val result = McpToolCatalog.confirm(
            McpToolCatalog.snapshots(SERVER, listOf(writes), McpRuntimeConfig.fallback, listOf(readOnly)),
            listOf(writes), mapOf("sync" to McpToolPermission.Auto), McpRuntimeConfig.fallback,
        )
        assertEquals(mapOf("sync" to McpToolPermission.Ask), result.permissions)

        val defs = listOf(def("became_ro", description = "v2", readOnly = true), def("off", description = "v2"), def("new_ro", readOnly = true), def("new_w"))
        val existing = listOf(settled(def("became_ro", description = "v1")), settled(def("off", description = "v1")))
        val confirmed = McpToolCatalog.confirm(
            McpToolCatalog.snapshots(SERVER, defs, McpRuntimeConfig.fallback, existing), defs,
            mapOf("became_ro" to McpToolPermission.Ask, "off" to McpToolPermission.Off), McpRuntimeConfig.fallback,
        )
        assertEquals(
            mapOf("became_ro" to McpToolPermission.Ask, "off" to McpToolPermission.Off, "new_ro" to McpToolPermission.Auto, "new_w" to McpToolPermission.Ask),
            confirmed.permissions,
        )
    }

    @Test
    fun `defaults duplicates oversized and off are handled`() {
        val snapshots = McpToolCatalog.snapshots(
            SERVER,
            listOf(def("search", description = "first", readOnly = true), def("create"), def("search", description = "second")),
            McpRuntimeConfig.fallback,
        )
        assertEquals(listOf("search", "create"), snapshots.map { it.toolName })
        assertEquals("first", snapshots.first().description)
        assertEquals(mapOf("search" to McpToolPermission.Auto, "create" to McpToolPermission.Ask), McpToolCatalog.defaultPermissions(snapshots))
        val big = def("big", description = "x".repeat(200))
        assertTrue(McpToolCatalog.isOversized(big, McpRuntimeConfig(maxToolDefinitionBytes = 50)))
        assertFalse(McpToolCatalog.isOversized(big, McpRuntimeConfig.fallback))
        val ok = snapshots.map { it.copy(pendingReview = false) }
        assertEquals(listOf("create"), McpToolCatalog.outboundSnapshots(ok + ok.first().copy(toolName = "fat", oversized = true), mapOf("search" to McpToolPermission.Off)).map { it.toolName })
        assertNotNull(McpToolDefinition.fromJson(McpJson.parse("""{"name":"a"}""")))
    }

    private companion object {
        const val SERVER = "00000000-0000-0000-0000-0000000000aa"
    }
}
