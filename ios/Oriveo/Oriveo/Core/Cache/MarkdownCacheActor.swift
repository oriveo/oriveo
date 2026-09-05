import Foundation

nonisolated enum MarkdownStaticRenderingMode: Sendable, Equatable {
    case plainText
    case blockMarkdown
    case segmentedCodeMarkdown
    case inlineMarkdown
}

nonisolated struct MarkdownRenderHint: Sendable, Equatable {
    let messageID: UUID
    let contentHash: Int
    let mode: MarkdownStaticRenderingMode

    nonisolated static func hash(for text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }

    nonisolated func matches(text: String) -> Bool {
        contentHash == Self.hash(for: text)
    }
}

nonisolated enum MarkdownRenderingClassifier {
    private final class RenderingModeCacheEntry {
        let mode: MarkdownStaticRenderingMode

        init(_ mode: MarkdownStaticRenderingMode) {
            self.mode = mode
        }
    }

    private static let markdownDetector = try! NSRegularExpression(
        pattern: #"\*\*|__|```|`|]\(|\$\$|\\\[|\\\(|^#{1,6}(?!#)[ \t]*\S|^> |\n> |\n[*\-] |\n\d+\. "#,
        options: [.anchorsMatchLines]
    )

    private static let blockMarkdownDetector = try! NSRegularExpression(
        pattern: #"(?m)^(?:[ ]{0,3}(?:[-+*]|\d+\.)\s+|[ ]{0,3}>[ ]+|[ ]{0,3}#{1,6}(?!#)[ \t]*\S|[ ]{0,3}(?:[-*_][ \t]*){3,}|[ ]{0,3}\|.*\|[ \t]*$)"#
    )

    private static let renderingModeCache: NSCache<NSNumber, RenderingModeCacheEntry> = {
        let cache = NSCache<NSNumber, RenderingModeCacheEntry>()
        cache.countLimit = 500
        return cache
    }()

    static func staticRenderingMode(for text: String) -> MarkdownStaticRenderingMode {
        let key = NSNumber(value: text.hashValue)
        if let cached = renderingModeCache.object(forKey: key) {
            return cached.mode
        }

        let mode = uncachedStaticRenderingMode(for: text)
        renderingModeCache.setObject(RenderingModeCacheEntry(mode), forKey: key)
        return mode
    }

    static func resolvedRenderingMode(
        for text: String,
        renderHint: MarkdownRenderHint?
    ) -> MarkdownStaticRenderingMode {
        if let renderHint, renderHint.matches(text: text) {
            return renderHint.mode
        }
        return staticRenderingMode(for: text)
    }

    static func shouldNotifyHeightChange(from previousHeight: CGFloat, to newHeight: CGFloat) -> Bool {
        guard previousHeight.isFinite, newHeight.isFinite else { return false }
        return abs(previousHeight - newHeight) >= 1
    }

    private static func uncachedStaticRenderingMode(for text: String) -> MarkdownStaticRenderingMode {
        let range = NSRange(text.startIndex..., in: text)
        let hasMarkdown = markdownDetector.firstMatch(in: text, range: range) != nil ||
            blockMarkdownDetector.firstMatch(in: text, range: range) != nil
        guard hasMarkdown else { return .plainText }
        if text.contains("```") {
            return .segmentedCodeMarkdown
        }
        if blockMarkdownDetector.firstMatch(in: text, range: range) != nil {
            return .blockMarkdown
        }
        return .inlineMarkdown
    }
}

actor MarkdownCacheActor {
    func prepareHint(messageID: UUID, text: String) async -> MarkdownRenderHint {
        let contentHash = MarkdownRenderHint.hash(for: text)
        return MarkdownRenderHint(
            messageID: messageID,
            contentHash: contentHash,
            mode: MarkdownRenderingClassifier.staticRenderingMode(for: text)
        )
    }

    private var preparedKeys: Set<Int> = []
    private var preparedOrder: [Int] = []
    private static let preparedKeyBudget = 400

    func prepareRendered(text: String, isDark: Bool) {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(isDark)
        let key = hasher.finalize()
        guard !preparedKeys.contains(key) else { return }

        let cached = MarkdownAttributedStringRenderer.prewarm(text, isDark: isDark)
        prewarmStaticBodySegments(text: text, isDark: isDark)
        guard cached else { return }

        preparedKeys.insert(key)
        preparedOrder.append(key)
        if preparedOrder.count > Self.preparedKeyBudget {
            let evicted = preparedOrder.removeFirst()
            preparedKeys.remove(evicted)
        }
    }

    private func prewarmStaticBodySegments(text: String, isDark: Bool) {
        let parsed = StreamingSegmentParser.parse(text)
        for segment in parsed.committed {
            if case .text = segment.kind {
                MarkdownAttributedStringRenderer.prewarm(segment.content, isDark: isDark)
            }
        }
        if !parsed.tail.isEmpty {
            let tailSegment = StreamingSegmentParser.Segment(kind: .text, content: parsed.tail)
            let refined = StreamingSegmentParser.splitTextSegmentsForTables([tailSegment])
            for segment in refined {
                if case .text = segment.kind {
                    MarkdownAttributedStringRenderer.prewarm(segment.content, isDark: isDark)
                }
            }
        }
    }
}
