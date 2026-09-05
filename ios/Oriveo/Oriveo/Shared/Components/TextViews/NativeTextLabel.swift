import SwiftUI


struct NativeTextLabel: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 16
    var fontWeight: UIFont.Weight = .regular
    var usesMonospacedFont: Bool = false
    let textColor: Color
    var numberOfLines: Int = 0

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.lineBreakMode = .byWordWrapping
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
        if changed { label.invalidateIntrinsicContentSize() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return size
    }

    private func resolvedUIFont() -> UIFont {
        if usesMonospacedFont {
            return .monospacedSystemFont(ofSize: fontSize, weight: fontWeight)
        }
        return .systemFont(ofSize: fontSize, weight: fontWeight)
    }
}
