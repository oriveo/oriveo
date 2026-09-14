import QuartzCore
import SwiftUI
import UIKit

final class UIKitTableCard: UIView {

    struct TableData {
        let headers: [String]
        let rows: [[String]]
        let alignments: [ColumnAlignment]
    }

    enum ColumnAlignment {
        case left, center, right

        var textAlignment: NSTextAlignment {
            switch self {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            }
        }
    }

    private let tableData: TableData


    private static let borderColor = UIColor(Color.dynamic(light: 0xCBD5E1, dark: 0x334155))
    private static let headerBg = UIColor(Color.dynamic(light: 0xF1F5F9, dark: 0x1E293B))
    private static let headerText = UIColor(OriveoTheme.Palette.textPrimary)
    private static let cellText = UIColor(OriveoTheme.Palette.textPrimary)
    private static let cellBg = UIColor(Color.dynamic(light: 0xFFFFFF, dark: 0x0F172A))
    private static let altRowBg = UIColor(Color.dynamic(light: 0xF8FAFC, dark: 0x131C2E))


    private let cellPaddingH: CGFloat = 12
    private let cellPaddingV: CGFloat = 8
    private let gridLineWidth: CGFloat = 1
    private let headerSepWidth: CGFloat = 1.5
    private let cornerRadius: CGFloat = 10
    private let bodyFontSize: CGFloat = 14
    private let headerFontSize: CGFloat = 13
    private let minColumnWidth: CGFloat = 60
    private let maxColumnWidth: CGFloat = 280


    private var computedHeight: CGFloat = 0


    private let scrollView = UIScrollView()
    private let tableContainer = UIView()
    private var heightConstraint: NSLayoutConstraint?
    private var lastLaidOutWidth: CGFloat = 0
    private var latexObserver: NSObjectProtocol?

    /// Every subview of one row. Cells are UITextViews (selection questions need them) at roughly
    /// 0.5-0.75ms each, so building a 30 x 5 table costs on the order of 100ms. Build them on the
    /// first layout only; later width changes just move frames.
    private struct RowViews {
        let rowView: UIView
        let topLine: UIView?
        let headerSeparator: UIView?
        let labels: [ChatPassiveTextView]
        let columnLines: [UIView]
    }

    private var rowViews: [RowViews] = []
    /// Set when an inline formula image finishes rendering: the next layout re-renders cell text.
    private var needsCellContentRender = false

    var onAskSelection: ((QuoteSelectionContent) -> Void)? {
        didSet { bindAskSelection() }
    }
    var onIntrinsicHeightDidChange: (() -> Void)?

    // MARK: - Reuse across cells

    /// Chat list cell reuse clears frozen views; when the same table scrolls back on screen, take back
    /// the detached card instead of rebuilding the whole table (one UITextView per cell, about 100ms
    /// for 30 x 5). Matches the raw markdown lines exactly and only holds detached cards, so the same
    /// table shown in two cells at once still builds a second card. NSCache evicts under memory pressure.
    private static let recycledCards: NSCache<NSString, UIKitTableCard> = {
        let cache = NSCache<NSString, UIKitTableCard>()
        cache.countLimit = 8
        return cache
    }()

    private var recycleKey: NSString?

    private static func recycleKey(for lines: [String]) -> NSString {
        NSString(string: lines.joined(separator: "\n"))
    }

    /// Takes back a detached card with the same content or builds a new one; returns nil when the
    /// lines do not parse as a table (the caller renders them as plain text).
    static func make(lines: [String]) -> UIKitTableCard? {
        let key = recycleKey(for: lines)
        if let card = recycledCards.object(forKey: key), card.superview == nil {
            recycledCards.removeObject(forKey: key)
            card.prepareForReuse()
            return card
        }
        guard let tableData = parseMarkdownLines(lines) else { return nil }
        let card = UIKitTableCard(tableData: tableData)
        card.recycleKey = key
        return card
    }

    /// Returns a card to the reuse pool after it has been removed from its cell.
    static func recycle(_ card: UIKitTableCard) {
        guard card.superview == nil, let key = card.recycleKey else { return }
        recycledCards.setObject(card, forKey: key)
    }

    /// Restores a freshly built card's state before it joins a new cell: no leftover entrance
    /// animation, horizontal scroll position or callbacks from the previous cell.
    private func prepareForReuse() {
        layer.removeAllAnimations()
        alpha = 1
        transform = .identity
        scrollView.setContentOffset(.zero, animated: false)
        onIntrinsicHeightDidChange = nil
        onAskSelection = nil
    }

    // MARK: - Init

    init(tableData: TableData) {
        self.tableData = tableData
        super.init(frame: .zero)
        buildTable()
        registerForTraitChanges()
        observeLatexRenders()
    }

    deinit {
        if let latexObserver {
            NotificationCenter.default.removeObserver(latexObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: computedHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let availableWidth = bounds.width
        guard availableWidth.isFinite, availableWidth > 0 else { return }
        let widthChanged = abs(availableWidth - lastLaidOutWidth) >= 0.5
        let rowCount = tableData.rows.count + 1
        // Deferred row builds keep the same width; the old early-return left the table stuck on the first slice.
        let needsMoreRows = lastLaidOutWidth >= 8 && rowViews.count < rowCount
        if !widthChanged && !needsMoreRows { return }
        if widthChanged {
            if !ChatCardStableWidth.isTrustworthy(width: availableWidth, anchor: ChatCardStableWidth.anchor(for: self)) {
                #if DEBUG
                if ChatRenderDiagnostics.enabled {
                    AppLog.info(
                        "table card skipped a transient width of \(Int(availableWidth))",
                        module: "ChatRender"
                    )
                }
                #endif
                return
            }
            lastLaidOutWidth = availableWidth
        }
        layoutTable(availableWidth: availableWidth)
    }


    private func buildTable() {
        let colCount = tableData.headers.count
        guard colCount > 0 else { return }

        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = gridLineWidth
        layer.borderColor = Self.borderColor.withAlphaComponent(0.5).cgColor
        clipsToBounds = true
        backgroundColor = Self.cellBg

        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(tableContainer)

        let heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            heightConstraint,
        ])

        layoutTable(availableWidth: 0)
    }

    private func layoutTable(availableWidth: CGFloat) {
        let colCount = tableData.headers.count
        guard colCount > 0 else { return }

        let headerFont = UIFont.systemFont(ofSize: headerFontSize, weight: .semibold)
        let bodyFont = UIFont.systemFont(ofSize: bodyFontSize)

        let naturalColumnWidths = computeColumnWidths(headerFont: headerFont, bodyFont: bodyFont)
        let columnWidths = adjustedColumnWidths(naturalColumnWidths, availableWidth: availableWidth)
        let totalWidth = columnWidths.reduce(0, +)

        let rowCount = tableData.rows.count + 1
        var rowHeights = [CGFloat]()

        for rowIdx in 0..<rowCount {
            let isHeader = rowIdx == 0
            let cells = cellsForRow(rowIdx)
            let font = isHeader ? headerFont : bodyFont

            var maxH: CGFloat = 0
            for (j, text) in cells.enumerated() where j < colCount {
                let attr = MarkdownAttributedStringRenderer.renderTableCellContent(
                    text,
                    font: font,
                    textColor: isHeader ? Self.headerText : Self.cellText,
                    isHeader: isHeader
                )
                let cellW = columnWidths[j] - cellPaddingH * 2
                let size = MarkdownAttributedStringRenderer.measureTableCellContent(attr, maxWidth: cellW)
                maxH = max(maxH, size.height)
            }
            rowHeights.append(maxH + cellPaddingV * 2)
        }

        let totalHeight = rowHeights.reduce(0, +) + headerSepWidth + CGFloat(max(rowCount - 2, 0)) * gridLineWidth
        let heightChanged = abs(computedHeight - totalHeight) >= 0.5
        computedHeight = totalHeight
        heightConstraint?.constant = totalHeight

        if availableWidth >= 8, rowViews.count < rowCount {
            buildRowViews(rowCount: rowCount, headerFont: headerFont, bodyFont: bodyFont)
        } else if needsCellContentRender, !rowViews.isEmpty {
            renderCellContent(headerFont: headerFont, bodyFont: bodyFont)
        }
        needsCellContentRender = false

        // Rows may still be filling in across frames; only place views that exist.
        var yOffset: CGFloat = 0
        for rowIdx in 0..<rowViews.count {
            let isHeader = rowIdx == 0
            let row = rowViews[rowIdx]
            let rowH = rowHeights[rowIdx]

            row.rowView.frame = CGRect(x: 0, y: yOffset, width: totalWidth, height: rowH)
            row.topLine?.frame = CGRect(x: 0, y: 0, width: totalWidth, height: gridLineWidth)
            row.headerSeparator?.frame = CGRect(x: 0, y: rowH - headerSepWidth, width: totalWidth, height: headerSepWidth)

            var xOffset: CGFloat = 0
            for (j, label) in row.labels.enumerated() {
                let colW = columnWidths[j]
                label.frame = CGRect(
                    x: xOffset + cellPaddingH,
                    y: cellPaddingV,
                    width: colW - cellPaddingH * 2,
                    height: rowH - cellPaddingV * 2
                )
                if j < row.columnLines.count {
                    row.columnLines[j].frame = CGRect(
                        x: xOffset + colW - gridLineWidth / 2,
                        y: 0,
                        width: gridLineWidth,
                        height: rowH
                    )
                }
                xOffset += colW
            }

            yOffset += rowH
            if isHeader {
                yOffset += headerSepWidth
            } else if rowIdx < rowCount - 1 {
                yOffset += gridLineWidth
            }
        }

        tableContainer.frame = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        scrollView.contentSize = CGSize(width: totalWidth, height: totalHeight)
        invalidateIntrinsicContentSize()
        if heightChanged {
            onIntrinsicHeightDidChange?()
        }
    }

    /// Builds row views. Heights are already fixed by `layoutTable` via boundingRect, so
    /// UITextViews can fill in across frames. Each frame stays under about 8ms so a 155-cell
    /// TextKit build does not land in a single frame.
    private func buildRowViews(rowCount: Int, headerFont: UIFont, bodyFont: UIFont) {
        let colCount = tableData.headers.count
        if rowViews.isEmpty {
            rowViews.reserveCapacity(rowCount)
        }
        let budgetStart = CACurrentMediaTime()
        let budget: CFTimeInterval = 0.008
        while rowViews.count < rowCount, CACurrentMediaTime() - budgetStart < budget {
            let rowIdx = rowViews.count
            let isHeader = rowIdx == 0
            let cells = cellsForRow(rowIdx)
            let font = isHeader ? headerFont : bodyFont

            let rowView = UIView()
            if isHeader {
                rowView.backgroundColor = Self.headerBg
            } else {
                rowView.backgroundColor = rowIdx % 2 == 0 ? Self.altRowBg : Self.cellBg
            }
            tableContainer.addSubview(rowView)

            var topLine: UIView?
            if rowIdx > 1 {
                let line = UIView()
                line.backgroundColor = Self.borderColor.withAlphaComponent(0.3)
                rowView.addSubview(line)
                topLine = line
            }

            var headerSeparator: UIView?
            if isHeader {
                let sep = UIView()
                sep.backgroundColor = Self.borderColor
                rowView.addSubview(sep)
                headerSeparator = sep
            }

            var labels: [ChatPassiveTextView] = []
            var columnLines: [UIView] = []
            for (j, text) in cells.enumerated() where j < colCount {
                // TextKit 1: same pixels, roughly 25% cheaper to create.
                let label = ChatPassiveTextView(usingTextLayoutManager: false)
                label.isEditable = false
                label.isSelectable = true
                label.isScrollEnabled = false
                label.backgroundColor = .clear
                label.textContainerInset = .zero
                label.textContainer.lineFragmentPadding = 0
                label.font = font
                label.textColor = isHeader ? Self.headerText : Self.cellText
                let alignment = j < tableData.alignments.count ? tableData.alignments[j] : .left
                label.textAlignment = alignment.textAlignment
                label.quoteContentKind = .table
                label.attributedText = MarkdownAttributedStringRenderer.renderTableCellContent(
                    text,
                    font: font,
                    textColor: isHeader ? Self.headerText : Self.cellText,
                    isHeader: isHeader
                )
                rowView.addSubview(label)
                labels.append(label)

                if j < colCount - 1 {
                    let colLine = UIView()
                    colLine.backgroundColor = Self.borderColor.withAlphaComponent(0.25)
                    rowView.addSubview(colLine)
                    columnLines.append(colLine)
                }
            }
            rowViews.append(RowViews(
                rowView: rowView,
                topLine: topLine,
                headerSeparator: headerSeparator,
                labels: labels,
                columnLines: columnLines
            ))
        }
        bindAskSelection()
        if rowViews.count < rowCount {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
        }
    }

    /// Snapshots and measurements want the finished table. Production still fills rows
    /// under the 8ms budget so the first frame stays responsive.
    func completeDeferredRows() {
        let rowCount = tableData.rows.count + 1
        var steps = 0
        while rowViews.count < rowCount, steps < 64 {
            setNeedsLayout()
            layoutIfNeeded()
            steps += 1
        }
    }

    private func renderCellContent(headerFont: UIFont, bodyFont: UIFont) {
        for (rowIdx, row) in rowViews.enumerated() {
            let isHeader = rowIdx == 0
            let cells = cellsForRow(rowIdx)
            for (j, label) in row.labels.enumerated() where j < cells.count {
                label.attributedText = MarkdownAttributedStringRenderer.renderTableCellContent(
                    cells[j],
                    font: isHeader ? headerFont : bodyFont,
                    textColor: isHeader ? Self.headerText : Self.cellText,
                    isHeader: isHeader
                )
            }
        }
    }

    /// A selection question carries the row's other cells as context; stripping their markdown waits
    /// until a question is actually asked.
    private func bindAskSelection() {
        for (rowIdx, row) in rowViews.enumerated() {
            let cells = cellsForRow(rowIdx)
            for (j, label) in row.labels.enumerated() {
                guard let onAskSelection else {
                    label.onAskSelection = nil
                    continue
                }
                label.onAskSelection = { selection in
                    let strippedCells = cells.map(Self.stripMarkdown)
                    let prefix = strippedCells.prefix(j).joined(separator: " | ")
                    let suffix = strippedCells.dropFirst(j + 1).joined(separator: " | ")
                    onAskSelection(QuoteSelectionContent(
                        contentKind: .table,
                        leadingText: prefix.isEmpty
                            ? selection.leadingText
                            : prefix + " | " + selection.leadingText,
                        selectedText: selection.selectedText,
                        trailingText: suffix.isEmpty
                            ? selection.trailingText
                            : selection.trailingText + " | " + suffix
                    ))
                }
            }
        }
    }


    private func cellsForRow(_ rowIdx: Int) -> [String] {
        let colCount = tableData.headers.count
        if rowIdx == 0 { return tableData.headers }
        let dataRow = tableData.rows[rowIdx - 1]
        var padded = dataRow
        while padded.count < colCount { padded.append("") }
        return Array(padded.prefix(colCount))
    }

    private static let columnWidthCache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 100
        return cache
    }()

    private static func columnWidthCacheKey(headers: [String], rows: [[String]]) -> NSString {
        var hasher = Hasher()
        for h in headers { hasher.combine(h) }
        for row in rows { for c in row { hasher.combine(c) } }
        return NSString(string: String(hasher.finalize()))
    }

    private func computeColumnWidths(headerFont: UIFont, bodyFont: UIFont) -> [CGFloat] {
        let colCount = tableData.headers.count

        let cacheKey = Self.columnWidthCacheKey(headers: tableData.headers, rows: tableData.rows)
        if let cached = Self.columnWidthCache.object(forKey: cacheKey) as? [CGFloat], cached.count == colCount {
            return cached
        }

        var widths = [CGFloat](repeating: minColumnWidth, count: colCount)
        let maxW = maxColumnWidth - cellPaddingH * 2

        for (j, header) in tableData.headers.enumerated() {
            let attr = MarkdownAttributedStringRenderer.renderTableCellContent(
                header,
                font: headerFont,
                textColor: Self.headerText,
                isHeader: true
            )
            let size = MarkdownAttributedStringRenderer.measureTableCellContent(attr, maxWidth: maxW)
            widths[j] = max(widths[j], size.width + cellPaddingH * 2)
        }

        for row in tableData.rows {
            for (j, cell) in row.enumerated() where j < colCount {
                let attr = MarkdownAttributedStringRenderer.renderTableCellContent(
                    cell,
                    font: bodyFont,
                    textColor: Self.cellText,
                    isHeader: false
                )
                let size = MarkdownAttributedStringRenderer.measureTableCellContent(attr, maxWidth: maxW)
                widths[j] = max(widths[j], size.width + cellPaddingH * 2)
            }
        }

        let clamped = widths.map { min($0, maxColumnWidth) }
        Self.columnWidthCache.setObject(clamped as NSArray, forKey: cacheKey)
        return clamped
    }

    private func adjustedColumnWidths(_ naturalWidths: [CGFloat], availableWidth: CGFloat) -> [CGFloat] {
        guard availableWidth.isFinite, availableWidth > 0 else { return naturalWidths }
        let naturalTotal = naturalWidths.reduce(0, +)
        guard naturalTotal > 0, naturalTotal < availableWidth else { return naturalWidths }

        let extra = availableWidth - naturalTotal
        return naturalWidths.map { width in
            width + extra * (width / naturalTotal)
        }
    }


    private func registerForTraitChanges() {
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: UIKitTableCard, _: UITraitCollection) in
            view.layer.borderColor = Self.borderColor.withAlphaComponent(0.5).cgColor
        }
    }

    private func observeLatexRenders() {
        latexObserver = NotificationCenter.default.addObserver(
            forName: LatexImageCache.didRenderNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let latex = note.userInfo?[LatexImageCache.userInfoLatexKey] as? String,
                  !latex.isEmpty, self.containsLatex(latex) else { return }
            Self.columnWidthCache.removeObject(
                forKey: Self.columnWidthCacheKey(headers: self.tableData.headers, rows: self.tableData.rows)
            )
            self.needsCellContentRender = true
            self.lastLaidOutWidth = -1
            self.setNeedsLayout()
            self.invalidateIntrinsicContentSize()
        }
    }

    private func containsLatex(_ latex: String) -> Bool {
        tableData.headers.contains(where: { $0.contains(latex) })
            || tableData.rows.contains(where: { $0.contains(where: { $0.contains(latex) }) })
    }


    private static let mdBoldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    private static let mdItalicRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*([^*]+?)\\*(?!\\*)")
    private static let mdCodeRegex = try! NSRegularExpression(pattern: "`([^`]+)`")
    private static let mdStrikeRegex = try! NSRegularExpression(pattern: "~~(.+?)~~")
    private static let mdLinkRegex = try! NSRegularExpression(pattern: "\\[(.+?)\\]\\((.+?)\\)")

    static func stripMarkdown(_ text: String) -> String {
        var s = text
        s = mdBoldRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        s = mdItalicRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        s = mdCodeRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        s = mdStrikeRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        s = mdLinkRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        return s
    }


    static func parseMarkdownLines(_ lines: [String]) -> TableData? {
        guard lines.count >= 2 else { return nil }

        let headerCells = parseTableRow(lines[0])
        let sepCells = parseTableRow(lines[1])
        guard headerCells.count == sepCells.count, headerCells.count >= 1 else { return nil }

        let alignments = sepCells.map { parseAlignment($0) }
        let colCount = headerCells.count

        var dataRows: [[String]] = []
        for i in 2..<lines.count {
            var cells = parseTableRow(lines[i])
            while cells.count < colCount { cells.append("") }
            if cells.count > colCount { cells = Array(cells.prefix(colCount)) }
            dataRows.append(cells)
        }

        return TableData(headers: headerCells, rows: dataRows, alignments: alignments)
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var trimmed = line
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func parseAlignment(_ separator: String) -> ColumnAlignment {
        let s = separator.trimmingCharacters(in: .whitespaces)
        let left = s.hasPrefix(":")
        let right = s.hasSuffix(":")
        if left && right { return .center }
        if right { return .right }
        return .left
    }
}
