import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

@Suite("ChatToolbar long model names")
struct ChatToolbarLongModelNameTests {

    @Test("Toolbar Model Title Uses Two Lines")
    func toolbarModelTitleUsesTwoLines() throws {
        let source = try String(contentsOf: chatSourceURL("ChatToolbar.swift"), encoding: .utf8)
        let titleSource = try source.requiredSlice(
            from: "Text(realtimeModelName ?? currentModel?.name ?? pendingModelName ?? L10n.tr(\"Choose Model\"))",
            to: "HStack(spacing: 4)"
        )

        #expect(titleSource.contains(".lineLimit(2)"))
        #expect(titleSource.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(titleSource.contains(".layoutPriority(1)"))
    }

    @Test("Realtime-selected: regular and Duo vertical-bar model names both get a cyan dot; text models do not")
    func realtimeSelectedPutsDotBeforeBothModelNames() throws {
        let source = try String(contentsOf: chatSourceURL("ChatToolbar.swift"), encoding: .utf8)
        let title = "Text(realtimeModelName ?? currentModel?.name ?? pendingModelName ?? L10n.tr(\"Choose Model\"))"
        let dotThenTitle = "if realtimeSelected {\n"
        #expect(source.contains("var realtimeSelected: Bool = false"), "New parameter defaults to false: text models and existing callers get no dot")

        let regular = try source.requiredSlice(from: "VStack(alignment: .leading, spacing: 2) {\n                            HStack(spacing: 6)", to: title)
        #expect(regular.contains(dotThenTitle))
        #expect(regular.contains("RealtimeModelDot()"))

        let vertical = try source.requiredSlice(from: "private var verticalBarModelLabel", to: title)
        #expect(vertical.contains(dotThenTitle))
        #expect(vertical.contains("RealtimeModelDot()"))
        // Both places add the dot only in the realtimeSelected branch.
        #expect(source.components(separatedBy: "RealtimeModelDot()").count - 1 == 2)
        #expect(source.components(separatedBy: "if realtimeSelected {").count - 1 == 2)

        let chatView = try String(contentsOf: chatSourceURL("ChatView.swift"), encoding: .utf8)
        let call = try chatView.requiredSlice(from: "ChatToolbar(\n", to: "isSendingMessage: isSendingMessage")
        #expect(call.contains("realtimeSelected: appState.realtimeModelSelection(for: projection.activeConversationID) != nil"))
    }

    @Test("Realtime-selected: regular and Duo vertical-bar model names equal the realtime model name, never falling back to the default text model name")
    func realtimeSelectedShowsRealtimeModelName() throws {
        let source = try String(contentsOf: chatSourceURL("ChatToolbar.swift"), encoding: .utf8)
        #expect(source.contains("var realtimeModelName: String? = nil"), "New parameter defaults to nil: text models and existing callers unchanged")
        let title = "Text(realtimeModelName ?? currentModel?.name ?? pendingModelName ?? L10n.tr(\"Choose Model\"))"
        #expect(source.components(separatedBy: title).count - 1 == 2)
        #expect(!source.contains("Text(currentModel?.name"))

        let chatView = try String(contentsOf: chatSourceURL("ChatView.swift"), encoding: .utf8)
        let call = try chatView.requiredSlice(from: "ChatToolbar(\n", to: "isSendingMessage: isSendingMessage")
        #expect(call.contains("realtimeModelName: Self.toolbarRealtimeModelName("))
        #expect(call.contains("selection: appState.realtimeModelSelection(for: projection.activeConversationID)"))
        #expect(call.contains("awaitsCatalog: toolbarAwaitsVoiceCatalog"))
    }

    @Test("While the voice catalog has not arrived, the top-bar model name uses the session-stored id, not the provider default; after the catalog arrives, the realtime selected name is used as before")
    func awaiting_catalog_shows_stored_model_id() {
        // Catalog not arrived: no realtime decision yet (selection is nil); the top bar shows the session-stored value, and currentModel must not fall back to the default text model.
        #expect(ChatView.toolbarRealtimeModelName(
            selection: nil, awaitsCatalog: true, storedModelID: "gemini-3.8-live"
        ) == "gemini-3.8-live")
        // After the catalog arrives: use the realtime selected name as before.
        let selection = RealtimeModelSelection(providerID: UUID(), providerKind: .gemini, model: "gemini-3.8-live")
        #expect(ChatView.toolbarRealtimeModelName(
            selection: selection, awaitsCatalog: false, storedModelID: "gemini-3.8-live"
        ) == "gemini-3.8-live")
        // Text model: does not wait for the catalog and has no realtime selection, so nil; currentModel supplies the name.
        #expect(ChatView.toolbarRealtimeModelName(
            selection: nil, awaitsCatalog: false, storedModelID: "gemini-4-argon"
        ) == nil)
    }

    @Test("Cyan dot: theme token 6 pt plus a same-color soft glow, not read by screen readers")
    func realtimeDotUsesThemeTokenAndIsDecorative() throws {
        let dot = try String(
            contentsOf: chatSourceURL("Voice").appendingPathComponent("RealtimeModelDot.swift"), encoding: .utf8
        )
        #expect(RealtimeModelDot.diameter == 6)
        #expect(dot.contains(".fill(OriveoTheme.Palette.realtimeDot)"))
        #expect(dot.contains(".shadow(color: OriveoTheme.Palette.realtimeDot"))
        #expect(dot.contains(".accessibilityHidden(true)"))

        let light = UIColor(OriveoTheme.Palette.realtimeDot).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = UIColor(OriveoTheme.Palette.realtimeDot).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        for color in [light, dark] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            #expect(Int((r * 255).rounded()) == 0x22)
            #expect(Int((g * 255).rounded()) == 0xD3)
            #expect(Int((b * 255).rounded()) == 0xEE)
            #expect(a == 1)
        }
    }

    @Test("Realtime-selected top-bar model name for screen readers: label = model name, value = 'Realtime voice', no hard-coded separator (same convention as Android stateDescription)")
    func realtime_model_label_reads_realtime_voice() throws {
        let tag = L10n.tr("Realtime Voice", table: .voice)
        #expect(ChatToolbar.modelNameAccessibilityValue(realtime: true) == tag)
        #expect(ChatToolbar.modelNameAccessibilityValue(realtime: false) == "")
        let source = try String(contentsOf: chatSourceURL("ChatToolbar.swift"), encoding: .utf8)
        // The model name label is handed to Text itself; no longer concatenated as "name, Realtime voice".
        #expect(!source.contains("modelNameAccessibilityLabel"))
        #expect(!source.contains("name + \", \""))
        #expect(source.components(separatedBy: ".accessibilityValue(modelNameAccessibilityValue)").count - 1 == 2)
    }

    @Test("The cyan dot can be found by UI tests via realtime_model_dot; screen readers do not read it separately")
    func realtime_dot_has_identifier() throws {
        #expect(RealtimeModelDot.accessibilityIdentifier == "realtime_model_dot")
        let source = try String(contentsOf: chatSourceURL("ChatToolbar.swift"), encoding: .utf8)
        // The button merges label children: the identifier sits on the container outside the button, present only when realtime-selected.
        let switcher = try source.requiredSlice(from: "showModelSwitcher = true", to: "if hasInstructions")
        #expect(switcher.contains(".realtimeModelDotAnchor(realtimeSelected)"))
        let dot = try String(
            contentsOf: chatSourceURL("Voice").appendingPathComponent("RealtimeModelDot.swift"), encoding: .utf8
        )
        let anchor = try dot.requiredSlice(from: "func realtimeModelDotAnchor", to: "\n}\n")
        #expect(anchor.contains("VStack(spacing: 0) { self }"), "The container wraps the button from outside; the button's own accessibility element is unchanged")
        #expect(anchor.contains(".accessibilityElement(children: .contain)"))
        #expect(anchor.contains(".accessibilityIdentifier(realtimeSelected ? RealtimeModelDot.accessibilityIdentifier : \"\")"))
    }

    private func chatSourceURL(_ filename: String) -> URL {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Chat")
            .appendingPathComponent(filename)
    }
}

private extension String {
    func requiredSlice(from start: String, to end: String) throws -> String {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.upperBound..<endIndex) else {
            throw SliceError.missingBoundary
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}

private enum SliceError: Error {
    case missingBoundary
}
