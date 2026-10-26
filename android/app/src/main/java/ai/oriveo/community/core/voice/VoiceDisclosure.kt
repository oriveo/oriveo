package ai.oriveo.community.core.voice

import android.content.SharedPreferences
import ai.oriveo.community.core.model.ProviderKind

/**
 * Consent records for the cloud voice disclosure: keyed by (providerKind, direction), stored only in local SharedPreferences (not Room).
 *
 * Stored under [KEY_ACCEPTED] in [VoiceEngineSettings.PREFS_NAME]; StringSet elements look like `<providerKind rawValue>/<stt|tts|realtime>`.
 */
class VoiceDisclosureStore(
    prefsProvider: () -> SharedPreferences,
) {
    private val prefs: SharedPreferences by lazy(LazyThreadSafetyMode.PUBLICATION) {
        prefsProvider()
    }

    fun isAccepted(providerKind: ProviderKind, direction: VoiceDirection): Boolean =
        element(providerKind, direction) in accepted()

    fun markAccepted(providerKind: ProviderKind, direction: VoiceDirection) {
        val next = accepted() + element(providerKind, direction)
        prefs.edit().putStringSet(KEY_ACCEPTED, next.toMutableSet()).apply()
    }

    // Copy before use: the set returned by SharedPreferences must not be mutated in place.
    private fun accepted(): Set<String> = prefs.getStringSet(KEY_ACCEPTED, null)?.toSet() ?: emptySet()

    private fun element(providerKind: ProviderKind, direction: VoiceDirection) =
        "${providerKind.rawValue}/${direction.rawValue}"

    companion object {
        const val KEY_ACCEPTED = "oriveo.voice.disclosure.accepted"
    }
}

/** Result of choosing an engine. */
sealed interface VoiceChoice {
    /** Written to settings (system, or a cloud engine already consented to). */
    data object Written : VoiceChoice

    /** Cloud engine whose (providerKind, direction) has not been consented to: show the disclosure first, then call [VoiceEngineChooser.accept] / [VoiceEngineChooser.decline] based on the user's action. */
    data class NeedsDisclosure(
        val direction: VoiceDirection,
        val selection: VoiceEngineSelection.Cloud,
    ) : VoiceChoice

    /** Disclosure accepted: consent recorded and selection written. */
    data object Accepted : VoiceChoice

    /** Disclosure declined (not now / swipe to dismiss): nothing is written. */
    data object Declined : VoiceChoice
}

/**
 * Engine selection flow for the engine panel: system is written immediately; a cloud engine is written
 * immediately if already consented to, otherwise a disclosure is required first and it is written only on consent.
 */
class VoiceEngineChooser(
    private val settings: VoiceEngineSettings,
    private val store: VoiceDisclosureStore,
) {
    /** When choosing a read-aloud / conversation engine entry, the voice is set to the entry's default voice. */
    fun choose(direction: VoiceDirection, option: VoiceEngineOption, catalog: VoiceCatalog): VoiceChoice {
        val cloud = when (option) {
            VoiceEngineOption.System -> {
                settings.setSelection(direction, VoiceEngineSelection.System)
                return VoiceChoice.Written
            }
            is VoiceEngineOption.Cloud -> option
        }
        val voice = catalog.entry(cloud.providerKind, direction, cloud.model)?.defaultVoiceId()
        val selection = VoiceEngineSelection.Cloud(
            providerKind = cloud.providerKind,
            connectionId = cloud.connectionId,
            model = cloud.model,
            voice = voice,
        )
        if (!store.isAccepted(cloud.providerKind, direction)) {
            return VoiceChoice.NeedsDisclosure(direction, selection)
        }
        settings.setSelection(direction, selection)
        return VoiceChoice.Written
    }

    fun accept(pending: VoiceChoice.NeedsDisclosure): VoiceChoice {
        store.markAccepted(pending.selection.providerKind, pending.direction)
        settings.setSelection(pending.direction, pending.selection)
        return VoiceChoice.Accepted
    }

    fun decline(pending: VoiceChoice.NeedsDisclosure): VoiceChoice {
        return VoiceChoice.Declined
    }
}
