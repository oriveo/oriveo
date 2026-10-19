import Foundation
import OriveoProviderKit

/// Pre-send confirmation . The rules follow the context-cap-confirm contract:
/// asked once per user-initiated send / edit after pre-send compaction, when the estimate goes over a custom
/// cap or past the model's long-context price line. `decide` is pure; `text` assembles the dialog copy.
nonisolated enum ContextCapConfirmPresentation {
    enum Attempt: String, Hashable, Sendable {
        case send, edit, retry, regenerate, `continue`, overflowRecovery, toolLoopLeg

        /// Only a new user message is asked about.
        var asks: Bool { self == .send || self == .edit }
    }

    enum Kind: String, Hashable, Sendable {
        case none, overCap, priceLine, overCapAndPriceLine
    }

    struct Acknowledgement: Codable, Hashable, Sendable {
        var model: String
        var T: Int
    }

    /// Per-conversation state kept on this device only (never synced).
    struct ConversationState: Codable, Hashable, Sendable {
        var suppressed: Bool = false
        var acknowledged: Acknowledgement?

        static let initial = ConversationState()
    }

    /// Input cost in USD below (`base`) and above (`long`) the price line, rounded to 6 decimals.
    struct Cost: Hashable, Sendable {
        var long: Double
        var base: Double
    }

    struct Input: Hashable, Sendable {
        var attempt: Attempt
        /// Runtime model id of this request.
        var model: String
        var reminderEnabled: Bool
        var conversationState: ConversationState
        var pricing: ContextCapPresentation.Pricing?
        /// Assembled plan estimate (P-hat).
        var estimatedInput: Int
        var B: Int?
        var limitedBy: ContextBudgetLimit?
        var priceLineTokens: Int?
    }

    struct Decision: Hashable, Sendable {
        var kind: Kind
        var showDontAsk: Bool
        var cost: Cost?
        var multiplier: ContextCapPresentation.Multiplier?
        var acknowledgeOnConfirm: Acknowledgement?

        static let none = Decision(kind: .none, showDontAsk: false, cost: nil, multiplier: nil, acknowledgeOnConfirm: nil)

        var crossesPriceLine: Bool { kind == .priceLine || kind == .overCapAndPriceLine }
    }

    static func decide(_ input: Input) -> Decision {
        guard input.attempt.asks else { return .none }
        let P = input.estimatedInput

        var overCap = false
        if input.limitedBy == .custom, let B = input.B, P > B {
            overCap = true
        }

        var acknowledgement: Acknowledgement?
        if let T = input.priceLineTokens, P >= T, input.reminderEnabled, !input.conversationState.suppressed {
            let candidate = Acknowledgement(model: input.model, T: T)
            if input.conversationState.acknowledged != candidate {
                acknowledgement = candidate
            }
        }
        let priceLine = acknowledgement != nil

        let kind: Kind = switch (overCap, priceLine) {
        case (true, true): .overCapAndPriceLine
        case (true, false): .overCap
        case (false, true): .priceLine
        case (false, false): .none
        }
        guard priceLine else {
            return Decision(kind: kind, showDontAsk: false, cost: nil, multiplier: nil, acknowledgeOnConfirm: nil)
        }

        let cost = cost(estimatedInput: P, pricing: input.pricing)
        return Decision(
            kind: kind,
            showDontAsk: true,
            cost: cost,
            multiplier: cost == nil ? ContextCapPresentation.multiplier(input.pricing) : nil,
            acknowledgeOnConfirm: acknowledgement
        )
    }

    private static func cost(estimatedInput: Int, pricing: ContextCapPresentation.Pricing?) -> Cost? {
        guard let base = pricing?.base?.prompt, base > 0,
              let long = pricing?.long?.prompt, long > 0
        else { return nil }
        func rounded(_ value: Double) -> Double { (value * 1_000_000).rounded() / 1_000_000 }
        let tokens = Double(estimatedInput)
        return Cost(long: rounded(tokens * long / 1_000_000), base: rounded(tokens * base / 1_000_000))
    }

    // MARK: Text

    struct Text: Hashable, Sendable {
        var title: String
        var body: String
        /// "Don't ask again in this chat" checkbox, unchecked by default.
        var showsDontAsk: Bool
    }

    /// Dialog copy; nil when nothing is asked. Numbers are compact and FSI…PDI isolated like U7, amounts go
    /// through `CostFormatter`, the multiplier is the U7 sentence, not wrapped again (same as Web / Android). A blank `modelName` falls back to the id.
    @MainActor
    static func text(
        _ decision: Decision,
        input: Input,
        modelName: String,
        locale: Locale = AppLocalization.currentLocale
    ) -> Text? {
        guard decision.kind != .none else { return nil }
        func isolated(_ text: String) -> String { "\u{2068}\(text)\u{2069}" }
        func count(_ value: Int) -> String { isolated(ContextCompactionSeparator.compactCount(value, locale: locale)) }
        func format(_ key: String, _ arguments: CVarArg...) -> String {
            String(format: L10n.tr(key, table: .chat), locale: L10n.formattingLocale(locale), arguments: arguments)
        }

        let trimmedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = isolated(trimmedName.isEmpty ? input.model : trimmedName)
        let estimate = count(input.estimatedInput)
        let line = input.priceLineTokens.map(count) ?? ""
        let multiplier = ContextUsagePanel.multiplierText(decision.multiplier, locale: locale)

        let overCapSentence = format("context_confirm_over_cap_body", estimate, input.B.map(count) ?? "")

        switch decision.kind {
        case .none:
            return nil
        case .overCap:
            return Text(title: L10n.tr("context_confirm_over_cap_title", table: .chat), body: overCapSentence, showsDontAsk: false)
        case .priceLine:
            let body: String
            if let cost = decision.cost {
                body = format(
                    "context_confirm_price_line_body_cost",
                    estimate, model, line, isolated(CostFormatter.format(cost.long)), isolated(CostFormatter.format(cost.base))
                )
            } else if let multiplier {
                body = format("context_confirm_price_line_body_mult", estimate, model, line, multiplier)
            } else {
                body = format("context_confirm_price_line_body", estimate, model, line)
            }
            return Text(
                title: L10n.tr("context_confirm_price_line_title", table: .chat),
                body: body,
                showsDontAsk: decision.showDontAsk
            )
        case .overCapAndPriceLine:
            let also: String
            if let cost = decision.cost {
                also = format(
                    "context_confirm_also_price_line_cost",
                    model, line, isolated(CostFormatter.format(cost.long)), isolated(CostFormatter.format(cost.base))
                )
            } else if let multiplier {
                also = format("context_confirm_also_price_line_mult", model, line, multiplier)
            } else {
                also = format("context_confirm_also_price_line", model, line)
            }
            return Text(
                title: L10n.tr("context_confirm_over_cap_title", table: .chat),
                body: overCapSentence + "\n" + also,
                showsDontAsk: decision.showDontAsk
            )
        }
    }

    // MARK: Production assembly

    struct Prompt: Hashable, Sendable {
        var input: Input
        var decision: Decision
        var text: Text
    }

    /// Builds the input from the conversation's effective window (same reading as the cap panel), the
    /// global reminder switch and this device's state, then decides. Nil when nothing is asked or the
    /// conversation / provider / model is gone.
    @MainActor
    static func prompt(
        in appState: AppState,
        conversationID: UUID,
        attempt: Attempt,
        estimatedInput: Int,
        store: ContextPriceLineConfirmStore,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection(),
        locale: Locale = AppLocalization.currentLocale
    ) -> Prompt? {
        guard attempt.asks,
              let conversation = appState.conversation(for: conversationID),
              let model = appState.currentModel(for: conversation),
              let source = ContextCapPresentation.panelSource(
                  in: appState,
                  conversationID: conversationID,
                  capabilitySelection: capabilitySelection
              )
        else { return nil }
        var window = source.window
        window.budgetCap = source.cap
        let budget = ContextBudget.window(window)
        let input = Input(
            attempt: attempt,
            model: model.id,
            reminderEnabled: appState.preferences.contextPriceLineReminderEnabled,
            conversationState: store.state(for: conversationID),
            pricing: source.pricing,
            estimatedInput: estimatedInput,
            B: budget.B,
            limitedBy: budget.limitedBy,
            priceLineTokens: source.window.priceLineTokens
        )
        let decision = decide(input)
        guard let text = text(
            decision,
            input: input,
            modelName: ContextCapPickerView.modelName(in: appState, conversationID: conversationID),
            locale: locale
        ) else { return nil }
        return Prompt(input: input, decision: decision, text: text)
    }
}

/// Local per-conversation price-line confirmation state, key `context_price_line_confirm:<conversation id>`,
/// value JSON `{suppressed, acknowledged: {model, T} | null}`. Not synced.
nonisolated struct ContextPriceLineConfirmStore: @unchecked Sendable {
    typealias State = ContextCapConfirmPresentation.ConversationState

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(_ conversationID: UUID) -> String {
        "context_price_line_confirm:\(conversationID.uuidString)"
    }

    /// Missing or unreadable reads as `{false, null}`.
    func state(for conversationID: UUID) -> State {
        guard let data = defaults.data(forKey: Self.key(conversationID)),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return .initial }
        return state
    }

    /// "Send anyway": past the price line records `{model, T}`; a checked box also suppresses further asks.
    /// Over-cap alone changes nothing.
    func confirm(_ decision: ContextCapConfirmPresentation.Decision, dontAsk: Bool, conversationID: UUID) {
        guard decision.crossesPriceLine else { return }
        var state = state(for: conversationID)
        if let acknowledgement = decision.acknowledgeOnConfirm {
            state.acknowledged = acknowledgement
        }
        if dontAsk, decision.showDontAsk {
            state.suppressed = true
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key(conversationID))
    }

    /// Cancel leaves the state as it was.
    func cancel(_ decision: ContextCapConfirmPresentation.Decision, conversationID: UUID) {}
}
