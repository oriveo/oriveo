package ai.oriveo.community.core.studio

import java.util.Base64
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlin.math.floor

/**
 * Image response normalization for Studio: [parse] accepts every known response shape,
 * [decodeImageInfo] reads the real pixel size from the image header, [materialize] turns a
 * parsed image into bytes and [assemble] judges the delivery from the per-image outcomes.
 * Behavior follows image_response_samples.v1.
 */
object StudioImageResponse {
    enum class Kind(val wire: String) { B64("b64"), URL("url"), DATA_URL("data_url") }

    /** [value] is the raw base64 string, the URL, or the full data URL; [mime] is the declared mime (null = sniff). */
    data class Image(val kind: Kind, val mime: String?, val value: String, val revisedPrompt: String?)

    data class Usage(val inputTokens: Long?, val outputTokens: Long?, val totalTokens: Long?)

    data class Size(val width: Int, val height: Int)

    /** [declaredSize] is informational only; the real size always comes from [decodeImageInfo]. */
    data class Parsed(
        val shapes: List<String>,
        val deduped: List<String>,
        val images: List<Image>,
        val usage: Usage?,
        val declaredSize: Size?,
    )

    data class ImageInfo(val mime: String, val width: Int, val height: Int)

    /** Decoded bytes with the mime and stored pixel size read from the header. */
    class DeliveredImage(val bytes: ByteArray, val mime: String, val width: Int, val height: Int)

    /** Per-image failure kinds, named as in image_error_samples.v1. */
    enum class Failure(val wire: String) { NETWORK("network"), TIMEOUT("timeout"), DECODE_FAILED("decode_failed") }

    sealed interface Outcome {
        class Ok(val image: DeliveredImage) : Outcome
        data class Failed(val failure: Failure) : Outcome
    }

    sealed interface Delivery {
        val wire: String

        data object Ok : Delivery {
            override val wire = "ok"
        }

        data object Partial : Delivery {
            override val wire = "partial"
        }

        data class Failed(val failure: Failure) : Delivery {
            override val wire: String get() = failure.wire
        }
    }

    /** [result] is null when there is no image at all: the error classifier decides then. */
    data class Assembly(val result: Delivery?, val delivered: Int, val failures: List<Failure>)

    private const val SHAPE_DATA_B64 = "data[].b64_json"
    private const val SHAPE_DATA_URL = "data[].url"
    private const val SHAPE_IMAGES_URL = "images[].url"
    private const val SHAPE_MESSAGE_IMAGES = "message.images[]"
    private const val SHAPE_MARKDOWN = "markdown data URL"
    private const val SHAPE_INLINE_DATA = "inlineData"
    private const val SHAPE_DASHSCOPE = "output.choices[].message.content[].image"
    private const val SHAPE_MINIMAX = "data.image_base64[]"

    private val MARKDOWN_DATA_URL = Regex("""!\[[^\]]*\]\((data:(image/[a-z0-9.+-]+);base64,[^)]+)\)""", RegexOption.IGNORE_CASE)
    private val DATA_URL_MIME = Regex("""^data:(image/[a-z0-9.+-]+);base64,""", RegexOption.IGNORE_CASE)
    private val DATA_URL_BASE64_PREFIX = Regex("""^data:[^,]*;base64,""", RegexOption.IGNORE_CASE)
    private val SIZE = Regex("""^(\d+)x(\d+)$""")

    private class Collector {
        val shapes = mutableListOf<String>()
        val images = mutableListOf<Image>()

        fun add(shape: String, image: Image) {
            images += image
            if (shape !in shapes) shapes += shape
        }
    }

    fun parse(body: JsonElement?): Parsed {
        val root = body as? JsonObject ?: return Parsed(emptyList(), emptyList(), emptyList(), null, null)
        val out = Collector()
        val deduped = mutableListOf<String>()

        val data = root["data"]
        if (data is JsonArray) {
            for (item in data) {
                val obj = item as? JsonObject ?: continue
                val revisedPrompt = obj["revised_prompt"].string()
                val b64 = obj["b64_json"].string()
                val url = obj["url"].string()
                when {
                    b64 != null -> {
                        val mime = obj["mime_type"].string() ?: obj["media_type"].string()
                        out.add(SHAPE_DATA_B64, Image(Kind.B64, mime, b64, revisedPrompt))
                    }
                    // Declared mime is read for b64 items only; url items sniff (http) or use the data URL prefix.
                    url != null -> out.add(SHAPE_DATA_URL, urlImage(url, revisedPrompt))
                }
            }
        }
        // SiliconFlow sends data[] and images[] for the same picture: only data[] counts.
        val images = root["images"]
        if (images is JsonArray) {
            if (data is JsonArray && data.isNotEmpty()) {
                deduped += SHAPE_IMAGES_URL
            } else {
                for (item in images) {
                    val url = (item as? JsonObject)?.get("url").string() ?: continue
                    out.add(SHAPE_IMAGES_URL, urlImage(url, null))
                }
            }
        }
        ((data as? JsonObject)?.get("image_base64") as? JsonArray)?.forEach { item ->
            item.string()?.let { out.add(SHAPE_MINIMAX, Image(Kind.B64, null, it, null)) }
        }
        root["choices"].array().forEach { choice ->
            val message = (choice as? JsonObject)?.get("message") as? JsonObject ?: return@forEach
            message["images"].array().forEach { item ->
                val url = ((item as? JsonObject)?.get("image_url") as? JsonObject)?.get("url").string()
                if (url != null) out.add(SHAPE_MESSAGE_IMAGES, urlImage(url, null))
            }
            message["content"].string()?.let { content ->
                for (match in MARKDOWN_DATA_URL.findAll(content)) {
                    val (dataUrl, mime) = match.destructured
                    out.add(SHAPE_MARKDOWN, Image(Kind.DATA_URL, mime.lowercase(), dataUrl, null))
                }
            }
        }
        root["candidates"].array().forEach { candidate ->
            val content = (candidate as? JsonObject)?.get("content") as? JsonObject ?: return@forEach
            content["parts"].array().forEach { part ->
                val obj = part as? JsonObject ?: return@forEach
                val inline = (obj["inlineData"] as? JsonObject) ?: (obj["inline_data"] as? JsonObject) ?: return@forEach
                val b64 = inline["data"].string() ?: return@forEach
                val mime = inline["mimeType"].string() ?: inline["mime_type"].string()
                out.add(SHAPE_INLINE_DATA, Image(Kind.B64, mime, b64, null))
            }
        }
        ((root["output"] as? JsonObject)?.get("choices")).array().forEach { choice ->
            val message = (choice as? JsonObject)?.get("message") as? JsonObject ?: return@forEach
            message["content"].array().forEach { part ->
                val url = (part as? JsonObject)?.get("image").string()
                if (url != null) out.add(SHAPE_DASHSCOPE, urlImage(url, null))
            }
        }
        return Parsed(out.shapes, deduped, out.images, usageOf(root), declaredSizeOf(root))
    }

    /** Any URL field holding a data: URI (case-insensitive) is an inline data URL; its prefix gives the mime. */
    private fun urlImage(url: String, revisedPrompt: String?): Image =
        if (url.startsWith("data:", ignoreCase = true)) {
            Image(Kind.DATA_URL, DATA_URL_MIME.find(url)?.groupValues?.get(1)?.lowercase(), url, revisedPrompt)
        } else {
            Image(Kind.URL, null, url, revisedPrompt)
        }

    private fun usageOf(root: JsonObject): Usage? {
        val usage = root["usage"] as? JsonObject
        val meta = root["usageMetadata"] as? JsonObject
        val result = Usage(
            inputTokens = firstCount(usage?.get("input_tokens"), usage?.get("prompt_tokens"), meta?.get("promptTokenCount")),
            outputTokens = firstCount(usage?.get("output_tokens"), usage?.get("completion_tokens"), meta?.get("candidatesTokenCount")),
            totalTokens = firstCount(usage?.get("total_tokens"), meta?.get("totalTokenCount")),
        )
        return result.takeUnless { it.inputTokens == null && it.outputTokens == null && it.totalTokens == null }
    }

    /** First positive integer wins, else the first integer present (relays report 0 next to the real field). */
    private fun firstCount(vararg values: JsonElement?): Long? {
        val integers = values.mapNotNull { it.integer() }
        return integers.firstOrNull { it > 0 } ?: integers.firstOrNull()
    }

    private fun declaredSizeOf(root: JsonObject): Size? {
        root["size"].string()?.let { SIZE.matchEntire(it) }?.let { match ->
            val width = match.groupValues[1].toIntOrNull()
            val height = match.groupValues[2].toIntOrNull()
            if (width != null && height != null && width > 0 && height > 0) return Size(width, height)
        }
        val usage = root["usage"] as? JsonObject ?: return null
        val width = usage["width"].integer()
        val height = usage["height"].integer()
        if (width == null || height == null) return null
        if (width !in 1..Int.MAX_VALUE.toLong() || height !in 1..Int.MAX_VALUE.toLong()) return null
        return Size(width.toInt(), height.toInt())
    }

    private fun JsonElement?.string(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

    /** Integral JSON numbers only (14, 14.0 and 1e3 count; strings, fractions and non-finite values do not). */
    private fun JsonElement?.integer(): Long? {
        val primitive = (this as? JsonPrimitive)?.takeIf { !it.isString } ?: return null
        primitive.content.toLongOrNull()?.let { return it }
        val value = primitive.doubleOrNull ?: return null
        if (!value.isFinite() || value != floor(value)) return null
        if (value < -9.223372036854775808E18 || value >= 9.223372036854775808E18) return null
        return value.toLong()
    }

    private fun JsonElement?.array(): List<JsonElement> = (this as? JsonArray) ?: emptyList()

    /**
     * Reads the stored pixel size from a png (IHDR), jpeg (SOF0-SOF15 except C4 / C8 / CC) or
     * webp (VP8, VP8L, VP8X) header; EXIF orientation is ignored. Anything else, truncated or empty is null.
     */
    fun decodeImageInfo(bytes: ByteArray): ImageInfo? = png(bytes) ?: jpeg(bytes) ?: webp(bytes)

    private val PNG_SIGNATURE = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    private fun ByteArray.u8(at: Int): Int = this[at].toInt() and 0xFF
    private fun ByteArray.be16(at: Int): Int = (u8(at) shl 8) or u8(at + 1)
    private fun ByteArray.be32(at: Int): Long = (be16(at).toLong() shl 16) or be16(at + 2).toLong()
    private fun ByteArray.le16(at: Int): Int = u8(at) or (u8(at + 1) shl 8)
    private fun ByteArray.le24(at: Int): Int = le16(at) or (u8(at + 2) shl 16)
    private fun ByteArray.ascii(at: Int, text: String): Boolean =
        at + text.length <= size && text.indices.all { this[at + it] == text[it].code.toByte() }

    private fun info(mime: String, width: Long, height: Long): ImageInfo? =
        if (width in 1..Int.MAX_VALUE.toLong() && height in 1..Int.MAX_VALUE.toLong()) {
            ImageInfo(mime, width.toInt(), height.toInt())
        } else {
            null
        }

    private fun png(b: ByteArray): ImageInfo? {
        if (b.size < 24 || PNG_SIGNATURE.indices.any { b[it] != PNG_SIGNATURE[it] } || !b.ascii(12, "IHDR")) return null
        return info("image/png", b.be32(16), b.be32(20))
    }

    private fun jpeg(b: ByteArray): ImageInfo? {
        if (b.size < 4 || b.u8(0) != 0xFF || b.u8(1) != 0xD8) return null
        var i = 2
        while (i < b.size) {
            if (b.u8(i) != 0xFF) return null
            while (i < b.size && b.u8(i) == 0xFF) i++
            if (i >= b.size) return null
            val marker = b.u8(i++)
            // Standalone markers carry no length.
            if (marker == 0x01 || marker == 0xD8 || marker in 0xD0..0xD7) continue
            // End of image or start of scan before any frame header: no size to read.
            if (marker == 0xD9 || marker == 0xDA) return null
            if (i + 2 > b.size) return null
            val length = b.be16(i)
            if (length < 2) return null
            if (marker in 0xC0..0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
                // length(2) precision(1) height(2) width(2): a shorter segment is malformed.
                if (length < 7 || i + 7 > b.size) return null
                return info("image/jpeg", b.be16(i + 5).toLong(), b.be16(i + 3).toLong())
            }
            i += length
        }
        return null
    }

    private fun webp(b: ByteArray): ImageInfo? {
        if (b.size < 20 || !b.ascii(0, "RIFF") || !b.ascii(8, "WEBP")) return null
        return when {
            b.ascii(12, "VP8 ") -> {
                if (b.size < 30 || b.u8(23) != 0x9D || b.u8(24) != 0x01 || b.u8(25) != 0x2A) return null
                info("image/webp", (b.le16(26) and 0x3FFF).toLong(), (b.le16(28) and 0x3FFF).toLong())
            }
            b.ascii(12, "VP8L") -> {
                if (b.size < 25 || b.u8(20) != 0x2F) return null
                val width = 1 + (b.u8(21) or ((b.u8(22) and 0x3F) shl 8))
                val height = 1 + ((b.u8(22) shr 6) or (b.u8(23) shl 2) or ((b.u8(24) and 0x0F) shl 10))
                info("image/webp", width.toLong(), height.toLong())
            }
            b.ascii(12, "VP8X") -> {
                if (b.size < 30) return null
                info("image/webp", 1L + b.le24(24), 1L + b.le24(27))
            }
            else -> null
        }
    }

    /** Bytes that decode as an image become [Outcome.Ok]; null, empty or unreadable bytes are decode_failed. */
    fun outcomeOf(bytes: ByteArray?): Outcome {
        val info = bytes?.let(::decodeImageInfo) ?: return Outcome.Failed(Failure.DECODE_FAILED)
        return Outcome.Ok(DeliveredImage(bytes, info.mime, info.width, info.height))
    }

    /** Inline kinds are base64-decoded here; URL images go to [fetch] (normally [StudioImageFetcher.fetch]). */
    suspend fun materialize(image: Image, fetch: suspend (String) -> Outcome): Outcome = when (image.kind) {
        Kind.B64 -> outcomeOf(decodeBase64(image.value))
        Kind.DATA_URL -> outcomeOf(
            DATA_URL_BASE64_PREFIX.find(image.value)?.let { decodeBase64(image.value.substring(it.range.last + 1)) },
        )
        Kind.URL -> fetch(image.value)
    }

    private fun decodeBase64(text: String): ByteArray? = try {
        Base64.getDecoder().decode(if (text.any { it.isWhitespace() }) text.filterNot { it.isWhitespace() } else text)
    } catch (e: IllegalArgumentException) {
        null
    }

    /**
     * ok when at least [nRequested] images arrived, partial when some did, the first failure when
     * none did, null when there were no images to deliver at all.
     */
    fun assemble(nRequested: Int, outcomes: List<Outcome>): Assembly {
        val failures = outcomes.mapNotNull { (it as? Outcome.Failed)?.failure }
        val delivered = outcomes.count { it is Outcome.Ok }
        val result = when {
            outcomes.isEmpty() -> null
            delivered == 0 -> Delivery.Failed(failures.first())
            delivered >= nRequested -> Delivery.Ok
            else -> Delivery.Partial
        }
        return Assembly(result, delivered, failures)
    }
}
