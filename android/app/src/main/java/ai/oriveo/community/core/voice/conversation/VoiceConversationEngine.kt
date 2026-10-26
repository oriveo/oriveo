package ai.oriveo.community.core.voice.conversation

import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * What the voice bar host drives: one voice conversation at a time. The cascade [VoiceConversationController] is
 * the default implementation; every implementation emits the same [VoiceConversationEvent] types.
 */
interface VoiceConversationEngine {
    val statusKey: StateFlow<ConversationStatusKey?>

    /** Orb level 0…1. */
    val level: StateFlow<Float>
    val active: StateFlow<Boolean>
    val events: SharedFlow<VoiceConversationEvent>

    fun start(chat: VoiceConversationChatPort)

    fun tapOrb()

    fun toggleMute()

    /** the screen reader is speaking the status word. */
    fun screenReaderSpeaking(speaking: Boolean)

    fun end(reason: EndReason = EndReason.USER)

    /** The page is going away (navigation): a system end, except that a realtime session keeps its half-spoken draft. */
    fun endLeavingPage() = end(EndReason.SYSTEM)
}
