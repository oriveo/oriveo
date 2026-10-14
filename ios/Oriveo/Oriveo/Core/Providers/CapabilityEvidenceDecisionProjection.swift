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
        let form = ProviderForm.of(provider)
        switch form {
        case .relay:
            return resolveRelayCapabilities(
                form: form, providerKind: provider.kind, model: model, identity: identity,
                keys: keys, explicitKeys: explicitKeys,
                consumesEngineDeclaration: hasEngineProfile(provider),
                webFragment: relayWebFragment(provider: provider, model: model)
            )
        case .subscription:
            return resolveSubscriptionCapabilities(
                form: form, providerKind: provider.kind, model: model,
                catalogModels: provider.catalogModels,
                transport: CapabilityControlResolution.subscriptionFinalTransport(for: provider, model: model),
                identity: identity, keys: keys, explicitKeys: explicitKeys
            )
        case .official:
            return resolveOfficialCapabilities(
                form: form, providerKind: provider.kind, model: model, identity: identity,
                keys: keys, explicitKeys: explicitKeys
            )
        }
    }

    /// For callers that do not hold the Provider object. The connection identity is already bound by the ChatManager TaskLocal;
    /// this builds candidates only from the same metadata pair, reads no key and triggers no network. A relay declaration needs the
    /// connection object, so this entry fails closed for a relay.
    ///
    /// The caller has no Provider, so it supplies the form directly; `providerKind` is used only to look up the official metadata.
    static func capabilityProjection(
        form: ProviderForm,
        providerKind: ProviderKind,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity?,
        keys: Set<String>,
        explicitKeys: Set<String> = []
    ) -> CapabilityEvidenceProjection {
        guard let identity else {
            return unknownCapabilityProjection(keys: keys, identity: nil)
        }
        switch form {
        case .relay:
            return unknownCapabilityProjection(keys: keys, identity: identity)
        case .subscription:
            // Without a Provider the subscription protocol cannot be computed, so the identity transport the caller already settled on is trusted.
            return resolveSubscriptionCapabilities(
                form: form, providerKind: providerKind, model: model, catalogModels: nil,
                transport: identity.query.effectiveTransport,
                identity: identity, keys: keys, explicitKeys: explicitKeys
            )
        case .official:
            return resolveOfficialCapabilities(
                form: form, providerKind: providerKind, model: model, identity: identity,
                keys: keys, explicitKeys: explicitKeys
            )
        }
    }

    static func uiDispatchIdentity(
        provider: Provider,
        model: AIModel,
        partitionID: String
    ) -> CapabilityEvidenceRequestIdentity? {
        guard ProviderForm.of(provider) == .relay,
              let transport = RelayEndpointResolver.explicitTransport(provider: provider, model: model),
              let requested = RelayEndpointResolver.routedRequested(provider: provider, model: model),
              let rawBaseURL = trimmedNonEmpty(provider.baseURLText),
              trimmedNonEmpty(partitionID) != nil,
              let endpoint = relayChatEndpoint(
                apiRoot: RelayEndpointResolver.injectedAPIRoot(requested) ?? rawBaseURL,
                modelID: ModelResolver.resolvedProviderModelIdentifier(
                    model.id, providerKind: provider.kind
                ),
                transport: transport,
                requested: requested
              ) else { return nil }

        let metadataRevision = MetadataClient.shared.syncMetadataETag()
        let localProfile = LocalEngineGenerationProfiles.profile(
            for: requested.engineProfile, transport: transport
        )
        let generationRevision = mergeRelayDeclaration(
            localProfile, model.generationProfile
        )?.revision ?? metadataRevision
        return CapabilityEvidenceRequestIdentity.make(
            provider: provider, model: model, partitionID: partitionID,
            hasExplicitValue: false, effectiveTransport: transport.rawValue,
            metadataETag: metadataRevision
        ).resolvingFinalDispatch(
            endpoint,
            effectiveTransport: transport.rawValue,
            metadataRevision: metadataRevision,
            generationRevision: generationRevision
        )
    }

    /// `requested` is a copy of `routedRequested`, the same one the service gets at send time;
    /// for an existing connection it is the connection config as is, so the endpoint is byte-identical to before per-model routing.
    private static func relayChatEndpoint(
        apiRoot: String,
        modelID: String,
        transport: RelayTransport,
        requested: RelayRequestedConfig
    ) -> URL? {
        let credentials = RelayEndpointPolicy.Credentials(
            authMode: requested.authMode,
            hasKey: false,
            sensitiveHeaders: requested.effectiveHeaders?.map(\.key) ?? [],
            sensitiveQueryKeys: requested.effectiveQueryParams?.map(\.key) ?? []
        )
        guard let configured = try? RelayEndpointPolicy.requireConfigured(
            apiRoot,
            securityMode: requested.securityMode,
            credentials: credentials
        ) else { return nil }

        do {
            switch transport {
            case .auto:
                return nil
            case .llamacppNative:
                return URL(string: configured.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                ) + "/completion")
            case .openaiChatCompletions, .openaiResponses, .anthropicMessages,
                 .geminiGenerateContent:
                let defaultVersion = transport == .geminiGenerateContent ? "v1beta" : "v1"
                let acceptedVersions: Set<String> = transport == .geminiGenerateContent
                    ? ["v1", "v1beta"] : ["v1"]
                let apiBaseURL = try RelayEndpointResolver.runtimeAPIBaseURL(
                    rawBaseURL: configured,
                    relayRequested: requested,
                    defaultVersion: defaultVersion,
                    acceptedVersions: acceptedVersions
                )
                let endpointPath: String
                switch transport {
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
        let form = ProviderForm.of(provider)
        return finalDispatchIntent(
            request: request, effectiveTransport: effectiveTransport,
            form: form, providerKind: provider.kind, model: model, current: current,
            keys: keys, explicitKeys: explicitKeys,
            catalogModels: form == .subscription ? provider.catalogModels : nil,
            consumesEngineDeclaration: hasEngineProfile(provider),
            webFragment: relayWebFragment(provider: provider, model: model)
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
              let authMode = ProviderAuthMode(rawValue: current.query.authMode),
              let model,
              current.query.modelID == model.id,
              CapabilityEvidenceFacade.isConcreteTransport(effectiveTransport) else {
            return unknownCapabilityProjection(keys: keys, identity: nil)
        }
        return finalDispatchIntent(
            request: request, effectiveTransport: effectiveTransport,
            form: ProviderForm.of(kind: providerKind, authMode: authMode),
            providerKind: providerKind, model: model, current: current,
            keys: keys, explicitKeys: explicitKeys,
            // No Provider is available: declarations are written only by the local connector, so a model that carries one belongs to a local engine connection.
            consumesEngineDeclaration: model.engineDeclaration != nil
        )
    }

    private static func finalDispatchIntent(
        request: URLRequest,
        effectiveTransport: String,
        form: ProviderForm,
        providerKind: ProviderKind,
        model: AIModel,
        current: CapabilityEvidenceRequestIdentity,
        keys: Set<String>,
        explicitKeys: Set<String>,
        catalogModels: [AIModel]? = nil,
        consumesEngineDeclaration: Bool = false,
        webFragment: CapabilityTruthInput.Relay.WebFragment? = nil
    ) -> CapabilityEvidenceProjection {
        switch form {
        case .relay:
            let metadataRevision = MetadataClient.shared.syncMetadataETag()
            guard let identity = current.resolvingFinalDispatch(
                request.url,
                effectiveTransport: effectiveTransport,
                metadataRevision: metadataRevision,
                generationRevision: current.query.generationRevision ?? metadataRevision
            ) else { return unknownCapabilityProjection(keys: keys, identity: nil) }
            return resolveRelayCapabilities(
                form: form, providerKind: providerKind, model: model, identity: identity,
                keys: keys, explicitKeys: explicitKeys, consumesEngineDeclaration: consumesEngineDeclaration,
                webFragment: webFragment
            )

        case .subscription:
            // The builder decides the subscription protocol (`subscriptionFinalTransport`); only the transport it already selected is trusted here.
            let metadataRevision = MetadataClient.shared.syncMetadataETag()
            guard let identity = current.resolvingFinalDispatch(
                request.url,
                effectiveTransport: effectiveTransport,
                metadataRevision: metadataRevision,
                generationRevision: current.query.generationRevision ?? metadataRevision
            ) else { return unknownCapabilityProjection(keys: keys, identity: nil) }
            return resolveSubscriptionCapabilities(
                form: form, providerKind: providerKind, model: model,
                catalogModels: catalogModels, transport: effectiveTransport, identity: identity,
                keys: keys, explicitKeys: explicitKeys
            )

        case .official:
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
                form: form, providerKind: providerKind, model: model, identity: identity,
                keys: keys, explicitKeys: explicitKeys, input: input
            )
        }
    }

    private typealias OfficialMetadataInput = (
        resolved: MetadataClient.ResolvedModelMetadata?,
        metadataRevision: String?,
        reasoningModes: [ReasoningMode],
        reasoningDefaultLevel: ReasoningMode?
    )

    /// When the caller passes `input`, the identity and the candidates come from the same metadata read (the final writer needs this);
    /// otherwise it is read once here.
    private static func resolveOfficialCapabilities(
        form: ProviderForm,
        providerKind: ProviderKind,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity,
        keys: Set<String>,
        explicitKeys: Set<String>,
        input suppliedInput: OfficialMetadataInput? = nil
    ) -> CapabilityEvidenceProjection {
        let input = suppliedInput ?? MetadataClient.shared.syncCapabilityEvidenceModelInput(
            modelID: model.id, providerKind: providerKind
        )
        let metadataRevision = input.metadataRevision
        guard let resolved = input.resolved,
              identity.query.metadataRevision == metadataRevision,
              CapabilityEvidenceFacade.isConcreteTransport(identity.query.effectiveTransport),
              resolved.transport == identity.query.effectiveTransport else {
            return unknownCapabilityProjection(keys: keys, identity: identity)
        }
        guard !resolved.capabilityEvidenceViewMalformed else {
            return unknownCapabilityProjection(keys: keys, identity: identity)
        }

        let candidates = CapabilityTruthRegistry.adapter(for: form).candidates(.init(
            providerKind: providerKind, model: model,
            keys: keys.filter(isSafeCapabilityKey), query: identity.query,
            official: .init(
                resolved: resolved, metadataRevision: metadataRevision,
                reasoningModes: input.reasoningModes,
                webState: {
                    CapabilityControlResolution.webVerdict(
                        providerKind: providerKind,
                        modelID: identity.query.effectiveModelID,
                        declaresWebCapability: resolved.capabilities.contains(.web),
                        webSearchProfileName: resolved.profiles.webSearch
                    ).state
                }
            )
        ))
        return resolvedProjection(
            keys: keys, identity: identity, explicitKeys: explicitKeys,
            candidates: candidates,
            reasoningDefaultLevel: input.reasoningDefaultLevel
        )
    }

    private static func hasEngineProfile(_ provider: Provider) -> Bool {
        trimmedNonEmpty(provider.relayRequested?.engineProfile) != nil
    }

    /// Input for relay web-search truth: the fragment decision and the record lookup always use the model's first-send protocol,
    /// resolved the same way as `RelayWebProbe.chatFragments` / `panelFact`; when a fragment exists it carries the probe record result under the current fragment.
    private static func relayWebFragment(provider: Provider, model: AIModel) -> CapabilityTruthInput.Relay.WebFragment? {
        guard ProviderForm.of(provider) == .relay,
              let fact = RelayWebProbe.fact(provider: provider, model: model, preference: nil) else { return nil }
        return .init(probe: fact.probe)
    }

    private static func resolveRelayCapabilities(
        form: ProviderForm,
        providerKind: ProviderKind,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity,
        keys: Set<String>,
        explicitKeys: Set<String>,
        consumesEngineDeclaration: Bool,
        webFragment: CapabilityTruthInput.Relay.WebFragment? = nil
    ) -> CapabilityEvidenceProjection {
        guard isCompleteConnectionQuery(identity.query),
              let transport = RelayTransport(rawValue: identity.query.effectiveTransport) else {
            return unknownCapabilityProjection(keys: keys, identity: identity)
        }
        let runtime = MetadataClient.shared.syncRelayRuntimeConfig()
        let envelope = Set(RelayRuntimeSupport.envelopeCapabilities(
            transport: transport, runtimeConfig: runtime
        ))
        let candidates = CapabilityTruthRegistry.adapter(for: form).candidates(.init(
            providerKind: providerKind, model: model,
            keys: keys.filter(isSafeCapabilityKey), query: identity.query,
            relay: .init(
                envelopeCapabilities: envelope,
                supportedReasoningModes: {
                    MetadataClient.shared.syncSupportedReasoningModes(profileName: $0)
                },
                consumesEngineDeclaration: consumesEngineDeclaration,
                webFragment: webFragment
            )
        ))
        return resolvedProjection(
            keys: keys, identity: identity, explicitKeys: explicitKeys,
            candidates: candidates,
            reasoningDefaultLevel: nil
        )
    }

    /// Subscription (Codex / Grok subscription login): capabilities follow only the upstream `/models` snapshot; the transport comes from
    /// the link itself (`subscriptionFinalTransport`) and fails closed when it cannot be computed. The level source is injected into the adapter as a closure.
    private static func resolveSubscriptionCapabilities(
        form: ProviderForm,
        providerKind: ProviderKind,
        model: AIModel,
        catalogModels: [AIModel]?,
        transport: String?,
        identity: CapabilityEvidenceRequestIdentity,
        keys: Set<String>,
        explicitKeys: Set<String>
    ) -> CapabilityEvidenceProjection {
        guard let transport,
              let subscriptionIdentity = identity.resolvingCapabilityRuntimeTransport(transport) else {
            return unknownCapabilityProjection(keys: keys, identity: identity)
        }
        let candidates = CapabilityTruthRegistry.adapter(for: form).candidates(.init(
            providerKind: providerKind, model: model,
            keys: keys.filter(isSafeCapabilityKey), query: subscriptionIdentity.query,
            subscription: .init(
                finalTransport: transport,
                declaredReasoningLevels: {
                    CapabilityControlResolution.subscriptionDeclaredReasoningLevels(
                        providerKind: providerKind, model: $0
                    )
                }
            ),
            catalogModels: catalogModels
        ))
        // Keys the adapter has no ruling for (`tool_call`, and every key when the catalog is empty) stay unknown and are not sent outbound,
        // as before the adapter was introduced; handing them to the facade would take the "no candidate + user explicit" pass-through,
        // which would loosen the catalog-backed form.
        let decided = Set(candidates.map(\.key))
        let resolutions = Dictionary(uniqueKeysWithValues: keys.map { key in
            guard decided.contains(key) else {
                return (key, CapabilityEvidenceFacade.Resolution(
                    key: key, support: .unknown, source: .none, grade: .none,
                    requestPolicy: .omitUnknown, reasonCode: .missingEvidence, policyEvidence: nil
                ))
            }
            let itemQuery = query(subscriptionIdentity.query, hasExplicitValue: explicitKeys.contains(key))
            return (key, CapabilityEvidenceFacade.resolve(key: key, query: itemQuery, candidates: candidates))
        })
        return .init(
            identity: subscriptionIdentity, resolutions: resolutions,
            declaredReasoningDefaultLevel: nil
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
}

struct CapabilityEvidenceFinalChatIntent: Sendable, Equatable {
    let projection: CapabilityEvidenceProjection
    let outboundMessages: [ChatMessage]
    let webSearchEnabled: Bool
    let reasoningMode: ReasoningMode?
}

/// Side channel fired only after the final serializer confirms web_search actually goes out.
/// The TaskLocal lets a request rebuilt by retry / self-heal keep using the same send's dedup gate,
/// so telemetry never becomes a condition of capability judgement.
nonisolated enum CapabilityEvidenceDispatchContext {
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
    /// When a relay's image understanding is unknown, the image is sent anyway: it is stripped only on negative evidence (an override of false /
    /// an engine declaration of false / a protocol envelope that does not accept images, all already folded into the resolution's unsupported)
    /// or when the `image` negative cache for that key has not expired. The adapter is not given an unknown candidate (that would light up the
    /// model library badge); without a complete connection identity it still fails closed. Other forms are unchanged.
    static func relayPermitsUnknownImage(
        projection: CapabilityEvidenceProjection,
        model: AIModel?,
        negativeCache: RelayNegativeCache = .shared
    ) -> Bool {
        guard let model,
              let query = projection.identity?.query,
              let providerKind = ProviderKind(rawValue: query.providerKind),
              let authMode = ProviderAuthMode(rawValue: query.authMode),
              ProviderForm.of(kind: providerKind, authMode: authMode) == .relay,
              isCompleteConnectionQuery(query),
              CapabilityEvidenceFacade.isConcreteTransport(query.effectiveTransport),
              projection.resolution(for: "vision_input")?.support != .unsupported else { return false }
        return !negativeCache.isRejected(
            connectionID: query.connectionInstanceID, modelID: model.id,
            transport: query.effectiveTransport, kind: .image
        )
    }

    static func finalChatIntent(
        messages: [ChatMessage],
        request: URLRequest,
        effectiveTransport: String,
        model: AIModel?,
        requestedReasoningMode: ReasoningMode,
        webSearchEnabled: Bool,
        imagePlaceholderText: String? = nil,
        keepImageAttachments: Bool = false
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
        // The image item of "Test capabilities" is itself testing this image, so neither an override of false nor the negative cache may strip it.
        if hasImages, !keepImageAttachments, !projection.permitsOutbound("vision_input"),
           !relayPermitsUnknownImage(projection: projection, model: model) {
            outboundMessages = messages.map { message in
                var copy = message
                if let attachments = message.attachments {
                    let filtered = attachments.filter { $0.kind != .image }
                    copy.attachments = filtered.isEmpty ? nil : filtered
                    // On a text-only route, a removed image leaves a placeholder line in the body (the same bytes and position as AttachmentDelivery writes),
                    // otherwise the model would not know the user attached an image.
                    let removed = attachments.count - filtered.count
                    if let imagePlaceholderText, removed > 0 {
                        copy.text = ([message.text] + Array(repeating: imagePlaceholderText, count: removed))
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n\n")
                    }
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
