package ai.oriveo.community.core.studio

/**
 * BYOK reference image budget: encoded-size limits per route and the backwards shrink walk that keeps a
 * request under them. Pure planning; the platform shrinker is passed in.
 */
object StudioReferenceBudget {
    /** Fixed allowance for the non-image part of a request body (JSON / multipart framing). */
    const val OVERHEAD_BYTES: Long = 65_536
    const val SHRINK_MAX_LONG_EDGE: Int = 2048
    const val SHRINK_JPEG_QUALITY: Double = 0.9
    const val SHRINK_MIME: String = "image/jpeg"
    const val TOO_LARGE_ERROR_KIND: String = "invalid_param"

    private const val ROLE_BASE = "base"
    private const val TRANSPORT_MULTIPART = "multipart"
    private const val ROUTE_GEMINI = "gemini_generate_content"

    /** One reference image as the budget sees it. */
    data class Item(val slot: Int, val role: String, val mime: String, val byteCount: Long)

    /** Encoded-size limits of a route; null = no limit of that kind. */
    data class Limits(val maxRequestBytes: Long?, val maxImageBytes: Long?)

    enum class Status(val wire: String) { FITS("fits"), TOO_LARGE("too_large") }

    /** Outcome of [fit]; [images] are in send order. */
    data class FitResult<T>(val status: Status, val errorKind: String?, val requestBytes: Long, val images: List<T>)

    /** Route -> limits; a null value means the route cannot edit, so there is nothing to shrink. */
    val routeLimits: Map<String, Limits?> = linkedMapOf(
        "openai_images" to Limits(maxRequestBytes = 50_000_000, maxImageBytes = 20_971_520),
        "xai_images" to Limits(maxRequestBytes = 50_000_000, maxImageBytes = 20_971_520),
        "openrouter_images" to Limits(maxRequestBytes = 50_000_000, maxImageBytes = null),
        "chat_modalities" to Limits(maxRequestBytes = 50_000_000, maxImageBytes = null),
        "gemini_generate_content" to Limits(maxRequestBytes = 20_000_000, maxImageBytes = null),
        "dashscope_multimodal" to Limits(maxRequestBytes = 16_777_216, maxImageBytes = 10_000_000),
        "minimax_image_generation" to null,
    )

    /**
     * Bytes one image adds to the request body: multipart sends raw bytes, Gemini inline_data bare base64,
     * every other route a data URI.
     */
    fun encodedBytes(route: String, editTransport: String?, mime: String, byteCount: Long): Long {
        if (editTransport == TRANSPORT_MULTIPART) return byteCount
        val base64 = 4 * ((byteCount + 2) / 3)
        if (route == ROUTE_GEMINI) return base64
        return "data:$mime;base64,".length + base64
    }

    /**
     * Orders [images] for sending (base first, then ascending slot) and walks that order backwards, handing
     * images to [shrink] until the request fits; a shrink result is taken only when its encoded size is
     * strictly smaller. Routes without limits fit as-is and never call [shrink].
     */
    suspend fun <T> fit(
        route: String,
        editTransport: String?,
        prompt: String,
        images: List<T>,
        describe: (T) -> Item,
        shrink: suspend (T) -> T?,
    ): FitResult<T> {
        val limits = routeLimits[route]
        val promptBytes = prompt.toByteArray(Charsets.UTF_8).size.toLong()
        val current = images.sortedWith(
            compareBy<T>({ describe(it).role != ROLE_BASE }, { describe(it).slot }),
        ).toMutableList()

        fun encoded(image: T): Long = describe(image).let { encodedBytes(route, editTransport, it.mime, it.byteCount) }
        fun total(): Long = OVERHEAD_BYTES + promptBytes + current.sumOf { encoded(it) }
        fun requestOk(): Boolean = limits?.maxRequestBytes?.let { total() <= it } ?: true
        fun imageOver(image: T): Boolean = limits?.maxImageBytes?.let { encoded(image) > it } ?: false
        fun fits(): Boolean = limits == null || (requestOk() && current.none { imageOver(it) })

        for (index in current.indices.reversed()) {
            if (fits()) break
            if (requestOk() && !imageOver(current[index])) continue
            val shrunk = shrink(current[index]) ?: continue
            if (encoded(shrunk) < encoded(current[index])) current[index] = shrunk
        }

        val ok = fits()
        return FitResult(
            status = if (ok) Status.FITS else Status.TOO_LARGE,
            errorKind = if (ok) null else TOO_LARGE_ERROR_KIND,
            requestBytes = total(),
            images = current.toList(),
        )
    }
}
