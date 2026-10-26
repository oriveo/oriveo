package ai.oriveo.community.feature.chat

import ai.oriveo.community.feature.chat.voice.ViewModelVoiceChatPort
import ai.oriveo.community.feature.chat.voice.VoiceConversationTarget

/**
 * The Chat target of realtime voice on this chat page: the context for the opening and the re-plan at turn boundaries
 * comes from [ChatSendCoordinator.realtimeSessionContext];
 * a draft ([conversationId] empty) creates its conversation through [ChatViewModel.createFirstConversation] on the first-send path
 * (onConversationActivated -> flushPendingPinnedNotes), and the opening plan uses [ChatViewModel.plannedFirstConversation].
 * The host only calls here and does not assemble this itself.
 * Kept outside the ViewModel file: ChatViewModelStructureTest locks the logical-line budget of ChatViewModel.kt, and wiring functions do not count against it.
 */
internal fun ChatViewModel.realtimeVoiceTarget(conversationId: String?): VoiceConversationTarget.Chat = VoiceConversationTarget.Chat(
    conversationId = conversationId,
    context = { conversation -> sendCoordinator.realtimeSessionContext(conversation, currentMemoryItems.value) },
    createConversation = ::createFirstConversation,
    newConversation = ::plannedFirstConversation,
) { ViewModelVoiceChatPort.of(this) }
