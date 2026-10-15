import Foundation

/// Key of a handoff snapshot: a stored conversation by id; a new conversation (no id yet) is the draft.
enum ChatCarrierKey: Hashable {
    case draft
    case conversation(UUID)

    init(conversationID: UUID?) {
        self = conversationID.map { .conversation($0) } ?? .draft
    }
}

/// Sheets to reopen on the new view after a carrier change. System pickers (camera, photos, files) and confirmation dialogs are not among them.
enum ChatCarrierSheet {
    case modelPicker
    case mcpTools
}

/// `ChatView`'s page state: a new conversation is not stored, so after a carrier rebuild this is the only way it comes back.
struct ChatPageCarrierState {
    var pendingAttachments: [Attachment]
    var pendingQuoteContext: QuoteContext?
    var reasoningMode: ReasoningMode
    var reasoningIntentSelection: String?
    var webEnabled: Bool
    var generationParameterDraftSessionID: UUID
    var sheet: ChatCarrierSheet?
}

/// The composer's transient state: text (a new conversation has no stored draft), focus, and whether the model options panel is open.
struct ChatComposerCarrierState: Equatable {
    var text: String
    var isFocused: Bool
    var showsModelControls: Bool
}

/// The handoff the list bridge uses when it creates a controller: `readingAnchor == nil` means at the bottom. Having one means this is a carrier rebuild
/// with no push transition to protect, so the controller skips the entrance delay.
struct ChatListCarrierRestore: Equatable {
    let readingAnchor: ChatReadingAnchor?
}

struct ChatCarrierSnapshot {
    let key: ChatCarrierKey
    let capturedAt: Date
    let page: ChatPageCarrierState?
    let composer: ChatComposerCarrierState?
    /// Whether a list controller existed when the snapshot was taken (an empty conversation has no list, and then no list state is handed over).
    let hasList: Bool
    let readingAnchor: ChatReadingAnchor?
}

/// Hands the page state over when a conversation changes carrier (two-column detail column ↔ outer stack); one per window, owned by `NavigationManager`.
///
/// Moving a conversation in `updateLayoutWidth` rebuilds `ChatView` from scratch, losing a new conversation's
/// input, pending attachments, toggles, reading position, focus and any open sheet. The three parties
/// (page, composer, list bridge) each register a provider; a snapshot is captured synchronously before
/// the move and the new page consumes it once by key.
///
/// Registrations carry a token: the new view may appear before the old one's onDisappear, and the old view only removes its own registration.
@MainActor
final class ChatCarrierHandoff {
    struct Token: Hashable {
        fileprivate let raw: UInt64
    }

    /// Snapshot lifetime: the move and the new view's appearance are a frame or two apart, so anything older is unrelated to the current page.
    static let freshnessWindow: TimeInterval = 2

    private struct Registration<Value> {
        let token: Token
        let provide: () -> Value
    }

    private let now: () -> Date
    private var nextTokenRaw: UInt64 = 0
    private var pageProvider: Registration<ChatPageCarrierState>?
    private var composerProvider: Registration<ChatComposerCarrierState>?
    private var readingAnchorProvider: Registration<ChatReadingAnchor?>?
    private var snapshot: ChatCarrierSnapshot?
    /// List handoff already consumed by the page and waiting for the list controller (which is only created once there are messages, so it has to wait).
    /// Owned by the page that consumed it: discarded when that page unregisters.
    private var pendingListRestore: (owner: Token, restore: ChatListCarrierRestore)?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    // MARK: - Registration

    func registerPage(_ provide: @escaping () -> ChatPageCarrierState) -> Token {
        let token = makeToken()
        pageProvider = Registration(token: token, provide: provide)
        return token
    }

    func registerComposer(_ provide: @escaping () -> ChatComposerCarrierState) -> Token {
        let token = makeToken()
        composerProvider = Registration(token: token, provide: provide)
        return token
    }

    func registerReadingAnchor(_ provide: @escaping () -> ChatReadingAnchor?) -> Token {
        let token = makeToken()
        readingAnchorProvider = Registration(token: token, provide: provide)
        return token
    }

    /// Clears only what this token registered; does nothing once a newer registration has replaced it.
    func unregister(_ token: Token) {
        if pageProvider?.token == token { pageProvider = nil }
        if composerProvider?.token == token { composerProvider = nil }
        if readingAnchorProvider?.token == token { readingAnchorProvider = nil }
        if pendingListRestore?.owner == token { pendingListRestore = nil }
    }

    /// The composer's current text (dropped text is appended after it); nil before the composer has registered.
    func liveComposerText() -> String? {
        composerProvider?.provide().text
    }

    // MARK: - Capture and consume

    /// Called synchronously before the move: the old views still exist, so each provider reads what the user is looking at.
    func capture(key: ChatCarrierKey) {
        pendingListRestore = nil
        let anchorProvider = readingAnchorProvider
        snapshot = ChatCarrierSnapshot(
            key: key,
            capturedAt: now(),
            page: pageProvider?.provide(),
            composer: composerProvider?.provide(),
            hasList: anchorProvider != nil,
            readingAnchor: anchorProvider?.provide() ?? nil
        )
    }

    /// Consumed once by key when the new page appears: a mismatched key or an expired snapshot is discarded (and the snapshot cleared).
    /// If a list existed at capture time, the list handoff is kept for `owner` until its list controller is created.
    func consume(key: ChatCarrierKey, by owner: Token) -> ChatCarrierSnapshot? {
        guard let snapshot else { return nil }
        self.snapshot = nil
        guard snapshot.key == key,
              now().timeIntervalSince(snapshot.capturedAt) <= Self.freshnessWindow else { return nil }
        if snapshot.hasList {
            pendingListRestore = (owner, ChatListCarrierRestore(readingAnchor: snapshot.readingAnchor))
        }
        return snapshot
    }

    /// Taken once by the list bridge when it creates the controller.
    func takeListRestore() -> ChatListCarrierRestore? {
        defer { pendingListRestore = nil }
        return pendingListRestore?.restore
    }

    private func makeToken() -> Token {
        nextTokenRaw += 1
        return Token(raw: nextTokenRaw)
    }
}
