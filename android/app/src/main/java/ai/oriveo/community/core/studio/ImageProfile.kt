package ai.oriveo.community.core.studio

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

// Closed enums of image_profile.v2 (shared contract model-contracts/image_profile.v2.json).
// An unknown wire value makes the whole profile unusable; it never falls back to chat.

enum class ImageOperation(val wire: String) {
    GENERATE("generate"),
    EDIT("edit"),
    ;

    companion object {
        fun fromWire(value: String?): ImageOperation? = entries.firstOrNull { it.wire == value }
    }
}

enum class ImageEditTransport(val wire: String) {
    MULTIPART("multipart"),
    JSON_IMAGE("json_image"),
    JSON_IMAGE_URL("json_image_url"),
    JSON_IMAGE_OBJECT("json_image_object"),
    INPUT_REFERENCES("input_references"),
    INLINE("inline"),
    ;

    companion object {
        fun fromWire(value: String?): ImageEditTransport? = entries.firstOrNull { it.wire == value }
    }
}

enum class ImageSizeParam(val wire: String) {
    WXH("wxh"),
    ASPECT_RESOLUTION("aspect_resolution"),
    GEMINI_IMAGE_CONFIG("gemini_image_config"),
    DASHSCOPE_WXH("dashscope_wxh"),
    CHAT_IMAGE_CONFIG("chat_image_config"),
    ASPECT_ONLY("aspect_only"),
    ;

    companion object {
        fun fromWire(value: String?): ImageSizeParam? = entries.firstOrNull { it.wire == value }
    }
}

/** Wire route plus the edit transports and size params it accepts (image_profile.v2 routes table). */
enum class ImageRoute(
    val wire: String,
    val allowedEditTransports: List<ImageEditTransport>,
    val allowedSizeParams: List<ImageSizeParam>,
) {
    OPENAI_IMAGES(
        "openai_images",
        listOf(ImageEditTransport.MULTIPART, ImageEditTransport.JSON_IMAGE, ImageEditTransport.JSON_IMAGE_URL),
        listOf(ImageSizeParam.WXH),
    ),
    XAI_IMAGES("xai_images", listOf(ImageEditTransport.JSON_IMAGE_OBJECT), listOf(ImageSizeParam.ASPECT_RESOLUTION)),
    GEMINI_GENERATE_CONTENT(
        "gemini_generate_content",
        listOf(ImageEditTransport.INLINE),
        listOf(ImageSizeParam.GEMINI_IMAGE_CONFIG),
    ),
    CHAT_MODALITIES("chat_modalities", listOf(ImageEditTransport.INLINE), listOf(ImageSizeParam.CHAT_IMAGE_CONFIG)),
    OPENROUTER_IMAGES("openrouter_images", listOf(ImageEditTransport.INPUT_REFERENCES), listOf(ImageSizeParam.WXH)),
    DASHSCOPE_MULTIMODAL("dashscope_multimodal", listOf(ImageEditTransport.INLINE), listOf(ImageSizeParam.DASHSCOPE_WXH)),
    MINIMAX_IMAGE_GENERATION("minimax_image_generation", emptyList(), listOf(ImageSizeParam.ASPECT_ONLY)),
    ;

    companion object {
        fun fromWire(value: String?): ImageRoute? = entries.firstOrNull { it.wire == value }
    }
}

enum class ImageProfileSource(val wire: String) {
    OFFICIAL_API("official_api"),
    VERIFIED_ALLOWLIST("verified_allowlist"),
    MODELS_DEV("models_dev"),
    OPENROUTER("openrouter"),
    RELAY_PROBE("relay_probe"),
    USER_DECLARED("user_declared"),
    MANAGED_CATALOG("managed_catalog"),
    ;

    companion object {
        fun fromWire(value: String?): ImageProfileSource? = entries.firstOrNull { it.wire == value }
    }
}

/** Closed set of reasons a model has no usable profile (image_profile_resolution.v1 reasons). */
enum class ImageProfileReason(val wire: String) {
    MISSING_REQUIRED_FIELD("missing_required_field"),
    NO_IMAGE_PROFILE("no_image_profile"),
    DANGLING_PROFILE("dangling_profile"),
    MODEL_NOT_IN_CATALOG("model_not_in_catalog"),
    UNKNOWN_ROUTE("unknown_route"),
    UNKNOWN_EDIT_TRANSPORT("unknown_edit_transport"),
    UNKNOWN_SIZE_PARAM("unknown_size_param"),
    UNKNOWN_OPERATION("unknown_operation"),
    SIZE_PARAM_NOT_ALLOWED("size_param_not_allowed"),
    EDIT_TRANSPORT_NOT_ALLOWED("edit_transport_not_allowed"),
    EDIT_TRANSPORT_WITHOUT_EDIT("edit_transport_without_edit"),
    UNKNOWN_SOURCE("unknown_source"),
    NOT_IMAGE_OUTPUT("not_image_output"),
    RELAY_UNMATCHED("relay_unmatched"),
    PROBE_PENDING_CONFIRMATION("probe_pending_confirmation"),
}

data class ImageSizeConstraints(
    val multipleOf: Int? = null,
    val minPixels: Long? = null,
    val maxPixels: Long? = null,
    val maxLongEdge: Int? = null,
    val ratioRange: List<Double>? = null,
)

/**
 * A validated ImageProfile. Only [ImageProfileResolver.validate] builds one, so the enums are
 * known and the route allows the transport / size param. Unknown fields are ignored; an
 * optional field of the wrong JSON type (elements included) reads as absent. Integer fields
 * accept whole numbers written as decimals (2.0 is 2).
 */
data class ImageProfile(
    val imageOutput: Boolean,
    val operations: List<ImageOperation>,
    val route: ImageRoute,
    val editTransport: ImageEditTransport?,
    val maxReferenceImages: Int?,
    val aspectRatios: List<String>,
    val sizeParam: ImageSizeParam,
    val resolutions: Map<String, Int>,
    val resolutionValues: Map<String, String>?,
    val sizeConstraints: ImageSizeConstraints?,
    val qualityMap: Map<String, String>?,
    val params: JsonObject?,
    val maxNPerCall: Int,
    val nParam: Boolean?,
    val nativeMultiTurn: Boolean?,
    val timeoutSeconds: Int,
    val typicalSeconds: List<Double>?,
    val pricing: JsonObject?,
    val maxPromptChars: Int?,
    val source: ImageProfileSource,
    val verifiedAt: String?,
)

/**
 * The metadata slice in wire shape: profiles.image plus providers.<kind>.models and
 * providers.<kind>.imageModels, both keyed by wire model id.
 */
data class ImageProfileSlice(
    val profiles: Map<String, JsonObject>,
    val providers: Map<String, Provider>,
) {
    data class Provider(
        val models: Map<String, ModelEntry> = emptyMap(),
        val imageModels: Map<String, ModelEntry> = emptyMap(),
    )

    data class ModelEntry(
        val imageProfile: String? = null,
        val imageProfileOverride: JsonObject? = null,
    )
}

/**
 * Resolves and validates the ImageProfile of one model (shared contract
 * model-contracts/image_profile_resolution.v1.json) and decides Studio list visibility.
 * Pure functions; no UI entry point.
 */
object ImageProfileResolver {
    const val USER_DECLARED_REF = "user_declared"

    /** image_profile.v2 fields.required, in contract order. */
    val REQUIRED_FIELDS: List<String> = listOf(
        "imageOutput",
        "operations",
        "route",
        "aspectRatios",
        "sizeParam",
        "resolutions",
        "maxNPerCall",
        "timeoutSeconds",
        "source",
    )

    /** Size params whose wire request needs sizeConstraints (image_profile.v2 rules). */
    private val SIZE_CONSTRAINTS_PARAMS = setOf(ImageSizeParam.WXH.wire, ImageSizeParam.DASHSCOPE_WXH.wire)

    /** Size params whose wire request needs resolutionValues (image_profile.v2 rules). */
    private val RESOLUTION_VALUES_PARAMS = setOf(ImageSizeParam.ASPECT_RESOLUTION.wire, ImageSizeParam.GEMINI_IMAGE_CONFIG.wire)

    /** Server alias-table match of a relay model id to an official model. */
    data class OfficialMatch(val providerKind: String, val modelId: String)

    /** Relay connection context; [userDeclared] is the connection-level (declared or probed) profile. */
    data class Relay(
        val officialMatch: OfficialMatch?,
        val probe: String? = null,
        val userDeclared: JsonObject? = null,
    )

    /** Exactly one of [profile] / [reason] is non-null. */
    data class Validation(val profile: ImageProfile?, val reason: ImageProfileReason?)

    /** [appliedOverride] is the imageProfileOverride merged into [profile], null when none applied. */
    data class Resolution(
        val profile: ImageProfile?,
        val profileRef: String?,
        val reason: ImageProfileReason?,
        val appliedOverride: JsonObject?,
    )

    fun validate(raw: JsonObject): Validation {
        check(raw)?.let { return Validation(profile = null, reason = it) }
        // A required value of the wrong JSON type counts as missing (fail closed).
        val profile = decode(raw) ?: return Validation(profile = null, reason = ImageProfileReason.MISSING_REQUIRED_FIELD)
        return Validation(profile = profile, reason = null)
    }

    fun resolve(
        slice: ImageProfileSlice,
        providerKind: String?,
        modelId: String,
        relay: Relay? = null,
    ): Resolution {
        relay?.userDeclared?.let { declared ->
            val validation = validate(declared)
            val profile = validation.profile ?: return failure(validation.reason)
            return Resolution(profile = profile, profileRef = USER_DECLARED_REF, reason = null, appliedOverride = null)
        }
        val targetKind: String?
        val targetId: String
        if (relay == null) {
            targetKind = providerKind
            targetId = modelId
        } else {
            val match = relay.officialMatch ?: return failure(
                if (relay.probe.isNullOrEmpty()) {
                    ImageProfileReason.RELAY_UNMATCHED
                } else {
                    ImageProfileReason.PROBE_PENDING_CONFIRMATION
                },
            )
            targetKind = match.providerKind
            targetId = match.modelId
        }
        val provider = targetKind?.let { slice.providers[it] }
        // models wins on a shared id; imageModels only supplements ids models lacks.
        val entry = provider?.models?.get(targetId) ?: provider?.imageModels?.get(targetId)
            ?: return failure(ImageProfileReason.MODEL_NOT_IN_CATALOG)
        val ref = entry.imageProfile?.takeIf { it.isNotEmpty() } ?: return failure(ImageProfileReason.NO_IMAGE_PROFILE)
        val base = slice.profiles[ref] ?: return failure(ImageProfileReason.DANGLING_PROFILE)
        val override = entry.imageProfileOverride
        val merged = if (override == null) base else JsonObject(base + override)
        val validation = validate(merged)
        val profile = validation.profile ?: return failure(validation.reason)
        return Resolution(profile = profile, profileRef = ref, reason = null, appliedOverride = override)
    }

    /**
     * Whether a model appears in the Studio model list: images = base (0/1) + references; with no
     * image the profile must generate, otherwise it must edit within maxReferenceImages (default 1).
     */
    fun visibleInStudio(
        profile: ImageProfile?,
        connectionUsable: Boolean,
        hasBase: Boolean,
        referenceCount: Int,
    ): Boolean {
        if (profile == null || !profile.imageOutput || !connectionUsable) return false
        val images = (if (hasBase) 1 else 0) + referenceCount
        if (images == 0) return ImageOperation.GENERATE in profile.operations
        if (ImageOperation.EDIT !in profile.operations) return false
        return images <= (profile.maxReferenceImages ?: 1)
    }

    /**
     * Metadata -> slice adapter: builds the wire-shaped slice from raw profiles.image and
     * per-provider entries. A profiles.image that is not an object yields an empty table; a
     * non-object profile entry is dropped, so its ref reads as dangling.
     */
    fun sliceOf(
        profiles: JsonElement?,
        providers: Map<String, ImageProfileSlice.Provider>,
    ): ImageProfileSlice = ImageProfileSlice(
        profiles = (profiles as? JsonObject).orEmpty().mapNotNull { (ref, raw) -> (raw as? JsonObject)?.let { ref to it } }.toMap(),
        providers = providers,
    )

    /**
     * One model entry from its raw fields: a non-string imageProfile reads as absent and an
     * imageProfileOverride that is not an object is ignored.
     */
    fun entryOf(imageProfile: JsonElement?, imageProfileOverride: JsonElement?): ImageProfileSlice.ModelEntry =
        ImageProfileSlice.ModelEntry(
            imageProfile = imageProfile.stringValue(),
            imageProfileOverride = imageProfileOverride as? JsonObject,
        )

    /**
     * One raw models / imageModels entry. JSON null or absent yields null (the id is not listed, so
     * lookup moves on to imageModels); a non-object entry is an entry without imageProfile.
     */
    fun entryOf(raw: JsonElement?): ImageProfileSlice.ModelEntry? = when (raw) {
        null, JsonNull -> null
        is JsonObject -> entryOf(raw["imageProfile"], raw["imageProfileOverride"])
        else -> ImageProfileSlice.ModelEntry()
    }

    /** A raw models / imageModels table keyed by wire id; a non-object table has no entries. */
    fun entriesOf(raw: JsonElement?): Map<String, ImageProfileSlice.ModelEntry> =
        (raw as? JsonObject).orEmpty().mapNotNull { (id, value) -> entryOf(value)?.let { id to it } }.toMap()

    private fun failure(reason: ImageProfileReason?): Resolution = Resolution(
        profile = null,
        profileRef = null,
        reason = reason ?: ImageProfileReason.MISSING_REQUIRED_FIELD,
        appliedOverride = null,
    )

    /** Contract validation order; null means the profile is usable. */
    private fun check(raw: JsonObject): ImageProfileReason? {
        if (REQUIRED_FIELDS.any { raw[it] == null || raw[it] is JsonNull }) return ImageProfileReason.MISSING_REQUIRED_FIELD
        // Required fields without a dedicated reason count as missing when their type (elements
        // included) is wrong, and so do the fields the size param makes required.
        if (raw.stringList("aspectRatios") == null || raw.intMap("resolutions") == null ||
            raw.int("maxNPerCall") == null || raw.int("timeoutSeconds") == null
        ) {
            return ImageProfileReason.MISSING_REQUIRED_FIELD
        }
        val sizeParamWire = raw.string("sizeParam")
        if (sizeParamWire in SIZE_CONSTRAINTS_PARAMS && raw["sizeConstraints"] !is JsonObject) {
            return ImageProfileReason.MISSING_REQUIRED_FIELD
        }
        if (sizeParamWire in RESOLUTION_VALUES_PARAMS && raw["resolutionValues"] !is JsonObject) {
            return ImageProfileReason.MISSING_REQUIRED_FIELD
        }
        if (raw.boolean("imageOutput") != true) return ImageProfileReason.NOT_IMAGE_OUTPUT
        val route = ImageRoute.fromWire(raw.string("route")) ?: return ImageProfileReason.UNKNOWN_ROUTE
        val sizeParam = ImageSizeParam.fromWire(raw.string("sizeParam")) ?: return ImageProfileReason.UNKNOWN_SIZE_PARAM
        val operations = operationsOf(raw) ?: return ImageProfileReason.UNKNOWN_OPERATION
        if (sizeParam !in route.allowedSizeParams) return ImageProfileReason.SIZE_PARAM_NOT_ALLOWED
        if (ImageOperation.EDIT in operations) {
            val transport = ImageEditTransport.fromWire(raw.string("editTransport"))
                ?: return ImageProfileReason.UNKNOWN_EDIT_TRANSPORT
            if (transport !in route.allowedEditTransports) return ImageProfileReason.EDIT_TRANSPORT_NOT_ALLOWED
        } else if (raw["editTransport"].let { it != null && it !is JsonNull }) {
            // JSON null equals an absent key, so a generate-only profile may carry editTransport: null.
            return ImageProfileReason.EDIT_TRANSPORT_WITHOUT_EDIT
        }
        if (ImageProfileSource.fromWire(raw.string("source")) == null) return ImageProfileReason.UNKNOWN_SOURCE
        return null
    }

    private fun decode(raw: JsonObject): ImageProfile? {
        val operations = operationsOf(raw) ?: return null
        val route = ImageRoute.fromWire(raw.string("route")) ?: return null
        val sizeParam = ImageSizeParam.fromWire(raw.string("sizeParam")) ?: return null
        val source = ImageProfileSource.fromWire(raw.string("source")) ?: return null
        val aspectRatios = raw.stringList("aspectRatios") ?: return null
        val resolutions = raw.intMap("resolutions") ?: return null
        val maxNPerCall = raw.int("maxNPerCall") ?: return null
        val timeoutSeconds = raw.int("timeoutSeconds") ?: return null
        return ImageProfile(
            imageOutput = true,
            operations = operations,
            route = route,
            editTransport = ImageEditTransport.fromWire(raw.string("editTransport")),
            maxReferenceImages = raw.int("maxReferenceImages"),
            aspectRatios = aspectRatios,
            sizeParam = sizeParam,
            resolutions = resolutions,
            resolutionValues = raw.nonEmptyStringEntries("resolutionValues"),
            sizeConstraints = (raw["sizeConstraints"] as? JsonObject)?.let {
                ImageSizeConstraints(
                    // Read per sub-field: a value that is not a positive integer reads as absent.
                    multipleOf = it.int("multipleOf")?.takeIf { value -> value > 0 },
                    minPixels = it.long("minPixels")?.takeIf { value -> value > 0 },
                    maxPixels = it.long("maxPixels")?.takeIf { value -> value > 0 },
                    maxLongEdge = it.int("maxLongEdge")?.takeIf { value -> value > 0 },
                    ratioRange = it.doubleList("ratioRange"),
                )
            },
            qualityMap = raw.nonEmptyStringEntries("qualityMap"),
            params = raw["params"] as? JsonObject,
            maxNPerCall = maxNPerCall,
            nParam = raw.boolean("nParam"),
            nativeMultiTurn = raw.boolean("nativeMultiTurn"),
            timeoutSeconds = timeoutSeconds,
            typicalSeconds = raw.doubleList("typicalSeconds"),
            pricing = raw["pricing"] as? JsonObject,
            maxPromptChars = raw.int("maxPromptChars"),
            source = source,
            verifiedAt = raw.string("verifiedAt"),
        )
    }

    /** Non-empty array of known operations, else null. */
    private fun operationsOf(raw: JsonObject): List<ImageOperation>? {
        val array = raw["operations"] as? JsonArray ?: return null
        if (array.isEmpty()) return null
        return array.map { ImageOperation.fromWire(it.stringValue()) ?: return null }
    }

    private fun JsonElement?.stringValue(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonElement?.literal(): JsonPrimitive? =
        (this as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }

    private fun JsonObject.string(key: String): String? = this[key].stringValue()

    private fun JsonObject.boolean(key: String): Boolean? = this[key].literal()?.booleanOrNull

    private fun JsonObject.int(key: String): Int? = this[key].wholeInt()

    private fun JsonObject.long(key: String): Long? = this[key].wholeLong()

    /** A JSON number with no fractional part (2.0 is 2), else null. */
    private fun JsonElement?.wholeLong(): Long? {
        val literal = literal() ?: return null
        literal.content.toLongOrNull()?.let { return it }
        val number = literal.doubleOrNull ?: return null
        if (number.isNaN() || number.isInfinite() || number % 1.0 != 0.0) return null
        if (number < Long.MIN_VALUE.toDouble() || number >= Long.MAX_VALUE.toDouble()) return null
        return number.toLong()
    }

    private fun JsonElement?.wholeInt(): Int? = wholeLong()?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()

    private fun JsonObject.stringList(key: String): List<String>? =
        (this[key] as? JsonArray)?.map { it.stringValue() ?: return null }

    private fun JsonObject.doubleList(key: String): List<Double>? =
        (this[key] as? JsonArray)?.map { it.literal()?.doubleOrNull ?: return null }

    private fun JsonObject.intMap(key: String): Map<String, Int>? =
        (this[key] as? JsonObject)?.mapValues { (_, value) -> value.wholeInt() ?: return null }

    /**
     * A tier table read per entry: an object keeps only its non-empty string entries, so a bad
     * entry disables just its own tier; a non-object reads as absent.
     */
    private fun JsonObject.nonEmptyStringEntries(key: String): Map<String, String>? =
        (this[key] as? JsonObject)?.mapNotNull { (tier, value) ->
            value.stringValue()?.takeIf { it.isNotEmpty() }?.let { tier to it }
        }?.toMap()
}
