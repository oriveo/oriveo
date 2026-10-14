import Foundation
import Testing
@testable import Oriveo

/// The "add model manually" page (board ManualModel). Relays and official providers share one page with the same layout.
/// Layout and text assertions use the production row model `ManualModelBoardModel`; saving is asserted against the production save path `AppState.saveManualModel`.
@Suite("Add model manually board · BOARD-MANUALMODEL", .serialized)
@MainActor
struct ManualModelBoardTests {
    private typealias Board = ManualModelBoardModel

    private static let relayNotes = [
        "Enter the model ID exactly as your Custom Relay lists it.",
        "What it can do is remembered after you send a message, or you can test it under Advanced.",
    ]

    private static let viewPath = "Features/Providers/ManualModelEntryView.swift"

    private func catalogKeys(_ table: String) throws -> Set<String> {
        let data = try Data(contentsOf: ProductionSource.root.appendingPathComponent("\(table).xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        return Set(strings.keys)
    }

    // MARK: - BOARD-MANUALMODEL-01

    @Test("BOARD-MANUALMODEL-01 relay: input slot + two description lines + primary button; placeholder comes from RelayModelPlaceholder; no preview card / example / Hero")
    func board01RelayLayout() throws {
        let board = Board.make(isRelay: true, input: "")
        #expect(board.sections == [.modelSlot, .notes])
        #expect(board.title == .init(key: "Add Model", table: .providers))
        #expect(board.slotTitle == .init(key: "Model ID", table: .localizable))
        // The placeholder is the flagship model ID delivered by the server (spec section 6.2), neither a hint sentence nor a hardcoded example.
        #expect(board.placeholder == .verbatim(RelayModelPlaceholder.current))
        #expect(board.notes == Self.relayNotes.map { Board.Copy(key: $0, table: .providers) })
        #expect(board.primaryAction == .init(key: "Save", table: .localizable))
        #expect(board.secondaryAction == nil)
        // A model ID is a technical value and is laid out left to right even in RTL languages.
        #expect(board.forcesLeftToRightValue)

        // Both description lines exist in all 16 languages and no longer say "custom LLM".
        for key in Self.relayNotes {
            let values = try ProductionSource.localizations(table: "Providers", key: key)
            #expect(values.count == 16, "\(key)")
            #expect(values["en"] == key)
            for (language, value) in values {
                #expect(!value.localizedCaseInsensitiveContains("LLM"), "\(language): \(value)")
                #expect(!value.contains("\u{81EA}\u{5B9A}\u{4E49} LLM") && !value.contains("\u{81EA}\u{8A02} LLM"), "\(language): \(value)")
            }
        }

        // The page renders only what the row model gives: the old Hero / preview card / example / underline animation / glow shadow are all gone.
        let source = try ProductionSource.read(Self.viewPath)
        #expect(source.contains("ManualModelBoardModel.make("))
        for removed in [
            "spotlightHero", "spotlightBadge", "previewCard", "examplesSection", "animatedUnderline",
            "relayExamples", "ManualEntryExampleSuggestion", "ExampleListRow", "ManualEntryFlow",
            "sparkles", "primaryGlow", "LinearGradient", "Image(systemName:", ".stroke(",
            "manual_model_entry_example_row",
        ] {
            #expect(!source.contains(removed), "\(removed)")
        }
        #expect(source.contains("OriveoBackButton {"))
        #expect(source.contains("PhosphorIcon.x"))
        #expect(source.contains(".environment(\\.layoutDirection, board.forcesLeftToRightValue ? .leftToRight : layoutDirection)"))
        // The input slot has a VoiceOver name and does not rely on the placeholder alone.
        #expect(source.contains(".accessibilityLabel(L10n.tr(board.slotTitle.key, table: board.slotTitle.table))"))

        // Old-wording text is cleared out of the resources.
        let providers = try catalogKeys("Providers")
        for key in [
            "Enter a model ID your relay supports.",
            "Use the exact model ID exposed by your relay.",
            "For example: gpt-image-2 or claude-4-sonnet",
            "Tap to fill",
        ] {
            #expect(!providers.contains(key), "\(key)")
        }
        let localizable = try catalogKeys("Localizable")
        for key in ["Common examples", "Default capabilities", "Will be added"] {
            #expect(!localizable.contains(key), "\(key)")
        }
    }

    // MARK: - BOARD-MANUALMODEL-02

    @Test("BOARD-MANUALMODEL-02 official provider: same layout, the text keys and Retry Sync are still there")
    func board02OfficialProviderKeepsCopy() throws {
        let board = Board.make(isRelay: false, input: "")
        let relay = Board.make(isRelay: true, input: "")
        #expect(board.sections == relay.sections)
        #expect(board.slotTitle == relay.slotTitle)
        #expect(board.title == .init(key: "Fallback Model", table: .providers))
        #expect(board.placeholder == .localized(.init(key: "For example: claude-4-sonnet or gpt-4o", table: .providers)))
        #expect(board.notes == [.init(
            key: "Just enter one usable model ID. You don't need to understand the protocol details.",
            table: .providers
        )])
        #expect(board.primaryAction == .init(key: "Save & Continue", table: .providers))
        #expect(board.secondaryAction == .init(key: "Retry Sync", table: .providers))
        // The official-mode placeholder is a localized hint sentence and follows the interface direction.
        #expect(!board.forcesLeftToRightValue)

        let providers = try catalogKeys("Providers")
        for copy in [board.title, board.primaryAction] + board.notes + [board.secondaryAction].compactMap({ $0 }) {
            #expect(providers.contains(copy.key), "\(copy.key)")
        }
        #expect(providers.contains("For example: claude-4-sonnet or gpt-4o"))

        // The retry-sync action and its telemetry event are kept unchanged.
        let source = try ProductionSource.read(Self.viewPath)
        #expect(source.contains("Task { await retrySync() }"))
        #expect(source.contains("try await appState.resyncProvider(providerID: provider.id)"))
    }

    // MARK: - BOARD-MANUALMODEL-03

    @Test("BOARD-MANUALMODEL-03 an empty input disables the primary button; after saving, the model enters the enabled list with text capability only (relay, spec section 4.2)")
    func board03EmptyDisabledAndSaveIsTextOnly() throws {
        for isRelay in [true, false] {
            for blank in ["", "   ", "\n\t"] {
                let board = Board.make(isRelay: isRelay, input: blank)
                #expect(!board.isPrimaryEnabled)
                #expect(board.trimmedModelID.isEmpty)
            }
            #expect(!Board.make(isRelay: isRelay, input: "").showsClear)
            // The clear button follows whether the slot has any characters, not the trimmed result: typing only spaces can still be cleared in one tap.
            #expect(Board.make(isRelay: isRelay, input: "  ").showsClear)
        }
        let filled = Board.make(isRelay: true, input: "  my-relay-model \n")
        #expect(filled.isPrimaryEnabled)
        #expect(filled.showsClear)
        #expect(filled.trimmedModelID == "my-relay-model")

        let state = AppState(seedDemoData: false, sessionUID: "manual-model-\(UUID().uuidString)")
        _ = state.providerManager.registerRelay(
            name: "relay",
            endpoint: "https://relay.example.com/v1",
            apiKey: "sk-test",
            relayRequested: RelayRequestedConfig(transport: .openaiChatCompletions)
        )
        let providerID = try #require(state.providers.first { $0.kind == .relay }?.id)

        let didSave = state.saveManualModel(
            providerID: providerID,
            modelID: filled.trimmedModelID,
            context: .providerDetail
        )
        #expect(didSave)
        let provider = try #require(state.provider(for: providerID))
        let saved = try #require(provider.models.first { $0.id.hasSuffix("my-relay-model") })
        #expect(Set(saved.capabilities) == [.text])
        #expect(Set(saved.capabilities) == ProviderManager.defaultManualModelCapabilities(for: .relay))
    }
}
