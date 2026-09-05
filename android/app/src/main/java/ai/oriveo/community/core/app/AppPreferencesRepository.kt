package ai.oriveo.community.core.app

import android.content.Context
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.data.dao.PreferenceDao
import ai.oriveo.community.core.data.entity.PreferenceEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.AppPreference
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.LastUsedModelRef
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ThemeOption
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.util.takeGraphemes
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.Instant

@OptIn(ExperimentalCoroutinesApi::class)
class AppPreferencesRepository(
    private val preferenceDao: PreferenceDao,
    private val runInTransaction: suspend (suspend () -> Unit) -> Unit = { block -> block() },
    private val appContext: Context? = null,
) {
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    companion object {
        const val MEMORY_CHARACTER_LIMIT = 2_000
        const val MEMORY_ANTI_FORGET_CHARACTER_LIMIT = 200

        
        private const val STARTUP_CACHE_PREFS = "oriveo_prefs"

        
        private const val STARTUP_CACHE_ONBOARDING_COMPLETED = "onboarding_completed_cache"

        
        fun readOnboardingCompletedSync(context: Context): Boolean =
            context.getSharedPreferences(STARTUP_CACHE_PREFS, Context.MODE_PRIVATE)
                .getBoolean(STARTUP_CACHE_ONBOARDING_COMPLETED, false)

        fun parseThemePreference(value: String?): ThemeOption? {
            if (value.isNullOrBlank()) return null
            return ThemeOption.entries.firstOrNull { option ->
                option.name.equals(value, ignoreCase = true) ||
                    option.name.lowercase() == value.lowercase()
            }
        }

        fun parseLanguagePreference(value: String?): LanguageOption? {
            if (value.isNullOrBlank()) return null
            return LanguageOption.entries.firstOrNull { option ->
                option.name.equals(value, ignoreCase = true) ||
                    option.name.replaceFirstChar { it.lowercase() }.equals(value, ignoreCase = true)
            }
        }

        fun serializeThemePreference(option: ThemeOption): String = option.name.lowercase()

        fun serializeLanguagePreference(option: LanguageOption): String = when (option) {
            LanguageOption.System -> "system"
            LanguageOption.English -> "english"
            LanguageOption.ChineseSimplified -> "chineseSimplified"
            LanguageOption.ChineseTraditional -> "chineseTraditional"
            LanguageOption.Japanese -> "japanese"
            LanguageOption.Korean -> "korean"
            LanguageOption.Spanish -> "spanish"
            LanguageOption.French -> "french"
            LanguageOption.German -> "german"
            LanguageOption.Portuguese -> "portuguese"
            LanguageOption.Arabic -> "arabic"
            LanguageOption.Hindi -> "hindi"
            LanguageOption.Indonesian -> "indonesian"
            LanguageOption.Vietnamese -> "vietnamese"
            LanguageOption.Thai -> "thai"
            LanguageOption.Turkish -> "turkish"
            LanguageOption.Russian -> "russian"
        }

        
        fun serializeLanguageSyncTag(option: LanguageOption): String? = when (option) {
            LanguageOption.System -> null
            LanguageOption.English -> "en"
            LanguageOption.ChineseSimplified -> "zh-Hans"
            LanguageOption.ChineseTraditional -> "zh-Hant"
            LanguageOption.Japanese -> "ja"
            LanguageOption.Korean -> "ko"
            LanguageOption.Spanish -> "es"
            LanguageOption.French -> "fr"
            LanguageOption.German -> "de"
            LanguageOption.Portuguese -> "pt-BR"
            LanguageOption.Arabic -> "ar"
            LanguageOption.Hindi -> "hi"
            LanguageOption.Indonesian -> "id"
            LanguageOption.Vietnamese -> "vi"
            LanguageOption.Thai -> "th"
            LanguageOption.Turkish -> "tr"
            LanguageOption.Russian -> "ru"
        }

        
        fun parseLanguageSyncTag(value: String?): LanguageOption? {
            if (value.isNullOrBlank()) return null
            when (value) {
                "en" -> return LanguageOption.English
                "zh-Hans" -> return LanguageOption.ChineseSimplified
                "zh-Hant" -> return LanguageOption.ChineseTraditional
                "ja" -> return LanguageOption.Japanese
                "ko" -> return LanguageOption.Korean
                "es" -> return LanguageOption.Spanish
                "fr" -> return LanguageOption.French
                "de" -> return LanguageOption.German
                "pt-BR" -> return LanguageOption.Portuguese
                "ar" -> return LanguageOption.Arabic
                "hi" -> return LanguageOption.Hindi
                "id" -> return LanguageOption.Indonesian
                "vi" -> return LanguageOption.Vietnamese
                "th" -> return LanguageOption.Thai
                "tr" -> return LanguageOption.Turkish
                "ru" -> return LanguageOption.Russian
            }
            return parseLanguagePreference(value)
        }
    }

    val hasCompletedOnboarding: Flow<Boolean> = observeDeviceScoped(AppPreferenceKeys.ONBOARDING_COMPLETED)
        .map { it == "true" }

    
    val initialOnboardingCompleted: Boolean
        get() = appContext?.let { readOnboardingCompletedSync(it) } ?: false

    val theme: Flow<ThemeOption> = observeDeviceScoped(AppPreferenceKeys.THEME)
        .map { value ->
            
            parseThemePreference(value) ?: ThemeOption.Dark
        }

    val language: Flow<LanguageOption> = observeDeviceScoped(AppPreferenceKeys.LANGUAGE)
        .map { value ->
            parseLanguagePreference(value) ?: LanguageOption.System
        }

    val memoryText: Flow<String> = observeUserState(AppPreferenceKeys.MEMORY_TEXT)
        .map { it ?: "" }

    val memoryAntiForgetEnabled: Flow<Boolean> = observeUserState(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED)
        .map { it?.toBooleanStrictOrNull() ?: false }

    val memoryAntiForgetText: Flow<String> = observeUserState(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT)
        .map { it ?: "" }

    val memoryUpdatedAt: Flow<String?> = observeUserState(AppPreferenceKeys.MEMORY_UPDATED_AT)

    val memoryUsageCount: Flow<Int> = observeUserState(AppPreferenceKeys.MEMORY_USAGE_COUNT)
        .map { it?.toIntOrNull() ?: 0 }

    val memoryUsageConversationIds: Flow<Set<String>> = observeUserState(AppPreferenceKeys.MEMORY_USAGE_CONVERSATION_IDS)
        .map(::decodeMemoryUsageConversationIds)

    val memoryHasSeen: Flow<Boolean> = observeUserState(AppPreferenceKeys.MEMORY_HAS_SEEN)
        .map { it?.toBooleanStrictOrNull() ?: false }

    
    val pinnedConversationIds: Flow<List<String>> = observeUserState(AppPreferenceKeys.PINNED_CONVERSATION_IDS)
        .map(::decodePinnedConversationIds)

    
    val pinnedConversationIdsUpdatedAt: Flow<String?> = observeUserState(AppPreferenceKeys.PINNED_CONVERSATION_IDS_UPDATED_AT)

    val preference: Flow<AppPreference> = combine(
        combine(theme, language, memoryText) { theme, language, memoryText ->
            Triple(theme, language, memoryText)
        },
        combine(memoryAntiForgetEnabled, memoryAntiForgetText, memoryUpdatedAt) { enabled, text, updatedAt ->
            Triple(enabled, text, updatedAt)
        },
    ) { basePreference, memoryPreference ->
        AppPreference(
            theme = basePreference.first,
            language = basePreference.second,
            memoryText = basePreference.third,
            memoryAntiForgetEnabled = memoryPreference.first,
            memoryAntiForgetText = memoryPreference.second,
            memoryUpdatedAt = memoryPreference.third,
        )
    }

    
    
    private val lastUsedModelOverride = MutableStateFlow<Pair<String, LastUsedModelRef>?>(null)

    val lastUsedModelRef: Flow<LastUsedModelRef?> = combine(
        combine(
            observeUserState(AppPreferenceKeys.LAST_USED_PROVIDER_ID),
            observeUserState(AppPreferenceKeys.LAST_USED_MODEL_ID),
        ) { providerId, modelId ->
            if (providerId.isNullOrBlank() || modelId.isNullOrBlank()) {
                null
            } else {
                LastUsedModelRef(
                    providerID = providerId,
                    modelID = modelId,
                )
            }
        },
        lastUsedModelOverride,
    ) { stored, override ->
        override?.takeIf { it.first == currentAccountId() }?.second ?: stored
    }

    
    val lastUsedModelRefSnapshot: LastUsedModelRef?
        get() = lastUsedModelOverride.value?.takeIf { it.first == currentAccountId() }?.second

    /**
     * Marks onboarding finished.
     *
     * The flag is mirrored into shared preferences as well as the database because the first frame
     * decides which screen to show before the database has been opened.
     */
    suspend fun completeOnboarding() {
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.ONBOARDING_COMPLETED, "true"))
        appContext?.getSharedPreferences(STARTUP_CACHE_PREFS, Context.MODE_PRIVATE)
            ?.edit()
            ?.putBoolean(STARTUP_CACHE_ONBOARDING_COMPLETED, true)
            ?.apply()
    }

    suspend fun setTheme(option: ThemeOption) {
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.THEME, option.name))

    }

    suspend fun setLanguage(option: LanguageOption) {
        preferenceDao.set(PreferenceEntity(AppPreferenceKeys.LANGUAGE, option.name))
        
        appContext?.getSharedPreferences("oriveo_prefs", Context.MODE_PRIVATE)
            ?.edit()
            ?.putString("app_language", option.name)
            ?.apply()

    }

    
    suspend fun hasAcceptedProviderDisclosure(kind: ProviderKind): Boolean =
        acceptedProviderDisclosureRawValues().contains(kind.rawValue)

    suspend fun markProviderDisclosureAccepted(kind: ProviderKind) {
        runInTransaction {
            val current = acceptedProviderDisclosureRawValues()
            if (current.contains(kind.rawValue)) return@runInTransaction
            val updated = (current + kind.rawValue).joinToString(",")
            preferenceDao.set(
                PreferenceEntity(AppPreferenceKeys.PROVIDER_DISCLOSURE_ACCEPTED_LIST, updated),
            )
        }
    }

    private suspend fun acceptedProviderDisclosureRawValues(): Set<String> =
        acceptedRawValues(AppPreferenceKeys.PROVIDER_DISCLOSURE_ACCEPTED_LIST)

    
    private suspend fun acceptedRawValues(key: String): Set<String> {
        val raw = observeDeviceScopedValue(key).orEmpty()
        if (raw.isBlank()) return emptySet()
        return raw.split(',').map { it.trim() }.filter { it.isNotEmpty() }.toSet()
    }

    /** One-shot hint shown the first time a reply can be captured as a note. */
    suspend fun hasSeenNoteCaptureHint(): Boolean =
        observeDeviceScopedValue(AppPreferenceKeys.NOTE_CAPTURE_HINT_SEEN) == "true"

    suspend fun markNoteCaptureHintSeen() {
        preferenceDao.set(
            PreferenceEntity(AppPreferenceKeys.NOTE_CAPTURE_HINT_SEEN, "true"),
        )
    }

    suspend fun getLanguage(): LanguageOption =
        parseLanguagePreference(observeDeviceScopedValue(AppPreferenceKeys.LANGUAGE)) ?: LanguageOption.System

    
    fun primeLastUsedModel(providerId: String, modelId: String) {
        lastUsedModelOverride.value =
            currentAccountId() to LastUsedModelRef(providerID = providerId, modelID = modelId)
    }

    suspend fun setLastUsedModel(providerId: String, modelId: String) {
        preferenceDao.set(
            PreferenceEntity(
                storageKeyForCurrentAccount(AppPreferenceKeys.LAST_USED_PROVIDER_ID),
                providerId,
            ),
        )
        preferenceDao.set(
            PreferenceEntity(
                storageKeyForCurrentAccount(AppPreferenceKeys.LAST_USED_MODEL_ID),
                modelId,
            ),
        )
    }

    suspend fun setLastUsedModel(providerId: String, model: AIModel) {
        setLastUsedModel(
            providerId = providerId,
            modelId = ModelSelectionUtils.preferredStoredModelIdentifier(model),
        )
    }

    suspend fun clearLastUsedModel() {
        lastUsedModelOverride.value = null
        preferenceDao.delete(storageKeyForCurrentAccount(AppPreferenceKeys.LAST_USED_PROVIDER_ID))
        preferenceDao.delete(storageKeyForCurrentAccount(AppPreferenceKeys.LAST_USED_MODEL_ID))
    }

    suspend fun getMemoryText(accountId: String = currentAccountId()): String =
        accountScopedValue(AppPreferenceKeys.MEMORY_TEXT, accountId).orEmpty()

    suspend fun getMemoryAntiForgetEnabled(accountId: String = currentAccountId()): Boolean =
        accountScopedValue(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED, accountId)?.toBooleanStrictOrNull() ?: false

    suspend fun getMemoryAntiForgetText(accountId: String = currentAccountId()): String =
        accountScopedValue(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT, accountId).orEmpty()

    suspend fun getMemoryUpdatedAt(accountId: String = currentAccountId()): String? =
        accountScopedValue(AppPreferenceKeys.MEMORY_UPDATED_AT, accountId)

    suspend fun getLastUsedModelRef(accountId: String = currentAccountId()): LastUsedModelRef? {
        val providerId = accountScopedValue(AppPreferenceKeys.LAST_USED_PROVIDER_ID, accountId)
        val modelId = accountScopedValue(AppPreferenceKeys.LAST_USED_MODEL_ID, accountId)
        if (providerId.isNullOrBlank() || modelId.isNullOrBlank()) return null
        return LastUsedModelRef(
            providerID = providerId,
            modelID = modelId,
        )
    }

    suspend fun setMemoryText(text: String) {
        preferenceDao.set(
            PreferenceEntity(
                storageKeyForCurrentAccount(AppPreferenceKeys.MEMORY_TEXT),
                text.takeGraphemes(MEMORY_CHARACTER_LIMIT),
            ),
        )
    }

    suspend fun setMemoryAntiForgetEnabled(enabled: Boolean) {
        preferenceDao.set(
            PreferenceEntity(
                storageKeyForCurrentAccount(AppPreferenceKeys.MEMORY_ANTI_FORGET_ENABLED),
                enabled.toString(),
            ),
        )
    }

    suspend fun setMemoryAntiForgetText(text: String) {
        preferenceDao.set(
            PreferenceEntity(
                storageKeyForCurrentAccount(AppPreferenceKeys.MEMORY_ANTI_FORGET_TEXT),
                text.takeGraphemes(MEMORY_ANTI_FORGET_CHARACTER_LIMIT),
            ),
        )
    }

    suspend fun setMemoryUpdatedAt(isoTimestamp: String) {
        preferenceDao.set(
            PreferenceEntity(
                storageKeyForCurrentAccount(AppPreferenceKeys.MEMORY_UPDATED_AT),
                isoTimestamp,
            ),
        )
    }

    suspend fun setMemoryHasSeen(seen: Boolean) {
        preferenceDao.set(
            PreferenceEntity(
                storageKeyForCurrentAccount(AppPreferenceKeys.MEMORY_HAS_SEEN),
                seen.toString(),
            ),
        )
    }

    
    suspend fun setPinnedConversationIds(ids: List<String>, updatedAt: String = Instant.now().toString()) {
        persistPinnedConversationIds(ids, updatedAt)

    }

    suspend fun togglePinnedConversation(conversationId: String, updatedAt: String = Instant.now().toString()): List<String> {
        val currentIds = getPinnedConversationIds()
        val updatedIds = if (currentIds.contains(conversationId)) {
            currentIds.filterNot { it == conversationId }
        } else {
            currentIds + conversationId
        }
        setPinnedConversationIds(updatedIds, updatedAt)
        return updatedIds
    }

    private suspend fun persistPinnedConversationIds(ids: List<String>, updatedAt: String) {
        runInTransaction {
            preferenceDao.set(
                PreferenceEntity(
                    storageKeyForCurrentAccount(AppPreferenceKeys.PINNED_CONVERSATION_IDS),
                    json.encodeToString(ids),
                ),
            )
            preferenceDao.set(
                PreferenceEntity(
                    storageKeyForCurrentAccount(AppPreferenceKeys.PINNED_CONVERSATION_IDS_UPDATED_AT),
                    updatedAt,
                ),
            )
        }
    }

    
    suspend fun applyRemotePinnedConversationIds(ids: List<String>, remoteUpdatedAt: String) {
        persistPinnedConversationIds(ids = ids, updatedAt = remoteUpdatedAt)
    }

    suspend fun getPinnedConversationIds(accountId: String = currentAccountId()): List<String> =
        decodePinnedConversationIds(accountScopedValue(AppPreferenceKeys.PINNED_CONVERSATION_IDS, accountId))

    suspend fun getPinnedConversationIdsUpdatedAt(accountId: String = currentAccountId()): String? =
        accountScopedValue(AppPreferenceKeys.PINNED_CONVERSATION_IDS_UPDATED_AT, accountId)

    suspend fun markMemoryUsedInConversation(conversationId: String) {
        val normalizedId = conversationId.trim()
        if (normalizedId.isEmpty()) return

        val current = decodeMemoryUsageConversationIds(
            accountScopedValue(AppPreferenceKeys.MEMORY_USAGE_CONVERSATION_IDS, currentAccountId()),
        ).toMutableSet()
        if (!current.add(normalizedId)) return

        val sortedIds = current.toList().sorted()
        preferenceDao.set(
            PreferenceEntity(
                storageKeyForCurrentAccount(AppPreferenceKeys.MEMORY_USAGE_CONVERSATION_IDS),
                json.encodeToString(sortedIds),
            ),
        )
        preferenceDao.set(
            PreferenceEntity(
                storageKeyForCurrentAccount(AppPreferenceKeys.MEMORY_USAGE_COUNT),
                sortedIds.size.toString(),
            ),
        )
    }

    suspend fun saveMemory(
        text: String,
        antiForgetEnabled: Boolean,
        antiForgetText: String,
        updatedAt: String = Instant.now().toString(),
    ) {
        val normalizedText = text.trim().takeGraphemes(MEMORY_CHARACTER_LIMIT)
        runInTransaction {
            if (normalizedText.isBlank()) {
                setMemoryText("")
                setMemoryAntiForgetEnabled(false)
                setMemoryAntiForgetText("")
                setMemoryUpdatedAt(updatedAt)
                return@runInTransaction
            }

            setMemoryText(normalizedText)
            setMemoryAntiForgetEnabled(antiForgetEnabled)
            setMemoryAntiForgetText(
                antiForgetText.trim().takeGraphemes(MEMORY_ANTI_FORGET_CHARACTER_LIMIT),
            )
            setMemoryUpdatedAt(updatedAt)
        }

    }

    private fun observeDeviceScoped(key: String): Flow<String?> {
        check(AppPreferenceKeys.isDeviceScoped(key)) { "Unsupported device-scoped key: $key" }
        return preferenceDao.observe(key)
    }

    private fun observeUserState(key: String): Flow<String?> {
        check(AppPreferenceKeys.isUserState(key)) { "Unsupported user-state key: $key" }
        return preferenceDao.observe(key)
    }

    private suspend fun observeDeviceScopedValue(key: String): String? {
        check(AppPreferenceKeys.isDeviceScoped(key)) { "Unsupported device-scoped key: $key" }
        return preferenceDao.get(key)
    }

    private suspend fun accountScopedValue(
        key: String,
        @Suppress("UNUSED_PARAMETER") accountId: String,
    ): String? {
        check(AppPreferenceKeys.isUserState(key)) { "Unsupported user-state key: $key" }
        return preferenceDao.get(key)
    }

    private fun storageKeyForCurrentAccount(key: String): String = key

    private fun currentAccountId(): String = LOCAL_PARTITION_ID

    private fun decodeMemoryUsageConversationIds(rawValue: String?): Set<String> {
        val raw = rawValue?.takeIf { it.isNotBlank() } ?: return emptySet()
        return runCatching {
            json.decodeFromString<List<String>>(raw)
                .map(String::trim)
                .filter(String::isNotEmpty)
                .toSet()
        }.getOrDefault(emptySet())
    }

    
    private fun decodePinnedConversationIds(rawValue: String?): List<String> {
        val raw = rawValue?.takeIf { it.isNotBlank() } ?: return emptyList()
        return runCatching {
            json.decodeFromString<List<String>>(raw)
                .map(String::trim)
                .filter(String::isNotEmpty)
        }.getOrDefault(emptyList())
    }
}
