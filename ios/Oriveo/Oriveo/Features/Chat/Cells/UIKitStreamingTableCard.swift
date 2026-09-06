import SwiftUI
import UIKit

final class UIKitStreamingTableCard: UIView {

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

    private lazy var headerFont = UIFont.systemFont(ofSize: headerFontSize, weight: .semibold)
    private lazy var bodyFont = UIFont.systemFont(ofSize: bodyFontSize)


    private let scrollView = UIScrollView()
    private let tableContainer = UIView()
    private var heightConstraint: NSLayoutConstraint?


    private var headers: [String] = []
    private var alignments: [UIKitTableCard.ColumnAlignment] = []
    private var dataRows: [[String]] = []

    private var rowViews: [UIView] = []
    private var cellLabels: [[UILabel]] = []
    private var headerSepLine: UIView?

    private var columnWidths: [CGFloat] = []
    private var totalHeight: CGFloat = 0
    private var lastLaidOutWidth: CGFloat = 0
    private var lastFittedWidth: CGFloat = 0
    private var latexObserver: NSObjectProtocol?
    var onIntrinsicHeightDidChange: (() -> Void)?

    private var lastTailCellsHash: Int = 0

    // MARK: - Init

    init?(initialLines: [String]) {
        super.init(frame: .zero)
        setupContainer()
        registerForTraitChanges()
        observeLatexRenders()
        guard ingestLines(initialLines) else { return nil }
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

    private func setupContainer() {
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

        let h = heightAnchor.constraint(equalToConstant: 0)
        h.priority = .required
        heightConstraint = h
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            h,
        ])
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: totalHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let availableWidth = bounds.width
        guard availableWidth.isFinite, availableWidth > 0 else { return }
        if abs(availableWidth - lastLaidOutWidth) >= 0.5 {
            if !ChatCardStableWidth.isTrustworthy(width: availableWidth, anchor: ChatCardStableWidth.anchor(for: self)) {
                #if DEBUG
                if ChatRenderDiagnostics.enabled {
                    AppLog.info(
                        "streaming table card skipped a transient width of \(Int(availableWidth))",
                        module: "ChatRender"
                    )
                }
                #endif
                return
            }
            lastLaidOutWidth = availableWidth
            refitToAvailableWidth()
        }
    }


    @discardableResult
    func updateLines(_ lines: [String]) -> Bool {
        ingestLines(lines)
    }


    @discardableResult
    private func ingestLines(_ lines: [String]) -> Bool {
        guard lines.count >= 2 else { return false }
        let headerCells = Self.parseTableRow(lines[0])
        let sepCells = Self.parseTableRow(lines[1])
        guard headerCells.count == sepCells.count, headerCells.count >= 1 else { return false }
        let newAlignments = sepCells.map(Self.parseAlignment)

        let headerChanged = headers != headerCells || alignments.map(\.textAlignment) != newAlignments.map(\.textAlignment)
        if headerChanged && !rowViews.isEmpty {
            tearDownAll()
        }
        headers = headerCells
        alignments = newAlignments

        let colCount = headers.count
        var newDataRows: [[String]] = []
        for i in 2..<lines.count {
            var cells = Self.parseTableRow(lines[i])
            while cells.count < colCount { cells.append("") }
            if cells.count > colCount { cells = Array(cells.prefix(colCount)) }
            newDataRows.append(cells)
        }

        applyDataRows(newDataRows)
        return true
    }

    private func applyDataRows(_ newRows: [[String]]) {
        let measured = computeColumnWidthsFromContent(headerCells: headers, dataRows: newRows)
        var widthsChanged = false
        if columnWidths.isEmpty {
            columnWidths = measured
            widthsChanged = true
        } else {
            for j in 0..<columnWidths.count {
                if measured[j] > columnWidths[j] {
                    columnWidths[j] = measured[j]
                    widthsChanged = true
                }
            }
        }

        if rowViews.isEmpty {
            let headerRow = buildHeaderRow()
            tableContainer.addSubview(headerRow)
            rowViews.append(headerRow)
        }

        let oldCount = dataRows.count
        let newCount = newRows.count

        let stableEnd = max(0, min(oldCount, newCount) - 1)
        for i in 0..<stableEnd {
            if dataRows[i] != newRows[i] {
                updateRowCells(rowIndex: i + 1, cells: newRows[i])
            }
        }

        if newCount > 0 {
            let tailIdx = newCount - 1
            if tailIdx < oldCount {
                if dataRows[tailIdx] != newRows[tailIdx] {
                    updateRowCells(rowIndex: tailIdx + 1, cells: newRows[tailIdx])
                }
            } else {
                for i in oldCount..<newCount {
                    let row = buildDataRow(cells: newRows[i], rowIndex: i)
                    tableContainer.addSubview(row)
                    rowViews.append(row)
                }
            }
        }

        while rowViews.count - 1 > newCount {
            let removed = rowViews.removeLast()
            removed.removeFromSuperview()
            if !cellLabels.isEmpty { cellLabels.removeLast() }
        }

        dataRows = newRows

        if widthsChanged {
            relayoutForColumnWidths()
        }

        recomputeHeightsAndLayout()
    }

    // MARK: - Build helpers

    private func buildHeaderRow() -> UIView {
        let row = UIView()
        row.backgroundColor = Self.headerBg
        row.clipsToBounds = false

        var labels: [UILabel] = []
        for j in 0..<headers.count {
            let label = UILabel()
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.font = headerFont
            label.textColor = Self.headerText
            label.textAlignment = (j < alignments.count ? alignments[j] : .left).textAlignment
            label.attributedText = MarkdownAttributedStringRenderer.renderTableCellContent(
                headers[j],
                font: headerFont,
                textColor: Self.headerText,
                isHeader: true
            )
            row.addSubview(label)
            labels.append(label)

            if j < headers.count - 1 {
                let colLine = UIView()
                colLine.backgroundColor = Self.borderColor.withAlphaComponent(0.25)
                colLine.tag = Self.colSeparatorTag
                row.addSubview(colLine)
            }
        }

        let sep = UIView()
        sep.backgroundColor = Self.borderColor
        sep.tag = Self.headerSepTag
        row.addSubview(sep)
        headerSepLine = sep

        cellLabels.insert(labels, at: 0)
        return row
    }

    private func buildDataRow(cells: [String], rowIndex: Int) -> UIView {
        let row = UIView()
        row.backgroundColor = rowIndex % 2 == 0 ? Self.altRowBg : Self.cellBg

        var labels: [UILabel] = []
        for j in 0..<headers.count {
            let label = UILabel()
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.font = bodyFont
            label.textColor = Self.cellText
            label.textAlignment = (j < alignments.count ? alignments[j] : .left).textAlignment
            label.attributedText = MarkdownAttributedStringRenderer.renderTableCellContent(
                j < cells.count ? cells[j] : "",
                font: bodyFont,
                textColor: Self.cellText,
                isHeader: false
            )
            row.addSubview(label)
            labels.append(label)

            if j < headers.count - 1 {
                let colLine = UIView()
                colLine.backgroundColor = Self.borderColor.withAlphaComponent(0.25)
                colLine.tag = Self.colSeparatorTag
                row.addSubview(colLine)
            }
        }

        if rowIndex >= 1 {
            let line = UIView()
            line.backgroundColor = Self.borderColor.withAlphaComponent(0.3)
            line.tag = Self.rowSeparatorTag
            row.addSubview(line)
        }

        cellLabels.append(labels)
        return row
    }

    private func updateRowCells(rowIndex: Int, cells: [String]) {
        guard rowIndex < cellLabels.count else { return }
        let labels = cellLabels[rowIndex]
        for j in 0..<labels.count {
            let attr = MarkdownAttributedStringRenderer.renderTableCellContent(
                j < cells.count ? cells[j] : "",
                font: bodyFont,
                textColor: Self.cellText,
                isHeader: false
            )
            labels[j].attributedText = attr
        }
    }


    private func computeColumnWidthsFromContent(headerCells: [String], dataRows: [[String]]) -> [CGFloat] {
        let colCount = headerCells.count
        var widths = [CGFloat](repeating: minColumnWidth, count: colCount)
        let maxW = maxColumnWidth - cellPaddingH * 2

        for (j, header) in headerCells.enumerated() {
            let attr = MarkdownAttributedStringRenderer.renderTableCellContent(
                header,
                font: headerFont,
                textColor: Self.headerText,
                isHeader: true
            )
            let size = MarkdownAttributedStringRenderer.measureTableCellContent(attr, maxWidth: maxW)
            widths[j] = max(widths[j], size.width + cellPaddingH * 2)
        }

        for row in dataRows {
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

        return widths.map { min($0, maxColumnWidth) }
    }

    private func refitToAvailableWidth() {
        let availableWidth = lastLaidOutWidth
        guard availableWidth > 0, !columnWidths.isEmpty else { return }
        let naturalTotal = columnWidths.reduce(0, +)
        let fittedWidths: [CGFloat]
        if naturalTotal > 0, naturalTotal < availableWidth {
            let extra = availableWidth - naturalTotal
            fittedWidths = columnWidths.map { $0 + extra * ($0 / naturalTotal) }
        } else {
            fittedWidths = columnWidths
        }
        let totalW = fittedWidths.reduce(0, +)
        if abs(totalW - lastFittedWidth) < 0.5 { return }
        lastFittedWidth = totalW
        applyLayoutWithWidths(fittedWidths)
    }

    private func relayoutForColumnWidths() {
        lastFittedWidth = 0 // force refit
        if lastLaidOutWidth > 0 {
            refitToAvailableWidth()
        } else {
            applyLayoutWithWidths(columnWidths)
        }
    }

    private func recomputeHeightsAndLayout() {
        if lastLaidOutWidth > 0 {
            lastFittedWidth = 0
            refitToAvailableWidth()
        } else {
            applyLayoutWithWidths(columnWidths)
        }
    }

    private func applyLayoutWithWidths(_ widths: [CGFloat]) {
        guard !widths.isEmpty, rowViews.count >= 1 else { return }
        let colCount = headers.count
        let totalWidth = widths.reduce(0, +)

        var rowHeights: [CGFloat] = []
        for rowIdx in 0..<rowViews.count {
            let isHeader = rowIdx == 0
            let font = isHeader ? headerFont : bodyFont
            let labels = rowIdx < cellLabels.count ? cellLabels[rowIdx] : []
            var maxH: CGFloat = 0
            for j in 0..<colCount {
                let cellW = widths[j] - cellPaddingH * 2
                if j < labels.count, let attr = labels[j].attributedText, attr.length > 0 {
                    let size = MarkdownAttributedStringRenderer.measureTableCellContent(attr, maxWidth: cellW)
                    maxH = max(maxH, size.height)
                }
            }
            maxH = max(maxH, ceil(font.lineHeight))
            rowHeights.append(maxH + cellPaddingV * 2)
        }

        var yOffset: CGFloat = 0
        for rowIdx in 0..<rowViews.count {
            let isHeader = rowIdx == 0
            let rowH = rowHeights[rowIdx]
            let row = rowViews[rowIdx]
            row.frame = CGRect(x: 0, y: yOffset, width: totalWidth, height: rowH)

            let labels = rowIdx < cellLabels.count ? cellLabels[rowIdx] : []
            var xOffset: CGFloat = 0
            for j in 0..<colCount {
                let colW = widths[j]
                if j < labels.count {
                    labels[j].frame = CGRect(
                        x: xOffset + cellPaddingH,
                        y: cellPaddingV,
                        width: colW - cellPaddingH * 2,
                        height: rowH - cellPaddingV * 2
                    )
                }
                xOffset += colW
            }

            let colSeparators = row.subviews.filter { $0.tag == Self.colSeparatorTag }
            var sepX: CGFloat = 0
            for (j, sepView) in colSeparators.enumerated() {
                if j < colCount - 1 {
                    sepX += widths[j]
                    sepView.frame = CGRect(
                        x: sepX - gridLineWidth / 2,
                        y: 0,
                        width: gridLineWidth,
                        height: rowH
                    )
                }
            }

            if isHeader, let sep = headerSepLine {
                sep.frame = CGRect(x: 0, y: rowH - headerSepWidth, width: totalWidth, height: headerSepWidth)
            }

            if rowIdx >= 2 {
                if let hLine = row.subviews.first(where: { $0.tag == Self.rowSeparatorTag }) {
                    hLine.frame = CGRect(x: 0, y: 0, width: totalWidth, height: gridLineWidth)
                }
            }

            yOffset += rowH
            if isHeader {
                yOffset += headerSepWidth
            } else if rowIdx < rowViews.count - 1 {
                yOffset += gridLineWidth
            }
        }

        let previousTotalHeight = totalHeight
        totalHeight = yOffset
        heightConstraint?.constant = totalHeight
        tableContainer.frame = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        scrollView.contentSize = CGSize(width: totalWidth, height: totalHeight)
        if abs(previousTotalHeight - totalHeight) > 0.5 {
            invalidateIntrinsicContentSize()
            onIntrinsicHeightDidChange?()
        }
    }

    // MARK: - Reset / tear down

    private func tearDownAll() {
        for row in rowViews { row.removeFromSuperview() }
        rowViews.removeAll()
        cellLabels.removeAll()
        headerSepLine = nil
        columnWidths.removeAll()
        dataRows.removeAll()
        totalHeight = 0
        lastFittedWidth = 0
        heightConstraint?.constant = 0
    }


    private func registerForTraitChanges() {
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: UIKitStreamingTableCard, _: UITraitCollection) in
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
            self.refreshLatexCells()
        }
    }

    private func containsLatex(_ latex: String) -> Bool {
        headers.contains(where: { $0.contains(latex) })
            || dataRows.contains(where: { $0.contains(where: { $0.contains(latex) }) })
    }

    private func refreshLatexCells() {
        if !headers.isEmpty, !cellLabels.isEmpty {
            let headerLabels = cellLabels[0]
            for j in 0..<headerLabels.count {
                headerLabels[j].attributedText = MarkdownAttributedStringRenderer.renderTableCellContent(
                    j < headers.count ? headers[j] : "",
                    font: headerFont,
                    textColor: Self.headerText,
                    isHeader: true
                )
            }
        }
        for rowIdx in 0..<dataRows.count {
            let labelIdx = rowIdx + 1
            guard labelIdx < cellLabels.count else { continue }
            updateRowCells(rowIndex: labelIdx, cells: dataRows[rowIdx])
        }
        lastFittedWidth = 0
        recomputeHeightsAndLayout()
    }


    static func parseTableRow(_ line: String) -> [String] {
        var trimmed = line
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    static func parseAlignment(_ separator: String) -> UIKitTableCard.ColumnAlignment {
        let s = separator.trimmingCharacters(in: .whitespaces)
        let left = s.hasPrefix(":")
        let right = s.hasSuffix(":")
        if left && right { return .center }
        if right { return .right }
        return .left
    }


    private static let colSeparatorTag = 9001
    private static let rowSeparatorTag = 9002
    private static let headerSepTag = 9003
}
