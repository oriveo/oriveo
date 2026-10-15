import Foundation

nonisolated struct ChatRequestBuildResult: Sendable {
    let requestMessages: [ChatMessage]
    let requestOptions: ChatRequestOptions
}

nonisolated struct ChatRequestPromptContext: Sendable, Equatable {
    let systemPrompt: String
    let remainingChars: Int
    let useMemory: Bool
    let memoryInjected: Bool
}

nonisolated struct ChatRequestKnowledgeBudgetResult: Sendable, Equatable {
    let referenceFiles: [ChatRequestKnowledgeFileSnapshot]
    let retrievalSnippets: [ChatRequestRetrievedSnippet]
}

nonisolated enum ChatRequestBuilder {
    private static let maxSystemPromptChars = 12_000
    private static let maxPromptFileNameChars = 120

    static func build(from snapshot: ChatRequestSnapshot) -> ChatRequestBuildResult {
        var requestMessages = mergeAdjacentSameRole(buildRequestMessages(snapshot.messages, sendPath: snapshot.sendPath))
        let promptContext = buildPromptInjectionContext(
            skill: snapshot.skill,
            preferences: snapshot.preferences,
            conversation: snapshot.conversation,
            retrievedSnippets: snapshot.retrievedSnippets,
            pinnedNotes: snapshot.pinnedNotes
        )
        applyQuoteContexts(to: &requestMessages)
        requestMessages = OutboundAttachmentBudget.apply(to: requestMessages)

        let hasFileAttachments = requestMessages.contains { msg in
            msg.attachments?.contains { $0.kind == AttachmentKind.file } ?? false
        }
        let basePrompt = promptContext?.systemPrompt ?? ""
        let finalSystemPrompt = BaseAPIService.appendAttachmentSystemGuidance(
            to: basePrompt,
            hasAttachments: hasFileAttachments
        )

        return ChatRequestBuildResult(
            requestMessages: requestMessages,
            requestOptions: ChatRequestOptions(systemPrompt: finalSystemPrompt)
        )
    }

    private static func applyQuoteContexts(to messages: inout [ChatMessage]) {
        for index in messages.indices where messages[index].role == .user {
            messages[index].text = QuotePromptBuilder.effectiveUserContent(
                userInput: messages[index].text,
                quoteContext: messages[index].quoteContext
            )
            messages[index].quoteContext = nil
        }
    }

    static func shouldInjectMemory(
        skill: ChatRequestSkillSnapshot?,
        preferences: ChatRequestPreferencesSnapshot,
        conversation: ChatRequestConversationSnapshot?
    ) -> Bool {
        let memoryText = preferences.memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !memoryText.isEmpty else { return false }

        if let skill {
            return conversation?.useMemory ?? skill.useMemory
        }

        return conversation?.useMemory ?? true
    }

    static func buildPromptInjectionContext(
        skill: ChatRequestSkillSnapshot?,
        preferences: ChatRequestPreferencesSnapshot,
        conversation: ChatRequestConversationSnapshot?,
        retrievedSnippets: [ChatRequestRetrievedSnippet] = [],
        pinnedNotes: [ChatRequestPinnedNoteSnapshot] = []
    ) -> ChatRequestPromptContext? {
        var parts: [String] = []
        let maxChars = maxSystemPromptChars
        var remainingChars = maxChars
        var memoryInjected = false

        func injectPinnedNotes() {
            guard !pinnedNotes.isEmpty, remainingChars > 0 else { return }
            let budget = min(remainingChars, PinnedNotePromptBuilder.budgetChars)
            let block = PinnedNotePromptBuilder.build(pinnedNotes, budgetChars: budget)
            guard !block.isEmpty else { return }
            parts.append(block)
            remainingChars = max(0, remainingChars - block.count)
        }

        if let skill {
            let useMemory = conversation?.useMemory ?? skill.useMemory
            if !skill.systemPrompt.isEmpty {
                parts.append(skill.systemPrompt)
                remainingChars = max(0, remainingChars - skill.systemPrompt.count)
            }

            let budgeted = applyKnowledgeBudget(
                skill: skill,
                retrievalSnippets: retrievedSnippets,
                remainingChars: remainingChars
            )

            for file in budgeted.referenceFiles {
                guard let block = fitWrappedSegment(
                    prefix: "--- Reference: \(sanitizePromptFileName(file.name)) ---\n",
                    content: file.content,
                    suffix: "\n--- End ---",
                    remainingChars: remainingChars
                ) else {
                    break
                }
                parts.append(block)
                remainingChars = max(0, remainingChars - block.count)
            }

            for snippet in budgeted.retrievalSnippets {
                guard let block = fitWrappedSegment(
                    prefix: "--- Knowledge Base: \(sanitizePromptFileName(snippet.fileName)) ---\n",
                    content: snippet.text,
                    suffix: "\n--- End ---",
                    remainingChars: remainingChars
                ) else {
                    break
                }
                parts.append(block)
                remainingChars = max(0, remainingChars - block.count)
            }

            injectPinnedNotes()

            if shouldInjectMemory(
                skill: skill,
                preferences: preferences,
                conversation: conversation
            ) {
                let memoryText = preferences.memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let memoryBlock = fitWrappedSegment(
                    prefix: "[User context: ",
                    content: memoryText,
                    suffix: "]",
                    remainingChars: remainingChars
                ) {
                    parts.append(memoryBlock)
                    remainingChars = max(0, remainingChars - memoryBlock.count)
                    memoryInjected = true
                }
            }

            let result = parts.joined(separator: "\n\n")
            guard !result.isEmpty else { return nil }
            return ChatRequestPromptContext(
                systemPrompt: result,
                remainingChars: remainingChars,
                useMemory: useMemory,
                memoryInjected: memoryInjected
            )
        }

        injectPinnedNotes()

        let memoryText = preferences.memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let useMemory = conversation?.useMemory ?? true
        if shouldInjectMemory(
            skill: nil,
            preferences: preferences,
            conversation: conversation
        ) {
            parts.append(memoryText)
            remainingChars = max(0, remainingChars - memoryText.count)
            memoryInjected = true
        }

        let result = parts.joined(separator: "\n\n")
        guard !result.isEmpty else { return nil }
        return ChatRequestPromptContext(
            systemPrompt: result,
            remainingChars: remainingChars,
            useMemory: useMemory,
            memoryInjected: memoryInjected
        )
    }

    static func applyKnowledgeBudget(
        skill: ChatRequestSkillSnapshot,
        retrievalSnippets: [ChatRequestRetrievedSnippet],
        remainingChars: Int
    ) -> ChatRequestKnowledgeBudgetResult {
        let referenceFiles = skill.knowledgeFiles
        guard remainingChars > 0 else {
            return ChatRequestKnowledgeBudgetResult(referenceFiles: [], retrievalSnippets: [])
        }

        let totalReferenceChars = referenceFiles.reduce(0) { $0 + $1.content.count }
        let totalSnippetChars = retrievalSnippets.reduce(0) { $0 + $1.text.count }
        var overflow = max(0, totalReferenceChars + totalSnippetChars - remainingChars)

        let trimmedSnippets = retrievalSnippets.compactMap { snippet -> ChatRequestRetrievedSnippet? in
            if overflow <= 0 { return snippet }
            let snippetChars = snippet.text.count
            if overflow >= snippetChars {
                overflow -= snippetChars
                return nil
            }

            let keepChars = snippetChars - overflow
            overflow = 0
            return ChatRequestRetrievedSnippet(
                fileName: snippet.fileName,
                text: String(snippet.text.prefix(keepChars)),
                score: snippet.score
            )
        }

        let trimmedReferences = referenceFiles.compactMap { file -> ChatRequestKnowledgeFileSnapshot? in
            if overflow <= 0 { return file }
            let fileChars = file.content.count
            if overflow >= fileChars {
                overflow -= fileChars
                return nil
            }

            let keepChars = fileChars - overflow
            overflow = 0
            return ChatRequestKnowledgeFileSnapshot(
                name: file.name,
                content: String(file.content.prefix(keepChars))
            )
        }

        return ChatRequestKnowledgeBudgetResult(
            referenceFiles: trimmedReferences,
            retrievalSnippets: trimmedSnippets
        )
    }

    /// The attachment shape of the outbound history: normalized the same way as `build` (filtering, adjacent same-role merge, history attachment budget),
    /// minus only the plain-text injections that do not touch attachments (citations). The pre-send check of the outbound route uses it.
    static func outboundAttachmentHistory(_ messages: [ChatMessage], sendPath: ChatRequestSendPath) -> [ChatMessage] {
        OutboundAttachmentBudget.apply(to: mergeAdjacentSameRole(buildRequestMessages(messages, sendPath: sendPath)))
    }

    private static func buildRequestMessages(_ messages: [ChatMessage], sendPath: ChatRequestSendPath) -> [ChatMessage] {
        switch sendPath {
        case .send(let excludingMessageID):
            return filteredMessages(
                messages,
                excludingMessageID: excludingMessageID,
                treatingAssistantMessageIDAsDelivered: nil
            )
        case .continueResponse(let assistantMessageID, let instruction):
            var requestMessages = filteredMessages(
                messages,
                excludingMessageID: nil,
                treatingAssistantMessageIDAsDelivered: assistantMessageID
            )
            requestMessages.append(makeInstructionMessage(instruction, from: requestMessages))
            return requestMessages
        }
    }

    private static func filteredMessages(
        _ messages: [ChatMessage],
        excludingMessageID: UUID?,
        treatingAssistantMessageIDAsDelivered: UUID?
    ) -> [ChatMessage] {
        messages.compactMap { message in
            if message.id == excludingMessageID {
                return nil
            }

            var requestMessage = message
            if requestMessage.id == treatingAssistantMessageIDAsDelivered {
                requestMessage.state = .delivered
            }

            if requestMessage.role == .assistant, let attachments = requestMessage.attachments {
                let kept = attachments.filter { $0.kind != .image && $0.kind != .video }
                requestMessage.attachments = kept.isEmpty ? nil : kept
            }

            let hasText = !requestMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasAttachments = !(requestMessage.attachments?.isEmpty ?? true)
            guard hasText || hasAttachments else {
                return nil
            }

            if requestMessage.role == .user || requestMessage.state != .failed {
                return requestMessage
            }

            return nil
        }
    }

    /// Explanatory sentence inside the envelope that wraps unanswered user turns. Cross-platform contract
    /// `shared/context-contracts/sanitize.v1.json` `unansweredEnvelope.note`; every platform uses it verbatim,
    /// so any change must update the contract too.
    static let unansweredEnvelopeNote = "The user sent this earlier but no reply was delivered. Treat it as context and answer the latest message."

    /// Outbound history sanitizing (filtering + merging adjacent same-role turns), i.e. the part of `build`
    /// without injections. `keepAssistantID` is the continue / retry target, kept as delivered for prefill.
    /// The cross-platform contract test calls this directly.
    static func sanitizeOutbound(_ messages: [ChatMessage], keepAssistantID: UUID?) -> [ChatMessage] {
        mergeAdjacentSameRole(
            filteredMessages(
                messages,
                excludingMessageID: nil,
                treatingAssistantMessageIDAsDelivered: keepAssistantID
            )
        )
    }

    /// Normalizes adjacent same-role messages: once filteredMessages drops failed / empty assistants in
    /// between, the user turns they separated become adjacent. Strict OpenAI-compatible relays require
    /// user/assistant to alternate and reject consecutive turns with the same role.
    /// - Adjacent users (contract sanitize.v1): a run of N >= 2 users collapses into one that keeps the last
    ///   message's id and fields. Earlier non-empty texts are trimmed, XML-escaped and wrapped in an
    ///   `<oriveo-unanswered>` envelope placed before the latest text; attachments are concatenated in order.
    ///   Earlier users are often standing instructions ("reply in Arabic from now on") and must not be
    ///   silently dropped; the envelope note tells the model to treat them as context and only answer
    ///   the latest message instead of answering both questions at once.
    /// - Adjacent assistants (rare): text (trimmed, joined by a blank line) and attachments (in order) are
    ///   merged, keeping the first message's fields.
    ///
    /// Note: an interrupted assistant with partial text is kept and naturally separates two users, so it
    /// never triggers the user merge.
    private static func mergeAdjacentSameRole(_ messages: [ChatMessage]) -> [ChatMessage] {
        var merged: [ChatMessage] = []
        var userRun: [ChatMessage] = []
        func flushUserRun() {
            guard !userRun.isEmpty else { return }
            merged.append(mergeUserRun(userRun))
            userRun.removeAll()
        }
        for message in messages {
            if message.role == .user {
                userRun.append(message)
                continue
            }
            flushUserRun()
            if let last = merged.last, last.role == message.role {
                var combinedLast = last
                let lastText = combinedLast.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let currentText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                combinedLast.text = [lastText, currentText].filter { !$0.isEmpty }.joined(separator: "\n\n")
                let combined = (combinedLast.attachments ?? []) + (message.attachments ?? [])
                combinedLast.attachments = combined.isEmpty ? nil : combined
                merged[merged.count - 1] = combinedLast
            } else {
                merged.append(message)
            }
        }
        flushUserRun()
        return merged
    }

    /// Collapses a run of consecutive user turns into one (contract sanitize.v1 `unansweredEnvelope.rules`).
    private static func mergeUserRun(_ run: [ChatMessage]) -> ChatMessage {
        guard var result = run.last else {
            preconditionFailure("mergeUserRun requires a non-empty run")
        }
        guard run.count >= 2 else { return result }
        let earlier = run.dropLast()
        let earlierTexts = earlier
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(escapeUnansweredXML)
        if !earlierTexts.isEmpty {
            let envelope = "<oriveo-unanswered>\n<note>\(unansweredEnvelopeNote)</note>\n"
                + earlierTexts.joined(separator: "\n\n")
                + "\n</oriveo-unanswered>"
            let latest = result.text
            result.text = latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? envelope
                : envelope + "\n\n" + latest
        }
        let attachments = run.flatMap { $0.attachments ?? [] }
        result.attachments = attachments.isEmpty ? nil : attachments
        return result
    }

    /// Escapes only the earlier texts inside the envelope. `&` must be replaced first, otherwise the
    /// entities produced afterwards would be escaped a second time.
    private static func escapeUnansweredXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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

    private static func fitWrappedSegment(
        prefix: String,
        content: String,
        suffix: String,
        remainingChars: Int
    ) -> String? {
        guard remainingChars > 0 else { return nil }
        let full = prefix + content + suffix
        if full.count <= remainingChars {
            return full
        }

        let contentLimit = remainingChars - prefix.count - suffix.count
        guard contentLimit > 0 else { return nil }
        return prefix + String(content.prefix(contentLimit)) + suffix
    }

    private static func remainingCharsBeforeMemory(
        skill: ChatRequestSkillSnapshot?,
        retrievedSnippets: [ChatRequestRetrievedSnippet] = []
    ) -> Int {
        var remainingChars = maxSystemPromptChars
        guard let skill else { return remainingChars }

        if !skill.systemPrompt.isEmpty {
            remainingChars = max(0, remainingChars - skill.systemPrompt.count)
        }

        let budgeted = applyKnowledgeBudget(
            skill: skill,
            retrievalSnippets: retrievedSnippets,
            remainingChars: remainingChars
        )

        for file in budgeted.referenceFiles {
            let prefix = "--- Reference: \(sanitizePromptFileName(file.name)) ---\n"
            let suffix = "\n--- End ---"
            let fullLength = prefix.count + file.content.count + suffix.count

            if fullLength <= remainingChars {
                remainingChars -= fullLength
                continue
            }

            let contentLimit = remainingChars - prefix.count - suffix.count
            if contentLimit > 0 {
                remainingChars = 0
            }
            break
        }

        for snippet in budgeted.retrievalSnippets {
            let prefix = "--- Knowledge Base: \(sanitizePromptFileName(snippet.fileName)) ---\n"
            let suffix = "\n--- End ---"
            let fullLength = prefix.count + snippet.text.count + suffix.count

            if fullLength <= remainingChars {
                remainingChars -= fullLength
                continue
            }

            let contentLimit = remainingChars - prefix.count - suffix.count
            if contentLimit > 0 {
                remainingChars = 0
            }
            break
        }

        return remainingChars
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
