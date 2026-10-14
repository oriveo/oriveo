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
            // A model-level protocol wins, otherwise follow the connection; `auto` is an intent, not a chosen protocol, so it still resolves to nothing.
            guard let transport = RelayEndpointResolver.explicitTransport(provider: provider, model: model) else {
                return nil
            }
            return transportKindName(for: transport)
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
        negativeCache: RelayNegativeCache = .shared
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
            return (model.toolCall, model.toolCall == nil ? .unknown : .relayDeclaration)
        }
        if provider.authMode == .subscription {
            if let firstParty = model.toolCall { return (firstParty, .catalog) }
            if let fact = MetadataClient.shared.syncModelFacts(
                providerKind: provider.kind, modelID: model.id
            )?.toolCall {
                return (fact, .modelFacts)
            }
            return (nil, .unknown)
        }
        let catalog = MetadataClient.shared.syncResolveCatalogModel(modelID: model.id, providerKind: provider.kind)
        if let catalog {
            return (catalog.toolCall, catalog.toolCall == nil ? .unknown : .catalog)
        }
        guard model.isManual else { return (nil, .unknown) }
        if let fact = MetadataClient.shared.syncModelFacts(
            providerKind: provider.kind, modelID: model.id
        )?.toolCall {
            return (fact, .modelFacts)
        }
        if let local = model.toolCall { return (local, .localDeclaration) }
        return (nil, .unknown)
    }

    static func decide(
        provider: Provider,
        model: AIModel,
        memory: ToolCallMemoryStore = .shared,
        adapterTransports: Set<String> = localAdapterTransports
    ) -> Decision {
        let transport = finalTransportKindName(provider: provider, model: model)
        var (verdict, source) = catalogVerdict(provider: provider, model: model)
        if verdict == nil, memoryEligible(provider: provider, model: model),
           let remembered = memory.lookup(connectionID: provider.id, modelID: model.id),
           // A relay's "unsupported" is recognized only from the toolCall negative cache; a false in the old tool memory counts as no value.
           provider.kind != .relay || remembered.toolCall {
            verdict = remembered.toolCall
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

    static func permitsToolsOutbound(provider: Provider, model: AIModel, memory: ToolCallMemoryStore = .shared) -> Bool {
        decide(provider: provider, model: model, memory: memory).allowed
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
