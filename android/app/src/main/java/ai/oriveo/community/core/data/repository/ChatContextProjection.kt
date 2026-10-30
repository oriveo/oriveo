package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.DirectiveDetector
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.context.ContextAssembleInput
import ai.oriveo.community.core.context.ContextBlockKind
import ai.oriveo.community.core.context.ContextConversation
import ai.oriveo.community.core.context.ContextLibraryEntry
import ai.oriveo.community.core.context.CheckpointFallbackMessage
import ai.oriveo.community.core.context.ContextAssembler
import ai.oriveo.community.core.context.ContextBudget
import ai.oriveo.community.core.context.ContextCheckpoint
import ai.oriveo.community.core.context.ContextCompactionAdvice
import ai.oriveo.community.core.context.ContextDynamicInput
import ai.oriveo.community.core.context.ContextMaxOutput
import ai.oriveo.community.core.context.ContextMessage
import ai.oriveo.community.core.context.ContextPlan
import ai.oriveo.community.core.context.ContextReject
import ai.oriveo.community.core.context.ContextWindowBudget
import ai.oriveo.community.core.context.ContextWindowInput
import ai.oriveo.community.core.context.ContextBasis
import ai.oriveo.community.core.context.ContextManifest
import ai.oriveo.community.core.context.ContextManifestSegment
import ai.oriveo.community.core.context.StopReason
import ai.oriveo.community.core.context.ContextWindowKind
import ai.oriveo.community.core.context.RequestPurpose
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.QuotePromptBuilder
import ai.oriveo.community.core.tools.ToolLoopMessage
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

/**
 * Projection result of one chat request: the system prompt and the outbound history both come from the same [ContextPlan].
 * The constructor is private: instances can only be obtained from a plan via [of], system is always plan.system,
 * and callers cannot assemble their own.
 */
internal class ChatContextProjection private constructor(
    val plan: ContextPlan,
    /** plan.system; no system prompt is sent when null. */
    val system: String?,
    /** App messages mapped back from plan.messages (attachments are restored by message id, before the attachment budget / backfill). */
    val messages: List<ChatMessage>,
    /** The plan refused to send: no request is made and no message is persisted. */
    val reject: ContextReject? = null,
    /** Window budget of this request (used to judge whether an overflow was a prediction miss). */
    val windowBudget: ContextWindowBudget? = null,
    /** Id of the first tail message when the fallback cut a checkpoint; null when no fallback ran. */
    val tailFrom: String? = null,
    /** Checkpoint text carried by this outbound request (stored row or in-memory fallback); null when neither (used for the stateful continuation fingerprint). */
    val checkpointText: String? = null,
    /** checkpointId of the stored row applied to this request; null when no row was applied (including the in-memory fallback). Written into the manifest so the usage panel can tell whether it was cleared. */
    val checkpointId: String? = null,
    /** After applying the stored row (before any in-memory fallback) the plan is still compaction=required: the send path hands off to the coordinator to compact. */
    val compactionRequired: Boolean = false,
) {
    /** Outbound plan for this projection; the transport only accepts its [PlannedChatRequest.transportInput]. */
    val planned: PlannedChatRequest by lazy { PlannedChatRequest.from(this) }

    companion object {
        fun of(
            plan: ContextPlan,
            messages: List<ChatMessage>,
            reject: ContextReject? = null,
            windowBudget: ContextWindowBudget? = null,
            tailFrom: String? = null,
            checkpointText: String? = null,
            checkpointId: String? = null,
            compactionRequired: Boolean = false,
        ): ChatContextProjection = ChatContextProjection(
            plan = plan,
            system = plan.system,
            messages = messages,
            reject = reject,
            windowBudget = windowBudget,
            tailFrom = tailFrom,
            checkpointText = checkpointText,
            checkpointId = checkpointId,
            compactionRequired = compactionRequired,
        )
    }
}

/** The only input handed to ProviderService: outbound messages plus options that already carry the plan system and [D]. */
internal class TransportInput(
    val messages: List<ChatMessage>,
    val options: ChatRequestOptions,
) {
    /**
     * Messages for the first leg of a tool loop (library agent / MCP): the plan system (options.systemPrompt, which
     * already contains the toolSafety section) goes at index 0, followed by [history] (the neutral shape mapped
     * from [messages]). The tool loop's system message is produced only here; nothing is sent when system is empty.
     */
    fun toolLoopMessages(history: List<ToolLoopMessage>): List<ToolLoopMessage> {
        val system = options.systemPrompt.takeIf { it.isNotBlank() } ?: return history
        return listOf(ToolLoopMessage("system", system)) + history
    }
}

/**
 * Outbound plan obtainable only from [ChatContextProjection] (i.e. a projection of ContextPlan).
 * The system prompt is written into options only here; the last user message in [messages] still has [D] appended
 * with "\n\n", and [dynamicText] is the original text of the [D] blocks joined with "\n\n".
 */
internal class PlannedChatRequest private constructor(
    val plan: ContextPlan,
    /** plan.system; no system prompt is sent when null. */
    val system: String?,
    /** App messages projected back from the plan messages. */
    val messages: List<ChatMessage>,
    /** The current user's [D] blocks (joined with "\n\n"); null when there is no [D]. */
    val dynamicText: String?,
) {
    /**
     * [outbound] is the outbound message list derived from [messages] (the same set after attachment budget / backfill and library re-projection); defaults to [messages].
     */
    fun transportInput(
        options: ChatRequestOptions,
        outbound: List<ChatMessage> = messages,
        /** false = the last outbound user message was swapped back to the original text without [D] (relay image generation), so dynamicText is cleared. */
        withDynamic: Boolean = true,
    ): TransportInput =
        TransportInput(
            messages = outbound,
            options = options.copy(systemPrompt = system.orEmpty(), dynamicText = dynamicText.takeIf { withDynamic }),
        )

    companion object {
        /**
         * Compaction summary call: system = the summary request's [summarySystem] ?: this chat plan's system,
         * outbound = the summary request messages [messages]; no [D] (tools / extra memory were never outside the plan system anyway).
         */
        internal fun compaction(
            chat: ChatContextProjection,
            summarySystem: String?,
            messages: List<ChatMessage>,
        ): PlannedChatRequest = PlannedChatRequest(
            plan = chat.plan,
            system = summarySystem ?: chat.system,
            messages = messages,
            dynamicText = null,
        )

        internal fun from(projection: ChatContextProjection): PlannedChatRequest {
            val plan = projection.plan
            val dynamic = plan.messages?.lastOrNull()
                ?.takeIf { it.role == ChatRole.User }
                ?.blocks
                ?.filter { it.kind == ContextBlockKind.DYNAMIC }
                ?.takeIf { it.isNotEmpty() }
                ?.joinToString("\n\n") { it.text }
            return PlannedChatRequest(
                plan = plan,
                system = projection.system,
                messages = projection.messages,
                dynamicText = dynamic,
            )
        }
    }
}

/**
 * Stateful continuation fingerprint: {digest of plan.system, wire model id, digest of checkpoint text}.
 * Recorded at the same moment as previousResponseId, kept in memory only and never persisted; if it cannot be read it counts as changed.
 */
internal data class ContinuationFingerprint(
    val systemDigest: String,
    val wireModelId: String,
    val checkpointDigest: String,
) {
    companion object {
        fun of(projection: ChatContextProjection, wireModelId: String): ContinuationFingerprint =
            ContinuationFingerprint(
                systemDigest = digest(projection.system),
                wireModelId = wireModelId,
                checkpointDigest = digest(projection.checkpointText),
            )

        private fun digest(text: String?): String {
            if (text == null) return ""
            val bytes = java.security.MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
            return bytes.joinToString("") { "%02x".format(it) }
        }
    }
}

/** Assembler projection for the main chat path: only assembles and maps, never touches the network or the database. */
internal object ChatContextProjector {
    /** Parameter id of the panel's "max output" setting. */
    private const val MAX_OUTPUT_PARAMETER_ID = "max_output_tokens"

    /** Connection key of the ledger rho: the connection instance id. */
    fun rhoTransportKey(provider: Provider): String = provider.id

    /**
     * W / windowKind / O chain: the recipe output cap has no source yet, so it is left empty and the budget function falls back.
     * The surcharge threshold T is looked up on demand from the metadata's pricing.longContext by (kind, modelId) and is not written into AIModel.
     * [budgetCap] = the effective tier (conversation contextCap ?: global default); single-purpose callers leave it out and get auto.
     */
    fun window(
        provider: Provider,
        model: AIModel?,
        requestOptions: ChatRequestOptions,
        budgetCap: ai.oriveo.community.core.context.ContextBudgetCap = ai.oriveo.community.core.context.ContextBudgetCap.Auto,
    ): ContextWindowInput =
        ContextWindowInput(
            W = model?.contextLength,
            windowKind = ContextWindowKind.TOTAL,
            maxOutput = ContextMaxOutput(
                user = userMaxOutput(requestOptions),
                recipe = null,
                model = model?.maxOutputTokens,
            ),
            budgetCap = budgetCap,
            priceLineTokens = priceLineTokens(provider.kind, model?.id),
        )

    /** Server-ordered models and Relay never use a surcharge threshold; the rest are looked up synchronously in the official catalog, and a miss means no T. */
    internal fun priceLineTokens(kind: ProviderKind, modelId: String?): Int? {
        if (modelId.isNullOrBlank() || kind.usesServerOrderedModels || kind == ProviderKind.Relay) return null
        return MetadataClient.resolveCatalogModel(modelId, kind)?.longContext?.thresholdTokens
    }

    private fun userMaxOutput(requestOptions: ChatRequestOptions): Int? {
        val override = requestOptions.generationParameters?.values?.get(MAX_OUTPUT_PARAMETER_ID) ?: return null
        if (override.state != GenerationOverrideState.Value) return null
        return (override.value as? JsonPrimitive)?.intOrNull?.takeIf { it > 0 }
    }

    /**
     * The last of [rawMessages] must be the current user turn; quotes are expanded into the body before handing off to the assembler.
     * With [purpose] = CONTINUE, [rawMessages] is cut at the target assistant (inclusive) and a placeholder user message is appended;
     * the assembler swaps the placeholder for [ContextAssembler.CONTINUE_PROMPT], and [keepAssistantId] = the target assistant.
     * When the plan refuses to send, a projection carrying [ChatContextProjection.reject] is returned (messages empty);
     * when there is no current user turn or the plan yields no messages, null is returned and the caller takes the legacy path.
     * With compaction=required, a deterministic pre-send fallback runs first (the checkpoint goes to the assembler and lands before the first user message of the tail), then assembly runs once more.
     * A non-null [overflowFallbackB] means a resend after overflow: the fallback runs regardless of the compaction advice, B is the plan's B, and when W is unknown
     * it takes this value (the failed request's estimatedInput); when no checkpoint can be cut, [ChatContextProjection.tailFrom] is null.
     * A non-null [library] is this turn's library evidence (direct / server retrieval), one entry per document in `<oriveo-library>` of [D]; an empty list means searched and found nothing.
     * [toolSafety] goes into the final segment of the system prompt only when [purpose] = TOOL_LOOP_LEG (safety hints for library / MCP tool loops).
     * A non-null [checkpoint] is a valid stored row: only history after coversTo is taken, and the row text goes to the assembler just like the in-memory fallback;
     * if coversTo is not in the history it is treated as absent. Once a stored row is applied, the in-memory fallback for required is skipped.
     * With [memoryFallback] = false, required does not run the in-memory fallback (the send path hands off to the coordinator first and re-projects with true on noop).
     * [oldSummary] = the summary of the conversation's current checkpoint winner: every deterministic fallback carries it; pass null when there is none.
     */
    fun project(
        request: ChatContextRequest,
        rawMessages: List<ChatMessage>,
        window: ContextWindowInput,
        rhoHi: Double,
        overflowFallbackB: Int? = null,
        library: List<ContextLibraryEntry>? = null,
        /** External search delivery for [D] (after the library envelope); see [ContextDynamicInput.web]. */
        web: String? = null,
        purpose: RequestPurpose = RequestPurpose.CHAT,
        keepAssistantId: String? = null,
        /** Assistant slot reused by a retry (the same write target as [keepAssistantId]): it is the message this turn writes, so history gets no compact search record for it. */
        recordExcludeId: String? = null,
        toolSafety: String? = null,
        checkpoint: ContextCheckpointRecord? = null,
        memoryFallback: Boolean = true,
        oldSummary: String? = null,
    ): ChatContextProjection? {
        val quoted = QuotePromptBuilder.applyToMessages(rawMessages)
        val current = quoted.lastOrNull()?.takeIf { it.role == ChatRole.User } ?: return null
        fun assemble(history: List<ContextMessage>, checkpointText: String? = null) = ContextAssembler.assemble(
            ContextAssembleInput(
                purpose = purpose,
                window = window,
                rhoHi = rhoHi,
                conversation = request.conversation,
                memoryItems = request.memoryItems,
                history = history,
                current = current.text,
                currentId = current.id,
                currentAttachments = current.attachments.orEmpty(),
                keepAssistantId = keepAssistantId,
                toolSafety = toolSafety,
                dynamic = if (request.attachmentGuide != null || library != null || request.recall.isNotEmpty() || web != null) {
                    ContextDynamicInput(recall = request.recall, library = library, web = web, attachmentGuide = request.attachmentGuide)
                } else {
                    null
                },
                checkpoint = checkpointText,
            ),
        )
        val history = quoted.dropLast(1).map {
            it.toContextMessage(withSearchRecord = it.id != keepAssistantId && it.id != recordExcludeId)
        }
        val stored = checkpoint?.let { row ->
            val coversIndex = history.indexOfFirst { it.id == row.coversTo }
            if (coversIndex < 0) null else applyStored(row.text, history.subList(coversIndex + 1, history.size), current)
        }
        var plan = if (stored != null) assemble(stored.tail, stored.checkpointText) else assemble(history)
        plan.reject?.let { reject ->
            return ChatContextProjection.of(plan = plan, messages = emptyList(), reject = reject)
        }
        val compactionRequired = plan.compaction == ContextCompactionAdvice.REQUIRED
        var tailFrom: String? = stored?.tailFrom
        var checkpointText: String? = stored?.checkpointText
        var checkpointId: String? = stored?.let { checkpoint?.checkpointId }
        val fallbackB = when {
            overflowFallbackB != null -> plan.budget.B ?: overflowFallbackB
            compactionRequired && stored == null && memoryFallback -> plan.budget.B
            else -> null
        }
        if (fallbackB != null) {
            checkpointed(plan, history, current, rhoHi, fallbackB, continueTail = purpose == RequestPurpose.CONTINUE, oldSummary = oldSummary)?.let { cut ->
                plan = assemble(cut.tail, cut.checkpointText)
                tailFrom = cut.tailFrom
                checkpointText = cut.checkpointText
                checkpointId = null
            }
        }
        val planned = plan.messages ?: return null
        val byId = quoted.associateBy { it.id }
        val messages = planned.mapNotNull { message ->
            byId[message.id]?.copy(
                text = message.blocks.joinToString("\n\n") { it.text },
                attachments = message.attachments.takeIf { it.isNotEmpty() },
            )
        }
        return ChatContextProjection.of(
            plan = plan,
            messages = messages,
            windowBudget = ContextBudget.window(window),
            tailFrom = tailFrom,
            checkpointText = checkpointText,
            checkpointId = checkpointId,
            compactionRequired = compactionRequired,
        )
    }

    /**
     * The local history the compaction coordinator sees: the same quote-expanded text as [project], minus the final current user turn;
     * both the latestValid digest and the stored row's digest are computed from it.
     */
    fun compactionHistory(rawMessages: List<ChatMessage>, rhoHi: Double): List<ContextCompactionMessage> =
        QuotePromptBuilder.applyToMessages(rawMessages).dropLast(1).map { message ->
            ContextCompactionMessage(
                id = message.id,
                role = message.role,
                text = message.text,
                estTokens = ContextBudget.estimateMessage(message.text, rhoHi),
                directive = { message.role == ChatRole.User && DirectiveDetector.detect(message.text).isDirective },
                // A summary placeholder only needs the kind and file name: images count as image, everything else (files / videos) as file.
                attachments = message.attachments.orEmpty().map { attachment ->
                    ai.oriveo.community.core.context.SummaryAttachment(
                        kind = if (attachment.kind == ai.oriveo.community.core.model.AttachmentKind.Image) {
                            ai.oriveo.community.core.context.SummaryAttachmentKind.IMAGE
                        } else {
                            ai.oriveo.community.core.context.SummaryAttachmentKind.FILE
                        },
                        name = attachment.fileName,
                    )
                },
                carriesMedia = carriesMedia(message),
            )
        }

    /**
     * Criterion for where manual compaction stops (same as iOS compactionStopsAtMedia and Web carriesMedia):
     * images and videos count as media; a file counts only when its original bytes are kept (it can go out as a native
     * file block), while a file already extracted to text can go into the summary.
     */
    private fun carriesMedia(message: ChatMessage): Boolean =
        message.attachments.orEmpty().any { attachment ->
            when (attachment.kind) {
                ai.oriveo.community.core.model.AttachmentKind.Image,
                ai.oriveo.community.core.model.AttachmentKind.Video -> true
                ai.oriveo.community.core.model.AttachmentKind.File ->
                    !attachment.originalBase64Data.isNullOrEmpty() || attachment.rawContentRef != null
            }
        }

    /**
     * Stored-row checkpoint: tail = the history after coversTo; the checkpoint text goes to the assembler,
     * which places it before the first user text block after sanitizing, so the app no longer splices it into the history text.
     */
    private fun applyStored(text: String, tail: List<ContextMessage>, current: ChatMessage): CheckpointCut =
        CheckpointCut(tail, tail.firstOrNull()?.id ?: current.id, text)

    /**
     * Projection of a single-purpose request (crosscheck / memory draft / image generation): [purpose] decides the system prompt and the outbound shape; no memory / instructions / [D] / checkpoint.
     * [messages] are the raw app messages of this request; plan messages are mapped back by id.
     * Image generation has no plan messages: outbound = a single user message made of the last user message with its text replaced by plan.imagePrompt (attachments kept).
     */
    fun projectPurpose(
        purpose: RequestPurpose,
        messages: List<ChatMessage>,
        window: ContextWindowInput,
        purposeSystem: String? = null,
        // Only image generation passes the conversation instructions (as a prefix); crosscheck / memory draft do not.
        instructions: String? = null,
    ): PlannedChatRequest {
        val plan = ContextAssembler.assemble(
            ContextAssembleInput(
                purpose = purpose,
                window = window,
                conversation = ContextConversation(id = PURPOSE_CONVERSATION_ID, useMemory = false, instructions = instructions),
                history = messages.map { it.toContextMessage() },
                purposeSystem = purposeSystem,
            ),
        )
        val outbound = if (purpose == RequestPurpose.IMAGE_GENERATION) {
            listOfNotNull(messages.lastOrNull { it.role == ChatRole.User }?.copy(text = plan.imagePrompt.orEmpty()))
        } else {
            val byId = messages.associateBy { it.id }
            plan.messages.orEmpty().mapNotNull { message ->
                byId[message.id]?.copy(
                    text = message.blocks.joinToString("\n\n") { it.text },
                    attachments = message.attachments.takeIf { it.isNotEmpty() },
                )
            }
        }
        return ChatContextProjection.of(plan = plan, messages = outbound, windowBudget = ContextBudget.window(window))
            .planned
    }

    private const val PURPOSE_CONVERSATION_ID = "purpose-request"

    /**
     * Manifest of one chat request: transport is this request's StopFamily string; O is the O computed from the window (not oWire);
     * basis is observed when observedInput is present, otherwise estimated when estimatedInput is present, otherwise unknown.
     */
    fun manifest(
        projection: ChatContextProjection,
        requestId: String,
        conversationId: String,
        transport: String,
        model: String,
        observedInput: Int?,
        stopReason: StopReason?,
        createdAt: Long,
    ): ContextManifest {
        val plan = projection.plan
        return ContextManifest(
            requestId = requestId,
            conversationId = conversationId,
            purpose = plan.purpose,
            transport = transport,
            model = model,
            W = plan.budget.W,
            O = projection.windowBudget?.O ?: plan.budget.oWire,
            B = plan.budget.B,
            basis = when {
                observedInput != null -> ContextBasis.OBSERVED
                plan.budget.estimatedInput != null -> ContextBasis.ESTIMATED
                else -> ContextBasis.UNKNOWN
            },
            estimatedInput = plan.budget.estimatedInput ?: 0,
            observedInput = observedInput,
            segments = plan.segments.map { ContextManifestSegment(it.kind, it.tokens, it.items, it.omitted) },
            checkpointId = projection.checkpointId,
            tailFrom = projection.tailFrom,
            unansweredMerged = plan.unansweredMerged,
            reminder = plan.reminder,
            stopReason = stopReason,
            createdAt = createdAt,
        )
    }

    private class CheckpointCut(
        val tail: List<ContextMessage>,
        val tailFrom: String?,
        val checkpointText: String,
    )

    /**
     * Called only when there is no usable stored row and the coordinator is absent or compaction was a noop (the in-memory fallback).
     * 0.90 fallback: each history entry is counted as an estimated message, user messages carry their original text and are non-directive; fixedTokens = system + the current message estimate;
     * the coverage range of any old checkpoint is not read; a non-null [oldSummary] is carried into the checkpoint as the old summary. Returns (tail history, checkpoint text);
     * the checkpoint goes to the assembler, which places it before the first user text block after sanitizing; nothing is persisted, and the request is sent even when targetMet=false.
     * [continueTail]: the current message of a continue is replaced by the continuation prompt, so the checkpoint cannot land before it. When the tail has no user message,
     * the tail is extended backwards to the nearest user message; if the history has no user message, no fallback runs.
     */
    private fun checkpointed(
        plan: ContextPlan,
        history: List<ContextMessage>,
        current: ChatMessage,
        rhoHi: Double,
        B: Int,
        continueTail: Boolean = false,
        oldSummary: String? = null,
    ): CheckpointCut? {
        val planned = plan.messages ?: return null
        val plannedHistory = planned.filter { it.id != current.id }
        val currentPlanned = planned.lastOrNull { it.id == current.id }
        val fixedTokens = (plan.system?.let { ContextBudget.estimateMessage(it, rhoHi) } ?: 0) +
            ContextBudget.estimateMessage(currentPlanned?.blocks?.joinToString("\n\n") { it.text } ?: current.text, rhoHi)
        val fallback = ContextCheckpoint.fallback(
            messages = plannedHistory.map { message ->
                val text = message.blocks.joinToString("\n\n") { it.text }
                CheckpointFallbackMessage(
                    id = message.id,
                    role = message.role,
                    estTokens = ContextBudget.estimateMessage(text, rhoHi),
                    text = text.takeIf { message.role == ChatRole.User },
                    isDirective = message.role == ChatRole.User && DirectiveDetector.detect(text).isDirective,
                )
            },
            B = B,
            rhoHi = rhoHi,
            fixedTokens = fixedTokens,
            oldSummary = oldSummary,
        )
        val checkpoint = fallback.checkpointText ?: return null
        var tailStart = fallback.tailStartId?.let { id -> history.indexOfFirst { it.id == id } }?.takeIf { it >= 0 } ?: history.size
        if (continueTail && history.subList(tailStart, history.size).none { it.role == ChatRole.User }) {
            tailStart = history.subList(0, tailStart).indexOfLast { it.role == ChatRole.User }.takeIf { it >= 0 } ?: return null
        }
        val tail = history.subList(tailStart, history.size)
        // When no tail start can be given the tail is empty: unanswered user messages that the plan merged into the current message are not in the plan history,
        // so take the user messages after the last plan-history entry from the raw history and append them to the tail; on rebuild, sanitize merges them into an <oriveo-unanswered> envelope again.
        val mergedIntoCurrent = if (tail.isNotEmpty()) {
            emptyList()
        } else {
            val lastKept = plannedHistory.lastOrNull()
            val after = lastKept?.let { kept -> history.indexOfFirst { it.id == kept.id } } ?: -1
            if (lastKept != null && after < 0) {
                emptyList()
            } else {
                history.subList(after + 1, history.size).filter { it.role == ChatRole.User }
            }
        }
        return CheckpointCut(tail + mergedIntoCurrent, tail.firstOrNull()?.id ?: current.id, checkpoint)
    }

    internal fun ChatMessage.toContextMessage(withSearchRecord: Boolean = true): ContextMessage =
        ContextMessage(id = id, role = role, text = if (withSearchRecord) historyText() else text, state = state, attachments = attachments.orEmpty())

    /** A past assistant message with external search sources gets a compact record after a blank line (queries, titles and URLs only); with an empty body only the record line is kept. */
    private fun ChatMessage.historyText(): String {
        if (role != ChatRole.Assistant) return text
        val line = ai.oriveo.community.core.search.searchedRecordLineFor(citations) ?: return text
        return if (text.isEmpty()) line else text + "\n\n" + line
    }
}
