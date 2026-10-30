import Foundation

// MARK: - Chat presentation for external search
//
// Each UI state reads from a single source: source card title = persisted sourcesLine; error card = persisted errorCard; rejection notice = persisted notice;
// the regenerate menu's "search again" item = the message has an external_search source. This file only maps; the cell just draws.

/// Actions on the error card / menu (button semantics, independent of whether the local service still exists).
nonisolated enum ExternalSearchCardAction: Equatable, Sendable {
    case updateKey(serviceID: String)
    case topUp(serviceID: String)
    /// retry / retry_later: regenerate and search again (regenerate.action = re_search).
    case retry
    case switchService
    case checkSettings(serviceID: String)
    case viewSetupGuide
    case reconfirm(serviceID: String)
    /// Secondary button: after pick_service for this conversation x current model, regenerate and search again.
    case answerWith(serviceID: String, name: String)
    /// Regenerate menu item "Regenerate and search again".
    case regenerateWithSearch

    /// Will regenerate (only offered on the last answer).
    var regenerates: Bool {
        switch self {
        case .retry, .answerWith, .regenerateWithSearch: return true
        default: return false
        }
    }
}

/// Where the action lands (resolved against the current local services at tap time).
nonisolated enum ExternalSearchChatRoute: Equatable, Sendable {
    case serviceDetail(serviceID: String)
    /// Service detail, opening the Key editor directly.
    case updateKey(serviceID: String)
    /// Jump straight to the custom service editing area.
    case editCustomService(serviceID: String)
    case webSearchSettings
    case openURL(URL)
    /// Push "Search method" in the model options panel.
    case searchSource
    case regenerateWithSearch
    case pickServiceAndRegenerate(serviceID: String, name: String)

    /// - Parameters:
    ///   - serviceExists: the service on the card still exists locally (when it does not, jump-type actions open the "Web search" settings page instead).
    ///   - pricingURL: the pricing page of the site the service belongs to (regionLinks.pricing).
    static func resolve(_ action: ExternalSearchCardAction, serviceExists: Bool, pricingURL: String?) -> ExternalSearchChatRoute {
        switch action {
        case .updateKey(let id):
            return serviceExists ? .updateKey(serviceID: id) : .webSearchSettings
        case .checkSettings(let id):
            return serviceExists ? .editCustomService(serviceID: id) : .webSearchSettings
        case .reconfirm(let id):
            return serviceExists ? .serviceDetail(serviceID: id) : .webSearchSettings
        case .topUp:
            guard serviceExists, let url = pricingURL.flatMap(ExternalURLPolicy.httpsURL(from:)) else { return .webSearchSettings }
            return .openURL(url)
        case .viewSetupGuide:
            guard let url = URL(string: SearchSettings.searxngSetupGuideUrl) else { return .webSearchSettings }
            return .openURL(url)
        case .switchService:
            return .searchSource
        case .retry, .regenerateWithSearch:
            return .regenerateWithSearch
        case let .answerWith(id, name):
            return serviceExists ? .pickServiceAndRegenerate(serviceID: id, name: name) : .webSearchSettings
        }
    }
}

/// Error card.
nonisolated struct SearchErrorCardPresentation: Equatable, Sendable {
    struct Button: Equatable, Sendable {
        /// Key after `webSearch.` in WebSearch.xcstrings.
        let titleKey: String
        /// {name} argument (action.answerWith).
        let titleArgument: String?
        let action: ExternalSearchCardAction
        /// External link (with the external-link icon).
        let external: Bool
    }

    let titleKey: String
    let serviceName: String
    let detailKey = "chat.errorDetail"
    let primary: Button?
    let secondary: Button?

    /// Known headlines (WebSearch.xcstrings has chatError.<camelCase>); unknown ones fall back to the service_error title.
    static let knownHeadlines: Set<String> = [
        "key_rejected", "insufficient_balance", "rate_limited", "no_response", "service_error",
        "format_mismatch", "searxng_json_disabled", "host_changed", "service_withdrawn",
    ]

    /// - switchTargetExists: the service for the secondary button still exists locally (if not, "Answer again with X" is not offered).
    static func make(
        card: ExternalSearchMessageRecord.ErrorCard,
        isLastAssistant: Bool,
        switchTargetExists: (String) -> Bool = { _ in true }
    ) -> SearchErrorCardPresentation {
        let primary: Button? = {
            let id = card.serviceId
            let (key, action, external): (String, ExternalSearchCardAction, Bool)
            switch card.primaryAction {
            case "update_key": (key, action, external) = ("action.updateKey", .updateKey(serviceID: id), false)
            case "top_up": (key, action, external) = ("action.topUp", .topUp(serviceID: id), true)
            case "retry", "retry_later": (key, action, external) = ("action.retry", .retry, false)
            case "switch_service": (key, action, external) = ("action.switchService", .switchService, false)
            case "check_settings": (key, action, external) = ("action.checkSettings", .checkSettings(serviceID: id), false)
            case "view_setup_guide": (key, action, external) = ("action.viewSetupGuide", .viewSetupGuide, true)
            case "reconfirm": (key, action, external) = ("action.reconfirm", .reconfirm(serviceID: id), false)
            default: return nil
            }
            guard isLastAssistant || !action.regenerates else { return nil }
            return Button(titleKey: key, titleArgument: nil, action: action, external: external)
        }()
        let secondary: Button? = card.switchTo.flatMap { target in
            guard isLastAssistant, switchTargetExists(target.id) else { return nil }
            return Button(
                titleKey: "action.answerWith", titleArgument: target.name,
                action: .answerWith(serviceID: target.id, name: target.name), external: false
            )
        }
        return SearchErrorCardPresentation(
            titleKey: "chatError." + camel(knownHeadlines.contains(card.headline) ? card.headline : "service_error"),
            serviceName: card.serviceName,
            primary: primary,
            secondary: secondary
        )
    }
}

/// Source card title in three segments: `Searched N times | Reused the previous search` · service name [custom] · `N sources | No relevant pages found`.
nonisolated struct SearchSourcesHeaderPresentation: Equatable, Sendable {
    enum Lead: Equatable, Sendable {
        case searched(count: Int)
        case reused
    }

    enum Count: Equatable, Sendable {
        case sources(Int)
        case none
    }

    let lead: Lead
    let serviceName: String
    let showsCustomBadge: Bool
    let count: Count
    /// No disclosure arrow when there are 0 sources.
    var expandable: Bool { count != .none }

    static func make(_ line: ExternalSearchMessageRecord.SourcesLine) -> SearchSourcesHeaderPresentation {
        SearchSourcesHeaderPresentation(
            lead: line.reused ? .reused : .searched(count: line.searchCount),
            serviceName: line.serviceName,
            showsCustomBadge: line.custom,
            count: line.sourceCount > 0 ? .sources(line.sourceCount) : .none
        )
    }
}

/// snake_case → lowerCamel (headline → `chatError.<camelCase>`; same as WebSearchCopy.camel, needed here in a pure mapping isolated from the main thread).
private nonisolated func camel(_ snake: String) -> String {
    let parts = snake.split(separator: "_").map(String.init)
    guard let first = parts.first else { return snake }
    return first + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
}

nonisolated enum ExternalSearchChatPresentation {
    /// The message has external search sources: the regenerate menu gains "Regenerate and search again".
    static func offersRegenerateWithSearch(_ message: ChatMessage) -> Bool {
        (message.citations ?? []).contains { $0.source == Citation.externalSearchSource }
    }

    /// Persisted notice == tools_rejected → reply notice row.
    static func replyNotice(_ message: ChatMessage) -> RelayWebReplyNotice? {
        message.capabilityExecution?.externalSearch?.notice == RelayWebReplyNotice.searchToolsRejected.rawValue
            ? .searchToolsRejected
            : nil
    }

    static func sourcesHeader(_ message: ChatMessage) -> SearchSourcesHeaderPresentation? {
        message.capabilityExecution?.externalSearch?.sourcesLine.map(SearchSourcesHeaderPresentation.make)
    }

    static func errorCard(
        _ message: ChatMessage, isLastAssistant: Bool, serviceExists: (String) -> Bool = { _ in true }
    ) -> SearchErrorCardPresentation? {
        message.capabilityExecution?.externalSearch?.errorCard.map {
            SearchErrorCardPresentation.make(card: $0, isLastAssistant: isLastAssistant, switchTargetExists: serviceExists)
        }
    }
}

// MARK: - Copy

@MainActor
extension SearchErrorCardPresentation {
    var title: String { WebSearchCopy.format(titleKey, serviceName) }
    var detail: String { WebSearchCopy.tr(detailKey) }
}

@MainActor
extension SearchErrorCardPresentation.Button {
    var title: String { titleArgument.map { WebSearchCopy.format(titleKey, $0) } ?? WebSearchCopy.tr(titleKey) }
}

@MainActor
extension SearchSourcesHeaderPresentation {
    var leadText: String {
        switch lead {
        case .searched(let count): return WebSearchCopy.format("chat.searchedTimes", count)
        case .reused: return WebSearchCopy.tr("chat.reusedSearch")
        }
    }

    var countText: String {
        switch count {
        case .sources(let n): return WebSearchCopy.format("chat.sourcesCount", n)
        case .none: return WebSearchCopy.tr("chat.noSources")
        }
    }

    var customBadgeText: String? { showsCustomBadge ? WebSearchCopy.tr("badge.custom") : nil }
}

@MainActor
extension ExternalSearchActivityTrail {
    /// In flight: "Searching with {name}…"; after everything is delivered and before the first character: "Answering from search results…".
    var caption: String {
        inFlight ? WebSearchCopy.format("chat.searching", serviceName) : WebSearchCopy.tr("chat.answeringFromResults")
    }
}
