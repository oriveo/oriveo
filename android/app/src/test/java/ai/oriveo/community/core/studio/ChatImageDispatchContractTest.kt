package ai.oriveo.community.core.studio

import ai.oriveo.community.core.model.ProviderServiceError
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Chat image dispatch contract: code constants equal the spec, every dispatch case decides the same
 * path / operation / reference images, and every studio error kind maps to the spec category and the
 * matching chat error. Fixture chat_image_dispatch.v1.
 */
class ChatImageDispatchContractTest {
    // Shared contract directory name.
    private val sharedDir = "shared"

    private val fixture: JsonObject by lazy {
        val path: Path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("$sharedDir/studio-contracts/chat_image_dispatch.v1.json") }
            .firstOrNull { Files.exists(it) }
            ?: error("chat_image_dispatch.v1.json not found")
        Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    private val spec: JsonObject by lazy { fixture.getValue("spec").jsonObject }

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    private fun JsonObject.strings(key: String): List<String> =
        getValue(key).jsonArray.map { it.jsonPrimitive.content }

    private fun profile(ref: String): ImageProfile {
        val raw = fixture.getValue("profiles").jsonObject.getValue(ref).jsonObject
        return ImageProfileResolver.validate(raw).profile ?: error("$ref does not validate")
    }

    @Test
    fun constants() {
        assertEquals(spec.strings("studioRoutes"), ChatImageDispatch.STUDIO_ROUTES.map { it.wire })
        assertEquals(spec.strings("legacyProviderKinds"), ChatImageDispatch.LEGACY_PROVIDER_KINDS)
        val params = spec.getValue("chatParams").jsonObject
        assertEquals(
            ImageParamRequest(
                aspect = params.str("aspect"),
                resolution = params.str("resolution"),
                quality = params.str("quality"),
                n = params.getValue("n").jsonPrimitive.int,
            ),
            ChatImageDispatch.chatParams,
        )
    }

    @Test
    fun dispatch() {
        val cases = fixture.getValue("dispatch").jsonArray.map { it.jsonObject }
        assertTrue("dispatch group must not be empty", cases.isNotEmpty())
        val firstRole = spec.getValue("firstImage").jsonObject
        val laterRole = spec.getValue("laterImages").jsonObject.str("role")
        val mismatches = mutableListOf<String>()
        for (case in cases) {
            val input = case.getValue("input").jsonObject
            val expect = case.getValue("expect").jsonObject
            val profileRef = input.getValue("profileRef")
            val profile = if (profileRef is JsonNull) null else profile(profileRef.jsonPrimitive.content)
            val attachments = input.getValue("attachments").jsonArray.map {
                val item = it.jsonObject
                ChatImageDispatch.Candidate(item.str("id"), item.getValue("hasBytes").jsonPrimitive.boolean)
            }
            val expected: ChatImageDispatch.Decision = when (val path = expect.str("path")) {
                "legacy" -> ChatImageDispatch.Decision.Legacy
                "studio" -> ChatImageDispatch.Decision.Studio(
                    operation = ImageOperation.fromWire(expect.str("operation")) ?: error("bad operation"),
                    images = expect.getValue("images").jsonArray.map {
                        val image = it.jsonObject
                        ChatImageDispatch.Pick(image.str("attachmentId"), image.getValue("slot").jsonPrimitive.int, image.str("role"))
                    },
                )
                else -> error("unknown path $path")
            }
            // Spec roles: the first pick uses firstImage, later picks use laterImages.
            if (expected is ChatImageDispatch.Decision.Studio) {
                expected.images.forEachIndexed { index, pick ->
                    if (index == 0) {
                        assertEquals(firstRole.getValue("slot").jsonPrimitive.int, pick.slot)
                        assertEquals(firstRole.str("role"), pick.role)
                    } else {
                        assertEquals(laterRole, pick.role)
                    }
                }
            }
            val actual = ChatImageDispatch.decide(
                providerKind = input.str("providerKind"),
                legacyImageDispatch = input.getValue("legacyImageDispatch").jsonPrimitive.boolean,
                profile = profile,
                attachments = attachments,
            )
            if (actual != expected) mismatches += "${case.str("caseId")}: expected $expected, got $actual"
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    @Test
    fun missingMaxReferenceImagesTakesOne() {
        val profile = profile("openai_gpt_image").copy(maxReferenceImages = null)
        val decision = ChatImageDispatch.decide(
            providerKind = "openAI",
            legacyImageDispatch = true,
            profile = profile,
            attachments = listOf(ChatImageDispatch.Candidate("a1", true), ChatImageDispatch.Candidate("a2", true)),
        )
        assertEquals(
            ChatImageDispatch.Decision.Studio(ImageOperation.EDIT, listOf(ChatImageDispatch.Pick("a1", 1, "base"))),
            decision,
        )
    }

    @Test
    fun baseUrlMatchesFixture() {
        val cases = fixture.getValue("baseUrl").jsonArray.map { it.jsonObject }
        assertTrue("baseUrl group must not be empty", cases.isNotEmpty())
        val mismatches = mutableListOf<String>()
        for (case in cases) {
            val caseId = case.str("caseId")
            val input = case.getValue("input").jsonObject
            val raw = input["connectionBaseUrl"]
            val connection = if (raw == null || raw is JsonNull) null else raw.jsonPrimitive.content
            val expectRaw = case.getValue("expect").jsonObject["baseUrl"]
            val expected = if (expectRaw == null || expectRaw is JsonNull) null else expectRaw.jsonPrimitive.content
            val actual = ChatImageDispatch.studioBaseUrl(input.str("route"), connection)
            if (actual != expected) mismatches += "$caseId: '$actual', expected '$expected'"
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    private fun expectedFailure(category: String, message: String): ProviderServiceError = when (category) {
        "upstream_400" -> ProviderServiceError.Upstream(statusCode = 400, detail = message)
        "upstream_502" -> ProviderServiceError.Upstream(statusCode = 502, detail = message)
        "upstream_507" -> ProviderServiceError.Upstream(statusCode = 507, detail = message)
        "invalid_key" -> ProviderServiceError.InvalidAPIKey(message)
        "quota_exceeded" -> ProviderServiceError.QuotaExceeded(message)
        "rate_limited" -> ProviderServiceError.RateLimited(message)
        "model_unavailable" -> ProviderServiceError.ModelUnavailable(message)
        "network" -> ProviderServiceError.Network(message)
        "empty_response" -> ProviderServiceError.EmptyResponse
        else -> error("unknown category $category")
    }

    @Test
    fun errorMap() {
        val map = spec.getValue("errorMap").jsonObject
        assertTrue("errorMap group must not be empty", map.isNotEmpty())
        // Every failing kind is in the spec; partial is a completed send, not a chat failure.
        assertEquals(
            StudioImageErrorKind.entries.filter { it != StudioImageErrorKind.PARTIAL }.map { it.wire }.toSet(),
            map.keys,
        )
        val message = "upstream said no"
        for ((wire, value) in map) {
            val kind = StudioImageErrorKind.entries.first { it.wire == wire }
            val category = value.jsonPrimitive.content
            assertEquals(wire, category, ChatImageDispatch.category(kind))
            assertEquals(wire, expectedFailure(category, message), ChatImageDispatch.chatFailure(kind, message))
        }
        assertNull(ChatImageDispatch.category(StudioImageErrorKind.PARTIAL))
        assertNull(ChatImageDispatch.chatFailure(StudioImageErrorKind.PARTIAL, message))
    }
}
