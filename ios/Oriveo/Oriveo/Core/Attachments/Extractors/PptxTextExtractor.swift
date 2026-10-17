import Foundation

/// PPTX extraction (attachment extraction spec section 7): emit slide by slide in `p:sldIdLst` order (by N of `slideN.xml` when presentation.xml is missing)
/// `## Slide N[: title][ (hidden)]`, body paragraphs and tables, `### Notes` notes -> section 3.1 normalization. The deadline is checked at the start of each slide (section 14).
nonisolated enum PptxTextExtractor {
    private static let titleTypes: Set<String> = ["title", "ctrTitle"]
    private static let skippedPlaceholderTypes: Set<String> = ["sldNum", "dt", "ftr", "hdr", "sldImg"]

    static func extract(_ package: OfficePackage) throws -> String {
        let presentationPath = try package.mainPart(fallback: "ppt/presentation.xml")
        let slidePaths: [String]
        if let presentation = try package.xml(presentationPath) {
            var targets: [String: String] = [:]
            for relationship in try package.relationships(of: presentationPath) where targets[relationship.id] == nil {
                targets[relationship.id] = relationship.target
            }
            slidePaths = (presentation.child("p:sldIdLst")?.children("p:sldId") ?? []).compactMap { slide in
                slide.attr("r:id").flatMap { targets[$0] }
            }
        } else {
            slidePaths = package.paths
                .compactMap { path -> (Int, String)? in
                    let prefix = "ppt/slides/slide"
                    guard path.hasPrefix(prefix), path.hasSuffix(".xml") else { return nil }
                    let middle = path.dropFirst(prefix.count).dropLast(".xml".count)
                    guard !middle.isEmpty, middle.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(middle) else { return nil }
                    return (number, path)
                }
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }

        var writer = StructuredBlockWriter()
        // When the referenced slide part does not exist, skip it without consuming a number.
        var number = 0
        for path in slidePaths {
            try package.deadline.check()
            guard let slide = try package.xml(path) else { continue }
            number += 1
            let tree = slide.child("p:cSld")?.child("p:spTree")
            let title = tree.flatMap(findTitle)
            let titleText = title.map(titleText) ?? ""
            let hidden = ["0", "false"].contains(slide.attr("show") ?? "")

            var heading = "## Slide \(number)"
            if !titleText.isEmpty { heading += ": \(titleText)" }
            if hidden { heading += " (hidden)" }
            writer.section(heading)
            if let tree { body(tree, title: title, into: &writer) }

            if let notesPath = try package.relationships(of: path).first(where: { $0.hasType("/notesSlide") })?.target,
               let notes = try package.xml(notesPath),
               let notesTree = notes.child("p:cSld")?.child("p:spTree") {
                var paragraphs: [String] = []
                collectNotes(notesTree, into: &paragraphs)
                let nonEmpty = paragraphs.filter { !StructuredBlockWriter.trimSpacesAndTabs($0).isEmpty }
                if !nonEmpty.isEmpty {
                    writer.notesHeading()
                    for paragraph in nonEmpty { writer.paragraph(paragraph) }
                }
            }
        }
        return writer.render()
    }

    private static func placeholderType(_ shape: OfficeXmlNode) -> String? {
        guard let placeholder = shape.child("p:nvSpPr")?.child("p:nvPr")?.child("p:ph") else { return nil }
        return placeholder.attr("type") ?? "obj"
    }

    /// The first shape, in document order over the whole shape tree (including those in `p:grpSp`), whose placeholder type is `title` / `ctrTitle`.
    private static func findTitle(_ tree: OfficeXmlNode) -> OfficeXmlNode? {
        for child in tree.elements {
            switch child.name {
            case "p:sp":
                if let type = placeholderType(child), titleTypes.contains(type) { return child }
            case "p:grpSp":
                if let found = findTitle(child) { return found }
            case "mc:AlternateContent":
                if let choice = child.child("mc:Choice"), let found = findTitle(choice) { return found }
            default:
                continue
            }
        }
        return nil
    }

    private static func titleText(_ shape: OfficeXmlNode) -> String {
        paragraphs(of: shape)
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func paragraphs(of shape: OfficeXmlNode) -> [String] {
        (shape.child("p:txBody")?.children("a:p") ?? []).map(paragraphText)
    }

    /// Paragraph text takes `a:r/a:t` and `a:fld/a:t`; `a:br` -> `\n`.
    private static func paragraphText(_ paragraph: OfficeXmlNode) -> String {
        var text = ""
        for child in paragraph.elements {
            switch child.name {
            case "a:r", "a:fld":
                for run in child.children("a:t") { text += run.textContent }
            case "a:br":
                text += "\n"
            default:
                continue
            }
        }
        return text
    }

    private static func body(_ tree: OfficeXmlNode, title: OfficeXmlNode?, into writer: inout StructuredBlockWriter) {
        for child in tree.elements {
            switch child.name {
            case "p:sp":
                if let title, child === title { continue }
                if let type = placeholderType(child), skippedPlaceholderTypes.contains(type) { continue }
                for paragraph in paragraphs(of: child) { writer.paragraph(paragraph) }
            case "p:grpSp":
                body(child, title: title, into: &writer)
            case "p:graphicFrame":
                if let table = child.firstDescendant("a:tbl") { writer.table(tableRows(table)) }
            case "mc:AlternateContent":
                if let choice = child.child("mc:Choice") { body(choice, title: title, into: &writer) }
            default:
                continue
            }
        }
    }

    /// A cell with `hMerge` or `vMerge` equal to `1` / `true` outputs empty.
    private static func tableRows(_ table: OfficeXmlNode) -> [[String]] {
        table.children("a:tr").map { row in
            row.children("a:tc").map { cell in
                let merged = ["1", "true"].contains(cell.attr("hMerge") ?? "") || ["1", "true"].contains(cell.attr("vMerge") ?? "")
                guard !merged else { return "" }
                let texts = (cell.child("a:txBody")?.children("a:p") ?? []).map(paragraphText)
                return StructuredTextFormat.cellText(paragraphs: texts)
            }
        }
    }

    /// On a notes page take only shapes whose placeholder type is `body`.
    private static func collectNotes(_ tree: OfficeXmlNode, into result: inout [String]) {
        for child in tree.elements {
            switch child.name {
            case "p:sp":
                if placeholderType(child) == "body" { result += paragraphs(of: child) }
            case "p:grpSp":
                collectNotes(child, into: &result)
            case "mc:AlternateContent":
                if let choice = child.child("mc:Choice") { collectNotes(choice, into: &result) }
            default:
                continue
            }
        }
    }
}
