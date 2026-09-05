import Foundation

/// One observation from a provider stream, in the vocabulary every client shares.
///
/// The events describe what arrived on the wire and nothing more. Each client maps them onto
/// its own model layer, so a provider quirk is normalised once here instead of once per
/// platform.
///
/// Tool-call arguments stay as the raw string the provider sent. Parsing them here would force
/// a decision about malformed JSON that only the caller can make - retry, surface the text,
/// abandon the call - and a fabricated repair is worse than a faithful copy.
public enum ProviderStreamEvent: Equatable, Sendable {
    /// A piece of the answer. Inline thinking tags have already been split out where the
    /// provider's profile says they occur.
    case textDelta(String)
    /// A piece of the model's reasoning, whether it arrived in `reasoning_content`, in a
    /// dedicated event, or inside `<think>` tags.
    case reasoningDelta(String)
    /// Provider-owned state that has to be replayed on the next request of a tool loop and is
    /// otherwise not interpreted.
    case opaqueContinuation(ProviderRecipeValue)
    /// A completed tool call, emitted once the stream says the call is final.
    case toolCall(ProviderToolCall)
    /// Sources the provider's own web search returned. Only produced for recipes that declare a
    /// citation shape.
    case citations([ProviderCitation])
    /// Token counts, emitted at most once and only when the provider reported usable numbers.
    case usage(ProviderTokenUsage)
    /// Always the last event of a stream.
    case finished(reason: String?)
}

/// A source returned by a provider's web search. URLs are normalised and validated before use,
/// since they are rendered as links.
public struct ProviderCitation: Codable, Hashable, Sendable {
    public static let maximumPerEvent = 64
    public var url: String
    public var title: String?
    public var snippet: String?
    public var index: Int?
    public var startIndex: Int?
    public var endIndex: Int?

    public init(
        url: String,
        title: String? = nil,
        snippet: String? = nil,
        index: Int? = nil,
        startIndex: Int? = nil,
        endIndex: Int? = nil
    ) {
        self.url = url
        self.title = title
        self.snippet = snippet
        self.index = index
        self.startIndex = startIndex
        self.endIndex = endIndex
    }

    public func validated() -> ProviderCitation? {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, trimmedURL.count <= 2_048,
              var components = URLComponents(string: trimmedURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        guard let normalizedURL = components.url?.absoluteString else { return nil }
        let start = startIndex.flatMap { $0 >= 0 ? $0 : nil }
        let end = endIndex.flatMap { $0 >= 0 ? $0 : nil }
        let validRange: Bool
        if let start, let end {
            validRange = start <= end
        } else {
            validRange = true
        }
        return ProviderCitation(
            url: normalizedURL,
            title: Self.bounded(title, maximum: 256),
            snippet: Self.bounded(snippet, maximum: 4_096),
            index: index.flatMap { $0 >= 0 ? $0 : nil },
            startIndex: validRange ? start : nil,
            endIndex: validRange ? end : nil
        )
    }

    private static func bounded(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maximum))
    }
}

/// A stream that started as a 2xx but did not deliver a complete answer.
///
/// The provider's own message is deliberately not carried: those bodies routinely quote the
/// request back, API key included, so the caller decides what to show from redacted text
/// instead of from this error.
public enum ProviderStreamWireError: Error, Equatable, Sendable {
    case upstreamError
    case truncated
}

public struct ProviderToolCall: Equatable, Sendable {
    /// The provider's id for this call, needed to match the result back to it. Absent when the
    /// provider does not issue one.
    public var providerCallID: String?
    /// The tool id, already decoded from its wire form (`fs__read` becomes `fs.read`).
    public var name: String
    /// Arguments exactly as the provider sent them, unparsed.
    public var rawArguments: String
    /// Opaque per-call state some providers require on the next request, such as Gemini's
    /// `thoughtSignature`.
    public var providerSignature: String?

    public init(providerCallID: String?, name: String, rawArguments: String, providerSignature: String? = nil) {
        self.providerCallID = providerCallID
        self.name = name
        self.rawArguments = rawArguments
        self.providerSignature = providerSignature
    }
}

/// Token counts as the provider reported them. Cost is not computed here: prices belong to the
/// model catalog, and multiplying them into a stream event would freeze a stale rate into the
/// record.
public struct ProviderTokenUsage: Equatable, Sendable {
    /// Prompt tokens, including any that were served from cache.
    public var inputTokens: Int64
    public var outputTokens: Int64
    /// The part of `outputTokens` spent on reasoning. Nil when the provider does not report it.
    public var reasoningOutputTokens: Int64?
    /// Prompt tokens served from cache. Nil, never zero, when the provider does not report
    /// them: "not measured" and "measured as none" are different answers and are shown
    /// differently.
    public var cachedInputTokens: Int64?

    public init(
        inputTokens: Int64,
        outputTokens: Int64,
        cachedInputTokens: Int64? = nil,
        reasoningOutputTokens: Int64? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }
}
