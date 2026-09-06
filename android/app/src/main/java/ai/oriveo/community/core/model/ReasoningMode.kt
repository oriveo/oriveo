package ai.oriveo.community.core.model

import ai.oriveo.community.R
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class ReasoningMode {
    @SerialName("automatic") Automatic,
    @SerialName("fast") Fast,
    @SerialName("balanced") Balanced,
    @SerialName("deep") Deep,
    @SerialName("max") Max;

    val rawValue: String
        get() = when (this) {
            Automatic -> "automatic"
            Fast -> "fast"
            Balanced -> "balanced"
            Deep -> "deep"
            Max -> "max"
        }

    val titleResId: Int
        get() = when (this) {
            Automatic -> R.string.reasoning_auto
            Fast -> R.string.reasoning_fast
            Balanced -> R.string.reasoning_balanced
            Deep -> R.string.reasoning_deep
            Max -> R.string.reasoning_max
        }

    val intentValue: String?
        get() = when (this) {
            Automatic -> null
            Fast -> "low"
            Balanced -> "balanced"
            Deep -> "deep"
            Max -> "max"
        }

    companion object {

        fun fromIntentOrNull(intent: String?): ReasoningMode? = when (intent) {
            "low" -> Fast
            "balanced" -> Balanced
            "deep" -> Deep
            "max" -> Max
            else -> null
        }

        fun fromIntent(intent: String?): ReasoningMode = fromIntentOrNull(intent) ?: Automatic
    }
}
