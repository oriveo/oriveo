package ai.oriveo.community.core.studio

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths
import java.util.Base64

/**
 * Runs the openai_images / xai_images / openrouter_images / minimax_image_generation /
 * gemini_generate_content / chat_modalities cases plus every clientCase of the shared
 * request_shape_contract.v2 imageRequests fixture: profile plus profileOverride are
 * shallow-merged and validated, intent.params are normalized and wireOverride is merged into the
 * wire, then the production builder's request is compared with expect.
 */
class ImageRequestShapeContractTest {
    private fun load(name: String): JsonObject {
        val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("shared/model-contracts/$name") }
            .firstOrNull { Files.exists(it) }
            ?: error("$name not found")
        return Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    private val imageRequests: JsonObject by lazy {
        load("request_shape_contract.v2.json").getValue("imageRequests").jsonObject
    }
    private val profiles: JsonObject by lazy {
        load("image_param_normalization.v1.json").getValue("profiles").jsonObject
    }
    private val cases: List<JsonObject> by lazy {
        val vendor = imageRequests.getValue("cases").jsonArray.map { it.jsonObject }
            .filter { it.getValue("intent").jsonObject.str("route") in SUPPORTED_ROUTES }
        vendor + imageRequests.getValue("clientCases").jsonArray.map { it.jsonObject }
    }

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    private fun JsonObject.optString(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

    private fun profileOf(ref: String, override: JsonObject?): ImageProfile {
        val base = profiles.getValue(ref).jsonObject
        val merged = if (override == null) base else JsonObject(base + override)
        val validation = ImageProfileResolver.validate(merged)
        return validation.profile ?: error("profile does not validate: ${validation.reason}")
    }

    private fun requestOf(raw: JsonObject): ImageParamRequest = ImageParamRequest(
        aspect = raw.optString("aspect"),
        resolution = raw.optString("resolution"),
        quality = raw.optString("quality"),
        n = (raw["n"] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.int,
    )

    private fun imagesOf(raw: JsonArray?): List<ImageRequestImage> = raw.orEmpty().map { element ->
        val image = element.jsonObject
        val slot = image.getValue("slot").jsonPrimitive.int
        val data = image.optString("data") ?: "image-$slot"
        ImageRequestImage(slot = slot, role = image.str("role"), mime = image.str("mime"), data = data.toByteArray(Charsets.UTF_8))
    }

    /** wireOverride: dotted keys with string values, merged over the normalized wire. */
    private fun wireOverrideOf(raw: JsonObject?): Map<String, JsonPrimitive> = raw.orEmpty().mapValues { (key, value) ->
        val primitive = value as? JsonPrimitive
        require(primitive != null && primitive.isString) { "wireOverride $key is not a string" }
        primitive
    }

    private fun advancedOf(raw: JsonObject?): ImageRequestAdvanced {
        if (raw == null) return ImageRequestAdvanced()
        return ImageRequestAdvanced(
            negativePrompt = raw.optString("negativePrompt"),
            seed = (raw["seed"] as? JsonPrimitive)?.longOrNull,
            transparentBackground = (raw["transparentBackground"] as? JsonPrimitive)?.booleanOrNull,
            outputFormat = raw.optString("outputFormat"),
        )
    }

    private fun resolve(root: JsonElement, path: String): JsonElement? =
        path.split('.').fold(root as JsonElement?) { current, segment ->
            when (current) {
                is JsonObject -> current[segment]
                is JsonArray -> segment.toIntOrNull()?.let { current.getOrNull(it) }
                else -> null
            }
        }

    private fun isStandardBase64(text: String): Boolean =
        text.isNotEmpty() && text.length % 4 == 0 && runCatching { Base64.getDecoder().decode(text) }.isSuccess

    /** Returns null when [actual] satisfies the fixture pattern [expected], else a reason. */
    private fun mismatch(actual: JsonElement?, expected: JsonElement): String? {
        if (actual == null) return "missing (expected $expected)"
        val pattern = (expected as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (pattern == "*") {
            val present = when (actual) {
                is JsonNull -> false
                is JsonPrimitive -> actual.content.isNotEmpty()
                is JsonObject -> actual.isNotEmpty()
                is JsonArray -> actual.isNotEmpty()
            }
            return if (present) null else "expected non-empty, got $actual"
        }
        if (pattern != null && pattern.startsWith("data:") && pattern.endsWith(";base64,*")) {
            val prefix = pattern.dropLast(1)
            val text = (actual as? JsonPrimitive)?.takeIf { it.isString }?.content
            val ok = text != null && text.startsWith(prefix) && isStandardBase64(text.removePrefix(prefix))
            return if (ok) null else "expected $pattern, got $actual"
        }
        return if (actual == expected) null else "expected $expected, got $actual"
    }

    private fun compare(case: JsonObject): List<String> {
        val intent = case.getValue("intent").jsonObject
        val expect = case.getValue("expect").jsonObject
        val profile = profileOf(intent.str("profileRef"), case["profileOverride"] as? JsonObject)
        val normalized = ImageParamNormalizer.normalize(profile, requestOf(intent.getValue("params").jsonObject))
        val params = normalized.params ?: error("normalize failed: ${normalized.error?.wire}")
        val apiKey = intent.optString("apiKey") ?: "test-key"
        val baseUrlExample = expect.optString("baseUrlExample")
        val input = ImageRequestInput(
            operation = ImageOperation.fromWire(intent.str("operation")) ?: error("unknown operation"),
            modelId = intent.str("modelId"),
            prompt = intent.str("prompt"),
            wire = params.wire + wireOverrideOf(case["wireOverride"] as? JsonObject),
            images = imagesOf(intent["images"] as? JsonArray),
            advanced = advancedOf(intent["advanced"] as? JsonObject),
            baseUrl = intent.optString("baseUrl") ?: baseUrlExample ?: FALLBACK_BASE_URL,
            apiKey = apiKey,
        )
        val outcome = ImageRequestBuilder.build(profile, input)

        expect.optString("error")?.let { wanted ->
            return if (outcome.error?.wire == wanted) emptyList() else listOf("expected error $wanted, got ${outcome.error?.wire}")
        }
        val request = outcome.request ?: return listOf("expected a request, got error ${outcome.error?.wire}")
        val failures = mutableListOf<String>()
        fun check(label: String, problem: String?) {
            if (problem != null) failures += "$label: $problem"
        }

        check("method", request.method.takeIf { it != expect.str("method") }?.let { "got $it" })
        val wantedUrl = expect.optString("url")
            ?: (baseUrlExample.orEmpty().trimEnd('/') + expect.str("endpointPath"))
        check("url", request.url.takeIf { it != wantedUrl }?.let { "expected $wantedUrl, got $it" })
        val contentType = expect.str("contentType")
        check("Content-Type", request.headers["Content-Type"].takeIf { it != contentType }?.let { "got $it" })
        if (expect.containsKey("auth")) {
            val key = apiKey.trim { it in ASCII_WHITESPACE }
            val auth = expect["auth"]
            val (wantedAuth, wantedGoogKey) = when {
                auth is JsonNull -> null to null
                auth is JsonPrimitive && auth.isString && auth.content == "Authorization: Bearer" -> "Bearer $key" to null
                auth is JsonPrimitive && auth.isString && auth.content == "x-goog-api-key" -> null to key
                else -> error("unknown expect.auth $auth")
            }
            val authorization = request.headers["Authorization"]
            check("Authorization", authorization.takeIf { it != wantedAuth }?.let { "expected $wantedAuth, got $it" })
            val googKey = request.headers["x-goog-api-key"]
            check("x-goog-api-key", googKey.takeIf { it != wantedGoogKey }?.let { "expected $wantedGoogKey, got $it" })
        }
        // Plain string split: java.net.URI rejects URLs the contract keeps, such as a U+00A0 in the path.
        val queryNames = request.url.substringAfter('?', "").substringBefore('#').split('&').filter { it.isNotEmpty() }
            .map { it.substringBefore('=') }.toSet()
        (expect["queryExcludes"] as? JsonArray).orEmpty().forEach { key ->
            check("query", key.jsonPrimitive.content.takeIf { it in queryNames }?.let { "$it present" })
        }

        when (val body = request.body) {
            is ImageRequestBody.Json -> {
                check("body kind", "multipart expected".takeIf { contentType != "application/json" })
                (expect["bodyIncludes"] as? JsonObject).orEmpty().forEach { (path, wanted) ->
                    check("body $path", mismatch(resolve(body.json, path), wanted))
                }
                (expect["bodyExcludes"] as? JsonArray).orEmpty().forEach { path ->
                    val key = path.jsonPrimitive.content
                    check("body $key", resolve(body.json, key)?.let { "present: $it" })
                }
            }
            is ImageRequestBody.Multipart -> {
                check("body kind", "JSON expected".takeIf { contentType != "multipart/form-data" })
                val parts = expect["multipartParts"] as? JsonObject ?: return failures + "no multipartParts in expect"
                val fieldNames = body.fields.map { it.first }
                val duplicates = fieldNames.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
                check("field names", duplicates.takeIf { it.isNotEmpty() }?.let { "duplicated $it" })
                (parts["fieldOrder"] as? JsonArray)?.let { order ->
                    val wantedOrder = order.map { it.jsonPrimitive.content }
                    check("fieldOrder", fieldNames.takeIf { it != wantedOrder }?.let { "expected $wantedOrder, got $it" })
                }
                (parts["fields"] as? JsonObject).orEmpty().forEach { (name, wanted) ->
                    val actual = body.fields.firstOrNull { it.first == name }?.second?.let { JsonPrimitive(it) }
                    check("field $name", mismatch(actual, wanted))
                }
                val wantedFiles = (parts["files"] as? JsonArray).orEmpty().map { it.jsonObject }
                check("files", "expected ${wantedFiles.size}, got ${body.files.size}".takeIf { wantedFiles.size != body.files.size })
                wantedFiles.zip(body.files).forEachIndexed { index, (wanted, file) ->
                    check("file $index name", file.name.takeIf { it != wanted.str("name") }?.let { "got $it" })
                    check("file $index mime", file.mime.takeIf { it != wanted.str("mime") }?.let { "got $it" })
                    wanted.optString("filename")?.let { filename ->
                        check("file $index filename", file.filename.takeIf { it != filename }?.let { "got $it" })
                    }
                    wanted.optString("data")?.let { data ->
                        val text = String(file.data, Charsets.UTF_8)
                        check("file $index data", text.takeIf { it != data }?.let { "got $it" })
                    }
                }
                val names = body.fields.map { it.first }.toSet() + body.files.map { it.name }
                (parts["excludes"] as? JsonArray).orEmpty().forEach { excluded ->
                    val name = excluded.jsonPrimitive.content
                    check("excludes", name.takeIf { it in names }?.let { "$it present" })
                }
            }
        }
        return failures
    }

    @Test
    fun everyImageRequestCaseMatchesTheSharedShape() {
        val failures = mutableListOf<String>()
        var ran = 0
        for (case in cases) {
            val caseId = case.str("caseId")
            val problems = runCatching { compare(case) }.getOrElse { listOf("threw ${it.message}") }
            if (problems.none { it.startsWith("threw ") }) ran += 1
            failures += problems.map { "$caseId: $it" }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
        assertEquals("cases actually compared", EXPECTED_CASES, ran)
    }

    @Test
    fun geminiModelSegmentEncodesLoneSurrogateAsReplacement() {
        val profile = profileOf("gemini_flash_image", null)
        val normalized = ImageParamNormalizer.normalize(profile, ImageParamRequest(aspect = "1:1"))
        val params = normalized.params ?: error("normalize failed: ${normalized.error?.wire}")
        val input = ImageRequestInput(
            operation = ImageOperation.GENERATE,
            modelId = "a\uD800b",
            prompt = "a red fox in the snow",
            wire = params.wire,
            images = emptyList(),
            baseUrl = FALLBACK_BASE_URL,
            apiKey = "test-key",
        )
        val outcome = ImageRequestBuilder.build(profile, input)
        val url = outcome.request?.url ?: error("expected a request, got error ${outcome.error?.wire}")
        assertTrue("lone surrogate must encode as U+FFFD bytes, got $url", url.endsWith("/models/a%EF%BF%BDb:generateContent"))
    }

    private companion object {
        val SUPPORTED_ROUTES = setOf(
            "openai_images",
            "xai_images",
            "openrouter_images",
            "minimax_image_generation",
            "gemini_generate_content",
            "chat_modalities",
            "dashscope_multimodal",
        )
        const val EXPECTED_CASES = 113

        /** Error cases carry no baseUrlExample; a valid URL keeps the base URL rule out of their way. */
        const val FALLBACK_BASE_URL = "https://api.example.com/v1"

        /** Contract whitespace is ASCII only: space, tab, LF, VT, FF, CR. */
        const val ASCII_WHITESPACE = " \t\n\u000B\u000C\r"
    }
}
