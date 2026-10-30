package ai.oriveo.community.core.search

import java.io.File
import java.net.URLDecoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertTrue

/** Read and compare helpers for the external search shared fixtures (the `shared/` directory at the repo root); call sites write the full relative path `search-contracts/<file>`. */
internal object SearchContractFixtures {
    fun load(relative: String): JsonObject {
        val file = generateSequence(File(System.getProperty("user.dir") ?: ".").absoluteFile) { it.parentFile }
            .take(8)
            .map { File(it, "shared/$relative") }
            .firstOrNull { it.exists() }
            ?: File("shared/$relative")
        require(file.exists()) { "fixture not found at: ${file.absolutePath}" }
        return Json.parseToJsonElement(file.readText()).jsonObject
    }

    fun cases(doc: JsonObject, key: String): List<JsonObject> = doc.getValue(key).jsonArray.map { it.jsonObject }

    fun str(e: JsonElement?): String? = (e as? JsonPrimitive)?.takeIf { it.isString }?.content

    fun int(e: JsonElement?): Int? = (e as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.content?.toIntOrNull()

    fun bool(e: JsonElement?): Boolean? = (e as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.content?.toBooleanStrictOrNull()

    fun obj(e: JsonElement?): JsonObject? = e as? JsonObject

    fun catalogEntry(catalog: JsonObject, serviceId: String): JsonObject =
        catalog.getValue("services").jsonArray.map { it.jsonObject }.first { str(it["id"]) == serviceId }

    /** Returns a copy of the entry with one site (regionId) modified; if transform returns null it is left unchanged. */
    fun withRegion(entry: JsonObject, regionId: String, transform: (JsonObject) -> JsonObject): JsonObject {
        val regions = entry.getValue("regions").jsonArray.map { r ->
            val o = r.jsonObject
            if (str(o["id"]) == regionId) transform(o) else o
        }
        return JsonObject(entry + ("regions" to JsonArray(regions)))
    }

    fun parseResultOf(expect: JsonObject): SearchParseResult = when (str(expect["kind"])) {
        "results" -> SearchParseResult.Results(
            expect.getValue("results").jsonArray.map { r ->
                val o = r.jsonObject
                SearchResultItem(str(o["title"])!!, str(o["url"])!!, str(o["snippet"])!!, str(o["site"]), str(o["date"]))
            },
        )
        "empty" -> SearchParseResult.Empty
        else -> SearchParseResult.Error(str(expect["errorClass"])!!)
    }

    fun errorOutcomeOf(expect: JsonObject): SearchErrorOutcome {
        val card = expect.getValue("card").jsonObject
        return SearchErrorOutcome(
            errorClass = str(expect["errorClass"])!!,
            retryOnce = bool(expect["retryOnce"])!!,
            toolMessage = str(expect["toolMessage"])!!,
            card = SearchErrorCard(str(card["headline"])!!, str(card["primaryAction"])!!, str(card["secondaryAction"])),
        )
    }

    /** Request comparison: method, scheme://host[:port]/path, decoded query (unordered), headers, and JSON-semantic body. */
    fun requestMismatch(expect: JsonObject, result: SearchBuildResult): String? {
        str(expect["skip"])?.let { skip ->
            return if (result == SearchRequestSkip(skip)) null else "expected skip $skip but was $result"
        }
        val actual = result as? SearchHttpRequest ?: return "expected a request but was $result"
        val expectUrl = str(expect["url"])!!
        fun split(url: String): Pair<String, List<Pair<String, String>>> {
            val base = url.substringBefore('?')
            val query = url.substringAfter('?', "")
            val pairs = if (query.isEmpty()) emptyList() else query.split('&').map {
                URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
            }
            return base to pairs.sortedWith(compareBy({ it.first }, { it.second }))
        }
        val headers = expect.getValue("headers").jsonObject.mapValues { str(it.value)!! }
        val body = expect["body"]?.takeIf { it != JsonNull }
        return when {
            str(expect["method"]) != actual.method -> "method ${actual.method}"
            split(expectUrl) != split(actual.url) -> "url ${actual.url}"
            headers != actual.headers -> "headers ${actual.headers}"
            body != actual.body -> "body ${actual.body}"
            else -> null
        }
    }

    class Mismatches {
        private val items = mutableListOf<String>()

        fun check(caseId: String, expected: Any?, actual: Any?) {
            if (expected != actual) items += "$caseId: expected <$expected> but was <$actual>"
        }

        fun fail(caseId: String, why: String) {
            items += "$caseId: $why"
        }

        fun assertNone(total: Int) {
            assertTrue("$total cases, ${items.size} mismatched:\n" + items.joinToString("\n"), items.isEmpty())
            assertTrue("fixture has no cases", total > 0)
        }
    }
}
