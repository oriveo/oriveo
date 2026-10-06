import Foundation

// Pure logic of the advanced settings page: display text of values, input validation, row assembly, group layout, reset scope.
// Nothing here touches SwiftUI or decides an outbound rule again; outbound criteria come only from
// `ProfileParamsResolver.evaluateOutbound` and the constant tables it uses.

// MARK: - Display text of values

enum GenerationParameterValueText {
    /// The single implementation of number display. Never `formatted()`: it inserts locale grouping separators,
    /// and this text is the input of the next edit; once a separator gets in, it no longer parses back to a number.
    static func number(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 {
            return String(Int64(number))
        }
        return String(number)
    }

    /// Folds user input back into a parseable decimal literal: grouping separators are removed first, then the local decimal mark becomes `.`.
    static func normalizedNumberInput(_ raw: String, locale: Locale = .current) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let grouping = locale.groupingSeparator, !grouping.isEmpty {
            text = text.replacingOccurrences(of: grouping, with: "")
        }
        if let decimal = locale.decimalSeparator, decimal != "." {
            text = text.replacingOccurrences(of: decimal, with: ".")
        }
        return text
    }

    /// The text of the value on the right of a row. The raw text in an input comes from `editingText`; the two are not mixed.
    static func display(_ value: GenerationParameterValue, parameterID: String) -> String {
        switch value {
        case .number(let number):
            if let label = GenerationParameterPresentationFacts.modeLabel(parameterID: parameterID, value: number) {
                return label
            }
            return Self.number(number)
        case .string(let string):
            return string
        case .boolean(let flag):
            return flag ? L10n.tr("On", table: .chat) : L10n.tr("Off", table: .chat)
        case .stringList(let list):
            return String(format: L10n.tr("%lld entries", table: .chat), list.count)
        case .object:
            return L10n.tr("Set", table: .chat)
        }
    }

    /// The raw text in an input: numbers without separators, objects as formatted JSON.
    static func editingText(_ value: GenerationParameterValue?) -> String {
        switch value {
        case .number(let number): return Self.number(number)
        case .string(let string): return string
        case .stringList(let strings): return strings.joined(separator: ", ")
        case .object(let object):
            let foundation = object.mapValues(\.foundationValue)
            guard JSONSerialization.isValidJSONObject(foundation),
                  let data = try? JSONSerialization.data(
                    withJSONObject: foundation, options: [.prettyPrinted, .sortedKeys]
                  ) else { return "" }
            return String(decoding: data, as: UTF8.self)
        case .boolean, .none: return ""
        }
    }

    /// The allowed range in a few words, for example "0 – 2" or "≥ 1". nil without a range.
    static func range(_ range: GenerationParameterRange?) -> String? {
        guard let range else { return nil }
        let lower = range.min.map { (number($0), false) } ?? range.minExclusive.map { (number($0), true) }
        let upper = range.max.map { (number($0), false) } ?? range.maxExclusive.map { (number($0), true) }
        switch (lower, upper) {
        case let (lower?, upper?) where !lower.1 && !upper.1:
            return "\(lower.0) – \(upper.0)"
        case let (lower?, upper?):
            return "\(lower.1 ? ">" : "≥") \(lower.0), \(upper.1 ? "<" : "≤") \(upper.0)"
        case let (lower?, nil):
            return "\(lower.1 ? ">" : "≥") \(lower.0)"
        case let (nil, upper?):
            return "\(upper.1 ? "<" : "≤") \(upper.0)"
        case (nil, nil):
            return nil
        }
    }
}

// MARK: - Input validation

/// Validation of what is being typed. The verdict must agree with the outbound `ProfileParamsResolver.isValidGenerationValue`:
/// this only says what is wrong and what is allowed, with no second standard. No clamping, no rounding.
enum GenerationParameterInputValidation {
    enum Issue: Equatable {
        case notANumber
        case notAnInteger
        case aboveMaximum(Double)
        case notBelow(Double)
        case belowMinimum(Double)
        case notAbove(Double)
        case invalidSchema
        case notAccepted
    }

    static func issue(value: GenerationParameterValue, parameter: GenerationParameterRef) -> Issue? {
        guard !ProfileParamsResolver.isValidGenerationValue(value, for: parameter) else { return nil }
        let isNumeric = parameter.valueSchema == "number" || parameter.valueSchema == "integer"
        guard case .number(let number) = value, number.isFinite else {
            if isNumeric { return .notANumber }
            return parameter.valueSchema == "json-schema" ? .invalidSchema : .notAccepted
        }
        if parameter.valueSchema == "integer", number.rounded() != number { return .notAnInteger }
        if let maximum = parameter.range?.max, number > maximum { return .aboveMaximum(maximum) }
        if let minimum = parameter.range?.min, number < minimum { return .belowMinimum(minimum) }
        if let minimum = parameter.range?.minExclusive, number <= minimum { return .notAbove(minimum) }
        if let maximum = parameter.range?.maxExclusive, number >= maximum { return .notBelow(maximum) }
        return .notAccepted
    }

    /// A draft in a number input that is not a value yet. An empty string is not an error (it means unset).
    static func issue(
        numericDraft raw: String, parameter: GenerationParameterRef, locale: Locale = .current
    ) -> Issue? {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let number = Double(GenerationParameterValueText.normalizedNumberInput(raw, locale: locale)) else {
            return .notANumber
        }
        return issue(value: .number(number), parameter: parameter)
    }

    static func message(_ issue: Issue, parameterID: String) -> String {
        func bound(_ key: String, _ value: Double) -> String {
            String(format: L10n.tr(key, table: .chat), GenerationParameterValueText.number(value))
        }
        switch issue {
        case .notANumber:
            return L10n.tr(
                "Enter a number. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
                table: .chat
            )
        case .notAnInteger:
            return L10n.tr(
                "Enter a whole number. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
                table: .chat
            )
        case .aboveMaximum(let maximum):
            if parameterID == "max_output_tokens" {
                return bound(
                    "This model can write at most %@. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
                    maximum
                )
            }
            return bound(
                "The highest value this model accepts is %@. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
                maximum
            )
        case .belowMinimum(let minimum):
            return bound(
                "The lowest value this model accepts is %@. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
                minimum
            )
        case .notAbove(let minimum):
            return bound(
                "This must be greater than %@. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
                minimum
            )
        case .notBelow(let maximum):
            return bound(
                "This must be less than %@. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
                maximum
            )
        case .invalidSchema:
            return L10n.tr(
                "This isn’t a valid JSON Schema. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
                table: .chat
            )
        case .notAccepted:
            return L10n.tr(
                "This model doesn’t accept this value. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
                table: .chat
            )
        }
    }
}

// MARK: - Stop sequences

/// Stop sequences are edited as one tag per entry. An entry may contain commas, spaces and newlines; splitting the input on commas
/// would make `", "`, one of the most common stop sequences, impossible to enter.
enum GenerationParameterStopSequences {
    enum AddResult: Equatable {
        case added([String])
        case empty
        case duplicate
        case full
    }

    /// Added as is: whitespace is not trimmed and nothing is split. Empty strings, duplicates and entries past the limit are not added.
    static func adding(_ raw: String, to list: [String], limit: Int?) -> AddResult {
        guard !raw.isEmpty else { return .empty }
        guard !list.contains(raw) else { return .duplicate }
        if let limit, list.count >= limit { return .full }
        return .added(list + [raw])
    }

    /// Display text on a tag: invisible characters become visible marks, everything else stays.
    static func visible(_ sequence: String) -> String {
        var result = ""
        for character in sequence {
            switch character {
            case "\n", "\r\n", "\r": result.append("↵")
            case "\t": result.append("⇥")
            case " ": result.append("␣")
            default: result.append(character)
            }
        }
        return result
    }

    /// Whether this entry contains characters replaced by marks (the interface accents the marks accordingly).
    static func hasInvisibleCharacters(_ sequence: String) -> Bool {
        sequence.contains { $0 == "\n" || $0 == "\r\n" || $0 == "\r" || $0 == "\t" || $0 == " " }
    }

    /// The limit is only the `maxItems` declared in the parameter table; without a declaration no limit is shown or enforced on the device.
    static func limit(for parameter: GenerationParameterRef) -> Int? {
        for constraint in parameter.constraints ?? [] {
            if case .number(let value)? = constraint["maxItems"], value >= 1 { return Int(value) }
        }
        return nil
    }
}

// MARK: - Presentation facts by parameter id

/// Presentation facts that depend on the parameter id alone, not on the engine: which parameters form a family, which one is a mode switch,
/// and which takes over which when turned on. The page looks this table up while laying out a parameter table; parameters not in it are plain rows.
enum GenerationParameterPresentationFacts {
    struct Family: Equatable {
        let id: String
        /// The family's switch or main value. Without it in the parameter table the family does not exist.
        let head: String
        let members: [String]
        /// Integer value → mode name; when non-nil the family head renders as a segmented choice.
        let modes: [Int: String]?
        /// While the family head has one of these values, the parameters in `supersedes` are taken over and have no effect.
        let activeModes: Set<Int>
        let supersedes: [String]
    }

    static let families: [Family] = [
        .init(id: "mirostat", head: "mirostat", members: ["mirostat_tau", "mirostat_eta"],
              modes: [0: "Off", 1: "v1", 2: "v2"], activeModes: [1, 2], supersedes: ["top_k", "top_p"]),
        .init(id: "repeat", head: "repeat_penalty",
              members: ["repeat_last_n", "frequency_penalty", "presence_penalty"],
              modes: nil, activeModes: [], supersedes: []),
        .init(id: "dry", head: "dry_multiplier",
              members: ["dry_base", "dry_allowed_length", "dry_penalty_last_n", "dry_sequence_breakers"],
              modes: nil, activeModes: [], supersedes: []),
        .init(id: "xtc", head: "xtc_probability", members: ["xtc_threshold"],
              modes: nil, activeModes: [], supersedes: []),
        .init(id: "dynatemp", head: "dynatemp_range", members: ["dynatemp_exponent"],
              modes: nil, activeModes: [], supersedes: []),
    ]

    /// Which parameters the "Common" group holds, in display order. Those missing from the parameter table simply do not appear.
    static let commonParameterIDs = ["max_output_tokens", "temperature", "top_k", "top_p", "min_p"]

    static func family(headedBy parameterID: String) -> Family? {
        families.first { $0.head == parameterID }
    }

    static func modeLabel(parameterID: String, value: Double) -> String? {
        guard let modes = family(headedBy: parameterID)?.modes,
              value.rounded() == value, let name = modes[Int(value)] else { return nil }
        // "v1" and "v2" are algorithm version names and are not translated; only "Off" comes from the catalog.
        return name == "Off" ? L10n.tr("Off", table: .chat) : name
    }

    static func familyTitle(_ family: Family) -> String {
        switch family.id {
        case "mirostat": return "Mirostat"
        case "dry": return "DRY"
        case "xtc": return "XTC"
        case "dynatemp": return L10n.tr("Dynamic temperature", table: .chat)
        default: return GenerationParameterVocabulary.title(family.head)
        }
    }

    static func familySubtitle(_ family: Family, presentMembers: [String]) -> String? {
        switch family.id {
        case "mirostat":
            return L10n.tr(
                "Keeps the randomness of the output steady around a target, in place of Top K and Top P.",
                table: .chat
            )
        case "dry": return L10n.tr("Discourages repeating whole passages from earlier text", table: .chat)
        case "xtc": return L10n.tr("Sometimes skips the most likely word for more varied wording", table: .chat)
        case "dynatemp": return L10n.tr("Temperature shifts with how confident the model is", table: .chat)
        case "repeat":
            guard !presentMembers.isEmpty else { return nil }
            return String(
                format: L10n.tr("Also covers %@", table: .chat),
                ListFormatter.localizedString(byJoining: presentMembers.map(GenerationParameterVocabulary.title))
            )
        default: return nil
        }
    }

    /// How an engine default declared in the parameter table is shown. A negative default for the output limit means "no limit"
    /// (as with llama.cpp's `n_predict = -1`), and a bare -1 means nothing to a reader. The criterion is the table's value alone.
    static func engineDefaultText(_ value: GenerationParameterValue, parameterID: String) -> String {
        if parameterID == "max_output_tokens", case .number(let number) = value, number < 0 {
            return L10n.tr("No limit", table: .chat)
        }
        return GenerationParameterValueText.display(value, parameterID: parameterID)
    }

    /// Inside its own family's card a member row drops the family prefix: main name + the parameter's name in the engine.
    /// Outside the card (summary chips, the "kept" list, accessibility) the full name from the vocabulary is used.
    static func memberShortTitle(parameterID: String) -> (name: String, symbol: String)? {
        switch parameterID {
        case "mirostat_tau": return (L10n.tr("Target entropy", table: .chat), "tau")
        case "mirostat_eta": return (L10n.tr("Learning rate", table: .chat), "eta")
        default: return nil
        }
    }

    /// What the right side of a row says when no layer gives a value and the parameter table has no engine default.
    static func unsetLabel(parameterID: String) -> String {
        switch parameterID {
        case "seed": return L10n.tr("Random each time", table: .chat)
        case "stop", "stop_sequences", "dry_sequence_breakers", "samplers":
            return L10n.tr("Not set", table: .chat)
        case "response_format", "json_schema", "grammar": return L10n.tr("Plain text", table: .chat)
        // The existing string "Model default" means exactly "not set, the model decides".
        default: return L10n.tr("Model default")
        }
    }

    /// Only the two most frequently changed items get a plain-language note; the others are touched only by people who know them, and notes on every row would bury these two.
    static func annotation(parameterID: String) -> String? {
        switch parameterID {
        case "temperature":
            return L10n.tr("Higher is more creative, lower is more consistent.", table: .providers)
        case "max_output_tokens":
            return L10n.tr("The longest reply the model may write.", table: .providers)
        case "stop", "stop_sequences":
            return L10n.tr(
                "The model stops as soon as it writes any one of these. A sequence can contain commas, spaces and line breaks.",
                table: .chat
            )
        default:
            return nil
        }
    }
}

// MARK: - Rows

/// One row of the advanced settings page: the shared `GenerationParameterRowModel` plus the parameter definition and editing state the controls need.
struct AdvancedParameterRow: Identifiable, Equatable {
    /// Where this row's value stands relative to "the layer being edited".
    enum Standing: Equatable {
        /// A value from the layer being edited (on the conversation page: changed in this conversation).
        case editedHere
        /// A value from a lower layer (on the conversation page: inherited from the model default).
        case inherited
        /// No layer gave one.
        case unset
    }

    let model: GenerationParameterRowModel
    let parameter: GenerationParameterRef
    let standing: Standing
    /// The layer in effect says "do not send".
    let isOmitted: Bool
    /// The value in effect (in the `.value` state).
    let effectiveValue: GenerationParameterValue?
    /// The value the layer being edited stores itself; nil when it stores none or stores "do not send".
    let ownValue: GenerationParameterValue?
    /// The value this falls back to once this layer is cleared: the lower layer's value, or the engine default from the parameter table.
    let fallbackValue: GenerationParameterValue?
    /// The value a lower layer really gave (on the conversation page: the model default you set). An engine default does not count.
    let modelDefaultValue: GenerationParameterValue?
    /// Display text of the engine default declared in the parameter table.
    let engineDefaultText: String?
    /// Display name of the parameter that conflicts with this item and pushes it out.
    let conflictPartner: String?
    /// Display name of the parameter this item's prerequisite points to.
    let requirementPartner: String?

    var id: String { model.id }

    /// The text of the value on the right of the row: the value when there is one, otherwise a note such as "decided by the model".
    var trailingText: String {
        if isOmitted { return L10n.tr("Omit") }
        return model.displayValue ?? GenerationParameterPresentationFacts.unsetLabel(parameterID: id)
    }

    /// The "why this will not be sent" sentence under the row. A validation error is the most specific and takes precedence over a general drop reason.
    var notice: (text: String, isError: Bool)? {
        if let error = model.validationError { return (error, true) }
        // A row that is taken over is only struck through: the reason is said once in the group's footnote, and again when the row is opened (see `supersededNote`).
        guard model.supersededBy == nil, let reason = model.dropReason else { return nil }
        return (Self.message(for: reason, conflictPartner: conflictPartner, requirementPartner: requirementPartner), false)
    }

    /// One sentence on what took this row over. Shown only while the row is expanded, in secondary color; it is not an error to act on.
    var supersededNote: String? {
        model.supersededBy.map {
            String(format: L10n.tr("%@ is on, so this setting isn’t used.", table: .chat), $0)
        }
    }

    static func message(
        for reason: GenerationParameterApplication.DropReason,
        conflictPartner: String? = nil,
        requirementPartner: String? = nil
    ) -> String {
        switch reason {
        case .invalidValue:
            return L10n.tr("This model doesn’t accept this value, so this setting isn’t sent.", table: .chat)
        case .conflict:
            if let conflictPartner {
                return String(
                    format: L10n.tr("Can’t be sent together with %@, so this setting is left out.", table: .chat),
                    conflictPartner
                )
            }
            return L10n.tr("Conflicts with another setting, so this one is left out.", table: .chat)
        case .requirementUnmet:
            if let requirementPartner {
                return String(
                    format: L10n.tr("Only sent when %@ is set as well.", table: .chat), requirementPartner
                )
            }
            return L10n.tr("Depends on another setting that isn’t set, so it isn’t sent.", table: .chat)
        case .requiredField:
            return L10n.tr("This model requires this field, so the default is still sent.", table: .chat)
        case .thinkingIncompatible:
            return L10n.tr("The model doesn’t accept this while thinking is on, so it isn’t sent.", table: .chat)
        case .thinkingBudget:
            return L10n.tr("Smaller than the reasoning budget, so the default is sent instead.", table: .chat)
        }
    }

    /// Assembles rows from the evaluation. `editingLayers` are the layers this page edits: the conversation layer on the conversation page,
    /// the model default layer on the provider detail page.
    static func rows(
        _ inputs: GenerationParameterRowModel.Inputs,
        editingLayers: Set<GenerationParameterResolution.Layer>,
        ownValues: GenerationParameterOverrides? = nil
    ) -> [AdvancedParameterRow] {
        let entries = inputs.resolution.entries
        let candidates = entries.compactMapValues { $0.override.state == .value ? $0.override : nil }
        let outbound = ProfileParamsResolver.evaluateOutbound(
            candidates: candidates, profile: inputs.profile, builderPresence: inputs.builderPresence
        )
        var dropped = outbound.dropped
        let wire = inputs.profile.wire ?? [:]
        var definitions: [String: GenerationParameterRef] = [:]
        for parameter in inputs.profile.parameters ?? [] {
            if let id = parameter.id, definitions[id] == nil { definitions[id] = parameter }
        }

        // A field the upstream requires: "do not send" cannot remove it, and the builder's default is sent regardless.
        let required = ProfileParamsResolver.requiredWireFields[inputs.profile.template ?? ""] ?? []
        for (id, entry) in entries where entry.override.state == .omit {
            if let path = wire[id], required.contains(path) { dropped[id] = .requiredField }
        }

        // The guard for Anthropic with thinking on: it reads the same constants as `applyAnthropicThinkingGuard` on the send path.
        if let thinking = inputs.activeThinking {
            for id in outbound.kept {
                guard let path = wire[id] else { continue }
                let number: Double? = { if case .number(let value)? = candidates[id]?.value { return value }; return nil }()
                if ProfileParamsResolver.anthropicThinkingDroppedParameters.contains(path) {
                    dropped[id] = .thinkingIncompatible
                } else if path == "top_p", let number, number < ProfileParamsResolver.anthropicThinkingTopPMin {
                    dropped[id] = .thinkingIncompatible
                } else if path == "max_tokens", let number, let budget = thinking.budgetTokens,
                          Int(number) <= budget {
                    dropped[id] = .thinkingBudget
                }
            }
        }

        // Takeover: when the family head is on a superseding mode and is really sent itself, the listed parameters have no effect.
        var superseded: [String: String] = [:]
        for family in GenerationParameterPresentationFacts.families where !family.supersedes.isEmpty {
            guard dropped[family.head] == nil, outbound.kept.contains(family.head),
                  case .number(let mode)? = candidates[family.head]?.value,
                  mode.rounded() == mode, family.activeModes.contains(Int(mode)) else { continue }
            for target in family.supersedes {
                superseded[target] = GenerationParameterPresentationFacts.familyTitle(family)
            }
        }

        func conflictPartner(of id: String) -> String? {
            let occupied = outbound.kept.union(inputs.builderPresence)
            let own = definitions[id]?.conflictsWith ?? []
            let partner = own.first(where: occupied.contains)
                ?? outbound.kept.sorted().first { definitions[$0]?.conflictsWith?.contains(id) == true }
            return partner.map(GenerationParameterVocabulary.title)
        }

        func requirementPartner(of id: String) -> String? {
            for requirement in definitions[id]?.requires ?? [] {
                if case .string(let key)? = requirement["key"] { return GenerationParameterVocabulary.title(key) }
            }
            return nil
        }

        return inputs.parameters.compactMap { parameter in
            guard let id = parameter.id else { return nil }
            let entry = entries[id]
            let isOmitted = entry?.override.state == .omit
            let effective = entry?.override.state == .value ? entry?.override.value : nil
            let engineDefault = parameter.defaultDescription.map {
                GenerationParameterPresentationFacts.engineDefaultText($0, parameterID: id)
            }
            let standing: Standing
            if let entry {
                standing = editingLayers.contains(entry.layer) ? .editedHere : .inherited
            } else {
                standing = .unset
            }
            let reason = dropped[id]
            let validation: String? = {
                guard reason == .invalidValue, let effective,
                      let issue = GenerationParameterInputValidation.issue(value: effective, parameter: parameter)
                else { return nil }
                return GenerationParameterInputValidation.message(issue, parameterID: id)
            }()
            let own = ownValues?.values[id]
            let lower: GenerationParameterValue? = {
                // When this layer takes no position itself, the value in effect comes from a lower layer anyway.
                if standing == .inherited { return effective }
                return nil
            }()
            let model = GenerationParameterRowModel(
                id: id,
                title: GenerationParameterVocabulary.title(id),
                displayValue: effective.map { GenerationParameterValueText.display($0, parameterID: id) }
                    ?? (entry == nil ? engineDefault : nil),
                source: inputs.resolution.source(for: id),
                allowedRangeText: GenerationParameterValueText.range(parameter.range),
                validationError: validation,
                dropReason: reason,
                supersededBy: superseded[id]
            )
            return AdvancedParameterRow(
                model: model,
                parameter: parameter,
                standing: standing,
                isOmitted: isOmitted,
                effectiveValue: effective,
                ownValue: own?.state == .value ? own?.value : (standing == .editedHere ? effective : nil),
                fallbackValue: inputs.lowerLayerValues[id] ?? lower ?? parameter.defaultDescription,
                modelDefaultValue: inputs.lowerLayerValues[id] ?? lower,
                engineDefaultText: engineDefault,
                conflictPartner: reason == .conflict ? conflictPartner(of: id) : nil,
                requirementPartner: reason == .requirementUnmet ? requirementPartner(of: id) : nil
            )
        }
    }
}

extension GenerationParameterResolution {
    /// The evaluation used by the provider detail page (no conversation): just the model default and connection default layers.
    static func modelDefaultScope(
        modelDefaults: GenerationParameterOverrides?, connectionDefaults: GenerationParameterOverrides?
    ) -> GenerationParameterResolution {
        var entries: [String: Entry] = [:]
        for (layer, values) in [(Layer.connectionModel, modelDefaults), (Layer.connection, connectionDefaults)] {
            for (key, value) in values?.values ?? [:] where entries[key] == nil && value.state != .inherit {
                entries[key] = .init(override: value, layer: layer)
            }
        }
        return .init(entries: entries)
    }
}

// MARK: - Group layout

/// The page's groups and rows, derived entirely from the parameter table (each parameter's `group` and the declaration order).
/// Every engine follows the same rules; no page is hard-coded for any one of them.
enum AdvancedSettingsLayout {
    /// With more parameters than this outside "Common", the single "More" card becomes a long page with one card per group.
    static let sectionedThreshold = 8

    struct Cluster: Equatable, Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        /// The family head; the summary shows its value first. A cluster aggregated by group has no head.
        let headID: String?
        let memberIDs: [String]
    }

    enum Item: Equatable, Identifiable {
        case parameter(String)
        /// A segmented mode switch (with its one-sentence note).
        case mode(parameterID: String, description: String?, options: [ModeOption])
        case cluster(Cluster)

        var id: String {
            switch self {
            case .parameter(let id): return "p:\(id)"
            case .mode(let id, _, _): return "m:\(id)"
            case .cluster(let cluster): return "c:\(cluster.id)"
            }
        }
    }

    struct ModeOption: Equatable, Identifiable {
        let value: Int
        let title: String
        var id: Int { value }
    }

    struct Section: Equatable, Identifiable {
        let id: String
        let title: String?
        let items: [Item]
    }

    static let groupOrder = [
        "budget", "reasoning", "sampling", "repetition", "reproducibility", "output_contract", "engine_runtime",
    ]

    static func sections(parameters: [GenerationParameterRef]) -> [Section] {
        let ids = parameters.compactMap(\.id)
        let present = Set(ids)
        let common = GenerationParameterPresentationFacts.commonParameterIDs.filter(present.contains)
        let rest = parameters.filter { parameter in parameter.id.map { !common.contains($0) } ?? false }
        var sections: [Section] = []
        if !common.isEmpty {
            sections.append(.init(
                id: "common",
                // With this group alone, "Common" is not rendered: one card, one group, and a heading that would say nothing.
                title: rest.isEmpty ? nil : L10n.tr("Basic Settings", table: .providers),
                items: common.map(Item.parameter)
            ))
        }
        guard !rest.isEmpty else { return sections }
        if rest.count > sectionedThreshold {
            sections.append(contentsOf: sectioned(rest))
        } else {
            sections.append(.init(id: "more", title: L10n.tr("More", table: .chat), items: grouped(rest)))
        }
        return sections
    }

    /// A page with few parameters: one "More" card, one row per group, expanding in place. A group with a single parameter is just that row.
    private static func grouped(_ parameters: [GenerationParameterRef]) -> [Item] {
        groupOrder.compactMap { group -> Item? in
            let members = parameters.filter { ($0.group ?? "sampling") == group }.compactMap(\.id)
            guard let first = members.first else { return nil }
            if members.count == 1 { return .parameter(first) }
            return .cluster(.init(
                id: "group:\(group)", title: compactGroupTitle(group), subtitle: nil, headID: nil,
                memberIDs: members
            ))
        }
    }

    /// A page with many parameters (such as llama.cpp): each mode family gets its own card, the rest one card per group, with families folded into one row.
    private static func sectioned(_ parameters: [GenerationParameterRef]) -> [Section] {
        var remaining = parameters
        let present = Set(parameters.compactMap(\.id))
        var sections: [Section] = []

        // A mode family (such as Mirostat): the segmented choice plus its member rows, in a card of its own.
        for family in GenerationParameterPresentationFacts.families {
            guard let modes = family.modes, present.contains(family.head) else { continue }
            let members = family.members.filter(present.contains)
            let options = modes.keys.sorted().map { value in
                ModeOption(
                    value: value,
                    title: GenerationParameterPresentationFacts.modeLabel(
                        parameterID: family.head, value: Double(value)
                    ) ?? String(value)
                )
            }
            sections.append(.init(
                id: "family:\(family.id)",
                title: GenerationParameterPresentationFacts.familyTitle(family),
                items: [.mode(
                    parameterID: family.head,
                    description: GenerationParameterPresentationFacts.familySubtitle(family, presentMembers: members),
                    options: options
                )] + members.map(Item.parameter)
            ))
            let taken = Set([family.head] + members)
            remaining.removeAll { $0.id.map(taken.contains) ?? false }
        }

        func take(_ groups: Set<String>) -> [String] {
            let ids = remaining.filter { groups.contains($0.group ?? "sampling") }.compactMap(\.id)
            remaining.removeAll { groups.contains($0.group ?? "sampling") }
            return ids
        }

        /// Folds the parameters of a group that form a family into one row; with `collapseLoose`, loose parameters outside a family fold into one row as well.
        func items(for ids: [String], collapseLoose: Bool, looseID: String) -> [Item] {
            var pending = ids
            var result: [Item] = []
            var loose: [String] = []
            while let id = pending.first {
                pending.removeFirst()
                let family = GenerationParameterPresentationFacts.families.first {
                    $0.modes == nil && ($0.head == id || $0.members.contains(id)) && ids.contains($0.head)
                }
                guard let family else { loose.append(id); continue }
                let members = family.members.filter(ids.contains)
                guard !members.isEmpty else { loose.append(id); continue }
                pending.removeAll { $0 == family.head || members.contains($0) }
                result.append(.cluster(.init(
                    id: "family:\(family.id)",
                    title: GenerationParameterPresentationFacts.familyTitle(family),
                    subtitle: GenerationParameterPresentationFacts.familySubtitle(family, presentMembers: members),
                    headID: family.head,
                    memberIDs: [family.head] + members
                )))
            }
            if collapseLoose, loose.count > 2 {
                let names = loose.prefix(3).map(GenerationParameterVocabulary.title)
                result.append(.cluster(.init(
                    id: looseID, title: ListFormatter.localizedString(byJoining: names), subtitle: nil,
                    headID: nil, memberIDs: loose
                )))
            } else {
                result.append(contentsOf: loose.map(Item.parameter))
            }
            return result
        }

        let reasoning = take(["reasoning"])
        if !reasoning.isEmpty {
            sections.append(.init(
                id: "reasoning", title: L10n.tr("Reasoning"), items: reasoning.map(Item.parameter)
            ))
        }
        let repetition = take(["repetition"])
        if !repetition.isEmpty {
            sections.append(.init(
                id: "repetition", title: L10n.tr("Repetition", table: .chat),
                items: items(for: repetition, collapseLoose: false, looseID: "loose:repetition")
            ))
        }
        let sampling = take(["sampling"])
        if !sampling.isEmpty {
            sections.append(.init(
                id: "sampling", title: L10n.tr("More sampling", table: .chat),
                items: items(for: sampling, collapseLoose: true, looseID: "loose:sampling")
            ))
        }
        // Output: stop sequences, output format, random seed and other "what the model writes and where it stops" items share one card.
        let contract = remaining.filter { ($0.group ?? "") == "output_contract" }.compactMap(\.id)
        let output = remaining.filter { ["budget", "reproducibility"].contains($0.group ?? "") }.compactMap(\.id)
        remaining.removeAll { ["budget", "reproducibility", "output_contract"].contains($0.group ?? "") }
        var outputItems = output.map(Item.parameter)
        if contract.count > 1 {
            outputItems.append(.cluster(.init(
                id: "group:output_contract", title: compactGroupTitle("output_contract"), subtitle: nil,
                headID: nil, memberIDs: contract
            )))
        } else {
            outputItems.append(contentsOf: contract.map(Item.parameter))
        }
        if !outputItems.isEmpty {
            sections.append(.init(id: "output", title: L10n.tr("Output", table: .chat), items: outputItems))
        }
        let runtime = remaining.compactMap(\.id)
        if !runtime.isEmpty {
            sections.append(.init(
                id: "engine_runtime", title: L10n.tr("Engine Runtime"), items: runtime.map(Item.parameter)
            ))
        }
        return sections
    }

    static func compactGroupTitle(_ group: String) -> String {
        switch group {
        case "budget": return L10n.tr("Output Budget")
        case "reasoning": return L10n.tr("Reasoning")
        case "sampling": return L10n.tr("Sampling")
        case "repetition": return L10n.tr("Repetition Control")
        case "reproducibility": return L10n.tr("Reproducibility")
        case "output_contract": return L10n.tr("Output Contract")
        default: return L10n.tr("Engine Runtime")
        }
    }

    /// The summary on the right of a cluster row. `emphasized` means it holds a value changed in this layer.
    static func summary(
        of cluster: Cluster, rows: [String: AdvancedParameterRow]
    ) -> (text: String, emphasized: Bool) {
        let members = cluster.memberIDs.compactMap { rows[$0] }
        let adjusted = members.filter { $0.standing != .unset && !$0.isOmitted && $0.model.displayValue != nil }
        let emphasized = adjusted.contains { $0.standing == .editedHere }
        if let headID = cluster.headID, let head = rows[headID], adjusted.contains(where: { $0.id == headID }) {
            return (head.model.displayValue ?? "", emphasized)
        }
        switch adjusted.count {
        case 0:
            if cluster.headID != nil { return (L10n.tr("Off", table: .chat), false) }
            if members.count == 1, let only = members.first { return (only.trailingText, false) }
            if cluster.id == "group:output_contract" { return (L10n.tr("Plain text", table: .chat), false) }
            return (L10n.tr("Not adjusted", table: .chat), false)
        case 1:
            let row = adjusted[0]
            return ("\(row.model.title) \(row.model.displayValue ?? "")", emphasized)
        default:
            return (String(format: L10n.tr("%lld adjusted", table: .chat), adjusted.count), emphasized)
        }
    }

    /// The note under the "Common" card: what a gray number is, and why a struck-through item is struck through. Nothing is said when neither occurs.
    static func commonFootnote(
        rows: [AdvancedParameterRow], commonIDs: [String], engineName: String?
    ) -> String? {
        let common = rows.filter { commonIDs.contains($0.id) }
        var sentences: [String] = []
        if let engineName, common.contains(where: { $0.standing == .unset && $0.engineDefaultText != nil }) {
            sentences.append(String(
                format: L10n.tr(
                    "Grey numbers are %@’s own defaults. They aren’t sent unless you change them.", table: .chat
                ),
                engineName
            ))
        }
        let superseded = common.filter { $0.model.supersededBy != nil }
        if let owner = superseded.first?.model.supersededBy {
            sentences.append(String(
                format: L10n.tr("Crossed-out settings are being handled by %@.", table: .chat), owner
            ))
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: "\n")
    }
}

// MARK: - Reset scope

/// Which layer "Reset" really clears. The copy and the cleared scope both follow from this one value, so they cannot disagree.
enum AdvancedSettingsResetScope: Equatable {
    /// Entered from the chat page: clears this conversation's override layer only.
    case conversation(UUID)
    /// Entered from the provider detail page: clears this model's defaults.
    case modelDefault

    init(conversationID: UUID?) {
        self = conversationID.map(Self.conversation) ?? .modelDefault
    }

    /// The layer this reset clears.
    var clearedLayer: GenerationParameterResolution.Layer {
        switch self {
        case .conversation: return .conversation
        case .modelDefault: return .connectionModel
        }
    }

    var confirmationTitle: String {
        switch self {
        case .conversation: return L10n.tr("Reset this conversation’s settings?", table: .chat)
        case .modelDefault: return L10n.tr("Reset this model’s defaults?", table: .chat)
        }
    }

    var confirmationMessage: String {
        switch self {
        case .conversation:
            return L10n.tr(
                "This clears only the parameters you changed in this conversation. Your model defaults and the additional request body stay as they are.",
                table: .chat
            )
        case .modelDefault:
            return L10n.tr(
                "This clears the default parameters you set for this model on this connection. Changes made inside individual conversations stay as they are.",
                table: .chat
            )
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .conversation: return L10n.tr("Reset this conversation’s changes", table: .chat)
        case .modelDefault: return L10n.tr("Reset model defaults", table: .chat)
        }
    }

    /// Performs the reset. Only the record of `clearedLayer` is deleted; other layers are not touched.
    func perform(
        store: GenerationParameterSettingsStore, providerID: UUID, modelID: String, profileFingerprint: String?
    ) {
        switch self {
        case .conversation(let conversationID):
            store.setSessionOverrides(
                nil, providerID: providerID, modelID: modelID, conversationID: conversationID,
                profileFingerprint: profileFingerprint
            )
        case .modelDefault:
            store.setModelDefaults(
                nil, providerID: providerID, modelID: modelID, profileFingerprint: profileFingerprint
            )
        }
    }
}

// MARK: - Applying a preset

/// Applying a preset overwrites everything: every value set in the current layer is replaced by the preset's. The confirmation has to say which ones.
enum GenerationParameterPresetApplication {
    /// Parameter ids in the current layer that will be overwritten (sorted by id, the same order on every platform).
    static func overwrittenParameterIDs(current: GenerationParameterOverrides) -> [String] {
        current.values.filter { $0.value.state != .inherit }.keys.sorted()
    }

    /// With nothing set there is nothing to overwrite and no need to interrupt.
    static func needsConfirmation(current: GenerationParameterOverrides) -> Bool {
        !overwrittenParameterIDs(current: current).isEmpty
    }

    static func confirmationMessage(presetName: String, overwrittenTitles: [String]) -> String {
        String(
            format: L10n.tr(
                "“%1$@” replaces everything you’ve set for this model: %2$@.", table: .providers
            ),
            presetName,
            ListFormatter.localizedString(byJoining: overwrittenTitles)
        )
    }
}

// MARK: - Labels under the slider

/// The label line under the slider: the numbers at both ends, the midpoint (when it is an integer), the "model default" tick and its label.
/// Which of them would overlap is computed here; the view only places them.
enum AdvancedSliderScale {
    struct Label: Equatable {
        enum Kind: Hashable { case lowerBound, upperBound, midpoint, modelDefault }
        let kind: Kind
        let text: String
        /// The x position of the text's left edge.
        let minX: CGFloat
        let width: CGFloat
        var maxX: CGFloat { minX + width }
    }

    struct Marks: Equatable {
        /// The x position of the "model default" tick; nil without a model default or when it is outside the track.
        let defaultTickX: CGFloat?
        let labels: [Label]
    }

    /// - Parameters:
    ///   - width: the width of the whole line.
    ///   - inset: half a thumb width the system slider keeps at each end; the track lies within.
    ///   - textWidth: measures the width of a piece of text.
    static func marks(
        range: ClosedRange<Double>,
        modelDefault: Double?,
        defaultLabel: String,
        width: CGFloat,
        inset: CGFloat = 14,
        spacing: CGFloat = 6,
        textWidth: (String) -> CGFloat
    ) -> Marks {
        let track = max(0, width - inset * 2)
        let span = range.upperBound - range.lowerBound
        func position(_ value: Double) -> CGFloat { inset + track * CGFloat((value - range.lowerBound) / span) }
        func overlaps(_ a: Label, _ b: Label) -> Bool { a.minX < b.maxX + spacing && b.minX < a.maxX + spacing }

        let lowerText = GenerationParameterValueText.number(range.lowerBound)
        let upperText = GenerationParameterValueText.number(range.upperBound)
        let upperWidth = textWidth(upperText)
        let lower = Label(kind: .lowerBound, text: lowerText, minX: 0, width: textWidth(lowerText))
        let upper = Label(kind: .upperBound, text: upperText, minX: max(0, width - upperWidth), width: upperWidth)
        var labels = [lower, upper]

        var tickX: CGFloat?
        if let modelDefault, span > 0, range.contains(modelDefault) {
            let x = position(modelDefault)
            tickX = x
            let text = "\(defaultLabel) \(GenerationParameterValueText.number(modelDefault))"
            let labelWidth = textWidth(text)
            // The label hangs slightly left under the tick, within the left and right bounds.
            let minX = min(max(0, x - labelWidth * 0.3), max(0, width - labelWidth))
            let label = Label(kind: .modelDefault, text: text, minX: minX, width: labelWidth)
            // When the tick is close to an end and its label would overlap the end's number, only the tick stays.
            if !overlaps(label, lower), !overlaps(label, upper) { labels.append(label) }
        }

        let middle = (range.lowerBound + range.upperBound) / 2
        if span > 0, middle.rounded() == middle {
            let text = GenerationParameterValueText.number(middle)
            let labelWidth = textWidth(text)
            let label = Label(kind: .midpoint, text: text, minX: position(middle) - labelWidth / 2, width: labelWidth)
            // The midpoint gives way to the "model default" label.
            if !labels.contains(where: { overlaps(label, $0) }) { labels.append(label) }
        }
        return Marks(defaultTickX: tickX, labels: labels)
    }
}
