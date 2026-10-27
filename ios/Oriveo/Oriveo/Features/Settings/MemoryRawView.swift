import OriveoProviderKit
import SwiftUI

/// State of the raw text view: only active items, separated by `---` lines; saving goes through `MemoryItems.rawApply`.
struct MemoryRawEditorState: Equatable, Identifiable, Sendable {
    /// Snapshot of the items at open time, used to fold changes back on save.
    let items: [MemoryItem]
    var text: String
    /// The over-long section hit by the last save (rawApply index, 0-based); no notice when nil.
    private(set) var tooLongIndex: Int?

    var id: String { "raw" }

    init(items: [MemoryItem]) {
        self.items = items
        self.text = MemoryItems.rawRender(items)
    }

    /// Compute the changes to write; when a section is too long, record its index and return nil without writing any item.
    mutating func prepareSave() -> [MemoryRawOp]? {
        switch MemoryItems.rawApply(items, text: text, newId: MemoryItemRepository.newId) {
        case .ops(let ops):
            tooLongIndex = nil
            return ops
        case .tooLong(let index):
            tooLongIndex = index
            return nil
        }
    }

    /// "Item n...": n is shown to the user starting from 1.
    var tooLongMessage: String? {
        tooLongIndex.map {
            L10n.tr("memory_raw_view_too_long", table: .chat)
                .replacingOccurrences(of: "{index}", with: "\($0 + 1)")
        }
    }

    /// Apply to the store in order: update changes only the content, create adds a new item (kind comes from rawApply), delete writes a tombstone.
    nonisolated static func apply(_ ops: [MemoryRawOp], writer: MemoryItemWriter) throws {
        for op in ops {
            switch op {
            case .update(let id, let content):
                _ = try writer.update(id: id, content: content)
            case .create(_, let kind, let content):
                _ = try writer.create(kind: kind, content: content)
            case .delete(let id):
                _ = try writer.remove(id: id)
            }
        }
    }
}

/// Raw text editing (full-screen sheet): top bar Cancel / Raw / Save, one line of explanation, and a text box with a line-number gutter;
/// the over-long section gets a red background plus a 3pt red bar. Cancel discards directly; saving returns to the list.
struct MemoryRawView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state: MemoryRawEditorState
    let onSave: ([MemoryRawOp]) -> Void

    init(state: MemoryRawEditorState, onSave: @escaping ([MemoryRawOp]) -> Void) {
        _state = State(initialValue: state)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            HStack(spacing: 8) {
                Text(verbatim: MemoryItems.rawViewSeparator)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(OriveoTheme.Palette.surface))
                    .accessibilityHidden(true)
                Text(L10n.tr("memory_raw_view_hint", table: .chat))
                    .font(.system(size: 13))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MemoryTag.fill))
            .padding(.horizontal, 20)
            .padding(.top, 8)

            MemoryRawTextView(text: $state.text, errorSegment: state.tooLongIndex)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(OriveoTheme.Palette.surfaceInset)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(OriveoTheme.Palette.border, lineWidth: 0.5)
                )
                .padding(.horizontal, 16)
                .padding(.top, 14)

            if let message = state.tooLongMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 15, weight: .medium))
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.system(size: 13.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(OriveoTheme.Palette.danger)
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(OriveoTheme.Palette.surface)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(OriveoTheme.Palette.surface)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Text(L10n.tr("Cancel"))
                    .font(.system(size: 17))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                guard let ops = state.prepareSave() else { return }
                if !ops.isEmpty { onSave(ops) }
                dismiss()
            } label: {
                Text(L10n.tr("memory_raw_view_save", table: .chat))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay {
            Text(L10n.tr("memory_raw_view", table: .chat))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 96)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(height: 52)
        .padding(.horizontal, 8)
        .padding(.top, 14)
    }
}

/// Raw text box with a line-number gutter (TextKit 1): line numbers, the monospaced style and dashed rule of `---` separator lines, and the red background of the over-long section are all drawn on a decoration layer behind the text.
private struct MemoryRawTextView: UIViewRepresentable {
    @Binding var text: String
    let errorSegment: Int?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> MemoryRawGutterTextView {
        let view = MemoryRawGutterTextView.make()
        view.delegate = context.coordinator
        view.text = text
        view.errorSegment = errorSegment
        view.restyle()
        DispatchQueue.main.async {
            view.becomeFirstResponder()
            view.revealStart()
        }
        return view
    }

    func updateUIView(_ view: MemoryRawGutterTextView, context: Context) {
        if view.text != text {
            view.text = text
            view.restyle()
        }
        if view.errorSegment != errorSegment {
            view.errorSegment = errorSegment
            view.redrawDecorations()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            (textView as? MemoryRawGutterTextView)?.restyle()
        }
    }
}

final class MemoryRawGutterTextView: UITextView {
    static let gutterWidth: CGFloat = 38
    static let lineHeight: CGFloat = 28

    /// The over-long section index reported by rawApply (split by `---` and skipping empty sections, the same way it counts).
    var errorSegment: Int?

    private let bodyFont = UIFont.systemFont(ofSize: 16)
    private let separatorFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let decorations = DecorationView()
    /// Text storage of the TextKit 1 stack: UITextView does not strongly hold a self-built storage, so keep a reference here.
    private var ownedStorage: NSTextStorage?

    /// Build the TextKit 1 stack explicitly through this class's designated initializer (`init(usingTextLayoutManager:)` does not go through it, so the stored properties would be empty).
    static func make() -> MemoryRawGutterTextView {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        let view = MemoryRawGutterTextView(frame: .zero, textContainer: container)
        view.ownedStorage = storage
        return view
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 0, left: Self.gutterWidth, bottom: 0, right: 14)
        self.textContainer.lineFragmentPadding = 0
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        tintColor = UIColor(OriveoTheme.Palette.primary)
        decorations.owner = self
        decorations.isUserInteractionEnabled = false
        decorations.backgroundColor = .clear
        decorations.contentMode = .redraw
        insertSubview(decorations, at: 0)
        registerForTraitChanges(OriveoDarkPaletteTrait.colorAppearanceTraits) { (view: MemoryRawGutterTextView, _) in
            view.restyle()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: bounds.width, height: max(contentSize.height, bounds.height))
        if decorations.frame.size != size {
            decorations.frame = CGRect(origin: .zero, size: size)
            decorations.setNeedsDisplay()
        }
    }

    /// Body 16pt with 28pt line height; `---` lines switch to monospaced tertiary color. Only attributes change, never characters; skipped while an input method is composing.
    func restyle() {
        guard markedTextRange == nil else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.lineHeight
        paragraph.maximumLineHeight = Self.lineHeight
        let body: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: UIColor(OriveoTheme.Palette.textPrimary),
            .paragraphStyle: paragraph,
            .baselineOffset: (Self.lineHeight - bodyFont.lineHeight) / 4
        ]
        // Split lines first: the text storage is locked during beginEditing, and reading `text` would throw
        let separators = lines().filter(\.isSeparator)
        let storage = textStorage
        storage.beginEditing()
        storage.setAttributes(body, range: NSRange(location: 0, length: storage.length))
        for line in separators {
            storage.addAttributes([
                .font: separatorFont,
                .foregroundColor: UIColor(OriveoTheme.Palette.textTertiary),
                .baselineOffset: (Self.lineHeight - separatorFont.lineHeight) / 4
            ], range: line.range)
        }
        storage.endEditing()
        typingAttributes = body
        redrawDecorations()
    }

    /// Put the caret at the start of the over-long section (or the text start when there is none) and scroll to it, so the failing section is the first thing seen on entering.
    func revealStart() {
        let all = lines()
        let location = errorLines(all).map { all[$0.lowerBound].range.location } ?? 0
        selectedRange = NSRange(location: location, length: 0)
        scrollRangeToVisible(selectedRange)
    }

    func redrawDecorations() {
        decorations.setNeedsDisplay()
    }

    fileprivate struct Line {
        let range: NSRange
        let isSeparator: Bool
        let isBlank: Bool
    }

    /// Split lines by `\n` (keeping the trailing empty line, since line numbers must count it).
    fileprivate func lines() -> [Line] {
        let ns = (text ?? "") as NSString
        var result: [Line] = []
        var start = 0
        while true {
            let search = NSRange(location: start, length: ns.length - start)
            let newline = ns.range(of: "\n", options: [], range: search)
            let end = newline.location == NSNotFound ? ns.length : newline.location
            let range = NSRange(location: start, length: end - start)
            let raw = ns.substring(with: range)
            let bare = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            result.append(Line(
                range: range,
                isSeparator: bare == MemoryItems.rawViewSeparator,
                isBlank: bare.trimmingCharacters(in: .whitespaces).isEmpty
            ))
            if newline.location == NSNotFound { break }
            start = newline.location + newline.length
        }
        return result
    }

    /// The line-number range of the over-long section (first non-empty line to last non-empty line).
    fileprivate func errorLines(_ lines: [Line]) -> ClosedRange<Int>? {
        guard let errorSegment else { return nil }
        var segment = 0
        var first: Int?
        var last: Int?
        func close() -> ClosedRange<Int>? {
            defer { first = nil; last = nil }
            guard let first, let last else { return nil }
            if segment == errorSegment { return first...last }
            segment += 1
            return nil
        }
        for (index, line) in lines.enumerated() {
            if line.isSeparator {
                if let found = close() { return found }
            } else if !line.isBlank {
                if first == nil { first = index }
                last = index
            }
        }
        return close()
    }

    /// The vertical extent of a line in text box coordinates, and the baseline of its first line.
    fileprivate func lineFrame(of line: Line) -> (top: CGFloat, bottom: CGFloat, baseline: CGFloat)? {
        let manager = layoutManager
        let inset = textContainerInset.top
        let length = textStorage.length
        if line.range.location >= length {
            let extra = manager.extraLineFragmentRect
            guard extra.height > 0 else { return nil }
            return (extra.minY + inset, extra.maxY + inset, extra.minY + inset + Self.lineHeight * 0.68)
        }
        let characters = line.range.length > 0 ? line.range : NSRange(location: line.range.location, length: 1)
        let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let firstFragment = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let lastFragment = manager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        let baseline = manager.location(forGlyphAt: glyphs.location).y
        return (firstFragment.minY + inset, lastFragment.maxY + inset, firstFragment.minY + inset + baseline)
    }

    /// Decoration layer behind the text: scrolls with the content and is redrawn only when the text or size changes.
    fileprivate final class DecorationView: UIView {
        weak var owner: MemoryRawGutterTextView?

        override func draw(_ rect: CGRect) {
            guard let owner, let context = UIGraphicsGetCurrentContext() else { return }
            owner.layoutManager.ensureLayout(for: owner.textContainer)
            let lines = owner.lines()
            let errors = owner.errorLines(lines)
            let numberFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let tertiary = UIColor(OriveoTheme.Palette.textTertiary).withAlphaComponent(0.7)
            let danger = UIColor(OriveoTheme.Palette.danger)

            if let errors,
               let top = owner.lineFrame(of: lines[errors.lowerBound])?.top,
               let bottom = owner.lineFrame(of: lines[errors.upperBound])?.bottom {
                UIColor(OriveoTheme.Palette.dangerSoft).setFill()
                context.fill(CGRect(x: 0, y: top, width: bounds.width, height: bottom - top))
                danger.setFill()
                context.fill(CGRect(x: 0, y: top, width: 3, height: bottom - top))
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            for (index, line) in lines.enumerated() {
                guard let frame = owner.lineFrame(of: line) else { continue }
                if frame.bottom < rect.minY || frame.top > rect.maxY { continue }
                let isError = errors?.contains(index) ?? false
                let number = "\(index + 1)" as NSString
                number.draw(
                    in: CGRect(
                        x: 0,
                        y: frame.baseline - numberFont.ascender,
                        width: MemoryRawGutterTextView.gutterWidth - 12,
                        height: numberFont.lineHeight
                    ),
                    withAttributes: [
                        .font: numberFont,
                        .foregroundColor: isError ? danger : tertiary,
                        .paragraphStyle: paragraph
                    ]
                )
                if line.isSeparator {
                    let textWidth = (MemoryItems.rawViewSeparator as NSString)
                        .size(withAttributes: [.font: owner.separatorFont]).width
                    let y = (frame.top + frame.bottom) / 2
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: MemoryRawGutterTextView.gutterWidth + textWidth + 10, y: y))
                    path.addLine(to: CGPoint(x: bounds.width - 14, y: y))
                    path.lineWidth = 1
                    path.setLineDash([3, 3], count: 2, phase: 0)
                    UIColor(OriveoTheme.Palette.borderStrong).setStroke()
                    path.stroke()
                }
            }
        }
    }
}
