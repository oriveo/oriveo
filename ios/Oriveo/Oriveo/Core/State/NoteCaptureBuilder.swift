import Foundation

enum NoteCaptureBuilder {

    static func fullAnswer(message: ChatMessage, conversationID: UUID, prompt: String?) -> NoteDraft {
        var draft = NoteDraft(body: message.text, captureKind: .fullAnswer)
        applySource(to: &draft, message: message, conversationID: conversationID, prompt: prompt, snapshot: message.text)
        return draft
    }

    static func selection(text: String, message: ChatMessage, conversationID: UUID, prompt: String?) -> NoteDraft {
        let body = SelectionSourceMapper.extractSelectionMarkdown(sourceMarkdown: message.text, renderedSelection: text) ?? text
        var draft = NoteDraft(body: body, captureKind: .selection)
        applySource(to: &draft, message: message, conversationID: conversationID, prompt: prompt, snapshot: message.text)
        return draft
    }

    static func codeBlock(code: String, language: String?, message: ChatMessage, conversationID: UUID, prompt: String?) -> NoteDraft {
        let lang = (language ?? "").trimmingCharacters(in: .whitespaces)
        let body = "```\(lang)\n\(code)\n```"
        var draft = NoteDraft(body: body, captureKind: .selection)
        applySource(to: &draft, message: message, conversationID: conversationID, prompt: prompt, snapshot: message.text)
        return draft
    }

    static func userMessage(message: ChatMessage, conversationID: UUID) -> NoteDraft {
        var draft = NoteDraft(body: message.text, captureKind: .userMessage)
        applySource(to: &draft, message: message, conversationID: conversationID, prompt: message.text, snapshot: message.text)
        return draft
    }

    static func blank(folderID: UUID? = nil) -> NoteDraft {
        NoteDraft(body: "", noteFolderID: folderID, captureKind: .blank)
    }

    private static func applySource(
        to draft: inout NoteDraft,
        message: ChatMessage,
        conversationID: UUID,
        prompt: String?,
        snapshot: String
    ) {
        draft.bodySnapshot = snapshot
        draft.sourceConversationId = conversationID
        draft.sourceMessageId = message.id
        draft.sourceModelID = message.modelID
        draft.sourceModelName = message.modelName
        draft.sourceProviderKind = message.providerKind
        draft.sourceProviderName = message.providerName
        draft.sourcePrompt = prompt
    }
}

enum SelectionSourceMapper {
    private static let minSigLength = 8

    private struct SourceBlock { let raw: String; let sig: String }

    static func extractSelectionMarkdown(sourceMarkdown: String, renderedSelection: String) -> String? {
        let selSig = contentSignature(renderedSelection)
        guard selSig.count >= minSigLength else { return nil }

        let blocks = splitSourceBlocks(sourceMarkdown)
        guard !blocks.isEmpty else { return nil }

        guard let matched = locateCovered(blocks.enumerated().map { ($0.element.sig, $0.offset) }, selSig: selSig) else {
            return nil
        }

        if matched.min == matched.max,
           let refined = refineSingleBlock(blocks[matched.min].raw, selSig: selSig) {
            return refined
        }

        let extracted = blocks[matched.min...matched.max].map(\.raw)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extracted.isEmpty, hasStructure(extracted) else { return nil }
        return extracted
    }

    private static func contentSignature(_ text: String) -> String {
        var sig = ""
        for ch in text.lowercased() where ch.isLetter || ch.isNumber {
            sig.append(ch)
        }
        return sig
    }

    private static func splitSourceBlocks(_ md: String) -> [SourceBlock] {
        var blocks: [SourceBlock] = []
        var curLines: [String] = []
        var hasCur = false
        var inFence = false
        var fenceMarker = ""

        func flush() {
            guard hasCur else { return }
            let raw = curLines.joined(separator: "\n")
            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(SourceBlock(raw: raw, sig: contentSignature(raw)))
            }
            curLines = []
            hasCur = false
        }

        for line in md.components(separatedBy: "\n") {
            let fence = leadingFence(line)
            if inFence {
                curLines.append(line); hasCur = true
                if fence != nil, line.trimmingCharacters(in: .whitespaces).hasPrefix(fenceMarker) { inFence = false }
                continue
            }
            if let fence {
                curLines.append(line); hasCur = true
                inFence = true
                fenceMarker = fence
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            curLines.append(line); hasCur = true
        }
        flush()
        return blocks
    }

    private static func leadingFence(_ line: String) -> String? {
        let t = line.drop { $0 == " " || $0 == "\t" }
        if t.hasPrefix("```") { return "```" }
        if t.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func hasStructure(_ md: String) -> Bool {
        let patterns = [
            #"(^|\n)[^\n]*\|[^\n]*\|"#,
            #"(^|\n)\s*(```|~~~)"#,
            #"(^|\n)\s*([-*+]|\d+\.)\s+"#,
            #"(^|\n)\s*#{1,6}\s+"#,
            #"\$\$[\s\S]+?\$\$"#,
            #"(?<!\$)\$[^\$\n]+?\$(?!\$)"#,
        ]
        return patterns.contains { md.range(of: $0, options: .regularExpression) != nil }
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("|") && t.contains("-") && t.range(of: #"^\|?[\s:|-]+\|?$"#, options: .regularExpression) != nil
    }

    private static func findTableParts(_ blockRaw: String) -> (header: String, separator: String, bodyRows: [String])? {
        let lines = blockRaw.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var i = 1
        while i < lines.count {
            if isSeparatorRow(lines[i]), lines[i - 1].contains("|") {
                let header = lines[i - 1]
                var bodyRows: [String] = []
                var j = i + 1
                while j < lines.count, lines[j].contains("|") { bodyRows.append(lines[j]); j += 1 }
                return bodyRows.isEmpty ? nil : (header, lines[i], bodyRows)
            }
            i += 1
        }
        return nil
    }

    private static func locateCovered(_ units: [(String, Int)], selSig: String) -> (min: Int, max: Int)? {
        var concat = ""
        var owner: [Int] = []
        for (sig, own) in units {
            for ch in sig { concat.append(ch); owner.append(own) }
        }
        guard let range = concat.range(of: selSig) else { return nil }
        let start = concat.distance(from: concat.startIndex, to: range.lowerBound)
        var mn = Int.max
        var mx = -1
        for k in start..<(start + selSig.count) where owner[k] >= 0 {
            mn = Swift.min(mn, owner[k])
            mx = Swift.max(mx, owner[k])
        }
        return mx >= 0 ? (mn, mx) : nil
    }

    private static func extractTableRowSelection(_ blockRaw: String, selSig: String) -> String? {
        guard let parts = findTableParts(blockRaw) else { return nil }
        var units: [(String, Int)] = [(contentSignature(parts.header), -1)]
        for (idx, row) in parts.bodyRows.enumerated() { units.append((contentSignature(row), idx)) }
        guard let covered = locateCovered(units, selSig: selSig) else { return nil }
        let selectedRows = Array(parts.bodyRows[covered.min...covered.max])
        return ([parts.header, parts.separator] + selectedRows).joined(separator: "\n")
    }

    private static func extractLineSelection(_ blockRaw: String, selSig: String) -> String? {
        let lines = blockRaw.components(separatedBy: "\n")
        guard let covered = locateCovered(lines.enumerated().map { (contentSignature($0.element), $0.offset) }, selSig: selSig) else {
            return nil
        }
        let selected = lines[covered.min...covered.max].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (!selected.isEmpty && hasStructure(selected)) ? selected : nil
    }

    private static func refineSingleBlock(_ blockRaw: String, selSig: String) -> String? {
        if blockRaw.range(of: #"(?m)^\s*(```|~~~)"#, options: .regularExpression) != nil {
            return blockRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return extractTableRowSelection(blockRaw, selSig: selSig) ?? extractLineSelection(blockRaw, selSig: selSig)
    }
}
