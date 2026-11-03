package ai.oriveo.community.core.studio

import kotlinx.serialization.json.JsonPrimitive
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Raw Studio request values. null and empty string mean unset; n = 0 also means unset.
 */
data class ImageParamRequest(
    val aspect: String? = null,
    val resolution: String? = null,
    val quality: String? = null,
    val n: Int? = null,
)

/** Closed error set of image_param_normalization.v1. */
enum class ImageParamError(val wire: String) {
    INVALID_REQUEST("invalid_request"),
    INVALID_PROFILE("invalid_profile"),
}

/** One replaced user choice, shown in the notice bar. */
data class ImageParamAdjustment(val field: Field, val from: Value?, val to: Value?) {
    enum class Field(val wire: String) {
        ASPECT("aspect"),
        RESOLUTION("resolution"),
        SIZE("size"),
        QUALITY("quality"),
        N("n"),
    }

    sealed interface Value {
        data class Text(val text: String) : Value
        data class Count(val count: Int) : Value
        data class Counts(val counts: List<Int>) : Value
    }
}

/** Normalized parameters; [wire] holds dotted body keys with string or integer values. */
data class NormalizedImageParams(
    val aspect: String,
    val resolution: String,
    val quality: String?,
    val wire: Map<String, JsonPrimitive>,
    val batches: List<Int>,
    val adjustments: List<ImageParamAdjustment>,
)

/**
 * Pure normalization of a Studio request against a validated profile (shared contract
 * model-contracts/image_param_normalization.v1.json). Profile checks run before request checks.
 */
object ImageParamNormalizer {
    const val DEFAULT_ASPECT = "1:1"

    /** Closed request tiers, lowest first. */
    val RESOLUTION_TIERS: List<String> = listOf("1K", "2K", "4K")
    val QUALITY_TIERS: List<String> = listOf("draft", "standard", "fine")

    private const val DEFAULT_RESOLUTION = "1K"
    private const val DEFAULT_QUALITY = "standard"

    /** Two |ln ratio| distances closer than this are a tie; the earlier list entry wins. */
    private const val TIE_TOLERANCE = 1e-12

    /** W:H with each side 1..9999 and no leading zero; requests and profile entries alike. */
    private val ASPECT_PATTERN = Regex("^([1-9][0-9]{0,3}):([1-9][0-9]{0,3})$")

    /** Size params whose tiers also need a non-empty resolutionValues entry. */
    private val RESOLUTION_VALUE_PARAMS = setOf(ImageSizeParam.ASPECT_RESOLUTION, ImageSizeParam.GEMINI_IMAGE_CONFIG)

    /** Exactly one of [params] / [error] is non-null. */
    data class Outcome(val params: NormalizedImageParams?, val error: ImageParamError?)

    private data class Ratio(val width: Long, val height: Long) {
        val logValue: Double get() = ln(width.toDouble() / height.toDouble())
    }

    fun normalize(profile: ImageProfile, request: ImageParamRequest, defaultAspect: String = DEFAULT_ASPECT): Outcome {
        // Profile first: a bad profile is rejected whatever the request holds.
        val ratios = profile.aspectRatios.map { parseAspect(it) ?: return failure(ImageParamError.INVALID_PROFILE) }
        if (ratios.isEmpty() || profile.maxNPerCall < 1) return failure(ImageParamError.INVALID_PROFILE)
        val tiers = availableTiers(profile)
        if (tiers.isEmpty()) return failure(ImageParamError.INVALID_PROFILE)

        // Then the request: a set value outside the closed set is a caller bug.
        val aspectInput = request.aspect.setOrNull()
        val requestedRatio = aspectInput?.let { parseAspect(it) ?: return failure(ImageParamError.INVALID_REQUEST) }
        val resolutionInput = request.resolution.setOrNull()
        if (resolutionInput != null && resolutionInput !in RESOLUTION_TIERS) return failure(ImageParamError.INVALID_REQUEST)
        val qualityInput = request.quality.setOrNull()
        if (qualityInput != null && qualityInput !in QUALITY_TIERS) return failure(ImageParamError.INVALID_REQUEST)
        val nInput = request.n?.takeIf { it != 0 }
        if (nInput != null && nInput < 0) return failure(ImageParamError.INVALID_REQUEST)

        val adjustments = mutableListOf<ImageParamAdjustment>()
        val wire = linkedMapOf<String, JsonPrimitive>()

        // A malformed defaultAspect is a configuration fault, reported like a bad profile.
        val wantedRatio = requestedRatio ?: parseAspect(defaultAspect) ?: return failure(ImageParamError.INVALID_PROFILE)
        val aspectIndex = pickAspect(
            wanted = aspectInput ?: defaultAspect,
            wantedRatio = wantedRatio,
            entries = profile.aspectRatios,
            ratios = ratios,
        )
        val aspect = profile.aspectRatios[aspectIndex]
        val ratio = ratios[aspectIndex]
        if (aspectInput != null && aspect != aspectInput) {
            adjustments += adjustment(ImageParamAdjustment.Field.ASPECT, text(aspectInput), text(aspect))
        }

        val resolution = pickTier(resolutionInput ?: DEFAULT_RESOLUTION, tiers)
        if (resolutionInput != null && resolution != resolutionInput) {
            adjustments += adjustment(ImageParamAdjustment.Field.RESOLUTION, text(resolutionInput), text(resolution))
        }

        val resolutionValue = profile.resolutionValues?.get(resolution)
        when (profile.sizeParam) {
            ImageSizeParam.WXH, ImageSizeParam.DASHSCOPE_WXH -> {
                val (rounded, clamped) = pixelSize(profile, resolution, ratio)
                if (rounded != clamped) {
                    adjustments += adjustment(
                        ImageParamAdjustment.Field.SIZE,
                        text("${rounded.first}x${rounded.second}"),
                        text("${clamped.first}x${clamped.second}"),
                    )
                }
                if (profile.sizeParam == ImageSizeParam.WXH) {
                    wire["size"] = JsonPrimitive("${clamped.first}x${clamped.second}")
                } else {
                    wire["parameters.size"] = JsonPrimitive("${clamped.first}*${clamped.second}")
                }
            }
            ImageSizeParam.ASPECT_RESOLUTION -> {
                wire["aspect_ratio"] = JsonPrimitive(aspect)
                wire["resolution"] = JsonPrimitive(resolutionValue)
            }
            ImageSizeParam.GEMINI_IMAGE_CONFIG -> {
                wire["generationConfig.imageConfig.aspectRatio"] = JsonPrimitive(aspect)
                wire["generationConfig.imageConfig.imageSize"] = JsonPrimitive(resolutionValue)
            }
            ImageSizeParam.CHAT_IMAGE_CONFIG -> wire["image_config.aspect_ratio"] = JsonPrimitive(aspect)
            ImageSizeParam.ASPECT_ONLY -> wire["aspect_ratio"] = JsonPrimitive(aspect)
        }

        var quality: String? = null
        val qualityKey = qualityKey(profile.route)
        val qualityMap = profile.qualityMap
        if (qualityMap != null && qualityKey != null) {
            val wanted = qualityInput ?: DEFAULT_QUALITY
            val value = qualityMap[wanted]
            if (value != null) {
                quality = wanted
                wire[qualityKey] = JsonPrimitive(value)
            } else if (qualityInput != null) {
                adjustments += adjustment(ImageParamAdjustment.Field.QUALITY, text(qualityInput), null)
            }
        }

        val n = nInput ?: 1
        val nKey = nKey(profile.route)
        val sendsN = nKey != null && profile.nParam != false
        val batches = if (sendsN) splitBatches(n, profile.maxNPerCall) else List(n) { 1 }
        if (sendsN && nKey != null) wire[nKey] = JsonPrimitive(batches.first())
        if (batches.size > 1) {
            adjustments += adjustment(
                ImageParamAdjustment.Field.N,
                ImageParamAdjustment.Value.Count(n),
                ImageParamAdjustment.Value.Counts(batches),
            )
        }

        return Outcome(
            params = NormalizedImageParams(
                aspect = aspect,
                resolution = resolution,
                quality = quality,
                wire = wire,
                batches = batches,
                adjustments = adjustments,
            ),
            error = null,
        )
    }

    private fun failure(error: ImageParamError): Outcome = Outcome(params = null, error = error)

    private fun String?.setOrNull(): String? = this?.takeIf { it.isNotEmpty() }

    private fun text(value: String): ImageParamAdjustment.Value = ImageParamAdjustment.Value.Text(value)

    private fun adjustment(
        field: ImageParamAdjustment.Field,
        from: ImageParamAdjustment.Value?,
        to: ImageParamAdjustment.Value?,
    ): ImageParamAdjustment = ImageParamAdjustment(field = field, from = from, to = to)

    /** W:H matching [ASPECT_PATTERN], else null. */
    private fun parseAspect(value: String): Ratio? {
        val match = ASPECT_PATTERN.matchEntire(value) ?: return null
        return Ratio(match.groupValues[1].toLong(), match.groupValues[2].toLong())
    }

    /** Index of the wanted entry, else the nearest by |ln ratio| (ties keep the earlier entry). */
    private fun pickAspect(wanted: String, wantedRatio: Ratio, entries: List<String>, ratios: List<Ratio>): Int {
        entries.indexOf(wanted).takeIf { it >= 0 }?.let { return it }
        val target = wantedRatio.logValue
        var best = 0
        var bestDistance = abs(ratios[0].logValue - target)
        for (index in 1 until ratios.size) {
            val distance = abs(ratios[index].logValue - target)
            if (distance < bestDistance - TIE_TOLERANCE) {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    /** 1K / 2K / 4K tiers with a positive resolutions entry (and a resolutionValues entry when needed). */
    private fun availableTiers(profile: ImageProfile): List<String> = RESOLUTION_TIERS.filter { tier ->
        (profile.resolutions[tier] ?: 0) > 0 &&
            (profile.sizeParam !in RESOLUTION_VALUE_PARAMS || !profile.resolutionValues?.get(tier).isNullOrEmpty())
    }

    /** The wanted tier, else the highest available not above it, else the lowest available. */
    private fun pickTier(wanted: String, tiers: List<String>): String {
        if (wanted in tiers) return wanted
        val rank = RESOLUTION_TIERS.indexOf(wanted)
        return tiers.lastOrNull { RESOLUTION_TIERS.indexOf(it) <= rank } ?: tiers.first()
    }

    /**
     * Rounded and clamped pixel size: long edge = resolutions[tier], short edge from the ratio,
     * each rounded to the nearest multipleOf; then maxLongEdge (integer math), maxPixels (floor)
     * and minPixels (ceil). After rounding, maxLongEdge and maxPixels each edge stays at least one
     * multipleOf, so no edge reaches 0 and the minPixels scale never divides by zero.
     */
    private fun pixelSize(profile: ImageProfile, tier: String, ratio: Ratio): Pair<Pair<Long, Long>, Pair<Long, Long>> {
        val constraints = profile.sizeConstraints
        val multiple = (constraints?.multipleOf ?: 1).toLong()
        fun atLeastOne(edge: Long): Long = max(multiple, edge)
        fun nearest(edge: Double): Long = atLeastOne(floor(edge / multiple + 0.5).toLong() * multiple)
        val longEdge = profile.resolutions.getValue(tier).toDouble()
        var width: Long
        var height: Long
        if (ratio.width >= ratio.height) {
            width = nearest(longEdge)
            height = nearest(longEdge * ratio.height / ratio.width)
        } else {
            height = nearest(longEdge)
            width = nearest(longEdge * ratio.width / ratio.height)
        }
        val rounded = width to height
        constraints?.maxLongEdge?.toLong()?.let { cap ->
            val current = max(width, height)
            if (current > cap) {
                width = atLeastOne(width * cap / current / multiple * multiple)
                height = atLeastOne(height * cap / current / multiple * multiple)
            }
        }
        constraints?.maxPixels?.let { cap ->
            if (width * height > cap) {
                val scale = sqrt(cap.toDouble() / (width * height).toDouble())
                width = atLeastOne(floor(width * scale / multiple).toLong() * multiple)
                height = atLeastOne(floor(height * scale / multiple).toLong() * multiple)
            }
        }
        constraints?.minPixels?.let { floorPixels ->
            if (width * height < floorPixels) {
                val scale = sqrt(floorPixels.toDouble() / (width * height).toDouble())
                width = ceil(width * scale / multiple).toLong() * multiple
                height = ceil(height * scale / multiple).toLong() * multiple
            }
        }
        return rounded to (width to height)
    }

    /** Batches of at most [perCall]; a countdown, so a perCall near Int.MAX_VALUE cannot overflow. */
    private fun splitBatches(n: Int, perCall: Int): List<Int> {
        val batches = mutableListOf<Int>()
        var left = n
        while (left > 0) {
            val batch = minOf(left, perCall)
            batches += batch
            left -= batch
        }
        return batches
    }

    /** Body key of the quality tier; only these routes take one. */
    private fun qualityKey(route: ImageRoute): String? = when (route) {
        ImageRoute.OPENAI_IMAGES, ImageRoute.OPENROUTER_IMAGES -> "quality"
        else -> null
    }

    /** Body key of n; gemini_generate_content and chat_modalities have none. */
    private fun nKey(route: ImageRoute): String? = when (route) {
        ImageRoute.DASHSCOPE_MULTIMODAL -> "parameters.n"
        ImageRoute.GEMINI_GENERATE_CONTENT, ImageRoute.CHAT_MODALITIES -> null
        ImageRoute.OPENAI_IMAGES, ImageRoute.XAI_IMAGES, ImageRoute.OPENROUTER_IMAGES,
        ImageRoute.MINIMAX_IMAGE_GENERATION,
        -> "n"
    }
}
