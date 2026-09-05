import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    private struct Row {
        var items: [LayoutSubviews.Element] = []
        var height: CGFloat = 0
    }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        var x: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
                x = 0
            }
            rows[rows.count - 1].items.append(sub)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let laidOut = rows(maxWidth: maxWidth, subviews: subviews)
        let totalHeight = laidOut.map(\.height).reduce(0, +)
            + spacing * CGFloat(max(0, laidOut.count - 1))
        let width: CGFloat
        if maxWidth == .infinity {
            width = laidOut.map { row in
                row.items.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
            }.max() ?? 0
        } else {
            width = maxWidth
        }
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laidOut = rows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in laidOut {
            var x = bounds.minX
            for sub in row.items {
                let size = sub.sizeThatFits(.unspecified)
                let yOffset = (row.height - size.height) / 2
                sub.place(at: CGPoint(x: x, y: y + yOffset), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
}
