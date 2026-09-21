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

// MARK: - Text host and measurement cache

/// Hosts the user bubble text: the UITextView is laid out by frame, and its size comes from the host's
/// intrinsicContentSize.
///
/// Why the text view does not join Auto Layout itself: when a non-scrolling UITextView takes part in constraints,
/// both constraint update passes compute its baseline (`_updateBaselineInformationDependentOnBounds →
/// _baselineOffsetsAtSize:`), and every time that means setting a size, invalidating the whole TextKit container,
/// laying out to the last line and restoring the size. A new cell laid the full text out about 5.5 times just to
/// appear, and every size change another 4–5 times; with one long pasted paragraph each pass took seconds. Out of
/// the constraint engine the baseline work is gone, and the height comes from a single measurement in an offscreen
/// text view of the same class (`UserBubbleTextLayout`), cached per message and reused across cell reuse.
private final class UserBubbleTextHost: UIView {
    let textView = ChatPassiveTextView()

    var measuredSize: CGSize = .zero {
        didSet {
            guard measuredSize != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.translatesAutoresizingMaskIntoConstraints = true
        textView.autoresizingMask = []
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { measuredSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        if textView.frame != bounds {
            textView.frame = bounds
        }
    }
}

/// Display string and size of the user bubble text, shared across cells. The display string only depends on the
/// message content and is cached by (message id, textHash); sizes are cached separately by (display string, pixel
/// width, insets, hug), so rotation or split view never rebuilds the display string or resets the whole text.
///
/// Display string = overlong paragraphs first get their first-strong direction pinned, then are soft-split with
/// U+2029 into display paragraphs of at most `SoftParagraphBreaks.maxParagraphUTF16` (in this order: splitting first
/// would make every chunk resolve its own direction). Paragraphs that are not split stay `.natural` and lay out
/// exactly as before. Without the split, every layout pass of one unbroken pasted paragraph redoes bidi and shaping
/// for all of it.
/// Known trade-off (same as the bounded note viewport): the system Share / Look Up / Translate / Speak actions still
/// receive the display string with its soft breaks.
enum UserBubbleTextLayout {
    private static let displayCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 64
        return cache
    }()

    private static let sizeCache: NSCache<NSString, NSValue> = {
        let cache = NSCache<NSString, NSValue>()
        cache.countLimit = 128
        return cache
    }()

    static func displayKey(messageID: UUID, textHash: Int) -> String {
        "\(messageID.uuidString)|\(textHash)"
    }

    static func display(forKey key: String, text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        if let hit = displayCache.object(forKey: key as NSString) { return hit }
        let display = displayText(text, attributes: attributes)
        displayCache.setObject(display, forKey: key as NSString)
        return display
    }

    /// `maxWidth` must already sit on the pixel grid: the cache key, the measurement and the constraint share that one
    /// value, so two widths in the same bucket can never reuse the wrong height.
    static func size(
        displayKey: String,
        display: NSAttributedString,
        maxWidth: CGFloat,
        insets: UIEdgeInsets,
        hug: Bool,
        scale: CGFloat
    ) -> CGSize {
        let key = "\(displayKey)|\(Int((maxWidth * scale).rounded()))|\(insets.top),\(insets.left),\(insets.bottom),\(insets.right)|\(hug)" as NSString
        if let hit = sizeCache.object(forKey: key) { return hit.cgSizeValue }
        let size = measure(display, maxWidth: maxWidth, insets: insets, hug: hug)
        sizeCache.setObject(NSValue(cgSize: size), forKey: key)
        return size
    }

    static func displayText(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let string = NSMutableAttributedString(string: SoftParagraphBreaks.normalized(text), attributes: attributes)
        SoftParagraphBreaks.pinDirectionOfOverlongParagraphs(in: string)
        // Don't fixAttributes up front: once the fallback font (SF Arabic and so on) is written into the attributes,
        // TextKit uses that font's line height and Arabic line spacing grows from 22.0 to 23.2 pt (the text view's
        // own storage used to handle font fallback, and still does).
        return SoftParagraphBreaks.insertingBreaks(into: string)
    }

    /// The offscreen text view used for measuring: the same class and storage as the `ChatPassiveTextView` in the
    /// bubble. Scrolling is on so the container height is unlimited and the whole text is laid out in one go.
    ///
    /// Only a text view of the same class lays text out exactly as the bubble shows it (measured with Arabic, in pt):
    /// - a standalone NSTextStorage + NSLayoutManager substitutes fonts eagerly and uses the fallback font's line
    ///   height: 23.2 per line (100 characters: 115.8 vs the real 110.0);
    /// - boundingRect matches the text view point for point on short strings (22.0 per line) but switches to another
    ///   internal path on long ones: 20K characters measured 15796 vs the real 11286, leaving 4500 pt of blank space.
    private static let measuringView: ChatPassiveTextView = {
        let view = ChatPassiveTextView()
        view.isScrollEnabled = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        return view
    }()

    /// hug: the width is the text's natural width (capped at maxWidth); otherwise it fills maxWidth. The text view's
    /// lineFragmentPadding is always 0.
    static func measure(_ display: NSAttributedString, maxWidth: CGFloat, insets: UIEdgeInsets, hug: Bool) -> CGSize {
        let horizontal = insets.left + insets.right
        let vertical = insets.top + insets.bottom
        guard display.length > 0 else { return CGSize(width: hug ? 0 : maxWidth, height: vertical) }
        let view = measuringView
        view.frame = CGRect(x: 0, y: 0, width: max(1, maxWidth - horizontal), height: 100)
        view.attributedText = display
        view.layoutManager.ensureLayout(for: view.textContainer)
        let used = view.layoutManager.usedRect(for: view.textContainer)
        // Don't let the offscreen view keep holding tens of thousands of characters.
        view.attributedText = nil
        let width = hug ? min(ceil(used.width) + horizontal, maxWidth) : maxWidth
        return CGSize(width: width, height: ceil(used.height) + vertical)
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
    private let textHost = UserBubbleTextHost()
    private var textView: ChatPassiveTextView { textHost.textView }
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
    /// Key (message id + textHash) of the display string currently in the text view; reconfiguring the same message
    /// skips resetting the whole string, which would lay the full paragraph out again.
    private var appliedDisplayKey: String?

    /// Minimum bubble leading margin Spacing.xl (24) + bubble-to-avatar gap Spacing.sm (8) + avatar 36 + avatar
    /// trailing margin Spacing.xl (24), one for one with the four constraints in setupViews (a literal so the
    /// nonisolated row height estimate can use it too). The real bubble width = cell width − this; measurement has
    /// to use it, or it counts too few lines and the last lines get clipped.
    nonisolated static let horizontalChrome: CGFloat = 24 + 8 + 36 + 24

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
        appliedDisplayKey = nil
        textView.onSaveSelection = nil
        textView.onAskSelection = nil
        textView.onReplaceSelection = nil
        textView.text = nil
        textView.attributedText = nil
        textView.isHidden = false
        textHost.isHidden = false
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

        // The limit is also bounded by the cell's real width (the bubble's leading >= xl is required): on a 393 pt wide
        // phone the bubble is at most 301, and measuring at 320 counts too few lines and clips the end of long messages.
        let availableBubbleWidth = contentView.bounds.width > Self.horizontalChrome
            ? min(maxBubbleWidth, contentView.bounds.width - Self.horizontalChrome)
            : maxBubbleWidth
        let rawBubbleWidth: CGFloat = {
            guard isImmersiveHero,
                  let img = attachments.first(where: { $0.kind == .image }) else {
                return availableBubbleWidth
            }
            let aspect = CachedAttachmentImage.preferredAspectRatio(
                for: img,
                partitionUID: AppSessionStore.activeUID
            )
            let heroMaxHeight: CGFloat = 240
            return min(availableBubbleWidth, heroMaxHeight * aspect)
        }()
        // Snap to the pixel grid: the measurement cache key, the measured width and the constraint share one value
        // (see UserBubbleTextLayout.size).
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
        let effectiveBubbleWidth = (rawBubbleWidth * scale).rounded(.down) / scale

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
            let insets = isImmersiveHero
                ? UIEdgeInsets(top: 8, left: OriveoTheme.Spacing.lg, bottom: 14, right: OriveoTheme.Spacing.lg)
                : .zero
            textWidthConstraint.constant = isImmersiveHero
                ? effectiveBubbleWidth
                : (effectiveBubbleWidth - OriveoTheme.Spacing.lg * 2)
            let hugText = attachments.isEmpty && quoteContext == nil
            let displayKey = UserBubbleTextLayout.displayKey(messageID: model.messageID, textHash: model.textHash)
            let display = UserBubbleTextLayout.display(
                forKey: displayKey,
                text: text,
                attributes: [
                    .font: userFont,
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: userParagraph,
                ]
            )
            let size = UserBubbleTextLayout.size(
                displayKey: displayKey,
                display: display,
                maxWidth: textWidthConstraint.constant,
                insets: insets,
                hug: hugText,
                scale: scale
            )
            // Reconfiguring the same message (stream finished, metadata refreshed) or changing width never resets the
            // whole string: a reset makes TextKit lay out the full paragraph again.
            if appliedDisplayKey != displayKey {
                textView.attributedText = display
                appliedDisplayKey = displayKey
            }
            if textView.textContainerInset != insets {
                textView.textContainerInset = insets
            }
            textView.isHidden = false
            textHost.isHidden = false
            textHost.measuredSize = size
            textHost.setContentHuggingPriority(hugText ? .defaultHigh : .defaultLow, for: .horizontal)
            if hugText {
                bubbleEqualWidthConstraint.constant = size.width + OriveoTheme.Spacing.lg * 2
            } else {
                bubbleEqualWidthConstraint.constant = effectiveBubbleWidth
            }
            bubbleEqualWidthConstraint.isActive = true
        } else {
            textView.isHidden = true
            textHost.isHidden = true
            textHost.measuredSize = .zero
            textView.textContainerInset = .zero
            appliedDisplayKey = nil
            textWidthConstraint.constant = effectiveBubbleWidth - (OriveoTheme.Spacing.lg * 2)
            textHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
        // No non-contiguous layout: on a non-scrolling text view whose height is measured outside, it lays out the
        // middle at estimated positions, and the usedRect estimate can make contentSize larger than the bounds and
        // scroll programmatically when a selection reaches the edge. The host and soft breaks already fix the stall.
        // Copy / Save as Note / Ask on a selection must get the source text, without the display-only soft breaks.
        textView.stripsSoftParagraphBreaks = true
        textHost.translatesAutoresizingMaskIntoConstraints = false
        textHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Vertical compression resistance stays at the default 750 (as the text view had): it is the relief valve for
        // the frames where the cell height lags behind the natural height. shadowHost.bottom is required, and with both
        // required the constraints have no solution and UIKit breaks one at random.
        textHost.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        textHost.setContentHuggingPriority(.required, for: .vertical)
        bubbleStack.addArrangedSubview(textHost)

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
        textWidthConstraint = textHost.widthAnchor.constraint(lessThanOrEqualToConstant: 288)

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
