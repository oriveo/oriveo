import Foundation

// The message shape owned by the context pipeline: it carries only the fields sanitize / assemble need, and attachments are referenced by id;
// the caller maps it from the app's message model, so it is decoupled from the app's ChatMessage.

public enum ContextMessageRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
}

public enum ContextMessageState: String, Codable, Hashable, Sendable {
    case delivered
    case generating
    case interrupted
    case failed
}

public enum ContextAttachmentKind: String, Codable, Hashable, Sendable {
    case image
    case video
    case audio
    case file
}

/// Attachment reference: sanitize looks only at kind (assistant image / video is stripped on the way out); content is fetched by the caller by id.
public struct ContextAttachmentRef: Codable, Hashable, Sendable {
    public var id: String
    public var kind: ContextAttachmentKind

    public init(id: String, kind: ContextAttachmentKind) {
        self.id = id
        self.kind = kind
    }
}

public struct ContextMessage: Codable, Hashable, Sendable {
    public var id: String
    public var role: ContextMessageRole
    public var text: String
    public var state: ContextMessageState
    public var attachments: [ContextAttachmentRef]

    public init(
        id: String,
        role: ContextMessageRole,
        text: String,
        state: ContextMessageState,
        attachments: [ContextAttachmentRef] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.state = state
        self.attachments = attachments
    }
}
