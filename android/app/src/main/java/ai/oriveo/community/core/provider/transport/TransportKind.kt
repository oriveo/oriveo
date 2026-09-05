package ai.oriveo.community.core.provider.transport

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * Closed set of wire protocol shapes a model can speak.
 *
 * The `model.transport` field in the catalog decides which [TransportStrategy]
 * parses the stream. Adding a kind here is a deliberate protocol change and ships
 * with a release, so the enum is intentionally closed.
 *
 * Decoding goes through [TransportKindLenientSerializer] so that a kind published
 * by a newer catalog than this build knows about decodes to null instead of
 * blowing up the whole catalog parse. [TransportRegistry] then hides just that
 * model.
 */
@Serializable(with = TransportKindLenientSerializer::class)
enum class TransportKind(val wireValue: String) {
    @SerialName("openai_chat")
    OpenAIChat("openai_chat"),

    @SerialName("openai_responses")
    OpenAIResponses("openai_responses"),

    @SerialName("anthropic_messages")
    AnthropicMessages("anthropic_messages"),

    @SerialName("gemini_generate")
    GeminiGenerate("gemini_generate"),

    @SerialName("dashscope_native")
    DashScopeNative("dashscope_native"),

    @SerialName("openai_images")
    OpenAIImages("openai_images"),

    @SerialName("gemini_image")
    GeminiImage("gemini_image"),

    @SerialName("qwen_image")
    QwenImage("qwen_image"),

    @SerialName("grok_image")
    GrokImage("grok_image"),

    @SerialName("zhipu_image")
    ZhipuImage("zhipu_image"),

    @SerialName("anthropic_files")
    AnthropicFiles("anthropic_files"),

    @SerialName("openai_files")
    OpenAIFiles("openai_files");

    companion object {
        /** Parses a wire value; unknown strings return null. */
        fun fromWireValue(value: String?): TransportKind? {
            val normalized = value?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            return entries.firstOrNull { it.wireValue == normalized }
        }
    }
}

/**
 * Lenient serializer: an unrecognised string (a `future_kind` published by a
 * catalog newer than this build) decodes to null so the caller can fall back,
 * rather than failing the surrounding document.
 */
object TransportKindLenientSerializer : KSerializer<TransportKind?> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("TransportKind", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): TransportKind? {
        val raw = decoder.decodeString()
        return TransportKind.fromWireValue(raw)
    }

    override fun serialize(encoder: Encoder, value: TransportKind?) {
        if (value == null) return
        encoder.encodeString(value.wireValue)
    }
}

/** Thrown when the client meets a transport kind it cannot speak; the model selection layer catches it and filters that model out. */
class UnsupportedTransportException(val rawKind: String) :
    RuntimeException("Unsupported transport kind: $rawKind")
