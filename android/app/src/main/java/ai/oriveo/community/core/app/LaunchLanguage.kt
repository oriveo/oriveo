package ai.oriveo.community.core.app

import android.app.LocaleManager
import android.content.Context
import android.os.Build
import android.os.LocaleList
import android.os.StrictMode
import androidx.annotation.RequiresApi
import ai.oriveo.community.core.model.LanguageOption
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.Locale

/**
 * Language handling at cold start.
 *
 * - API 33+: the system (LocaleManager) persists the per-app language and applies it at process start, so the launch path reads no prefs.
 *   A one-time background migration writes the user's choice into the system when the system value is empty and prefs hold a choice.
 *   After that the system is the source of truth: prefs / DB that disagree with it are rewritten to the system value; values that do not map to [LanguageOption] are left alone.
 * - API <= 32: there is no system persistence, so the value must be read and applied synchronously before the first Activity is created
 *   (AppCompat guidance: with autoStoreLocales=false the app restores it before Activities). This single read is explicitly exempted from StrictMode disk reads.
 */
object LaunchLanguage {

    const val PREFS_NAME = "oriveo_prefs"
    const val KEY_APP_LANGUAGE = "app_language"

    /** API 33+ one-time migration marker: the user's choice in prefs has been written to the system (or needs no write); from then on the system is the source of truth. */
    const val KEY_SYSTEM_SYNCED = "app_language_system_synced"

    /**
     * @param scope Scope for background reconciliation; production passes appScope (Dispatchers.IO).
     * @param repository Reconciliation target; when it returns null (for example, the local database is unavailable) the whole step is skipped.
     */
    fun applyOnLaunch(
        context: Context,
        scope: CoroutineScope,
        repository: suspend () -> AppPreferencesRepository?,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            scope.launch { reconcileWithSystem(context, repository) }
            return
        }
        // <=32 must restore the language synchronously before the Activity (AppCompat: the app is responsible when autoStoreLocales is off).
        // A single SharedPreferences key read takes microseconds; StrictMode disk reads are exempted here, and finally restores the original policy.
        val oldPolicy = StrictMode.allowThreadDiskReads()
        val stored = try {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getString(KEY_APP_LANGUAGE, null)
        } finally {
            StrictMode.setThreadPolicy(oldPolicy)
        }
        AppLanguageManager.apply(AppPreferencesRepository.parseLanguagePreference(stored) ?: LanguageOption.System)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private suspend fun reconcileWithSystem(
        context: Context,
        repository: suspend () -> AppPreferencesRepository?,
    ) {
        // AppCompat cannot get LocaleManager without an Activity, so all system reads and writes go through the framework LocaleManager
        val localeManager = context.getSystemService(LocaleManager::class.java) ?: return
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val stored = prefs.getString(KEY_APP_LANGUAGE, null)
        val prefsOption = AppPreferencesRepository.parseLanguagePreference(stored) ?: LanguageOption.System
        var systemLocales = localeManager.applicationLocales
        if (!prefs.getBoolean(KEY_SYSTEM_SYNCED, false)) {
            // One-time migration (12 to 13 upgrade, or a <=32 backup restored on 33+): when the system is empty but prefs hold the user's choice, write the choice to the system,
            // so it is not overwritten to "follow system". If the system already has a value, it is the source of truth; only the marker is recorded.
            if (systemLocales.isEmpty && prefsOption != LanguageOption.System) {
                val tag = AppLanguageManager.applicationLocaleTag(prefsOption) ?: return
                systemLocales = LocaleList.forLanguageTags(tag)
                localeManager.applicationLocales = systemLocales
            }
            prefs.edit().putBoolean(KEY_SYSTEM_SYNCED, true).commit()
        }
        val system = optionFor(systemLocales) ?: return
        val repo = repository() ?: return
        // If both sides already match the system, write nothing (running again on the same snapshot produces no writes)
        if (prefsOption == system && repo.getLanguage() == system) return
        // If the system value changed during reconciliation (the user just changed the language in system settings), abandon this write and leave it to the next pass; do not write back the old value
        if (localeManager.applicationLocales.toLanguageTags() != systemLocales.toLanguageTags()) return
        repo.setLanguage(system)
    }

    /** System per-app language to [LanguageOption]; an empty list means "follow system"; returns null when it does not map. */
    internal fun optionFor(locales: LocaleList): LanguageOption? {
        if (locales.isEmpty) return LanguageOption.System
        return optionFor(locales[0])
    }

    internal fun optionFor(locale: Locale): LanguageOption? {
        if (locale.language == "zh") {
            val traditional = locale.script == "Hant" ||
                (locale.script.isEmpty() && locale.country in setOf("TW", "HK", "MO"))
            return if (traditional) LanguageOption.ChineseTraditional else LanguageOption.ChineseSimplified
        }
        return LanguageOption.entries.firstOrNull { option ->
            val tag = option.localeTag ?: return@firstOrNull false
            Locale.forLanguageTag(tag).language == locale.language
        }
    }
}
