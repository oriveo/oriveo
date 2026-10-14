import Foundation

/// Local negative cache of upstream Relay rejections.
///
/// Relay form only. Entry key = connection (`provider.id.uuidString`) x model (`model.id`) x effective protocol
/// (`RelayTransport.rawValue`) x tier; hits within 7 days of recording. Stored in UserDefaults under
/// `relay_negative_cache.v1`, excluded from cloud sync and backups; the whole key can be deleted, and the old tool memory table is not touched.
nonisolated final class RelayNegativeCache: @unchecked Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case image, file, toolCall
        /// Thinking tier rejected: original value `reasoningTier:<tier>`, same name as stored on all three platforms.
        case reasoningTierFast = "reasoningTier:fast"
        case reasoningTierBalanced = "reasoningTier:balanced"
        case reasoningTierDeep = "reasoningTier:deep"
        case reasoningTierMax = "reasoningTier:max"
    }

    static let storageKey = "relay_negative_cache.v1"
    static let ttl: TimeInterval = 604_800
    static let shared = RelayNegativeCache()

    private struct Entry: Codable, Equatable {
        let connectionID: String
        let modelID: String
        let transport: String
        let kind: Kind
        let recordedAt: TimeInterval
    }

    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
    }

    func record(connectionID: String, modelID: String, transport: String, kind: Kind, at date: Date? = nil) {
        let recordedAt = (date ?? clock()).timeIntervalSince1970
        mutate { entries in
            // Keep only the latest entry per key: a fresh rejection restarts the 7 days from now.
            entries.removeAll {
                $0.connectionID == connectionID && $0.modelID == modelID
                    && $0.transport == transport && $0.kind == kind
            }
            entries.append(Entry(
                connectionID: connectionID, modelID: modelID, transport: transport,
                kind: kind, recordedAt: recordedAt
            ))
            // Also drop the expired ones along the way, so storage does not grow forever.
            entries.removeAll { recordedAt - $0.recordedAt >= Self.ttl }
        }
    }

    func isRejected(connectionID: String, modelID: String, transport: String, kind: Kind, now: Date? = nil) -> Bool {
        let current = (now ?? clock()).timeIntervalSince1970
        return load().contains {
            $0.connectionID == connectionID && $0.modelID == modelID
                && $0.transport == transport && $0.kind == kind
                && current - $0.recordedAt < Self.ttl
        }
    }

    /// Test-capabilities write-back (clears image + toolCall), and the user manually setting an override for a tier (clears that tier).
    func clear(connectionID: String, modelID: String, transport: String, kinds: Set<Kind>) {
        mutate { entries in
            entries.removeAll {
                $0.connectionID == connectionID && $0.modelID == modelID
                    && $0.transport == transport && kinds.contains($0.kind)
            }
        }
    }

    /// Re-detection, deleting the connection: clears the whole connection.
    func clearConnection(_ connectionID: String) {
        mutate { entries in entries.removeAll { $0.connectionID == connectionID } }
    }

    private func load() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return decode()
    }

    private func mutate(_ body: (inout [Entry]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var entries = decode()
        body(&entries)
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Corrupt data is treated as empty as a whole: the negative cache only speeds up judgment, and if lost the worst case is one more upstream rejection.
    private func decode() -> [Entry] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}

// MARK: - Write side

/// The one HTTP failure the upstream returned before any output (status code + body). Whether it counts as a rejection is decided only by `classify` of "Test capabilities".
nonisolated struct RelayPreOutputRejection: Sendable, Equatable {
    let status: Int
    let contentType: String
    let body: Data

    /// Recorder of one Relay send attempt: `BaseAPIService.mapHTTPError` records the upstream non-2xx before any event,
    /// and a 2xx whose content is a web page is recorded by `BaseAPIService.rejectRelayWebPageSuccess`; the sender reads it on the failure path. Only the first one is kept (when the inner native file fallback's resend fails, the first one is still what is reported).
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var first: RelayPreOutputRejection?

        func record(status: Int, contentType: String, body: Data) {
            lock.lock(); defer { lock.unlock() }
            if first == nil { first = RelayPreOutputRejection(status: status, contentType: contentType, body: body) }
        }

        var rejection: RelayPreOutputRejection? {
            lock.lock(); defer { lock.unlock() }
            return first
        }
    }

    @TaskLocal static var current: Recorder?
}

/// Protocol-level fallback (fixture protocolFallbackRules / protocolFallbackCases): only a route-level rejection before output counts,
/// the source is not `user` (a nil that follows the connection also counts), and this message has not switched yet; the next one = the first candidate not equal to the current protocol.
/// Candidates are supplied by the caller: when the user chose the connection protocol and the model follows it, there is no other candidate (`RelayProbeCandidates.followsUserChosenConnection`).
nonisolated enum RelayProtocolFallback {
    static let statuses: Set<Int> = [404, 405, 415]
    /// For these status codes the response body must carry one of `phrases` to count as a route-level rejection; those without are key / account problems.
    static let phraseStatuses: Set<Int> = [403]
    /// The verbatim text sub2api returns when rejecting `/v1/messages` on a group without messages dispatch enabled.
    static let phrases = ["does not allow /v1/messages dispatch"]

    /// A 2xx whose content is a web page (the gateway's SPA fallback page) also counts: this path is not an API route.
    static let htmlSuccessIsRouteRejection = true

    /// Route-level rejection = "this protocol path does not serve this request". The send-time protocol fallback and the per-model probe's move to the next candidate
    /// share this one criterion; nobody else may write another copy.
    static func isRouteRejection(_ rejection: RelayPreOutputRejection) -> Bool {
        let status = rejection.status, body = rejection.body
        if (200..<300).contains(status) {
            return htmlSuccessIsRouteRejection
                && RelaySuccessResponsePolicy.isWebPage(contentType: rejection.contentType, data: body)
        }
        if statuses.contains(status) { return true }
        guard phraseStatuses.contains(status) else { return false }
        // When the response body is raw JSON, slashes may be written as `\/` (a valid escape, which PHP's json_encode emits by default): restore them before comparing,
        // and the phrase itself is registered in only one spelling.
        let text = String(decoding: body, as: UTF8.self).lowercased().replacingOccurrences(of: "\\/", with: "/")
        return phrases.contains { text.contains($0.lowercased()) }
    }

    static func next(
        current: RelayTransport,
        source: RelayTransportSource?,
        candidates: [RelayTransport],
        rejection: RelayPreOutputRejection,
        outputStarted: Bool,
        alreadySwitched: Bool
    ) -> RelayTransport? {
        guard isEligible(
            source: source, rejection: rejection, outputStarted: outputStarted, alreadySwitched: alreadySwitched
        ) else { return nil }
        return candidates.first { $0 != current }
    }

    /// Preconditions independent of the candidates; callers use them to block early, without looking up candidates for every failure.
    static func isEligible(
        source: RelayTransportSource?,
        rejection: RelayPreOutputRejection,
        outputStarted: Bool,
        alreadySwitched: Bool
    ) -> Bool {
        isRouteRejection(rejection) && !outputStarted && !alreadySwitched && source != .user
    }
}

/// Official CLI gate (fixture clientGateRules / clientGateCases): a 403 before output whose body contains one of `phrases` =
/// the group of this key lets only the official CLI client through. It is neither a key problem (key-access records none) nor a route-level rejection (do not switch protocol);
/// it is used only to give the relay a hint to switch group / key. Oriveo neither sends nor impersonates any CLI identity.
nonisolated enum RelayClientGate {
    static let statuses: Set<Int> = [403]
    static let phrases = [
        "official claude cli",
        "restricted to claude code clients",
        "标准 claude code 客户端",
    ]

    static func isClientGated(status: Int, body: Data) -> Bool {
        guard statuses.contains(status) else { return false }
        // Same convention as RelayProtocolFallback: lowercase, restore `\/` to `/`, then substring match.
        let text = String(decoding: body, as: UTF8.self).lowercased().replacingOccurrences(of: "\\/", with: "/")
        return phrases.contains { text.contains($0.lowercased()) }
    }
}

/// Write point of the rejection loop. The signal counts only when `RelayCapabilityTest.classify` judges rejected.
nonisolated enum RelayRejectionRecording {
    /// Whether image recognition is unknown for the model at send time (fixture imageRecordCases): positive image evidence of any level -- override true,
    /// local engine declaration true, image in the model capabilities (inherited from official or declared) -- means it is not unknown.
    static func imageSupportUnknown(provider: Provider, model: AIModel) -> Bool {
        guard ProviderForm.of(provider) == .relay,
              model.relayCapabilityOverrides?.image != true,
              !model.capabilities.contains(.image) else { return false }
        // A local engine declaration takes effect only when the connection has an engineProfile (same convention as RelayTruthAdapter).
        if provider.relayRequested?.engineProfile != nil, model.engineDeclaration?.image == true { return false }
        return true
    }

    static func isRejected(_ rejection: RelayPreOutputRejection?) -> Bool {
        guard let rejection else { return false }
        return RelayCapabilityTest.classify(
            status: rejection.status, contentType: rejection.contentType, body: rejection.body
        ) == .rejected
    }

    @discardableResult
    static func recordImageRejection(
        provider: Provider,
        model: AIModel,
        transport: RelayTransport,
        rejection: RelayPreOutputRejection?,
        outputStarted: Bool = false,
        protocolSwitched: Bool = false,
        negativeCache: RelayNegativeCache = .shared
    ) -> Bool {
        // Neither "already output" nor "protocol already switched in this message" is recorded.
        guard ProviderForm.of(provider) == .relay, !outputStarted, !protocolSwitched,
              imageSupportUnknown(provider: provider, model: model),
              isRejected(rejection) else { return false }
        negativeCache.record(
            connectionID: provider.id.uuidString, modelID: model.id,
            transport: transport.rawValue, kind: .image
        )
        return true
    }

    static func rememberToolCall(
        provider: Provider,
        model: AIModel,
        toolCall: Bool,
        reason: ToolCallMemoryReason,
        statusCode: Int?,
        sentTransport: RelayTransport?,
        memory: ToolCallMemoryStore = .shared,
        negativeCache: RelayNegativeCache = .shared
    ) {
        guard ToolCallCapabilityPolicy.memoryEligible(provider: provider, model: model) else { return }
        // A Relay false is recorded as a toolCall negative cache instead of writing the old tool memory; true is as before. The key protocol = the protocol actually sent this time,
        // `sentTransport`: when the first send fell back to Chat because of attachments, or the tool leg was on Chat anyway, it was Chat that was rejected, and it must not be recorded under the first-send protocol.
        // The read side (entry point, ruling) still reads by the first-send protocol, representing the next ordinary send. If the caller cannot get the actual protocol, nothing is recorded.
        if provider.kind == .relay, !toolCall {
            guard let statusCode, let sentTransport,
                  isRejected(RelayPreOutputRejection(status: statusCode, contentType: "application/json", body: Data()))
            else { return }
            negativeCache.record(
                connectionID: provider.id.uuidString, modelID: model.id,
                transport: sentTransport.rawValue,
                kind: .toolCall
            )
            return
        }
        _ = memory.record(connectionID: provider.id, modelID: model.id, toolCall: toolCall, reason: reason)
    }
}

// MARK: - Thinking tiers (fixture reasoning-tier.v1.json)

/// Relay thinking tiers: the automatic set comes from model-facts, a rejected tier is recorded in the negative cache and the nearest tier is picked. Shared by the panel, outbound and in-send resend.
nonisolated enum RelayReasoningTier {
    /// Words of model-facts `reasoningEfforts` -> tiers; `none` / `minimal` and unrecognized words are ignored.
    static let effortMap: [String: ReasoningMode] = [
        "low": .fast, "medium": .balanced, "high": .deep, "xhigh": .max, "max": .max,
    ]
    /// Only an error body (lowercased) that names a thinking parameter counts as a tier rejection; the `param` field is also in the raw error body, so check it too.
    static let rejectionTokens = [
        "reasoning", "thinking", "effort", "budget_tokens", "thinkingconfig", "thinkingbudget",
        "thinkinglevel", "enable_thinking",
    ]
    static let order: [ReasoningMode] = [.fast, .balanced, .deep, .max]

    static func tiers(efforts: [String]) -> [ReasoningMode] {
        let present = Set(efforts.compactMap { effortMap[$0.lowercased()] })
        return order.filter(present.contains)
    }

    /// The rejected tier; nil = not a tier rejection (no tier sent, already output, not 400 / 422, or the error body does not name a thinking parameter).
    static func classify(status: Int, body: String, sentTier: ReasoningMode?, outputStarted: Bool) -> ReasoningMode? {
        guard let sentTier, sentTier != .automatic, !outputStarted, status == 400 || status == 422 else { return nil }
        let lowered = body.lowercased()
        return rejectionTokens.contains(where: lowered.contains) ? sentTier : nil
    }

    /// If the selected tier was not rejected, return it as is; otherwise look downward first, then upward, for a tier that is available and not rejected; if there is none, return nil (no thinking field).
    static func fallback(available: [ReasoningMode], rejected: Set<ReasoningMode>, selected: ReasoningMode) -> ReasoningMode? {
        guard selected != .automatic, rejected.contains(selected),
              let index = order.firstIndex(of: selected) else { return selected }
        let usable = Set(available).subtracting(rejected)
        if let lower = order[..<index].reversed().first(where: usable.contains) { return lower }
        return order[(index + 1)...].first(where: usable.contains)
    }

    static func kind(for tier: ReasoningMode) -> RelayNegativeCache.Kind? {
        switch tier {
        case .automatic: nil
        case .fast: .reasoningTierFast
        case .balanced: .reasoningTierBalanced
        case .deep: .reasoningTierDeep
        case .max: .reasoningTierMax
        }
    }

    static let kinds: Set<RelayNegativeCache.Kind> = Set(order.compactMap(kind(for:)))

    static func rejectedTiers(
        provider: Provider, model: AIModel, transport: RelayTransport, negativeCache: RelayNegativeCache = .shared
    ) -> Set<ReasoningMode> {
        guard ProviderForm.of(provider) == .relay else { return [] }
        return Set(order.filter { tier in
            kind(for: tier).map {
                negativeCache.isRejected(
                    connectionID: provider.id.uuidString, modelID: model.id, transport: transport.rawValue, kind: $0
                )
            } ?? false
        })
    }

    /// Pick the tier before outbound: the available set = the tiers given by the same resolver as the panel (including override narrowing).
    @MainActor
    static func outboundMode(
        provider: Provider, model: AIModel, transport: RelayTransport, selected: ReasoningMode,
        negativeCache: RelayNegativeCache = .shared
    ) -> ReasoningMode {
        guard selected != .automatic else { return selected }
        let rejected = rejectedTiers(provider: provider, model: model, transport: transport, negativeCache: negativeCache)
        guard rejected.contains(selected) else { return selected }
        let available = CapabilityControlResolution.resolve(provider: provider, model: model, capability: "reasoning")
            .intents.compactMap(RelayReasoningLevelOverride.mode(ofIntent:))
        return fallback(available: available, rejected: rejected, selected: selected) ?? .automatic
    }

    /// In-send tier rejection: if judged rejected, record the negative cache and return the tier to use for this resend (nil = no thinking field); if it is not a tier rejection, return `.none`.
    @MainActor
    static func recordRejection(
        provider: Provider, model: AIModel, transport: RelayTransport, sent: ReasoningMode,
        rejection: RelayPreOutputRejection?, outputStarted: Bool, negativeCache: RelayNegativeCache = .shared
    ) -> ReasoningMode?? {
        guard ProviderForm.of(provider) == .relay, let rejection,
              let tier = classify(
                  status: rejection.status, body: String(decoding: rejection.body, as: UTF8.self),
                  sentTier: sent, outputStarted: outputStarted
              ),
              let kind = kind(for: tier) else { return .none }
        negativeCache.record(
            connectionID: provider.id.uuidString, modelID: model.id, transport: transport.rawValue, kind: kind
        )
        let rejected = rejectedTiers(provider: provider, model: model, transport: transport, negativeCache: negativeCache)
        let available = CapabilityControlResolution.resolve(provider: provider, model: model, capability: "reasoning")
            .intents.compactMap(RelayReasoningLevelOverride.mode(ofIntent:))
        return .some(fallback(available: available, rejected: rejected, selected: tier))
    }
}
