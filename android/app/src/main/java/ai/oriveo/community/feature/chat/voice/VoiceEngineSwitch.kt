package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.conversation.EndReason
import ai.oriveo.community.core.voice.conversation.VoiceConversationEngine
import kotlinx.coroutines.flow.first

/** The engine a page's model answers with: a realtime model (connection, model); null = a text model (the cascade). */
internal data class VoiceEngineKey(val providerId: String, val modelId: String)

internal fun VoiceEngineSelection.Cloud?.voiceEngineKey(): VoiceEngineKey? =
    this?.let { VoiceEngineKey(it.connectionId, it.model) }

/**
 * E-690: the page's model changed from [previousKey] to [nextKey] while a voice conversation is [active] and the
 * answering engine differs (text ↔ realtime, realtime ↔ another realtime) → end it and enter again. Text ↔ text and
 * an idle page never switch.
 */
internal fun shouldSwitchEngine(previousKey: VoiceEngineKey?, nextKey: VoiceEngineKey?, active: Boolean): Boolean =
    active && previousKey != nextKey

/**
 * Ends [running] (user end) when [shouldSwitchEngine] says so, waits for it to stop and then [reenter]s the page's
 * entry flow, which prepares the new target. Returns whether it switched.
 */
internal suspend fun switchVoiceEngine(
    running: VoiceConversationEngine,
    previousKey: VoiceEngineKey?,
    nextKey: VoiceEngineKey?,
    /** false = a realtime session opened by typing (playback only, E-693): end it, never reenter. */
    capturing: Boolean = true,
    reenter: () -> Unit,
): Boolean {
    if (!shouldSwitchEngine(previousKey, nextKey, running.active.value)) return false
    running.end(EndReason.USER)
    running.active.first { !it }
    // E-690 ②: no microphone, no paid connection the user did not ask for; the next typed sentence opens the new model.
    if (capturing) reenter()
    return true
}

/** The switch notice's model (E-690): the page's display name of its selected model, else the realtime model id. */
internal fun voiceEngineSwitchName(target: VoiceConversationTarget): String? =
    target.modelName?.takeIf { it.isNotBlank() } ?: target.realtimeSelection?.model

/**
 * The model name the chat page hands its voice target (E-690 notice): the model's short name only, never the top bar's
 * " · via Ollama cloud" suffix; no model object yet → the selected model id.
 */
internal fun voiceSwitchModelName(activeModel: AIModel?, activeModelId: String?): String? =
    activeModel?.name ?: activeModelId
