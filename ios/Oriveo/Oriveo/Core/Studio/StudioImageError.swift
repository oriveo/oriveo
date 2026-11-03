import Foundation

/// Closed set of image generation failure kinds and their handling policy, plus the
/// classifier from an HTTP status and response body to a kind.
///
/// Truth table: `shared/model-contracts/image_error_samples.v1.json`, read by the
/// iOS / Android / Web contract tests alike. `timeout`, `network` and `storage_full`
/// are decided by the transport and storage layers and never come out of `classify`.
nonisolated enum StudioImageErrorKind: String, CaseIterable, Equatable, Sendable {
    case refused
    case auth
    case insufficientBalance = "insufficient_balance"
    case rateLimited = "rate_limited"
    case invalidParam = "invalid_param"
    case modelUnavailable = "model_unavailable"
    case upstreamError = "upstream_error"
    case timeout
    case network
    case partial
    case decodeFailed = "decode_failed"
    case storageFull = "storage_full"

    /// Whether a failed run uses up the free quota.
    enum FreeQuota: String, Equatable, Sendable {
        case none
        /// Only the images that were actually delivered count.
        case byDeliveredCount = "by_delivered_count"
        /// The quota was already settled when generation succeeded; saving failed afterwards.
        case alreadySettled = "already_settled"
    }

    enum AutoRetry: String, Equatable, Sendable {
        case none
        /// One silent retry, only when the request body never left the device.
        case onceBeforeBodySent = "once_before_body_sent"
    }

    struct Policy: Equatable, Sendable {
        var consumesFreeQuota: FreeQuota
        var autoRetry: AutoRetry
        /// UI action identifier, verbatim from the fixture.
        var ui: String
        /// Whether the failure is worth reporting (raw body kept for diagnosis).
        var report: Bool
    }

    static func policy(_ kind: StudioImageErrorKind) -> Policy {
        switch kind {
        case .refused: return Policy(consumesFreeQuota: .none, autoRetry: .none, ui: "rewrite_prompt_or_switch_model", report: false)
        case .auth: return Policy(consumesFreeQuota: .none, autoRetry: .none, ui: "check_key", report: false)
        case .insufficientBalance: return Policy(consumesFreeQuota: .none, autoRetry: .none, ui: "top_up_or_switch_model", report: false)
        case .rateLimited: return Policy(consumesFreeQuota: .none, autoRetry: .none, ui: "retry_later", report: false)
        case .invalidParam: return Policy(consumesFreeQuota: .none, autoRetry: .none, ui: "show_raw_and_switch_model", report: true)
        case .modelUnavailable: return Policy(consumesFreeQuota: .none, autoRetry: .none, ui: "switch_model", report: false)
        case .upstreamError: return Policy(consumesFreeQuota: .none, autoRetry: .none, ui: "retry", report: false)
        case .timeout: return Policy(consumesFreeQuota: .none, autoRetry: .none, ui: "retry", report: false)
        case .network: return Policy(consumesFreeQuota: .none, autoRetry: .onceBeforeBodySent, ui: "retry", report: false)
        case .partial: return Policy(consumesFreeQuota: .byDeliveredCount, autoRetry: .none, ui: "fill_missing", report: false)
        case .decodeFailed: return Policy(consumesFreeQuota: .none, autoRetry: .none, ui: "retry", report: true)
        case .storageFull: return Policy(consumesFreeQuota: .alreadySettled, autoRetry: .none, ui: "free_space_then_retry_save", report: false)
        }
    }

    // MARK: - classify

    /// Gemini finish reasons that mean the image was blocked.
    static let blockedFinishReasons: Set<String> = [
        "IMAGE_SAFETY", "PROHIBITED_CONTENT", "SAFETY", "IMAGE_PROHIBITED_CONTENT",
    ]

    /// Balance text ("insufficient quota/balance" and the two Chinese phrasings), matched
    /// case-insensitively against string values only.
    static let balancePattern =
        "insufficient[_ ](?:quota|balance)|\u{4F59}\u{989D}\u{4E0D}\u{8DB3}|\u{989D}\u{5EA6}\u{4E0D}\u{8DB3}"

    /// `body` is what `JSONSerialization` produced, the raw text when the reply was not
    /// JSON, or `nil` (or `NSNull`) when there was no body. Returns `nil` for ok.
    static func classify(http: Int, body: Any?, nRequested: Int) -> StudioImageErrorKind? {
        let body: Any? = body is NSNull ? nil : body
        switch http {
        case 401, 403: return .auth
        case 402: return .insufficientBalance
        case 404: return .modelUnavailable
        case 429: return hasBalanceText(body) ? .insufficientBalance : .rateLimited
        case 200...299: return classifySuccess(body, nRequested: nRequested)
        case 400...499: return classifyClientError(body)
        default: return .upstreamError
        }
    }

    private static func classifyClientError(_ body: Any?) -> StudioImageErrorKind {
        let object = body as? [String: Any]
        switch (object?["error"] as? [String: Any])?["code"] as? String {
        case "moderation_blocked", "content_policy_violation": return .refused
        case "model_not_found", "model_not_available": return .modelUnavailable
        default: return hasBalanceText(body) ? .insufficientBalance : .invalidParam
        }
    }

    private static func classifySuccess(_ body: Any?, nRequested: Int) -> StudioImageErrorKind? {
        let object = body as? [String: Any]
        if let status = number((object?["base_resp"] as? [String: Any])?["status_code"]),
           status.doubleValue != 0 {
            switch status.doubleValue {
            case 1002: return .rateLimited
            case 1004: return .auth
            case 1008: return .insufficientBalance
            case 1026, 1027: return .refused
            default: return .invalidParam
            }
        }
        if let reason = (object?["promptFeedback"] as? [String: Any])?["blockReason"] as? String,
           !reason.isEmpty {
            return .refused
        }
        let delivered = StudioImageResponse.parse(body).images.count
        if delivered == 0 {
            let first = (object?["candidates"] as? [Any])?.first as? [String: Any]
            if let reason = first?["finishReason"] as? String, blockedFinishReasons.contains(reason) {
                return .refused
            }
            if failedCount((object?["metadata"] as? [String: Any])?["failed_count"]) {
                return .refused
            }
            return .decodeFailed
        }
        return delivered < nRequested ? .partial : nil
    }

    /// A JSON number; booleans are excluded even though they bridge to `NSNumber`.
    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number
    }

    /// `failed_count > 0`, counted only as a JSON number or an all-digit string.
    private static func failedCount(_ value: Any?) -> Bool {
        if let number = number(value) { return number.doubleValue > 0 }
        guard let text = value as? String, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else {
            return false
        }
        return text.unicodeScalars.contains { $0 != "0" }
    }

    /// Balance text in any string value, recursing into object values and array
    /// elements; keys are not inspected.
    private static func hasBalanceText(_ value: Any?) -> Bool {
        switch value {
        case let text as String:
            // ASCII-only case folding: ICU .caseInsensitive also folds U+017F / U+0131 onto s / i.
            let folded = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
                ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
            }))
            return folded.range(of: balancePattern, options: .regularExpression) != nil
        case let object as [String: Any]:
            return object.values.contains { hasBalanceText($0) }
        case let array as [Any]:
            return array.contains { hasBalanceText($0) }
        default:
            return false
        }
    }
}

extension StudioImageResponse.Failure {
    /// Transport / decode failures map to the kind with the same wire name.
    nonisolated var errorKind: StudioImageErrorKind {
        switch self {
        case .network: return .network
        case .timeout: return .timeout
        case .decodeFailed: return .decodeFailed
        }
    }
}
