import Foundation

/// Judging "this key" for a non-2xx before output on a relay.
///
/// The source of truth for the rules is the fixture `shared/test-fixtures/relay/key-access.v1.json` (signals / classifyCases).
/// It runs before the capability rejection loop: `modelAccessDenied` writes no capability negative cache, does no protocol-level fallback and does not resend with another key.
/// The criteria require explicit codes or phrases; a bare "model / group / not found" does not count; 5xx is never judged (done-hub folds them into 503 and they cannot be told apart).
nonisolated enum RelayKeyAccess {
    enum Outcome: String, CaseIterable, Sendable {
        case modelAccessDenied = "model_access_denied"
        case keyInvalid = "key_invalid"
        case keyLimited = "key_limited"
        case none
    }

    static let modelAccessDeniedStatuses: Set<Int> = [400, 403, 404]
    static let modelAccessDeniedCodes = [
        "model_not_found", "key_model_access_denied", "team_model_access_denied",
        "user_model_access_denied", "token_model_forbidden",
    ]
    static let modelAccessDeniedPhrases = [
        "无权访问模型", "无权使用模型", "无权使用分组", "is not available for this group",
        "is not supported for current token", "unknown provider for model", "do not have access to the model",
        "does not have access to model", "not allowed to access model", "not allowed to use model",
    ]
    static let keyInvalidStatuses: Set<Int> = [401]
    static let keyInvalidCodes403 = ["api_key_expired", "expired_key", "token_expired"]
    static let keyLimitedStatuses: Set<Int> = [402, 429]
    static let keyLimitedCodes403 = [
        "insufficient_user_quota", "insufficient_balance", "insufficient_quota",
        "budget_exceeded", "api_key_quota_exhausted", "usage_limit_exceeded",
    ]

    /// The raw response body is matched as a case-insensitive substring.
    static func classify(status: Int, body: String) -> Outcome {
        if keyInvalidStatuses.contains(status) { return .keyInvalid }
        if keyLimitedStatuses.contains(status) { return .keyLimited }
        let lower = body.lowercased()
        func containsAny(_ needles: [String]) -> Bool {
            needles.contains { lower.contains($0.lowercased()) }
        }
        if status == 403 {
            if containsAny(keyInvalidCodes403) { return .keyInvalid }
            if containsAny(keyLimitedCodes403) { return .keyLimited }
        }
        if modelAccessDeniedStatuses.contains(status),
           containsAny(modelAccessDeniedCodes) || containsAny(modelAccessDeniedPhrases) {
            return .modelAccessDenied
        }
        return .none
    }

    static func classify(status: Int, body: Data) -> Outcome {
        classify(status: status, body: String(decoding: body, as: UTF8.self))
    }

    /// The pre-output rejection recorded by a send attempt; no record = not an HTTP rejection (network error etc.).
    static func classify(_ rejection: RelayPreOutputRejection?) -> Outcome {
        guard let rejection else { return .none }
        return classify(status: rejection.status, body: rejection.body)
    }

    /// Key status when the catalog fetch fails (catalogCases): an invalid / restricted key is judged as such; any other 403 = denied; any other failure = failed.
    static func catalogFailureState(status: Int?, body: String) -> RelayKey.Status.State {
        guard let status else { return .failed }
        switch classify(status: status, body: body) {
        case .keyInvalid: return .invalid
        case .keyLimited: return .limited
        case .modelAccessDenied, .none: return status == 403 ? .denied : .failed
        }
    }

    /// Key status for generation requests (send / 1-token verification / lazy verification / test capabilities) (generationCases):
    /// 2xx -> ok; an invalid / restricted key is judged as such; everything else (no access, route rejection, gate, capability rejection, 5xx, network = nil status code) says nothing about this key, so nil is returned and the status is not touched.
    static func generationStatus(status: Int?, body: String) -> RelayKey.Status.State? {
        guard let status else { return nil }
        if (200..<300).contains(status) { return .ok }
        switch classify(status: status, body: body) {
        case .keyInvalid: return .invalid
        case .keyLimited: return .limited
        case .modelAccessDenied, .none: return nil
        }
    }

    /// A failed generation request is judged by the upstream response recorded for that attempt: a 2xx that is treated as failed (web page / content cannot be parsed) is not a success, and nil is returned.
    static func generationFailureStatus(_ rejection: RelayPreOutputRejection?) -> RelayKey.Status.State? {
        guard let rejection, !(200..<300).contains(rejection.status) else { return nil }
        return generationStatus(status: rejection.status, body: String(decoding: rejection.body, as: UTF8.self))
    }

    /// Writes one key's status; a new Provider is returned only if the request carried a key, that key is in the list, and the status (state / httpStatus) changed.
    /// The first time the primary key's status is written on a single-key connection (no list), it is materialized as a `[{id: initial, apiKey: "", status}]` entry.
    static func settingStatus(
        _ provider: Provider,
        keyID: String,
        state: RelayKey.Status.State,
        httpStatus: Int?,
        at date: Date
    ) -> Provider? {
        // If the request carried no key (auth mode is none / key is empty), there is no status to talk about for this key: nothing is written or materialized.
        guard RelayCredentialPolicy.requiresCredential(provider.relayRequested),
              !ProviderCredentialResolver.secret(provider: provider, keyID: keyID)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let existing = provider.relayKeys.flatMap { $0.isEmpty ? nil : $0 }
        let stored = existing ?? (keyID == RelayKeyBinding.implicitKeyID ? [RelayKey(id: keyID)] : nil)
        guard var list = stored,
              let index = list.firstIndex(where: { $0.id == keyID }) else { return nil }
        if let current = list[index].status, current.state == state, current.httpStatus == httpStatus {
            return nil
        }
        list[index].status = RelayKey.Status(state: state, httpStatus: httpStatus, checkedAt: date)
        var out = provider
        out.relayKeys = list
        return out
    }
}

/// The conclusion of one generation request about the key actually sent: `secret` stays in memory only, and before write-back we check that key's value has not changed.
nonisolated struct RelayKeyStatusObservation: Equatable, Sendable {
    let keyID: String
    let secret: String
    /// nil = this request says nothing about this key.
    let state: RelayKey.Status.State?
    let httpStatus: Int?
}
