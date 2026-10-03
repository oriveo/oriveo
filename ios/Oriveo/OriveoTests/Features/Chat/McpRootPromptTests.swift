import Foundation
import Testing
@testable import Oriveo

// MARK: - The authorization-expired prompt is hosted at the app root and follows the user

@Suite("MCP root prompt")
@MainActor
struct McpRootPromptTests {
    private let conversationA = UUID()
    private let conversationB = UUID()
    private let serverId = UUID()

    private func request(_ conversation: UUID, step: String = "1:call_1") -> McpReauthorizationRequest {
        McpReauthorizationRequest(conversationId: conversation, serverId: serverId, serverName: "Notion", stepId: step)
    }

    /// Enqueues one request through the production gate (the same path the loop takes when it pauses on that step).
    private func enqueue(
        _ coordinator: McpReauthorizationCoordinator, _ request: McpReauthorizationRequest
    ) async -> Task<McpReauthorizationChoice, Error> {
        let before = coordinator.pending.count
        let waiting = Task { try await coordinator.requestReauthorization(request) }
        #expect(await McpUiWait.until { coordinator.pending.count == before + 1 })
        return waiting
    }

    @Test("User is outside the conversation that started the answer: the root presents the prompt; no extra prompt while that conversation's chat page is on screen")
    func promptFollowsTheUserUnlessTheChatIsOnScreen() async throws {
        let coordinator = McpReauthorizationCoordinator()
        let waiting = await enqueue(coordinator, request(conversationA))
        let pending = try #require(coordinator.pending.first)

        // The user is in Settings or in another conversation.
        #expect(coordinator.rootPrompt(signingInServerId: nil)?.id == pending.id)
        coordinator.chatPageAppeared(conversationB)
        #expect(coordinator.rootPrompt(signingInServerId: nil)?.id == pending.id, "another conversation being on screen does not count")

        // Back in the originating conversation: both buttons already sit below the step block.
        coordinator.chatPageAppeared(conversationA)
        #expect(coordinator.rootPrompt(signingInServerId: nil) == nil)
        coordinator.chatPageDisappeared(conversationA)
        #expect(coordinator.rootPrompt(signingInServerId: nil)?.id == pending.id, "after leaving, the prompt follows the user again")

        // "Skip this step" at the root is the same action as the one below the step block: the step is fed back as auth_skipped.
        coordinator.skip(conversationID: conversationA, stepID: "1:call_1")
        #expect(try await waiting.value == .skip)
        #expect(coordinator.rootPrompt(signingInServerId: nil) == nil)
    }

    @Test("No prompt while signing in again from that server's detail page; dismissing the prompt is not a skip, the step keeps waiting")
    func promptYieldsToSignInAndDismissalDoesNotDecide() async throws {
        let coordinator = McpReauthorizationCoordinator()
        let waiting = await enqueue(coordinator, request(conversationA))
        let pending = try #require(coordinator.pending.first)

        let detail: [AppRoute] = [.mcpServers, .mcpServerDetail(serverID: serverId, intent: .reauthorize)]
        #expect(McpReauthorizationCoordinator.signingInServerId(in: detail) == serverId)
        #expect(McpReauthorizationCoordinator.signingInServerId(in: [.mcpServers]) == nil)
        #expect(coordinator.rootPrompt(signingInServerId: serverId) == nil, "sign-in is in progress, do not cover it")
        #expect(coordinator.rootPrompt(signingInServerId: UUID())?.id == pending.id, "another server's detail page does not count")

        #expect(coordinator.rootPrompt(signingInServerId: nil, dismissed: [pending.id]) == nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(coordinator.pending.count == 1 && !waiting.isCancelled, "dismissing the prompt does not decide for the user")

        // Sign-in succeeded: the steps paused on this server resume.
        coordinator.serverReauthorized(serverId)
        #expect(try await waiting.value == .reauthorized)
    }

    @Test("The presentation host lives at the app root; the chat page only registers which conversation it is showing")
    func hostIsAtTheRoot() throws {
        let features = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Features", isDirectory: true)
        let appRoot = try String(contentsOf: features.appendingPathComponent("App/AppRootView.swift"), encoding: .utf8)
        let chat = try String(contentsOf: features.appendingPathComponent("Chat/ChatView.swift"), encoding: .utf8)
        let sheet = try String(contentsOf: features.appendingPathComponent("Chat/MCP/McpConfirmationSheet.swift"), encoding: .utf8)
        #expect(appRoot.contains(".mcpReauthorizationPresenter(appState: appState)"))
        #expect(!chat.contains(".mcpReauthorizationPresenter("), "if it were attached to the chat page only, nothing would present it once the user leaves that page")
        #expect(chat.contains(".mcpReauthorizationInlineHost(conversationID:"))
        #expect(
            sheet.contains("conversationTitle: appState.conversation(for: pending.request.conversationId)?.title"),
            "both the root confirmation dialog and the authorization-expired prompt carry the originating conversation's title"
        )
    }
}
