import SwiftUI


struct SelectableTextLabel: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 16
    var fontWeight: UIFont.Weight = .regular
    var usesMonospacedFont: Bool = false
    let textColor: Color
    var tintColor: Color?

    func makeUIView(context: Context) -> UITextView {
        let tv = ChatPassiveTextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let resolvedFont = resolvedUIFont()
        let resolvedTextColor = UIColor(textColor)
        let resolvedTintColor = tintColor.map(UIColor.init)
        var changed = false
        if tv.text != text { tv.text = text; changed = true }
        if tv.font != resolvedFont { tv.font = resolvedFont; changed = true }
        if tv.textColor != resolvedTextColor { tv.textColor = resolvedTextColor; changed = true }
        if let resolvedTintColor, tv.tintColor != resolvedTintColor { tv.tintColor = resolvedTintColor }
        if changed { tv.invalidateIntrinsicContentSize() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingCompressedSize.width
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func resolvedUIFont() -> UIFont {
        if usesMonospacedFont {
            return .monospacedSystemFont(ofSize: fontSize, weight: fontWeight)
        }
        return .systemFont(ofSize: fontSize, weight: fontWeight)
    }
}
