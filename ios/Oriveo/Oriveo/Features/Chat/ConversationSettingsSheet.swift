import SwiftUI
import OriveoProviderKit

/// Pure logic behind the chat settings sheet, kept view-free for tests.
enum ConversationSettingsLogic {
    /// Saves the editor text on close. `original` is the value snapshotted when the sheet opened:
    /// if the normalized text equals it the user made no edit, so nothing is written (a remote change
    /// synced in while the sheet was open is kept). Otherwise a conversation goes through
    /// `setInstructions`; a draft (no id) writes the in-memory pending value. Returns false when nothing was written.
    @MainActor
    @discardableResult
    static func save(_ text: String, original: String, conversationID: UUID?, appState: AppState) -> Bool {
        guard ConversationInstructions.normalize(text) != ConversationInstructions.normalize(original) else { return false }
        if let conversationID {
            return appState.conversationManager.setInstructions(id: conversationID, text: text)
        }
        let normalized = ConversationInstructions.normalize(text)
        guard appState.pendingDraftInstructions != normalized else { return false }
        appState.pendingDraftInstructions = normalized
        return true
    }

    /// Instructions offered by the carry-over item: the latest (by `updatedAt`) non-deleted conversation
    /// other than the current one. Nil when the current text is non-empty or that conversation has none.
    static func carryOverInstructions(in conversations: [Conversation], currentID: UUID?, currentText: String) -> String? {
        guard ConversationInstructions.normalize(currentText).isEmpty else { return nil }
        let source = conversations
            .filter { $0.id != currentID && $0.deletedAt == nil }
            .max { $0.updatedAt < $1.updatedAt }
        guard let instructions = source?.instructions, !instructions.isEmpty else { return nil }
        return instructions
    }

    /// Current instructions for the toolbar badge: the conversation's value, or the pending draft value.
    @MainActor
    static func currentInstructions(conversationID: UUID?, appState: AppState) -> String {
        guard let conversationID else { return appState.pendingDraftInstructions }
        return appState.conversation(for: conversationID)?.instructions ?? ""
    }
}

/// Sheet item for the chat settings sheet.
struct ConversationSettingsPresentation: Identifiable {
    let id = UUID()
    let conversationID: UUID?
    let useMemory: Bool
    /// Opened from the instructions badge: focus the editor right away.
    let focusEditor: Bool
}

/// Chat settings: per-chat instructions, carry-over, memory toggle and an optional usage row.
/// Saves on close (Done or swipe down).
struct ConversationSettingsSheet: View {
    let presentation: ConversationSettingsPresentation
    /// Usage row value: "N%", about N%, or unavailable.
    var usageValue: String?
    /// Usage row action; nil hides the row.
    var onOpenUsage: (() -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var useMemory: Bool
    @State private var loaded = false
    /// Value at open time; closing without an edit writes nothing.
    @State private var original = ""
    @FocusState private var editorFocused: Bool

    init(presentation: ConversationSettingsPresentation, usageValue: String? = nil, onOpenUsage: (() -> Void)? = nil) {
        self.presentation = presentation
        self.usageValue = usageValue
        self.onOpenUsage = onOpenUsage
        _text = State(initialValue: "")
        _useMemory = State(initialValue: presentation.useMemory)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(L10n.tr("conversation_settings_instructions_placeholder", table: .chat))
                                .font(OriveoTheme.Typography.body)
                                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text)
                            .font(OriveoTheme.Typography.body)
                            .frame(minHeight: 140)
                            .focused($editorFocused)
                            .scrollContentBackground(.hidden)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editorFocused = true
                    }

                    if let carryOver {
                        Button {
                            text = carryOver
                        } label: {
                            Label(L10n.tr("conversation_settings_carry_over", table: .chat),
                                  systemImage: "arrow.uturn.down")
                        }
                    }
                } header: {
                    Text(L10n.tr("conversation_settings_instructions_header", table: .chat))
                } footer: {
                    Text(L10n.tr("conversation_settings_instructions_footer", table: .chat))
                }

                // Draft (no conversation id yet): no memory toggle, it could not be written anywhere.
                if hasMemoryText, presentation.conversationID != nil {
                    Section {
                        Toggle(isOn: Binding(
                            get: { useMemory },
                            set: { newValue in
                                useMemory = newValue
                                if let conversationID = presentation.conversationID {
                                    appState.setConversationUseMemory(conversationID, useMemory: newValue)
                                }
                            }
                        )) {
                            Label(L10n.tr("Use Memory", table: .chat), systemImage: "brain")
                        }
                    }
                }

                if let onOpenUsage {
                    Section {
                        Button {
                            onOpenUsage()
                        } label: {
                            HStack {
                                Label(L10n.tr("conversation_settings_usage", table: .chat), systemImage: "gauge.medium")
                                Spacer(minLength: OriveoTheme.Spacing.sm)
                                if let usageValue {
                                    Text(usageValue)
                                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("conversation_settings_title", table: .chat))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(L10n.tr("Done"))
                    }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            original = ConversationSettingsLogic.currentInstructions(
                conversationID: presentation.conversationID, appState: appState)
            text = original
            if presentation.focusEditor { editorFocused = true }
        }
        // Done and swipe-down both end here: save once, normalized, unchanged = no write.
        .onDisappear {
            ConversationSettingsLogic.save(text, original: original, conversationID: presentation.conversationID, appState: appState)
        }
    }

    private var carryOver: String? {
        ConversationSettingsLogic.carryOverInstructions(
            in: appState.conversations, currentID: presentation.conversationID, currentText: text)
    }

    /// Same criterion as the toolbar memory indicator: there are active semantic items.
    private var hasMemoryText: Bool {
        MemoryUsedPresentation.hasActiveSemanticItems(appState.memoryItemsCache.items)
    }
}
