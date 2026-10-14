import Foundation

// MARK: - Web search settings page board (WebSearch)
//
// The page header, protocol groups (expanded ones / those folded into "Other protocols"), the bottom action bar, and the decisions for back and filling in a template all live here;
// the view (`RelayWebSearchPage`) only renders. Draft validation and persistence remain in `RelayWebSearchDraft` and are not repeated here.

struct RelayWebSearchBoardModel: Equatable, Sendable {
    /// The page header has only a back button on the leading side; a pushed sub-page shows no close button.
    enum HeaderLeading: Equatable, Sendable {
        case back
    }

    struct Header: Equatable, Sendable {
        let leading: HeaderLeading
        let titleKey: String
        let titleTable: L10n.Table
        /// Subtitle: the connection name.
        let subtitle: String
    }

    enum GroupID: String, Equatable, Sendable {
        /// Protocols this connection will use, always expanded.
        case primary
        /// The remaining protocols, folded into "Other protocols".
        case other
    }

    /// One card per protocol: editor + "Use template" and "Clear".
    struct Section: Equatable, Sendable {
        let transport: RelayTransport
        let error: RelayWebFragments.ValidationError?
        /// Explanation below the card (only Chat Completions has one).
        let noteKey: String?
    }

    struct Group: Equatable, Sendable {
        let id: GroupID
        /// nil = no group title (the protocol cards appear directly).
        let titleKey: String?
        let sections: [Section]
        let isCollapsible: Bool
        let startsExpanded: Bool
        /// Number of protocols in the group that already have content; written on the right of the group title, omitted when 0.
        let filledCount: Int

        var hasError: Bool { sections.contains { $0.error != nil } }

        /// Collapsing would hide the error while the Save button is disabled: pin the group open while it has an invalid segment.
        var isPinnedOpen: Bool { isCollapsible && hasError }

        /// - userChoice: the state after the user tapped the group header; nil if never tapped.
        func isExpanded(userChoice: Bool?) -> Bool {
            guard isCollapsible else { return true }
            if isPinnedOpen { return true }
            return userChoice ?? startsExpanded
        }

        /// Expansion state to remember after the group header is tapped. Tapping the header while pinned open is not recorded as "collapse",
        /// otherwise the whole group would collapse in front of the user as soon as the JSON is fixed.
        func userChoiceAfterTap(_ userChoice: Bool?) -> Bool {
            isPinnedOpen ? true : !isExpanded(userChoice: userChoice)
        }
    }

    struct ActionBar: Equatable, Sendable {
        /// "Save" in the default table (Localizable).
        let primaryKey: String
        let isPrimaryEnabled: Bool
        /// Notice line above the Save button: a web search probe is sent automatically after saving.
        let disclosureKey: String
    }

    /// The line below the groups for "models that rejected these settings": model name + "Test again".
    struct RejectedModel: Equatable, Sendable {
        let modelID: String
        let name: String
    }

    enum BackAction: Equatable, Sendable {
        case pop
        case confirmDiscard
    }

    enum TemplateAction: Equatable, Sendable {
        case fill
        case confirmReplace
    }

    /// The title uses the same key as the "Web search" row on the detail page (Chat table).
    static let titleKey = RelayDetailBoardModel.webSearchTitleKey
    static let otherProtocolsKey = "Other protocols"
    static let saveKey = "Save"
    static let disclosureKey = "After you save, up to 5 enabled models each get one web search request with your key, to check that search works. Searches may be billed."
    static let rejectedTitleKey = "Models that reject these settings"
    static let retestKey = "Test again"
    /// The unsaved-changes prompt fully reuses the edit-connection copy and has no separate copy.
    static let discardTitleKey = "Discard unsaved changes?"
    static let discardMessageKey = RelayEditBoardModel.discardMessageKey
    static let discardKey = "Discard"
    static let keepEditingKey = "Keep editing"
    /// The overwrite confirmation's title and buttons reuse the chat page's "additional request body" paste-overwrite set (Chat table).
    static let replaceTitleKey = "Replace what’s here?"
    static let replaceKey = "Replace"
    static let replaceMessageKey = "The template replaces what you’ve entered for this protocol."
    /// Start zone and decision distance of the swipe-back: same direction as the app-level back gesture (rightward only).
    static let backSwipeEdgeWidth: CGFloat = 24
    static let backSwipeMinimumDistance: CGFloat = 60

    let header: Header
    let introKey: String
    let groups: [Group]
    /// Enabled models whose current record is rejected (in enabling order); empty = the rejected area is not drawn.
    let rejected: [RejectedModel]
    let footerKey: String
    let actionBar: ActionBar
    let isDirty: Bool

    /// Groups pinned open by an error: the view records them as "expanded" and keeps them so after the error disappears (the user is editing inside).
    var groupsPinnedOpen: [GroupID] { groups.filter(\.isPinnedOpen).map(\.id) }

    /// The back button and the swipe use the same decision.
    var backAction: BackAction { isDirty ? .confirmDiscard : .pop }

    /// With unsaved changes, stop the swipe and go back directly; otherwise a single swipe would lose them.
    var allowsBackSwipe: Bool { !isDirty }

    /// When leaving this page, hand the app-level swipe back regardless of whether there were changes.
    static let allowsBackSwipeAfterLeaving = true
    /// JSON is code and does not flip with interface direction: in an RTL interface the editor still runs left to right.
    static let forcesLeftToRightEditor = true

    // MARK: Assembly

    /// nil = this connection has no web search settings page (not a relay, or a local engine).
    static func make(
        provider: Provider,
        draft: RelayWebSearchDraft,
        saved: RelayWebSearchDraft,
        fragments: RelayWebFragmentStore = .shared,
        records: RelayWebProbeStore = .shared
    ) -> Self? {
        guard let used = usedTransports(provider) else { return nil }
        return make(
            subtitle: provider.displayName, used: used, draft: draft, saved: saved,
            rejected: rejectedModels(provider: provider, fragments: fragments, records: records)
        )
    }

    /// - used: the result of `usedTransports(_:)`. The view computes it once on entering the page and passes it in, so the detail page's row model is not recomputed while typing.
    /// - saved: the content on entering the page, the baseline for judging whether there are unsaved changes.
    static func make(
        subtitle: String,
        used: [RelayTransport],
        draft: RelayWebSearchDraft,
        saved: RelayWebSearchDraft,
        rejected: [RejectedModel] = []
    ) -> Self {
        let all = RelayWebFragments.transports
        // When not a single protocol has been verified, there is no way to tell which ones go unused: expand all four segments and hide none.
        let primary = used.isEmpty ? all : all.filter(used.contains)
        let other = all.filter { !primary.contains($0) }

        var groups = [group(.primary, transports: primary, draft: draft)]
        if !other.isEmpty {
            groups.append(group(.other, transports: other, draft: draft))
        }

        let isDirty = all.contains { normalized(draft.text($0)) != normalized(saved.text($0)) }
        return Self(
            header: Header(leading: .back, titleKey: titleKey, titleTable: .chat, subtitle: subtitle),
            introKey: RelayWebSearchDraft.introKey,
            groups: groups,
            rejected: rejected,
            footerKey: RelayWebSearchDraft.footerKey,
            actionBar: ActionBar(primaryKey: saveKey, isPrimaryEnabled: isDirty && draft.canSave, disclosureKey: disclosureKey),
            isDirty: isDirty
        )
    }

    /// Protocols this connection will use, in the settings page's segment order. Takes the set behind the detail page's "Base paths" row;
    /// when the connection protocol is chosen it contains at least that one (once chosen, models follow it even if the root address has not been verified).
    /// nil = no such page; empty = no basis yet.
    static func usedTransports(_ provider: Provider) -> [RelayTransport]? {
        guard let detail = RelayDetailBoardModel.make(provider), detail.form == .relay else { return nil }
        var used = Set(detail.connectionRows.first { $0.id == .basePaths }?.basePaths.map(\.transport) ?? [])
        let requested = RelayEndpointResolver.requestedConnectionTransport(of: provider)
        if requested != .auto { used.insert(requested) }
        return RelayWebFragments.transports.filter(used.contains)
    }

    /// Rejected area: among enabled models (in enabling order), those whose first-sent protocol has a saved snippet and whose record under the current snippet is rejected.
    /// Looks only at saved snippets, not the draft.
    static func rejectedModels(
        provider: Provider, fragments: RelayWebFragmentStore, records: RelayWebProbeStore
    ) -> [RejectedModel] {
        let set = fragments.chatFragments(for: provider)
        return provider.models.compactMap { model in
            // When the first-choice transport has no saved fragment the effective fragment is the template; a rejected template goes through the capability retest and does not belong in this section.
            guard RelayWebProbe.isEligible(provider: provider, model: model),
                  set?.object(for: RelayWebProbe.transport(provider: provider, model: model)) != nil,
                  RelayWebProbe.currentResult(provider: provider, model: model, fragments: set, records: records) == .rejected
            else { return nil }
            return RejectedModel(modelID: model.id, name: model.name.isEmpty ? model.id : model.name)
        }
    }

    // MARK: Saving

    /// Save: write the snippets to storage; the connection with the old web search fields cleared is handed to `persist` to store.
    /// Returns the new baseline draft; with an invalid segment nothing is written, `persist` is not called, and nil is returned.
    static func commit(
        _ draft: RelayWebSearchDraft,
        provider: Provider,
        store: RelayWebFragmentStore = .shared,
        persist: (Provider) -> Void
    ) -> RelayWebSearchDraft? {
        guard let updated = draft.save(provider: provider, store: store) else { return nil }
        persist(updated)
        return draft
    }

    // MARK: Decisions

    /// "Use template": confirmation is needed only when the box holds other content; if it is empty or already the template, fill it directly.
    static func templateAction(for transport: RelayTransport, draft: RelayWebSearchDraft) -> TemplateAction {
        let current = normalized(draft.text(transport))
        guard !current.isEmpty, current != (RelayWebFragments.template(for: transport) ?? "") else { return .fill }
        return .confirmReplace
    }

    /// Whether this is a swipe-back: starts at the left edge, goes right, horizontally dominant.
    /// Only edge starts count: dragging the cursor or a selection in the editor is also a horizontal drag and must not count as going back.
    static func isBackSwipe(startX: CGFloat, dx: CGFloat, dy: CGFloat) -> Bool {
        startX <= backSwipeEdgeWidth && dx >= backSwipeMinimumDistance && dx > abs(dy) * 2
    }

    // MARK: Private

    private static func group(_ id: GroupID, transports: [RelayTransport], draft: RelayWebSearchDraft) -> Group {
        Group(
            id: id,
            titleKey: id == .other ? otherProtocolsKey : nil,
            sections: transports.map { transport in
                Section(
                    transport: transport,
                    error: draft.error(transport),
                    noteKey: transport == .openaiChatCompletions ? RelayWebSearchDraft.chatNoteKey : nil
                )
            },
            isCollapsible: id == .other,
            startsExpanded: id != .other,
            filledCount: transports.filter { !normalized(draft.text($0)).isEmpty }.count
        )
    }

    /// Whitespace only = not filled (on save that segment is deleted as well).
    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
    }
}
