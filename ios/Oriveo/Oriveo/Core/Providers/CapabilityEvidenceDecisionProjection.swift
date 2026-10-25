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
    /// Projections of the three input keys; filled by the two `capabilityProjection` entries and
    /// `finalDispatchIntent`. A key without a projection is still read from the resolution by the outbound gate.
    var inputProjections: [String: CapabilityEvidenceFacade.InputCapabilityProjection] = [:]

    func resolution(for key: String) -> CapabilityEvidenceFacade.Resolution? {
        resolutions[key]
    }

    func inputProjection(for key: String) -> CapabilityEvidenceFacade.InputCapabilityProjection? {
        inputProjections[key]
    }

    func permitsOutbound(_ key: String) -> Bool {
        if let input = inputProjections[key] { return input.outbound == .nativePart }
        guard let policy = resolution(for: key)?.requestPolicy else { return false }
        return policy == .allow || policy == .allowExplicitUnverified
    }

    func hasConclusiveDecision(_ key: String) -> Bool {
        guard let policy = resolution(for: key)?.requestPolicy else { return false }
        return policy != .omitUnknown
    }
}

extension CapabilityEvidenceProductionAdapter {
    private static let scalarCapabilityKeys: Set<String> = Set(
        ["tool_call", "web_search"] + CapabilityEvidenceFacade.inputCapabilityKeys
    )

    static func capabilityProjection(
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity?,
        keys: Set<String>,
        explicitKeys: Set<String> = []
    ) -> CapabilityEvidenceProjection {
        let form = ProviderForm.of(provider)
        guard let identity else {
            var projection = unknownCapabilityProjection(keys: keys, identity: nil)
            // A relay projection needs only the connection and the model: an incomplete UI identity (for example an auto connection) does not mean there is no connection identity.
            if form == .relay { projection.inputProjections = relayInputProjections(provider: provider, model: model, keys: keys) }
            return projection
        }
        var projection = formCapabilityProjection(
            form: form, provider: provider, model: model, identity: identity,
            keys: keys, explicitKeys: explicitKeys
        )
        projection.inputProjections = form == .relay
            ? relayInputProjections(provider: provider, model: model, keys: keys)
            : inputCapabilityProjections(
                form: form, providerKind: provider.kind, connectionID: provider.id.uuidString,
                identity: identity, keys: keys, resolutions: projection.resolutions,
                effectiveTransport: projection.identity?.query.effectiveTransport
            )
        return projection
    }

    private static func formCapabilityProjection(
        form: ProviderForm,
        provider: Provider,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity,
        keys: Set<String>,
        explicitKeys: Set<String>
    ) -> CapabilityEvidenceProjection {
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

    /// Projection of the three input keys. Hard blocks are added at this layer, and the truth adapters' own rulings stay unchanged:
    /// - Official: reads only `capabilityControls[key]`, a missing key = unknown; a missing wireFamily is inferred from the catalog transport, and a text-only transport counts as not implemented here;
    ///   the v2 negative cache is keyed by connectionId = provider.id (entries without a Provider use the TaskLocal-bound
    ///   connectionInstanceID, which has the same value) and wireFamily.
    /// - Subscription: the truth adapter's ruling (first-party > model-facts > catalog_silent) is projected by the table; the wire family follows the final subscription transport,
    ///   and a transport with no family for the key = not implemented here.
    /// - Relay: see `relayInputProjections`.
    private static func inputCapabilityProjections(
        form: ProviderForm,
        providerKind: ProviderKind,
        connectionID: String,
        identity: CapabilityEvidenceRequestIdentity,
        keys: Set<String>,
        resolutions: [String: CapabilityEvidenceFacade.Resolution],
        effectiveTransport: String? = nil
    ) -> [String: CapabilityEvidenceFacade.InputCapabilityProjection] {
        let inputKeys = keys.filter { CapabilityEvidenceFacade.inputCapabilityKeys.contains($0) }
        guard !inputKeys.isEmpty, form != .relay else { return [:] }
        let controls: [String: MetadataClient.CapabilityControl]? = form == .official
            ? MetadataClient.shared.syncCapabilityRecipeRuntime(
                modelID: identity.query.effectiveModelID, providerKind: providerKind
            ).controls
            : nil
        return Dictionary(uniqueKeysWithValues: inputKeys.map { key in
            let projection: CapabilityEvidenceFacade.InputCapabilityProjection
            switch form {
            case .official:
                projection = officialInputProjection(
                    key: key, control: controls?[key], providerKind: providerKind,
                    connectionID: connectionID, modelID: identity.query.effectiveModelID
                )
            case .subscription:
                let verdict = SubscriptionTruthAdapter.inputVerdict(
                    key: key, resolution: resolutions[key], transport: effectiveTransport
                )
                projection = CapabilityEvidenceFacade.inputCapabilityProjection(
                    verdict: verdict,
                    endImplements: verdict.wireFamily.map(CapabilityEvidenceFacade.implementsWireFamily) ?? false,
                    override: nil, negativeCacheHit: false, connection: .official
                )
            case .relay:
                preconditionFailure("relay input projection is produced by relayInputProjections")
            }
            return (key, projection)
        })
    }

    private static func officialInputProjection(
        key: String,
        control: MetadataClient.CapabilityControl?,
        providerKind: ProviderKind,
        connectionID: String,
        modelID: String
    ) -> CapabilityEvidenceFacade.InputCapabilityProjection {
        // The current transport is the catalog model's transport; when the ruling names no wire family, fall back to the (key, transport) table (the same rule as Web / Android).
        let transport = MetadataClient.shared.syncResolveCatalogModel(modelID: modelID, providerKind: providerKind)?
            .transport.map(CapabilityEvidenceFacade.canonicalInputTransport)
        let wireFamily = control?.wireFamily ?? CapabilityEvidenceFacade.inputWireFamily(key: key, transport: transport)
        let verdict: CapabilityEvidenceFacade.InputVerdict? = control.map { control in
            var state = CapabilityControlResolution.State(rawValue: control.state) ?? .unknown
            // The transport is unknown too and no wire family can be inferred: this client cannot tell whether it can send natively, so project unknown.
            if state == .autoAvailable, wireFamily == nil, transport == nil { state = .unknown }
            return .init(state: state, reasonCode: control.reasonCode, wireFamily: wireFamily)
        }
        // A text-only transport is always not implemented here; a known transport with no matching family is also not implemented; an unknown transport does not block (left to the ruling).
        let endImplements: Bool
        if let transport, CapabilityEvidenceFacade.textOnlyInputTransports.contains(transport) {
            endImplements = false
        } else if let wireFamily {
            endImplements = CapabilityEvidenceFacade.implementsWireFamily(wireFamily)
        } else {
            endImplements = transport == nil
        }
        let negativeCacheHit = wireFamily.map { family in
            CapabilityNegativeCache.shared.isRejected(
                connectionId: connectionID, modelId: modelID, wireFamily: family, capabilityKey: key,
                verdictRevision: CapabilityNegativeCache.verdictRevision(control.map {
                    .init(state: $0.state, reasonCode: $0.reasonCode, wireFamily: $0.wireFamily, sourceRefs: $0.sourceRefs)
                })
            )
        } ?? false
        return CapabilityEvidenceFacade.inputCapabilityProjection(
            verdict: verdict,
            endImplements: endImplements,
            override: nil,
            negativeCacheHit: negativeCacheHit,
            connection: .official
        )
    }

    private static func relayInputProjections(
        provider: Provider, model: AIModel, keys: Set<String>
    ) -> [String: CapabilityEvidenceFacade.InputCapabilityProjection] {
        // The protocol is the one actually sent first, the same key the relay negative cache writes with.
        relayInputProjections(
            connectionID: provider.id.uuidString, model: model,
            transport: RelayFirstSendTransport.current(provider: provider, model: model),
            consumesEngineDeclaration: hasEngineProfile(provider), keys: keys
        )
    }

    /// Relay projection of the three input keys. The server ruling is always unknown; priority:
    /// envelope rejection (looks only at the image / nativeFile bits, absence is not rejection; video ignores the envelope, and a first-send protocol without a video family is not implemented) > user delta override > v2 negative cache >
    /// local negative evidence (a tested override of false, a local engine declaration of false, from the same source as `RelayTruthAdapter`) > unknown.
    /// A tested override is not a user choice and cannot beat the negative cache; connectionId = provider.id.
    private static func relayInputProjections(
        connectionID: String,
        model: AIModel,
        transport: RelayTransport,
        consumesEngineDeclaration: Bool,
        keys: Set<String>
    ) -> [String: CapabilityEvidenceFacade.InputCapabilityProjection] {
        let inputKeys = keys.filter { CapabilityEvidenceFacade.inputCapabilityKeys.contains($0) }
        guard !inputKeys.isEmpty else { return [:] }
        let envelope = RelayRuntimeSupport.inputEnvelope(
            transport: transport, runtimeConfig: MetadataClient.shared.syncRelayRuntimeConfig()
        )
        let overrides = CapabilityOverrideNormalizer.normalize(
            connection: .relay, legacy: model.relayCapabilityOverrides, stored: nil,
            serverVerdict: [:], now: Date()
        )
        let visionEvidence = RelayTruthAdapter.visionEvidence(
            model: model, consumesEngineDeclaration: consumesEngineDeclaration
        )
        return Dictionary(uniqueKeysWithValues: inputKeys.map { key in
            let envelopeAccepts: Bool
            switch key {
            // A missing envelope is not rejection; only an explicit false is a hard block.
            case CapabilityEvidenceFacade.visionInputKey: envelopeAccepts = envelope?.image ?? true
            case CapabilityEvidenceFacade.fileInputKey: envelopeAccepts = envelope?.nativeFile ?? true
            // Video is not judged by the envelope; a first-send protocol with no video wire family (only chat has openai_chat.video_url) is not implemented here.
            default: envelopeAccepts = relayWireFamily(transport: transport, key: key) != nil
            }
            let override: CapabilityEvidenceFacade.InputOverride? = CapabilityOverrideKey(rawValue: key)
                .flatMap(overrides.effective)
                .map { $0 == .add ? .add : .remove }
            let negativeCacheHit = relayWireFamily(transport: transport, key: key).map { family in
                CapabilityNegativeCache.shared.isRejected(
                    connectionId: connectionID, modelId: model.id, wireFamily: family, capabilityKey: key,
                    verdictRevision: CapabilityNegativeCache.verdictRevision(relayInputVerdict(
                        key: key, visionEvidence: visionEvidence, wireFamily: family
                    ))
                )
            } ?? false
            return (key, CapabilityEvidenceFacade.inputCapabilityProjection(
                verdict: relayLocalVerdict(
                    key: key, model: model, legacyKept: overrides.legacyKept,
                    consumesEngineDeclaration: consumesEngineDeclaration
                ),
                endImplements: envelopeAccepts,
                override: override,
                negativeCacheHit: negativeCacheHit,
                connection: .relay
            ))
        })
    }

    /// The facade's composite ruling for a relay input key; the revisions on both the read and write side of the v2 negative cache take its hash
    /// instead of the missing-ruling hash:
    /// vision follows the connection evidence (supported -> auto_available; unsupported -> unavailable + model_capability_absent;
    /// anything else unknown, with no reasonCode); file / video = unknown + catalog_silent. wireFamily is the family of the first-send (or actually sent) protocol.
    static func relayInputVerdict(
        key: String,
        visionEvidence: CapabilityEvidenceFacade.Support?,
        wireFamily: String
    ) -> CapabilityNegativeCache.Verdict {
        typealias State = CapabilityControlResolution.State
        guard key == CapabilityEvidenceFacade.visionInputKey else {
            return .init(state: State.unknown.rawValue, reasonCode: "catalog_silent", wireFamily: wireFamily)
        }
        switch visionEvidence {
        case .supported?:
            return .init(state: State.autoAvailable.rawValue, wireFamily: wireFamily)
        case .unsupported?:
            return .init(state: State.unavailable.rawValue, reasonCode: "model_capability_absent", wireFamily: wireFamily)
        case .unknown?, nil:
            return .init(state: State.unknown.rawValue, wireFamily: wireFamily)
        }
    }

    /// Entry points that hold the Provider take the image connection evidence (a local engine declaration takes effect only when the connection has an engineProfile).
    static func relayVisionEvidence(provider: Provider, model: AIModel) -> CapabilityEvidenceFacade.Support? {
        RelayTruthAdapter.visionEvidence(model: model, consumesEngineDeclaration: hasEngineProfile(provider))
    }

    /// Local negative evidence exists only for vision: a tested override beats the engine declaration, and a user override is already normalized into a delta.
    private static func relayLocalVerdict(
        key: String,
        model: AIModel,
        legacyKept: RelayCapabilityOverrides?,
        consumesEngineDeclaration: Bool
    ) -> CapabilityEvidenceFacade.InputVerdict? {
        guard key == CapabilityEvidenceFacade.visionInputKey else { return nil }
        let declared = legacyKept?.image
            ?? (consumesEngineDeclaration ? model.engineDeclaration?.image : nil)
        return declared == false ? .init(state: .unavailable, reasonCode: "model_capability_absent") : nil
    }

    /// Relay transport x input key -> wire family; nil = this protocol has no such family, so the negative cache does not hit.
    static func relayWireFamily(transport: RelayTransport, key: String) -> String? {
        switch (transport, key) {
        case (.openaiChatCompletions, CapabilityEvidenceFacade.visionInputKey),
             (.auto, CapabilityEvidenceFacade.visionInputKey): return "openai_chat.image_url"
        case (.openaiChatCompletions, CapabilityEvidenceFacade.fileInputKey),
             (.auto, CapabilityEvidenceFacade.fileInputKey): return "openai_chat.file"
        case (.openaiChatCompletions, CapabilityEvidenceFacade.videoInputKey),
             (.auto, CapabilityEvidenceFacade.videoInputKey): return "openai_chat.video_url"
        case (.openaiResponses, CapabilityEvidenceFacade.visionInputKey): return "openai_responses.input_image"
        case (.openaiResponses, CapabilityEvidenceFacade.fileInputKey): return "openai_responses.input_file"
        case (.anthropicMessages, CapabilityEvidenceFacade.visionInputKey): return "anthropic.image"
        case (.anthropicMessages, CapabilityEvidenceFacade.fileInputKey): return "anthropic.document"
        case (.geminiGenerateContent, _): return CapabilityEvidenceFacade.inputCapabilityKeys.contains(key)
            ? "gemini.inline_data" : nil
        default: return nil
        }
    }

    /// The read side cannot get the connection (no Provider and no bound connection identity): the three relay input keys are hard blocked.
    private static func relayBlockedInputProjections(
        keys: Set<String>
    ) -> [String: CapabilityEvidenceFacade.InputCapabilityProjection] {
        Dictionary(uniqueKeysWithValues: keys.filter {
            CapabilityEvidenceFacade.inputCapabilityKeys.contains($0)
        }.map { key in
            (key, CapabilityEvidenceFacade.inputCapabilityProjection(
                verdict: nil, endImplements: false, override: nil, negativeCacheHit: false, connection: .relay
            ))
        })
    }

    /// Entries without a Provider (the form entry and the final writer) add the three-key projection for non-relay forms;
    /// the connection identity is the connectionInstanceID already bound on the identity.
    private static func attachingInputProjections(
        _ projection: CapabilityEvidenceProjection,
        form: ProviderForm,
        providerKind: ProviderKind,
        identity: CapabilityEvidenceRequestIdentity,
        keys: Set<String>
    ) -> CapabilityEvidenceProjection {
        var projection = projection
        projection.inputProjections = inputCapabilityProjections(
            form: form, providerKind: providerKind, connectionID: identity.query.connectionInstanceID,
            identity: identity, keys: keys, resolutions: projection.resolutions,
            effectiveTransport: projection.identity?.query.effectiveTransport
        )
        return projection
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
            var projection = unknownCapabilityProjection(keys: keys, identity: nil)
            if form == .relay { projection.inputProjections = relayBlockedInputProjections(keys: keys) }
            return projection
        }
        if form == .relay {
            var projection = unknownCapabilityProjection(keys: keys, identity: identity)
            projection.inputProjections = relayBlockedInputProjections(keys: keys)
            return projection
        }
        return attachingInputProjections(
            formResolutions(
                form: form, providerKind: providerKind, model: model, identity: identity,
                keys: keys, explicitKeys: explicitKeys
            ),
            form: form, providerKind: providerKind, identity: identity, keys: keys
        )
    }

    private static func formResolutions(
        form: ProviderForm,
        providerKind: ProviderKind,
        model: AIModel,
        identity: CapabilityEvidenceRequestIdentity,
        keys: Set<String>,
        explicitKeys: Set<String>
    ) -> CapabilityEvidenceProjection {
        switch form {
        case .relay:
            preconditionFailure("relay is handled by capabilityProjection(form:)")
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
        guard ProviderForm.of(provider) == .relay else { return nil }
        // Auto is first resolved to the first-send protocol on a model copy, and routing and the endpoint are both computed from it (the same shape as the ChatManager first-send protocol switch).
        var routed = model
        if RelayEndpointResolver.explicitTransport(provider: provider, model: model) == nil {
            routed.relayTransport = RelayFirstSendTransport.current(provider: provider, model: model)
        }
        guard let transport = RelayEndpointResolver.explicitTransport(provider: provider, model: routed),
              let requested = RelayEndpointResolver.routedRequested(provider: provider, model: routed),
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
            ) else {
                var projection = unknownCapabilityProjection(keys: keys, identity: nil)
                projection.inputProjections = relayBlockedInputProjections(keys: keys)
                return projection
            }
            var projection = resolveRelayCapabilities(
                form: form, providerKind: providerKind, model: model, identity: identity,
                keys: keys, explicitKeys: explicitKeys, consumesEngineDeclaration: consumesEngineDeclaration,
                webFragment: webFragment
            )
            // The connection identity comes from the TaskLocal binding (connectionInstanceID = provider.id), and the protocol is the one actually sent this time.
            if let transport = RelayTransport(rawValue: identity.query.effectiveTransport),
               trimmedNonEmpty(identity.query.connectionInstanceID) != nil {
                projection.inputProjections = relayInputProjections(
                    connectionID: identity.query.connectionInstanceID, model: model, transport: transport,
                    consumesEngineDeclaration: consumesEngineDeclaration, keys: keys
                )
            } else {
                projection.inputProjections = relayBlockedInputProjections(keys: keys)
            }
            return projection

        case .subscription:
            // The builder decides the subscription protocol (`subscriptionFinalTransport`); only the transport it already selected is trusted here.
            let metadataRevision = MetadataClient.shared.syncMetadataETag()
            guard let identity = current.resolvingFinalDispatch(
                request.url,
                effectiveTransport: effectiveTransport,
                metadataRevision: metadataRevision,
                generationRevision: current.query.generationRevision ?? metadataRevision
            ) else { return unknownCapabilityProjection(keys: keys, identity: nil) }
            return attachingInputProjections(
                resolveSubscriptionCapabilities(
                    form: form, providerKind: providerKind, model: model,
                    catalogModels: catalogModels, transport: effectiveTransport, identity: identity,
                    keys: keys, explicitKeys: explicitKeys
                ),
                form: form, providerKind: providerKind, identity: identity, keys: keys
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
            return attachingInputProjections(
                resolveOfficialCapabilities(
                    form: form, providerKind: providerKind, model: model, identity: identity,
                    keys: keys, explicitKeys: explicitKeys, input: input
                ),
                form: form, providerKind: providerKind, identity: identity, keys: keys
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
                },
                inputState: { key in
                    CapabilityControlResolution.inputVerdict(
                        providerKind: providerKind,
                        modelID: identity.query.effectiveModelID,
                        key: key
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
                },
                modelFactsInputModalities: {
                    SubscriptionTruthAdapter.modelFacts(providerKind: providerKind, model: $0)?.modalities?.input
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
    /// How images are delivered in this request: when the image projection's outbound is native_part (or there is no image, or the capability test keeps images)
    /// the builder assembles image parts per protocol; with placeholder no image is assembled and `AttachmentDelivery` writes one wire placeholder line per image.
    let imageOutbound: CapabilityEvidenceFacade.InputCapabilityProjection.Outbound
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
        // Native files read only the file_input projection: only files that carry native original data are asked about.
        let hasNativeFiles = messages.contains { message in
            message.attachments?.contains(where: carriesNativeFileData) == true
        }
        if hasNativeFiles {
            keys.insert(CapabilityEvidenceFacade.fileInputKey)
            explicitKeys.insert(CapabilityEvidenceFacade.fileInputKey)
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
        var outboundMessages: [ChatMessage]
        let imageOutbound: CapabilityEvidenceFacade.InputCapabilityProjection.Outbound
        // The image item of "Test capabilities" is itself testing this image, so neither an override of false nor the negative cache may strip it.
        // A relay with unknown image understanding still sends the image: envelope, override and negative-cache stripping are all folded into the input projection of vision_input.
        if hasImages, !keepImageAttachments, !projection.permitsOutbound(CapabilityEvidenceFacade.visionInputKey) {
            imageOutbound = .placeholder
            if imagePlaceholderText != nil {
                // A transport that declares a placeholder: the images stay in the copy and AttachmentDelivery writes a placeholder per image
                // (body -> file blocks -> placeholder); the builder sees `.placeholder` and assembles no image parts.
                outboundMessages = messages
            } else {
                outboundMessages = messages.map { message in
                    var copy = message
                    if let attachments = message.attachments {
                        let filtered = attachments.filter { $0.kind != .image }
                        copy.attachments = filtered.isEmpty ? nil : filtered
                    }
                    return copy
                }
            }
        } else {
            imageOutbound = .nativePart
            outboundMessages = messages
        }
        // When file_input does not allow it, drop the native original data so the file goes through AttachmentDelivery text injection, with no placeholder.
        // The projection is only a necessary condition: after it allows, the mime allowlist / pdfNativeDefault still judge the format.
        if hasNativeFiles, !projection.permitsOutbound(CapabilityEvidenceFacade.fileInputKey) {
            outboundMessages = outboundMessages.map(removingNativeFileData)
        }
        let allowedWebSearch = webSearchEnabled && projection.permitsOutbound("web_search")
        if allowedWebSearch {
            CapabilityEvidenceDispatchContext.onWebSearchDispatched?()
        }
        return .init(
            projection: projection,
            outboundMessages: outboundMessages,
            webSearchEnabled: allowedWebSearch,
            reasoningMode: selectedReasoningMode,
            imageOutbound: imageOutbound
        )
    }
}

extension CapabilityEvidenceProductionAdapter {
    /// File attachments that carry native original data (originalBase64Data): the file_input projection covers only this kind.
    static func carriesNativeFileData(_ attachment: Attachment) -> Bool {
        attachment.kind == .file && attachment.originalBase64Data?.isEmpty == false
    }

    /// Drops the native original data of a file and keeps the extracted text for AttachmentDelivery text injection.
    static func removingNativeFileData(_ message: ChatMessage) -> ChatMessage {
        var copy = message
        copy.attachments = message.attachments?.map { attachment in
            guard carriesNativeFileData(attachment) else { return attachment }
            var textOnly = attachment
            textOnly.originalBase64Data = nil
            return textOnly
        }
        return copy
    }
}
