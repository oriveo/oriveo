import Foundation

/// execution truth is intentionally separate from the request compiler. The compiler tells us
/// a reviewed delta entered the final body; only the selected production parser can add an observed
/// fact.  HTTP success, text output and a tool declaration are deliberately not facts here.
nonisolated enum CapabilityExecutionProducerEvent: String, Sendable {
    case citations
    case reasoning
    case toolResult = "tool_result"
    case reasoningUsage = "reasoning_usage"
}

nonisolated struct CapabilityExecutionResult: Codable, Hashable, Sendable {
    /// Owner -> terminal fact. This contains no provider/model/error body/custom JSON.
    let states: [String: RequestResultState]
    /// Device-local, redacted recovery identity persisted beside a failed message.
    let recoveryDescriptors: [CapabilityRecoveryDescriptor]?

    init(
        states: [String: RequestResultState],
        recoveryDescriptors: [CapabilityRecoveryDescriptor]? = nil
    ) {
        self.states = states
        self.recoveryDescriptors = recoveryDescriptors
    }

    static let empty = CapabilityExecutionResult(states: [:])
}

nonisolated enum CapabilityRejectionSource: String, Sendable, Codable {
    case providerRecipe = "recipe"
    case custom
}

nonisolated struct CapabilityRecoveryDescriptor: Codable, Hashable, Sendable {
    let source: CapabilityRejectionSource
    let owner: String
    let recipeRef: String?
    let locatedPointers: Set<String>
    let runtimeRevision: String
}

/// Failed-message recovery is only a proposal. The current production identity and the durable
/// negative cache must still prove the exact same rejection before ChatManager may preserve/append
/// failed content or install the one-request resend latch.
nonisolated enum CapabilityRecoveryDescriptorValidation {
    @MainActor
    static func validated(
        _ descriptor: CapabilityRecoveryDescriptor?,
        providerKind: ProviderKind,
        identity: CapabilityEvidenceRequestIdentity?,
        cache: UnsupportedParamCache
    ) -> CapabilityRecoveryDescriptor? {
        guard let descriptor, let identity,
              identity.runtimeRevision == descriptor.runtimeRevision,
              !descriptor.owner.isEmpty,
              !descriptor.locatedPointers.isEmpty else { return nil }
        let modelID = identity.query.effectiveModelID
        switch descriptor.source {
        case .providerRecipe:
            guard let recipeRef = descriptor.recipeRef, !recipeRef.isEmpty,
                  cache.recipeRejectedPointers(
                    providerKind: providerKind, modelID: modelID, owner: descriptor.owner,
                    recipeRef: recipeRef, identity: identity
                  ) == descriptor.locatedPointers else { return nil }
        case .custom:
            guard descriptor.recipeRef == nil,
                  cache.customRejectedPointers(
                    providerKind: providerKind, modelID: modelID, owner: descriptor.owner,
                    identity: identity
                  ) == ["owner:\(descriptor.owner)"] else { return nil }
        }
        return descriptor
    }
}

nonisolated struct CapabilityRuntimeRejection: Sendable, Equatable {
    let source: CapabilityRejectionSource
    let owner: String
    let recipeRef: String?
    let capabilityKeys: Set<String>
    let locatedPointers: Set<String>
    let runtimeRevision: String
}

/// Mutable only for the lifetime of one normal chat request.  It is carried with TaskLocal, never
/// serialized, synced, logged or reused by a later retry.
final class CapabilityExecutionTracker: @unchecked Sendable {
    private struct RequestedPlan: Sendable {
        let source: CapabilityRejectionSource
        let owner: String
        let recipeRef: String?
        let definition: MetadataClient.CapabilityResponseEvidenceDefinition
        let recoveryDefinition: MetadataClient.CapabilityErrorRecoveryDefinition?
        let runtimeRevision: String
        let allowsObservation: Bool
        let includeExecutionFact: Bool
        let deltaRootKeys: Set<String>
        let ownedPointers: Set<String>
        let capabilityKeys: Set<String>
    }

    private let lock = NSLock()
    private let onRequested: @Sendable (CapabilityExecutionResult) -> Void
    private var frozenRuntime: (runtime: MetadataClient.CapabilityRuntimeEnvelope, controls: [String: MetadataClient.CapabilityControl]?)?
    private var compiled: [String: RequestedPlan] = [:]
    private var finalWireEncoded = false
    private var requested: [String: RequestedPlan] = [:]
    private var observedOwners = Set<String>()
    private var toolsRecoveredOwners = Set<String>()
    private var rejectedPlanIDs = Set<String>()
    private var recoveryDescriptors: [CapabilityRecoveryDescriptor] = []
    // These latches describe transport progress only. They are used solely by the explicit
    // custom-field retry safety gate; they are never execution-result evidence.
    private var receivedUpstreamResponse = false
    private var performedSideEffect = false

    init(onRequested: @escaping @Sendable (CapabilityExecutionResult) -> Void = { _ in }) {
        self.onRequested = onRequested
    }

    func freezeRuntimeEnvelope(
        _ runtime: MetadataClient.CapabilityRuntimeEnvelope,
        controls: [String: MetadataClient.CapabilityControl]?
    ) {
        lock.lock()
        // The first envelope used by the production compiler owns this request. A metadata refresh
        // while the body is being built must not swap custom evidence/recovery definitions.
        if frozenRuntime == nil { frozenRuntime = (runtime, controls) }
        lock.unlock()
    }

    /// Compiler output is not yet a request fact: later profile/custom validation can still stop
    /// encoding.  Keep it pending until the one final JSON encoder has succeeded.
    func recordCompiledDelta(
        recipe: MetadataClient.CapabilityRecipe,
        runtime: MetadataClient.CapabilityRuntimeEnvelope,
        finalTransport: String,
        source: CapabilityRejectionSource = .providerRecipe,
        allowsObservation: Bool = true,
        includeExecutionFact: Bool = true,
        deltaRootKeys: Set<String> = [],
        ownedPointers: Set<String>? = nil,
        capabilityKeys: Set<String> = []
    ) {
        guard let owner = RequestPreferenceOwner(rawValue: recipe.capability)?.rawValue,
              let evidenceRef = recipe.responseEvidenceRef,
              let definition = runtime.responseEvidenceDefinitions?[evidenceRef],
              definition.capability == owner,
              CapabilityRecipeRequestCompiler.canonicalTransport(definition.protocolName)
                == CapabilityRecipeRequestCompiler.canonicalTransport(finalTransport),
              definition.responseParserKind == recipe.responseParserKind,
              !runtime.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !definition.signals.contains(where: { !$0.nonEmpty || $0.producerEvent.isEmpty || $0.pointer.isEmpty })
        else { return }

        lock.lock()
        let recoveryDefinition: MetadataClient.CapabilityErrorRecoveryDefinition?
        if let recoveryRef = recipe.errorRecoveryRef,
           let candidate = runtime.errorRecoveryDefinitions?[recoveryRef],
           candidate.capability == owner,
           CapabilityRecipeRequestCompiler.canonicalTransport(candidate.protocolName)
            == CapabilityRecipeRequestCompiler.canonicalTransport(finalTransport),
           candidate.responseParserKind == recipe.responseParserKind {
            recoveryDefinition = candidate
        } else {
            recoveryDefinition = nil
        }
        let actualPointers = ownedPointers ?? Set(recipe.requestOps.compactMap(\.pointer))
        let planID = [source.rawValue, owner, actualPointers.sorted().joined(separator: "\u{1f}")]
            .joined(separator: "\u{1e}")
        compiled[planID] = RequestedPlan(
            source: source, owner: owner,
            recipeRef: source == .providerRecipe ? recipe.id : nil,
            definition: definition, recoveryDefinition: recoveryDefinition,
            runtimeRevision: runtime.revision, allowsObservation: allowsObservation,
            includeExecutionFact: includeExecutionFact,
            deltaRootKeys: deltaRootKeys,
            ownedPointers: actualPointers, capabilityKeys: capabilityKeys
        )
        lock.unlock()
    }

    /// custom fragments are local user intent, not automatic configuration. They can earn
    /// only requested → unconfirmed, and only when the same runtime revision has an exact owner
    /// recipe/evidence definition for the final transport.  No raw JSON/path/value is retained.
    func recordCustomDelta(owner: String, pointers: Set<String>, finalTransport: String) {
        lock.lock()
        let envelope = frozenRuntime
        lock.unlock()
        guard let envelope else { return }
        let runtime = envelope.runtime
        let controls = envelope.controls
        guard !runtime.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !pointers.isEmpty,
              let control = controls?[owner],
              let recipeRef = control.recipeRef,
              let recipe = runtime.recipes[recipeRef],
              recipe.capability == owner else { return }
        let roots = Set(pointers.compactMap { Self.pointerSegments($0).first })
        recordCompiledDelta(
            recipe: recipe, runtime: runtime, finalTransport: finalTransport,
            source: .custom, allowsObservation: false,
            deltaRootKeys: roots, ownedPointers: pointers
        )
    }

    func confirmFinalWireEncoded() {
        lock.lock()
        finalWireEncoded = true
        lock.unlock()
    }

    /// Encoding proves the body is complete, but it still is not a request fact: a cancellation or
    /// local failure can occur before URLSession starts.  This is called immediately before the
    /// actual URLSession data/bytes operation.
    func confirmRequestDispatched() {
        lock.lock()
        guard finalWireEncoded else {
            lock.unlock()
            return
        }
        requested = compiled
        let result = CapabilityExecutionResult(states: requested.values.reduce(into: [:]) {
            guard $1.includeExecutionFact else { return }
            $0[$1.owner] = .requested
        })
        lock.unlock()
        guard !result.states.isEmpty else { return }
        onRequested(result)
    }

    func recordToolsRecovered(owner: String) {
        lock.lock()
        toolsRecoveredOwners.insert(owner)
        lock.unlock()
    }

    func recordParserEvent(_ event: CapabilityExecutionProducerEvent, nonEmpty: Bool) {
        recordUpstreamResponse()
        guard nonEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for plan in requested.values where plan.allowsObservation && plan.definition.signals.contains(where: {
            $0.producerEvent == event.rawValue && $0.nonEmpty
        }) {
            observedOwners.insert(plan.owner)
        }
    }

    @discardableResult
    func recordUpstreamRejection(statusCode: Int, errorData: Data) -> [CapabilityRuntimeRejection] {
        guard let root = try? JSONSerialization.jsonObject(with: errorData) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard !receivedUpstreamResponse, !performedSideEffect else { return [] }
        var candidates: [(planID: String, rejection: CapabilityRuntimeRejection)] = []
        // Custom uses the structured upstream parameter field plus the pointers actually emitted
        // by the production custom compiler. Exactly one owner must own that final pointer;
        // mismatch or cross-owner ambiguity fails closed.
        if statusCode == 400,
           let rawParam = Self.stringValue(at: "/error/param", in: root),
           let pointer = Self.pointerFromStructuredParam(rawParam) {
            let matches = requested.filter { _, plan in
                plan.source == .custom && plan.ownedPointers.contains(pointer)
            }
            if matches.count == 1, let (planID, plan) = matches.first {
                candidates.append((planID, .init(
                    source: .custom, owner: plan.owner, recipeRef: nil,
                    capabilityKeys: [], locatedPointers: [pointer],
                    runtimeRevision: plan.runtimeRevision
                )))
            }
        }
        for (planID, plan) in requested where plan.source == .providerRecipe {
            guard let recoveryDefinition = plan.recoveryDefinition,
                  let rule = recoveryDefinition.locatorRules.first(where: { rule in
                guard rule.status == statusCode,
                      rule.status == 400,
                      rule.owner == plan.owner,
                      !rule.pointers.isEmpty,
                      !rule.errorFields.isEmpty,
                      Set(rule.pointers).isSubset(of: plan.ownedPointers),
                      rule.pointers.allSatisfy({ pointer in
                          guard let first = Self.pointerSegments(pointer).first else { return false }
                          return plan.deltaRootKeys.contains(first)
                      }) else { return false }
                return rule.errorFields.allSatisfy { pointer, expected in
                    Self.stringValue(at: pointer, in: root) == expected
                }
            }) else { continue }
            // Custom fragments are applied after official recipe ops. For an overlapping pointer
            // the final wire owner is custom, so the same structured locator must not poison the
            // recipe cache. Different pointers of the same owner remain independently attributable.
            if plan.source == .providerRecipe {
                let customOwnedPointers = requested.values.reduce(into: Set<String>()) { result, candidate in
                    guard candidate.source == .custom, candidate.owner == plan.owner else { return }
                    result.formUnion(candidate.ownedPointers)
                }
                if !Set(rule.pointers).isDisjoint(with: customOwnedPointers) { continue }
            }
            candidates.append((planID, .init(
                source: plan.source,
                owner: plan.owner,
                recipeRef: plan.recipeRef,
                capabilityKeys: plan.capabilityKeys,
                locatedPointers: Set(rule.pointers),
                runtimeRevision: plan.runtimeRevision
            )))
        }
        guard candidates.count == 1, let candidate = candidates.first else { return [] }
        rejectedPlanIDs.insert(candidate.planID)
        recoveryDescriptors = [.init(
            source: candidate.rejection.source,
            owner: candidate.rejection.owner,
            recipeRef: candidate.rejection.recipeRef,
            locatedPointers: candidate.rejection.locatedPointers,
            runtimeRevision: candidate.rejection.runtimeRevision
        )]
        return [candidate.rejection]
    }

    private static func pointerSegments(_ pointer: String) -> [String] {
        guard pointer.first == "/" else { return [] }
        return pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
        }
    }

    private static func stringValue(at pointer: String, in root: Any) -> String? {
        var current: Any = root
        for segment in pointerSegments(pointer) {
            if let object = current as? [String: Any], let next = object[segment] {
                current = next
            } else if let array = current as? [Any], let index = Int(segment), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current as? String
    }

    private static func pointerFromStructuredParam(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.first == "/" {
            return pointerSegments(value).isEmpty ? nil : value
        }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, segments.allSatisfy({ segment in
            segment.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
        }) else { return nil }
        return "/" + segments.map {
            $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        }.joined(separator: "/")
    }

    func terminalResult() -> CapabilityExecutionResult {
        lock.lock()
        defer { lock.unlock() }
        let visible = requested.filter { planID, plan in
            plan.includeExecutionFact || rejectedPlanIDs.contains(planID)
        }
        let grouped = Dictionary(grouping: visible, by: { $0.value.owner })
        var states = grouped.reduce(into: [String: RequestResultState]()) { result, pair in
            // An empty catalog signal list intentionally remains unconfirmed, even after HTTP 200.
            let classification = RequestPreferenceResolver.classifyResult(.init(
                wireApplied: true,
                providerAccepted: !pair.value.contains(where: { rejectedPlanIDs.contains($0.key) }),
                evidenceKinds: observedOwners.contains(pair.key)
                    ? [RequestObservationEvidence.providerToolResult.rawValue] : [],
                recovered: toolsRecoveredOwners.contains(pair.key)
            ))
            result[pair.key] = classification.state
        }
        for owner in toolsRecoveredOwners where states[owner] == nil {
            states[owner] = .recovered
        }
        return .init(
            states: states,
            recoveryDescriptors: recoveryDescriptors.isEmpty ? nil : recoveryDescriptors
        )
    }

    var hasDispatchedFact: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !requested.isEmpty
    }

    /// Any event emitted by a real service/parser closes the pre-token custom retry window,
    /// including empty reasoning heartbeats and events which do not prove execution.
    func recordUpstreamResponse() {
        lock.lock()
        receivedUpstreamResponse = true
        lock.unlock()
    }

    /// A tool/fiber result has externally visible effects even when the next chat leg fails
    /// before producing text. It therefore also closes the custom retry window.
    func recordSideEffect() {
        lock.lock()
        performedSideEffect = true
        lock.unlock()
    }

    /// This never authorizes a retry itself. It only describes whether ChatManager may offer the
    /// user's explicit omit-custom action for an upstream 400.
    var canOfferExplicitCustomRetry: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !receivedUpstreamResponse && !performedSideEffect
    }

    func hasRejectedSource(_ source: CapabilityRejectionSource) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested.contains { planID, plan in
            plan.source == source && rejectedPlanIDs.contains(planID)
        }
    }

}

/// The only bridge between actual final-body compilation / protocol parsers and the chat task.
/// `nil` means a legacy or non-capability request; no global fallback is allowed.
enum CapabilityExecutionRuntime {
    @TaskLocal static var current: CapabilityExecutionTracker?

    static func recordCompiledDelta(
        recipe: MetadataClient.CapabilityRecipe,
        runtime: MetadataClient.CapabilityRuntimeEnvelope,
        finalTransport: String,
        deltaIsNonEmpty: Bool,
        deltaRootKeys: Set<String> = [],
        ownedPointers: Set<String>? = nil,
        capabilityKeys: Set<String> = [],
        includeExecutionFact: Bool = true
    ) {
        guard deltaIsNonEmpty else { return }
        current?.recordCompiledDelta(
            recipe: recipe, runtime: runtime, finalTransport: finalTransport,
            includeExecutionFact: includeExecutionFact,
            deltaRootKeys: deltaRootKeys, ownedPointers: ownedPointers,
            capabilityKeys: capabilityKeys
        )
    }

    @discardableResult
    static func recordUpstreamRejection(statusCode: Int, errorData: Data) -> [CapabilityRuntimeRejection] {
        current?.recordUpstreamRejection(statusCode: statusCode, errorData: errorData) ?? []
    }

    static func confirmFinalWireEncoded() {
        current?.confirmFinalWireEncoded()
    }

    static func freezeRuntimeEnvelope(
        _ runtime: MetadataClient.CapabilityRuntimeEnvelope,
        controls: [String: MetadataClient.CapabilityControl]?
    ) {
        current?.freezeRuntimeEnvelope(runtime, controls: controls)
    }

    static func recordCustomDelta(owner: String, pointers: Set<String>, finalTransport: String) {
        current?.recordCustomDelta(owner: owner, pointers: pointers, finalTransport: finalTransport)
    }

    static func confirmRequestDispatched() {
        current?.confirmRequestDispatched()
    }

    static func recordParserEvent(_ event: CapabilityExecutionProducerEvent, nonEmpty: Bool) {
        current?.recordParserEvent(event, nonEmpty: nonEmpty)
    }

    static func recordUpstreamResponse() {
        current?.recordUpstreamResponse()
    }

    static func recordSideEffect() {
        current?.recordSideEffect()
    }

    static func recordToolsRecovered(owner: String) {
        current?.recordToolsRecovered(owner: owner)
    }

    static func canOfferExplicitCustomRetry() -> Bool {
        current?.canOfferExplicitCustomRetry ?? false
    }


    static func hasRejectedSource(_ source: CapabilityRejectionSource) -> Bool {
        current?.hasRejectedSource(source) ?? false
    }

    static func hasDispatchedFact() -> Bool {
        current?.hasDispatchedFact ?? false
    }
}

/// One request only. Chat recovery sets this while the user-confirmed resend is executing; it is
/// never persisted or inherited by a later normal send.
nonisolated enum CapabilityRecipeResendContext {
    @TaskLocal static var recoveryDescriptor: CapabilityRecoveryDescriptor?
}
