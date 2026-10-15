import SwiftUI
import UIKit

/// Menu bar / hardware keyboard commands (the iPadOS menu bar; the shortcut overlay shown while holding ⌘ lists them too).
enum AppCommand: Hashable {
    case newChat
    case searchConversations
    case chooseModel
    case stopGenerating
    case copyLastResponse
    case showTab(AppTab)
}

/// The command target a chat page registers with its window: which conversation ⌘. and ⌘⇧C act on.
/// `owner` identifies the ChatView instance: on a carrier change the old page may disappear after the new one, and unregistering by owner keeps the new page's registration.
struct ChatCommandTarget: Equatable {
    let owner: UUID
    /// The stored conversation id; nil for an unsent draft (it changes once the first message is sent).
    let conversationID: UUID?
    /// The same source as the copy button under an assistant reply (`message.text`); nil when there is no copyable reply.
    let lastResponseText: String?

    /// The last copyable assistant reply; one still being generated does not count.
    static func lastCopyableResponse(in messages: [ChatMessage]) -> String? {
        guard let last = messages.last(where: { $0.role == .assistant }),
              last.state != .generating,
              !last.text.isEmpty else { return nil }
        return last.text
    }
}

/// Command availability for the active window. A plain value type, testable without UI.
struct AppCommandState: Equatable {
    var hasCompletedOnboarding: Bool
    /// The window is showing a chat page (in either carrier: the two-column detail column or the top of the single-column stack).
    var isShowingChat: Bool
    var hasCopyableResponse: Bool
    /// The conversation on the chat page is generating a reply.
    var isGenerating: Bool
    /// The window uses the two-column layout.
    var usesSplitLayout: Bool
    var windowCount: Int

    func isEnabled(_ command: AppCommand) -> Bool {
        guard hasCompletedOnboarding else { return false }
        switch command {
        case .newChat, .searchConversations, .showTab:
            return true
        case .chooseModel:
            return isShowingChat
        case .stopGenerating:
            return isShowingChat && isGenerating
        case .copyLastResponse:
            return isShowingChat && hasCopyableResponse
        }
    }

    /// ⌃⌘S is the system sidebar toggle, which exists only with two columns.
    var canToggleSidebar: Bool { hasCompletedOnboarding && usesSplitLayout }
    /// ⌘W is the system Close Window, unavailable when only one window is left.
    var canCloseWindow: Bool { windowCount > 1 }
}

extension AppState {
    /// Command availability, derived from the active window.
    var commandState: AppCommandState {
        let navigation = navigation
        let target = navigation.isShowingChat ? navigation.chatCommandTarget : nil
        let isGenerating = target?.conversationID.map { streamingConversationIDs.contains($0) } ?? false
        return AppCommandState(
            hasCompletedOnboarding: hasCompletedOnboarding,
            isShowingChat: navigation.isShowingChat,
            hasCopyableResponse: target?.lastResponseText != nil,
            isGenerating: isGenerating,
            usesSplitLayout: navigation.isRegularWidth,
            windowCount: registeredWindowCount
        )
    }

    /// Runs a command only in the active window; when the command is unavailable it returns false and changes nothing.
    @discardableResult
    func perform(_ command: AppCommand, pasteboard: UIPasteboard = .general) -> Bool {
        guard commandState.isEnabled(command) else { return false }
        let navigation = navigation
        switch command {
        case .newChat:
            navigation.selectedTab = .home
            // One column: with other pages on the stack go back to the root first so the new chat is not stacked on them; on a chat page presentChat replaces the top atomically.
            if !navigation.isRegularWidth, !navigation.isShowingChat {
                navigation.popToRoot()
            }
            startNewChat()
        case .searchConversations:
            navigation.selectedTab = .home
            // The outer stack covers Home (in one column the conversation is on it too), so search is only visible after going back to the root; with two columns the conversation is in the detail column and unaffected.
            navigation.popToRoot()
            navigation.requestSearchReveal()
        case .chooseModel:
            navigation.requestModelPicker()
        case .stopGenerating:
            guard let conversationID = navigation.chatCommandTarget?.conversationID else { return false }
            cancelGeneration(in: conversationID)
        case .copyLastResponse:
            guard let text = navigation.chatCommandTarget?.lastResponseText else { return false }
            pasteboard.string = text
            ToastManager.shared.show(L10n.tr("Copied"), style: .success)
        case let .showTab(tab):
            navigation.selectedTab = tab
            // The outer stack covers the tab roots; without going back to the root the switched tab would not be visible.
            navigation.popToRoot()
        }
        return true
    }
}
