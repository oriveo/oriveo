import Foundation
import Testing
@testable import Oriveo

/// Menu bar command availability: chat page or not × copyable reply or not × generating or not × two columns, plus the window count and onboarding.
@Suite("AppCommandState")
struct AppCommandStateTests {

    private func makeState(
        onboarding: Bool = true,
        chat: Bool,
        copyable: Bool,
        generating: Bool,
        split: Bool,
        windows: Int = 1
    ) -> AppCommandState {
        AppCommandState(
            hasCompletedOnboarding: onboarding,
            isShowingChat: chat,
            hasCopyableResponse: copyable,
            isGenerating: generating,
            usesSplitLayout: split,
            windowCount: windows
        )
    }

    @Test("All four dimensions: ⌘K follows the chat page, ⌘. needs a chat page that is generating, ⌘⇧C a chat page with a copyable reply, ⌃⌘S only two columns")
    func fourDimensionMatrix() {
        for chat in [false, true] {
            for copyable in [false, true] {
                for generating in [false, true] {
                    for split in [false, true] {
                        let state = makeState(chat: chat, copyable: copyable, generating: generating, split: split)
                        let label = "chat=\(chat) copyable=\(copyable) generating=\(generating) split=\(split)"
                        #expect(state.isEnabled(.newChat), "\(label)")
                        #expect(state.isEnabled(.searchConversations), "\(label)")
                        #expect(state.isEnabled(.showTab(.home)), "\(label)")
                        #expect(state.isEnabled(.showTab(.providers)), "\(label)")
                        #expect(state.isEnabled(.showTab(.settings)), "\(label)")
                        #expect(state.isEnabled(.chooseModel) == chat, "\(label)")
                        #expect(state.isEnabled(.stopGenerating) == (chat && generating), "\(label)")
                        #expect(state.isEnabled(.copyLastResponse) == (chat && copyable), "\(label)")
                        #expect(state.canToggleSidebar == split, "\(label)")
                    }
                }
            }
        }
    }

    @Test("Without a chat page ⌘K ⌘. ⌘⇧C are all disabled, even with leftover generating / copyable state")
    func noChatGraysChatCommands() {
        let state = makeState(chat: false, copyable: true, generating: true, split: true)
        #expect(!state.isEnabled(.chooseModel))
        #expect(!state.isEnabled(.stopGenerating))
        #expect(!state.isEnabled(.copyLastResponse))
    }

    @Test("Before onboarding: every command is unavailable, including the sidebar toggle")
    func onboardingIncompleteDisablesEverything() {
        let state = makeState(onboarding: false, chat: true, copyable: true, generating: true, split: true, windows: 2)
        let commands: [AppCommand] = [
            .newChat, .searchConversations, .chooseModel, .stopGenerating, .copyLastResponse,
            .showTab(.home), .showTab(.providers), .showTab(.settings),
        ]
        for command in commands {
            #expect(!state.isEnabled(command), "\(command)")
        }
        #expect(!state.canToggleSidebar)
    }

    @Test("⌘W: unavailable with one window left, available with two or more")
    func closeWindowNeedsAnotherWindow() {
        #expect(!makeState(chat: false, copyable: false, generating: false, split: false, windows: 1).canCloseWindow)
        #expect(!makeState(chat: false, copyable: false, generating: false, split: false, windows: 0).canCloseWindow)
        #expect(makeState(chat: false, copyable: false, generating: false, split: false, windows: 2).canCloseWindow)
    }

    @Test("The copyable reply has the same source as the copy button: the last assistant message's text; generating or empty text does not count")
    func lastCopyableResponse() {
        let user = TestFactories.makeMessage(role: .user, text: "Question")
        let first = TestFactories.makeMessage(role: .assistant, text: "First answer")
        let second = TestFactories.makeMessage(role: .assistant, text: "Second answer")
        #expect(ChatCommandTarget.lastCopyableResponse(in: [user, first, user, second]) == "Second answer")
        #expect(ChatCommandTarget.lastCopyableResponse(in: [first, user]) == "First answer")
        #expect(ChatCommandTarget.lastCopyableResponse(in: []) == nil)
        #expect(ChatCommandTarget.lastCopyableResponse(in: [user]) == nil)

        let generating = TestFactories.makeMessage(role: .assistant, text: "partial", state: .generating)
        #expect(ChatCommandTarget.lastCopyableResponse(in: [first, user, generating]) == nil)
        let empty = TestFactories.makeMessage(role: .assistant, text: "", state: .failed)
        #expect(ChatCommandTarget.lastCopyableResponse(in: [first, user, empty]) == nil)
        let interrupted = TestFactories.makeMessage(role: .assistant, text: "Cut short", state: .interrupted)
        #expect(ChatCommandTarget.lastCopyableResponse(in: [user, interrupted]) == "Cut short")
    }
}
