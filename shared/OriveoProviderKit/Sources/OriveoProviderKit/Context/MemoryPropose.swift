import Foundation

// Pure functions for the host tool propose_memory (source of truth: `shared/context-contracts/memory-propose.v2.json`
// algorithm 1, 4, 6). Decisions only: tool definition and fixed tool_result, single call -> candidate decision, this turn's mode, downgrade criteria.
// Candidate generation reuses MemoryIntent.makeCandidate; everything works on code points and String.contains is not used.

/// Reasons propose is skipped (fixture skipReasons).
public enum MemoryProposeSkipReason: String, Codable, Hashable, Sendable, CaseIterable {
    case invalidArguments = "invalid_arguments"
    case tooLong = "too_long"
    case quoteNotInMessage = "quote_not_in_message"
    case secret
    case special
    case conversationInstruction = "conversation_instruction"
    case conversationNotInstruction = "conversation_not_instruction"
    case instructLimit = "instruct_limit"
    case turnLimit = "turn_limit"
    case duplicateActive = "duplicate_active"
    case exists
    case duplicatePending = "duplicate_pending"
    case rejectedRecently = "rejected_recently"
}

/// Outcome action of a propose: create yields a memory candidate, instruct yields a "set as conversation instruction" suggestion, skip skips.
public enum MemoryProposeAction: String, Codable, Hashable, Sendable {
    case create
    case skip
    case instruct
}

/// Outcome of one propose_memory call: create carries the candidate, instruct carries the sentence, skip carries the reason.
public struct MemoryProposeDecision: Codable, Hashable, Sendable {
    public var action: MemoryProposeAction
    public var reason: MemoryProposeSkipReason?
    public var candidate: MemoryCandidate?
    /// Present only for instruct: sourceQuote with leading and trailing White_Space removed (not normalized).
    public var sentence: String?

    public init(action: MemoryProposeAction, reason: MemoryProposeSkipReason?, candidate: MemoryCandidate?, sentence: String? = nil) {
        self.action = action
        self.reason = reason
        self.candidate = candidate
        self.sentence = sentence
    }

    private enum CodingKeys: String, CodingKey {
        case action, reason, candidate, sentence
    }

    /// null is written as null, with the same key order as the fixture.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(reason, forKey: .reason)
        try container.encode(candidate, forKey: .candidate)
        try container.encodeIfPresent(sentence, forKey: .sentence)
    }
}

/// Context for propose: the candidate context + the body of the user message newly sent this turn.
public struct MemoryProposeContext: Codable, Hashable, Sendable {
    public var conversationId: String
    public var folderId: String?
    public var messageId: String
    public var nowMs: Int64
    public var activeContents: [String]
    public var records: [MemoryCandidate]
    public var userText: String

    public init(
        conversationId: String,
        folderId: String?,
        messageId: String,
        nowMs: Int64,
        activeContents: [String],
        records: [MemoryCandidate],
        userText: String
    ) {
        self.conversationId = conversationId
        self.folderId = folderId
        self.messageId = messageId
        self.nowMs = nowMs
        self.activeContents = activeContents
        self.records = records
        self.userText = userText
    }

    /// Context handed to makeCandidate: autoSuggest defaults to on.
    var candidateContext: MemoryCandidateContext {
        MemoryCandidateContext(
            conversationId: conversationId,
            folderId: folderId,
            messageId: messageId,
            nowMs: nowMs,
            activeContents: activeContents,
            records: records
        )
    }
}

public enum MemoryPropose {
    /// This turn's mode (fixture modes).
    public enum Mode: String, Codable, Hashable, Sendable, CaseIterable {
        case tool, fallback, none
    }

    /// Request purpose: only chat decides a mode, everything else is none.
    public enum Purpose: String, Codable, Hashable, Sendable, CaseIterable {
        case chat
        case `continue`
        case toolLoopLeg
        case compaction
    }

    /// Input of the mode decision (fixture modeCases.input).
    public struct ModeInput: Codable, Hashable, Sendable {
        public var purpose: Purpose
        /// A fresh user send (retry / regenerate / edit / continue / resume are not).
        public var freshSend: Bool
        /// The useMemory actually in effect for this request.
        public var memoryEnabled: Bool
        /// This device's auto-suggest switch.
        public var autoSuggest: Bool
        /// Whether this request can carry client tools (the same criterion as MCP, and not running Moonshot's built-in web-search loop).
        public var connectionSupportsTools: Bool
        /// This connection + model has already been downgraded in-process.
        public var degraded: Bool

        public init(
            purpose: Purpose,
            freshSend: Bool,
            memoryEnabled: Bool,
            autoSuggest: Bool,
            connectionSupportsTools: Bool,
            degraded: Bool
        ) {
            self.purpose = purpose
            self.freshSend = freshSend
            self.memoryEnabled = memoryEnabled
            self.autoSuggest = autoSuggest
            self.connectionSupportsTools = connectionSupportsTools
            self.degraded = degraded
        }
    }

    /// Tool name.
    public static let toolName = "propose_memory"

    /// Maximum number of propose calls handled per turn (fixture constants.maxProposalsPerTurn).
    public static let maxProposalsPerTurn = 3

    /// At most one instruct per turn (fixture constants.maxInstructPerTurn).
    public static let maxInstructPerTurn = 1

    /// The tool_result returned to the model for every call (identical for every outcome).
    public static let toolResult =
        "Recorded as a suggestion; the user will decide whether to save it. Continue your reply. Do not ask about it or say it was saved."

    /// Tool definition (openai_chat shape, same as the fixture tool); each platform projects it with its own ToolAdapter.
    public static let toolJSON = #"""
        {
          "type": "function",
          "function": {
            "name": "propose_memory",
            "description": "Propose one long-term memory for the user to confirm, or one standing instruction for this conversation. Call it when the user's own message in this turn asks you to remember something for future conversations, or states a lasting fact or preference about themselves, or a decision or event they will want to look up later, that they clearly want kept beyond this conversation. Also call it when the user asks you to keep answering in a certain way for the rest of this conversation (from now on, going forward, always, never, every time...): set scope to conversation and kind to instruction. One atomic statement per call, keeping the user's meaning and language; never record your own inference. Do not call it for: reminders and to-dos; questions, including 'can you remember...'; corrections or statements that something is no longer true; quoted, hypothetical or role-play text; anything containing passwords, keys, codes, payment or ID details, health, sexuality, religion, politics, ethnicity, criminal record or immigration status. Nothing is saved until the user confirms. After calling, continue your reply normally and do not mention the proposal.",
            "parameters": {
              "type": "object",
              "properties": {
                "proposition": {
                  "type": "string",
                  "description": "The fact, preference or rule to keep, as one self-contained statement in the language the user wrote."
                },
                "kind": {
                  "type": "string",
                  "enum": [
                    "instruction",
                    "project",
                    "goal",
                    "preference",
                    "identity",
                    "fact",
                    "decision",
                    "event"
                  ],
                  "description": "instruction: a standing rule for how to respond; project: about a project the user works on; goal: something the user is working toward; preference: what the user likes or dislikes; identity: who the user is; fact: any other lasting fact about the user; decision: something the user decided and will want to look up later; event: something that happened that the user will want to look up later."
                },
                "scope": {
                  "type": "string",
                  "enum": [
                    "global",
                    "folder",
                    "unspecified",
                    "conversation"
                  ],
                  "description": "global: the user said it applies to all chats; folder: the user said it applies to this project or folder; unspecified: the user named no scope; conversation: a way of answering the user wants kept for the rest of this conversation only (use kind instruction)."
                },
                "sourceQuote": {
                  "type": "string",
                  "description": "The exact words in the user's message that this comes from, copied verbatim."
                }
              },
              "required": [
                "proposition",
                "kind",
                "scope",
                "sourceQuote"
              ],
              "additionalProperties": false
            }
          }
        }
        """#

    /// Fixture scopes.
    private static let scopes: [String: MemoryIntent.Scope] = [
        "global": .global, "folder": .folder, "unspecified": .unspecified,
    ]

    /// The fixture scope that takes the instruct branch.
    private static let conversationScope = "conversation"

    /// memory-intent.v1 kinds plus episodicKinds.
    private static let kinds: Set<MemoryKind> = [.instruction, .project, .goal, .preference, .identity, .fact, .decision, .event]

    // MARK: Rule 1

    public static func mode(_ input: ModeInput) -> Mode {
        guard input.purpose == .chat, input.freshSend else { return .none }
        guard input.memoryEnabled, input.autoSuggest, input.connectionSupportsTools, !input.degraded else {
            return .fallback
        }
        return .tool
    }

    // MARK: Rule 4

    /// One propose_memory call -> candidate decision. priorInTurn = the number of propose calls earlier in this turn (regardless of outcome).
    public static func propose(
        _ arguments: String,
        context: MemoryProposeContext,
        priorInTurn: Int,
        priorInstructInTurn: Int = 0
    ) -> MemoryProposeDecision {
        if priorInTurn >= maxProposalsPerTurn { return skip(.turnLimit) }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any],
              let proposition = object["proposition"] as? String,
              let sourceQuote = object["sourceQuote"] as? String,
              let kindRaw = object["kind"] as? String,
              let kind = MemoryKind(rawValue: kindRaw), kinds.contains(kind),
              let scopeRaw = object["scope"] as? String,
              scopeRaw == conversationScope || scopes[scopeRaw] != nil else {
            return skip(.invalidArguments)
        }
        let content = DirectiveDetector.trim(proposition.unicodeScalars.map(\.value))
        let quote = MemoryIntent.canonical(sourceQuote).unicodeScalars.map(\.value)
        if content.isEmpty || quote.isEmpty { return skip(.invalidArguments) }
        if content.count > MemoryIntentLexicon.contentMaxCodePoints { return skip(.tooLong) }
        let message = MemoryIntent.canonical(context.userText).unicodeScalars.map(\.value)
        if !contains(message, quote) { return skip(.quoteNotInMessage) }
        let contentText = DirectiveDetector.string(content)
        let sensitivities = [context.userText, contentText, sourceQuote].map { MemoryIntent.classify($0).sensitive }
        if sensitivities.contains(.secret) { return skip(.secret) }
        if sensitivities[1] == .special || sensitivities[2] == .special { return skip(.special) }
        // Instruct branch: a conversation-scoped directive yields only the "set as conversation instruction" bar and never a memory candidate.
        guard let scope = scopes[scopeRaw] else {
            if kind != .instruction { return skip(.conversationNotInstruction) }
            if priorInstructInTurn >= maxInstructPerTurn { return skip(.instructLimit) }
            let sentence = DirectiveDetector.string(DirectiveDetector.trim(sourceQuote.unicodeScalars.map(\.value)))
            return MemoryProposeDecision(action: .instruct, reason: nil, candidate: nil, sentence: sentence)
        }
        // A convention scoped to this conversation belongs to the "set as conversation instruction" bar, not to a memory bar.
        let v1 = MemoryIntent.classify(context.userText)
        if v1.suggestion == .conversationInstruction || v1.blocked == .conversationScope { return skip(.conversationInstruction) }
        let classification = MemoryIntent.Classification(
            intent: .implicitPersist, rule: nil, span: nil, proposition: contentText, kind: kind, scope: scope,
            sensitive: .none, blocked: nil, suggestion: .memory
        )
        let decision = MemoryIntent.makeCandidate(classification, context: context.candidateContext)
        switch decision.reason {
        case nil:
            return MemoryProposeDecision(action: decision.action == .create ? .create : .skip, reason: nil, candidate: decision.candidate)
        case .duplicateActive: return skip(.duplicateActive)
        case .exists: return skip(.exists)
        case .duplicatePending: return skip(.duplicatePending)
        case .rejectedRecently: return skip(.rejectedRecently)
        case .noSuggestion, .autoSuggestOff:
            // The classification above is always memory / implicit_persist and autoSuggest defaults to on, so it never reaches here.
            return skip(.invalidArguments)
        }
    }

    // MARK: Rule 5 (instruction bar)

    /// After this many consecutive ignores, the "set as conversation instruction" bar is no longer shown in this conversation.
    public static let instructionBarIgnoreLimit = 3

    /// Whether the "set as conversation instruction" bar is shown (fixture instructBarCases; shared by the lexical bar and instruct): ignore count < 3,
    /// the sentence is not a substring (by code point) of the existing instructions, and the appended text (instructions + \n + sentence) stays within maxCodePoints.
    public static func instructionBarShows(sentence: String, instructions: String, ignoreCount: Int) -> Bool {
        let needle = sentence.unicodeScalars.map(\.value)
        guard ignoreCount < instructionBarIgnoreLimit, !needle.isEmpty else { return false }
        if contains(instructions.unicodeScalars.map(\.value), needle) { return false }
        let existing = instructions.unicodeScalars.count
        let appended = existing == 0 ? needle.count : existing + 1 + needle.count
        return appended <= ConversationInstructions.maxCodePoints
    }

    // MARK: Rule 6

    /// Whether to degrade after a request carrying the propose tool is rejected: the rejection matches the tool-unsupported criteria, it is the first leg, no text was streamed, and no structured tool_calls were seen.
    public static func degrade(
        rejectionMatches: Bool,
        legIndex: Int,
        streamStarted: Bool,
        receivedStructuredToolCalls: Bool
    ) -> Bool {
        rejectionMatches && legIndex == 0 && !streamStarted && !receivedStructuredToolCalls
    }

    /// Key of the in-process downgrade set: "connection id\nmodel id".
    public static func degradedKey(connectionId: String, modelId: String) -> String {
        connectionId + "\n" + modelId
    }

    private static func skip(_ reason: MemoryProposeSkipReason) -> MemoryProposeDecision {
        MemoryProposeDecision(action: .skip, reason: reason, candidate: nil)
    }

    /// Contiguous-substring containment on code point arrays.
    private static func contains(_ text: [UInt32], _ needle: [UInt32]) -> Bool {
        guard needle.count <= text.count else { return false }
        if needle.isEmpty { return true }
        for start in 0...(text.count - needle.count) where text[start] == needle[0] {
            if Array(text[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}
