import Foundation

/// Two decisions about a failed chat message: what is stored as its technical detail, and whether the failure
/// card offers "Switch model".
///
/// Both used to be answered by probing strings at the call sites:
/// - The technical detail was always `technicalDetail`, so a subscription request rejected with HTTP 426 put the
///   upstream text into the card's collapsed section — "Your Grok CLI version (1.0.4) is outdated. Please update
///   … via `grok update`" — although an app user has no CLI to update.
/// - "Switch model" was found by looking for the English words "switch models" in the **already translated**
///   body, so only users of the English interface got that way out when a model was unavailable.
enum ChatFailurePresentation {
    /// The `errorDetail` persisted with a failed message (what the card's "Technical details" section shows).
    ///
    /// - Subscription lanes: the sentence written for the user, the same one the pre-send preparation failure
    ///   stores. The upstream text addresses the provider's own CLI and is not shown.
    /// - Everything else: `technicalDetail`, as before (people using their own key or relay need it to debug).
    static func persistedDetail(for error: ProviderServiceError) -> String {
        switch error {
        case .subscriptionFailure:
            return error.message
        default:
            return error.technicalDetail
        }
    }

    /// Title keys of failures where another model lets the user carry on: an unavailable model, and the four
    /// kinds of failure on either subscription lane (a subscriber has no key to replace and no bill to check,
    /// so another connection is the only way out that works right away).
    static let modelSwitchTitleKeys: Set<String> = [
        "Model Unavailable",
        ProviderServiceError.SubscriptionLane.grok.titleKey,
        ProviderServiceError.SubscriptionLane.openAI.titleKey,
    ]

    /// Whether the failure card offers "Switch model".
    ///
    /// The persisted **title key** is checked first (keys are the English source strings and do not change with
    /// the interface language). The remaining checks are the earlier criteria, kept for rate-limit and quota
    /// failures and for messages persisted by older versions.
    static func offersModelSwitch(errorTitle: String?, errorDetail: String?, bodyText: String) -> Bool {
        if let errorTitle, modelSwitchTitleKeys.contains(errorTitle) { return true }
        let title = errorTitle?.lowercased() ?? ""
        let detail = errorDetail?.lowercased() ?? ""
        return title.contains("rate") || title.contains("quota")
            || detail.contains("429") || detail.contains("insufficient")
            || bodyText.lowercased().contains("switch models")
    }
}

extension ProviderServiceError {
    /// The lane whose request the provider rejected as "client version too old" (HTTP 426); nil otherwise.
    var subscriptionClientVersionRejectionLane: SubscriptionLane? {
        if case let .subscriptionFailure(lane, .unavailable, _, _) = self { return lane }
        return nil
    }
}
