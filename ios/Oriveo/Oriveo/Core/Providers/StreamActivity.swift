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
        /// A request to the device's external search service is in flight (external search services contract, applySearchEvent's send). The display context (service name + query)
        /// lives in `StreamingSession.externalSearchActivity` and is cleared on deliver.
    case externalSearch = "external_search"
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
        /// Display context when `activity == .externalSearch` (service name, queries sent so far this turn, whether a request is in flight).
    var externalSearch: ExternalSearchActivityTrail? = nil
}

/// Display context of the external search activity row (transient, same as `StreamActivityState`): send appends the query and marks in flight, deliver clears in flight;
/// while in flight the text is "Searching with {name}...", and from the last deliver until the first character it is "Answering from search results...".
nonisolated struct ExternalSearchActivityTrail: Equatable, Sendable {
        /// Maximum number of capsules (appended per call in order; the earliest is dropped when exceeded).
    static let maxChips = 3
        /// Capsule text limit (first line only).
    static let chipCharacterLimit = 40

    var serviceName: String
    var queries: [String] = []
    var inFlight = false

        /// One send: a new call appends its query; a retry of the same call (already in flight) is not appended again.
    mutating func send(serviceName: String, query: String) {
        self.serviceName = serviceName
        if !inFlight {
            queries.append(query)
            if queries.count > Self.maxChips { queries.removeFirst(queries.count - Self.maxChips) }
        }
        inFlight = true
    }

    mutating func deliver() { inFlight = false }

        /// Capsule text: the first non-empty line, trimmed, truncated beyond 40 grapheme clusters with an appended "...".
    static func chipText(_ query: String) -> String {
        let trimmed = query.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard trimmed.count > chipCharacterLimit else { return trimmed }
        return String(trimmed.prefix(chipCharacterLimit)) + "…"
    }
}
