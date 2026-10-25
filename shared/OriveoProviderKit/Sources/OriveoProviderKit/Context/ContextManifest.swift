import Foundation

// The manifest of what was actually loaded into context for each request; ContextManifestLog keeps only the latest 50 per conversation, in memory only.

/// Closed set of request purposes; the assembler decides which sections to load from it.
public enum RequestPurpose: String, Codable, Hashable, Sendable, CaseIterable {
    case chat
    case `continue`
    case toolLoopLeg
    case imageGeneration
    case crosscheck
    case compaction
    case memoryExtraction
    /// Native realtime session opening plan; it goes only through ContextAssembler.assembleRealtimeSession, and receiving it in assemble() is a programmer error.
    case realtimeSession
}

/// Closed set of manifest section types.
public enum ContextSegmentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case skill
    case instructions
    case standingInstructions
    case memory
    case notes
    case knowledge
    case toolSafety
    case purposeSystem
}

public struct ContextManifestSegment: Codable, Hashable, Sendable {
    public var kind: ContextSegmentKind
    public var tokens: Int
    public var items: Int?
    public var omitted: Int?

    public init(kind: ContextSegmentKind, tokens: Int, items: Int? = nil, omitted: Int? = nil) {
        self.kind = kind
        self.tokens = tokens
        self.items = items
        self.omitted = omitted
    }
}

public struct ContextManifest: Codable, Hashable, Sendable {
    public var requestId: String
    public var conversationId: String
    public var purpose: RequestPurpose
    public var transport: String
    public var model: String
    public var W: Int?
    public var O: Int
    public var B: Int?
    public var basis: ContextEstimateBasis
    public var estimatedInput: Int
    public var observedInput: Int?
    public var segments: [ContextManifestSegment]
    public var checkpointId: String?
    public var tailFrom: String?
    public var unansweredMerged: Int
    public var reminder: Bool
    public var stopReason: StopReason?
    /// Epoch milliseconds.
    public var createdAt: Int64

    public init(
        requestId: String,
        conversationId: String,
        purpose: RequestPurpose,
        transport: String,
        model: String,
        W: Int?,
        O: Int,
        B: Int?,
        basis: ContextEstimateBasis,
        estimatedInput: Int,
        observedInput: Int? = nil,
        segments: [ContextManifestSegment],
        checkpointId: String? = nil,
        tailFrom: String? = nil,
        unansweredMerged: Int,
        reminder: Bool,
        stopReason: StopReason? = nil,
        createdAt: Int64
    ) {
        self.requestId = requestId
        self.conversationId = conversationId
        self.purpose = purpose
        self.transport = transport
        self.model = model
        self.W = W
        self.O = O
        self.B = B
        self.basis = basis
        self.estimatedInput = estimatedInput
        self.observedInput = observedInput
        self.segments = segments
        self.checkpointId = checkpointId
        self.tailFrom = tailFrom
        self.unansweredMerged = unansweredMerged
        self.reminder = reminder
        self.stopReason = stopReason
        self.createdAt = createdAt
    }
}

public struct ContextManifestLog: Codable, Hashable, Sendable {
    public static let capacityPerConversation = 50

    /// Conversation id -> manifest, oldest first.
    public var byConversation: [String: [ContextManifest]]

    public init(byConversation: [String: [ContextManifest]] = [:]) {
        self.byConversation = byConversation
    }

    public mutating func append(_ manifest: ContextManifest) {
        var list = byConversation[manifest.conversationId] ?? []
        list.append(manifest)
        if list.count > Self.capacityPerConversation {
            list.removeFirst(list.count - Self.capacityPerConversation)
        }
        byConversation[manifest.conversationId] = list
    }

    /// Oldest -> newest.
    public func manifests(conversationId: String) -> [ContextManifest] {
        byConversation[conversationId] ?? []
    }

    public func latest(conversationId: String) -> ContextManifest? {
        byConversation[conversationId]?.last
    }
}
