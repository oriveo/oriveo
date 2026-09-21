import GRDB
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// With the input text living in the composer, reading, writing and restoring the draft all happen in
/// ChatComposerBar. These tests lock the behavior: restoring the draft on entry, writing on leave
/// (including clearing it), not writing when unchanged, clear-after-send and failure restore, repeated
/// edit restores, conversation switches, New Chat writing back the previous draft, keeping input after
/// a pushed page, and writing back when the app goes to the background.
@MainActor
@Suite("Chat composer draft lifecycle", .serialized)
struct ChatComposerDraftLifecycleTests {
    // MARK: - Reconciliation state (pure logic)

    @Test("deduplication uses only the known stored value: unchanged does not write, clearing writes empty, unbound does not write")
    func commitDedupesAgainstPersistedSnapshot() {
        let conversationID = UUID()
        var session = ChatComposerDraftSession()
        #expect(session.commit("typed") == nil, "Nothing is written before binding")

        #expect(session.bind(conversationID: conversationID, storeDraft: "saved") == "saved")
        #expect(session.commit("saved") == nil, "Leaving with an unchanged draft must not write")
        #expect(session.commit("") == .init(conversationID: conversationID, text: ""), "Clearing the draft must write an empty draft")
        #expect(session.commit("") == nil, "The same value is written only once")

        _ = session.bind(conversationID: conversationID, storeDraft: nil)
        #expect(session.commit("") == nil, "Before the store is read, empty text must not overwrite a real draft")
        #expect(session.commit("typed") == .init(conversationID: conversationID, text: "typed"))

        _ = session.bind(conversationID: nil, storeDraft: nil)
        #expect(session.commit("new chat") == nil, "A new chat has no conversation to write to yet")
    }

    @Test("first store read restores only into an empty composer; existing input (a failure restore) stays and is written later")
    func firstStoreLoadNeverClobbersExistingInput() {
        let conversationID = UUID()
        var session = ChatComposerDraftSession()
        _ = session.bind(conversationID: conversationID, storeDraft: nil)
        #expect(session.reconcile(storeDraft: nil, latestDraft: nil, composerText: "", isFocused: false) == nil)
        #expect(session.reconcile(storeDraft: "saved", latestDraft: "saved", composerText: "", isFocused: true) == "saved")

        var restored = ChatComposerDraftSession()
        _ = restored.bind(conversationID: conversationID, storeDraft: nil)
        #expect(restored.reconcile(storeDraft: "", latestDraft: "", composerText: "first message", isFocused: false) == nil)
        #expect(restored.commit("first message") == .init(conversationID: conversationID, text: "first message"))
    }

    @Test("stale echoes and echoes of our own writes never overwrite; external changes overwrite when unfocused and only move the baseline when focused")
    func reconcileSeparatesStaleOwnAndExternalEchoes() {
        let conversationID = UUID()
        var session = ChatComposerDraftSession()
        _ = session.bind(conversationID: conversationID, storeDraft: "")
        _ = session.commit("a")
        _ = session.commit("ab")
        // Memory already holds "ab"; the "a" arriving from the store first is an older write.
        #expect(session.reconcile(storeDraft: "a", latestDraft: "ab", composerText: "ab", isFocused: false) == nil)
        #expect(session.reconcile(storeDraft: "ab", latestDraft: "ab", composerText: "ab", isFocused: false) == nil)

        // Regenerate clears the draft (memory becomes "" synchronously).
        #expect(session.reconcile(storeDraft: "", latestDraft: "", composerText: "ab", isFocused: false) == "")

        var focused = ChatComposerDraftSession()
        _ = focused.bind(conversationID: conversationID, storeDraft: "draft")
        #expect(focused.reconcile(storeDraft: "", latestDraft: "", composerText: "typing", isFocused: true) == nil)
        #expect(focused.commit("typing") == .init(conversationID: conversationID, text: "typing"), "Focus loss writes the user's input back")
    }

    @Test("without the conversation in memory only a real store change counts; reading the same value again after a stop does not")
    func reconcileWithoutMemoryIgnoresReobservedValue() {
        let conversationID = UUID()
        var session = ChatComposerDraftSession()
        _ = session.bind(conversationID: conversationID, storeDraft: "saved")
        _ = session.commit("unsent")
        #expect(session.reconcile(storeDraft: nil, latestDraft: nil, composerText: "unsent", isFocused: false) == nil)
        #expect(session.reconcile(storeDraft: "saved", latestDraft: nil, composerText: "unsent", isFocused: false) == nil)
        #expect(session.reconcile(storeDraft: "changed", latestDraft: nil, composerText: "unsent", isFocused: false) == "changed")
    }

    // MARK: - Real composer (ordering of pushes and store echoes inside SwiftUI updates)

    @Test("after clear-on-send and a failed send restore, a late empty draft echo does not wipe the restored text, and leaving writes it back")
    func sendFailureRestoreSurvivesLateEcho() async throws {
        let conversation = TestFactories.makeConversation(draftText: "draft")
        let environment = try ChatDraftEnvironment(conversations: { provider in
            [Self.withProvider(conversation, provider)]
        })
        defer { environment.tearDown() }
        let harness = ComposerDraftHarness(conversationID: conversation.id, storeDraft: "draft")
        let host = try environment.host(ComposerDraftHarnessView(environment: environment, harness: harness))

        let input = try await Self.waitForInput(in: host.view)
        #expect(input.text == "draft")
        try await Self.focus(harness, input)
        Self.type(" more", into: input)
        try await Self.waitUntil { input.text == "draft more" }

        // ChatView's send: `composerFocused = false` and an empty push in the same pass.
        harness.push.push("")
        harness.setFocus?(false)
        try await Self.waitUntil { input.text.isEmpty && harness.commits.count == 1 }
        #expect(harness.commits == [.init(conversationID: conversation.id, text: "")])

        // sendMessage returned nil, so the text is restored; only then does the store echo the "" written on send.
        harness.push.push("draft more")
        try await Self.waitUntil { input.text == "draft more" }
        harness.storeDraft = ""
        try await Self.settle()
        #expect(input.text == "draft more", "A stale empty draft echo wiped the restored text")

        harness.showsComposer = false
        try await Self.waitUntil { harness.commits.count == 2 }
        #expect(harness.commits.last == .init(conversationID: conversation.id, text: "draft more"))
        #expect(environment.state.conversation(for: conversation.id)?.draftText == "draft more")
    }

    @Test("pushing the same edit restore twice still overwrites input the user changed in between")
    func repeatedEditPushOfSameTextApplies() async throws {
        let conversation = TestFactories.makeConversation()
        let environment = try ChatDraftEnvironment(conversations: { provider in
            [Self.withProvider(conversation, provider)]
        })
        defer { environment.tearDown() }
        let harness = ComposerDraftHarness(conversationID: conversation.id, storeDraft: "")
        let host = try environment.host(ComposerDraftHarnessView(environment: environment, harness: harness))
        let input = try await Self.waitForInput(in: host.view)

        harness.push.push("edit me")
        try await Self.waitUntil { input.text == "edit me" }
        try await Self.focus(harness, input)
        Self.type(" changed", into: input)
        try await Self.waitUntil { input.text == "edit me changed" }

        harness.push.push("edit me")
        try await Self.waitUntil { input.text == "edit me" }
    }

    @Test("first send in a new chat: when the conversation switch and the failure restore land together the restore wins, and a later empty draft does not overwrite it")
    func conversationSwitchAndRestorePushResolveInOrder() async throws {
        let created = TestFactories.makeConversation()
        let environment = try ChatDraftEnvironment(conversations: { provider in
            [Self.withProvider(created, provider)]
        })
        defer { environment.tearDown() }
        let harness = ComposerDraftHarness(conversationID: nil, storeDraft: nil)
        let host = try environment.host(ComposerDraftHarnessView(environment: environment, harness: harness))
        let input = try await Self.waitForInput(in: host.view)
        try await Self.focus(harness, input)
        Self.type("first message", into: input)
        try await Self.waitUntil { input.text == "first message" }

                harness.push.push("")
        harness.setFocus?(false)
        // Wait for the blur too, not just the text. `isFocused` is written back through the host's
        // onChange, and it propagates asynchronously just like the UIKit first responder resign; waiting
        // only on the text lets the blur slip into the next statement's update — the one
        // that switches conversations. `applyDraftInputs` runs in a fixed order there:
        // ①rebind to the new conversation → ②a push overwrites the text → ③blur commits,
        // so ③ would write ②'s restored text under the **new** conversation id, which is
        // exactly what this case asserts must not happen yet. Not a production defect —
        // after the rebind the composer text does belong to the new conversation — the
        // wait condition was simply missing half of what it had to wait for.
        try await Self.waitUntil { input.text.isEmpty && !harness.isFocused }

        // Replacing the new-chat route with the created conversation and sendMessage returning nil
        // happen in the same pass.
        harness.conversationID = created.id
        harness.push.push("first message")
        try await Self.waitUntil { input.text == "first message" }
        try await Self.settle()
        #expect(input.text == "first message", "The conversation switch reset overwrote the restored text")

        harness.storeDraft = ""
        try await Self.settle()
        #expect(input.text == "first message")
        #expect(harness.commits.isEmpty, "Nothing should be written before leaving the new conversation")

        harness.showsComposer = false
        try await Self.waitUntil { harness.commits.count == 1 }
        #expect(harness.commits == [.init(conversationID: created.id, text: "first message")])
    }

    @Test("going to the background while focused writes the draft without dropping focus; inactive does not write; a second background with no change does not write again")
    func backgroundWritesDraftWhileFocused() async throws {
        let conversation = TestFactories.makeConversation(draftText: "saved")
        let environment = try ChatDraftEnvironment(conversations: { provider in
            [Self.withProvider(conversation, provider)]
        })
        defer { environment.tearDown() }
        let harness = ComposerDraftHarness(conversationID: conversation.id, storeDraft: "saved")
        let host = try environment.host(ComposerDraftHarnessView(environment: environment, harness: harness))
        let input = try await Self.waitForInput(in: host.view)
        try await Self.focus(harness, input)
        Self.type(" and more", into: input)
        try await Self.waitUntil { input.text == "saved and more" }

        harness.scenePhase = .inactive
        try await Self.settle()
        #expect(harness.commits.isEmpty, "Inactive (Control Center, an incoming call banner) must not write")

        harness.scenePhase = .background
        try await Self.waitUntil { harness.commits.count == 1 }
        #expect(harness.commits == [.init(conversationID: conversation.id, text: "saved and more")])
        #expect(harness.isFocused, "Writing on background must not dismiss the keyboard")
        environment.state.flushConversationPersistQueue()
        #expect(try environment.persistedDraft(conversation.id) == "saved and more")

        harness.scenePhase = .active
        try await Self.settle()
        harness.scenePhase = .background
        try await Self.settle()
        #expect(harness.commits.count == 1, "Going to the background again without changes must not write again")
    }

    // MARK: - Real chat screen (leave / reuse / pushed page)

    @Test("entering a conversation restores the draft; clearing it while focused and leaving stores an empty draft")
    func leavingAfterClearingDraftPersistsEmptyDraft() async throws {
        let conversation = Self.conversationWithMessages(draftText: "saved draft")
        let environment = try ChatDraftEnvironment(conversations: { provider in
            [Self.withProvider(conversation, provider)]
        })
        defer { environment.tearDown() }
        let model = ChatDraftHostModel(conversationID: conversation.id)
        let host = try environment.host(ChatDraftHostRoot(model: model, state: environment.state))

        let input = try await Self.waitForInput(in: host.view)
        try await Self.waitUntil { input.text == "saved draft" }
        input.becomeFirstResponder()
        input.selectedTextRange = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
        input.deleteBackward()
        try await Self.waitUntil { input.text.isEmpty }

        model.showsChat = false
        try await Self.waitUntil { environment.state.conversation(for: conversation.id)?.draftText == "" }
        environment.state.flushConversationPersistQueue()
        #expect(try environment.persistedDraft(conversation.id) == "")
    }

    @Test("leaving with an unchanged draft does not write the conversation")
    func leavingWithoutChangesDoesNotWrite() async throws {
        let conversation = Self.conversationWithMessages(draftText: "saved draft")
        let environment = try ChatDraftEnvironment(conversations: { provider in
            [Self.withProvider(conversation, provider)]
        })
        defer { environment.tearDown() }
        let model = ChatDraftHostModel(conversationID: conversation.id)
        let host = try environment.host(ChatDraftHostRoot(model: model, state: environment.state))
        let input = try await Self.waitForInput(in: host.view)
        try await Self.waitUntil { input.text == "saved draft" }
        try await Self.settle()

        var upserts: [String] = []
        environment.state._testingBeforeConversationProjectionUpsert = { upserted in
            if upserted.id == conversation.id { upserts.append(upserted.draftText) }
        }
        defer { environment.state._testingBeforeConversationProjectionUpsert = nil }
        model.showsChat = false
        try await Self.settle()
        #expect(upserts.isEmpty, "An unchanged draft still wrote \(upserts)")
        #expect(try environment.persistedDraft(conversation.id) == "saved draft")
    }

    @Test("New Chat reusing the screen writes the previous conversation's unsaved input back, then clears the composer")
    func newChatReuseWritesBackPreviousDraft() async throws {
        let conversation = Self.conversationWithMessages(draftText: "")
        let environment = try ChatDraftEnvironment(conversations: { provider in
            [Self.withProvider(conversation, provider)]
        })
        defer { environment.tearDown() }
        let model = ChatDraftHostModel(conversationID: conversation.id)
        let host = try environment.host(ChatDraftHostRoot(model: model, state: environment.state))
        let input = try await Self.waitForInput(in: host.view)
        try await Self.settle()
        input.becomeFirstResponder()
        Self.type("unsaved", into: input)
        try await Self.waitUntil { input.text == "unsaved" }

        // Starting a new chat replaces the route with a new-chat route: the same ChatView instance gets new arguments.
        model.conversationID = nil
        try await Self.waitUntil { environment.state.conversation(for: conversation.id)?.draftText == "unsaved" }
        let reused = try await Self.waitForInput(in: host.view)
        try await Self.waitUntil { reused.text.isEmpty }
        environment.state.flushConversationPersistQueue()
        #expect(try environment.persistedDraft(conversation.id) == "unsaved")
    }

    @Test("pushing a page from a new chat and coming back keeps the unsent input")
    func returningFromPushedPageKeepsNewChatInput() async throws {
        let environment = try ChatDraftEnvironment(conversations: { _ in [] })
        defer { environment.tearDown() }
        let model = ChatDraftHostModel(conversationID: nil)
        let host = try environment.host(ChatDraftHostRoot(model: model, state: environment.state))
        let input = try await Self.waitForInput(in: host.view)
        input.becomeFirstResponder()
        Self.type("keep me", into: input)
        try await Self.waitUntil { input.text == "keep me" }
        input.resignFirstResponder()

        model.path = [1]
        try await Self.settle(seconds: 0.8)
        model.path = []
        try await Self.settle(seconds: 0.8)
        let returned = try await Self.waitForInput(in: host.view)
        #expect(returned.text == "keep me", "Returning to the chat screen cleared the input")
    }

    // MARK: - Helpers

    static func withProvider(_ conversation: Conversation, _ provider: Provider) -> Conversation {
        var copy = conversation
        copy.providerID = provider.id
        copy.providerKind = provider.kind
        return copy
    }

    static func conversationWithMessages(draftText: String) -> Conversation {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        return TestFactories.makeConversation(
            messages: (0..<2).map { index in
                var message = TestFactories.makeMessage(
                    role: index.isMultiple(of: 2) ? .user : .assistant,
                    text: index.isMultiple(of: 2) ? "Question" : "Answer"
                )
                message.createdAt = base.addingTimeInterval(TimeInterval(index))
                return message
            },
            draftText: draftText,
            updatedAt: base.addingTimeInterval(10)
        )
    }

    static func settle(seconds: TimeInterval = 0.3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The default timeout is 8s: this group runs host-based tests that wait on real UIKit first
    /// responder changes, SwiftUI updates and GRDB writes. 3s is not enough on a machine also
    /// building or capturing screenshots, where it turns "not yet" into a failure. The condition
    /// returns as soon as it holds, so a longer ceiling only affects the failing path — a real
    /// deadlock still fails, just a few seconds later.
    static func waitUntil(
        timeout: TimeInterval = 8,
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for the condition", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Focuses through the focus binding (the same path ChatView uses to drive `composerFocused`) and waits
    /// until the text view really is the first responder.
    private static func focus(_ harness: ComposerDraftHarness, _ input: UITextView) async throws {
        harness.setFocus?(true)
        try await waitUntil { harness.isFocused && input.isFirstResponder }
    }

    /// Moves the caret to the end before inserting, the same UITextInput path as continuing to type.
    static func type(_ text: String, into input: UITextView) {
        input.selectedTextRange = input.textRange(from: input.endOfDocument, to: input.endOfDocument)
        input.insertText(text)
    }

    static func waitForInput(in view: UIView) async throws -> UITextView {
        var input: UITextView?
        try await waitUntil {
            input = firstEditableTextView(in: view)
            return input != nil
        }
        return try #require(input, "The chat input was not found")
    }

    private static func firstEditableTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isEditable, !textView.isHidden, textView.window != nil {
            return textView
        }
        for subview in view.subviews {
            if let found = firstEditableTextView(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - Test hosts

private struct ChatDraftEnvironmentError: Error {}

/// The same real database and AppState setup as ChatComposerTypingHangCostTests.
@MainActor
private final class ChatDraftEnvironment {
    let uid: String
    let previousUID: String
    let provider: Provider
    let state: AppState
    private let window: UIWindow

    init(conversations: (Provider) -> [Conversation]) throws {
        uid = "composer-draft-\(UUID().uuidString)"
        previousUID = AppSessionStore.activeUID
        provider = TestFactories.makeProvider(kind: .openAI)
        DatabaseManager.shared.close()
        let seeded = conversations(provider)
        if !seeded.isEmpty {
            _ = try ConversationRuntimeBridge().replaceAllConversations(seeded, uid: uid)
            DatabaseManager.shared.close()
        }
        state = AppState(sessionUID: uid)
        // Switch after creating AppState: in a clean container the first AppState runs the partition
        // migration and switches back to the guest partition.
        AppSessionStore.switchToUser(uid)
        state.providers = [provider]
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw ChatDraftEnvironmentError()
        }
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    }

    func host<Root: View>(_ root: Root) throws -> UIHostingController<Root> {
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return host
    }

    func persistedDraft(_ conversationID: UUID) throws -> String? {
        try DatabaseManager.shared.openCurrent().read { db in
            try ConversationStore.fetchConversationSummary(db: db, id: conversationID)?.draftText
        }
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        state.flushConversationPersistQueue()
        DatabaseManager.shared.close()
        AppSessionStore.switchToUser(previousUID)
        try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
    }
}

@MainActor
@Observable
private final class ChatDraftHostModel {
    var conversationID: UUID?
    var showsChat = true
    var path: [Int] = []

    init(conversationID: UUID?) {
        self.conversationID = conversationID
    }
}

private struct ChatDraftHostRoot: View {
    let model: ChatDraftHostModel
    let state: AppState

    var body: some View {
        @Bindable var model = model
        Group {
            if model.showsChat {
                NavigationStack(path: $model.path) {
                    ChatView(conversationID: model.conversationID)
                        .navigationDestination(for: Int.self) { _ in Color.white }
                }
            } else {
                Color.clear
            }
        }
        .environment(state)
    }
}

/// Stands in for ChatView driving the composer: pushes, store echoes and the conversation id are
/// controlled by the test, and writes still go through AppState.
@MainActor
@Observable
private final class ComposerDraftHarness {
    var conversationID: UUID?
    var storeDraft: String?
    var push = ChatComposerTextPush()
    var showsComposer = true
    var scenePhase: ScenePhase = .active
    var commits: [ChatComposerDraftSession.Write] = []
    /// Mirror of the host view's focus state, plus a way to set it.
    var isFocused = false
    @ObservationIgnored var setFocus: ((Bool) -> Void)?

    init(conversationID: UUID?, storeDraft: String?) {
        self.conversationID = conversationID
        self.storeDraft = storeDraft
    }
}

private struct ComposerDraftHarnessView: View {
    let environment: ChatDraftEnvironment
    let harness: ComposerDraftHarness

    @State private var attachments: [Oriveo.Attachment] = []
    @State private var quoteContext: QuoteContext?
    @State private var reasoningMode: ReasoningMode = .automatic
    @State private var reasoningIntent: String?
    @State private var webEnabled = false
    @State private var scopeID = UUID()
    @State private var focused = false

    var body: some View {
        VStack {
            Spacer()
            if harness.showsComposer {
                ChatComposerBar(
                    provider: environment.provider,
                    currentModel: environment.provider.models.first,
                    visibleCapabilityKeys: [],
                    capabilityEvidenceIdentity: nil,
                    generationProjection: nil,
                    capabilityDecision: .resolve(
                        webRequested: false,
                        webPermitted: false,
                        reasoningModeRequested: .automatic,
                        reasoningModePermitted: true,
                        reasoningIntentRequested: nil,
                        reasoningIntentPermitted: false
                    ),
                    isSendingMessage: false,
                    conversationID: harness.conversationID,
                    generationParameterScopeID: scopeID,
                    storeDraft: harness.storeDraft,
                    textPush: harness.push,
                    onDraftCommit: { text, conversationID in
                        harness.commits.append(.init(conversationID: conversationID, text: text))
                        environment.state.updateDraftText(text, in: conversationID)
                    },
                    pendingAttachments: $attachments,
                    pendingQuoteContext: $quoteContext,
                    reasoningMode: $reasoningMode,
                    reasoningIntentSelection: $reasoningIntent,
                    webEnabled: $webEnabled,
                    composerFocused: $focused,
                    onSend: { _, _ in },
                    onChooseModel: {},
                    onCancel: {},
                    onShowPhotoPicker: {},
                    onShowCamera: {},
                    onShowFileImporter: {}
                )
                .environment(\.scenePhase, harness.scenePhase)
            }
        }
        .environment(environment.state)
        .onAppear { harness.setFocus = { focused = $0 } }
        .onChange(of: focused) { _, value in harness.isFocused = value }
    }
}
