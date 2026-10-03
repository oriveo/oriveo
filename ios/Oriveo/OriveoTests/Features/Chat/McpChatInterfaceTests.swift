import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

// MARK: - MCP UI on the chat page
//
// The display decisions are pure functions (the content of the step block, the tools panel and the confirmation
// dialog) and are pinned here one by one. The production cell and the three sheets are then actually rendered,
// and PNGs are exported for visual comparison when `ORIVEO_MCP_SNAPSHOT_DIR` is set.

private let serverA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!
private let serverB = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000B2")!

private func step(
    _ number: Int,
    _ status: McpToolStep.Status,
    server: String = "Linear",
    title: String = "Search issues",
    summary: String = "open · bug",
    errorCode: String? = nil
) -> McpToolStep {
    McpToolStep(
        id: "\(number):call_\(number)", serverId: serverA.uuidString.lowercased(), serverName: server,
        toolName: "tool_\(number)", title: title, argsSummary: summary, status: status, errorCode: errorCode,
        step: number, durationMs: status == .done ? 1_200 : nil
    )
}

@Suite("MCP step block display decisions")
struct McpToolStepsPresentationTests {
    @Test("Running: the title reads \"Using tools\" and the trailing text is the index of the running step; a running row does not open details")
    func running() {
        let presentation = McpToolStepsPresentation.make(
            steps: [step(1, .done), step(2, .done), step(3, .running, server: "Notion", title: "Find page")],
            isGenerating: true
        )
        #expect(presentation.header == .running)
        #expect(presentation.trailing == .step(3))
        #expect(presentation.isActive)
        #expect(presentation.rows.map(\.opensDetail) == [true, true, false])
        #expect(presentation.rows[2].detail == .argsSummary("open · bug"))
    }

    @Test("Between two steps (no running step but the message is still generating) it still counts as in progress and keeps the latest step's index")
    func betweenSteps() {
        let presentation = McpToolStepsPresentation.make(steps: [step(1, .done), step(2, .done)], isGenerating: true)
        #expect(presentation.header == .running)
        #expect(presentation.trailing == .step(2))
    }

    @Test("Finished: the number in the title counts only completed steps; the trailing text lists server names (deduplicated in order of appearance)")
    func finished() {
        let presentation = McpToolStepsPresentation.make(
            steps: [step(1, .done), step(2, .done), step(3, .done, server: "Notion"), step(4, .done, server: "Notion")],
            isGenerating: false
        )
        #expect(presentation.header == .finished(usedCount: 4))
        #expect(presentation.trailing == .servers(["Linear", "Notion"]))
        #expect(!presentation.isActive)
        #expect(presentation.rows.map(\.opensDetail) == [true, true, true, true])
    }

    @Test("With declined or failed steps the trailing text becomes a count; failure outranks declined; needing re-authorization counts as a failure")
    func deniedAndFailed() {
        let denied = McpToolStepsPresentation.make(
            steps: [step(1, .done), step(2, .done), step(3, .done), step(4, .denied, errorCode: "user_denied")],
            isGenerating: false
        )
        #expect(denied.header == .finished(usedCount: 3))
        #expect(denied.trailing == .declined(1))
        #expect(denied.rows[3].detail == .declined)

        let failed = McpToolStepsPresentation.make(
            steps: [
                step(1, .failed, errorCode: "timeout"), step(2, .denied), step(3, .needsAuth, errorCode: "needs_auth"),
            ],
            isGenerating: false
        )
        #expect(failed.header == .finished(usedCount: 0))
        #expect(failed.trailing == .failed(2))
        #expect(failed.rows[0].detail == .failure(code: "timeout"))
        #expect(failed.rows[2].detail == .signInExpired(serverName: "Linear"))
    }

    @Test("Message no longer generating while a step is still running: drawn as interrupted, and details can be opened")
    func staleRunningIsInterrupted() {
        let presentation = McpToolStepsPresentation.make(steps: [step(1, .done), step(2, .running)], isGenerating: false)
        #expect(presentation.rows[1].status == .interrupted)
        #expect(presentation.rows[1].detail == .interrupted)
        #expect(presentation.rows[1].opensDetail)
        #expect(presentation.header == .finished(usedCount: 1))
    }

    @Test("Authorization expires midway: generating with needs_auth as the last step means waiting for re-authorization; no longer paused once skipped or the answer has ended")
    func pausedForSignIn() {
        let pausedSteps = [step(1, .done), step(2, .done), step(3, .needsAuth, server: "Notion", errorCode: "needs_auth")]
        let paused = McpToolStepsPresentation.make(steps: pausedSteps, isGenerating: true)
        #expect(paused.header == .waitingForSignIn)
        #expect(paused.trailing == .step(3))
        #expect(paused.pausedForSignIn?.id == "3:call_3")
        #expect(paused.rows[2].detail == .signInExpired(serverName: "Notion"))

        let skipped = McpToolStepsPresentation.make(
            steps: [step(1, .done), step(2, .needsAuth, errorCode: "auth_skipped")], isGenerating: true
        )
        #expect(skipped.pausedForSignIn == nil && skipped.header == .running)

        let ended = McpToolStepsPresentation.make(steps: pausedSteps, isGenerating: false)
        #expect(ended.pausedForSignIn == nil)
        #expect(ended.header == .finished(usedCount: 2) && ended.trailing == .failed(1))
    }

    @Test("The limit footer row only appears after the answer has ended")
    func limitNoteOnlyAfterFinish() {
        let steps = (1...6).map { step($0, .done) }
        #expect(!McpToolStepsPresentation.make(steps: steps, isGenerating: true, limitReached: true).limitReached)
        #expect(McpToolStepsPresentation.make(steps: steps, isGenerating: false, limitReached: true).limitReached)
    }

    @Test("With more than 5 steps the earlier ones collapse and only the last 2 stay; 5 or fewer are not collapsed")
    func collapsesEarlierSteps() {
        let eight = McpToolStepsPresentation.make(steps: (1...8).map { step($0, .done) }, isGenerating: false)
        #expect(eight.hiddenEarlierCount == 6)
        let five = McpToolStepsPresentation.make(steps: (1...5).map { step($0, .done) }, isGenerating: false)
        #expect(five.hiddenEarlierCount == 0)
    }
}

@Suite("MCP tools panel data")
struct McpToolPanelModelTests {
    private func snapshot(_ name: String, server: UUID, readOnly: Bool = true, pendingReview: Bool = false) -> McpToolSnapshot {
        McpToolSnapshot(
            serverId: server, toolName: name, title: name, description: "Tool \(name)",
            inputSchema: .object(JSONObject([("type", .string("object"))])),
            annotations: .object(JSONObject([("readOnlyHint", .bool(readOnly))])),
            contentHash: sha256Hex("\(server):\(name)"), readOnly: readOnly, pendingReview: pendingReview, oversized: false
        )
    }

    private func add(
        _ database: McpTestDatabase, id: UUID, name: String, url: String,
        tools: [McpToolSnapshot], permissions: [String: McpToolPermission] = [:],
        status: McpConnectionStatus, lastSuccessAt: Date? = nil
    ) throws {
        try database.store.addServer(
            McpServerAddition(
                id: id, name: name, url: url, authKind: .auto, localOnly: false, iconURL: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000), snapshots: tools, permissions: permissions,
                connectionState: McpConnectionState(
                    serverId: id, status: status, lastSuccessAt: lastSuccessAt, generation: .stateless
                )
            ),
            maxServers: 20
        )
    }

    private func load(
        _ database: McpTestDatabase, conversation: UUID,
        config: McpRuntimeConfig = .fallback, availability: McpToolAvailability = .available
    ) throws -> McpToolPanelState {
        try McpToolPanelModel.load(
            conversationId: conversation, store: database.store,
            credentialStore: McpCredentialStore(storage: InMemoryMcpCredentialStorage()), uid: "u1",
            runtimeConfig: config, availability: availability
        )
    }

    @Test("No servers: empty state, the pill shows no number")
    func emptyState() throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        let state = try load(database, conversation: UUID())
        #expect(!state.hasServers)
        #expect(state.enabledServerCount == 0)
        #expect(state.estimatedTokens == 0)
    }

    @Test("List: the tool count excludes disabled and quarantined tools; the pill number counts only enabled and usable servers; the estimate and the send path share one assembly")
    func rowsAndCount() throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        let conversation = UUID()
        let lastSuccess = Date(timeIntervalSince1970: 1_700_000_500)
        try add(database, id: serverA, name: "Linear", url: "https://mcp.linear.app/mcp", tools: [
            snapshot("search", server: serverA), snapshot("read", server: serverA),
            snapshot("hidden", server: serverA), snapshot("quarantined", server: serverA, pendingReview: true),
        ], permissions: ["hidden": .off], status: .connected)
        try add(database, id: serverB, name: "GitHub", url: "https://mcp.github.example/mcp",
                tools: [snapshot("issues", server: serverB)], status: .needsAuth)
        let nas = UUID()
        try add(database, id: nas, name: "NAS", url: "https://nas.example/mcp",
                tools: [snapshot("files", server: nas)], status: .unreachable, lastSuccessAt: lastSuccess)
        for id in [serverA, serverB] {
            try database.store.setServerEnabled(true, conversationId: conversation, serverId: id)
        }

        let state = try load(database, conversation: conversation)
        let linear = try #require(state.rows.first { $0.id == serverA })
        #expect(linear.toolCount == 2)
        #expect(linear.status == .ready && linear.isEnabled && linear.canToggle)
        let github = try #require(state.rows.first { $0.id == serverB })
        #expect(github.status == .needsAuth && !github.canToggle && !github.contributesTools)
        let unreachable = try #require(state.rows.first { $0.id == nas })
        #expect(unreachable.status == .unreachable(lastSuccessAt: lastSuccess))
        #expect(!unreachable.canToggle, "an unreachable server that is off cannot be turned on")

        #expect(state.enabledServerCount == 1, "a server that needs re-authorization does not count as usable")
        #expect(state.outboundToolCount == 2)
        let plan = try McpToolBridge.plan(
            conversationId: conversation, store: database.store,
            credentialStore: McpCredentialStore(storage: InMemoryMcpCredentialStorage()), uid: "u1", runtimeConfig: .fallback
        )
        #expect(plan.tools.count == state.outboundToolCount, "the tool count the panel reports is the tool count the send path will carry")
        #expect(state.estimatedTokens == McpToolPanelModel.estimatedTokens(for: plan))
        #expect(state.estimatedTokens >= 100 && state.estimatedTokens % 100 == 0)
        #expect(!state.truncated)

        // Other conversations are not affected.
        #expect(try load(database, conversation: UUID()).enabledServerCount == 0)
    }

    @Test("Over maxToolsPerRequest: flagged as truncated, and the reported number is the truncated one")
    func truncation() throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        let conversation = UUID()
        try add(database, id: serverA, name: "Linear", url: "https://mcp.linear.app/mcp",
                tools: (1...5).map { snapshot("t\($0)", server: serverA) }, status: .connected)
        try database.store.setServerEnabled(true, conversationId: conversation, serverId: serverA)
        let state = try load(database, conversation: conversation, config: McpRuntimeConfig(maxToolsPerRequest: 3))
        #expect(state.truncated)
        #expect(state.outboundToolCount == 3)
        #expect(state.maxToolsPerRequest == 3)
    }

    @Test("A model without tool support: the pill number is always 0 and nothing is estimated")
    func unavailableConnection() throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        let conversation = UUID()
        try add(database, id: serverA, name: "Linear", url: "https://mcp.linear.app/mcp",
                tools: [snapshot("search", server: serverA)], status: .connected)
        try database.store.setServerEnabled(true, conversationId: conversation, serverId: serverA)
        let state = try load(database, conversation: conversation, availability: .modelUnsupported)
        #expect(state.enabledServerCount == 0)
        #expect(state.outboundToolCount == 0 && state.estimatedTokens == 0)
        #expect(state.hasServers, "the list is still there, just dimmed")
    }

    @Test("Availability uses the same gate as the send path: a model that supports tool calls is available, one that does not is unsupported")
    @MainActor
    func availability() throws {
        let memory = try makeToolLoopMemoryStore()
        let (relay, model) = makeToolLoopRelayProvider(transport: .openaiChatCompletions)
        #expect(McpToolAvailability.resolve(provider: relay, model: model, memory: memory) == .available)
        let (plainRelay, noTools) = makeToolLoopRelayProvider(transport: .openaiChatCompletions, toolCall: false)
        #expect(McpToolAvailability.resolve(provider: plainRelay, model: noTools, memory: memory) == .modelUnsupported)
    }

    @Test("Toggles for a new conversation are kept under the draft id first and move to the conversation id when the first message is sent")
    func draftSwitchesMove() throws {
        let database = try McpTestDatabase.make(); defer { database.cleanUp() }
        try add(database, id: serverA, name: "Linear", url: "https://mcp.linear.app/mcp",
                tools: [snapshot("search", server: serverA)], status: .connected)
        let draft = UUID(), conversation = UUID()
        try database.store.setServerEnabled(true, conversationId: draft, serverId: serverA)
        try database.store.moveConversationSwitches(from: draft, to: conversation)
        #expect(try database.store.fetchEnabledServerIds(conversationId: conversation) == [serverA])
        #expect(try database.store.fetchEnabledServerIds(conversationId: draft).isEmpty)
    }
}

@Suite("MCP confirmation dialog content and gate")
struct McpConfirmationTests {
    private func request(_ json: String, conversation: UUID = UUID()) throws -> McpConfirmationRequest {
        McpConfirmationRequest(
            conversationId: conversation, serverId: serverA, serverName: "Notion", serverHost: "mcp.notion.com",
            toolName: "create_page", toolTitle: "Create page", arguments: try JSONValue(parsing: json),
            inputSchema: .object(JSONObject())
        )
    }

    @Test("First 4 top-level arguments, key names verbatim, in the order the model gave; long text shows only its length; non-strings show as JSON text")
    func parameters() throws {
        let body = String(repeating: "x", count: 640)
        let arguments = try JSONValue(parsing: """
        {"parent":"Sprint notes","title":"Week 40","content":"\(body)","tags":["a","b"],"extra":1}
        """)
        let parameters = McpConfirmationContent.parameters(for: arguments)
        #expect(parameters.map(\.key) == ["parent", "title", "content", "tags"])
        #expect(parameters[0].display == .inline("Sprint notes"))
        #expect(parameters[2].display == .long(characterCount: 640))
        #expect(parameters[2].fullText == body)
        #expect(parameters[3].display == .inline(#"["a","b"]"#))
        #expect(McpConfirmationContent.hasMoreParameters(arguments))
        let all = McpConfirmationContent.allParametersText(arguments)
        #expect(all.contains("extra: 1") && all.contains(#"parent: "Sprint notes""#))
    }

    @Test("Gate: requests queue and are presented one at a time; a choice is delivered by id; stopping throws CancellationError and clears the dialog")
    @MainActor
    func coordinatorQueuesAndResolves() async throws {
        let coordinator = McpConfirmationCoordinator()
        let conversation = UUID()
        let first = try request(#"{"n":1}"#, conversation: conversation)
        let second = try request(#"{"n":2}"#, conversation: conversation)

        let firstTask = Task { try await coordinator.requestConfirmation(first) }
        try await waitUntil { coordinator.pending.count == 1 }
        let secondTask = Task { try await coordinator.requestConfirmation(second) }
        try await waitUntil { coordinator.pending.count == 2 }
        #expect(coordinator.pending.map(\.request) == [first, second], "queued in proposal order")

        coordinator.resolve(id: coordinator.pending[0].id, choice: .conversation)
        #expect(try await firstTask.value == .conversation)
        #expect(coordinator.pending.map(\.request) == [second])

        coordinator.cancel(conversationID: conversation)
        await #expect(throws: CancellationError.self) { try await secondTask.value }
        #expect(coordinator.pending.isEmpty)

        // Cancelling the task that raised it (the user taps Stop) also resolves as a cancellation.
        let third = Task { try await coordinator.requestConfirmation(first) }
        try await waitUntil { coordinator.pending.count == 1 }
        third.cancel()
        await #expect(throws: CancellationError.self) { try await third.value }
        try await waitUntil { coordinator.pending.isEmpty }
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("timed out waiting for the condition")
    }
}

@Suite("MCP chat UI rendering (production views)")
@MainActor
struct McpChatInterfaceRenderTests {
    private var snapshotDirectory: URL? {
        ProcessInfo.processInfo.environment["ORIVEO_MCP_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func export(_ image: UIImage, _ name: String) throws {
        guard let directory = snapshotDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try image.pngData()?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func makeModel(steps: [McpToolStep], state: ChatMessageState, text: String) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let id = UUID()
        var message = ChatMessage(
            id: id, role: .assistant, text: text, reasoningText: nil,
            providerKind: .relay, providerName: "My Relay", modelName: "relay-model",
            estimatedCost: 0, state: state, attachments: nil, citations: nil
        )
        message.toolSteps = steps
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: id, message: message, presentationKind: .assistant,
            showMetadata: state != .generating, resolvedProviderName: "My Relay", resolvedModelName: "relay-model",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: text.hashValue,
            isStreaming: state == .generating, providerMetadataVersion: 0
        )
    }

    private func firstDescendant<T: UIView>(of view: UIView, as type: T.Type) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = firstDescendant(of: sub, as: type) { return hit }
        }
        return nil
    }

    private func renderCell(
        steps: [McpToolStep], state: ChatMessageState, text: String,
        style: UIUserInterfaceStyle = .light, expand: Bool = false
    ) -> (UIImage, UIKitToolStepsView?, AssistantMessageCell) {
        let width: CGFloat = 390
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        window.overrideUserInterfaceStyle = style
        let parent = UIViewController()
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        cell.overrideUserInterfaceStyle = style
        cell.configure(
            model: makeModel(steps: steps, state: state, text: text),
            parentViewController: parent, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil
        )
        parent.view.addSubview(cell)
        let block = firstDescendant(of: cell, as: UIKitToolStepsView.self)
        if expand { block?.tapHeaderForTesting() }
        let size = cell.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        cell.frame = CGRect(x: 0, y: 0, width: width, height: max(size.height, 80))
        cell.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: cell.bounds.size).image { _ in
            cell.drawHierarchy(in: cell.bounds, afterScreenUpdates: true)
        }
        return (image, block, cell)
    }

    private func renderSheet<Content: View>(_ content: Content, height: CGFloat, style: UIUserInterfaceStyle = .light) -> UIImage {
        let size = CGSize(width: 390, height: height)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: content.background(OriveoTheme.Palette.background))
        host.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }

    private let doneSteps = [
        step(1, .done, title: "Search issues", summary: "open · bug · this week"),
        step(2, .done, title: "Read issues", summary: "12"),
        step(3, .done, server: "Notion", title: "Find page", summary: "Sprint notes"),
        step(4, .done, server: "Notion", title: "Create page", summary: "Week 40 · open bugs"),
    ]

    @Test("Running: the production cell mounts the step block, expanded by default, with the title and each row's text generated by the rules")
    func runningBlock() throws {
        let steps = Array(doneSteps.prefix(2)) + [step(3, .running, server: "Notion", title: "Find page", summary: "Sprint notes")]
        let (image, block, cell) = renderCell(steps: steps, state: .generating, text: "")
        let view = try #require(block, "the production cell did not mount UIKitToolStepsView")
        #expect(!view.isHidden && view.isExpanded)
        let rendered = view.renderedStateForTesting
        #expect(rendered.title == L10n.tr("Using tools", table: .mcp))
        #expect(rendered.trailing == String(format: L10n.tr("Step %d", table: .mcp), 3))
        #expect(rendered.rowTitles == ["Linear · Search issues", "Linear · Read issues", "Notion · Find page"])
        #expect(rendered.rowDetails == ["open · bug · this week", "12", "Sprint notes"])
        #expect(!rendered.showsPauseControls && !rendered.showsLimitNote)
        #expect(cell.runningToolStepCaption == String(format: L10n.tr("Using %1$@ · %2$@", table: .mcp), "Notion", "Find page"))
        try export(image, "steps-running")
    }

    @Test("Finished: collapsed to one row by default; every row is tappable once expanded; the collapsed height matches the row height estimate")
    func finishedBlock() throws {
        let (collapsed, block, cell) = renderCell(steps: doneSteps, state: .delivered, text: "The report is in Notion.")
        let view = try #require(block)
        #expect(!view.isExpanded, "collapsed once the answer has finished")
        let rendered = view.renderedStateForTesting
        #expect(rendered.title == String(format: L10n.tr("Tools used: %d", table: .mcp), 4))
        #expect(rendered.trailing?.contains("Linear") == true && rendered.trailing?.contains("Notion") == true)
        #expect(abs(view.bounds.height - UIKitToolStepsView.headerHeight) <= 1, "the collapsed state is just the header row: \(view.bounds.height)")
        #expect(cell.runningToolStepCaption == nil)
        try export(collapsed, "steps-done")

        let (expanded, expandedBlock, _) = renderCell(steps: doneSteps, state: .delivered, text: "The report is in Notion.", expand: true)
        #expect(expandedBlock?.isExpanded == true)
        #expect((expandedBlock?.bounds.height ?? 0) >= UIKitToolStepsView.headerHeight + 4 * UIKitToolStepsView.rowMinHeight)
        try export(expanded, "steps-done-expanded")

        let (dark, _, _) = renderCell(steps: doneSteps, state: .delivered, text: "The report is in Notion.", style: .dark, expand: true)
        try export(dark, "steps-done-expanded-dark")
    }

    @Test("Exceptional states: declined, failed, waiting for re-authorization (two button callbacks), limit reached")
    func exceptionStates() throws {
        // Declined
        let deniedSteps = Array(doneSteps.prefix(3))
            + [step(4, .denied, server: "Notion", title: "Create page", errorCode: "user_denied")]
        let (denied, deniedBlock, _) = renderCell(steps: deniedSteps, state: .delivered, text: "Okay, nothing was written.", expand: true)
        let deniedState = try #require(deniedBlock).renderedStateForTesting
        #expect(deniedState.title == String(format: L10n.tr("Tools used: %d", table: .mcp), 3))
        #expect(deniedState.trailing == String(format: L10n.tr("%d declined", table: .mcp), 1))
        #expect(deniedState.rowDetails.last == L10n.tr("You declined, so it wasn't run", table: .mcp))
        try export(denied, "step-denied")

        // Failed
        let failedSteps = [doneSteps[0], step(2, .failed, title: "Read issues", errorCode: "timeout")]
        let (failed, failedBlock, _) = renderCell(steps: failedSteps, state: .delivered, text: "I could not read the issues.", expand: true)
        let failedState = try #require(failedBlock).renderedStateForTesting
        #expect(failedState.trailing == String(format: L10n.tr("%d failed", table: .mcp), 1))
        #expect(failedState.rowDetails.last == L10n.tr("The server took too long to respond.", table: .mcp))
        try export(failed, "step-failed")

        // Waiting for re-authorization
        let pausedSteps = Array(doneSteps.prefix(2))
            + [step(3, .needsAuth, server: "Notion", title: "Find page", errorCode: "needs_auth")]
        let (paused, pausedBlock, pausedCell) = renderCell(steps: pausedSteps, state: .generating, text: "")
        let pausedView = try #require(pausedBlock)
        let pausedState = pausedView.renderedStateForTesting
        #expect(pausedView.isExpanded)
        #expect(pausedState.title == L10n.tr("Waiting for sign-in", table: .mcp))
        #expect(pausedState.showsPauseControls)
        #expect(pausedState.rowDetails.last == String(format: L10n.tr("%@'s sign-in expired", table: .mcp), "Notion"))
        var actions: [McpToolStepAction] = []
        pausedCell.onToolStepAction = { actions.append($0) }
        pausedView.onReauthorize?(pausedSteps[2])
        pausedView.onSkipStep?(pausedSteps[2])
        #expect(actions == [.reauthorize(pausedSteps[2]), .skip(pausedSteps[2])], "both buttons are routed to the chat page through the cell")
        try export(paused, "step-reauth")

        // Limit reached
        let limitView = UIKitToolStepsView()
        limitView.frame = CGRect(x: 0, y: 0, width: 358, height: 10)
        limitView.configure(steps: (1...8).map { step($0, .done, title: "Read issue", summary: "APP-22\(70 - $0)") },
                            isGenerating: false, limitReached: true)
        limitView.tapHeaderForTesting()
        let limitState = limitView.renderedStateForTesting
        #expect(limitState.showsLimitNote && !limitState.showsPauseControls)
        #expect(limitState.earlierButtonTitle == String(format: L10n.tr("Show earlier steps (%d)", table: .mcp), 6))
        #expect(limitState.rowTitles.count == 2)
        let size = limitView.systemLayoutSizeFitting(
            CGSize(width: 358, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        limitView.frame = CGRect(origin: .zero, size: CGSize(width: 358, height: size.height))
        limitView.layoutIfNeeded()
        let limitImage = UIGraphicsImageRenderer(size: limitView.bounds.size).image { _ in
            limitView.drawHierarchy(in: limitView.bounds, afterScreenUpdates: true)
        }
        try export(limitImage, "step-limit")
    }

    @Test("The step block follows state: expanded while running, auto-collapsed when finished; once the user has expanded it manually it no longer auto-collapses")
    func autoCollapse() {
        let view = UIKitToolStepsView()
        view.configure(steps: [step(1, .running)], isGenerating: true)
        #expect(view.isExpanded)
        view.configure(steps: [step(1, .done)], isGenerating: false)
        #expect(!view.isExpanded)

        let kept = UIKitToolStepsView()
        kept.configure(steps: [step(1, .running)], isGenerating: true)
        kept.tapHeaderForTesting()
        kept.tapHeaderForTesting()
        kept.configure(steps: [step(1, .done)], isGenerating: false)
        #expect(kept.isExpanded, "no auto-collapse after the user has changed the expansion state")

        view.configure(steps: [], isGenerating: false)
        #expect(view.isHidden, "takes no space when there are no steps")
    }

    @Test("Tapping a row: only finished steps call back for details")
    func rowTap() {
        let view = UIKitToolStepsView()
        var selected: [String] = []
        view.onSelectStep = { selected.append($0.id) }
        view.configure(steps: [step(1, .done), step(2, .running)], isGenerating: true)
        view.tapRowForTesting(at: 0)
        view.tapRowForTesting(at: 1)
        #expect(selected == ["1:call_1"])
    }

    @Test("The three tools panel variants render")
    func toolPanel() throws {
        let rows = [
            McpToolPanelServerRow(id: serverA, name: "Linear", iconURL: nil, toolCount: 7, status: .ready, isEnabled: true),
            McpToolPanelServerRow(id: serverB, name: "Notion", iconURL: nil, toolCount: 14, status: .ready, isEnabled: true),
            McpToolPanelServerRow(id: UUID(), name: "GitHub", iconURL: nil, toolCount: 9, status: .needsAuth, isEnabled: false),
            McpToolPanelServerRow(
                id: UUID(), name: "Home NAS", iconURL: nil, toolCount: 3,
                status: .unreachable(lastSuccessAt: Date().addingTimeInterval(-3 * 86_400)), isEnabled: false
            ),
        ]
        let list = McpToolPanelState(
            availability: .available, rows: rows, outboundToolCount: 21, estimatedTokens: 1_800,
            truncated: false, maxToolsPerRequest: 40
        )
        #expect(list.enabledServerCount == 2)
        func sheet(_ state: McpToolPanelState) -> McpToolPanelSheet {
            McpToolPanelSheet(
                state: state, onToggle: { _, _ in }, onReauthorize: { _ in }, onManage: {}, onAddServer: {}, onSwitchModel: {}
            )
        }
        try export(renderSheet(sheet(list), height: 520), "tool-picker")
        try export(renderSheet(sheet(.empty), height: 340), "tool-picker-empty")
        var unsupported = list
        unsupported.availability = .modelUnsupported
        #expect(unsupported.enabledServerCount == 0)
        try export(renderSheet(sheet(unsupported), height: 560), "tool-picker-unsupported")
        var truncated = list
        truncated.truncated = true
        try export(renderSheet(sheet(truncated), height: 520), "tool-picker-over-limit")
        #expect(McpToolPanelSheet.grouped(1_800).contains("800"))
    }

    @Test("The confirmation dialog and the single-step detail render; with no payload on this device only a one-line note shows")
    func confirmationAndDetail() throws {
        let body = String(repeating: "Line of the weekly report. ", count: 24)
        let request = McpConfirmationRequest(
            conversationId: UUID(), serverId: serverB, serverName: "Notion", serverHost: "mcp.notion.com",
            toolName: "create_page", toolTitle: "Create page",
            arguments: try JSONValue(parsing: #"{"parent":"Sprint notes","title":"Week 40 · open bugs (12)","content":"\#(body)"}"#),
            inputSchema: .object(JSONObject())
        )
        try export(renderSheet(McpConfirmationSheet(request: request) { _ in }, height: 620), "confirm")
        try export(renderSheet(McpConfirmationSheet(request: request) { _ in }, height: 620, style: .dark), "confirm-dark")

        // The dialog is hosted at the root and follows the user: it carries the originating conversation's title so
        // the user can tell which conversation is asking even from another one.
        let untitled = renderSheet(McpConfirmationSheet(request: request) { _ in }, height: 620)
        let titled = renderSheet(
            McpConfirmationSheet(request: request, conversationTitle: "Weekly report") { _ in }, height: 620
        )
        try export(titled, "confirm-with-chat")
        #expect(titled.pngData() != untitled.pngData(), "the owning-conversation row is drawn")
        let blank = renderSheet(McpConfirmationSheet(request: request, conversationTitle: "  ") { _ in }, height: 620)
        #expect(blank.pngData() == untitled.pngData(), "the row is not drawn when the title is blank")
        #expect(McpConfirmationContent.displayConversationTitle(" Weekly report\n") == "Weekly report")
        #expect(McpConfirmationContent.displayConversationTitle(nil) == nil)

        let reauth = McpReauthorizationRequest(
            conversationId: request.conversationId, serverId: serverB, serverName: "Notion", stepId: "1:call_1"
        )
        try export(
            renderSheet(
                McpReauthorizationSheet(request: reauth, conversationTitle: "Weekly report", onReauthorize: {}, onSkip: {}),
                height: 380
            ),
            "reauth-root"
        )

        let payload = McpStepDetailSheet.Payload(
            arguments: #"{"label":"bug","state":"open","updatedAt":"this week"}"#,
            resultPrefix: "APP-2291  Stream stops after lock screen\n  iOS · High · Unassigned\nAPP-2287  Search retries on weak network"
        )
        try export(
            renderSheet(McpStepDetailSheet(step: doneSteps[0], status: .done, payload: payload), height: 560),
            "step-detail"
        )
        try export(
            renderSheet(McpStepDetailSheet(step: doneSteps[0], status: .done, payload: nil), height: 260),
            "step-detail-no-payload"
        )
        #expect(McpConfirmationContent.allParametersText(storedJSON: payload.arguments ?? "").contains(#"state: "open""#))
        #expect(McpStepDetailSheet.durationText(milliseconds: 1_200).contains("1"))
    }
}
