import Observation
import SwiftUI

/// What the detail (right) column of the wide-screen two-column layout is showing.
///
/// `.empty` and `.draft` are different things and cannot share one `UUID?`: the first means
/// nothing is selected yet and the column renders its empty state, the second means a new,
/// unsaved conversation. In the single-column era the two were told apart by whether a `.chat`
/// route sat on the navigation path; once the conversation moves into a selection they have to
/// be modelled explicitly.
enum ChatDetailState: Hashable {
    case empty
    case draft
    case conversation(UUID)

    /// The id of a stored conversation. Neither `.empty` nor `.draft` has one.
    var conversationID: UUID? {
        if case let .conversation(id) = self { return id }
        return nil
    }

    var isEmpty: Bool { self == .empty }
}

/// The current window's own navigation manager. With several windows (iPad, Duo) the window's root view injects it;
/// when it is nil, views fall back to `AppState.navigation` (the active window).
private struct WindowNavigationKey: EnvironmentKey {
    static var defaultValue: NavigationManager? { nil }
}

/// Whether this window offers "Open in New Window". The window's root view computes it with `canOpenConversationWindow` and injects it.
private struct CanOpenConversationWindowKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {
    var windowNavigation: NavigationManager? {
        get { self[WindowNavigationKey.self] }
        set { self[WindowNavigationKey.self] = newValue }
    }

    var canOpenConversationWindow: Bool {
        get { self[CanOpenConversationWindowKey.self] }
        set { self[CanOpenConversationWindowKey.self] = newValue }
    }
}

// Routing, tab switching and navigation path state
// Pure navigation logic extracted from AppState
@MainActor
@Observable
final class NavigationManager {

    /// The tab this window is on. Each window has its own, so windows never interfere.
    var selectedTab: AppTab = .home {
        didSet { onSelectedTabChange?() }
    }
    /// Single observation point for tab changes: AppState persists the session snapshot from it.
    @ObservationIgnored var onSelectedTabChange: (() -> Void)?

    var path: [AppRoute] = []
    /// What the wide-screen detail column is showing. It sits beside `path`: `path` drives
    /// push/pop of the outer routes, this drives the conversation column alone.
    ///
    /// **Invariant: a conversation only ever lives in one carrier.** At regular width that is
    /// `chatDetail`; at compact width it is a `.chat` route on `path`, which keeps the
    /// pre-two-column behaviour exactly (the outer stack covers the whole screen including the
    /// tab bar, and an edge swipe pops back to the previous route).
    /// `updateLayoutWidth(isRegular:)` moves the conversation between the two, so both are
    /// never occupied at once.
    var chatDetail: ChatDetailState = .empty
    /// Whether the window currently uses two columns (see `usesSplitLayout`). Defaults to a single
    /// column so the first frame after a cold start renders narrow; `AppRootView` corrects it as
    /// soon as it has the real size class and window width.
    private(set) var isRegularWidth = false

    func openProviderSetup(from entryPoint: ProviderSetupEntryPoint, preselectedKind: ProviderKind? = nil) {
        attemptNavigate(to: .providerSetup(entryPoint: entryPoint, preselectedKind: preselectedKind))
    }

    func openProviderDetail(providerID: UUID) {
        attemptNavigate(to: .providerDetail(providerID: providerID))
    }

    func openManualModelEntry(providerID: UUID, context: ManualModelEntryContext) {
        attemptNavigate(to: .manualModelEntry(providerID: providerID, context: context))
    }

    /// Opens the conversation detail. At regular width this writes the detail column; at
    /// compact width it goes through the outer stack.
    ///
    /// The compact branch has to replace the top route when a conversation is already showing:
    /// a `removeLast` followed by an `append` in the same tick makes NavigationStack run two
    /// transitions against each other.
    func presentChat(conversationID: UUID?) {
        guard !isRegularWidth else {
            chatDetail = conversationID.map { .conversation($0) } ?? .draft
            return
        }
        if isShowingChatRoute {
            replaceLast(with: .chat(conversationID: conversationID))
        } else {
            attemptNavigate(to: .chat(conversationID: conversationID))
        }
    }

    /// Dismisses the conversation detail and returns to the "no conversation" state.
    ///
    /// When `conversationID` is non-nil this only applies to that one conversation, so a caller
    /// reacting to a deletion cannot close a different conversation the user has since opened.
    func dismissChat(conversationID: UUID? = nil) {
        if isRegularWidth {
            if let conversationID, chatDetail.conversationID != conversationID { return }
            chatDetail = .empty
        } else {
            guard isShowingChatRoute else { return }
            if let conversationID, path.last != .chat(conversationID: conversationID) { return }
            pop()
        }
    }

    /// Lands on "one new conversation", the end state after onboarding or provider setup.
    func resetToNewChat() {
        guard !isRegularWidth else {
            path = []
            chatDetail = .draft
            return
        }
        path = [.chat(conversationID: nil)]
    }

    func openBackup() {
        attemptNavigate(to: .backup)
    }

    func openRelayModelLibrary(providerID: UUID, keyID: String? = nil) {
        attemptNavigate(to: .relayModelLibrary(providerID: providerID, keyID: keyID))
    }

    func openRelayKeys(providerID: UUID) {
        attemptNavigate(to: .relayKeys(providerID: providerID))
    }

    func openRelayWebSearch(providerID: UUID) {
        attemptNavigate(to: .relayWebSearch(providerID: providerID))
    }

    func openRelayModelAdvanced(providerID: UUID, modelID: String, readOnly: Bool) {
        attemptNavigate(to: .relayModelAdvanced(providerID: providerID, modelID: modelID, readOnly: readOnly))
    }

    func openRelaySetup(from entryPoint: ProviderSetupEntryPoint) {
        attemptNavigate(to: .relaySetup(entryPoint: entryPoint))
    }

    func openMemory() {
        attemptNavigate(to: .memory)
    }

    func openSkillsList() {
        attemptNavigate(to: .skillsList)
    }

    func openSkillEdit(skillID: UUID? = nil) {
        attemptNavigate(to: .skillEdit(skillID))
    }

    func openNotesList() {
        attemptNavigate(to: .notesList)
    }

    func openNoteDetail(noteID: UUID) {
        attemptNavigate(to: .noteDetail(noteID: noteID))
    }

    func attemptNavigate(to route: AppRoute) {
        path.append(route)
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func popToRoot() {
        path = []
    }

    func replaceLast(with route: AppRoute) {
        guard !path.isEmpty else {
            path.append(route)
            return
        }
        path[path.count - 1] = route
    }

    /// Replaces the whole stack. Onboarding completion swaps the root content, which has to land
    /// on its target stack in one step rather than pushing route by route.
    func reset(to newPath: [AppRoute]) {
        path = newPath
    }

    /// Drops the provider setup subtree while keeping the route that launched it.
    func returnToProviderSetupCaller() {
        path = ProviderSetupCompletionPolicy.returnedCallerPath(from: path)
    }

    // MARK: - Layout changes

    /// Minimum full window width for two columns: a 360pt sidebar plus a 420pt conversation column.
    static let splitLayoutMinimumWidth: CGFloat = 780

    /// Whether "Open in New Window" is offered: multiple windows are supported **and** the window is
    /// horizontally regular.
    ///
    /// `supportsMultipleWindows` alone is not enough: on the Duo's cover screen (466pt, compact) it
    /// also reports true, yet the cover screen cannot open a new window. The system's
    /// `UIWindowSceneActivationAction` hides itself there, and a SwiftUI menu has no equivalent, so
    /// the decision is made on the available space: a compact window does not get the item (nor does
    /// a narrow iPad window; a wide one still does).
    static func canOpenConversationWindow(supportsMultipleWindows: Bool, horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        supportsMultipleWindows && horizontalSizeClass == .regular
    }

    /// Two columns only when the size class is regular **and** the full window width is at least
    /// `splitLayoutMinimumWidth`; anything else is a single column.
    ///
    /// The size class alone is not enough: an unfolded Duo held upright is 669pt and still regular,
    /// too narrow for the two minimum column widths, so the system collapses the sidebar and leaves
    /// only the empty detail column — the home screen disappears. An 11" iPad in portrait (834pt)
    /// fits two columns. An unknown width (not measured yet, 0) means a single column.
    static func usesSplitLayout(horizontalSizeClass: UserInterfaceSizeClass?, windowWidth: CGFloat) -> Bool {
        horizontalSizeClass == .regular && windowWidth >= splitLayoutMinimumWidth
    }

    /// Moves the conversation to the carrier that matches the new layout, keeping the
    /// "only one carrier" invariant. `isRegular` means "uses two columns" (the result of
    /// `usesSplitLayout`), not the raw size class.
    ///
    /// Folding and unfolding is a real, frequent path on an iPhone Duo, not a corner: folding
    /// while reading a conversation in the detail column has to put that conversation on the
    /// outer stack, and unfolding while inside a conversation has to move it into the detail
    /// column — otherwise the two-column home renders with an empty right side and the
    /// conversation the user was reading simply vanishes.
    func updateLayoutWidth(isRegular: Bool) {
        guard isRegular != isRegularWidth else { return }
        isRegularWidth = isRegular

        if isRegular {
            guard case let .chat(conversationID) = path.last else { return }
            path.removeLast()
            chatDetail = conversationID.map { .conversation($0) } ?? .draft
        } else {
            guard !chatDetail.isEmpty else { return }
            let conversationID = chatDetail.conversationID
            chatDetail = .empty
            attemptNavigate(to: .chat(conversationID: conversationID))
        }
    }

    // MARK: - Stack queries

    /// Whether a conversation detail is showing, in either carrier. The conversation screen
    /// carries its own sync status overlay, so the global offline banner is suppressed on this.
    var isShowingChat: Bool {
        isRegularWidth ? !chatDetail.isEmpty : isShowingChatRoute
    }

    private var isShowingChatRoute: Bool {
        if case .chat = path.last { return true }
        return false
    }
}
