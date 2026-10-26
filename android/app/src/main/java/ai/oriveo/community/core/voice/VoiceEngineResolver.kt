package ai.oriveo.community.core.voice

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ProviderCredentialResolver

/** Engine resolution only looks at these four connection fields; order is given by the caller (the connection order in settings). */
data class VoiceConnection(
    val id: String,
    val providerKind: ProviderKind,
    val authMode: ProviderAuthMode,
    val hasKey: Boolean,
) {
    /** Subscription-login connections and connections without a key are not candidates. */
    val isUsable: Boolean get() = authMode == ProviderAuthMode.ApiKey && hasKey

    companion object {
        fun from(provider: Provider): VoiceConnection = VoiceConnection(
            id = provider.id,
            providerKind = provider.kind,
            authMode = provider.authMode,
            hasKey = ProviderCredentialResolver.apiKey(provider, null).isNotEmpty(),
        )
    }
}

/** The selection stored in settings. */
sealed interface VoiceEngineSelection {
    data object System : VoiceEngineSelection

    data class Cloud(
        val providerKind: ProviderKind,
        val connectionId: String,
        val model: String,
        val voice: String? = null,
    ) : VoiceEngineSelection
}

/** The engine actually used; a Cloud voice only has a value for tts / realtime (voice fallback already applied). */
sealed interface VoiceEngine {
    data object System : VoiceEngine

    data class Cloud(
        val providerKind: ProviderKind,
        val connectionId: String,
        val model: String,
        val voice: String? = null,
    ) : VoiceEngine
}

enum class VoiceFallbackReason(val rawValue: String) {
    ConnectionMissing("connection_missing"),
    KeyMissing("key_missing"),
    EntryRemoved("entry_removed"),
}

enum class VoiceSelectionPersist(val rawValue: String) {
    /** Leave the stored selection untouched. */
    Keep("keep"),

    /** Rewrite the stored selection to system. */
    System("system"),
}

/** notice = true: show on the settings row once, and prompt once more on next use. */
data class VoiceEngineResolution(
    val engine: VoiceEngine,
    val reason: VoiceFallbackReason? = null,
    val notice: Boolean = false,
    val persist: VoiceSelectionPersist = VoiceSelectionPersist.Keep,
)

/** One row of the engine picker; unavailable combinations are not listed (not greyed out). */
sealed interface VoiceEngineOption {
    data object System : VoiceEngineOption

    data class Cloud(
        val providerKind: ProviderKind,
        val connectionId: String,
        val model: String,
        val isDefault: Boolean,
    ) : VoiceEngineOption
}

/** rules.resolve / rules.options of the shared engine-resolution.v2.json contract. */
object VoiceEngineResolver {
    fun resolve(
        catalog: VoiceCatalog,
        direction: VoiceDirection,
        selection: VoiceEngineSelection,
        connections: List<VoiceConnection>,
    ): VoiceEngineResolution {
        val cloud = selection as? VoiceEngineSelection.Cloud
            ?: return VoiceEngineResolution(VoiceEngine.System)
        val connection = connections.firstOrNull { it.id == cloud.connectionId }
        if (connection == null || connection.providerKind != cloud.providerKind) {
            return fallback(VoiceFallbackReason.ConnectionMissing)
        }
        if (!connection.isUsable) return fallback(VoiceFallbackReason.KeyMissing)
        val entry = catalog.entry(cloud.providerKind, direction, cloud.model)
            ?: return fallback(VoiceFallbackReason.EntryRemoved)
        val voice = entry.voiceOptions()?.let { voices ->
            voices.firstOrNull { it.id == cloud.voice }?.id ?: entry.defaultVoiceId()
        }
        return VoiceEngineResolution(
            VoiceEngine.Cloud(
                providerKind = cloud.providerKind,
                connectionId = connection.id,
                model = entry.model,
                voice = voice,
            ),
        )
    }

    fun options(
        catalog: VoiceCatalog,
        direction: VoiceDirection,
        connections: List<VoiceConnection>,
    ): List<VoiceEngineOption> = buildList {
        add(VoiceEngineOption.System)
        for (connection in connections) {
            if (!connection.isUsable) continue
            for (entry in catalog.entries(connection.providerKind, direction)) {
                add(
                    VoiceEngineOption.Cloud(
                        providerKind = connection.providerKind,
                        connectionId = connection.id,
                        model = entry.model,
                        isDefault = entry.isDefault,
                    ),
                )
            }
        }
    }

    private fun fallback(reason: VoiceFallbackReason) = VoiceEngineResolution(
        engine = VoiceEngine.System,
        reason = reason,
        notice = true,
        persist = VoiceSelectionPersist.System,
    )
}

/** Voice list of entries that carry voices (tts / realtime); null for stt. */
internal fun VoiceCatalogEntry.voiceOptions(): List<VoiceOption>? = when (this) {
    is VoiceTtsEntry -> voices
    is VoiceRealtimeEntry -> voices
    is VoiceSttEntry -> null
}

/** Entry default voice: the one marked isDefault, otherwise the first; null for stt. */
internal fun VoiceCatalogEntry.defaultVoiceId(): String? = when (this) {
    is VoiceTtsEntry -> defaultVoice.id
    is VoiceRealtimeEntry -> defaultVoice.id
    is VoiceSttEntry -> null
}
