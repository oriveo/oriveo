import CoreGraphics
import Foundation
import Testing
@testable import Oriveo

/// **What the whole model options panel draws**: the status seal, which of the two rows comes first, removing a way forward that leads nowhere, the notes at the bottom of the card,
/// the summary on the "Advanced settings" row, and how tall the panel is. Under test are `ModelOptionsPanelModel.make` and the pure functions next to it;
/// the panel view only draws the result (structural constraints are in `ModelControlsPanelStructureTests`).
@MainActor
@Suite("Model options panel model")
struct ModelOptionsPanelModelTests {
    typealias Shape = ModelOptionCapabilityShape
    typealias Input = ModelOptionCapabilityShape.Input

    private static func facts(
        web: Input = .init(capability: .web, presentation: .automaticAvailable, selectedIntent: "off"),
        reasoning: Input = .init(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: ["low", "balanced", "deep"], selectedIntent: "balanced"
        )
    ) -> ModelOptionsPanelFacts {
        .init(
            modelName: "Model", connectionName: "Connection", protocolLabel: "Chat Completions",
            web: web, reasoning: reasoning
        )
    }

    private static func custom(_ capability: Shape.Capability) -> Input {
        .init(capability: capability, presentation: .unknown, connection: .custom)
    }

    private static func rows(_ model: ModelOptionsPanelModel) -> [ModelOptionsPanelModel.Row] {
        guard case let .rows(rows) = model.card else { return [] }
        return rows
    }

    // MARK: - Status seal

    @Test("status seal: an official configuration → official, a custom connection without one → unverified, an official connection not in the catalog yet → none")
    func sealFollowsWhoProvidesTheSettings() {
        #expect(ModelOptionsSeal.resolve(
            connection: .official, presentations: [.unsupported, .automaticAvailable]
        ) == .officialConfiguration)
        // "Cannot be done", stated by the catalog, is a verdict of the official configuration as well.
        #expect(ModelOptionsSeal.resolve(
            connection: .official, presentations: [.unsupported, .unsupported]
        ) == .officialConfiguration)
        #expect(ModelOptionsSeal.resolve(
            connection: .custom, presentations: [.unknown, .unknown]
        ) == .unverified)
        // A custom connection that matches an official configuration is handled like an official one.
        #expect(ModelOptionsSeal.resolve(
            connection: .custom, presentations: [.unknown, .automaticAvailable]
        ) == .officialConfiguration)
        #expect(ModelOptionsSeal.resolve(
            connection: .official, presentations: [.pending, .unknown]
        ) == nil)
        for seal in ModelOptionsSeal.allCases {
            #expect(!seal.title.isEmpty)
        }
    }

    // MARK: - Rows and order

    @Test("official connection: the order is fixed as web search, thinking, and the header carries connection, protocol and seal as they are")
    func officialConnectionKeepsWebThenReasoning() {
        let model = ModelOptionsPanelModel.make(Self.facts())
        #expect(Self.rows(model).map(\.capability) == [.web, .reasoning])
        #expect(model.title == "Model")
        #expect(model.connectionName == "Connection")
        #expect(model.protocolLabel == "Chat Completions")
        #expect(model.seal == .officialConfiguration)
        #expect(model.banner == nil)
        #expect(model.notes.isEmpty)
        #expect(model.scopeUpgrade == nil)
    }

    @Test("custom connection without an official configuration: thinking is the chat template toggle and comes first, the web search row says it cannot be done, the seal is unverified")
    func customConnectionPutsTheTemplateSwitchFirst() {
        var facts = Self.facts(web: Self.custom(.web), reasoning: Self.custom(.reasoning))
        let off = ModelOptionsPanelModel.make(facts)
        #expect(off.seal == .unverified)
        let rows = Self.rows(off)
        #expect(rows.map(\.capability) == [.reasoning, .web])
        guard case let .toggle(toggle) = rows[0].shape else {
            Issue.record("thinking should be a toggle, got \(rows[0].shape)")
            return
        }
        #expect(toggle.target == .chatTemplateThinking)
        #expect(!toggle.isOn)
        #expect(toggle.link?.action == .openAdditionalRequestBody)
        #expect(rows[1].shape == .disclosure(.init(
            status: L10n.tr("This connection can’t do this", table: .chat), action: .switchConnection
        )))

        // The toggle's displayed value only comes from the state read from the additional request body.
        facts.chatTemplateThinking = .on
        guard case let .toggle(on) = Self.rows(ModelOptionsPanelModel.make(facts))[0].shape else {
            Issue.record("thinking should be a toggle")
            return
        }
        #expect(on.isOn)
    }

    @Test("the additional request body has other fields and is not being sent: the thinking row offers no toggle and sends the user there to turn sending on first")
    func templateSwitchDoesNotTurnSendingOnForOtherFields() {
        var facts = Self.facts(web: Self.custom(.web), reasoning: Self.custom(.reasoning))
        facts.chatTemplateThinking = .notSending
        let rows = Self.rows(ModelOptionsPanelModel.make(facts))
        #expect(rows.map(\.capability) == [.reasoning, .web])
        guard case let .notice(notice) = rows[0].shape else {
            Issue.record("flipping a toggle now would send the other fields along, so none should be offered; got \(rows[0].shape)")
            return
        }
        #expect(notice.body == L10n.tr(
            "The additional request body isn’t being sent with requests right now. Turn that on there first.",
            table: .chat
        ))
        #expect(notice.link?.action == .openAdditionalRequestBody)
    }

    @Test("custom connection whose protocol applies no chat template: thinking is a note with a link to the additional request body, and web search is first again")
    func customConnectionWithoutChatTemplateGetsManualSetup() {
        var reasoning = Self.custom(.reasoning)
        reasoning.supportsChatTemplate = false
        let rows = Self.rows(ModelOptionsPanelModel.make(Self.facts(web: Self.custom(.web), reasoning: reasoning)))
        #expect(rows.map(\.capability) == [.web, .reasoning])
        guard case let .notice(notice) = rows[1].shape else {
            Issue.record("no chat template toggle should be offered, got \(rows[1].shape)")
            return
        }
        #expect(notice.link?.action == .openAdditionalRequestBody)
    }

    @Test("the stored additional request body has a problem: the thinking row offers no toggle, explains why and points to where it can be fixed")
    func blockedTemplateSwitchBecomesANoticeWithAWayOut() {
        var facts = Self.facts(web: Self.custom(.web), reasoning: Self.custom(.reasoning))
        facts.chatTemplateThinking = .blocked
        let rows = Self.rows(ModelOptionsPanelModel.make(facts))
        // The position does not jump: it still comes first.
        #expect(rows.map(\.capability) == [.reasoning, .web])
        guard case let .notice(notice) = rows[0].shape else {
            Issue.record("with broken content there must be no toggle that would overwrite it, got \(rows[0].shape)")
            return
        }
        #expect(notice.link?.action == .openAdditionalRequestBody)
        #expect(!notice.body.isEmpty)
        #expect(!notice.status.isEmpty)
    }

    @Test("undecided protocol: the whole card collapses into one thing")
    func undecidedProtocolCollapsesTheCard() {
        var web = Self.custom(.web)
        web.protocolUndecided = true
        var reasoning = Self.custom(.reasoning)
        reasoning.protocolUndecided = true
        let model = ModelOptionsPanelModel.make(Self.facts(web: web, reasoning: reasoning))
        guard case let .callout(callout) = model.card else {
            Issue.record("an undecided protocol should collapse the whole card into one thing, got \(model.card)")
            return
        }
        #expect(callout.link.action == .openConnectionProtocol)
    }

    // MARK: - Ways forward that lead nowhere

    @Test("no other model to switch to in this connection: the see-which-models link is removed instead of opening an empty list")
    func emptyModelListIsNotOfferedAsAWayOut() {
        let unsupported = Self.facts(
            web: .init(capability: .web, presentation: .unsupported),
            reasoning: .init(capability: .reasoning, presentation: .pending)
        )
        let reachable = Self.rows(ModelOptionsPanelModel.make(unsupported))
        guard case let .disclosure(web) = reachable[0].shape, case let .notice(reasoning) = reachable[1].shape else {
            Issue.record("precondition: the two rows should be a status row and a note")
            return
        }
        #expect(web.action == .openSupportedModels)
        #expect(reasoning.link?.action == .openSupportedModels)

        var stranded = unsupported
        stranded.hasWebCandidates = false
        stranded.hasReasoningCandidates = false
        let rows = Self.rows(ModelOptionsPanelModel.make(stranded))
        guard case let .disclosure(deadWeb) = rows[0].shape, case let .notice(deadReasoning) = rows[1].shape else {
            Issue.record("the shape should not change for lack of candidates")
            return
        }
        // Status and body stay; it just no longer pretends to be tappable.
        #expect(deadWeb.action == nil)
        #expect(deadWeb.status == web.status)
        #expect(deadReasoning.link == nil)
        #expect(deadReasoning.body == reasoning.body)

        // Other ways forward are unaffected.
        let other = Shape.disclosure(.init(status: "x", action: .switchConnection))
        #expect(other.withoutEmptyModelList(hasCandidates: false) == other)
    }

    // MARK: - Notes at the bottom of the card

    @Test("a preference taken over by custom request fields is said right in the card with a link to advanced settings; the risk notice only appears during a takeover")
    func takeoverIsVisibleInTheCard() {
        var facts = Self.facts()
        facts.customFieldRiskTiers = ["privacy_impacting"]
        // While the fields are not rewriting the request the risk notice has no subject and is not shown.
        #expect(ModelOptionsPanelModel.make(facts).notes.isEmpty)

        facts.takenOverByCustomFields = [.reasoning]
        let notes = ModelOptionsPanelModel.make(facts).notes
        #expect(notes.count == 2)
        #expect(notes[0].opensAdvancedSettings)
        #expect(notes[0].tone == .warning)
        #expect(notes[1].text == L10n.tr("This field can send your data to a third-party service.", table: .chat))
        #expect(!notes[1].opensAdvancedSettings)
    }

    @Test("the provider rejected web search: the bottom of the card says so")
    func upstreamWebRejectionIsSaid() {
        var facts = Self.facts()
        facts.webRejectedUpstream = true
        let notes = ModelOptionsPanelModel.make(facts).notes
        #expect(notes.map(\.id) == ["web-rejected"])
        #expect(notes[0].tone == .warning)
    }

    // MARK: - The "Advanced settings" row

    private static func row(
        _ id: String, _ value: String?, source: GenerationParameterResolution.Source = .conversation,
        dropReason: GenerationParameterApplication.DropReason? = nil
    ) -> GenerationParameterRowModel {
        .init(
            id: id, title: GenerationParameterVocabulary.title(id), displayValue: value,
            source: source, dropReason: dropReason
        )
    }

    @Test("the summary only shows items changed in this conversation that will be sent: two chips at most, the rest only counted, in the order of the rows passed in")
    func advancedSummaryShowsSentConversationOverridesOnly() {
        var facts = Self.facts()
        facts.advancedRows = [
            Self.row("top_k", "40", source: .modelDefault),
            Self.row("temperature", "0.7"),
            Self.row("stop", nil),
            Self.row("max_output_tokens", "4096"),
            Self.row("top_p", "0.9"),
            Self.row("seed", "42"),
            Self.row("frequency_penalty", nil, source: .providerDecides),
        ]
        let advanced = ModelOptionsPanelModel.make(facts).advanced
        #expect(advanced.chips.map(\.id) == ["temperature", "max_output_tokens"])
        #expect(advanced.chips.map(\.value) == ["0.7", "4096"])
        #expect(advanced.chips[0].title == GenerationParameterVocabulary.title("temperature"))
        #expect(advanced.moreCount == 2)
    }

    @Test("nothing changed: no chips and no remaining count")
    func advancedSummaryIsEmptyWhenNothingChanged() {
        let none = ModelOptionsPanelModel.make(Self.facts()).advanced
        #expect(none.chips.isEmpty)
        #expect(none.moreCount == 0)
    }

    // MARK: - Header subtitle

    @Test("first segment: the engine name when the connection declares an engine type, the connection name otherwise")
    func subjectNameFollowsTheDeclaredEngine() {
        let names = ["llamacpp": "llama.cpp", "ollama": "Ollama", "lmstudio": "LM Studio", "vllm": "vLLM", "openwebui": "Open WebUI"]
        #expect(Set(names.keys) == Set(LocalEngineKind.allCases.map(\.rawValue)), "the engine enum changed; this table has to follow")
        for (profile, name) in names {
            #expect(ModelOptionsSubject.name(connectionName: "My box", engineProfile: profile) == name)
        }
        #expect(ModelOptionsSubject.name(connectionName: "My box", engineProfile: nil) == "My box")
        #expect(ModelOptionsSubject.name(connectionName: "My box", engineProfile: "something-new") == "My box")
    }

    @Test("second segment: on this device when the host of the API root is a loopback address, the protocol name otherwise")
    func subjectDetailSaysLocalForLoopbackHosts() {
        for root in [
            "http://localhost:8080", "http://127.0.0.1:11434/v1", "http://[::1]:1234/v1",
            "localhost:8080", "127.0.0.1", " HTTP://LOCALHOST:8080/v1 ",
        ] {
            #expect(ModelOptionsSubject.isLoopback(apiRoot: root), "\(root) should count as this device")
        }
        for root in [
            "http://192.168.1.20:8080", "https://api.example.com/v1", "http://localhost.example.com",
            "http://127.0.0.1.example.com", "https://example.com/localhost", "", "not a url",
        ] {
            #expect(!ModelOptionsSubject.isLoopback(apiRoot: root), "\(root) should not count as this device")
        }
        #expect(!ModelOptionsSubject.isLoopback(apiRoot: nil))

        var facts = Self.facts(web: Self.custom(.web), reasoning: Self.custom(.reasoning))
        facts.connectionName = "My llama"
        facts.engineProfile = "llamacpp"
        facts.apiRoot = "http://127.0.0.1:8080"
        let local = ModelOptionsPanelModel.make(facts)
        #expect(local.connectionName == "llama.cpp")
        #expect(local.protocolLabel == L10n.tr("Local", table: .chat))
        #expect(local.seal == .unverified)

        facts.apiRoot = "http://192.168.1.20:8080"
        #expect(ModelOptionsPanelModel.make(facts).protocolLabel == "Chat Completions")
    }

    // MARK: - Read-only banner

    @Test("no settings-are-read-only banner while the panel has a control that can be flipped; shown as usual when everything is read-only")
    func readOnlyBannerYieldsToAWritableControl() {
        let banner = ModelOptionsPanelModel.Banner(text: "read-only", action: .refetch)
        // Custom connection, snapshot not fetched: the chat template toggle writes the additional request body and still works.
        var writable = Self.facts(web: Self.custom(.web), reasoning: Self.custom(.reasoning))
        writable.banner = banner
        #expect(ModelOptionsPanelModel.make(writable).banner == nil)

        // Official connection, snapshot not fetched: both rows are read-only and the banner has to be there.
        var readOnly = Self.facts(
            web: .init(capability: .web, presentation: .automaticAvailable, selectedIntent: "off", isWritable: false),
            reasoning: .init(
                capability: .reasoning, presentation: .automaticAvailable,
                availableIntents: ["low", "deep"], selectedIntent: "low", isWritable: false
            )
        )
        readOnly.banner = banner
        #expect(ModelOptionsPanelModel.make(readOnly).banner == banner)

        // While the toggle cannot write (broken content) it does not count as a control that can be flipped.
        writable.chatTemplateThinking = .blocked
        #expect(ModelOptionsPanelModel.make(writable).banner == banner)
    }

    // MARK: - Clearing the selection

    @Test("without Automatic, tapping the selected level again goes back to the model’s default; with Automatic that gesture is not needed")
    func tappingTheSelectedTierClearsItOnlyWithoutAnAutomaticTier() {
        typealias Control = ModelOptionSegmentedControl
        func tiers(_ intents: [String], selected: String?) -> Shape.Tiers? {
            guard case let .tiers(tiers) = Shape.resolve(.init(
                capability: .reasoning, presentation: .automaticAvailable,
                availableIntents: intents, selectedIntent: selected
            )) else { return nil }
            return tiers
        }
        let plain = tiers(["low", "balanced", "deep"], selected: "balanced")
        #expect(plain?.allowsClearing == true)
        #expect(Control.tap(on: "balanced", selection: plain?.selection, allowsClearing: true) == .cleared)
        #expect(Control.tap(on: "deep", selection: plain?.selection, allowsClearing: true) == .selected("deep"))

        let withAutomatic = tiers(["automatic", "low", "deep"], selected: "low")
        #expect(withAutomatic?.allowsClearing == false)
        #expect(Control.tap(on: "low", selection: withAutomatic?.selection, allowsClearing: false) == .ignored)
        #expect(Control.tap(on: "automatic", selection: "low", allowsClearing: false) == .selected("automatic"))
        // When nothing was chosen, tapping any segment selects it.
        #expect(Control.tap(on: "low", selection: nil, allowsClearing: true) == .selected("low"))
        // The search timing row always has one segment selected and cannot be cleared.
        #expect(Control.tap(on: "automatic", selection: "automatic", allowsClearing: false) == .ignored)
    }

    // MARK: - Panel height

    @Test("the height is the content height with no bottom safe area added; half the screen rather than full when it cannot be measured; full after a second-level page is pushed")
    func sheetHeightFollowsContentWithAHalfScreenFallback() {
        // `.height` measures the part inside the safe area: the system reserves the safe area below it, and adding it here would leave a blank strip.
        #expect(ModelOptionsSheetHeight.resolve(contentHeight: 420, hasPushedPage: false) == .fitted(420))
        #expect(ModelOptionsSheetHeight.resolve(contentHeight: 420.2, hasPushedPage: false) == .fitted(421))
        // Not measured yet, an invalid value, or the impossible reading a lazy container gives.
        for unusable: CGFloat in [0, -1, .infinity, .nan, .greatestFiniteMagnitude, 10_000] {
            #expect(
                ModelOptionsSheetHeight.resolve(contentHeight: unusable, hasPushedPage: false) == .half,
                "a content height of \(unusable) must not be taken as real"
            )
        }
        #expect(ModelOptionsSheetHeight.resolve(contentHeight: 300, hasPushedPage: true) == .full)
    }

    // MARK: - Joining notes

    @Test("several notes joined into one paragraph: no space after full-width punctuation, one after a half-width period")
    func footnotesJoinWithoutASpaceAfterFullWidthPunctuation() {
        #expect(ModelOptionsText.joined(["\u{901F}\u{5EA6}\u{548C}\u{6DF1}\u{5EA6}\u{517C}\u{987E}\u{3002}", "\u{6863}\u{4F4D}\u{8D8A}\u{9AD8}\u{8D8A}\u{6162}\u{FF0C}\u{4E5F}\u{53EF}\u{80FD}\u{66F4}\u{8D35}\u{3002}"]) == "\u{901F}\u{5EA6}\u{548C}\u{6DF1}\u{5EA6}\u{517C}\u{987E}\u{3002}\u{6863}\u{4F4D}\u{8D8A}\u{9AD8}\u{8D8A}\u{6162}\u{FF0C}\u{4E5F}\u{53EF}\u{80FD}\u{66F4}\u{8D35}\u{3002}")
        #expect(ModelOptionsText.joined(["\u{771F}\u{7684}\u{5417}\u{FF1F}", "\u{662F}\u{7684}\u{FF01}", "\u{597D}"]) == "\u{771F}\u{7684}\u{5417}\u{FF1F}\u{662F}\u{7684}\u{FF01}\u{597D}")
        #expect(
            ModelOptionsText.joined(["A balance of speed and depth.", "Higher levels take longer."])
                == "A balance of speed and depth. Higher levels take longer."
        )
        #expect(ModelOptionsText.joined(["", "Only one.", ""]) == "Only one.")
        #expect(ModelOptionsText.joined([]) == "")
        // Production copy: joined in Simplified Chinese, these two sentences must not contain a full-width period followed by a space.
        guard case let .tiers(tiers) = Shape.resolve(.init(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: ["low", "balanced", "deep", "max"], selectedIntent: "balanced"
        )) else {
            Issue.record("several levels should be segments")
            return
        }
        #expect(tiers.footnotes.count == 2)
        #expect(!ModelOptionsText.joined(tiers.footnotes).contains("\u{3002} "))
    }

    // MARK: - Level icons

    @Test("level icons: more effort lights more bars; Off and Automatic are not bars")
    func tierGlyphBarsGrowWithEffort() {
        #expect(["low", "balanced", "deep", "max"].map(ModelOptionTierGlyph.filledBars(for:)) == [1, 2, 3, 4])
        #expect(ModelOptionTierGlyph.filledBars(for: "off") == nil)
        #expect(ModelOptionTierGlyph.filledBars(for: Shape.automaticIntent) == nil)
    }
}

/// New copy on the panel ships with the English source and Simplified Chinese first; the
/// other 14 languages follow once each has been written and reviewed by a native speaker.
@Suite("Model options panel copy")
struct ModelOptionsPanelCopyTests {
    private static let locales = [
        "ar", "de", "en", "es", "fr", "hi", "id", "ja", "ko", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    /// Strings still waiting for the other languages. This list may only shrink.
    private static let pendingFullLocalization: Set<String> = [
        "When needed",
        "Every message",
        "%lld more",
        "Can’t switch here yet",
        "The additional request body has a problem, so this switch can’t change it. Fix it there first.",
        "The additional request body isn’t being sent with requests right now. Turn that on there first.",
        "Local",
    ]

    /// Earlier keys that this panel replaced and that no call site uses any more: they must not stay in the string catalog or be referenced again.
    private static let retiredKeys = [
        "Search when needed",
        "Search every message",
        "When on, the model searches the web when it helps before answering.",
        "Cannot adjust yet",
        "Not supported by this model",
        "This model has no official thinking configuration yet. Oriveo doesn’t guess.",
        "This model has no official web search configuration. Oriveo doesn’t guess, to avoid failed requests.",
        "This model cannot turn thinking off.",
        "Higher levels are usually slower and can cost more. The provider and model decide what actually runs.",
        "%d adjusted",
        "Set the protocol",
        "View supported models",
        "This connection supports custom configuration only.",
        "This capability is unavailable for this connection.",
        "Automatic configuration is not ready for this connection yet.",
        "Automatic configuration is unavailable for the current model route.",
    ]

    private static func catalogStrings() throws -> [String: Any] {
        let root = projectRoot()
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(
            contentsOf: root.appendingPathComponent("Oriveo").appendingPathComponent("Chat.xcstrings")
        )) as? [String: Any])
        return try #require(catalog["strings"] as? [String: Any])
    }

    private static func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("every new string on the panel has an English source and Simplified Chinese; a key with all 16 languages must leave the pending list")
    func copyHasSourceAndSimplifiedChinese() throws {
        let strings = try Self.catalogStrings()
        func localizations(_ key: String) -> [String: Any] {
            (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
        }
        func value(_ key: String, _ locale: String) -> String? {
            ((localizations(key)[locale] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }

        // A Chat-table key used in the panel's sources either has all 16 languages already or is on the pending list.
        let directory = ["Oriveo", "Features", "Chat", "ModelControls"].reduce(Self.projectRoot()) {
            $0.appendingPathComponent($1)
        }
        let pattern = try NSRegularExpression(pattern: #"L10n\.tr\(\s*"([^"]+)",\s*table: \.chat\s*\)"#)
        var used: Set<String> = ["When needed", "Every message"]
        for name in ["ModelControlsSheet.swift", "ModelControlsComponents.swift", "ModelControlCapabilityLayout.swift"] {
            let source = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let range = Range(match.range(at: 1), in: source) { used.insert(String(source[range])) }
            }
        }
        // Keys shared with the shape function and registered on its pending list are not registered twice.
        let registeredElsewhere: Set<String> = ["On", "Open additional request body"]
        // English is the source language, and an existing key does not always carry its own en entry; with the other 15 languages present it counts as complete.
        func isComplete(_ key: String) -> Bool {
            Self.locales.filter { $0 != "en" }.allSatisfy { localizations(key)[$0] != nil }
        }
        let incomplete = used.filter { !isComplete($0) }.subtracting(registeredElsewhere)
        let pending = Self.pendingFullLocalization
        #expect(
            incomplete == pending,
            "keys used by the panel differ from the pending list: \(incomplete.symmetricDifference(pending))"
        )

        var problems: [String] = []
        for key in Self.pendingFullLocalization.sorted() {
            if value(key, "en") != key { problems.append("\(key) has no English source, or it differs from the key") }
            let simplifiedChinese = value(key, "zh-Hans") ?? ""
            if simplifiedChinese.isEmpty || simplifiedChinese == key {
                problems.append("\(key) [zh-Hans] has no translation")
            }
            if isComplete(key) {
                problems.append("\(key) has all 16 languages; remove it from pendingFullLocalization")
            }
        }
        #expect(problems.isEmpty, "\n\(problems.joined(separator: "\n"))")
    }

    @Test("replaced strings are gone from the string catalog and referenced nowhere in the project")
    func retiredCopyIsGone() throws {
        let strings = try Self.catalogStrings()
        for key in Self.retiredKeys {
            #expect(strings[key] == nil, "Chat.xcstrings still has a key without any call site: \(key)")
        }
        let sources = Self.projectRoot().appendingPathComponent("Oriveo")
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for key in Self.retiredKeys where text.contains("\"\(key)\"") {
                offenders.append("\(url.lastPathComponent): \(key)")
            }
        }
        #expect(offenders.isEmpty, "still referencing removed strings: \(offenders)")
    }
}
