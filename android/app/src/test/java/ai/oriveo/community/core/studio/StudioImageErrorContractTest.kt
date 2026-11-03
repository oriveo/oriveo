package ai.oriveo.community.core.studio

import ai.oriveo.community.core.studio.StudioImageError.AutoRetry
import ai.oriveo.community.core.studio.StudioImageError.ConsumesFreeQuota
import ai.oriveo.community.core.studio.StudioImageError.Policy
import ai.oriveo.community.core.studio.StudioImageResponse.Failure
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Runs the shared image_error_samples.v1.json fixture against the Android error normalizer:
 * every body case, the kind policies, the captured real responses and the per-image failures.
 */
class StudioImageErrorContractTest {
    private val contracts: Path by lazy {
        generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("\u5171\u4eab/model-contracts") }
            .firstOrNull { Files.exists(it.resolve("image_error_samples.v1.json")) }
            ?: error("image_error_samples.v1.json not found")
    }

    private fun read(path: Path): JsonElement = Json.parseToJsonElement(path.toFile().readText())

    private val fixture: JsonObject by lazy { read(contracts.resolve("image_error_samples.v1.json")).jsonObject }

    private val fixtureKinds: JsonObject by lazy { fixture.getValue("kinds").jsonObject }

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    /** A JSON null body means "no body". */
    private fun JsonElement?.bodyOrNull(): JsonElement? = if (this == null || this is JsonNull) null else this

    private fun wireOf(kind: StudioImageErrorKind?): String = kind?.wire ?: "ok"

    /** The fixture writes `false` for "none"; strings are the wire value. */
    private fun JsonObject.enumWire(key: String): String {
        val value = getValue(key).jsonPrimitive
        return if (value.isString) value.content else if (value.boolean) error("unexpected true for $key") else "none"
    }

    private fun Policy.wire(): Map<String, Any> = mapOf(
        "consumesFreeQuota" to consumesFreeQuota.wire,
        "autoRetry" to autoRetry.wire,
        "ui" to ui,
        "report" to report,
    )

    private fun JsonObject.policyWire(): Map<String, Any> = mapOf(
        "consumesFreeQuota" to enumWire("consumesFreeQuota"),
        "autoRetry" to enumWire("autoRetry"),
        "ui" to str("ui"),
        "report" to ((this["report"] as? JsonPrimitive)?.boolean ?: false),
    )

    @Test
    fun cases() {
        val cases = fixture.getValue("cases").jsonArray.map { it.jsonObject }
        assertTrue("fixture has cases", cases.isNotEmpty())
        val mismatches = cases.mapNotNull { case ->
            val actual = wireOf(
                StudioImageError.classify(
                    http = case.getValue("http").jsonPrimitive.int,
                    body = case["body"].bodyOrNull(),
                    nRequested = case.getValue("nRequested").jsonPrimitive.int,
                ),
            )
            val expected = case.str("expectKind")
            if (actual == expected) null else "${case.str("caseId")}: expected $expected, got $actual"
        }
        assertEquals("classify mismatches", emptyList<String>(), mismatches)
    }

    @Test
    fun kinds() {
        assertEquals(fixtureKinds.keys, StudioImageErrorKind.entries.map { it.wire }.toSet())
        assertEquals(StudioImageErrorKind.entries.size, StudioImageErrorKind.entries.map { it.wire }.toSet().size)
        for ((wire, spec) in fixtureKinds) {
            val kind = StudioImageErrorKind.entries.first { it.wire == wire }
            assertEquals("policy of $wire", spec.jsonObject.policyWire(), StudioImageError.policy(kind).wire())
        }
        assertEquals(setOf("none", "by_delivered_count", "already_settled"), ConsumesFreeQuota.entries.map { it.wire }.toSet())
        assertEquals(setOf("none", "once_before_body_sent"), AutoRetry.entries.map { it.wire }.toSet())
    }

    @Test
    fun realSamples() {
        val dir = contracts.resolve("image_response_samples.v1")
        val samples = read(dir.resolve("index.json")).jsonObject.getValue("samples").jsonArray.map { it.jsonObject }
        assertTrue("index has samples", samples.isNotEmpty())
        val mismatches = samples.mapNotNull { sample ->
            val file = read(dir.resolve(sample.str("file"))).jsonObject
            val actual = wireOf(
                StudioImageError.classify(
                    http = file.getValue("meta").jsonObject.getValue("http").jsonPrimitive.int,
                    body = file["response"].bodyOrNull(),
                    nRequested = sample.getValue("nRequested").jsonPrimitive.int,
                ),
            )
            val expected = sample.getValue("expect").jsonObject.str("result")
            if (actual == expected) null else "${sample.str("file")}: expected $expected, got $actual"
        }
        assertEquals("real sample mismatches", emptyList<String>(), mismatches)
    }

    /** kotlinx tree parsing accepts tokens outside the JSON number grammar; they must not count as numbers. */
    @Test
    fun nonJsonNumberTokens() {
        val bodies = listOf(
            """{"base_resp":{"status_code":1026d}}""",
            """{"data":{"image_base64":[]},"metadata":{"failed_count":01}}""",
            """{"data":{"image_base64":[]},"metadata":{"failed_count":1e400}}""",
        )
        val mismatches = bodies.mapNotNull { raw ->
            val actual = wireOf(StudioImageError.classify(http = 200, body = Json.parseToJsonElement(raw), nRequested = 1))
            if (actual == "decode_failed") null else "$raw: expected decode_failed, got $actual"
        }
        assertEquals("non-JSON number token mismatches", emptyList<String>(), mismatches)
    }

    @Test
    fun failureKinds() {
        assertTrue(Failure.entries.isNotEmpty())
        for (failure in Failure.entries) {
            assertTrue("${failure.wire} is a fixture kind", failure.wire in fixtureKinds.keys)
            assertEquals(failure.wire, failure.errorKind.wire)
        }
    }
}
