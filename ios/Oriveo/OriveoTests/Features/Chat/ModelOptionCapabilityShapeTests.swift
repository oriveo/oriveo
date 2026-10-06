import Foundation
import Testing
@testable import Oriveo

/// Every shape a capability card can take, one test per shape.
///
/// Under test is `ModelOptionCapabilityShape.resolve`: the view layer only switches over the shape it returns
/// and decides no business condition itself. Each assertion therefore pins which control appears, with which levels, and where a tap leads.
///
/// The on/off, cannot-turn-off, no-configuration, no-thinking and web search cases take their input from the
/// **production resolution path**: a slice of production metadata
/// (`shared/model-contracts/production-capability-snapshot.json`) is loaded into `MetadataClient` and then goes
/// through `CapabilityControlPresentationResolver` and `CapabilityControlResolution.resolve` to produce the
/// presentation and levels. The slice carries no recipe bodies, so the fixture adds an empty recipe with each
/// model's own protocol for the "recipe protocol == model protocol" check to work on. The remaining cases have no counterpart in the slice and use hand-written facts.
@MainActor
@Suite("Capability card shapes", .serialized)
struct ModelOptionCapabilityShapeTests {
    typealias Shape = ModelOptionCapabilityShape

    // MARK: - Thinking

    @Test("on and off only → a toggle")
    func onAndOffOnlyIsAToggle() async throws {
        let facts = try await Self.production("zhipu/glm-4.6", capability: "reasoning")
        #expect(facts.presentation == .automaticAvailable)
        #expect(facts.intents == ["off", "balanced"])

        let off = Shape.resolve(.init(
            capability: .reasoning, presentation: facts.presentation,
            availableIntents: facts.intents, selectedIntent: "off"
        ))
        guard case let .toggle(toggle) = off else {
            Issue.record("on and off only should be a toggle, got \(off)")
            return
        }
        #expect(!toggle.isOn)
        #expect(toggle.target == .capabilityPreference(on: "balanced", off: "off"))
        #expect(toggle.caption == L10n.tr(
            "Thinks it through first, so answers take a little longer", table: .chat
        ))
        #expect(toggle.link == nil)

        let on = Shape.resolve(.init(
            capability: .reasoning, presentation: facts.presentation,
            availableIntents: facts.intents, selectedIntent: "balanced"
        ))
        guard case let .toggle(onToggle) = on else {
            Issue.record("still a toggle once turned on, got \(on)")
            return
        }
        #expect(onToggle.isOn)
    }

    @Test("several levels, can turn off → segments including Off")
    func severalLevelsWithOff() {
        let shape = Shape.resolve(.init(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: ["max", "deep", "low", "off"], selectedIntent: "off"
        ))
        guard case let .tiers(tiers) = shape else {
            Issue.record("several levels should be segments, got \(shape)")
            return
        }
        #expect(tiers.includesOff)
        // Off comes first, the rest from least to most effort; Balanced was not delivered and does not appear.
        #expect(tiers.options.map(\.id) == ["off", "low", "deep", "max"])
        #expect(tiers.selection == "off")
        // The top-right note follows the selected level.
        #expect(tiers.headerNote == L10n.tr("Answer right away, no thinking time.", table: .chat))
        #expect(tiers.headerTone == .neutral)
        #expect(tiers.footnotes.isEmpty)
        #expect(tiers.rejected.isEmpty)
    }

    @Test("several levels, cannot turn off → segments without Off, and a note at the top right")
    func severalLevelsWithoutOff() async throws {
        let facts = try await Self.production("anthropic/claude-fable-5", capability: "reasoning")
        #expect(facts.presentation == .automaticAvailable)
        #expect(facts.intents == ["low", "balanced", "deep", "max"])

        let shape = Shape.resolve(.init(
            capability: .reasoning, presentation: facts.presentation,
            availableIntents: facts.intents, selectedIntent: "balanced"
        ))
        guard case let .tiers(tiers) = shape else {
            Issue.record("several levels should be segments, got \(shape)")
            return
        }
        #expect(!tiers.includesOff)
        #expect(tiers.options.map(\.id) == ["low", "balanced", "deep", "max"])
        #expect(!tiers.options.map(\.id).contains("off"))
        #expect(tiers.selection == "balanced")
        #expect(tiers.headerNote == L10n.tr("Always thinks before answering", table: .chat))
        #expect(tiers.footnotes == [
            L10n.tr("A balance of speed and depth.", table: .chat),
            L10n.tr("Higher levels take longer and may cost more.", table: .chat),
        ])
    }

    @Test("no official configuration yet → a note and a way forward")
    func noOfficialConfigurationYet() async throws {
        let facts = try await Self.production("qwen/qwen3.6-plus", capability: "reasoning")
        #expect(facts.presentation == .pending)

        let shape = Shape.resolve(.init(
            capability: .reasoning, presentation: facts.presentation, availableIntents: facts.intents
        ))
        #expect(shape == .notice(.init(
            status: L10n.tr("Uses the model’s default", table: .chat),
            body: L10n.tr(
                "Oriveo doesn’t have thinking settings for this model yet, so it runs on its own default.",
                table: .chat
            ),
            link: .init(
                title: L10n.tr("See which models can be adjusted", table: .chat),
                action: .openSupportedModels
            )
        )))
    }

    // MARK: - Unsupported models and web search

    @Test("model does not think → one tappable row")
    func modelDoesNotThink() async throws {
        let facts = try await Self.production("deepseek/deepseek-chat", capability: "reasoning")
        #expect(facts.presentation == .unsupported)

        let shape = Shape.resolve(.init(
            capability: .reasoning, presentation: facts.presentation, availableIntents: facts.intents
        ))
        #expect(shape == .disclosure(.init(
            status: L10n.tr("This model has no thinking mode", table: .chat),
            action: .openSupportedModels
        )))
    }

    @Test("web search on → an extra timing row; searching every message appears only when the recipe supports it")
    func webSearchOnAddsTiming() async throws {
        let facts = try await Self.production("openAI/gpt-5-pro", capability: "web")
        #expect(facts.presentation == .automaticAvailable)
        #expect(facts.intents.contains("force"))

        let on = Shape.resolve(.init(
            capability: .web, presentation: facts.presentation,
            availableIntents: facts.intents, selectedIntent: "automatic"
        ))
        guard case let .toggleWithTiming(toggle, timing) = on else {
            Issue.record("with web search on and forced search supported there should be a timing row, got \(on)")
            return
        }
        #expect(toggle.isOn)
        #expect(toggle.target == .capabilityPreference(on: "automatic", off: "off"))
        #expect(timing.options.map(\.id) == ["automatic", "force"])
        #expect(timing.selection == "automatic")

        // No timing row while it is off.
        let off = Shape.resolve(.init(
            capability: .web, presentation: facts.presentation,
            availableIntents: facts.intents, selectedIntent: "off"
        ))
        guard case let .toggle(offToggle) = off else {
            Issue.record("web search off should be a plain toggle, got \(off)")
            return
        }
        #expect(!offToggle.isOn)

        // A model whose recipe has no forced search: just a toggle even when on.
        let plain = try await Self.production("zhipu/glm-4.6", capability: "web")
        #expect(plain.presentation == .automaticAvailable)
        #expect(!plain.intents.contains("force"))
        let plainOn = Shape.resolve(.init(
            capability: .web, presentation: plain.presentation,
            availableIntents: plain.intents, selectedIntent: "automatic"
        ))
        guard case let .toggle(plainToggle) = plainOn else {
            Issue.record("no timing row without forced search in the recipe, got \(plainOn)")
            return
        }
        #expect(plainToggle.isOn)
    }

    @Test("web search needs manual setup → a note and a link to the additional request body")
    func webSearchNeedsManualSetup() {
        let shape = Shape.resolve(.init(capability: .web, presentation: .customOnly))
        #expect(shape == .notice(.init(
            status: L10n.tr("Needs manual setup", table: .chat),
            body: L10n.tr(
                "This provider has no standard switch for web search. Add its fields in the additional request body.",
                table: .chat
            ),
            link: .init(
                title: L10n.tr("Open additional request body", table: .chat),
                action: .openAdditionalRequestBody
            )
        )))
    }

    @Test("model cannot search the web → one tappable row")
    func modelCannotSearchTheWeb() async throws {
        let facts = try await Self.production("deepseek/deepseek-chat", capability: "web")
        #expect(facts.presentation == .unsupported)

        let shape = Shape.resolve(.init(
            capability: .web, presentation: facts.presentation, availableIntents: facts.intents
        ))
        #expect(shape == .disclosure(.init(
            status: L10n.tr("This model can’t search the web", table: .chat),
            action: .openSupportedModels
        )))
    }

    // MARK: - Custom connections and rejected levels

    @Test("custom LLM, protocol undecided → the whole card collapses into one thing")
    func protocolUndecidedCollapsesTheCard() {
        let callout = Shape.Callout(
            title: L10n.tr("Choose this connection’s protocol first", table: .chat),
            body: L10n.tr(
                "The protocol is still set to Auto, so Oriveo can’t tell how to send web search and thinking settings.",
                table: .chat
            ),
            link: .init(title: L10n.tr("Choose protocol", table: .chat), action: .openConnectionProtocol)
        )
        let web = Shape.Input(
            capability: .web, presentation: .unknown, connection: .custom,
            isWritable: false, protocolUndecided: true
        )
        let reasoning = Shape.Input(
            capability: .reasoning, presentation: .unknown, connection: .custom,
            isWritable: false, protocolUndecided: true, chatTemplateThinkingIsOn: true
        )
        // A single row reports the same thing; the card shows it once instead of in two rows.
        #expect(Shape.resolve(web) == .protocolUndecided(callout))
        #expect(Shape.resolve(reasoning) == .protocolUndecided(callout))
        #expect(ModelOptionCapabilityCard.resolve(web: web, reasoning: reasoning) == .protocolUndecided(callout))
    }

    @Test("custom LLM or local engine → thinking toggles through the chat template, web search says it cannot be done")
    func customConnectionGetsATemplateThinkingToggle() {
        // A custom connection has no official recipe: the presentation is unknown, but thinking still needs a way.
        let card = ModelOptionCapabilityCard.resolve(
            web: .init(capability: .web, presentation: .unknown, connection: .custom),
            reasoning: .init(
                capability: .reasoning, presentation: .unknown, connection: .custom,
                chatTemplateThinkingIsOn: false
            )
        )
        guard case let .rows(web, reasoning) = card else {
            Issue.record("a custom connection with a decided protocol should have two rows, got \(card)")
            return
        }
        #expect(reasoning == .toggle(.init(
            isOn: false,
            caption: L10n.tr(
                "Turns thinking on or off through the chat template. Whether it works depends on your server.",
                table: .chat
            ),
            target: .chatTemplateThinking,
            link: .init(
                title: L10n.tr("Open additional request body", table: .chat),
                action: .openAdditionalRequestBody
            )
        )))
        #expect(web == .disclosure(.init(
            status: L10n.tr("This connection can’t do this", table: .chat),
            action: .switchConnection
        )))

        // The toggle state is whatever the caller read from the additional request body; the shape function does not infer it.
        let on = Shape.resolve(.init(
            capability: .reasoning, presentation: .unknown, connection: .custom,
            chatTemplateThinkingIsOn: true
        ))
        guard case let .toggle(toggle) = on else {
            Issue.record("thinking on a custom connection should be a toggle, got \(on)")
            return
        }
        #expect(toggle.isOn)

        // An official connection in the same presentation must not get this toggle: without a recipe there is no field to send.
        let official = Shape.resolve(.init(capability: .reasoning, presentation: .unknown))
        guard case .notice = official else {
            Issue.record("an official connection without configuration should be a note, got \(official)")
            return
        }
    }

    @Test("provider rejected a level → removed from the segments, with an explanation")
    func rejectedLevelIsRemovedAndExplained() {
        let shape = Shape.resolve(.init(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: ["low", "balanced", "deep", "max"],
            selectedIntent: "max", rejectedIntents: ["max"]
        ))
        guard case let .tiers(tiers) = shape else {
            Issue.record("still segments after one level was rejected, got \(shape)")
            return
        }
        #expect(tiers.options.map(\.id) == ["low", "balanced", "deep"])
        #expect(tiers.rejected == ["max"])
        // The selected level is the rejected one: fall to the nearest of the remaining levels.
        #expect(tiers.selection == "deep")
        #expect(tiers.headerTone == .warning)
        let max = ModelControlIntentLabel.text("max")
        #expect(tiers.headerNote == String(format: L10n.tr("“%@” was rejected", table: .chat), max))
        #expect(tiers.footnotes == [String(
            format: L10n.tr(
                "This model isn’t accepting “%1$@” right now, so it’s back on “%2$@”. The level will return on its own once the model supports it again.",
                table: .chat
            ),
            max, ModelControlIntentLabel.text("deep")
        )])

        // The panel is reopened after the caller already moved the selection back to Balanced: the selection stays, the explanation too.
        let reopened = Shape.resolve(.init(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: ["low", "balanced", "deep", "max"],
            selectedIntent: "balanced", rejectedIntents: ["max"]
        ))
        guard case let .tiers(reopenedTiers) = reopened else {
            Issue.record("still segments after one level was rejected, got \(reopened)")
            return
        }
        #expect(reopenedTiers.selection == "balanced")
        #expect(reopenedTiers.options.map(\.id) == ["low", "balanced", "deep"])
    }

    // MARK: - Automatic level, never chosen, read-only

    @Test("the recipe offers Automatic → drawn as the first segment; highlighted when never chosen, without storing a value for the user")
    func automaticTierIsFirstAndHighlightedWhenNothingIsStored() {
        let input = Shape.Input(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: ["max", "automatic", "low", "deep"]
        )
        guard case let .tiers(tiers) = Shape.resolve(input) else {
            Issue.record("with Automatic and several levels this should be segments, got \(Shape.resolve(input))")
            return
        }
        #expect(tiers.options.map(\.id) == ["automatic", "low", "deep", "max"])
        #expect(tiers.selection == Shape.automaticIntent)
        #expect(!tiers.includesOff)
        #expect(tiers.headerNote == L10n.tr("Always thinks before answering", table: .chat))
        #expect(tiers.footnotes.first == L10n.tr("The model decides on its own.", table: .chat))
        // The shape function only decides what to draw: the stored choice in the input is not rewritten.
        #expect(input.selectedIntent == nil)

        // It does not take the highlight once another level has been chosen.
        var chosen = input
        chosen.selectedIntent = "deep"
        guard case let .tiers(chosenTiers) = Shape.resolve(chosen) else {
            Issue.record("still segments once a level has been chosen")
            return
        }
        #expect(chosenTiers.selection == "deep")

        // Automatic plus Off are two real choices as well; this does not degrade into "fixed level".
        guard case let .tiers(two) = Shape.resolve(.init(
            capability: .reasoning, presentation: .automaticAvailable, availableIntents: ["off", "automatic"]
        )) else {
            Issue.record("Automatic together with Off should be segments")
            return
        }
        #expect(two.options.map(\.id) == ["automatic", "off"])
        #expect(two.selection == Shape.automaticIntent)
    }

    @Test("no Automatic in the recipe and never chosen → nothing highlighted, and the top right says it uses the model’s default")
    func nothingStoredAndNoAutomaticTierHighlightsNothing() {
        let modelDefault = L10n.tr("Uses the model’s default", table: .chat)
        guard case let .tiers(withOff) = Shape.resolve(.init(
            capability: .reasoning, presentation: .automaticAvailable, availableIntents: ["off", "low", "deep"]
        )) else {
            Issue.record("several levels should be segments")
            return
        }
        #expect(withOff.selection == nil)
        #expect(withOff.headerNote == modelDefault)
        #expect(withOff.headerTone == .neutral)

        guard case let .tiers(withoutOff) = Shape.resolve(.init(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: ["low", "balanced", "deep", "max"]
        )) else {
            Issue.record("several levels should be segments")
            return
        }
        #expect(withoutOff.selection == nil)
        #expect(withoutOff.headerNote == modelDefault)
        // With no level selected, the note is not borrowed from Automatic to fill the gap.
        #expect(withoutOff.footnotes == [L10n.tr("Higher levels take longer and may cost more.", table: .chat)])

        // The stored level is no longer in the configuration: handled like never chosen, with no falsely highlighted segment.
        guard case let .tiers(stale) = Shape.resolve(.init(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: ["off", "low", "deep"], selectedIntent: "max"
        )) else {
            Issue.record("several levels should be segments")
            return
        }
        #expect(stale.selection == nil)
        #expect(stale.headerNote == modelDefault)

        // The read-only row says the same sentence.
        #expect(Shape.resolve(.init(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: ["low", "deep"], isWritable: false
        )) == .disclosure(.init(status: modelDefault, action: nil)))
    }

    @Test("web search with only on and off has a caption under the title; with a timing row the caption goes away and the two segments are search when needed / search every message")
    func webToggleCaptionAndTimingLabels() {
        guard case let .toggle(plain) = Shape.resolve(.init(
            capability: .web, presentation: .automaticAvailable, selectedIntent: "off"
        )) else {
            Issue.record("web search should be a toggle")
            return
        }
        #expect(plain.caption == L10n.tr("Searches the web first when a question needs it", table: .chat))

        guard case let .toggleWithTiming(toggle, timing) = Shape.resolve(.init(
            capability: .web, presentation: .automaticAvailable,
            availableIntents: ["force"], selectedIntent: "force"
        )) else {
            Issue.record("with forced search supported and web search on there should be a timing row")
            return
        }
        #expect(toggle.caption == nil)
        #expect(timing.selection == "force")
        #expect(timing.options.map(\.label) == [
            L10n.tr("When needed", table: .chat), L10n.tr("Every message", table: .chat),
        ])
    }

    @Test("a stored search-every-message that the configuration no longer has counts as search when needed; without a configuration the stored choice is not rewritten")
    func staleForceIsClampedOnlyWhenTheConfigurationSaysSo() {
        #expect(Shape.clampedWebPreference(
            .force, presentation: .automaticAvailable, availableIntents: []
        ) == .automatic)
        #expect(Shape.clampedWebPreference(
            .force, presentation: .automaticAvailable, availableIntents: ["force"]
        ) == .force)
        for presentation: CapabilityControlPresentation in [.pending, .unknown, .unsupported, .customOnly] {
            #expect(Shape.clampedWebPreference(.force, presentation: presentation, availableIntents: []) == .force)
        }
        #expect(Shape.clampedWebPreference(
            .automatic, presentation: .automaticAvailable, availableIntents: []
        ) == .automatic)
        // In the shape: on, but without a timing row.
        guard case let .toggle(toggle) = Shape.resolve(.init(
            capability: .web, presentation: .automaticAvailable, selectedIntent: "force"
        )) else {
            Issue.record("no timing row when the configuration has no forced search")
            return
        }
        #expect(toggle.isOn)
    }

    @Test("the chat template toggle on a custom connection becomes a current-value row while the panel is read-only")
    func templateSwitchIsAStatusLineWhileReadOnly() {
        let on = Shape.resolve(.init(
            capability: .reasoning, presentation: .unknown, connection: .custom,
            isWritable: false, chatTemplateThinkingIsOn: true
        ))
        #expect(on == .disclosure(.init(status: L10n.tr("On", table: .chat), action: nil)))
        let off = Shape.resolve(.init(
            capability: .reasoning, presentation: .unknown, connection: .custom, isWritable: false
        ))
        #expect(off == .disclosure(.init(status: ModelControlIntentLabel.text("off"), action: nil)))
    }

    @Test("a custom connection whose protocol applies no chat template → no toggle; a note with a link to the additional request body instead")
    func customConnectionWithoutChatTemplateGetsManualSetup() {
        let shape = Shape.resolve(.init(
            capability: .reasoning, presentation: .unknown, connection: .custom,
            chatTemplateThinkingIsOn: true, supportsChatTemplate: false
        ))
        #expect(shape == .notice(.init(
            status: L10n.tr("Needs manual setup", table: .chat),
            body: L10n.tr(
                "This provider has no standard switch for thinking. Add its fields in the additional request body.",
                table: .chat
            ),
            link: .init(
                title: L10n.tr("Open additional request body", table: .chat), action: .openAdditionalRequestBody
            )
        )))
        // The web search row is unaffected; neither is an official connection.
        #expect(Shape.resolve(.init(
            capability: .web, presentation: .unknown, connection: .custom, supportsChatTemplate: false
        )) == .disclosure(.init(
            status: L10n.tr("This connection can’t do this", table: .chat), action: .switchConnection
        )))
        guard case .tiers = Shape.resolve(.init(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: ["low", "deep"], supportsChatTemplate: false
        )) else {
            Issue.record("still segments when there is an official configuration")
            return
        }
    }

    /// Pins "unavailable always comes with an explanation and a way forward" as one exhaustive assertion: a new presentation has to take a position here at once.
    @Test("when a capability is unavailable its row always has an explanation and a way forward, and no interactive control")
    func everyUnavailableStateHasAnExplanationAndAWayOut() {
        let unavailable: [CapabilityControlPresentation] = [
            .unsupported, .externalConnectorOnly, .customOnly, .pending, .unknown,
        ]
        for presentation in unavailable {
            for capability in [Shape.Capability.web, .reasoning] {
                let shape = Shape.resolve(.init(capability: capability, presentation: presentation))
                switch shape {
                case let .notice(notice):
                    #expect(!notice.body.isEmpty, "\(capability)/\(presentation) has no explanation")
                    #expect(notice.link != nil, "\(capability)/\(presentation) has no way forward")
                case let .disclosure(disclosure):
                    #expect(!disclosure.status.isEmpty)
                    #expect(disclosure.action != nil, "\(capability)/\(presentation) has no way forward")
                case .toggle, .tiers, .toggleWithTiming, .protocolUndecided:
                    Issue.record("\(capability)/\(presentation) must not be \(shape)")
                }
            }
        }
    }

    // MARK: - Production resolution path

    private struct Facts {
        let presentation: CapabilityControlPresentation
        let intents: [String]
    }

    private struct Snapshot: Decodable {
        struct Control: Decodable {
            let state: String?
            let recipeRef: String?
            let reasonCode: String?
            let availableIntents: [String]?
        }
        struct Model: Decodable {
            let providerKind: String
            let modelId: String
            let capabilities: [String]
            let capabilityControls: [String: Control]
            let transport: String
        }
        let models: [String: Model]
    }

    /// Loads the production slice, then takes this model's presentation and levels for the capability from the production resolution path.
    /// Levels are read the way the panel reads them: thinking from the verdict's `intents`, web search from the delivered levels only under `auto_available`.
    private static func production(_ key: String, capability: String) async throws -> Facts {
        let snapshot = try loadSnapshot()
        let entry = try #require(snapshot.models[key], "the production slice has no \(key)")
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(
            json: try metadataJSON(snapshot), metadataETag: "model-option-capability-shape"
        )
        let kind = try #require(ProviderKind(rawValue: entry.providerKind))
        let persisted = TestFactories.makeModel(
            id: entry.modelId, capabilities: entry.capabilities.compactMap(ModelCapability.init(rawValue:))
        )
        let model = MetadataClient.shared.syncCurrentCapabilityEvidenceModel(persisted, providerKind: kind)
        let provider = TestFactories.makeProvider(id: UUID(), kind: kind, models: [model])
        let presentation = CapabilityControlPresentationResolver.presentation(
            provider: provider, model: model, capability: capability
        )
        let verdict = CapabilityControlResolution.resolve(
            provider: provider, model: model, capability: capability
        )
        await MetadataClient.shared.resetForTesting()
        return Facts(
            presentation: presentation,
            intents: verdict.state == .autoAvailable ? verdict.intents : []
        )
    }

    private static func loadSnapshot() throws -> Snapshot {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let candidate = current.appendingPathComponent("shared").appendingPathComponent("model-contracts")
                .appendingPathComponent("production-capability-snapshot.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: candidate))
            }
            current = current.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func metadataJSON(_ snapshot: Snapshot) throws -> String {
        var providers: [String: Any] = [:]
        var recipes: [String: Any] = [:]
        for (_, model) in snapshot.models {
            var provider = providers[model.providerKind] as? [String: Any]
                ?? ["resolveMap": [String: String](), "models": [String: Any]()]
            var resolveMap = provider["resolveMap"] as? [String: String] ?? [:]
            var models = provider["models"] as? [String: Any] ?? [:]
            resolveMap[model.modelId] = model.modelId
            var controls: [String: Any] = [:]
            for (capability, control) in model.capabilityControls {
                var encoded: [String: Any] = [:]
                if let state = control.state { encoded["state"] = state }
                if let recipeRef = control.recipeRef {
                    encoded["recipeRef"] = recipeRef
                    // The slice only carries recipe references; add an empty recipe body with this model's own protocol.
                    recipes[recipeRef] = [
                        "id": recipeRef,
                        "providerKind": model.providerKind,
                        "transport": ["protocol": model.transport],
                        "capability": capability,
                        "executionKind": "request_overlay",
                        "requestOps": [Any](),
                        "sourceRefs": [String](),
                    ]
                }
                if let reasonCode = control.reasonCode { encoded["reasonCode"] = reasonCode }
                if let intents = control.availableIntents { encoded["availableIntents"] = intents }
                controls[capability] = encoded
            }
            models[model.modelId] = [
                "canonicalModelId": model.modelId,
                "transport": model.transport,
                "capabilities": model.capabilities,
                "profiles": [String: Any](),
                "capabilityControls": controls,
            ]
            provider["resolveMap"] = resolveMap
            provider["models"] = models
            providers[model.providerKind] = provider
        }
        let payload: [String: Any] = [
            "version": 1,
            "providers": providers,
            "capabilityRuntime": [
                "schemaVersion": RequestPreferenceResolver.runtimeSchemaVersion,
                "revision": "sha256:model-option-capability-shape",
                "generatedAt": "2026-08-13T02:00:00Z",
                "recipes": recipes,
                "controlDefinitions": [String: Any](),
                "sourceIndex": [String: Any](),
            ],
        ]
        return String(
            decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            as: UTF8.self
        )
    }
}

/// Copy carried by the shape function ships with the English source and Simplified Chinese first; the
/// other 14 languages follow once each has been written and reviewed by a native speaker.
@Suite("Capability card shape copy")
struct ModelOptionCapabilityShapeCopyTests {
    private static let locales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    /// Strings still waiting for the other languages. This list may only shrink.
    private static let pendingFullLocalization: Set<String> = [
        "Thinks it through first, so answers take a little longer",
        "Always thinks before answering",
        "Higher levels take longer and may cost more.",
        "Uses the model’s default",
        "Oriveo doesn’t have thinking settings for this model yet, so it runs on its own default.",
        "Not available yet",
        "Oriveo doesn’t have web search settings for this model yet, so it can’t be turned on here.",
        "See which models can be adjusted",
        "This model has no thinking mode",
        "This model can’t search the web",
        "Needs manual setup",
        "This provider has no standard switch for web search. Add its fields in the additional request body.",
        "This provider has no standard switch for thinking. Add its fields in the additional request body.",
        "Open additional request body",
        "Choose this connection’s protocol first",
        "The protocol is still set to Auto, so Oriveo can’t tell how to send web search and thinking settings.",
        "Choose protocol",
        "Turns thinking on or off through the chat template. Whether it works depends on your server.",
        "This connection can’t do this",
        "“%@” was rejected",
        "Searches the web first when a question needs it",
        "On",
        "This model isn’t accepting “%1$@” right now, so it’s back on “%2$@”. The level will return on its own once the model supports it again.",
    ]

    @Test("Every string the shape function uses has an English source and Simplified Chinese; a key with all 16 languages must leave the pending list")
    func copyHasSourceAndSimplifiedChinese() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(
            contentsOf: root.appendingPathComponent("Oriveo").appendingPathComponent("Chat.xcstrings")
        )) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        func localizations(_ key: String) -> [String: Any] {
            (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
        }
        func value(_ key: String, _ locale: String) -> String? {
            ((localizations(key)[locale] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }

        let source = try String(
            contentsOf: ["Oriveo", "Features", "Chat", "ModelControls", "ModelOptionCapabilityShape.swift"]
                .reduce(root) { $0.appendingPathComponent($1) },
            encoding: .utf8
        )
        let pattern = try NSRegularExpression(pattern: #"L10n\.tr\(\s*"([^"]+)",\s*table: \.chat\s*\)"#)
        var used: Set<String> = []
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            if let range = Range(match.range(at: 1), in: source) { used.insert(String(source[range])) }
        }
        #expect(!used.isEmpty)

        // A key used by production code either has all 16 languages already (existing copy) or is on the pending list.
        let complete = used.filter { key in Self.locales.allSatisfy { localizations(key)[$0] != nil } }
        let pending = Self.pendingFullLocalization
        #expect(
            used.subtracting(complete) == pending,
            "keys used by production code differ from the pending list: \(used.subtracting(complete).symmetricDifference(pending))"
        )

        var problems: [String] = []
        for key in Self.pendingFullLocalization.sorted() {
            if value(key, "en") != key { problems.append("\(key) has no English source, or it differs from the key") }
            let simplifiedChinese = value(key, "zh-Hans") ?? ""
            if simplifiedChinese.isEmpty || simplifiedChinese == key {
                problems.append("\(key) [zh-Hans] has no translation")
            }
            // Once all 16 languages are present this fails, forcing the key off the list.
            if Self.locales.allSatisfy({ localizations(key)[$0] != nil }) {
                problems.append("\(key) has all 16 languages; remove it from pendingFullLocalization")
            }
        }
        #expect(problems.isEmpty, "\n\(problems.joined(separator: "\n"))")
    }
}
