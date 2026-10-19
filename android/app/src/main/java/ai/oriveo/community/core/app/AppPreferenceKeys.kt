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
    // sha256 of memoryText, written alongside it so an edit that changes memoryText without the digest can be recognised.
    const val MEMORY_TEXT_DIGEST = "memory_text_digest"
    // Local marker that the old preference text has been migrated into memory items; never leaves the device.
    const val MEMORY_ITEMS_MIGRATED = "memory_items_migrated"
    const val MEMORY_ANTI_FORGET_ENABLED = "memory_anti_forget_enabled"
    const val MEMORY_ANTI_FORGET_TEXT = "memory_anti_forget_text"
    const val CONTEXT_AI_SUMMARY_ENABLED = "context_ai_summary_enabled"
    // Default global input budget cap (stored text of ContextBudgetCap) and the over-the-line reminder switch; local only.
    const val CONTEXT_DEFAULT_CAP = "context_default_cap"
    const val CONTEXT_PRICE_LINE_REMINDER_ENABLED = "context_price_line_reminder_enabled"
    const val MEMORY_UPDATED_AT = "memory_updated_at"
    // Legacy keys: the memory usage count was removed and is no longer read or written; the key names stay only so clearing user state still wipes old values.
    const val MEMORY_USAGE_COUNT = "memory_usage_count"
    const val MEMORY_USAGE_CONVERSATION_IDS = "memory_usage_conversation_ids"
    const val MEMORY_HAS_SEEN = "memory_has_seen"

    /** Switch for automatic memory suggestions: a local preference, on by default. */
    const val MEMORY_AUTO_SUGGEST_ENABLED = "memory_auto_suggest_enabled"

    /**
     * Provider kinds whose content notice the user has acknowledged, as a comma-separated list of
     * raw values. Acknowledgement is per provider because each one sends the user's text to a
     * different company.
     */
    const val PROVIDER_DISCLOSURE_ACCEPTED_LIST = "provider_disclosure_accepted_list"

    /** Whether the one-time hint about capturing a reply as a note has been shown. */
    const val NOTE_CAPTURE_HINT_SEEN = "note_capture_hint_seen"

    /** Ids of new-feature badges the user has already seen, comma separated. Device-local. */
    const val FEATURE_BADGES_SEEN = "feature_badges_seen"

    /** Conversation ids pinned to the top of the list, as a JSON array. */
    const val PINNED_CONVERSATION_IDS = "pinned_conversation_ids"
    const val PINNED_CONVERSATION_IDS_UPDATED_AT = "pinned_conversation_ids_updated_at"

    /**
     * One-off marker that provider ids have been rewritten to their deterministic form. Kept so a
     * rename is applied once rather than on every launch.
     */
    const val PROVIDER_DETERMINISTIC_ID_MIGRATION = "provider_deterministic_id_migration"

    /** Marker that existing llama.cpp connections were moved to the chat channel; set once so a native channel chosen later is left alone. */
    const val LLAMACPP_CHAT_CHANNEL_MIGRATION = "llamacpp_chat_channel_migration"

    /** Local device id stamped on memory items; generated as a UUID on first use and kept across state clears. */
    const val MEMORY_DEVICE_ID = "memory_device_id"

    val DEVICE_SCOPED_KEYS = setOf(
        ONBOARDING_COMPLETED,
        THEME,
        LANGUAGE,
        PROVIDER_DISCLOSURE_ACCEPTED_LIST,
        NOTE_CAPTURE_HINT_SEEN,
        FEATURE_BADGES_SEEN,
        MEMORY_DEVICE_ID,
    )

    val USER_STATE_KEYS = setOf(
        LAST_USED_PROVIDER_ID,
        LAST_USED_MODEL_ID,
        MEMORY_TEXT,
        MEMORY_TEXT_DIGEST,
        MEMORY_ITEMS_MIGRATED,
        MEMORY_ANTI_FORGET_ENABLED,
        MEMORY_ANTI_FORGET_TEXT,
        CONTEXT_AI_SUMMARY_ENABLED,
        CONTEXT_DEFAULT_CAP,
        CONTEXT_PRICE_LINE_REMINDER_ENABLED,
        MEMORY_UPDATED_AT,
        MEMORY_USAGE_COUNT,
        MEMORY_USAGE_CONVERSATION_IDS,
        MEMORY_HAS_SEEN,
        MEMORY_AUTO_SUGGEST_ENABLED,
        PROVIDER_DETERMINISTIC_ID_MIGRATION,
        LLAMACPP_CHAT_CHANNEL_MIGRATION,
        PINNED_CONVERSATION_IDS,
        PINNED_CONVERSATION_IDS_UPDATED_AT,
    )

    fun isDeviceScoped(key: String): Boolean = DEVICE_SCOPED_KEYS.contains(key)

    fun isUserState(key: String): Boolean = USER_STATE_KEYS.contains(key)
}
