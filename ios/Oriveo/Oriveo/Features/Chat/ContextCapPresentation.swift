import Foundation
import OriveoProviderKit

/// Context cap settings UI presentation . The rules follow the
/// context-cap-presentation contract; B / U / limitedBy come from
/// `ContextBudget.window`, slider stops from `ContextBudget.capTicks`. Pure values only: no text, no state.
nonisolated enum ContextCapPresentation {
    /// Custom slider start when neither the conversation nor the effective budget gives a B.
    static let customStartFallback = 128_000
    /// Prefill of the settings custom input when the stored global cap is not custom.
    static let settingsCustomPrefill = ContextBudget.autoCapDefault

    struct Effective: Hashable, Sendable {
        var B: Int?
        var limitedBy: ContextBudgetLimit?
    }

    // MARK: Picker

    enum PickerSelection: String, Hashable, Sendable {
        case follow, auto, unlimited, custom
    }

    enum CustomHintKind: String, Hashable, Sendable {
        /// No price line.
        case none
        case over
        case at
        case under
    }

    struct CustomHint: Hashable, Sendable {
        var kind: CustomHintKind
        /// T - customStart; only for `under`.
        var gap: Int?
    }

    struct PickerModel: Hashable, Sendable {
        var selected: PickerSelection
        var effective: Effective
        var auto: Effective
        var unlimited: Effective
        var U: Int?
        var ticks: [Int]
        var customStart: Int
        var sliderIndex: Int
        var priceLineTickIndex: Int?
        var unlimitedCrossesPriceLine: Bool
        var customHint: CustomHint
    }

    /// Per-conversation cap picker. `window.budgetCap` is ignored; `conversationCap` nil follows `globalCap`.
    static func picker(
        window: ContextWindowInput,
        conversationCap: ContextBudgetCap?,
        globalCap: ContextBudgetCap
    ) -> PickerModel {
        let current = budget(window, cap: conversationCap ?? globalCap)
        let U = current.U
        let T = window.priceLineTokens
        let ticks = ContextBudget.capTicks(U: U, priceLineTokens: T)

        let customStart: Int
        if case .custom = conversationCap, let B = current.B {
            customStart = B
        } else {
            customStart = current.B ?? customStartFallback
        }

        let customHint: CustomHint
        if let T {
            if customStart > T {
                customHint = CustomHint(kind: .over, gap: nil)
            } else if customStart == T {
                customHint = CustomHint(kind: .at, gap: nil)
            } else {
                customHint = CustomHint(kind: .under, gap: T - customStart)
            }
        } else {
            customHint = CustomHint(kind: .none, gap: nil)
        }

        let crosses: Bool = if let U, let T { U > T } else { false }

        return PickerModel(
            selected: selection(conversationCap),
            effective: effective(current),
            auto: effective(budget(window, cap: .auto)),
            unlimited: effective(budget(window, cap: .unlimited)),
            U: U,
            ticks: ticks,
            customStart: customStart,
            sliderIndex: nearestTickIndex(customStart, ticks: ticks),
            priceLineTickIndex: T.flatMap { ticks.firstIndex(of: $0) },
            unlimitedCrossesPriceLine: crosses,
            customHint: customHint
        )
    }

    /// Index of the tick nearest to `value`; on a tie the lower tick wins.
    static func nearestTickIndex(_ value: Int, ticks: [Int]) -> Int {
        var best = 0
        for index in ticks.indices where abs(ticks[index] - value) < abs(ticks[best] - value) {
            best = index
        }
        return best
    }

    // MARK: Commit

    struct Commit: Hashable, Sendable {
        var value: Int
        var adjusted: Bool
        /// The text did not parse; `value` is the previous cap and nothing should be written.
        var restored: Bool
    }

    private static let groupingSeparators: Set<Unicode.Scalar> = [",", ".", "'", "\u{2019}", "_"]
    private static let maxDigits = 10

    /// Commits the typed custom number: drops White_Space and grouping separators, accepts only ASCII
    /// digits, saturates beyond 10 significant digits and takes min(max(n, customCapMin), U ?? customCapMax),
    /// so a U below customCapMin yields U.
    static func commit(text: String, U: Int?, previous: Int) -> Commit {
        let digits = text.unicodeScalars.filter {
            !$0.properties.isWhitespace && !groupingSeparators.contains($0)
        }
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else {
            return Commit(value: previous, adjusted: false, restored: true)
        }
        // Digits are counted after dropping leading zeros: "00000000064000" is 64000.
        let significant = String(digits).drop { $0 == "0" }
        let saturated = significant.count > maxDigits
        let parsed = saturated ? ContextBudget.customCapMax : Int(significant) ?? 0
        let upper = U ?? ContextBudget.customCapMax
        let value = min(max(parsed, ContextBudget.customCapMin), upper)
        return Commit(value: value, adjusted: saturated || value != parsed, restored: false)
    }

    // MARK: Panel

    enum WindowLine: String, Hashable, Sendable {
        /// U unknown.
        case unknown
        /// No price line.
        case window
        /// Price line at or above B.
        case windowPriceLine
        /// Price line below B.
        case aboveLine
    }

    /// Long-context price ratio in tenths (20 = x2); a side is nil unless it is above x1.
    struct Multiplier: Hashable, Sendable {
        var input: Int?
        var output: Int?

        /// Both sides equal: the "both" sentence.
        var isUniform: Bool { input != nil && input == output }
    }

    /// Per-million-token prices below (`base`) and above (`long`) the price line.
    struct Pricing: Hashable, Sendable {
        struct Side: Hashable, Sendable {
            var prompt: Double?
            var completion: Double?
        }

        var base: Side?
        var long: Side?
    }

    struct Panel: Hashable, Sendable {
        /// Effective B; nil when the window is unknown and the cap is auto / unlimited (show the option name).
        var capValue: Int?
        /// Custom cap above U: the model caps it.
        var limitedByModel: Bool
        var actual: Int?
        var windowLine: WindowLine
        /// max(T - used, 0) for `aboveLine` (0 = already past the line).
        var priceLineDistance: Int?
        var multiplier: Multiplier?
    }

    static func panel(
        window: ContextWindowInput,
        conversationCap: ContextBudgetCap?,
        globalCap: ContextBudgetCap,
        used: Int,
        pricing: Pricing?
    ) -> Panel {
        let cap = conversationCap ?? globalCap
        let current = budget(window, cap: cap)
        let T = window.priceLineTokens

        var limitedByModel = false
        if case .custom(let tokens) = cap, let U = current.U, tokens > U {
            limitedByModel = true
        }

        let windowLine: WindowLine
        var distance: Int?
        if current.U == nil {
            windowLine = .unknown
        } else if let T {
            if let B = current.B, T < B {
                windowLine = .aboveLine
                distance = max(T - used, 0)
            } else {
                windowLine = .windowPriceLine
            }
        } else {
            windowLine = .window
        }

        return Panel(
            capValue: current.B,
            limitedByModel: limitedByModel,
            actual: limitedByModel ? current.B : nil,
            windowLine: windowLine,
            priceLineDistance: distance,
            multiplier: multiplier(pricing)
        )
    }

    static func multiplier(_ pricing: Pricing?) -> Multiplier? {
        guard let pricing else { return nil }
        func tenths(_ base: Double?, _ long: Double?) -> Int? {
            guard let base, base > 0, let long else { return nil }
            let value = Int((long / base * 10).rounded())
            return value > 10 ? value : nil
        }
        let input = tenths(pricing.base?.prompt, pricing.long?.prompt)
        let output = tenths(pricing.base?.completion, pricing.long?.completion)
        guard input != nil || output != nil else { return nil }
        return Multiplier(input: input, output: output)
    }

    // MARK: Settings

    enum SettingsSelection: String, Hashable, Sendable, CaseIterable {
        case auto, unlimited, custom
    }

    struct Settings: Hashable, Sendable {
        var selected: SettingsSelection
        var customPrefill: Int
    }

    /// Settings row from the raw stored value; anything that does not parse reads as auto.
    static func settings(stored: Any?) -> Settings {
        settings(cap: ContextBudgetCap.parse(stored) ?? .auto)
    }

    static func settings(cap: ContextBudgetCap) -> Settings {
        switch cap {
        case .auto: Settings(selected: .auto, customPrefill: settingsCustomPrefill)
        case .unlimited: Settings(selected: .unlimited, customPrefill: settingsCustomPrefill)
        case .custom(let tokens): Settings(selected: .custom, customPrefill: tokens)
        }
    }

    // MARK: Helpers

    private static func budget(_ window: ContextWindowInput, cap: ContextBudgetCap) -> ContextWindowBudget {
        var input = window
        input.budgetCap = cap
        return ContextBudget.window(input)
    }

    private static func effective(_ budget: ContextWindowBudget) -> Effective {
        Effective(B: budget.B, limitedBy: budget.limitedBy)
    }

    private static func selection(_ conversationCap: ContextBudgetCap?) -> PickerSelection {
        switch conversationCap {
        case nil: .follow
        case .auto: .auto
        case .unlimited: .unlimited
        case .custom: .custom
        }
    }
}

// MARK: - Production assembly

extension ContextCapPresentation {
    /// Production inputs of one conversation's cap rows; the chat panel and tests read the same value.
    struct PanelSource: Sendable {
        /// Window parameters as the send path builds them; `budgetCap` is overridden by `panel(...)`.
        var window: ContextWindowInput
        var conversationCap: ContextBudgetCap?
        var globalCap: ContextBudgetCap
        var pricing: Pricing?

        /// The cap in effect: conversation cap, else the global default.
        var cap: ContextBudgetCap { conversationCap ?? globalCap }

        func panel(used: Int) -> Panel {
            ContextCapPresentation.panel(
                window: window,
                conversationCap: conversationCap,
                globalCap: globalCap,
                used: used,
                pricing: pricing
            )
        }
    }

    /// Builds the panel inputs from the conversation cap, the global default, the conversation's
    /// provider / current model, the resolved generation parameters (same reading as the send path)
    /// and catalog prices. Nil when the conversation, its provider or its model is gone.
    @MainActor
    static func panelSource(
        in appState: AppState,
        conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection = ChatCapabilitySelection()
    ) -> PanelSource? {
        guard let conversation = appState.conversation(for: conversationID),
              let provider = appState.provider(for: conversation.providerID),
              let model = appState.currentModel(for: conversation)
        else { return nil }
        let parameters = generationParameters(
            provider: provider,
            model: model,
            conversationID: conversationID,
            capabilitySelection: capabilitySelection
        )
        let window = ChatRequestBuilder.contextWindowInput(
            providerKind: provider.kind,
            model: model,
            userMaxOutput: ChatRequestBuilder.userMaxOutputTokens(from: parameters)
        )
        return PanelSource(
            window: window,
            conversationCap: conversation.contextCap,
            globalCap: appState.preferences.contextDefaultCap,
            pricing: window.priceLineTokens == nil ? nil : pricing(providerKind: provider.kind, modelID: model.id)
        )
    }

    /// Base prices are per token in metadata, long-context prices per million; both become per million.
    static func pricing(providerKind: ProviderKind, modelID: String) -> Pricing? {
        guard let metadata = MetadataClient.shared.resolveCatalogModel(modelID: modelID, providerKind: providerKind)
        else { return nil }
        let perMillion: (Double?) -> Double? = { $0.map { $0 * 1_000_000 } }
        return Pricing(
            base: Pricing.Side(
                prompt: perMillion(metadata.promptPerToken),
                completion: perMillion(metadata.completionPerToken)
            ),
            long: metadata.longContext.map {
                Pricing.Side(prompt: $0.promptPerMToken, completion: $0.completionPerMToken)
            }
        )
    }

    /// Mirrors ChatManager.resolveGenerationParameters (private there):
    /// only parameters the current profile still declares with a wire name count.
    @MainActor
    private static func generationParameters(
        provider: Provider,
        model: AIModel,
        conversationID: UUID,
        capabilitySelection: ChatCapabilitySelection
    ) -> GenerationParameterOverrides? {
        let generationProfile = GenerationParameterAvailability.profile(provider: provider, model: model)
        let declaredGenerationParameterIDs = Set(
            generationProfile?.parameters?.compactMap { parameter -> String? in
                guard let id = parameter.id,
                      let wire = generationProfile?.wire?[id],
                      !wire.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return id
            } ?? []
        )
        return GenerationParameterSettingsStore.shared.resolve(
            transient: nil,
            providerID: provider.id,
            modelID: provider.kind == .relay
                ? CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model)
                : ModelResolver.preferredStoredModelIdentifier(for: model, providerKind: provider.kind),
            conversationID: conversationID,
            profileFingerprint: GenerationParameterProfileFingerprint.make(provider: provider, model: model),
            reasoningMode: capabilitySelection.reasoningMode,
            activeParameterIDs: declaredGenerationParameterIDs
        )
    }
}
