package ai.oriveo.community.core.studio

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

/**
 * Runs every clientCases group of the shared studio_presets.v1 fixture through the production
 * StudioPresets functions; snapshotCases load the committed Android asset copy through the
 * production snapshot reader.
 */
class StudioPresetsContractTest {
    private fun findUp(vararg relative: String): Path =
        generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .flatMap { dir -> relative.asSequence().map { dir.resolve(it) } }
            .firstOrNull { Files.exists(it) }
            ?: error("${relative.first()} not found")

    private fun load(name: String): JsonObject =
        Json.parseToJsonElement(findUp("\u5171\u4eab/studio-contracts/$name").toFile().readText()).jsonObject

    private val fixture: JsonObject by lazy { load("studio_presets.v1.json") }
    private val clientCases: JsonObject by lazy { fixture.getValue("clientCases").jsonObject }

    private fun group(name: String): List<JsonObject> =
        clientCases.getValue(name).jsonArray.map { it.jsonObject }.also { assertTrue("$name is empty", it.isNotEmpty()) }

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    private fun JsonObject.optString(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

    private fun String?.json(): JsonElement = this?.let { JsonPrimitive(it) } ?: JsonNull

    private fun StudioPresets.Group.toJson() = JsonObject(
        mapOf("id" to JsonPrimitive(id), "order" to JsonPrimitive(order), "displayName" to JsonPrimitive(displayName)),
    )

    private fun StudioPresets.Style.toJson() = JsonObject(
        mapOf(
            "id" to JsonPrimitive(id),
            "group" to JsonPrimitive(group),
            "order" to JsonPrimitive(order),
            "featured" to JsonPrimitive(featured),
            "displayName" to JsonPrimitive(displayName),
            "description" to JsonPrimitive(description),
            "promptFragment" to JsonPrimitive(promptFragment),
            "placeholderColor" to placeholderColor.json(),
            "sample" to (
                sample?.let {
                    JsonObject(
                        mapOf(
                            "url" to JsonPrimitive(it.url),
                            "width" to JsonPrimitive(it.width),
                            "height" to JsonPrimitive(it.height),
                            "sha256" to JsonPrimitive(it.sha256),
                        ),
                    )
                } ?: JsonNull
                ),
        ),
    )

    private fun StudioPresets.Effect.toJson() = JsonObject(
        mapOf(
            "id" to JsonPrimitive(id),
            "group" to JsonPrimitive(group),
            "order" to JsonPrimitive(order),
            "displayName" to JsonPrimitive(displayName),
            "promptFragment" to JsonPrimitive(promptFragment),
            "swatch" to JsonArray(swatch.map { JsonPrimitive(it) }),
        ),
    )

    private fun StudioPresets.DecodeResult.toJson(): JsonObject = when (this) {
        is StudioPresets.DecodeResult.Failure -> JsonObject(mapOf("error" to JsonPrimitive(error.wire)))
        is StudioPresets.DecodeResult.Success -> JsonObject(
            mapOf(
                "error" to JsonNull,
                "revision" to JsonPrimitive(presets.revision),
                "locale" to JsonPrimitive(presets.locale),
                "styleGroups" to JsonArray(presets.styleGroups.map { it.toJson() }),
                "effectGroups" to JsonArray(presets.effectGroups.map { it.toJson() }),
                "styles" to JsonArray(presets.styles.map { it.toJson() }),
                "effects" to JsonArray(presets.effects.map { it.toJson() }),
                "dropped" to JsonArray(
                    presets.dropped.map {
                        JsonObject(mapOf("kind" to JsonPrimitive(it.kind), "id" to it.id.json(), "reason" to JsonPrimitive(it.reason)))
                    },
                ),
            ),
        )
    }

    private fun cacheOf(raw: JsonElement?): StudioPresets.Cache? = (raw as? JsonObject)?.let {
        StudioPresets.Cache(
            locale = it.str("locale"),
            revision = it.str("revision"),
            etag = it.optString("etag"),
            checkedAtMs = it.getValue("checkedAtMs").jsonPrimitive.long,
        )
    }

    private fun StudioPresets.Cache?.toJson(): JsonElement = this?.let {
        JsonObject(
            mapOf(
                "locale" to JsonPrimitive(it.locale),
                "revision" to JsonPrimitive(it.revision),
                "etag" to it.etag.json(),
                "checkedAtMs" to JsonPrimitive(it.checkedAtMs),
            ),
        )
    } ?: JsonNull

    private fun check(groupName: String, label: (JsonObject) -> String, actualOf: (JsonObject) -> JsonElement) {
        val failures = group(groupName).mapNotNull { case ->
            val actual = actualOf(case)
            val expected = case.getValue("expect")
            if (actual == expected) null else "${label(case)}: expected $expected but was $actual"
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun decodeCases() = check("decode", { it.str("caseId") }) { case ->
        StudioPresets.decode(case.getValue("input").toString()).toJson()
    }

    @Test
    fun localeCases() {
        val locales = fixture.getValue("locales").jsonArray.map { it.jsonPrimitive.content }
        check("locale", { "tag '${it.str("tag")}'" }) { case ->
            JsonPrimitive(StudioPresets.resolveLocale(locales, case.str("tag")))
        }
    }

    @Test
    fun snapshotCases() {
        // Production loader and asset path constant; the opener maps asset paths onto src/main/assets.
        val asset = StudioPresets.snapshotReader { path ->
            findUp(
                "src/main/assets/$path",
                "app/src/main/assets/$path",
                "\u5e94\u7528/oriveo-android/app/src/main/assets/$path",
            ).toFile().inputStream()
        }() ?: error("snapshot asset unreadable")
        check("snapshot", { "tag '${it.str("tag")}'" }) { case ->
            when (val result = StudioPresets.parseSnapshot(asset, case.str("tag"))) {
                is StudioPresets.DecodeResult.Failure -> JsonObject(mapOf("error" to JsonPrimitive(result.error.wire)))
                is StudioPresets.DecodeResult.Success -> {
                    val p = result.presets
                    val firstStyle = p.styles.firstOrNull()
                    val firstEffect = p.effects.firstOrNull()
                    val firstGroup = p.styleGroups.firstOrNull()
                    JsonObject(
                        mapOf(
                            "locale" to JsonPrimitive(p.locale),
                            "revision" to JsonPrimitive(p.revision),
                            "styles" to JsonPrimitive(p.styles.size),
                            "effects" to JsonPrimitive(p.effects.size),
                            "dropped" to JsonPrimitive(p.dropped.size),
                            "everySampleNull" to JsonPrimitive(p.styles.all { it.sample == null }),
                            "firstStyle" to (
                                firstStyle?.let {
                                    JsonObject(
                                        mapOf(
                                            "id" to JsonPrimitive(it.id),
                                            "displayName" to JsonPrimitive(it.displayName),
                                            "description" to JsonPrimitive(it.description),
                                            "placeholderColor" to it.placeholderColor.json(),
                                        ),
                                    )
                                } ?: JsonNull
                                ),
                            "firstEffect" to (
                                firstEffect?.let {
                                    JsonObject(mapOf("id" to JsonPrimitive(it.id), "displayName" to JsonPrimitive(it.displayName)))
                                } ?: JsonNull
                                ),
                            "firstStyleGroup" to (firstGroup?.toJson() ?: JsonNull),
                        ),
                    )
                }
            }
        }
    }

    @Test
    fun refreshPlanCases() = check("refreshPlan", { it.str("caseId") }) { case ->
        val input = case.getValue("input").jsonObject
        val plan = StudioPresets.planRefresh(
            cache = cacheOf(input["cache"]),
            locale = input.str("locale"),
            nowMs = input.getValue("nowMs").jsonPrimitive.long,
        )
        JsonObject(mapOf("fetch" to JsonPrimitive(plan.fetch), "ifNoneMatch" to plan.ifNoneMatch.json()))
    }

    @Test
    fun refreshApplyCases() = check("refreshApply", { it.str("caseId") }) { case ->
        val input = case.getValue("input").jsonObject
        val response = input.getValue("response").jsonObject
        val applied = StudioPresets.applyResponse(
            cache = cacheOf(input["cache"]),
            locale = input.str("locale"),
            nowMs = input.getValue("nowMs").jsonPrimitive.long,
            response = StudioPresets.Response(
                status = response.getValue("status").jsonPrimitive.int,
                etag = response.optString("etag"),
                body = response["body"]?.toString(),
            ),
        )
        JsonObject(
            mapOf(
                "outcome" to JsonPrimitive(applied.outcome.wire),
                "cache" to applied.cache.toJson(),
                "bodyReplaced" to JsonPrimitive(applied.bodyReplaced),
            ),
        )
    }
}
