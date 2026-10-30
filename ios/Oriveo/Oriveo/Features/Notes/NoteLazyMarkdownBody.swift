import SwiftUI
import UIKit

/// Lazy rendering of long note bodies: the leaf views that a whole-body `MarkdownMessageView` render
/// already stacks (`MarkdownLazyUnit`: segments cut at code fences, groups of a MarkdownUI body cut at
/// top-level blocks) are put into a `LazyVStack` one by one, so only units near the viewport are built.
///
/// Equivalence with the whole-body render rests on `MarkdownLazyUnit`: the cuts come from the renderer
/// itself, unit spacing is the renderer's own spacing, and every unit goes through the same leaf entry.
/// The card background / shadow / colophon are still drawn once by the detail page over the whole card.
/// The cut boundaries were already separate views, so the selection / copy range is unchanged for
/// bodies of up to 10k characters, which stay in one UITextView (selectable across paragraphs).
///
/// Before this, whole-body first-frame cost grew linearly with length (code + table mixes and table
/// bodies of ~40 sections took hundreds of milliseconds), and bodies over 10k UTF-16 units had to
/// degrade to plain text.
struct NoteLazyMarkdownBody: View {
    let units: [MarkdownLazyUnit]
    /// Units currently built on screen (updated as rows appear / disappear). A reference type that does not trigger re-rendering: read once, when Select Text is tapped.
    var visibleUnits: NoteLazyVisibleUnits?
    /// Long press on a block: the detail page opens Select Text and preselects the pressed word (each block is its own view, so an in-place selection cannot span blocks).
    var onLongPress: ((NoteLazyLongPress) -> Void)?

    /// Bodies shorter than this (about a screen and a half) stay one whole render, so short notes are unchanged.
    nonisolated static let minimumUTF16Count = 3_000

    /// Only cut when the body is long enough and the whole render really is a stack of several leaf views.
    /// Every length is rendered as rich text; only a single block that cannot be cut (tens of thousands
    /// of characters without one paragraph boundary, e.g. one unbroken generated paragraph) returns nil,
    /// and the caller hands it to the bounded plain-text viewport: laying out tens of thousands of
    /// characters in one UITextView is still O(n) and risks a watchdog termination.
    nonisolated static func units(markdown: String) -> [MarkdownLazyUnit]? {
        guard markdown.utf16.count >= minimumUTF16Count else { return nil }
        let units = MarkdownMessageView.lazyUnits(for: markdown, typography: .notes)
        guard units.count >= 2 || NoteText.requiresBoundedLayout(markdown) else { return nil }
        guard units.allSatisfy({ $0.content.text.utf16.count <= MarkdownMessageView.maximumLazyUnitUTF16 }) else { return nil }
        return units
    }

    #if DEBUG
    /// For tests: the number of units built (whose body has been evaluated).
    static var debugRowBodyCount = 0
    #endif

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(units.indices, id: \.self) { index in
                NoteLazyMarkdownRow(unit: units[index])
                    .background { NoteLazyRowAnchor(index: index, registry: visibleUnits, onLongPress: onLongPress) }
                    .onAppear { visibleUnits?.indices.insert(index) }
                    .onDisappear { visibleUnits?.indices.remove(index) }
            }
        }
        .gesture(NoteLazyLongPressGesture(registry: visibleUnits))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NoteLazyMarkdownRow: View {
    let unit: MarkdownLazyUnit

    var body: some View {
        #if DEBUG
        let _ = NoteLazyMarkdownBody.debugRowBodyCount += 1
        #endif
        MarkdownLazyUnitView(unit: unit, typography: .notes)
    }
}

/// Pre-renders the CachedMarkdownView chunks cut from a long body into its cache in the background:
/// chunks are built only when scrolled near, and on a cache miss CachedMarkdownView shows a plain-text
/// placeholder until parsing finishes, which flashes and jumps in height while scrolling. Before opening,
/// only the first-screen chunks are awaited (so the first frame hits the cache) and the rest keep going in
/// the background; the cache is shared with chat (150 entries), so only the first `budget` chunks are warmed.
enum NoteLazyMarkdownPrewarm {
    static let awaitedUnits = 4
    static let budget = 100

    static func prepare(units: [MarkdownLazyUnit]?, isDark: Bool) async {
        guard let units else { return }
        let texts: [String] = units.compactMap {
            if case let .cachedMarkdown(text) = $0.content { return text }
            return nil
        }
        guard !texts.isEmpty else { return }
        let head = Array(texts.prefix(awaitedUnits))
        let tail = Array(texts.dropFirst(awaitedUnits).prefix(budget - awaitedUnits))
        await Task.detached(priority: .userInitiated) {
            for text in head { _ = CachedMarkdownView.cachedRender(text, typography: .notes, isDark: isDark) }
        }.value
        guard !tail.isEmpty else { return }
        Task.detached(priority: .utility) {
            for text in tail { _ = CachedMarkdownView.cachedRender(text, typography: .notes, isDark: isDark) }
        }
    }
}

/// Indices of the units currently built in the reading pane's lazy stack.
final class NoteLazyVisibleUnits {
    var indices: Set<Int> = []
    /// Anchor view of every built unit (the row background, same size as the row): on a long press, finds which block was pressed by window coordinates.
    let anchors = NSMapTable<NSNumber, UIView>.strongToWeakObjects()

    /// The detail page's long-press callback (written when a row anchor is made / updated, used on long press).
    var onLongPress: ((NoteLazyLongPress) -> Void)?

    var top: Int { indices.min() ?? 0 }

    #if DEBUG
    /// For tests: SwiftUI creates the UIKit recognizer only on the first touch, so tests cannot reach it; they take the live reading pane from here and run the same path that follows recognition.
    static let debugInstances = NSHashTable<NoteLazyVisibleUnits>.weakObjects()
    #endif

    /// Window coordinates to (unit index, vertical fraction within the block, window).
    func unit(atWindowPoint point: CGPoint) -> (index: Int, fraction: CGFloat, window: UIWindow)? {
        for index in indices {
            guard let anchor = anchors.object(forKey: NSNumber(value: index)), let window = anchor.window else { continue }
            let frame = anchor.convert(anchor.bounds, to: nil)
            guard frame.contains(point) else { continue }
            return (index, frame.height > 0 ? (point.y - frame.minY) / frame.height : 0, window)
        }
        return nil
    }
}

/// Where a long press landed on the reading pane. `renderedText` is the displayed text at the press: for a UITextView block (CachedMarkdownView / plain text / code)
/// it is the view's display string; for a MarkdownUI group (a body with tables, SwiftUI Text) it is the accessibility label of the pressed text element. `renderedWord` is the pressed word.
/// When neither is available only the vertical fraction within the block remains.
nonisolated struct NoteLazyLongPress: Equatable, Sendable {
    let unitIndex: Int
    let fraction: CGFloat
    var renderedText: String?
    var renderedWord: NSRange?
}

/// An empty view in the row background, used only to measure the row's position in the window on a long press (takes no touches, draws nothing).
private struct NoteLazyRowAnchor: UIViewRepresentable {
    let index: Int
    let registry: NoteLazyVisibleUnits?
    let onLongPress: ((NoteLazyLongPress) -> Void)?

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        updateUIView(view, context: context)
        #if DEBUG
        if let registry { NoteLazyVisibleUnits.debugInstances.add(registry) }
        #endif
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        registry?.anchors.setObject(view, forKey: NSNumber(value: index))
        registry?.onLongPress = onLongPress
    }
}

/// Handling after a long press on the reading pane is recognized: finds the block by window coordinates, then the text view inside it and the pressed word, and hands them to the detail page.
enum NoteLazyLongPressHit {
    static func fire(atWindowPoint point: CGPoint, registry: NoteLazyVisibleUnits?) {
        guard let registry, let onLongPress = registry.onLongPress,
              let (index, fraction, window) = registry.unit(atWindowPoint: point) else { return }
        var press = NoteLazyLongPress(unitIndex: index, fraction: fraction)
        if let textView = Self.textView(at: point, in: window) {
            press.renderedText = textView.text
            press.renderedWord = Self.word(in: textView, atWindowPoint: point)
            // The text view's own long press already yields (see Coordinator); if another gesture still starts an in-place selection, the panel takes over and the in-place one is cleared.
            textView.selectedTextRange = nil
        } else if let (label, frame) = Self.textElement(at: point, in: window) {
            press.renderedText = label
            press.renderedWord = Self.word(inLabel: label, size: frame.size, at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY))
        }
        onLongPress(press)
    }

    private static func textView(at point: CGPoint, in window: UIWindow) -> UITextView? {
        var view = window.hitTest(point, with: nil)
        while let current = view {
            if let textView = current as? UITextView { return textView }
            view = current.superview
        }
        return nil
    }

    /// Range (UTF-16) of the pressed word in the text view's display string. Goes through UITextInput and never touches layoutManager (that would downgrade a TextKit 2 view).
    static func word(in textView: UITextView, atWindowPoint point: CGPoint) -> NSRange? {
        guard let position = textView.closestPosition(to: textView.convert(point, from: nil)) else { return nil }
        let tokenizer = textView.tokenizer
        let forward = UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        let backward = UITextDirection(rawValue: UITextStorageDirection.backward.rawValue)
        guard let range = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: forward)
            ?? tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: backward) else { return nil }
        let location = textView.offset(from: textView.beginningOfDocument, to: range.start)
        let length = textView.offset(from: range.start, to: range.end)
        return length > 0 ? NSRange(location: location, length: length) : nil
    }

    /// SwiftUI text (MarkdownUI) has no hit-testable glyphs: takes the smallest labeled accessibility element under the press (frame in window coordinates).
    /// Only descends along branches whose frame contains the point, and runs once per long press.
    private static func textElement(at point: CGPoint, in window: UIWindow) -> (label: String, frame: CGRect)? {
        let screenPoint = window.convert(point, to: window.screen.coordinateSpace)
        var best: (label: String, frame: CGRect)?
        var visited = Set<ObjectIdentifier>()
        func visit(_ node: NSObject, depth: Int) {
            guard depth < 64, visited.insert(ObjectIdentifier(node)).inserted else { return }
            if let view = node as? UIView {
                guard !view.isHidden, view.convert(view.bounds, to: nil).contains(point) else { return }
            } else if !node.accessibilityFrame.contains(screenPoint) {
                return
            }
            if node.isAccessibilityElement, !(node is UIView),
               let label = node.accessibilityLabel, !label.isEmpty,
               !node.accessibilityTraits.contains(.button) {
                let frame = window.convert(node.accessibilityFrame, from: window.screen.coordinateSpace)
                if best.map({ frame.width * frame.height < $0.frame.width * $0.frame.height }) ?? true {
                    best = (label, frame)
                }
            }
            if let elements = node.accessibilityElements as? [NSObject] {
                for element in elements { visit(element, depth: depth + 1) }
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let element = node.accessibilityElement(at: index) as? NSObject { visit(element, depth: depth + 1) }
                    }
                }
            }
            if let view = node as? UIView {
                for child in view.subviews { visit(child, depth: depth + 1) }
            }
        }
        visit(window, depth: 0)
        return best
    }

    /// Lays the label out at body font size (a small TextKit 1 string, scaling vertically to the element's real height to cancel the heading font-size difference) and takes the word at the pressed point.
    static func word(inLabel label: String, size: CGSize, at point: CGPoint) -> NSRange? {
        let text = label as NSString
        guard text.length > 0, size.width > 0 else { return nil }
        let storage = NSTextStorage(string: label, attributes: [.font: UIFont.systemFont(ofSize: MarkdownTypography.notes.baseFontSize)])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: size.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let used = layoutManager.usedRect(for: container)
        let y = used.height > 0 && size.height > 0 ? point.y * used.height / size.height : point.y
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: CGPoint(x: point.x, y: y), in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        var hit: NSRange?
        var previous: NSRange?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byWords) { _, range, _, stop in
            if NSMaxRange(range) > index {
                hit = range.location <= index ? range : (previous ?? range)
                stop.pointee = true
            }
            previous = range
        }
        return hit ?? previous
    }
}

/// Recognized simultaneously with scrolling and the text views' own gestures (does not steal scrolling; fails once movement exceeds the tolerance).
private struct NoteLazyLongPressGesture: UIGestureRecognizerRepresentable {
    let registry: NoteLazyVisibleUnits?

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        guard recognizer.state == .began else { return }
        NoteLazyLongPressHit.fire(atWindowPoint: recognizer.location(in: nil), registry: registry)
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        /// A text view's own long press (in-place word selection / magnifier) must wait for this long press to fail: otherwise both recognize at once,
        /// and the in-place selection and edit menu show up on the reading pane first and linger underneath once the panel appears. Taps and double taps are unaffected.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            guard other is UILongPressGestureRecognizer, var view = other.view else { return false }
            while true {
                if view is UITextView { return true }
                guard let parent = view.superview else { return false }
                view = parent
            }
        }
    }
}

extension NoteLazyMarkdownBody {
    /// Start (UTF-16) of unit `index` in the stored source. Unit text comes from readingMarkdown (rules removed, blank lines collapsed),
    /// so each unit's first line is searched for in order in the source, keeping the previous position when not found; this only scrolls Select Text to roughly the same place.
    static func sourceLocation(ofUnit index: Int, units: [MarkdownLazyUnit], in source: String) -> Int {
        let text = source as NSString
        var cursor = 0
        for unit in units.prefix(index + 1) {
            let firstLine = unit.content.text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map { String($0.trimmingCharacters(in: .whitespaces).prefix(48)) } ?? ""
            guard !firstLine.isEmpty else { continue }
            let found = text.range(of: firstLine, options: [], range: NSRange(location: cursor, length: text.length - cursor))
            if found.location != NSNotFound { cursor = found.location }
        }
        return cursor
    }
    /// Long-press point to the range (UTF-16) to preselect in the stored source. A block's source interval runs from its first line to the next block's first line.
    /// With a pressed word: first find the start of the displayed text's first line in the block interval (the display string has Markdown markers removed; the first 24 characters are used),
    /// and if the word is its k-th occurrence in the displayed text, take the k-th occurrence in the source from there (Markdown markers almost never add the same word);
    /// if the count does not line up, take the occurrence nearest the proportionally estimated position. With nothing to go on, estimate the position from the vertical fraction in the block and take the word there.
    static func selectionRange(for press: NoteLazyLongPress, units: [MarkdownLazyUnit], in source: String) -> NSRange {
        let text = source as NSString
        let start = sourceLocation(ofUnit: press.unitIndex, units: units, in: source)
        var end = press.unitIndex + 1 < units.count
            ? sourceLocation(ofUnit: press.unitIndex + 1, units: units, in: source) : text.length
        if end <= start { end = text.length }
        let fraction = min(max(press.fraction, 0), 1)
        let estimate = min(start + Int(CGFloat(end - start) * fraction), max(end - 1, start))

        if let rendered = press.renderedText.map({ $0 as NSString }), let word = press.renderedWord,
           word.length > 0, NSMaxRange(word) <= rendered.length {
            let needle = rendered.substring(with: word)
            let ordinal = occurrences(of: needle, in: rendered, range: NSRange(location: 0, length: word.location)).count
            var from = start
            let lead = String(rendered as String)
                .split(separator: "\n", omittingEmptySubsequences: true).first
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(24)) } ?? ""
            if !lead.isEmpty {
                let found = text.range(of: lead, options: .literal, range: NSRange(location: start, length: end - start))
                if found.location != NSNotFound { from = found.location }
            }
            let candidates = occurrences(of: needle, in: text, range: NSRange(location: from, length: end - from))
            if ordinal < candidates.count { return candidates[ordinal] }
            let renderedEstimate = start + Int(CGFloat(end - start) * CGFloat(word.location) / CGFloat(max(rendered.length, 1)))
            if let nearest = candidates.min(by: { abs($0.location - renderedEstimate) < abs($1.location - renderedEstimate) }) {
                return nearest
            }
        }
        return wordRange(in: text, near: estimate) ?? NSRange(location: estimate, length: 0)
    }

    private static func occurrences(of needle: String, in text: NSString, range: NSRange) -> [NSRange] {
        var found: [NSRange] = []
        var search = range
        while search.length > 0 {
            let hit = text.range(of: needle, options: .literal, range: search)
            guard hit.location != NSNotFound else { break }
            found.append(hit)
            search = NSRange(location: NSMaxRange(hit), length: NSMaxRange(range) - NSMaxRange(hit))
        }
        return found
    }

    /// The word at `location`; in whitespace between words, the next word on the same line, and at the end of a line the previous one.
    private static func wordRange(in text: NSString, near location: Int) -> NSRange? {
        guard text.length > 0 else { return nil }
        let line = text.lineRange(for: NSRange(location: min(location, text.length - 1), length: 0))
        var before: NSRange?
        var after: NSRange?
        text.enumerateSubstrings(in: line, options: .byWords) { _, range, _, stop in
            if NSMaxRange(range) > location {
                after = range
                stop.pointee = true
            } else {
                before = range
            }
        }
        return after ?? before
    }
}
