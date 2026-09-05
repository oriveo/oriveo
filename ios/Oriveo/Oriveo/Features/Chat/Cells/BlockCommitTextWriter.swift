import Foundation
import QuartzCore
import UIKit

@MainActor
final class BlockCommitTextWriter {

    // MARK: - Dependencies

    var textViewProvider: () -> UITextView? = { nil }

    weak var chunkFader: ChunkFadeAnimator?

    // MARK: - State

    private(set) var lastCommittedTail: String = ""

    // MARK: - API

    nonisolated static func normalizedTailForRendering(_ raw: String) -> String {
        var s = Substring(raw)
        while s.first == "\n" { s = s.dropFirst() }
        let hadTrailingNewline = s.last == "\n"
        while s.last == "\n" { s = s.dropLast() }
        guard !s.isEmpty else { return String(s) }
        let lastLine = s.lastIndex(of: "\n").map { s[s.index(after: $0)...] } ?? s
        let trimmedLine = lastLine.trimmingCharacters(in: .whitespaces)
        let isSingleLineBlockMath = trimmedLine.count >= 4
            && ((trimmedLine.hasPrefix("$$") && trimmedLine.hasSuffix("$$"))
                || (trimmedLine.hasPrefix("\\[") && trimmedLine.hasSuffix("\\]")))
        let isHR = MarkdownAttributedStringRenderer.isHorizontalRule(trimmedLine)
        if isSingleLineBlockMath || isHR {
            return String(s) + "\n"
        }
        guard hadTrailingNewline else { return String(s) }
        if trimmedLine == "$$" || trimmedLine == "\\]" {
            return String(s) + "\n"
        }
        return String(s)
    }

    func applyTail(_ rawTailText: String) {
        guard let textView = textViewProvider() else { return }
        let tailText = Self.normalizedTailForRendering(rawTailText)
        guard tailText != lastCommittedTail else { return }
        let storage = textView.textStorage

        guard tailText.hasPrefix(lastCommittedTail), !tailText.isEmpty else {
            rebuild(tailText, in: storage)
            return
        }

        let prevNS = lastCommittedTail as NSString
        let prevLen = prevNS.length
        let delta = (tailText as NSString).substring(from: prevLen)
        guard !delta.isEmpty else { return }

        let lastNL = prevLen > 0
            ? prevNS.range(of: "\n", options: .backwards)
            : NSRange(location: NSNotFound, length: 0)
        let openLine = lastNL.location == NSNotFound
            ? lastCommittedTail
            : prevNS.substring(from: lastNL.location + 1)

        var pieces: [NSAttributedString] = []
        let deltaNS = delta as NSString
        var rest = delta

        if !openLine.isEmpty {
            let firstNL = deltaNS.range(of: "\n")
            let span = firstNL.location == NSNotFound ? delta : deltaNS.substring(to: firstNL.location)
            if !span.isEmpty {
                let kind = MarkdownAttributedStringRenderer.canonicalLineKind(openLine)
                pieces.append(MarkdownAttributedStringRenderer.renderCommittedSpan(
                    kind: kind, span: span, isLineStart: false
                ))
            }
            if firstNL.location != NSNotFound {
                pieces.append(MarkdownAttributedStringRenderer.canonicalLineSeparator())
                rest = deltaNS.substring(from: firstNL.location + 1)
            } else {
                rest = ""
            }
        }

        if !rest.isEmpty {
            let restNS = rest as NSString
            let lastRestNL = restNS.range(of: "\n", options: .backwards)
            if lastRestNL.location != NSNotFound {
                let group = restNS.substring(to: lastRestNL.location)
                if !group.isEmpty {
                    pieces.append(MarkdownAttributedStringRenderer.renderPreservingBoundaries(group))
                }
                pieces.append(MarkdownAttributedStringRenderer.canonicalLineSeparator())
                let partial = restNS.substring(from: lastRestNL.location + 1)
                if !partial.isEmpty {
                    pieces.append(MarkdownAttributedStringRenderer.renderCommittedSpan(
                        kind: MarkdownAttributedStringRenderer.canonicalLineKind(partial),
                        span: partial, isLineStart: true
                    ))
                }
            } else {
                pieces.append(MarkdownAttributedStringRenderer.renderCommittedSpan(
                    kind: MarkdownAttributedStringRenderer.canonicalLineKind(rest),
                    span: rest, isLineStart: true
                ))
            }
        }

        storage.beginEditing()
        for piece in pieces where piece.length > 0 {
            let location = storage.length
            storage.append(piece)
            chunkFader?.enqueueChunk(range: NSRange(location: location, length: piece.length))
        }
        chunkFader?.applyAlphasInCurrentTransaction()
        storage.endEditing()
        lastCommittedTail = tailText
    }

    func harvestForFreeze() -> NSAttributedString {
        guard let textView = textViewProvider() else { return NSAttributedString() }
        chunkFader?.settleAll()
        let harvested = NSAttributedString(attributedString: textView.textStorage)
        textView.textStorage.setAttributedString(NSAttributedString())
        lastCommittedTail = ""
        return harvested
    }

    func reset() {
        lastCommittedTail = ""
    }

    // MARK: - Private

    private func rebuild(_ tailText: String, in storage: NSTextStorage) {
        chunkFader?.settleAll()
        storage.beginEditing()
        if tailText.isEmpty {
            storage.setAttributedString(NSAttributedString())
        } else {
            storage.setAttributedString(
                MarkdownAttributedStringRenderer.renderPreservingBoundaries(tailText)
            )
        }
        storage.endEditing()
        lastCommittedTail = tailText
    }
}
