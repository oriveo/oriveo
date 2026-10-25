import Foundation
import OriveoProviderKit

nonisolated enum ToolCallCapabilityPolicy {
    enum VerdictSource: String, Sendable, Equatable {
        case catalog
        case relayDeclaration
        case localDeclaration
        case modelFacts
        case memory
        case unknown
    }

    struct Decision: Sendable, Equatable {
        var verdict: Bool?
        var source: VerdictSource
        var transport: String?
        var allowed: Bool
        var decided: Bool
    }

    static var localAdapterTransports: Set<String> {
        Set(ToolProtocolAdapters.available.keys)
    }

    static func memoryEligible(provider: Provider, model: AIModel) -> Bool {
        provider.kind == .relay
            || provider.authMode == .subscription
            || model.isManual
    }

    static func finalTransportKindName(provider: Provider, model: AIModel) -> String? {
        if provider.kind == .relay {
            // A model-level protocol wins, otherwise follow the connection; when both are `auto` the first-send protocol is used, the same source as the negative-cache read key and the advanced page's "Auto =".
            return transportKindName(for: RelayFirstSendTransport.current(provider: provider, model: model))
        }
        // Subscription and catalog transports resolve below.
        if let subscription = CapabilityControlResolution.subscriptionFinalTransport(for: provider, model: model) {
            return subscription
        }
        let transport = MetadataClient.shared.syncResolveCatalogModel(
            modelID: model.id, providerKind: provider.kind
        )?.transport
        if transport?.isEmpty == false { return transport }
        switch provider.kind {
        case .anthropic:
            return TransportKind.anthropicMessages.rawValue
        case .gemini:
            return TransportKind.geminiGenerate.rawValue
        case .relay:
            return nil
        default:
            return TransportKind.openaiChat.rawValue
        }
    }

    static func transportKindName(for relay: RelayTransport) -> String? {
        switch relay {
        case .auto: return nil
        case .openaiChatCompletions: return TransportKind.openaiChat.rawValue
        case .openaiResponses: return TransportKind.openaiResponses.rawValue
        case .anthropicMessages: return TransportKind.anthropicMessages.rawValue
        case .geminiGenerateContent: return TransportKind.geminiGenerate.rawValue
        case .llamacppNative: return relay.rawValue
        }
    }

    static func catalogVerdict(
        provider: Provider,
        model: AIModel,
        negativeCache: RelayNegativeCache = .shared,
        rejectionRemembered: Bool = false,
        now: Date = Date()
    ) -> (verdict: Bool?, source: VerdictSource) {
        if provider.kind == .relay {
            // An override (user / tested) is the highest source for relay tools.
            if let overridden = model.relayCapabilityOverrides?.toolCall {
                return (overridden, .relayDeclaration)
            }
            // The upstream rejected tools before any output and the rejection is under 7 days old: treat as unsupported.
            // The cache key uses the same protocol as the write side: the protocol an unverified model really sends first
            // (`RelayFirstSendTransport`), which is otherwise just the effective transport.
            if negativeCache.isRejected(
                connectionID: provider.id.uuidString, modelID: model.id,
                transport: RelayFirstSendTransport.current(provider: provider, model: model).rawValue,
                kind: .toolCall
            ) {
                return (false, .memory)
            }
            // A per-model declaration from a local engine replaces the source: when the connection has an engineProfile
            // and the declaration carries toolCall, it wins and the older toolCall on the model no longer counts.
            if provider.relayRequested?.engineProfile != nil, let declared = model.engineDeclaration?.toolCall {
                return (declared, .relayDeclaration)
            }
            let declared = RelayTruthAdapter.toolCallDeclaration(model)
            return (declared, declared == nil ? .unknown : .relayDeclaration)
        }
        if provider.authMode == .subscription {
            // The subscription /models has no tool field, so there is no first-hand layer: remembered rejection > modelFacts > remembered true (decide) > unknown.
            if rejectionRemembered { return (false, .memory) }
            if let fact = SubscriptionTruthAdapter.toolCallModelFact(providerKind: provider.kind, model: model) {
                return (fact, .modelFacts)
            }
            return (nil, .unknown)
        }
        let catalog = MetadataClient.shared.syncResolveCatalogModel(modelID: model.id, providerKind: provider.kind)
        if let catalog {
            // Official only trusts the tool_call evidence the catalog sends; missing or expired is unknown and the top-level `toolCall` field is not a fallback.
            let verdict = officialToolCallEvidence(catalog, now: now)
            if verdict == nil, rejectionRemembered { return (false, .memory) }
            return (verdict, verdict == nil ? .unknown : .catalog)
        }
        if rejectionRemembered { return (false, .memory) }
        // On a catalog miss the facts are consulted right away. Relay already short-circuited at the top of the function, so it never
        // borrows cross-connection facts by looking like Claude/GPT.
        if let fact = MetadataClient.shared.syncModelFacts(
            providerKind: provider.kind, modelID: model.id
        )?.toolCall {
            return (fact, .modelFacts)
        }
        if let local = OfficialTruthAdapter.handEnteredToolCallDeclaration(model) { return (local, .localDeclaration) }
        return (nil, .unknown)
    }

    /// The official catalog's tool_call evidence (candidates of the evidence namespace): takes the unexpired supported / unsupported ones;
    /// none, all expired or contradicting each other is nil (unknown).
    static func officialToolCallEvidence(
        _ resolved: MetadataClient.ResolvedModelMetadata,
        now: Date = Date()
    ) -> Bool? {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1_000)
        let supports = Set(resolved.capabilityEvidenceCandidates.compactMap { candidate -> Bool? in
            guard candidate.key == "tool_call" else { return nil }
            if let expiresAt = candidate.expiresAt, expiresAt <= nowMillis { return nil }
            switch candidate.support {
            case .supported: return true
            case .unsupported: return false
            case .unknown: return nil
            }
        })
        return supports.count == 1 ? supports.first : nil
    }

    static func decide(
        provider: Provider,
        model: AIModel,
        memory: ToolCallMemoryStore = .shared,
        adapterTransports: Set<String> = localAdapterTransports,
        now: Date = Date()
    ) -> Decision {
        let transport = finalTransportKindName(provider: provider, model: model)
        let remembered = validMemory(provider: provider, model: model, memory: memory)
        // A relay's "unsupported" is recognized only from the toolCall negative cache; a false in the old tool memory counts as no value.
        var (verdict, source) = catalogVerdict(
            provider: provider, model: model,
            rejectionRemembered: provider.kind != .relay && remembered == false,
            now: now
        )
        if verdict == nil, remembered == true {
            verdict = true
            source = .memory
        }
        let adapterAvailable = transport.map(adapterTransports.contains) ?? false
        return Decision(
            verdict: verdict,
            source: source,
            transport: transport,
            allowed: (verdict ?? true) && adapterAvailable,
            decided: transport != nil
        )
    }

    /// The remembered connection value that is still valid: only for connections the memory applies to; a revision mismatch (inside `lookup`) or a hand-entered declaration changed after recording voids it.
    static func validMemory(provider: Provider, model: AIModel, memory: ToolCallMemoryStore) -> Bool? {
        guard memoryEligible(provider: provider, model: model),
              let record = memory.lookup(connectionID: provider.id, modelID: model.id),
              record.handEnteredDeclaration == OfficialTruthAdapter.handEnteredToolCallDeclaration(model)
        else { return nil }
        return record.toolCall
    }

    /// Outbound gate: whether this request should carry tools. Same source as `decide`, with the extra premise that the caller already decided to use tools.
    /// - Parameter now: the clock of the evidence time window; always the current time in production, injected in tests.
    static func permitsToolsOutbound(
        provider: Provider, model: AIModel, memory: ToolCallMemoryStore = .shared, now: Date = Date()
    ) -> Bool {
        decide(provider: provider, model: model, memory: memory, now: now).allowed
    }
}

nonisolated enum ToolUnsupportedErrorMatcher {
    static let statusRange = 400...499
    static let excludedStatuses: Set<Int> = [401, 402, 403, 407, 408, 429]

    static let subjectPatterns: [String] = [
        #"\btools?\b"#,
        #"\btool_calls?\b"#,
        #"\btool_choice\b"#,
        #"\bfunctions?\b"#,
        #"\bfunction[_ ]call(ing)?\b"#,
    ]

    static let verdictPatterns: [String] = [
        #"\bunsupported\b"#,
        #"\bnot (currently )?support(ed)?\b"#,
        #"\bdoes(n't| not) support\b"#,
        #"\binvalid\b"#,
        #"\bunknown\b"#,
        #"\bunrecognized\b"#,
        #"\bunexpected\b"#,
        #"\bextra (inputs?|fields?|parameters?)\b"#,
        #"\bnot (allowed|permitted|available)\b"#,
        #"\bnot a valid\b"#,
    ]

    private static let subjectRegexes = subjectPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    private static let verdictRegexes = verdictPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func matches(statusCode: Int, body: String) -> Bool {
        guard statusRange.contains(statusCode), !excludedStatuses.contains(statusCode) else { return false }
        let range = NSRange(body.startIndex..., in: body)
        let subject = subjectRegexes.contains { $0.firstMatch(in: body, range: range) != nil }
        guard subject else { return false }
        return verdictRegexes.contains { $0.firstMatch(in: body, range: range) != nil }
    }

    static func matches(_ error: any Error) -> Bool {
        if error is ToolsRejectedByUpstreamError { return true }
        guard case let ProviderServiceError.upstream(statusCode, detail) = error else { return false }
        return matches(statusCode: statusCode, body: detail)
    }

    static func annotate(_ mapped: ProviderServiceError, statusCode: Int, rawBody: Data) -> any Error {
        let raw = String(decoding: rawBody, as: UTF8.self)
        let detail: String = {
            if case let .upstream(_, detail) = mapped { return detail }
            return ""
        }()
        guard matches(statusCode: statusCode, body: raw) || matches(statusCode: statusCode, body: detail) else {
            return mapped
        }
        return ToolsRejectedByUpstreamError(statusCode: statusCode, underlying: mapped, rawBody: raw)
    }
}

nonisolated struct ToolsRejectedByUpstreamError: Error, @unchecked Sendable {
    var statusCode: Int
    var underlying: ProviderServiceError
    var legIndex: Int?
    var receivedStructuredToolCalls = false
    /// The raw response body (when `annotate` can get it); a relay uses it to tell whether the key has no access.
    var rawBody: String? = nil

    var qualifiesAsConnectionUnsupported: Bool {
        (legIndex ?? 0) == 0 && !receivedStructuredToolCalls
    }
}
