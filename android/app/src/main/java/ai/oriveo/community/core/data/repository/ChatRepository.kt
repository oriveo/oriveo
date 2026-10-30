package ai.oriveo.community.core.data.repository

import ai.oriveo.community.feature.chat.OMIT_LOCAL_FIELDS_ONCE_PREFIX
import ai.oriveo.community.core.attachments.AttachmentHydrator
import ai.oriveo.community.core.context.ContextOverflowClassifier
import ai.oriveo.community.core.context.OverflowFamily
import ai.oriveo.community.core.context.StopFamily
import ai.oriveo.community.core.context.StopReason
import ai.oriveo.community.core.context.StopReasonResolver
import ai.oriveo.community.core.context.StreamEnding
import ai.oriveo.community.core.context.StreamFinish
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.streaming.StreamingImageProcessor
import ai.oriveo.community.core.data.repository.streaming.StreamingTokenBuffer
import ai.oriveo.community.core.data.repository.streaming.failedMessageDetail
import ai.oriveo.community.core.data.repository.streaming.isSubscriptionClientVersionRejection
import ai.oriveo.community.core.error.isTransientNetworkFailure
import ai.oriveo.community.feature.chat.ContextConfirmAttempt
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.CapabilityExecutionCollector
import ai.oriveo.community.core.model.CapabilityExecutionResult
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Citation
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.grok.GrokSubscriptionRuntime
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionError
import ai.oriveo.community.core.provider.openai.OpenAISubscriptionRuntime
import ai.oriveo.community.core.provider.openai.toProviderServiceError
import ai.oriveo.community.core.provider.grok.toProviderServiceError
import ai.oriveo.community.core.model.QuoteContext
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RequestPreferenceResolver
import ai.oriveo.community.core.provider.transport.CitationParser
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.model.ToolCallDelta
import ai.oriveo.community.core.provider.DeliveredCostResolver
import ai.oriveo.community.core.provider.CostSource
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.model.UnhandledToolCall
import ai.oriveo.community.core.provider.NativeToolCallAccumulator
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.emitAll
import ai.oriveo.community.core.provider.ToolCallMemoryStore
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.RelayEndpointResolver
import ai.oriveo.community.core.provider.RelayRuntimeSupport
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.ModelControlRejectionCache
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.model.RelayImageConfig
import ai.oriveo.community.core.model.RelayImageMode
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.search.toCitation
import ai.oriveo.community.core.util.generateUuidString
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

private const val RELAY_IMAGE_ROUTE_UNSUPPORTED_KEY = "relay_image_route_unsupported"
private const val RELAY_IMAGE_CHAT_MODEL_REQUIRED_KEY = "relay_image_chat_model_required"

internal fun canOfferExplicitModelControlResend(
    located: ai.oriveo.community.core.provider.LocatedModelControlRejection,
    receivedUpstreamEvent: Boolean,
    error: Throwable,
): Boolean {
    if (receivedUpstreamEvent) return false
    val upstream = error as? ProviderServiceError.Upstream ?: return false
    return RequestPreferenceResolver.resolveRetry(
        RequestPreferenceResolver.RetryIntent(
            source = located.source,
            status = upstream.statusCode,
            errorClass = "optional_parameter_rejected",
            owner = located.owner,
            locatedPointers = located.locatedPointers,
            preToken = true,
            streamStarted = false,
            sideEffects = false,
            automaticRetryCount = 0,
        ),
    ).action == "user_confirmed_resend_without_located_setting"
}

internal const val LOCAL_FIELDS_RETRY_OFFER_PREFIX = "local_fields_retry_offer:"

/**
 * Decides the "retry without the additional request body / without this custom-fields section" way out and returns the owner to omit.
 *
 * - Web-search or thinking custom fields failed local validation: no request was sent, so offer a way out for that section (not for a local rejection of the additional request body, which has to be fixed and resent).
 * - The request really carried the additional request body, no upstream event had arrived yet and there was no tool side effect, and the failure is an HTTP 400 or an in-stream error frame
 *   that is not classified as quota / rate limit / auth / model unavailable (an `Upstream(200)` carrying the `streamErrorFrame` mark).
 *   An `Upstream(200)` that is not an error frame, such as an empty stream or a blocking fallback, gets no way out.
 *   An error after content has already arrived means the upstream started answering and is not a rejection of the request body, so no way out is offered.
 */
internal fun localFieldsRetryOwner(
    error: Throwable,
    sentAdditionalBody: String?,
    receivedUpstreamEvent: Boolean,
    hadToolSideEffects: Boolean,
): String? {
    if (error is ProviderServiceError.LocalRequestRejected) {
        return error.owner.takeIf { it == "web" || it == "reasoning" }
    }
    if (sentAdditionalBody.isNullOrBlank() || receivedUpstreamEvent || hadToolSideEffects) return null
    val rejectsBody = when (error) {
        is ProviderServiceError.Upstream -> error.statusCode == 400 || (error.statusCode == 200 && error.streamErrorFrame)
        is ProviderServiceError.RelayUpstream -> error.statusCode == 400
        else -> false
    }
    return ai.oriveo.community.core.provider.AdditionalRequestBody.OWNER.takeIf { rejectsBody }
}

/** Title of the error card when the upstream rejected a request that carried the additional request body; the English source string is localized through the ErrorMapper title table. */
internal const val ADDITIONAL_BODY_REJECTED_UPSTREAM_TITLE = "Request with additional request body was rejected"

/** Driven by the same decision as [localFieldsRetryOwner]: the title changes only when the "retry without the additional request body" way out is offered, otherwise it is left as is. */
internal fun localFieldsFailureTitle(title: String?, retryOwner: String?): String? =
    if (retryOwner == ai.oriveo.community.core.provider.AdditionalRequestBody.OWNER) ADDITIONAL_BODY_REJECTED_UPSTREAM_TITLE else title

/**
 * Sends a message and drives the stream that answers it.
 *
 * One send is a fixed sequence:
 * 1. persist the user message,
 * 2. persist an assistant placeholder in the Generating state,
 * 3. open the stream against the user's provider,
 * 4. accumulate tokens in a buffer and publish them to the UI, without a database write per token,
 * 5. on completion, persist the final text, token counts and cost,
 * 6. on failure, persist the error on the message so it can be retried,
 * 7. on cancellation, persist whatever arrived so the partial answer is not lost.
 *
 * Steps 4 and 7 are why the buffer exists: writing every token to the database would make the
 * conversation list rebuild on each one, and losing the buffer on cancellation would throw away
 * text the user already watched appear.
 */
class ChatRepository(
    private val conversationRepository: ConversationRepository,
    private val providerRepository: ProviderRepository,
    private val attachmentStore: AttachmentStore,
    private val continuationStore: ai.oriveo.community.core.provider.MessageContinuationStore? = null,
    private val continuationAccountId: () -> String? = { null },
    private val toolCallMemoryStore: ToolCallMemoryStore? = null,
    /** Entry point that brings remote MCP into the send path; when null (focused tests) a request carries no MCP tools. */
    private val mcpChatToolRunner: ai.oriveo.community.core.mcp.McpChatToolRunner? = null,
    /** Negative cache for upstream rejections on a relay: rejected image input / tools are recorded here, and the read side uses the same one. */
    private val relayNegativeCache: ai.oriveo.community.core.provider.relay.RelayNegativeCache =
        ai.oriveo.community.core.provider.relay.RelayNegativeCache.shared,
    /** Negative cache v2: when a relay records the v1 `image` key, a `vision_input` entry is written alongside (the verdict still follows v1). */
    private val inputNegativeCache: ai.oriveo.community.core.capability.InputNegativeCache =
        ai.oriveo.community.core.capability.InputNegativeCache.shared,
    /** Connection-level web search fragments of a relay: merged under the first-send protocol while the chat web switch is on. */
    private val relayWebFragmentStore: ai.oriveo.community.core.provider.relay.RelayWebFragmentStore =
        ai.oriveo.community.core.provider.relay.RelayWebFragmentStore.shared,
    /** Relay web search probe records: a chat on a protocol recorded as rejected does not attach the fragment; a delivered reply with citations writes an observed record. */
    private val relayWebProbeRecords: ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore =
        ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore.shared,
    /** Relay web reply notices: in memory only, keyed by the assistant message id. */
    private val relayWebReplyNotices: ai.oriveo.community.core.provider.relay.RelayWebReplyNotices =
        ai.oriveo.community.core.provider.relay.RelayWebReplyNotices.shared,
    /** Context ledger: the chat projection reads rho from it (null = a focused test without Room, which uses rho0). */
    private val contextLedgerDao: ai.oriveo.community.core.data.dao.ContextLedgerDao? = null,
    /** Notice channel used when the plan refuses to send (the chat screen subscribes to shared). */
    private val contextRejections: ChatContextRejections = ChatContextRejections.shared,
    /** Compaction: pre-send stored checkpoint and coordinator (null = in-memory fallback only). */
    private val contextCompaction: ContextCompactionCoordinator? = null,
    /** Global default context cap: used when the conversation's contextCap is empty (follows the global setting); a focused test without preferences uses auto. */
    private val contextDefaultCap: suspend () -> ai.oriveo.community.core.context.ContextBudgetCap =
        { ai.oriveo.community.core.context.ContextBudgetCap.Auto },
    /** Pre-send confirmation gate: null = never ask (a focused test without it). */
    private val contextCapConfirm: ai.oriveo.community.core.context.ContextCapConfirmCoordinator? = null,
) {
    /** Stateful continuation fingerprints, recorded by assistant message id at the same moment as previousResponseId; in memory only, and after a process restart they count as changed. */
    private val continuationFingerprints = java.util.concurrent.ConcurrentHashMap<String, ContinuationFingerprint>()

    /**
     * Sends [text] to [provider] and streams the answer back into [outputs].
     *
     * @param existingMessages the conversation so far, used to build the request context
     * @param appendToAssistant an existing assistant message to continue instead of creating one
     */
    suspend fun sendMessage(
        conversation: Conversation,
        text: String,
        provider: Provider,
        modelID: String,
        existingMessages: List<ChatMessage>,
        attachments: List<Attachment>? = null,
        quoteContext: QuoteContext? = null,
        reasoningMode: ReasoningMode = ReasoningMode.Automatic,
        webSearchEnabled: Boolean = false,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        outputs: ConversationStreamingOutputs,
        persistUserMessage: Boolean = true,
        userMessageAlreadyInHistory: Boolean = false,
        appendToAssistant: ChatMessage? = null,
        /** Where this attempt came from (send / edit / retry / regenerate / continue). */
        attemptKind: ContextConfirmAttempt = ContextConfirmAttempt.SEND,
        /** Automatic resend after a context overflow: reuses the same assistant message and the fallback projection; external callers leave it out. */
        overflowRecovery: ChatOverflowRecovery? = null,
        /** Called with the id and text of the user message once it is persisted; null by default, and not called on an overflow resend. */
        onUserMessageCreated: ((messageId: String, text: String) -> Unit)? = null,
        /**
         * Non-null when a new send is in tool mode: [requestOptions].clientTools carries propose_memory. Only the ordinary streaming first leg carries it;
         * calls are reported back one by one and a tail leg is added by the rules; when the first leg's tools are deterministically rejected,
         * the request is resent without tools and the downgrade is reported back.
         */
        memoryPropose: ai.oriveo.community.core.memory.MemoryProposeSendHook? = null,
        /**
         * Non-null when search_memory is in tool mode: [requestOptions].clientTools ends with search_memory;
         * it shares the first-leg / tail-leg / downgrade behavior with propose_memory.
         */
        memorySearch: ai.oriveo.community.core.memory.MemorySearchTurn? = null,
        /**
         * External web search: non-null when route.path is an external path. Wired strictly from planSearchTurn's output:
         * the tool path registers web_search, presearch / reuse go into [D]; on every other path it is null and the outbound request is unchanged.
         */
        externalSearch: ai.oriveo.community.core.search.ExternalSearchSend? = null,
    ) {
        val modelSelection = resolveSendModelSelection(provider, modelID)
        val runtimeModelId = modelSelection.runtimeModelId
        val storedModelId = modelSelection.storedModelId
        val modelName = modelSelection.modelName
        val supportsImageGen = modelSelection.supportsImageGen
        val model = ProviderSelectionSnapshot.selectedModel(provider, modelID)

        // The assistant message is stamped one millisecond after the user message so the pair
        // keeps its order even when both are written inside the same millisecond.
        val userCreatedAt = System.currentTimeMillis()
        val assistantCreatedAt = userCreatedAt + 1

        val userMessage = ChatMessage(
            id = generateUuidString(),
            role = ChatRole.User,
            text = text,
            providerID = provider.id,
            providerKind = provider.kind,
            providerName = provider.displayName,
            modelID = runtimeModelId,
            modelName = modelName,
            state = ChatMessageState.Delivered,
            createdAt = userCreatedAt,
            attachments = attachments,
            quoteContext = quoteContext?.takeIf { it.isValid },
        )
        val rawMessages = if (userMessageAlreadyInHistory) {
            existingMessages
        } else {
            existingMessages + userMessage
        }
        // Main chat path: the system prompt and the history are produced by ContextAssembler (off the main thread). The retry target
        // is not part of the history, the same as providerMessages dropping it below. This runs before persisting: when the plan
        // refuses to send, no request is made and no user / assistant message is persisted.
        // Continue: purpose continue, history cut at the target assistant (inclusive), keepAssistantId = the target;
        // on an overflow resend appendToAssistant is null and the target comes from overflowRecovery.
        val continueTarget = (appendToAssistant ?: overflowRecovery?.assistant)
            ?.takeIf { attemptKind == ContextConfirmAttempt.CONTINUE }
        val rhoTransportKey = ChatContextProjector.rhoTransportKey(provider)
        // The effective tier is evaluated once per send (conversation ?: global); an overflow resend reuses the value of the failed attempt,
        // so every leg of one send sees the same value.
        val budgetCap = overflowRecovery?.budgetCap ?: effectiveBudgetCap(conversation)
        val projectionMessages = when {
            continueTarget != null -> rawMessages
            appendToAssistant != null -> rawMessages.filterNot { it.id == appendToAssistant.id }
            else -> rawMessages
        }
        suspend fun currentRhoHi(): Double = rhoHiFor(provider, runtimeModelId)
        // Only the first send with purpose=chat takes part in compaction (continue / image generation / overflow resend keep the plain projection).
        val compaction = contextCompaction?.takeIf { overflowRecovery == null && continueTarget == null && !supportsImageGen }
        // The stored row applied to this send (the re-projection of the overflow fallback does not carry it). When the coordinator is present,
        // the in-memory fallback is skipped first and compaction is handed to the coordinator.
        // A resend after an overflow compaction carries the row the coordinator just stored: this request reads it and does not fall back in memory
        // by the overflow B again; the tool-loop first leg never reads it.
        var storedCheckpoint: ContextCheckpointRecord? = overflowRecovery?.checkpoint
        var memoryFallback = compaction == null
        val recoveryFallbackB = overflowRecovery?.takeIf { it.checkpoint == null }
            ?.projection?.plan?.budget?.let { budget -> budget.B ?: budget.estimatedInput }
        // The external search segment this turn hands to [D] (deliver.content of a presearch / reuse); every re-projection carries it, right after <oriveo-library>.
        var injectedWebSegment: String? = null
        suspend fun projectChat(
            overflowFallbackB: Int?,
            toolSafety: String? = null,
            // search_memory results are appended after the automatic recall (the same <oriveo-recall>, the same recallMax cut).
            extraRecall: List<ai.oriveo.community.core.context.ContextRecallEntry> = emptyList(),
        ): ChatContextProjection? = (
            // Without a chatContext (unreachable in production, ChatSendCoordinator always supplies one) the same assembler runs on an empty context:
            // no skill / instructions / memory / notes, history as usual; it never falls back to assembling the old options.systemPrompt.
            requestOptions.chatContext
                ?: ai.oriveo.community.core.context.ChatContextRequest(
                    conversation = ai.oriveo.community.core.context.ContextConversation(
                        id = conversation.id,
                        useMemory = false,
                        instructions = conversation.instructions,
                    ),
                )
            ).let { base ->
            val chatContext = if (extraRecall.isEmpty()) base else base.copy(recall = base.recall + extraRecall)
            val rhoHi = currentRhoHi()
            withContext(Dispatchers.IO) {
                ChatContextProjector.project(
                    request = chatContext,
                    rawMessages = projectionMessages,
                    window = ChatContextProjector.window(provider, model ?: requestOptions.activeModel, requestOptions, budgetCap),
                    rhoHi = rhoHi,
                    overflowFallbackB = overflowFallbackB,
                    web = injectedWebSegment,
                    purpose = if (toolSafety != null) {
                        ai.oriveo.community.core.context.RequestPurpose.TOOL_LOOP_LEG
                    } else if (continueTarget != null) {
                        ai.oriveo.community.core.context.RequestPurpose.CONTINUE
                    } else {
                        ai.oriveo.community.core.context.RequestPurpose.CHAT
                    },
                    keepAssistantId = continueTarget?.id,
                    recordExcludeId = appendToAssistant?.id,
                    toolSafety = toolSafety,
                    // The stored row is applied only to projections with purpose=chat; the tool-loop first leg does not read it (it uses the in-memory fallback when required).
                    checkpoint = storedCheckpoint.takeIf { overflowFallbackB == null && toolSafety == null },
                    memoryFallback = memoryFallback || toolSafety != null,
                    // An overflow re-projection does not apply the stored row (checkpoint is null), but the fallback still carries its old summary.
                    oldSummary = storedCheckpoint?.summary?.takeIf { it.isNotBlank() },
                )
            }
        }
        // Before sending, project with the stored row only (to decide refusal); when it is still required, compaction moves to after the user message and the assistant placeholder are persisted.
        val compactionHistory = compaction?.let { ChatContextProjector.compactionHistory(projectionMessages, currentRhoHi()) }
        val firstProjection = overflowRecovery?.projection
            ?: compaction?.let { coordinator ->
                storedProjection(coordinator, conversation.id,
                    history = compactionHistory.orEmpty(),
                    useStored = { storedCheckpoint = it },
                    project = { fallback -> memoryFallback = fallback; projectChat(overflowFallbackB = null) },
                )
            }
            ?: projectChat(overflowFallbackB = null)
        firstProjection?.reject?.let { reject ->
            contextRejections.emit(
                ChatContextRejection(
                    conversationId = conversation.id,
                    reject = reject,
                    text = text,
                    attachments = attachments,
                    quoteContext = quoteContext?.takeIf { it.isValid },
                    restoresComposer = persistUserMessage && !userMessageAlreadyInHistory,
                ),
            )
            return
        }
        // Reuse: the external sources already persisted on the answer being regenerated (a retry reuses the assistant slot; a regenerate takes the answer after the last user message, before it is deleted).
        val previousSearchCitations: List<Citation> = if (externalSearch == null) {
            emptyList()
        } else {
            (
                appendToAssistant?.citations ?: if (
                    overflowRecovery == null && attemptKind == ContextConfirmAttempt.REGENERATE && userMessageAlreadyInHistory
                ) {
                    existingMessages.lastOrNull()?.takeIf { it.role == ChatRole.User }?.let { lastUser ->
                        conversationRepository.getWithMessages(conversation.id)?.messages.orEmpty()
                            .dropWhile { it.id != lastUser.id }.drop(1)
                            .lastOrNull { it.role == ChatRole.Assistant }?.citations
                    }
                } else {
                    null
                }
                ).orEmpty().filter { it.source == ai.oriveo.community.core.search.EXTERNAL_SEARCH_SOURCE }
        }
        // Regenerate: the old answer (the messages after the last user message) is deleted only once the refusal check has passed; on a refusal it stays untouched.
        if (overflowRecovery == null && attemptKind == ContextConfirmAttempt.REGENERATE && userMessageAlreadyInHistory) {
            existingMessages.lastOrNull()?.takeIf { it.role == ChatRole.User }?.let { lastUser ->
                conversationRepository.deleteMessagesAfter(conversation.id, lastUser.id)
            }
        }
        // Regenerate reuses the kept last user message and does not persist a second identical user message (it only serves as request context).
        if (persistUserMessage) {
            conversationRepository.addMessage(conversation.id, userMessage)
            if (overflowRecovery == null) onUserMessageCreated?.invoke(userMessage.id, text)
        }

        val preservesGeneratedContent = appendToAssistant?.customRetryWithoutFieldsCode
            ?.let {
                it.startsWith("omit_capability_setting_once:") || it.startsWith(OMIT_LOCAL_FIELDS_ONCE_PREFIX) ||
                    it.startsWith(ai.oriveo.community.feature.chat.OMIT_PARAMETER_ONCE_PREFIX)
            } == true

        val assistantMessageId: String
        val assistantPlaceholder: ChatMessage
        val initialText: String
        if (overflowRecovery != null) {
            // Overflow resend: the same assistant message (already persisted, still Generating); it is not created again and the user message is not persisted twice.
            assistantMessageId = overflowRecovery.assistant.id
            assistantPlaceholder = overflowRecovery.assistant
            // A resend of a continue still appends after the target's original text; for every other entry the assistant slot is empty at this point.
            initialText = if (attemptKind == ContextConfirmAttempt.CONTINUE) overflowRecovery.assistant.text else ""
        } else if (appendToAssistant != null) {
            assistantMessageId = appendToAssistant.id
            assistantPlaceholder = appendToAssistant.copy(
                providerID = provider.id,
                providerKind = provider.kind,
                providerName = provider.displayName,
                modelID = runtimeModelId,
                modelName = modelName,
                servedModelID = null,
                state = ChatMessageState.Generating,
                errorTitle = null,
                errorDetail = null,
                customRetryWithoutFieldsAvailable = false,
                customRetryWithoutFieldsCode = null,
                citations = appendToAssistant.citations,
                // A continue keeps the memory items already injected into the original answer; a regenerate clears the old value (overwritten at completion from this send's plan).
                memoryItemIds = appendToAssistant.memoryItemIds.takeIf { continueTarget != null },
            )
            initialText = appendToAssistant.text
            conversationRepository.updateMessage(conversation.id, assistantPlaceholder)
        } else {
            assistantMessageId = generateUuidString()
            assistantPlaceholder = ChatMessage(
                id = assistantMessageId,
                role = ChatRole.Assistant,
                text = "",
                providerID = provider.id,
                providerKind = provider.kind,
                providerName = provider.displayName,
                modelID = runtimeModelId,
                modelName = modelName,
                state = ChatMessageState.Generating,
                createdAt = assistantCreatedAt,
            )
            initialText = ""
            conversationRepository.addMessage(conversation.id, assistantPlaceholder)
        }

        // Compaction runs only after the user message is visible in the database; a compaction error counts as noop and falls back to the in-memory fallback, and never blocks sending.
        val chatProjection = if (compaction != null && firstProjection != null && !memoryFallback && overflowRecovery == null) {
            try {
                compactedProjection(compaction, conversation.id, firstProjection, provider, model ?: requestOptions.activeModel,
                    runtimeModelId,
                    history = compactionHistory.orEmpty(),
                    rhoHi = currentRhoHi(),
                    useStored = { storedCheckpoint = it },
                    project = { fallback -> memoryFallback = fallback; projectChat(overflowFallbackB = null) },
                )
            } catch (e: CancellationException) {
                // Stopping during compaction counts as stopping before the first token: the placeholder is finalized the same way, leaving no empty "generating" message.
                finalizeStoppedBeforeOutput(conversation.id, assistantPlaceholder, initialText, outputs, e)
                throw e
            }
        } else {
            firstProjection
        }

        // The confirmation gate: after compaction and before the transport, suspend on the decision; only the first leg of a send / edit asks,
        // an overflow resend and tool legs never pass through. Cancelling (including tapping stop while waiting) rolls back: only this pair of messages
        // on the device is deleted and the composer is refilled; nothing is recorded as stopped or failed.
        val confirmAttempt = if (overflowRecovery != null) {
            ContextConfirmAttempt.OVERFLOW_RECOVERY
        } else {
            attemptKind
        }
        val confirmGate = contextCapConfirm?.takeIf {
            confirmAttempt == ContextConfirmAttempt.SEND ||
                confirmAttempt == ContextConfirmAttempt.EDIT
        }
        val gateEstimatedInput = chatProjection?.plan?.budget?.estimatedInput
        if (confirmGate != null && gateEstimatedInput != null) {
            val gateModel = model ?: requestOptions.activeModel
            val rollBack = suspend {
                rollBackUnconfirmedSend(
                    conversationId = conversation.id,
                    // Delete only what this send just wrote: the persisted user message and the newly created assistant slot; a newer send in the same conversation that replaced it is not affected.
                    messageIds = listOfNotNull(
                        userMessage.id.takeIf { persistUserMessage },
                        assistantMessageId.takeIf { appendToAssistant == null },
                    ),
                    rejection = ChatContextRejection(
                        conversationId = conversation.id,
                        reject = null,
                        text = text,
                        attachments = attachments,
                        quoteContext = quoteContext?.takeIf { it.isValid },
                        restoresComposer = persistUserMessage && !userMessageAlreadyInHistory,
                        rolledBack = true,
                        userMessageId = userMessage.id.takeIf { persistUserMessage },
                    ),
                )
            }
            val proceed = confirmContextCapOrRollBack(
                confirmGate,
                ai.oriveo.community.core.context.ContextCapConfirmRequest(
                    conversationId = conversation.id,
                    messageId = assistantMessageId,
                    attempt = confirmAttempt,
                    model = runtimeModelId,
                    modelName = ai.oriveo.community.feature.chat.ContextCapConfirmPresentation
                        .modelDisplayName(gateModel, runtimeModelId),
                    providerKind = provider.kind,
                    estimatedInput = gateEstimatedInput,
                    B = chatProjection.windowBudget?.B,
                    limitedBy = chatProjection.windowBudget?.limitedBy,
                    priceLineTokens = ChatContextProjector.window(provider, gateModel, requestOptions, budgetCap).priceLineTokens,
                ),
                rollBack,
            )
            if (!proceed) return
        }

        // Start streaming (on a continue, both the display and the accumulation start from the original text)
        outputs.streamingMessageId.value = assistantMessageId
        outputs.streamingText.value = initialText
        val initialReasoning = appendToAssistant?.reasoningText.orEmpty().takeIf { preservesGeneratedContent }.orEmpty()
        outputs.streamingReasoning.value = initialReasoning

        // The buffer is seeded with whatever the message already had so that continuing an
        // interrupted answer appends to it instead of restarting from an empty string.
        val tokenBuffer = StreamingTokenBuffer(initialText, initialReasoning)
        val imageProcessor = StreamingImageProcessor(attachmentStore)

        var accumulatedCitations: List<Citation> = appendToAssistant?.citations.orEmpty()
            .takeIf { preservesGeneratedContent }.orEmpty()
        // Whether the upstream parser produced non-empty citations this round (used to record relay web search passively; local citations such as library retrieval are excluded).
        var relayWebCitationSeen = false
        // Structured provider tool calls must survive even when this connection has no executor.
        // Accumulate the native stream fields and surface them as a local-only message card.
        val nativeToolCallDeltas = mutableMapOf<Int, ToolCallDelta>()
        // Proposals from the tool loop that matched no registered tool. Collected apart from
        // nativeToolCallDeltas: that table is keyed by the index inside one stream, and every leg
        // of the loop numbers from 0 again, so mixing them would concatenate arguments.
        val loopUnhandledToolCalls = mutableListOf<UnhandledToolCall>()
        // The remote MCP tool steps. A continued answer keeps the steps already on the message;
        // a retry cleared them on entry.
        var mcpToolSteps: List<ai.oriveo.community.core.mcp.McpToolStep> = assistantPlaceholder.toolSteps.orEmpty()
        // One status callback from the executor becomes the summary on the message plus the
        // per-step payload stored next to it. The loop runs the tools of a leg serially, so the
        // callbacks never overlap.
        val recordMcpToolStep: suspend (ai.oriveo.community.core.mcp.McpToolStepUpdate) -> Unit = { update ->
            mcpToolSteps = ai.oriveo.community.core.mcp.McpToolStep.merging(update, mcpToolSteps)
            conversationRepository.updateMcpToolStepsProgress(assistantMessageId, mcpToolSteps)
            // The activity status line: set as soon as a step is running and cleared when it leaves
            // that state. A step waiting for the user's confirmation is still running, so it stays
            // set. The UI reads what to display (server name and tool title) from toolSteps.
            outputs.streamingActivity.value = if (update.status == ai.oriveo.community.core.mcp.McpToolStepUpdate.Status.Running) {
                ai.oriveo.community.core.model.StreamActivity.McpTool
            } else {
                null
            }
            mcpChatToolRunner?.saveStepPayload(assistantMessageId, update)
        }

        // Large attachment content is persisted only as a localImageId / rawContentRef reference (see AttachmentProcessor), which avoids
        // SQLiteBlobTooBigException. Before the request goes to the provider the base64 is filled back from AttachmentStore on demand,
        // covering the new attachments of this turn and older image / video / file attachments in the history (multi-turn conversations).
        suspend fun hydratedOutbound(projected: List<ChatMessage>): List<ChatMessage> = withContext(Dispatchers.IO) {
            // Sanitizing, quoting, the attachment budget and the pre-send check share [OutboundHistory].
            // Attachment bytes are loaded on IO and capped before hydration, so a conversation
            // with several large files cannot build a request too big to send.
            val budgeted = OutboundHistory.budgetProjected(
                messages = projected,
                imageSizeOf = { localImageId -> attachmentStore.imageSizeBytes(localImageId) },
                blobSizeOf = { ref -> attachmentStore.blobSizeBytes(ref) },
            )
            AttachmentHydrator.hydrate(
                messages = budgeted,
                loadImageBase64 = { localImageId -> attachmentStore.loadBase64(localImageId) },
                loadBlobBase64 = { ref -> attachmentStore.loadBlobBase64(ref) },
            )
        }
        // Without a projection (the plan yields nothing) the outbound list is empty and the send takes the failure path inside the try; it never falls back to the old assembly.
        val allMessages = hydratedOutbound(chatProjection?.messages.orEmpty())
        val service by lazy { providerRepository.serviceFor(provider, model ?: requestOptions.activeModel) }
        val capabilityExecutionCollector = CapabilityExecutionCollector(
            onDispatched = { requested ->
                // This is called only after the final service has prepared the real request and is
                // about to execute it. Display a requested fact during generation; terminal results
                // later replace it with observed or unconfirmed.
                conversationRepository.updateMessage(
                    conversation.id,
                    // A whole-row write: carry the MCP steps recorded so far, or every outgoing leg
                    // of the tool loop would reset the steps column to the placeholder's value.
                    assistantPlaceholder.copy(
                        capabilityExecutionResults = requested,
                        toolSteps = mcpToolSteps.takeIf { it.isNotEmpty() } ?: assistantPlaceholder.toolSteps,
                    ),
                )
            },
            onWebSearchDispatched = {},
        )
        var effectiveApiKey = ProviderCredentialResolver.apiKey(provider, runtimeModelId)
        // This message has already switched protocol: later failures report the second error, record no negative cache and show no image hint card.
        val relayProtocolSwitchStarted = java.util.concurrent.atomic.AtomicBoolean(false)
        // This message carried native file blocks, was rejected, and the fallback did not save it: on failure the file-rejected marker is set; a successful fallback or protocol switch never reaches failure.
        val relayFileRejected = java.util.concurrent.atomic.AtomicBoolean(false)
        // First-send protocol: an unverified Claude family on an auto connection sends Messages first, everything else = the effective protocol; the negative-cache key and the advanced page read the same one.
        val relayFirstSend = (model ?: requestOptions.activeModel)?.takeIf { provider.kind == ProviderKind.Relay }?.let { routeModel ->
            ai.oriveo.community.core.provider.relay.RelayFirstSendTransport.forSend(provider, routeModel, allMessages)
        }
        // The web fragments to carry this round, per protocol (key = protocol value): the first send and each protocol fallback within the same send each take the fragment of the protocol being tried.
        var relayWebFragmentsForSend: Map<String, kotlinx.serialization.json.JsonObject> = emptyMap()
        // The web switch is on (and the user has not overridden it off in the advanced page): if the delivered attempt carried no fragment, a reply notice is attached.
        var relayWebSwitchOn = false
        var relayWebSentTransport: RelayTransport? = null
        // The protocol of the delivered attempt: the first-send protocol, or the target protocol after a switch; also the protocol whose resend without the fragment succeeded.
        val relayDeliveredTransport = java.util.concurrent.atomic.AtomicReference<RelayTransport?>(null)
        val relayWebDroppedTransport = java.util.concurrent.atomic.AtomicReference<RelayTransport?>(null)
        var effectiveRequestOptions = if (provider.kind == ProviderKind.Relay) {
            // Protocol and root are resolved for this model (a model-level protocol wins); RelayService runs the safe-mode check again before sending.
            val routeModel = model ?: requestOptions.activeModel
            val transport = relayFirstSend ?: RelayEndpointResolver.effectiveTransport(provider, routeModel)
            // Web search = the chat switch: when on and not overridden off by the user, every protocol that may be tried gets its own fragment (stored ?? template);
            // a protocol whose current record is rejected (and not overridden on by the user) carries none; when the switch is off, none at all.
            val webOn = webSearchEnabled
            relayWebFragmentsForSend = routeModel?.let {
                ai.oriveo.community.core.provider.relay.RelayWebChat.fragmentsForSend(provider, it, webOn, relayWebFragmentStore, relayWebProbeRecords)
            }.orEmpty()
            relayWebSwitchOn = webOn && routeModel?.let {
                ai.oriveo.community.core.provider.relay.RelayWebChat.of(provider, it, relayWebFragmentStore, relayWebProbeRecords, transport)
            }?.userDisabled == false
            val sendableFragments = relayWebFragmentsForSend
            relayWebSentTransport = transport
            relayDeliveredTransport.set(transport)
            // When the first send changed the protocol, the root is taken for the first-send protocol (the same way as a protocol-fallback switch).
            val rootModel = routeModel?.takeIf { transport != RelayEndpointResolver.effectiveTransport(provider, it) }
                ?.copy(relayTransport = transport) ?: routeModel
            requestOptions.copy(
                // Service-level pricing and request construction match the catalog by the canonicalModelId this model already inherited.
                activeModel = routeModel,
                relayRequested = provider.relayRequested,
                relayImage = provider.relayImage,
                relayWebFragments = sendableFragments,
                relayRouteTransport = transport,
                relayRouteAPIRoot = RelayEndpointResolver.effectiveAPIRoot(provider, rootModel),
                capabilityExecutionCollector = capabilityExecutionCollector,
                relayProtocolSwitched = model?.let { sent ->
                    val sentTransport = RelayEndpointResolver.effectiveTransport(provider, sent)
                    val switched: suspend (RelayTransport) -> Unit = { next ->
                        recordRelayProtocolFallback(provider, sent, sentTransport, next)
                    }
                    switched
                },
                relayProtocolSwitchStarted = { next ->
                    relayProtocolSwitchStarted.set(true)
                    relayDeliveredTransport.set(next)
                },
                relayWebFragmentDropped = { dropped -> relayWebDroppedTransport.set(dropped) },
                relayFileRejected = { relayFileRejected.set(true) },
            )
        } else {
            requestOptions.copy(capabilityExecutionCollector = capabilityExecutionCollector)
        }.let { options ->
            // The system prompt and [D] are written only by the plan's transportInput (no system prompt is sent when plan.system is empty).
            // The max_tokens base is plan.budget.oWire; it only affects services that already send an output cap field.
            chatProjection?.let { projection ->
                projection.planned.transportInput(options.copy(outputTokenBudget = projection.plan.budget.oWire)).options
            } ?: options
        }
        // Client tools ride only on the ordinary streaming first leg (added back below as needed); image generation, non-streaming, tool loops and overflow resends never carry them.
        // search_memory follows the same rule as propose_memory and sits in the same group of client tools (propose first, then search).
        val proposeTools = if (memoryPropose != null || memorySearch != null) effectiveRequestOptions.clientTools else emptyList()
        effectiveRequestOptions = effectiveRequestOptions.copy(clientTools = emptyList())
        // This is evaluated from the frozen request carrier, never from the store after a failure:
        // a settings edit while an HTTP call is in flight must not manufacture a retry affordance.
        val sentCustomFragments = effectiveRequestOptions.localCustomFragments.ifEmpty {
            effectiveRequestOptions.localCustomFragment?.let {
                mapOf(effectiveRequestOptions.localCustomOwner to it)
            }.orEmpty()
        }
        var receivedUpstreamEvent = false
        // Whether this attempt has received any text / reasoning / image delta (old text already present on a continue does not count).
        var receivedOutputDelta = false
        // The finish info the stream delivered when it ended with an empty body (EmptyResponse); an in-stream window overflow takes the overflow recovery based on it.
        var emptyStreamFinish: StreamFinish? = null

        val effectiveReasoning = reasoningMode
        // A relay's "web search this round" = the first send actually merged the effective fragment: false when the switch is on but the user overrode it off,
        // or the current record is rejected; protocol fallback and the resend without the fragment are rewritten by the outbound layer per attempt.
        val effectiveWebSearchEnabled = if (provider.kind == ProviderKind.Relay) {
            relayWebSentTransport?.let { relayWebFragmentsForSend[it.value] } != null
        } else {
            shouldEnableWebSearchForSend(
                provider = provider,
                requested = webSearchEnabled,
                model = model ?: requestOptions.activeModel,
            )
        }
        var providerMessages = if (appendToAssistant != null && continueTarget == null) {
            // The target UI partial is presentation state, not protocol continuation state.
            // Services insert the opaque sidecar block before the new user turn.
            // A continue keeps the target here (contract A item 1); only a replay-kind sidecar drops it below.
            allMessages.filterNot { it.id == appendToAssistant.id }
        } else {
            allMessages
        }

        var relayUpstreamModelId = runtimeModelId
        var relayUseImagesEndpoint = false
        // A route configuration error is not thrown here: the assistant placeholder is already persisted, so throwing would
        // bypass the failure handling of the try below. Remember it and throw it as the first thing inside the try, so the
        // assistant message is persisted as failed and the error card renders from the localized key.
        var relayImageRouteError: ProviderServiceError? = null
        val relayTransport = RelayEndpointResolver.effectiveTransport(provider, model ?: requestOptions.activeModel)
        if (provider.kind == ProviderKind.Relay && supportsImageGen) {
            when (RelayRuntimeSupport.imageRoute(relayTransport)) {
                RelayRuntimeSupport.ImageRoute.Unsupported ->
                    relayImageRouteError = ProviderServiceError.InvalidConfiguration(
                        RELAY_IMAGE_ROUTE_UNSUPPORTED_KEY,
                    )

                RelayRuntimeSupport.ImageRoute.ImagesEndpoint -> relayUseImagesEndpoint = true

                RelayRuntimeSupport.ImageRoute.InlineResponsesTool -> {
                    when (
                        val driver = RelayRuntimeSupport.pickChatDriverModelID(provider, runtimeModelId)
                    ) {
                        is RelayRuntimeSupport.PickChatDriverResult.Success -> {
                            relayUpstreamModelId = driver.modelID
                            if (driver.modelID != runtimeModelId) {
                                effectiveRequestOptions = effectiveRequestOptions.copy(
                                    relayImage = RelayImageConfig(
                                        enabled = true,
                                        mode = RelayImageMode.ToolModel,
                                        toolModelID = runtimeModelId,
                                    ),
                                )
                            }
                        }

                        RelayRuntimeSupport.PickChatDriverResult.MissingChatDriverModel ->
                            relayImageRouteError = ProviderServiceError.InvalidConfiguration(
                                RELAY_IMAGE_CHAT_MODEL_REQUIRED_KEY,
                            )
                    }
                }

                RelayRuntimeSupport.ImageRoute.GeminiModality -> Unit
            }
        }
        // Relay image generation (the images endpoint and the image route that goes through chat): the image prompt uses the user's original text, without the [D] dynamic block or a checkpoint.
        // After swapping back to the original text this outbound request carries no [D], and the transport's dynamicText is cleared with it (same as iOS).
        val relayImageRawPrompt = provider.kind == ProviderKind.Relay && supportsImageGen && chatProjection != null
        if (relayImageRawPrompt) {
            val lastUserIndex = providerMessages.indexOfLast { it.role == ChatRole.User }
            if (lastUserIndex >= 0) {
                providerMessages = providerMessages.toMutableList().also {
                    it[lastUserIndex] = it[lastUserIndex].copy(text = text)
                }
            }
        }

        // Image generation request (purpose imageGeneration): a single user message = plan.imagePrompt + the attachments of the last user message (already backfilled),
        // with no system prompt and no [D] / checkpoint; the empty system prompt is left to the outbound layer, which does not send it.
        fun imageGenerationRequest(options: ChatRequestOptions): TransportInput {
            val planned = ChatContextProjector.projectPurpose(
                purpose = ai.oriveo.community.core.context.RequestPurpose.IMAGE_GENERATION,
                messages = rawMessages.filterNot { it.id == appendToAssistant?.id },
                window = ChatContextProjector.window(provider, model ?: requestOptions.activeModel, requestOptions, budgetCap),
                instructions = conversation.instructions,
            )
            val attachments = providerMessages.lastOrNull { it.role == ChatRole.User }?.attachments
            return planned.transportInput(
                options = options,
                outbound = planned.messages.map { it.copy(attachments = attachments) },
            )
        }

        val streamingAttachments = appendToAssistant?.attachments.orEmpty()
            .takeIf { preservesGeneratedContent }.orEmpty().toMutableList()
        val useNonStreamingRelayRuntime =
            provider.kind == ProviderKind.Relay &&
                effectiveRequestOptions.relayRequested?.stream == false &&

                !relayForcesStream(provider, model, relayTransport)

        // When this send has an MCP / tool-loop leg, neither the rho sample nor the overflow miss is recorded (only a single-leg chat counts).
        var rhoMultiLeg = false
        // Projection of the tool-loop first leg (later legs reuse its system prompt); memoryItemIds is taken from its plan.
        var toolLoopProjection: ChatContextProjection? = null
        // Re-projection carrying search_memory entries when a thinking model's empty-body answer is resent; memoryItemIds is taken from its plan.
        var searchRetryProjection: ChatContextProjection? = null
        // The ordinary streaming first leg ran a search but the results never reached a tail leg (no tail leg / thinking branch): the returned ids are not merged into memoryIds.
        var searchResultsUnsent = false
        // Re-projection carrying this turn's external search segment in [D]; when set, the outbound request and the bookkeeping use it instead of the first projection.
        var webProjection: ChatContextProjection? = null
        // External search driver of this reply (tool path / presearch / reuse); finalizing, stopping and failing all take sources, facts and the error card from it.
        var searchRunner: ai.oriveo.community.core.search.SearchReplyRunner? = null

        /** When the reply ends, write the external search outcome onto the assistant message (sources in the same list as other citations, message facts, error card, notice). */
        fun ChatMessage.withSearchReply(stopped: Boolean): ChatMessage {
            val runner = searchRunner ?: return this
            if (stopped) runner.stopped()
            val finish = runner.finish()
            val searchCitations = finish.citations.map { it.toCitation() }
            val merged = citations.orEmpty().filterNot { c ->
                c.source == ai.oriveo.community.core.search.EXTERNAL_SEARCH_SOURCE && searchCitations.any { it.url == c.url }
            } + searchCitations
            val fact = finish.facts.source?.let { source ->
                CapabilityExecutionResult(owner = "web", state = finish.facts.state, source = source)
            }
            return copy(
                citations = merged.takeIf { it.isNotEmpty() },
                capabilityExecutionResults = capabilityExecutionResults.filterNot {
                    it.source == ai.oriveo.community.core.search.EXTERNAL_SEARCH_SOURCE
                } + listOfNotNull(fact),
                searchErrorCard = finish.errorCard?.let { card ->
                    ai.oriveo.community.core.model.SearchMessageErrorCard(
                        errorClass = card.errorClass,
                        headline = card.headline,
                        primaryAction = card.primaryAction,
                        secondaryAction = card.secondaryAction,
                        serviceName = card.serviceName,
                        serviceId = runner.state.service.id,
                        switchTo = card.switchTo?.let { ai.oriveo.community.core.model.SearchMessageSwitchTarget(it.id, it.name) },
                    )
                },
                searchNotice = finish.notice,
                searchSourcesLine = finish.sourcesLine?.let { line ->
                    ai.oriveo.community.core.model.SearchMessageSourcesLine(line.searchCount, line.serviceName, line.sourceCount, line.reused, line.custom)
                },
            )
        }
        try {
            relayImageRouteError?.let { throw it }
            // The main chat path sends only the plan: if the assembler yields no messages (the last outbound message is not this turn's user message) it counts as a send failure.
            val sendProjection = checkNotNull(chatProjection) { "chat request has no context plan" }
            withContext(Dispatchers.IO) {

                if (provider.kind == ProviderKind.Grok &&
                    provider.authMode == ProviderAuthMode.Subscription
                ) {
                    when (val prepared = providerRepository.prepareGrokSubscription(provider.id)) {
                        is GrokSubscriptionRuntime.PrepareResult.Success -> {
                            effectiveApiKey = prepared.prepared.accessToken
                            val activeSubscriptionModel = model ?: effectiveRequestOptions.activeModel
                            val finalTransport = activeSubscriptionModel?.let {
                                CapabilityControlResolution.subscriptionFinalTransport(provider, it)
                            } ?: ai.oriveo.community.core.provider.transport.TransportKind.OpenAIResponses.wireValue
                            effectiveRequestOptions = effectiveRequestOptions.copy(
                                grokSubscription = prepared.prepared.context.withTransport(finalTransport),

                                activeModel = activeSubscriptionModel,
                            )
                        }
                        is GrokSubscriptionRuntime.PrepareResult.Failure -> {

                            if (prepared.error.requiresConfigRefresh) {

                                runCatching { MetadataClient.refresh() }
                            }
                            throw prepared.error.toProviderServiceError()
                        }
                    }
                }

                if (provider.kind == ProviderKind.OpenAI &&
                    provider.authMode == ProviderAuthMode.Subscription
                ) {
                    when (val prepared = providerRepository.prepareOpenAISubscription(provider.id)) {
                        is OpenAISubscriptionRuntime.PrepareResult.Success -> {
                            effectiveApiKey = prepared.prepared.accessToken
                            effectiveRequestOptions = effectiveRequestOptions.copy(
                                openAISubscription = prepared.prepared.context,
                                activeModel = model ?: effectiveRequestOptions.activeModel,
                            )
                        }
                        is OpenAISubscriptionRuntime.PrepareResult.Failure -> {
                            if (prepared.error is OpenAISubscriptionError.ClientVersionRejected) {

                                runCatching { MetadataClient.refresh() }
                            }
                            throw prepared.error.toProviderServiceError()
                        }
                    }
                }
                var finalResult: ProviderChatResult? = null
                // The stream finish carried by a streaming Done (stored as stopReason); non-streaming / tool-loop endings have none and are recorded as unknown
                var streamFinish: StreamFinish? = null
                var loadedContinuation: ai.oriveo.community.core.provider.MessageContinuationStore.Loaded? = null
                var producedContinuationThisRound = false
                var localToolFallbackNotice: String? = null
                val localCapabilityExecutionResults = mutableListOf<CapabilityExecutionResult>()

                /**
                 * Providers re-send the whole citation list on every update rather than appending,
                 * so the incoming batch is merged by identity instead of concatenated.
                 */
                fun mergeIncomingCitations(incoming: List<Citation>): List<Citation> =
                    CitationParser.mergeCitations(
                        existing = accumulatedCitations,
                        incoming = incoming,
                    )

                /**
                 * The external search segment (deliver.content of a presearch / reuse) goes verbatim into this turn's [D], right after <oriveo-library>,
                 * through the same re-projection path as every other [D] input; a refusal counts as a send failure.
                 */
                suspend fun injectWebSegment(content: String) {
                    val lastUserIndex = providerMessages.indexOfLast { it.role == ChatRole.User }
                    if (lastUserIndex < 0) return
                    injectedWebSegment = content
                    val reprojected = projectChat(overflowFallbackB = recoveryFallbackB)
                    reprojected?.reject?.let { throw ContextRejectedError(it) }
                    val currentText = checkNotNull(
                        reprojected?.messages?.lastOrNull()?.takeIf { it.role == ChatRole.User }?.text,
                    ) { "web search delivery has no context plan" }
                    webProjection = reprojected
                    providerMessages = providerMessages.toMutableList().also {
                        it[lastUserIndex] = it[lastUserIndex].copy(text = currentText)
                    }
                }

                /**
                 * The only input of the tool-loop (MCP) first leg: re-projects with purpose toolLoopLeg and [toolSafety] as the last segment of the system prompt;
                 * the stored-row checkpoint is not applied. options gets this plan's system prompt and [D], and the outbound messages are [providerMessages].
                 * When the re-projection is refused or yields no messages it is treated as a send failure (same as the main path; the system prompt is never assembled separately).
                 */
                suspend fun toolLoopTransport(toolSafety: String): TransportInput {
                    // The tool loop does not read the stored row; an overflow resend falls back with the failed request's B (estimatedInput when W is unknown).
                    val toolLoopFallbackB = overflowRecovery?.projection?.plan?.budget
                        ?.let { budget -> budget.B ?: budget.estimatedInput }
                    val projected = projectChat(
                        overflowFallbackB = toolLoopFallbackB,
                        toolSafety = toolSafety,
                    )
                    projected?.reject?.let { throw ContextRejectedError(it) }
                    val planned = checkNotNull(projected) { "tool loop leg has no context plan" }.planned
                    toolLoopProjection = projected
                    // When this chat projection applied a stored row, providerMessages starts with that row: the first leg sends this plan's history instead (same attachment budget / backfill).
                    val outbound = if (storedCheckpoint != null) hydratedOutbound(planned.messages) else providerMessages
                    return planned.transportInput(effectiveRequestOptions, outbound)
                }

                // Remote MCP: tools are assembled only when this conversation has a server switched
                // on and this connection can carry tools; otherwise the plan is empty and the request
                // takes the usual path. Image generation never goes through the tool loop; a continue only
                // continues the text, so it does not enter the MCP tool loop either.
                val textContinuationOnly = appendToAssistant != null && attemptKind == ContextConfirmAttempt.CONTINUE
                val mcpPlan = if (relayUseImagesEndpoint || supportsImageGen || textContinuationOnly) {
                    ai.oriveo.community.core.mcp.McpToolPlan.Empty
                } else {
                    mcpChatToolRunner?.plan(
                        conversationId = conversation.id,
                        provider = provider,
                        model = model,
                        memoryVerdict = model?.let { providerRepository.toolCallMemoryVerdict(provider, it) },
                        // A relay's tool-call verdict is scoped by the connection identity; this is
                        // the same one the leg runner sends with.
                        localIdentity = requestOptions.capabilityEvidenceIdentity,
                    ) ?: ai.oriveo.community.core.mcp.McpToolPlan.Empty
                }
                var toolLoopAnswered = false
                // In tool mode this is the last entry of the MCP loop registry; null in fallback / none mode.
                val proposeLoopEntry = memoryPropose?.takeIf { proposeTools.isNotEmpty() }
                    ?.let { ai.oriveo.community.core.memory.ProposeMemoryEntry(it) }
                // search_memory is the last registry entry (after propose) and excludes the ids already placed in this round's [D].
                val searchLoopEntry = memorySearch?.takeIf { proposeTools.isNotEmpty() }?.let { turn ->
                    ai.oriveo.community.core.memory.MemorySearchEntry(
                        turn = turn,
                        recallIds = sendProjection.plan.memoryIds,
                        recallMax = sendProjection.windowBudget?.derived?.recallMax,
                        rhoHi = currentRhoHi(),
                    )
                }

                // External web search: externalSearch is set only when route.path is an external path. Counts, budgets, numbering,
                // facts and error cards all follow the output of planSearchTurn and applySearchEvent; nothing is decided here.
                val searchBinding = externalSearch?.binding?.takeIf {
                    !relayUseImagesEndpoint && !supportsImageGen && !textContinuationOnly
                }
                // The tool-path web_search entry; set back to null after a rejection reroute (later resends carry no tool).
                var webSearchEntry: ai.oriveo.community.core.tools.ToolRegistryEntry? = null
                // A loop carrying web_search ran (including a rejected first leg): the ordinary streaming branch adds no memory-tool leg.
                var webSearchLoopAttempted = false
                // MCP write confirmation: plan.writeToolConfirm and the current webResultsPresent decide "just this once"
                var searchWriteToolConfirm = "n/a"
                val mcpForceOnceConfirmation = {
                    searchWriteToolConfirm == "once_when_web_results_present" && searchRunner?.webResultsPresent == true
                }
                // Evaluated only when this turn takes external search (other paths never touch the MCP config)
                val searchToolHostInput by lazy {
                    ai.oriveo.community.core.search.SearchToolHostInput(
                        mcp = !mcpPlan.isEmpty,
                        memoryTools = proposeLoopEntry != null || searchLoopEntry != null,
                        nativeMoonshotLoop = provider.kind == ProviderKind.Moonshot,
                        // Always pass the effective step count of the MCP runtime config (not only when MCP is on)
                        serverMaxSteps = mcpChatToolRunner?.serverMaxSteps(),
                        // The generic loop replays tool_calls and tool results itself, so this is always tool_loop
                        continuationKind = "tool_loop",
                    )
                }
                fun planExternalSearch(
                    rejection: ai.oriveo.community.core.search.SearchUpstreamRejection?,
                ): ai.oriveo.community.core.search.SearchTurnPlan {
                    val ext = checkNotNull(externalSearch)
                    return ai.oriveo.community.core.search.planSearchTurn(
                        ai.oriveo.community.core.search.SearchTurnPlanInput(
                            path = ext.path,
                            service = checkNotNull(searchBinding).service,
                            toolCall = ext.toolCall,
                            host = searchToolHostInput,
                            // thinking.on = this turn's outbound request really carries a reasoning parameter;
                            // continuation state is always available (the generic loop replays tool_calls and tool results itself).
                            thinking = ai.oriveo.community.core.search.SearchThinking(
                                on = ai.oriveo.community.core.search.searchThinkingOn(effectiveReasoning),
                                protocol = ai.oriveo.community.core.search.searchThinkingProtocol(
                                    requestOptions.modelControlRuntimeIdentity?.finalTransport,
                                    provider.kind.name.lowercase(),
                                ),
                                continuationStateAvailable = true,
                            ),
                            upstreamRejection = rejection,
                            toolsRejectedBefore = ai.oriveo.community.core.search.SearchToolsRejectionMemory
                                .rejectedBefore(conversation.id, ext.modelKey),
                            regenerate = ai.oriveo.community.core.search.SearchRegenerate(
                                ext.action,
                                previousResultsPersisted = previousSearchCitations.isNotEmpty(),
                            ),
                            userText = text,
                            b = sendProjection.windowBudget?.B,
                            today = java.time.LocalDate.now().toString(),
                        ),
                    )
                }
                suspend fun searchReplyStart(plan: ai.oriveo.community.core.search.SearchTurnPlan): ai.oriveo.community.core.search.SearchReplyStart {
                    val binding = checkNotNull(searchBinding)
                    return ai.oriveo.community.core.search.SearchReplyStart(
                        plan = plan.replyPlan,
                        service = binding.service,
                        otherServices = binding.otherServices,
                        b = sendProjection.windowBudget?.B,
                        rhoHi = currentRhoHi(),
                        retrievedAt = java.time.Instant.now().toString(),
                    )
                }
                /** A non-null [resume] means an internal resend within this turn: keep this turn's reply state (sources line, facts and error card keep their actual values). */
                suspend fun startSearchRunner(
                    plan: ai.oriveo.community.core.search.SearchTurnPlan,
                    resume: ai.oriveo.community.core.search.SearchReplyState? = null,
                ): ai.oriveo.community.core.search.SearchReplyRunner {
                    val binding = checkNotNull(searchBinding)
                    val runner = ai.oriveo.community.core.search.SearchReplyRunner(
                        initial = resume ?: ai.oriveo.community.core.search.startSearchReply(searchReplyStart(plan)),
                        binding = binding,
                        track = {},
                        activity = { activity, retry ->
                            outputs.streamingExternalSearch.value = ai.oriveo.community.core.search.nextExternalSearchActivity(
                                outputs.streamingExternalSearch.value,
                                activity,
                                retry,
                            )
                            // After deliver the activity stays until the first token (a text / reasoning delta clears it), and the row reads "answering from the search results"
                            if (activity != null) {
                                outputs.streamingActivity.value = ai.oriveo.community.core.model.StreamActivity.ExternalSearch
                            }
                        },
                    )
                    searchRunner = runner
                    searchWriteToolConfirm = plan.writeToolConfirm
                    return runner
                }
                /** Presearch (query = the user's text) or reuse: the delivered content goes into [D]. */
                suspend fun applySearchPlanToContext(plan: ai.oriveo.community.core.search.SearchTurnPlan, runner: ai.oriveo.community.core.search.SearchReplyRunner) {
                    val presearch = plan.presearch
                    when {
                        plan.reuse -> runner.reuse(previousSearchCitations)?.let { injectWebSegment(it) }
                        presearch != null -> injectWebSegment(runner.search(presearch.query, presearch.count).content)
                    }
                }
                val resumeSearch = externalSearch?.resume
                if (searchBinding != null && resumeSearch != null) {
                    // Internal resend within this turn: no new request and no web_search; [D] is rebuilt by reuse on a separate state, the reply state is unchanged (not marked as reused)
                    val plan = planExternalSearch(null)
                    startSearchRunner(plan, resumeSearch)
                    ai.oriveo.community.core.search.rebuildSearchDelivery(searchReplyStart(plan), resumeSearch.citations)
                        ?.let { injectWebSegment(it) }
                } else if (searchBinding != null) {
                    val plan = planExternalSearch(null)
                    val runner = startSearchRunner(plan)
                    applySearchPlanToContext(plan, runner)
                    val tool = plan.webSearchTool
                    if (plan.requestHasWebSearchTool && tool != null && mcpChatToolRunner != null && model != null) {
                        webSearchEntry = ai.oriveo.community.core.search.WebSearchToolEntry(tool, runner)
                    }
                }
                val searchToolHost = webSearchEntry?.let { searchToolHostInput }
                    ?.let { ai.oriveo.community.core.search.resolveSearchToolHost(it.copy(path = "external_tool")) }
                /**
                 * Rejection reroute: the first leg carrying web_search was rejected (400 / 422). Remember the conversation and model,
                 * re-plan, and when the plan moves to presearch put it into [D].
                 * Returns true when it moved to presearch / reuse (this turn is then resent with that, not through the old "resend without tools" branch).
                 */
                suspend fun rerouteSearchAfterRejection(error: ai.oriveo.community.core.tools.ToolsUnsupportedError): Boolean {
                    val ext = externalSearch ?: return false
                    if (webSearchEntry == null) return false
                    webSearchEntry = null
                    val status = error.upstream.httpStatus ?: return false
                    val plan = planExternalSearch(ai.oriveo.community.core.search.SearchUpstreamRejection(status, 0))
                    if (plan.presearch == null && !plan.reuse) return false
                    // Remember the conversation and model only once the presearch reroute holds
                    ai.oriveo.community.core.search.SearchToolsRejectionMemory.mark(conversation.id, ext.modelKey)
                    applySearchPlanToContext(plan, startSearchRunner(plan))
                    return true
                }

                // null = the MCP loop did not run, or its first leg had tools rejected and the ordinary send below resends without tools.
                var mcpResult: ai.oriveo.community.core.tools.ToolCallLoop.Result? = null
                if (!mcpPlan.isEmpty || webSearchEntry != null) {
                    // The tool loop produces the final answer itself, leg by leg, over whichever of
                    // the four wire protocols this connection speaks.
                    val runner = checkNotNull(mcpChatToolRunner)
                    runner.clearStepLimitReached(assistantMessageId)
                    val activeModel = checkNotNull(model)
                    var legText = ""
                    rhoMultiLeg = true
                    // With search alone there is no MCP safety segment (an empty toolSafety = a tool-loop leg with nothing added to the system prompt)
                    val transport = toolLoopTransport(if (mcpPlan.isEmpty) "" else ai.oriveo.community.core.mcp.McpSafetyPrompt.TEXT)
                    val loopSearchEntry = webSearchEntry
                    if (loopSearchEntry != null) webSearchLoopAttempted = true
                    mcpResult = try {
                        runner.run(
                            conversationId = conversation.id,
                            provider = provider,
                            model = activeModel,
                            modelId = runtimeModelId,
                            transport = transport,
                            reasoningMode = effectiveReasoning,
                            plan = mcpPlan,
                            onStep = recordMcpToolStep,
                            onUnhandledToolCalls = { calls ->
                                // A name outside the lookup table is never executed. It takes the same
                                // route as a tool call nothing can run in an ordinary chat: collected
                                // here and shown as a notice card when the answer is finalized.
                                loopUnhandledToolCalls += calls.map { call ->
                                    UnhandledToolCall(
                                        id = call.id,
                                        name = call.function.name.takeIf { it.isNotBlank() } ?: "?",
                                        arguments = call.function.arguments,
                                    )
                                }
                            },
                            onProgress = { event ->
                            when (event) {
                                is ai.oriveo.community.core.tools.ToolCallLoop.ProgressEvent.LegStarted -> legText = ""
                                is ai.oriveo.community.core.tools.ToolCallLoop.ProgressEvent.TextDelta -> {
                                    if (event.text.isNotEmpty()) {
                                        outputs.streamingActivity.value = null
                                        if (outputs.reasoningStartedAtMs.value != null) {
                                            outputs.reasoningEndedAtMs.compareAndSet(
                                                ConversationStreamingOutputs.NOT_SET,
                                                System.currentTimeMillis(),
                                            )
                                        }
                                    }
                                    legText += event.text
                                    outputs.streamingText.value = initialText + legText
                                }
                                is ai.oriveo.community.core.tools.ToolCallLoop.ProgressEvent.ToolCallsAccepted -> {
                                    // The text of a leg that ends in tool calls is only a lead-in: it
                                    // does not stay on screen while the tools run and wait for confirmation.
                                    legText = ""
                                    outputs.streamingText.value = initialText
                                }
                                is ai.oriveo.community.core.tools.ToolCallLoop.ProgressEvent.ReasoningDelta -> {
                                    // The same route as reasoning in an ordinary stream: the legs'
                                    // reasoning accumulates into one block with the same throttling.
                                    // The first reasoning event lights up "thinking"; an empty
                                    // heartbeat does not clear the activity.
                                    val now = System.currentTimeMillis()
                                    outputs.reasoningStartedAtMs.compareAndSet(null, now)
                                    if (event.text.isNotEmpty()) outputs.streamingActivity.value = null
                                    if (tokenBuffer.appendReasoning(event.text, now)) {
                                        outputs.streamingReasoning.value = tokenBuffer.accumulatedReasoningText
                                        tokenBuffer.markReasoningFlushed(now)
                                    }
                                }
                                is ai.oriveo.community.core.tools.ToolCallLoop.ProgressEvent.Usage -> Unit
                            }
                            },
                            proposeEntry = proposeLoopEntry,
                            searchEntry = searchLoopEntry,
                            webSearchEntry = loopSearchEntry,
                            searchHost = searchToolHost,
                            // "Just this once" is only possible when this turn takes external search; otherwise nothing is passed
                            forceOnceConfirmation = mcpForceOnceConfirmation.takeIf { searchBinding != null },
                        )
                    } catch (error: ai.oriveo.community.core.tools.ToolsUnsupportedError) {
                        // A 4xx on a later leg, or after a structured tool call was seen, is not "tools unsupported": it fails with the usual error card.
                        if (error.legIndex != 0 || error.receivedStructuredToolCalls) throw error.upstream
                        // A 400 / 422 on a first leg carrying web_search that is really a context overflow goes to overflow recovery; it is not a tools rejection
                        if (webSearchEntry != null && isContextOverflow(
                                error.upstream,
                                overflowFamilyOf(chatRequestFamily(null, provider, relayDeliveredTransport.get())),
                            )
                        ) {
                            throw error.upstream
                        }
                        val searchRerouted = rerouteSearchAfterRejection(error)
                        // Rejected only because it carried web_search, and no reroute is possible: fail with the usual error card
                        if (error.webSearchRejection && !searchRerouted) throw error.upstream
                        // A first leg that carried propose_memory was rejected: report the downgrade; this round runs the fallback (the resend below carries no tools).
                        if (proposeLoopEntry != null) memoryPropose?.onToolsRejected()
                        if (searchLoopEntry != null) memorySearch?.onToolsRejected()
                        // A deterministic 4xx on the first leg: resend once this time without tools; the connection
                        // memory records false only when it is eligible (recordToolsRejected / ToolCallMemoryStore.isEligible).
                        // A rejection that rerouted web_search to presearch (remembered per conversation and model in process) writes no connection memory.
                        if (!searchRerouted && !mcpPlan.isEmpty) {
                            recordToolsRejected(provider, activeModel, error, sentTransport = relayFirstSend)
                        }
                        outputs.streamingText.value = initialText
                        null
                    }
                }
                if (mcpResult != null) {
                    val runner = checkNotNull(mcpChatToolRunner)
                    val activeModel = checkNotNull(model)
                    // At the step limit the steps block ends with a line saying that the answer below
                    // is based on the results gathered so far.
                    if (mcpResult.stepLimitReached) runner.markStepLimitReached(assistantMessageId)
                    if (mcpResult.receivedStructuredToolCalls) {
                        toolCallMemoryStore?.record(
                            partitionId = providerRepository.currentCapabilityPartitionId(),
                            provider = provider,
                            model = activeModel,
                            observedToolCall = true,
                            reason = "structured_tool_calls_observed",
                        )
                    }
                    outputs.streamingText.value = initialText + mcpResult.text
                    if (tokenBuffer.hasPendingReasoning()) {
                        outputs.streamingReasoning.value = tokenBuffer.accumulatedReasoningText
                        tokenBuffer.markReasoningFlushed(System.currentTimeMillis())
                    }
                    // A tool loop stores the stopReason from the stream finish of its last leg
                    streamFinish = mcpResult.finish
                    // Each loop leg is priced on its own (cache buckets and the upstream's actual charge follow the leg); if any leg returned no usage the whole result is unknown
                    finalResult = toolLoopLegResult(mcpResult.usage, activeModel).copy(
                        text = mcpResult.text,
                        citations = accumulatedCitations.takeIf { it.isNotEmpty() },
                    )
                    toolLoopAnswered = true
                }

                if (toolLoopAnswered) {
                    // The tool loop already produced the final answer; no second provider request.
                } else if (relayUseImagesEndpoint) {
                    // relay imageRoute = images_endpoint: not the chat protocol, call /images/generations directly
                    // Judged tool but this exit does not carry propose_memory: this message reruns the fallback (directive suggestion plus v1 memory routing) and no degradation is recorded.
                    if (proposeTools.isNotEmpty()) memoryPropose?.onToolsNotAttached()
                    val transport = imageGenerationRequest(effectiveRequestOptions)
                    val done = (service as RelayService).generateImageViaImagesEndpoint(
                        apiKey = effectiveApiKey,
                        modelID = relayUpstreamModelId,
                        messages = transport.messages,
                        baseUrl = ai.oriveo.community.core.provider.transport.OfficialEndpointSource.effectiveBaseUrlText(provider),
                        requestOptions = transport.options,
                    )
                    finalResult = done.result
                    outputs.streamingText.value = initialText + done.result.appendedText(initialText)
                    done.result.attachments?.let { streamingAttachments.addAll(it) }
                } else if (supportsImageGen && provider.kind != ProviderKind.Relay) {
                    // Judged tool but this exit does not carry propose_memory: this message reruns the fallback (directive suggestion plus v1 memory routing) and no degradation is recorded.
                    if (proposeTools.isNotEmpty()) memoryPropose?.onToolsNotAttached()
                    // Purpose imageGeneration goes to a dedicated image endpoint (route = images_api / dashscope_multimodal /
                    // minimax_image_generation); route = chat_api (conversational image output such as Gemini's image modality) is still a chat request and carries the full chat projection.
                    val dedicatedImageRoute = MetadataClient.imageGenRoute(
                        MetadataClient.resolveCatalogModel(relayUpstreamModelId, provider.kind)?.profiles?.imageGen,
                    ) in DEDICATED_IMAGE_GEN_ROUTES
                    val transport = if (dedicatedImageRoute) {
                        imageGenerationRequest(effectiveRequestOptions)
                    } else {
                        (webProjection ?: sendProjection).planned.transportInput(effectiveRequestOptions, providerMessages)
                    }
                    val done = service.sendMessage(
                        apiKey = effectiveApiKey,
                        modelID = relayUpstreamModelId,
                        messages = transport.messages,
                        baseUrl = ai.oriveo.community.core.provider.transport.OfficialEndpointSource.effectiveBaseUrlText(provider),
                        supportsImageGen = true,
                        reasoningMode = effectiveReasoning,
                        webSearchEnabled = effectiveWebSearchEnabled,
                        requestOptions = transport.options,
                    )
                    finalResult = done.result
                    // Continue: the original text plus this round's result (an ordinary send has initialText = "", which is the original behavior)
                    outputs.streamingText.value = initialText + done.result.appendedText(initialText)
                    done.result.attachments?.let { streamingAttachments.addAll(it) }
                } else if (useNonStreamingRelayRuntime) {
                    // Judged tool but this exit does not carry propose_memory: this message reruns the fallback (directive suggestion plus v1 memory routing) and no degradation is recorded.
                    if (proposeTools.isNotEmpty()) memoryPropose?.onToolsNotAttached()
                    val transport = (webProjection ?: sendProjection).planned
                        .transportInput(effectiveRequestOptions, providerMessages, withDynamic = !relayImageRawPrompt)
                    val done = service.sendMessage(
                        apiKey = effectiveApiKey,
                        modelID = relayUpstreamModelId,
                        messages = transport.messages,
                        baseUrl = ai.oriveo.community.core.provider.transport.OfficialEndpointSource.effectiveBaseUrlText(provider),
                        supportsImageGen = supportsImageGen,
                        reasoningMode = effectiveReasoning,
                        webSearchEnabled = effectiveWebSearchEnabled,
                        requestOptions = transport.options,
                    )
                    finalResult = done.result
                    // Continue: the original text plus this round's result (an ordinary send has initialText = "", which is the original behavior)
                    outputs.streamingText.value = initialText + done.result.appendedText(initialText)
                    done.result.attachments?.let { streamingAttachments.addAll(it) }
                } else {
                    // Stateful continuation is used only for an explicit continue (attemptKind CONTINUE); regenerate / retry reuse the assistant slot but take the full plan.
                    // Normal send and app start never read the sidecar. Valid state is acknowledged
                    // only after the provider call completes, so a network failure remains retryable.
                    val explicitContinue = appendToAssistant != null && attemptKind == ContextConfirmAttempt.CONTINUE
                    val continuationState = if (explicitContinue) {
                        continuationAccountId()?.let { accountId ->
                            continuationStore?.loadForExplicit(accountId, assistantMessageId)?.also {
                                loadedContinuation = it
                            }?.state
                        }
                    } else {
                        null
                    }
                    // Only replay kinds have the service replay the target partial; previous_id, tool_loop
                    // and no sidecar keep it in the history. Judge by kind, not by which fields are present.
                    if (continueTarget != null && loadedContinuation?.kind in REPLAY_CONTINUATION_KINDS) {
                        providerMessages = providerMessages.filterNot { it.id == continueTarget.id }
                    }
                    val currentFingerprint = ContinuationFingerprint.of(webProjection ?: sendProjection, relayUpstreamModelId)
                    // Only an ordinary streaming first leg that did not enter the tool loop carries propose_memory.
                    var proposeLegTools = proposeTools.isNotEmpty() && mcpPlan.isEmpty && !webSearchLoopAttempted
                    val serviceOptions = effectiveRequestOptions.copy(
                        localContinuationMessageId = assistantMessageId,
                        localContinuationState = continuationState,
                        localContinuationExplicit = explicitContinue,
                        localContinuationFingerprintMatches = continuationFingerprints[assistantMessageId] == currentFingerprint,
                        clientTools = if (proposeLegTools) proposeTools else emptyList(),
                    )
                    val transport = (webProjection ?: sendProjection).planned
                        .transportInput(serviceOptions, providerMessages, withDynamic = !relayImageRawPrompt)
                    fun openStream(transport: TransportInput) = service.sendMessageStream(
                        apiKey = effectiveApiKey,
                        modelID = relayUpstreamModelId,
                        messages = transport.messages,
                        baseUrl = ai.oriveo.community.core.provider.transport.OfficialEndpointSource.effectiveBaseUrlText(provider),
                        supportsImageGen = supportsImageGen,
                        reasoningMode = effectiveReasoning,
                        webSearchEnabled = effectiveWebSearchEnabled,
                        requestOptions = transport.options,
                    )
                    openStream(transport).catch { error ->
                        // A first leg with tools that is deterministically rejected before any text and before a structured tool_calls was seen: resend once without tools, run the fallback this round, and record the downgrade.
                        // Everything else (after text started / no access / not a tool rejection) is rethrown as is. Only upstream exceptions are caught; exceptions from the collector body do not pass through here.
                        val activeModel = model
                        if (!proposeLegTools || (memoryPropose == null && memorySearch == null) || activeModel == null || receivedOutputDelta ||
                            nativeToolCallDeltas.isNotEmpty() || !isToolsRejection(error)
                        ) {
                            throw error
                        }
                        proposeLegTools = false
                        recordToolsRejected(
                            provider, activeModel,
                            ai.oriveo.community.core.tools.ToolsUnsupportedError(error as ProviderServiceError),
                            sentTransport = relayFirstSend,
                        )
                        memoryPropose?.onToolsRejected()
                        memorySearch?.onToolsRejected()
                        emitAll(
                            openStream(
                                (webProjection ?: sendProjection).planned.transportInput(
                                    serviceOptions.copy(clientTools = emptyList()),
                                    providerMessages,
                                    withDynamic = !relayImageRawPrompt,
                                ),
                            ),
                        )
                    }.collect { event ->
                        receivedUpstreamEvent = true
                        if (event is StreamEvent.Delta || event is StreamEvent.Reasoning || event is StreamEvent.ImagePart) {
                            receivedOutputDelta = true
                        }
                        // The stream parser is the only source allowed to mark a capability observed.
                        // Intent, recipes, HTTP success, and custom control refs never count as evidence.
                        capabilityExecutionCollector.observe(event)
                        when (event) {
                            is StreamEvent.Delta -> {
                                val now = System.currentTimeMillis()
                                // The first visible token ends the reasoning phase, which is how
                                // the reasoning duration is measured for providers that do not
                                // report one.
                                if (outputs.reasoningStartedAtMs.value != null) {
                                    outputs.reasoningEndedAtMs.compareAndSet(
                                        ConversationStreamingOutputs.NOT_SET,
                                        now,
                                    )
                                }
                                // The model is talking again, so the activity is over. Cleared as
                                // the event arrives rather than on the throttled flush.
                                if (event.text.isNotEmpty()) outputs.streamingActivity.value = null
                                val shouldFlush = tokenBuffer.appendDelta(event.text, now)

                                if (shouldFlush) {
                                    tokenBuffer.drainTextToAccumulated(now)
                                    outputs.streamingText.value = tokenBuffer.accumulatedText
                                }
                                // Periodically persist what has arrived. Without this, killing the
                                // app mid-answer loses everything the user already watched appear.
                                if (tokenBuffer.shouldPartialFlush(
                                        now,
                                        PARTIAL_FLUSH_CHAR_THRESHOLD,
                                        PARTIAL_FLUSH_TIME_THRESHOLD_MS,
                                    )) {
                                    if (tokenBuffer.hasPendingText()) {
                                        tokenBuffer.drainTextToAccumulated(now)
                                        outputs.streamingText.value = tokenBuffer.accumulatedText
                                    }
                                    // A failed checkpoint must not abort the stream: the answer is
                                    // still arriving and will be persisted again on completion.
                                    try {
                                        flushPartialToMessage(
                                            messageId = assistantMessageId,
                                            text = tokenBuffer.accumulatedText,
                                            reasoningText = tokenBuffer.accumulatedReasoningText.trim()
                                                .takeIf { it.isNotEmpty() },
                                        )
                                    } catch (e: CancellationException) {
                                        throw e
                                    } catch (_: Exception) {
                                    }
                                    tokenBuffer.markPartialFlushed(now)
                                }
                            }
                            is StreamEvent.Reasoning -> {
                                val now = System.currentTimeMillis()
                                outputs.reasoningStartedAtMs.compareAndSet(null, now)
                                // An empty-string heartbeat changes nothing on screen, so it does
                                // not end the activity.
                                if (event.text.isNotEmpty()) outputs.streamingActivity.value = null
                                val shouldFlushReasoning = tokenBuffer.appendReasoning(event.text, now)
                                if (shouldFlushReasoning) {
                                    outputs.streamingReasoning.value = tokenBuffer.accumulatedReasoningText
                                    tokenBuffer.markReasoningFlushed(now)
                                }
                            }
                            is StreamEvent.ImagePart -> {
                                streamingAttachments.add(event.attachment)
                            }
                            is StreamEvent.Citations -> {
                                accumulatedCitations = mergeIncomingCitations(event.citations)
                                if (event.citations.any { it.url.isNotBlank() }) relayWebCitationSeen = true
                            }
                            is StreamEvent.RecipeContinuation -> {
                                val accountId = continuationAccountId()
                                if (accountId != null) {
                                    continuationStore?.save(
                                        accountId = accountId,
                                        conversationId = conversation.id,
                                        messageId = assistantMessageId,
                                        kind = event.kind,
                                        state = event.state,
                                    )
                                    // Record this plan's fingerprint at the same moment as previousResponseId (in memory only).
                                    val fingerprint = (webProjection ?: chatProjection)
                                        ?.let { ContinuationFingerprint.of(it, relayUpstreamModelId) }
                                    if (fingerprint != null) {
                                        continuationFingerprints[assistantMessageId] = fingerprint
                                    } else {
                                        continuationFingerprints.remove(assistantMessageId)
                                    }
                                    producedContinuationThisRound = true
                                }
                            }
                            is StreamEvent.ToolCallDeltas -> {
                                NativeToolCallAccumulator.merge(nativeToolCallDeltas, event.deltas)
                            }
                            is StreamEvent.Activity -> {
                                outputs.streamingActivity.value = event.activity
                            }
                            is StreamEvent.ToolCall,
                            is StreamEvent.ToolResult -> Unit
                            is StreamEvent.Done -> {
                                // Flush remaining buffer
                                if (tokenBuffer.hasPendingText()) {
                                    tokenBuffer.drainTextToAccumulated(System.currentTimeMillis())
                                    outputs.streamingText.value = tokenBuffer.accumulatedText
                                }
                                if (tokenBuffer.hasPendingReasoning()) {
                                    outputs.streamingReasoning.value = tokenBuffer.accumulatedReasoningText
                                    tokenBuffer.markReasoningFlushed(System.currentTimeMillis())
                                }
                                finalResult = event.result
                                streamFinish = event.finish
                            }
                        }
                    }
                    loadedContinuation?.takeIf {
                        finalResult != null && !producedContinuationThisRound
                    }?.let { snapshot ->
                        continuationStore?.acknowledge(snapshot)
                    }
                    val proposeHook = memoryPropose
                    val searchHook = memorySearch
                    if (proposeLegTools && (proposeHook != null || searchHook != null)) {
                        // Host tool calls of the first leg run in order (propose -> a fixed tool result,
                        // search -> the search result text) and do not go into the "no executor" card.
                        val hostNames = listOfNotNull(
                            ai.oriveo.community.core.context.MemoryPropose.TOOL_NAME.takeIf { proposeHook != null },
                            ai.oriveo.community.core.context.MemorySearch.TOOL_NAME.takeIf { searchHook != null },
                        )
                        val firstCalls = NativeToolCallAccumulator.finalize(nativeToolCallDeltas, namespace = "provider_tool_call")
                        val proposeCalls = firstCalls.filter { it.name in hostNames }
                        val hostResults = ArrayList<String>(proposeCalls.size)
                        if (proposeCalls.isNotEmpty()) {
                            nativeToolCallDeltas.entries.removeAll { it.value.name in hostNames }
                            val recallIds = sendProjection.plan.memoryIds
                            val recallMax = sendProjection.windowBudget?.derived?.recallMax
                            val rhoHi = currentRhoHi()
                            proposeCalls.forEach { call ->
                                hostResults += if (call.name == ai.oriveo.community.core.context.MemoryPropose.TOOL_NAME) {
                                    proposeHook?.onProposeCall(call.arguments)
                                    ai.oriveo.community.core.context.MemoryPropose.TOOL_RESULT
                                } else {
                                    searchHook!!.run(call.arguments, recallIds, recallMax, rhoHi)
                                }
                            }
                        }
                        // A tail leg is added only when the first leg ended with tool_calls and all of them are propose_memory. The resume state is needed only when the first leg carried thinking
                        // (thinking text / signature / stateful continuation); ordinary streaming does not hand it out, so with thinking: if the first-leg text is non-empty it ends the answer,
                        // and if it is empty the original request is resent once without tools to get an answer (the candidates are kept, no downgrade is recorded). Without thinking, all four protocols add the tail leg in the ordinary message shape.
                        val tailRunner = mcpChatToolRunner
                        val tailModel = model
                        val finish = streamFinish
                        val endedWithToolCalls = finish != null && when (finish.family) {
                            StopFamily.OPENAI_CHAT -> finish.finishRaw == "tool_calls"
                            StopFamily.ANTHROPIC -> finish.finishRaw == "tool_use"
                            else -> true
                        }
                        val onlyPropose = proposeCalls.isNotEmpty() && proposeCalls.size == firstCalls.size && endedWithToolCalls
                        val firstLegThought = tokenBuffer.accumulatedReasoningText.isNotBlank() || producedContinuationThisRound
                        val firstLegText = finalResult?.text?.takeIf { it.isNotBlank() } ?: tokenBuffer.accumulatedText
                        // The first leg's search results actually reach the model only when a tail leg is added; in the other branches (including the thinking resend) they are not used to mark the message as having used memory.
                        searchResultsUnsent = proposeCalls.isNotEmpty()
                        if (onlyPropose && firstLegThought && firstLegText.isBlank()) {
                            rhoMultiLeg = true
                            val firstLeg = finalResult
                            var retryText = ""
                            var retryResult: ProviderChatResult? = null
                            var retryFinish: ai.oriveo.community.core.context.StreamFinish? = null
                            // Before the resend, append the entries found by search after the automatic recall in [D] (re-projection, with the same recallMax cut).
                            var retryProjection = webProjection ?: sendProjection
                            var retryMessages = providerMessages
                            val searchedEntries = searchHook?.searchedEntries.orEmpty()
                            if (searchedEntries.isNotEmpty()) {
                                val reprojected = projectChat(
                                    overflowFallbackB = recoveryFallbackB,
                                                    extraRecall = searchedEntries,
                                )?.takeIf { it.reject == null }
                                val currentText = reprojected?.messages?.lastOrNull()?.takeIf { it.role == ChatRole.User }?.text
                                val lastUserIndex = providerMessages.indexOfLast { it.role == ChatRole.User }
                                if (reprojected != null && currentText != null && lastUserIndex >= 0) {
                                    retryProjection = reprojected
                                    searchRetryProjection = reprojected
                                    retryMessages = providerMessages.toMutableList().also {
                                        it[lastUserIndex] = it[lastUserIndex].copy(text = currentText)
                                    }
                                }
                            }
                            openStream(
                                retryProjection.planned.transportInput(
                                    serviceOptions.copy(clientTools = emptyList()),
                                    retryMessages,
                                    withDynamic = !relayImageRawPrompt,
                                ),
                            ).collect { event ->
                                when (event) {
                                    is StreamEvent.Delta -> {
                                        retryText += event.text
                                        outputs.streamingText.value = initialText + retryText
                                    }
                                    is StreamEvent.Reasoning -> {
                                        val now = System.currentTimeMillis()
                                        if (tokenBuffer.appendReasoning(event.text, now)) {
                                            outputs.streamingReasoning.value = tokenBuffer.accumulatedReasoningText
                                            tokenBuffer.markReasoningFlushed(now)
                                        }
                                    }
                                    is StreamEvent.Citations -> accumulatedCitations = mergeIncomingCitations(event.citations)
                                    is StreamEvent.ToolCallDeltas ->
                                        NativeToolCallAccumulator.merge(nativeToolCallDeltas, event.deltas)
                                    is StreamEvent.Done -> {
                                        retryResult = event.result
                                        retryFinish = event.finish
                                    }
                                    else -> Unit
                                }
                            }
                            val answer = retryResult
                            val answerText = answer?.text?.takeIf { it.isNotBlank() } ?: retryText
                            // The first leg's tokens are already spent: both requests are priced per leg and added up, and the stopReason comes from the resend;
                            // if any leg returned no usage the total is unknown.
                            finalResult = ai.oriveo.community.core.provider.DeliveredCostResolver.mergeLegs(
                                listOf(firstLeg, answer),
                                base = answer ?: ProviderChatResult(text = "", usageReported = false),
                            ).copy(text = answerText)
                            streamFinish = retryFinish
                            outputs.streamingText.value = initialText + answerText
                        } else if (onlyPropose && !firstLegThought && tailRunner != null && tailModel != null) {
                            rhoMultiLeg = true
                            searchResultsUnsent = false
                            val firstLeg = finalResult
                            val firstText = firstLegText
                            val appended = listOf(
                                ai.oriveo.community.core.tools.ToolLoopMessage(
                                    role = "assistant",
                                    content = kotlinx.serialization.json.JsonPrimitive(firstText),
                                    toolCalls = proposeCalls.map { call ->
                                        ai.oriveo.community.core.tools.ToolLoopToolCall(
                                            id = call.id,
                                            function = ai.oriveo.community.core.tools.ToolLoopToolCallFunction(call.name, call.arguments),
                                        )
                                    },
                                ),
                            ) + proposeCalls.mapIndexed { i, call ->
                                ai.oriveo.community.core.tools.ToolLoopMessage(
                                    role = "tool",
                                    content = kotlinx.serialization.json.JsonPrimitive(hostResults[i]),
                                    toolCallId = call.id,
                                )
                            }
                            var tailText = ""
                            var tailUsage: ai.oriveo.community.core.tools.ToolLoopUsage? = null
                            var tailFinish: ai.oriveo.community.core.context.StreamFinish? = null
                            val tailDeltas = LinkedHashMap<Int, ai.oriveo.community.core.tools.ToolLoopToolCallDelta>()
                            // A failing tail leg is rethrown as is (error card); candidates already created are not rolled back.
                            tailRunner.proposeTailLeg(
                                provider = provider,
                                model = tailModel,
                                modelId = runtimeModelId,
                                transport = transport,
                                reasoningMode = effectiveReasoning,
                                appended = appended,
                                tools = proposeTools,
                            ).collect { event ->
                                when (event) {
                                    is ai.oriveo.community.core.tools.ToolLoopLegEvent.TextDelta -> {
                                        tailText += event.text
                                        outputs.streamingText.value = initialText + joinProposeLegTexts(firstText, tailText)
                                    }
                                    is ai.oriveo.community.core.tools.ToolLoopLegEvent.ReasoningDelta -> {
                                        val now = System.currentTimeMillis()
                                        outputs.reasoningStartedAtMs.compareAndSet(null, now)
                                        if (tokenBuffer.appendReasoning(event.text, now)) {
                                            outputs.streamingReasoning.value = tokenBuffer.accumulatedReasoningText
                                            tokenBuffer.markReasoningFlushed(now)
                                        }
                                    }
                                    is ai.oriveo.community.core.tools.ToolLoopLegEvent.ToolCallDeltas ->
                                        ai.oriveo.community.core.tools.ToolCallLoop.mergeToolCallDeltas(tailDeltas, event.deltas)
                                    is ai.oriveo.community.core.tools.ToolLoopLegEvent.Usage ->
                                        tailUsage = ai.oriveo.community.core.tools.ToolLoopUsage.mergeWithinLeg(tailUsage, event.usage)
                                    is ai.oriveo.community.core.tools.ToolLoopLegEvent.Finish -> tailFinish = event.finish
                                    is ai.oriveo.community.core.tools.ToolLoopLegEvent.ProviderContinuation -> Unit
                                }
                            }
                            // A propose_memory call in the tail leg only creates candidates and adds no further leg; a search_memory call in the tail leg is not executed;
                            // any other name (which should not occur under tool_choice none) goes to the no-executor card.
                            tailDeltas.toSortedMap().values.forEachIndexed { offset, delta ->
                                val name = delta.name?.takeIf { it.isNotBlank() } ?: "?"
                                if (name == ai.oriveo.community.core.context.MemoryPropose.TOOL_NAME && proposeHook != null) {
                                    proposeHook.onProposeCall(delta.arguments.orEmpty())
                                } else if (name == ai.oriveo.community.core.context.MemorySearch.TOOL_NAME && searchHook != null) {
                                    Unit
                                } else {
                                    loopUnhandledToolCalls += UnhandledToolCall(
                                        id = delta.id?.takeIf { it.isNotBlank() } ?: "provider_tool_call_tail_${offset + 1}",
                                        name = name,
                                        arguments = delta.arguments.orEmpty(),
                                    )
                                }
                            }
                            // Both legs are priced per leg and added up (the tail leg only returns prompt / completion, so it is priced by estimate), and the stopReason comes from the tail leg;
                            // if any leg returned no usage the total is unknown.
                            finalResult = ai.oriveo.community.core.provider.DeliveredCostResolver.mergeLegs(
                                listOf(
                                    firstLeg,
                                    // A subscription connection is judged as a whole by authMode in the delivery layer, so it is not marked here.
                                    toolLoopLegResult(tailUsage, tailModel),
                                ),
                                base = firstLeg ?: ProviderChatResult(text = "", usageReported = false),
                            ).copy(text = joinProposeLegTexts(firstText, tailText))
                            streamFinish = tailFinish
                            outputs.streamingText.value = initialText + joinProposeLegTexts(firstText, tailText)
                        }
                    }
                }

                val result = finalResult
                // A continue must keep the original text: result.text usually holds only what this round generated, so using it directly would drop the original.
                // - ordinary send / regenerate (initialText empty): result.text first, falling back to the accumulated text when it is blank
                // - continue (initialText non-empty): prefer the accumulated text (original + new); if the stream produced nothing new but Done carried
                //   result.text (some providers put the whole text into Done), append it after the original
                val streamedFull = outputs.streamingText.value
                val finalText = if (initialText.isEmpty()) {
                    result?.text?.ifBlank { streamedFull } ?: streamedFull
                } else if (streamedFull.length > initialText.length) {
                    streamedFull
                } else {
                    initialText + result?.appendedText(initialText).orEmpty()
                }

                val resolvedAttachments = imageProcessor.downloadHttpUrls(streamingAttachments)
                streamingAttachments.clear()
                streamingAttachments.addAll(resolvedAttachments)

                val (cleanedText, inlineImageAttachments) = imageProcessor.extractInlineImages(finalText)
                streamingAttachments.addAll(inlineImageAttachments)

                val persistedAttachments = imageProcessor.persistInlineBase64(streamingAttachments)
                streamingAttachments.clear()
                streamingAttachments.addAll(persistedAttachments)

                val displayText = if (inlineImageAttachments.isNotEmpty()) cleanedText else finalText
                val unhandledToolCalls = (
                    loopUnhandledToolCalls + NativeToolCallAccumulator.finalize(
                        target = nativeToolCallDeltas,
                        namespace = "provider_tool_call",
                    )
                    ).distinctBy { it.id }
                if (unhandledToolCalls.isNotEmpty()) {
                    model?.let { activeModel ->
                        toolCallMemoryStore?.record(
                            partitionId = providerRepository.currentCapabilityPartitionId(),
                            provider = provider,
                            model = activeModel,
                            observedToolCall = true,
                            reason = "structured_tool_calls_observed",
                        )
                    }
                }
                // Price by the connection's effective region and keep the original currency; for per-item pricing the unit count is the number
                // of images produced this time, and 0 images means unknown.
                val generationParts = DeliveredCostResolver.resolveParts(
                    result = result,
                    model = model,
                    provider = provider,
                    modelId = runtimeModelId,
                    at = java.time.Instant.now(),
                    units = DeliveredCostResolver.producedUnits(streamingAttachments),
                    relayTransport = relayDeliveredTransport.get(),
                )
                // The USD part goes into estimatedCost and a non-USD generation cost into nonUsdCost; currencies are not converted.
                val costRecord = DeliveredCostResolver.record(generationParts)
                // Continue: this round's cost is merged part by part with the placeholder's existing cost, so earlier rounds' cost is not overwritten.
                val messageCost = if (continueTarget != null) {
                    DeliveredCostResolver.addMessageCost(assistantPlaceholder.estimatedCost, assistantPlaceholder.nonUsdCost, costRecord)
                } else {
                    costRecord
                }

                if (displayText.isBlank() && streamingAttachments.isEmpty() && unhandledToolCalls.isEmpty()) {
                    emptyStreamFinish = streamFinish
                    throw ProviderServiceError.EmptyResponse
                }

                val finalCitations = mergeIncomingCitations(result?.citations.orEmpty())
                if (result?.citations.orEmpty().any { it.url.isNotBlank() }) relayWebCitationSeen = true

                val reasoningStartedAt = outputs.reasoningStartedAtMs.value
                val reasoningEndedAt = outputs.reasoningEndedAtMs.get()
                    .takeIf { it != ConversationStreamingOutputs.NOT_SET }
                    ?: reasoningStartedAt?.let { System.currentTimeMillis() }
                val computedDurationMs = if (reasoningStartedAt != null && reasoningEndedAt != null) {
                    (reasoningEndedAt - reasoningStartedAt).coerceAtLeast(0L)
                } else null
                val hasProviderUsage = result != null && (
                    result.promptTokens > 0 || result.completionTokens > 0 ||
                        result.cachedInputTokens != null || result.cacheCreation5mTokens != null ||
                        result.cacheCreation1hTokens != null
                    )
                val roundInputTokens = result?.promptTokens?.takeIf { hasProviderUsage }
                val roundOutputTokens = result?.completionTokens?.takeIf { hasProviderUsage }
                val roundCacheReadTokens = result?.cachedInputTokens
                val roundCacheWriteTokens = result?.let { value ->
                    if (value.cacheCreation5mTokens != null || value.cacheCreation1hTokens != null) {
                        (value.cacheCreation5mTokens ?: 0) + (value.cacheCreation1hTokens ?: 0)
                    } else null
                }
                fun addUsage(previous: Int?, current: Int?): Int? =
                    if (previous == null && current == null) null else (previous ?: 0) + (current ?: 0)

                val accumulatedReasoning = tokenBuffer.accumulatedReasoningText.trim().takeIf { it.isNotEmpty() }
                val finalReasoning = if (initialReasoning.isNotEmpty()) {
                    when {
                        accumulatedReasoning != null && accumulatedReasoning.length > initialReasoning.length -> accumulatedReasoning
                        !result?.reasoningText.isNullOrEmpty() -> initialReasoning + result.reasoningText.orEmpty()
                        else -> initialReasoning
                    }
                } else {
                    result?.reasoningText ?: accumulatedReasoning
                }
                val deliveredMessage = assistantPlaceholder.copy(
                    text = displayText.trim(),
                    reasoningText = finalReasoning,
                    reasoningDurationMs = computedDurationMs,
                    servedModelID = result?.servedModelID,
                    estimatedCost = messageCost.estimatedCost,
                    nonUsdCost = messageCost.nonUsdCost,
                    state = ChatMessageState.Delivered,
                    stopReason = deliveredStopReason(finish = streamFinish, hadContent = displayText.isNotBlank()),
                    attachments = streamingAttachments.ifEmpty { result?.attachments },
                    citations = finalCitations.takeIf { it.isNotEmpty() },
                    unhandledToolCalls = (
                        assistantPlaceholder.unhandledToolCalls + unhandledToolCalls
                    ).distinctBy { it.id },
                    toolFallbackNotice = localToolFallbackNotice ?: assistantPlaceholder.toolFallbackNotice,
                    toolSteps = mcpToolSteps.takeIf { it.isNotEmpty() },
                    capabilityExecutionResults = capabilityExecutionCollector.successfulTerminalResults() +
                        localCapabilityExecutionResults,
                    memoryItemIds = deliveredMemoryItemIds(
                        // Memory items returned to the model by search_memory are merged into memoryIds; on a thinking-model resend they are already in the re-projected [D].
                        sentMemoryIds = (toolLoopProjection ?: searchRetryProjection ?: webProjection ?: chatProjection)
                            ?.plan?.memoryIds?.let { ids ->
                                if (searchRetryProjection != null || searchResultsUnsent) ids else (ids + memorySearch?.returnedIds.orEmpty()).distinct()
                            },
                        previous = assistantPlaceholder.memoryItemIds,
                        isContinue = continueTarget != null,
                        delivered = true,
                    ),
                    inputTokens = addUsage(assistantPlaceholder.inputTokens, roundInputTokens),
                    outputTokens = addUsage(assistantPlaceholder.outputTokens, roundOutputTokens),
                    cachedInputTokens = addUsage(assistantPlaceholder.cachedInputTokens, roundCacheReadTokens),
                    cacheCreationInputTokens = addUsage(
                        assistantPlaceholder.cacheCreationInputTokens,
                        roundCacheWriteTokens,
                    ),
                    cacheCreation5mTokens = result?.cacheCreation5mTokens,
                    cacheCreation1hTokens = result?.cacheCreation1hTokens,
                    costSource = messageCost.costSource,
                ).withSearchReply(stopped = false)
                conversationRepository.updateMessage(conversation.id, deliveredMessage)
                // A rho sample is taken only from plain-text requests, using the input tokens of this round's usage.
                val observedInput = result?.promptTokens?.takeIf { hasProviderUsage && it > 0 }
                recordChatLedger(
                    projection = webProjection ?: chatProjection,
                    conversationId = conversation.id,
                    transportKey = rhoTransportKey,
                    family = chatRequestFamily(streamFinish, provider, relayDeliveredTransport.get()),
                    modelId = runtimeModelId,
                    observedInput = observedInput,
                    textBytes = chatRequestTextBytes(effectiveRequestOptions.systemPrompt, providerMessages)
                        .takeIf { providerMessages.none { !it.attachments.isNullOrEmpty() } },
                    stopReason = deliveredMessage.stopReason,
                    rhoEligible = !rhoMultiLeg,
                )
                if (deliveredMessage.state == ChatMessageState.Delivered) {
                    relayObservedPromotionTransport(provider, model, delivered = true)?.let { sentTransport ->
                        promoteRelayModelAfterDelivery(provider, requireNotNull(model), sentTransport)
                    }
                    // The first send went out on a different protocol and did not switch again: write the first-send protocol to this model as observed, through the same write-back path as a protocol fallback.
                    relayFirstSendObservedTransport(provider, model, relayFirstSend, relayProtocolSwitchStarted.get())?.let { (sent, observed) ->
                        recordRelayProtocolFallback(provider, requireNotNull(model), sent, observed)
                    }
                    recordRelayKeyAccessSuccess(provider, runtimeModelId)
                    if (provider.kind == ProviderKind.Relay) {
                        val webModel = model ?: requestOptions.activeModel
                        val deliveredTransport = relayDeliveredTransport.get()
                        val droppedTransport = relayWebDroppedTransport.get()
                        // The fragment the delivered attempt carried: the one of that protocol, none for a protocol that was resent without it.
                        val deliveredFragment = deliveredTransport
                            ?.takeIf { it != droppedTransport }
                            ?.let { relayWebFragmentsForSend[it.value] }
                        // The web parameter was rejected and the resend without it succeeded: record rejected for that protocol x current fragment hash (tested), the same as a probe verdict.
                        droppedTransport?.let { dropped ->
                            recordRelayWebRejected(provider, webModel, dropped, relayWebFragmentsForSend[dropped.value])
                        }
                        // Delivered with a fragment and the parser produced citations: write searched / observed for the actual protocol (including after a protocol fallback).
                        if (relayWebCitationSeen) {
                            recordRelayWebObserved(provider, webModel, deliveredTransport, deliveredFragment)
                        }
                        // The switch is on but the delivered attempt carried no fragment: attach a one-line notice under the reply (in memory only).
                        relayWebReplyNotices.set(
                            deliveredMessage.id,
                            ai.oriveo.community.core.provider.relay.RelayWebReplyNotices.Notice.WebNotUsed
                                .takeIf { relayWebSwitchOn && deliveredFragment == null },
                        )
                    }
                }
                conversationRepository.refreshCost(conversation.id)
            }
        } catch (e: CancellationException) {
            // Cancellation is a normal outcome: the user tapped stop, or the screen went away.
            // Whatever arrived is kept and the message is marked interrupted so it can be resumed.
            if (tokenBuffer.hasPendingText()) {
                tokenBuffer.drainTextToAccumulated(System.currentTimeMillis())
                outputs.streamingText.value = tokenBuffer.accumulatedText
            }
            if (tokenBuffer.hasPendingReasoning()) {
                outputs.streamingReasoning.value = tokenBuffer.accumulatedReasoningText
                tokenBuffer.markReasoningFlushed(System.currentTimeMillis())
            }
            val cancelStartedAt = outputs.reasoningStartedAtMs.value
            val cancelEndedAt = outputs.reasoningEndedAtMs.get()
                .takeIf { it != ConversationStreamingOutputs.NOT_SET }
                ?: cancelStartedAt?.let { System.currentTimeMillis() }
            val cancelDurationMs = if (cancelStartedAt != null && cancelEndedAt != null) {
                (cancelEndedAt - cancelStartedAt).coerceAtLeast(0L)
            } else null
            // interrupted is only for a user stop or being displaced by a newer send in the same conversation; system interruptions such as sign-out / account switch are recorded as transport errors
            val cancelStopReason = if (outputs.systemInterrupted.get()) {
                failureStopReason(e, hadContent = outputs.streamingText.value.isNotBlank())
            } else {
                StopReason.INTERRUPTED
            }
            val interruptedMessage = assistantPlaceholder.copy(
                text = outputs.streamingText.value.trim(),
                state = ChatMessageState.Interrupted,
                stopReason = cancelStopReason,
                attachments = streamingAttachments.ifEmpty { null },
                reasoningText = tokenBuffer.accumulatedReasoningText.trim().takeIf { it.isNotEmpty() },
                reasoningDurationMs = cancelDurationMs,
                citations = accumulatedCitations.takeIf { it.isNotEmpty() }
                    ?: assistantPlaceholder.citations,
                capabilityExecutionResults = capabilityExecutionCollector.requestedResults(),
                toolSteps = mcpToolSteps.takeIf { it.isNotEmpty() },
            ).withSearchReply(stopped = true)
            // NonCancellable: the surrounding scope is already cancelled, so an ordinary write
            // here would be skipped and the partial answer lost.
            withContext(NonCancellable) {
                val (interruptedText, interruptedAttachments) = imageProcessor.localizeInlineImages(
                    interruptedMessage.text,
                    interruptedMessage.attachments.orEmpty(),
                )
                conversationRepository.updateMessage(
                    conversation.id,
                    interruptedMessage.copy(text = interruptedText.trim(), attachments = interruptedAttachments.ifEmpty { null }),
                )
                continuationAccountId()?.let { accountId ->
                    continuationStore?.markInterrupted(accountId, assistantMessageId)
                }
                // A user cancellation writes an interrupted manifest; a system interruption (sign-out / account switch / background expiry) writes none.
                if (!outputs.systemInterrupted.get()) {
                    recordChatLedger(
                        projection = webProjection ?: chatProjection,
                        conversationId = conversation.id,
                        transportKey = rhoTransportKey,
                        family = chatStopFamily(provider, relayDeliveredTransport.get()),
                        modelId = runtimeModelId,
                        observedInput = null,
                        textBytes = null,
                        stopReason = cancelStopReason,
                    )
                }
            }
            throw e
        } catch (e: Exception) {
            // A context overflow on a failed send feeds back the rho prediction miss; a first failure before any output falls back and resends once on the same assistant message.
            // Protocol family: use the family of the finish the stream delivered, otherwise the wire protocol actually used for this request.
            val attemptFamily = chatRequestFamily(errorStreamFinish(e) ?: emptyStreamFinish, provider, relayDeliveredTransport.get())
            val overflowed = chatProjection != null &&
                isContextOverflow(e, overflowFamilyOf(attemptFamily), emptyStreamFinish)
            if (overflowed && chatProjection != null) {
                recordOverflowAttempt(
                    projection = chatProjection,
                    ledgerProjection = webProjection ?: chatProjection,
                    recordMiss = !rhoMultiLeg,
                    conversationId = conversation.id,
                    transportKey = rhoTransportKey,
                    family = attemptFamily,
                    modelId = runtimeModelId,
                )
                // A retry / continue of a failed message also carries appendToAssistant (reusing the original assistant slot) and recovers once as usual.
                // When the coordinator is present (first chat send) it compacts by the configured mode and stores a row first; if there is a row, the resend reads it; only on noop does the in-memory fallback run.
                val overflowB = chatProjection.plan.budget.B ?: chatProjection.plan.budget.estimatedInput
                val compactedRow = if (overflowRecovery == null && !receivedOutputDelta && compaction != null && overflowB != null) {
                    val overflowRhoHi = currentRhoHi()
                    overflowCompaction(compaction, conversation.id, chatProjection, overflowB, provider,
                        model ?: requestOptions.activeModel, runtimeModelId,
                        history = ChatContextProjector.compactionHistory(projectionMessages, overflowRhoHi),
                        rhoHi = overflowRhoHi,
                    )
                } else {
                    null
                }
                val recovery = if (overflowRecovery != null || receivedOutputDelta) {
                    null
                } else {
                    if (compactedRow != null) storedCheckpoint = compactedRow
                    memoryFallback = true
                    // With a stored row the resend reads it (without B); only on noop does the in-memory fallback run with the overflow B.
                    projectChat(overflowFallbackB = overflowB.takeIf { compactedRow == null })
                        ?.takeIf { it.reject == null && it.tailFrom != null }
                }
                if (recovery != null) {
                    sendMessage(
                        conversation = conversation,
                        text = text,
                        provider = provider,
                        modelID = modelID,
                        existingMessages = existingMessages,
                        attachments = attachments,
                        quoteContext = quoteContext,
                        reasoningMode = reasoningMode,
                        webSearchEnabled = webSearchEnabled,
                        requestOptions = requestOptions,
                        outputs = outputs,
                        persistUserMessage = false,
                        userMessageAlreadyInHistory = userMessageAlreadyInHistory,
                        appendToAssistant = null,
                        attemptKind = attemptKind,
                        overflowRecovery = ChatOverflowRecovery(assistantPlaceholder, recovery, compactedRow, budgetCap),
                        // An internal resend within this turn reuses the external search results already fetched (rebuilt by reuse: no new request, no new charge)
                        externalSearch = externalSearch?.let { ext ->
                            searchRunner?.let { runner -> ext.forInternalResend(runner.state) } ?: ext
                        },
                    )
                    return
                }
            }
            // A rejected client version usually means the catalog knows something this build does
            // not, so refresh it before the user retries. This covers both subscriptions: a
            // rejection that arrives while streaming would otherwise leave the stale version in
            // place until the next cold start.
            if (e is ProviderServiceError && e.isSubscriptionClientVersionRejection()) {
                runCatching { MetadataClient.refresh() }
            }
            if (tokenBuffer.hasPendingText()) {
                tokenBuffer.drainTextToAccumulated(System.currentTimeMillis())
                outputs.streamingText.value = tokenBuffer.accumulatedText
            }
            val (title, detail) = when (e) {
                is ContextRejectedError -> {
                    // A re-projection (the tool-loop first leg) was refused by the plan: the same notice as a pre-send refusal;
                    // the user message is already persisted and the assistant slot ends as failed, and the composer is not refilled.
                    contextRejections.emit(
                        ChatContextRejection(
                            conversationId = conversation.id,
                            reject = e.reject,
                            text = text,
                            attachments = attachments,
                            quoteContext = quoteContext?.takeIf { it.isValid },
                            restoresComposer = false,
                        ),
                    )
                    "Request Failed" to e.message
                }
                is ProviderServiceError.RelayUpstream -> e.title to (
                    e.guidanceCode?.persistenceKey ?: e.userMessage
                    )
                is ProviderServiceError -> e.title to failedMessageDetail(e)
                // Anything else is either a transport failure or a defect. Transport failures get
                // the network wording; a defect keeps its own message so the report is useful.
                else -> if (e.isTransientNetworkFailure()) {
                    val networkError = ProviderServiceError.Network(e.message ?: "Unknown error")
                    networkError.title to networkError.userMessage
                } else {
                    "Request Failed" to (e.message ?: "Unknown error")
                }
            }
            // Only a rejection that arrived before the first token can be blamed on the request
            // body. Once tokens have streamed, the request was accepted and the failure is
            // something else.
            val locatedRejection = if (!receivedUpstreamEvent) {
                val upstream = e as? ProviderServiceError.Upstream
                upstream?.let { error ->
                    (capabilityExecutionCollector.locateProviderRecipeRejection(
                        statusCode = error.statusCode,
                        rejectedParameter = error.rejectedParameter,
                    ) ?: capabilityExecutionCollector.locateCustomRejection(
                        statusCode = error.statusCode,
                        rejectedParameter = error.rejectedParameter,
                    ))?.let { located ->
                        ai.oriveo.community.core.provider.LocatedModelControlRejection(
                            source = located.source,
                            owner = located.owner,
                            recipeRef = located.recipeRef,
                            locatedPointers = located.locatedPointers,
                        )
                    }
                }
            } else null
            val canExplicitlyResend = locatedRejection != null &&
                canOfferExplicitModelControlResend(locatedRejection, receivedUpstreamEvent, e)
            if (canExplicitlyResend) {
                effectiveRequestOptions.modelControlRuntimeIdentity?.let { identity ->
                    // The recipe's thinking setting is recorded under the tier actually selected for this send, so the panel removes only the rejected tier.
                    ModelControlRejectionCache.recordLocated(
                        identity,
                        locatedRejection,
                        ModelControlRejectionCache.rejectedTier(
                            locatedRejection,
                            effectiveRequestOptions.capabilityPreferences?.reasoningIntent,
                        ),
                    )
                    CapabilityEvidenceObservationBridge.invalidate()
                }
            }
            val localFieldsRetryOwner = if (canExplicitlyResend) null else localFieldsRetryOwner(
                error = e,
                sentAdditionalBody = effectiveRequestOptions.additionalRequestBody,
                receivedUpstreamEvent = receivedUpstreamEvent,
                hadToolSideEffects = mcpToolSteps.isNotEmpty(),
            )
            val resendCode = localFieldsRetryOwner?.let { "$LOCAL_FIELDS_RETRY_OFFER_PREFIX$it" }
                ?: locatedRejection?.takeIf { canExplicitlyResend }?.let { located ->
                fun encode(value: String) = java.util.Base64.getUrlEncoder().withoutPadding()
                    .encodeToString(value.toByteArray(Charsets.UTF_8))
                val pointers = encode(located.locatedPointers.sorted().joinToString("\u001f"))
                val recipe = located.recipeRef?.let(::encode) ?: "-"
                "capability_setting_pre_token_400:${located.source}:${located.owner}:$recipe:$pointers"
            }
            val relayImageRejected = recordRelayImageRejection(
                provider = provider,
                model = model,
                messages = providerMessages,
                error = e,
                outputStarted = receivedUpstreamEvent,
                protocolSwitched = relayProtocolSwitchStarted.get(),
                sentTransport = relayFirstSend,
                localIdentity = requestOptions.capabilityEvidenceIdentity,
            )
            // An official connection's upstream rejected media on a narrow signature: write negative cache v2; the error is shown as is and not retried.
            // The failure card offers "resend without the image / file / video" for the rejected key: the next outbound projection is already rejected_recently, so a plain resend swaps in the placeholder.
            // The record key must be the same one the outbound projection looks up: the connection id comes from the request identity (the outbound projection uses it too) and the transport is the one actually dispatched this time;
            // when the identity is missing or does not match the connection the outbound side cannot find it, so it is better not to record than to record a wrong key.
            // "Sent this time" only counts messages that passed the outbound gate: history images already swapped for placeholders and files injected as text do not count; if the post-gate result is unavailable nothing is recorded.
            val officialInputRejection = model
                ?.takeIf { requestOptions.capabilityEvidenceIdentity?.connectionInstanceId == provider.id }
                ?.let { sent ->
                    val outboundMessages = ai.oriveo.community.core.capability.InputRejectionFlow.outboundMessages(
                        provider = provider,
                        model = sent,
                        messages = providerMessages,
                        dispatchTransport = capabilityExecutionCollector.inputDispatchTransport,
                    ) ?: return@let null
                    ai.oriveo.community.core.capability.InputRejectionFlow.recordOfficial(
                        provider = provider,
                        model = sent,
                        messages = outboundMessages,
                        error = e,
                        outputStarted = receivedUpstreamEvent,
                        finalTransport = capabilityExecutionCollector.inputDispatchTransport,
                    )
                }
            // A parameter rejected by the upstream on a narrow signature (temperature / top_p / structured_output / thinking): record a param negative cache entry;
            // the error is shown as is and not resent automatically; the failure card offers "resend without that parameter" and the next send omits it through GenerationParameterResolver. The key is the same as above.
            val officialParameterRejection = model
                ?.takeIf { requestOptions.capabilityEvidenceIdentity?.connectionInstanceId == provider.id }
                ?.let { sent ->
                    ai.oriveo.community.core.capability.InputRejectionFlow.recordOfficialParameter(
                        provider = provider,
                        model = sent,
                        error = e,
                        outputStarted = receivedUpstreamEvent,
                        dispatchTransport = capabilityExecutionCollector.inputDispatchTransport,
                    )
                }
            val inputRejectionResendCode = ai.oriveo.community.core.capability.InputRejectionFlow.recoveryCode(
                input = officialInputRejection,
                rejectedParameter = officialParameterRejection,
            )
            if (!receivedUpstreamEvent) recordRelayKeyAccessFailure(provider, runtimeModelId, e)
            // The coroutine is already cancelled (user stop / system interruption) when OkHttp first throws IOException("Canceled") and it lands here:
            // that is a stop and not a failure.
            val attemptCancelled = !currentCoroutineContext().isActive
            // The stream threw after a user stop: land as Interrupted / interrupted like the cancellation branch (a system interruption is still recorded as a transport error, see systemInterrupted).
            val userStopped = attemptCancelled && !outputs.systemInterrupted.get()
            val failedMessage = assistantPlaceholder.copy(
                text = outputs.streamingText.value.trim(),
                state = if (userStopped) ChatMessageState.Interrupted else ChatMessageState.Failed,
                // Overflow recovery failed (the resend overflowed again / output had already started / no checkpoint could be cut): context_window_exceeded, the failure styling stays as usual.
                stopReason = when {
                    userStopped -> StopReason.INTERRUPTED
                    overflowed -> StopReason.CONTEXT_WINDOW_EXCEEDED
                    else -> failureStopReason(e, hadContent = outputs.streamingText.value.isNotBlank())
                },
                errorTitle = if (userStopped) null else localFieldsFailureTitle(title, localFieldsRetryOwner),
                // Body of the hint card: a string-table key is stored and the display layer localizes it by key, with a Switch Model button on the card;
                // when both an image rejection and a file rejection hold, the image card wins.
                errorDetail = when {
                    userStopped -> null
                    relayImageRejected -> RELAY_IMAGE_UNSUPPORTED_DETAIL
                    // A failure after the fallback / switched hop already started producing output is a different matter and does not get the file-rejected marker.
                    relayFileRejected.get() && !receivedUpstreamEvent -> RELAY_FILE_UNSUPPORTED_DETAIL
                    else -> detail
                },
                // A rejected response is not observed success. Preserve only the production
                // dispatch facts; the exact recipe/custom locator is carried separately by CTA.
                capabilityExecutionResults = capabilityExecutionCollector.requestedResults(),
                // No provider-text heuristic is permitted here. This is only an explicit user
                // affordance for the production-located recipe/custom + pre-token HTTP 400 shape;
                // auth/rate-limit/5xx/network/stream failures keep the ordinary recovery card.
                customRetryWithoutFieldsAvailable = canExplicitlyResend || localFieldsRetryOwner != null,
                customRetryWithoutFieldsCode = resendCode ?: inputRejectionResendCode,
                reasoningText = tokenBuffer.accumulatedReasoningText.trim().takeIf { it.isNotEmpty() },
                attachments = streamingAttachments.ifEmpty { assistantPlaceholder.attachments },
                citations = accumulatedCitations.takeIf { it.isNotEmpty() } ?: assistantPlaceholder.citations,
                toolSteps = mcpToolSteps.takeIf { it.isNotEmpty() },
            ).withSearchReply(stopped = userStopped)
            // Inline images that arrived before the failure are extracted and saved too; the attempt may
            // already be cancelled, so saving must not be interrupted.
            val (failedText, failedAttachments) = withContext(NonCancellable) {
                imageProcessor.localizeInlineImages(failedMessage.text, failedMessage.attachments.orEmpty())
            }
            conversationRepository.updateMessage(
                conversation.id,
                failedMessage.copy(text = failedText.trim(), attachments = failedAttachments.ifEmpty { null }),
            )
            // A system interruption (sign-out / account switch / background expiry) writes no manifest; the message stopReason stays the transport error.
            if (!overflowed && !(attemptCancelled && outputs.systemInterrupted.get())) {
                // A cancelled attempt (OkHttp "Canceled" landing here) is recorded as interrupted; the coroutine is already cancelled, so the ledger write must not be interrupted.
                withContext(NonCancellable) {
                    recordChatLedger(
                        projection = webProjection ?: chatProjection,
                        conversationId = conversation.id,
                        transportKey = rhoTransportKey,
                        family = attemptFamily,
                        modelId = runtimeModelId,
                        observedInput = null,
                        textBytes = null,
                        stopReason = if (attemptCancelled) StopReason.INTERRUPTED else failedMessage.stopReason,
                    )
                }
            }
        } finally {
            outputs.streamingMessageId.value = null
            outputs.streamingText.value = ""
            outputs.streamingActivity.value = null
            tokenBuffer.clear()
        }
    }

    /**
     * Ledger write-back of one chat request: with [observedInput] and [textBytes] (a plain-text request) a rho sample is recorded;
     * a manifest is appended every time (transport = the wire string of [family], rho is still keyed by [transportKey]). Nothing is written without a projection
     * (not the main chat path) or without Room; a ledger failure does not affect sending.
     */
    private suspend fun recordChatLedger(
        projection: ChatContextProjection?,
        conversationId: String,
        transportKey: String,
        family: StopFamily,
        modelId: String,
        observedInput: Int?,
        textBytes: Int?,
        stopReason: StopReason?,
        /** false = this send had tool legs (so the input is not a single-leg chat), so no rho sample is recorded. */
        rhoEligible: Boolean = true,
    ) {
        val dao = contextLedgerDao ?: return
        projection ?: return
        runCatching {
            // When the request ended with context_window_exceeded, usage does not represent the full input, so no sample is recorded.
            if (rhoEligible && observedInput != null && textBytes != null && stopReason != StopReason.CONTEXT_WINDOW_EXCEEDED) {
                val current = dao.rho(transportKey, modelId)?.calibration ?: ai.oriveo.community.core.context.RhoCalibration()
                val next = current.recordingSample(observedInput, 0, textBytes)
                if (next != current) {
                    dao.upsertRho(ai.oriveo.community.core.data.entity.ContextRhoCalibrationEntity.of(transportKey, modelId, next))
                }
            }
            val manifest = ChatContextProjector.manifest(
                projection = projection,
                requestId = generateUuidString(),
                conversationId = conversationId,
                transport = family.wire,
                model = modelId,
                observedInput = observedInput,
                stopReason = stopReason,
                createdAt = System.currentTimeMillis(),
            )
            dao.appendManifest(ai.oriveo.community.core.data.entity.ContextManifestEntity.of(manifest))
        }
    }

    /** The rhoHi from the same source as sending (ledger calibration, by the conversation's provider and runtime model); falls back to RHO0 when the provider is gone. */
    suspend fun currentRhoHi(conversation: Conversation): Double {
        val provider = providerRepository.getById(conversation.providerID)
            ?: return ai.oriveo.community.core.context.ContextBudget.RHO0
        return rhoHiFor(provider, resolveSendModelSelection(provider, conversation.modelID).runtimeModelId)
    }

    private suspend fun rhoHiFor(provider: Provider, runtimeModelId: String): Double = withContext(Dispatchers.IO) {
        contextLedgerDao
            ?.rho(ChatContextProjector.rhoTransportKey(provider), runtimeModelId)
            ?.calibration?.rhoHi
            ?: ai.oriveo.community.core.context.ContextBudget.RHO0
    }

    /**
     * Manual compaction entry: trigger=manual, always uses the AI summary (the preference and the circuit breaker are ignored), falling back only when the remote switch is off.
     * The last message of the conversation is the current message (not in the span, counted in fixedTokens) and the rest is history; the system prompt and the snapshot come from
     * the same projection as a chat send (with the stored row applied). Returns noop, never throws, when there is no conversation / the conversation is empty / there is no provider or model / no coordinator is wired.
     * [chatContext]: the context request assembled by the caller the way a chat send does it (ChatSendCoordinator.manualCompactionContext,
     * including memory, skills and pinned notes); when omitted it is built from the conversation's memory switch, with no memory items and no skills.
     */
    suspend fun compactConversationNow(
        conversationId: String,
        chatContext: ai.oriveo.community.core.context.ChatContextRequest? = null,
        requestOptions: ChatRequestOptions? = null,
    ): ContextCompactionResult {
        val coordinator = contextCompaction ?: return noopCompaction()
        val inputs = compactionInputs(coordinator, conversationId, chatContext, requestOptions)
            ?: return noopCompaction()
        return coordinator.compact(
            conversationId,
            ContextCompactionTrigger.MANUAL,
            inputs.context,
            summarizeWith = inputs.summarizeWith,
        )
    }

    /**
     * Pre-compaction (composer focus or first input): only in AI mode (preference and remote switch and circuit breaker all llm) and with no AI compaction in progress
     * for this conversation, and only when P-hat >= 0.75 * B does it run compact(PRE_SEND). The projection is the same as the manual one;
     * P-hat = fixedTokens (already including the prefix and the current message) + the stored row estimate + the estimate of the history after coversTo.
     * An AI failure or cancellation stores no fallback row (returns noop, the circuit breaker still counts it); the 0.90 * B check before sending then handles it by mode.
     */
    suspend fun precompactIfNeeded(
        conversationId: String,
        chatContext: ai.oriveo.community.core.context.ChatContextRequest? = null,
        requestOptions: ChatRequestOptions? = null,
    ): ContextCompactionResult {
        val coordinator = contextCompaction ?: return noopCompaction()
        if (conversationId in coordinator.aiCompacting.value) return noopCompaction()
        if (!coordinator.aiMode(conversationId)) return noopCompaction()
        val inputs = compactionInputs(coordinator, conversationId, chatContext, requestOptions)
            ?: return noopCompaction()
        val context = inputs.context
        val stored = inputs.stored
        val afterCovers = stored?.let { row ->
            val index = context.messages.indexOfFirst { it.id == row.coversTo }
            context.messages.drop(index + 1)
        } ?: context.messages
        val pHat = context.fixedTokens +
            (stored?.let { ai.oriveo.community.core.context.ContextBudget.estimateText(it.text, context.rhoHi) } ?: 0) +
            afterCovers.sumOf { it.estTokens }
        val threshold = ai.oriveo.community.core.context.ContextBudget.derived(context.B.toLong()).preCompactAt
        if (pHat < threshold) return noopCompaction()
        return coordinator.compact(
            conversationId,
            ContextCompactionTrigger.PRE_SEND,
            context,
            summarizeWith = inputs.summarizeWith,
            fallback = false,
        )
    }

    /** The conversation's contextCap when set, otherwise the global default (unresolvable = auto). */
    private suspend fun effectiveBudgetCap(conversation: Conversation): ai.oriveo.community.core.context.ContextBudgetCap =
        conversation.contextCap ?: contextDefaultCap()

    private fun noopCompaction() =
        ContextCompactionResult(ai.oriveo.community.core.context.CompactOutcome.NOOP, null, emptyList())

    /** Coordinator input, stored row and summary call shared by manual compaction and pre-compaction. */
    private class CompactionInputs(
        val provider: Provider,
        val stored: ContextCheckpointRecord?,
        val context: ContextCompactionContext,
        val summarizeWith: suspend (ai.oriveo.community.core.context.SummaryRequest) -> String?,
    )

    private suspend fun compactionInputs(
        coordinator: ContextCompactionCoordinator,
        conversationId: String,
        chatContext: ai.oriveo.community.core.context.ChatContextRequest?,
        requestOptions: ChatRequestOptions?,
    ): CompactionInputs? {
        val conversation = conversationRepository.getWithMessages(conversationId) ?: return null
        val messages = conversation.messages
        val current = messages.lastOrNull() ?: return null
        val provider = providerRepository.getById(conversation.providerID) ?: return null
        val model = ProviderSelectionSnapshot.selectedModel(provider, conversation.modelID) ?: return null
        val runtimeModelId = resolveSendModelSelection(provider, conversation.modelID).runtimeModelId
        val rhoHi = rhoHiFor(provider, runtimeModelId)
        val history = ChatContextProjector.compactionHistory(messages, rhoHi)
        val stored = coordinator.latestValid(
            conversation.id,
            history.map { ai.oriveo.community.core.context.CheckpointCoveredMessage(it.id, it.text) },
        )
        // The projection requires the current message to be a user message; when the last one is an assistant reply it is projected as a user message, taking only the system prompt and the budget without changing the history.
        val projectionMessages = messages.dropLast(1) +
            if (current.role == ChatRole.User) current else current.copy(role = ChatRole.User)
        val projection = withContext(Dispatchers.IO) {
            ChatContextProjector.project(
                request = chatContext ?: ai.oriveo.community.core.context.ChatContextRequest(
                    conversation = ai.oriveo.community.core.context.ContextConversation(
                        id = conversation.id,
                        useMemory = conversation.useMemory,
                        instructions = conversation.instructions,
                    ),
                ),
                rawMessages = projectionMessages,
                // Same as a chat send: the window carries the panel's max output (requestOptions.generationParameters).
                window = ChatContextProjector.window(
                    provider,
                    model,
                    (requestOptions ?: ChatRequestOptions()).copy(activeModel = model),
                    effectiveBudgetCap(conversation),
                ),
                rhoHi = rhoHi,
                checkpoint = stored,
                memoryFallback = false,
            )
        } ?: return null
        val B = projection.plan.budget.B ?: return null
        return CompactionInputs(
            provider = provider,
            stored = stored,
            context = compactionContext(projection, history, B, rhoHi, runtimeModelId),
            summarizeWith = { request ->
                summarizeForCompaction(request, projection, provider, model, runtimeModelId)
            },
        )
    }

    /** Coordinator input: prefix = system, fixed = system + the current message (the same for pre-send / overflow / manual). */
    private fun compactionContext(
        projection: ChatContextProjection,
        history: List<ContextCompactionMessage>,
        B: Int,
        rhoHi: Double,
        runtimeModelId: String,
    ): ContextCompactionContext {
        val systemTokens = projection.system
            ?.let { ai.oriveo.community.core.context.ContextBudget.estimateMessage(it, rhoHi) } ?: 0
        val currentTokens = projection.messages.lastOrNull()?.text
            ?.let { ai.oriveo.community.core.context.ContextBudget.estimateMessage(it, rhoHi) } ?: 0
        return ContextCompactionContext(
            messages = history,
            B = B,
            U = projection.windowBudget?.U ?: B,
            rhoHi = rhoHi,
            prefixTokens = systemTokens,
            fixedTokens = systemTokens + currentTokens,
            model = runtimeModelId,
        )
    }

    /**
     * Pre-send step one: project with the latestValid stored row applied (no in-memory fallback), for the refusal decision.
     * When no projection comes out it falls back to the in-memory fallback projection. A chat send that is not refused records one turn.
     */
    private suspend fun storedProjection(
        coordinator: ContextCompactionCoordinator,
        conversationId: String,
        history: List<ContextCompactionMessage>,
        useStored: (ContextCheckpointRecord?) -> Unit,
        project: suspend (memoryFallback: Boolean) -> ChatContextProjection?,
    ): ChatContextProjection? {
        useStored(
            coordinator.latestValid(
                conversationId,
                history.map { ai.oriveo.community.core.context.CheckpointCoveredMessage(it.id, it.text) },
            ),
        )
        val first = project(false) ?: return project(true)
        if (first.reject != null) return first
        coordinator.recordTurn(conversationId)
        return first
    }

    /**
     * Pre-send step two (after the user message and the assistant placeholder are persisted): only when the plan is still required after applying the stored row
     * is compaction handed to the coordinator (previous = that row); a new row is used to re-project; on noop or a compaction error it falls back to the plain behavior
     * (the in-memory fallback runs only when there is no stored row).
     */
    private suspend fun compactedProjection(
        coordinator: ContextCompactionCoordinator,
        conversationId: String,
        first: ChatContextProjection,
        provider: Provider,
        model: ai.oriveo.community.core.model.AIModel?,
        runtimeModelId: String,
        history: List<ContextCompactionMessage>,
        rhoHi: Double,
        useStored: (ContextCheckpointRecord?) -> Unit,
        project: suspend (memoryFallback: Boolean) -> ChatContextProjection?,
    ): ChatContextProjection? {
        if (!first.compactionRequired) return first
        val B = first.plan.budget.B ?: return project(true)
        val row = try {
            coordinator.compact(
                conversationId,
                ContextCompactionTrigger.PRE_SEND,
                compactionContext(first, history, B, rhoHi, runtimeModelId),
                summarizeWith = { request ->
                    summarizeForCompaction(request, first, provider, model, runtimeModelId)
                },
            ).row
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Exception) {
            android.util.Log.w("ChatRepository", "pre-send compaction failed: ${e.message}")
            null
        }
        row?.let(useStored)
        return project(true) ?: first
    }

    /**
     * Rollback of a send whose pre-send confirmation was cancelled: only the device copy of this pair of messages is deleted; the checkpoint is kept as usual,
     * nothing is recorded as stopped / failed; the rollback marker travels through the refusal channel to refill the composer. When the conversation has no messages
     * left after the deletion (the first send was cancelled) it turns back into a draft (the same as iOS isDraft = messages.isEmpty): it does not show in the list.
     */
    private suspend fun rollBackUnconfirmedSend(
        conversationId: String,
        messageIds: List<String>,
        rejection: ChatContextRejection,
    ) {
        val deleted = if (messageIds.isNotEmpty()) {
            conversationRepository.deleteMessagesLocally(conversationId, messageIds, draftWhenEmpty = true)
        } else {
            emptyList()
        }
        // Attachments may have been uploaded and had a storageRef filled in while the gate was suspended: the payload takes the attachments of the deleted user row, otherwise the chat screen cannot clear them.
        val deletedUser = rejection.userMessageId?.let { id -> deleted.firstOrNull { it.id.equals(id, ignoreCase = true) } }
        contextRejections.emit(
            deletedUser?.let { rejection.copy(attachments = it.attachments) } ?: rejection,
        )
    }

    /**
     * Cancelled before the request went out (stopped during compaction): the placeholder ends as Interrupted just like a stop before the first token, keeping the existing text;
     * a system interruption records the stopReason as a transport error. The request was never sent, so nothing is written to the ledger.
     */
    private suspend fun finalizeStoppedBeforeOutput(
        conversationId: String,
        placeholder: ChatMessage,
        initialText: String,
        outputs: ai.oriveo.community.core.streaming.ConversationStreamingOutputs,
        cause: CancellationException,
    ) {
        val stopReason = if (outputs.systemInterrupted.get()) {
            failureStopReason(cause, hadContent = initialText.isNotBlank())
        } else {
            StopReason.INTERRUPTED
        }
        withContext(NonCancellable) {
            conversationRepository.updateMessage(
                conversationId,
                placeholder.copy(text = initialText.trim(), state = ChatMessageState.Interrupted, stopReason = stopReason),
            )
            continuationAccountId()?.let { accountId -> continuationStore?.markInterrupted(accountId, placeholder.id) }
        }
    }

    /**
     * After an overflow, compact through the coordinator with compact(overflow) and store the row; B is the failed request's plan B (estimatedInput when W is unknown).
     * Returns the newly stored row; null on noop or a compaction error (the caller falls back to the in-memory fallback, the resend condition unchanged).
     */
    private suspend fun overflowCompaction(
        coordinator: ContextCompactionCoordinator,
        conversationId: String,
        failed: ChatContextProjection,
        B: Int,
        provider: Provider,
        model: ai.oriveo.community.core.model.AIModel?,
        runtimeModelId: String,
        history: List<ContextCompactionMessage>,
        rhoHi: Double,
    ): ContextCheckpointRecord? = try {
        coordinator.compact(
            conversationId,
            ContextCompactionTrigger.OVERFLOW,
            compactionContext(failed, history, B, rhoHi, runtimeModelId),
            summarizeWith = { request ->
                summarizeForCompaction(request, failed, provider, model, runtimeModelId)
            },
        ).row
    } catch (e: kotlin.coroutines.cancellation.CancellationException) {
        throw e
    } catch (e: Exception) {
        android.util.Log.w("ChatRepository", "overflow compaction failed: ${e.message}")
        null
    }

    /**
     * Summary call for compaction: a one-shot call on this conversation's provider / model (the same channel as the memory draft);
     * system = req.system ?: the chat plan's system, with no tools, no [D], no extra memory, and the output cap = req.maxOutputTokens.
     */
    private suspend fun summarizeForCompaction(
        request: ai.oriveo.community.core.context.SummaryRequest,
        chat: ChatContextProjection,
        provider: Provider,
        model: ai.oriveo.community.core.model.AIModel?,
        runtimeModelId: String,
    ): String {
        val service = providerRepository.serviceFor(provider, model)
        val messages = request.messages.map { message ->
            ChatMessage(
                id = generateUuidString(),
                role = message.role,
                text = message.text,
                providerID = provider.id,
                providerKind = provider.kind,
                providerName = provider.displayName,
                modelID = runtimeModelId,
                modelName = model?.name ?: runtimeModelId,
                state = ChatMessageState.Delivered,
            )
        }
        val transport = PlannedChatRequest.compaction(chat, request.system, messages).transportInput(
            ChatRequestOptions(
                outputTokenBudget = request.maxOutputTokens,
                activeModel = model,
            ),
        )
        val done = service.sendMessage(
            apiKey = ProviderCredentialResolver.apiKey(provider, runtimeModelId),
            modelID = runtimeModelId,
            messages = transport.messages,
            baseUrl = ai.oriveo.community.core.provider.transport.OfficialEndpointSource.effectiveBaseUrlText(provider),
            supportsImageGen = false,
            reasoningMode = ReasoningMode.Automatic,
            webSearchEnabled = false,
            requestOptions = transport.options,
        )
        return done.result.text
    }

    /**
     * The confirmation gate: suspends until the user confirms; both false and cancellation roll back the messages this send just wrote first.
     * Like the two helpers below, it folds a group of suspending calls from sendMessage into one suspension point: every extra suspension point adds a set of
     * saved / restored locals to the sendMessage state machine, and once the bytecode gets close to the 64KB limit MockK's inline instrumentation fails to rewrite it,
     * so mocks fall through to the real implementation.
     */
    private suspend fun confirmContextCapOrRollBack(
        gate: ai.oriveo.community.core.context.ContextCapConfirmCoordinator,
        request: ai.oriveo.community.core.context.ContextCapConfirmRequest,
        rollBack: suspend () -> Unit,
    ): Boolean {
        val proceed = try {
            gate.confirm(request)
        } catch (e: CancellationException) {
            withContext(NonCancellable) { rollBack() }
            throw e
        }
        if (!proceed) withContext(NonCancellable) { rollBack() }
        return proceed
    }

    /** Feeds back the rho prediction miss of an overflow failure (only when not multi-leg) and appends one ledger row. */
    private suspend fun recordOverflowAttempt(
        projection: ChatContextProjection,
        ledgerProjection: ChatContextProjection,
        recordMiss: Boolean,
        conversationId: String,
        transportKey: String,
        family: StopFamily,
        modelId: String,
    ) {
        if (recordMiss) recordOverflowMiss(projection, transportKey, modelId)
        recordChatLedger(
            projection = ledgerProjection,
            conversationId = conversationId,
            transportKey = transportKey,
            family = family,
            modelId = modelId,
            observedInput = null,
            textBytes = null,
            stopReason = StopReason.CONTEXT_WINDOW_EXCEEDED,
        )
    }

    /** Predicted P-hat < U yet the request overflowed: raises rho as an overflow miss and writes it back. */
    private suspend fun recordOverflowMiss(projection: ChatContextProjection, transportKey: String, modelId: String) {
        val dao = contextLedgerDao ?: return
        val estimated = projection.plan.budget.estimatedInput ?: return
        val usable = projection.windowBudget?.U ?: return
        if (estimated >= usable) return
        runCatching {
            val current = dao.rho(transportKey, modelId)?.calibration ?: ai.oriveo.community.core.context.RhoCalibration()
            dao.upsertRho(
                ai.oriveo.community.core.data.entity.ContextRhoCalibrationEntity.of(transportKey, modelId, current.recordingOverflowMiss()),
            )
        }
    }

    /**
     * Deterministic rejection test for the first leg with host tools: the same matcher as the tool leg (a 4xx), and not "this key may not use this model".
     */
    private fun isToolsRejection(error: Throwable): Boolean {
        val providerError = error as? ProviderServiceError ?: return false
        val status = providerError.httpStatus ?: return false
        if (providerError.relayKeyAccess?.outcome == ai.oriveo.community.core.model.RelayKeyAccessOutcome.ModelAccessDenied) {
            return false
        }
        return ai.oriveo.community.core.provider.ToolUnsupportedErrorMatcher.matches(status, providerError.rawBody.orEmpty())
    }

    /**
     * Tools rejected (matcher and the resend without tools unchanged): a relay records the `toolCall` negative cache only on a rejected signal
     * and no longer writes false into the old tool memory; other kinds write the tool memory as before.
     * The key follows the protocol actually sent: when the first send went out on Messages but fell back to Chat because of attachments, the rejection is recorded under the Chat key,
     * so it does not pollute the Messages key the next ordinary send reads.
     */
    private fun recordToolsRejected(
        provider: Provider,
        model: AIModel,
        error: ai.oriveo.community.core.tools.ToolsUnsupportedError,
        sentTransport: RelayTransport?,
    ) {
        val key = sentTransport?.let { ai.oriveo.community.core.provider.relay.RelayNegativeCache.keyFor(provider, model, it) }
            ?: ai.oriveo.community.core.provider.relay.RelayNegativeCache.keyFor(provider, model)
        if (key != null) {
            relayNegativeCache.recordIfRejected(
                key,
                ai.oriveo.community.core.provider.relay.RelayNegativeCache.Kind.ToolCall,
                error.upstream,
            )
            return
        }
        toolCallMemoryStore?.record(
            partitionId = providerRepository.currentCapabilityPartitionId(),
            provider = provider,
            model = model,
            observedToolCall = false,
            reason = "tools_rejected_4xx",
        )
    }

    /**
     * Image input rejected: record `image` only when the request carried an image and the model has no positive evidence of image support at any level
     * (see [relayImageRejectionRecords]). Returns whether it was recorded, which decides whether the failed message shows the hint card.
     */
    private fun recordRelayImageRejection(
        provider: Provider,
        model: AIModel?,
        messages: List<ChatMessage>,
        error: Throwable,
        outputStarted: Boolean,
        protocolSwitched: Boolean,
        /** The protocol this first send actually used (including the attachment rule); a switched send is not recorded, so this is the protocol it went out on. */
        sentTransport: RelayTransport? = null,
        /** Local connection identity: the v2 revision uses the same vision verdict, with connection evidence, as the projection. */
        localIdentity: ai.oriveo.community.core.model.CapabilityEvidenceIdentity? = null,
    ): Boolean {
        val sent = model ?: return false
        val key = sentTransport?.let { ai.oriveo.community.core.provider.relay.RelayNegativeCache.keyFor(provider, sent, it) }
            ?: ai.oriveo.community.core.provider.relay.RelayNegativeCache.keyFor(provider, sent)
            ?: return false
        if (messages.none { message -> message.attachments.orEmpty().any { it.kind == AttachmentKind.Image } }) return false
        val rejected = ai.oriveo.community.core.provider.relay.RelayNegativeCache.isRejectionSignal(error)
        val relayIdentity = ai.oriveo.community.core.capability.truth.relayInputIdentity(provider, sent, localIdentity)
        if (!relayImageRejectionRecords(provider, sent, rejected, outputStarted, protocolSwitched, relayIdentity)) return false
        relayNegativeCache.record(key, ai.oriveo.community.core.provider.relay.RelayNegativeCache.Kind.Image)
        ai.oriveo.community.core.capability.InputRejectionFlow.recordRelay(
            ai.oriveo.community.core.capability.truth.relayInputNegativeCacheTarget(
                provider = provider,
                model = sent,
                transport = key.transport,
                key = ai.oriveo.community.core.provider.CapabilityEvidenceFacade.VISION_INPUT,
                relayIdentity = relayIdentity,
            ),
            inputNegativeCache,
        )
        return true
    }

    /**
     * Writes back the key-access verdict of a relay's non-2xx response before any output: "no access" is recorded on the model, an invalid / limited key is recorded on that key's status
     * (also for a single key); a failed write does not stop this message from failing as usual.
     */
    private suspend fun recordRelayKeyAccessFailure(provider: Provider, modelID: String, error: Throwable) {
        if (provider.kind != ProviderKind.Relay) return
        val signal = ai.oriveo.community.core.provider.relay.RelayKeyAccess.signalOf(error) ?: return
        if (signal.outcome == ai.oriveo.community.core.model.RelayKeyAccessOutcome.None) return
        val keyID = ai.oriveo.community.core.provider.relay.RelayKeyBinding.effectiveKeyID(provider, modelID)
        try {
            providerRepository.recordRelayKeyAccess(provider.id, modelID, keyID, signal, provider)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // The next rejection of the same kind records it again.
        }
    }

    /**
     * A send succeeded on the same key: clear the model's no-access marker for it and write that key back as ok; nothing is touched in storage when there is nothing to change.
     * The model's "not connected" state is cleared first, regardless of whether the key status changed.
     */
    private suspend fun recordRelayKeyAccessSuccess(provider: Provider, modelID: String) {
        if (provider.kind != ProviderKind.Relay) return
        try {
            providerRepository.clearRelayModelProbeFailure(provider.id, modelID)
        } catch (_: Exception) {
            // It is only in-memory state; failing to clear it does not affect the delivered message.
        }
        val keyID = ai.oriveo.community.core.provider.relay.RelayKeyBinding.effectiveKeyID(provider, modelID)
        if (!ai.oriveo.community.core.provider.relay.RelayKeyAccess.successChanges(provider, modelID, keyID)) return
        try {
            providerRepository.recordRelayKeyAccessSuccess(provider.id, modelID, keyID, provider)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // A failed write-back does not affect the delivered message.
        }
    }

    /** A protocol-level fallback switched protocol successfully: a failed write-back does not affect the delivered message. */
    private suspend fun recordRelayProtocolFallback(
        provider: Provider,
        model: AIModel,
        sentTransport: RelayTransport,
        transport: RelayTransport,
    ) {
        try {
            providerRepository.recordRelayProtocolFallback(provider.id, model.id, sentTransport, transport)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            // The next identical 404 / 415 switches again.
        }
    }

    /** The resend without the web fragment succeeded: a failed write-back does not affect the delivered message. */
    private fun recordRelayWebRejected(
        provider: Provider,
        model: AIModel?,
        transport: RelayTransport,
        fragment: kotlinx.serialization.json.JsonObject?,
    ) {
        if (provider.kind != ProviderKind.Relay || model == null || fragment == null) return
        relayWebProbeRecords.record(
            ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore.Key(provider.id, model.id, transport.value),
            ai.oriveo.community.core.provider.relay.RelayWebProbeRecord(
                result = ai.oriveo.community.core.provider.relay.RelayWebProbeResult.Rejected,
                source = ai.oriveo.community.core.provider.relay.RelayWebProbeSource.Tested,
                at = relayWebProbeRecords.now(),
                fragmentHash = ai.oriveo.community.core.provider.relay.RelayWebProbe.fragmentHash(fragment),
            ),
        )
    }

    /** A failed write-back does not affect the delivered message. */
    private fun recordRelayWebObserved(
        provider: Provider,
        model: AIModel?,
        transport: RelayTransport?,
        fragment: kotlinx.serialization.json.JsonObject?,
    ) {
        if (provider.kind != ProviderKind.Relay || model == null || transport == null || fragment == null) return
        relayWebProbeRecords.record(
            ai.oriveo.community.core.provider.relay.RelayWebProbeRecordStore.Key(provider.id, model.id, transport.value),
            ai.oriveo.community.core.provider.relay.RelayWebProbeRecord(
                result = ai.oriveo.community.core.provider.relay.RelayWebProbeResult.Searched,
                source = ai.oriveo.community.core.provider.relay.RelayWebProbeSource.Observed,
                at = relayWebProbeRecords.now(),
                fragmentHash = ai.oriveo.community.core.provider.relay.RelayWebProbe.fragmentHash(fragment),
            ),
        )
    }

    private suspend fun promoteRelayModelAfterDelivery(provider: Provider, model: AIModel, sentTransport: RelayTransport) {
        try {
            providerRepository.promoteRelayModelToObserved(provider.id, model.id, sentTransport)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            // The next delivered message tries again; the finished send is not disturbed by this step.
        }
    }

    /**
     * Checkpoints a message that is still generating.
     *
     * The screen reads the streaming text from a flow, not from the row, so this write is only
     * about surviving process death: without it, killing the app mid-answer loses everything that
     * had already arrived. It is throttled rather than per-token because each write invalidates the
     * message window query.
     *
     * What actually keeps that invalidation off the screen is
     * [ai.oriveo.community.core.data.repository.chat.messageWindowSnapshotsEquivalent]: a
     * checkpoint column never reaches `toDomain()` while the message is still generating. Without
     * it, a re-emitted window maps all of its rows again — several JSON fields per message — and
     * hands the list a new set of instances, so every visible cell recomposes along with its
     * markdown subtree. Check that predicate before changing which columns this method writes.
     */
    suspend fun flushPartialToMessage(
        messageId: String,
        text: String,
        reasoningText: String? = null,
    ) {
        // NonCancellable: this often runs while the surrounding scope is already going away, and
        // that is exactly the case the checkpoint exists for.
        withContext(NonCancellable) {
            // Inline images stay out of the partial: one generated image can push the row past the
            // CursorWindow limit. On completion the images are extracted from the full in-memory text.
            val partialText = StreamingImageProcessor.stripInlineImageData(text)
            if (partialText.isNotBlank()) {
                conversationRepository.updatePartialText(messageId, partialText)
            }
            if (!reasoningText.isNullOrBlank()) {
                conversationRepository.updatePartialReasoning(messageId, reasoningText)
            }
        }
    }

    companion object {
        /** The assistant's replay-style continuation kinds that the service replays (same across platforms): on a continue the outbound history drops the target. */
        private val REPLAY_CONTINUATION_KINDS = setOf("replay_blocks", "replay_reasoning")
        /** imageGen routes that use a dedicated image generation endpoint: the request purpose is imageGeneration. */
        internal val DEDICATED_IMAGE_GEN_ROUTES = setOf("images_api", "dashscope_multimodal", "minimax_image_generation")

        /** Key of the hint card body on the failed message after a relay's image input was rejected upstream (string table relay_image_unsupported_hint). */
        const val RELAY_IMAGE_UNSUPPORTED_DETAIL =
            "This model doesn't support images. Switch to another model to send them."

        /** Key of the hint card body on the failed message after a relay request with native file blocks was rejected and the fallback did not save it (string table relay_file_unsupported_hint). */
        const val RELAY_FILE_UNSUPPORTED_DETAIL =
            "This model doesn't support these files. Switch to another model to send them."

        /** Checkpoint after this many buffered characters, or this long, whichever comes first. */
        internal const val PARTIAL_FLUSH_CHAR_THRESHOLD = 4000
        internal const val PARTIAL_FLUSH_TIME_THRESHOLD_MS = 60_000L
    }
}

/** Automatic resend after an overflow: the same assistant message plus the fallback projection. Only [ChatRepository.sendMessage] constructs it. */
class ChatOverflowRecovery internal constructor(
    internal val assistant: ChatMessage,
    internal val projection: ChatContextProjection,
    /** The row the coordinator just stored after the overflow; null = in-memory fallback. */
    internal val checkpoint: ContextCheckpointRecord? = null,
    /** The effective tier of the failed send: the resend reuses it instead of re-reading the global value. */
    internal val budgetCap: ai.oriveo.community.core.context.ContextBudgetCap? = null,
)

/**
 * Protocol family of this request by wire protocol: obtained the same way as the StopFamily each service uses when parsing the stream
 * (Anthropic / Gemini / OpenAI Responses; a relay by the protocol actually delivered; everything else is OpenAI-compatible Chat).
 */
internal fun chatStopFamily(provider: Provider, relayTransport: RelayTransport?): StopFamily = when (provider.kind) {
    ProviderKind.Anthropic -> StopFamily.ANTHROPIC
    ProviderKind.Gemini -> StopFamily.GEMINI
    ProviderKind.OpenAI -> StopFamily.OPENAI_RESPONSES
    ProviderKind.Relay -> when (relayTransport) {
        RelayTransport.AnthropicMessages -> StopFamily.ANTHROPIC
        RelayTransport.GeminiGenerateContent -> StopFamily.GEMINI
        RelayTransport.OpenAIResponses -> StopFamily.OPENAI_RESPONSES
        RelayTransport.LlamaCppNative -> StopFamily.LLAMA_CPP
        else -> StopFamily.OPENAI_CHAT
    }
    else -> StopFamily.OPENAI_CHAT
}

/** Stop-reason protocol family to overflow-detection family: mostly the same name; Interactions maps to gemini and native llama.cpp to openai_compatible. */
internal fun overflowFamilyOf(family: StopFamily): OverflowFamily = when (family) {
    StopFamily.OPENAI_CHAT -> OverflowFamily.OPENAI_CHAT
    StopFamily.OPENAI_RESPONSES -> OverflowFamily.OPENAI_RESPONSES
    StopFamily.ANTHROPIC -> OverflowFamily.ANTHROPIC
    StopFamily.GEMINI, StopFamily.GEMINI_INTERACTIONS -> OverflowFamily.GEMINI
    StopFamily.LLAMA_CPP -> OverflowFamily.OPENAI_COMPATIBLE
    else -> OverflowFamily.OPENAI_CHAT
}

/** Protocol family of this request: the family of the finish the stream delivered if there is one, otherwise the wire protocol actually used. */
internal fun chatRequestFamily(finish: StreamFinish?, provider: Provider, relayTransport: RelayTransport?): StopFamily =
    finish?.family ?: chatStopFamily(provider, relayTransport)

/** The stream finish an error carries (terminal frame / EOF type); null otherwise. */
internal fun errorStreamFinish(error: Throwable): StreamFinish? = when (error) {
    is ProviderServiceError.Upstream -> error.streamFinish
    else -> null
}

/**
 * An HTTP error that carries a status code is judged by the overflow rules (extraPatterns empty); 401 / 429 / 5xx never count.
 * An empty-body ending ([ProviderServiceError.EmptyResponse]) whose stream finish resolves to context_window_exceeded
 * also counts as an overflow and takes the same recovery as an HTTP overflow; a stream that already produced output does not throw and ends as usual.
 */
internal fun isContextOverflow(error: Throwable, family: OverflowFamily, emptyStreamFinish: StreamFinish? = null): Boolean {
    if (error is ProviderServiceError.EmptyResponse && emptyStreamFinish != null) {
        val reason = StopReasonResolver.resolve(emptyStreamFinish.family, emptyStreamFinish.ended, emptyStreamFinish.finishRaw, false)
        if (ContextOverflowClassifier.isOverflow(reason)) return true
    }
    val providerError = error as? ProviderServiceError ?: return false
    val status = providerError.httpStatus ?: return false
    return ContextOverflowClassifier.classify(family, status, providerError.rawBody.orEmpty()).overflow
}

/** Denominator of a rho sample: the sum of the UTF-8 byte counts of the system prompt and the text of every outbound message. */
internal fun chatRequestTextBytes(systemPrompt: String?, messages: List<ChatMessage>): Int =
    ai.oriveo.community.core.context.ContextBudget.utf8Bytes(systemPrompt.orEmpty()) +
        messages.sumOf { ai.oriveo.community.core.context.ContextBudget.utf8Bytes(it.text) }

/**
 * The memoryItemIds stored on the assistant message: the ids of the memory items actually injected into this request (a tool loop takes the plan of the last leg); an empty list is stored as null.
 * A failed message from a streaming error does not record this request's value; a continue that injected no items this time keeps the ids the message already has, and new ids overwrite them.
 */
internal fun deliveredMemoryItemIds(
    sentMemoryIds: List<String>?,
    previous: List<String>?,
    isContinue: Boolean,
    delivered: Boolean,
): List<String>? = sentMemoryIds?.takeIf { delivered && it.isNotEmpty() } ?: previous?.takeIf { isContinue && it.isNotEmpty() }

/** When the first leg and the tail leg both have text, join them with a blank line; if either is empty, take the other. */
internal fun joinProposeLegTexts(first: String, tail: String): String = when {
    first.isEmpty() -> tail
    tail.isEmpty() -> first
    else -> first + "\n\n" + tail
}

/**
 * A tool loop's / tail leg's usage as pricing legs: each leg of [ToolLoopUsage.perLeg] (its usage comes from the same parser as that provider's
 * ordinary chat, with cache buckets and the upstream's actual charge) becomes one leg and they are combined through
 * [ai.oriveo.community.core.provider.DeliveredCostResolver.mergeLegs]; at delivery each leg is priced (the leg's actual upstream charge, else an estimate)
 * and then added per currency. A leg that returned no usage ([ToolLoopUsage.allLegsReported]) counts as missing usage and makes the whole result unknown.
 * A subscription connection is judged by the delivery layer from the connection's authMode, so it is not marked here.
 */
internal fun toolLoopLegResult(
    usage: ai.oriveo.community.core.tools.ToolLoopUsage?,
    model: AIModel?,
): ProviderChatResult {
    val hasKnownPrice = (model?.promptPrice ?: 0.0) > 0.0 || (model?.completionPrice ?: 0.0) > 0.0
    val estimateSource = if (hasKnownPrice) CostSource.LOCAL_ESTIMATE.name else CostSource.UNKNOWN.name
    val perLeg = usage?.perLeg() ?: listOf(null)
    // The merge flag says some leg returned no usage but the breakdown holds no empty leg (the old path only gave a total): add an empty leg so the whole result is unknown.
    val legs = if (usage?.allLegsReported == false && perLeg.none { it == null }) perLeg + null else perLeg
    return ai.oriveo.community.core.provider.DeliveredCostResolver.mergeLegs(
        legs.map { breakdown ->
            breakdown?.let {
                val upstream = it.upstreamCost
                ProviderChatResult(
                    text = "",
                    promptTokens = it.totalInputTokens,
                    completionTokens = it.completionTokens,
                    estimatedCost = upstream ?: 0.0,
                    cachedInputTokens = it.reportedCachedInputTokens,
                    cacheCreation5mTokens = it.reportedCacheCreation5mTokens,
                    cacheCreation1hTokens = it.reportedCacheCreation1hTokens,
                    costSource = if (upstream != null) CostSource.UPSTREAM.name else estimateSource,
                    usageReported = true,
                )
            }
        },
    )
}

/**
 * The stopReason of a normal ending: when Done carries a finish it is resolved from it;
 * when Done carries no finish (non-streaming, a tool loop) it is unknown.
 */
internal fun deliveredStopReason(finish: StreamFinish?, hadContent: Boolean): StopReason =
    when {
        finish != null -> StopReasonResolver.resolve(finish.family, finish.ended, finish.finishRaw, hadContent)
        else -> StopReason.UNKNOWN
    }

/**
 * The stopReason of a thrown ending: when the error carries a stream finish (terminal frame / EOF type) it is resolved from it, otherwise as a transport error
 * (transport_error and error_frame follow the same rule: incomplete when there is content, error when there is none).
 */
internal fun failureStopReason(error: Throwable, hadContent: Boolean): StopReason {
    val finish = errorStreamFinish(error)
    return if (finish != null) {
        StopReasonResolver.resolve(finish.family, finish.ended, finish.finishRaw, hadContent)
    } else {
        StopReasonResolver.resolve(StopFamily.OPENAI_CHAT, StreamEnding.TRANSPORT_ERROR, null, hadContent)
    }
}

internal fun shouldEnableWebSearchForSend(
    provider: Provider,
    requested: Boolean,
    model: AIModel? = null,
): Boolean {
    if (!requested) return false
    if (provider.kind != ProviderKind.Relay) return true
    return RelayRuntimeSupport.supportsWebSearch(
        provider = provider,
        runtimeConfig = MetadataClient.relayRuntimeConfig(),
        model = model,
    )
}

/** Whether a relay must stream: the image generation verdict (including the image generation override) x the inline-tool rule of Responses. */
internal fun relayForcesStream(
    provider: Provider,
    model: AIModel?,
    transport: RelayTransport,
): Boolean = model != null && RelayRuntimeSupport.shouldForceStream(
    transport,
    ai.oriveo.community.core.provider.relay.relayDispatchesImageGeneration(provider, model),
)

/**
 * The text this round's result appends after [initialText]: an explicit "continue" (non-empty original) uses the untrimmed rawText, preserving whitespace / newlines at the start of the continuation;
 * a new answer (empty original) uses the trimmed text as before.
 */
internal fun ProviderChatResult.appendedText(initialText: String): String =
    if (initialText.isEmpty()) text else rawText ?: text

/**
 * Whether a request with images that was rejected should record `image`: it is a rejected signal, no output has started, this message has not switched protocol,
 * and the model has no positive evidence of image support at any level.
 */
internal fun relayImageRejectionRecords(
    provider: Provider,
    model: AIModel,
    rejected: Boolean,
    outputStarted: Boolean,
    protocolSwitched: Boolean,
    relayIdentity: ai.oriveo.community.core.provider.CapabilityEvidenceFacade.QueryIdentity? = null,
): Boolean {
    if (!rejected || outputStarted || protocolSwitched) return false
    return relayImageSupportUnknown(provider, model, relayIdentity)
}

/**
 * The model has no positive evidence of image support at any level (the record decision and the "unknown" image state in the model options use this same predicate):
 * an override of true or an engine declaration of true counts as positive evidence; otherwise the facade's image support level is read ([relayIdentity] comes from
 * [ai.oriveo.community.core.capability.truth.relayInputIdentity], with the protocol following the first send), and supported / accepted (including
 * catalog or model declarations) is positive evidence while anything else is unconfirmed. A missing connection identity fails closed as unconfirmed.
 */
internal fun relayImageSupportUnknown(
    provider: Provider,
    model: AIModel,
    relayIdentity: ai.oriveo.community.core.provider.CapabilityEvidenceFacade.QueryIdentity? = null,
): Boolean {
    if (model.relayCapabilityOverrides?.image == true) return false
    if (!provider.relayRequested?.engineProfile.isNullOrBlank() && model.engineDeclaration?.image == true) return false
    return ai.oriveo.community.core.capability.truth.relayVisionInputSupport(provider, model, relayIdentity) !in
        setOf("supported", "accepted")
}

/**
 * When the first-send protocol differs from the effective protocol and this message did not switch protocol, what to write back as observed after delivery:
 * (the effective protocol when the send started, the first-send protocol); otherwise null.
 */
internal fun relayFirstSendObservedTransport(
    provider: Provider,
    model: AIModel?,
    firstSend: RelayTransport?,
    protocolSwitched: Boolean,
): Pair<RelayTransport, RelayTransport>? {
    if (provider.kind != ProviderKind.Relay || model == null || firstSend == null || protocolSwitched) return null
    val effective = RelayEndpointResolver.effectiveTransport(provider, model)
    return (effective to firstSend).takeIf { firstSend != effective }
}

/**
 * Whether this send should go compare "reachable to observed" in the store; if so, returns the effective protocol when the send started.
 * [model] is the snapshot at send start, and the effective protocol computed from it is the one this send used. Whether anything is actually written is decided by the model in the store at completion
 * (source reachable and protocol equal to it, see [ProviderRepository.promoteRelayModelToObserved]): a model that followed the connection at the start and was lazily verified to the same protocol as reachable midway is promoted too.
 * A failure or a partial reply does not touch the store.
 */
internal fun relayObservedPromotionTransport(provider: Provider, model: AIModel?, delivered: Boolean): RelayTransport? {
    if (!delivered || provider.kind != ProviderKind.Relay || model == null) return null
    return RelayEndpointResolver.effectiveTransport(provider, model)
}

internal data class SendModelSelection(
    val runtimeModelId: String,
    val storedModelId: String,
    val modelName: String,
    val supportsImageGen: Boolean,
)

internal fun resolveSendModelSelection(
    provider: Provider,
    modelID: String,
): SendModelSelection {
    val model = ProviderSelectionSnapshot.selectedModel(provider, modelID)
    return SendModelSelection(
        runtimeModelId = model?.id ?: modelID,
        storedModelId = model?.let { ModelSelectionUtils.preferredStoredModelIdentifier(it, provider.kind) }
            ?: ModelSelectionUtils.resolvedId(modelID),
        modelName = model?.name ?: modelID,

        // A model-level image generation override of a relay wins.
        supportsImageGen = when {
            model == null -> false
            provider.kind == ProviderKind.Relay ->
                ai.oriveo.community.core.provider.relay.relayDispatchesImageGeneration(provider, model)
            else -> model.capabilities.contains(ModelCapability.ImageGen) && !model.imageGenProfile.isNullOrBlank()
        },
    )
}

/** A re-projection before sending (the tool-loop first leg) was refused by the plan: it shows the context refusal notice and is not treated as an ordinary send failure. */
internal class ContextRejectedError(
    val reject: ai.oriveo.community.core.context.ContextReject,
) : IllegalStateException("context rejected: ${reject.wire}")
