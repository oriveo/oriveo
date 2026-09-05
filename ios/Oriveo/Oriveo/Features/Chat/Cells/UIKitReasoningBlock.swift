import SwiftUI
import UIKit

final class UIKitReasoningBlock: UIView {


    private static let chatBodyMinus1ptSize: CGFloat = 15
    private static let headerFontSize: CGFloat = 13         // footnote
    private static let decorationLineWidth: CGFloat = 2
    private static let pulseAnimationKey = "reasoningPulse"

    // MARK: - Subviews

    private let containerStack = UIStackView()
    private let decorationLine = UIView()
    private let contentStack = UIStackView()
    private let headerButton = UIButton(type: .system)
    private let pulseDot = UIView()
    private let chevronIcon = UIImageView()
    private let headerTitleLabel = UILabel()
    private let contentContainer = UIView()
    private let contentTextView = ReasoningContentTextView()


    private var finalReasoningText: String = ""
    private var streamingPreviewSource: String = ""
    private var streamingMessageID: UUID?
    private var streamingSendTaskID: UUID?
    private var streamingRevision: UInt64 = 0
    private var hasStreamingContent = false
    private var transientStreamingSnapshot: String?
    private var durationMs: Int64?
    private var isStreaming: Bool = false
    private var userExpanded: Bool?
    private var autoExpanded: Bool = false
    private var isExpanded: Bool { userExpanded ?? autoExpanded }
    private var renderGeneration: UInt = 0

    private enum ContentRenderMode {
        case collapsedTail
        case expandedStreamingCanonical
        case expandedFinal
    }
    private var contentRenderMode: ContentRenderMode?
    private var canonicalStream = ReasoningCanonicalStream()
    private var lastNotifiedContentHeight: CGFloat = -1
    private var lastAppliedExpanded: Bool?
    private var lastHeaderTitle: String?
    private var lastAppliedStreamingVisualState: Bool?
    private var lastCollapsedPreview: String?

    var onLayoutChange: (() -> Void)?

    var onHeightDidChange: (() -> Void)?

    var onRequestStreamingSnapshot: (() -> Void)?

    #if DEBUG
    var _testContentRenderCount = 0
    var _testStreamFullReplaceCount = 0
    var _testStreamAppendCount = 0
    var _testContentPlainText: String {
        contentTextView.textStorage.string
    }
    var _testStreamingPreviewUTF8Count: Int { streamingPreviewSource.utf8.count }
    var _testHeaderTitle: String? { headerTitleLabel.text }
    var _testStreamingRevision: UInt64 { streamingRevision }
    var _testIsExpanded: Bool { isExpanded }
    func _testTapHeader() { headerTapped() }
    #endif

    private lazy var streamingSingleLineHeight: NSLayoutConstraint =
        contentContainer.heightAnchor.constraint(
            equalToConstant: ceil(UIFont.systemFont(ofSize: Self.chatBodyMinus1ptSize).lineHeight))

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var ovDebugState: String {
        "stream=\(isStreaming ? "Y" : "N") hidden=\(contentContainer.isHidden ? "Y" : "N")"
            + " contentH=\(Int(contentContainer.frame.height)) lines=\(contentTextView.textContainer.maximumNumberOfLines)"
    }

    // MARK: - Public API

    func resetForReuse() {
        finalReasoningText = ""
        streamingPreviewSource = ""
        streamingMessageID = nil
        streamingSendTaskID = nil
        streamingRevision = 0
        hasStreamingContent = false
        transientStreamingSnapshot = nil
        durationMs = nil
        isStreaming = false
        userExpanded = nil
        autoExpanded = false
        renderGeneration &+= 1
        contentTextView.textStorage.setAttributedString(NSAttributedString())
        contentRenderMode = nil
        canonicalStream.reset()
        lastNotifiedContentHeight = -1
        lastAppliedExpanded = nil
        lastHeaderTitle = nil
        lastAppliedStreamingVisualState = nil
        lastCollapsedPreview = nil
        stopPulseAnimation()
        isHidden = true
    }

    /// - Parameters:
    func configure(
        text: String,
        durationMs: Int64?,
        isStreaming: Bool,
        hasMainText: Bool
    ) {
        if isStreaming {
            applyLegacyStreamingSnapshot(text)
            return
        }
        guard text.contains(where: { !$0.isWhitespace }) else {
            resetForReuse()
            return
        }

        let textChanged = text != finalReasoningText
        let durationChanged = durationMs != self.durationMs
        let streamingChanged = isStreaming != self.isStreaming

        finalReasoningText = text
        streamingPreviewSource = ""
        streamingMessageID = nil
        streamingSendTaskID = nil
        streamingRevision = 0
        hasStreamingContent = false
        self.durationMs = durationMs
        self.isStreaming = isStreaming

        autoExpanded = false

        isHidden = false

        if textChanged || streamingChanged {
            updateContent()
        }
        if textChanged || durationChanged || streamingChanged {
            updateHeader()
        }
        applyExpansionState(animated: false, notifyLayout: false)
        applyVisualState()

        if isStreaming {
            startPulseAnimationIfNeeded()
        } else {
            stopPulseAnimation()
        }
    }

    func applyStreamingSnapshot(_ snapshot: ReasoningStreamSnapshot?) {
        let nextMessageID = snapshot?.messageID
        let nextSendTaskID = snapshot?.sendTaskID
        let text = snapshot?.text ?? ""
        let hasContent = text.contains(where: { !$0.isWhitespace })
        let messageChanged = streamingMessageID != nil && streamingMessageID != nextMessageID
        let taskChanged = streamingSendTaskID != nil && streamingSendTaskID != nextSendTaskID

        if messageChanged || (taskChanged && !hasContent) {
            userExpanded = nil
            autoExpanded = false
        }

        finalReasoningText = ""
        durationMs = nil
        isStreaming = true
        autoExpanded = false
        streamingMessageID = nextMessageID
        streamingSendTaskID = nextSendTaskID
        streamingRevision = snapshot?.revision ?? 0
        hasStreamingContent = hasContent
        streamingPreviewSource = ReasoningPreviewText.boundedSuffix(of: text)
        transientStreamingSnapshot = text
        isHidden = !hasStreamingContent

        if hasStreamingContent {
            updateHeader()
            let previouslyAppliedExpansion = lastAppliedExpanded
            applyExpansionState(animated: false, notifyLayout: false)
            if previouslyAppliedExpansion == nil || previouslyAppliedExpansion == isExpanded {
                updateContent()
            }
            applyVisualState()
            startPulseAnimationIfNeeded()
        } else {
            contentTextView.textStorage.setAttributedString(NSAttributedString())
            contentRenderMode = nil
            lastCollapsedPreview = nil
        }
        transientStreamingSnapshot = nil
    }

    func appendStreamingDelta(_ event: ReasoningStreamDelta) {
        guard event.messageID == streamingMessageID,
              event.sendTaskID == streamingSendTaskID,
              event.revision > streamingRevision else { return }
        streamingRevision = event.revision
        streamingPreviewSource = ReasoningPreviewText.appendingToBoundedSuffix(
            streamingPreviewSource,
            delta: event.delta
        )

        let becameVisible = !hasStreamingContent
        if becameVisible {
            hasStreamingContent = true
            isHidden = false
            updateHeader()
            applyVisualState()
            applyExpansionState(animated: false, notifyLayout: false)
            startPulseAnimationIfNeeded()
        }
        guard hasStreamingContent else { return }

        if isExpanded {
            guard contentRenderMode == .expandedStreamingCanonical else {
                onRequestStreamingSnapshot?()
                return
            }
            guard let piece = canonicalStream.consume(event.delta) else { return }
            contentTextView.textStorage.append(Self.reasoningStyled(piece))
            #if DEBUG
            _testStreamAppendCount += 1
            #endif
            contentTextView.invalidateIntrinsicContentSize()
            notifyHeightChangeIfNeeded()
        } else {
            updateContent()
        }
    }

    private func applyLegacyStreamingSnapshot(_ text: String) {
        let snapshot = ReasoningStreamSnapshot(
            messageID: streamingMessageID ?? UUID(),
            sendTaskID: streamingSendTaskID ?? UUID(),
            revision: streamingRevision,
            text: text
        )
        applyStreamingSnapshot(snapshot)
    }

    // MARK: - Setup

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isHidden = true

        containerStack.axis = .horizontal
        containerStack.alignment = .fill
        containerStack.spacing = OriveoTheme.Spacing.sm
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerStack)
        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor),
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        decorationLine.translatesAutoresizingMaskIntoConstraints = false
        decorationLine.layer.cornerRadius = Self.decorationLineWidth / 2
        decorationLine.widthAnchor.constraint(equalToConstant: Self.decorationLineWidth).isActive = true
        decorationLine.setContentHuggingPriority(.required, for: .horizontal)
        decorationLine.setContentCompressionResistancePriority(.required, for: .horizontal)
        containerStack.addArrangedSubview(decorationLine)

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = OriveoTheme.Spacing.xs
        containerStack.addArrangedSubview(contentStack)

        setupHeaderButton()
        contentStack.addArrangedSubview(headerButton)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentTextView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(contentTextView)
        NSLayoutConstraint.activate([
            contentTextView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            contentTextView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            contentTextView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentTextView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        contentStack.addArrangedSubview(contentContainer)
    }

    private static let headerRowHeight: CGFloat =
        ceil(UIFont.systemFont(ofSize: headerFontSize, weight: .medium).lineHeight) + 8

    private func setupHeaderButton() {
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.contentHorizontalAlignment = .leading
        headerButton.titleLabel?.numberOfLines = 1
        headerButton.addTarget(self, action: #selector(headerTapped), for: .touchUpInside)
        headerButton.isAccessibilityElement = true
        headerButton.accessibilityTraits = .button
        headerButton.heightAnchor.constraint(equalToConstant: Self.headerRowHeight).isActive = true

        let headerStack = UIStackView()
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 6
        headerStack.isUserInteractionEnabled = false
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerButton.addSubview(headerStack)
        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: headerButton.leadingAnchor),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: headerButton.trailingAnchor),
            headerStack.topAnchor.constraint(equalTo: headerButton.topAnchor, constant: 2),
            headerStack.bottomAnchor.constraint(equalTo: headerButton.bottomAnchor, constant: -2),
        ])

        pulseDot.backgroundColor = UIColor(OriveoTheme.Palette.primary)
        pulseDot.layer.cornerRadius = 4
        pulseDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pulseDot.widthAnchor.constraint(equalToConstant: 8),
            pulseDot.heightAnchor.constraint(equalToConstant: 8),
        ])
        headerStack.addArrangedSubview(pulseDot)

        let chevronImage = UIImage(systemName: "chevron.right")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            .imageFlippedForRightToLeftLayoutDirection()
        chevronIcon.image = chevronImage
        chevronIcon.tintColor = UIColor(OriveoTheme.Palette.textTertiary)
        chevronIcon.contentMode = .scaleAspectFit
        chevronIcon.setContentHuggingPriority(.required, for: .horizontal)
        chevronIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevronIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chevronIcon.widthAnchor.constraint(equalToConstant: 12),
            chevronIcon.heightAnchor.constraint(equalToConstant: 12),
        ])
        headerStack.addArrangedSubview(chevronIcon)

        headerTitleLabel.font = UIFont.systemFont(ofSize: Self.headerFontSize, weight: .medium)
        headerTitleLabel.textColor = UIColor(OriveoTheme.Palette.textSecondary)
        headerStack.addArrangedSubview(headerTitleLabel)
    }


    private func updateHeader() {
        let title: String
        if isStreaming {
            title = L10n.tr("Thinking…", table: .chat)
        } else if let durationMs, durationMs > 0 {
            title = String(format: L10n.tr("Thought for %@", table: .chat), Self.formatDuration(ms: durationMs))
        } else {
            title = isExpanded ? L10n.tr("Hide thinking", table: .chat) : L10n.tr("Show thinking", table: .chat)
        }
        let accessibilityValue = isExpanded
            ? L10n.tr("Hide thinking", table: .chat)
            : L10n.tr("Show thinking", table: .chat)
        let headerKey = title + "\u{1F}" + accessibilityValue
        guard headerKey != lastHeaderTitle else { return }
        lastHeaderTitle = headerKey

        headerTitleLabel.text = title
        headerButton.accessibilityLabel = title
        headerButton.accessibilityValue = accessibilityValue

        pulseDot.isHidden = !isStreaming
        chevronIcon.isHidden = false
    }

    private static let plainContentAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: chatBodyMinus1ptSize),
        .foregroundColor: UIColor(OriveoTheme.Palette.textSecondary),
    ]

    private var plainContentAttributes: [NSAttributedString.Key: Any] { Self.plainContentAttributes }

    private func updateContent() {
        #if DEBUG
        _testContentRenderCount += 1
        #endif
        if !isExpanded {
            contentRenderMode = .collapsedTail
            lastNotifiedContentHeight = -1
            renderGeneration &+= 1
            let previewSource = isStreaming ? streamingPreviewSource : finalReasoningText
            let preview = ReasoningPreviewText.previewLine(of: previewSource)
            if preview.isEmpty, lastCollapsedPreview != nil { return }
            guard preview != lastCollapsedPreview else { return }
            lastCollapsedPreview = preview
            contentTextView.textStorage.setAttributedString(
                NSAttributedString(string: preview, attributes: plainContentAttributes))
            contentTextView.invalidateIntrinsicContentSize()
            return
        }
        lastCollapsedPreview = nil

        if isStreaming {
            guard let snapshot = transientStreamingSnapshot else { return }
            canonicalStream.reset()
            let rebuilt = canonicalStream.consume(snapshot).map(Self.reasoningStyled)
            contentTextView.textStorage.setAttributedString(rebuilt ?? NSAttributedString())
            contentRenderMode = .expandedStreamingCanonical
            #if DEBUG
            _testStreamFullReplaceCount += 1
            #endif
            contentTextView.invalidateIntrinsicContentSize()
            notifyHeightChangeIfNeeded()
            renderGeneration &+= 1
            return
        }

        let previousRenderMode = contentRenderMode
        contentRenderMode = .expandedFinal
        let text = finalReasoningText
        if let cached = MarkdownAttributedStringRenderer.cachedRender(for: text) {
            renderGeneration &+= 1
            applyContentAttributedText(cached)
            return
        }
        let hasCanonicalContentOnScreen =
            previousRenderMode == .expandedStreamingCanonical && contentTextView.textStorage.length > 0
        if !hasCanonicalContentOnScreen {
            contentTextView.textStorage.setAttributedString(
                NSAttributedString(string: text, attributes: plainContentAttributes))
            contentTextView.invalidateIntrinsicContentSize()
            notifyHeightChangeIfNeeded()
        }
        renderGeneration &+= 1
        let generation = renderGeneration
        MarkdownAttributedStringRenderer.renderAsync(text) { [weak self] rendered in
            guard let self, self.renderGeneration == generation else { return }
            self.applyContentAttributedText(rendered)
        }
    }

    private func notifyHeightChangeIfNeeded() {
        guard isExpanded else { return }
        let h = contentTextView.intrinsicContentSize.height
        guard h >= 0, abs(h - lastNotifiedContentHeight) > 0.5 else { return }
        lastNotifiedContentHeight = h
        onHeightDidChange?()
    }

    static func reasoningStyled(_ original: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: original)
        let range = NSRange(location: 0, length: mutable.length)
        guard range.length > 0 else { return mutable }
        mutable.enumerateAttribute(.font, in: range, options: []) { value, attrRange, _ in
            let baseFont = (value as? UIFont) ?? UIFont.systemFont(ofSize: chatBodyMinus1ptSize)
            let descriptor = baseFont.fontDescriptor
            let smaller = UIFont(descriptor: descriptor, size: max(baseFont.pointSize - 1, 11))
            mutable.addAttribute(.font, value: smaller, range: attrRange)
        }
        mutable.addAttribute(
            .foregroundColor,
            value: UIColor(OriveoTheme.Palette.textSecondary),
            range: range
        )
        return mutable
    }

    private func applyContentAttributedText(_ original: NSAttributedString) {
        let mutable = Self.reasoningStyled(original)
        contentTextView.textStorage.setAttributedString(mutable)
        contentTextView.invalidateIntrinsicContentSize()
        notifyHeightChangeIfNeeded()
    }


    @objc private func headerTapped() {
        let target = !isExpanded
        userExpanded = target
        updateHeader()
        applyExpansionState(animated: true, notifyLayout: true)
        if target, isStreaming {
            onRequestStreamingSnapshot?()
        }
    }

    private func applyExpansionState(animated: Bool, notifyLayout: Bool) {
        let expanded = isExpanded
        let stateChanged = expanded != lastAppliedExpanded
        let isFirstApply = lastAppliedExpanded == nil
        guard stateChanged else { return }
        lastAppliedExpanded = expanded
        contentContainer.isHidden = false
        contentContainer.accessibilityElementsHidden = false
        contentTextView.textContainer.maximumNumberOfLines = expanded ? 0 : 1
        contentTextView.textContainer.lineBreakMode = expanded ? .byWordWrapping : .byClipping
        streamingSingleLineHeight.isActive = !expanded

        if !isFirstApply {
            updateContent()
        }

        let targetTransform: CGAffineTransform = expanded
            ? CGAffineTransform(rotationAngle: .pi / 2)
            : .identity
        let shouldAnimate = animated && !UIAccessibility.isReduceMotionEnabled
        if shouldAnimate {
            UIView.animate(withDuration: 0.2) { [weak self] in
                self?.chevronIcon.transform = targetTransform
            }
        } else {
            chevronIcon.transform = targetTransform
        }

        if notifyLayout {
            onLayoutChange?()
        }
    }

    private static let streamingDecorationColor =
        UIColor(OriveoTheme.Palette.primary).withAlphaComponent(0.3)
    private static let idleDecorationColor =
        UIColor(OriveoTheme.Palette.textTertiary).withAlphaComponent(0.2)

    private func applyVisualState() {
        guard isStreaming != lastAppliedStreamingVisualState else { return }
        lastAppliedStreamingVisualState = isStreaming
        decorationLine.backgroundColor = isStreaming
            ? Self.streamingDecorationColor
            : Self.idleDecorationColor
    }


    private func startPulseAnimationIfNeeded() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            pulseDot.alpha = 1
            return
        }
        guard pulseDot.layer.animation(forKey: Self.pulseAnimationKey) == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.35
        animation.duration = 0.8
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulseDot.layer.add(animation, forKey: Self.pulseAnimationKey)
    }

    private func stopPulseAnimation() {
        pulseDot.layer.removeAnimation(forKey: Self.pulseAnimationKey)
        pulseDot.alpha = 1
    }


    private static func formatDuration(ms: Int64) -> String {
        let seconds = Int(ms / 1000)
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        let s = seconds % 60
        return "\(m)m \(s)s"
    }
}

private final class ReasoningContentTextView: UITextView {

    private var lastIntrinsicWidth: CGFloat = 0

    private let measuringLayoutManager = NSLayoutManager()
    private let measuringContainer = NSTextContainer(
        size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    init() {
        super.init(frame: .zero, textContainer: nil)
        isScrollEnabled = false
        isEditable = false
        isSelectable = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        layoutManager.allowsNonContiguousLayout = false
        contentMode = .topLeft

        measuringContainer.lineFragmentPadding = 0
        measuringLayoutManager.addTextContainer(measuringContainer)
        textStorage.addLayoutManager(measuringLayoutManager)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width
        guard width > 0 else { return super.intrinsicContentSize }
        let targetWidth = width - textContainerInset.left - textContainerInset.right
        if abs(measuringContainer.size.width - targetWidth) > 0.5 {
            measuringContainer.size = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
        }
        if measuringContainer.maximumNumberOfLines != textContainer.maximumNumberOfLines {
            measuringContainer.maximumNumberOfLines = textContainer.maximumNumberOfLines
        }
        measuringLayoutManager.ensureLayout(for: measuringContainer)
        let used = measuringLayoutManager.usedRect(for: measuringContainer)
        let height = ceil(used.height) + textContainerInset.top + textContainerInset.bottom
        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastIntrinsicWidth) > 0.5 {
            lastIntrinsicWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}
