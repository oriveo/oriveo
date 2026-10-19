import Foundation

// The assembler's product: the system / messages to send for one request plus the budget verdict. init is internal,
// so only ContextAssembler.assemble can construct it and callers cannot hand-build one around the assembly rules.

public enum ContextBlockKind: String, Codable, Hashable, Sendable {
    /// Message body (after sanitize).
    case text
    /// The [D] section computed fresh every turn (recall / library / attachment notes / reminder), placed as the last block of the current user message.
    case dynamic
}

public struct ContextBlock: Hashable, Sendable {
    public let kind: ContextBlockKind
    public let text: String
}

public struct ContextPlanMessage: Hashable, Sendable {
    public let id: String
    public let role: ContextMessageRole
    public let blocks: [ContextBlock]
    /// Attachment references kept after sanitize; the caller fetches the content by id.
    public let attachments: [ContextAttachmentRef]
}

public struct ContextPlanSegment: Hashable, Sendable {
    public let kind: ContextSegmentKind
    /// Section text estimate (est text).
    public let tokens: Int
    /// Number of entries in an envelope section; nil for skill / instructions / toolSafety / purposeSystem.
    public let items: Int?
    /// Number of entries dropped because system was over budget; has a value only when > 0.
    public let omitted: Int?
}

public struct ContextOmitted: Hashable, Sendable {
    public let knowledge: Int
    public let notes: Int
    public let memory: Int
}

public struct ContextPlanBudget: Hashable, Sendable {
    /// W / B are nil when the window is unknown.
    public let W: Int?
    public let B: Int?
    public let oWire: Int
    /// nil when refused or for image generation.
    public let estimatedInput: Int?
}

public enum ContextCompactionAdvice: String, Codable, Hashable, Sendable {
    case none
    case preSuggested
    case required
}

public enum ContextAssembleWarning: String, Codable, Hashable, Sendable {
    /// skill + conversation instructions exceed systemMax, but the request is still sent.
    case instructionsAndSkillOverShare
}

public enum ContextRejectReason: String, Codable, Hashable, Sendable {
    case instructionsTooLong = "instructions_too_long"
    case messageTooLong = "message_too_long"
}

public struct ContextPlan: Hashable, Sendable {
    public let purpose: RequestPurpose
    public let system: String?
    /// nil when refused and for image generation.
    public let messages: [ContextPlanMessage]?
    public let segments: [ContextPlanSegment]
    public let omitted: ContextOmitted
    public let reminder: Bool
    public let unansweredMerged: Int
    public let budget: ContextPlanBudget
    public let compaction: ContextCompactionAdvice
    public let warnings: [ContextAssembleWarning]
    public let reject: ContextRejectReason?
    /// imageGeneration only: the last non-empty user text after trim.
    public let imagePrompt: String?
    /// IDs of the memory items actually rendered into system: the standingInstructions section first, then the memory section, in render order;
    /// items dropped by shrinking or skipped as empty are not listed; empty when there is no memory section. The "memory was used" marker stores exactly this list.
    public let memoryIds: [String]

    init(
        purpose: RequestPurpose,
        system: String?,
        messages: [ContextPlanMessage]?,
        segments: [ContextPlanSegment],
        omitted: ContextOmitted,
        reminder: Bool,
        unansweredMerged: Int,
        budget: ContextPlanBudget,
        compaction: ContextCompactionAdvice,
        warnings: [ContextAssembleWarning],
        reject: ContextRejectReason?,
        imagePrompt: String?,
        memoryIds: [String]
    ) {
        self.purpose = purpose
        self.system = system
        self.messages = messages
        self.segments = segments
        self.omitted = omitted
        self.reminder = reminder
        self.unansweredMerged = unansweredMerged
        self.budget = budget
        self.compaction = compaction
        self.warnings = warnings
        self.reject = reject
        self.imagePrompt = imagePrompt
        self.memoryIds = memoryIds
    }
}
