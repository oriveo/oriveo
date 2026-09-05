import SafariServices
import SwiftUI
import UIKit

struct CitationRowPresentation: Equatable {
    let symbolName: String
    let title: String
    let detail: String

    @MainActor
    static func make(citation: Citation) -> CitationRowPresentation {
        let host = URL(string: citation.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        let trimmedTitle = citation.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CitationRowPresentation(
            symbolName: "globe",
            title: !trimmedTitle.isEmpty ? trimmedTitle : (!host.isEmpty ? host : citation.url),
            detail: host
        )
    }
}

final class CitationsBlock: UIView {
    nonisolated static let collapsedLimit = 3

    private var citations: [Citation] = []
    private var isExpanded: Bool = false

    private let containerStack = UIStackView()
    private let headerLabel = UILabel()
    private let itemsStack = UIStackView()
    private let toggleButton = UIButton(type: .system)

    private weak var parentViewController: UIViewController?

    var onLayoutChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    func update(citations: [Citation], parentViewController: UIViewController) {
        let changed = self.citations != citations
        self.parentViewController = parentViewController
        guard changed else { return }
        self.citations = citations
        rebuildItems()
    }

    // MARK: - Setup

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        backgroundColor = .clear

        containerStack.axis = .vertical
        containerStack.spacing = OriveoTheme.Spacing.sm
        containerStack.alignment = .fill
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerStack)
        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor),
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        headerLabel.text = L10n.tr("Sources", table: .chat)
        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headerLabel.textColor = UIColor(OriveoTheme.Palette.textSecondary)
        containerStack.addArrangedSubview(headerLabel)

        itemsStack.axis = .vertical
        itemsStack.spacing = 6
        itemsStack.alignment = .fill
        containerStack.addArrangedSubview(itemsStack)

        toggleButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        toggleButton.contentHorizontalAlignment = .leading
        toggleButton.setTitleColor(UIColor(OriveoTheme.Palette.primary), for: .normal)
        toggleButton.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)
        toggleButton.isHidden = true
        containerStack.addArrangedSubview(toggleButton)
    }


    private func rebuildItems() {
        for view in itemsStack.arrangedSubviews {
            itemsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let visible = isExpanded
            ? citations
            : Array(citations.prefix(Self.collapsedLimit))

        for (offset, citation) in visible.enumerated() {
            let row = makeRow(for: citation, displayIndex: offset + 1)
            itemsStack.addArrangedSubview(row)
        }

        if citations.count > Self.collapsedLimit {
            toggleButton.isHidden = false
            let title: String
            if isExpanded {
                title = L10n.tr("Show less", table: .chat)
            } else {
                let template = L10n.tr("View all %d citations", table: .chat)
                title = String(format: template, citations.count)
            }
            toggleButton.setTitle(title, for: .normal)
        } else {
            toggleButton.isHidden = true
        }
    }

    @objc private func toggleTapped() {
        isExpanded.toggle()
        rebuildItems()
        onLayoutChange?()
    }


    private func makeRow(for citation: Citation, displayIndex: Int) -> UIView {
        let row = CitationRowView(citation: citation, displayIndex: displayIndex)
        row.translatesAutoresizingMaskIntoConstraints = false
        guard ExternalURLPolicy.httpsURL(from: citation.url) != nil else {
            row.isUserInteractionEnabled = false
            return row
        }
        row.onTap = { [weak self] in
            self?.openCitation(citation)
        }
        return row
    }

    private func openCitation(_ citation: Citation) {
        guard let url = ExternalURLPolicy.httpsURL(from: citation.url) else { return }

        if let presenter = parentViewController {
            let safari = SFSafariViewController(url: url)
            presenter.present(safari, animated: true)
        } else {
            UIApplication.shared.open(url)
        }
    }
}


private final class CitationRowView: UIControl {
    private let citation: Citation
    private let displayIndex: Int

    private let indexLabel = UILabel()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let domainLabel = UILabel()

    var onTap: (() -> Void)?

    init(citation: Citation, displayIndex: Int) {
        self.citation = citation
        self.displayIndex = displayIndex
        super.init(frame: .zero)
        setupViews()
        bind()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = UIColor(OriveoTheme.Palette.surfaceInset)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(OriveoTheme.Palette.border).cgColor

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        row.layoutMargins = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.isLayoutMarginsRelativeArrangement = true
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        indexLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        indexLabel.textColor = UIColor(OriveoTheme.Palette.primary)
        indexLabel.setContentHuggingPriority(.required, for: .horizontal)
        indexLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(indexLabel)

        // Source-specific symbol is bound with the citation below.
        iconView.tintColor = UIColor(OriveoTheme.Palette.textTertiary)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(iconView)

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = UIColor(OriveoTheme.Palette.textPrimary)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(titleLabel)

        domainLabel.font = .systemFont(ofSize: 11, weight: .regular)
        domainLabel.textColor = UIColor(OriveoTheme.Palette.textTertiary)
        domainLabel.numberOfLines = 1
        domainLabel.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(domainLabel)

        row.addArrangedSubview(textStack)
    }

    private func bind() {
        let presentation = CitationRowPresentation.make(citation: citation)
        let shown = citation.index ?? displayIndex
        indexLabel.text = "[\(shown)]"

        iconView.image = UIImage(systemName: presentation.symbolName)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        titleLabel.text = presentation.title
        domainLabel.text = presentation.detail
        domainLabel.isHidden = presentation.detail.isEmpty
    }

    @objc private func handleTap() {
        onTap?()
    }
}
