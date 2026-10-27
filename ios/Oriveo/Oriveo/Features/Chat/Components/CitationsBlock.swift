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
    #if DEBUG
    /// Screenshots only: start with the sources card expanded (manifest preset.sourcesExpanded).
    static var debugSearchSourcesExpanded = false
    #endif

    private var citations: [Citation] = []
    private var isExpanded: Bool = false
    /// External search sources card: the title becomes the three parts of the stored sourcesLine, collapsed by default,
    /// and tapping the title expands all sources. nil = an ordinary citations block.
    private var searchHeader: SearchSourcesHeaderPresentation?
    private let searchHeaderControl = SearchSourcesHeaderControl()
    /// In sources-card mode, library / MCP sources still go in an ordinary citations block (the card holds only external_search).
    private var otherSourcesBlock: CitationsBlock?

    /// The sources card holds only external search sources; the rest (library / MCP) is left to the ordinary citations block.
    nonisolated static func splitSearchSources(_ citations: [Citation]) -> (web: [Citation], others: [Citation]) {
        (
            citations.filter { $0.source == Citation.externalSearchSource },
            citations.filter { $0.source != Citation.externalSearchSource }
        )
    }

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

    func update(
        citations: [Citation],
        searchHeader: SearchSourcesHeaderPresentation? = nil,
        parentViewController: UIViewController
    ) {
        self.parentViewController = parentViewController
        let split = searchHeader == nil ? (web: citations, others: []) : Self.splitSearchSources(citations)
        updateOtherSources(split.others, parentViewController: parentViewController)
        let citations = split.web
        let changed = self.citations != citations || self.searchHeader != searchHeader
        guard changed else { return }
        if (self.searchHeader == nil) != (searchHeader == nil) {
            isExpanded = false
            #if DEBUG
            if searchHeader != nil { isExpanded = Self.debugSearchSourcesExpanded }
            #endif
        }
        self.citations = citations
        self.searchHeader = searchHeader
        rebuildItems()
    }

    private func updateOtherSources(_ others: [Citation], parentViewController: UIViewController) {
        guard !others.isEmpty else {
            if let block = otherSourcesBlock {
                containerStack.removeArrangedSubview(block)
                block.removeFromSuperview()
                otherSourcesBlock = nil
            }
            return
        }
        let block = otherSourcesBlock ?? {
            let new = CitationsBlock()
            new.onLayoutChange = { [weak self] in self?.onLayoutChange?() }
            containerStack.addArrangedSubview(new)
            otherSourcesBlock = new
            return new
        }()
        block.update(citations: others, parentViewController: parentViewController)
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

        searchHeaderControl.isHidden = true
        searchHeaderControl.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)
        containerStack.addArrangedSubview(searchHeaderControl)

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

        headerLabel.isHidden = searchHeader != nil
        searchHeaderControl.isHidden = searchHeader == nil
        if let searchHeader {
            // Sources card: collapsed to the title by default; expanded it lists every source by number. With 0 sources there is no arrow and it cannot be opened.
            searchHeaderControl.apply(searchHeader, expanded: isExpanded)
            let rows = isExpanded && searchHeader.expandable
                ? citations.enumerated()
                    .sorted { ($0.element.index ?? Int.max, $0.offset) < ($1.element.index ?? Int.max, $1.offset) }
                    .map(\.element)
                : []
            itemsStack.isHidden = rows.isEmpty
            for (offset, citation) in rows.enumerated() {
                itemsStack.addArrangedSubview(makeRow(for: citation, displayIndex: offset + 1))
            }
            toggleButton.isHidden = true
            return
        }
        itemsStack.isHidden = false

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
        if let searchHeader, !searchHeader.expandable { return }
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

// MARK: - External search sources card title

/// `Searched N times · service name [Custom] · N sources` plus an expand arrow (no arrow with 0 sources). The whole row is one button.
private final class SearchSourcesHeaderControl: UIControl {
    private let leadLabel = UILabel()
    private let badgeLabel = PaddedBadgeLabel()
    private let countLabel = UILabel()
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let row = UIStackView(arrangedSubviews: [leadLabel, badgeLabel, countLabel, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        for label in [leadLabel, countLabel] {
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = UIColor(OriveoTheme.Palette.textSecondary)
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        leadLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        badgeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        badgeLabel.textColor = UIColor(OriveoTheme.Palette.textSecondary)
        badgeLabel.backgroundColor = UIColor(OriveoTheme.Palette.surfaceInset)
        badgeLabel.layer.cornerRadius = 5
        badgeLabel.layer.cornerCurve = .continuous
        badgeLabel.clipsToBounds = true
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.tintColor = UIColor(OriveoTheme.Palette.textTertiary)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ header: SearchSourcesHeaderPresentation, expanded: Bool) {
        leadLabel.text = header.leadText + " · " + header.serviceName
        badgeLabel.text = header.customBadgeText
        badgeLabel.isHidden = header.customBadgeText == nil
        countLabel.text = "· " + header.countText
        chevron.isHidden = !header.expandable
        chevron.image = UIImage(systemName: expanded ? "chevron.up" : "chevron.down")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        isEnabled = header.expandable
        accessibilityLabel = [header.leadText, header.serviceName, header.customBadgeText, header.countText]
            .compactMap { $0 }
            .joined(separator: ", ")
        accessibilityTraits = header.expandable ? .button : .staticText
    }
}

private final class PaddedBadgeLabel: UILabel {
    private let insets = UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}
