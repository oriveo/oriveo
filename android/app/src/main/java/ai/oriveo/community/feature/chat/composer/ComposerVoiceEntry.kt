package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.RelayRuntimeSupport

/** What the composer's main button shows: stop while generating, up arrow with content, waveform key on an empty draft. */
internal enum class ComposerActionMode { Stop, Send, Voice, Idle }

/** Home hero bottom row: the up arrow is always the primary key; the waveform key is a secondary key left of it, only on an empty draft. */
internal data class HomeComposerActions(val sendEnabled: Boolean, val showsVoice: Boolean)

internal object ComposerVoiceEntry {
    /** The waveform key ignores taps for this long after stop turned back into the waveform key. */
    const val REARM_MILLIS = 500L

    fun mode(isGenerating: Boolean, hasContent: Boolean, voiceAvailable: Boolean): ComposerActionMode = when {
        isGenerating -> ComposerActionMode.Stop
        hasContent -> ComposerActionMode.Send
        offersVoice(isBusy = false, hasContent = false, voiceAvailable = voiceAvailable) -> ComposerActionMode.Voice
        else -> ComposerActionMode.Idle
    }

    /**
     * Home hero: the up arrow stays the primary key (enabled unless a send is in flight); the waveform key uses the same gate as the chat
     * page's Voice mode. [voiceAvailable] is true when no model is resolved yet, so the entry stays offered.
     */
    fun home(isSending: Boolean, hasContent: Boolean, voiceAvailable: Boolean): HomeComposerActions =
        HomeComposerActions(
            sendEnabled = !isSending,
            showsVoice = offersVoice(isBusy = isSending, hasContent = hasContent, voiceAvailable = voiceAvailable),
        )

    /** Shared waveform-key gate: nothing in flight, empty draft, and a model that can answer in text. */
    private fun offersVoice(isBusy: Boolean, hasContent: Boolean, voiceAvailable: Boolean): Boolean =
        !isBusy && !hasContent && voiceAvailable

    /**
     * The model only generates images and never answers in text, so the waveform key is not offered (grey up arrow stays).
     * Image only = the server metadata routes it to a dedicated image endpoint
     * ([ChatRepository.DEDICATED_IMAGE_GEN_ROUTES]), the id is a dedicated image model, or the metadata lists image
     * generation without text. Raw capability lists are not read here (capability gate R1: only the evidence facade
     * may read them, [CapabilityEvidenceFacade.isImageOnlyModel]).
     */
    fun isImageOnly(model: AIModel, imageGenRoute: String?): Boolean {
        if (RelayRuntimeSupport.isDedicatedImageModel(model.id)) return true
        if (imageGenRoute != null && imageGenRoute in ChatRepository.DEDICATED_IMAGE_GEN_ROUTES) return true
        return CapabilityEvidenceFacade.isImageOnlyModel(model)
    }

    /** The waveform key is offered for every selected model that can answer in text. */
    fun voiceAvailable(model: AIModel?, providerKind: ProviderKind?): Boolean {
        if (model == null || providerKind == null) return false
        return !isImageOnly(model, imageGenRoute(model.id, providerKind))
    }

    /** imageGen route of the server catalog entry (same lookup as ChatRepository's send path). */
    fun imageGenRoute(modelId: String, providerKind: ProviderKind): String? =
        MetadataClient.imageGenRoute(MetadataClient.resolveCatalogModel(modelId, providerKind)?.profiles?.imageGen)
}

/**
 * Tap guard: after generation stops, the waveform key stays inert for [ComposerVoiceEntry.REARM_MILLIS] so the tap that
 * was meant for ■ does not open the microphone. [clock] is monotonic milliseconds (injectable for tests).
 */
internal class VoiceEntryRearmGuard(private val clock: () -> Long) {
    private var wasGenerating = false
    private var stoppedAt: Long? = null

    fun observe(isGenerating: Boolean) {
        if (wasGenerating && !isGenerating) stoppedAt = clock()
        wasGenerating = isGenerating
    }

    fun accepts(): Boolean {
        val stopped = stoppedAt ?: return true
        return clock() - stopped >= ComposerVoiceEntry.REARM_MILLIS
    }
}
