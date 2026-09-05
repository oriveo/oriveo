package ai.oriveo.community.core.app

/**
 * Keys for the small settings table.
 *
 * Device-scoped keys describe this installation (theme, language, whether onboarding is done).
 * Account-scoped keys describe the user's own content and travel with a backup file.
 */
object AppPreferenceKeys {
    const val ONBOARDING_COMPLETED = "has_completed_onboarding"
    const val THEME = "theme"
    const val LANGUAGE = "language"
    const val LAST_USED_PROVIDER_ID = "last_used_provider_id"
    const val LAST_USED_MODEL_ID = "last_used_model_id"
    const val MEMORY_TEXT = "memory_text"
    const val MEMORY_ANTI_FORGET_ENABLED = "memory_anti_forget_enabled"
    const val MEMORY_ANTI_FORGET_TEXT = "memory_anti_forget_text"
    const val MEMORY_UPDATED_AT = "memory_updated_at"
    const val MEMORY_USAGE_COUNT = "memory_usage_count"
    const val MEMORY_USAGE_CONVERSATION_IDS = "memory_usage_conversation_ids"
    const val MEMORY_HAS_SEEN = "memory_has_seen"

    /**
     * Provider kinds whose content notice the user has acknowledged, as a comma-separated list of
     * raw values. Acknowledgement is per provider because each one sends the user's text to a
     * different company.
     */
    const val PROVIDER_DISCLOSURE_ACCEPTED_LIST = "provider_disclosure_accepted_list"

    /** Whether the one-time hint about capturing a reply as a note has been shown. */
    const val NOTE_CAPTURE_HINT_SEEN = "note_capture_hint_seen"

    /** Conversation ids pinned to the top of the list, as a JSON array. */
    const val PINNED_CONVERSATION_IDS = "pinned_conversation_ids"
    const val PINNED_CONVERSATION_IDS_UPDATED_AT = "pinned_conversation_ids_updated_at"

    /**
     * One-off marker that provider ids have been rewritten to their deterministic form. Kept so a
     * rename is applied once rather than on every launch.
     */
    const val PROVIDER_DETERMINISTIC_ID_MIGRATION = "provider_deterministic_id_migration"

    val DEVICE_SCOPED_KEYS = setOf(
        ONBOARDING_COMPLETED,
        THEME,
        LANGUAGE,
        PROVIDER_DISCLOSURE_ACCEPTED_LIST,
        NOTE_CAPTURE_HINT_SEEN,
    )

    val USER_STATE_KEYS = setOf(
        LAST_USED_PROVIDER_ID,
        LAST_USED_MODEL_ID,
        MEMORY_TEXT,
        MEMORY_ANTI_FORGET_ENABLED,
        MEMORY_ANTI_FORGET_TEXT,
        MEMORY_UPDATED_AT,
        MEMORY_USAGE_COUNT,
        MEMORY_USAGE_CONVERSATION_IDS,
        MEMORY_HAS_SEEN,
        PROVIDER_DETERMINISTIC_ID_MIGRATION,
        PINNED_CONVERSATION_IDS,
        PINNED_CONVERSATION_IDS_UPDATED_AT,
    )

    fun isDeviceScoped(key: String): Boolean = DEVICE_SCOPED_KEYS.contains(key)

    fun isUserState(key: String): Boolean = USER_STATE_KEYS.contains(key)
}
