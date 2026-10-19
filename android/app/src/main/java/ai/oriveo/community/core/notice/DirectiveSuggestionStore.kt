package ai.oriveo.community.core.notice

import android.content.SharedPreferences

/**
 * Local ignore counter of the "set as instructions" suggestion strip: key `directive_suggestion_ignores:<conversation id>`, local only.
 * The same lazy SharedPreferences as [NoticesSeenStore]: the first access reads the XML synchronously, so callers must read and write on an IO thread.
 */
class DirectiveSuggestionStore(
    prefsProvider: () -> SharedPreferences,
) {
    private val prefs: SharedPreferences by lazy(LazyThreadSafetyMode.PUBLICATION) {
        prefsProvider()
    }

    fun ignoreCount(conversationId: String): Int = prefs.getInt(key(conversationId), 0)

    fun recordIgnore(conversationId: String) {
        prefs.edit().putInt(key(conversationId), ignoreCount(conversationId) + 1).apply()
    }

    fun resetIgnores(conversationId: String) {
        prefs.edit().remove(key(conversationId)).apply()
    }

    private fun key(conversationId: String) = "$KEY_PREFIX$conversationId"

    companion object {
        const val PREFS_NAME = "oriveo_directive_suggestions"
        private const val KEY_PREFIX = "directive_suggestion_ignores:"
    }
}
