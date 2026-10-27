import SwiftUI


struct SelectableTextLabel: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 16
    var fontWeight: UIFont.Weight = .regular
    var usesMonospacedFont: Bool = false
    /// Takes a UIColor directly: a dynamic color (including the dark palette trait) is handed to the UITextView as is and resolved by its own trait,
    /// without a `UIColor(Color)` round trip (the round trip loses dynamic resolution on some systems).
    let textColor: UIColor
    var tintColor: UIColor?

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
        var changed = false
        if tv.text != text { tv.text = text; changed = true }
        if tv.font != resolvedFont { tv.font = resolvedFont; changed = true }
        if tv.textColor != textColor { tv.textColor = textColor; changed = true }
        if let tintColor, tv.tintColor != tintColor { tv.tintColor = tintColor }
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
