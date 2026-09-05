import SwiftUI
import UIKit


private final class GradientBubbleView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

    private let borderLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()

    var onPathChanged: ((CGPath) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradientLayer.colors = [
            UIColor(Color.dynamic(light: 0x8347F5, dark: 0x8347F5)).cgColor,
            UIColor(Color.dynamic(light: 0x6B3BC7, dark: 0x6B3BC7)).cgColor,
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)

        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        borderLayer.strokeColor = UIColor(OriveoTheme.Palette.hairline).cgColor
        layer.addSublayer(borderLayer)

        layer.mask = maskLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        let path = Self.bubblePath(in: b)
        maskLayer.path = path
        borderLayer.path = path
        borderLayer.frame = b
        onPathChanged?(path)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            gradientLayer.colors = [
                UIColor(Color.dynamic(light: 0x8347F5, dark: 0x8347F5)).cgColor,
                UIColor(Color.dynamic(light: 0x6B3BC7, dark: 0x6B3BC7)).cgColor,
            ]
            borderLayer.strokeColor = UIColor(OriveoTheme.Palette.hairline).cgColor
        }
    }

    /// UnevenRoundedRect: topLeading=20, topTrailing=20, bottomLeading=20, bottomTrailing=6
    private static func bubblePath(in rect: CGRect) -> CGPath {
        let (tl, tr, bl, br): (CGFloat, CGFloat, CGFloat, CGFloat) = (20, 20, 20, 6)
        let w = rect.width, h = rect.height
        let path = UIBezierPath()
        path.move(to: CGPoint(x: tl, y: 0))
        path.addLine(to: CGPoint(x: w - tr, y: 0))
        path.addQuadCurve(to: CGPoint(x: w, y: tr), controlPoint: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: h - br))
        path.addQuadCurve(to: CGPoint(x: w - br, y: h), controlPoint: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: bl, y: h))
        path.addQuadCurve(to: CGPoint(x: 0, y: h - bl), controlPoint: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: 0, y: tl))
        path.addQuadCurve(to: CGPoint(x: tl, y: 0), controlPoint: CGPoint(x: 0, y: 0))
        path.close()
        return path.cgPath
    }
}

// MARK: - UserMessageCell

/// ```
///     VStack(.trailing, spacing: 8)       ← bubbleContent
/// ```
final class UserMessageCell: UICollectionViewCell {
    private let shadowHost = UIView()
    private let bubbleView = GradientBubbleView()
    private let bubbleStack = UIStackView()
    private let textView = ChatPassiveTextView()
    private let savedNoteReferenceButton = UIButton(type: .system)
    private let avatarView = UIKitAvatarView()

    private var attachmentHostingController: UIHostingController<AnyView>?
    private var quoteHostingController: UIHostingController<AnyView>?
    private weak var parentViewController: UIViewController?

    private var topPaddingConstraint: NSLayoutConstraint!
    private var bubbleWidthConstraint: NSLayoutConstraint!
    private var bubbleEqualWidthConstraint: NSLayoutConstraint!
    private var textWidthConstraint: NSLayoutConstraint!
    private var bubbleStackTopConstraint: NSLayoutConstraint!
    private var bubbleStackLeadingConstraint: NSLayoutConstraint!
    private var bubbleStackTrailingConstraint: NSLayoutConstraint!
    private var bubbleStackBottomConstraint: NSLayoutConstraint!
    private var boundMessageID: UUID?
    private var currentText = ""

    var onSaveNote: (() -> Void)?
    private var onOpenNoteReferences: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        bubbleView.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateShadow()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateShadow()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onSaveNote = nil
        onOpenNoteReferences = nil
        boundMessageID = nil
        currentText = ""
        textView.onSaveSelection = nil
        textView.onAskSelection = nil
        textView.onReplaceSelection = nil
        textView.text = nil
        textView.attributedText = nil
        textView.isHidden = false
        tearDownAttachmentHost()
        tearDownQuoteHost()
    }

    func configure(
        model: ChatCollectionProjectionBuilder.MessageRenderModel,
        maxBubbleWidth: CGFloat,
        parentViewController: UIViewController,
        onSaveNote: (() -> Void)? = nil,
        onSaveSelection: ((String) -> Void)? = nil,
        onAskSelection: ((QuoteSelectionContent) -> Void)? = nil,
        onOpenNoteReferences: (() -> Void)? = nil
    ) {
        boundMessageID = model.messageID
        self.parentViewController = parentViewController
        self.onSaveNote = onSaveNote
        self.onOpenNoteReferences = onOpenNoteReferences
        textView.onSaveSelection = onSaveSelection
        textView.onAskSelection = onAskSelection
        textView.quoteContentKind = .prose
        textView.onReplaceSelection = nil

        topPaddingConstraint.constant = model.topPadding

        let text = model.message.text
        currentText = text
        let attachments = model.message.attachments ?? []
        let quoteContext = model.message.quoteContext?.isValid == true ? model.message.quoteContext : nil
        let imageCount = attachments.filter { $0.kind == .image }.count
        let fileCount = attachments.filter { $0.kind != .image }.count
        let isImmersiveHero = imageCount == 1 && fileCount == 0
        let hasText = !text.isEmpty

        let effectiveBubbleWidth: CGFloat = {
            guard isImmersiveHero,
                  let img = attachments.first(where: { $0.kind == .image }) else {
                return maxBubbleWidth
            }
            let aspect = CachedAttachmentImage.preferredAspectRatio(
                for: img,
                partitionUID: AppSessionStore.activeUID
            )
            let heroMaxHeight: CGFloat = 240
            return min(maxBubbleWidth, heroMaxHeight * aspect)
        }()

        bubbleWidthConstraint.constant = effectiveBubbleWidth

        bubbleStackTopConstraint.constant = isImmersiveHero ? 0 : 14
        bubbleStackLeadingConstraint.constant = isImmersiveHero ? 0 : OriveoTheme.Spacing.lg
        bubbleStackTrailingConstraint.constant = isImmersiveHero ? 0 : -OriveoTheme.Spacing.lg
        bubbleStackBottomConstraint.constant = isImmersiveHero ? 0 : -14

        if hasText {
            let userParagraph = NSMutableParagraphStyle()
            let scale = UIScreen.main.scale > 0 ? UIScreen.main.scale : 3.0
            let userFont = OriveoTheme.Typography.chatBodyUIFont()
            let alignedLineHeight = (userFont.lineHeight * 1.08 * scale).rounded() / scale
            userParagraph.minimumLineHeight = alignedLineHeight
            userParagraph.paragraphSpacing = 0
            textView.attributedText = NSAttributedString(
                string: text,
                attributes: [
                    .font: userFont,
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: userParagraph,
                ]
            )
            textView.isHidden = false
            textView.textContainerInset = isImmersiveHero
                ? UIEdgeInsets(top: 8, left: OriveoTheme.Spacing.lg, bottom: 14, right: OriveoTheme.Spacing.lg)
                : .zero
            textWidthConstraint.constant = isImmersiveHero
                ? effectiveBubbleWidth
                : (effectiveBubbleWidth - OriveoTheme.Spacing.lg * 2)
            let hugText = attachments.isEmpty && quoteContext == nil
            textView.maxContentWidth = textWidthConstraint.constant
            textView.hugsContentWidth = hugText
            textView.setContentHuggingPriority(hugText ? .defaultHigh : .defaultLow, for: .horizontal)
            if hugText {
                let contentWidth = textView.intrinsicContentSize.width
                bubbleEqualWidthConstraint.constant = contentWidth + OriveoTheme.Spacing.lg * 2
            } else {
                bubbleEqualWidthConstraint.constant = effectiveBubbleWidth
            }
            bubbleEqualWidthConstraint.isActive = true
        } else {
            textView.isHidden = true
            textView.textContainerInset = .zero
            textWidthConstraint.constant = effectiveBubbleWidth - (OriveoTheme.Spacing.lg * 2)
            textView.hugsContentWidth = false
            textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            bubbleEqualWidthConstraint.constant = effectiveBubbleWidth
            bubbleEqualWidthConstraint.isActive = true
        }

        configureQuote(quoteContext, parentViewController: parentViewController)

        if !attachments.isEmpty {
            configureAttachments(
                attachments,
                immersiveHero: isImmersiveHero,
                hasText: hasText,
                parentViewController: parentViewController
            )
        } else {
            tearDownAttachmentHost()
        }

        savedNoteReferenceButton.isHidden = onOpenNoteReferences == nil || model.noteReferences.isEmpty
    }

    var bubbleFrameForTesting: CGRect { shadowHost.frame }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        shadowHost.backgroundColor = .clear
        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(shadowHost)

        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.addSubview(bubbleView)
        bubbleView.onPathChanged = { [weak self] path in
            self?.shadowHost.layer.shadowPath = path
        }

        bubbleStack.axis = .vertical
        bubbleStack.alignment = .fill
        bubbleStack.spacing = OriveoTheme.Spacing.sm
        bubbleStack.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(bubbleStack)

        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textColor = .white
        textView.tintColor = .white
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        bubbleStack.addArrangedSubview(textView)

        var savedNoteConfig = UIButton.Configuration.plain()
        savedNoteConfig.image = UIImage(
            systemName: "note.text",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )
        savedNoteConfig.imagePadding = 4
        savedNoteConfig.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 0, trailing: 0)
        savedNoteConfig.baseForegroundColor = UIColor.white.withAlphaComponent(0.82)
        var savedNoteTitle = AttributedString(L10n.tr("Saved as note", table: .notes))
        savedNoteTitle.font = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .caption2), size: 0)
        savedNoteConfig.attributedTitle = savedNoteTitle
        savedNoteReferenceButton.configuration = savedNoteConfig
        savedNoteReferenceButton.contentHorizontalAlignment = .trailing
        savedNoteReferenceButton.accessibilityLabel = L10n.tr("Saved as note", table: .notes)
        savedNoteReferenceButton.addTarget(self, action: #selector(savedNoteReferenceTapped), for: .touchUpInside)
        savedNoteReferenceButton.isHidden = true
        bubbleStack.addArrangedSubview(savedNoteReferenceButton)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatarView)

        topPaddingConstraint = shadowHost.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16)
        bubbleWidthConstraint = shadowHost.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        bubbleEqualWidthConstraint = shadowHost.widthAnchor.constraint(equalToConstant: 320)
        bubbleEqualWidthConstraint.priority = .required - 1
        textWidthConstraint = textView.widthAnchor.constraint(lessThanOrEqualToConstant: 288)

        bubbleStackTopConstraint = bubbleStack.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 14)
        bubbleStackLeadingConstraint = bubbleStack.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: OriveoTheme.Spacing.lg)
        bubbleStackTrailingConstraint = bubbleStack.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -OriveoTheme.Spacing.lg)
        bubbleStackBottomConstraint = bubbleStack.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -14)

        NSLayoutConstraint.activate([
            topPaddingConstraint,
            shadowHost.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            shadowHost.trailingAnchor.constraint(equalTo: avatarView.leadingAnchor, constant: -OriveoTheme.Spacing.sm),
            shadowHost.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: OriveoTheme.Spacing.xl),

            avatarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -OriveoTheme.Spacing.xl),
            avatarView.centerYAnchor.constraint(equalTo: shadowHost.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),

            bubbleView.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            bubbleView.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            bubbleView.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            bubbleView.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),

            bubbleStackTopConstraint,
            bubbleStackLeadingConstraint,
            bubbleStackTrailingConstraint,
            bubbleStackBottomConstraint,

            bubbleWidthConstraint,
            textWidthConstraint,
        ])
    }

    private func updateShadow() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        shadowHost.layer.shadowColor = UIColor(OriveoTheme.Palette.primaryGlow).cgColor
        shadowHost.layer.shadowOpacity = isDark ? 0.7 : 0.9
        shadowHost.layer.shadowRadius = isDark ? 22 : 10
        shadowHost.layer.shadowOffset = CGSize(width: 0, height: isDark ? 4 : 6)
    }

    private func configureAttachments(
        _ attachments: [Attachment],
        immersiveHero: Bool,
        hasText: Bool,
        parentViewController: UIViewController
    ) {
        let attachmentView = AnyView(
            UserAttachmentsGroup(
                attachments: attachments,
                immersiveHero: immersiveHero,
                hasText: hasText
            )
        )
        if let host = attachmentHostingController {
            host.rootView = attachmentView
        } else {
            let host = UIHostingController(rootView: attachmentView)
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            parentViewController.addChild(host)
            bubbleStack.insertArrangedSubview(host.view, at: quoteHostingController == nil ? 0 : 1)
            host.didMove(toParent: parentViewController)
            attachmentHostingController = host
        }
    }

    private func tearDownAttachmentHost() {
        guard let host = attachmentHostingController else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        bubbleStack.removeArrangedSubview(host.view)
        host.removeFromParent()
        attachmentHostingController = nil
    }

    private func configureQuote(_ quote: QuoteContext?, parentViewController: UIViewController) {
        guard let quote else {
            tearDownQuoteHost()
            return
        }
        let quoteView = AnyView(QuoteContextChip(
            quote: quote,
            presentation: .sentMessage
        ))
        if let host = quoteHostingController {
            host.rootView = quoteView
        } else {
            let host = UIHostingController(rootView: quoteView)
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            parentViewController.addChild(host)
            bubbleStack.insertArrangedSubview(host.view, at: 0)
            host.didMove(toParent: parentViewController)
            quoteHostingController = host
        }
    }

    private func tearDownQuoteHost() {
        guard let host = quoteHostingController else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        bubbleStack.removeArrangedSubview(host.view)
        host.removeFromParent()
        quoteHostingController = nil
    }

    @objc private func savedNoteReferenceTapped() {
        onOpenNoteReferences?()
    }
}

extension UserMessageCell: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        if shouldYieldContextMenuToTextSelection(at: location) {
            return nil
        }

        let hasCopyableText = !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasCopyableText || onSaveNote != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = []
            if hasCopyableText {
                actions.append(UIAction(
                    title: L10n.tr("Copy"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = self?.currentText
                })
            }
            if self?.onSaveNote != nil {
                actions.append(UIAction(
                    title: L10n.tr("Save as Note", table: .notes),
                    image: UIImage(systemName: "note.text.badge.plus")
                ) { _ in
                    self?.onSaveNote?()
                })
            }
            return UIMenu(title: "", children: actions)
        }
    }

    private func shouldYieldContextMenuToTextSelection(at location: CGPoint) -> Bool {
        guard !textView.isHidden, textView.isSelectable else { return false }

        let textLocation = textView.convert(location, from: bubbleView)
        return textView.bounds.contains(textLocation)
    }
}
