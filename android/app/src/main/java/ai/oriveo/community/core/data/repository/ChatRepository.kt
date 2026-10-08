package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.attachments.AttachmentHydrator
import ai.oriveo.community.core.attachments.OutboundAttachmentBudget
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.streaming.StreamingImageProcessor
import ai.oriveo.community.core.data.repository.streaming.StreamingTokenBuffer
import ai.oriveo.community.core.data.repository.streaming.failedMessageDetail
import ai.oriveo.community.core.data.repository.streaming.isSubscriptionClientVersionRejection
import ai.oriveo.community.core.error.isTransientNetworkFailure
import ai.oriveo.community.core.model.Attachment
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
import ai.oriveo.community.core.model.QuotePromptBuilder
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RequestPreferenceResolver
import ai.oriveo.community.core.provider.transport.CitationParser
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.model.ToolCallDelta
import ai.oriveo.community.core.provider.DeliveredCostResolver
import ai.oriveo.community.core.provider.CostSource
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.core.provider.ModelSelectionUtils
import ai.oriveo.community.core.model.UnhandledToolCall
import ai.oriveo.community.core.provider.NativeToolCallAccumulator
import ai.oriveo.community.core.provider.ToolCallMemoryStore
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.core.provider.RelayRuntimeSupport
import ai.oriveo.community.core.provider.RelayService
import ai.oriveo.community.core.provider.ModelControlRejectionCache
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.CapabilityControlResolution
import ai.oriveo.community.core.model.RelayImageConfig
import ai.oriveo.community.core.model.RelayImageMode
import ai.oriveo.community.core.model.RelayTransport

import ai.oriveo.community.core.util.generateUuidString
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
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
) {
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
        antiForgetText: String? = null,
        requestOptions: ChatRequestOptions = ChatRequestOptions(),
        outputs: ConversationStreamingOutputs,
        persistUserMessage: Boolean = true,
        userMessageAlreadyInHistory: Boolean = false,
        appendToAssistant: ChatMessage? = null,
    ) {
        val sendStartedAtMs = System.currentTimeMillis()
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
        if (persistUserMessage) {
            conversationRepository.addMessage(conversation.id, userMessage)
        }

        val preservesGeneratedContent = appendToAssistant?.customRetryWithoutFieldsCode
            ?.startsWith("omit_capability_setting_once:") == true

        val assistantMessageId: String
        val assistantPlaceholder: ChatMessage
        val initialText: String
        if (appendToAssistant != null) {
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

        val outboundUserMessage = antiForgetText
            ?.takeIf { it.isNotBlank() }
            ?.let { context ->
                userMessage.copy(text = "${userMessage.text}\n\n$context")
            }
            ?: userMessage
        val rawMessages = if (userMessageAlreadyInHistory) {
            existingMessages
        } else {
            existingMessages + outboundUserMessage
        }
        // Failed and interrupted messages are dropped from the outbound history: sending a half
        // finished answer back as context teaches the model to continue producing broken output.
        val sanitizedMessages = MessageBuilder.sanitizeOutboundMessages(
            rawMessages,
            keepAssistantId = appendToAssistant?.id,
        )
        val quotedMessages = QuotePromptBuilder.applyToMessages(sanitizedMessages)
        val allMessages = withContext(Dispatchers.IO) {
            // Attachment bytes are loaded on IO and capped before hydration, so a conversation
            // with several large files cannot build a request too big to send.
            val budgeted = OutboundAttachmentBudget.apply(
                messages = quotedMessages,
                imageSizeOf = { localImageId -> attachmentStore.imageSizeBytes(localImageId) },
                blobSizeOf = { ref -> attachmentStore.blobSizeBytes(ref) },
            )
            AttachmentHydrator.hydrate(
                messages = budgeted,
                loadImageBase64 = { localImageId -> attachmentStore.loadBase64(localImageId) },
                loadBlobBase64 = { ref -> attachmentStore.loadBlobBase64(ref) },
            )
        }
        val service by lazy { providerRepository.serviceFor(provider) }
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
        var effectiveApiKey = provider.apiKey
        var effectiveRequestOptions = if (provider.kind == ProviderKind.Relay) {
            requestOptions.copy(
                relayRequested = provider.relayRequested,
                relayImage = provider.relayImage,
                capabilityExecutionCollector = capabilityExecutionCollector,
            )
        } else {
            requestOptions.copy(capabilityExecutionCollector = capabilityExecutionCollector)
        }
        // This is evaluated from the frozen request carrier, never from the store after a failure:
        // a settings edit while an HTTP call is in flight must not manufacture a retry affordance.
        val sentCustomFragments = effectiveRequestOptions.localCustomFragments.ifEmpty {
            effectiveRequestOptions.localCustomFragment?.let {
                mapOf(effectiveRequestOptions.localCustomOwner to it)
            }.orEmpty()
        }
        var receivedUpstreamEvent = false

        val effectiveReasoning = reasoningMode
        val effectiveWebSearchEnabled = shouldEnableWebSearchForSend(
            provider = provider,
            requested = webSearchEnabled,
        )
        var providerMessages = if (appendToAssistant != null) {
            // The target UI partial is presentation state, not protocol continuation state.
            // Services insert the opaque sidecar block before the new user turn.
            allMessages.filterNot { it.id == appendToAssistant.id }
        } else {
            allMessages
        }

        var relayUpstreamModelId = runtimeModelId
        var relayUseImagesEndpoint = false
        val relayTransport = provider.relayRequested?.transport ?: RelayTransport.Auto
        if (provider.kind == ProviderKind.Relay && supportsImageGen) {
            when (RelayRuntimeSupport.imageRoute(relayTransport)) {
                RelayRuntimeSupport.ImageRoute.Unsupported ->
                    throw ProviderServiceError.InvalidConfiguration(
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
                            throw ProviderServiceError.InvalidConfiguration(
                                RELAY_IMAGE_CHAT_MODEL_REQUIRED_KEY,
                            )
                    }
                }

                RelayRuntimeSupport.ImageRoute.GeminiModality -> Unit
            }
        }

        val streamingAttachments = appendToAssistant?.attachments.orEmpty()
            .takeIf { preservesGeneratedContent }.orEmpty().toMutableList()
        val useNonStreamingRelayRuntime =
            provider.kind == ProviderKind.Relay &&
                effectiveRequestOptions.relayRequested?.stream == false &&

                !RelayRuntimeSupport.shouldForceStream(
                    relayTransport,
                    model?.capabilities ?: emptyList(),
                )

        try {
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

                // Remote MCP: tools are assembled only when this conversation has a server switched
                // on and this connection can carry tools; otherwise the plan is empty and the request
                // takes the usual path. Image generation never goes through the tool loop.
                val mcpPlan = if (relayUseImagesEndpoint || supportsImageGen) {
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
                if (!mcpPlan.isEmpty) {
                    // The tool loop produces the final answer itself, leg by leg, over whichever of
                    // the four wire protocols this connection speaks.
                    val runner = checkNotNull(mcpChatToolRunner)
                    runner.clearStepLimitReached(assistantMessageId)
                    val activeModel = checkNotNull(model)
                    var legText = ""
                    val mcpResult = try {
                        runner.run(
                            conversationId = conversation.id,
                            provider = provider,
                            model = activeModel,
                            modelId = runtimeModelId,
                            messages = providerMessages,
                            systemPrompt = effectiveRequestOptions.systemPrompt,
                            reasoningMode = effectiveReasoning,
                            requestOptions = effectiveRequestOptions,
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
                        ) { event ->
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
                        }
                    } catch (error: ai.oriveo.community.core.tools.ToolsUnsupportedError) {
                        // Only a deterministic 4xx on the first leg, before any structured tool call
                        // was seen, is remembered as "this connection does not support tools"; the
                        // next send then leaves the MCP tools out. This send fails with the usual
                        // error card.
                        if (error.legIndex == 0 && !error.receivedStructuredToolCalls) {
                            toolCallMemoryStore?.record(
                                partitionId = providerRepository.currentCapabilityPartitionId(),
                                provider = provider,
                                model = activeModel,
                                toolCall = false,
                                reason = "tools_rejected_4xx",
                            )
                        }
                        throw error.upstream
                    }
                    // At the step limit the steps block ends with a line saying that the answer below
                    // is based on the results gathered so far.
                    if (mcpResult.stepLimitReached) runner.markStepLimitReached(assistantMessageId)
                    if (mcpResult.receivedStructuredToolCalls) {
                        toolCallMemoryStore?.record(
                            partitionId = providerRepository.currentCapabilityPartitionId(),
                            provider = provider,
                            model = activeModel,
                            toolCall = true,
                            reason = "structured_tool_calls_observed",
                        )
                    }
                    outputs.streamingText.value = initialText + mcpResult.text
                    if (tokenBuffer.hasPendingReasoning()) {
                        outputs.streamingReasoning.value = tokenBuffer.accumulatedReasoningText
                        tokenBuffer.markReasoningFlushed(System.currentTimeMillis())
                    }
                    val hasKnownPrice = (activeModel.promptPrice ?: 0.0) > 0.0 ||
                        (activeModel.completionPrice ?: 0.0) > 0.0
                    finalResult = ProviderChatResult(
                        text = mcpResult.text,
                        promptTokens = mcpResult.usage?.promptTokens ?: 0,
                        completionTokens = mcpResult.usage?.completionTokens ?: 0,
                        citations = accumulatedCitations.takeIf { it.isNotEmpty() },
                        costSource = if (hasKnownPrice) CostSource.LOCAL_ESTIMATE.name else CostSource.UNKNOWN.name,
                    )
                    toolLoopAnswered = true
                }

                if (toolLoopAnswered) {
                    // The tool loop already produced the final answer; no second provider request.
                } else if (relayUseImagesEndpoint) {
                    val done = (service as RelayService).generateImageViaImagesEndpoint(
                        apiKey = effectiveApiKey,
                        modelID = relayUpstreamModelId,
                        messages = providerMessages,
                        baseUrl = provider.baseUrlText,
                        requestOptions = effectiveRequestOptions,
                    )
                    finalResult = done.result
                    outputs.streamingText.value = initialText + done.result.text
                    done.result.attachments?.let { streamingAttachments.addAll(it) }
                } else if (supportsImageGen && provider.kind != ProviderKind.Relay) {
                    val done = service.sendMessage(
                        apiKey = effectiveApiKey,
                        modelID = relayUpstreamModelId,
                        messages = providerMessages,
                        baseUrl = provider.baseUrlText,
                        supportsImageGen = true,
                        reasoningMode = effectiveReasoning,
                        webSearchEnabled = effectiveWebSearchEnabled,
                        requestOptions = effectiveRequestOptions,
                    )
                    finalResult = done.result

                    outputs.streamingText.value = initialText + done.result.text
                    done.result.attachments?.let { streamingAttachments.addAll(it) }
                } else if (useNonStreamingRelayRuntime) {
                    val done = service.sendMessage(
                        apiKey = effectiveApiKey,
                        modelID = relayUpstreamModelId,
                        messages = providerMessages,
                        baseUrl = provider.baseUrlText,
                        supportsImageGen = supportsImageGen,
                        reasoningMode = effectiveReasoning,
                        webSearchEnabled = effectiveWebSearchEnabled,
                        requestOptions = effectiveRequestOptions,
                    )
                    finalResult = done.result

                    outputs.streamingText.value = initialText + done.result.text
                    done.result.attachments?.let { streamingAttachments.addAll(it) }
                } else {
                    // Only a user-explicit continue/retry reaches this branch (`appendToAssistant`).
                    // Normal send and app start never read the sidecar. Valid state is acknowledged
                    // only after the provider call completes, so a network failure remains retryable.
                    val continuationState = if (appendToAssistant != null) {
                        continuationAccountId()?.let { accountId ->
                            continuationStore?.loadForExplicit(accountId, assistantMessageId)?.also {
                                loadedContinuation = it
                            }?.state
                        }
                    } else {
                        null
                    }
                    val serviceOptions = effectiveRequestOptions.copy(
                        localContinuationMessageId = assistantMessageId,
                        localContinuationState = continuationState,
                        localContinuationExplicit = appendToAssistant != null,
                    )
                    service.sendMessageStream(
                        apiKey = effectiveApiKey,
                        modelID = relayUpstreamModelId,
                        messages = providerMessages,
                        baseUrl = provider.baseUrlText,
                        supportsImageGen = supportsImageGen,
                        reasoningMode = effectiveReasoning,
                        webSearchEnabled = effectiveWebSearchEnabled,
                        requestOptions = serviceOptions,
                    ).collect { event ->
                        receivedUpstreamEvent = true
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
                            }
                        }
                    }
                    loadedContinuation?.takeIf {
                        finalResult != null && !producedContinuationThisRound
                    }?.let { snapshot ->
                        continuationStore?.acknowledge(snapshot)
                    }
                }

                val result = finalResult
                // The streamed text is authoritative when it is longer than what the terminal
                // event reported: some providers return an abridged final body, and trusting it
                // would visibly truncate an answer the user already read.
                val streamedFull = outputs.streamingText.value
                val finalText = if (initialText.isEmpty()) {
                    result?.text?.ifBlank { streamedFull } ?: streamedFull
                } else if (streamedFull.length > initialText.length) {
                    streamedFull
                } else {
                    initialText + result?.text.orEmpty()
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
                            toolCall = true,
                            reason = "structured_tool_calls_observed",
                        )
                    }
                }
                val generationCost = DeliveredCostResolver.resolve(result, model, provider.kind)
                val generationCostStatus = if (DeliveredCostResolver.isUnknownPricing(result, model, provider.kind)) {
                    "unknown"
                } else {
                    "priced"
                }

                if (displayText.isBlank() && streamingAttachments.isEmpty() && unhandledToolCalls.isEmpty()) {
                    throw ProviderServiceError.EmptyResponse
                }

                unhandledToolCalls.forEach { call ->
                    if (model?.toolCall == false) {
                    }
                }

                val finalCitations = mergeIncomingCitations(result?.citations.orEmpty())

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
                    estimatedCost = generationCost,
                    state = ChatMessageState.Delivered,
                    attachments = streamingAttachments.ifEmpty { result?.attachments },
                    citations = finalCitations.takeIf { it.isNotEmpty() },
                    unhandledToolCalls = (
                        assistantPlaceholder.unhandledToolCalls + unhandledToolCalls
                    ).distinctBy { it.id },
                    toolFallbackNotice = localToolFallbackNotice ?: assistantPlaceholder.toolFallbackNotice,
                    toolSteps = mcpToolSteps.takeIf { it.isNotEmpty() },
                    capabilityExecutionResults = capabilityExecutionCollector.successfulTerminalResults() +
                        localCapabilityExecutionResults,
                    inputTokens = addUsage(assistantPlaceholder.inputTokens, roundInputTokens),
                    outputTokens = addUsage(assistantPlaceholder.outputTokens, roundOutputTokens),
                    cachedInputTokens = addUsage(assistantPlaceholder.cachedInputTokens, roundCacheReadTokens),
                    cacheCreationInputTokens = addUsage(
                        assistantPlaceholder.cacheCreationInputTokens,
                        roundCacheWriteTokens,
                    ),
                    cacheCreation5mTokens = result?.cacheCreation5mTokens,
                    cacheCreation1hTokens = result?.cacheCreation1hTokens,
                    costSource = result?.costSource,
                )
                conversationRepository.updateMessage(conversation.id, deliveredMessage)
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
            val interruptedMessage = assistantPlaceholder.copy(
                text = outputs.streamingText.value.trim(),
                state = ChatMessageState.Interrupted,
                attachments = streamingAttachments.ifEmpty { null },
                reasoningText = tokenBuffer.accumulatedReasoningText.trim().takeIf { it.isNotEmpty() },
                reasoningDurationMs = cancelDurationMs,
                citations = accumulatedCitations.takeIf { it.isNotEmpty() }
                    ?: assistantPlaceholder.citations,
                capabilityExecutionResults = capabilityExecutionCollector.requestedResults(),
                toolSteps = mcpToolSteps.takeIf { it.isNotEmpty() },
            )
            // NonCancellable: the surrounding scope is already cancelled, so an ordinary write
            // here would be skipped and the partial answer lost.
            withContext(NonCancellable) {
                conversationRepository.updateMessage(conversation.id, interruptedMessage)
                continuationAccountId()?.let { accountId ->
                    continuationStore?.markInterrupted(accountId, assistantMessageId)
                }
            }
            throw e
        } catch (e: Exception) {
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
                    locatedRejection.locatedPointers.forEach { pointer ->
                        ModelControlRejectionCache.record(
                            identity = identity,
                            owner = locatedRejection.owner,
                            source = locatedRejection.source,
                            setting = pointer,
                            recipeRef = locatedRejection.recipeRef,
                        )
                    }
                    CapabilityEvidenceObservationBridge.invalidate()
                }
            }
            val resendCode = locatedRejection?.takeIf { canExplicitlyResend }?.let { located ->
                fun encode(value: String) = java.util.Base64.getUrlEncoder().withoutPadding()
                    .encodeToString(value.toByteArray(Charsets.UTF_8))
                val pointers = encode(located.locatedPointers.sorted().joinToString("\u001f"))
                val recipe = located.recipeRef?.let(::encode) ?: "-"
                "capability_setting_pre_token_400:${located.source}:${located.owner}:$recipe:$pointers"
            }
            val failedMessage = assistantPlaceholder.copy(
                text = outputs.streamingText.value.trim(),
                state = ChatMessageState.Failed,
                errorTitle = title,
                errorDetail = detail,
                // A rejected response is not observed success. Preserve only the production
                // dispatch facts; the exact recipe/custom locator is carried separately by CTA.
                capabilityExecutionResults = capabilityExecutionCollector.requestedResults(),
                // No provider-text heuristic is permitted here. This is only an explicit user
                // affordance for the production-located recipe/custom + pre-token HTTP 400 shape;
                // auth/rate-limit/5xx/network/stream failures keep the ordinary recovery card.
                customRetryWithoutFieldsAvailable = canExplicitlyResend,
                customRetryWithoutFieldsCode = resendCode,
                reasoningText = tokenBuffer.accumulatedReasoningText.trim().takeIf { it.isNotEmpty() },
                attachments = streamingAttachments.ifEmpty { assistantPlaceholder.attachments },
                citations = accumulatedCitations.takeIf { it.isNotEmpty() } ?: assistantPlaceholder.citations,
                toolSteps = mcpToolSteps.takeIf { it.isNotEmpty() },
            )
            conversationRepository.updateMessage(conversation.id, failedMessage)
        } finally {
            outputs.streamingMessageId.value = null
            outputs.streamingText.value = ""
            outputs.streamingActivity.value = null
            tokenBuffer.clear()
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
            if (text.isNotBlank()) {
                conversationRepository.updatePartialText(messageId, text)
            }
            if (!reasoningText.isNullOrBlank()) {
                conversationRepository.updatePartialReasoning(messageId, reasoningText)
            }
        }
    }

    companion object {
        /** Checkpoint after this many buffered characters, or this long, whichever comes first. */
        internal const val PARTIAL_FLUSH_CHAR_THRESHOLD = 4000
        internal const val PARTIAL_FLUSH_TIME_THRESHOLD_MS = 60_000L
    }
}

internal fun shouldEnableWebSearchForSend(
    provider: Provider,
    requested: Boolean,
): Boolean {
    if (!requested) return false
    if (provider.kind != ProviderKind.Relay) return true
    return RelayRuntimeSupport.supportsWebSearch(
        provider = provider,
        runtimeConfig = MetadataClient.relayRuntimeConfig(),
    )
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
        storedModelId = model?.let(ModelSelectionUtils::preferredStoredModelIdentifier)
            ?: ModelSelectionUtils.resolvedId(modelID),
        modelName = model?.name ?: modelID,

        supportsImageGen = model?.capabilities?.contains(ModelCapability.ImageGen) == true &&
            (provider.kind == ProviderKind.Relay || !model.imageGenProfile.isNullOrBlank()),
    )
}
