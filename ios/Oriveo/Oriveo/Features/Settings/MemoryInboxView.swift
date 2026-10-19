import Foundation
import Observation
import OriveoProviderKit
import SwiftUI

/// Inbox "Edit" sheet target: the captured candidate plus the prefilled item editor (new-item mode).
struct MemoryInboxEdit: Identifiable, Equatable, Sendable {
    let candidate: MemoryCandidate
    let state: MemoryItemEditorState

    var id: String { candidate.id }
}

/// Memory suggestions inbox (P6·U4 contract items 3, 4): pending candidates, newest first, with
/// save / edit / ignore. Actions run on app-level tasks so leaving the page does not cancel them.
@MainActor
@Observable
final class MemoryInboxModel {
    static let undoDuration: TimeInterval = 5

    /// Pending candidates in repository order (createdAtMs descending).
    private(set) var candidates: [MemoryCandidate] = []
    /// The first read has returned; before that the empty state is not drawn.
    private(set) var loaded = false

    /// Partition auto-suggest preference (default on). Off only skips implicit candidates; existing pending stay.
    private(set) var autoSuggestEnabled = true

    var showsEmptyState: Bool { loaded && candidates.isEmpty }

    /// Memory page entry row value: the pending count, nil when there is none.
    static func entryValue(pendingCount: Int) -> String? {
        pendingCount > 0 ? String(pendingCount) : nil
    }

    var entryValue: String? { Self.entryValue(pendingCount: candidates.count) }

    /// Group the candidate falls into; "About me" when proposedKind maps to none.
    static func group(for candidate: MemoryCandidate) -> MemoryItemGroup {
        MemoryItemGroup(kind: candidate.proposedKind) ?? .about
    }

    /// Re-read pending candidates (the repository sweeps expired / already-remembered ones first).
    /// A failed read keeps the previous list; failing on the first read shows the empty state.
    func reload(appState: AppState) async {
        loadAutoSuggest(appState: appState)
        #if DEBUG
        // Shots only: the manifest's candidates, never the real store.
        if let shots = MemoryShots.candidates {
            candidates = shots
            loaded = true
            return
        }
        #endif
        if let repository = appState.memoryCandidateRepository(),
           let pending = try? await repository.pending(nowMs: Self.nowMs()) {
            candidates = pending
        }
        loaded = true
    }

    /// Read the partition auto-suggest preference.
    func loadAutoSuggest(appState: AppState) {
        autoSuggestEnabled = appState.memoryCandidateRepository()?.autoSuggestEnabled() ?? true
    }

    /// Write the partition auto-suggest preference; the list is left as is.
    func setAutoSuggestEnabled(_ enabled: Bool, appState: AppState) {
        guard let repository = appState.memoryCandidateRepository() else { return }
        repository.setAutoSuggestEnabled(enabled)
        autoSuggestEnabled = repository.autoSuggestEnabled()
    }

    /// Editor prefilled from the candidate (new-item mode), group from proposedKind.
    func edit(_ candidate: MemoryCandidate) -> MemoryInboxEdit {
        MemoryInboxEdit(
            candidate: candidate,
            state: .create(category: Self.group(for: candidate), text: candidate.content)
        )
    }

    /// Save: accept the candidate as is. nil on failure.
    @discardableResult
    func save(_ candidate: MemoryCandidate, appState: AppState) async -> MemoryItem? {
        await accept(candidate.id, edit: nil, appState: appState)
    }

    /// Edit then save: edited content; kind only when the group was changed.
    @discardableResult
    func saveEdited(_ state: MemoryItemEditorState, for target: MemoryInboxEdit, appState: AppState) async -> MemoryItem? {
        guard state.canSave else { return nil }
        let edit = MemoryCandidateEdit(
            content: state.trimmedText,
            kind: state.category == Self.group(for: target.candidate) ? nil : state.kind
        )
        return await accept(target.candidate.id, edit: edit, appState: appState)
    }

    /// Ignore: reject the candidate (fingerprint kept); the row disappears.
    func ignore(_ candidate: MemoryCandidate, appState: AppState) async {
        candidates.removeAll { $0.id == candidate.id }
        guard let repository = appState.memoryCandidateRepository() else { return }
        do {
            try await repository.reject(id: candidate.id, nowMs: Self.nowMs())
        } catch {
            await reload(appState: appState)
        }
    }

    /// Undo a save: the normal item delete path on the item just created.
    func undo(itemID: String, appState: AppState) {
        _ = try? appState.memoryItemRepository()?.remove(id: itemID)
    }

    // MARK: - UI entries

    /// Save, then a 5 s "Saved to memory" toast whose action deletes the new item.
    @discardableResult
    func saveWithUndoToast(_ candidate: MemoryCandidate, appState: AppState) -> Task<Void, Never> {
        Task {
            let item = await self.save(candidate, appState: appState)
            self.showSavedToast(item, appState: appState)
        }
    }

    @discardableResult
    func saveEditedWithUndoToast(
        _ state: MemoryItemEditorState,
        for target: MemoryInboxEdit,
        appState: AppState
    ) -> Task<Void, Never> {
        Task {
            let item = await self.saveEdited(state, for: target, appState: appState)
            self.showSavedToast(item, appState: appState)
        }
    }

    @discardableResult
    func ignoreTask(_ candidate: MemoryCandidate, appState: AppState) -> Task<Void, Never> {
        Task { await self.ignore(candidate, appState: appState) }
    }

    @discardableResult
    func reloadTask(appState: AppState) -> Task<Void, Never> {
        Task { await self.reload(appState: appState) }
    }

    // MARK: - Private

    /// The row disappears right away; failure → "couldn't save" toast and a reload.
    private func accept(_ candidateID: String, edit: MemoryCandidateEdit?, appState: AppState) async -> MemoryItem? {
        candidates.removeAll { $0.id == candidateID }
        if let repository = appState.memoryCandidateRepository(),
           let item = try? await repository.accept(id: candidateID, edit: edit, nowMs: Self.nowMs()) {
            // A reload that ran while accepting may have brought the row back.
            candidates.removeAll { $0.id == candidateID }
            return item
        }
        ToastManager.shared.show(L10n.tr("memory_suggestion_failed", table: .chat), style: .error)
        await reload(appState: appState)
        return nil
    }

    private func showSavedToast(_ item: MemoryItem?, appState: AppState) {
        guard let item else { return }
        ToastManager.shared.show(
            L10n.tr("memory_suggestion_saved", table: .chat),
            duration: Self.undoDuration,
            actionTitle: L10n.tr("Undo", table: .notes)
        ) { [weak appState] in
            // Captures only appState: the undo must still work after the inbox page (and this model) is gone.
            _ = try? appState?.memoryItemRepository()?.remove(id: item.id)
        }
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// Memory › Memory suggestions: list of pending candidates or the empty state, then the footnote.
struct MemoryInboxView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = MemoryInboxModel()
    @State private var editTarget: MemoryInboxEdit? = nil
    /// The toolbar shows its material and title only once the content scrolls under it.
    @State private var isScrolled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.tr("memory_inbox_title", table: .chat))
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 4)

                autoSuggestSection
                    .padding(.top, 18)

                if model.showsEmptyState {
                    emptyState
                } else if !model.candidates.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 16))
                            .foregroundStyle(OriveoTheme.Palette.primary)
                            .accessibilityHidden(true)
                        Text(verbatim: "\(model.candidates.count)")
                            .font(OriveoTheme.Typography.brandDigits(13))
                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 26)
                    .padding(.bottom, 2)

                    ForEach(model.candidates, id: \.id) { candidate in
                        candidateCard(candidate)
                            .padding(.top, 12)
                    }
                }

                MemoryFootnote(systemImage: "iphone", text: L10n.tr("memory_inbox_footnote", table: .chat))
                    .padding(.top, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 40)
            .oriveoContentWidth()
        }
        .background(MemoryAtlasBackdrop(height: 300))
        .safeAreaInset(edge: .top) { toolbar }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 12
        } action: { _, scrolled in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                isScrolled = scrolled
            }
        }
        .onAppear {
            model.loadAutoSuggest(appState: appState)
            model.reloadTask(appState: appState)
        }
        .sheet(item: $editTarget) { target in
            MemoryItemEditorSheet(state: target.state) { saved in
                model.saveEditedWithUndoToast(saved, for: target, appState: appState)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            OriveoBackButton {
                appState.pop()
            }
            .padding(.leading, -OriveoBackButton.edgeInset)

            Spacer(minLength: 0)
        }
        .overlay {
            Text(L10n.tr("memory_inbox_title", table: .chat))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .opacity(isScrolled ? 1 : 0)
                .accessibilityHidden(!isScrolled)
                .allowsHitTesting(false)
        }
        .frame(minHeight: OriveoBackButton.hitSize)
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .background {
            Rectangle()
                .fill(.bar)
                .opacity(isScrolled ? 1 : 0)
                .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(height: 0.5)
                .opacity(isScrolled ? 1 : 0)
        }
    }

    private var autoSuggestBinding: Binding<Bool> {
        Binding(
            get: { model.autoSuggestEnabled },
            set: { model.setAutoSuggestEnabled($0, appState: appState) }
        )
    }

    private var autoSuggestSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(
                L10n.tr("memory_inbox_auto_suggest", table: .chat),
                isOn: autoSuggestBinding
            )
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(OriveoTheme.Palette.textPrimary)
            .tint(OriveoTheme.Palette.primaryTextSafe)
            .frame(minHeight: 56)

            Text(L10n.tr("memory_inbox_auto_suggest_footnote", table: .chat))
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCard(ring: true)
    }

    private var emptyState: some View {
        Text(L10n.tr("memory_inbox_empty", table: .chat))
            .font(.system(size: 15))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }

    /// Group eyebrow (glyph in the group hue), the suggestion in a quote, and ignore / edit / save.
    private func candidateCard(_ candidate: MemoryCandidate) -> some View {
        let group = MemoryInboxModel.group(for: candidate)
        // D-256: an episodic candidate's eyebrow is "Events & decisions" by layer, not by kind.
        let isEpisodic = candidate.proposedLayer == .episodic
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                MemoryGlyph(kind: isEpisodic ? .episodic : group.glyph, size: 14)
                    .foregroundStyle(isEpisodic ? OriveoTheme.Palette.memoryHue.episodic : group.hue)
                Text(isEpisodic ? L10n.tr("memory_group_episodic", table: .chat) : group.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\u{201C}")
                    .font(.custom("Georgia-Bold", size: 24))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .accessibilityHidden(true)
                Text(candidate.content)
                    .font(.system(size: 17, weight: .medium))
                    .tracking(-0.1)
                    .lineSpacing(4)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)

            HStack(spacing: 4) {
                Spacer(minLength: 0)

                Button(L10n.tr("memory_suggestion_ignore", table: .chat)) {
                    model.ignoreTask(candidate, appState: appState)
                }
                .buttonStyle(MemoryGhostButtonStyle())

                Button(L10n.tr("memory_suggestion_edit", table: .chat)) {
                    editTarget = model.edit(candidate)
                }
                .buttonStyle(MemoryGhostButtonStyle())

                Button(L10n.tr("memory_suggestion_save", table: .chat)) {
                    model.saveWithUndoToast(candidate, appState: appState)
                }
                .buttonStyle(MemoryPillButtonStyle(filled: true, height: 36, fontSize: 14.5))
                .padding(.leading, 4)
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { MemoryRowDivider(inset: 0) }
            .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCard(ring: true)
    }
}

/// Text-only capsule button (ignore / edit) on a suggestion card.
private struct MemoryGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.5, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
