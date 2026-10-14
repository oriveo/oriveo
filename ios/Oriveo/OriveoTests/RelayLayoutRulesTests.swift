import Foundation
import Testing
@testable import Oriveo

/// Layout gate for the trailing column of relay-family rows: a row marked "vertically centered on the whole row / note" must have an outer HStack with `.center` alignment,
/// and its right column must not use `.padding(.top` to pin itself back to the title line. This is a source-level regression gate; the real look is still judged on the sample screens.
@Suite("Relay trailing column centered on the whole row")
struct RelayLayoutRulesTests {
    /// Files relative to `Oriveo/Features/Providers/`; each file must have at least one anchor.
    private static let files = [
        "RelayModelAdvancedPage.swift",
        "RelayEditBoardView.swift",
        "RelayDetailBoardView.swift",
        "RelayKeysPage.swift",
        "RelaySetupStepViews.swift",
        "RelayCatalogBoardViews.swift",
        "RelayCapabilityTestPanel.swift",
    ]

    /// Row type -> file (page coverage). `marker` is a phrase that must appear on the anchor comment line: when a file has several anchors,
    /// it identifies the one that governs this row type. When rewording an anchor comment, change the marker with it and keep the "vertically centered on the whole row / note" wording.
    private static let rowTypes: [(rowType: String, file: String, marker: String)] = [
        ("Key row", "RelayKeysPage.swift", "the trailing column has only the status"),
        ("Model library enabled row", "RelayCatalogBoardViews.swift", "enabled row"),
        ("Model library catalog row", "RelayCatalogBoardViews.swift", "catalog row"),
        ("Detail row", "RelayDetailBoardView.swift", "trailing hint and chevron"),
        ("Edit / manual-setup menu row", "RelayEditBoardView.swift", "The right column is vertically centered"),
        ("Step 1 check row", "RelaySetupStepViews.swift", "Elapsed time is its own column"),
        ("Advanced key row", "RelayModelAdvancedPage.swift", "picker menu"),
        ("Capability test header", "RelayCapabilityTestPanel.swift", "capability test header"),
    ]

    /// Anchor comments say "vertically centered on the whole row" (or "against the whole note" for the add-key row).
    private static let anchorPattern = try! NSRegularExpression(
        pattern: "^\\s*//.*vertically cent(er|ered).*whole (row|note)",
        options: [.caseInsensitive]
    )

    /// An HStack within a few lines after the comment, before the enclosing block closes, is the row it governs (including wrapped function signatures);
    /// otherwise the comment sits on the right column and governs the HStack that wraps it.
    private static let forwardLookahead = 6

    private struct Anchor {
        let file: String
        let line: Int
    }

    @Test("RL2-LAYOUT-TRAILING-01 rows anchored as vertically centered on the whole row: outer HStack(alignment: .center and no .padding(.top inside")
    func trailingColumnsStayCenteredOnWholeRow() throws {
        var anchors: [Anchor] = []
        for file in Self.files {
            let lines = try Self.lines(of: file)
            let hits = lines.indices.filter { Self.isAnchor(lines[$0]) }
            #expect(!hits.isEmpty, "\(file) has no \"vertically centered on the whole row\" anchor comment: if the comment is reworded, update this gate so the anchor is not silently lost")
            for index in hits {
                anchors.append(Anchor(file: file, line: index))
                let stack = try #require(
                    Self.governingHStack(in: lines, anchor: index),
                    "\(file):\(index + 1) the anchor comment cannot find the HStack it governs"
                )
                let opening = lines[stack.lowerBound]
                #expect(
                    opening.contains("HStack(alignment: .center"),
                    "\(file):\(stack.lowerBound + 1) the outer container of an anchored row is not HStack(alignment: .center: \(opening.trimmingCharacters(in: .whitespaces))"
                )
                let paddedTop = stack.filter { lines[$0].contains(".padding(.top") }
                #expect(
                    paddedTop.isEmpty,
                    "\(file) line(s) \(paddedTop.map { String($0 + 1) }.joined(separator: ", ")) use .padding(.top inside a whole-row-centered row, which pins the right column back to the title line"
                )
            }
        }
        #expect(anchors.count >= 6, "Only \(anchors.count) anchors left (expected at least 6): anchor comments were widely reworded or deleted")
    }

    @Test("RL2-LAYOUT-TRAILING-02 page coverage: each of the 8 row types has at least one \"vertically centered on the whole row\" anchor")
    func everyRowTypeHasAnAnchor() throws {
        for entry in Self.rowTypes {
            let lines = try Self.lines(of: entry.file)
            let hits = lines.filter { Self.isAnchor($0) && $0.localizedCaseInsensitiveContains(entry.marker) }
            #expect(
                !hits.isEmpty,
                "\(entry.rowType) (\(entry.file)) has no anchor: no \"vertically centered on the whole row\" anchor comment containing \"\(entry.marker)\""
            )
        }
    }

    @Test("RL2-LAYOUT-ROW-01 enabled and catalog rows: the name owns the first line; chips flow protocol then key; capability icons always take the line below the chips")
    func catalogRowNameOwnsFirstLine() throws {
        let file = "RelayCatalogBoardViews.swift"
        let lines = try Self.lines(of: file)
        let body = try #require(Self.declaration(in: lines, "var body", after: "struct RelayCatalogRowContent"), "\(file) cannot find RelayCatalogRowContent.body")
        let nameLine = try #require(body.first { lines[$0].contains("Text(row.name)") }, "\(file) cannot find Text(row.name) in the row")
        let nameContainer = try #require(Self.innermostStack(in: lines, enclosing: nameLine), "\(file) the name has no row container of its own")
        let chipLines = nameContainer.filter { lines[$0].contains("Chip") || lines[$0].contains("chips") }
        #expect(chipLines.isEmpty, "\(file) a chip appears in the name's container (line \(chipLines.map { String($0 + 1) }.joined(separator: ", "))), so the name no longer owns the first line")

        // The layout no longer depends on width: icons always sit below the chips, and a chip that does not fit wraps as a whole.
        let code = body.map { lines[$0] }.filter { !Self.isComment($0) }.joined(separator: "\n")
        #expect(!code.contains("ViewThatFits"), "The row still uses ViewThatFits to pick between \"icons inline\" and \"icons wrapped\"")
        let flowLine = try #require(
            body.first { !Self.isComment(lines[$0]) && lines[$0].contains("RelayChipFlowLayout(") },
            "The chip row is not a flow layout (RelayChipFlowLayout): a key chip that does not fit would be squeezed into an ellipsis"
        )
        let flow = try #require(Self.block(in: lines, from: flowLine))
        #expect(flow.contains { lines[$0].contains("chips") }, "The flow layout contains no chips")
        #expect(!flow.contains { lines[$0].contains("capabilityIcons") }, "Capability icons moved into the chip row")
        let iconLine = try #require(body.first { lines[$0].trimmingCharacters(in: .whitespaces) == "capabilityIcons" }, "Cannot find the capability icons in the row")
        let iconContainer = try #require(Self.innermostStack(in: lines, enclosing: iconLine))
        #expect(
            lines[iconContainer.lowerBound].contains("VStack(") && iconContainer.contains(nameLine) && iconContainer.contains(flowLine),
            "Capability icons are not their own line in the left column (container at line \(iconContainer.lowerBound + 1))"
        )

        let chips = try #require(Self.declaration(in: lines, "private var chips: some View"), "\(file) cannot find chips")
        let protocolChip = try #require(chips.first { lines[$0].contains("RelayCatalogProtocolChip(") }, "chips has no protocol chip")
        let keyChip = try #require(chips.first { lines[$0].contains("RelayCatalogKeyChip(") }, "chips has no key chip")
        #expect(protocolChip < keyChip, "In chips the key chip comes before the protocol chip")
    }

    @Test("RL2-LAYOUT-ROW-02 enabled row: status text sits in the trailing column, wraps instead of truncating, max width 84; centered on the whole row together with the button group, which never wraps")
    func enabledRowStatusWrapsInTrailingColumn() throws {
        // The production constant itself: changing the width limit turns this red first.
        #expect(RelayCatalogRowContent.statusMaxWidth == 84)

        let file = "RelayCatalogBoardViews.swift"
        let lines = try Self.lines(of: file)
        let body = try #require(Self.declaration(in: lines, "var body", after: "struct RelayCatalogRowContent"))
        let split = try #require(Self.rowSplit(in: lines, within: body, leftOpener: "VStack("), "\(file) row has no outer HStack / left column")
        let trailing = split.trailing.map { lines[$0] }.joined(separator: "\n")
        #expect(trailing.contains("status") && trailing.contains(".frame(maxWidth: Self.statusMaxWidth"), "Status text is not in the trailing column, or is not limited by statusMaxWidth")
        let leftHasStatus = split.left.contains { lines[$0].trimmingCharacters(in: .whitespaces) == "status" }
        #expect(!leftHasStatus, "Status text moved into the left column")

        for name in ["private var status: some View", "fileprivate func statusText("] {
            let block = try #require(Self.declaration(in: lines, name), "\(file) cannot find \(name)")
            let clipped = block.filter { lines[$0].contains(".lineLimit(") }
            #expect(clipped.isEmpty, "\(name) limits the line count (line \(clipped.map { String($0 + 1) }.joined(separator: ", "))); status text must not be truncated to one line")
        }

        // Enabled row: the row content and the button group are two children of the same HStack(alignment: .center, and the button group has a fixed width and never wraps.
        let enabledFile = "ProviderEnabledModels.swift"
        let enabled = try Self.lines(of: enabledFile)
        let rowLine = try #require(enabled.firstIndex { $0.contains("RelayCatalogRowContent(row: boardRow") }, "\(enabledFile) cannot find the board row")
        let actionsLine = try #require(enabled.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "boardActions(boardRow)" }, "\(enabledFile) cannot find the trailing button group")
        let rowStack = try #require(Self.innermostStack(in: enabled, enclosing: rowLine))
        #expect(enabled[rowStack.lowerBound].contains("HStack(alignment: .center"), "The outer container of the enabled row is not HStack(alignment: .center")
        #expect(rowStack.contains(actionsLine), "The button group is not on the same line as the row content")
        let actions = try #require(Self.declaration(in: enabled, "private func boardActions("))
        #expect(actions.contains { enabled[$0].contains(".fixedSize(horizontal: true") }, "The button group has no fixed width and would be squeezed and wrapped on narrow screens")
    }

    @Test("RL2-LAYOUT-ROW-03 key row: the mask is always the catalog-line prefix in the left column; the trailing column has only the status (at most 2 lines); inline keys on the detail page use the same component")
    func keyRowTrailingHoldsOnlyStatus() throws {
        let keysFile = "RelayKeysPage.swift"
        let lines = try Self.lines(of: keysFile)
        let rowView = try #require(Self.declaration(in: lines, "struct RelayKeyRowView"), "\(keysFile) cannot find RelayKeyRowView")
        let rowCode = rowView.map { lines[$0] }.filter { !Self.isComment($0) }.joined(separator: "\n")
        #expect(!rowCode.contains("ViewThatFits") && !rowCode.contains("maskOnTitleLine"), "The key row still moves the mask between the left and right columns by width")

        let layout = try #require(Self.declaration(in: lines, "private var rowLayout: some View", after: "struct RelayKeyRowView"), "\(keysFile) cannot find RelayKeyRowView.rowLayout")
        let split = try #require(Self.rowSplit(in: lines, within: layout, leftOpener: "VStack("))
        let trailing = split.trailing.map { lines[$0] }.filter { !Self.isComment($0) }.joined(separator: "\n")
        #expect(trailing.contains("statusLabel"), "The trailing column of the key row has no status text")
        #expect(!trailing.contains("mask") && !trailing.contains("Mask"), "The mask is still in the trailing column of the key row")
        #expect(split.left.contains { lines[$0].contains("catalogLine") }, "The left catalog line has no mask prefix (catalogLine)")
        #expect(!split.left.contains { lines[$0].contains("statusLabel") }, "Status text moved into the left column of the key row")
        // The status column takes at most 50% of the row width: long status words wrap instead of squeezing "mask · catalog" to a sliver.
        #expect(layout.contains { lines[$0].contains("RelayMenuRowColumns(") && lines[$0].contains("trailingMaxFraction: Self.statusMaxFraction") }, "The key row status column is not capped at 50% of the row width")
        #expect(lines.joined(separator: "\n").contains("static let statusMaxFraction: CGFloat = 0.5"), "The key row status column cap is not 50% of the row width")

        let status = try #require(Self.declaration(in: lines, "private func statusLabel(", after: "struct RelayKeyRowView"))
        let statusCode = status.map { lines[$0] }.filter { !Self.isComment($0) }.joined(separator: "\n")
        #expect(statusCode.contains(".lineLimit(2)"), "The status word is not limited to 2 lines")
        #expect(!statusCode.contains(".lineLimit(1)"), "The status word is still truncated to one line")

        let detailFile = "RelayDetailBoardView.swift"
        let detail = try Self.lines(of: detailFile)
        let inline = try #require(Self.declaration(in: detail, "private func inlineKeys("), "\(detailFile) cannot find inlineKeys")
        #expect(inline.contains { detail[$0].contains("RelayKeyRowView(") }, "Inline keys on the detail page do not use RelayKeyRowView")
    }

    @Test("RL2-LAYOUT-ROW-04 step 1 check row: elapsed time alone in the trailing column; detail, key catalog line and failure text all in the left column")
    func setupCheckRowKeepsElapsedTrailing() throws {
        let file = "RelaySetupStepViews.swift"
        let lines = try Self.lines(of: file)
        let row = try #require(Self.declaration(in: lines, "private func checkRow<Extra"), "\(file) cannot find checkRow")
        let split = try #require(Self.rowSplit(in: lines, within: row, leftOpener: "HStack(alignment: .top"), "\(file) checkRow has no outer HStack / left column")
        // Lines starting with "." are modifiers after the left column closes, not views in the trailing column.
        let trailing = split.trailing.map { lines[$0] }.filter { !Self.isComment($0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "}" && !$0.hasPrefix(".") }
        #expect(trailing.count == 1 && trailing.first?.hasPrefix("elapsedLabel(") == true, "The trailing column of the check row should contain only the elapsed time: \(trailing)")
        let left = split.left.map { lines[$0] }.joined(separator: "\n")
        #expect(left.contains("extra()"), "The key catalog line / failure diagnostics (extra) are not in the left column")
        #expect(left.contains("Text(detail)"), "Detail / failure text is not in the left column")

        // The key catalog line and failure diagnostics enter the left column through extra; failure text enters it through detail.
        let callSites = lines.joined(separator: "\n")
        let catalogCall = try #require(Self.callSite(callSites, key: "RelaySetupBoardModel.catalogCheckKey"), "Cannot find the catalog check row call")
        #expect(catalogCall.contains("keyCatalogRow("), "The key catalog line is not in the extra of the catalog check row")
        #expect(catalogCall.contains("detection.failure?.text"), "Catalog check failure text does not go through detail")
        let connectionCall = try #require(Self.callSite(callSites, key: "RelaySetupBoardModel.connectionCheckKey"), "Cannot find the connection check row call")
        #expect(connectionCall.contains("failureDiagnostics("), "Failure diagnostics are not in the extra of the connection check row")
    }

    @Test("RL2-LAYOUT-ROW-05 edit / manual-setup menu row: value and chevron share the trailing column; the footnote is in the left column")
    func menuRowKeepsValueAndCaretTrailing() throws {
        let file = "RelayEditBoardView.swift"
        let lines = try Self.lines(of: file)
        let body = try #require(Self.declaration(in: lines, "private func rowBody<Trailing"), "\(file) cannot find rowBody")
        let split = try #require(Self.rowSplit(in: lines, within: body, leftOpener: "VStack("), "\(file) rowBody has no outer HStack / left column")
        let trailing = split.trailing.map { lines[$0] }.joined(separator: "\n")
        #expect(trailing.contains("row.value"), "The menu row value is not in the trailing column")
        #expect(trailing.contains("trailing()"), "The menu row trailing control (chevron) is not in the trailing column")
        #expect(split.left.contains { lines[$0].contains("rowFootnote(") }, "The menu row footnote is not in the left column")
        #expect(!split.trailing.contains { lines[$0].contains("rowFootnote(") }, "The menu row footnote moved into the trailing column")

        let menu = try #require(Self.declaration(in: lines, "private func menuRow("), "\(file) cannot find menuRow")
        let menuText = menu.map { lines[$0] }.joined(separator: "\n")
        #expect(menuText.contains("rowBody(row)") && menuText.contains("caretDown"), "The menuRow chevron is not drawn through the rowBody trailing control")
    }

    @Test("RL2-LAYOUT-ROW-01 chip flow: a chip that does not fit wraps as a whole; only a single chip wider than the column is cut to the column width")
    func chipFlowWrapsWholeChips() {
        // Protocol 60 + key 120 do not fit in 150: the key chip moves to line 2 as a whole.
        #expect(RelayChipFlowLayout.rows(widths: [60, 120], maxWidth: 150, spacing: 6) == [[0], [1]])
        // If they fit they stay on one line, protocol first.
        #expect(RelayChipFlowLayout.rows(widths: [60, 80], maxWidth: 150, spacing: 6) == [[0, 1]])
        // A key name wider than the whole column gets its own line (cut to the column width).
        #expect(RelayChipFlowLayout.rows(widths: [60, 400], maxWidth: 150, spacing: 6) == [[0], [1]])
    }

    @Test("RL2-LAYOUT-ROW-03 mask prefix: with a name show \"<mask> · <catalog>\", without a name do not repeat the mask")
    func keyRowCatalogLinePrefixesMask() {
        #expect(RelayKeyRowView.catalogLine(maskedSecret: "sk-…7f2a", hasName: true, catalog: "Catalog: 12 models") == "sk-…7f2a · Catalog: 12 models")
        #expect(RelayKeyRowView.catalogLine(maskedSecret: "sk-…7f2a", hasName: false, catalog: "Catalog: 12 models") == "Catalog: 12 models")
    }

    @Test("RL2-LAYOUT-ROW-06 menu row columns: value column at most 45%, short values use their ideal width, the rest goes to the title column")
    func menuRowColumnWidths() {
        let long = RelayMenuRowColumns.columnWidths(total: 300, valueIdeal: 400, spacing: 12)
        #expect(long.value == 135 && long.title == 153)
        let short = RelayMenuRowColumns.columnWidths(total: 300, valueIdeal: 60, spacing: 12)
        #expect(short.value == 60 && short.title == 228)
        // Key row status column (ROW-03): the same column split, capped at 50% of the row width.
        #expect(RelayKeyRowView.statusMaxFraction == 0.5)
        let status = RelayMenuRowColumns.columnWidths(total: 300, valueIdeal: 400, spacing: 8, maxFraction: RelayKeyRowView.statusMaxFraction)
        #expect(status.value == 150 && status.title == 142)
    }

    @Test("RL2-LAYOUT-URL-01 address slot with a scheme chip: shows only what follows the scheme; text containing :// replaces the whole string, otherwise the written scheme is kept; clearing the slot clears the whole string")
    func schemeSlotTextRules() {
        typealias Slot = RelaySchemeSlotText
        #expect(Slot.body(of: "https://api.example.com/v1") == "api.example.com/v1")
        #expect(Slot.body(of: "api.example.com") == "api.example.com")
        #expect(Slot.explicitScheme(in: "HTTP://10.0.0.2:8080") == "http")
        #expect(Slot.explicitScheme(in: "api.example.com") == nil)
        #expect(Slot.text("http://10.0.0.2", replacingBodyWith: "10.0.0.3:8080") == "http://10.0.0.3:8080")
        #expect(Slot.text("http://10.0.0.2", replacingBodyWith: "https://relay.example.com") == "https://relay.example.com")
        #expect(Slot.text("api.example.com", replacingBodyWith: "api.example.com/v1") == "api.example.com/v1")
        #expect(Slot.text("", replacingBodyWith: "") == "")
        // Slot cleared: the whole string is cleared, leaving no dangling "https://".
        #expect(Slot.text("https://api.example.com", replacingBodyWith: "") == "")
        // The edit page address slot follows the same rule.
        #expect(RelayEditBoardModel.address("http://10.0.0.2", replacingBodyWith: "") == "")
        #expect(RelayEditBoardModel.address("https://relay.example.com/v1", replacingBodyWith: "") == "")
        #expect(RelayEditBoardModel.address("http://10.0.0.2", replacingBodyWith: "10.0.0.3") == "http://10.0.0.3")
    }

    @Test("RL2-LAYOUT-ROW-06 menu row: value column at most 45% of the row width, at most 2 lines, tail truncation; title / footnote column has priority")
    func menuRowValueCappedAt45Percent() throws {
        let file = "RelayEditBoardView.swift"
        let lines = try Self.lines(of: file)
        let body = try #require(Self.declaration(in: lines, "private func rowBody<Trailing"), "\(file) cannot find rowBody")
        #expect(body.contains { lines[$0].contains("RelayMenuRowColumns(") }, "rowBody does not split columns with the value column at most 45% (RelayMenuRowColumns)")
        let valueLine = try #require(body.first { lines[$0].contains("Text(text(value))") }, "rowBody cannot find the value")
        let chain = Self.modifierChain(in: lines, after: valueLine)
        #expect(chain.contains(".lineLimit(2)"), "The menu value is not limited to 2 lines: \(chain)")
        #expect(chain.contains(".truncationMode(.tail)"), "The menu value is not tail-truncated: \(chain)")
        #expect(!chain.contains(".layoutPriority(1)"), "The menu value still takes width ahead of the title")
        let source = lines.joined(separator: "\n")
        #expect(source.contains("static let valueMaxFraction: CGFloat = 0.45"), "The value column cap is not 45% of the row width")
    }

    @Test("RL2-LAYOUT-ROW-07 model library header subtitle: at most 2 lines, tail truncation")
    func libraryHeaderSubtitleWrapsTwoLines() throws {
        let file = "RelayModelLibraryPage.swift"
        let lines = try Self.lines(of: file)
        let line = try #require(lines.firstIndex { $0.contains("Text(verbatim: subtitle)") }, "\(file) cannot find the subtitle")
        let chain = Self.modifierChain(in: lines, after: line)
        #expect(chain.contains(".lineLimit(2)"), "The subtitle is not limited to 2 lines: \(chain)")
        #expect(chain.contains(".truncationMode(.tail)") && !chain.contains(".truncationMode(.middle)"), "The subtitle is not tail-truncated: \(chain)")
    }

    @Test("RL2-LAYOUT-ROW-08 embedded key bar in the model library: left column has two lines (name / catalog); trailing status at most 50% and 2 lines; Retry keeps its intrinsic width without wrapping or being squeezed")
    func catalogKeyStatusBarColumns() throws {
        let file = "RelayCatalogBoardViews.swift"
        let lines = try Self.lines(of: file)
        let bar = try #require(Self.declaration(in: lines, "struct RelayCatalogKeyStatusBar"), "\(file) cannot find RelayCatalogKeyStatusBar")
        let source = lines.joined(separator: "\n")

        // The left column and the status column split at 50% of the row width (same Layout as the keys page); status no longer shares the width evenly with the catalog.
        let row = try #require(Self.declaration(in: lines, "private func keyRow(", after: "struct RelayCatalogKeyStatusBar"), "The key bar has no keyRow")
        let columnsLine = try #require(row.first { lines[$0].contains("RelayMenuRowColumns(") }, "The key bar does not split columns by row width (RelayMenuRowColumns)")
        #expect(lines[columnsLine].contains("trailingMaxFraction: Self.statusMaxFraction"), "The key bar status column is not capped by statusMaxFraction")
        #expect(source.contains("static let statusMaxFraction: CGFloat = 0.5"), "The key bar status column cap is not 50% of the row width")
        let columns = try #require(Self.block(in: lines, from: columnsLine))
        let leftStart = try #require(columns.dropFirst().first { !Self.isComment(lines[$0]) && lines[$0].contains("VStack(") }, "The key bar left column is not a VStack")
        let left = try #require(Self.block(in: lines, from: leftStart))

        let nameLine = try #require(left.first { lines[$0].contains("Text(verbatim: item.title)") }, "The left column has no name")
        let nameChain = Self.modifierChain(in: lines, after: nameLine)
        #expect(nameChain.contains(".lineLimit(1)") && nameChain.contains(".truncationMode(.middle)"), "The name is not a single line with middle truncation: \(nameChain)")
        let catalogLine = try #require(left.first { lines[$0].contains("RelayKeysBoardModel.catalogCountKey") }, "The left column has no catalog count")
        #expect(catalogLine > nameLine, "The catalog count is not below the name")
        let catalogChain = Self.modifierChain(in: lines, after: catalogLine)
        #expect(catalogChain.contains(".lineLimit(1)") && catalogChain.contains(".truncationMode(.tail)"), "The catalog is not a single line with tail truncation: \(catalogChain)")
        #expect(!left.contains { lines[$0].contains("statusLabel") }, "Status moved into the left column")
        #expect(columns.contains { lines[$0].contains("statusLabel(") }, "Status is not in the trailing column of the split")
        #expect(!columns.contains { lines[$0].contains("RelayCatalogTextButtonLabel") }, "Retry is inside the column split and would be squeezed by the status")

        // Status: a failure shows only the text "<code> <status word>", at most 2 lines, with no icon (same on all platforms); success shows only a check mark.
        let status = try #require(Self.declaration(in: lines, "private func statusLabel(", after: "struct RelayCatalogKeyStatusBar"), "The key bar has no statusLabel")
        let failedLine = try #require(status.first { lines[$0].contains("Text(verbatim: httpStatus.map") }, "The key bar has no failure status text")
        let failedChain = Self.modifierChain(in: lines, after: failedLine)
        #expect(failedChain.contains(".lineLimit(2)") && !failedChain.contains(".lineLimit(1)"), "The failure status is not limited to 2 lines: \(failedChain)")
        #expect(!status.contains { lines[$0].contains("PhosphorIcon.warning") }, "The failure status has an extra warning icon")
        #expect(status.contains { lines[$0].contains("PhosphorIcon.checkCircle") }, "The success status is not a check mark")

        // Retry: intrinsic width, never wraps.
        let retryLine = try #require(bar.first { lines[$0].contains("RelayCatalogTextButtonLabel(title: L10n.tr(\"Retry\"))") }, "The failure row has no Retry")
        let retryChain = Self.modifierChain(in: lines, after: retryLine + 1)
        #expect(retryChain.contains(".fixedSize()"), "Retry does not use its intrinsic width: \(retryChain)")

        // Production column-split function: at width 320 with a long status word the status is capped at 50% and the name column still gets half the width.
        let widths = RelayMenuRowColumns.columnWidths(total: 320, valueIdeal: 400, spacing: 8, maxFraction: RelayCatalogKeyStatusBar.statusMaxFraction)
        #expect(widths.value == 160 && widths.title == 152)
    }

    @Test("RL2-LAYOUT-HEADER-01 family page section titles are small secondary-color labels; only the two model library sections use the accent-bar header")
    func familySectionHeadersArePlainLabels() throws {
        // Detail / edit / manual setup / web search / keys / local: no accent-bar header.
        for file in ["RelayDetailBoardView.swift", "RelayEditBoardView.swift", "RelayManualSetupView.swift",
                     "RelayWebSearchPage.swift", "RelayKeysPage.swift", "LocalComputeSetupView.swift"] {
            let source = try Self.lines(of: file).filter { !Self.isComment($0) }.joined(separator: "\n")
            #expect(!source.contains("ProviderSectionHeader("), "\(file) uses the accent-bar header")
        }
        let detail = try Self.lines(of: "RelayDetailBoardView.swift")
        let section = try #require(Self.declaration(in: detail, "private func section(_ titleKey"), "The detail page has no section")
        let title = try #require(section.first { detail[$0].contains("Text(L10n.tr(titleKey") })
        let chain = Self.modifierChain(in: detail, after: title)
        #expect(chain.contains(".font(OriveoTheme.Typography.footnote") && chain.contains("textSecondary"), "The detail page section title is not small secondary-color text: \(chain)")

        // Model library "Enabled · N" and "Model library · N": accent-bar header.
        let enabled = try Self.lines(of: "ProviderEnabledModels.swift").joined(separator: "\n")
        #expect(enabled.contains("ProviderSectionHeader(") && enabled.contains("RelayCatalogBoardModel.enabledSectionKey"))
        let library = try Self.lines(of: "ProviderModelLibrary.swift").joined(separator: "\n")
        #expect(library.contains("ProviderSectionHeader(") && library.contains("RelayCatalogBoardModel.librarySectionKey"))
        let header = try Self.lines(of: "ProviderSummaryCard.swift")
        let headerBody = try #require(Self.declaration(in: header, "var body", after: "struct ProviderSectionHeader"))
        #expect(headerBody.contains { header[$0].contains(".frame(width: 4, height: 20)") }, "ProviderSectionHeader has no accent bar")
    }

    @Test("RL2-ORDER-01 relay enabled rows keep the enabled order and are not reordered by model-name scoring")
    func relayEnabledModelsKeepStoredOrder() {
        let models = [
            TestFactories.makeModel(id: "zeta-chat"),
            TestFactories.makeModel(id: "gpt-5.6-sol", isAvailable: false),
            TestFactories.makeModel(id: "claude-opus-5", isDefault: true),
            TestFactories.makeModel(id: "alpha-mini", createdAt: 9_999_999_999),
        ]
        let relay = TestFactories.makeProvider(kind: .relay, models: models, baseURLText: "https://relay.example.com/v1")
        #expect(sortedEnabledModels(for: relay).map(\.id) == models.map(\.id))
    }

    @Test("RL2-KEYINPUT-01 add / replace key / rename: × close + centered title, labeled fields, an eye toggle on the key field, full-width Save at the bottom, no Cancel")
    func keyInputSheetStructure() throws {
        // Production model: add = name + key; replace key = key; rename = name.
        #expect(RelayKeysBoardModel.inputSheet(.add).fields.map(\.kind) == [.name, .secret])
        #expect(RelayKeysBoardModel.inputSheet(.replace).fields.map(\.kind) == [.secret])
        #expect(RelayKeysBoardModel.inputSheet(.rename, maskedSecret: "sk-…7f2a").fields.map(\.kind) == [.name])

        let file = "RelayKeysPage.swift"
        let lines = try Self.lines(of: file)
        let sheet = try #require(Self.declaration(in: lines, "private struct RelayKeyInputSheet"), "\(file) cannot find RelayKeyInputSheet")
        let code = sheet.map { lines[$0] }.filter { !Self.isComment($0) }.joined(separator: "\n")
        #expect(code.contains("OriveoLabeledField(") && code.contains("isSecure: field.kind == .secret"), "The field is not a labeled field, or the key field is not a secure field")
        #expect(code.contains("PhosphorIcon.x.image") && code.contains("L10n.tr(\"Close\")"), "No × close at the top left")
        #expect(code.contains("ZStack {") && code.contains(".padding(.horizontal, 52)"), "The title is not centered")
        #expect(code.contains("Button(L10n.tr(\"Save\")") && code.contains(".disabled(!canSave)"), "No disableable Save at the bottom")
        #expect(!code.contains("\"Cancel\""), "The input sheet still has a Cancel button")
        let canSave = try #require(Self.declaration(in: lines, "private var canSave: Bool", after: "private struct RelayKeyInputSheet"))
        #expect(canSave.contains { lines[$0].contains("case .add, .replace: !secret.trimmingCharacters") }, "Save is not disabled for an empty value when adding / replacing a key")

        let field = try Self.lines(of: "../../Shared/Components/FormFields.swift").joined(separator: "\n")
        #expect(field.contains("revealsSecureText ? \"eye.slash\" : \"eye\""), "The secure field has no show / hide eye toggle")
    }

    @Test("RL2-RECOVERY-01 needs-attention card: neutral card surface, the top-right × hides it only for this visit, the reason line = lastError")
    func recoveryCardNeutralWithDismiss() throws {
        var provider = TestFactories.makeProvider(kind: .relay, lastError: ProviderIssueMessage.unverifiedConnectionKey, baseURLText: "https://relay.example.com/v1")
        provider.status = .issue("issue")
        let card = try #require(RelayDetailBoardModel.recoveryCard(for: provider))
        #expect(card.detailMessageKey == ProviderIssueMessage.unverifiedConnectionKey)
        #expect(ProviderIssueMessage.unverifiedConnectionKey == "Connection has not been verified.")

        let lines = try Self.lines(of: "RelayDetailBoardView.swift")
        let view = try #require(Self.declaration(in: lines, "struct RelayDetailRecoveryCard"))
        let code = view.map { lines[$0] }.filter { !Self.isComment($0) }.joined(separator: "\n")
        #expect(code.contains(".fill(OriveoTheme.Palette.surfaceElevated)"), "The needs-attention card is not a plain card surface")
        #expect(!code.contains("warningSoft") && !code.contains(".stroke("), "The needs-attention card still has a yellow fill / stroke")
        #expect(code.contains("Button(action: onDismiss)"), "The needs-attention card has no × close")
        let detail = try Self.lines(of: "ProviderDetailView.swift").joined(separator: "\n")
        #expect(detail.contains("@State private var dismissedHealthBanner = false"), "The × close is not one-shot in-page state")
    }

    // MARK: - Helpers

    /// The modifier chain right after `line` (lines starting with ".", skipping comments).
    private static func modifierChain(in lines: [String], after line: Int) -> String {
        var out: [String] = []
        var index = line + 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if isComment(lines[index]) { index += 1; continue }
            guard trimmed.hasPrefix(".") else { break }
            out.append(trimmed)
            index += 1
        }
        return out.joined(separator: " ")
    }

    /// The full line range of the first declaration containing `needle` (optionally after `anchor`).
    private static func declaration(in lines: [String], _ needle: String, after anchor: String? = nil) -> ClosedRange<Int>? {
        var start = 0
        if let anchor {
            guard let found = lines.firstIndex(where: { $0.contains(anchor) }) else { return nil }
            start = found
        }
        guard let index = lines[start...].firstIndex(where: { !isComment($0) && $0.contains(needle) }) else { return nil }
        return block(in: lines, from: index)
    }

    /// The first HStack in the block is the whole row; the first `leftOpener` block inside it is the left column, and what lies between the left column's end and the HStack's end is the trailing column.
    private static func rowSplit(
        in lines: [String],
        within range: ClosedRange<Int>,
        leftOpener: String
    ) -> (left: ClosedRange<Int>, trailing: ClosedRange<Int>)? {
        guard let rowStart = range.first(where: { !isComment(lines[$0]) && lines[$0].contains("HStack(") }),
              let row = block(in: lines, from: rowStart),
              let leftStart = row.dropFirst().first(where: { !isComment(lines[$0]) && lines[$0].contains(leftOpener) }),
              let left = block(in: lines, from: leftStart),
              left.upperBound + 1 <= row.upperBound
        else { return nil }
        return (left, (left.upperBound + 1)...row.upperBound)
    }

    /// The innermost HStack / VStack block that wraps `line`.
    private static func innermostStack(in lines: [String], enclosing line: Int) -> ClosedRange<Int>? {
        var candidate = line - 1
        while candidate >= 0 {
            let text = lines[candidate]
            if text.contains("HStack(") || text.contains("VStack("),
               let range = block(in: lines, from: candidate), range.contains(line) {
                return range
            }
            candidate -= 1
        }
        return nil
    }

    /// Source of a `checkRow(` call from `titleKey: <key>` up to the next `checkRow(` or the end of the file.
    private static func callSite(_ source: String, key: String) -> String? {
        guard let start = source.range(of: "titleKey: \(key)") else { return nil }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "checkRow(")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    private static func isAnchor(_ line: String) -> Bool {
        anchorPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//")
    }

    /// The line range (inclusive) of the HStack governed by the anchor.
    private static func governingHStack(in lines: [String], anchor: Int) -> ClosedRange<Int>? {
        var codeLines = 0
        var index = anchor + 1
        while index < lines.count, codeLines < forwardLookahead {
            if !isComment(lines[index]) {
                if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("}") { break }
                codeLines += 1
                if lines[index].contains("HStack(") { return block(in: lines, from: index) }
            }
            index += 1
        }
        // The comment sits on the right column: search backwards for the first HStack whose block contains the anchor.
        var candidate = anchor - 1
        while candidate >= 0 {
            if lines[candidate].contains("HStack("), let range = block(in: lines, from: candidate), range.contains(anchor) {
                return range
            }
            candidate -= 1
        }
        return nil
    }

    /// Matches braces from the first `{` on the `HStack(` line and returns up to the line of the matching `}`.
    private static func block(in lines: [String], from start: Int) -> ClosedRange<Int>? {
        var depth = 0
        var opened = false
        for index in start..<lines.count {
            let code = lines[index].components(separatedBy: "//").first ?? ""
            for character in code {
                if character == "{" {
                    depth += 1
                    opened = true
                } else if character == "}" {
                    depth -= 1
                    if opened, depth == 0 { return start...index }
                }
            }
        }
        return nil
    }

    private static func lines(of file: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OriveoTests
            .deletingLastPathComponent()   // Oriveo
            .appendingPathComponent("Oriveo/Features/Providers")
            .appendingPathComponent(file)
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }
}
