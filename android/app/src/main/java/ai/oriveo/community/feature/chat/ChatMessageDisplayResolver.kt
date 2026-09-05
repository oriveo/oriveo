package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.provider.ModelDisplayLookup

internal data class ChatMessageDisplayMetadata(
    val providerName: String?,
    val modelName: String?,
)

internal fun resolveMessageDisplayMetadata(
    message: ChatMessage,
    displayLookup: ModelDisplayLookup,
): ChatMessageDisplayMetadata {
    return ChatMessageDisplayMetadata(
        providerName = displayLookup.providerDisplayName(message.providerID)
            ?: message.providerName,
        modelName = displayLookup.modelDisplayName(
            providerId = message.providerID,
            modelId = message.modelID,
            fallback = message.modelName,
        ),
    )
}
