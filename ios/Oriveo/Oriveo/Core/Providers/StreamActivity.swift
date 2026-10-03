import Foundation

/// The closed set of activities that can be observed while a reply is streaming.
///
/// Only a "started" signal seen on the wire counts. The user having web search switched on, the
/// model declaring search support, the provider kind or model id, and an HTTP 200 are not
/// observations and must not be turned into one. An unknown value is ignored; it is never
/// downgraded to some known activity.
nonisolated enum StreamActivity: String, Equatable, Sendable {
    case webSearch = "web_search"
    /// The local tool loop set one MCP tool step to running. What to display (server name and tool title)
    /// is read from the running step in the message's `toolSteps`; it does not travel with the activity.
    case mcpTool = "mcp_tool"
}

/// The current activity of one streaming message. Transient: it lives only in
/// `ChatManager.StreamingSession`, is never persisted and never becomes part of a `ChatMessage`.
nonisolated struct StreamActivityState: Equatable, Sendable {
    let messageID: UUID
    let activity: StreamActivity?
    /// `false` once the streaming session for this message is gone (finished, failed, stopped or
    /// replaced). Subscribers drop every waiting indicator right away instead of waiting for the
    /// message state to be reconfigured; otherwise the pause fallback would step in for a moment
    /// with the neutral label as soon as the activity clears.
    var isStreaming = true
}
