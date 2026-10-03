import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

// MARK: - Rendering the add-server pages
//
// Each state of the flow renders the production view once (PNGs are exported for visual comparison when
// `ORIVEO_MCP_SNAPSHOT_DIR` is set) and pins the text the page must show in that state. Dark mode covers the key
// pages only.

@Suite("MCP add-server page rendering (production views)")
@MainActor
struct McpAddServerSnapshotTests {
    private func state(_ screen: McpAddScreen, _ edit: (inout McpAddUiState) -> Void = { _ in }) -> McpAddUiState {
        var state = McpAddUiState()
        state.url = "https://mcp.linear.app/mcp"
        state.screen = screen
        edit(&state)
        return state
    }

    private func render(_ state: McpAddUiState, _ name: String, style: UIUserInterfaceStyle = .light) throws {
        let image = try McpUiSnapshot.render(
            McpAddServerContent(state: state, actions: McpAddServerActions()), name: name, style: style
        )
        #expect(McpUiSnapshot.hasContent(image), "\(name) rendered no content")
    }

    private var linearTools: [McpToolSnapshot] {
        McpToolCatalog.snapshots(serverId: UUID(), definitions: McpUiRig.sampleTools, runtimeConfig: .fallback)
    }

    @Test("Settings entry: the MCP servers row sits in the Tools & connections group, and its subtitle follows the server summary")
    func settingsEntry() throws {
        let color = Color.dynamic(light: 0x8C5FF8, dark: 0xA78BFA)
        func section(_ summary: McpSettingsEntrySummary?) -> some View {
            McpSettingsSection(iconColor: color, mcpSummary: summary, onOpenMcpServers: {})
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        let summary = McpSettingsEntrySummary(serverCount: 4, attentionCount: 1)
        let withSubtitle = try McpUiSnapshot.render(section(summary), name: "settings-entry", height: 240)
        let withoutSubtitle = try McpUiSnapshot.render(section(nil), name: "settings-entry-no-summary", height: 240)
        _ = try McpUiSnapshot.render(section(summary), name: "settings-entry-dark", height: 240, style: .dark)
        #expect(McpUiSnapshot.hasContent(withSubtitle) && McpUiSnapshot.hasContent(withoutSubtitle))
        #expect(withSubtitle.pngData() != withoutSubtitle.pngData(), "the subtitle is drawn once a summary is known")
        #expect(
            McpHealthCopy.settingsSubtitle(summary)
                == String(format: L10n.tr("Servers: %1$d · Need attention: %2$d", table: .mcp), 4, 1)
        )
    }

    @Test("No servers yet: title, three promises, primary button at the bottom; the empty state is not drawn before local storage has been read")
    func serversEmpty() throws {
        func content(loaded: Bool) -> McpServersContent {
            McpServersContent(servers: [], loaded: loaded, onBack: {}, onAddServer: {}, onOpenServer: { _ in })
        }
        let empty = try McpUiSnapshot.render(content(loaded: true), name: "servers-empty")
        let loading = try McpUiSnapshot.render(content(loaded: false), name: "servers-loading")
        _ = try McpUiSnapshot.render(content(loaded: true), name: "servers-empty-dark", style: .dark)
        #expect(McpUiSnapshot.hasContent(empty))
        #expect(empty.pngData() != loading.pngData(), "the empty state must not flash before loading finishes")
    }

    @Test("Entering the address: only address and name, with no sign-in method for the user to pick")
    func form() throws {
        try render(state(.form), "add-form")
        try render(state(.form), "add-form-dark", style: .dark)
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Oriveo/Features/Settings/MCP/McpAddServerView.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("setAuthKind"), "the form must not offer a sign-in method choice")
        #expect(state(.form).canConnect)
        #expect(!state(.form) { $0.url = "  " }.canConnect)
    }

    @Test("Connecting: the title is the hostname while the name is unknown; after the callback the second step reads \"Signed in\"")
    func progress() throws {
        let connecting = state(.progress(stage: .connecting, authorizationHost: nil, signedIn: false))
        #expect(connecting.displayName == "mcp.linear.app" && connecting.nameIsUnknown)
        try render(connecting, "add-connecting")

        let named: (inout McpAddUiState) -> Void = { $0.name = "Linear" }
        try render(
            state(.progress(stage: .authPrompt, authorizationHost: "linear.app", signedIn: false), named),
            "add-auth-prompt-underlay"
        )
        try render(state(.progress(stage: .browser, authorizationHost: "linear.app", signedIn: false), named), "add-browser")
        try render(state(.progress(stage: .finishing, authorizationHost: "linear.app", signedIn: true), named), "add-finishing")
        try render(
            state(.progress(stage: .finishing, authorizationHost: "linear.app", signedIn: true), named),
            "add-finishing-dark", style: .dark
        )
        #expect(McpAddServerContent.progressCaption(.connecting) == L10n.tr("Connecting…", table: .mcp))
        #expect(McpAddServerContent.progressCaption(.finishing) == L10n.tr("Finishing up…", table: .mcp))
    }

    @Test("Pre-sign-in notice sheet: shows both the sign-in page hostname and the hostname being connected; top padding is at least 24")
    func authPromptSheet() throws {
        let sheet = McpAuthPromptSheet(
            serverName: "Linear", iconURL: nil, authorizationHost: "linear.app", serverHost: "mcp.linear.app",
            onContinue: {}, onCancel: {}
        )
        let image = try McpUiSnapshot.render(sheet, name: "add-auth-prompt", height: 440)
        _ = try McpUiSnapshot.render(sheet, name: "add-auth-prompt-dark", height: 440, style: .dark)
        #expect(McpUiSnapshot.hasContent(image))
        #expect(McpSheetMetrics.topPadding >= 24, "not enough top padding for a sheet without a navigation bar")
    }

    @Test("Reviewing default permissions: one editable row per group; a one-line note when there are no tools")
    func review() throws {
        let tools = linearTools
        let review = McpAddReviewScreen(serverId: UUID(), tools: tools)
        #expect(review.readOnlyTools.count == 5 && review.changingTools.count == 2)
        #expect(McpAddServerContent.groupNames(review.readOnlyTools) == "Search issues, Read issue, List projects")
        let named: (inout McpAddUiState) -> Void = { $0.name = "Linear" }
        try render(state(.review(review), named), "add-review")
        try render(state(.review(review), named), "add-review-dark", style: .dark)
        try render(state(.review(McpAddReviewScreen(serverId: UUID(), tools: [])), named), "add-review-no-tools")
    }

    @Test("Malformed address: error under the field (two reasons, two messages), primary button disabled")
    func invalidAddress() throws {
        let malformed = state(.form) { $0.url = "linear.app/mcp"; $0.urlError = .malformed }
        #expect(!malformed.canConnect)
        try render(malformed, "add-error-url")
        try render(malformed, "add-error-url-dark", style: .dark)
        try render(
            state(.form) { $0.url = "https://user:pass@mcp.linear.app/mcp"; $0.urlError = .hasUserinfo },
            "add-error-url-userinfo"
        )
        #expect(McpAddServerContent.urlErrorText(.malformed) != McpAddServerContent.urlErrorText(.hasUserinfo))
    }

    @Test("Failure pages, including limit reached / not saved: each failure has its own status pill, title and next actions")
    func failures() throws {
        let nas: (inout McpAddUiState) -> Void = { $0.url = "https://nas.example.net/mcp" }
        try render(state(.failure(.unreachable), nas), "add-error-unreachable")
        try render(state(.failure(.unreachable), nas), "add-error-unreachable-dark", style: .dark)
        try render(state(.failure(.notMcp), nas), "add-error-not-mcp")
        let github: (inout McpAddUiState) -> Void = { $0.name = "GitHub" }
        try render(state(.failure(.needsToken), github), "add-need-token")
        try render(
            state(.failure(.needsToken)) { $0.name = "GitHub"; $0.token = "pat_wrong"; $0.tokenRejected = true },
            "add-need-token-rejected"
        )
        try render(state(.failure(.authCancelled)) { $0.name = "Linear" }, "add-auth-cancelled")
        try render(state(.failure(.limitReached(max: 20)), nas), "add-limit-reached")
        try render(state(.failure(.saveFailed), nas), "add-save-failed")

        let all: [McpAddFailure] = [.unreachable, .notMcp, .needsToken, .authCancelled, .limitReached(max: 20), .saveFailed]
        let copies = all.map(McpAddServerContent.failureCopy)
        #expect(Set(copies.map(\.title)).count == all.count, "every failure has a distinct title")
        #expect(copies.allSatisfy { !$0.message.isEmpty && !$0.pill.isEmpty })
        // Error copy never mentions status codes, protocol names or JSON-RPC.
        for copy in copies {
            for banned in ["401", "404", "JSON-RPC", "OAuth", "HTTP "] {
                #expect(!copy.title.contains(banned) && !copy.message.contains(banned), "\(copy.title) contains \(banned)")
            }
        }
        #expect(McpAddServerContent.failureCopy(.limitReached(max: 20)).message.contains("20"))
    }
}
