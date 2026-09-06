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
    var onAskSelection: ((QuoteSelectionContent) -> Void)? {
        didSet {
            lastLaidOutWidth = -1
            setNeedsLayout()
        }
    }
    var onIntrinsicHeightDidChange: (() -> Void)?

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
        guard abs(availableWidth - lastLaidOutWidth) >= 0.5 else { return }
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

        tableContainer.subviews.forEach { $0.removeFromSuperview() }

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

        var yOffset: CGFloat = 0
        for rowIdx in 0..<rowCount {
            let isHeader = rowIdx == 0
            let cells = cellsForRow(rowIdx)
            let font = isHeader ? headerFont : bodyFont
            let rowH = rowHeights[rowIdx]

            let rowBg: UIColor
            if isHeader {
                rowBg = Self.headerBg
            } else {
                rowBg = rowIdx % 2 == 0 ? Self.altRowBg : Self.cellBg
            }

            let rowView = UIView()
            rowView.backgroundColor = rowBg
            rowView.frame = CGRect(x: 0, y: yOffset, width: totalWidth, height: rowH)
            tableContainer.addSubview(rowView)

            if rowIdx > 1 {
                let line = UIView()
                line.backgroundColor = Self.borderColor.withAlphaComponent(0.3)
                line.frame = CGRect(x: 0, y: 0, width: totalWidth, height: gridLineWidth)
                rowView.addSubview(line)
            }

            if isHeader {
                let sep = UIView()
                sep.backgroundColor = Self.borderColor
                sep.frame = CGRect(x: 0, y: rowH - headerSepWidth, width: totalWidth, height: headerSepWidth)
                rowView.addSubview(sep)
            }

            var xOffset: CGFloat = 0
            for (j, text) in cells.enumerated() where j < colCount {
                let colW = columnWidths[j]

                let label = ChatPassiveTextView()
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

                if let onAskSelection {
                    let strippedCells = cells.map(Self.stripMarkdown)
                    let prefix = strippedCells.prefix(j).joined(separator: " | ")
                    let suffix = strippedCells.dropFirst(j + 1).joined(separator: " | ")
                    label.onAskSelection = { selection in
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

                label.frame = CGRect(
                    x: xOffset + cellPaddingH,
                    y: cellPaddingV,
                    width: colW - cellPaddingH * 2,
                    height: rowH - cellPaddingV * 2
                )
                rowView.addSubview(label)

                if j < colCount - 1 {
                    let colLine = UIView()
                    colLine.backgroundColor = Self.borderColor.withAlphaComponent(0.25)
                    colLine.frame = CGRect(
                        x: xOffset + colW - gridLineWidth / 2,
                        y: 0,
                        width: gridLineWidth,
                        height: rowH
                    )
                    rowView.addSubview(colLine)
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
