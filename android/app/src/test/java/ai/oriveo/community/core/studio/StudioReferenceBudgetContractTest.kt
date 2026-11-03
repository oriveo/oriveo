package ai.oriveo.community.core.studio

import ai.oriveo.community.core.studio.StudioReferenceBudget.Item
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Runs the shared byok_reference_budget.v1.json fixture against the Android reference image budget:
 * groups spec, encodedBytes and fit.
 */
class StudioReferenceBudgetContractTest {
    private val contracts: Path by lazy {
        generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("\u5171\u4eab/studio-contracts") }
            .firstOrNull { Files.exists(it.resolve("byok_reference_budget.v1.json")) }
            ?: error("byok_reference_budget.v1.json not found")
    }

    private fun read(path: Path): JsonElement = Json.parseToJsonElement(path.toFile().readText())

    private val fixture: JsonObject by lazy { read(contracts.resolve("byok_reference_budget.v1.json")).jsonObject }

    private fun group(name: String): List<JsonObject> {
        val cases = fixture.getValue(name).jsonArray.map { it.jsonObject }
        assertTrue("fixture group $name has cases", cases.isNotEmpty())
        return cases
    }

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    private fun JsonObject.isNull(key: String): Boolean = this[key] == null || this[key] is JsonNull

    private fun JsonObject.strOrNull(key: String): String? = if (isNull(key)) null else str(key)

    private fun JsonObject.longOrNull(key: String): Long? = if (isNull(key)) null else getValue(key).jsonPrimitive.long

    private fun JsonObject.item(role: String? = null): Item = Item(
        slot = getValue("slot").jsonPrimitive.int,
        role = role ?: str("role"),
        mime = str("mime"),
        byteCount = getValue("byteCount").jsonPrimitive.long,
    )

    @Test
    fun spec() {
        val spec = fixture.getValue("spec").jsonObject
        assertEquals(spec.getValue("overheadBytes").jsonPrimitive.long, StudioReferenceBudget.OVERHEAD_BYTES)
        val routes = spec.getValue("routes").jsonObject
        assertEquals(7, routes.size)
        assertEquals(routes.keys, StudioReferenceBudget.routeLimits.keys)
        for ((route, value) in routes) {
            assertTrue("route $route has a row", StudioReferenceBudget.routeLimits.containsKey(route))
            val expected = if (value is JsonNull) {
                null
            } else {
                val row = value.jsonObject
                StudioReferenceBudget.Limits(row.longOrNull("maxRequestBytes"), row.longOrNull("maxImageBytes"))
            }
            assertEquals("limits of $route", expected, StudioReferenceBudget.routeLimits[route])
        }
        val shrink = spec.getValue("shrink").jsonObject
        assertEquals(shrink.getValue("maxLongEdge").jsonPrimitive.int, StudioReferenceBudget.SHRINK_MAX_LONG_EDGE)
        assertEquals(shrink.getValue("jpegQuality").jsonPrimitive.double, StudioReferenceBudget.SHRINK_JPEG_QUALITY, 0.0)
        assertEquals(shrink.str("mime"), StudioReferenceBudget.SHRINK_MIME)
        assertEquals(spec.str("tooLargeErrorKind"), StudioReferenceBudget.TOO_LARGE_ERROR_KIND)
        assertEquals(
            spec.getValue("statuses").jsonArray.map { it.jsonPrimitive.content },
            StudioReferenceBudget.Status.entries.map { it.wire },
        )
    }

    @Test
    fun encodedBytes() {
        for (case in group("encodedBytes")) {
            val id = case.str("caseId")
            val input = case.getValue("input").jsonObject
            val actual = StudioReferenceBudget.encodedBytes(
                route = input.str("route"),
                editTransport = input.strOrNull("editTransport"),
                mime = input.str("mime"),
                byteCount = input.getValue("byteCount").jsonPrimitive.long,
            )
            assertEquals(id, case.getValue("expect").jsonPrimitive.long, actual)
        }
    }

    @Test
    fun fit() = runTest {
        for (case in group("fit")) {
            val id = case.str("caseId")
            val input = case.getValue("input").jsonObject
            val expect = case.getValue("expect").jsonObject
            val rows = input.getValue("images").jsonArray.map { it.jsonObject }
            val images = rows.map { it.item() }
            val shrunkBySlot: Map<Int, Item?> = rows.associate { row ->
                val original = row.item()
                original.slot to if (row.isNull("shrunk")) {
                    null
                } else {
                    val shrunk = row.getValue("shrunk").jsonObject
                    original.copy(mime = shrunk.str("mime"), byteCount = shrunk.getValue("byteCount").jsonPrimitive.long)
                }
            }
            val shrinkCalls = mutableListOf<Int>()

            val result = StudioReferenceBudget.fit(
                route = input.str("route"),
                editTransport = input.strOrNull("editTransport"),
                prompt = input.str("prompt"),
                images = images,
                describe = { it },
                shrink = { image ->
                    shrinkCalls += image.slot
                    shrunkBySlot.getValue(image.slot)
                },
            )

            assertEquals("$id status", expect.str("status"), result.status.wire)
            assertEquals("$id errorKind", expect.strOrNull("errorKind"), result.errorKind)
            assertEquals("$id requestBytes", expect.getValue("requestBytes").jsonPrimitive.long, result.requestBytes)
            val expectedImages = expect.getValue("images").jsonArray.map { it.jsonObject }.map {
                Triple(it.getValue("slot").jsonPrimitive.int, it.str("mime"), it.getValue("byteCount").jsonPrimitive.long)
            }
            assertEquals("$id images", expectedImages, result.images.map { Triple(it.slot, it.mime, it.byteCount) })
            assertEquals(
                "$id shrinkCalls",
                expect.getValue("shrinkCalls").jsonArray.map { it.jsonPrimitive.int },
                shrinkCalls,
            )
        }
    }
}
