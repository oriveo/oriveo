import SwiftUI
import UIKit

private struct SendableAttributedString: @unchecked Sendable {
    let value: NSAttributedString
}

final class UIKitCodeBlockCard: UIView {

    private let language: String?
    private let content: String
    private weak var parentViewController: UIViewController?
    private let highlightTransition: Bool
    private let initialAttributedText: NSAttributedString?


    nonisolated static let maxPreviewHeight: CGFloat = 392
    private let renderLineCap = 60


    static let codeBg = MarkdownCodeBlockPalette.backgroundUIColor
    private static let headerBg = MarkdownCodeBlockPalette.surfaceUIColor
    private static let borderColor = MarkdownCodeBlockPalette.borderUIColor
    private static let textFg = MarkdownCodeBlockPalette.foregroundUIColor
    private static let secondaryFg = MarkdownCodeBlockPalette.secondaryUIColor


    private let contentContainer = UIView()
    private let headerBar = UIView()
    private let langCapsule = UIView()
    private let langIcon = UIImageView()
    private let langLabel = UILabel()
    private let lineCountLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let saveNoteButton = UIButton(type: .system)
    private let expandButton = UIButton(type: .system)
    private let codeTextView = ChatPassiveTextView()
    private let gradientOverlay = GradientOverlayView()


    private var copied = false
    private var copyResetWorkItem: DispatchWorkItem?

    var onIntrinsicHeightDidChange: (() -> Void)?

    private var codeHeightConstraint: NSLayoutConstraint!

    #if DEBUG
    var codeHeightConstantForTesting: CGFloat { codeHeightConstraint.constant }
    #endif
    private var copyTrailingToExpand: NSLayoutConstraint!
    private var copyTrailingToHeader: NSLayoutConstraint!
    private var copyTrailingToSave: NSLayoutConstraint!
    private var saveTrailingToExpand: NSLayoutConstraint!
    private var saveTrailingToHeader: NSLayoutConstraint!
    private var lastResolvedWidth: CGFloat = -1

    private var pendingHeightHostNotify: Bool = false


    private var codeText: String {
        content.replacingOccurrences(of: "\t", with: "    ")
    }

    private var lineCount: Int {
        max(codeText.components(separatedBy: .newlines).count, 1)
    }

    private var displayText: String {
        let lines = codeText.components(separatedBy: .newlines)
        guard lines.count > renderLineCap else { return codeText }
        return lines.prefix(renderLineCap).joined(separator: "\n")
    }

    private var isMarkdownLanguage: Bool {
        guard let lang = language?.lowercased() else { return false }
        return lang == "markdown" || lang == "md"
    }

    // MARK: - Init

    var onSaveNote: (() -> Void)? {
        didSet {
            updateHeaderActionLayout(isClipped: !expandButton.isHidden)
        }
    }

    var onAskSelection: ((QuoteSelectionContent) -> Void)? {
        didSet {
            codeTextView.quoteContentKind = .code
            codeTextView.onAskSelection = onAskSelection.map { handler in
                { [weak self] selection in
                    guard let self else { return }
                    let leadingCount = selection.leadingText.count
                    let selectedCount = selection.selectedText.count
                    let full = self.codeText
                    let fullLeading = String(full.prefix(leadingCount))
                    let fullTrailing = String(full.dropFirst(min(full.count, leadingCount + selectedCount)))
                    handler(QuoteSelectionContent(
                        contentKind: .code,
                        leadingText: fullLeading,
                        selectedText: selection.selectedText,
                        trailingText: fullTrailing
                    ))
                }
            }
        }
    }

    init(
        language: String?,
        content: String,
        parentViewController: UIViewController?,
        highlightTransition: Bool = true,
        initialAttributedText: NSAttributedString? = nil
    ) {
        self.language = language
        self.content = content
        self.parentViewController = parentViewController
        self.highlightTransition = highlightTransition
        self.initialAttributedText = initialAttributedText
        super.init(frame: .zero)
        setupViews()
        renderCode()
        addInteraction(UIContextMenuInteraction(delegate: self))
        seedCodeHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        copyResetWorkItem?.cancel()
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .clear
        clipsToBounds = false
        layer.masksToBounds = false
        layer.shadowColor = UIColor(OriveoTheme.Palette.shadow).cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 8)

        contentContainer.backgroundColor = Self.codeBg
        contentContainer.layer.cornerRadius = 16
        contentContainer.layer.cornerCurve = .continuous
        contentContainer.layer.borderWidth = 1
        contentContainer.layer.borderColor = Self.borderColor.cgColor
        contentContainer.clipsToBounds = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setupHeader()
        setupCodeArea()
        setupLayout()

        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: UIKitCodeBlockCard, _) in
                self.updateTraitDependentColors()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        resolveTruncationIfNeeded()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 16).cgPath
    }

    private func resolveTruncationIfNeeded() {
        let width = codeTextView.bounds.width
        guard width > 0, abs(width - lastResolvedWidth) > 0.5 else { return }
        if !ChatCardStableWidth.isTrustworthy(width: width, anchor: ChatCardStableWidth.anchor(for: self)) {
            #if DEBUG
            if ChatRenderDiagnostics.enabled {
                AppLog.info("code card skipped a transient width of \(Int(width))", module: "ChatRender")
            }
            #endif
            return
        }
        lastResolvedWidth = width
        let notify = pendingHeightHostNotify
        pendingHeightHostNotify = false
        applyCodeHeight(forWidth: width, notifyHost: notify)
    }

    private func applyCodeHeight(forWidth width: CGFloat, notifyHost: Bool) {
        guard width > 0 else { return }
        let natural = codeTextView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        let target = min(natural, Self.maxPreviewHeight)
        let heightChanged = abs(codeHeightConstraint.constant - target) > 0.5
        if heightChanged {
            #if DEBUG
            if ChatRenderDiagnostics.enabled {
                AppLog.info(
                    "code card height \(Int(codeHeightConstraint.constant)) -> \(Int(target)) "
                    + "at width \(Int(width))",
                    module: "ChatRender"
                )
            }
            #endif
            codeHeightConstraint.constant = target
        }
        let clipped = natural > Self.maxPreviewHeight + 0.5
            || codeText.components(separatedBy: .newlines).count > renderLineCap
        gradientOverlay.isHidden = !clipped
        expandButton.isHidden = !clipped
        lineCountLabel.isHidden = !clipped
        if clipped {
            lineCountLabel.text = String(format: L10n.tr("%lld lines"), Int64(lineCount))
        }
        updateHeaderActionLayout(isClipped: clipped)
        if heightChanged && notifyHost {
            onIntrinsicHeightDidChange?()
        }
    }

    private func seedCodeHeight() {
        let width = codeTextView.bounds.width > 0
            ? codeTextView.bounds.width
            : (bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - ChatCardStableWidth.contentChrome)
        applyCodeHeight(forWidth: width, notifyHost: false)
    }

    private func updateTraitDependentColors() {
        contentContainer.layer.borderColor = Self.borderColor.cgColor
    }

    private func setupHeader() {
        headerBar.backgroundColor = Self.headerBg
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(headerBar)

        langCapsule.backgroundColor = Self.headerBg
        langCapsule.layer.cornerRadius = 12
        langCapsule.layer.cornerCurve = .continuous
        langCapsule.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(langCapsule)

        langIcon.image = UIImage(systemName: "curlybraces")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        langIcon.tintColor = Self.secondaryFg
        langIcon.translatesAutoresizingMaskIntoConstraints = false
        langCapsule.addSubview(langIcon)

        langLabel.font = .systemFont(ofSize: 12)
        langLabel.textColor = Self.textFg
        langLabel.text = (language?.isEmpty == false ? language! : L10n.tr("Code")).uppercased()
        langLabel.translatesAutoresizingMaskIntoConstraints = false
        langCapsule.addSubview(langLabel)

        lineCountLabel.font = .systemFont(ofSize: 12)
        lineCountLabel.textColor = Self.secondaryFg
        lineCountLabel.isHidden = true
        lineCountLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(lineCountLabel)

        configurePillButton(copyButton, icon: "doc.on.doc", title: L10n.tr("Copy"))
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(copyButton)

        configurePillButton(saveNoteButton, icon: "note.text.badge.plus", title: L10n.tr("Save as Note", table: .notes))
        saveNoteButton.addTarget(self, action: #selector(saveNoteTapped), for: .touchUpInside)
        saveNoteButton.isHidden = true
        saveNoteButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(saveNoteButton)

        configurePillButton(expandButton, icon: "arrow.up.left.and.arrow.down.right", title: L10n.tr("Expand"))
        expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        expandButton.isHidden = true
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(expandButton)
    }

    private func configurePillButton(_ button: UIButton, icon: String, title: String) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: icon)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.title = title
        config.baseForegroundColor = Self.textFg
        config.imagePadding = 4
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .footnote)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont(descriptor: descriptor, size: 0)
            return outgoing
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        button.configuration = config
    }

    private func setupCodeArea() {
        codeTextView.isEditable = false
        codeTextView.isScrollEnabled = false
        codeTextView.isSelectable = true
        codeTextView.backgroundColor = .clear
        codeTextView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        codeTextView.textColor = Self.textFg
        codeTextView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        codeTextView.textContainer.lineFragmentPadding = 0
        codeTextView.setContentHuggingPriority(.required, for: .vertical)
        codeTextView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        codeTextView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(codeTextView)

        gradientOverlay.isHidden = true
        gradientOverlay.translatesAutoresizingMaskIntoConstraints = false
        gradientOverlay.isUserInteractionEnabled = false
        contentContainer.addSubview(gradientOverlay)
    }

    private func setupLayout() {
        let headerHeight: CGFloat = 44 // 12 + 20(capsule) + 12

        let headerHeightConstraint = headerBar.heightAnchor.constraint(equalToConstant: headerHeight)
        headerHeightConstraint.priority = .required - 1

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            headerHeightConstraint,

            langCapsule.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),
            langCapsule.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            langIcon.leadingAnchor.constraint(equalTo: langCapsule.leadingAnchor, constant: 10),
            langIcon.centerYAnchor.constraint(equalTo: langCapsule.centerYAnchor),

            langLabel.leadingAnchor.constraint(equalTo: langIcon.trailingAnchor, constant: 8),
            langLabel.trailingAnchor.constraint(equalTo: langCapsule.trailingAnchor, constant: -10),
            langLabel.centerYAnchor.constraint(equalTo: langCapsule.centerYAnchor),

            langCapsule.heightAnchor.constraint(equalToConstant: 28),

            expandButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12),
            expandButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            saveNoteButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            copyButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            lineCountLabel.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            lineCountLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            codeTextView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            codeTextView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            codeTextView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            codeTextView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            gradientOverlay.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            gradientOverlay.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            gradientOverlay.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            gradientOverlay.heightAnchor.constraint(equalToConstant: 44),
        ])

        codeHeightConstraint = codeTextView.heightAnchor.constraint(equalToConstant: Self.maxPreviewHeight)
        codeHeightConstraint.priority = .required
        codeHeightConstraint.isActive = true

        copyTrailingToExpand = copyButton.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: -8)
        copyTrailingToHeader = copyButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12)
        copyTrailingToSave = copyButton.trailingAnchor.constraint(equalTo: saveNoteButton.leadingAnchor, constant: -8)
        saveTrailingToExpand = saveNoteButton.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: -8)
        saveTrailingToHeader = saveNoteButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12)
        copyTrailingToHeader.isActive = true
    }

    private func updateHeaderActionLayout(isClipped: Bool) {
        let canSave = onSaveNote != nil
        saveNoteButton.isHidden = !canSave

        copyTrailingToExpand.isActive = !canSave && isClipped
        copyTrailingToHeader.isActive = !canSave && !isClipped
        copyTrailingToSave.isActive = canSave
        saveTrailingToExpand.isActive = canSave && isClipped
        saveTrailingToHeader.isActive = canSave && !isClipped
    }


    private static let asyncHighlightThresholdLines = 20
    private static let asyncHighlightThresholdChars = 2000

    private func renderCode() {
        let preview = displayText
        let shouldAsync = lineCount > Self.asyncHighlightThresholdLines
            || codeText.count > Self.asyncHighlightThresholdChars

        guard shouldAsync else {
            renderCodeSync(previewText: preview)
            return
        }

        if isMarkdownLanguage {
            if let cached = MarkdownAttributedStringRenderer.cachedRender(for: preview) {
                codeTextView.attributedText = cached
                return
            }
        } else if let cached = SyntaxHighlighter.cachedHighlight(preview, language: language) {
            codeTextView.attributedText = cached
            return
        }

        if let handoff = initialAttributedText, handoff.string.hasPrefix(preview) {
            let previewUTF16 = (preview as NSString).length
            codeTextView.attributedText = handoff.length == previewUTF16
                ? handoff
                : handoff.attributedSubstring(from: NSRange(location: 0, length: previewUTF16))
        } else {
            let plainAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: Self.textFg,
            ]
            codeTextView.attributedText = NSAttributedString(string: preview, attributes: plainAttrs)
        }

        let lang = language
        let isMd = isMarkdownLanguage
        let baseColor = Self.textFg
        let expectedPreview = preview  // capture for validation
        Task.detached(priority: .utility) { [weak self] in
            let highlighted: SendableAttributedString
            if isMd {
                highlighted = SendableAttributedString(
                    value: MarkdownAttributedStringRenderer.render(preview)
                )
            } else {
                highlighted = SendableAttributedString(
                    value: SyntaxHighlighter.highlight(preview, language: lang, baseColor: baseColor)
                )
            }
            await MainActor.run { [weak self] in
                guard let self, self.displayText == expectedPreview else { return }
                if let current = self.codeTextView.attributedText, highlighted.value.isEqual(to: current) {
                    return
                }
                guard self.highlightTransition else {
                    self.codeTextView.attributedText = highlighted.value
                    self.refreshCodeHeightAfterRehighlight()
                    return
                }
                UIView.transition(
                    with: self.codeTextView,
                    duration: 0.18,
                    options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
                ) {
                    self.codeTextView.attributedText = highlighted.value
                }
                self.refreshCodeHeightAfterRehighlight()
            }
        }
    }

    private func refreshCodeHeightAfterRehighlight() {
        lastResolvedWidth = -1
        pendingHeightHostNotify = true
        setNeedsLayout()
    }

    #if DEBUG
    var _testCodeAttributedText: NSAttributedString? { codeTextView.attributedText }
    #endif

    private func renderCodeSync(previewText: String) {
        if isMarkdownLanguage {
            codeTextView.attributedText = MarkdownAttributedStringRenderer.render(previewText)
        } else {
            codeTextView.attributedText = SyntaxHighlighter.highlight(
                previewText,
                language: language,
                baseColor: Self.textFg
            )
        }
    }

    // MARK: - Actions

    @objc private func copyTapped() {
        UIPasteboard.general.string = content
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        copied = true
        updateCopyButtonState()

        copyResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.copied = false
            self?.updateCopyButtonState()
        }
        copyResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func updateCopyButtonState() {
        var config = copyButton.configuration ?? .plain()
        config.image = UIImage(systemName: copied ? "checkmark" : "doc.on.doc")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.title = copied ? L10n.tr("Copied") : L10n.tr("Copy")
        copyButton.configuration = config
    }

    @objc private func expandTapped() {
        guard let parentVC = parentViewController ?? findViewController() else { return }
        let sheet = CodeBlockViewerSheet(language: language, content: codeText)
        let hostingVC = UIHostingController(rootView: sheet)
        parentVC.present(hostingVC, animated: true)
    }

    @objc private func saveNoteTapped() {
        onSaveNote?()
    }

    private func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController { return vc }
            responder = next
        }
        return nil
    }
}


private final class GradientOverlayView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [
            UIColor.clear.cgColor,
            UIKitCodeBlockCard.codeBg.withAlphaComponent(0.92).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }
}

extension UIKitCodeBlockCard: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard onSaveNote != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let save = UIAction(
                title: L10n.tr("Save as Note", table: .notes),
                image: UIImage(systemName: "note.text.badge.plus")
            ) { _ in
                self?.onSaveNote?()
            }
            return UIMenu(title: "", children: [save])
        }
    }
}
