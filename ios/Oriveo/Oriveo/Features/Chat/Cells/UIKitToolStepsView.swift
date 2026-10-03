import SwiftUI
import UIKit

/// The step block for remote MCP tools.
///
/// One header row plus expandable step rows, in permanent slots collapsed through `isHidden`: card corner
/// radius 16, header height 46, minimum row height 44. What to show is decided by the pure function
/// `McpToolStepsPresentation.make`; this view only draws.
@MainActor
final class UIKitToolStepsView: UIView {
    static let cornerRadius: CGFloat = 16
    static let headerHeight: CGFloat = 46
    static let rowMinHeight: CGFloat = 44

    private let contentStack = UIStackView()
    private let headerControl = UIControl()
    private let headerIcon = UIImageView()
    private let titleLabel = UILabel()
    private let trailingLabel = UILabel()
    private let chevronView = UIImageView()
    private let bodyStack = UIStackView()
    private let divider = UIView()
    private let earlierButton = UIButton(type: .system)
    private let rowsStack = UIStackView()
    private let pauseStack = UIStackView()
    private let reauthorizeButton = UIButton(type: .system)
    private let skipButton = UIButton(type: .system)
    private let pauseNoteLabel = UILabel()
    private let limitDivider = UIView()
    private let limitLabel = UILabel()

    private var presentation: McpToolStepsPresentation?
    private var rowViews: [UIKitToolStepRow] = []
    private var hasConfiguredContent = false
    private var userToggledExpansion = false
    private var showsEarlierSteps = false
    private var wasActive = false
    private(set) var isExpanded = false

    var onLayoutChange: (() -> Void)?
    var onSelectStep: ((McpToolStep) -> Void)?
    var onReauthorize: ((McpToolStep) -> Void)?
    var onSkipStep: ((McpToolStep) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(steps: [McpToolStep], isGenerating: Bool, limitReached: Bool = false) {
        guard !steps.isEmpty else {
            resetForReuse()
            return
        }
        let next = McpToolStepsPresentation.make(steps: steps, isGenerating: isGenerating, limitReached: limitReached)
        let previous = presentation
        presentation = next
        isHidden = false

        if !hasConfiguredContent {
            hasConfiguredContent = true
            setExpanded(next.isActive, animated: false, notify: false)
        } else if wasActive, !next.isActive, !userToggledExpansion {
            // Collapses automatically once the answer finishes, unless the user expanded it by hand.
            setExpanded(false, animated: false, notify: false)
        }
        wasActive = next.isActive

        guard next != previous else { return }
        applyHeader(next)
        rebuildBody(next)
    }

    func resetForReuse() {
        presentation = nil
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll(keepingCapacity: true)
        hasConfiguredContent = false
        userToggledExpansion = false
        showsEarlierSteps = false
        wasActive = false
        isExpanded = false
        bodyStack.isHidden = true
        chevronView.layer.removeAllAnimations()
        chevronView.transform = .identity
        isHidden = true
    }

    // MARK: - Content

    private func applyHeader(_ presentation: McpToolStepsPresentation) {
        switch presentation.header {
        case .running:
            titleLabel.text = L10n.tr("Using tools", table: .mcp)
        case .waitingForSignIn:
            titleLabel.text = L10n.tr("Waiting for sign-in", table: .mcp)
        case let .finished(usedCount):
            titleLabel.text = String(format: L10n.tr("Tools used: %d", table: .mcp), usedCount)
        }
        switch presentation.trailing {
        case let .step(number):
            trailingLabel.text = String(format: L10n.tr("Step %d", table: .mcp), number)
        case let .servers(names):
            trailingLabel.text = names.joined(separator: Self.listSeparator)
        case let .declined(count):
            trailingLabel.text = String(format: L10n.tr("%d declined", table: .mcp), count)
        case let .failed(count):
            trailingLabel.text = String(format: L10n.tr("%d failed", table: .mcp), count)
        }
        headerControl.accessibilityLabel = [titleLabel.text, trailingLabel.text]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func rebuildBody(_ presentation: McpToolStepsPresentation) {
        let hidden = showsEarlierSteps ? 0 : presentation.hiddenEarlierCount
        earlierButton.isHidden = hidden == 0
        if hidden > 0 {
            earlierButton.setTitle(String(format: L10n.tr("Show earlier steps (%d)", table: .mcp), hidden), for: .normal)
        }
        let visible = Array(presentation.rows.dropFirst(hidden))
        while rowViews.count > visible.count {
            rowViews.removeLast().removeFromSuperview()
        }
        while rowViews.count < visible.count {
            let row = UIKitToolStepRow()
            row.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)
            rowViews.append(row)
            rowsStack.addArrangedSubview(row)
        }
        for (view, row) in zip(rowViews, visible) {
            view.configure(row: row)
        }

        let paused = presentation.pausedForSignIn != nil
        pauseStack.isHidden = !paused
        pauseNoteLabel.isHidden = !paused
        limitDivider.isHidden = !presentation.limitReached
        limitLabel.isHidden = !presentation.limitReached
    }

    // MARK: - Layout

    private func setup() {
        isHidden = true
        backgroundColor = UIColor(OriveoTheme.Palette.surface)
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(OriveoTheme.Palette.border).cgColor
        clipsToBounds = true

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        setupHeader()
        contentStack.addArrangedSubview(headerControl)

        bodyStack.axis = .vertical
        bodyStack.alignment = .fill
        bodyStack.isHidden = true
        contentStack.addArrangedSubview(bodyStack)

        divider.backgroundColor = UIColor(OriveoTheme.Palette.border)
        bodyStack.addArrangedSubview(divider)

        let inner = UIStackView()
        inner.axis = .vertical
        inner.alignment = .fill
        inner.spacing = OriveoTheme.Spacing.xs
        inner.isLayoutMarginsRelativeArrangement = true
        inner.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 8, trailing: 14)
        bodyStack.addArrangedSubview(inner)

        earlierButton.contentHorizontalAlignment = .leading
        earlierButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        earlierButton.setTitleColor(UIColor(OriveoTheme.Palette.primaryTextSafe), for: .normal)
        earlierButton.addTarget(self, action: #selector(showEarlierSteps), for: .touchUpInside)
        earlierButton.isHidden = true
        inner.addArrangedSubview(earlierButton)

        rowsStack.axis = .vertical
        rowsStack.alignment = .fill
        inner.addArrangedSubview(rowsStack)

        setupPauseControls()
        inner.addArrangedSubview(pauseStack)
        inner.setCustomSpacing(OriveoTheme.Spacing.sm, after: rowsStack)

        pauseNoteLabel.font = .systemFont(ofSize: 12.5)
        pauseNoteLabel.textColor = UIColor(OriveoTheme.Palette.textTertiary)
        pauseNoteLabel.numberOfLines = 0
        pauseNoteLabel.text = L10n.tr("After you sign in, it picks up from this step. Earlier results are kept.", table: .mcp)
        pauseNoteLabel.isHidden = true
        inner.addArrangedSubview(pauseNoteLabel)

        limitDivider.backgroundColor = UIColor(OriveoTheme.Palette.border)
        limitDivider.isHidden = true
        inner.addArrangedSubview(limitDivider)

        limitLabel.font = .systemFont(ofSize: 12.5)
        limitLabel.textColor = UIColor(OriveoTheme.Palette.textTertiary)
        limitLabel.numberOfLines = 0
        limitLabel.text = L10n.tr("Tool limit reached. The answer below uses the results so far.", table: .mcp)
        limitLabel.isHidden = true
        inner.addArrangedSubview(limitLabel)

        setContentCompressionResistancePriority(.required, for: .vertical)
        let hairline = 1 / UIScreen.main.scale
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            headerControl.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.headerHeight),
            divider.heightAnchor.constraint(equalToConstant: hairline),
            limitDivider.heightAnchor.constraint(equalToConstant: hairline),
            earlierButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func setupHeader() {
        headerControl.addTarget(self, action: #selector(toggleExpanded), for: .touchUpInside)
        headerControl.isAccessibilityElement = true
        headerControl.accessibilityTraits = .button

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = OriveoTheme.Spacing.sm
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        headerControl.addSubview(stack)

        headerIcon.image = UIImage(systemName: "wrench.adjustable")
        headerIcon.tintColor = UIColor(OriveoTheme.Palette.primaryTextSafe)
        headerIcon.contentMode = .scaleAspectFit
        stack.addArrangedSubview(headerIcon)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = UIColor(OriveoTheme.Palette.textPrimary)
        titleLabel.numberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(titleLabel)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)

        trailingLabel.font = .systemFont(ofSize: 12.5)
        trailingLabel.textColor = UIColor(OriveoTheme.Palette.textTertiary)
        trailingLabel.numberOfLines = 1
        trailingLabel.lineBreakMode = .byTruncatingTail
        trailingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(trailingLabel)

        chevronView.image = UIImage(systemName: "chevron.down")
        chevronView.tintColor = UIColor(OriveoTheme.Palette.textTertiary)
        chevronView.contentMode = .scaleAspectFit
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(chevronView)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: headerControl.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: headerControl.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: headerControl.topAnchor),
            stack.bottomAnchor.constraint(equalTo: headerControl.bottomAnchor),
            headerIcon.widthAnchor.constraint(equalToConstant: 18),
            headerIcon.heightAnchor.constraint(equalToConstant: 18),
            chevronView.widthAnchor.constraint(equalToConstant: 16),
            chevronView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func setupPauseControls() {
        pauseStack.axis = .horizontal
        pauseStack.alignment = .fill
        pauseStack.distribution = .fillEqually
        pauseStack.spacing = 10
        pauseStack.isHidden = true

        var primary = UIButton.Configuration.filled()
        primary.title = L10n.tr("Sign in again", table: .mcp)
        primary.baseBackgroundColor = UIColor(OriveoTheme.Palette.primarySoft)
        primary.baseForegroundColor = UIColor(OriveoTheme.Palette.primaryTextSafe)
        primary.background.cornerRadius = 14
        primary.background.strokeColor = UIColor(OriveoTheme.Palette.primary).withAlphaComponent(0.35)
        primary.background.strokeWidth = 1
        reauthorizeButton.configuration = primary
        reauthorizeButton.addTarget(self, action: #selector(reauthorizeTapped), for: .touchUpInside)
        pauseStack.addArrangedSubview(reauthorizeButton)

        var secondary = UIButton.Configuration.filled()
        secondary.title = L10n.tr("Skip this step", table: .mcp)
        secondary.baseBackgroundColor = UIColor(OriveoTheme.Palette.surface)
        secondary.baseForegroundColor = UIColor(OriveoTheme.Palette.textPrimary)
        secondary.background.cornerRadius = 14
        secondary.background.strokeColor = UIColor(OriveoTheme.Palette.borderStrong)
        secondary.background.strokeWidth = 1
        skipButton.configuration = secondary
        skipButton.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)
        pauseStack.addArrangedSubview(skipButton)

        NSLayoutConstraint.activate([
            reauthorizeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            skipButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    // MARK: - Interaction

    @objc private func toggleExpanded() {
        userToggledExpansion = true
        setExpanded(!isExpanded, animated: true, notify: true)
    }

    @objc private func showEarlierSteps() {
        guard let presentation, !showsEarlierSteps else { return }
        showsEarlierSteps = true
        rebuildBody(presentation)
        onLayoutChange?()
    }

    @objc private func rowTapped(_ sender: UIKitToolStepRow) {
        guard let row = sender.row, row.opensDetail else { return }
        onSelectStep?(row.step)
    }

    @objc private func reauthorizeTapped() {
        guard let step = presentation?.pausedForSignIn else { return }
        onReauthorize?(step)
    }

    @objc private func skipTapped() {
        guard let step = presentation?.pausedForSignIn else { return }
        onSkipStep?(step)
    }

    private func setExpanded(_ expanded: Bool, animated: Bool, notify: Bool) {
        guard isExpanded != expanded || bodyStack.isHidden == expanded else { return }
        isExpanded = expanded
        // Implicit animation is switched off: inside the batch animation context of a reconfigure, UIStackView
        // would animate toggling `isHidden` on an arranged subview.
        UIView.performWithoutAnimation { bodyStack.isHidden = !expanded }
        headerControl.accessibilityValue = expanded
            ? L10n.tr("Expanded", table: .mcp)
            : L10n.tr("Collapsed", table: .mcp)
        let transform = expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        if animated, !UIAccessibility.isReduceMotionEnabled {
            chevronView.layer.removeAllAnimations()
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.chevronView.transform = transform
            }
        } else {
            chevronView.transform = transform
        }
        if notify { onLayoutChange?() }
    }

    /// For tests: what is currently drawn (text and visibility), without exposing the views themselves.
    struct RenderedStateForTesting: Equatable {
        var title: String?
        var trailing: String?
        var rowTitles: [String]
        var rowDetails: [String]
        var earlierButtonTitle: String?
        var showsPauseControls: Bool
        var showsLimitNote: Bool
    }

    var renderedStateForTesting: RenderedStateForTesting {
        RenderedStateForTesting(
            title: titleLabel.text,
            trailing: trailingLabel.text,
            rowTitles: rowViews.map(\.titleTextForTesting),
            rowDetails: rowViews.map(\.detailTextForTesting),
            earlierButtonTitle: earlierButton.isHidden ? nil : earlierButton.title(for: .normal),
            showsPauseControls: !pauseStack.isHidden,
            showsLimitNote: !limitLabel.isHidden
        )
    }

    func tapHeaderForTesting() { toggleExpanded() }
    func tapRowForTesting(at index: Int) { rowTapped(rowViews[index]) }
    func tapEarlierStepsForTesting() { showEarlierSteps() }

    /// Separator between server names: the ideographic comma for Chinese and Japanese, a comma otherwise.
    private static var listSeparator: String {
        let language = AppLocalization.currentLanguage.rawValue
        return language.hasPrefix("zh") || language.hasPrefix("ja") ? "、" : ", "
    }

    // MARK: - Copy (shared by the view and accessibility)

    static func statusText(for status: McpToolStep.Status) -> String {
        switch status {
        case .running: return L10n.tr("Running", table: .mcp)
        case .done: return L10n.tr("Done", table: .mcp)
        case .failed: return L10n.tr("Failed", table: .mcp)
        case .denied: return L10n.tr("Declined", table: .mcp)
        case .needsAuth: return L10n.tr("Needs sign-in", table: .mcp)
        case .interrupted: return L10n.tr("Interrupted", table: .mcp)
        }
    }

    static func failureText(code: String?) -> String {
        switch code.flatMap(McpErrorCode.init(rawValue:)) {
        case .timeout: return L10n.tr("The server took too long to respond.", table: .mcp)
        case .unreachable: return L10n.tr("Couldn't reach the server.", table: .mcp)
        case .serverError: return L10n.tr("The server returned an error.", table: .mcp)
        case .toolError: return L10n.tr("The tool reported an error.", table: .mcp)
        case .needsInputUnsupported:
            return L10n.tr("This tool asked for more input, which isn't supported yet.", table: .mcp)
        case .toolUnavailable: return L10n.tr("This tool is no longer available.", table: .mcp)
        case .authSkipped: return L10n.tr("Skipped", table: .mcp)
        default: return L10n.tr("Failed", table: .mcp)
        }
    }

    static func detailText(for detail: McpToolStepsPresentation.RowDetail) -> String {
        switch detail {
        case let .argsSummary(summary): return summary
        case .declined: return L10n.tr("You declined, so it wasn't run", table: .mcp)
        case .interrupted: return L10n.tr("Interrupted", table: .mcp)
        case let .signInExpired(serverName):
            return String(format: L10n.tr("%@'s sign-in expired", table: .mcp), serverName)
        case let .failure(code): return failureText(code: code)
        }
    }
}

/// One row of the step block: tool icon on the left, main text "server · tool title", a note, status icon on
/// the right.
@MainActor
final class UIKitToolStepRow: UIControl {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let statusIcon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let disclosure = UIImageView()
    private(set) var row: McpToolStepsPresentation.Row?
    var titleTextForTesting: String { titleLabel.text ?? "" }
    var detailTextForTesting: String { detailLabel.isHidden ? "" : (detailLabel.text ?? "") }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(row: McpToolStepsPresentation.Row) {
        self.row = row
        let step = row.step
        // The server name and the tool title are third-party text and are not translated.
        titleLabel.text = step.serverName.isEmpty ? step.displayTitle : "\(step.serverName) · \(step.displayTitle)"

        let detail = UIKitToolStepsView.detailText(for: row.detail).trimmingCharacters(in: .whitespacesAndNewlines)
        detailLabel.text = detail
        detailLabel.isHidden = detail.isEmpty
        switch row.detail {
        case .signInExpired: detailLabel.textColor = UIColor(OriveoTheme.Palette.warningText)
        case .failure: detailLabel.textColor = UIColor(OriveoTheme.Palette.danger)
        case .argsSummary, .declined, .interrupted: detailLabel.textColor = UIColor(OriveoTheme.Palette.textTertiary)
        }

        spinner.stopAnimating()
        statusIcon.isHidden = false
        switch row.status {
        case .running:
            statusIcon.isHidden = true
            spinner.startAnimating()
        case .done:
            statusIcon.image = UIImage(systemName: "checkmark.circle.fill")
            statusIcon.tintColor = UIColor(OriveoTheme.Palette.success)
        case .failed:
            statusIcon.image = UIImage(systemName: "exclamationmark.circle.fill")
            statusIcon.tintColor = UIColor(OriveoTheme.Palette.danger)
        case .needsAuth:
            statusIcon.image = UIImage(systemName: "exclamationmark.circle.fill")
            statusIcon.tintColor = UIColor(OriveoTheme.Palette.warning)
        case .denied, .interrupted:
            statusIcon.image = UIImage(systemName: "circle.slash")
            statusIcon.tintColor = UIColor(OriveoTheme.Palette.textTertiary)
        }
        disclosure.isHidden = !row.opensDetail
        isEnabled = row.opensDetail

        accessibilityLabel = [titleLabel.text ?? "", detail, UIKitToolStepsView.statusText(for: row.status)]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityTraits = row.opensDetail ? .button : .staticText
    }

    private func setup() {
        isAccessibilityElement = true

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        iconView.image = UIImage(systemName: "puzzlepiece.extension")
        iconView.tintColor = UIColor(OriveoTheme.Palette.textSecondary)
        iconView.contentMode = .scaleAspectFit
        stack.addArrangedSubview(iconView)

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 1
        stack.addArrangedSubview(textStack)

        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.textColor = UIColor(OriveoTheme.Palette.textPrimary)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 12.5)
        detailLabel.textColor = UIColor(OriveoTheme.Palette.textTertiary)
        detailLabel.numberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(detailLabel)

        statusIcon.contentMode = .scaleAspectFit
        stack.addArrangedSubview(statusIcon)

        spinner.hidesWhenStopped = true
        spinner.color = UIColor(OriveoTheme.Palette.primary)
        spinner.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        stack.addArrangedSubview(spinner)

        disclosure.image = UIImage(systemName: "chevron.right")
        disclosure.tintColor = UIColor(OriveoTheme.Palette.textTertiary)
        disclosure.contentMode = .scaleAspectFit
        disclosure.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        stack.addArrangedSubview(disclosure)

        for view in [iconView, statusIcon, spinner] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        disclosure.setContentHuggingPriority(.required, for: .horizontal)
        disclosure.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: UIKitToolStepsView.rowMinHeight),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            statusIcon.widthAnchor.constraint(equalToConstant: 18),
            statusIcon.heightAnchor.constraint(equalToConstant: 18),
            spinner.widthAnchor.constraint(equalToConstant: 18),
            disclosure.widthAnchor.constraint(equalToConstant: 10),
        ])
    }
}
