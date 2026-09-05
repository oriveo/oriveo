package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.data.repository.ConversationRepository
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.ModelControlRejectionCache
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentity
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.core.streaming.ChatStreamingManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

internal fun interface ChatSendLauncher {
    fun launch(
        conversation: Conversation,
        provider: Provider,
        modelId: String,
        text: String,
        existingMessages: List<ChatMessage>,
        attachments: List<Attachment>?,
        persistUserMessage: Boolean,
        appendToAssistant: ChatMessage?,
        userMessageAlreadyInHistory: Boolean,
        quoteContext: QuoteContext?,
    )
}

/** Converts a saved failure descriptor into a one-send latch only on the exact cached runtime. */
internal fun validatedModelControlResendMarker(
    failureCode: String?,
    identity: ModelControlRuntimeIdentity?,
): String? {
    val runtime = identity ?: return null
    val parts = failureCode?.split(':')?.takeIf {
        it.size == 5 && it[0] == "capability_setting_pre_token_400" &&
            it[1] in setOf("custom", "provider_recipe") &&
            it[2] in setOf("web", "reasoning", "generation")
    } ?: return null
    fun decode(value: String): String? = runCatching {
        String(java.util.Base64.getUrlDecoder().decode(value), Charsets.UTF_8)
    }.getOrNull()
    val source = parts[1]
    val owner = parts[2]
    val recipeRef: String? = if (source == "custom") {
        if (parts[3] != "-") return null
        null
    } else {
        parts[3].takeUnless { it == "-" }?.let(::decode)?.takeIf { it.isNotBlank() } ?: return null
    }
    val pointers = decode(parts[4])?.split('\u001f')
        ?.filter { it.startsWith('/') && it.length <= 160 }
        ?.toSet()?.takeIf { it.isNotEmpty() } ?: return null
    val cached = ModelControlRejectionCache.rejectedSettings(runtime, owner, source, recipeRef = recipeRef)
    if (!cached.containsAll(pointers)) return null
    return listOf("omit_capability_setting_once", source, owner, parts[3], parts[4]).joinToString(":")
}

internal class ChatRetryCoordinator(
    private val viewModelScope: CoroutineScope,
    private val conversationRepository: ConversationRepository,
    private val providerRepository: ProviderRepository,
    private val chatStreamingManager: ChatStreamingManager,
    private val currentConversation: () -> Conversation?,
    private val activeProviderId: () -> String?,
    private val activeModelId: () -> String?,
    private val requestPin: () -> Unit,
    private val launchSend: ChatSendLauncher,
    private val onProviderResolutionError: (Throwable) -> Unit = {},
    private val modelControlRuntimeIdentity: (Provider, ai.oriveo.community.core.model.AIModel) -> ModelControlRuntimeIdentity? =
        { provider, model -> ModelControlRuntimeIdentityResolver.resolve(provider, model) },
) {
    /**
     * Retry means "run it again", not "carry on": the previous round's body and every value
     * derived from it are cleared.
     *
     * Keeping the old body has two consequences. New output would be appended after the leftover
     * text, and MessageBubble treats a non-empty displayText as "there is something to show", so
     * the typing indicator never appears and the bubble stays frozen on the previous round (for a
     * failed message, on the error text) until the conversation is reopened.
     *
     * The message id is reused on purpose: createdAt and sort order are looked up by id, so a new
     * id would move the message to the end of the conversation.
     */
    private fun ChatMessage.clearedForRetry(): ChatMessage = copy(
        text = "",
        reasoningText = null,
        reasoningDurationMs = null,
        citations = null,
        attachments = null,
        estimatedCost = 0.0,
        errorTitle = null,
        errorDetail = null,
        inputTokens = null,
        outputTokens = null,
        cachedInputTokens = null,
        cacheCreationInputTokens = null,
        cacheCreation5mTokens = null,
        cacheCreation1hTokens = null,
        costSource = null,
        customRetryWithoutFieldsAvailable = false,
        customRetryWithoutFieldsCode = null,
    )

    /** Model-control CTA is an append resend: generated user-visible content is immutable input. */
    private fun ChatMessage.preparedForModelControlResend(marker: String): ChatMessage = copy(
        errorTitle = null,
        errorDetail = null,
        customRetryWithoutFieldsAvailable = false,
        customRetryWithoutFieldsCode = marker,
    )

    fun regenerateMessage(messageId: String) {
        val conv = currentConversation() ?: return
        val assistantMsg = conv.messages.find { it.id == messageId } ?: return
        val assistantIndex = conv.messages.indexOf(assistantMsg)
        val lastUser = conv.messages.take(assistantIndex).lastOrNull { it.role == ChatRole.User }
            ?: return

        viewModelScope.launch {
            // Resolve the provider before anything destructive happens: bailing out after the
            // delete would throw away answers the user already had.
            val provider = resolveChatProvider(
                providerRepository = providerRepository,
                providerId = activeProviderId(),
                onFailure = onProviderResolutionError,
            ) ?: return@launch

            // The delete covers the assistant message that may still be generating, so the stream
            // has to be stopped and joined first. Otherwise the old stream keeps burning tokens
            // with nobody listening, and its finalize can write the old answer back after the
            // delete. startStream does cancel a same-conversation stream on entry, but that
            // happens after the delete and does not close this window.
            chatStreamingManager.stopStreamAndJoin(conv.id)
            conversationRepository.deleteMessagesAfter(conv.id, lastUser.id)

            val modelId = activeModelId() ?: return@launch
            val runtimeModelId = ProviderSelectionSnapshot.runtimeModelId(provider, modelId) ?: modelId

            requestPin()

            val fullHistoryAfterDelete = fetchFullConversationHistory(conv.id)
            launchSend.launch(
                conversation = conv,
                provider = provider,
                modelId = runtimeModelId,
                text = lastUser.text,
                existingMessages = fullHistoryAfterDelete.dropLast(1),
                attachments = lastUser.attachments,
                quoteContext = lastUser.quoteContext,
                persistUserMessage = false,
                appendToAssistant = null,
                userMessageAlreadyInHistory = false,
            )
        }
    }

    fun retryMessage(messageId: String) {
        val conv = currentConversation() ?: return
        val assistantMsg = conv.messages.find {
            it.id == messageId && it.role == ChatRole.Assistant && it.state == ChatMessageState.Failed
        } ?: run {
            regenerateMessage(messageId)
            return
        }
        val lastUser = conv.messages.take(conv.messages.indexOf(assistantMsg))
            .lastOrNull { it.role == ChatRole.User }
            ?: return

        viewModelScope.launch {
            val provider = resolveChatProvider(
                providerRepository = providerRepository,
                providerId = activeProviderId(),
                onFailure = onProviderResolutionError,
            ) ?: return@launch
            val modelId = activeModelId() ?: return@launch
            val runtimeModelId = ProviderSelectionSnapshot.runtimeModelId(provider, modelId) ?: modelId

            requestPin()

            val retryTarget = assistantMsg.clearedForRetry()
            val fullHistory = fetchFullConversationHistory(conv.id)
            val failedIdx = fullHistory.indexOfFirst { it.id == messageId }
            // The copy in the outbound history is cleared too. An empty assistant message is
            // dropped when the request is assembled, so the model sees context only up to the last
            // user message and does not treat the previous round's failure text as something it
            // already said.
            val messagesThroughFailedAssistant = (
                if (failedIdx >= 0) fullHistory.take(failedIdx + 1) else fullHistory
                ).map { if (it.id == messageId) retryTarget else it }

            launchSend.launch(
                conversation = conv,
                provider = provider,
                modelId = runtimeModelId,
                text = lastUser.text,
                existingMessages = messagesThroughFailedAssistant,
                attachments = lastUser.attachments,
                quoteContext = lastUser.quoteContext,
                persistUserMessage = false,
                appendToAssistant = retryTarget,
                userMessageAlreadyInHistory = true,
            )
        }
    }

    fun continueMessage(messageId: String) {
        val conv = currentConversation() ?: return
        val assistantMsg = conv.messages.find { it.id == messageId && it.role == ChatRole.Assistant }
            ?: return
        // An empty interrupted message has no partial content to continue from, so fall back to
        // regenerating an answer to the original question. Continuing instead would be worse: the
        // empty assistant message is dropped when the request is assembled, which puts the
        // continuation instruction directly next to the preceding user message and the model ends
        // up receiving only the instruction. Same fallback retryMessage uses for a message that is
        // not in the failed state.
        if (assistantMsg.text.isBlank()) {
            regenerateMessage(messageId)
            return
        }

        viewModelScope.launch {
            val provider = resolveChatProvider(
                providerRepository = providerRepository,
                providerId = activeProviderId(),
                onFailure = onProviderResolutionError,
            ) ?: return@launch
            val modelId = activeModelId() ?: return@launch
            val runtimeModelId = ProviderSelectionSnapshot.runtimeModelId(provider, modelId) ?: modelId

            // Continuing only fills in the target assistant message; it never deletes what comes
            // after it. The UI already offers the continue action on the last message of a
            // conversation, and not deleting here is the second line of defence against "stop A,
            // send B, continue A" overwriting B. Stop the in-flight stream first so the
            // continuation does not run concurrently with the old one.
            chatStreamingManager.stopStreamAndJoin(conv.id)
            requestPin()

            // History stops at the target assistant message, so anything after it is not fed in as
            // continuation context.
            val fullHistory = fetchFullConversationHistory(conv.id)
            val assistantIdx = fullHistory.indexOfFirst { it.id == assistantMsg.id }
            val historyThroughAssistant = if (assistantIdx >= 0) {
                fullHistory.take(assistantIdx + 1)
            } else {
                fullHistory
            }
            launchSend.launch(
                conversation = conv,
                provider = provider,
                modelId = runtimeModelId,
                text = "Continue from where you stopped. Do not repeat what you have already said.",
                existingMessages = historyThroughAssistant,
                attachments = null,
                quoteContext = null,
                persistUserMessage = false,
                appendToAssistant = assistantMsg,
                userMessageAlreadyInHistory = false,
            )
        }
    }

    /**
     * Lets the user retry exactly this failed request once without any of their local custom
     * namespaces. It does not modify the stored fragments and never retries on its own.
     */
    fun retryWithoutLocalCustomFields(messageId: String) {
        val conv = currentConversation() ?: return
        val assistantMsg = conv.messages.find {
            it.id == messageId && it.role == ChatRole.Assistant &&
                it.state == ChatMessageState.Failed && it.customRetryWithoutFieldsAvailable &&
                it.customRetryWithoutFieldsCode?.startsWith("capability_setting_pre_token_400:") == true
        } ?: return
        val lastUser = conv.messages.take(conv.messages.indexOf(assistantMsg))
            .lastOrNull { it.role == ChatRole.User } ?: return
        viewModelScope.launch {
            val provider = resolveChatProvider(
                providerRepository = providerRepository,
                providerId = activeProviderId(),
                onFailure = onProviderResolutionError,
            ) ?: return@launch
            val modelId = activeModelId() ?: return@launch
            val runtimeModelId = ProviderSelectionSnapshot.runtimeModelId(provider, modelId) ?: modelId
            val selectedModel = ProviderSelectionSnapshot.selectedModel(provider, runtimeModelId) ?: return@launch
            val resendMarker = validatedModelControlResendMarker(
                assistantMsg.customRetryWithoutFieldsCode,
                modelControlRuntimeIdentity(provider, selectedModel),
            ) ?: return@launch
            requestPin()
            // One request-carried marker only. Unlike ordinary retry this target retains every
            // generated text/reasoning/citation/attachment and ChatRepository appends new output.
            val retryTarget = assistantMsg.preparedForModelControlResend(resendMarker)
            val fullHistory = fetchFullConversationHistory(conv.id)
            val failedIdx = fullHistory.indexOfFirst { it.id == messageId }
            val history = (if (failedIdx >= 0) fullHistory.take(failedIdx + 1) else fullHistory)
                .map { if (it.id == messageId) retryTarget else it }
            launchSend.launch(
                conversation = conv,
                provider = provider,
                modelId = runtimeModelId,
                text = lastUser.text,
                existingMessages = history,
                attachments = lastUser.attachments,
                quoteContext = lastUser.quoteContext,
                persistUserMessage = false,
                appendToAssistant = retryTarget,
                userMessageAlreadyInHistory = true,
            )
        }
    }

    fun editMessageInline(messageId: String): String? {
        val conv = currentConversation() ?: return null
        val editableMessage = editableUserMessageFor(conv, messageId) ?: return null
        val text = editableMessage.text

        viewModelScope.launch {
            // Editing mid-stream does not start a new stream, so nothing else stops the old one.
            // Stop and join first to cut token spend short, and to let the NonCancellable finalize
            // finish writing before the rows are deleted; otherwise finalize puts the deleted
            // answer back.
            chatStreamingManager.stopStreamAndJoin(conv.id)
            conversationRepository.deleteMessagesStartingAt(conv.id, editableMessage.id)
        }
        return text
    }

    private suspend fun fetchFullConversationHistory(conversationId: String): List<ChatMessage> =
        conversationRepository.getWithMessages(conversationId)?.messages.orEmpty()

    private fun editableUserMessageFor(conv: Conversation, messageId: String): ChatMessage? {
        val directMessage = conv.messages.find { it.id == messageId }
        if (directMessage?.role == ChatRole.User) {
            return directMessage
        }

        val assistantIndex = conv.messages.indexOfFirst { it.id == messageId }
        if (assistantIndex < 0) return null
        return conv.messages.take(assistantIndex).lastOrNull { it.role == ChatRole.User }
    }
}
