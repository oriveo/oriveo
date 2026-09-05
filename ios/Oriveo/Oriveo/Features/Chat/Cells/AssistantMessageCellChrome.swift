import SwiftUI
import UIKit

extension AssistantMessageCell {

    func embedRecoveryCard(_ config: UIKitRecoveryCard.Config) {
        tearDownRecoveryCard()
        var enrichedConfig = config
        enrichedConfig.onLayoutChange = { [weak self] in
            self?.notifyContentDidChange()
        }
        let card = UIKitRecoveryCard(config: enrichedConfig)
        card.translatesAutoresizingMaskIntoConstraints = false
        recoveryCardHost.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: recoveryCardHost.topAnchor),
            card.leadingAnchor.constraint(equalTo: recoveryCardHost.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: recoveryCardHost.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: recoveryCardHost.bottomAnchor),
        ])
        recoveryCardHost.isHidden = false
        recoveryCard = card
        notifyContentDidChange()
    }

    func tearDownRecoveryCard() {
        guard let card = recoveryCard else { return }
        card.removeFromSuperview()
        recoveryCard = nil
        recoveryCardHost.isHidden = true
        notifyContentDidChange()
    }

    // MARK: - Attachments

    func configureAttachments(_ imageAttachments: [Attachment], parentViewController: UIViewController) {
        guard !imageAttachments.isEmpty else {
            tearDownAttachmentViews()
            return
        }
        guard imageAttachments != configuredImageAttachments || attachmentViews.isEmpty else { return }

        tearDownAttachmentViews(notify: false)
        attachmentsHost.isHidden = false
        var previous: UIView?
        for att in imageAttachments {
            let imageView = UIKitAssistantImageView(
                attachment: att,
                partitionUID: AppSessionStore.activeUID,
                parentViewController: parentViewController
            )
            imageView.onLanded = { [weak self] in self?.notifyContentDidChange() }
            imageView.translatesAutoresizingMaskIntoConstraints = false
            attachmentsHost.addSubview(imageView)
            attachmentLayoutConstraints.append(contentsOf: [
                imageView.leadingAnchor.constraint(equalTo: attachmentsHost.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: attachmentsHost.trailingAnchor),
                imageView.topAnchor.constraint(
                    equalTo: previous?.bottomAnchor ?? attachmentsHost.topAnchor,
                    constant: previous == nil ? 0 : OriveoTheme.Spacing.sm
                ),
            ])
            attachmentViews.append(imageView)
            previous = imageView
        }
        if let last = attachmentViews.last {
            attachmentLayoutConstraints.append(
                last.bottomAnchor.constraint(equalTo: attachmentsHost.bottomAnchor)
            )
        }
        NSLayoutConstraint.activate(attachmentLayoutConstraints)
        configuredImageAttachments = imageAttachments

        notifyContentDidChange()
    }

    func tearDownAttachmentViews(notify: Bool = true) {
        let hadAttachments = !attachmentViews.isEmpty
        NSLayoutConstraint.deactivate(attachmentLayoutConstraints)
        attachmentLayoutConstraints.removeAll()
        for view in attachmentViews {
            view.removeFromSuperview()
        }
        attachmentViews.removeAll()
        configuredImageAttachments.removeAll()
        attachmentsHost.isHidden = true
        if notify && hadAttachments {
            notifyContentDidChange()
        }
    }

    // MARK: - Citations

    func configureCitations(_ citations: [Citation], parentViewController: UIViewController) {
        let block: CitationsBlock
        if let existing = citationsBlock {
            block = existing
        } else {
            let new = CitationsBlock()
            citationsBlock = new
            new.onLayoutChange = { [weak self] in
                self?.notifyContentDidChange()
            }
            new.translatesAutoresizingMaskIntoConstraints = false
            citationsHost.addSubview(new)
            NSLayoutConstraint.activate([
                new.topAnchor.constraint(equalTo: citationsHost.topAnchor),
                new.leadingAnchor.constraint(equalTo: citationsHost.leadingAnchor),
                new.trailingAnchor.constraint(equalTo: citationsHost.trailingAnchor),
                new.bottomAnchor.constraint(equalTo: citationsHost.bottomAnchor),
            ])
            citationsHost.isHidden = false
            block = new
            notifyContentDidChange()
        }
        block.update(citations: citations, parentViewController: parentViewController)
    }

    func tearDownCitationsBlock() {
        guard let block = citationsBlock else { return }
        block.removeFromSuperview()
        citationsBlock = nil
        citationsHost.isHidden = true
        notifyContentDidChange()
    }

    // MARK: - Setup

    func setupViews() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        clipsToBounds = false
        contentView.clipsToBounds = false

        outerStack.axis = .vertical
        outerStack.alignment = .fill
        outerStack.spacing = 0
        outerStack.setContentHuggingPriority(.required, for: .vertical)
        outerStack.setContentCompressionResistancePriority(.required, for: .vertical)
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(outerStack)

        providerBadge.translatesAutoresizingMaskIntoConstraints = false

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = OriveoTheme.Spacing.sm
        contentStack.setContentHuggingPriority(.required, for: .vertical)
        contentStack.setContentCompressionResistancePriority(.required, for: .vertical)
        outerStack.addArrangedSubview(contentStack)

        setupHeader()
        contentStack.addArrangedSubview(headerStack)

        bodyStack.axis = .vertical
        bodyStack.alignment = .fill
        bodyStack.spacing = OriveoTheme.Spacing.md
        bodyStack.setContentHuggingPriority(.required, for: .vertical)
        bodyStack.setContentCompressionResistancePriority(.required, for: .vertical)
        bodyStack.isLayoutMarginsRelativeArrangement = true
        bodyStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0,
            leading: Self.assistantBodyLeadingInset,
            bottom: OriveoTheme.Spacing.xs,
            trailing: 0
        )
        let bodyStackMinHeight = OriveoTheme.Typography.chatBodyUIFont().lineHeight + 4
        bodyStackMinHeightConstraint = bodyStack.heightAnchor.constraint(
            greaterThanOrEqualToConstant: bodyStackMinHeight
        )
        bodyStackMinHeightConstraint?.priority = .defaultHigh
        bodyStackMinHeightConstraint?.isActive = false
        contentStack.addArrangedSubview(bodyStack)

        reasoningBlock.translatesAutoresizingMaskIntoConstraints = false
        reasoningBlock.onLayoutChange = { [weak self] in
            self?.streamingHeightFloor = 0
            self?.notifyContentDidChange()
        }
        reasoningBlock.onHeightDidChange = { [weak self] in
            self?.requestStreamingSelfSizeInvalidate()
        }
        reasoningBlock.onRequestStreamingSnapshot = { [weak self] in
            self?.streamingController.synchronizeReasoning()
        }
        bodyStack.addArrangedSubview(reasoningBlock)

        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textColor = UIColor(OriveoTheme.Palette.textPrimary)
        textView.linkTextAttributes = [.foregroundColor: UIColor(OriveoTheme.Palette.primary)]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.useStableWidthForIntrinsic = true
        bodyStack.addArrangedSubview(textView)

        bodyStack.addArrangedSubview(streamingCodeRenderer.view)

        typingContainer.isHidden = true
        typingContainer.alpha = 1
        typingContainer.translatesAutoresizingMaskIntoConstraints = false
        typingIndicator.translatesAutoresizingMaskIntoConstraints = false
        typingContainer.addSubview(typingIndicator)
        let typingMinHeight = OriveoTheme.Typography.chatBodyUIFont().lineHeight + 4
        NSLayoutConstraint.activate([
            typingIndicator.leadingAnchor.constraint(
                equalTo: typingContainer.leadingAnchor,
                constant: Self.assistantBodyLeadingInset
            ),
            typingIndicator.topAnchor.constraint(equalTo: typingContainer.topAnchor),
            typingIndicator.bottomAnchor.constraint(equalTo: typingContainer.bottomAnchor),
            typingIndicator.trailingAnchor.constraint(lessThanOrEqualTo: typingContainer.trailingAnchor),
            typingContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: typingMinHeight),
        ])
        bodyStack.addArrangedSubview(typingContainer)

        unhandledToolCallView.isHidden = true
        unhandledToolCallView.onLayoutChange = { [weak self] in
            self?.streamingHeightFloor = 0
            self?.notifyContentDidChange()
        }
        contentStack.addArrangedSubview(unhandledToolCallView)

        citationsHost.isHidden = true
        contentStack.addArrangedSubview(citationsHost)

        recoveryCardHost.isHidden = true
        contentStack.addArrangedSubview(recoveryCardHost)

        attachmentsHost.isHidden = true
        contentStack.addArrangedSubview(attachmentsHost)

        contentStack.addArrangedSubview(metadataView)

        topPaddingConstraint = outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16)
        let outerStackBottom = outerStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
        outerStackBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            topPaddingConstraint,
            outerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 26),
            outerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            outerStackBottom,

            providerBadge.widthAnchor.constraint(equalToConstant: 28),
            providerBadge.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    func updateStreamingCodeBlock(language: String?, code: String) {
        streamingCodeRenderer.update(language: language, code: code)
    }

    func upgradeStreamingCodeContainerToFrozenView(language: String?, content: String) {
        let segment = StreamingSegmentParser.Segment(
            kind: .codeBlock(language: language),
            content: content
        )
        appendFrozenViews(newSegments: [segment])
        bodyStack.setNeedsLayout()
        bodyStack.layoutIfNeeded()

        streamingCodeRenderer.hide()
    }

    func hideStreamingCodeBlock() {
        streamingCodeRenderer.hide()
    }


    func updateStreamingTableCard(lines: [String]) {
        let renderer = streamingTableRenderer ?? {
            let renderer = AssistantStreamingTableRenderer(
                bodyStack: bodyStack,
                insertAfterView: streamingCodeRenderer.view,
                onHeightChange: { [weak self] in
                    self?.requestStreamingSelfSizeInvalidate()
                }
            )
            streamingTableRenderer = renderer
            return renderer
        }()
        renderer.update(lines: lines)
    }

    func hideStreamingTableCard() {
        streamingTableRenderer?.hide()
    }

    func setupHeader() {
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = OriveoTheme.Spacing.sm

        headerStack.addArrangedSubview(providerBadge)

        modelNameLabel.font = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .footnote), size: 0)
        modelNameLabel.textColor = UIColor(OriveoTheme.Palette.textSecondary)
        modelNameLabel.setContentHuggingPriority(.required, for: .vertical)
        modelNameLabel.setContentHuggingPriority(.required, for: .horizontal)
        headerStack.addArrangedSubview(modelNameLabel)

        let headerHeight = modelNameLabel.heightAnchor.constraint(equalToConstant: 28)
        headerHeight.isActive = true

        statusPillLabel.text = L10n.tr("Generating")
        statusPillLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusPillLabel.textColor = UIColor(OriveoTheme.Palette.onPrimary)
        statusPillLabel.translatesAutoresizingMaskIntoConstraints = false

        statusPillContainer.backgroundColor = UIColor(OriveoTheme.Palette.primary)
        statusPillContainer.layer.cornerRadius = 8
        statusPillContainer.clipsToBounds = true
        statusPillContainer.isHidden = true
        statusPillContainer.setContentHuggingPriority(.required, for: .horizontal)
        statusPillContainer.addSubview(statusPillLabel)
        NSLayoutConstraint.activate([
            statusPillLabel.leadingAnchor.constraint(equalTo: statusPillContainer.leadingAnchor, constant: 6),
            statusPillLabel.trailingAnchor.constraint(equalTo: statusPillContainer.trailingAnchor, constant: -6),
            statusPillLabel.topAnchor.constraint(equalTo: statusPillContainer.topAnchor, constant: 2),
            statusPillLabel.bottomAnchor.constraint(equalTo: statusPillContainer.bottomAnchor, constant: -2),
        ])
        headerStack.addArrangedSubview(statusPillContainer)

        let headerSpacer = UIView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerStack.addArrangedSubview(headerSpacer)
    }

}
