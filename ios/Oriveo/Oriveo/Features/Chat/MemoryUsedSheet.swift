import OriveoProviderKit
import SwiftUI

/// Pure presentation rules for the "Memory used" marker, its sheet and the toolbar memory indicator.
enum MemoryUsedPresentation {
    /// Headline limit (in graphemes); longer text gets an ellipsis.
    static let headlineMaxGraphemes = 60

    /// One sheet row: a live item shows its headline and can be tapped with "This is wrong"; a tombstoned or locally missing one shows "Deleted memory".
    struct Row: Equatable, Identifiable {
        let id: String
        /// Item headline; nil when deleted or missing locally.
        let headline: String?

        var isDeleted: Bool { headline == nil }
    }

    /// Shown only on assistant replies that recorded item ids and are not streaming.
    static func showsChip(for message: ChatMessage, isStreaming: Bool) -> Bool {
        message.role == .assistant
            && !message.memoryItemIds.isEmpty
            && !isStreaming
            && message.state != .generating
    }

    /// Rows follow the order recorded with the reply.
    static func rows(ids: [String], items: [MemoryItem]) -> [Row] {
        let live = Dictionary(
            items.filter { $0.status != .deleted }.map { ($0.id.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.map { id in
            let key = id.lowercased()
            return Row(id: key, headline: live[key].map { headline(for: $0.content) })
        }
    }

    /// The first non-empty line (trimmed); beyond `headlineMaxGraphemes` it is truncated with an ellipsis.
    static func headline(for content: String) -> String {
        let line = content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard line.count > headlineMaxGraphemes else { return line }
        return String(line.prefix(headlineMaxGraphemes)) + "…"
    }

    /// The items recognized by the toolbar memory indicator and the conversation settings memory switch.
    static func activeSemanticItems(_ items: [MemoryItem]) -> [MemoryItem] {
        items.filter { $0.status == .active && $0.layer == .semantic }
    }

    static func hasActiveSemanticItems(_ items: [MemoryItem]) -> Bool {
        items.contains { $0.status == .active && $0.layer == .semantic }
    }

    /// Toolbar memory indicator: the conversation switch is on and there are active semantic items.
    static func showsToolbarIndicator(useMemory: Bool, items: [MemoryItem]) -> Bool {
        useMemory && hasActiveSemanticItems(items)
    }

    /// Toolbar popover preview: one headline row per active semantic item.
    static func toolbarPreview(items: [MemoryItem]) -> String {
        activeSemanticItems(items).map { headline(for: $0.content) }.joined(separator: "\n")
    }
}

/// Presented by tapping the "Memory" marker: the items this reply used, each with "This is wrong".
struct MemoryUsedSheet: View {
    let rows: [MemoryUsedPresentation.Row]
    let onFix: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.lg) {
                header
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            Divider().overlay(OriveoTheme.Palette.hairline)
                        }
                        rowView(row)
                    }
                }
                .padding(.horizontal, OriveoTheme.Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                        .fill(OriveoTheme.Palette.surfaceInset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OriveoTheme.Radius.lg, style: .continuous)
                        .stroke(OriveoTheme.Palette.border, lineWidth: 1)
                )
            }
            .padding(OriveoTheme.Spacing.lg)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(OriveoTheme.Palette.primaryGradient)
                    .frame(width: 40, height: 40)
                Image(systemName: "brain")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            Text(L10n.tr("memory_used_title", table: .chat))
                .font(OriveoTheme.Typography.title2)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            OriveoCloseButton(accessibilityLabel: L10n.tr("Dismiss")) {
                onDismiss()
            }
            .padding(.trailing, -OriveoBackButton.edgeInset)
        }
    }

    @ViewBuilder
    private func rowView(_ row: MemoryUsedPresentation.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OriveoTheme.Spacing.md) {
            if let headline = row.headline {
                Text(headline)
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    onFix(row.id)
                } label: {
                    Text(L10n.tr("memory_used_wrong", table: .chat))
                        .font(OriveoTheme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(OriveoTheme.Palette.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(OriveoTheme.Palette.primarySoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
            } else {
                Text(L10n.tr("memory_used_deleted", table: .chat))
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, OriveoTheme.Spacing.md)
    }
}
