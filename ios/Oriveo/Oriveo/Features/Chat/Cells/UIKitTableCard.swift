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

    private lazy var headerFont = UIFont.systemFont(ofSize: headerFontSize, weight: .semibold)
    private lazy var bodyFont = UIFont.systemFont(ofSize: bodyFontSize)


    private var computedHeight: CGFloat = 0
    /// Each cell's attributed text is rendered once and shared by layout, measuring, placeholders and
    /// UITextViews. It is rendered again only when an inline formula image lands or the appearance
    /// changes (formula image colors are baked in at render time).
    private var cellContents: [[NSAttributedString]] = []
    /// The appearance `cellContents` was rendered in; re-rendered when it differs from the view's
    /// current appearance and the table contains formulas.
    private var contentStyle: UIUserInterfaceStyle = .light
    private lazy var containsMath: Bool = {
        let mayHaveMath: (String) -> Bool = { $0.contains("$") || $0.contains("\\(") || $0.contains("\\[") }
        return tableData.headers.contains(where: mayHaveMath)
            || tableData.rows.contains(where: { $0.contains(where: mayHaveMath) })
    }()
    /// Row heights depend only on column widths and content: reused while the widths are unchanged,
    /// so upgrading cells or relaying out at the same width does not measure every cell again.
    private var rowHeights: [CGFloat] = []
    private var rowHeightsColumnWidths: [CGFloat] = []
    private var appliedBorderStyle: UIUserInterfaceStyle?


    private let scrollView = UIScrollView()
    private let tableContainer = UIView()
    private var heightConstraint: NSLayoutConstraint?
    private var lastLaidOutWidth: CGFloat = 0
    private var latexObserver: NSObjectProtocol?
    private var untrustedWidthFallbackScheduled = false

    /// Every subview of one row. Cells start as drawing placeholders with the same frame and
    /// attributed text (a plain UIView plus one text draw, pixel-identical to the UITextView), so the
    /// first frame shows the whole table. UITextViews (needed for selection questions, about 0.5ms
    /// each, on the order of 100ms for a 30 x 5 table) replace them in later idle frames under the
    /// shared budget of `TableCardCellUpgradeScheduler`.
    private struct RowViews {
        let rowView: UIView
        let topLine: UIView?
        let headerSeparator: UIView?
        /// `CellPlaceholderView` or `ChatPassiveTextView`
        var cells: [UIView]
        let columnLines: [UIView]
        var placeholderCount: Int
    }

    private var rowViews: [RowViews] = []
    private var placeholderCount = 0
    /// Set when an inline formula image finishes rendering or the appearance changes: the next layout
    /// re-renders cell text, for built and placeholder cells alike.
    private var needsCellContentRender = false

    var onAskSelection: ((QuoteSelectionContent) -> Void)? {
        didSet { bindAskSelection() }
    }
    var onIntrinsicHeightDidChange: (() -> Void)?

    // MARK: - Reuse across cells

    /// Chat list cell reuse clears frozen views; when the same table scrolls back on screen, take back
    /// the detached card instead of rebuilding the whole table (one UITextView per cell, about 100ms
    /// for 30 x 5). Matches the raw markdown lines exactly.
    private static let recycledCards = ChatRichCardRecyclePool<UIKitTableCard>(countLimit: 8)

    private var recycleKey: String?

    /// Takes back a detached card with the same content or builds a new one; returns nil when the
    /// lines do not parse as a table (the caller renders them as plain text).
    static func make(lines: [String]) -> UIKitTableCard? {
        let key = lines.joined(separator: "\n")
        if let card = recycledCards.take(key: key) {
            card.prepareForReuse()
            return card
        }
        guard let tableData = parseMarkdownLines(lines) else { return nil }
        let card = UIKitTableCard(tableData: tableData)
        card.recycleKey = key
        return card
    }

    /// Returns a card to the reuse pool after it has been removed from its cell. The previous cell's
    /// callbacks are cleared right away: the selection callback captures the whole message list through
    /// the render context, and clearing it only on the next take would keep that list alive in the pool.
    static func recycle(_ card: UIKitTableCard) {
        guard card.superview == nil, let key = card.recycleKey else { return }
        card.onIntrinsicHeightDidChange = nil
        card.onAskSelection = nil
        recycledCards.put(card, key: key)
    }

    static func purgeRecycledCards() {
        recycledCards.removeAll()
    }

    #if DEBUG
    static var recycledCardCountForTesting: Int { recycledCards.count }
    #endif

    /// Restores a freshly built card's state before it joins a new cell: no leftover entrance
    /// animation or horizontal scroll position.
    private func prepareForReuse() {
        layer.removeAllAnimations()
        alpha = 1
        transform = .identity
        scrollView.setContentOffset(.zero, animated: false)
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
        revalidateTraitDependentAppearance()
        let widthChanged = abs(availableWidth - lastLaidOutWidth) >= 0.5
        if !widthChanged && !needsCellContentRender { return }
        if widthChanged {
            // Transient widths from intermediate self-sizing passes must not re-run column widths or
            // height; keep the last layout until a real width arrives. See ChatCardStableWidth.
            if ChatCardStableWidth.isTrustworthy(width: availableWidth, anchor: ChatCardStableWidth.anchor(for: self)) {
                lastLaidOutWidth = availableWidth
            } else {
                #if DEBUG
                if ChatRenderDiagnostics.enabled {
                    AppLog.info(
                        "table card skipped a transient width of \(Int(availableWidth))",
                        module: "ChatRender"
                    )
                }
                #endif
                scheduleUntrustedWidthFallbackIfNeeded()
                // A landed formula image does not wait for a trustworthy width: refresh the content at
                // the last trusted width so drawn cells do not stay on `$...$`.
                guard needsCellContentRender else { return }
            }
        }
        layoutTable(availableWidth: lastLaidOutWidth)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // A pooled card may be taken back by a cell in the other appearance; returning to a window at
        // the same size does not run layoutSubviews again.
        revalidateTraitDependentAppearance()
        if needsCellContentRender {
            setNeedsLayout()
        }
        // The scheduler skips this card while it is off screen or in the reuse pool; back in a window,
        // the remaining placeholders continue upgrading to UITextViews.
        if placeholderCount > 0 {
            TableCardCellUpgradeScheduler.shared.enqueue(self)
        }
    }

    /// A touch on a row that is still placeholders upgrades that row to UITextViews before normal hit
    /// testing, so long-press selection and the Ask menu work from the first frame (a few milliseconds
    /// for a five-cell row, paid once on touch down).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if placeholderCount > 0, self.point(inside: point, with: event) {
            let pointInTable = convert(point, to: tableContainer)
            if let rowIdx = rowViews.firstIndex(where: { $0.rowView.frame.minY <= pointInTable.y && pointInTable.y < $0.rowView.frame.maxY }),
               rowViews[rowIdx].placeholderCount > 0 {
                traitCollection.performAsCurrent {
                    for j in rowViews[rowIdx].cells.indices {
                        upgradeCell(row: rowIdx, column: j)
                    }
                }
            }
        }
        return super.hitTest(point, with: event)
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

        let contentChanged = needsCellContentRender || cellContents.isEmpty
        if contentChanged {
            renderCellContents()
            needsCellContentRender = false
        }

        // Column widths fill the message width when the content is narrower, and keep horizontal
        // scrolling when it is wider.
        let naturalColumnWidths = computeColumnWidths()
        let columnWidths = adjustedColumnWidths(naturalColumnWidths, availableWidth: availableWidth)
        let totalWidth = columnWidths.reduce(0, +)
        let rowCount = tableData.rows.count + 1

        if contentChanged || columnWidths != rowHeightsColumnWidths {
            rowHeights = cellContents.map { cells in
                var maxH: CGFloat = 0
                for (j, attr) in cells.enumerated() {
                    let cellW = columnWidths[j] - cellPaddingH * 2
                    let size = MarkdownAttributedStringRenderer.measureTableCellContent(attr, maxWidth: cellW)
                    maxH = max(maxH, size.height)
                }
                return maxH + cellPaddingV * 2
            }
            rowHeightsColumnWidths = columnWidths
        }

        let totalHeight = rowHeights.reduce(0, +) + headerSepWidth + CGFloat(max(rowCount - 2, 0)) * gridLineWidth
        let heightChanged = abs(computedHeight - totalHeight) >= 0.5
        computedHeight = totalHeight
        heightConstraint?.constant = totalHeight

        if availableWidth >= 8 {
            if rowViews.isEmpty {
                buildRowSkeletons()
            } else if contentChanged {
                applyCellContents()
            }
            layoutRows(columnWidths: columnWidths, totalWidth: totalWidth)
            // Layout never builds a UITextView: placeholders already match the final pixels, and
            // upgrades happen only inside the scheduler's shared per-frame budget.
            if placeholderCount > 0 {
                TableCardCellUpgradeScheduler.shared.enqueue(self)
            }
        }

        tableContainer.frame = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        scrollView.contentSize = CGSize(width: totalWidth, height: totalHeight)
        invalidateIntrinsicContentSize()
        if heightChanged {
            onIntrinsicHeightDidChange?()
        }
    }

    private func renderCellContents() {
        let rowCount = tableData.rows.count + 1
        cellContents = (0..<rowCount).map { rowIdx in
            let isHeader = rowIdx == 0
            return cellsForRow(rowIdx).map { text in
                MarkdownAttributedStringRenderer.renderTableCellContent(
                    text,
                    font: isHeader ? headerFont : bodyFont,
                    textColor: isHeader ? Self.headerText : Self.cellText,
                    isHeader: isHeader
                )
            }
        }
        contentStyle = Self.effectiveStyle(UITraitCollection.current)
    }

    /// Builds every row skeleton (row background, separators, column lines) and cell placeholder at
    /// once. They are plain UIViews, so the first frame draws the whole table. Subview order and styling
    /// match the upgraded final state exactly; an upgrade replaces the placeholder in place.
    private func buildRowSkeletons() {
        let colCount = tableData.headers.count
        rowViews.reserveCapacity(cellContents.count)
        for (rowIdx, contents) in cellContents.enumerated() {
            let isHeader = rowIdx == 0

            let rowView = UIView()
            if isHeader {
                rowView.backgroundColor = Self.headerBg
            } else {
                rowView.backgroundColor = rowIdx % 2 == 0 ? Self.altRowBg : Self.cellBg
            }

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

            var cells: [UIView] = []
            var columnLines: [UIView] = []
            for (j, attr) in contents.enumerated() {
                let placeholder = CellPlaceholderView()
                placeholder.attributedText = attr
                rowView.addSubview(placeholder)
                cells.append(placeholder)

                if j < colCount - 1 {
                    let colLine = UIView()
                    colLine.backgroundColor = Self.borderColor.withAlphaComponent(0.25)
                    rowView.addSubview(colLine)
                    columnLines.append(colLine)
                }
            }
            // Attach the row only once it is assembled: adding subviews one by one to a row view that
            // is already in a window triggers a window callback for each of them.
            tableContainer.addSubview(rowView)
            rowViews.append(RowViews(
                rowView: rowView,
                topLine: topLine,
                headerSeparator: headerSeparator,
                cells: cells,
                columnLines: columnLines,
                placeholderCount: cells.count
            ))
            placeholderCount += cells.count
        }
    }

    private func layoutRows(columnWidths: [CGFloat], totalWidth: CGFloat) {
        let rowCount = rowViews.count
        var yOffset: CGFloat = 0
        for rowIdx in 0..<rowCount {
            let isHeader = rowIdx == 0
            let row = rowViews[rowIdx]
            let rowH = rowHeights[rowIdx]

            row.rowView.frame = CGRect(x: 0, y: yOffset, width: totalWidth, height: rowH)
            row.topLine?.frame = CGRect(x: 0, y: 0, width: totalWidth, height: gridLineWidth)
            row.headerSeparator?.frame = CGRect(x: 0, y: rowH - headerSepWidth, width: totalWidth, height: headerSepWidth)

            var xOffset: CGFloat = 0
            for (j, cell) in row.cells.enumerated() {
                let colW = columnWidths[j]
                cell.frame = CGRect(
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
    }

    private func applyCellContents() {
        for (rowIdx, row) in rowViews.enumerated() {
            for (j, cell) in row.cells.enumerated() {
                let attr = cellContents[rowIdx][j]
                if let label = cell as? ChatPassiveTextView {
                    label.attributedText = attr
                } else if let placeholder = cell as? CellPlaceholderView {
                    placeholder.attributedText = attr
                }
            }
        }
    }

    // MARK: - Upgrading placeholders to UITextViews

    /// Replaces placeholders with UITextViews until the deadline, visible rows first. Returns whether
    /// every cell is upgraded. With `guaranteesProgress`, at least one cell is upgraded so the scheduler
    /// always moves forward.
    @discardableResult
    func upgradePendingCells(until deadline: CFTimeInterval, guaranteesProgress: Bool) -> Bool {
        guard placeholderCount > 0 else { return true }
        var upgraded = 0
        // Scheduler callbacks run outside layout, where UITraitCollection.current is unreliable; build
        // with the card's own traits.
        traitCollection.performAsCurrent {
            for rowIdx in rowIndicesVisibleFirst() {
                for j in rowViews[rowIdx].cells.indices where rowViews[rowIdx].cells[j] is CellPlaceholderView {
                    if CACurrentMediaTime() >= deadline, !(guaranteesProgress && upgraded == 0) { return }
                    upgradeCell(row: rowIdx, column: j)
                    upgraded += 1
                }
            }
        }
        return placeholderCount == 0
    }

    private func rowIndicesVisibleFirst() -> [Int] {
        let pending = rowViews.indices.filter { rowViews[$0].placeholderCount > 0 }
        guard let window else { return pending }
        let visibleRect = window.bounds
        var visible: [Int] = []
        var offscreen: [Int] = []
        for rowIdx in pending {
            let rowView = rowViews[rowIdx].rowView
            if rowView.convert(rowView.bounds, to: window).intersects(visibleRect) {
                visible.append(rowIdx)
            } else {
                offscreen.append(rowIdx)
            }
        }
        return visible + offscreen
    }

    private func upgradeCell(row rowIdx: Int, column j: Int) {
        guard let placeholder = rowViews[rowIdx].cells[j] as? CellPlaceholderView else { return }
        let isHeader = rowIdx == 0
        // TextKit 1: same pixels, roughly 25% cheaper to create.
        let label = ChatPassiveTextView(usingTextLayoutManager: false)
        label.isEditable = false
        label.isSelectable = true
        label.isScrollEnabled = false
        label.backgroundColor = .clear
        label.textContainerInset = .zero
        label.textContainer.lineFragmentPadding = 0
        label.font = isHeader ? headerFont : bodyFont
        label.textColor = isHeader ? Self.headerText : Self.cellText
        let alignment = j < tableData.alignments.count ? tableData.alignments[j] : .left
        label.textAlignment = alignment.textAlignment
        label.quoteContentKind = .table
        label.attributedText = cellContents[rowIdx][j]
        label.frame = placeholder.frame
        placeholder.superview?.insertSubview(label, aboveSubview: placeholder)
        placeholder.removeFromSuperview()
        rowViews[rowIdx].cells[j] = label
        rowViews[rowIdx].placeholderCount -= 1
        placeholderCount -= 1
        bindAskSelection(label, rowCells: cellsForRow(rowIdx), column: j)
    }

    #if DEBUG
    /// Snapshots and measurements want the finished table: upgrade every placeholder synchronously.
    /// Production spreads upgrades across frames through the scheduler.
    func completeDeferredRows() {
        setNeedsLayout()
        layoutIfNeeded()
        upgradePendingCells(until: .infinity, guaranteesProgress: true)
    }

    /// Test seam: (rows, rows with content, rows that are all UITextViews, remaining placeholder cells).
    var _testCellCoverage: (rows: Int, rowsWithContent: Int, rowsWithTextViews: Int, placeholders: Int) {
        let withContent = rowViews.filter { !$0.cells.isEmpty }.count
        let upgraded = rowViews.filter { !$0.cells.isEmpty && $0.placeholderCount == 0 }.count
        return (tableData.rows.count + 1, withContent, upgraded, placeholderCount)
    }

    /// Test seam: the current cell view (placeholder or UITextView) at a row and column, and the
    /// attributed text it shows.
    func _testCell(row: Int, column: Int) -> (view: UIView, attributedText: NSAttributedString?)? {
        guard row < rowViews.count, column < rowViews[row].cells.count else { return nil }
        let cell = rowViews[row].cells[column]
        return (cell, (cell as? ChatPassiveTextView)?.attributedText ?? (cell as? CellPlaceholderView)?.attributedText)
    }

    /// Test seam: a row's frame in the card's coordinate space.
    func _testRowFrame(row: Int) -> CGRect? {
        guard row < rowViews.count else { return nil }
        let rowView = rowViews[row].rowView
        return rowView.convert(rowView.bounds, to: self)
    }
    #endif

    /// A selection question carries the row's other cells as context; stripping their markdown waits
    /// until a question is actually asked.
    private func bindAskSelection() {
        for (rowIdx, row) in rowViews.enumerated() {
            let cells = cellsForRow(rowIdx)
            for (j, cell) in row.cells.enumerated() {
                guard let label = cell as? ChatPassiveTextView else { continue }
                bindAskSelection(label, rowCells: cells, column: j)
            }
        }
    }

    private func bindAskSelection(_ label: ChatPassiveTextView, rowCells cells: [String], column j: Int) {
        guard let onAskSelection else {
            label.onAskSelection = nil
            return
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

    /// Fallback for a width that never becomes trustworthy (the card width does not match the
    /// ChatCardStableWidth anchor). Transient widths only appear in intermediate passes of one layout;
    /// if this run loop turn ends without a trustworthy width, the current width is final, so the table
    /// is built with it instead of staying a blank background.
    private func scheduleUntrustedWidthFallbackIfNeeded() {
        guard lastLaidOutWidth <= 0, !untrustedWidthFallbackScheduled else { return }
        untrustedWidthFallbackScheduled = true
        // Common modes: a table scrolled in during a drag needs the fallback too. RunLoop.perform also
        // runs when tests spin the run loop.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            self.untrustedWidthFallbackScheduled = false
            let width = self.bounds.width
            guard self.lastLaidOutWidth <= 0, width.isFinite, width >= 8 else { return }
            self.lastLaidOutWidth = width
            self.traitCollection.performAsCurrent {
                self.layoutTable(availableWidth: width)
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

    private static func effectiveStyle(_ traits: UITraitCollection) -> UIUserInterfaceStyle {
        traits.userInterfaceStyle == .dark ? .dark : .light
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

    private func computeColumnWidths() -> [CGFloat] {
        let colCount = tableData.headers.count

        let cacheKey = Self.columnWidthCacheKey(headers: tableData.headers, rows: tableData.rows)
        if let cached = Self.columnWidthCache.object(forKey: cacheKey) as? [CGFloat], cached.count == colCount {
            return cached
        }

        var widths = [CGFloat](repeating: minColumnWidth, count: colCount)
        let maxW = maxColumnWidth - cellPaddingH * 2

        // cellContents uses the same parameters as rendering each cell on the spot (semibold 13 for the
        // header, 14 for the body, same colors), so measurements are unchanged.
        for cells in cellContents {
            for (j, attr) in cells.enumerated() where j < colCount {
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
            view.revalidateTraitDependentAppearance()
            view.setNeedsLayout()
        }
    }

    /// CGColors and formula image colors are fixed when they are resolved. When the card's appearance
    /// changes (switching light and dark in place, or a pooled card taken back by a cell in the other
    /// appearance), resolve them again for the view's current appearance. Plain text colors are dynamic
    /// and follow at draw time without re-rendering.
    private func revalidateTraitDependentAppearance() {
        let style = Self.effectiveStyle(traitCollection)
        if appliedBorderStyle != style {
            appliedBorderStyle = style
            layer.borderColor = Self.borderColor.withAlphaComponent(0.5).resolvedColor(with: traitCollection).cgColor
        }
        if containsMath, !cellContents.isEmpty, contentStyle != style {
            needsCellContentRender = true
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
            // Independent of upgrade progress: the next layout re-renders every cell (UITextViews and
            // placeholders alike), so a notification arriving mid-upgrade never leaves built cells on `$...$`.
            self.needsCellContentRender = true
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

// MARK: - Cell placeholders

extension UIKitTableCard {
    /// A cell placeholder shown until its UITextView is built: same frame and attributed text, drawn
    /// directly with NSAttributedString. It matches a TextKit 1 UITextView pixel for pixel in light and
    /// dark, at fractional column widths, with wrapping, header kerning and inline formulas. It does not
    /// receive touches: the card's hitTest upgrades the row first.
    final class CellPlaceholderView: UIView {
        var attributedText: NSAttributedString? {
            didSet { setNeedsDisplay() }
        }

        override var bounds: CGRect {
            didSet {
                if bounds.size != oldValue.size { setNeedsDisplay() }
            }
        }

        override var frame: CGRect {
            didSet {
                if frame.size != oldValue.size { setNeedsDisplay() }
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear
            // When columns stretch to fractional widths, .redraw / .scaleToFill scale the whole-pixel
            // bitmap across the fractional bounds and glyph edges pick up one more antialiasing step than
            // the UITextView. Top-left alignment does not scale; size changes redraw explicitly.
            contentMode = .topLeft
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityTraits = .staticText
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var accessibilityLabel: String? {
            get { attributedText?.string }
            set {}
        }

        override func draw(_ rect: CGRect) {
            attributedText?.draw(
                with: CGRect(x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        }
    }
}

// MARK: - Placeholder upgrade scheduling

/// Shared scheduling for table cards upgrading cell placeholders to UITextViews: every card shares one
/// per-frame budget.
///
/// - Layout never builds UITextViews (placeholders already match the final pixels); upgrades happen only
///   here. Each frame (one display link callback) every pending card shares `frameBudget`, so several
///   tables entering the screen together do not each take a full budget and overrun the frame.
/// - Runs only in the default run loop mode: nothing upgrades while the user drags or the list
///   decelerates (tracking mode); it resumes after.
/// - Cards not in a window (off screen, in the reuse pool) are skipped and dropped from the queue;
///   `didMoveToWindow` enqueues them again.
/// - Visible cards upgrade first. Upgrades only make selection available, so the budget is
///   conservative and does not compete with scrolling or animations.
@MainActor
final class TableCardCellUpgradeScheduler {
    static let shared = TableCardCellUpgradeScheduler()

    static let frameBudget: CFTimeInterval = 0.004

    private var displayLink: CADisplayLink?
    private let cards = NSHashTable<UIKitTableCard>.weakObjects()

    private init() {}

    #if DEBUG
    /// Test seam: overrides the per-frame budget (0 upgrades a single cell per frame).
    var frameBudgetOverrideForTesting: CFTimeInterval?
    /// Test seam: pauses display-link-driven upgrades (to capture the placeholder-only first frame or
    /// to isolate measurements).
    var isPausedForTesting = false
    /// Test seam: runs one upgrade frame synchronously (same implementation as the display link callback).
    func runFrameForTesting() {
        runFrame()
    }
    #endif

    private var budget: CFTimeInterval {
        #if DEBUG
        if let frameBudgetOverrideForTesting { return frameBudgetOverrideForTesting }
        #endif
        return Self.frameBudget
    }

    func enqueue(_ card: UIKitTableCard) {
        cards.add(card)
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }
        link.add(to: .main, forMode: .default)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        #if DEBUG
        if isPausedForTesting { return }
        #endif
        runFrame()
    }

    private func runFrame() {
        let deadline = CACurrentMediaTime() + budget
        var visible: [UIKitTableCard] = []
        var offscreen: [UIKitTableCard] = []
        for card in cards.allObjects {
            guard let window = card.window else {
                cards.remove(card)
                continue
            }
            if card.convert(card.bounds, to: window).intersects(window.bounds) {
                visible.append(card)
            } else {
                offscreen.append(card)
            }
        }
        var madeProgress = false
        for card in visible + offscreen {
            if madeProgress, CACurrentMediaTime() >= deadline { break }
            // Upgrade at least one cell per frame so a single cell over budget cannot starve the queue.
            if card.upgradePendingCells(until: deadline, guaranteesProgress: !madeProgress) {
                cards.remove(card)
            }
            madeProgress = true
        }
        if cards.count == 0 {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    // A long-lived singleton; like StreamingDisplayClock, a nonisolated deinit avoids the iOS 18
    // back-deploy shim.
    nonisolated deinit {}
}
