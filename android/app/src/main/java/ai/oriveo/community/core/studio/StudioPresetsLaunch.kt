package ai.oriveo.community.core.studio

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Launch-time refresh of studio presets. A hidden Studio entry returns null without touching the
 * store; a visible one resolves the app language against the preset locales, calls
 * [StudioPresetsStore.refreshIfNeeded], and only on [StudioPresets.Outcome.REPLACED] prunes the
 * sample cache to the sha256 set of the current styles' samples. Never prefetches samples.
 */
object StudioPresetsLaunch {
    /** [locales] is read only when the entry is visible (production: [snapshotLocales] of the bundled snapshot). */
    suspend fun run(
        entryVisible: Boolean,
        appLanguageTag: String?,
        store: StudioPresetsStore,
        sampleCache: StudioPresetSampleCache,
        locales: () -> List<String>,
    ): StudioPresets.Outcome? {
        if (!entryVisible) return null
        val locale = StudioPresets.resolveLocale(locales(), appLanguageTag)
        val outcome = store.refreshIfNeeded(locale)
        if (outcome == StudioPresets.Outcome.REPLACED) {
            val current = store.current(locale)
            if (current != null) {
                sampleCache.prune(current.styles.mapNotNullTo(HashSet()) { it.sample?.sha256 })
            }
        }
        return outcome
    }

    /** The `locales` list of the bundled presets snapshot; empty when it cannot be read. */
    fun snapshotLocales(snapshot: () -> String?): List<String> {
        val raw = runCatching { snapshot() }.getOrNull() ?: return emptyList()
        val root = runCatching { Json.parseToJsonElement(raw) }.getOrNull() as? JsonObject ?: return emptyList()
        return (root["locales"] as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
            ?: emptyList()
    }
}
