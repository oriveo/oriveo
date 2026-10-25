import Foundation

// Opening plan for a native realtime session (context pipeline contract section 3.1).
// The spec is the shared realtime-session fixtures; the plan is computed here.
// Does not go through assemble(ContextAssembleInput): the budget is computed from contextWindow alone, without ContextBudget.window / derived;
// every attachment is projected to a one-line placeholder.

/// One input message of a realtime session plan: the ContextMessage fields plus the id of the realtime session it was stored under (not persisted; the host supplies it in memory).
public struct RealtimeSessionMessage: Hashable, Sendable {
    public var id: String
    public var role: ContextMessageRole
    public var text: String
    public var state: ContextMessageState
    public var attachments: [ContextAttachmentRef]
    public var realtimeSessionId: String?

    public init(
        id: String,
        role: ContextMessageRole,
        text: String,
        state: ContextMessageState,
        attachments: [ContextAttachmentRef] = [],
        realtimeSessionId: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.state = state
        self.attachments = attachments
        self.realtimeSessionId = realtimeSessionId
    }

    public init(_ message: ContextMessage, realtimeSessionId: String? = nil) {
        self.init(
            id: message.id, role: message.role, text: message.text, state: message.state,
            attachments: message.attachments, realtimeSessionId: realtimeSessionId
        )
    }
}

/// Input = the assemble.v1 input shape + contextWindow (voice catalog realtime[].contextWindow) + currentSessionId.
public struct RealtimeSessionInput: Hashable, Sendable {
    /// nil or < 1 yields unknown_window.
    public var contextWindow: Int?
    public var rhoHi: Double
    public var conversation: ContextConversation
    public var memoryItems: [ContextMemoryItem]
    /// Must be in the shape sanitize leaves unchanged (all delivered, starting with user, roles alternating).
    public var history: [RealtimeSessionMessage]
    /// nil or "" means there is no checkpoint.
    public var checkpoint: String?
    /// Remote switch context_reminder_enabled.
    public var reminderEnabled: Bool
    /// The currently open realtime session; when non-nil, messages whose realtimeSessionId equals it stay out of the plan.
    public var currentSessionId: String?

    public init(
        contextWindow: Int?,
        rhoHi: Double = 0.5,
        conversation: ContextConversation,
        memoryItems: [ContextMemoryItem] = [],
        history: [RealtimeSessionMessage],
        checkpoint: String? = nil,
        reminderEnabled: Bool = true,
        currentSessionId: String? = nil
    ) {
        self.contextWindow = contextWindow
        self.rhoHi = rhoHi
        self.conversation = conversation
        self.memoryItems = memoryItems
        self.history = history
        self.checkpoint = checkpoint
        self.reminderEnabled = reminderEnabled
        self.currentSessionId = currentSessionId
    }
}

public enum RealtimeSessionReject: String, Hashable, Sendable {
    case instructionsTooLong = "instructions_too_long"
    case unknownWindow = "unknown_window"
}

/// One opening-history entry; a nil id marks the first entry that the checkpoint forms on its own.
public struct RealtimeSessionHistoryItem: Hashable, Sendable {
    public let id: String?
    public let role: ContextMessageRole
    public let text: String
}

/// Fingerprint used to decide on reopening: any differing field reopens.
public struct RealtimeSessionFingerprint: Hashable, Sendable {
    /// Lowercase hex SHA-256 of the UTF-8 instructions.
    public let instructionsSha256: String
    public let lastHistoryId: String?

    public init(instructionsSha256: String, lastHistoryId: String?) {
        self.instructionsSha256 = instructionsSha256
        self.lastHistoryId = lastHistoryId
    }
}

public struct RealtimeSessionOmitted: Hashable, Sendable {
    public let knowledge: Int
    public let notes: Int
    public let memory: Int
    /// Number of input messages that were non-empty after projection but dropped because of the budget.
    public let history: Int
}

public struct RealtimeSessionBudget: Hashable, Sendable {
    public let B: Int
    public let limit: Int
    public let systemMax: Int
    public let estimatedInstructions: Int
    public let estimatedInjected: Int
}

/// The opening plan; the app can only read it, and it is constructed only in assembleRealtimeSession. When rejected, instructions / history / fingerprint are nil.
public struct RealtimeSessionPlan: Hashable, Sendable {
    public let reject: RealtimeSessionReject?
    public let instructions: String?
    public let history: [RealtimeSessionHistoryItem]?
    public let fingerprint: RealtimeSessionFingerprint?
    public let segments: [ContextSegmentKind]
    public let omitted: RealtimeSessionOmitted
    public let memoryIds: [String]
    public let reminder: Bool
    public let budget: RealtimeSessionBudget?

    init(
        reject: RealtimeSessionReject?,
        instructions: String?,
        history: [RealtimeSessionHistoryItem]?,
        fingerprint: RealtimeSessionFingerprint?,
        segments: [ContextSegmentKind],
        omitted: RealtimeSessionOmitted,
        memoryIds: [String],
        reminder: Bool,
        budget: RealtimeSessionBudget?
    ) {
        self.reject = reject
        self.instructions = instructions
        self.history = history
        self.fingerprint = fingerprint
        self.segments = segments
        self.omitted = omitted
        self.memoryIds = memoryIds
        self.reminder = reminder
        self.budget = budget
    }

    static func rejected(_ reason: RealtimeSessionReject) -> RealtimeSessionPlan {
        RealtimeSessionPlan(
            reject: reason, instructions: nil, history: nil, fingerprint: nil, segments: [],
            omitted: RealtimeSessionOmitted(knowledge: 0, notes: 0, memory: 0, history: 0),
            memoryIds: [], reminder: false, budget: nil
        )
    }
}

extension ContextAssembler {
    /// Body of the realtime delivery envelope; byte-identical to the fixture constants.deliveryRealtime, so changes must update the fixtures too.
    public static let deliveryRealtime =
        "The user is talking with you by voice in real time and hears your spoken replies. Speak naturally in short sentences, usually under 80 words unless the user asks for detail. Do not read out Markdown, code, tables, lists, or emoji; say symbols and units in words. Reply in the language the user is speaking unless the conversation instructions say otherwise."

    /// Attachment placeholder sentences, byte-identical to the fixture constants.attachmentPlaceholders.
    public static let realtimeImagePlaceholder = "[Image omitted: this route sends text only]"
    public static let realtimeFilePlaceholder = "[File omitted: this route sends text only]"
    public static let realtimeVideoPlaceholder = "[Video omitted: this route sends text only]"
    public static let realtimeAudioPlaceholder = "[Audio omitted: this route sends text only]"

    static let realtimeSystemMaxCap = 32000

    public static func realtimeAttachmentPlaceholder(_ kind: ContextAttachmentKind) -> String {
        switch kind {
        case .image: realtimeImagePlaceholder
        case .file: realtimeFilePlaceholder
        case .video: realtimeVideoPlaceholder
        case .audio: realtimeAudioPlaceholder
        }
    }

    /// For hosts that hold the raw kind string: an unknown kind is treated as file.
    public static func realtimeAttachmentPlaceholder(rawKind: String) -> String {
        ContextAttachmentKind(rawValue: rawKind).map(realtimeAttachmentPlaceholder) ?? realtimeFilePlaceholder
    }

    /// Whether to reopen the session at a turn boundary: reopen when any fingerprint field changed.
    public static func shouldReopen(_ previous: RealtimeSessionFingerprint, _ next: RealtimeSessionFingerprint) -> Bool {
        previous.instructionsSha256 != next.instructionsSha256 || previous.lastHistoryId != next.lastHistoryId
    }

    public static func assembleRealtimeSession(_ input: RealtimeSessionInput) -> RealtimeSessionPlan {
        guard let B = input.contextWindow, B >= 1 else { return .rejected(.unknownWindow) }
        let rhoHi = input.rhoHi
        let limit = B / 2
        let systemMax = min(B / 4, realtimeSystemMaxCap)
        let reminderAt = Int((0.3 * Double(B)).rounded(.down))
        func estMessage(_ text: String) -> Int { ContextBudget.estimateMessage(text, rhoHi: rhoHi) }

        // system: assemble.v1 layout 0-4 and 11, without toolSafety; while over systemMax, drop in order the last knowledge file, the last note, the last unpinned fact;
        // entries with an empty body stay in the shrink pool (skipped when rendering) and are still counted when dropped.
        let conversation = input.conversation
        let memory = conversation.useMemory ? eligibleMemory(input.memoryItems, conversationId: conversation.id, dropEmpty: false) : []
        let instructionsBody = ContextSanitizer.trimmed(conversation.instructions ?? "")
        let skill = ContextSanitizer.trimmed(conversation.skillPrompt ?? "")
        var prefix = Prefix(
            skill: skill.isEmpty ? nil : skill,
            instructions: instructionsBody.isEmpty ? nil : instructionsHeader + "\n" + instructionsBody,
            standing: pinnedFirst(memory.filter { isStanding($0) }),
            facts: pinnedFirst(memory.filter { !isStanding($0) }),
            notes: conversation.pinnedNotes,
            knowledge: conversation.knowledgeFiles,
            toolSafety: nil
        )
        var omittedKnowledge = 0
        var omittedNotes = 0
        var omittedMemory = 0
        while let system = prefix.system(), estMessage(system) > systemMax {
            if !prefix.knowledge.isEmpty {
                prefix.knowledge.removeLast()
                omittedKnowledge += 1
            } else if !prefix.notes.isEmpty {
                prefix.notes.removeLast()
                omittedNotes += 1
            } else if let index = prefix.facts.lastIndex(where: { !$0.pinned }) {
                prefix.facts.remove(at: index)
                omittedMemory += 1
            } else {
                break
            }
        }
        let system = prefix.system()
        let segments = prefix.parts().map(\.kind)

        // history: this session's own transcript stays out of the plan; each message is projected to plain text, empty ones are skipped, and leading assistant messages are skipped too.
        let own: (RealtimeSessionMessage) -> Bool = { message in
            input.currentSessionId != nil && message.realtimeSessionId == input.currentSessionId
        }
        let considered = input.history.filter { !own($0) }
        var items: [RealtimeSessionHistoryItem] = considered.compactMap { message in
            var lines: [String] = []
            if !message.text.isEmpty { lines.append(message.text) }
            lines += message.attachments.map { realtimeAttachmentPlaceholder($0.kind) }
            let text = lines.joined(separator: "\n")
            return text.isEmpty ? nil : RealtimeSessionHistoryItem(id: message.id, role: message.role, text: text)
        }
        if let first = items.firstIndex(where: { $0.role == .user }) {
            items.removeFirst(first)
        } else {
            items.removeAll()
        }
        let checkpoint = input.checkpoint.flatMap { $0.isEmpty ? nil : $0 }
        let userCount = considered.filter { $0.role == .user }.count

        // The checkpoint attaches to the first user message; with no user message it forms the first entry on its own (id nil) and is never dropped.
        func withCheckpoint(_ kept: [RealtimeSessionHistoryItem]) -> [RealtimeSessionHistoryItem] {
            guard let checkpoint else { return kept }
            guard let index = kept.firstIndex(where: { $0.role == .user }) else {
                return [RealtimeSessionHistoryItem(id: nil, role: .user, text: checkpoint)] + kept
            }
            var result = kept
            let original = result[index]
            result[index] = RealtimeSessionHistoryItem(
                id: original.id, role: original.role, text: checkpoint + "\n\n" + original.text
            )
            return result
        }
        func estHistory(_ kept: [RealtimeSessionHistoryItem]) -> Int {
            kept.reduce(0) { $0 + estMessage($1.text) }
        }

        // [D]: reminder (same as assemble.v1 layout 8, threshold based on this window B) + the always-present <oriveo-delivery>.
        let pHat = estMessage(system ?? "") + estHistory(withCheckpoint(items))
        let reminder = input.reminderEnabled && !instructionsBody.isEmpty
            && (userCount >= reminderMinUserMessages || pHat >= reminderAt)
        var dynamicParts: [String] = []
        if reminder {
            let fitsInline = ContextBudget.estimateText(instructionsBody, rhoHi: rhoHi) <= reminderFullTextMaxTokens
            let body = fitsInline ? ContextSanitizer.escapeXML(instructionsBody) : reminderPointer
            dynamicParts.append("<oriveo-reminder>\n<note>\(note("oriveo-reminder"))</note>\n\(body)\n</oriveo-reminder>")
        }
        dynamicParts.append("<oriveo-delivery>\n\(deliveryRealtime)\n</oriveo-delivery>")
        let dynamicText = dynamicParts.joined(separator: "\n\n")
        let instructions = system.map { $0 + "\n\n" + dynamicText } ?? dynamicText
        let estimatedInstructions = estMessage(instructions)

        // Budget: reject if instructions (plus the undroppable checkpoint) do not fit; otherwise drop whole messages from the oldest, always leaving the history starting with a user message.
        guard estimatedInstructions + estHistory(withCheckpoint([])) <= limit else {
            return .rejected(.instructionsTooLong)
        }
        var start = 0
        var kept = withCheckpoint(items)
        while estimatedInstructions + estHistory(kept) > limit, start < items.count {
            start += 1
            while start < items.count, items[start].role != .user { start += 1 }
            kept = withCheckpoint(Array(items[start...]))
        }

        return RealtimeSessionPlan(
            reject: nil,
            instructions: instructions,
            history: kept,
            fingerprint: RealtimeSessionFingerprint(
                instructionsSha256: MemoryItems.sha256Hex(instructions), lastHistoryId: kept.last?.id
            ),
            segments: segments,
            omitted: RealtimeSessionOmitted(
                knowledge: omittedKnowledge, notes: omittedNotes, memory: omittedMemory,
                history: items.count - kept.filter { $0.id != nil }.count
            ),
            memoryIds: prefix.memoryIds(),
            reminder: reminder,
            budget: RealtimeSessionBudget(
                B: B, limit: limit, systemMax: systemMax,
                estimatedInstructions: estimatedInstructions,
                estimatedInjected: estimatedInstructions + estHistory(kept)
            )
        )
    }
}
