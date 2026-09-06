import Foundation
import Observation

/// The one lifecycle owner for both ways of adding a custom LLM.
/// A connection attempt is deliberately represented by an opaque generation token.  An
/// adapter may finish after the user switches methods, changes a credential, or leaves the
/// screen; only this object is allowed to decide whether that result may update UI, persist a
enum CustomLLMConnectionMethod: String, CaseIterable, Equatable, Sendable {
    case relay
    case local
}

enum CustomLLMSetupPhase: Equatable {
    case ready
    case detecting
    case readyToCommit
    case failed
}

enum CustomLLMVerificationEvidence: Equatable {
    /// A 1-token request completed through the actual generation path.
    case generationVerified
    /// The relay protocol was identified but it did not publish a model ID, so a generation
    /// request cannot be formed yet. This may save only as an issue and must lead to manual model
    /// entry, never to an optimistic connected/onboarding completion state.
    case needsManualModel
}

enum CustomLLMCatalogEvidence: Equatable {
    case available
    case unavailable
}

/// The exact connection identity proved by a verification request.
/// Credentials are represented only by a one-way fingerprint. The raw secret must remain in the
/// adapter draft and must never enter evidence, logs, telemetry, or equality diagnostics.
struct CustomLLMVerificationIdentity: Equatable, Sendable {
    let method: CustomLLMConnectionMethod
    let engineProfile: String
    let normalizedEndpoint: String
    let securityMode: RelayConnectionSecurityMode
    let authFingerprint: String
    let selectedModel: String
    let networkRevision: UInt

    func replacingSelectedModel(_ modelID: String) -> Self {
        Self(
            method: method,
            engineProfile: engineProfile,
            normalizedEndpoint: normalizedEndpoint,
            securityMode: securityMode,
            authFingerprint: authFingerprint,
            selectedModel: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            networkRevision: networkRevision
        )
    }

    fileprivate func acceptsVerificationResult(_ result: Self) -> Bool {
        guard method == result.method,
              engineProfile == result.engineProfile,
              normalizedEndpoint == result.normalizedEndpoint,
              securityMode == result.securityMode,
              authFingerprint == result.authFingerprint,
              networkRevision == result.networkRevision else {
            return false
        }
        // An empty model means the connector was explicitly asked to resolve one from the real
        // catalog. A non-empty requested model may never be silently replaced by another model.
        return selectedModel.isEmpty || selectedModel == result.selectedModel
    }
}

struct CustomLLMSetupAttempt: Equatable {
    fileprivate let generation: UInt
    fileprivate let method: CustomLLMConnectionMethod
    fileprivate let identity: CustomLLMVerificationIdentity?
}

struct CustomLLMConnectionEvidence: Equatable {
    let attempt: CustomLLMSetupAttempt
    let identity: CustomLLMVerificationIdentity?
    let verification: CustomLLMVerificationEvidence
    let catalog: CustomLLMCatalogEvidence
    let canCommit: Bool

    /// A production-derived payload used by the setup screens before they register a provider.
    static func verified(
        _ attempt: CustomLLMSetupAttempt,
        identity: CustomLLMVerificationIdentity? = nil
    ) -> CustomLLMConnectionEvidence {
        CustomLLMConnectionEvidence(
            attempt: attempt,
            identity: identity,
            verification: .generationVerified,
            catalog: .available,
            canCommit: true
        )
    }

    static func needsManualModel(_ attempt: CustomLLMSetupAttempt) -> CustomLLMConnectionEvidence {
        CustomLLMConnectionEvidence(
            attempt: attempt,
            identity: nil,
            verification: .needsManualModel,
            catalog: .unavailable,
            canCommit: true
        )
    }
}

@MainActor
@Observable
final class CustomLLMSetupCoordinator {
    private(set) var method: CustomLLMConnectionMethod
    private(set) var phase: CustomLLMSetupPhase = .ready
    private(set) var evidence: CustomLLMConnectionEvidence?

    private var generation: UInt = 0
    private var cancelActiveWork: (() -> Void)?

    init(method: CustomLLMConnectionMethod = .relay) {
        self.method = method
    }

    /// Switching methods is an invalidation boundary, not a cosmetic UI change.
    func select(method next: CustomLLMConnectionMethod) {
        guard next != method else { return }
        invalidate()
        method = next
    }

    /// Starts the shared 1-token verification lifecycle and returns a token an adapter must
    /// present when it completes.  Starting a new attempt also cancels the prior adapter work.
    func beginVerification(
        for method: CustomLLMConnectionMethod,
        identity: CustomLLMVerificationIdentity? = nil
    ) -> CustomLLMSetupAttempt {
        precondition(identity == nil || identity?.method == method)
        if self.method != method {
            select(method: method)
        } else {
            invalidate()
        }
        phase = .detecting
        return CustomLLMSetupAttempt(generation: generation, method: method, identity: identity)
    }

    /// Keeps cancellation in the same owner as phase/generation.  The adapter still creates the
    /// Task because its inputs are view state, but it cannot outlive this coordinator's attempt.
    func registerCancellation(
        for attempt: CustomLLMSetupAttempt,
        _ cancellation: @escaping () -> Void
    ) {
        guard isCurrent(attempt) else {
            cancellation()
            return
        }
        cancelActiveWork = cancellation
    }

    @discardableResult
    func acceptVerified(_ evidence: CustomLLMConnectionEvidence) -> Bool {
        guard isCurrent(evidence.attempt),
              evidence.canCommit,
              verificationIdentityMatches(evidence) else {
            return false
        }
        self.evidence = evidence
        phase = .readyToCommit
        cancelActiveWork = nil
        return true
    }

    @discardableResult
    func acceptFailure(for attempt: CustomLLMSetupAttempt) -> Bool {
        guard isCurrent(attempt) else { return false }
        evidence = nil
        phase = .failed
        cancelActiveWork = nil
        return true
    }

    /// Discovery with no compatible configuration is a terminal result, not an indefinitely
    /// spinning attempt. Kept here so adapters cannot accidentally forget the phase transition.
    @discardableResult
    func acceptDiscoveryResult(
        for attempt: CustomLLMSetupAttempt,
        hasDetections: Bool
    ) -> Bool {
        guard hasDetections else { return acceptFailure(for: attempt) }
        return isCurrent(attempt)
    }

    /// The only permission check for writes and navigation after an asynchronous probe.
    func canCommit(_ evidence: CustomLLMConnectionEvidence) -> Bool {
        guard evidence.identity == nil else { return false }
        return canCommitCurrentEvidence(evidence)
    }

    /// Identity-bearing attempts must present the current form/network identity at the final
    /// write gate. This makes it impossible to accidentally weaken a Local adapter back to the
    /// method-generation-only check used by legacy Relay attempts.
    func canCommit(
        _ evidence: CustomLLMConnectionEvidence,
        matching identity: CustomLLMVerificationIdentity
    ) -> Bool {
        evidence.identity == identity && canCommitCurrentEvidence(evidence)
    }

    func invalidate() {
        generation &+= 1
        cancelActiveWork?()
        cancelActiveWork = nil
        evidence = nil
        phase = .ready
    }

    func isCurrent(_ attempt: CustomLLMSetupAttempt) -> Bool {
        attempt.generation == generation && attempt.method == method
    }

    private func verificationIdentityMatches(_ evidence: CustomLLMConnectionEvidence) -> Bool {
        switch (evidence.attempt.identity, evidence.identity) {
        case (nil, nil):
            return true
        case let (attemptIdentity?, verifiedIdentity?):
            return attemptIdentity.acceptsVerificationResult(verifiedIdentity)
        default:
            return false
        }
    }

    private func canCommitCurrentEvidence(_ evidence: CustomLLMConnectionEvidence) -> Bool {
        isCurrent(evidence.attempt)
            && phase == .readyToCommit
            && self.evidence == evidence
            && evidence.canCommit
    }
}

