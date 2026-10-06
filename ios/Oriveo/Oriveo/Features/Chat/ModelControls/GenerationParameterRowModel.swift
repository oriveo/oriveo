import Foundation

/// One generation parameter's row on the advanced settings page, and the data behind the "Advanced settings" summary on the model options page.
///
/// Its fields come from three existing evaluations only: `GenerationParameterSettingsStore.resolveWithSources`
/// (value and source), and `ProfileParamsResolver.evaluateOutbound` with `GenerationParameterApplication`
/// (which items will not be sent, and why). No outbound rule is decided again here.
///
/// The rows themselves are assembled from those results by the advanced settings page.
struct GenerationParameterRowModel: Identifiable, Equatable {
    /// Parameter id.
    let id: String
    let title: String
    /// Display text of the value in effect; nil when there is nothing to show.
    let displayValue: String?
    /// Changed in this conversation / inherited from the model default / decided by the model.
    let source: GenerationParameterResolution.Source
    /// Description of the allowed range, for example "0 – 2".
    let allowedRangeText: String?
    /// Validation error for what is being typed.
    let validationError: String?
    /// Why this item will not be sent.
    let dropReason: GenerationParameterApplication.DropReason?
    /// The parameter that takes this one over (its display name); once taken over, this item has no effect.
    let supersededBy: String?

    init(
        id: String,
        title: String,
        displayValue: String?,
        source: GenerationParameterResolution.Source,
        allowedRangeText: String? = nil,
        validationError: String? = nil,
        dropReason: GenerationParameterApplication.DropReason? = nil,
        supersededBy: String? = nil
    ) {
        self.id = id
        self.title = title
        self.displayValue = displayValue
        self.source = source
        self.allowedRangeText = allowedRangeText
        self.validationError = validationError
        self.dropReason = dropReason
        self.supersededBy = supersededBy
    }

    /// Changed in this conversation, and actually sent with the request right now.
    var isSentConversationOverride: Bool {
        source == .conversation && displayValue != nil
            && validationError == nil && dropReason == nil && supersededBy == nil
    }

    /// Summary for the "Advanced settings" row on the model options page: the first few items each become a "title value" chip, the rest are only counted.
    ///
    /// Counts only items changed in this conversation that will be sent, in the order of the rows passed in.
    static func summary(
        _ rows: [GenerationParameterRowModel], maxChips: Int = 2
    ) -> (chips: [String], moreCount: Int) {
        let adjusted = rows.filter(\.isSentConversationOverride)
        let shown = adjusted.prefix(max(0, maxChips))
        return (
            chips: shown.map { "\($0.title) \($0.displayValue ?? "")" },
            moreCount: adjusted.count - shown.count
        )
    }
}

// MARK: - Assembling rows from the evaluations

extension GenerationParameterRowModel {
    /// With thinking on, the Anthropic send path guards sampling parameters and max tokens together; to predict that, the interface needs the budget.
    struct ThinkingContext: Equatable, Sendable {
        /// Thinking budget in tokens. nil when adaptive thinking has no fixed budget.
        let budgetTokens: Int?
    }

    /// Everything needed to assemble the rows. All three are existing evaluations or the parameter table; nothing here reads storage.
    struct Inputs {
        /// The parameters this page shows, in display order.
        var parameters: [GenerationParameterRef]
        /// The profile used for the outbound request (declaration order, exclusions, prerequisites and wire paths all live there).
        var profile: GenerationProfileRef
        /// The result of `GenerationParameterSettingsStore.resolveWithSources`.
        var resolution: GenerationParameterResolution
        /// Keys the builder has already written into the request body (they take part in conflict checks).
        var builderPresence: Set<String> = []
        /// Passed while thinking is on; nil when it is off or the provider is not Anthropic.
        var activeThinking: ThinkingContext? = nil
        /// Values from the layers below the one being edited (on the conversation page: model default and connection default combined).
        /// The interface uses it to draw the "model default" tick and to answer what going back to the model default would give.
        var lowerLayerValues: [String: GenerationParameterValue] = [:]
    }

    /// Rows of the conversation page: changed in this conversation / inherited from the model default / decided by the model, and which items will not be sent and why.
    static func rows(_ inputs: Inputs) -> [GenerationParameterRowModel] {
        AdvancedParameterRow.rows(inputs, editingLayers: [.singleSend, .conversation]).map(\.model)
    }
}
