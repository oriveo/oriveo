package ai.oriveo.community.core.notice

import android.content.SharedPreferences
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Price lines already confirmed in this conversation: only the same runtime model id and the same T count as confirmed. */
@Serializable
data class ContextPriceLineAcknowledgement(
    val model: String,
    @SerialName("T") val T: Int,
)

/** Local state of the price-line confirmation; defaults to {false, null}. */
@Serializable
data class ContextPriceLineConfirmState(
    val suppressed: Boolean = false,
    val acknowledged: ContextPriceLineAcknowledgement? = null,
) {
    companion object {
        val DEFAULT = ContextPriceLineConfirmState()
    }
}

/**
 * Local state of the pre-send price-line confirmation: key `context_price_line_confirm:<conversation id>`, value JSON {suppressed, acknowledged}, local only.
 * The same lazy SharedPreferences as [DirectiveSuggestionStore]: the first access reads the XML synchronously, so callers must read and write on an IO thread.
 */
class ContextPriceLineConfirmStore(
    prefsProvider: () -> SharedPreferences,
) {
    private val prefs: SharedPreferences by lazy(LazyThreadSafetyMode.PUBLICATION) {
        prefsProvider()
    }

    /** Anything unreadable or undecodable falls back to the default {false, null}. */
    fun state(conversationId: String): ContextPriceLineConfirmState {
        val raw = prefs.getString(key(conversationId), null) ?: return ContextPriceLineConfirmState.DEFAULT
        return runCatching { json.decodeFromString<ContextPriceLineConfirmState>(raw) }
            .getOrDefault(ContextPriceLineConfirmState.DEFAULT)
    }

    fun save(conversationId: String, state: ContextPriceLineConfirmState) {
        if (state == ContextPriceLineConfirmState.DEFAULT) {
            prefs.edit().remove(key(conversationId)).apply()
        } else {
            prefs.edit().putString(key(conversationId), json.encodeToString(state)).apply()
        }
    }

    private fun key(conversationId: String) = "$KEY_PREFIX$conversationId"

    companion object {
        const val PREFS_NAME = "oriveo_context_price_line_confirm"
        private const val KEY_PREFIX = "context_price_line_confirm:"
        private val json = Json { ignoreUnknownKeys = true }
    }
}
