package ai.oriveo.community.testing

import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.streaming.ChatStreamingManager
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.core.streaming.StreamRequest
import io.mockk.every
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking


internal fun installChatStreamingManagerForwardingStub(
    chatStreamingManager: ChatStreamingManager,
    chatRepository: ChatRepository,
) {
    every { chatStreamingManager.startStream(any()) } answers {
        val req = firstArg<StreamRequest>()
        val outputs = ConversationStreamingOutputs(
            streamingText = MutableStateFlow(""),
            streamingMessageId = MutableStateFlow<String?>(null),
        )
        runBlocking {
            chatRepository.sendMessage(
                conversation = req.conversation,
                text = req.text,
                provider = req.provider,
                modelID = req.modelID,
                existingMessages = req.existingMessages,
                attachments = req.attachments,
                reasoningMode = req.reasoningMode,
                webSearchEnabled = req.webSearchEnabled,
                antiForgetText = req.antiForgetText,
                requestOptions = req.requestOptions,
                retrieval = req.retrieval,
                outputs = outputs,
                persistUserMessage = req.persistUserMessage,
                userMessageAlreadyInHistory = req.userMessageAlreadyInHistory,
                appendToAssistant = req.appendToAssistant,
            )
        }
    }
}
