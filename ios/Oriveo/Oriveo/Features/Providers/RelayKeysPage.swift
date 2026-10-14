import SwiftUI

// MARK: - Keys page board
//
// Data comes only through `RelayKeyBinding` (rows / showsKeyUI / keys / Operation); all writes go through
// `ProviderManager.applyRelayKeyOperation`, and replacing the key of an implicit single key uses the existing single-key replace path (`EditAPIKeySheet`).
// Status is read only from `RelayKey.status`; this page sends no probes of its own.

struct RelayKeysBoardModel: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Open the model library filtered by this key; only shown when this key's catalog has entries, and listed first.
        case viewModels, rename, replaceSecret, moveUp, moveDown, delete
    }

    struct LastStatus: Equatable, Sendable {
        let httpStatus: Int
        let statusKey: String
        let checkedAt: Date?
    }

    /// Marker before the status word: healthy = dot, anything else = warning icon, this key's catalog still loading = spinner; never checked draws nothing.
    enum StatusIcon: Equatable, Sendable {
        case dot, warning, progress
    }

    struct Row: Equatable, Sendable {
        let id: String
        /// Name; with no name (or an implicit single key) the mask is used.
        let title: String
        let hasName: Bool
        let maskedSecret: String
        let showsPrimaryBadge: Bool
        let state: RelayKey.Status.State?
        /// nil = never checked: neither the status word nor the marker is drawn (including the VoiceOver reading).
        let statusKey: String?
        let statusIcon: StatusIcon?
        /// nil = the catalog has no model listed by this key (shows "—").
        let catalogCount: Int?
        let enabledCount: Int
        /// "Last: <code> <status word> · <time>" when the status is not healthy and has a status code.
        let lastStatus: LastStatus?
        /// Action sheet shown when a key is tapped, ordered by when each action applies.
        let actions: [Action]

        /// Caption slot of the action sheet: the primary key's sheet has no delete, so it says how to delete before the user chooses (instead of a red button that only objects after being tapped).
        var panelMessageKey: String? {
            showsPrimaryBadge ? RelayKeysBoardModel.primaryNotDeletableKey : nil
        }
    }

    /// Rows of the key card from top to bottom: one per key; a connection that needs credentials gets one more row, "Add key", at the end.
    enum ListItem: Equatable, Sendable, Identifiable {
        case key(Row)
        case addKey

        var id: String {
            switch self {
            case let .key(row): "key:\(row.id)"
            case .addKey: "add-key"
            }
        }
    }

    /// One row of the explanation card: the action plus its consequence, visible before choosing.
    struct ActionNote: Equatable, Sendable {
        let action: Action
        let hintKey: String
    }

    /// The one sentence the page owes the user after an operation finishes.
    enum Notice: Hashable, Sendable {
        /// The key is saved, but this key's catalog was not fetched (the request failed or was rejected).
        case fetchFailed
        /// The key is saved, but this key's fetch result was not written back: a later refresh took over the connection's refresh ownership, or the connection has fewer than two keys,
        /// so `refreshRelayCatalog` abandoned the whole run and that key's status is still empty. Without a note this would be a silent drop.
        case fetchInterrupted
        /// The operation was not accepted (the connection is gone / structural rejection). The UI cannot reach this, but it must still not be silent.
        case rejected
        /// Added successfully and this key's catalog write-back is ok: it lists `listed` models, of which `new` are listed only by this key.
        /// Carries the keyID for the trailing link (open the model library filtered by this key).
        case added(keyID: String, listed: Int, new: Int)

        var messageKey: String {
            switch self {
            case .fetchFailed: RelayKeysBoardModel.fetchFailedNoticeKey
            case .fetchInterrupted: RelayKeysBoardModel.fetchInterruptedNoticeKey
            case .rejected: RelayKeysBoardModel.rejectedNoticeKey
            case .added: RelayKeysBoardModel.addedNoticeKey
            }
        }

        /// Success style (green check); the other three are warnings.
        var isSuccess: Bool {
            if case .added = self { return true }
            return false
        }

        /// The key opened by the trailing "View models" link; only `added` has it.
        var modelsKeyID: String? {
            if case let .added(keyID, _, _) = self { return keyID }
            return nil
        }
    }

    enum InputMode: Equatable, Sendable {
        case add, replace, rename
    }

    struct InputField: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case name, secret
        }

        let kind: Kind
        let titleKey: String
        /// A literal value, not copy: in the name slot it is what this row shows when no name is entered (that key's mask, or empty if none yet); in the key slot it is what the key looks like.
        let placeholder: String
    }

    struct InputSheet: Equatable, Sendable {
        let titleKey: String
        /// "Rename" is in the common table; the rest are in the Providers table.
        let titleTable: L10n.Table
        let fields: [InputField]
        let hintKey: String?
    }

    /// What to say before deleting: the primary key cannot be deleted; for other keys, list the models in use and the primary key they fall back to.
    enum DeletePrompt: Equatable, Sendable {
        case primaryNotDeletable
        case confirm(modelNames: [String], fallbackKeyTitle: String)
    }

    /// Which path replacing a key takes: implicit / only one key left = the existing single-key replace-key sheet; two or more keys = `replaceSecret`.
    enum ReplaceRoute: Equatable, Sendable {
        case singleKeySheet
        case keyOperation
    }

    static let titleKey = "API Keys"
    static let keysCountKey = "%lld keys"
    static let primaryHintKey = "The first key is the primary key"
    static let primaryBadgeKey = "Primary"
    static let catalogCountKey = "Catalog: %lld models"
    static let viewModelsActionKey = "View models (%lld)"
    static let addedNoticeKey = "Key added · Lists %lld models"
    static let addedNewNoticeKey = "%lld new"
    static let noticeViewModelsKey = "View models"
    static let catalogNoneKey = "Catalog: —"
    static let enabledUsingKey = "%lld enabled models use it"
    static let enabledNoneKey = "No models use it"
    static let lastStatusKey = "Last: %1$@ · %2$@"
    static let addKey = "Add key"
    static let footnoteKey = "Key status comes from model list fetches and real requests, including capability tests."
    static let renameHintKey = "Only changes the display name. Bindings stay the same."
    static let replaceKey = "Replace key"
    static let replaceHintKey = "Only this key’s model list is fetched again. The model library isn’t cleared."
    static let deleteHintKey = "Models using it switch to the primary key. They’re listed before deleting."
    static let moveUpKey = "Move up"
    static let moveDownKey = "Move down"
    static let deleteTitleKey = "Delete this key?"
    static let deleteMessageKey = "%1$lld models use it. After deleting, they’ll use %2$@."
    static let deleteMessageNoneKey = "No models use it."
    static let primaryNotDeletableKey = "To delete the primary key, move another key to the top first."
    static let fetchingKey = "Loading model list..."
    static let appliesNowKey = "Changes apply right away."
    static let actionNotesTitleKey = "Actions for each key"
    static let fetchFailedNoticeKey = "Key saved, but its model list couldn’t be fetched. See its status in the list."
    static let rejectedNoticeKey = "Couldn’t apply this change. Please try again."
    static let fetchInterruptedNoticeKey =
        "Key saved, but fetching its model list was interrupted by another change. Use Detect again to fetch it."
    static let nameFieldKey = "Name (optional)"
    static let secretFieldKey = "API Key"
    static let secretPlaceholder = "sk-..."

    let host: String
    let keyCount: Int
    /// `showsKeyUI` false (implicit or only one key left): one row, no name and no badge, only replacing the key.
    let isSingle: Bool
    let rows: [Row]
    /// A connection that needs no credentials has no "Add key".
    let showsAddKey: Bool

    var listItems: [ListItem] {
        rows.map(ListItem.key) + (showsAddKey ? [.addKey] : [])
    }

    /// With a single key there is no explanation card: it can only be replaced, and the replace-key sheet explains itself. The consequence of moving up / down is covered by "the first key is the primary key" above the card.
    var actionNotes: [ActionNote] {
        guard !isSingle else { return [] }
        return [
            ActionNote(action: .rename, hintKey: Self.renameHintKey),
            ActionNote(action: .replaceSecret, hintKey: Self.replaceHintKey),
            ActionNote(action: .delete, hintKey: Self.deleteHintKey),
        ]
    }

    /// - Parameter fetchingKeyIDs: the keys just added / replaced whose catalog is still loading. `ProviderManager` only publishes at the connection level
    ///   (`relayCatalogRefreshingProviderIDs`), so the page that started the operation passes in which key it was.
    static func make(_ provider: Provider, fetchingKeyIDs: Set<String> = []) -> Self {
        let isSingle = !RelayKeyBinding.showsKeyUI(provider)
        let keys = RelayKeyBinding.keys(provider)
        let readRows = RelayKeyBinding.rows(provider)
        let rows = readRows.enumerated().map { index, row -> Row in
            let status = keys.first(where: { $0.id == row.id })?.status
            let name = isSingle ? nil : row.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasName = name?.isEmpty == false
            let masked = row.maskedSecret.isEmpty ? APIKeyMask.fullyMasked : row.maskedSecret
            let isFetching = fetchingKeyIDs.contains(row.id)
            var lastStatus: LastStatus?
            // While a re-fetch is running the previous failure is no longer the current state, so the two are not shown side by side.
            if !isFetching, let status, status.state != .ok, let code = status.httpStatus {
                lastStatus = LastStatus(httpStatus: code, statusKey: statusKey(status.state), checkedAt: status.checkedAt)
            }
            return Row(
                id: row.id,
                title: hasName ? (name ?? masked) : masked,
                hasName: hasName,
                maskedSecret: row.maskedSecret,
                showsPrimaryBadge: !isSingle && row.isPrimary,
                state: row.status,
                statusKey: isFetching ? fetchingKey : row.status.map(statusKey),
                statusIcon: isFetching ? .progress : row.status.map(statusIcon),
                catalogCount: row.catalogCount > 0 ? row.catalogCount : nil,
                enabledCount: row.enabledCount,
                lastStatus: lastStatus,
                actions: actions(index: index, count: readRows.count, isSingle: isSingle, catalogCount: row.catalogCount)
            )
        }
        return Self(
            host: host(provider),
            keyCount: rows.count,
            isSingle: isSingle,
            rows: rows,
            showsAddKey: RelayCredentialPolicy.requiresCredential(provider.relayRequested)
        )
    }

    static func statusKey(_ state: RelayKey.Status.State) -> String {
        switch state {
        case .ok: "Active"
        case .invalid: "Invalid"
        case .denied: "No access"
        case .limited: "Out of credit or rate-limited"
        case .failed: "Failed"
        }
    }

    static func statusIcon(_ state: RelayKey.Status.State) -> StatusIcon {
        switch state {
        case .ok: .dot
        default: .warning
        }
    }

    static func replaceRoute(_ provider: Provider) -> ReplaceRoute {
        RelayKeyBinding.showsKeyUI(provider) ? .keyOperation : .singleKeySheet
    }

    // MARK: Operations (only assemble the Operation; writing is left to ProviderManager)

    static func addOperation(id: String, name: String, apiKey: String) -> RelayKeyBinding.Operation? {
        let secret = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return .add(id: id, name: trimmedName(name), apiKey: secret)
    }

    static func replaceOperation(id: String, apiKey: String) -> RelayKeyBinding.Operation? {
        let secret = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return .replaceSecret(id: id, apiKey: secret)
    }

    /// Clearing the name = store nil, and the row goes back to the mask.
    static func renameOperation(id: String, name: String) -> RelayKeyBinding.Operation? {
        guard !id.isEmpty else { return nil }
        return .rename(id: id, name: trimmedName(name))
    }

    /// Move up / move down / delete; nil for no move-up on the first key, no move-down on the last key, and no delete on the primary key.
    static func operation(_ action: Action, keyID: String, in provider: Provider) -> RelayKeyBinding.Operation? {
        let ids = RelayKeyBinding.keyIDs(provider)
        guard RelayKeyBinding.showsKeyUI(provider), let index = ids.firstIndex(of: keyID) else { return nil }
        switch action {
        case .moveUp: return index > 0 ? .move(id: keyID, toIndex: index - 1) : nil
        case .moveDown: return index < ids.count - 1 ? .move(id: keyID, toIndex: index + 1) : nil
        case .delete: return index > 0 ? .delete(id: keyID) : nil
        case .viewModels, .rename, .replaceSecret: return nil
        }
    }

    static func deletePrompt(_ provider: Provider, keyID: String) -> DeletePrompt? {
        let board = make(provider)
        guard let index = board.rows.firstIndex(where: { $0.id == keyID }) else { return nil }
        guard index > 0 else { return .primaryNotDeletable }
        let ids = RelayKeyBinding.keyIDs(provider)
        let names = provider.models
            .filter { RelayKeyBinding.effectiveKeyID($0.relayKeyID, keyIDs: ids) == keyID }
            // Display name; with no display name use the model id (the same on every platform).
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.id : $0.name }
        return .confirm(modelNames: names, fallbackKeyTitle: board.rows[0].title)
    }

    // MARK: What to say after an operation

    /// Which key's catalog is fetched after this operation (only add and replace key).
    static func fetchedKeyID(_ operation: RelayKeyBinding.Operation) -> String? {
        switch operation {
        case let .add(id, _, _): id
        case let .replaceSecret(id, _): id
        case .rename, .move, .delete, .rebind: nil
        }
    }

    /// `accepted` = the return value of `applyRelayKeyOperation`; `provider` = the connection after the operation finished.
    /// The fetch result is read only from the `RelayKey.status` written back for that key; this page sends no probes. Both add and replaceSecret clear that key's status,
    /// and any fetch that writes back always leaves a status; still empty after returning = this fetch was abandoned. If that key has been deleted there is nothing to say.
    static func notice(accepted: Bool, operation: RelayKeyBinding.Operation, provider: Provider?) -> Notice? {
        guard accepted else { return .rejected }
        guard let keyID = fetchedKeyID(operation), let provider,
              let row = RelayKeyBinding.rows(provider).first(where: { $0.id == keyID }) else { return nil }
        switch row.status {
        case nil: return .fetchInterrupted
        case .ok?:
            // Only say something when the add succeeded and this key listed entries; a successful replace or an empty catalog says nothing.
            guard case .add = operation, row.catalogCount > 0 else { return nil }
            return .added(keyID: keyID, listed: row.catalogCount, new: onlyListedCount(provider, keyID: keyID))
        case _?: return .fetchFailed
        }
    }

    /// Number of entries listed only by this key and by none of the other existing keys; "lists" uses the same criterion as `RelayKeyBinding.listingKeyIDs`.
    static func onlyListedCount(_ provider: Provider, keyID: String) -> Int {
        let keyIDs = RelayKeyBinding.keyIDs(provider)
        return provider.catalogModels.filter { entry in
            Set(RelayKeyBinding.listingKeyIDs(entry, keyIDs: keyIDs)).intersection(keyIDs) == [keyID]
        }.count
    }

    /// Notice text: added = the "Key added · Lists N models" copy + (if M > 0) " · " + "M new"; the others are one fixed sentence.
    static func noticeText(_ notice: Notice) -> String {
        guard case let .added(_, listed, new) = notice else { return L10n.tr(notice.messageKey, table: .providers) }
        var text = String(format: L10n.tr(addedNoticeKey, table: .providers), Int64(listed))
        if new > 0 {
            text += " · " + String(format: L10n.tr(addedNewNoticeKey, table: .providers), Int64(new))
        }
        return text
    }

    /// Shared by the sheet's "View models (N)" and the link in the add-success notice: push the model library filtered by this key (going back returns to the keys page).
    @MainActor
    static func openModels(keyID: String, providerID: UUID, in appState: AppState) {
        appState.openRelayModelLibrary(providerID: providerID, keyID: keyID)
    }

    // MARK: Input alert

    /// - Parameter maskedSecret: when renaming, that key's mask, used as the name placeholder (after the name is cleared the row shows it).
    static func inputSheet(_ mode: InputMode, maskedSecret: String = "") -> InputSheet {
        let secret = InputField(kind: .secret, titleKey: secretFieldKey, placeholder: secretPlaceholder)
        switch mode {
        case .add:
            // There is no mask yet when adding; do not compute one from the key being typed, so each keystroke does not leak the plaintext tail into the placeholder.
            return InputSheet(
                titleKey: addKey,
                titleTable: .providers,
                fields: [InputField(kind: .name, titleKey: nameFieldKey, placeholder: ""), secret],
                hintKey: nil
            )
        case .replace:
            return InputSheet(titleKey: replaceKey, titleTable: .providers, fields: [secret], hintKey: replaceHintKey)
        case .rename:
            return InputSheet(
                titleKey: "Rename",
                titleTable: .localizable,
                fields: [InputField(kind: .name, titleKey: nameFieldKey, placeholder: maskedSecret)],
                hintKey: renameHintKey
            )
        }
    }

    // MARK: Private

    private static func actions(index: Int, count: Int, isSingle: Bool, catalogCount: Int) -> [Action] {
        let head: [Action] = catalogCount > 0 ? [.viewModels] : []
        guard !isSingle else { return head + [.replaceSecret] }
        var out: [Action] = head + [.rename, .replaceSecret]
        if index > 0 { out.append(.moveUp) }
        if index < count - 1 { out.append(.moveDown) }
        if index > 0 { out.append(.delete) }
        return out
    }

    private static func trimmedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func host(_ provider: Provider) -> String {
        let raw = (provider.baseURLText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        return URL(string: withScheme)?.host ?? raw
    }
}

// MARK: - In-flight page state

/// Registry of in-flight operations and outcomes for a series of operations on the keys page. The view only calls `begin` / `finish`; concurrency ordering is covered by unit tests.
/// - The same key can be in flight twice in a row (replaced, then replaced again); fetching is counted per operation and removed only when the last one completes.
/// - Outcomes are appended one by one: when two keys finish interleaved, the later one does not overwrite the earlier one's sentence.
struct RelayKeysPageState: Equatable, Sendable {
    /// Which keys an in-flight operation registered as fetching (add re-fetches all of them).
    private struct Pending: Equatable, Sendable {
        let operation: RelayKeyBinding.Operation
        let keyIDs: [String]
    }

    private(set) var fetchingCounts: [String: Int] = [:]
    private(set) var notices: [RelayKeysBoardModel.Notice] = []
    private var pending: [Pending] = []

    var fetchingKeyIDs: Set<String> {
        Set(fetchingCounts.keys)
    }

    /// - Parameter provider: the connection before the operation; add uses it to also register every existing key as fetching (they will all be re-fetched).
    mutating func begin(_ operation: RelayKeyBinding.Operation, provider: Provider? = nil) {
        var keyIDs: [String] = []
        if case .add = operation, let provider {
            keyIDs = RelayKeyBinding.keyIDs(provider)
        }
        if let keyID = RelayKeysBoardModel.fetchedKeyID(operation), !keyIDs.contains(keyID) {
            keyIDs.append(keyID)
        }
        for keyID in keyIDs {
            fetchingCounts[keyID, default: 0] += 1
        }
        pending.append(Pending(operation: operation, keyIDs: keyIDs))
        // A notice that was already given stays until the next operation; ones still in flight append as usual when they finish.
        notices = []
    }

    /// - Parameters: `accepted` / `provider` are the same as in `RelayKeysBoardModel.notice` (`provider` is the connection at the moment of completion).
    /// The outcome looks only at the key this operation fetched (add = the newly added key).
    mutating func finish(_ operation: RelayKeyBinding.Operation, accepted: Bool, provider: Provider?) {
        let keyIDs: [String]
        if let index = pending.firstIndex(where: { $0.operation == operation }) {
            keyIDs = pending.remove(at: index).keyIDs
        } else {
            keyIDs = RelayKeysBoardModel.fetchedKeyID(operation).map { [$0] } ?? []
        }
        let noticeKeyID = RelayKeysBoardModel.fetchedKeyID(operation)
        var noticeKeyStillFetching = false
        for keyID in keyIDs {
            let remaining = (fetchingCounts[keyID] ?? 1) - 1
            if remaining > 0 {
                fetchingCounts[keyID] = remaining
                if keyID == noticeKeyID { noticeKeyStillFetching = true }
            } else {
                fetchingCounts[keyID] = nil
            }
        }
        // A later operation on this key is still in flight: the fetch outcome is reported by the last one to finish, using the connection at that time, so we never announce "interrupted" and then retract it.
        if noticeKeyStillFetching, accepted { return }
        guard let notice = RelayKeysBoardModel.notice(accepted: accepted, operation: operation, provider: provider),
              !notices.contains(notice) else { return }
        notices.append(notice)
    }
}

#if DEBUG
extension RelayKeysPageState {
    /// Screenshots only: preset the notice the page already gave (add-success notice).
    init(debugNotices: [RelayKeysBoardModel.Notice]) {
        self.init()
        notices = debugNotices
    }
}
#endif

// MARK: - View

struct RelayKeysPage: View {
    typealias Board = RelayKeysBoardModel

    let providerID: UUID

    @Environment(AppState.self) private var appState
    @State private var selectedKeyID: String?
    #if DEBUG
    // Screenshots only: open the page with the "Add key" alert showing.
    @State private var showAddKey = RelayFamilyDebugShots.presentsAddKey
    #else
    @State private var showAddKey = false
    #endif
    @State private var renamingKeyID: String?
    @State private var replacingKeyID: String?
    @State private var showSingleKeySheet = false
    @State private var deletePrompt: (keyID: String, prompt: Board.DeletePrompt)?
    /// The keys just added / replaced whose catalog is still loading (from the start until `applyRelayKeyOperation` returns, which waits for the fetch to finish), and the outcome of each step.
    #if DEBUG
    // Screenshots only: show the given keys as "catalog still loading"; the in-flight count is private(set), so register through begin.
    // Add-success screenshot: preset the notice computed by the production notice function.
    @State private var pageState = RelayFamilyDebugShots.fetchingKeyIDs.reduce(
        into: RelayKeysPageState(debugNotices: RelayFamilyDebugShots.keysNotices)
    ) {
        $0.begin(.replaceSecret(id: $1, apiKey: ""))
    }
    #else
    @State private var pageState = RelayKeysPageState()
    #endif

    private var provider: Provider? {
        appState.provider(for: providerID)
    }

    var body: some View {
        Group {
            if let provider {
                let board = Board.make(provider, fetchingKeyIDs: pageState.fetchingKeyIDs)
                ScrollView {
                    VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xl) {
                        header(board)
                        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                            if !board.isSingle {
                                sectionTitle(Board.primaryHintKey)
                            }
                            keyList(board)
                            ForEach(pageState.notices, id: \.self) { notice in
                                noticeLine(notice)
                            }
                            footnotes
                        }
                        if !board.actionNotes.isEmpty {
                            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                                sectionTitle(Board.actionNotesTitleKey)
                                actionNotesCard(board)
                            }
                        }
                    }
                    .frame(maxWidth: OriveoTheme.Layout.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, OriveoTheme.Spacing.xl)
                    .padding(.top, OriveoTheme.Spacing.lg)
                    .padding(.bottom, OriveoTheme.Spacing.xxl)
                    .frame(maxWidth: .infinity)
                }
                .oriveoScreenBackground()
                .confirmationDialog(
                    selectedRow(board)?.title ?? "",
                    isPresented: selectedKeyPresented,
                    titleVisibility: .visible,
                    presenting: selectedRow(board)
                ) { row in
                    actionButtons(row, provider: provider)
                } message: { row in
                    if let messageKey = row.panelMessageKey {
                        Text(L10n.tr(messageKey, table: .providers))
                    }
                }
                .alert(
                    deletePrompt.map { alertTitle($0.prompt) } ?? "",
                    isPresented: deletePromptPresented,
                    presenting: deletePrompt
                ) { item in
                    if case .confirm = item.prompt {
                        Button(L10n.tr("Delete"), role: .destructive) {
                            apply(Board.operation(.delete, keyID: item.keyID, in: provider))
                        }
                        Button(L10n.tr("Cancel"), role: .cancel) {}
                    } else {
                        Button(L10n.tr("OK"), role: .cancel) {}
                    }
                } message: { item in
                    Text(alertMessage(item.prompt))
                }
                .sheet(isPresented: $showAddKey) {
                    RelayKeyInputSheet(mode: .add) { name, secret in
                        apply(Board.addOperation(id: "k-\(UUID().uuidString.lowercased())", name: name, apiKey: secret))
                    }
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                }
                .sheet(item: renamingSheetItem) { item in
                    RelayKeyInputSheet(
                        mode: .rename,
                        currentName: provider.relayKeys?.first(where: { $0.id == item.id })?.name ?? "",
                        maskedSecret: board.rows.first(where: { $0.id == item.id })?.maskedSecret ?? ""
                    ) { name, _ in
                        apply(Board.renameOperation(id: item.id, name: name))
                    }
                    // The custom header + bottom action bar is taller than the system navigation bar version.
                    .presentationDetents([.height(340)])
                    .presentationDragIndicator(.visible)
                }
                .sheet(item: replacingSheetItem) { item in
                    RelayKeyInputSheet(mode: .replace) { _, secret in
                        apply(Board.replaceOperation(id: item.id, apiKey: secret))
                    }
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                }
                .sheet(isPresented: $showSingleKeySheet) {
                    EditAPIKeySheet(providerID: providerID)
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                }
            } else {
                ProgressView()
                    .tint(OriveoTheme.Palette.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .oriveoScreenBackground()
            }
        }
    }

    // MARK: Header

    private func header(_ board: Board) -> some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                OriveoBackButton {
                    appState.pop()
                }
                .padding(.leading, -OriveoBackButton.edgeInset)
                Text(L10n.tr(Board.titleKey, table: .providers))
                    .font(OriveoTheme.Typography.title2)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            Text(subtitle(board))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
        }
    }

    private func subtitle(_ board: Board) -> String {
        let count = String(format: L10n.tr(Board.keysCountKey, table: .providers), Int64(board.keyCount))
        return board.host.isEmpty ? count : "\(board.host) · \(count)"
    }

    /// Drawn the same way as the group title above the cards on the detail page.
    private func sectionTitle(_ key: String) -> some View {
        Text(L10n.tr(key, table: .providers))
            .font(OriveoTheme.Typography.footnote.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: List

    private func keyList(_ board: Board) -> some View {
        let items = board.listItems
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                switch item {
                case let .key(row):
                    keyRow(row)
                case .addKey:
                    addRow
                }
                if index < items.count - 1 {
                    cardDivider
                }
            }
        }
        .background(cardBackground)
    }

    private func keyRow(_ row: Board.Row) -> some View {
        Button {
            selectedKeyID = row.id
        } label: {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                RelayKeyRowView(row: row, showsEnabledCount: true)
                // The trailing arrow is drawn only on the keys page: the few keys inlined on the detail page get an arrow from the row that contains them.
                PhosphorIcon.caretRight.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .flipsForRightToLeftLayoutDirection(true)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Add key" is the last row of the key card, not a separate card.
    private var addRow: some View {
        Button {
            showAddKey = true
        } label: {
            HStack(spacing: OriveoTheme.Spacing.sm) {
                PhosphorIcon.plus.image(.regular)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(L10n.tr(Board.addKey, table: .providers))
                    .font(OriveoTheme.Typography.body.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(OriveoTheme.Palette.primary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(OriveoTheme.Palette.border.opacity(0.6))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
            .fill(OriveoTheme.Palette.surfaceElevated)
    }

    private func noticeLine(_ notice: Board.Notice) -> some View {
        HStack(alignment: .top, spacing: 6) {
            (notice.isSuccess ? PhosphorIcon.checkCircle : PhosphorIcon.warning).image(.regular)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(notice.isSuccess ? OriveoTheme.Palette.success : OriveoTheme.Palette.warning)
                .accessibilityHidden(true)
            Text(Board.noticeText(notice))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(notice.isSuccess ? OriveoTheme.Palette.textSecondary : OriveoTheme.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            if let keyID = notice.modelsKeyID {
                Spacer(minLength: OriveoTheme.Spacing.sm)
                Button(L10n.tr(Board.noticeViewModelsKey, table: .providers)) {
                    Board.openModels(keyID: keyID, providerID: providerID, in: appState)
                }
                .buttonStyle(.plain)
                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                .foregroundStyle(OriveoTheme.Palette.primary)
            }
        }
    }

    /// This page has no save button, so the footer states that changes take effect immediately.
    private var footnotes: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xs) {
            Text(L10n.tr(Board.appliesNowKey, table: .providers))
            Text(L10n.tr(Board.footnoteKey, table: .providers))
        }
        .font(OriveoTheme.Typography.footnote)
        .foregroundStyle(OriveoTheme.Palette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Explanation card

    private func actionNotesCard(_ board: Board) -> some View {
        let notes = board.actionNotes
        return VStack(spacing: 0) {
            ForEach(Array(notes.enumerated()), id: \.element.action) { index, note in
                HStack(spacing: OriveoTheme.Spacing.md) {
                    actionIcon(note.action).image(.duotone)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(actionTint(note.action))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(actionTitle(note.action))
                            .font(OriveoTheme.Typography.caption.weight(.semibold))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        Text(L10n.tr(note.hintKey, table: .providers))
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 56)
                .accessibilityElement(children: .combine)
                if index < notes.count - 1 {
                    cardDivider
                }
            }
        }
        .background(cardBackground)
    }

    private func actionTitle(_ action: Board.Action) -> String {
        switch action {
        case .viewModels: L10n.tr(Board.noticeViewModelsKey, table: .providers)
        case .rename: L10n.tr("Rename")
        case .replaceSecret: L10n.tr(Board.replaceKey, table: .providers)
        case .moveUp: L10n.tr(Board.moveUpKey, table: .providers)
        case .moveDown: L10n.tr(Board.moveDownKey, table: .providers)
        case .delete: L10n.tr("Delete")
        }
    }

    private func actionIcon(_ action: Board.Action) -> PhosphorIcon {
        switch action {
        case .viewModels: .squaresFour
        case .rename: .pencilSimple
        case .replaceSecret: .arrowsClockwise
        case .moveUp: .arrowUp
        case .moveDown: .arrowDown
        case .delete: .trash
        }
    }

    private func actionTint(_ action: Board.Action) -> Color {
        switch action {
        case .viewModels, .rename, .moveUp, .moveDown: OriveoTheme.Palette.primary
        case .replaceSecret: DetailRowPalette.cyan
        case .delete: OriveoTheme.Palette.danger
        }
    }

    // MARK: Action sheet

    @ViewBuilder
    private func actionButtons(_ row: Board.Row, provider: Provider) -> some View {
        ForEach(row.actions, id: \.self) { action in
            switch action {
            case .viewModels:
                Button(
                    String(format: L10n.tr(Board.viewModelsActionKey, table: .providers), Int64(row.catalogCount ?? 0))
                ) {
                    Board.openModels(keyID: row.id, providerID: provider.id, in: appState)
                }
            case .rename:
                Button(L10n.tr("Rename")) {
                    renamingKeyID = row.id
                }
            case .replaceSecret:
                Button(L10n.tr(Board.replaceKey, table: .providers)) {
                    if Board.replaceRoute(provider) == .singleKeySheet {
                        showSingleKeySheet = true
                    } else {
                        replacingKeyID = row.id
                    }
                }
            case .moveUp:
                Button(L10n.tr(Board.moveUpKey, table: .providers)) {
                    apply(Board.operation(.moveUp, keyID: row.id, in: provider))
                }
            case .moveDown:
                Button(L10n.tr(Board.moveDownKey, table: .providers)) {
                    apply(Board.operation(.moveDown, keyID: row.id, in: provider))
                }
            case .delete:
                Button(L10n.tr("Delete"), role: .destructive) {
                    if let prompt = Board.deletePrompt(provider, keyID: row.id) {
                        deletePrompt = (row.id, prompt)
                    }
                }
            }
        }
        Button(L10n.tr("Cancel"), role: .cancel) {}
    }

    private func alertTitle(_ prompt: Board.DeletePrompt) -> String {
        switch prompt {
        case .primaryNotDeletable: L10n.tr("Delete")
        case .confirm: L10n.tr(Board.deleteTitleKey, table: .providers)
        }
    }

    private func alertMessage(_ prompt: Board.DeletePrompt) -> String {
        switch prompt {
        case .primaryNotDeletable:
            return L10n.tr(Board.primaryNotDeletableKey, table: .providers)
        case let .confirm(modelNames, fallback):
            guard !modelNames.isEmpty else { return L10n.tr(Board.deleteMessageNoneKey, table: .providers) }
            let summary = String(
                format: L10n.tr(Board.deleteMessageKey, table: .providers),
                Int64(modelNames.count),
                fallback
            )
            return ([summary] + modelNames).joined(separator: "\n")
        }
    }

    private func apply(_ operation: RelayKeyBinding.Operation?) {
        guard let operation else { return }
        let providerID = providerID
        pageState.begin(operation, provider: appState.provider(for: providerID))
        Task {
            let accepted = await appState.providerManager.applyRelayKeyOperation(providerID: providerID, operation)
            pageState.finish(operation, accepted: accepted, provider: appState.provider(for: providerID))
        }
    }

    // MARK: Binding

    private func selectedRow(_ board: Board) -> Board.Row? {
        selectedKeyID.flatMap { id in board.rows.first { $0.id == id } }
    }

    private var selectedKeyPresented: Binding<Bool> {
        Binding(get: { selectedKeyID != nil }, set: { if !$0 { selectedKeyID = nil } })
    }

    private var deletePromptPresented: Binding<Bool> {
        Binding(get: { deletePrompt != nil }, set: { if !$0 { deletePrompt = nil } })
    }

    private struct KeyItem: Identifiable {
        let id: String
    }

    private var renamingSheetItem: Binding<KeyItem?> {
        Binding(get: { renamingKeyID.map(KeyItem.init) }, set: { renamingKeyID = $0?.id })
    }

    private var replacingSheetItem: Binding<KeyItem?> {
        Binding(get: { replacingKeyID.map(KeyItem.init) }, set: { replacingKeyID = $0?.id })
    }
}

/// One key's row: shared by the inline list on the detail page (first 3 keys) and the keys page.
struct RelayKeyRowView: View {
    /// Maximum share of the row width taken by the trailing status column.
    static let statusMaxFraction: CGFloat = 0.5

    let row: RelayKeysBoardModel.Row
    /// The keys page adds a row for "number of enabled models using it" and the last status; the inline list on the detail page shows only the first three items.
    var showsEnabledCount: Bool = false

    var body: some View {
        rowLayout
            .accessibilityElement(children: .combine)
    }

    /// Catalog row: with a name, the mask is always in the leading column as the prefix "<mask> · <catalog>";
    /// with no name the title itself is the mask, so it is not repeated.
    static func catalogLine(maskedSecret: String, hasName: Bool, catalog: String) -> String {
        hasName ? "\(maskedSecret) · \(catalog)" : catalog
    }

    /// Leading column: title row (name / primary-key badge) + "mask · catalog" row + on the keys page the enabled count and last status; the trailing column has only the status, vertically centered on the whole row.
    /// Pinned to the title row, the right side of the lines below would stay empty and not line up with the vertically centered trailing arrow.
    private var rowLayout: some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.sm) {
            // The status column takes at most 50% of the row width: a long status word wraps instead of squeezing "mask · catalog".
            RelayMenuRowColumns(spacing: OriveoTheme.Spacing.sm, trailingMaxFraction: Self.statusMaxFraction) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: OriveoTheme.Spacing.sm) {
                        Text(verbatim: row.title)
                            .font(OriveoTheme.Typography.body.weight(.medium))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .lineLimit(1)
                        if row.showsPrimaryBadge {
                            primaryBadge
                        }
                    }
                    Text(verbatim: Self.catalogLine(maskedSecret: row.maskedSecret, hasName: row.hasName, catalog: catalogText))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsEnabledCount {
                        // Ideal width recorded as 0: a long sentence does not compete for the trailing status's width and wraps as usual.
                        Text(enabledText)
                            .font(OriveoTheme.Typography.footnote)
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                        if let last = row.lastStatus {
                            Text(lastStatusText(last))
                                .font(OriveoTheme.Typography.footnote)
                                .foregroundStyle(OriveoTheme.Palette.warning)
                                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let statusKey = row.statusKey, let statusIcon = row.statusIcon {
                    statusLabel(key: statusKey, icon: statusIcon)
                }
            }
        }
    }

    private var primaryBadge: some View {
        Text(L10n.tr(RelayKeysBoardModel.primaryBadgeKey, table: .providers))
            .font(OriveoTheme.Typography.footnote.weight(.semibold))
            .foregroundStyle(OriveoTheme.Palette.primary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(OriveoTheme.Palette.primarySoft))
            .fixedSize()
    }

    /// Status is not conveyed by color alone: the word is preceded by a dot / warning icon / spinner. The status word takes at most 2 lines, with the marker on the same line as the first.
    private func statusLabel(key: String, icon: RelayKeysBoardModel.StatusIcon) -> some View {
        HStack(alignment: .top, spacing: 4) {
            // Pad with an invisible same-size line to fix the first line's height; the marker is centered within that line and does not drop to the middle of two lines when the status word wraps.
            Text(verbatim: " ")
                .font(OriveoTheme.Typography.footnote)
                .hidden()
                .frame(width: 14)
                .overlay { statusIconView(icon) }
            Text(L10n.tr(key, table: .providers))
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func statusIconView(_ icon: RelayKeysBoardModel.StatusIcon) -> some View {
        switch icon {
        case .dot:
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        case .warning:
            PhosphorIcon.warning.image(.regular)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 13, height: 13)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
        case .progress:
            ProgressView()
                .controlSize(.mini)
                .tint(statusColor)
        }
    }

    private var statusColor: Color {
        if row.statusIcon == .progress { return OriveoTheme.Palette.textSecondary }
        switch row.state {
        case .ok: return OriveoTheme.Palette.success
        case nil: return OriveoTheme.Palette.textTertiary
        default: return OriveoTheme.Palette.warning
        }
    }

    private var catalogText: String {
        guard let count = row.catalogCount else {
            return L10n.tr(RelayKeysBoardModel.catalogNoneKey, table: .providers)
        }
        return String(format: L10n.tr(RelayKeysBoardModel.catalogCountKey, table: .providers), Int64(count))
    }

    private var enabledText: String {
        guard row.enabledCount > 0 else { return L10n.tr(RelayKeysBoardModel.enabledNoneKey, table: .providers) }
        return String(format: L10n.tr(RelayKeysBoardModel.enabledUsingKey, table: .providers), Int64(row.enabledCount))
    }

    private func lastStatusText(_ last: RelayKeysBoardModel.LastStatus) -> String {
        let status = "\(last.httpStatus) \(L10n.tr(last.statusKey, table: .providers))"
        // With no check time only the time is missing; nothing is made up.
        let time = last.checkedAt.map(relativeTimeText(from:)) ?? "—"
        return String(format: L10n.tr(RelayKeysBoardModel.lastStatusKey, table: .providers), status, time)
    }
}

/// Input alert shared by add / replace key / rename: the family's common modal style "close at top leading + centered title + bottom action bar", without the system navigation bar.
private struct RelayKeyInputSheet: View {
    let mode: RelayKeysBoardModel.InputMode
    var currentName = ""
    var maskedSecret = ""
    let onSave: (_ name: String, _ secret: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var secret = ""

    private var canSave: Bool {
        switch mode {
        case .add, .replace: !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .rename: true
        }
    }

    var body: some View {
        let sheet = RelayKeysBoardModel.inputSheet(mode, maskedSecret: maskedSecret)
        VStack(spacing: 0) {
            header(sheet)
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.md) {
                ForEach(sheet.fields, id: \.kind) { field in
                    OriveoLabeledField(
                        title: L10n.tr(field.titleKey, table: .providers),
                        text: field.kind == .name ? $name : $secret,
                        placeholder: field.placeholder,
                        isSecure: field.kind == .secret
                    )
                }
                if let hintKey = sheet.hintKey {
                    Text(L10n.tr(hintKey, table: .providers))
                        .font(OriveoTheme.Typography.footnote)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OriveoTheme.Spacing.xl)
            .padding(.top, OriveoTheme.Spacing.md)
        }
        .oriveoScreenBackground()
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .onAppear {
            if mode == .rename { name = currentName }
        }
    }

    /// A sheet without a navigation bar gets 24pt of top padding, otherwise the title sticks to the top edge of the sheet.
    private func header(_ sheet: RelayKeysBoardModel.InputSheet) -> some View {
        ZStack {
            Text(L10n.tr(sheet.titleKey, table: sheet.titleTable))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
                // Make room for the close button at top leading while keeping the title visually centered.
                .padding(.horizontal, 52)

            HStack {
                Button { dismiss() } label: {
                    PhosphorIcon.x.image(.regular)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: OriveoTheme.Radius.md, style: .continuous)
                                .fill(OriveoTheme.Palette.surfaceElevated)
                        )
                        // Drawn at 36pt, with the tappable area padded to 44pt.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Close"))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, OriveoTheme.Spacing.xl - 4)
        .padding(.top, 24)
        .padding(.bottom, OriveoTheme.Spacing.sm)
    }

    private var actionBar: some View {
        Button(L10n.tr("Save")) {
            onSave(name, secret)
            dismiss()
        }
        .buttonStyle(OriveoPrimaryButtonStyle())
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.4)
        .padding(.horizontal, OriveoTheme.Spacing.xl)
        .padding(.top, OriveoTheme.Spacing.md)
        .padding(.bottom, OriveoTheme.Spacing.lg)
    }
}
