import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Rows and groups of the advanced settings page. Row data comes only from the evaluation of real storage and the outbound criteria,
/// so the main cases here go from a real `GenerationParameterSettingsStore` to the row model.
@Suite("Advanced settings: row model and groups")
@MainActor
struct AdvancedSettingsModelTests {
    private static let providerID = UUID()
    private static let conversationID = UUID()
    private static let modelID = "sample-model"

    private static func makeStore() -> (GenerationParameterSettingsStore, UserDefaults, String) {
        let suite = "advanced-settings-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (GenerationParameterSettingsStore(defaults: defaults), defaults, suite)
    }

    private static func parameter(
        _ id: String, _ schema: String = "number", group: String = "sampling",
        range: GenerationParameterRange? = nil, conflictsWith: [String]? = nil,
        requires: [[String: GenerationParameterValue]]? = nil,
        defaultValue: GenerationParameterValue? = nil,
        constraints: [[String: GenerationParameterValue]]? = nil
    ) -> GenerationParameterRef {
        GenerationParameterRef(
            id: id, support: "supported", source: "authoritative_metadata", group: group,
            valueSchema: schema, range: range, defaultDescription: defaultValue,
            conflictsWith: conflictsWith, requires: requires, constraints: constraints
        )
    }

    private static func profile(
        _ parameters: [GenerationParameterRef], template: String = "openai_chat_completions",
        wire: [String: String]? = nil
    ) -> GenerationProfileRef {
        let ids = parameters.compactMap(\.id)
        return GenerationProfileRef(
            template: template, parameters: parameters,
            wire: wire ?? Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) }), transport: template
        )
    }

    private static func value(_ number: Double) -> GenerationParameterOverride {
        .init(state: .value, value: .number(number))
    }

    /// Real storage → `resolveWithSources` → rows.
    private static func rows(
        _ profile: GenerationProfileRef, store: GenerationParameterSettingsStore,
        thinking: GenerationParameterRowModel.ThinkingContext? = nil
    ) -> [String: AdvancedParameterRow] {
        let catalog = AdvancedSettingsCatalog.fixture(profile: profile)
        let layer = store.sessionOverrides(
            providerID: providerID, modelID: modelID, conversationID: conversationID
        ) ?? .init()
        let rows = catalog.rows(
            store: store, providerID: providerID, modelID: modelID, conversationID: conversationID,
            layerValues: layer, profileFingerprint: nil, activeThinking: thinking
        )
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    // MARK: - The three sources (production evaluation path)

    @Test("changed in this conversation / inherited from the model default / decided by the model: each source matches the real evaluation")
    func sourcesComeFromTheRealResolution() throws {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Self.profile([
            Self.parameter("max_output_tokens", "integer", group: "budget", range: .init(min: 1, max: 8192)),
            Self.parameter("temperature", range: .init(min: 0, max: 2)),
            Self.parameter("top_p", range: .init(min: 0, max: 1)),
        ])
        store.setModelDefaults(
            .init(values: ["temperature": Self.value(0.2)]), providerID: Self.providerID, modelID: Self.modelID
        )
        store.setSessionOverrides(
            .init(values: ["max_output_tokens": Self.value(4096)]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )

        // The row model has to agree with the store's own evaluation item by item: neither value nor source is computed again here.
        let resolution = store.resolveWithSources(
            transient: nil, providerID: Self.providerID, modelID: Self.modelID,
            conversationID: Self.conversationID
        )
        let rows = Self.rows(profile, store: store)
        for id in ["max_output_tokens", "temperature", "top_p"] {
            #expect(rows[id]?.model.source == resolution.source(for: id), "the source of \(id) differs from the evaluation")
        }

        let maxTokens = try #require(rows["max_output_tokens"])
        #expect(maxTokens.model.source == .conversation)
        #expect(maxTokens.model.displayValue == "4096")
        #expect(maxTokens.standing == .editedHere)
        #expect(maxTokens.model.isSentConversationOverride)
        #expect(maxTokens.model.allowedRangeText == "1 – 8192")

        let temperature = try #require(rows["temperature"])
        #expect(temperature.model.source == .modelDefault)
        #expect(temperature.model.displayValue == "0.2")
        #expect(temperature.standing == .inherited)
        #expect(!temperature.model.isSentConversationOverride)

        let topP = try #require(rows["top_p"])
        #expect(topP.model.source == .providerDecides)
        #expect(topP.model.displayValue == nil)
        #expect(topP.standing == .unset)
        #expect(topP.trailingText == L10n.tr("Model default"))

        // After the temperature is changed in the conversation, the model default remains as the tick and the fallback value.
        store.setSessionOverrides(
            .init(values: ["max_output_tokens": Self.value(4096), "temperature": Self.value(0.7)]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        let edited = try #require(Self.rows(profile, store: store)["temperature"])
        #expect(edited.model.source == .conversation)
        #expect(edited.model.displayValue == "0.7")
        #expect(edited.fallbackValue == .number(0.2))

        // The summary on the model options page reads the same rows.
        let summary = GenerationParameterRowModel.summary(
            profile.parameters!.compactMap { Self.rows(profile, store: store)[$0.id!]?.model }
        )
        #expect(summary.chips.count == 2)
        #expect(summary.moreCount == 0)
    }

    @Test("a local engine's default shows as a gray number, and the source is still decided by the model")
    func engineDefaultsStayProviderDecided() throws {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Self.profile([Self.parameter("top_k", "integer", defaultValue: .number(40))])
        let row = try #require(Self.rows(profile, store: store)["top_k"])
        #expect(row.model.source == .providerDecides)
        #expect(row.model.displayValue == "40")
        #expect(row.engineDefaultText == "40")
        #expect(!row.model.isSentConversationOverride)
    }

    @Test("do-not-send does not count as a value that will be sent")
    func omittedValuesAreNotSent() throws {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Self.profile([Self.parameter("temperature")])
        store.setSessionOverrides(
            .init(values: ["temperature": .init(state: .omit)]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        let row = try #require(Self.rows(profile, store: store)["temperature"])
        #expect(row.isOmitted)
        #expect(row.model.displayValue == nil)
        #expect(!row.model.isSentConversationOverride)
        #expect(row.trailingText == L10n.tr("Omit"))
    }

    // MARK: - Out of range and type

    @Test("an out-of-range value is kept as is, the allowed range is stated on the spot, and the item is judged not sent")
    func outOfRangeIsFlaggedNotClamped() throws {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Self.profile([
            Self.parameter("max_output_tokens", "integer", group: "budget", range: .init(min: 1, max: 8192)),
            Self.parameter("temperature", range: .init(min: 0, max: 2)),
        ])
        store.setSessionOverrides(
            .init(values: ["max_output_tokens": Self.value(90_000), "temperature": Self.value(0.7)]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        let rows = Self.rows(profile, store: store)
        let maxTokens = try #require(rows["max_output_tokens"])
        // No clamping, no rounding: what is shown is still the number the user wrote.
        #expect(maxTokens.model.displayValue == "90000")
        #expect(maxTokens.model.dropReason == .invalidValue)
        let error = try #require(maxTokens.model.validationError)
        #expect(error.contains("8192"))
        #expect(!maxTokens.model.isSentConversationOverride)
        // Other settings are unaffected.
        let temperature = try #require(rows["temperature"])
        #expect(temperature.model.dropReason == nil)
        #expect(temperature.model.validationError == nil)
        #expect(temperature.model.isSentConversationOverride)
    }

    @Test("input validation and the outbound criterion are the same rule: when one reports a problem, the other never lets it through")
    func validationAgreesWithTheOutboundRule() {
        let cases: [(GenerationParameterRef, GenerationParameterValue, GenerationParameterInputValidation.Issue?)] = [
            (Self.parameter("a", "integer", range: .init(min: 1, max: 10)), .number(10), nil),
            (Self.parameter("a", "integer", range: .init(min: 1, max: 10)), .number(11), .aboveMaximum(10)),
            (Self.parameter("a", "integer", range: .init(min: 1, max: 10)), .number(0), .belowMinimum(1)),
            (Self.parameter("a", "integer"), .number(1.5), .notAnInteger),
            (Self.parameter("a", "number", range: .init(minExclusive: 0)), .number(0), .notAbove(0)),
            (Self.parameter("a", "number", range: .init(maxExclusive: 1)), .number(1), .notBelow(1)),
            (Self.parameter("a", "number"), .string("abc"), .notANumber),
            (Self.parameter("a", "number"), .number(.infinity), .notANumber),
            (Self.parameter("a", "json-schema"), .string("x"), .invalidSchema),
            (Self.parameter("a", "boolean"), .string("x"), .notAccepted),
            (Self.parameter("a", "number"), .number(-3.5), nil),
        ]
        for (parameter, value, expected) in cases {
            let issue = GenerationParameterInputValidation.issue(value: value, parameter: parameter)
            #expect(issue == expected, "\(value) against \(parameter.valueSchema ?? "")")
            #expect((issue == nil) == ProfileParamsResolver.isValidGenerationValue(value, for: parameter))
            if let issue {
                #expect(!GenerationParameterInputValidation.message(issue, parameterID: "a").isEmpty)
            }
        }
    }

    @Test("number drafts: what is not a number is reported on the spot, empty is not an error, comma and decimal mark are parsed by locale")
    func numericDraftValidation() {
        let parameter = Self.parameter("temperature", range: .init(min: 0, max: 2))
        let en = Locale(identifier: "en_US")
        #expect(GenerationParameterInputValidation.issue(numericDraft: "", parameter: parameter, locale: en) == nil)
        #expect(GenerationParameterInputValidation.issue(numericDraft: "0.7", parameter: parameter, locale: en) == nil)
        #expect(GenerationParameterInputValidation.issue(numericDraft: "abc", parameter: parameter, locale: en) == .notANumber)
        #expect(GenerationParameterInputValidation.issue(numericDraft: "3", parameter: parameter, locale: en) == .aboveMaximum(2))
        #expect(GenerationParameterInputValidation.issue(
            numericDraft: "0,7", parameter: parameter, locale: Locale(identifier: "de_DE")
        ) == nil)
        // The out-of-range copy for max tokens carries the model's limit.
        let message = GenerationParameterInputValidation.message(.aboveMaximum(8192), parameterID: "max_output_tokens")
        #expect(message == String(
            format: L10n.tr(
                "This model can write at most %@. This setting won’t be sent until it’s fixed; your other settings aren’t affected.",
                table: .chat
            ),
            "8192"
        ))
    }

    // MARK: - The six drop reasons

    @Test("two conflicting items: the one later in declaration order is marked with the reason and the other's name")
    func conflictIsExplainedOnTheLosingRow() throws {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Self.profile([
            Self.parameter("temperature", conflictsWith: ["top_p"]),
            Self.parameter("top_p", conflictsWith: ["temperature"]),
        ])
        // One item in the model default, one in this conversation: the editor's same-layer exclusion cannot remove it, so the note on the row is all there is.
        store.setModelDefaults(
            .init(values: ["temperature": Self.value(0.5)]), providerID: Self.providerID, modelID: Self.modelID
        )
        store.setSessionOverrides(
            .init(values: ["top_p": Self.value(0.9)]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        let rows = Self.rows(profile, store: store)
        let loser = try #require(rows["top_p"])
        #expect(loser.model.dropReason == .conflict)
        #expect(loser.conflictPartner == GenerationParameterVocabulary.title("temperature"))
        #expect(loser.notice?.text.contains(GenerationParameterVocabulary.title("temperature")) == true)
        #expect(rows["temperature"]?.model.dropReason == nil)
    }

    @Test("an item whose prerequisite is unmet is dropped alone and names the item to set first")
    func unmetRequirementIsExplained() throws {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Self.profile([
            Self.parameter("logprobs", "boolean", group: "output_contract"),
            Self.parameter(
                "top_logprobs", "integer", group: "output_contract",
                requires: [["key": .string("logprobs"), "value": .boolean(true)]]
            ),
        ])
        store.setSessionOverrides(
            .init(values: ["top_logprobs": Self.value(3)]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        let row = try #require(Self.rows(profile, store: store)["top_logprobs"])
        #expect(row.model.dropReason == .requirementUnmet)
        #expect(row.requirementPartner == GenerationParameterVocabulary.title("logprobs"))
        #expect(!row.model.isSentConversationOverride)
    }

    @Test("a field the upstream requires cannot be removed by do-not-send, and the row says the default is still sent")
    func requiredFieldCannotBeOmitted() throws {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Self.profile(
            [Self.parameter("max_output_tokens", "integer", group: "budget")],
            template: "anthropic_messages", wire: ["max_output_tokens": "max_tokens"]
        )
        store.setSessionOverrides(
            .init(values: ["max_output_tokens": .init(state: .omit)]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        let row = try #require(Self.rows(profile, store: store)["max_output_tokens"])
        #expect(row.model.dropReason == .requiredField)
        // The required list is the one the outbound path uses, not a copy made here.
        #expect(ProfileParamsResolver.requiredWireFields["anthropic_messages"]?.contains("max_tokens") == true)
    }

    @Test("with thinking on: temperature and Top K are not sent, a Top P that is too low is not sent, and max tokens below the budget falls back to the default")
    func thinkingGuardIsPredictedPerRow() throws {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Self.profile(
            [
                Self.parameter("max_output_tokens", "integer", group: "budget"),
                Self.parameter("temperature"),
                Self.parameter("top_p"),
                Self.parameter("top_k", "integer"),
            ],
            template: "anthropic_messages",
            wire: ["max_output_tokens": "max_tokens", "temperature": "temperature", "top_p": "top_p", "top_k": "top_k"]
        )
        store.setSessionOverrides(
            .init(values: [
                "max_output_tokens": Self.value(1000), "temperature": Self.value(0.7),
                "top_p": Self.value(0.5), "top_k": Self.value(40),
            ]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        let off = Self.rows(profile, store: store)
        #expect(off.values.allSatisfy { $0.model.dropReason == nil }, "nothing should be predicted while thinking is off")

        let on = Self.rows(profile, store: store, thinking: .init(budgetTokens: 2000))
        #expect(on["temperature"]?.model.dropReason == .thinkingIncompatible)
        #expect(on["top_k"]?.model.dropReason == .thinkingIncompatible)
        #expect(on["top_p"]?.model.dropReason == .thinkingIncompatible)
        #expect(on["max_output_tokens"]?.model.dropReason == .thinkingBudget)

        // With a Top P high enough and max tokens large enough these two are sent as usual.
        store.setSessionOverrides(
            .init(values: ["max_output_tokens": Self.value(8000), "top_p": Self.value(0.98)]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        let roomy = Self.rows(profile, store: store, thinking: .init(budgetTokens: 2000))
        #expect(roomy["top_p"]?.model.dropReason == nil)
        #expect(roomy["max_output_tokens"]?.model.dropReason == nil)
    }

    @Test("each of the six drop reasons has a sentence of its own")
    func everyDropReasonHasItsOwnSentence() {
        var seen = Set<String>()
        for reason in GenerationParameterApplication.DropReason.allCases {
            let message = AdvancedParameterRow.message(for: reason)
            #expect(!message.isEmpty)
            #expect(seen.insert(message).inserted, "\(reason) says the same sentence as another reason")
        }
        #expect(seen.count == 6)
    }

    // MARK: - Takeover

    @Test("with Mirostat on, Top K / Top P are taken over; untouched while it is off")
    func mirostatSupersedesTopKAndTopP() throws {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = try #require(LocalEngineGenerationProfiles.profile(
            for: "llamacpp", transport: .openaiChatCompletions
        ))
        store.setSessionOverrides(
            .init(values: ["mirostat": Self.value(2), "top_k": Self.value(20)]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        let on = Self.rows(profile, store: store)
        #expect(on["top_k"]?.model.supersededBy == "Mirostat")
        #expect(on["top_p"]?.model.supersededBy == "Mirostat")
        #expect(on["min_p"]?.model.supersededBy == nil)
        // An item that is taken over does not count as a value in effect, even when changed in this conversation.
        #expect(on["top_k"]?.model.isSentConversationOverride == false)
        #expect(on["mirostat"]?.model.displayValue == "v2")

        store.setSessionOverrides(
            .init(values: ["mirostat": Self.value(0), "top_k": Self.value(20)]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        let off = Self.rows(profile, store: store)
        #expect(off["top_k"]?.model.supersededBy == nil)
        #expect(off["top_p"]?.model.supersededBy == nil)
        #expect(off["mirostat"]?.model.displayValue == L10n.tr("Off", table: .chat))
    }

    // MARK: - Groups follow the parameter table

    @Test("the long llama.cpp page: common, Mirostat, repetition, more sampling, output, each group derived from the parameter table")
    func llamaLayoutIsDrivenByTheParameterTable() throws {
        let profile = try #require(LocalEngineGenerationProfiles.profile(
            for: "llamacpp", transport: .openaiChatCompletions
        ))
        let parameters = profile.parameters ?? []
        let sections = AdvancedSettingsLayout.sections(parameters: parameters)
        #expect(sections.map(\.id) == ["common", "family:mirostat", "repetition", "sampling", "output"])

        #expect(sections[0].items == ["max_output_tokens", "temperature", "top_k", "top_p", "min_p"].map {
            AdvancedSettingsLayout.Item.parameter($0)
        })
        guard case let .mode(id, _, options) = sections[1].items[0] else {
            Issue.record("the first item of the Mirostat group should be the mode switch")
            return
        }
        #expect(id == "mirostat")
        #expect(options.map(\.value) == [0, 1, 2])
        #expect(sections[1].items.dropFirst().map(\.id) == ["p:mirostat_tau", "p:mirostat_eta"])

        // Every parameter appears exactly once: none missing, none placed twice.
        var placed: [String] = []
        for section in sections {
            for item in section.items {
                switch item {
                case .parameter(let id): placed.append(id)
                case .mode(let id, _, _): placed.append(id)
                case .cluster(let cluster): placed.append(contentsOf: cluster.memberIDs)
                }
            }
        }
        #expect(placed.sorted() == parameters.compactMap(\.id).sorted())

        let repetition = sections[2].items.compactMap { item -> AdvancedSettingsLayout.Cluster? in
            if case .cluster(let cluster) = item { return cluster }
            return nil
        }
        #expect(repetition.map(\.id) == ["family:repeat", "family:dry"])
        #expect(repetition[0].headID == "repeat_penalty")
        #expect(repetition[0].memberIDs.contains("frequency_penalty"))
    }

    @Test("other engines and cloud models are laid out by the same rules, losing no parameter")
    func otherTablesUseTheSameRules() throws {
        for engine in ["ollama", "lmstudio", "vllm", "openwebui"] {
            let profile = try #require(LocalEngineGenerationProfiles.profile(
                for: engine, transport: .openaiChatCompletions
            ))
            let parameters = profile.parameters ?? []
            let sections = AdvancedSettingsLayout.sections(parameters: parameters)
            var placed: [String] = []
            for item in sections.flatMap(\.items) {
                switch item {
                case .parameter(let id): placed.append(id)
                case .mode(let id, _, _): placed.append(id)
                case .cluster(let cluster): placed.append(contentsOf: cluster.memberIDs)
                }
            }
            #expect(placed.sorted() == parameters.compactMap(\.id).sorted(), "not every parameter of \(engine) was placed")
            #expect(sections.first?.id == "common", "\(engine) has no common group")
            // These two Ollama items do not appear in the interface (they are not in the parameter table to begin with).
            #expect(!placed.contains("num_ctx"))
            #expect(!placed.contains("keep_alive"))
        }

        // A table with few parameters uses one "More" card: a group with more than one parameter folds into one row, a group with one is just that row.
        let compact = AdvancedSettingsLayout.sections(parameters: [
            Self.parameter("max_output_tokens", "integer", group: "budget"),
            Self.parameter("temperature"),
            Self.parameter("frequency_penalty", group: "repetition"),
            Self.parameter("presence_penalty", group: "repetition"),
            Self.parameter("seed", "integer", group: "reproducibility"),
        ])
        #expect(compact.map(\.id) == ["common", "more"])
        #expect(compact[1].items.map(\.id) == ["c:group:repetition", "p:seed"])

        // With common parameters only, no group heading is rendered.
        let onlyCommon = AdvancedSettingsLayout.sections(parameters: [Self.parameter("temperature")])
        #expect(onlyCommon.count == 1)
        #expect(onlyCommon[0].title == nil)
    }

    @Test("cluster summary: nothing adjusted, one item adjusted, the family head has a value, several adjusted")
    func clusterSummary() throws {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = Self.profile([
            Self.parameter("frequency_penalty", group: "repetition"),
            Self.parameter("presence_penalty", group: "repetition"),
        ])
        let cluster = AdvancedSettingsLayout.Cluster(
            id: "group:repetition", title: "", subtitle: nil, headID: nil,
            memberIDs: ["frequency_penalty", "presence_penalty"]
        )
        var summary = AdvancedSettingsLayout.summary(of: cluster, rows: Self.rows(profile, store: store))
        #expect(summary.text == L10n.tr("Not adjusted", table: .chat))
        #expect(!summary.emphasized)

        store.setSessionOverrides(
            .init(values: ["frequency_penalty": Self.value(0.3)]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        summary = AdvancedSettingsLayout.summary(of: cluster, rows: Self.rows(profile, store: store))
        #expect(summary.text == "\(GenerationParameterVocabulary.title("frequency_penalty")) 0.3")
        #expect(summary.emphasized)

        store.setSessionOverrides(
            .init(values: ["frequency_penalty": Self.value(0.3), "presence_penalty": Self.value(0.1)]),
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        summary = AdvancedSettingsLayout.summary(of: cluster, rows: Self.rows(profile, store: store))
        #expect(summary.text == String(format: L10n.tr("%lld adjusted", table: .chat), 2))
    }

    // MARK: - Stop sequences

    @Test("one tag per stop sequence: commas, spaces and newlines are kept as is, with no splitting on commas")
    func stopSequencesAreNotSplit() {
        typealias Stops = GenerationParameterStopSequences
        #expect(Stops.adding(", ", to: [], limit: 4) == .added([", "]))
        #expect(Stops.adding("a,b", to: ["###"], limit: 4) == .added(["###", "a,b"]))
        #expect(Stops.adding("\n\n", to: ["###"], limit: 4) == .added(["###", "\n\n"]))
        #expect(Stops.adding(" ", to: [], limit: nil) == .added([" "]))
        #expect(Stops.adding("", to: [], limit: 4) == .empty)
        #expect(Stops.adding("###", to: ["###"], limit: 4) == .duplicate)
        #expect(Stops.adding("x", to: ["a", "b", "c", "d"], limit: 4) == .full)
        // Without a declared limit nothing is enforced on the device.
        #expect(Stops.adding("x", to: ["a", "b", "c", "d"], limit: nil) == .added(["a", "b", "c", "d", "x"]))

        #expect(Stops.visible("\n\n") == "↵↵")
        #expect(Stops.visible("a b\tc") == "a␣b⇥c")
        #expect(Stops.visible("###") == "###")
        #expect(Stops.hasInvisibleCharacters("\n"))
        #expect(!Stops.hasInvisibleCharacters("###"))

        #expect(Stops.limit(for: Self.parameter("stop", "string-list", constraints: [["maxItems": .number(4)]])) == 4)
        #expect(Stops.limit(for: Self.parameter("stop", "string-list")) == nil)
    }

    @Test("an edit lands on this layer: set a value, back to default, do not send; the other item of a same-layer exclusion is replaced")
    func editingAppliesToTheLayer() {
        let temperature = Self.parameter("temperature", conflictsWith: ["top_p"])
        let topP = Self.parameter("top_p")
        var values = GenerationParameterOverrides(values: ["top_p": Self.value(0.9)])
        values = AdvancedSettingsEditing.applying(
            .set(.number(0.7)), to: temperature, in: values, parameters: [temperature, topP]
        )
        #expect(values.values["temperature"] == Self.value(0.7))
        #expect(values.values["top_p"] == nil)
        values = AdvancedSettingsEditing.applying(.omit, to: temperature, in: values, parameters: [temperature, topP])
        #expect(values.values["temperature"]?.state == .omit)
        values = AdvancedSettingsEditing.applying(.useDefault, to: temperature, in: values, parameters: [temperature, topP])
        #expect(values.values.isEmpty)
    }

    // MARK: - Reset scope

    @Test("reset on the chat page only clears this conversation's override layer; model default, connection default and other conversations are untouched")
    func conversationResetClearsOnlyTheConversationLayer() {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let other = UUID()
        Self.seedAllLayers(store, otherConversation: other)

        let scope = AdvancedSettingsResetScope(conversationID: Self.conversationID)
        #expect(scope == .conversation(Self.conversationID))
        #expect(scope.clearedLayer == .conversation)
        scope.perform(store: store, providerID: Self.providerID, modelID: Self.modelID, profileFingerprint: nil)

        #expect(store.sessionOverrides(
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        ) == nil)
        #expect(store.modelDefaults(providerID: Self.providerID, modelID: Self.modelID) != nil)
        #expect(store.connectionDefaults(providerID: Self.providerID) != nil)
        #expect(store.sessionOverrides(providerID: Self.providerID, modelID: Self.modelID, conversationID: other) != nil)
        // The additional request body is outside the reset scope (the copy says it stays).
        #expect(store.additionalRequestBody(
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        ) != nil)
        // After clearing, the value in effect falls back to the model default.
        let resolution = store.resolveWithSources(
            transient: nil, providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        )
        #expect(resolution.entries["temperature"]?.layer == .connectionModel)
    }

    @Test("reset on the provider detail page clears the model default; changes inside conversations are untouched")
    func modelDefaultResetClearsOnlyTheModelDefaultLayer() {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let other = UUID()
        Self.seedAllLayers(store, otherConversation: other)

        let scope = AdvancedSettingsResetScope(conversationID: nil)
        #expect(scope == .modelDefault)
        #expect(scope.clearedLayer == .connectionModel)
        scope.perform(store: store, providerID: Self.providerID, modelID: Self.modelID, profileFingerprint: nil)

        #expect(store.modelDefaults(providerID: Self.providerID, modelID: Self.modelID) == nil)
        #expect(store.sessionOverrides(
            providerID: Self.providerID, modelID: Self.modelID, conversationID: Self.conversationID
        ) != nil)
        #expect(store.sessionOverrides(providerID: Self.providerID, modelID: Self.modelID, conversationID: other) != nil)
        #expect(store.connectionDefaults(providerID: Self.providerID) != nil)
    }

    @Test("the two resets each have their own title, body and button, and the scope they name is the layer that gets cleared")
    func resetCopyNamesTheLayerItClears() throws {
        let conversation = AdvancedSettingsResetScope.conversation(Self.conversationID)
        let modelDefault = AdvancedSettingsResetScope.modelDefault
        #expect(conversation.confirmationTitle != modelDefault.confirmationTitle)
        #expect(conversation.confirmationMessage != modelDefault.confirmationMessage)
        #expect(conversation.confirmButtonTitle != modelDefault.confirmButtonTitle)

        // The copy is pinned on the English source: the chat page says only this conversation's changes are cleared and the model default stays, the detail page says the model default is cleared.
        #expect(conversation.confirmationMessage == L10n.tr(
            "This clears only the parameters you changed in this conversation. Your model defaults and the additional request body stay as they are.",
            table: .chat
        ))
        #expect(modelDefault.confirmationMessage == L10n.tr(
            "This clears the default parameters you set for this model on this connection. Changes made inside individual conversations stay as they are.",
            table: .chat
        ))

        // Both pages' confirmation dialogs take copy and action from this one type instead of each keeping a copy.
        for file in [
            ["Features", "Chat", "ModelControls", "AdvancedSettingsPage.swift"],
            ["Features", "Providers", "GenerationParameterDefaultsSheet.swift"],
        ] {
            let source = try Self.source(file)
            #expect(source.contains("confirmationMessage"), "the confirmation copy in \(file.last!) does not come from the reset scope")
            #expect(source.contains(".perform(\n"), "the reset in \(file.last!) does not go through the reset scope's perform")
            #expect(
                !source.contains("This clears every value you set for this model."),
                "\(file.last!) still has the old confirmation sentence that names no scope"
            )
        }
    }

    private static func seedAllLayers(_ store: GenerationParameterSettingsStore, otherConversation: UUID) {
        store.setConnectionDefaults(.init(values: ["top_p": value(0.9)]), providerID: providerID)
        store.setModelDefaults(.init(values: ["temperature": value(0.2)]), providerID: providerID, modelID: modelID)
        store.setSessionOverrides(
            .init(values: ["temperature": value(0.7)]),
            providerID: providerID, modelID: modelID, conversationID: conversationID
        )
        store.setSessionOverrides(
            .init(values: ["temperature": value(1.1)]),
            providerID: providerID, modelID: modelID, conversationID: otherConversation
        )
        store.setAdditionalRequestBody(
            .init(rawJSON: "{\"cache_prompt\":true}", sendsWithRequest: true),
            providerID: providerID, modelID: modelID, conversationID: conversationID
        )
    }

    // MARK: - Confirmation before applying a preset

    @Test("applying a preset: with current values it confirms first and lists what will be overwritten; with none it does not interrupt")
    func presetApplicationNeedsConfirmationOnlyWhenItOverwrites() throws {
        typealias Application = GenerationParameterPresetApplication
        #expect(!Application.needsConfirmation(current: .init()))
        #expect(!Application.needsConfirmation(current: .init(values: ["temperature": .init(state: .inherit)])))
        let current = GenerationParameterOverrides(values: [
            "top_p": Self.value(0.9), "temperature": .init(state: .omit),
        ])
        #expect(Application.needsConfirmation(current: current))
        #expect(Application.overwrittenParameterIDs(current: current) == ["temperature", "top_p"])
        let message = Application.confirmationMessage(presetName: "Careful", overwrittenTitles: ["Temperature", "Top P"])
        #expect(message.contains("Careful"))
        #expect(message.contains("Temperature"))

        // Tapping a preset name no longer writes values directly: it goes through the confirmation, and apply is called only after confirming.
        let source = try Self.source(["Features", "Providers", "GenerationParameterDefaultsSheet.swift"])
        let tap = try #require(source.components(separatedBy: "Button(preset.name) {").dropFirst().first)
        let tapBody = try #require(tap.components(separatedBy: "Spacer()").first)
        #expect(tapBody.contains("needsConfirmation(current: values)"))
        #expect(tapBody.contains("pendingPresetApplication = preset"))
        #expect(!tapBody.contains("GenerationParameterPresetStore.shared.apply("))
    }

    // MARK: - Saved on this device only

    @Test("only values that do not sync are labeled as saved on this device only: the additional request body is, generation parameters are not")
    func deviceOnlyLabelMatchesWhatActuallySyncs() throws {
        let (store, defaults, suite) = Self.makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let presetSuite = "advanced-settings-presets-\(UUID().uuidString)"
        let presetDefaults = UserDefaults(suiteName: presetSuite)!
        defer { presetDefaults.removePersistentDomain(forName: presetSuite) }
        Self.seedAllLayers(store, otherConversation: UUID())

        // Generation parameters (including the conversation override layer) are in the sync envelope; the additional request body is not.
        let payload = GenerationParameterSyncContract.exportPayload(
            settings: store, presets: GenerationParameterPresetStore(defaults: presetDefaults), defaults: defaults
        )
        let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        #expect(encoded.contains("temperature"))
        #expect(!encoded.contains("cache_prompt"))

        let page = try Self.source(["Features", "Chat", "ModelControls", "AdvancedSettingsPage.swift"])
        let editor = try Self.source(["Features", "Chat", "ModelControls", "AdditionalRequestBodyPage.swift"])
        let sheet = try Self.source(["Features", "Providers", "GenerationParameterDefaultsSheet.swift"])
        // Both the entry row and the editor carry the label.
        #expect(page.contains("L10n.tr(\"Saved on this device only, not synced\", table: .chat)"))
        #expect(editor.contains("L10n.tr(\"Saved on this device only, not synced\", table: .chat)"))
        // Provider detail page: the additional request body entry is labeled; presets and parameters, which sync, are not.
        #expect(sheet.components(separatedBy: "L10n.tr(\"Saved on this device only, not synced\", table: .chat)").count == 2)
        let presets = try #require(
            sheet.components(separatedBy: "Section(L10n.tr(\"Presets\", table: .providers))").dropFirst().first?
                .components(separatedBy: "Section(L10n.tr(\"Connection\", table: .providers))").first
        )
        #expect(!presets.contains("Saved on this device only"))
    }

    @Test("the two pages share one row rendering, and the provider detail page has no copy of its own")
    func bothSurfacesShareOneRowRenderer() throws {
        let sheet = try Self.source(["Features", "Providers", "GenerationParameterDefaultsSheet.swift"])
        let page = try Self.source(["Features", "Chat", "ModelControls", "AdvancedSettingsPage.swift"])
        for source in [sheet, page] {
            #expect(source.contains("AdvancedSettingsSectionBody("))
            #expect(source.contains("AdvancedSettingsLayout.sections(parameters:"))
        }
        #expect(!sheet.contains("private func parameterRow("), "the provider detail page draws its own parameter row again")
        #expect(!sheet.contains("embeddedEditor"), "the chat page presentation is back in the provider detail page's file")
        // The type and initializer signature of the chat page's entry are unchanged; inside it forwards to the new page.
        #expect(sheet.contains("if presentation == .embeddedPage {\n            AdvancedSettingsPage("))
    }

    private static func source(_ components: [String]) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = (["Oriveo"] + components).reduce(root) { $0.appendingPathComponent($1) }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// The prediction of the thinking interplay reads the send path's own writer (it loads the runtime catalog, hence a separate, serialized suite).
@Suite("Advanced settings: the thinking interplay comes from the send path's own source", .serialized)
@MainActor
struct AdvancedSettingsThinkingProbeTests {
    private static let modelID = "claude-sonnet-4-5"
    private static let recipeRef = "anthropic.messages.reasoning.v1"

    @Test("official Anthropic: once a thinking level is written to the real store, the budget comes from the recipe and the temperature and max tokens rows state the reason")
    func thinkingStateComesFromTheRecipeCompiler() async throws {
        await MetadataClient.shared.resetForTesting()
        let runtime = try CapabilityRuntimeFixtures.runtimeEnvelopeJSON()
        let controls = try CapabilityRuntimeFixtures.controlsJSON(.init(
            capability: "reasoning",
            recipeRef: Self.recipeRef,
            availableIntents: try CapabilityRuntimeFixtures.reasoningIntents(ofRecipe: Self.recipeRef)
        ))
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-10-06T00:00:00Z",
          "capabilityRuntime": \(runtime),
          "providers": {
            "anthropic": {
              "transport": { "baseUrl": "https://api.anthropic.com/v1", "endpoints": { "chat": "/messages" } },
              "resolveMap": { "\(Self.modelID)": "\(Self.modelID)" },
              "models": {
                "\(Self.modelID)": {
                  "canonicalModelId": "\(Self.modelID)",
                  "capabilities": ["text", "reasoning"],
                  "transport": "anthropic_messages",
                  "maxOutputTokens": 64000,
                  "capabilityControls": \(controls)
                }
              }
            }
          }
        }
        """)

        let suite = "advanced-settings-thinking-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let model = AIModel(
            id: Self.modelID, name: Self.modelID, capabilities: [.text, .reasoning],
            reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: "",
            summary: nil, groupKey: nil, groupName: nil
        )
        let provider = Provider(
            id: UUID(), kind: .anthropic, status: .connected, models: [model], catalogModels: [model],
            lastCheckedAt: nil, apiKey: "", apiKeyPreview: "", lastError: nil, baseURLText: nil
        )
        let conversation = UUID()
        let identity = try #require(CapabilityPreferenceRuntimeIdentity.make(provider: provider, model: model))
        let profile = GenerationProfileRef(
            template: "anthropic_messages",
            parameters: [
                GenerationParameterRef(id: "max_output_tokens", support: "supported", group: "budget", valueSchema: "integer"),
                GenerationParameterRef(id: "temperature", support: "supported", group: "sampling", valueSchema: "number"),
                GenerationParameterRef(id: "top_p", support: "supported", group: "sampling", valueSchema: "number"),
            ],
            wire: ["max_output_tokens": "max_tokens", "temperature": "temperature", "top_p": "top_p"],
            transport: "anthropic_messages"
        )
        func probe() -> GenerationParameterRowModel.ThinkingContext? {
            AdvancedSettingsThinkingProbe.activeThinking(
                provider: provider, model: model, conversationID: conversation, profile: profile, store: store
            )
        }

        // No level set: thinking is off and nothing is predicted.
        #expect(probe() == nil)

        store.setCapabilityPreferences(
            .init(web: .inherit, reasoningIntent: "deep"),
            providerID: provider.id, modelID: identity.canonicalModelID, conversationID: conversation,
            transportIdentity: identity.wireValue
        )
        let thinking = try #require(probe(), "the level is stored in the conversation, yet the prediction says thinking is off")
        // The budget is not a number written by the test: it comes from the recipe for this level in the registry.
        let recipeThinking = try #require(try CapabilityRuntimeFixtures.recipeValue(
            recipeRef: Self.recipeRef, intent: "deep", pointer: "/thinking"
        ) as? [String: Any])
        let recipeBudget = try #require((recipeThinking["budget_tokens"] as? NSNumber)?.intValue)
        #expect(thinking.budgetTokens == recipeBudget)

        // The real store's evaluation plus the thinking fact above → rows.
        store.setSessionOverrides(
            .init(values: [
                "temperature": .init(state: .value, value: .number(0.7)),
                "top_p": .init(state: .value, value: .number(0.99)),
                "max_output_tokens": .init(state: .value, value: .number(Double(recipeBudget))),
            ]),
            providerID: provider.id, modelID: Self.modelID, conversationID: conversation
        )
        let rows = AdvancedSettingsCatalog.fixture(profile: profile).rows(
            store: store, providerID: provider.id, modelID: Self.modelID, conversationID: conversation,
            layerValues: store.sessionOverrides(
                providerID: provider.id, modelID: Self.modelID, conversationID: conversation
            ) ?? .init(),
            profileFingerprint: nil, activeThinking: thinking
        )
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID["temperature"]?.model.dropReason == .thinkingIncompatible)
        #expect(byID["top_p"]?.model.dropReason == nil, "a Top P that is high enough was marked by mistake")
        #expect(byID["max_output_tokens"]?.model.dropReason == .thinkingBudget)

        // Nothing is predicted once thinking is off again.
        store.setCapabilityPreferences(
            .init(web: .inherit, reasoningIntent: "off"),
            providerID: provider.id, modelID: identity.canonicalModelID, conversationID: conversation,
            transportIdentity: identity.wireValue
        )
        #expect(probe() == nil)

        // Not marked: a relay connection without a protocol field (a relay's Anthropic-compatible endpoint has its own full send-chain case), and non-Anthropic templates.
        var relay = provider
        relay.kind = .relay
        #expect(AdvancedSettingsThinkingProbe.activeThinking(
            provider: relay, model: model, conversationID: conversation, profile: profile, store: store
        ) == nil)
        var chat = profile
        chat.template = "openai_chat_completions"
        #expect(AdvancedSettingsThinkingProbe.activeThinking(
            provider: provider, model: model, conversationID: conversation, profile: chat, store: store
        ) == nil)

        await MetadataClient.shared.resetForTesting()
    }

    @Test("thinking-is-on uses the same list as the outbound guard; adaptive thinking has no fixed budget")
    func activeTypesMatchTheOutboundGuard() {
        typealias Probe = AdvancedSettingsThinkingProbe
        #expect(Probe.context(fromRequestFields: [:]) == nil)
        #expect(Probe.context(fromRequestFields: ["thinking": ["type": "disabled"]]) == nil)
        #expect(Probe.context(fromRequestFields: ["thinking": ["type": "enabled", "budget_tokens": 2048]])
            == .init(budgetTokens: 2048))
        #expect(Probe.context(fromRequestFields: ["thinking": ["type": "adaptive"]]) == .init(budgetTokens: nil))
        for type in ProfileParamsResolver.anthropicThinkingActiveTypes {
            #expect(Probe.context(fromRequestFields: ["thinking": ["type": type]]) != nil)
        }
    }
}

@Suite("Advanced settings: swipe back inside the sheet, and the single channel for custom generation content")
@MainActor
struct AdvancedSettingsNavigationTests {
    @Test("while the page is visible it takes over the pop gesture's delegate: allowed only with more than one page on the stack; restored on leaving")
    func interactivePopIsRestoredWhileThePageIsVisible() throws {
        let root = UIViewController()
        let page = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        navigation.pushViewController(page, animated: false)
        let gesture = try #require(navigation.interactivePopGestureRecognizer)
        let original = gesture.delegate

        let enabler = SheetInteractivePopEnabler.Controller()
        page.addChild(enabler)
        enabler.didMove(toParent: page)
        defer { SwipeBackCoordinator.shared.isBackSwipeEnabled = true }

        enabler.bind()
        #expect(gesture.delegate === enabler)
        #expect(gesture.isEnabled)
        #expect(enabler.gestureRecognizerShouldBegin(gesture), "a swipe should pop on a stack of two pages")
        // The edge swipe of the navigation stack underneath has to be off right now, or one swipe would pop two layers.
        #expect(!SwipeBackCoordinator.shared.isBackSwipeEnabled)

        navigation.setViewControllers([page], animated: false)
        #expect(!enabler.gestureRecognizerShouldBegin(gesture), "the root page has nowhere to go back to")

        enabler.unbind()
        #expect(gesture.delegate === original)
        #expect(SwipeBackCoordinator.shared.isBackSwipeEnabled)
        #expect(!enabler.gestureRecognizerShouldBegin(gesture))

        // All three pages with a self-drawn header attach it.
        for name in ["AdvancedSettingsPage.swift", "AdditionalRequestBodyPage.swift", "CustomRequestFieldsPage.swift"] {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Oriveo/Features/Chat/ModelControls/\(name)")
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(source.contains(".background(SheetInteractivePopEnabler())"), "\(name) hides the back button without keeping the swipe back")
        }
    }

    @Test("custom generation content only goes through the additional request body: no fragment is built for it on the device, and existing old records are not sent")
    func generationCustomContentOnlyTravelsAsAdditionalRequestBody() throws {
        #expect(GenerationParameterSettingsStore.localCustomOwnerNamespaces.map(\.owner) == ["web", "reasoning"])

        let suite = "advanced-settings-generation-owner-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let providerID = UUID()
        // The old generation namespace is not even accepted by the write entry; and if such content exists, the send path does not carry it out as a fragment.
        store.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: "{\"temperature\":0.1}"),
            providerID: providerID, modelID: "m", conversationID: nil,
            transportIdentity: "openai_chat_completions",
            namespace: GenerationParameterSettingsStore.retiredGenerationCustomNamespace
        )
        store.setLocalCustomConfiguration(
            .init(mode: .custom, rawJSON: "{\"reasoning\":{\"effort\":\"low\"}}"),
            providerID: providerID, modelID: "m", conversationID: nil,
            transportIdentity: "openai_chat_completions", namespace: "reasoningPatch"
        )
        let owners = store.activeLocalCustomFragments(
            providerID: providerID, modelID: "m", conversationID: nil,
            transportIdentity: "openai_chat_completions"
        ).map(\.owner)
        #expect(owners == ["reasoning"])
    }
}

@Suite("Advanced settings: three presentation details")
@MainActor
struct AdvancedSettingsPresentationTests {
    private static func parameter(
        _ id: String, _ schema: String, defaultValue: GenerationParameterValue? = nil
    ) -> GenerationParameterRef {
        GenerationParameterRef(
            id: id, support: "supported", group: "sampling", valueSchema: schema, defaultDescription: defaultValue
        )
    }

    private static func rows(
        _ profile: GenerationProfileRef, session: [String: GenerationParameterOverride]
    ) throws -> [String: AdvancedParameterRow] {
        let suite = "advanced-settings-presentation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let providerID = UUID()
        let conversation = UUID()
        store.setSessionOverrides(
            .init(values: session), providerID: providerID, modelID: "m", conversationID: conversation
        )
        let rows = AdvancedSettingsCatalog.fixture(profile: profile, engineProfile: "llamacpp").rows(
            store: store, providerID: providerID, modelID: "m", conversationID: conversation,
            layerValues: .init(values: session), profileFingerprint: nil
        )
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    @Test("a row that is taken over is only struck through: no inline note, the expanded row says in secondary color what took it over, and the group footnote gives the reason once")
    func supersededRowsCarryNoInlineNotice() throws {
        let profile = try #require(LocalEngineGenerationProfiles.profile(
            for: "llamacpp", transport: .openaiChatCompletions
        ))
        let on = try Self.rows(profile, session: [
            "mirostat": .init(state: .value, value: .number(2)),
            "top_k": .init(state: .value, value: .number(20)),
        ])
        for id in ["top_k", "top_p"] {
            let row = try #require(on[id])
            // The row model is unchanged: it still knows what took it over.
            #expect(row.model.supersededBy == "Mirostat")
            #expect(row.notice == nil, "\(id) is taken over yet carries an inline note")
            #expect(row.supersededNote?.contains("Mirostat") == true)
        }
        let footnote = try #require(AdvancedSettingsLayout.commonFootnote(
            rows: Array(on.values),
            commonIDs: GenerationParameterPresentationFacts.commonParameterIDs,
            engineName: "llama.cpp"
        ))
        #expect(footnote.contains(String(
            format: L10n.tr("Crossed-out settings are being handled by %@.", table: .chat), "Mirostat"
        )))
        #expect(footnote.contains("llama.cpp"))

        // Without a takeover the footnote does not mention it.
        let off = try Self.rows(profile, session: [:])
        #expect(off["top_k"]?.supersededNote == nil)
        let plain = AdvancedSettingsLayout.commonFootnote(
            rows: Array(off.values),
            commonIDs: GenerationParameterPresentationFacts.commonParameterIDs,
            engineName: "llama.cpp"
        )
        #expect(plain?.contains("Mirostat") != true)

        // A value that is really invalid still has an inline note, and it is an error.
        let invalid = try Self.rows(profile, session: ["top_p": .init(state: .value, value: .number(5))])
        #expect(invalid["top_p"]?.notice?.isError == true)

        // Presentation: the takeover note only appears in the expanded area, in secondary color.
        let view = try Self.source("AdvancedParameterRowView.swift")
        #expect(view.components(separatedBy: "row.supersededNote").count == 2, "the takeover note should be rendered once, in the expanded area only")
        let block = try #require(view.components(separatedBy: "if let supersededNote = row.supersededNote {").dropFirst().first?
            .components(separatedBy: "}\n").first)
        #expect(block.contains("OriveoTheme.Palette.textSecondary"))
        #expect(!block.contains("danger") && !block.contains("warning"))
    }

    @Test("slider ticks: tick and label only with a model default, only the tick close to an end, the midpoint only when it is an integer")
    func sliderScaleMarks() {
        func marks(_ range: ClosedRange<Double>, _ modelDefault: Double?) -> AdvancedSliderScale.Marks {
            AdvancedSliderScale.marks(
                range: range, modelDefault: modelDefault, defaultLabel: "\u{6A21}\u{578B}\u{9ED8}\u{8BA4}", width: 326,
                textWidth: { CGFloat($0.count) * 7 }
            )
        }
        func texts(_ marks: AdvancedSliderScale.Marks) -> [AdvancedSliderScale.Label.Kind: String] {
            Dictionary(uniqueKeysWithValues: marks.labels.map { ($0.kind, $0.text) })
        }

        // The reference layout: 0 … model default 0.2 … 1 … 2.
        let board = marks(0...2, 0.2)
        #expect(texts(board) == [.lowerBound: "0", .modelDefault: "\u{6A21}\u{578B}\u{9ED8}\u{8BA4} 0.2", .midpoint: "1", .upperBound: "2"])
        let tick = board.defaultTickX ?? -1
        #expect(abs(tick - (14 + 298 * 0.1)) < 0.001)
        // No two pieces of text overlap.
        let sorted = board.labels.sorted { $0.minX < $1.minX }
        for (left, right) in zip(sorted, sorted.dropFirst()) { #expect(left.maxX < right.minX) }

        // Without a model default neither tick nor label is drawn.
        let none = marks(0...2, nil)
        #expect(none.defaultTickX == nil)
        #expect(texts(none)[.modelDefault] == nil)

        // Close to an end: only the tick stays.
        for value in [0.0, 0.01, 2.0] {
            let edge = marks(0...2, value)
            #expect(edge.defaultTickX != nil)
            #expect(texts(edge)[.modelDefault] == nil, "the label for \(value) would overlap the number at the end")
        }
        // The model default is right around the midpoint: its label stays and the midpoint's number gives way.
        let middle = marks(0...2, 1)
        #expect(texts(middle)[.modelDefault] == "\u{6A21}\u{578B}\u{9ED8}\u{8BA4} 1")
        #expect(texts(middle)[.midpoint] == nil)
        // A non-integer midpoint is not labeled; a default outside the range is not drawn.
        #expect(texts(marks(0...1, nil))[.midpoint] == nil)
        #expect(marks(0...1, 3).defaultTickX == nil)
    }

    @Test("the slider's model default only uses a model default you set; the engine's own default does not count")
    func sliderDefaultIsTheUsersModelDefault() throws {
        let profile = GenerationProfileRef(
            template: "openai_chat_completions",
            parameters: [Self.parameter("temperature", "number", defaultValue: .number(0.8))],
            wire: ["temperature": "temperature"], transport: "openai_chat_completions"
        )
        let row = try #require(Self.rows(profile, session: [:])["temperature"])
        #expect(row.modelDefaultValue == nil)
        #expect(row.fallbackValue == .number(0.8))
    }

    @Test("a negative engine default for the output limit shows as no limit; the criterion is the parameter table's default alone")
    func unlimitedOutputDefaultReadsAsNoLimit() throws {
        typealias Facts = GenerationParameterPresentationFacts
        #expect(Facts.engineDefaultText(.number(-1), parameterID: "max_output_tokens") == L10n.tr("No limit", table: .chat))
        #expect(Facts.engineDefaultText(.number(4096), parameterID: "max_output_tokens") == "4096")
        // For other parameters -1 is just -1 (the default of Top-N Sigma).
        #expect(Facts.engineDefaultText(.number(-1), parameterID: "top_n_sigma") == "-1")

        let profile = GenerationProfileRef(
            template: "openai_chat_completions",
            parameters: [Self.parameter("max_output_tokens", "integer", defaultValue: .number(-1))],
            wire: ["max_output_tokens": "max_tokens"], transport: "openai_chat_completions"
        )
        let row = try #require(Self.rows(profile, session: [:])["max_output_tokens"])
        #expect(row.trailingText == L10n.tr("No limit", table: .chat))
        #expect(row.model.source == .providerDecides)
        // When the parameter table declares no default none is invented: it stays "decided by the model".
        let undeclared = GenerationProfileRef(
            template: "openai_chat_completions",
            parameters: [Self.parameter("max_output_tokens", "integer")],
            wire: ["max_output_tokens": "max_tokens"], transport: "openai_chat_completions"
        )
        #expect(try #require(Self.rows(undeclared, session: [:])["max_output_tokens"]).trailingText
            == L10n.tr("Model default"))
    }

    @Test("both llama.cpp channels declare n_predict = -1 in their in-app parameter table, and the max tokens row reads \"No limit\"")
    func llamaCppMaxTokensReadsAsNoLimit() throws {
        for transport in [RelayTransport.openaiChatCompletions, .llamacppNative] {
            let profile = try #require(LocalEngineGenerationProfiles.profile(for: "llamacpp", transport: transport))
            let row = try #require(Self.rows(profile, session: [:])["max_output_tokens"], "\(transport)")
            #expect(row.trailingText == L10n.tr("No limit", table: .chat), "\(transport)")
            #expect(row.model.source == .providerDecides, "\(transport)")
            // The placeholder after clearing the inline input must not show -1 either.
            #expect(row.fallbackText == L10n.tr("No limit", table: .chat), "\(transport)")
        }
    }

    @Test("member rows inside the Mirostat card use the short title; outside the card it is still the full vocabulary name")
    func mirostatMembersUseShortTitlesInsideTheirCard() throws {
        typealias Facts = GenerationParameterPresentationFacts
        #expect(Facts.memberShortTitle(parameterID: "mirostat_tau")?.name == L10n.tr("Target entropy", table: .chat))
        #expect(Facts.memberShortTitle(parameterID: "mirostat_tau")?.symbol == "tau")
        #expect(Facts.memberShortTitle(parameterID: "mirostat_eta")?.name == L10n.tr("Learning rate", table: .chat))
        #expect(Facts.memberShortTitle(parameterID: "mirostat_eta")?.symbol == "eta")
        #expect(Facts.memberShortTitle(parameterID: "temperature") == nil)

        let profile = try #require(LocalEngineGenerationProfiles.profile(
            for: "llamacpp", transport: .openaiChatCompletions
        ))
        let rows = try Self.rows(profile, session: ["mirostat_tau": .init(state: .value, value: .number(4))])
        // The row model (summary chips, accessibility) is unchanged.
        #expect(rows["mirostat_tau"]?.model.title == GenerationParameterVocabulary.title("mirostat_tau"))
        let view = try Self.source("AdvancedParameterRowView.swift")
        #expect(view.contains("shortTitle: section.id.hasPrefix(\"family:\")"))
        #expect(view.contains(".accessibilityLabel(Text(row.model.title))"))
    }

    private static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Features/Chat/ModelControls/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Suite("Advanced settings: rows only label exceptions, and the header states the page's tone once", .serialized)
@MainActor
struct AdvancedSettingsRowAnnotationTests {
    private typealias Annotations = AdvancedSettingsRowAnnotations

    private static func input(_ id: String, _ presentationClass: String = "unverified", unverified: Bool) -> Annotations.Input {
        .init(id: id, presentationClass: presentationClass, isUnverified: unverified)
    }

    @Test("a real llama.cpp connection: the header says unverified once and none of the dozen rows carries an inline label; the sample looks the same")
    func realLocalEngineRowsCarryNoInlineBadges() async throws {
        // Production path: the llama.cpp chat table of `LocalEngineGenerationProfiles`, through the real interface identity and evidence projection.
        // A relay's interface identity is only complete once the runtime catalog is ready (has an ETag), so an empty catalog is loaded first.
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: """
        {
          "version": 1,
          "updatedAt": "2026-10-06T00:00:00Z",
          "profiles": { "reasoning": {}, "webSearch": {}, "imageGen": {} },
          "providers": {}
        }
        """, metadataETag: "advanced-settings-annotations-etag")
        // A llama.cpp connection with a decided protocol and a resolvable endpoint (the same form as the relay fixture in `GenerationParameterEmptyStateTests`).
        let model = AdvancedSettingsSamples.localModel
        var provider = Provider(
            id: UUID(), kind: .relay, status: .connected, models: [model], catalogModels: [model],
            lastCheckedAt: nil, apiKey: "key", apiKeyPreview: "...key", lastError: nil,
            baseURLText: "https://relay.test/v1"
        )
        provider.relayRequested = RelayRequestedConfig(transport: .openaiChatCompletions, engineProfile: "llamacpp")
        let identity = try #require(CapabilityEvidenceProductionAdapter.uiDispatchIdentity(
            provider: provider, model: model, partitionID: "advanced-settings-annotations"
        ))
        let catalog = AdvancedSettingsCatalog.production(
            provider: provider, model: model, scope: .session,
            identity: identity, isReadOnly: false
        )
        let projection = CapabilityEvidenceProductionAdapter.generationProjection(
            provider: provider, model: model, identity: identity
        )
        await MetadataClient.shared.resetForTesting()

        let table = try #require(LocalEngineGenerationProfiles.profile(
            for: "llamacpp", transport: .openaiChatCompletions
        )?.parameters)
        let declared = table.compactMap { $0.id }
        #expect(Set(catalog.parameters.compactMap { $0.id }) == Set(declared), "the rows from the production path do not match the llama.cpp parameter table")
        #expect(catalog.parameters.count > 10)

        // Precondition: the production criterion really considers every row of this page "unverified"; it is not hidden here.
        #expect(GenerationParameterPanelPresentation.showsUnverifiedGroupNote(
            parameters: catalog.parameters, projection: projection
        ))
        let unverified = catalog.parameters.filter {
            GenerationParameterPanelPresentation.showsUnverifiedBadge(parameter: $0, projection: projection)
        }
        #expect(unverified.count == catalog.parameters.count)

        #expect(catalog.unverifiedGroupNote == AdvancedSettingsCatalog.unverifiedGroupNoteText, "the header does not say these parameters are inferred from the protocol")
        let badged = catalog.facts.filter { $0.value.showsUnverifiedBadge }.keys.sorted()
        #expect(badged.isEmpty, "these rows carry an unverified badge each again: \(badged)")
        let noted = catalog.facts.filter { $0.value.statusNote != nil }.keys.sorted()
        #expect(noted.isEmpty, "these rows each repeat the same status sentence when expanded: \(noted)")
        // The labels are gone, the rows themselves are still there and can still be changed.
        let locked = catalog.facts.filter { !$0.value.isEditable }.keys.sorted()
        #expect(locked.isEmpty, "these rows can no longer be changed: \(locked)")

        // The sample fixture looks the same as real data: the same rows, the same header note, the same absence of inline labels.
        let sample = AdvancedSettingsSamples.localCatalog
        #expect(sample.parameters.compactMap { $0.id } == catalog.parameters.compactMap { $0.id })
        #expect(sample.unverifiedGroupNote == catalog.unverifiedGroupNote)
        #expect(sample.facts == catalog.facts)
    }

    @Test("a page that is unverified throughout: the header says so and rows are not labeled; a row with a different status still labels itself")
    func uniformPagesAnnotateOnlyExceptions() {
        let uniform = (1...12).map { Self.input("p\($0)", unverified: true) }
        #expect(Annotations.resolve(uniform) == .init(showsPageNote: true, inlineIDs: []))

        // Unverified throughout, with a few rows rejected upstream (a different presentation class, and not "unverified").
        let withRejected = uniform + [Self.input("rejected", "notAdjustable", unverified: false)]
        #expect(Annotations.resolve(withRejected) == .init(showsPageNote: true, inlineIDs: ["rejected"]))

        // Unverified as well, but with a presentation class that differs from the tone: also an exception.
        let withFixed = uniform + [Self.input("fixed", "notAdjustable", unverified: true)]
        #expect(Annotations.resolve(withFixed) == .init(showsPageNote: true, inlineIDs: ["fixed"]))
    }

    @Test("a page with official configuration and a few unverified rows: the header says nothing and those rows label themselves")
    func mostlyVerifiedPagesKeepInlineBadges() {
        let rows = (1...9).map { Self.input("p\($0)", "silent", unverified: false) }
            + [Self.input("odd", unverified: true)]
        let result = Annotations.resolve(rows)
        #expect(!result.showsPageNote)
        #expect(result.inlineIDs == Set(rows.map(\.id)))
        // Exactly half is not a tone.
        let half = [Self.input("a", unverified: true), Self.input("b", "silent", unverified: false)]
        #expect(!Annotations.resolve(half).showsPageNote)
        #expect(Annotations.resolve([]) == .init(showsPageNote: false, inlineIDs: []))
    }
}
