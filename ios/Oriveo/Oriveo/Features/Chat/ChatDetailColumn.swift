import SwiftUI

/// The detail (right) column of the wide-screen two-column layout: it branches on
/// `ChatDetailState` between the empty state and a conversation.
///
/// It only appears at regular width. At compact width the conversation still goes through the
/// outer `NavigationStack` (covering the screen including the tab bar, with an edge swipe
/// popping back) — see the carrier invariant on `NavigationManager.chatDetail`.
struct ChatDetailColumn: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                // On iPadOS the system tab bar is a floating capsule centred at the top, and it
                // does **not** make room for content. In the single-column era the conversation
                // covered the whole screen and never met it; now that it lives inside the Home
                // tab, the conversation's own toolbar lands right underneath the capsule (on an
                // iPad in portrait the capsule occupies 38–70pt while the toolbar starts at 40).
                // The sidebar is unaffected: everything in its top bar sits left of the capsule.
                //
                // The test is *where the tab bar is*, not *which platform this is*: on an
                // unfolded Duo the tab bar is a vertical strip on the trailing edge and the
                // detail column already sits clear of it. That placement is the system's choice
                // and no public API reports it, so the idiom is the only signal available.
                // The real fix is to settle on one tab bar shape (`.tabViewStyle(.sidebarAdaptable)`),
                // which is a separate decision.
                Color.clear.frame(height: needsTopTabBarClearance ? 32 : 0)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.navigation.chatDetail {
        case .empty:
            ChatDetailEmptyStateView()
        case .draft:
            ChatView(conversationID: nil)
        case let .conversation(conversationID):
            ChatView(conversationID: conversationID)
        }
    }

    private var needsTopTabBarClearance: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
}

/// Where the detail column lands when no conversation is selected.
///
/// Not a blank panel: a brand mark, one line of guidance and three starter chips. Tapping a chip
/// opens a new conversation with that text already in the composer — sending it is still the
/// user's call, so the checks that run before a first message all still apply.
struct ChatDetailEmptyStateView: View {
    @Environment(AppState.self) private var appState

    /// Starter chips. All three are general openings that fit in one line and that a model can
    /// answer directly; nothing is personalised. The job of an empty state is to offer a next
    /// step, not to guess what the user came for.
    private static let starters: [String] = [
        "Draft an email for me",
        "Explain this code",
        "Summarize into key points",
    ]

    var body: some View {
        VStack(spacing: 15) {
            Image("OriveoLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 60, height: 60)
                .accessibilityHidden(true)

            Text(L10n.tr("Pick a conversation", table: .chat))
                .font(.system(size: 18.5, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            Text(L10n.tr("Or just ask something in the box on the left — the new conversation opens right here.", table: .chat))
                .font(.system(size: 13.5))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)

            // The detail column of an unfolded Duo is only 467pt wide, and three chips on one
            // row are each truncated there. This layout keeps them on one row when they fit and
            // wraps when they do not, rather than cutting the text.
            StarterChipLayout(spacing: OriveoTheme.Spacing.sm) {
                ForEach(Self.starters, id: \.self) { starter in
                    starterChip(starter)
                }
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        // The detail column is the workbench: the clean `backgroundBase` divides it from the
        // aurora gradient of the sidebar, and the seam is a single inset border rather than a
        // hard rule.
        .background(OriveoTheme.Palette.backgroundBase)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(OriveoTheme.Palette.border)
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private func starterChip(_ starter: String) -> some View {
        Button {
            appState.startNewChat(withPrefilledText: L10n.tr(starter, table: .chat))
        } label: {
            Text(L10n.tr(starter, table: .chat))
                .font(.system(size: 12.5))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .background(
                    Capsule().fill(OriveoTheme.Palette.surface)
                )
                .overlay(
                    Capsule().strokeBorder(OriveoTheme.Palette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Wrapping layout for the starter chips: one row when they fit, wrapping when they do not, and
/// each row centred.
///
/// Not an `HStack` (it squeezes every chip until the text truncates in a narrow column) and not
/// a `LazyVGrid` (equal-width cells leave chips of different lengths ragged, and a lazy
/// container cannot report a usable height).
private struct StarterChipLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width available: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, projected > available {
                rows.append(row)
                row = Row()
                row.indices = [index]
                row.width = size.width
                row.height = size.height
            } else {
                row.indices.append(index)
                row.width = projected
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
