import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

// MARK: - Rendering the management pages

@Suite("MCP management page rendering (production views)")
@MainActor
struct McpServerManagementSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(_ name: String, url: String, localOnly: Bool = false, authKind: McpAuthKind = .auto) -> McpServerRecord {
        McpServerRecord(name: name, slug: McpSlug.make(from: name), url: url, authKind: authKind, localOnly: localOnly)
    }

    private func summary(
        _ name: String, _ url: String, _ health: McpServerHealth, tools: Int, lastSuccessAt: Date? = nil
    ) -> McpServerSummary {
        McpServerSummary(record: record(name, url: url), health: health, toolCount: tools, lastSuccessAt: lastSuccessAt)
    }

    private func detail(
        _ name: String = "Linear",
        url: String = "https://mcp.linear.app/mcp",
        health: McpServerHealth = .connected,
        signIn: McpServerSignIn = .browser,
        localOnly: Bool = false,
        pending: Set<String> = [],
        permissions: [String: McpToolPermission] = [:]
    ) -> McpServerDetail {
        let record = record(name, url: url, localOnly: localOnly)
        let snapshots = McpToolCatalog.snapshots(
            serverId: record.id, definitions: McpUiRig.sampleTools, runtimeConfig: .fallback
        ).map { snapshot -> McpToolSnapshot in
            var copy = snapshot
            copy.pendingReview = pending.contains(snapshot.toolName)
            return copy
        }
        var merged = McpToolCatalog.defaultPermissions(for: snapshots)
        for (key, value) in permissions { merged[key] = value }
        return McpServerDetail(
            summary: McpServerSummary(record: record, health: health, toolCount: snapshots.count, lastSuccessAt: now),
            snapshots: snapshots, permissions: merged, signIn: signIn
        )
    }

    private func render(
        _ state: McpServerDetailUiState, _ name: String, height: CGFloat = 1090, style: UIUserInterfaceStyle = .light
    ) throws {
        let image = try McpUiSnapshot.render(
            McpServerDetailContent(state: state, actions: McpServerDetailActions()), name: name, height: height, style: style
        )
        #expect(McpUiSnapshot.hasContent(image), "\(name) rendered no content")
    }

    @Test("Server list: one card per server; each of the four states has its own pill and caption")
    func serverList() throws {
        let servers = [
            summary("Linear", "https://mcp.linear.app/mcp", .connected, tools: 7, lastSuccessAt: now),
            summary("Notion", "https://mcp.notion.com/mcp", .connected, tools: 14, lastSuccessAt: now),
            summary("GitHub", "https://api.githubcopilot.com/mcp", .needsAuth, tools: 9),
            summary("Home NAS", "https://nas.example.net/mcp", .unreachable, tools: 3, lastSuccessAt: now.addingTimeInterval(-3 * 86_400)),
            summary("Zapier", "https://hooks.example.org/…/mcp", .needsAddress, tools: 2),
            summary("Stripe", "https://mcp.stripe.com/mcp", .needsReview, tools: 5),
        ]
        func content() -> McpServersContent {
            McpServersContent(servers: servers, loaded: true, onBack: {}, onAddServer: {}, onOpenServer: { _ in })
        }
        let image = try McpUiSnapshot.render(content(), name: "servers", height: 1000)
        _ = try McpUiSnapshot.render(content(), name: "servers-dark", height: 1000, style: .dark)
        #expect(McpUiSnapshot.hasContent(image))
        #expect(McpHealthCopy.caption(servers[0]) == String(format: L10n.tr("Tools: %d", table: .mcp), 7))
        #expect(McpHealthCopy.caption(servers[2]) == L10n.tr("Needs sign-in again", table: .mcp))
        #expect(McpHealthCopy.caption(servers[3], now: now)?.isEmpty == false)
        #expect(McpHealthCopy.caption(servers[4]) == nil, "the pill already says the address is needed, so the caption does not repeat it")
        #expect(McpHealthCopy.caption(servers[5]) == L10n.tr("Review before use", table: .mcp))
    }

    @Test("Server detail: hero card + two tool groups, 3 shown per group by default with the rest collapsed; dark mode has the same structure")
    func serverDetail() throws {
        var state = McpServerDetailUiState(detail: detail(permissions: ["update_issue": .off]), loaded: true)
        try render(state, "server-detail")
        try render(state, "server-detail-dark", style: .dark)
        state.expandedReadOnly = true
        try render(state, "server-detail-expanded")
        #expect(!state.toolsDisabled)
        #expect(McpServerDetailContent.signInLabel(.browser) == L10n.tr("Browser sign-in", table: .mcp))
        #expect(McpServerDetailContent.heroCaption(state.detail!) == String(format: L10n.tr("Tools: %d", table: .mcp), 7))
    }

    @Test("Single tool permission: the server's description verbatim + a three-way choice; tools that modify data recommend Ask every time, read-only tools recommend Run automatically")
    func toolPermission() throws {
        let detail = detail()
        let create = try #require(detail.snapshots.first { $0.toolName == "create_issue" })
        let search = try #require(detail.snapshots.first { $0.toolName == "search_issues" })
        func sheet(_ tool: McpToolSnapshot, _ permission: McpToolPermission) -> McpToolPermissionSheet {
            McpToolPermissionSheet(serverName: "Linear", tool: tool, permission: permission, onSelect: { _ in })
        }
        let image = try McpUiSnapshot.render(sheet(create, .ask), name: "tool-permission", height: 600)
        _ = try McpUiSnapshot.render(sheet(create, .auto), name: "tool-permission-auto-write", height: 600)
        _ = try McpUiSnapshot.render(sheet(search, .auto), name: "tool-permission-read", height: 600)
        _ = try McpUiSnapshot.render(sheet(create, .ask), name: "tool-permission-dark", height: 600, style: .dark)
        #expect(McpUiSnapshot.hasContent(image))
        #expect(McpToolPermissionSheet.descriptionText(create).hasPrefix("Create a new issue"), "the description shows the server's text verbatim")
        #expect(McpToolPermission.defaultFor(readOnly: create.readOnly) == .ask)
        #expect(McpToolPermission.defaultFor(readOnly: search.readOnly) == .auto)
    }

    @Test("Authorization expired: the hero card button becomes the primary Reauthorize button and the tool list is dimmed; sign-in not completed / unreachable each have their own notice")
    func serverReauth() throws {
        var state = McpServerDetailUiState(
            detail: detail("GitHub", url: "https://api.githubcopilot.com/mcp", health: .needsAuth), loaded: true
        )
        #expect(state.toolsDisabled)
        #expect(McpServerDetailContent.heroCaption(state.detail!) == L10n.tr("Tools unavailable for now", table: .mcp))
        try render(state, "server-reauth")
        try render(state, "server-reauth-dark", style: .dark)
        state.notice = .signInNotCompleted
        try render(state, "server-reauth-not-completed")
        state.notice = nil
        state.busy = true
        try render(state, "server-reauth-busy")

        let token = McpTokenEntrySheet(token: "", rejected: false, busy: false, onChange: { _ in }, onSave: {}, onCancel: {})
        _ = try McpUiSnapshot.render(token, name: "server-reauth-token", height: 400)
        let rejected = McpTokenEntrySheet(token: "pat_wrong", rejected: true, busy: false, onChange: { _ in }, onSave: {}, onCancel: {})
        _ = try McpUiSnapshot.render(rejected, name: "server-reauth-token-rejected", height: 420)
    }

    @Test("Tools updated: one row per kind of change; the permission after confirmation is shown on the row; a notice appears if they changed again during confirmation")
    func toolsChanged() throws {
        let changes = [
            McpPendingToolChange(
                kind: .added, toolName: "bulk_update", title: "Bulk update issues", readOnly: false,
                permissionAfter: .ask, description: "Update many issues at once.", previousDescription: nil
            ),
            McpPendingToolChange(
                kind: .changed, toolName: "search_issues", title: "Search issues", readOnly: true,
                permissionAfter: .auto, description: "Search issues across teams.", previousDescription: "Search issues."
            ),
            McpPendingToolChange(
                kind: .removed, toolName: "list_projects", title: "List projects", readOnly: true,
                permissionAfter: nil, description: nil, previousDescription: nil
            ),
        ]
        func sheet(again: Bool) -> McpToolsChangedSheet {
            McpToolsChangedSheet(
                serverName: "Linear", iconURL: nil, changes: changes, changedAgain: again, busy: false,
                onConfirm: {}, onPause: {}
            )
        }
        let image = try McpUiSnapshot.render(sheet(again: false), name: "tools-changed", height: 520)
        _ = try McpUiSnapshot.render(sheet(again: true), name: "tools-changed-again", height: 560)
        _ = try McpUiSnapshot.render(sheet(again: false), name: "tools-changed-dark", height: 520, style: .dark)
        #expect(McpUiSnapshot.hasContent(image))
        #expect(McpToolsChangedSheet.pill(.added).text == L10n.tr("New", table: .mcp))
        #expect(McpToolsChangedSheet.pill(.changed).text == L10n.tr("Description changed", table: .mcp))
        #expect(McpToolsChangedSheet.pill(.removed).text == L10n.tr("Removed", table: .mcp))
        #expect(McpToolsChangedSheet.hint(changes[0]) == "\(L10n.tr("Changes data", table: .mcp)) · \(L10n.tr("Ask every time", table: .mcp))")
        #expect(McpToolsChangedSheet.hint(changes[2]) == L10n.tr("No longer offered by the server", table: .mcp))

        var state = McpServerDetailUiState(
            detail: detail(health: .needsReview, pending: ["search_issues"]), loaded: true
        )
        state.pendingChanges = changes
        try render(state, "server-needs-review")
    }

    @Test("Remove confirmation: a centered dialog over the detail page")
    func removeConfirm() throws {
        var state = McpServerDetailUiState(detail: detail(), loaded: true)
        state.overlay = .removeConfirm
        try render(state, "remove-confirm", height: 844)
        try render(state, "remove-confirm-dark", height: 844, style: .dark)
    }

    @Test("Re-entering the address: the hero card offers an input field when the server's full address is not on this device, and a rejected address shows an error under it")
    func needsAddress() throws {
        var state = McpServerDetailUiState(
            detail: detail(
                "Zapier", url: "https://hooks.example.org/…/mcp", health: .needsAddress, signIn: .notNeeded, localOnly: true
            ),
            loaded: true
        )
        #expect(state.toolsDisabled)
        try render(state, "server-detail-needs-address")
        state.address = "https://evil.example.com/mcp"
        state.notice = .addressRejected
        try render(state, "server-detail-needs-address-rejected")
        try render(state, "server-detail-needs-address-dark", style: .dark)
    }

    @Test("Sheet top padding is at least 24, and the content has no lazy containers (the sheet height is derived from the content height)")
    func sheetChrome() throws {
        #expect(McpSheetMetrics.topPadding >= 24)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Features/Settings/MCP", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 6)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for lazy in ["LazyVStack", "LazyVGrid", "LazyHStack", "List {", "List("] {
                #expect(!source.contains(lazy), "\(file.lastPathComponent) contains \(lazy)")
            }
        }
    }
}
