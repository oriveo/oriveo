import SwiftUI
import UIKit

@MainActor
final class AssistantMetadataView: UIStackView {
    private let infoRow = UIStackView()
    private let actionRow = UIStackView()
    private let savedNoteRow = UIStackView()
    private let infoTrailingSpacer = UIView()
    private let actionTrailingSpacer = UIView()
    private let savedNoteTrailingSpacer = UIView()

    private let providerLabel = UILabel()
    private let dot1 = UILabel()
    private let modelLabel = UILabel()
    private let dot2 = UILabel()
    private let costLabel = UILabel()
    private let capabilityExecutionLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let savedNoteReferenceButton = UIButton(type: .system)
    private let saveNoteButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let continueButton = UIButton(type: .system)
    private let metaFont = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .footnote), size: 0)

    private var currentMessageText = ""
    private var currentTokenUsage = MessageTokenUsageSnapshot()
    private var currentCapabilityExecution: CapabilityExecutionResult?
    private var copyResetWorkItem: DispatchWorkItem?
    private var onRetry: (() -> Void)?
    private var onContinue: (() -> Void)?
    private var onSaveNote: (() -> Void)?
    private var onOpenNoteReferences: (() -> Void)?
    private var messageStateAllowsFooterActions = false
    private var hasConfiguredFooterActions = false
    private var isVisualRenderPending = false

    var _testActionRowHasImplicitAnimation: Bool {
        actionRow.layer.animationKeys()?.isEmpty == false
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        model: ChatCollectionProjectionBuilder.MessageRenderModel,
        providerName: String,
        modelName: String,
        leadingInset: CGFloat,
        onRetry: (() -> Void)?,
        onContinue: (() -> Void)?,
        onSaveNote: (() -> Void)? = nil,
        onOpenNoteReferences: (() -> Void)? = nil,
        isVisualRenderPending: Bool = false
    ) {
        self.onRetry = onRetry
        self.onContinue = onContinue
        self.onSaveNote = onSaveNote
        self.onOpenNoteReferences = onOpenNoteReferences

        providerLabel.text = providerName
        modelLabel.text = modelName
        updateLeadingInset(leadingInset)

        let showCost = model.message.estimatedCost > 0 && model.message.state == .delivered
        dot2.isHidden = !showCost
        costLabel.isHidden = !showCost
        if showCost {
            costLabel.text = model.message.estimatedCostText
        }

        let canOfferRecovery = shouldOfferMessageRecovery(
            state: model.message.state,
            role: model.message.role,
            isLastInConversation: model.isLastInConversation
        )
        continueButton.isHidden = model.message.state != .interrupted || onContinue == nil || !canOfferRecovery

        currentMessageText = model.message.text
        currentTokenUsage = MessageTokenUsageSnapshot(
            message: model.message,
            contextLength: model.resolvedContextLength
        )
        currentCapabilityExecution = model.message.capabilityExecution
        let capabilityStatusText = Self.capabilityExecutionText(currentCapabilityExecution)
        capabilityExecutionLabel.text = capabilityStatusText
        capabilityExecutionLabel.accessibilityLabel = capabilityStatusText
        capabilityExecutionLabel.isHidden = capabilityStatusText == nil
        copyResetWorkItem?.cancel()
        copyResetWorkItem = nil
        updateCopyButton(copied: false)
        let isDeliveredWithText = model.message.state == .delivered && !model.message.text.isEmpty
        let showCopy = isDeliveredWithText
        copyButton.isHidden = !showCopy

        let showSavedNoteReference = onOpenNoteReferences != nil && !model.noteReferences.isEmpty
        updateSavedNoteReferenceButton(noteReferences: model.noteReferences)
        savedNoteReferenceButton.isHidden = !showSavedNoteReference
        savedNoteRow.isHidden = !showSavedNoteReference

        let showSaveNote = isDeliveredWithText && onSaveNote != nil
        saveNoteButton.isHidden = !showSaveNote

        let showRetry = isDeliveredWithText && onRetry != nil

        let showMore = true
        moreButton.isHidden = !showMore
        configureMoreMenu(showRetry: showRetry)

        messageStateAllowsFooterActions = model.message.state != .generating
        hasConfiguredFooterActions = showCopy || showSaveNote || showMore || !continueButton.isHidden
        self.isVisualRenderPending = isVisualRenderPending
        updateActionRowVisibility()

        isHidden = false
    }

    func markVisualRenderCompleted() {
        isVisualRenderPending = false
        updateActionRowVisibility()
    }

    func resetForReuse() {
        copyResetWorkItem?.cancel()
        copyResetWorkItem = nil
        currentMessageText = ""
        currentTokenUsage = MessageTokenUsageSnapshot()
        currentCapabilityExecution = nil
        capabilityExecutionLabel.text = nil
        capabilityExecutionLabel.accessibilityLabel = nil
        capabilityExecutionLabel.isHidden = true
        onRetry = nil
        onContinue = nil
        onSaveNote = nil
        onOpenNoteReferences = nil
        messageStateAllowsFooterActions = false
        hasConfiguredFooterActions = false
        isVisualRenderPending = false
        updateCopyButton(copied: false)
        updateSavedNoteReferenceButton(noteReferences: [])
        moreButton.menu = nil
        actionRow.isHidden = true
        savedNoteRow.isHidden = true
        isHidden = true
    }

    private func updateActionRowVisibility() {
        actionRow.isHidden = !messageStateAllowsFooterActions
            || !hasConfiguredFooterActions
            || isVisualRenderPending
    }

    private func setup() {
        axis = .vertical
        alignment = .fill
        spacing = 7
        isHidden = true
        isLayoutMarginsRelativeArrangement = true
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

        let metaColor = UIColor(OriveoTheme.Palette.textTertiary)

        for label in [providerLabel, dot1, modelLabel, dot2, costLabel] {
            label.font = metaFont
            label.textColor = metaColor
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        dot1.text = "•"
        dot2.text = "•"
        dot2.isHidden = true
        costLabel.isHidden = true

        providerLabel.setContentHuggingPriority(.required, for: .horizontal)
        providerLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        dot1.setContentHuggingPriority(.required, for: .horizontal)
        dot1.setContentCompressionResistancePriority(.required, for: .horizontal)
        dot2.setContentHuggingPriority(.required, for: .horizontal)
        dot2.setContentCompressionResistancePriority(.required, for: .horizontal)
        modelLabel.lineBreakMode = .byTruncatingMiddle
        modelLabel.adjustsFontSizeToFitWidth = true
        modelLabel.minimumScaleFactor = 0.86
        modelLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        costLabel.setContentHuggingPriority(.required, for: .horizontal)
        costLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        capabilityExecutionLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        capabilityExecutionLabel.adjustsFontForContentSizeCategory = true
        capabilityExecutionLabel.textColor = UIColor(OriveoTheme.Palette.textTertiary)
        capabilityExecutionLabel.numberOfLines = 0
        capabilityExecutionLabel.lineBreakMode = .byWordWrapping
        capabilityExecutionLabel.isAccessibilityElement = true
        capabilityExecutionLabel.isHidden = true

        configureRow(infoRow, alignment: .firstBaseline, spacing: 5)
        infoRow.addArrangedSubview(providerLabel)
        infoRow.addArrangedSubview(dot1)
        infoRow.addArrangedSubview(modelLabel)
        infoRow.addArrangedSubview(dot2)
        infoRow.addArrangedSubview(costLabel)
        configureTrailingSpacer(infoTrailingSpacer)
        infoRow.addArrangedSubview(infoTrailingSpacer)

        configureRow(actionRow, alignment: .center, spacing: 4)
        actionRow.isLayoutMarginsRelativeArrangement = true
        actionRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        actionRow.isHidden = true

        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        copyButton.isHidden = true
        updateCopyButton(copied: false)
        actionRow.addArrangedSubview(copyButton)

        configureActionButton(saveNoteButton, systemImage: "note.text.badge.plus",
                              title: L10n.tr("Save as Note", table: .notes),
                              selector: #selector(saveNoteTapped),
                              style: .accent,
                              symbolPointSize: 14)
        actionRow.addArrangedSubview(saveNoteButton)

        applyFooterButtonConfiguration(
            moreButton,
            systemImage: "ellipsis",
            title: nil,
            style: .neutral,
            symbolPointSize: 15,
            usesCustomHighlightBackground: false
        )
        moreButton.accessibilityLabel = L10n.tr("More", table: .chat)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.isHidden = true
        actionRow.addArrangedSubview(moreButton)

        applyFooterButtonConfiguration(
            continueButton,
            systemImage: "play.fill",
            title: L10n.tr("Continue Generating", table: .chat),
            style: .accent,
            symbolPointSize: 14
        )
        continueButton.accessibilityLabel = L10n.tr("Continue Generating", table: .chat)
        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        continueButton.isHidden = true
        actionRow.addArrangedSubview(continueButton)
        configureTrailingSpacer(actionTrailingSpacer)
        actionRow.addArrangedSubview(actionTrailingSpacer)

        configureRow(savedNoteRow, alignment: .center, spacing: 0)
        savedNoteRow.isLayoutMarginsRelativeArrangement = true
        savedNoteRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        savedNoteRow.isHidden = true
        configureSavedNoteReferenceButton()
        savedNoteRow.addArrangedSubview(savedNoteReferenceButton)
        configureTrailingSpacer(savedNoteTrailingSpacer)
        savedNoteRow.addArrangedSubview(savedNoteTrailingSpacer)

        addArrangedSubview(infoRow)
        addArrangedSubview(capabilityExecutionLabel)
        addArrangedSubview(actionRow)
        addArrangedSubview(savedNoteRow)
    }

    private func updateLeadingInset(_ leading: CGFloat) {
        guard directionalLayoutMargins.leading != leading else { return }
        var margins = directionalLayoutMargins
        margins.leading = leading
        directionalLayoutMargins = margins
    }

    private func configureRow(_ row: UIStackView, alignment: UIStackView.Alignment, spacing: CGFloat) {
        row.axis = .horizontal
        row.alignment = alignment
        row.distribution = .fill
        row.spacing = spacing
    }

    private func configureTrailingSpacer(_ spacer: UIView) {
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureActionButton(
        _ button: UIButton,
        systemImage: String,
        title: String,
        selector: Selector,
        style: FooterButtonStyle,
        symbolPointSize: CGFloat = 15
    ) {
        applyFooterButtonConfiguration(
            button,
            systemImage: systemImage,
            title: title,
            style: style,
            symbolPointSize: symbolPointSize
        )
        button.accessibilityLabel = title
        button.addTarget(self, action: selector, for: .touchUpInside)
        button.isHidden = true
    }

    private enum FooterButtonStyle {
        case neutral
        case accent
    }

    private func applyFooterButtonConfiguration(
        _ button: UIButton,
        systemImage: String,
        title: String?,
        style: FooterButtonStyle,
        symbolPointSize: CGFloat = 15,
        filled: Bool = false,
        usesCustomHighlightBackground: Bool = true
    ) {
        let foreground: UIColor
        let softBackground: UIColor
        switch style {
        case .neutral:
            foreground = UIColor(OriveoTheme.Palette.textTertiary)
            softBackground = UIColor(OriveoTheme.Palette.surfaceInset)
        case .accent:
            foreground = UIColor(OriveoTheme.Palette.primary)
            softBackground = UIColor(OriveoTheme.Palette.primarySoft)
        }
        let restBackground: UIColor = filled ? softBackground : .clear

        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .medium)
        )
        config.imagePadding = title == nil ? 0 : 5
        config.contentInsets = NSDirectionalEdgeInsets(
            top: title == nil ? 8 : 7,
            leading: 8,
            bottom: title == nil ? 8 : 7,
            trailing: title == nil ? 8 : 10
        )
        config.baseForegroundColor = foreground
        config.background.backgroundColor = restBackground
        config.background.cornerRadius = 8
        config.titleLineBreakMode = .byTruncatingTail
        if let title {
            var attributedTitle = AttributedString(title)
            attributedTitle.font = metaFont
            config.attributedTitle = attributedTitle
        }
        button.configuration = config
        if usesCustomHighlightBackground {
            button.configurationUpdateHandler = { button in
                guard var updated = button.configuration else { return }
                updated.background.backgroundColor = button.isHighlighted ? softBackground : restBackground
                button.configuration = updated
            }
        } else {
            button.configurationUpdateHandler = nil
        }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureMoreMenu(showRetry: Bool) {
        var actions: [UIMenuElement] = []
        actions.append(UIAction(
            title: L10n.tr("Token usage", table: .chat),
            subtitle: currentTokenUsage.total.map(Self.compactTokenCount),
            image: UIImage(systemName: "chart.bar")
        ) { [weak self] _ in
            self?.presentTokenUsage()
        })
        if let execution = currentCapabilityExecution, !execution.states.isEmpty {
            let stateActions = execution.states.keys.sorted().compactMap { owner -> UIAction? in
                guard let state = execution.states[owner] else { return nil }
                return UIAction(
                    title: Self.localizedCapabilityOwner(owner),
                    subtitle: Self.localizedCapabilityExecutionState(state),
                    image: UIImage(systemName: Self.capabilityExecutionImage(state))
                ) { _ in }
            }
            if !stateActions.isEmpty {
                actions.append(UIMenu(
                    title: L10n.tr("Capability execution", table: .chat),
                    image: UIImage(systemName: "checkmark.seal"),
                    children: stateActions
                ))
            }
        }
        if showRetry {
            actions.append(UIAction(
                title: L10n.tr("Regenerate", table: .chat),
                image: UIImage(systemName: "arrow.counterclockwise")
            ) { [weak self] _ in
                self?.onRetry?()
            })
        }
        moreButton.menu = actions.isEmpty ? nil : UIMenu(children: actions)
    }

    private static func localizedCapabilityOwner(_ owner: String) -> String {
        switch owner {
        case "web": return L10n.tr("Web", table: .providers)
        case "reasoning": return L10n.tr("Reasoning", table: .providers)
        case "generation": return L10n.tr("Parameters", table: .providers)
        default: return L10n.tr("Capability execution", table: .chat)
        }
    }

    private static func localizedCapabilityExecutionState(_ state: RequestResultState) -> String {
        switch state {
        case .notRequested: return L10n.tr("Not confirmed", table: .chat)
        case .requested: return L10n.tr("Requested", table: .chat)
        case .observed: return L10n.tr("Observed", table: .chat)
        case .unconfirmed: return L10n.tr("Not confirmed", table: .chat)
        case .rejected: return L10n.tr("Rejected", table: .chat)
        case .recovered: return L10n.tr("Recovered", table: .chat)
        }
    }

    private static func capabilityExecutionText(_ execution: CapabilityExecutionResult?) -> String? {
        guard let execution, !execution.states.isEmpty else { return nil }
        return execution.states.keys.sorted().compactMap { owner in
            guard let state = execution.states[owner] else { return nil }
            return "\(localizedCapabilityOwner(owner)): \(localizedCapabilityExecutionState(state))"
        }.joined(separator: " • ")
    }

    private static func capabilityExecutionImage(_ state: RequestResultState) -> String {
        switch state {
        case .requested: return "arrow.up.circle"
        case .observed: return "checkmark.circle"
        case .unconfirmed: return "questionmark.circle"
        case .rejected: return "xmark.circle"
        case .recovered: return "arrow.clockwise.circle"
        case .notRequested: return "minus.circle"
        }
    }

    private func presentTokenUsage() {
        let usage = currentTokenUsage
        let controller = UIHostingController(rootView: MessageTokenUsageSheet(usage: usage))
        controller.modalPresentationStyle = .pageSheet
        controller.view.backgroundColor = .clear

        let host = nearestViewController()
        let width = host?.view.bounds.width ?? UIScreen.main.bounds.width
        let measurer = UIHostingController(rootView: MessageTokenUsageContent(usage: usage))
        if let host {
            measurer.traitOverrides.preferredContentSizeCategory =
                host.traitCollection.preferredContentSizeCategory
        }
        let fitted = measurer
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            .height
        let bottomInset = host?.view.safeAreaInsets.bottom ?? 0

        if let sheet = controller.sheetPresentationController {
            let identifier = UISheetPresentationController.Detent.Identifier("tokenUsage")
            sheet.detents = [
                .custom(identifier: identifier) { context in
                    let maximum = context.maximumDetentValue
                    guard fitted.isFinite, fitted > 0, fitted < maximum else {
                        return maximum * 0.5
                    }
                    return min(fitted + bottomInset, maximum)
                },
                .large()
            ]
            sheet.selectedDetentIdentifier = identifier
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
        host?.present(controller, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        sequence(first: next, next: { $0?.next })
            .first(where: { $0 is UIViewController }) as? UIViewController
    }

    private static func compactTokenCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).locale(AppLocalization.currentLocale))
    }

    private func configureSavedNoteReferenceButton() {
        updateSavedNoteReferenceButton(noteReferences: [])
        savedNoteReferenceButton.addTarget(self, action: #selector(savedNoteReferenceTapped), for: .touchUpInside)
        savedNoteReferenceButton.isHidden = true
    }

    private func updateSavedNoteReferenceButton(noteReferences: [NoteSummary]) {
        let title = savedNoteReferenceTitle(for: noteReferences)
        applyFooterButtonConfiguration(
            savedNoteReferenceButton,
            systemImage: "note.text",
            title: title,
            style: .neutral,
            symbolPointSize: 13
        )
        savedNoteReferenceButton.accessibilityLabel = title
        savedNoteReferenceButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    private func savedNoteReferenceTitle(for noteReferences: [NoteSummary]) -> String {
        let baseTitle = L10n.tr("Saved as note", table: .notes)
        guard let firstTitle = noteReferences.first?.title.trimmingCharacters(in: .whitespacesAndNewlines),
              !firstTitle.isEmpty else {
            return baseTitle
        }
        let overflowCount = noteReferences.count - 1
        guard overflowCount > 0 else {
            return "\(baseTitle) \(firstTitle)"
        }
        return "\(baseTitle) \(firstTitle) +\(overflowCount)"
    }

    @objc private func savedNoteReferenceTapped() {
        onOpenNoteReferences?()
    }

    @objc private func saveNoteTapped() {
        onSaveNote?()
    }

    @objc private func continueTapped() {
        onContinue?()
    }

    @objc private func copyTapped() {
        guard !currentMessageText.isEmpty else { return }
        UIPasteboard.general.string = currentMessageText
        updateCopyButton(copied: true)
        let work = DispatchWorkItem { [weak self] in
            self?.updateCopyButton(copied: false)
        }
        copyResetWorkItem?.cancel()
        copyResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func updateCopyButton(copied: Bool) {
        let imageName = copied ? "checkmark" : "doc.on.doc"
        let titleKey = copied ? "Copied" : "Copy"
        applyFooterButtonConfiguration(
            copyButton,
            systemImage: imageName,
            title: nil,
            style: copied ? .accent : .neutral,
            symbolPointSize: 13,
            filled: copied
        )
        copyButton.accessibilityLabel = L10n.tr(titleKey)
    }
}

nonisolated struct MessageTokenUsageSnapshot: Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var contextLength: Int?
    var estimatedCost: Double
    var costSource: CostSource?
    var isPlatformPaid: Bool

    nonisolated init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        contextLength: Int? = nil,
        estimatedCost: Double = 0,
        costSource: CostSource? = nil,
        isPlatformPaid: Bool = false
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.contextLength = contextLength
        self.estimatedCost = estimatedCost
        self.costSource = costSource
        self.isPlatformPaid = isPlatformPaid
    }

    nonisolated init(message: ChatMessage, contextLength: Int? = nil) {
        self.init(
            inputTokens: message.inputTokens,
            outputTokens: message.outputTokens,
            cacheReadTokens: message.cachedInputTokens,
            cacheWriteTokens: message.cacheCreationInputTokens,
            contextLength: contextLength,
            estimatedCost: message.estimatedCost,
            costSource: message.costSource,
            isPlatformPaid: false
        )
    }

    nonisolated var total: Int? {
        guard let inputTokens, let outputTokens else { return nil }
        return inputTokens + outputTokens
    }

    nonisolated var contextUsageRatio: Double? {
        guard let inputTokens, let contextLength, contextLength > 0 else { return nil }
        return Double(inputTokens) / Double(contextLength)
    }

    nonisolated var showsCost: Bool {
        !isPlatformPaid && estimatedCost > CostFormatter.costEpsilon
    }

    nonisolated var isCostEstimated: Bool {
        costSource != .upstream
    }
}

private struct MessageTokenUsageSheet: View {
    let usage: MessageTokenUsageSnapshot

    var body: some View {
        ScrollView {
            MessageTokenUsageContent(usage: usage)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(OriveoTheme.Palette.background)
    }
}

private struct MessageTokenUsageContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let usage: MessageTokenUsageSnapshot

    private var cacheBreakdown: [(title: String, value: Int)] {
        var items: [(String, Int)] = []
        if let cacheReadTokens = usage.cacheReadTokens {
            items.append((L10n.tr("Cache read", table: .chat), cacheReadTokens))
        }
        if let cacheWriteTokens = usage.cacheWriteTokens {
            items.append((L10n.tr("Cache write", table: .chat), cacheWriteTokens))
        }
        return items
    }

    private var isSingleColumn: Bool {
        dynamicTypeSize >= .accessibility1 || !cacheBreakdown.isEmpty
    }

    private var inputCard: some View {
        metric(
            L10n.tr("Input", table: .chat),
            usage.inputTokens,
            footnote: contextFootnote,
            breakdown: cacheBreakdown
        )
    }

    private var outputCard: some View {
        metric(L10n.tr("Output", table: .chat), usage.outputTokens)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if isSingleColumn {
                VStack(spacing: 10) {
                    inputCard
                    outputCard
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    inputCard.frame(maxHeight: .infinity)
                    outputCard.frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            total

            if usage.showsCost {
                cost
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contextFootnote: String? {
        guard let ratio = usage.contextUsageRatio,
              let contextText = CatalogModelBuilder.compactContextText(usage.contextLength) else {
            return nil
        }
        let percent = ratio.formatted(
            .percent.precision(.fractionLength(ratio < 0.01 ? 2 : 1))
                .locale(AppLocalization.currentLocale)
        )
        return "\(L10n.tr("Context", table: .chat)) \(percent) • \(contextText)"
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Token usage", table: .chat))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Text(L10n.tr("This reply", table: .chat))
                    .font(.subheadline)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 12)

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(OriveoTheme.Palette.surfaceInset, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, -7)
            .padding(.top, -7)
            .accessibilityLabel(L10n.tr("Close"))
        }
    }

    private var total: some View {
        let title = L10n.tr("Total", table: .chat)
        let value = formatted(usage.total)
        return HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            OriveoTheme.Palette.primarySoft,
            in: RoundedRectangle(cornerRadius: OriveoTheme.Radius.inset, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private var cost: some View {
        let title = L10n.tr("Cost", table: .chat)
        let value = CostFormatter.format(usage.estimatedCost)
        let estimatedTag = usage.isCostEstimated ? L10n.tr("Estimated", table: .chat) : nil
        return HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
            if let estimatedTag {
                Text(estimatedTag)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        OriveoTheme.Palette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }
            Spacer(minLength: 12)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .modelControlSurface(cornerRadius: OriveoTheme.Radius.inset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value, estimatedTag].compactMap { $0 }.joined(separator: ", "))
    }

    private func metric(
        _ title: String,
        _ value: Int?,
        footnote: String? = nil,
        breakdown: [(title: String, value: Int)] = []
    ) -> some View {
        let text = formatted(value)
        let headlineLabel: String = footnote.map { "\(title), \($0)" } ?? title
        return VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(.footnote).weight(.medium))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(text)
                    .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let footnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(headlineLabel)
            .accessibilityValue(text)

            if !breakdown.isEmpty {
                Divider()
                    .overlay(OriveoTheme.Palette.border)
                    .padding(.top, 3)
                ForEach(Array(breakdown.enumerated()), id: \.offset) { _, item in
                    let itemText = formatted(item.value)
                    HStack {
                        Text(item.title)
                            .font(.system(.footnote))
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 12)
                        Text(itemText)
                            .font(.system(.subheadline, design: .rounded).weight(.medium).monospacedDigit())
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.title)
                    .accessibilityValue(itemText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .modelControlSurface(cornerRadius: OriveoTheme.Radius.inset)
        .accessibilityElement(children: .contain)
    }

    private func formatted(_ value: Int?) -> String {
        guard let value else { return L10n.tr("No data", table: .chat) }
        return value.formatted(.number.locale(AppLocalization.currentLocale))
    }
}
