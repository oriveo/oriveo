import Foundation
import Testing
@testable import Oriveo

/// The four model-option cards (contract cards BOARD-OPTIONS-01 to 10): the 2x2 capability grid, the three-state image / file
/// cards, the "sent this turn" summary bar, and the temperature row on the parameters card. Inputs for 01 to 05 go through the
/// production shape function `ModelOptionCapabilityShape` (called inside `ModelOptionsPanelModel.make`); assertions cover card kind, top-right control and status text.
@MainActor
@Suite("Model options four cards")
struct ModelOptionsBoardStructureTests {
    typealias Shape = ModelOptionCapabilityShape
    typealias Input = ModelOptionCapabilityShape.Input
    typealias Tiles = ModelOptionsTiles

    private static func chat(_ key: String) -> String { L10n.tr(key, table: .chat) }

    private static func facts(
        web: Input,
        reasoning: Input,
        chatTemplateThinking: ChatTemplateThinkingSwitch.State = .off,
        visionVisible: Bool = true,
        visionSupportUnknown: Bool = false,
        fileMode: NativeFileMode? = .always,
        nativeFileMimes: [String] = ["application/pdf"],
        pdfNativeDefault: Bool = false,
        relayFileRejected: Bool = false
    ) -> ModelOptionsPanelFacts {
        var facts = ModelOptionsPanelFacts(
            modelName: "Model", connectionName: "Connection", protocolLabel: "Responses",
            web: web, reasoning: reasoning
        )
        facts.chatTemplateThinking = chatTemplateThinking
        facts.visionVisible = visionVisible
        facts.visionSupportUnknown = visionSupportUnknown
        facts.fileMode = fileMode
        facts.nativeFileMimes = nativeFileMimes
        facts.pdfNativeDefault = pdfNativeDefault
        facts.relayFileRejected = relayFileRejected
        return facts
    }

    private static func officialWeb(_ selected: String = "automatic") -> Input {
        .init(capability: .web, presentation: .automaticAvailable, availableIntents: ["automatic"], selectedIntent: selected)
    }

    private static func officialReasoning(_ selected: String? = "balanced") -> Input {
        .init(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: ["off", "low", "balanced", "deep"], selectedIntent: selected
        )
    }

    // MARK: - BOARD-OPTIONS-01 to 05: the five shapes

    @Test("BOARD-OPTIONS-01 official BYOK: web toggle + thinking levels + image available + file in supported native formats")
    func officialByok() {
        let model = ModelOptionsPanelModel.make(Self.facts(web: Self.officialWeb(), reasoning: Self.officialReasoning()))
        #expect(model.tiles.map(\.kind) == [.web, .reasoning, .vision, .files])
        #expect(model.tiles.map(\.accessory) == [.toggle(isOn: true), .levelCount(4), .check, .check])
        #expect(model.tiles[0].status == Self.chat("Searches the web first when a question needs it"))
        #expect(model.tiles[1].status == ModelControlIntentLabel.text("balanced"))
        #expect(model.tiles[2].status == Self.chat("Available · photo picker shown"))
        #expect(model.tiles[3].status == Self.chat("Native when supported · others as text"))
        #expect(model.tiles[2].title == Self.chat("Vision"))
        #expect(model.tiles[3].title == L10n.tr("Files", table: .providers))
        // "%lld levels" counts the segments that can actually be tapped.
        #expect(model.tiles[1].levelCountText == String(format: Self.chat("%lld levels"), 4))
    }

    @Test("BOARD-OPTIONS-02 relay: chat-template toggle first, image unknown, file converted to text")
    func relayConnection() {
        let model = ModelOptionsPanelModel.make(Self.facts(
            web: .init(capability: .web, presentation: .unknown, connection: .custom),
            reasoning: .init(capability: .reasoning, presentation: .unknown, connection: .custom),
            chatTemplateThinking: .on,
            visionSupportUnknown: true,
            fileMode: .off
        ))
        #expect(model.tiles.map(\.kind) == [.reasoning, .web, .vision, .files])
        #expect(model.tiles[0].accessory == .toggle(isOn: true))
        #expect(model.tiles[2].accessory == .question)
        #expect(model.tiles[2].status == Self.chat("Unknown · remembered after sending"))
        #expect(model.tiles[3].accessory == .check)
        #expect(model.tiles[3].status == Self.chat("Sent as text"))
        // On a relay the web row is a tappable status row, not a control: nothing at the top right, the status line keeps the text the shape provides, and the whole card is tappable.
        guard case let .disclosure(disclosure) = model.tiles[1].row?.shape else {
            Issue.record("Web on a relay should be a status row: \(String(describing: model.tiles[1].row?.shape))")
            return
        }
        #expect(model.tiles[1].accessory == .chevron, "A fully tappable card draws a chevron at the top right")
        #expect(model.tiles[1].status == disclosure.status)
        #expect(model.tiles[1].isTappable)
    }

    @Test("BOARD-OPTIONS-05 subscription: web off, thinking levels with auto, file on the native route with text fallback")
    func subscription() {
        let model = ModelOptionsPanelModel.make(Self.facts(
            web: Self.officialWeb("off"),
            reasoning: .init(
                capability: .reasoning, presentation: .automaticAvailable,
                availableIntents: ["automatic", "low", "balanced", "deep", "max"]
            ),
            fileMode: .alwaysWithTextFallback
        ))
        #expect(model.tiles.map(\.accessory) == [.toggle(isOn: false), .levelCount(5), .check, .check])
        #expect(model.tiles[1].status == ModelControlIntentLabel.text("automatic"))
        #expect(model.tiles[3].status == Self.chat("Native when supported · others as text"))
    }

    @Test("BOARD-OPTIONS-05 Grok subscription: web is permanently on as a read-only Always on, not tappable, no chevron")
    func grokSubscriptionWebIsAlwaysOn() {
        let model = ModelOptionsPanelModel.make(Self.facts(
            web: .init(capability: .web, presentation: .alwaysOn, availableIntents: ["automatic"], selectedIntent: "off"),
            reasoning: .init(
                capability: .reasoning, presentation: .automaticAvailable,
                availableIntents: ["automatic", "low", "deep"]
            ),
            fileMode: .alwaysWithTextFallback
        ))
        #expect(model.tiles[0].accessory == Tiles.Accessory.none)
        #expect(!model.tiles[0].isTappable)
        #expect(model.tiles[0].status == Self.chat("Always on"))
        #expect(model.seal == .officialConfiguration)
    }

    @Test("Explanation cards with an action / single-row undecided-protocol cards: the whole card is tappable with a chevron at the top right; cards without an action draw none")
    func tappableTilesShowAChevron() {
        let link = Shape.Link(title: "go", action: .openSupportedModels)
        let notice = Tiles.tile(for: .init(capability: .reasoning, shape: .notice(.init(status: "s", body: "b", link: link))))
        #expect(notice.accessory == .chevron)
        #expect(notice.isTappable)
        let plainNotice = Tiles.tile(for: .init(capability: .reasoning, shape: .notice(.init(status: "s", body: "b", link: nil))))
        #expect(plainNotice.accessory == Tiles.Accessory.none)
        let undecided = Tiles.tile(for: .init(capability: .web, shape: .protocolUndecided(Shape.protocolCallout())))
        #expect(undecided.accessory == .chevron)
        #expect(undecided.isTappable)
        let readOnly = Tiles.tile(for: .init(capability: .web, shape: .disclosure(.init(status: "s", action: nil))))
        #expect(readOnly.accessory == Tiles.Accessory.none)
    }

    // MARK: - BOARD-OPTIONS-06 undecided protocol

    @Test("BOARD-OPTIONS-06 undecided protocol: only the full-width callout appears, no image / file cards")
    func protocolUndecidedOnlyShowsTheCallout() {
        let model = ModelOptionsPanelModel.make(Self.facts(
            web: .init(capability: .web, presentation: .unknown, connection: .custom, protocolUndecided: true),
            reasoning: .init(capability: .reasoning, presentation: .unknown, connection: .custom, protocolUndecided: true)
        ))
        guard case .callout = model.card else { Issue.record("Should collapse into a callout: \(model.card)"); return }
        #expect(model.tiles.isEmpty)
        #expect(model.summaryText == nil)
    }

    // MARK: - BOARD-OPTIONS-07 summary bar

    @Test("BOARD-OPTIONS-07 summary bar: web on / thinking at a non-auto level / thinking toggle on; with none of these the bar is not shown")
    func turnSummary() {
        let both = ModelOptionsPanelModel.make(Self.facts(web: Self.officialWeb(), reasoning: Self.officialReasoning("deep")))
        #expect(both.summary == [Self.chat("Web search on"), String(format: Self.chat("Thinking: %@"), ModelControlIntentLabel.text("deep"))])
        #expect(both.summaryText == String(
            format: Self.chat("This turn will send: %@"),
            "\(Self.chat("Web search on")) · \(String(format: Self.chat("Thinking: %@"), ModelControlIntentLabel.text("deep")))"
        ))

        // The auto level does not count as "actually sent"; web off is not listed either.
        let automatic = ModelOptionsPanelModel.make(Self.facts(
            web: Self.officialWeb("off"),
            reasoning: .init(
                capability: .reasoning, presentation: .automaticAvailable,
                availableIntents: ["automatic", "low", "deep"], selectedIntent: "automatic"
            )
        ))
        #expect(automatic.summary.isEmpty)
        #expect(automatic.summaryText == nil)

        // Thinking is only on or off: when on it is "Thinking on".
        let toggle = ModelOptionsPanelModel.make(Self.facts(
            web: Self.officialWeb("off"),
            reasoning: .init(
                capability: .reasoning, presentation: .automaticAvailable,
                availableIntents: ["off", "low"], selectedIntent: "low"
            )
        ))
        #expect(toggle.summary == [Self.chat("Thinking on")])

        // An enabled chat-template toggle counts as well.
        let template = ModelOptionsPanelModel.make(Self.facts(
            web: .init(capability: .web, presentation: .unknown, connection: .custom),
            reasoning: .init(capability: .reasoning, presentation: .unknown, connection: .custom),
            chatTemplateThinking: .on
        ))
        #expect(template.summary == [Self.chat("Thinking on")])

        // Web on with a timing row: still "Web on".
        let timing = ModelOptionsPanelModel.make(Self.facts(
            web: .init(
                capability: .web, presentation: .automaticAvailable,
                availableIntents: ["automatic", "force"], selectedIntent: "force"
            ),
            reasoning: Self.officialReasoning(nil)
        ))
        #expect(timing.summary == [Self.chat("Web search on")])
    }

    // MARK: - BOARD-OPTIONS-08 / 09 three-state decisions

    @Test("BOARD-OPTIONS-08 file three states: off / no allowlist / file negative cache -> text; otherwise pdfNativeDefault -> native PDF; otherwise native supported formats")
    func fileStates() {
        let pdf = ["application/pdf"]
        #expect(Tiles.files(mode: .off, nativeFileMimes: pdf, relayFileRejected: false, pdfNativeDefault: true) == .text)
        #expect(Tiles.files(mode: .always, nativeFileMimes: [], relayFileRejected: false, pdfNativeDefault: true) == .text)
        #expect(Tiles.files(mode: .alwaysWithTextFallback, nativeFileMimes: pdf, relayFileRejected: true, pdfNativeDefault: true) == .text)
        #expect(Tiles.files(mode: .always, nativeFileMimes: pdf, relayFileRejected: false, pdfNativeDefault: true) == .pdfNative)
        #expect(Tiles.files(mode: .alwaysWithTextFallback, nativeFileMimes: pdf, relayFileRejected: false, pdfNativeDefault: false) == .nativeWhenSupported)
        #expect(Tiles.files(mode: .always, nativeFileMimes: pdf, relayFileRejected: false, pdfNativeDefault: false) == .nativeWhenSupported)
        // All three states show a checkmark at the top right: a file can always be delivered.
        for state in [Tiles.FileState.text, .pdfNative, .nativeWhenSupported] {
            #expect(Tiles.filesTile(state).accessory == .check)
        }
    }

    @Test("BOARD-OPTIONS-09 image three states: entry not visible -> unavailable; visible and no positive relay evidence -> unknown; otherwise visible -> available")
    func visionStates() {
        #expect(Tiles.vision(isVisible: false, supportUnknown: true) == .hidden)
        #expect(Tiles.vision(isVisible: false, supportUnknown: false) == .hidden)
        #expect(Tiles.vision(isVisible: true, supportUnknown: true) == .unknown)
        #expect(Tiles.vision(isVisible: true, supportUnknown: false) == .available)
        #expect(Tiles.visionTile(.hidden).accessory == .cross)
        #expect(Tiles.visionTile(.hidden).status == Self.chat("Not available · photo picker hidden"))
        #expect(Tiles.visionTile(.unknown).accessory == .question)
        #expect(Tiles.visionTile(.available).accessory == .check)

        // "No positive evidence" uses the same predicate as the recorded decision: the production function returns false for an official model that inherited image.
        let provider = Provider(
            id: UUID(), kind: .relay, status: .connected, models: [], catalogModels: [],
            apiKey: "key", apiKeyPreview: "...key", baseURLText: "https://relay.test/v1",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )
        let plain = AIModel(
            id: "m", name: "m", capabilities: [.text],
            reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: ""
        )
        var vision = plain
        vision.capabilities = [.text, .image]
        #expect(RelayRejectionRecording.imageSupportUnknown(provider: provider, model: plain))
        #expect(!RelayRejectionRecording.imageSupportUnknown(provider: provider, model: vision))
    }

    @Test("BOARD-OPTIONS-09 the panel facts for image and file only call production functions and do not add their own criteria")
    func sheetReadsProductionPredicates() throws {
        let sheet = try Self.source(["Features", "Chat", "ModelControls", "ModelControlsSheet.swift"])
        let start = try #require(sheet.range(of: "private var panelFacts: ModelOptionsPanelFacts {"))
        let end = try #require(sheet.range(of: "private var banner:", range: start.upperBound..<sheet.endIndex))
        let facts = String(sheet[start.lowerBound..<end.lowerBound])
        for call in [
            "ChatView.photoPickerVisible(", "RelayRejectionRecording.imageSupportUnknown(",
            "AttachmentTransportResolver.resolve(", "AttachmentTransportResolver.deliveryModel(",
            "NativeFileFallback.isKnownTextOnly(",
        ] {
        #expect(facts.contains(call), "panelFacts does not call \(call)")
        }
        // The composer's photo-library entry and the panel's image card use the same function.
        let chatView = try Self.source(["Features", "Chat", "ChatView.swift"])
        let imageGate = try #require(chatView.range(of: "private var currentSupportsImageAttachment: Bool {"))
        let gateEnd = try #require(chatView.range(of: "private var currentSupportsVideoAttachment", range: imageGate.upperBound..<chatView.endIndex))
        #expect(chatView[imageGate.lowerBound..<gateEnd.lowerBound].contains("Self.photoPickerVisible("))
    }

    // MARK: - BOARD-OPTIONS-10 parameters card

    private static func row(_ id: String, _ value: String?) -> GenerationParameterRowModel {
        .init(id: id, title: GenerationParameterVocabulary.title(id), displayValue: value, source: .conversation)
    }

    @Test("BOARD-OPTIONS-10 parameters card: temperature gets its own row and the entry row's chip drops temperature; a model without temperature shows no such row")
    func temperatureRow() {
        var facts = Self.facts(web: Self.officialWeb(), reasoning: Self.officialReasoning())
        facts.advancedRows = [
            Self.row("temperature", "0.7"), Self.row("top_p", "0.9"), Self.row("max_output_tokens", "4096"),
        ]
        let model = ModelOptionsPanelModel.make(facts)
        #expect(model.temperature == .init(title: GenerationParameterVocabulary.title("temperature"), value: "0.7"))
        #expect(model.advanced.chips.map(\.id) == ["top_p", "max_output_tokens"])
        #expect(model.advanced.moreCount == 0)

        // With no value, use the row's existing default text.
        facts.advancedRows = [Self.row("temperature", nil), Self.row("top_p", "0.9")]
        #expect(ModelOptionsPanelModel.make(facts).temperature?.value
            == GenerationParameterPresentationFacts.unsetLabel(parameterID: "temperature"))

        facts.advancedRows = [Self.row("top_p", "0.9")]
        let without = ModelOptionsPanelModel.make(facts)
        #expect(without.temperature == nil)
        #expect(without.advanced.chips.map(\.id) == ["top_p"])
    }

    // MARK: - View structure

    @Test("The capability area is drawn as a 2x2 grid, collapsing to a single column at accessibility sizes; the summary bar and temperature row hang off the panel")
    func panelDrawsTheBoard() throws {
        let sheet = try Self.source(["Features", "Chat", "ModelControls", "ModelControlsSheet.swift"])
        let start = try #require(sheet.range(of: "struct ModelOptionsPanel: View {"))
        let end = try #require(sheet.range(of: "// MARK: - Route", range: start.upperBound..<sheet.endIndex))
        let panel = String(sheet[start.lowerBound..<end.lowerBound])
        #expect(panel.contains("dynamicTypeSize.isAccessibilitySize"))
        #expect(panel.contains("ModelOptionCapabilityTile("))
        #expect(panel.contains("model.summaryText"))
        #expect(panel.contains("model.temperature"))
        let components = try Self.source(["Features", "Chat", "ModelControls", "ModelControlsComponents.swift"])
        let tile = try #require(components.range(of: "struct ModelOptionCapabilityTile<"))
        let tileBody = components[tile.lowerBound...]
        // Capability colors come only from palette tokens, and icons only from Phosphor duotone.
        #expect(tileBody.contains("CapabilityPalette."))
        #expect(tileBody.contains(".image(.duotone)"))
    }

    private static func source(_ components: [String]) throws -> String {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = ["ios", "Oriveo", "Oriveo"] + components
        while current.path != current.deletingLastPathComponent().path {
            let candidate = relative.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            current = current.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
