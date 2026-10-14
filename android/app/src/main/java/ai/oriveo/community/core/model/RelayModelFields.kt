package ai.oriveo.community.core.model

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * The field surface owned by [AIModel] in Relay 2.0, verbatim identical to `modelFields` in `shared/test-fixtures/relay/portable-config.v1.json`.
 * All of it is device-local: it stays in local storage and the user's own backup files
 * and never enters Firestore (`SyncAdapter.toFirestoreModelList` strips it explicitly).
 * A new field must be declared in the fixture in the same change, otherwise the contract test goes red.
 */
val RELAY_MODEL_FIELDS: Set<String> =
    setOf(
        "relayTransport",
        "relayTransportSource",
        "relayCapabilityOverrides",
        "engineDeclaration",
        "relayKeyID",
        "relayListedByKeyIDs",
        "relayDeniedKeyID",
    )
val PORTABLE_RELAY_MODEL_FIELDS: Set<String> = emptySet()
val LOCAL_ONLY_RELAY_MODEL_FIELDS: Set<String> = RELAY_MODEL_FIELDS - PORTABLE_RELAY_MODEL_FIELDS

/**
 * Who decided the model-level transport: the user picked it / a real send succeeded / the 1-token probe passed.
 * Unknown values (including the deprecated gateway / facts / probed) decode to null and are then dropped together with the transport
 * (see [withConsistentRelayFields]).
 */
@Serializable(with = RelayTransportSourceLenientSerializer::class)
enum class RelayTransportSource(val value: String) {
    User("user"),
    Observed("observed"),
    Reachable("reachable"),
}

/** Any shape other than a string (number, object, array) is treated as absent, so it cannot blow up the decoding of the whole model. */
private fun Decoder.decodeStringOrNull(): String? =
    if (this is JsonDecoder) {
        (decodeJsonElement() as? JsonPrimitive)?.takeIf { it.isString }?.content
    } else {
        decodeString()
    }

object RelayTransportSourceLenientSerializer : KSerializer<RelayTransportSource?> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("RelayTransportSource", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): RelayTransportSource? {
        val raw = decoder.decodeStringOrNull()
        return RelayTransportSource.entries.firstOrNull { it.value == raw }
    }

    @OptIn(ExperimentalSerializationApi::class)
    override fun serialize(encoder: Encoder, value: RelayTransportSource?) {
        if (value == null) encoder.encodeNull() else encoder.encodeString(value.value)
    }
}

/** [AIModel.relayKeyID] / [AIModel.relayDeniedKeyID]: non-strings and empty strings are treated as absent. */
object RelayKeyIDLenientSerializer : KSerializer<String?> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("RelayKeyID", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): String? = decoder.decodeStringOrNull()?.takeIf { it.isNotEmpty() }

    @OptIn(ExperimentalSerializationApi::class)
    override fun serialize(encoder: Encoder, value: String?) {
        if (value == null) encoder.encodeNull() else encoder.encodeString(value)
    }
}

/** [AIModel.relayListedByKeyIDs]: the whole key is dropped when it is not a string array (including any non-string item) or is an empty array. */
object RelayKeyIDListLenientSerializer : KSerializer<List<String>?> {
    override val descriptor: SerialDescriptor =
        SerialDescriptor("ai.oriveo.community.core.model.RelayKeyIDList", JsonArray.serializer().descriptor)

    override fun deserialize(decoder: Decoder): List<String>? {
        val json = decoder as? JsonDecoder
            ?: throw SerializationException("RelayKeyIDList only supports the Json format")
        val items = json.decodeJsonElement() as? JsonArray ?: return null
        val ids = items.map { item ->
            (item as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it.isNotEmpty() } ?: return null
        }
        return ids.distinct().ifEmpty { null }
    }

    @OptIn(ExperimentalSerializationApi::class)
    override fun serialize(encoder: Encoder, value: List<String>?) {
        val json = encoder as? JsonEncoder
            ?: throw SerializationException("RelayKeyIDList only supports the Json format")
        if (value == null) {
            encoder.encodeNull()
        } else {
            json.encodeJsonElement(JsonArray(value.map { JsonPrimitive(it) }))
        }
    }
}

/**
 * Dedicated to [AIModel.relayTransport]: unknown transports and non-string shapes decode to [RelayTransport.Auto],
 * which [withConsistentRelayFields] then uniformly resets to null (`auto` is not a model-level value).
 */
object RelayModelTransportSerializer : KSerializer<RelayTransport> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("RelayModelTransport", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): RelayTransport {
        val raw = decoder.decodeStringOrNull()
        return RelayTransport.entries.firstOrNull { it.value == raw } ?: RelayTransport.Auto
    }

    override fun serialize(encoder: Encoder, value: RelayTransport) {
        encoder.encodeString(value.value)
    }
}

/**
 * Capability overrides of a single model. A null property = no override for that item, keep the value given by the catalog.
 *
 * The wire shape is `{ "<key>": { "value": ..., "source": "user" | "tested" } }`. The source is stored per item in
 * [testedKeys]: a valued item not in it has source `user` -- re-detection only clears reachable and leaves these two sources alone.
 */
@Serializable(with = RelayCapabilityOverridesSerializer::class)
data class RelayCapabilityOverrides(
    val image: Boolean? = null,
    val file: Boolean? = null,
    val imageGeneration: Boolean? = null,
    val toolCall: Boolean? = null,
    /** An empty list is a valid override ("this model has no reasoning tiers"), different from null. */
    val reasoningLevels: List<String>? = null,
    /** Web search: written as tested only by the web-search probe, or set by the user. */
    val web: Boolean? = null,
    /** Keys (from [KEYS]) whose source is `tested`; meaningful only for valued items. */
    val testedKeys: Set<String> = emptySet(),
) {
    val isEmpty: Boolean
        get() = image == null && file == null && imageGeneration == null && toolCall == null &&
            reasoningLevels == null && web == null

    fun sourceOf(key: String): String = if (key in testedKeys) SOURCE_TESTED else SOURCE_USER

    companion object {
        const val SOURCE_USER = "user"
        const val SOURCE_TESTED = "tested"
        val SOURCES: List<String> = listOf(SOURCE_USER, SOURCE_TESTED)
        val KEYS: List<String> = listOf("image", "file", "imageGeneration", "toolCall", "reasoningLevels", "web")
    }
}

/**
 * Per-item tolerance: items whose key is unknown, whose `source` is not `user` / `tested`, or whose `value` has the wrong shape are each dropped; the rest are kept as usual.
 * The value shape depends on the key (boolean / string array) and can only be judged on the JSON tree, so only the Json format is supported --
 * all reads and writes of [AIModel] on this platform (Room JSON column, backup files, Firestore mapping) are Json.
 */
object RelayCapabilityOverridesSerializer : KSerializer<RelayCapabilityOverrides> {
    override val descriptor: SerialDescriptor =
        SerialDescriptor("ai.oriveo.community.core.model.RelayCapabilityOverrides", JsonObject.serializer().descriptor)

    override fun deserialize(decoder: Decoder): RelayCapabilityOverrides {
        val json = decoder as? JsonDecoder
            ?: throw SerializationException("RelayCapabilityOverrides only supports the Json format")
        val entries = json.decodeJsonElement() as? JsonObject ?: return RelayCapabilityOverrides()
        fun sourceOf(key: String): String? {
            val entry = entries[key] as? JsonObject ?: return null
            return (entry["source"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                ?.takeIf { it in RelayCapabilityOverrides.SOURCES }
        }
        fun knownValue(key: String): JsonElement? =
            (entries[key] as? JsonObject)?.get("value")?.takeIf { sourceOf(key) != null }
        fun flag(key: String): Boolean? =
            (knownValue(key) as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
        fun strings(key: String): List<String>? {
            val items = knownValue(key) as? JsonArray ?: return null
            return items.map { item -> (item as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null }
        }
        val decoded = RelayCapabilityOverrides(
            image = flag("image"),
            file = flag("file"),
            imageGeneration = flag("imageGeneration"),
            toolCall = flag("toolCall"),
            reasoningLevels = strings("reasoningLevels"),
            web = flag("web"),
        )
        val present = mapOf(
            "image" to decoded.image,
            "file" to decoded.file,
            "imageGeneration" to decoded.imageGeneration,
            "toolCall" to decoded.toolCall,
            "reasoningLevels" to decoded.reasoningLevels,
            "web" to decoded.web,
        ).filterValues { it != null }.keys
        return decoded.copy(
            testedKeys = present.filterTo(linkedSetOf()) { sourceOf(it) == RelayCapabilityOverrides.SOURCE_TESTED },
        )
    }

    override fun serialize(encoder: Encoder, value: RelayCapabilityOverrides) {
        val json = encoder as? JsonEncoder
            ?: throw SerializationException("RelayCapabilityOverrides only supports the Json format")
        json.encodeJsonElement(
            buildJsonObject {
                fun flag(key: String, flag: Boolean?) {
                    if (flag == null) return
                    putJsonObject(key) {
                        put("value", flag)
                        put("source", value.sourceOf(key))
                    }
                }
                flag("image", value.image)
                flag("file", value.file)
                flag("imageGeneration", value.imageGeneration)
                flag("toolCall", value.toolCall)
                value.reasoningLevels?.let { levels ->
                    putJsonObject("reasoningLevels") {
                        putJsonArray("value") { levels.forEach { add(JsonPrimitive(it)) } }
                        put("source", value.sourceOf("reasoningLevels"))
                    }
                }
                flag("web", value.web)
            },
        )
    }
}

/**
 * Capability declarations of the local engine for a single model, written only by the local engine connector.
 * A null property = the engine made no declaration (unknown); the wire shape is `{ "image": true, ... }`, a missing key means unknown.
 */
@Serializable(with = EngineDeclarationSerializer::class)
data class EngineDeclaration(
    val image: Boolean? = null,
    val toolCall: Boolean? = null,
    val thinking: Boolean? = null,
) {
    val isEmpty: Boolean get() = image == null && toolCall == null && thinking == null

    companion object {
        val KEYS: List<String> = listOf("image", "toolCall", "thinking")
    }
}

/** Per-key tolerance: unknown keys and non-boolean values are each dropped, so one bad key cannot blow up the decoding of the whole model. */
object EngineDeclarationSerializer : KSerializer<EngineDeclaration> {
    override val descriptor: SerialDescriptor =
        SerialDescriptor("ai.oriveo.community.core.model.EngineDeclaration", JsonObject.serializer().descriptor)

    override fun deserialize(decoder: Decoder): EngineDeclaration {
        val json = decoder as? JsonDecoder
            ?: throw SerializationException("EngineDeclaration only supports the Json format")
        val entries = json.decodeJsonElement() as? JsonObject ?: return EngineDeclaration()
        fun flag(key: String): Boolean? = (entries[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
        return EngineDeclaration(image = flag("image"), toolCall = flag("toolCall"), thinking = flag("thinking"))
    }

    override fun serialize(encoder: Encoder, value: EngineDeclaration) {
        val json = encoder as? JsonEncoder
            ?: throw SerializationException("EngineDeclaration only supports the Json format")
        json.encodeJsonElement(
            buildJsonObject {
                value.image?.let { put("image", it) }
                value.toolCall?.let { put("toolCall", it) }
                value.thinking?.let { put("thinking", it) }
            },
        )
    }
}

/**
 * Cross-field normalization of Relay 2.0 model-level fields: transport `auto` -> no transport; no transport -> no source;
 * a transport without a recognizable source -> drop both (a transport of unknown origin cannot be taken at face value); override table / engine declarations with no item left -> omit the whole key.
 * Returns the input as is when already consistent, without allocating a new object.
 */
internal fun AIModel.withConsistentRelayFields(): AIModel {
    val paired = relayTransport != null && relayTransport != RelayTransport.Auto && relayTransportSource != null
    val transport = relayTransport.takeIf { paired }
    val source = relayTransportSource.takeIf { paired }
    val overrides = relayCapabilityOverrides?.takeUnless { it.isEmpty }
    val declaration = engineDeclaration?.takeUnless { it.isEmpty }
    if (transport == relayTransport && source == relayTransportSource && overrides == relayCapabilityOverrides &&
        declaration == engineDeclaration
    ) {
        return this
    }
    return copy(
        relayTransport = transport,
        relayTransportSource = source,
        relayCapabilityOverrides = overrides,
        engineDeclaration = declaration,
    )
}

/**
 * The public serializer of [AIModel]: reads and writes delegate to the one generated by the plugin, with
 * [withConsistentRelayFields] applied before and after. It does not transform the JSON tree, so decoding thousands of models in the catalog costs no extra allocation.
 */
@OptIn(ExperimentalSerializationApi::class)
object AIModelSerializer : KSerializer<AIModel> {
    private val generated = AIModel.generatedSerializer()

    override val descriptor: SerialDescriptor get() = generated.descriptor

    override fun deserialize(decoder: Decoder): AIModel =
        generated.deserialize(decoder).withConsistentRelayFields()

    override fun serialize(encoder: Encoder, value: AIModel) {
        generated.serialize(encoder, value.withConsistentRelayFields())
    }
}
