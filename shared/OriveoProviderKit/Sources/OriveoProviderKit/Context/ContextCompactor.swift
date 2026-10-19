import Foundation

// Pure LLM summary compaction functions. The spec is rules[7..10] in `shared/context-contracts/checkpoint.v1.json`:
// summary instruction, summary request assembly (appended / serialized / tooLarge), the compaction flow and the circuit breaker. Same name and algorithm on every platform.
// Pure functions only: model call results are passed in by the caller as summaryOutputs; app wiring is done separately.

public enum ContextCompactor {
    /// Identical verbatim on all platforms; changes must stay in sync with the contract's constants.summaryPromptTemplate.
    public static let summaryPromptTemplate =
        "You are writing a CONTEXT CHECKPOINT so this conversation can continue after older messages are removed.\n"
        + "The user's own messages are preserved separately; do not restate them, and do not restate any <oriveo-*> blocks.\n"
        + "Write in {language}. Use EXACTLY these level-2 headings in this order; write \"(none)\" if empty:\n"
        + "## Goal                 — what the user is trying to achieve in this conversation\n"
        + "## Key Facts & Decisions\n"
        + "## Work Produced        — artifacts created so far (e.g. chapters, code, plans): title + 1-line gist each\n"
        + "## Open Threads         — unanswered questions, pending tasks, what the user asked for next\n"
        + "## Style & Language     — language, tone, format conventions in use\n"
        + "Do not invent facts. Do not address the user. Max {S_max} tokens."
    public static let languageFallback = "the language the assistant's answers in this conversation are written in"
    public static let serializedSystem =
        "You write context checkpoints that let a conversation continue after older messages are removed. Follow the format given in the user's message exactly."
    public static let attachmentPlaceholder = "[{kind}: {name}]"
    public static let maxSummaryAttempts = 2
    /// The summary call needs text only and must not let the model call tools.
    public static let toolChoiceNone = "none"

    // MARK: summary prompt

    /// rules[7]: language is resolved by the caller; nil or whitespace-only uses languageFallback. Placeholders are replaced literally:
    /// {S_max} first, then {language}, so brace text inside language is not replaced again.
    public static func summaryPrompt(language: String?, summaryMax: Int) -> String {
        let resolved = nonBlank(language) ?? languageFallback
        return summaryPromptTemplate
            .replacingOccurrences(of: "{S_max}", with: String(summaryMax))
            .replacingOccurrences(of: "{language}", with: resolved)
    }

    /// nil or White_Space-only counts as absent; otherwise returned as is (not trimmed).
    static func nonBlank(_ text: String?) -> String? {
        guard let text, !ContextSanitizer.trimmed(text).isEmpty else { return nil }
        return text
    }

    // MARK: summary request

    public enum AttachmentKind: String, Hashable, Sendable {
        case image
        case file
    }

    public struct Attachment: Hashable, Sendable {
        public var kind: AttachmentKind
        public var name: String

        public init(kind: AttachmentKind, name: String) {
            self.kind = kind
            self.name = name
        }
    }

    public struct SpanMessage: Hashable, Sendable {
        public var id: String
        public var role: ContextMessageRole
        public var text: String
        public var attachments: [Attachment]

        public init(id: String, role: ContextMessageRole, text: String, attachments: [Attachment] = []) {
            self.id = id
            self.role = role
            self.text = text
            self.attachments = attachments
        }
    }

    public struct RequestMessage: Hashable, Sendable {
        public var role: ContextMessageRole
        public var text: String

        public init(role: ContextMessageRole, text: String) {
            self.role = role
            self.text = text
        }
    }

    public struct SummaryRequestInput: Hashable, Sendable {
        public var U: Int
        /// The appended form reuses the estimated tokens of the conversation system plus tool definitions.
        public var prefixTokens: Int
        public var rhoHi: Double
        public var language: String?
        public var summaryMax: Int
        public var previousCheckpointText: String?
        public var previousSummary: String?
        public var span: [SpanMessage]

        public init(
            U: Int,
            prefixTokens: Int,
            rhoHi: Double,
            language: String?,
            summaryMax: Int,
            previousCheckpointText: String? = nil,
            previousSummary: String? = nil,
            span: [SpanMessage]
        ) {
            self.U = U
            self.prefixTokens = prefixTokens
            self.rhoHi = rhoHi
            self.language = language
            self.summaryMax = summaryMax
            self.previousCheckpointText = previousCheckpointText
            self.previousSummary = previousSummary
            self.span = span
        }
    }

    public enum RequestShape: String, Hashable, Sendable {
        case appended
        case serialized
        case tooLarge
    }

    /// Field shape matches the fixture expected: tooLarge carries only appendedTokens / serializedTokens (messages empty),
    /// while appended / serialized do not carry these two.
    public struct SummaryRequest: Hashable, Sendable {
        public var shape: RequestShape
        /// appended == nil means keep the conversation system and tools.
        public var system: String?
        public var toolChoice: String?
        public var maxOutputTokens: Int?
        public var messages: [RequestMessage]
        /// Does not include summaryMax.
        public var estInputTokens: Int?
        public var appendedTokens: Int?
        public var serializedTokens: Int?
    }

    /// rules[8]: use appended if it fits, otherwise serialized; if neither form fits it is tooLarge (the caller takes the deterministic fallback).
    public static func summaryRequest(_ input: SummaryRequestInput) -> SummaryRequest {
        let prompt = summaryPrompt(language: input.language, summaryMax: input.summaryMax)
        let appended = appendedMessages(input, prompt: prompt)
        let appendedInput = input.prefixTokens
            + appended.reduce(0) { $0 + ContextBudget.estimateMessage($1.text, rhoHi: input.rhoHi) }
        let serializedUser = RequestMessage(role: .user, text: serializedText(input, prompt: prompt))
        let serializedInput = ContextBudget.estimateMessage(serializedSystem, rhoHi: input.rhoHi)
            + ContextBudget.estimateMessage(serializedUser.text, rhoHi: input.rhoHi)
        let appendedTokens = appendedInput + input.summaryMax
        let serializedTokens = serializedInput + input.summaryMax
        if appendedTokens <= input.U {
            return SummaryRequest(
                shape: .appended, system: nil, toolChoice: toolChoiceNone, maxOutputTokens: input.summaryMax,
                messages: appended, estInputTokens: appendedInput,
                appendedTokens: nil, serializedTokens: nil
            )
        }
        if serializedTokens <= input.U {
            return SummaryRequest(
                shape: .serialized, system: serializedSystem, toolChoice: toolChoiceNone, maxOutputTokens: input.summaryMax,
                messages: [serializedUser], estInputTokens: serializedInput,
                appendedTokens: nil, serializedTokens: nil
            )
        }
        return SummaryRequest(
            shape: .tooLarge, system: nil, toolChoice: nil, maxOutputTokens: nil,
            messages: [], estInputTokens: nil,
            appendedTokens: appendedTokens, serializedTokens: serializedTokens
        )
    }

    /// After the body, one placeholder line per attachment; empty segments are dropped and the rest joined with \n.
    static func messageText(_ message: SpanMessage) -> String {
        let placeholders = message.attachments.map { attachment in
            attachmentPlaceholder
                .replacingOccurrences(of: "{kind}", with: attachment.kind.rawValue)
                .replacingOccurrences(of: "{name}", with: attachment.name)
        }
        return ([message.text] + placeholders).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func appendedMessages(_ input: SummaryRequestInput, prompt: String) -> [RequestMessage] {
        var messages = input.span.map { RequestMessage(role: $0.role, text: messageText($0)) }
        if let previous = nonBlank(input.previousCheckpointText), !messages.isEmpty {
            messages[0].text = previous + "\n\n" + messages[0].text
        }
        if let last = messages.indices.last, messages[last].role == .user {
            messages[last].text += "\n\n" + prompt
        } else {
            messages.append(RequestMessage(role: .user, text: prompt))
        }
        return messages
    }

    private static func serializedText(_ input: SummaryRequestInput, prompt: String) -> String {
        var lines = ["<transcript>"]
        if let summary = nonBlank(input.previousSummary) {
            lines += ["<previous-summary>", ContextSanitizer.escapeXML(summary), "</previous-summary>"]
        }
        lines += input.span.map { message in
            "<message id=\"\(message.id)\" role=\"\(message.role.rawValue)\">\(ContextSanitizer.escapeXML(messageText(message)))</message>"
        }
        lines.append("</transcript>")
        return lines.joined(separator: "\n") + "\n\n" + prompt
    }

    // MARK: compact

    public struct Previous: Hashable, Sendable {
        public var coversTo: String
        public var summary: String?

        public init(coversTo: String, summary: String? = nil) {
            self.coversTo = coversTo
            self.summary = summary
        }
    }

    public struct CompactInput: Hashable, Sendable {
        public var conversationId: String
        public var B: Int
        public var rhoHi: Double
        public var messages: [ContextCheckpoint.Message]
        public var previous: Previous?
        /// Model outputs to try in order; nil = that call failed.
        public var summaryOutputs: [String?]

        public init(
            conversationId: String,
            B: Int,
            rhoHi: Double,
            messages: [ContextCheckpoint.Message],
            previous: Previous? = nil,
            summaryOutputs: [String?]
        ) {
            self.conversationId = conversationId
            self.B = B
            self.rhoHi = rhoHi
            self.messages = messages
            self.previous = previous
            self.summaryOutputs = summaryOutputs
        }
    }

    public enum Outcome: String, Hashable, Sendable {
        case summary
        case fallback
        case noop
    }

    public enum FailureReason: String, Hashable, Sendable {
        case callError
        case headings
        case tooLong
        case notShorterThanHalfSpan
        case envelopeTag
    }

    public struct CompactResult: Hashable, Sendable {
        public var outcome: Outcome
        public var attempts: Int
        public var failures: [[FailureReason]]
        /// nil for noop.
        public var spanTokens: Int?
        public var coversFrom: String?
        public var coversTo: String?
        /// coversFrom through text have values only when outcome == summary; fallback / noop leave them all nil and the caller runs the deterministic fallback itself.
        public var messagesCovered: Int?
        public var keptUserIds: [String]?
        public var checkpointId: String?
        public var coversDigest: String?
        public var text: String?
    }

    /// rules[9]: noop returns immediately; try at most maxSummaryAttempts times, the first summary that passes validation becomes the checkpoint, and if all fail the result is fallback.
    public static func compact(_ input: CompactInput) -> CompactResult {
        let messages = input.messages
        let span = ContextCheckpoint.selectSpan(messages: messages, B: input.B, previousCoversTo: input.previous?.coversTo)
        guard span.action == .compact, let coversFrom = span.coversFrom, let coversTo = span.coversTo else {
            return CompactResult(
                outcome: .noop, attempts: 0, failures: [], spanTokens: nil, coversFrom: nil, coversTo: nil,
                messagesCovered: nil, keptUserIds: nil, checkpointId: nil, coversDigest: nil, text: nil
            )
        }
        let spanIds = Set(span.spanIds)
        let spanTokens = messages.filter { spanIds.contains($0.id) }.reduce(0) { $0 + $1.estTokens }
            + (nonBlank(input.previous?.summary).map { ContextBudget.estimateText($0, rhoHi: input.rhoHi) } ?? 0)
        let summaryMax = ContextBudget.derived(B: input.B).summaryMax
        var failures: [[FailureReason]] = []
        var attempts = 0
        var accepted: String?
        for output in input.summaryOutputs.prefix(maxSummaryAttempts) {
            attempts += 1
            guard let output else {
                failures.append([.callError])
                continue
            }
            // Models often copy "## Heading - description" from the template verbatim, so normalize to the bare heading first and then validate; the stored text is the normalized one.
            let normalized = ContextCheckpoint.normalizeHeadings(output)
            let validation = ContextCheckpoint.validateSummary(
                normalized, summaryMax: summaryMax, spanTokens: spanTokens, rhoHi: input.rhoHi
            )
            if validation.valid {
                accepted = normalized
                break
            }
            failures.append(validation.reasons.compactMap { FailureReason(rawValue: $0.rawValue) })
        }
        guard let accepted else {
            return CompactResult(
                outcome: .fallback, attempts: attempts, failures: failures, spanTokens: spanTokens,
                coversFrom: nil, coversTo: nil, messagesCovered: nil,
                keptUserIds: nil, checkpointId: nil, coversDigest: nil, text: nil
            )
        }
        let beforeTail = messages.prefix(span.messagesCovered)
        let candidates = beforeTail
            .filter { $0.role == .user }
            .map { ContextCheckpoint.Candidate(id: $0.id, text: $0.text ?? "", isDirective: $0.isDirective) }
        let kept = ContextCheckpoint.pickUserMessages(candidates: candidates, B: input.B, rhoHi: input.rhoHi)
        let text = ContextCheckpoint.serialize(
            coversFrom: coversFrom,
            coversTo: coversTo,
            messagesCovered: span.messagesCovered,
            kept: kept,
            summary: accepted
        )
        return CompactResult(
            outcome: .summary,
            attempts: attempts,
            failures: failures,
            spanTokens: spanTokens,
            coversFrom: coversFrom,
            coversTo: coversTo,
            messagesCovered: span.messagesCovered,
            keptUserIds: kept.map(\.id),
            checkpointId: ContextCheckpoint.checkpointId(conversationId: input.conversationId, coversTo: coversTo),
            coversDigest: ContextCheckpoint.coversDigest(beforeTail.map { .init(id: $0.id, text: $0.text ?? "") }),
            text: text
        )
    }
}

// MARK: breaker

/// rules[10]: after failuresToTrip consecutive LLM summary failures, only the deterministic fallback is used for the next fallbackTurns turns.
/// Manual compaction ignores the circuit breaker but still reports llmFailure / llmSuccess.
public struct ContextCompactionBreaker: Hashable, Sendable {
    public static let failuresToTrip = 2
    public static let fallbackTurns = 10

    public enum Event: String, Hashable, Sendable {
        case llmFailure
        case llmSuccess
        case turn
        case retry
    }

    public enum Mode: String, Hashable, Sendable {
        case llm
        case fallbackOnly
    }

    public struct State: Hashable, Sendable {
        public var mode: Mode
        public var failures: Int
        public var turnsLeft: Int
    }

    public private(set) var failures: Int
    public private(set) var turnsLeft: Int

    public init(failures: Int = 0, turnsLeft: Int = 0) {
        self.failures = failures
        self.turnsLeft = turnsLeft
    }

    public var mode: Mode {
        turnsLeft > 0 ? .fallbackOnly : .llm
    }

    public var state: State {
        State(mode: mode, failures: failures, turnsLeft: turnsLeft)
    }

    @discardableResult
    public mutating func apply(_ event: Event) -> State {
        switch event {
        case .llmFailure:
            failures += 1
            if failures >= Self.failuresToTrip {
                turnsLeft = Self.fallbackTurns
                failures = 0
            }
        case .llmSuccess:
            failures = 0
        case .turn:
            turnsLeft = max(0, turnsLeft - 1)
        case .retry:
            failures = 0
            turnsLeft = 0
        }
        return state
    }
}
