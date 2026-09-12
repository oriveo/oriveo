import SwiftUI


struct NativeTextLabel: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 16
    var fontWeight: UIFont.Weight = .regular
    var usesMonospacedFont: Bool = false
    let textColor: Color
    var numberOfLines: Int = 0
    /// Single-line truncation needs `.byTruncatingTail`: with the default word wrapping the overflowing last
    /// line is simply cut off, without an ellipsis.
    var lineBreakMode: NSLineBreakMode = .byWordWrapping

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.lineBreakMode = lineBreakMode
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let resolvedFont = resolvedUIFont()
        let resolvedTextColor = UIColor(textColor)
        var changed = false
        if label.text != text { label.text = text; changed = true }
        if label.font != resolvedFont { label.font = resolvedFont; changed = true }
        if label.textColor != resolvedTextColor { label.textColor = resolvedTextColor; changed = true }
        if label.numberOfLines != numberOfLines { label.numberOfLines = numberOfLines; changed = true }
        if label.lineBreakMode != lineBreakMode { label.lineBreakMode = lineBreakMode; changed = true }
        if changed { label.invalidateIntrinsicContentSize() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // A single-line UILabel's sizeThatFits reports the full natural width and ignores the width constraint.
        // Without clamping to the proposal, SwiftUI lays the label out at that oversized width and pushes the
        // line out of the card instead of truncating within the proposed width.
        guard let proposedWidth = proposal.width else { return size }
        return CGSize(width: min(size.width, proposedWidth), height: size.height)
    }

    private func resolvedUIFont() -> UIFont {
        if usesMonospacedFont {
            return .monospacedSystemFont(ofSize: fontSize, weight: fontWeight)
        }
        return .systemFont(ofSize: fontSize, weight: fontWeight)
    }
}
