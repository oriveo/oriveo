package ai.oriveo.community.core.studio

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import java.util.Base64

/** One input image; [data] holds the exact bytes that go on the wire. */
class ImageRequestImage(val slot: Int, val role: String, val mime: String, val data: ByteArray)

/** Optional advanced controls; each is sent only when the profile and route support it. */
data class ImageRequestAdvanced(
    val negativePrompt: String? = null,
    val seed: Long? = null,
    val transparentBackground: Boolean? = null,
    val outputFormat: String? = null,
)

/** Builder input; [wire] is the dotted-key result of [ImageParamNormalizer.normalize]. */
data class ImageRequestInput(
    val operation: ImageOperation,
    val modelId: String,
    val prompt: String,
    val wire: Map<String, JsonPrimitive>,
    val images: List<ImageRequestImage>,
    val advanced: ImageRequestAdvanced = ImageRequestAdvanced(),
    val baseUrl: String,
    val apiKey: String,
)

/** Closed error set of the image request builder. */
enum class ImageRequestError(val wire: String) {
    INVALID_REQUEST("invalid_request"),
    INVALID_PROFILE("invalid_profile"),
}

/** Request body: a JSON object or an unencoded multipart description (no boundary). */
sealed interface ImageRequestBody {
    data class Json(val json: JsonObject) : ImageRequestBody

    data class Multipart(val fields: List<Pair<String, String>>, val files: List<File>) : ImageRequestBody

    class File(val name: String, val filename: String, val mime: String, val data: ByteArray)
}

/** A fully described HTTP request; [headers] keep insertion order. */
data class ImageHttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val body: ImageRequestBody,
)

/**
 * Pure builder of BYOK image requests (shared contract model-contracts/request_shape_contract.v2.json
 * imageRequests). Handles openai_images, xai_images, openrouter_images, minimax_image_generation,
 * gemini_generate_content, chat_modalities and dashscope_multimodal; any other route is invalid_profile.
 * JSON bodies write every fixed field of the route first, then wire and advanced keys, which never overwrite.
 */
object ImageRequestBuilder {
    data class Outcome(val request: ImageHttpRequest?, val error: ImageRequestError?)

    private const val BASE_ROLE = "base"
    private const val MAX_SEED = 2_147_483_647L
    private const val JSON_CONTENT_TYPE = "application/json"
    private const val MULTIPART_CONTENT_TYPE = "multipart/form-data"
    private const val MULTIPART_FILE_NAME = "image[]"

    private val SUPPORTED_ROUTES = setOf(
        ImageRoute.OPENAI_IMAGES,
        ImageRoute.XAI_IMAGES,
        ImageRoute.OPENROUTER_IMAGES,
        ImageRoute.MINIMAX_IMAGE_GENERATION,
        ImageRoute.GEMINI_GENERATE_CONTENT,
        ImageRoute.CHAT_MODALITIES,
        ImageRoute.DASHSCOPE_MULTIMODAL,
    )
    private const val DASHSCOPE_PATH = "/services/aigc/multimodal-generation/generation"
    private const val GEMINI_MODEL_PREFIX = "models/"
    private const val GEMINI_KEY_HEADER = "x-goog-api-key"
    private const val HEX_DIGITS = "0123456789ABCDEF"
    private const val PROTO_SEGMENT = "__proto__"
    private val MIME_EXTENSIONS = mapOf("image/png" to "png", "image/jpeg" to "jpg", "image/webp" to "webp")
    private val OUTPUT_FORMATS = setOf("png", "jpeg", "webp")

    /** ASCII whitespace only (space, tab, LF, VT, FF, CR); U+00A0 and other Unicode spaces are content. */
    private const val ASCII_WHITESPACE = " \t\n\u000B\u000C\r"

    /**
     * http(s) origin plus optional port and path; no userinfo, query or fragment. Whitespace is spelled
     * out as ASCII characters (no \s / \v, whose meaning differs between engines); U+00A0 stays content.
     */
    private val BASE_URL_PATTERN = Regex(
        "^[Hh][Tt][Tt][Pp][Ss]?://(\\[[0-9A-Fa-f:.]+\\]|[^/?# \\t\\n\\x0B\\f\\r:@\\[\\]]+)" +
            "(:[0-9]{1,5})?(/[^?# \\t\\n\\x0B\\f\\r]*)?$",
    )

    /** Thrown while assembling a body when a key would overwrite another; mapped to invalid_profile. */
    private class KeyCollision : RuntimeException()

    /** Body key per advanced field (profile.params name); a route without an entry sends none of them. */
    private val ADVANCED_KEYS: Map<ImageRoute, Map<String, String>> = mapOf(
        ImageRoute.OPENAI_IMAGES to mapOf(
            "negativePrompt" to "negative_prompt",
            "seed" to "seed",
            "transparentBackground" to "background",
            "outputFormat" to "output_format",
        ),
        ImageRoute.OPENROUTER_IMAGES to mapOf(
            "seed" to "seed",
            "transparentBackground" to "background",
            "outputFormat" to "output_format",
        ),
        ImageRoute.MINIMAX_IMAGE_GENERATION to mapOf("seed" to "seed"),
        // Dotted key: the seed goes into the fixed generationConfig object.
        ImageRoute.GEMINI_GENERATE_CONTENT to mapOf("seed" to "generationConfig.seed"),
        ImageRoute.CHAT_MODALITIES to mapOf("seed" to "seed"),
        // Dotted keys: both go into the fixed parameters object; transparency and format are never sent.
        ImageRoute.DASHSCOPE_MULTIMODAL to mapOf(
            "negativePrompt" to "parameters.negative_prompt",
            "seed" to "parameters.seed",
        ),
    )

    fun build(profile: ImageProfile, input: ImageRequestInput): Outcome {
        val route = profile.route
        if (route !in SUPPORTED_ROUTES) return failure(ImageRequestError.INVALID_PROFILE)
        if (input.operation !in profile.operations) return failure(ImageRequestError.INVALID_REQUEST)
        val isEdit = input.operation == ImageOperation.EDIT
        val transport = if (isEdit) {
            profile.editTransport?.takeIf { it in route.allowedEditTransports }
                ?: return failure(ImageRequestError.INVALID_PROFILE)
        } else {
            null
        }
        val modelId = asciiTrim(input.modelId)
        if (modelId.isEmpty() || isAsciiBlank(input.prompt)) return failure(ImageRequestError.INVALID_REQUEST)
        val images = orderedImages(profile, input.images, transport) ?: return failure(ImageRequestError.INVALID_REQUEST)
        if (!advancedInRange(input.advanced)) return failure(ImageRequestError.INVALID_REQUEST)
        val baseUrl = validBaseUrl(input.baseUrl) ?: return failure(ImageRequestError.INVALID_REQUEST)

        val path = when {
            route == ImageRoute.GEMINI_GENERATE_CONTENT -> {
                val segment = modelId.removePrefix(GEMINI_MODEL_PREFIX)
                if (segment.isEmpty()) return failure(ImageRequestError.INVALID_REQUEST)
                "/models/${percentEncode(segment)}:generateContent"
            }
            route == ImageRoute.CHAT_MODALITIES -> "/chat/completions"
            route == ImageRoute.DASHSCOPE_MULTIMODAL -> DASHSCOPE_PATH
            route == ImageRoute.OPENROUTER_IMAGES -> "/images"
            route == ImageRoute.MINIMAX_IMAGE_GENERATION -> "/image_generation"
            transport == ImageEditTransport.MULTIPART || transport == ImageEditTransport.JSON_IMAGE_OBJECT -> "/images/edits"
            else -> "/images/generations"
        }
        val advanced = advancedFields(profile, input.advanced)
        val body = try {
            if (transport == ImageEditTransport.MULTIPART) {
                multipartBody(modelId, input, images, advanced)
            } else {
                jsonBody(profile, transport, modelId, input, images, advanced)
            }
        } catch (_: KeyCollision) {
            return failure(ImageRequestError.INVALID_PROFILE)
        }
        val headers = linkedMapOf(
            "Content-Type" to if (body is ImageRequestBody.Multipart) MULTIPART_CONTENT_TYPE else JSON_CONTENT_TYPE,
        )
        asciiTrim(input.apiKey).takeIf { it.isNotEmpty() }?.let { key ->
            if (route == ImageRoute.GEMINI_GENERATE_CONTENT) {
                headers[GEMINI_KEY_HEADER] = key
            } else {
                headers["Authorization"] = "Bearer $key"
            }
        }
        val request = ImageHttpRequest(method = "POST", url = baseUrl + path, headers = headers, body = body)
        return Outcome(request = request, error = null)
    }

    private fun failure(error: ImageRequestError): Outcome = Outcome(request = null, error = error)

    /** Replaces each unpaired surrogate with U+FFFD; paired surrogates are kept. */
    private fun wellFormed(text: String): String = buildString(text.length) {
        var index = 0
        while (index < text.length) {
            val char = text[index]
            val paired = char.isHighSurrogate() && index + 1 < text.length && text[index + 1].isLowSurrogate()
            when {
                paired -> {
                    append(char).append(text[index + 1])
                    index += 2
                    continue
                }
                char.isSurrogate() -> append('\uFFFD')
                else -> append(char)
            }
            index += 1
        }
    }

    /**
     * Percent-encodes every UTF-8 byte outside A-Z a-z 0-9 - . _ ~ as %XX (uppercase hex). A lone
     * surrogate becomes U+FFFD (EF BF BD) like JS TextEncoder, not the "?" of String.toByteArray.
     */
    private fun percentEncode(text: String): String = buildString {
        wellFormed(text).toByteArray(Charsets.UTF_8).forEach { byte ->
            val value = byte.toInt() and 0xFF
            val char = value.toChar()
            val unreserved = char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' || char in "-._~"
            if (unreserved) {
                append(char)
            } else {
                append('%').append(HEX_DIGITS[value shr 4]).append(HEX_DIGITS[value and 0x0F])
            }
        }
    }

    private fun isAsciiWhitespace(char: Char): Boolean = char in ASCII_WHITESPACE

    private fun asciiTrim(text: String): String = text.trim(::isAsciiWhitespace)

    private fun isAsciiBlank(text: String): Boolean = text.all(::isAsciiWhitespace)

    /** Validated images, base first then ascending slot; null when the set is not sendable. */
    private fun orderedImages(
        profile: ImageProfile,
        images: List<ImageRequestImage>,
        transport: ImageEditTransport?,
    ): List<ImageRequestImage>? {
        if (transport == null) return images.takeIf { it.isEmpty() }
        if (images.isEmpty()) return null
        if (images.any { it.slot <= 0 } || images.map { it.slot }.toSet().size != images.size) return null
        if (images.count { it.role == BASE_ROLE } > 1) return null
        if (images.any { it.mime !in MIME_EXTENSIONS || it.data.isEmpty() }) return null
        val profileLimit = profile.maxReferenceImages?.takeIf { it > 0 } ?: 1
        if (images.size > minOf(profileLimit, transportLimit(transport))) return null
        return images.sortedWith(compareBy({ it.role != BASE_ROLE }, { it.slot }))
    }

    private fun transportLimit(transport: ImageEditTransport): Int = when (transport) {
        ImageEditTransport.JSON_IMAGE, ImageEditTransport.JSON_IMAGE_URL -> 1
        ImageEditTransport.JSON_IMAGE_OBJECT -> 5
        // input_references has no transport cap; only the profile limit applies.
        else -> Int.MAX_VALUE
    }

    /** null means unset; a set seed or output format is range-checked whether or not it is sent. */
    private fun advancedInRange(advanced: ImageRequestAdvanced): Boolean {
        val seedOk = advanced.seed?.let { it in 0..MAX_SEED } ?: true
        val formatOk = advanced.outputFormat?.let { it in OUTPUT_FORMATS } ?: true
        return seedOk && formatOk
    }

    /**
     * ASCII-trimmed base URL without trailing slashes, or null unless the whole string matches
     * [BASE_URL_PATTERN]. No platform URL parser: those reject hosts such as "my_relay".
     */
    private fun validBaseUrl(raw: String): String? {
        val trimmed = asciiTrim(raw)
        if (!BASE_URL_PATTERN.matches(trimmed)) return null
        return trimmed.trimEnd('/')
    }

    private fun supports(profile: ImageProfile, field: String): Boolean {
        val flag = profile.params?.get(field) as? JsonPrimitive ?: return false
        return !flag.isString && flag.booleanOrNull == true
    }

    /** profile.params.promptExtend when it is a literal JSON boolean; strings, numbers and null are ignored. */
    private fun promptExtend(profile: ImageProfile): Boolean? {
        val flag = profile.params?.get("promptExtend") as? JsonPrimitive ?: return null
        return if (flag.isString) null else flag.booleanOrNull
    }

    /** Advanced body fields in fixed order; only fields whose profile.params flag is literally true. */
    private fun advancedFields(profile: ImageProfile, advanced: ImageRequestAdvanced): List<Pair<String, JsonPrimitive>> {
        val keys = ADVANCED_KEYS[profile.route] ?: return emptyList()
        fun key(field: String): String? = keys[field]?.takeIf { supports(profile, field) }
        val fields = mutableListOf<Pair<String, JsonPrimitive>>()
        key("negativePrompt")?.let { k ->
            advanced.negativePrompt?.takeUnless { isAsciiBlank(it) }?.let { fields += k to JsonPrimitive(it) }
        }
        key("seed")?.let { k -> advanced.seed?.let { fields += k to JsonPrimitive(it) } }
        val transparent = key("transparentBackground")?.takeIf { advanced.transparentBackground == true }
        transparent?.let { fields += it to JsonPrimitive("transparent") }
        key("outputFormat")?.let { k ->
            // A transparent background cannot be jpeg, so the format is locked to png.
            val format = if (transparent != null) "png" else advanced.outputFormat
            format?.let { fields += k to JsonPrimitive(it) }
        }
        return fields
    }

    private fun dataUri(image: ImageRequestImage): String =
        "data:${image.mime};base64," + Base64.getEncoder().encodeToString(image.data)

    private fun jsonBody(
        profile: ImageProfile,
        transport: ImageEditTransport?,
        modelId: String,
        input: ImageRequestInput,
        images: List<ImageRequestImage>,
        advanced: List<Pair<String, JsonPrimitive>>,
    ): ImageRequestBody.Json {
        val route = profile.route
        val root = when (route) {
            ImageRoute.GEMINI_GENERATE_CONTENT -> geminiFixedFields(input.prompt, images)
            ImageRoute.CHAT_MODALITIES -> chatFixedFields(modelId, input.prompt, images)
            ImageRoute.DASHSCOPE_MULTIMODAL -> dashscopeFixedFields(modelId, input.prompt, images, promptExtend(profile))
            else -> imagesFixedFields(route, transport, modelId, input.prompt, images)
        }
        input.wire.forEach { (dotted, value) -> putPath(root, dotted.split('.'), value) }
        advanced.forEach { (dotted, value) -> putPath(root, dotted.split('.'), value) }
        return ImageRequestBody.Json(toJson(root))
    }

    /** model, prompt, the image field of [transport] and the route's response_format. */
    private fun imagesFixedFields(
        route: ImageRoute,
        transport: ImageEditTransport?,
        modelId: String,
        prompt: String,
        images: List<ImageRequestImage>,
    ): MutableMap<String, Any> {
        val root = linkedMapOf<String, Any>("model" to JsonPrimitive(modelId), "prompt" to JsonPrimitive(prompt))
        when (transport) {
            ImageEditTransport.JSON_IMAGE -> putNew(root, "image", JsonPrimitive(dataUri(images.first())))
            ImageEditTransport.JSON_IMAGE_URL -> putNew(root, "image_url", JsonPrimitive(dataUri(images.first())))
            ImageEditTransport.JSON_IMAGE_OBJECT -> {
                val objects = images.map { JsonObject(mapOf("url" to JsonPrimitive(dataUri(it)))) }
                if (objects.size == 1) putNew(root, "image", objects.first()) else putNew(root, "images", JsonArray(objects))
            }
            ImageEditTransport.INPUT_REFERENCES -> {
                // Always an array, even for a single reference.
                val references = images.map {
                    JsonObject(
                        mapOf(
                            "type" to JsonPrimitive("image_url"),
                            "image_url" to JsonObject(mapOf("url" to JsonPrimitive(dataUri(it)))),
                        ),
                    )
                }
                putNew(root, "input_references", JsonArray(references))
            }
            else -> Unit
        }
        when (route) {
            ImageRoute.XAI_IMAGES -> putNew(root, "response_format", JsonPrimitive("b64_json"))
            ImageRoute.MINIMAX_IMAGE_GENERATION -> putNew(root, "response_format", JsonPrimitive("base64"))
            else -> Unit
        }
        return root
    }

    /** contents (text part first, then inline_data parts with raw base64) and generationConfig; no model or prompt. */
    private fun geminiFixedFields(prompt: String, images: List<ImageRequestImage>): MutableMap<String, Any> {
        val parts = listOf(JsonObject(mapOf("text" to JsonPrimitive(prompt)))) + images.map { image ->
            val inline = JsonObject(
                mapOf(
                    "mime_type" to JsonPrimitive(image.mime),
                    "data" to JsonPrimitive(Base64.getEncoder().encodeToString(image.data)),
                ),
            )
            JsonObject(mapOf("inline_data" to inline))
        }
        val content = JsonObject(mapOf("role" to JsonPrimitive("user"), "parts" to JsonArray(parts)))
        // A mutable map so dotted wire / advanced keys can extend generationConfig without overwriting.
        val generationConfig = linkedMapOf<String, Any>(
            "responseModalities" to JsonArray(listOf(JsonPrimitive("TEXT"), JsonPrimitive("IMAGE"))),
        )
        return linkedMapOf("contents" to JsonArray(listOf(content)), "generationConfig" to generationConfig)
    }

    /** model, one user message, modalities and stream=false; no top-level prompt. */
    private fun chatFixedFields(modelId: String, prompt: String, images: List<ImageRequestImage>): MutableMap<String, Any> {
        val content: JsonElement = if (images.isEmpty()) {
            JsonPrimitive(prompt)
        } else {
            val text = JsonObject(mapOf("type" to JsonPrimitive("text"), "text" to JsonPrimitive(prompt)))
            JsonArray(
                listOf(text) + images.map {
                    JsonObject(
                        mapOf(
                            "type" to JsonPrimitive("image_url"),
                            "image_url" to JsonObject(mapOf("url" to JsonPrimitive(dataUri(it)))),
                        ),
                    )
                },
            )
        }
        val message = JsonObject(mapOf("role" to JsonPrimitive("user"), "content" to content))
        return linkedMapOf(
            "model" to JsonPrimitive(modelId),
            "messages" to JsonArray(listOf(message)),
            "modalities" to JsonArray(listOf(JsonPrimitive("image"), JsonPrimitive("text"))),
            "stream" to JsonPrimitive(false),
        )
    }

    /**
     * model, input.messages with one user message (image items in order, then exactly one text item) and
     * the fixed parameters object; no top-level prompt, messages, stream or response_format.
     */
    private fun dashscopeFixedFields(
        modelId: String,
        prompt: String,
        images: List<ImageRequestImage>,
        promptExtend: Boolean?,
    ): MutableMap<String, Any> {
        val content = images.map { JsonObject(mapOf("image" to JsonPrimitive(dataUri(it)))) } +
            JsonObject(mapOf("text" to JsonPrimitive(prompt)))
        val message = JsonObject(mapOf("role" to JsonPrimitive("user"), "content" to JsonArray(content)))
        // A mutable map so dotted wire / advanced keys can extend parameters; prompt_extend is written even when false.
        val parameters = linkedMapOf<String, Any>()
        promptExtend?.let { parameters["prompt_extend"] = JsonPrimitive(it) }
        return linkedMapOf(
            "model" to JsonPrimitive(modelId),
            "input" to JsonObject(mapOf("messages" to JsonArray(listOf(message)))),
            "parameters" to parameters,
        )
    }

    /** Sets [key] only when absent; an existing key means the profile maps two values onto it. */
    private fun putNew(node: MutableMap<String, Any>, key: String, value: Any) {
        if (key in node) throw KeyCollision()
        node[key] = value
    }

    /**
     * Expands a dotted key; a taken leaf, a non-object intermediate (arrays included) or any "__proto__"
     * segment is a collision, never an overwrite. A fixed-field JsonObject on the path is copied into a
     * writable map so new keys can go inside it; only keys it already has collide.
     */
    @Suppress("UNCHECKED_CAST")
    private fun putPath(node: MutableMap<String, Any>, segments: List<String>, value: JsonElement) {
        if (PROTO_SEGMENT in segments) throw KeyCollision()
        val head = segments.first()
        if (segments.size == 1) {
            putNew(node, head, value)
            return
        }
        val child = when (val existing = node[head]) {
            null -> linkedMapOf<String, Any>().also { node[head] = it }
            is MutableMap<*, *> -> existing as MutableMap<String, Any>
            is JsonObject -> LinkedHashMap<String, Any>(existing).also { node[head] = it }
            else -> throw KeyCollision()
        }
        putPath(child, segments.drop(1), value)
    }

    @Suppress("UNCHECKED_CAST")
    private fun toJson(node: Map<String, Any>): JsonObject = JsonObject(
        node.mapValues { (_, value) -> value as? JsonElement ?: toJson(value as Map<String, Any>) },
    )

    private fun multipartBody(
        modelId: String,
        input: ImageRequestInput,
        images: List<ImageRequestImage>,
        advanced: List<Pair<String, JsonPrimitive>>,
    ): ImageRequestBody.Multipart {
        val fields = mutableListOf("model" to modelId, "prompt" to input.prompt)
        val taken = mutableSetOf("model", "prompt")
        fun add(key: String, value: String) {
            if (!taken.add(key)) throw KeyCollision()
            fields += key to value
        }
        input.wire.entries.sortedBy { it.key }.forEach { add(it.key, it.value.content) }
        advanced.forEach { (key, value) -> add(key, value.content) }
        val files = images.mapIndexed { index, image ->
            ImageRequestBody.File(
                name = MULTIPART_FILE_NAME,
                filename = "image-${index + 1}.${MIME_EXTENSIONS.getValue(image.mime)}",
                mime = image.mime,
                data = image.data,
            )
        }
        return ImageRequestBody.Multipart(fields = fields, files = files)
    }
}
