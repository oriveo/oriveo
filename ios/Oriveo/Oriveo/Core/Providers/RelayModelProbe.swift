import Foundation

// MARK: - Relay 2.0 per-model probe
//
// The candidate order only decides which protocol the 1-token probe tries first: it is not a source, not persisted and not displayed.
// A passing probe only writes `reachable` on that model and writes the root address into `relayRequested.resolvedAPIBaseURLs[protocol]`;
// the connection's default protocol (`relayRequested.transport`) is never changed by a probe.

/// Pure function for the candidate order (`candidateRules` in the fixture `shared/test-fixtures/relay/probe-orchestration.v1.json`).
nonisolated enum RelayProbeCandidates {
    static let maxCandidates = 2

    static let endpointTypeToCandidate: [String: RelayTransport] = [
        "openai": .openaiChatCompletions,
        "openai-response": .openaiResponses,
        "anthropic": .anthropicMessages,
        "gemini": .geminiGenerateContent,
    ]

    static let familyCandidates: [String: [RelayTransport]] = [
        "anthropic": [.anthropicMessages, .openaiChatCompletions],
        "google": [.geminiGenerateContent, .openaiChatCompletions],
        "openai": [.openaiResponses, .openaiChatCompletions],
    ]

    static let defaultCandidates: [RelayTransport] = [.openaiChatCompletions]

    /// The endpoint types self-reported by the catalog are mapped in array order, dropping unrecognized and duplicate ones; if all are dropped, returns empty.
    static func fromEndpointTypes(_ types: [String]?) -> [RelayTransport] {
        var result: [RelayTransport] = []
        for raw in types ?? [] {
            guard let candidate = endpointTypeToCandidate[raw], !result.contains(candidate) else { continue }
            result.append(candidate)
        }
        return Array(result.prefix(maxCandidates))
    }

    /// A family hit goes through the family table; a miss, an unknown family or an unavailable lookup tries only Chat. The family is never guessed from the model id text.
    static func fromFamily(_ family: String?) -> [RelayTransport] {
        let candidates = family.flatMap { familyCandidates[$0] } ?? defaultCandidates
        return Array(candidates.prefix(maxCandidates))
    }

    /// Full rule: if endpoint types yield a result use it, otherwise look up the family lazily (`family` is called only when needed).
    static func candidates(
        supportedEndpointTypes: [String]?,
        family: () async -> String?
    ) async -> [RelayTransport] {
        let fromTypes = fromEndpointTypes(supportedEndpointTypes)
        if !fromTypes.isEmpty { return fromTypes }
        return fromFamily(await family())
    }

    /// Candidates when only a generation route was found (no catalog) (fixture `generationRouteCases`): the protocol found comes first,
    /// followed by the result of the full rule, de-duplicated, at most `maxCandidates`.
    static func generationRouteCandidates(
        route: RelayTransport,
        supportedEndpointTypes: [String]?,
        family: () async -> String?
    ) async -> [RelayTransport] {
        var result = [route]
        for candidate in await candidates(supportedEndpointTypes: supportedEndpointTypes, family: family)
        where !result.contains(candidate) {
            result.append(candidate)
        }
        return Array(result.prefix(maxCandidates))
    }

    /// The user chose a connection protocol (not `auto`) and the model has no protocol of its own: the model follows the connection (fixture
    /// `candidateRules.explicitConnection`). Such a model is not probed and no model field is written, and the protocol fallback at send time has no other candidate either.
    static func followsUserChosenConnection(provider: Provider, model: AIModel) -> Bool {
        if let own = model.relayTransport, own != .auto { return false }
        return RelayEndpointResolver.requestedConnectionTransport(of: provider) != .auto
    }
}

/// The protocol an unverified model actually uses on its first send. Sending (`ChatManager.relayFirstSendTransport`), negative-cache reads and writes, and the "Auto =" in the Advanced page
/// share this one answer: when the first send is rejected on Messages, the negative cache is recorded under Messages, and if the read side still looked it up by `effectiveTransport` (Chat)
/// it would never hit.
nonisolated enum RelayFirstSendTransport {
    /// Changed only for relay, non-local-engine, a model without its own protocol, not following a user-chosen connection, and non-image-generation; it is taken only if the first candidate is Messages
    /// (the OpenAI family still first-sends on Chat: many relays answer 400 for Responses and do not fall back). Everything else is `effectiveTransport`.
    static func resolve(
        provider: Provider,
        model: AIModel,
        family: String?,
        supportedEndpointTypes: [String]?
    ) -> RelayTransport {
        let effective = RelayEndpointResolver.effectiveTransport(provider: provider, model: model)
        guard provider.kind == .relay,
              provider.relayRequested?.engineProfile == nil,
              model.relayTransport == nil || model.relayTransport == .auto,
              !RelayProbeCandidates.followsUserChosenConnection(provider: provider, model: model),
              !RelayRuntimeSupport.dispatchesImageGeneration(model: model) else { return effective }
        // Synchronous version of the same rule as `RelayProbeCandidates.candidates`: if endpoint types yield a result use it, otherwise look at the family.
        let fromTypes = RelayProbeCandidates.fromEndpointTypes(supportedEndpointTypes)
        let candidates = fromTypes.isEmpty ? RelayProbeCandidates.fromFamily(family) : fromTypes
        return candidates.first == .anthropicMessages ? .anthropicMessages : effective
    }

    /// Reads the family table and catalog endpoint types already cached in this session (no request is made for it).
    static func current(
        provider: Provider,
        model: AIModel,
        endpointTypes: RelayCatalogEndpointTypesCache = .shared,
        family: (String) -> String? = { MetadataClient.shared.cachedRelayModelFamilyNow(for: $0) }
    ) -> RelayTransport {
        guard provider.kind == .relay else {
            return RelayEndpointResolver.effectiveTransport(provider: provider, model: model)
        }
        return resolve(
            provider: provider, model: model,
            family: family(model.id),
            supportedEndpointTypes: endpointTypes.endpointTypes(endpoint: provider.baseURLText, modelID: model.id)
        )
    }
}

/// The `supported_endpoint_types` of every model in the latest catalog result, cached in memory (not persisted) by connection address (`Provider.baseURLText`,
/// that is, the value passed to `RelayDiscoveryService.discover(endpoint:)`).
/// When unavailable (never probed / process restarted / gateway does not report it) the family path is used.
nonisolated final class RelayCatalogEndpointTypesCache: @unchecked Sendable {
    static let shared = RelayCatalogEndpointTypesCache()

    private let lock = NSLock()
    private var byEndpoint: [String: [String: [String]]] = [:]

    func record(endpoint: String, endpointTypesByModel: [String: [String]]) {
        let key = Self.key(endpoint)
        lock.withLock { byEndpoint[key] = endpointTypesByModel }
    }

    func endpointTypes(endpoint: String?, modelID: String) -> [String]? {
        guard let endpoint else { return nil }
        let key = Self.key(endpoint)
        return lock.withLock { byEndpoint[key]?[modelID] }
    }

    func removeAll() {
        lock.withLock { byEndpoint.removeAll() }
    }

    private static func key(_ endpoint: String) -> String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Probes one model: using the production ping primitive, sends 1 token per candidate in turn, and only a success counts as passing.
/// It does not write back -- after getting the `Outcome` the caller writes it to the provider with `apply`. Shared by the add flow and lazy verification in the model library.
enum RelayModelProbe {
    struct Outcome: Equatable, Sendable {
        let transport: RelayTransport
        let apiRoot: String
    }

    /// The three outcomes of one probe request (fixture `probeOutcomeRules`).
    enum StepResult: Equatable, Sendable {
        /// Passed: record `reachable` and stop.
        case pass
        /// Route-level rejection: this protocol path does not serve this model, try the next candidate.
        case routeRejected
        /// Could not be determined (key, rate limit, upstream failure, parameter rejected, network...): stop immediately and do not send the next candidate with the same key.
        case inconclusive
    }

    /// Output cap of the probe request (fixture `probeRequestRules`): Responses uses the official minimum of 16, the other protocols 1.
    static let responsesMaxOutputTokens = 16
    static let otherProtocolsMaxTokens = 1

    /// One 1-token probe. `requested` is already the copy of this model routed by the candidate protocol (the protocol and root address are both in it);
    /// a throw means not passed, and whether to move to the next candidate or stop here is decided by `classify` from that upstream HTTP failure.
    typealias Ping = (_ requested: RelayRequestedConfig?, _ modelID: String) async throws -> Void

    /// Which kind the failed probe falls under: the criterion is the send-time protocol fallback's `RelayProtocolFallback.isRouteRejection`;
    /// no HTTP response (network error, construction failure) is always "could not be determined".
    nonisolated static func classify(_ rejection: RelayPreOutputRejection?) -> StepResult {
        guard let rejection, RelayProtocolFallback.isRouteRejection(rejection) else { return .inconclusive }
        return .routeRejected
    }

    /// The copy of the connection and the root address the send path would use after temporarily setting the model protocol to the candidate.
    /// It goes through the send injection points `routedRequested` and `effectiveAPIRoot`, so probing takes the same road as a real send.
    static func probeRoute(
        provider: Provider,
        model: AIModel,
        candidate: RelayTransport
    ) -> (requested: RelayRequestedConfig?, apiRoot: String) {
        var probeModel = model
        probeModel.relayTransport = candidate
        probeModel.relayTransportSource = .reachable
        return (
            RelayEndpointResolver.routedRequested(provider: provider, model: probeModel),
            RelayEndpointResolver.effectiveAPIRoot(provider: provider, model: probeModel)
        )
    }

    /// Tries the candidates in turn (at most `RelayProbeCandidates.maxCandidates`) and returns the first protocol and root that pass; returns nil if none passes.
    /// Only a route-level rejection moves on to the next candidate; any other failure stops here. Only cancellation is thrown upward.
    /// `onFailure` receives each failure's error and the upstream HTTP failure of that attempt (nil if there was no HTTP response), for "View reason".
    static func probe(
        provider: Provider,
        model: AIModel,
        candidates: [RelayTransport],
        onFailure: ((_ error: Error, _ rejection: RelayPreOutputRejection?) -> Void)? = nil,
        ping: Ping
    ) async throws -> Outcome? {
        for candidate in candidates.prefix(RelayProbeCandidates.maxCandidates) {
            try Task.checkCancellation()
            let route = probeRoute(provider: provider, model: model, candidate: candidate)
            // The production ping records the upstream failure of that attempt (non-2xx, or 2xx whose content is a web page); the criterion looks only at it.
            let recorder = RelayPreOutputRejection.Recorder()
            do {
                try await RelayPreOutputRejection.$current.withValue(recorder) {
                    try await ping(route.requested, model.id)
                }
                return Outcome(transport: candidate, apiRoot: route.apiRoot)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onFailure?(error, recorder.rejection)
                guard classify(recorder.rejection) == .routeRejected else { return nil }
            }
        }
        return nil
    }

    /// Write-back: model `relayTransport = candidate`, `source = reachable`; the connection only adds
    /// the single entry `resolvedAPIBaseURLs[candidate]`, leaving other keys, the connection protocol and the single-value root address untouched.
    /// The model with the same id is written in both the enabled list and the catalog to keep both sides consistent.
    static func apply(_ outcome: Outcome, modelID: String, to provider: inout Provider) {
        func pin(_ models: inout [AIModel]) {
            for index in models.indices where models[index].id == modelID {
                models[index].relayTransport = outcome.transport
                models[index].relayTransportSource = .reachable
            }
        }
        pin(&provider.models)
        pin(&provider.catalogModels)
        guard var config = provider.relayRequested else { return }
        var roots = config.resolvedAPIBaseURLs ?? [:]
        roots[outcome.transport.rawValue] = outcome.apiRoot
        config.resolvedAPIBaseURLs = roots
        provider.relayRequested = config
    }
}

/// Verification orchestration for adding a relay; does not touch UI state.
enum RelayAddVerification {
    struct Result {
        let verified: Bool
        /// The protocol used by the request that passed (the connection protocol chosen by the user, or the candidate that passed the probe).
        let passedTransport: RelayTransport?
        /// Present only when the probe path passed: on save it is written onto the default model through `RelayModelProbe.apply`.
        let modelOutcome: RelayModelProbe.Outcome?
        let lastError: Error?
    }

    /// The connection config persisted by the add flow. The connection protocol takes only the user's intent: the protocol carried by the address if any, otherwise `auto`;
    /// the protocol obtained by probing is written only onto the model, not onto the connection.
    /// An `auto` connection: auth stores the form value (quick connect = auto, each protocol takes its default header per request),
    /// `disableResponseStorage = true`, and `codexCompatIdentity` is not written (taken per request protocol as default).
    /// The discovered root is recorded by `RelayEndpointResolver.recordDiscoveredRoot`: the old single-value field is written only when the protocol equals the connection's actual default.
    static func connectionRequested(
        detection: RelayDetectedConfiguration,
        explicitTransport: RelayTransport?,
        formAuthMode: RelayAuthMode,
        securityMode: RelayConnectionSecurityMode,
        modelID: String?
    ) -> RelayRequestedConfig {
        let connectionTransport = explicitTransport ?? .auto
        var config = RelayRequestedConfig(
            transport: connectionTransport,
            authMode: connectionTransport == .auto ? formAuthMode : detection.authMode,
            securityMode: securityMode,
            modelID: modelID,
            stream: true
        )
        RelayEndpointResolver.recordDiscoveredRoot(detection.apiBaseURL, discovered: detection.transport, into: &config)
        switch connectionTransport {
        case .openaiResponses:
            config.disableResponseStorage = true
            config.codexCompatIdentity = true
        case .auto:
            config.disableResponseStorage = true
        default:
            break
        }
        return config
    }

    /// When the catalog is unavailable and the request of the generation-route discovery used the default model and succeeded:
    /// count it as one pass of that model, with no extra ping. Models discovered through a sentinel (`generationVerified == false`) do not count.
    static func generationRoutePass(
        detection: RelayDetectedConfiguration,
        modelID: String
    ) -> RelayModelProbe.Outcome? {
        guard detection.detectionEvidence == .generationProbe,
              detection.generationVerified,
              detection.generationProbeModelID == modelID else { return nil }
        return RelayModelProbe.Outcome(transport: detection.transport, apiRoot: detection.apiBaseURL)
    }

    /// The draft connection before probing: carries only the address, connection config and default model, in the same shape as what `registerRelay` persists.
    static func draftProvider(endpoint: String, requested: RelayRequestedConfig, modelID: String) -> Provider {
        Provider(
            id: UUID(),
            kind: .relay,
            status: .connected,
            models: [
                AIModel(
                    id: modelID,
                    name: modelID,
                    capabilities: [.text],
                    reasoningModeAvailable: false,
                    isAvailable: true,
                    isDefault: true,
                    priceTier: ""
                )
            ],
            catalogModels: [],
            lastCheckedAt: nil,
            apiKey: "",
            apiKeyPreview: "",
            lastError: nil,
            baseURLText: endpoint,
            customName: nil,
            relayRequested: requested
        )
    }

    /// - Parameter userChosenTransport: passed when the connection protocol was chosen by the user (forced by the form or carried by the URL),
    ///   it is used only to verify once and writes nothing onto the model; when nil, the default model is probed.
    /// - Parameter generationRoute: the protocol found when discovery only found a generation route; it goes first among the candidates.
    static func run(
        endpoint: String,
        requested: RelayRequestedConfig,
        userChosenTransport: RelayTransport?,
        modelID: String,
        supportedEndpointTypes: [String]?,
        generationRoutePass: RelayModelProbe.Outcome? = nil,
        generationRoute: RelayTransport? = nil,
        family: () async -> String?,
        ping: RelayModelProbe.Ping
    ) async throws -> Result {
        let draft = draftProvider(endpoint: endpoint, requested: requested, modelID: modelID)
        if let userChosenTransport {
            do {
                try await ping(requested, modelID)
                return Result(verified: true, passedTransport: userChosenTransport, modelOutcome: nil, lastError: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return Result(verified: false, passedTransport: nil, modelOutcome: nil, lastError: error)
            }
        }

        if let generationRoutePass {
            return Result(verified: true, passedTransport: generationRoutePass.transport,
                          modelOutcome: generationRoutePass, lastError: nil)
        }

        // When only a generation route was found, the protocol found goes first (generationRouteCases); otherwise follow the full candidate rules.
        let candidates = if let generationRoute {
            await RelayProbeCandidates.generationRouteCandidates(
                route: generationRoute,
                supportedEndpointTypes: supportedEndpointTypes,
                family: family
            )
        } else {
            await RelayProbeCandidates.candidates(supportedEndpointTypes: supportedEndpointTypes, family: family)
        }
        var lastError: Error?
        let outcome = try await RelayModelProbe.probe(
            provider: draft,
            model: draft.models[0],
            candidates: candidates,
            onFailure: { error, _ in lastError = error },
            ping: ping
        )
        return Result(
            verified: outcome != nil,
            passedTransport: outcome?.transport,
            modelOutcome: outcome,
            lastError: outcome == nil ? lastError : nil
        )
    }
}
