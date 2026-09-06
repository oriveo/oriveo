import SwiftUI
import UIKit

nonisolated enum NoteDetailSourceActionKind: Equatable, Sendable {
    case backToConversation
    case crosscheck
}

nonisolated struct NoteDetailSourceAction: Equatable, Sendable {
    let kind: NoteDetailSourceActionKind
    let titleKey: String
    let systemImage: String
    let style: NoteDetailSourceActions.Style
    let isEnabled: Bool
}

nonisolated struct NoteDetailSourceActions: RandomAccessCollection, Equatable, Sendable {
    nonisolated enum Style: Equatable, Sendable { case primary, neutral }

    let primary: NoteDetailSourceAction?
    let secondary: [NoteDetailSourceAction]

    private var all: [NoteDetailSourceAction] {
        [primary].compactMap { $0 } + secondary
    }

    var startIndex: Int { all.startIndex }
    var endIndex: Int { all.endIndex }

    subscript(position: Int) -> NoteDetailSourceAction { all[position] }

    static func make(note: Note) -> Self {
        let primary: NoteDetailSourceAction? = note.sourceConversationId.map { _ in
            NoteDetailSourceAction(
                kind: .backToConversation,
                titleKey: "Back to conversation",
                systemImage: "arrow.uturn.left.circle",
                style: .primary,
                isEnabled: true
            )
        }
        let secondary = note.canCrosscheck ? [
            NoteDetailSourceAction(
                kind: .crosscheck,
                titleKey: "Cross-check",
                systemImage: "arrow.triangle.2.circlepath",
                style: .neutral,
                isEnabled: true
            )
        ] : []
        return Self(primary: primary, secondary: secondary)
    }

    static func shouldRenderSourceCard(note: Note) -> Bool {
        note.hasSource || note.sourceConversationId != nil
    }
}

enum NoteDetailTitleEditPolicy {
    static func shouldSave(
        draft: String,
        currentTitle: String,
        currentSource: NoteTitleSource
    ) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return currentSource == .manual }
        return trimmed != currentTitle
    }
}

struct NoteDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let noteID: UUID

    @State private var note: Note?
    @State private var reading = NoteReadingContent()
    @State private var hasLoadedOnce = false
    @State private var reloadToken = 0
    @State private var titleDraft = ""
    @State private var isEditingBody = false
    @State private var bodyDraft = ""
    @State private var newTag = ""
    @State private var showTagEditor = false
    @State private var contentPane = 0
    @State private var showDeleteConfirm = false
    @State private var showMoveSheet = false
    @State private var showCrosscheck = false
    @FocusState private var titleFocused: Bool

    // MARK: - Body

    var body: some View {
        Group {
            if let note {
                content(note)
            } else if hasLoadedOnce {
                notFound
            } else {
                Color.clear
            }
        }
        .background(NotesChrome.background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) { atmosphericGlow }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reload()
        }
        .onDisappear(perform: prepareToLeave)
        .onChange(of: appState.notesVersion) { _, _ in
            if !isEditingBody && !titleFocused { reload() }
        }
        .sheet(isPresented: $showMoveSheet) {
            if let note { MoveToNoteFolderSheet(noteID: note.id, current: note.noteFolderID) }
        }
        .fullScreenCover(isPresented: $showCrosscheck) {
            Group {
                if let note { CrosscheckSheet(origin: .note(note)) }
            }
            .interactiveDismissDisabled(true)
        }
    }

    @ViewBuilder
    private var atmosphericGlow: some View {
        if let note {
            ZStack {
                Circle()
                    .fill(heroBrand(note).opacity(note.showsBadge ? 0.13 : 0.055))
                    .frame(width: 260, height: 260)
                    .blur(radius: 88)
                    .offset(x: 44, y: -16)
                Circle()
                    .fill(OriveoTheme.Palette.primary.opacity(note.showsBadge ? 0.05 : 0.025))
                    .frame(width: 170, height: 170)
                    .blur(radius: 68)
                    .offset(x: -56, y: 90)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func detailHeader(_ note: Note) -> some View {
        HStack(spacing: 0) {
            Button { leaveDetail() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Back"))

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                Button { exportNote() } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("Share"))

                if !note.isTrashed {
                    Menu {
                        Button {
                            _ = appState.noteManager.setPinned(id: noteID, isPinned: !note.isPinned)
                            reload()
                        } label: {
                            Label(
                                note.isPinned ? L10n.tr("Unpin", table: .notes) : L10n.tr("Pin", table: .notes),
                                systemImage: note.isPinned ? "pin.slash" : "pin"
                            )
                        }
                        Button { showMoveSheet = true } label: {
                            Label(L10n.tr("Move to folder", table: .notes), systemImage: "folder")
                        }
                        Button(role: .destructive) { showDeleteConfirm = true } label: {
                            Label(L10n.tr("Delete this note", table: .notes), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("More", table: .chat))
                }
            }
        }
    }

    // MARK: - Single-scroll layout

    @ViewBuilder
    private func content(_ note: Note) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(note)

                if note.isTrashed {
                    trashBanner.padding(.top, 16)
                }

                hero(note).padding(.top, 16)

                tagsRow(note).padding(.top, 24)

                if NoteDetailSourceActions.shouldRenderSourceCard(note: note) {
                    sourceCard(note).padding(.top, 28)
                }

                Spacer().frame(height: 32)

                if hasSecondaryPane(note) {
                    contentPicker(note).padding(.bottom, 12)
                }

                contentCard(note)

                editControls(note).padding(.top, 12)

                if !note.isTrashed {
                    deleteZone.padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 36)
        }
    }

    // MARK: - Pane helpers

    private func hasSecondaryPane(_ note: Note) -> Bool {
        guard let snap = note.bodySnapshot, !snap.isEmpty, snap != note.body else { return false }
        return true
    }

    private func primaryPaneTitle(_ note: Note) -> String {
        reading.isCrosscheck ? L10n.tr("Cross-check", table: .notes) : L10n.tr("Body", table: .notes)
    }

    private func secondaryPaneTitle(_ note: Note) -> String {
        L10n.tr("Original snapshot", table: .notes)
    }

    private func heroBrand(_ note: Note) -> Color {
        note.showsBadge
            ? ProviderTints.tint(for: note.sourceProviderKind?.rawValue ?? "")
            : OriveoTheme.Palette.primary
    }

    // MARK: - Trash Banner

    @ViewBuilder
    private var trashBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
            Text(L10n.tr("This note is in Trash.", table: .notes))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            Spacer()
            Button(L10n.tr("Restore", table: .notes)) {
                appState.noteManager.restoreNote(id: noteID)
                reload()
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(OriveoTheme.Palette.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OriveoTheme.Palette.warningSoft)
        )
    }

    // MARK: - Hero

    @ViewBuilder
    private func hero(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                if note.showsBadge {
                    NoteSourceBadge(
                        providerKind: note.sourceProviderKind,
                        modelName: note.sourceModelName,
                        providerName: note.sourceProviderName,
                        size: 13
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(heroBrand(note).opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(heroBrand(note).opacity(0.11), lineWidth: 1)
                            )
                    )
                } else if let folderName = appState.noteManager.noteFolderName(for: note.noteFolderID) {
                    Label(folderName, systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                }

                Spacer(minLength: 8)

                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.onPrimary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(OriveoTheme.Palette.primaryPressed)
                                .shadow(color: OriveoTheme.Palette.primary.opacity(0.22), radius: 6, y: 2)
                        )
                        .accessibilityLabel(L10n.tr("Pinned", table: .notes))
                }

                Text(NoteText.mediumDate(note.createdAt))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(OriveoTheme.Palette.surfaceInset.opacity(0.72))
                    )
            }

            if titleFocused {
                TextField(L10n.tr("Untitled note", table: .notes), text: $titleDraft, axis: .vertical)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .focused($titleFocused)
                    .onChange(of: titleFocused) { _, focused in if !focused { saveTitleIfNeeded() } }
                    .submitLabel(.done)
            } else {
                Text(titleDraft.isEmpty ? L10n.tr("Untitled note", table: .notes) : titleDraft)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(titleDraft.isEmpty
                                     ? OriveoTheme.Palette.textTertiary
                                     : OriveoTheme.Palette.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { if !note.isTrashed { titleFocused = true } }
            }
        }
    }


    @ViewBuilder
    private func tagsRow(_ note: Note) -> some View {
        if !note.tags.isEmpty || !note.isTrashed {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(note.tags, id: \.self) { tag in
                            inlineTagChip(note, tag)
                        }
                        if !note.isTrashed && !showTagEditor {
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) { showTagEditor = true }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(L10n.tr("Add tag", table: .notes))
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                }
                                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.dynamic(light: 0xF0F1F4, dark: 0x2A2F3A))
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .strokeBorder(OriveoTheme.Palette.border, lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }

                if !note.isTrashed && showTagEditor {
                    tagInputRow(note)
                    let suggestions = tagSuggestions(for: note)
                    if !suggestions.isEmpty {
                        FlowLayout(spacing: 8) {
                            ForEach(suggestions, id: \.self) { tag in
                                tagSuggestionChip(note, tag)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func inlineTagChip(_ note: Note, _ tag: String) -> some View {
        NoteTagChip(
            tag: tag,
            brand: heroBrand(note),
            hasSource: note.showsBadge,
            onRemove: note.isTrashed ? nil : { removeTag(note, tag) }
        )
    }


    @ViewBuilder
    private func sourceCard(_ note: Note) -> some View {
        let brand = heroBrand(note)
        let hasBrand = note.showsBadge

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                Text(L10n.tr("Source", table: .notes).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }

            if let prompt = note.sourcePrompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.trailing, 46)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(brand.opacity(hasBrand ? 0.07 : 0.06))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "quote.opening")
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundStyle(brand.opacity(NoteCard.quoteWatermarkOpacity(isDark: colorScheme == .dark, hasSource: hasBrand, large: true)))
                                    .rotationEffect(.degrees(180))
                                    .offset(x: -10, y: 7)
                            }
                            .overlay(alignment: .leading) {
                                Capsule(style: .continuous)
                                    .fill(brand.opacity(hasBrand ? 0.5 : 0.42))
                                    .frame(width: 3)
                                    .padding(.vertical, 9)
                                    .padding(.leading, 6)
                            }
                    )
            }

            let actions = NoteDetailSourceActions.make(note: note)
            if actions.primary != nil || !actions.secondary.isEmpty {
                HStack(spacing: 10) {
                    if let _ = actions.primary {
                        Button { returnToConversation(note) } label: {
                            sourceActionBadge(
                                L10n.tr("Back to conversation", table: .notes),
                                systemImage: "arrow.uturn.left",
                                tint: hasBrand ? brand : OriveoTheme.Palette.primary
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if actions.secondary.contains(where: { $0.kind == .crosscheck }) {
                        Button { showCrosscheck = true } label: {
                            sourceActionBadge(
                                L10n.tr("Cross-check", table: .notes),
                                systemImage: "text.magnifyingglass",
                                tint: OriveoTheme.Palette.primary
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OriveoTheme.Palette.surface)
        )
        .shadow(color: OriveoTheme.Palette.shadow.opacity(0.06), radius: 8, y: 2)
        .shadow(color: brand.opacity(hasBrand ? 0.07 : 0.025), radius: 14, y: 6)
    }

    private func sourceActionBadge(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(tint)
                    .shadow(color: tint.opacity(0.28), radius: 3, y: 1)
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)

            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, 11)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.09))
        )
    }


    private func contentPicker(_ note: Note) -> some View {
        Picker("", selection: $contentPane) {
            Text(primaryPaneTitle(note)).tag(0)
            Text(secondaryPaneTitle(note)).tag(1)
        }
        .pickerStyle(.segmented)
        .disabled(isEditingBody)
    }


    private var brandCardBackground: some View {
        RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.dynamic(light: 0xFFFFFF, dark: 0x1E2230),
                        Color.dynamic(light: 0xF1EBFD, dark: 0x232845)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                RadialGradient(
                    colors: [OriveoTheme.Palette.primary.opacity(0.12), .clear],
                    center: .topTrailing, startRadius: 0, endRadius: 240
                )
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous)
                    .fill(OriveoTheme.Palette.cardHighlight.opacity(0.5))
                    .frame(height: 60)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom))
            }
            .overlay(
                RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous)
                    .strokeBorder(OriveoTheme.Palette.primary.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: OriveoTheme.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private func contentCard(_ note: Note) -> some View {
        if isEditingBody {
            Group {
                if NoteText.requiresBoundedLayout(bodyDraft) {
                    BoundedNoteTextView(text: $bodyDraft, isEditable: true)
                        .frame(height: UIScreen.main.bounds.height * 0.52)
                } else {
                    TextEditor(text: $bodyDraft)
                        .font(.system(size: 17))
                        .frame(minHeight: UIScreen.main.bounds.height * 0.42)
                        .scrollContentBackground(.hidden)
                }
            }
            .padding(18)
            .background(brandCardBackground)
            .shadow(color: OriveoTheme.Palette.shadow.opacity(0.5), radius: 16, y: 8)
            .shadow(color: OriveoTheme.Palette.primary.opacity(0.10), radius: 30, y: 14)
        } else {
            let text = contentPane == 0 ? reading.primary : reading.secondary
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyBodyPlaceholder
            } else {
                VStack(spacing: 30) {
                    if NoteText.requiresBoundedLayout(text) {
                        BoundedNoteTextView(text: .constant(text), isEditable: false)
                            .frame(height: UIScreen.main.bounds.height * 0.58)
                    } else {
                        MarkdownMessageView(
                            text: contentPane == 0 ? reading.primaryMarkdown : reading.secondaryMarkdown,
                            typography: .notes
                        )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    colophon(note)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(brandCardBackground)
                .shadow(color: OriveoTheme.Palette.shadow.opacity(0.5), radius: 16, y: 8)
                .shadow(color: OriveoTheme.Palette.primary.opacity(0.10), radius: 30, y: 14)
            }
        }
    }

    private func colophon(_ note: Note) -> some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(width: 28, height: 1)
            Image(systemName: "diamond.fill")
                .font(.system(size: 6, weight: .black))
                .foregroundStyle(heroBrand(note).opacity(0.55))
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(width: 28, height: 1)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyBodyPlaceholder: some View {
        Text(L10n.tr("Nothing written yet.", table: .notes))
            .font(.system(size: 14))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .padding(.top, 6)
    }


    @ViewBuilder
    private func editControls(_ note: Note) -> some View {
        if !note.isTrashed && contentPane == 0 {
            HStack(spacing: 8) {
                Spacer()
                if isEditingBody {
                    editActionPill(
                        title: L10n.tr("Cancel", table: .notes), icon: "xmark",
                        foreground: OriveoTheme.Palette.textTertiary,
                        background: OriveoTheme.Palette.surfaceInset.opacity(0.65)
                    ) { isEditingBody = false; bodyDraft = note.body }

                    editActionPill(
                        title: L10n.tr("Save", table: .notes), icon: "checkmark", isBold: true,
                        foreground: OriveoTheme.Palette.primary,
                        background: OriveoTheme.Palette.primary.opacity(0.10),
                        border: OriveoTheme.Palette.primary.opacity(0.22)
                    ) { saveBody() }
                } else {
                    editActionPill(
                        title: L10n.tr("Edit", table: .notes), icon: "square.and.pencil", isBold: true,
                        foreground: OriveoTheme.Palette.textSecondary,
                        background: OriveoTheme.Palette.surfaceInset.opacity(0.75),
                        border: OriveoTheme.Palette.hairline.opacity(0.42)
                    ) { bodyDraft = note.body; isEditingBody = true }
                }
            }
        }
    }

    private func editActionPill(
        title: String, icon: String, isBold: Bool = false,
        foreground: Color, background: Color, border: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: isBold ? .bold : .medium))
                Text(title)
                    .font(.system(size: 13, weight: isBold ? .semibold : .medium, design: .rounded))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(border ?? .clear, lineWidth: border != nil ? 1 : 0)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tag input & suggestions

    @ViewBuilder
    private func tagSuggestionChip(_ note: Note, _ tag: String) -> some View {
        NoteTagChip(
            tag: tag,
            brand: heroBrand(note),
            hasSource: note.showsBadge,
            role: .suggestion,
            onTap: { addExistingTag(note, tag) }
        )
        .accessibilityLabel("# \(tag)")
    }

    @ViewBuilder
    private func tagInputRow(_ note: Note) -> some View {
        HStack(spacing: 10) {
            TextField(L10n.tr("Add tag", table: .notes), text: $newTag)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onSubmit { addTag(note) }
            Button { addTag(note) } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canAddTag ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canAddTag)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OriveoTheme.Palette.surfaceInset.opacity(0.75))
        )
    }

    private func tagTextColor(for role: NoteTagChipVisualRole) -> Color {
        OriveoTheme.Palette.textSecondary
    }

    private var canAddTag: Bool {
        !newTag.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func tagSuggestions(for note: Note) -> [String] {
        let all = NoteListPresentation.tagSuggestions(in: appState.noteSummaries, excluding: note.tags, limit: 12)
        let needle = newTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(needle) }
    }


    @ViewBuilder
    private var deleteZone: some View {
        VStack(spacing: 0) {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .medium))
                    Text(L10n.tr("Delete this note", table: .notes))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                }
                .foregroundStyle(OriveoTheme.Palette.danger.opacity(0.78))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(OriveoTheme.Palette.dangerSoft)
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(L10n.tr("Delete note?", table: .notes),
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L10n.tr("Delete", table: .notes), role: .destructive) { confirmDelete() }
            Button(L10n.tr("Cancel", table: .notes), role: .cancel) {}
        } message: {
            Text(L10n.tr("The note moves to Trash and can be restored later.", table: .notes))
        }
    }

    // MARK: - Not Found

    @ViewBuilder
    private var notFound: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(OriveoTheme.Palette.primary.opacity(0.07))
                    .frame(width: 72, height: 72)
                    .blur(radius: 14)
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
            }
            Text(L10n.tr("Note not found", table: .notes))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Text(L10n.tr("It may have been deleted or not synced to this device yet.", table: .notes))
                .font(.system(size: 14))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(OriveoTheme.Spacing.xl)
    }

    // MARK: - Logic

    private func reload() {
        reloadToken &+= 1
        let token = reloadToken
        let id = noteID
        Task { @MainActor in
            let fetched = await appState.noteManager.noteDetail(id: id)
            guard token == reloadToken else { return }
            apply(fetched)
        }
    }

    private func apply(_ fetched: Note?) {
        note = fetched
        hasLoadedOnce = true
        reading = NoteReadingContent(note: fetched)
        titleDraft = fetched?.title ?? ""
        if !isEditingBody { bodyDraft = fetched?.body ?? "" }
        contentPane = 0
        showTagEditor = false
    }

    private func leaveDetail() {
        prepareToLeave()
        appState.navigation.pop()
    }

    private func prepareToLeave() {
        saveTitleIfNeeded()
        _ = appState.noteManager.discardEmptyBlankNoteIfNeeded(id: noteID)
    }

    private func saveTitleIfNeeded() {
        guard let note else { return }
        guard NoteDetailTitleEditPolicy.shouldSave(
            draft: titleDraft,
            currentTitle: note.title,
            currentSource: note.titleSource
        ) else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = appState.noteManager.updateTitle(id: noteID, title: trimmed)
        reload()
    }

    private func saveBody() {
        _ = appState.noteManager.updateBody(id: noteID, body: bodyDraft)
        isEditingBody = false
        reload()
        ToastManager.shared.show(L10n.tr("Saved", table: .notes), style: .success, duration: 2)
    }

    private func addTag(_ note: Note) {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty,
              !note.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
        else { newTag = ""; return }
        _ = appState.noteManager.updateTags(id: noteID, tags: note.tags + [tag])
        newTag = ""
        showTagEditor = false
        reload()
    }

    private func addExistingTag(_ note: Note, _ tag: String) {
        guard !note.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        _ = appState.noteManager.updateTags(id: noteID, tags: note.tags + [tag])
        newTag = ""
        showTagEditor = false
        reload()
    }

    private func removeTag(_ note: Note, _ tag: String) {
        _ = appState.noteManager.updateTags(id: noteID, tags: note.tags.filter { $0 != tag })
        reload()
    }

    private func confirmDelete() {
        appState.noteManager.deleteNote(id: noteID)
        appState.navigation.pop()
        ToastManager.shared.show(L10n.tr("Note deleted", table: .notes), duration: 5,
                                 actionTitle: L10n.tr("Undo", table: .notes)) {
            appState.noteManager.restoreNote(id: noteID)
        }
    }

    private func exportNote() {
        guard let note else { return }
        NoteExporter.share(note: note, from: appState)
    }

    private func returnToConversation(_ note: Note) {
        guard let convID = note.sourceConversationId else { return }
        appState.prepareReturnToConversation(
            noteID: note.id,
            conversationID: convID,
            messageID: note.sourceMessageId
        )
    }
}

private struct NoteReadingContent: Equatable {
    var isCrosscheck = false
    var primary = ""
    var secondary = ""
    var primaryMarkdown = ""
    var secondaryMarkdown = ""

    init() {}

    init(note: Note?) {
        guard let note else { return }
        isCrosscheck = Self.isCrosscheck(note)
        primary = isCrosscheck ? Self.crosscheckContent(note.body) : note.body
        secondary = note.bodySnapshot ?? note.body
        primaryMarkdown = NoteText.readingMarkdown(primary)
        secondaryMarkdown = NoteText.readingMarkdown(secondary)
    }

    static func isCrosscheck(_ note: Note) -> Bool {
        note.bodySnapshot != nil && note.body.contains("\n## Cross-check")
    }

    private static func crosscheckContent(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { $0.hasPrefix("## Cross-check") }) else { return body }
        return lines.dropFirst(idx + 1).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct BoundedNoteTextView: UIViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 17)
        textView.textColor = .label
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.layoutManager.allowsNonContiguousLayout = true
        textView.typingAttributes = Self.textAttributes
        textView.attributedText = Self.attributed(text)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.isEditable = isEditable
        if textView.text != text {
            let selection = textView.selectedRange
            textView.attributedText = Self.attributed(text)
            textView.selectedRange = NSRange(
                location: min(selection.location, textView.text.utf16.count),
                length: 0
            )
        }
    }

    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 17),
        .foregroundColor: UIColor.label,
    ]

    private static func attributed(_ text: String) -> NSAttributedString {
        let string = NSMutableAttributedString(
            string: text,
            attributes: textAttributes
        )
        ParagraphWritingDirection.applyParagraphDirections(to: string)
        return string
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
