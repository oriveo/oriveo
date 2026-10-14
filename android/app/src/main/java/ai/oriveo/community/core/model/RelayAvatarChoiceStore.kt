package ai.oriveo.community.core.model

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * On-device relay avatar choices (`relay-avatar-icon.v1.json`): key = the connection id after [RelayAvatarResolver.choiceKey],
 * value = an icon id or [LETTER]; the brand cell = remove the saved choice. Stored only in on-device SharedPreferences, never in Room, cloud sync or backups.
 * [choices] is the observable full map: avatar Composables subscribe to it, so a choice redraws every visible place immediately.
 *
 * Starts up the same way as [ai.oriveo.community.core.provider.ModelControlRejectionCache]: [configure] only captures the context,
 * and the first SharedPreferences load happens in [prewarm] (in the background); an empty map before it is ready = draw the default icon, refreshed automatically once ready.
 */
object RelayAvatarChoiceStore {
    /** The value written by the "Letter" cell. */
    const val LETTER = "letter"
    private const val PREFS = "relay_avatar_choice"

    private val state = MutableStateFlow<Map<String, String>>(emptyMap())
    val choices: StateFlow<Map<String, String>> = state.asStateFlow()

    @Volatile private var write: ((String, String?) -> Unit)? = null
    @Volatile private var pendingHydration: (() -> Unit)? = null

    @Synchronized
    fun configure(context: Context) {
        val appContext = context.applicationContext
        pendingHydration = {
            val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val stored = prefs.all.mapNotNull { (key, value) -> (value as? String)?.let { key to it } }.toMap()
            attach(stored) { key, value ->
                prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
            }
        }
    }

    /** Runs the load deferred by [configure]; call it in the background, idempotent. */
    @Synchronized
    fun prewarm() {
        val pending = pendingHydration ?: return
        pendingHydration = null
        pending()
    }

    fun choice(providerId: String): String? = state.value[RelayAvatarResolver.choiceKey(providerId)]

    /** Writes the [RelayAvatarPickerCell.choice] of a cell; null (the brand cell) = remove the saved choice. */
    @Synchronized
    fun select(providerId: String, choice: String?) {
        val key = RelayAvatarResolver.choiceKey(providerId)
        if (key.isEmpty()) return
        state.update { current -> if (choice == null) current - key else current + (key to choice) }
        write?.invoke(key, choice)
    }

    /** Clears the choice of a connection when it is deleted. */
    fun remove(providerId: String) = select(providerId, null)

    @Synchronized
    internal fun configurePersistenceForTesting(stored: Map<String, String>, write: (String, String?) -> Unit) {
        pendingHydration = null
        state.value = emptyMap()
        attach(stored, write)
    }

    @Synchronized
    internal fun resetForTesting() {
        pendingHydration = null
        write = null
        state.value = emptyMap()
    }

    /** Choices written to memory before the store was ready are kept (on top of the loaded map) and then persisted in one go. */
    private fun attach(stored: Map<String, String>, persist: (String, String?) -> Unit) {
        val early = state.value
        write = persist
        state.value = stored + early
        early.forEach { (key, value) -> persist(key, value) }
    }
}
