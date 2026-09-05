import Foundation
import Observation

@MainActor
@Observable
final class CapabilityEvidenceObservationBridge {
    static let shared = CapabilityEvidenceObservationBridge()

    private(set) var contentRevision: UInt64 = 0

    @ObservationIgnored private var futureExpiries: [Int64] = []
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let maximumSleepMilliseconds: Int64 = 24 * 60 * 60 * 1_000

    private init() {}

    func publishContent(candidateExpiries: [Int64], nowMilliseconds suppliedNow: Int64? = nil) {
        let nowMilliseconds = suppliedNow ?? CapabilityEvidenceObservationBridge.nowMilliseconds()
        contentRevision &+= 1
        futureExpiries = Array(Set(candidateExpiries.filter { $0 > nowMilliseconds })).sorted()
        scheduleNearestExpiry(nowMilliseconds: nowMilliseconds)
    }

    private func scheduleNearestExpiry(nowMilliseconds: Int64) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let nearest = futureExpiries.first else { return }
        let delay = max(1, min(nearest - nowMilliseconds, maximumSleepMilliseconds))
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.handleExpiryWake()
        }
    }

    private func handleExpiryWake(nowMilliseconds suppliedNow: Int64? = nil) {
        let nowMilliseconds = suppliedNow ?? CapabilityEvidenceObservationBridge.nowMilliseconds()
        let remaining = futureExpiries.drop(while: { $0 <= nowMilliseconds })
        if remaining.count != futureExpiries.count {
            futureExpiries = Array(remaining)
            contentRevision &+= 1
        }
        scheduleNearestExpiry(nowMilliseconds: nowMilliseconds)
    }

    private static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }

    #if DEBUG
    func resetForTesting() {
        expiryTask?.cancel()
        expiryTask = nil
        futureExpiries = []
        contentRevision &+= 1
    }

    var nearestExpiryForTesting: Int64? { futureExpiries.first }
    #endif
}

struct CapabilityEvidenceProjection: Sendable, Equatable {
    let identity: CapabilityEvidenceRequestIdentity?
    let resolutions: [String: CapabilityEvidenceFacade.Resolution]
    let declaredReasoningDefaultLevel: ReasoningMode?

    func resolution(for key: String) -> CapabilityEvidenceFacade.Resolution? {
        resolutions[key]
    }

    func permitsOutbound(_ key: String) -> Bool {
        guard let policy = resolution(for: key)?.requestPolicy else { return false }
        return policy == .allow || policy == .allowExplicitUnverified
    }

    func hasConclusiveDecision(_ key: String) -> Bool {
        guard let policy = resolution(for: key)?.requestPolicy else { return false }
        return policy != .omitUnknown
    }
}

extension CapabilityEvidenceProductionAdapter {
    private static let scalarCapabilityKeys: Set<String> = [
        "tool_call", "web_search", "vision_input",
    ]

    static func capabilityProjection(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity?,
        keys: Set<String>,
        explicitKeys: Set<String> = []
    ) -> CapabilityEvidenceProjection {
        guard let identity else { return unknownCapabilityProjection(keys: keys, identity: nil) }
        if provider.kind == .relay {
            return resolveRelayCapabilities(
                providerKind: provider.kind, model: model, identity: identity,
                keys: keys, explicitKeys: explicitKeys
            )
        }
        let input = MetadataClient.shared.syncCapabilityEvidenceModelInput(
            modelID: model.id, providerKind: provider.kind
        )
        return resolveOfficialCapabilities(
            providerKind: provider.kind, identity: identity, keys: keys,
            explicitKeys: explicitKeys, resolved: input.resolved,
            metadataRevision: input.metadataRevision, reasoningModes: input.reasoningModes,
            reasoningDefaultLevel: input.reasoningDefaultLevel
        )
    }

    static func capabilityProjection(
        providerKind: ProviderKind,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity?,
        keys: Set<String>,
        explicitKeys: Set<String> = []
    ) -> CapabilityEvidenceProjection {
        guard providerKind != .relay, let identity else {
            return unknownCapabilityProjection(keys: keys, identity: identity)
        }
        let input = MetadataClient.shared.syncCapabilityEvidenceModelInput(
            modelID: model.id, providerKind: providerKind
        )
        return resolveOfficialCapabilities(
            providerKind: providerKind, identity: identity, keys: keys,
            explicitKeys: explicitKeys, resolved: input.resolved,
            metadataRevision: input.metadataRevision, reasoningModes: input.reasoningModes,
            reasoningDefaultLevel: input.reasoningDefaultLevel
        )
    }

    static func uiDispatchIdentity(
        provider: Provider,
        model: AIModel,
        partitionID: String
    ) -> CapabilityEvidenceRequestIdentity? {
        guard provider.kind == .relay,
              let requested = provider.relayRequested,
              requested.transport != .auto,
              let rawBaseURL = trimmedNonEmpty(provider.baseURLText),
              trimmedNonEmpty(partitionID) != nil,
              let endpoint = relayChatEndpoint(
                rawBaseURL: rawBaseURL,
                modelID: ModelResolver.resolvedProviderModelIdentifier(
                    model.id, providerKind: provider.kind
                ),
                requested: requested
              ) else { return nil }

        let metadataRevision = MetadataClient.shared.syncMetadataETag()
        let localProfile = LocalEngineGenerationProfiles.profile(
            for: requested.engineProfile, transport: requested.transport
        )
        let generationRevision = mergeRelayDeclaration(
            localProfile, model.generationProfile
        )?.revision ?? metadataRevision
        return CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: partitionID,
            hasExplicitValue: false, effectiveTransport: requested.transport.rawValue,
            metadataETag: metadataRevision
        ).resolvingFinalDispatch(
            endpoint,
            effectiveTransport: requested.transport.rawValue,
            metadataRevision: metadataRevision,
            generationRevision: generationRevision
        )
    }

    private static func relayChatEndpoint(
        rawBaseURL: String,
        modelID: String,
        requested: RelayRequestedConfig
    ) -> URL? {
        let credentials = RelayEndpointPolicy.Credentials(
            authMode: requested.authMode,
            hasKey: false,
            sensitiveHeaders: requested.effectiveHeaders?.map(\.key) ?? [],
            sensitiveQueryKeys: requested.effectiveQueryParams?.map(\.key) ?? []
        )
        guard let configured = try? RelayEndpointPolicy.requireConfigured(
            requested.resolvedAPIBaseURL ?? rawBaseURL,
            securityMode: requested.securityMode,
            credentials: credentials
        ) else { return nil }

        do {
            switch requested.transport {
            case .auto:
                return nil
            case .llamacppNative:
                return URL(string: configured.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                ) + "/completion")
            case .openaiChatCompletions, .openaiResponses, .anthropicMessages,
                 .geminiGenerateContent:
                let defaultVersion = requested.transport == .geminiGenerateContent ? "v1beta" : "v1"
                let acceptedVersions: Set<String> = requested.transport == .geminiGenerateContent
                    ? ["v1", "v1beta"] : ["v1"]
                let apiBaseURL = try RelayEndpointResolver.runtimeAPIBaseURL(
                    rawBaseURL: configured,
                    relayRequested: requested,
                    defaultVersion: defaultVersion,
                    acceptedVersions: acceptedVersions
                )
                let endpointPath: String
                switch requested.transport {
                case .openaiChatCompletions:
                    endpointPath = "/chat/completions"
                case .openaiResponses:
                    endpointPath = "/responses"
                case .anthropicMessages:
                    endpointPath = "/messages"
                case .geminiGenerateContent:
                    let operation = requested.stream == false
                        ? "generateContent" : "streamGenerateContent"
                    endpointPath = "/models/\(modelID):\(operation)"
                case .auto, .llamacppNative:
                    return nil
                }
                return try RelayEndpointResolver.endpointURL(
                    apiBaseURL: apiBaseURL,
                    endpointPath: endpointPath,
                    securityMode: requested.securityMode
                )
            }
        } catch {
            return nil
        }
    }

    static func finalDispatchIntent(
        request: URLRequest,
        effectiveTransport: String,
        provider: Provider,
        model: AIModel,
        keys: Set<String>,
        explicitKeys: Set<String> = []
    ) -> CapabilityEvidenceProjection {
        guard let current = CapabilityEvidenceRequestContext.current,
              current.query.providerKind == provider.kind.rawValue,
              current.query.connectionInstanceID == provider.id.uuidString,
              CapabilityEvidenceFacade.isConcreteTransport(effectiveTransport) else {
            return unknownCapabilityProjection(keys: keys, identity: nil)
        }
        return finalDispatchIntent(
            request: request, effectiveTransport: effectiveTransport,
            providerKind: provider.kind, model: model, current: current,
            keys: keys, explicitKeys: explicitKeys
        )
    }

    static func finalDispatchIntent(
        request: URLRequest,
        effectiveTransport: String,
        model: AIModel?,
        keys: Set<String>,
        explicitKeys: Set<String> = []
    ) -> CapabilityEvidenceProjection {
        guard let current = CapabilityEvidenceRequestContext.current,
              let providerKind = ProviderKind(rawValue: current.query.providerKind),
              let model,
              current.query.modelID == model.id,
              CapabilityEvidenceFacade.isConcreteTransport(effectiveTransport) else {
            return unknownCapabilityProjection(keys: keys, identity: nil)
        }
        return finalDispatchIntent(
            request: request, effectiveTransport: effectiveTransport,
            providerKind: providerKind, model: model, current: current,
            keys: keys, explicitKeys: explicitKeys
        )
    }

    private static func finalDispatchIntent(
        request: URLRequest,
        effectiveTransport: String,
        providerKind: ProviderKind,
        model: AIModel,
        current: CapabilityEvidenceRequestIdentity,
        keys: Set<String>,
        explicitKeys: Set<String>
    ) -> CapabilityEvidenceProjection {

        if providerKind == .relay {
            let metadataRevision = MetadataClient.shared.syncMetadataETag()
            guard let identity = current.resolvingFinalDispatch(
                request.url,
                effectiveTransport: effectiveTransport,
                metadataRevision: metadataRevision,
                generationRevision: current.query.generationRevision ?? metadataRevision
            ) else { return unknownCapabilityProjection(keys: keys, identity: nil) }
            return resolveRelayCapabilities(
                providerKind: providerKind, model: model, identity: identity,
                keys: keys, explicitKeys: explicitKeys
            )
        }

        let input = MetadataClient.shared.syncCapabilityEvidenceModelInput(
            modelID: model.id, providerKind: providerKind
        )
        guard let identity = current.resolvingFinalDispatch(
            request.url,
            effectiveTransport: effectiveTransport,
            metadataRevision: input.metadataRevision,
            generationRevision: input.resolved?.generationProfile?.revision ?? input.metadataRevision
        ) else { return unknownCapabilityProjection(keys: keys, identity: nil) }
        return resolveOfficialCapabilities(
            providerKind: providerKind, identity: identity, keys: keys,
            explicitKeys: explicitKeys, resolved: input.resolved,
            metadataRevision: input.metadataRevision, reasoningModes: input.reasoningModes,
            reasoningDefaultLevel: input.reasoningDefaultLevel
        )
    }

    private static func resolveOfficialCapabilities(
        providerKind: ProviderKind,
        identity: CapabilityEvidenceRequestIdentity,
        keys: Set<String>,
        explicitKeys: Set<String>,
        resolved: MetadataClient.ResolvedModelMetadata?,
        metadataRevision: String?,
        reasoningModes: [ReasoningMode],
        reasoningDefaultLevel: ReasoningMode?
    ) -> CapabilityEvidenceProjection {
        guard let resolved,
              identity.query.metadataRevision == metadataRevision,
              CapabilityEvidenceFacade.isConcreteTransport(identity.query.effectiveTransport),
              resolved.transport == identity.query.effectiveTransport else {
            return unknownCapabilityProjection(keys: keys, identity: identity)
        }
        guard !resolved.capabilityEvidenceViewMalformed else {
            return unknownCapabilityProjection(keys: keys, identity: identity)
        }

        var candidates = resolved.capabilityEvidenceCandidates
        for key in keys where isSafeCapabilityKey(key) {
            guard !resolved.capabilityEvidenceViewMalformed,
                  !resolved.capabilityEvidenceOwnedKeys.contains(key),
                  let legacy = officialLegacyCandidate(
                    key: key, providerKind: providerKind, resolved: resolved,
                    query: identity.query, metadataRevision: metadataRevision,
                    reasoningModes: reasoningModes
                  ) else { continue }
            candidates.append(legacy)
        }
        return resolvedProjection(
            keys: keys, identity: identity, explicitKeys: explicitKeys,
            candidates: candidates,
            reasoningDefaultLevel: reasoningDefaultLevel
        )
    }

    private static func resolveRelayCapabilities(
        providerKind: ProviderKind,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity,
        keys: Set<String>,
        explicitKeys: Set<String>
    ) -> CapabilityEvidenceProjection {
        guard isCompleteConnectionQuery(identity.query),
              let transport = RelayTransport(rawValue: identity.query.effectiveTransport) else {
            return unknownCapabilityProjection(keys: keys, identity: identity)
        }
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        let envelope = Set(RelayRuntimeSupport.envelopeCapabilities(
            transport: transport, runtimeConfig: runtime
        ))
        var candidates: [CapabilityEvidenceFacade.Candidate] = []
        for key in keys where isSafeCapabilityKey(key) {
            if let candidate = relayDeclarationCandidate(
                key: key, providerKind: providerKind, model: model,
                envelopeCapabilities: envelope, query: identity.query
            ) {
                candidates.append(candidate)
            }
        }
        return resolvedProjection(
            keys: keys, identity: identity, explicitKeys: explicitKeys,
            candidates: candidates,
            reasoningDefaultLevel: nil
        )
    }

    private static func resolvedProjection(
        keys: Set<String>,
        identity: CapabilityEvidenceRequestIdentity,
        explicitKeys: Set<String>,
        candidates: [CapabilityEvidenceFacade.Candidate],
        reasoningDefaultLevel: ReasoningMode?
    ) -> CapabilityEvidenceProjection {
        let resolutions = Dictionary(uniqueKeysWithValues: keys.map { key in
            let itemQuery = query(identity.query, hasExplicitValue: explicitKeys.contains(key))
            return (key, CapabilityEvidenceFacade.resolve(key: key, query: itemQuery, candidates: candidates))
        })
        return .init(
            identity: identity, resolutions: resolutions,
            declaredReasoningDefaultLevel: reasoningDefaultLevel
        )
    }

    private static func officialLegacyCandidate(
        key: String,
        providerKind: ProviderKind,
        resolved: MetadataClient.ResolvedModelMetadata,
        query: CapabilityEvidenceFacade.Query,
        metadataRevision: String?,
        reasoningModes: [ReasoningMode]
    ) -> CapabilityEvidenceFacade.Candidate? {
        let verdict: (CapabilityEvidenceFacade.Support, CapabilityEvidenceFacade.Source, CapabilityEvidenceFacade.Grade)?
        switch key {
        case "tool_call":
            verdict = resolved.toolCall.map {
                ($0 ? .supported : .unsupported, .legacyMetadata, .legacyUnverified)
            }
        case "web_search":
            switch CapabilityControlResolution.webVerdict(
                providerKind: providerKind,
                modelID: query.effectiveModelID,
                declaresWebCapability: resolved.capabilities.contains(.web),
                webSearchProfileName: resolved.profiles.webSearch
            ).state {
            case .autoAvailable, .managedOnly:
                verdict = (.supported, .serverProfile, .declared)
            case .unavailable:
                verdict = (.unsupported, .serverProfile, .declared)
            case .customOnly, .unknown:
                verdict = nil
            }
        case "vision_input":
            verdict = resolved.capabilities.contains(.image)
                ? (.supported, .legacyMetadata, .legacyUnverified) : nil
        default:
            if key.hasPrefix("reasoning_level/"),
               let rawLevel = trimmedNonEmpty(String(key.dropFirst("reasoning_level/".count))),
               let mode = ReasoningMode.fromIntent(rawLevel),
               trimmedNonEmpty(resolved.profiles.reasoning) != nil {
                verdict = reasoningModes.contains(mode)
                    ? (.supported, .serverProfile, .effectVerified)
                    : (.unsupported, .serverProfile, .declared)
            } else {
                verdict = nil
            }
        }
        guard let verdict else { return nil }
        return .init(
            key: key, support: verdict.0, source: verdict.1, grade: verdict.2,
            scope: .providerModelTransport, providerKind: providerKind.rawValue,
            modelID: query.effectiveModelID, transport: query.effectiveTransport,
            metadataRevision: metadataRevision
        )
    }

    private static func relayDeclarationCandidate(
        key: String,
        providerKind: ProviderKind,
        model: AIModel,
        envelopeCapabilities: Set<ModelCapability>,
        query: CapabilityEvidenceFacade.Query
    ) -> CapabilityEvidenceFacade.Candidate? {
        let support: CapabilityEvidenceFacade.Support
        switch key {
        case "tool_call":
            guard let declared = model.toolCall else { return nil }
            support = declared ? .unknown : .unsupported
        case "web_search":
            if !envelopeCapabilities.contains(.web) { support = .unsupported }
            else if model.capabilities.contains(.web), trimmedNonEmpty(model.webSearchProfile) != nil { support = .unknown }
            else { return nil }
        case "vision_input":
            if !envelopeCapabilities.contains(.image) { support = .unsupported }
            else if model.capabilities.contains(.image) { support = .unknown }
            else { return nil }
        default:
            guard key.hasPrefix("reasoning_level/") else { return nil }
            let rawLevel = String(key.dropFirst("reasoning_level/".count))
            guard let mode = ReasoningMode.fromIntent(rawLevel) else { return nil }
            if !envelopeCapabilities.contains(.reasoning) { support = .unsupported }
            else if trimmedNonEmpty(model.reasoningProfile) != nil,
                    MetadataClient.shared.syncSupportedReasoningModes(
                        profileName: model.reasoningProfile
                    ).contains(mode) { support = .unknown }
            else { return nil }
        }
        return .init(
            key: key, support: support, source: .relayDeclaration,
            grade: support == .unsupported ? .declared : .acceptedUnverified,
            scope: .connectionModelTransport,
            partitionID: query.partitionID, providerKind: providerKind.rawValue,
            modelID: query.effectiveModelID, transport: query.effectiveTransport,
            connectionInstanceID: query.connectionInstanceID,
            connectionGeneration: query.connectionGeneration,
            credentialEpoch: query.credentialEpoch,
            endpointFingerprint: query.endpointFingerprint,
            metadataRevision: query.metadataRevision
        )
    }

    private static func isSafeCapabilityKey(_ key: String) -> Bool {
        scalarCapabilityKeys.contains(key)
            || (key.hasPrefix("reasoning_level/")
                && trimmedNonEmpty(String(key.dropFirst("reasoning_level/".count))) != nil)
    }

    private static func unknownCapabilityProjection(
        keys: Set<String>, identity: CapabilityEvidenceRequestIdentity?
    ) -> CapabilityEvidenceProjection {
        let resolutions = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, CapabilityEvidenceFacade.Resolution(
                key: key, support: .unknown, source: .none, grade: .none,
                requestPolicy: .omitUnknown, reasonCode: .missingEvidence, policyEvidence: nil
            ))
        })
        return .init(
            identity: identity, resolutions: resolutions,
            declaredReasoningDefaultLevel: nil
        )
    }

    static func visionFilteredOutboundMessages(
        _ messages: [ChatMessage],
        request: URLRequest,
        effectiveTransport: String,
        model: AIModel?
    ) -> [ChatMessage] {
        let hasImages = messages.contains { message in
            message.attachments?.contains(where: { $0.kind == .image }) == true
        }
        guard hasImages else { return messages }
        let intent = finalDispatchIntent(
            request: request, effectiveTransport: effectiveTransport, model: model,
            keys: ["vision_input"], explicitKeys: ["vision_input"]
        )
        guard !intent.permitsOutbound("vision_input") else { return messages }
        return messages.map { message in
            var copy = message
            if let attachments = message.attachments {
                let filtered = attachments.filter { $0.kind != .image }
                copy.attachments = filtered.isEmpty ? nil : filtered
            }
            return copy
        }
    }
}

struct CapabilityEvidenceFinalChatIntent: Sendable, Equatable {
    let projection: CapabilityEvidenceProjection
    let outboundMessages: [ChatMessage]
    let webSearchEnabled: Bool
    let reasoningMode: ReasoningMode?
}

enum CapabilityEvidenceDispatchContext {
    @TaskLocal static var onWebSearchDispatched: (@Sendable () -> Void)?
}

final class CapabilityEvidenceDispatchOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func perform(_ action: () -> Void) {
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        action()
    }
}

extension CapabilityEvidenceProductionAdapter {
    static func finalChatIntent(
        messages: [ChatMessage],
        request: URLRequest,
        effectiveTransport: String,
        model: AIModel?,
        requestedReasoningMode: ReasoningMode,
        webSearchEnabled: Bool
    ) -> CapabilityEvidenceFinalChatIntent {
        let hasImages = messages.contains { message in
            message.attachments?.contains(where: { $0.kind == .image }) == true
        }
        var keys: Set<String> = []
        var explicitKeys: Set<String> = []
        if webSearchEnabled {
            keys.insert("web_search")
            explicitKeys.insert("web_search")
        }
        if hasImages {
            keys.insert("vision_input")
            explicitKeys.insert("vision_input")
        }

        let concreteReasoningModes: [ReasoningMode]
        if requestedReasoningMode == .automatic {
            concreteReasoningModes = ReasoningMode.allCases.filter { $0 != .automatic }
        } else {
            concreteReasoningModes = [requestedReasoningMode]
            explicitKeys.insert("reasoning_level/\(requestedReasoningMode.rawValue)")
        }
        keys.formUnion(concreteReasoningModes.map { "reasoning_level/\($0.rawValue)" })

        let projection = finalDispatchIntent(
            request: request, effectiveTransport: effectiveTransport, model: model,
            keys: keys, explicitKeys: explicitKeys
        )
        let selectedReasoningMode: ReasoningMode? = {
            let selected = requestedReasoningMode == .automatic
                ? projection.declaredReasoningDefaultLevel : requestedReasoningMode
            guard let selected,
                  projection.permitsOutbound("reasoning_level/\(selected.rawValue)") else {
                return nil
            }
            return selected
        }()
        let outboundMessages: [ChatMessage]
        if hasImages, !projection.permitsOutbound("vision_input") {
            outboundMessages = messages.map { message in
                var copy = message
                if let attachments = message.attachments {
                    let filtered = attachments.filter { $0.kind != .image }
                    copy.attachments = filtered.isEmpty ? nil : filtered
                }
                return copy
            }
        } else {
            outboundMessages = messages
        }
        let allowedWebSearch = webSearchEnabled && projection.permitsOutbound("web_search")
        if allowedWebSearch {
            CapabilityEvidenceDispatchContext.onWebSearchDispatched?()
        }
        return .init(
            projection: projection,
            outboundMessages: outboundMessages,
            webSearchEnabled: allowedWebSearch,
            reasoningMode: selectedReasoningMode
        )
    }
}
