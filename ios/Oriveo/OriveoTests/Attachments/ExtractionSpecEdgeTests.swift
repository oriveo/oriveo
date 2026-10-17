import Foundation
import Testing
import ZIPFoundation
@testable import Oriveo

// Entries among the edge-case rules added to the attachment extraction spec during implementation that the shared fixture `extraction-golden-edges.v1.json` does not cover (sections 3.3, 3.4, 4A, 5, 8, 9, 10, 11).
@Suite("Attachment extraction edge-case rules (entries not covered by the fixtures, iOS)")
@MainActor
struct ExtractionSpecEdgeTests {
    private static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    private static func zip(_ entries: [(String, String)]) throws -> Data {
        let archive = try #require(Archive(accessMode: .create))
        for (path, text) in entries {
            let data = Data(text.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: UInt32(data.count),
                provider: { position, size in data[position..<(position + size)] }
            )
        }
        return try #require(archive.data)
    }

    private static func expectCorrupted(_ body: () throws -> Any?, _ label: String) {
        do {
            let result = try body()
            Issue.record("\(label) expected corrupted_file, but got \(String(describing: result))")
        } catch let error as ExtractionError {
            #expect(error.code == .corruptedFile, "\(label)")
        } catch {
            Issue.record("\(label) threw a non-ExtractionError: \(error)")
        }
    }

    private static func rtf(_ source: String) throws -> String {
        try RtfTextExtractor.extract(data: Data(source.utf8))
    }

    private static func html(_ source: String) throws -> String {
        try HtmlTextExtractor.extract(data: Data(source.utf8))
    }

    // MARK: - §3.3 / §3.4

    @Test("section 3.3 cells: each paragraph is trimmed first (including \\r \\n), empty paragraphs dropped, then joined with <br>; a trailing carriage return on a single value leaves no <br>")
    func cellParagraphsAreTrimmedBeforeJoining() {
        #expect(StructuredTextFormat.cellText(paragraphs: [" a\r\n", "\r\n", "\tb\n"]) == "a<br>b")
        #expect(StructuredTextFormat.cellText(paragraphs: ["x\r"]) == "x")
    }

    @Test("section 3.4 no alignment when the look-back hits the first line of the kept part")
    func alignmentKeepsLinesWhenHitIsFirstLine() {
        #expect(FileTextExtractor.alignToLogicalBoundary(["## Sheet: A", "| a |", "| b |"]) == ["## Sheet: A", "| a |", "| b |"])
        #expect(FileTextExtractor.alignToLogicalBoundary(["--- Page 1 ---", "x"]) == ["--- Page 1 ---", "x"])
        #expect(FileTextExtractor.alignToLogicalBoundary(["intro", "# H", "body"]) == ["intro"])
    }

    // MARK: - §4A

    @Test("section 4A empty zip, missing XLSX workbook, missing EPUB container / OPF -> corrupted_file")
    func missingMainPartsAreCorrupted() throws {
        let emptyZip = Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18))
        Self.expectCorrupted({ try OfficeTextExtractor.extractText(from: emptyZip, fileExtension: "xlsx") }, "xlsx empty zip")
        Self.expectCorrupted({ try OdfTextExtractor.extract(data: emptyZip, fileExtension: "odt") }, "odt empty zip")
        Self.expectCorrupted({ try EpubTextExtractor.extract(data: emptyZip) }, "epub empty zip")

        let noWorkbook = try Self.zip([("xl/worksheets/sheet1.xml", "<worksheet/>")])
        Self.expectCorrupted({ try OfficeTextExtractor.extractText(from: noWorkbook, fileExtension: "xlsx") }, "xlsx missing workbook")

        let noContainer = try Self.zip([("mimetype", "application/epub+zip"), ("OEBPS/content.opf", "<package/>")])
        Self.expectCorrupted({ try EpubTextExtractor.extract(data: noContainer) }, "epub missing container.xml")

        let container = """
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>\
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        let noOpf = try Self.zip([("mimetype", "application/epub+zip"), ("META-INF/container.xml", container)])
        Self.expectCorrupted({ try EpubTextExtractor.extract(data: noOpf) }, "epub missing OPF")
    }

    // MARK: - §5

    @Test("section 5 while in the field-instruction state, w:tab / w:br / w:cr / w:noBreakHyphen / note references / text boxes are not taken; w:sdtPr / w:sdtEndPr subtrees are skipped entirely")
    func docxFieldInstructionAndSdtProperties() throws {
        let document = """
        <w:document xmlns:w="\(Self.wordNamespace)"><w:body>\
        <w:p><w:r><w:t>A</w:t></w:r><w:r><w:fldChar w:fldCharType="begin"/></w:r>\
        <w:r><w:instrText>HYPERLINK</w:instrText><w:tab/><w:br/><w:cr/><w:noBreakHyphen/><w:footnoteReference w:id="1"/>\
        <w:endnoteReference w:id="2"/><w:t>hidden</w:t><w:txbxContent><w:p><w:r><w:t>Box</w:t></w:r></w:p></w:txbxContent></w:r>\
        <w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>B</w:t><w:tab/><w:t>C</w:t></w:r>\
        <w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>\
        <w:sdt><w:sdtPr><w:alias w:val="x"/><w:placeholder><w:t>P</w:t></w:placeholder></w:sdtPr>\
        <w:sdtContent><w:p><w:r><w:t>D</w:t></w:r></w:p></w:sdtContent></w:sdt>\
        <w:p><w:sdt><w:sdtPr><w:r><w:t>Q</w:t></w:r></w:sdtPr><w:sdtEndPr><w:r><w:t>R</w:t></w:r></w:sdtEndPr>\
        <w:sdtContent><w:r><w:t>E</w:t></w:r></w:sdtContent></w:sdt></w:p>\
        </w:body></w:document>
        """
        let data = try Self.zip([("word/document.xml", document)])
        let text = try OfficeTextExtractor.extractText(from: data, fileExtension: "docx")
        #expect(text == "AB\tC\nD\nE")
    }

    // MARK: - §8

    @Test("section 8 meta charset recognizes the target names of section 4 candidates (windows-1251); unrecognized encodings are treated as no declaration")
    func htmlMetaCharsetLabels() throws {
        let cyrillic: [UInt8] = [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]
        let declared = Data(Array("<meta charset=\"windows-1251\"><p>".utf8) + cyrillic + Array("</p>".utf8))
        #expect(try HtmlTextExtractor.extract(data: declared) == "Привет")
        #expect(try Self.html("<meta charset=\"x-made-up\"><p>café</p>") == "café")
    }

    @Test("section 8 details: spaces merge across nodes, empty li is not output, caption goes before the table, empty rows are dropped when no pipe table is drawn")
    func htmlDetails() throws {
        #expect(try Self.html("<p><b>a </b> b</p>") == "a b")
        #expect(try Self.html("<ul><li>a</li><li> </li><li><span></span></li><li>b</li></ul>") == "- a\n- b")
        #expect(try Self.html("<table><caption>Cap</caption><tr><td>a</td><td>b</td></tr></table>") == "Cap\n\n| a | b |\n| --- | --- |")
        let spanned = "<table><tr><td colspan=\"2\">a</td></tr><tr><td></td><td> </td></tr><tr><td>b</td><td>c</td></tr></table>"
        #expect(try Self.html(spanned) == "a\nb\tc")
    }

    @Test("section 8 entities: legacy entities without a semicolon decode by longest prefix")
    func htmlLegacyEntitiesWithoutSemicolon() throws {
        #expect(try Self.html("<p>&copy 2026 &ampx &notit;</p>") == "© 2026 &x ¬it;")
    }

    // MARK: - §9

    private static func odt(_ tableBody: String) throws -> String {
        let content = """
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text>\
        <table:table table:name="T">\(tableBody)</table:table></office:text></office:body></office:document-content>
        """
        return try OdfTextExtractor.extract(data: try Self.zip([("content.xml", content)]), fileExtension: "odt")
    }

    private static func odtRow(_ cells: [String]) -> String {
        "<table:table-row>" + cells.map { "<table:table-cell><text:p>\($0)</text:p></table:table-cell>" }.joined() + "</table:table-row>"
    }

    private static let emptyOdtRow = "<table:table-row><table:table-cell/><table:table-cell/></table:table-row>"

    @Test("section 9 ODT tables: empty rows in the middle are not merged and are output row by row")
    func odtTableKeepsEachMiddleEmptyRow() throws {
        let text = try Self.odt(Self.odtRow(["a", "b"]) + Self.emptyOdtRow + Self.emptyOdtRow + Self.odtRow(["c", "d"]))
        #expect(text == "| a | b |\n| --- | --- |\n|  |  |\n|  |  |\n| c | d |")
    }

    @Test("section 9 ODT tables: repeated empty rows land by count only when content follows, at most 100 rows per run; a trailing empty repeat is not expanded")
    func odtTableEmptyRepeatedRowsAreCapped() throws {
        let repeated = { (count: Int) in
            "<table:table-row table:number-rows-repeated=\"\(count)\"><table:table-cell table:number-columns-repeated=\"2\"/></table:table-row>"
        }
        let header = "| a | b |\n| --- | --- |"
        let three = try Self.odt(Self.odtRow(["a", "b"]) + repeated(3) + Self.odtRow(["c", "d"]) + repeated(5))
        #expect(three == header + String(repeating: "\n|  |  |", count: 3) + "\n| c | d |")
        let capped = try Self.odt(Self.odtRow(["a", "b"]) + repeated(1_000) + Self.odtRow(["c", "d"]))
        #expect(capped == header + String(repeating: "\n|  |  |", count: 100) + "\n| c | d |")
    }

    @Test("section 9 ODT tables over 50 columns: N is the width computed from the full repeat count minus 50")
    func odtTableWideColumnsNote() throws {
        let row = "<table:table-row><table:table-cell><text:p>x</text:p></table:table-cell>"
            + "<table:table-cell table:number-columns-repeated=\"60\"/>"
            + "<table:table-cell><text:p>y</text:p></table:table-cell></table:table-row>"
            + "<table:table-row><table:table-cell table:number-columns-repeated=\"70\"><text:p>z</text:p></table:table-cell></table:table-row>"
        let text = try Self.odt(row)
        let first = ["x"] + Array(repeating: "", count: 49)
        let second = Array(repeating: "z", count: 50)
        let expected = [
            "| " + first.joined(separator: " | ") + " |",
            "| " + Array(repeating: "---", count: 50).joined(separator: " | ") + " |",
            "| " + second.joined(separator: " | ") + " |",
            "",
            "(20 more columns not shown)",
        ].joined(separator: "\n")
        #expect(text == expected)
    }

    // MARK: - §10

    @Test("section 10 an out-of-bounds href is decided while processing .. segment by segment, not clamped to the root")
    func epubHrefOutOfRootIsDropped() {
        #expect(EpubTextExtractor.resolve(href: "../x.xhtml#a", against: ["OEBPS"]) == "x.xhtml")
        #expect(EpubTextExtractor.resolve(href: "../../x.xhtml", against: ["OEBPS"]) == nil)
        #expect(EpubTextExtractor.resolve(href: "a/../../x.xhtml", against: []) == nil)
        #expect(EpubTextExtractor.resolve(href: "/x.xhtml", against: ["OEBPS"]) == nil)
    }

    // MARK: - §11

    @Test("section 11 when \\f never appeared use the font code page of \\deff; an unrecognized code page is treated as 1252")
    func rtfDefaultFontAndUnknownCodePage() throws {
        #expect(try Self.rtf(#"{\rtf1\ansi\deff1{\fonttbl{\f0 Arial;}{\f1\fcharset134 SimSun;}}\'c4\'e3\'ba\'c3}"#) == "\u{4F60}\u{597D}")
        #expect(try Self.rtf(#"{\rtf1\ansi\ansicpg99999 caf\'e9}"#) == "café")
    }

    @Test("section 11 when a double-byte code page fails to decode the whole run, output U+FFFD unit by unit; a lone surrogate outputs U+FFFD")
    func rtfReplacementCharacters() throws {
        #expect(try Self.rtf(#"{\rtf1\ansi\ansicpg936 \'c4\'e3\'ff\'ff\'ba\'c3}"#) == "\u{4F60}\u{FFFD}\u{FFFD}\u{597D}")
        #expect(try Self.rtf(#"{\rtf1 a\u-10179?b}"#) == "a\u{FFFD}b")
    }

    @Test("section 11 line breaks are not output while \\v is hidden; \\*\\ud passes only inside \\upr")
    func rtfHiddenTextAndUpr() throws {
        #expect(try Self.rtf(#"{\rtf1 a{\v x\par y\line}\par b}"#) == "a\nb")
        #expect(try Self.rtf(#"{\rtf1 {\*\ud z}a{\upr{x}{\*\ud y}}}"#) == "ay")
    }
}
