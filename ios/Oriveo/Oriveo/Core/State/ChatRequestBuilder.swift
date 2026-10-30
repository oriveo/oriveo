import Foundation
import OriveoProviderKit

nonisolated struct ChatRequestBuildResult: Sendable {
    /// Projection of the plan; chat entry points only take its `transportInput(_:)`.
    let planned: PlannedChatRequest
    /// Base options derived from the plan (max_tokens, stateful-continuation sentence); no system, which only `transportInput` writes.
    let requestOptions: ChatRequestOptions
    /// The plan.budget produced by assembly.
    var budget: ContextPlanBudget? = nil
    /// Message id where the tail starts when a checkpoint was spliced in by the fallback (manifest.tailFrom).
    var tailFrom: String? = nil
    /// Checkpoint text spliced in by the fallback or a stored row (used for the stateful-continuation fingerprint); nil if none.
    var checkpointText: String? = nil
    /// checkpointId of the stored row this plan applied (manifest.checkpointId); nil for the in-memory fallback / overflow re-projection.
    var checkpointId: String? = nil
    /// Purpose chat: the plan is still required after applying a stored row (or no row), and the in-memory fallback did not run this time.
    var compactionRequired: Bool = false
    /// Raw material for the compaction snapshot: only present when compactionRequired.
    var compactionInputs: ChatCompactionInputs? = nil
}

/// Raw material for the coordinator snapshot: the history is the full history assembled this time (without the current message); budget and estimation parameters come from this plan.
nonisolated struct ChatCompactionInputs: Sendable {
    var messages: [ContextCheckpoint.Message]
    var attachments: [String: [ContextCompactor.Attachment]]
    var B: Int
    var U: Int
    var rhoHi: Double
    var prefixTokens: Int
    var fixedTokens: Int
    /// System of this chat plan (reused when the summary request's system is nil).
    var system: String
}

/// Budget parameters the main chat path hands to ContextAssembler: the window comes from the model, rho from the Context Ledger.
nonisolated struct ChatRequestAssemblyContext: Sendable, Equatable {
    let window: ContextWindowInput
    let rhoHi: Double
    /// Overflow-recovery resend: when non-nil the deterministic fallback runs regardless of the compaction suggestion; when the window is unknown it is B
    /// (the estimatedInput of the request that failed).
    var overflowFallbackB: Int? = nil
    /// The stored row picked by latestValid; for purpose chat the tail starts after coversTo and the row's text is spliced in.
    var checkpoint: ContextCheckpointRecord? = nil
    /// false = skip the in-memory fallback (the send path hands off to the coordinator first); also skipped when a stored row applies. Overflow resends ignore it.
    var memoryFallback: Bool = true
    /// On overflow-recovery trial runs, purpose chat also produces the compaction snapshot material (B taken as in the fallback: plan.budget.B ?? overflowFallbackB).
    var overflowCompactionInputs: Bool = false
    /// Manual compaction: the snapshot only takes history before the first message carrying media (image / video / a file with original data);
    /// that message and everything after it is kept as is and counted in fixedTokens. Same as false when no message carries media.
    var compactionStopsAtMedia: Bool = false
    /// oldSummary of the deterministic fallback: the non-empty summary of the latestValid winner; nil if none.
    var fallbackOldSummary: String? = nil
}

nonisolated enum ChatRequestBuilder {
    private static let maxPromptFileNameChars = 120

    /// Remote switch: when false the assembly input gets reminderEnabled = false, which only turns off <oriveo-reminder>; the directives section still goes into system.
    static let reminderRemoteFlagKey = "context_reminder_enabled"

    /// The request is projected from the plan of `ContextAssembler.assemble`: send / retry / regenerate / send-after-edit use purpose chat,
    /// continue-generating uses purpose continue (history is cut at the target assistant and keeps it; the current message is core's fixed continuation sentence).
    /// system = plan.system; history = plan.messages mapped back to app messages by id (attachments are brought back by id, history attachment budget unchanged);
    /// [D] is appended to the end of the current user text. When the plan gives no messages (send rejected) the request is empty: every entry point already blocks on the same check before creating messages.
    /// When toolSafety is non-nil (MCP / library agent tool loop) the send path assembles with purpose toolLoopLeg:
    /// the safety note is the last section of system, and every leg of the whole loop uses this same system.
    static func build(
        from snapshot: ChatRequestSnapshot,
        assembly: ChatRequestAssemblyContext,
        toolSafety: String? = nil
    ) -> ChatRequestBuildResult {
        let input = assembleInput(snapshot, assembly: assembly, toolSafety: toolSafety)
        let isChat = input.input.purpose == .chat
        let stored = isChat ? assembly.checkpoint.flatMap { applyingCheckpoint($0, to: input.input) } : nil
        let base = stored?.plan ?? ContextAssembler.assemble(input.input)
        let runsMemoryFallback = assembly.overflowFallbackB != nil || (assembly.memoryFallback && stored == nil)
        let (plan, tailFrom, checkpointText) = runsMemoryFallback
            ? compactedIfRequired(
                base,
                input: stored?.input ?? input.input,
                overflowFallbackB: assembly.overflowFallbackB,
                oldSummary: assembly.fallbackOldSummary
            )
            : (base, stored?.tailFrom, stored?.text)
        let compactionRequired = isChat && !runsMemoryFallback && base.compaction == .required
        let planned = PlannedChatRequest.projecting(
            plan, messages: input.sources.messages, attachments: input.sources.attachments
        )
        var requestOptions = ChatRequestOptions()
        // max_tokens = plan.budget.oWire: handed through request options to the builders that already send max_tokens.
        requestOptions.maxOutputTokens = plan.budget.oWire
        // A stateful continuation leg sends only the continuation sentence: no history and no [D].
        if plan.purpose == .continue {
            requestOptions.statefulLegText = ContextAssembler.continuePrompt
        }
        return ChatRequestBuildResult(
            planned: planned,
            requestOptions: requestOptions,
            budget: plan.budget,
            tailFrom: tailFrom,
            checkpointText: checkpointText,
            checkpointId: runsMemoryFallback ? nil : stored.flatMap { _ in assembly.checkpoint?.checkpointId },
            compactionRequired: compactionRequired,
            compactionInputs: compactionRequired || (isChat && assembly.overflowCompactionInputs)
                ? compactionInputs(
                    input.input, plan: base, sources: input.sources, window: assembly.window,
                    fallbackB: assembly.overflowFallbackB, stopsAtMedia: assembly.compactionStopsAtMedia
                )
                : nil
        )
    }

    /// Conversation history used by latestValid: the same ids / text as the coordinator snapshot (the assembled history of the chat send path, without the current message).
    static func checkpointHistory(from snapshot: ChatRequestSnapshot) -> [ContextCheckpoint.CoveredMessage] {
        preparedMessages(snapshot.messages, sendPath: snapshot.sendPath).history
            .map { ContextCheckpoint.CoveredMessage(id: $0.id, text: $0.text) }
    }

    /// Stored-row application: tail = after coversTo, row.text is handed to the assembler via input.checkpoint
    /// (start of the first user text block after sanitize; not inside the <oriveo-unanswered> envelope).
    /// Not applied when coversTo is not in the history or no messages can be assembled.
    private static func applyingCheckpoint(
        _ row: ContextCheckpointRecord,
        to input: ContextAssembleInput
    ) -> (plan: ContextPlan, input: ContextAssembleInput, tailFrom: String, text: String)? {
        guard let coversIndex = input.history.firstIndex(where: { $0.id == row.coversTo }) else { return nil }
        var applied = input
        let tail = Array(input.history[(coversIndex + 1)...])
        applied.history = tail
        applied.checkpoint = row.text
        let plan = ContextAssembler.assemble(applied)
        guard plan.messages != nil else { return nil }
        return (plan, applied, tail.first?.id ?? input.currentId, row.text)
    }

    /// Raw material for the coordinator snapshot: the full history (without a stored row applied) estimated message by message, with the full text (same rule as digest and latestValid);
    /// fixedTokens = est(system) + est(all text blocks of the current plan messages, including [D]), same rule as the in-memory fallback.
    private static func compactionInputs(
        _ input: ContextAssembleInput,
        plan: ContextPlan,
        sources: AssemblySources,
        window: ContextWindowInput,
        fallbackB: Int? = nil,
        stopsAtMedia: Bool = false
    ) -> ChatCompactionInputs? {
        guard let B = plan.budget.B ?? fallbackB, B > 0 else { return nil }
        let rhoHi = input.rhoHi
        let firstMediaIndex = stopsAtMedia
            ? input.history.firstIndex { message in
                message.attachments.contains { ref in
                    guard let attachment = sources.attachments[ref.id] else { return false }
                    switch attachment.kind {
                    case .image, .video: return true
                    // Only files with original data (native send) count as media; files injected as plain text can be summarized.
                    case .file: return attachment.originalBase64Data?.isEmpty == false
                    }
                }
            }
            : nil
        let summarizable = input.history[..<(firstMediaIndex ?? input.history.count)]
        let keptRawTokens = input.history[(firstMediaIndex ?? input.history.count)...].reduce(0) {
            $0 + ContextBudget.estimateMessage($1.text, rhoHi: rhoHi)
        }
        let messages = summarizable.map { message in
            ContextCheckpoint.Message(
                id: message.id,
                role: message.role,
                estTokens: ContextBudget.estimateMessage(message.text, rhoHi: rhoHi),
                text: message.text,
                // Compaction candidates: user messages are flagged as durable by the detector.
                isDirective: message.role == .user && DirectiveDetector.detect(message.text).isDirective
            )
        }
        var attachments: [String: [ContextCompactor.Attachment]] = [:]
        for message in summarizable where !message.attachments.isEmpty {
            attachments[message.id] = message.attachments.compactMap { ref in
                sources.attachments[ref.id].map { attachment in
                    ContextCompactor.Attachment(kind: attachment.kind == .image ? .image : .file, name: attachment.fileName)
                }
            }
        }
        let system = plan.system ?? ""
        let systemTokens = system.isEmpty ? 0 : ContextBudget.estimateMessage(system, rhoHi: rhoHi)
        let currentPlanMessage = (plan.messages ?? []).last { $0.id == input.currentId && $0.role == .user }
        let currentText = currentPlanMessage.map { $0.blocks.map(\.text).joined(separator: "\n\n") }
            ?? input.current ?? ""
        return ChatCompactionInputs(
            messages: messages,
            attachments: attachments,
            B: B,
            U: ContextBudget.window(window).U ?? B,
            rhoHi: rhoHi,
            prefixTokens: systemTokens,
            fixedTokens: systemTokens + ContextBudget.estimateMessage(currentText, rhoHi: rhoHi) + keptRawTokens,
            system: system
        )
    }

    /// Dedicated image generation: purpose imageGeneration, a single user message,
    /// text = plan.imagePrompt, attachments = those of the last user message; no system, memory, [D] or checkpoint.
    /// Same rule for official image generation and the Relay images endpoint; the message list is empty when the plan gives no prompt.
    static func imageGenerationRequest(
        from snapshot: ChatRequestSnapshot,
        window: ContextWindowInput
    ) -> PlannedChatRequest {
        var messages = snapshot.messages
        if case .send(let excluding) = snapshot.sendPath {
            messages.removeAll { $0.id == excluding }
        }
        let plan = ContextAssembler.assemble(ContextAssembleInput(
            purpose: .imageGeneration,
            window: window,
            conversation: ContextConversation(
                id: snapshot.conversation?.id.uuidString ?? "",
                useMemory: false,
                instructions: snapshot.conversation?.instructions
            ),
            history: messages.map { contextMessage($0) }
        ))
        return PlannedChatRequest.projectingImageGeneration(plan, history: messages)
    }

    /// Dedicated system request: purposeSystem goes into system, history is used as-is,
    /// with no memory, conversation instructions or [D].
    static func purposeRequest(
        purpose: RequestPurpose,
        purposeSystem: String,
        history: [ChatMessage],
        window: ContextWindowInput
    ) -> PlannedChatRequest {
        let plan = ContextAssembler.assemble(ContextAssembleInput(
            purpose: purpose,
            window: window,
            conversation: ContextConversation(id: "", useMemory: false),
            purposeSystem: purposeSystem,
            history: history.map { contextMessage($0) }
        ))
        return PlannedChatRequest.projectingPurpose(plan, history: history)
    }

    /// Pre-send rejection check: assemble once with the messages about to be sent; a non-empty plan.reject means do not send.
    /// Only the skill + instructions and the current message matter and retrieved snippets do not change the verdict, so the snapshot without retrieval is enough.
    static func rejectReason(
        for snapshot: ChatRequestSnapshot,
        assembly: ChatRequestAssemblyContext
    ) -> ContextRejectReason? {
        rejectPrecheck(for: snapshot, assembly: assembly).reject
    }

    /// The plan produced by the rejection pre-check: the rejection reason and plan.budget (B follows the effective tier in the window parameters).
    static func rejectPrecheck(
        for snapshot: ChatRequestSnapshot,
        assembly: ChatRequestAssemblyContext
    ) -> (reject: ContextRejectReason?, budget: ContextPlanBudget) {
        let plan = ContextAssembler.assemble(assembleInput(snapshot, assembly: assembly).input)
        return (plan.reject, plan.budget)
    }

    /// 0.90 deterministic fallback: when plan.compaction = required, run `ContextCheckpoint.fallback` over the history,
    /// hand the checkpoint text to the assembler via input.checkpoint (start of the first user text block after sanitize), then assemble again.
    /// It only changes this request and is not persisted; it is sent even when targetMet = false. Falls back to the original plan if no messages can be assembled after the fallback.
    /// On the send path it only runs here when no stored row is usable and the coordinator is a noop (memoryFallback); overflow resends are unchanged.
    /// Overflow-recovery resends (overflowFallbackB non-nil) ignore the compaction suggestion and take B from it when the window is unknown.
    /// The second return value is the message id where the tail starts (only present when a checkpoint was spliced in; nil means the fallback produced no checkpoint, and overflow recovery does not resend based on that),
    /// the third is the spliced-in checkpoint text (used for the stateful-continuation fingerprint).
    private static func compactedIfRequired(
        _ plan: ContextPlan,
        input: ContextAssembleInput,
        overflowFallbackB: Int?,
        oldSummary: String?
    ) -> (ContextPlan, String?, String?) {
        let forced = overflowFallbackB != nil
        guard plan.compaction == .required || forced,
              let B = plan.budget.B ?? overflowFallbackB, B > 0 else { return (plan, nil, nil) }
        let rhoHi = input.rhoHi
        // The fallback input uses the plan history after sanitize: the current message is the last user message of the plan.
        let planMessages = plan.messages ?? []
        let currentPlanMessage = planMessages.last { $0.id == input.currentId && $0.role == .user }
        let history: [ContextMessage] = planMessages
            .filter { $0.id != currentPlanMessage?.id }
            .map { message in
                ContextMessage(
                    id: message.id,
                    role: message.role,
                    text: message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n"),
                    state: .delivered,
                    attachments: message.attachments
                )
            }
        let messages = history.map { message in
            ContextCheckpoint.Message(
                id: message.id,
                role: message.role,
                estTokens: ContextBudget.estimateMessage(message.text, rhoHi: rhoHi),
                text: message.role == .user ? message.text : nil,
                // Compaction candidates: user messages are flagged as durable by the detector.
                isDirective: message.role == .user && DirectiveDetector.detect(message.text).isDirective
            )
        }
        // fixedTokens = est(system) + est(all text blocks of the current plan messages, including [D]).
        let currentText = currentPlanMessage.map { $0.blocks.map(\.text).joined(separator: "\n\n") }
            ?? input.current ?? ""
        let fixedTokens = (plan.system.map { ContextBudget.estimateMessage($0, rhoHi: rhoHi) } ?? 0)
            + ContextBudget.estimateMessage(currentText, rhoHi: rhoHi)
        let fallback = ContextCheckpoint.fallback(
            messages: messages, B: B, rhoHi: rhoHi, fixedTokens: fixedTokens, oldSummary: oldSummary
        )
        guard let checkpoint = fallback.checkpointText else { return (plan, nil, nil) }

        let tailStart = fallback.tailStartId.flatMap { id in history.firstIndex { $0.id == id } }
            ?? history.count
        var compacted = input
        let tail = Array(history[tailStart...])
        // Earlier user messages that the original plan merged into the current message (unanswered after the failed reply) are not in the plan history: take the user messages
        // after the last plan-history entry from the raw history and reattach them to the tail, so a rebuild's sanitize merges them into an <oriveo-unanswered> envelope again.
        let mergedIntoCurrent: [ContextMessage]
        if let lastKept = history.last {
            mergedIntoCurrent = input.history.firstIndex { $0.id == lastKept.id }
                .map { input.history[($0 + 1)...].filter { $0.role == .user } } ?? []
        } else {
            mergedIntoCurrent = input.history.filter { $0.role == .user }
        }
        compacted.history = tail + mergedIntoCurrent
        compacted.checkpoint = checkpoint
        let replanned = ContextAssembler.assemble(compacted)
        // When the tail is empty (history fully folded) tailFrom is the current message id: once a checkpoint is spliced in there is always a tailFrom.
        return replanned.messages == nil
            ? (plan, nil, nil)
            : (replanned, tail.first?.id ?? input.currentId, checkpoint)
    }

    /// Window parameters: W / O come from the model.
    /// There is no matching recipe-level field on iOS, so it is left empty. The price line T looks up metadata by (kind, modelId) on demand.
    /// budgetCap = conversation cap ?? global default (resolved by ChatManager); single-purpose callers such as crosscheck use the default auto.
    static func contextWindowInput(
        providerKind: ProviderKind,
        model: AIModel,
        userMaxOutput: Int? = nil,
        budgetCap: ContextBudgetCap = .auto
    ) -> ContextWindowInput {
        ContextWindowInput(
            W: model.contextLength,
            windowKind: .total,
            maxOutput: ContextMaxOutputSources(user: userMaxOutput, model: model.maxOutputTokens),
            budgetCap: budgetCap,
            priceLineTokens: priceLineTokens(providerKind: providerKind, modelID: model.id)
        )
    }

    /// pricing.longContext.thresholdTokens from the official catalog metadata; never used for relays.
    static func priceLineTokens(providerKind: ProviderKind, modelID: String) -> Int? {
        guard !providerKind.usesServerOrderedModels, providerKind != .relay else { return nil }
        return MetadataClient.shared.resolveCatalogModel(
            modelID: modelID,
            providerKind: providerKind
        )?.longContext?.thresholdTokens
    }

    /// The output cap the user explicitly set in the evaluated generation parameters (canonical id `max_output_tokens`); nil if unset or non-positive.
    static func userMaxOutputTokens(from parameters: GenerationParameterOverrides?) -> Int? {
        guard let override = parameters?.values["max_output_tokens"],
              override.state == .value,
              case let .number(value)? = override.value,
              value.isFinite, value >= 1 else {
            return nil
        }
        return Int(value)
    }

    /// Clamps the user's explicit output cap to oWire when it exceeds oWire (sent value = min(user value, oWire)); returned unchanged when there is no oWire or it is not exceeded.
    static func cappingUserMaxOutputTokens(
        _ parameters: GenerationParameterOverrides?,
        to oWire: Int?
    ) -> GenerationParameterOverrides? {
        guard var parameters, let oWire, oWire >= 1,
              let user = userMaxOutputTokens(from: parameters), user > oWire else {
            return parameters
        }
        parameters.values["max_output_tokens"]?.value = .number(Double(oWire))
        return parameters
    }

    struct AssemblySources {
        var messages: [String: ChatMessage] = [:]
        var attachments: [String: Attachment] = [:]
    }

    /// The purpose is decided by the send path: `.send` is chat (toolLoopLeg when toolSafety is present), `.continueResponse` is continue.
    static func assembleInput(
        _ snapshot: ChatRequestSnapshot,
        assembly: ChatRequestAssemblyContext,
        toolSafety: String? = nil
    ) -> (input: ContextAssembleInput, sources: AssemblySources) {
        let prepared = preparedMessages(snapshot.messages, sendPath: snapshot.sendPath)
        let purpose: RequestPurpose = prepared.isContinue ? .continue : (toolSafety == nil ? .chat : .toolLoopLeg)

        let useMemory = snapshot.effectiveUseMemory
        let memoryItems = useMemory
            ? injectableMemory(snapshot.preferences.memoryItems, conversation: snapshot.conversation, now: Date())
            : []
        let knowledgeFiles = (snapshot.skill?.knowledgeFiles ?? []).map {
            ContextKnowledgeFile(name: sanitizePromptFileName($0.name), text: $0.content)
        } + snapshot.retrievedSnippets.map {
            ContextKnowledgeFile(name: sanitizePromptFileName($0.fileName), text: $0.text)
        }
        let conversation = ContextConversation(
            id: snapshot.conversation?.id.uuidString ?? "",
            useMemory: useMemory,
            skillPrompt: snapshot.skill?.systemPrompt,
            instructions: snapshot.conversation?.instructions,
            pinnedNotes: snapshot.pinnedNotes.map { ContextPinnedNote(title: $0.title, text: $0.body) },
            knowledgeFiles: knowledgeFiles
        )

        // Attachment note: when the outbound history has file attachments it goes into [D], judged by the same rule as the old build.
        let hasFileAttachments = outboundAttachmentHistory(snapshot.messages, sendPath: snapshot.sendPath)
            .contains { $0.attachments?.contains { $0.kind == .file } ?? false }
        // Library evidence: one entry per document goes into [D]'s <oriveo-library>, without rewriting system or the user text.
        // L3 recall: already retrieved in the snapshot by the effective useMemory; empty when useMemory is off, no envelope.
        let dynamic = ContextDynamicInput(
            recall: useMemory ? snapshot.recall : [],
            library: snapshot.library,
            attachmentGuide: hasFileAttachments ? AttachmentInjector.systemPromptGuidance : nil,
            delivery: snapshot.delivery,
            web: snapshot.web
        )

        let input = ContextAssembleInput(
            purpose: purpose,
            window: assembly.window,
            rhoHi: assembly.rhoHi,
            conversation: conversation,
            memoryItems: memoryItems,
            toolSafety: purpose == .toolLoopLeg ? toolSafety : nil,
            history: prepared.history,
            current: prepared.current?.text,
            currentId: prepared.current?.id ?? "current",
            currentAttachments: prepared.current?.attachments ?? [],
            keepAssistantId: prepared.keepAssistantID?.uuidString,
            dynamic: dynamic,
            reminderEnabled: MetadataClient.shared.syncFeatureFlag(reminderRemoteFlagKey, defaultValue: true)
        )
        return (input, prepared.sources)
    }

    /// Items are filtered by `MemoryItems.injectable` (conversation id, folder id, now), standing section first and memory section after,
    /// keeping list order within a section; status / layer / scope are already filtered here, so the assembler no longer gets those fields.
    /// Conversation / folder ids use `uuidString`, the same as the stored document ids.
    static func injectableMemory(
        _ items: [MemoryItem],
        conversation: ChatRequestConversationSnapshot?,
        now: Date
    ) -> [ContextMemoryItem] {
        guard !items.isEmpty else { return [] }
        let injection = MemoryItems.injectable(
            items,
            conversationId: conversation?.id.uuidString,
            folderId: conversation?.folderID?.uuidString,
            now: now
        )
        return (injection.standingInstructions + injection.memory).map {
            ContextMemoryItem(id: $0.id, kind: $0.kind.rawValue, content: $0.content, pinned: $0.pinned)
        }
    }

    private struct PreparedMessages {
        var isContinue: Bool
        var keepAssistantID: UUID?
        var history: [ContextMessage]
        var current: ContextMessage?
        var sources: AssemblySources
    }

    /// Assembled messages decided by the send path: excluded messages are removed and quotes expanded, and the original message and attachments are recorded by id for the projection to fetch back.
    /// chat: the last user message is the current message and the rest is history. continue: history is cut at the target assistant (inclusive),
    /// the current message is core's fixed continuation sentence; here it only gets an id and a prototype that maps back to an app message.
    private static func preparedMessages(_ snapshotMessages: [ChatMessage], sendPath: ChatRequestSendPath) -> PreparedMessages {
        let isContinue: Bool
        let excludingMessageID: UUID?
        let keepAssistantID: UUID?
        switch sendPath {
        case .send(let excluding):
            isContinue = false
            excludingMessageID = excluding
            keepAssistantID = nil
        case .continueResponse(let assistantMessageID):
            isContinue = true
            excludingMessageID = nil
            keepAssistantID = assistantMessageID
        }
        var messages = snapshotMessages.filter { $0.id != excludingMessageID }
        applyQuoteContexts(to: &messages)

        var sources = AssemblySources()
        var contextMessages: [ContextMessage] = []
        for message in messages {
            sources.messages[message.id.uuidString] = message
            for attachment in message.attachments ?? [] where sources.attachments[attachment.id.uuidString] == nil {
                sources.attachments[attachment.id.uuidString] = attachment
            }
            // The message being continued carries on from its own text, so no search record is appended to it.
            contextMessages.append(contextMessage(message, appendsSearchedRecord: message.id != keepAssistantID))
        }
        var current: ContextMessage?
        if isContinue {
            let prompt = makeInstructionMessage(ContextAssembler.continuePrompt, from: messages)
            sources.messages[prompt.id.uuidString] = prompt
            current = ContextMessage(
                id: prompt.id.uuidString, role: .user, text: prompt.text, state: .delivered, attachments: []
            )
        } else if contextMessages.last?.role == .user {
            current = contextMessages.removeLast()
        }
        return PreparedMessages(
            isContinue: isContinue, keepAssistantID: keepAssistantID,
            history: contextMessages, current: current, sources: sources
        )
    }

    static func contextMessage(_ message: ChatMessage, appendsSearchedRecord: Bool = true) -> ContextMessage {
        let state: ContextMessageState = switch message.state {
        case .delivered: .delivered
        case .generating: .generating
        case .interrupted: .interrupted
        case .failed: .failed
        }
        let attachments = (message.attachments ?? []).map { attachment in
            let kind: ContextAttachmentKind = switch attachment.kind {
            case .image: .image
            case .video: .video
            case .file: .file
            }
            return ContextAttachmentRef(id: attachment.id.uuidString, kind: kind)
        }
        // Compact record of external searches on a past assistant message: only the query, title and URL,
        // attached after the text with a blank line.
        var text = message.text
        if appendsSearchedRecord, message.role == .assistant,
           let line = SearchTurn.searchedRecordLine((message.citations ?? []).compactMap(\.webCitation)) {
            text = text.isEmpty ? line : text + "\n\n" + line
        }
        return ContextMessage(
            id: message.id.uuidString,
            role: message.role == .user ? .user : .assistant,
            text: text,
            state: state,
            attachments: attachments
        )
    }

    private static func applyQuoteContexts(to messages: inout [ChatMessage]) {
        for index in messages.indices where messages[index].role == .user {
            messages[index].text = QuotePromptBuilder.effectiveUserContent(
                userInput: messages[index].text,
                quoteContext: messages[index].quoteContext
            )
            // Provider adapters only need standard role/content; the internal snapshot must not keep leaking into transport.
            messages[index].quoteContext = nil
        }
    }

    /// Attachment shape of the outbound history: the same projection as `build` (core sanitize + the history attachment budget of `PlannedChatRequest.projecting`),
    /// but with an empty context and no window, since system / memory / [D] and window trimming never touch attachments. Used to predict the outbound wire before sending.
    /// There is no outbound history when the last message is not a user message (no plan can be assembled).
    static func outboundAttachmentHistory(_ messages: [ChatMessage], sendPath: ChatRequestSendPath) -> [ChatMessage] {
        let prepared = preparedMessages(messages, sendPath: sendPath)
        let plan = ContextAssembler.assemble(ContextAssembleInput(
            purpose: prepared.isContinue ? .continue : .chat,
            window: ContextWindowInput(W: nil, windowKind: .total, maxOutput: ContextMaxOutputSources()),
            conversation: ContextConversation(id: "", useMemory: false),
            history: prepared.history,
            current: prepared.current?.text,
            currentId: prepared.current?.id ?? "current",
            currentAttachments: prepared.current?.attachments ?? [],
            keepAssistantId: prepared.keepAssistantID?.uuidString
        ))
        return PlannedChatRequest.projecting(
            plan, messages: prepared.sources.messages, attachments: prepared.sources.attachments
        ).messages
    }

    private static func makeInstructionMessage(
        _ instruction: String,
        from messages: [ChatMessage]
    ) -> ChatMessage {
        let prototype = messages.last ?? ChatMessage(
            id: UUID(),
            role: .user,
            text: "",
            providerKind: .openAI,
            providerName: "OpenAI",
            modelName: "",
            state: .delivered
        )

        return ChatMessage(
            id: UUID(),
            role: .user,
            text: instruction,
            providerID: prototype.providerID,
            providerKind: prototype.providerKind,
            providerName: prototype.providerName,
            modelID: prototype.modelID,
            modelName: prototype.modelName,
            state: .delivered
        )
    }

    private static func sanitizePromptFileName(_ name: String) -> String {
        let cleaned = String(
            name.map { character in
                let isControl = character.unicodeScalars.contains(where: { scalar in
                    scalar.value < 32 || scalar.value == 127
                })
                return character.isNewline || isControl ? Character(" ") : character
            }
        )
        let normalized = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if normalized.isEmpty {
            return "file"
        }
        return String(normalized.prefix(maxPromptFileNameChars))
    }
}
