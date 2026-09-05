import SwiftUI
import UIKit

@MainActor
final class AssistantStreamingCodeRenderer {
 /// shadow :bounds shadowPath--, shadowPath
    private final class ShadowContainerView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 16).cgPath
        }
    }

    let view: UIView = ShadowContainerView()

    private let contentContainer = UIView()
    private let headerBar = UIView()
    private let languageIcon = UIImageView()
    private let languageLabel = UILabel()
    private let textView = ChatPassiveTextView()

    private static let maxHeight: CGFloat = UIKitCodeBlockCard.maxPreviewHeight

    private var textViewHeightConstraint: NSLayoutConstraint!

    private(set) var lastRenderedCode = ""

    private var isHeightCapped = false

    private var highlightedPrefixUTF16 = 0
    private var blockCommentOpen = false
    private var currentLanguage: String?

    var isHidden: Bool {
        view.isHidden
    }

    init() {
        setup()
    }

    func update(language: String?, code: String) {
        let wasHidden = view.isHidden
        view.isHidden = false
        languageLabel.text = (language?.isEmpty == false ? language! : L10n.tr("Code")).uppercased()
        currentLanguage = language

        if !wasHidden, !lastRenderedCode.isEmpty, code.hasPrefix(lastRenderedCode) {
            let appended = String(code.dropFirst(lastRenderedCode.count))
            if !appended.isEmpty {
                let suffix = NSAttributedString(string: appended, attributes: Self.codeAttributes)
                textView.textStorage.beginEditing()
                textView.textStorage.append(suffix)
                textView.textStorage.endEditing()
            }
        } else {
            textView.attributedText = NSAttributedString(string: code, attributes: Self.codeAttributes)
            highlightedPrefixUTF16 = 0
            blockCommentOpen = false
            isHeightCapped = false
        }

        lastRenderedCode = code
        highlightNewlyCompletedLines()

 // cell self-sizing bounds( UIKitCodeBlockCard ).
        if !isHeightCapped {
            let measuredWidth = textView.bounds.width > 0
                ? textView.bounds.width
 : view.bounds.width // layout textView.bounds=0, view.bounds
            let targetWidth = ChatCardStableWidth.anchor(for: view)
                ?? (measuredWidth > 0 ? measuredWidth : UIScreen.main.bounds.width - ChatCardStableWidth.contentChrome)
            let fittingSize = textView.sizeThatFits(CGSize(
                width: targetWidth,
                height: .greatestFiniteMagnitude
            ))
            let newHeight = min(fittingSize.height, Self.maxHeight)
            if abs(textViewHeightConstraint.constant - newHeight) > 0.5 {
                textViewHeightConstraint.constant = newHeight
            }
            if fittingSize.height > Self.maxHeight {
                isHeightCapped = true
            }
        }

        if isHeightCapped, textView.contentSize.height > 0 {
            let bottomY = max(0, textView.contentSize.height - textView.bounds.height)
            if abs(textView.contentOffset.y - bottomY) > 1 {
                textView.contentOffset.y = bottomY
            }
        }
    }

    func hide() {
        guard !view.isHidden else {
            lastRenderedCode = ""
            resetHighlightState()
            return
        }
        view.isHidden = true
        textView.text = nil
        textView.contentOffset = .zero
        textViewHeightConstraint.constant = 0
        lastRenderedCode = ""
        resetHighlightState()
    }

 // MARK: -

    private func resetHighlightState() {
        highlightedPrefixUTF16 = 0
        blockCommentOpen = false
        currentLanguage = nil
        isHeightCapped = false
    }

    private func highlightNewlyCompletedLines() {
        let ns = lastRenderedCode as NSString
        while highlightedPrefixUTF16 < ns.length {
            let searchRange = NSRange(
                location: highlightedPrefixUTF16,
                length: ns.length - highlightedPrefixUTF16
            )
            let nl = ns.range(of: "\n", range: searchRange)
            guard nl.location != NSNotFound else { return }
            let lineRange = NSRange(
                location: highlightedPrefixUTF16,
                length: nl.location - highlightedPrefixUTF16
            )
            applyLineHighlight(lineRange: lineRange, line: ns.substring(with: lineRange))
            highlightedPrefixUTF16 = nl.location + nl.length
        }
    }

    private func applyLineHighlight(lineRange: NSRange, line: String) {
        let highlighted = Self.highlightLine(
            line,
            language: currentLanguage,
            blockCommentOpen: &blockCommentOpen
        )
        guard lineRange.length > 0 else { return }
        guard highlighted.length == lineRange.length,
              lineRange.location + lineRange.length <= textView.textStorage.length else { return }
        textView.textStorage.beginEditing()
        highlighted.enumerateAttributes(
            in: NSRange(location: 0, length: highlighted.length)
        ) { attrs, range, _ in
            textView.textStorage.setAttributes(
                attrs,
                range: NSRange(location: lineRange.location + range.location, length: range.length)
            )
        }
        textView.textStorage.endEditing()
    }

    static func highlightLine(
        _ line: String,
        language: String?,
        blockCommentOpen: inout Bool
    ) -> NSAttributedString {
        let baseColor = MarkdownCodeBlockPalette.foregroundUIColor
        guard let delims = SyntaxHighlighter.blockCommentDelimiters(for: language) else {
            return SyntaxHighlighter.highlightUncached(line, language: language, baseColor: baseColor)
        }
        guard !line.isEmpty else {
            return NSAttributedString(string: line, attributes: Self.codeAttributes)
        }

        let commentAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: MarkdownCodeBlockPalette.commentUIColor,
        ]
        let result = NSMutableAttributedString()
        var rest = Substring(line)
        while !rest.isEmpty {
            if blockCommentOpen {
                if let close = rest.range(of: delims.close) {
                    result.append(NSAttributedString(
                        string: String(rest[..<close.upperBound]), attributes: commentAttrs
                    ))
                    rest = rest[close.upperBound...]
                    blockCommentOpen = false
                } else {
                    result.append(NSAttributedString(string: String(rest), attributes: commentAttrs))
                    rest = rest[rest.endIndex...]
                }
            } else {
                if let open = rest.range(of: delims.open) {
                    let before = String(rest[..<open.lowerBound])
                    if !before.isEmpty {
                        result.append(SyntaxHighlighter.highlightUncached(
                            before, language: language, baseColor: baseColor
                        ))
                    }
                    rest = rest[open.lowerBound...]
                    blockCommentOpen = true
                } else {
                    result.append(SyntaxHighlighter.highlightUncached(
                        String(rest), language: language, baseColor: baseColor
                    ))
                    rest = rest[rest.endIndex...]
                }
            }
        }
        return result
    }

 /// - Parameter fullContent: (committed segment.content).chunker
 /// codeChunk "+ fence "(codeChunkBoundary clamp
 /// harvest/instant backlog ( spring+plain).
    func harvestAttributedCodeForHandoff(fullContent: String) -> NSAttributedString? {
        guard !view.isHidden, !lastRenderedCode.isEmpty,
              fullContent.hasPrefix(lastRenderedCode) else { return nil }
        if fullContent != lastRenderedCode {
            update(language: currentLanguage, code: fullContent)
        }
        guard textView.textStorage.length > 0 else { return nil }
        let ns = lastRenderedCode as NSString
        if highlightedPrefixUTF16 < ns.length {
            let lineRange = NSRange(
                location: highlightedPrefixUTF16,
                length: ns.length - highlightedPrefixUTF16
            )
            applyLineHighlight(lineRange: lineRange, line: ns.substring(with: lineRange))
            highlightedPrefixUTF16 = ns.length
        }
        return NSAttributedString(attributedString: textView.textStorage)
    }

    #if DEBUG
    var _testAttributedCode: NSAttributedString {
        NSAttributedString(attributedString: textView.textStorage)
    }
    #endif

    private static var codeAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: MarkdownCodeBlockPalette.foregroundUIColor,
        ]
    }

    private func setup() {
        let codeBg = MarkdownCodeBlockPalette.backgroundUIColor
        let headerBg = MarkdownCodeBlockPalette.surfaceUIColor
        let borderColor = MarkdownCodeBlockPalette.borderUIColor
        let textFg = MarkdownCodeBlockPalette.foregroundUIColor
        let secondaryFg = MarkdownCodeBlockPalette.secondaryUIColor

        view.isHidden = true
        view.backgroundColor = .clear
        view.clipsToBounds = false
        view.layer.masksToBounds = false
        view.layer.shadowColor = UIColor(OriveoTheme.Palette.shadow).cgColor
        view.layer.shadowOpacity = 0.18
        view.layer.shadowRadius = 14
        view.layer.shadowOffset = CGSize(width: 0, height: 8)

        contentContainer.backgroundColor = codeBg
        contentContainer.layer.cornerRadius = 16
        contentContainer.layer.cornerCurve = .continuous
        contentContainer.layer.borderWidth = 1
        contentContainer.layer.borderColor = borderColor.cgColor
        contentContainer.clipsToBounds = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        headerBar.backgroundColor = headerBg
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(headerBar)

        let capsule = UIView()
        capsule.backgroundColor = headerBg
        capsule.layer.cornerRadius = 12
        capsule.layer.cornerCurve = .continuous
        capsule.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(capsule)

        languageIcon.image = UIImage(systemName: "curlybraces")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        languageIcon.tintColor = secondaryFg
        languageIcon.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(languageIcon)

        languageLabel.font = .systemFont(ofSize: 12)
        languageLabel.textColor = textFg
        languageLabel.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(languageLabel)

        textView.isEditable = false
 // ****:.`isScrollEnabled = false` textView
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = true
        textView.showsHorizontalScrollIndicator = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = textFg
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(textView)

        textViewHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 0)
        textViewHeightConstraint.priority = .required

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            headerBar.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 44),

            capsule.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),
            capsule.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            capsule.heightAnchor.constraint(equalToConstant: 28),

            languageIcon.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 10),
            languageIcon.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),

            languageLabel.leadingAnchor.constraint(equalTo: languageIcon.trailingAnchor, constant: 8),
            languageLabel.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -10),
            languageLabel.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),

            textView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            textViewHeightConstraint,
        ])
    }
}
