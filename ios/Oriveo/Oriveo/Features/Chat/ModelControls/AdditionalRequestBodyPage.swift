import SwiftUI
import UIKit

/// The "Additional request body" editor (Advanced settings → Write it yourself → Additional request body).
///
/// A JSON object written by the user and merged into every request as written. The page does three things: lets them write it, tells them what happens to each field
/// when sent, and points at the exact line when something is wrong. The content is stored on the device only, not synced and not in backups.
struct AdditionalRequestBodyPage: View {
    let provider: Provider
    let model: AIModel
    let conversationID: UUID?
    /// The runtime identity for the officially declared web search and thinking fields; an empty string means this connection has no such sections.
    let transportIdentity: String
    var store: GenerationParameterSettingsStore = .shared

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var sends = false
    @State private var didLoad = false
    @State private var report = AdditionalRequestBodyInspector.inspect("")
    @State private var formatFailed = false
    @State private var showsPasteConfirmation = false
    @State private var showsOfficialFields = false
    @State private var hasOfficialFields = false


    private var storageModelID: String {
        CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            AdvancedPageHeader(
                title: L10n.tr("Additional request body", table: .chat),
                subtitle: "\(model.name) · \(scopeWord)",
                onBack: { dismiss() }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    sendCard.padding(.top, 6)
                    editorCard
                    if let problem {
                        Text(problem)
                            .font(.system(size: 12.5))
                            .foregroundStyle(OriveoTheme.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6)
                    }
                    if !report.fields.isEmpty {
                        AdvancedSectionLabel(title: L10n.tr("When sending", table: .chat))
                        fieldList
                    }
                    Text(L10n.tr(
                        "Fields here are added to the request as written; Oriveo doesn’t check whether your server accepts them. If one has the same name as an advanced setting, the one here is used, and your other settings are sent as usual.",
                        table: .chat
                    ))
                    .font(.system(size: 12.5))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.top, 2)

                    if let documentation = AdditionalRequestBodyInspector.engineDocumentation(
                        engineProfile: provider.relayRequested?.engineProfile
                    ) {
                        Link(destination: documentation.url) {
                            Text(String(
                                format: L10n.tr("See which fields %@ supports", table: .chat),
                                documentation.engineName
                            ))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .padding(.horizontal, 6)
                    }

                    if hasOfficialFields {
                        // The officially declared web search and thinking fields follow other validation rules and have a page of their own.
                        Button {
                            showsOfficialFields = true
                        } label: {
                            HStack(spacing: 10) {
                                Text(L10n.tr("Web search and thinking fields", table: .chat))
                                    .font(.system(size: 16))
                                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                Spacer(minLength: 8)
                                AdvancedChevron()
                            }
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .modelControlSurface()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(OriveoTheme.Palette.background)
        .background(SheetInteractivePopEnabler())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: load)
        .alert(L10n.tr("Replace what’s here?", table: .chat), isPresented: $showsPasteConfirmation) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Replace", table: .chat), role: .destructive) {
                pasteFromClipboard()
            }
        } message: {
            Text(L10n.tr("Pasting replaces the current content with what’s on the clipboard.", table: .chat))
        }
        .navigationDestination(isPresented: $showsOfficialFields) {
            CustomRequestFieldsPage(
                provider: provider, model: model, conversationID: conversationID,
                transportIdentity: transportIdentity
            )
        }
        .tint(OriveoTheme.Palette.primary)
    }

    private var scopeWord: String {
        conversationID != nil
            ? L10n.tr("This conversation only", table: .chat)
            : L10n.tr("Model defaults", table: .chat)
    }

    /// Problems the list cannot pin to a field (not valid JSON, not an object, too large, too deep) are said here.
    /// Protected fields already have their reason and line in the list and are not repeated.
    private var problem: String? {
        if formatFailed {
            return L10n.tr("This isn’t valid JSON yet, so nothing was changed.", table: .chat)
        }
        guard let rejection = report.rejection else { return nil }
        if report.fields.contains(where: { $0.status != .added }) { return nil }
        if rejection.line == nil, let line = report.errorLines.min() {
            return AdditionalRequestBodyRejection(reason: rejection.reason, field: rejection.field, line: line)
                .localizedMessage
        }
        return rejection.localizedMessage
    }

    // MARK: - Cards

    private var sendCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("Send with requests", table: .chat))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(L10n.tr("When off, the content is kept but not sent", table: .chat))
                    .font(.system(size: 12.5))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { sends },
                set: { next in
                    sends = next
                    persist()
                }
            ))
            .labelsHidden()
            .tint(OriveoTheme.Palette.primaryTextSafe)
            .accessibilityLabel(Text(L10n.tr("Send with requests", table: .chat)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .modelControlSurface()
    }

    private var editorCard: some View {
        VStack(spacing: 0) {
            AdditionalRequestBodyEditor(
                text: Binding(
                    get: { draft },
                    // Saved as typed: closing the page must not lose half-written JSON.
                    set: { next in
                        guard next != draft else { return }
                        draft = next
                        formatFailed = false
                        report = AdditionalRequestBodyInspector.inspect(next)
                        persist()
                    }
                ),
                errorLines: report.errorLines,
                markedKeys: Set(report.fields.filter { $0.status != .added }.map { "\($0.line):\($0.name)" })
            )
            .frame(minHeight: 150)
            .accessibilityLabel(Text(L10n.tr("Additional request body", table: .chat)))

            HStack(spacing: 0) {
                Text(L10n.tr("Saved on this device only, not synced", table: .chat))
                    .font(.system(size: 12.5))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                barButton(L10n.tr("Paste", table: .chat)) {
                    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pasteFromClipboard()
                    } else {
                        showsPasteConfirmation = true
                    }
                }
                barButton(L10n.tr("Tidy up", table: .chat)) {
                    // Laid out again only when valid; invalid text is left untouched, with one sentence saying so.
                    if let formatted = AdditionalRequestBodyInspector.formatted(draft) {
                        replaceDraft(formatted)
                    } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        formatFailed = true
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(minHeight: 44)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .modelControlSurface()
    }

    private func barButton(
        _ title: String, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fieldList: some View {
        VStack(spacing: 0) {
            ForEach(Array(report.fields.enumerated()), id: \.element.id) { index, field in
                if index > 0 { ModelControlHairline() }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(field.path)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if field.status != .added {
                            Text(AdditionalRequestBodyInspector.explanation(for: field))
                                .font(.system(size: 12.5))
                                .foregroundStyle(OriveoTheme.Palette.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(statusText(field))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(statusColor(field))
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modelControlSurface()
    }

    private func statusText(_ field: AdditionalRequestBodyInspector.Field) -> String {
        guard field.status == .added else { return L10n.tr("Can’t be changed", table: .chat) }
        // While the switch is off it does not say "added": that would state something that is not happening right now.
        return sends ? L10n.tr("Included", table: .chat) : L10n.tr("Omit")
    }

    private func statusColor(_ field: AdditionalRequestBodyInspector.Field) -> Color {
        guard field.status == .added else { return OriveoTheme.Palette.danger }
        return sends ? OriveoTheme.Palette.success : OriveoTheme.Palette.textTertiary
    }

    // MARK: - Reading and writing

    private func load() {
        // onAppear fires again each time this page is returned to, and reading again would roll the draft being edited back to the stored value.
        guard !didLoad else { return }
        didLoad = true
        let configuration = store.effectiveAdditionalRequestBody(
            providerID: provider.id, modelID: storageModelID, conversationID: conversationID
        )
        draft = configuration.rawJSON
        sends = configuration.sendsWithRequest
        report = AdditionalRequestBodyInspector.inspect(draft)
        hasOfficialFields = !transportIdentity.isEmpty && !CustomRequestFieldsPage.resolveSections(
            provider: provider, model: model, conversationID: conversationID,
            transportIdentity: transportIdentity
        ).visible.isEmpty
    }

    /// The conversation scope always keeps a record (even when cleared): otherwise a cleared body falls back to the model default
    /// and the content just deleted shows up again next time. In the model default scope a cleared body with the switch off deletes the record.
    private func persist() {
        let isBlank = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let configuration: AdditionalRequestBodyConfiguration? = conversationID == nil && isBlank && !sends
            ? nil
            : .init(rawJSON: draft, sendsWithRequest: sends)
        store.setAdditionalRequestBody(
            configuration, providerID: provider.id, modelID: storageModelID, conversationID: conversationID
        )
    }

    private func replaceDraft(_ next: String) {
        draft = next
        formatFailed = false
        report = AdditionalRequestBodyInspector.inspect(next)
        persist()
    }

    private func pasteFromClipboard() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { return }
        replaceDraft(pasted)
    }
}

// MARK: - Editor

/// A dark monospaced editor: line numbers, JSON coloring, highlighted error lines.
///
/// SwiftUI's `TextEditor` can neither color parts of the text nor report line positions, hence `UITextView`.
/// It does not scroll by itself: its height follows the content and the surrounding page scrolls, which keeps line numbers aligned with the text.
struct AdditionalRequestBodyEditor: UIViewRepresentable {
    @Binding var text: String
    let errorLines: Set<Int>
    /// Keys to mark individually, as `line:key`.
    let markedKeys: Set<String>

    /// The editor is dark in both themes (the convention for code areas), so its colors do not follow the theme.
    enum Palette {
        static let background = UIColor(red: 0x17 / 255, green: 0x1B / 255, blue: 0x24 / 255, alpha: 1)
        static let text = UIColor(red: 0xE6 / 255, green: 0xE8 / 255, blue: 0xEE / 255, alpha: 1)
        static let key = UIColor(red: 0xC4 / 255, green: 0xB5 / 255, blue: 0xFD / 255, alpha: 1)
        static let literal = UIColor(red: 0xFC / 255, green: 0xD3 / 255, blue: 0x4D / 255, alpha: 1)
        static let gutter = UIColor(red: 0x5C / 255, green: 0x64 / 255, blue: 0x73 / 255, alpha: 1)
        static let errorText = UIColor(red: 0xFC / 255, green: 0xA5 / 255, blue: 0xA5 / 255, alpha: 1)
        static let errorKeyFill = UIColor(red: 0xF8 / 255, green: 0x71 / 255, blue: 0x71 / 255, alpha: 0.24)
        static let errorLineFill = UIColor(red: 0xF8 / 255, green: 0x71 / 255, blue: 0x71 / 255, alpha: 0.10)
    }

    static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let gutterWidth: CGFloat = 34

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> LineNumberTextView {
        let view = LineNumberTextView.make()
        view.delegate = context.coordinator
        view.backgroundColor = Palette.background
        view.isScrollEnabled = false
        view.font = Self.font
        view.textColor = Palette.text
        view.tintColor = Palette.key
        view.keyboardAppearance = .dark
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.textContainerInset = UIEdgeInsets(top: 14, left: Self.gutterWidth, bottom: 14, right: 14)
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.typingAttributes = Self.baseAttributes

        // A UIKit text view does not get SwiftUI's keyboard toolbar; the "Done" that dismisses the keyboard sits on its own accessory view.
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.items = [
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(
                title: L10n.tr("Done"), style: .done, target: context.coordinator,
                action: #selector(Coordinator.dismissKeyboard)
            ),
        ]
        view.inputAccessoryView = bar
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: LineNumberTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
        }
        context.coordinator.highlight(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LineNumberTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(150, fitted.height))
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        return [.font: font, .foregroundColor: Palette.text, .paragraphStyle: paragraph]
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AdditionalRequestBodyEditor
        weak var textView: LineNumberTextView?
        private var lastSignature: Int?

        init(_ parent: AdditionalRequestBodyEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? LineNumberTextView)?.setNeedsGutterDisplay()
        }

        @objc func dismissKeyboard() {
            textView?.resignFirstResponder()
        }

        /// Only attributes change, never the text, so caret and selection stay put. Nothing is touched during IME composition, which would interrupt the candidates.
        func highlight(_ view: LineNumberTextView) {
            guard view.markedTextRange == nil else { return }
            let raw = view.text ?? ""
            var hasher = Hasher()
            hasher.combine(raw)
            hasher.combine(parent.errorLines)
            hasher.combine(parent.markedKeys)
            let signature = hasher.finalize()
            guard signature != lastSignature else { return }
            lastSignature = signature

            let storage = view.textStorage
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(AdditionalRequestBodyEditor.baseAttributes, range: full)
            for line in parent.errorLines {
                if let range = AdditionalRequestBodyInspector.range(ofLine: line, in: raw), range.length > 0 {
                    storage.addAttribute(.backgroundColor, value: Palette.errorLineFill, range: range)
                }
            }
            for token in AdditionalRequestBodyInspector.tokens(raw) where NSMaxRange(token.range) <= storage.length {
                switch token.kind {
                case .key:
                    if parent.markedKeys.contains("\(token.line):\(token.text)") {
                        storage.addAttributes(
                            [.foregroundColor: Palette.errorText, .backgroundColor: Palette.errorKeyFill],
                            range: token.range
                        )
                    } else {
                        storage.addAttribute(.foregroundColor, value: Palette.key, range: token.range)
                    }
                case .literal:
                    storage.addAttribute(.foregroundColor, value: Palette.literal, range: token.range)
                case .string, .punctuation:
                    break
                }
            }
            storage.endEditing()
            view.typingAttributes = AdditionalRequestBodyEditor.baseAttributes
            view.errorLines = parent.errorLines
            view.setNeedsGutterDisplay()
        }
    }
}

/// A text view with line numbers on the left. They are drawn on a subview that takes no touches, positioned from the layout result,
/// so with soft wrapping a line number still sits at the first fragment of its logical line and wrapped fragments are not counted again.
final class LineNumberTextView: UITextView {
    struct GutterEntry: Equatable {
        /// The logical line number, starting at 1.
        let number: Int
        /// The vertical extent this logical line (with its wrapped fragments) takes in the view.
        let minY: CGFloat
        let height: CGFloat
        let isError: Bool
    }

    var errorLines: Set<Int> = [] {
        didSet { if errorLines != oldValue { gutter.setNeedsDisplay() } }
    }
    private let gutter = GutterView()
    /// The text stack is built here (TextKit 1, since line numbers need positions per line fragment), and someone has to hold the text storage strongly.
    private var ownedStorage: NSTextStorage?

    /// Created with an explicit TextKit 1 stack. `UITextView(usingTextLayoutManager:)` is not used: it is a class factory
    /// that does not guarantee this class's initializer runs, and the gutter would never be attached.
    static func make() -> LineNumberTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let view = LineNumberTextView(frame: .zero, textContainer: container)
        view.ownedStorage = storage
        return view
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        attachGutterIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func attachGutterIfNeeded() {
        gutter.owner = self
        guard gutter.superview !== self else { return }
        gutter.backgroundColor = .clear
        gutter.isOpaque = false
        gutter.contentMode = .redraw
        gutter.isUserInteractionEnabled = false
        gutter.isAccessibilityElement = false
        addSubview(gutter)
    }

    /// Whether the gutter is really attached to the view (tests use it to confirm that "nothing drawn" is not because it was never added).
    var hasGutter: Bool { gutter.superview === self && gutter.owner === self }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachGutterIfNeeded()
        gutter.frame = CGRect(
            x: 0, y: 0, width: AdditionalRequestBodyEditor.gutterWidth, height: max(bounds.height, contentSize.height)
        )
        bringSubviewToFront(gutter)
        gutter.setNeedsDisplay()
    }

    func setNeedsGutterDisplay() {
        setNeedsLayout()
        gutter.setNeedsDisplay()
    }

    /// The gutter's content: one entry per logical line, with soft-wrapped fragments merged into the same entry.
    func gutterEntries() -> [GutterEntry] {
        let text = (self.text ?? "") as NSString
        var entries: [GutterEntry] = []
        var location = 0
        layoutManager.ensureLayout(for: textContainer)
        let top = textContainerInset.top
        let fallbackHeight = (font ?? AdditionalRequestBodyEditor.font).lineHeight * 1.25
        func append(minY: CGFloat, height: CGFloat) {
            let number = entries.count + 1
            entries.append(.init(number: number, minY: minY, height: height, isError: errorLines.contains(number)))
        }
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = glyphs.length > 0
                ? layoutManager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
                : first
            append(minY: first.minY + top, height: max(last.maxY - first.minY, 0))
            guard lineRange.length > 0 else { break }
            location = NSMaxRange(lineRange)
        }
        // Empty text, or text ending in a newline: there is one more empty line without glyphs, positioned from the layout manager's "extra line".
        if text.length == 0 || text.character(at: text.length - 1) == 10 {
            let extra = layoutManager.extraLineFragmentRect
            let minY = extra.isEmpty ? (entries.last.map { $0.minY + $0.height } ?? top) : extra.minY + top
            append(minY: minY, height: extra.isEmpty ? fallbackHeight : extra.height)
        }
        return entries
    }

    private final class GutterView: UIView {
        weak var owner: LineNumberTextView?

        override func draw(_ rect: CGRect) {
            guard let owner else { return }
            let font = AdditionalRequestBodyEditor.font
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            // The line height multiple pushes glyphs down a little; line numbers are shifted by the same amount to sit near the baseline.
            let leading = font.lineHeight * 0.25
            for entry in owner.gutterEntries() {
                if entry.isError {
                    // The error line's background starts at the left edge and joins the highlight over the text into one full line.
                    AdditionalRequestBodyEditor.Palette.errorLineFill.setFill()
                    UIRectFillUsingBlendMode(
                        CGRect(x: 0, y: entry.minY, width: bounds.width, height: entry.height), .normal
                    )
                }
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: entry.isError
                        ? AdditionalRequestBodyEditor.Palette.errorText
                        : AdditionalRequestBodyEditor.Palette.gutter,
                    .paragraphStyle: paragraph,
                ]
                // Right-aligned, with 12pt between it and the code.
                let frame = CGRect(
                    x: 0, y: entry.minY + leading,
                    width: AdditionalRequestBodyEditor.gutterWidth - 12, height: font.lineHeight
                )
                ("\(entry.number)" as NSString).draw(in: frame, withAttributes: attributes)
            }
        }
    }
}
