import OriveoProviderKit
import SwiftUI

/// The items to organize; used by sheet(item:).
struct MemoryOrganizeTarget: Identifiable, Equatable {
    let item: MemoryItem

    var id: String { item.id }
}

/// Organize into items: while the request runs it shows "Organizing..."; failure / empty parse / no model each show one line of notice with only Cancel left;
/// with a result it shows a checklist (all selected by default) + a "Keep original items" switch (off by default) + [Save selected].
struct MemoryOrganizeSheet: View {
    private enum Phase: Equatable {
        case loading
        case message(String)
        case ready
    }

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var selection: MemoryOrganizeSelection?

    let target: MemoryOrganizeTarget
    let organizer: MemoryOrganizer
    let onSave: (MemoryOrganizeSelection) -> Void

    var body: some View {
        NavigationStack {
            content
                .background(OriveoScreenBackground())
                .navigationTitle(L10n.tr("memory_action_organize", table: .chat))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("Cancel")) {
                            dismiss()
                        }
                    }
                    if phase == .ready, let selection {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.tr("memory_organize_save", table: .chat)) {
                                onSave(selection)
                                dismiss()
                            }
                            .disabled(!selection.canSave)
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // The task is cancelled when the sheet closes
        .task { await run() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.tr("memory_organize_loading", table: .chat))
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .message(let text):
            Text(text)
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if let selection {
                resultList(selection)
            }
        }
    }

    private func resultList(_ selection: MemoryOrganizeSelection) -> some View {
        List {
            Section {
                ForEach(Array(selection.entries.enumerated()), id: \.offset) { index, entry in
                    Toggle(isOn: selectedBinding(index)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text((MemoryItemGroup(kind: entry.kind) ?? .about).title)
                                .font(OriveoTheme.Typography.footnote.weight(.semibold))
                                .foregroundStyle(OriveoTheme.Palette.primary)
                            Text(entry.content)
                                .font(OriveoTheme.Typography.body)
                                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        }
                    }
                    .toggleStyle(OrganizeCheckboxToggleStyle())
                }
            }
            Section {
                Toggle(
                    L10n.tr("memory_organize_keep_original", table: .chat),
                    isOn: keepOriginalBinding
                )
                .tint(OriveoTheme.Palette.primary)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func selectedBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { selection?.selected[index] ?? false },
            set: { selection?.selected[index] = $0 }
        )
    }

    private var keepOriginalBinding: Binding<Bool> {
        Binding(
            get: { selection?.keepOriginal ?? false },
            set: { selection?.keepOriginal = $0 }
        )
    }

    private func run() async {
        guard phase == .loading else { return }
        let outcome = await organizer.organize(content: target.item.content)
        guard !Task.isCancelled else { return }
        switch outcome {
        case .noModel:
            phase = .message(L10n.tr("memory_organize_no_model", table: .chat))
        case .failed:
            phase = .message(L10n.tr("memory_organize_failed", table: .chat))
        case .empty:
            phase = .message(L10n.tr("memory_organize_empty", table: .chat))
        case .entries(let entries):
            selection = MemoryOrganizeSelection(sourceId: target.item.id, entries: entries)
            phase = .ready
        }
    }
}

/// Check circle at the row start; the whole row is tappable.
private struct OrganizeCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(configuration.isOn ? OriveoTheme.Palette.primary : OriveoTheme.Palette.textTertiary)
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
