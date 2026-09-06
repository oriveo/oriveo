package ai.oriveo.community.core.model

import ai.oriveo.community.R
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

@Serializable(with = ModelCapabilitySerializer::class)
enum class ModelCapability(val raw: String) {
    Reasoning("reasoning"),
    Text("text"),
    Image("image"),
    Video("video"),
    File("file"),
    Web("web"),
    ImageGen("imageGeneration"),

    ToolCall("toolCall"),

    NativePdf("native_pdf"),

    Unknown("__unknown__");

    val titleResId: Int
        get() = when (this) {
            Reasoning -> R.string.capability_reasoning
            Text -> R.string.capability_text
            Image -> R.string.capability_image
            Video -> R.string.capability_video
            File -> R.string.capability_file
            Web -> R.string.capability_web
            ImageGen -> R.string.capability_image_gen
            ToolCall -> R.string.capability_tool_call
            NativePdf -> R.string.capability_file
            Unknown -> R.string.capability_text
        }

    val iconName: String
        get() = when (this) {
            Reasoning -> "psychology"
            Text -> "notes"
            Image -> "image"
            Video -> "videocam"
            File -> "description"
            Web -> "language"
            ImageGen -> "brush"
            ToolCall -> "build"
            NativePdf -> "description"
            Unknown -> "notes"
        }
}

object ModelCapabilitySerializer : KSerializer<ModelCapability> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("ModelCapability", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: ModelCapability) {
        encoder.encodeString(value.raw)
    }

    override fun deserialize(decoder: Decoder): ModelCapability {
        val raw = decoder.decodeString()
        return ModelCapability.entries.firstOrNull { it.raw == raw } ?: ModelCapability.Unknown
    }
}
