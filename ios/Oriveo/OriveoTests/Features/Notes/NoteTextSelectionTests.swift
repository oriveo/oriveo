import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// The long-note reading surface is a series of lazy blocks; selecting across blocks goes through "Select text", which puts the whole note into one selectable bounded text view.
@MainActor
@Suite("Long note body cross-block selection", .serialized, .sharedProcessState)
struct NoteTextSelectionTests {
    private typealias Gate = NoteLongBodyPerformanceGateTests

    /// The two markers sit in different lazy units (proves the selection spans blocks).
    private func markersInDifferentUnits(_ body: String, _ a: String, _ b: String) -> Bool {
        guard let units = NoteLazyMarkdownBody.units(markdown: NoteText.readingMarkdown(body)) else { return false }
        let ia = units.firstIndex { $0.content.text.contains(a) }
        let ib = units.firstIndex { $0.content.text.contains(b) }
        return ia != nil && ib != nil && ia != ib
    }

    private func selectAndCopy(_ view: BoundedNoteUITextView, from a: String, through b: String) -> String? {
        let display = view.textStorage.string as NSString
        let start = display.range(of: a).location
        let end = NSMaxRange(display.range(of: b))
        guard start != NSNotFound, end > start else { return nil }
        let pasteboard = UIPasteboard.withUniqueName()
        view.sourcePasteboard = pasteboard
        view.selectedRange = NSRange(location: start, length: end - start)
        view.copy(nil)
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        return pasteboard.string ?? UIPasteboard.general.string
    }

    @Test("Dragging a selection across two blocks in the select-text view copies text containing both blocks' markers")
    func copiesAcrossUnits() async throws {
        let body = Gate.virtualizationBody(sections: 300)
        #expect(markersInDifferentUnits(body, "marker12 ", "marker13 "))
        let view = BoundedNoteTextView.makeTextView(text: body, isEditable: false, coordinator: BoundedNoteTextView.Coordinator(text: .constant(body)))
        let window = makeSceneWindow(width: 390, height: 844)
        window.addSubview(view)
        window.isHidden = false
        view.frame = CGRect(x: 0, y: 0, width: 346, height: 600)
        view.layoutIfNeeded()
        let copied = try #require(selectAndCopy(view, from: "marker12 ", through: "marker13 "))
        #expect(copied.contains("marker12"))
        #expect(copied.contains("marker13"))
        #expect(copied.contains("val x = 12"), "The code block source between the two blocks is also in the selection")
        window.isHidden = true
    }

    @Test("Tapping \"Select text\" on the detail page: the whole source goes into one selectable view, scrolls to the reader's current position, and copies across blocks")
    func detailPageSelectionMode() async throws {
        let state = AppState(seedDemoData: false, sessionUID: "note-select-\(UUID().uuidString)")
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: state.sessionPartitionUID))
        }
        let body = Gate.virtualizationBody(sections: 300)
        let note = try #require(state.noteManager.createNote(from: NoteDraft(title: "Select", body: body, captureKind: .blank)))
        await settle(1.0)
        let host = UIHostingController(rootView: AnyView(NoteDetailView(noteID: note.id).environment(state)))
        let window = makeSceneWindow(width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            host.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        await settle(1.5)
        let select = try #require(Self.accessibilityElement(labeled: L10n.tr("Select text", table: .notes), in: host.view), "A long note should have \"Select text\"")
        #expect(select.accessibilityActivate())
        await settle(1.5)
        let presented = try #require(host.presentedViewController, "The select-text panel should be presented")
        let view = try #require(Self.descendant(BoundedNoteUITextView.self, of: presented.view))
        #expect(NoteSoftParagraphBreaks.strip(view.textStorage) == body, "The panel contains the whole source")
        #expect(!view.isEditable)
        let copied = try #require(selectAndCopy(view, from: "marker12 ", through: "marker13 "))
        #expect(copied.contains("marker12") && copied.contains("marker13"))

        // A short note is a single view and can already be selected continuously: this button must not appear.
        let shortNote = try #require(state.noteManager.createNote(from: NoteDraft(title: "Short", body: Gate.virtualizationBody(sections: 2), captureKind: .blank)))
        presented.dismiss(animated: false)
        await settle(0.5)
        // Use a new host: swapping rootView in the same host makes SwiftUI reuse the old detail page's state.
        let shortHost = UIHostingController(rootView: NoteDetailView(noteID: shortNote.id).environment(state))
        window.rootViewController = shortHost
        shortHost.view.frame = window.bounds
        await settle(1.5)
        #expect(Self.accessibilityElement(labeled: L10n.tr("Edit", table: .notes), in: shortHost.view) != nil)
        #expect(Self.accessibilityElement(labeled: L10n.tr("Select text", table: .notes), in: shortHost.view) == nil)
    }

    @Test("The k-th reader block maps to the position of its first line in the source")
    func unitSourceLocation() throws {
        let body = Gate.virtualizationBody(sections: 300)
        let units = try #require(NoteLazyMarkdownBody.units(markdown: NoteText.readingMarkdown(body)))
        let index = try #require(units.firstIndex { $0.content.text.contains("marker150 ") })
        let location = NoteLazyMarkdownBody.sourceLocation(ofUnit: index, units: units, in: body)
        let firstLine = String(units[index].content.text.split(separator: "\n").first ?? "")
        #expect((body as NSString).substring(from: location).hasPrefix(firstLine.trimmingCharacters(in: .whitespaces)))
        #expect(NoteLazyMarkdownBody.sourceLocation(ofUnit: 0, units: units, in: body) == 0)
    }

    @Test("Long-pressing a word in a reader block presents the panel directly with that word preselected (both the SwiftUI paragraph and code block text view paths); short notes have no long press attached")
    func longPressPreselectsWord() async throws {
        let state = AppState(seedDemoData: false, sessionUID: "note-press-\(UUID().uuidString)")
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: state.sessionPartitionUID))
        }
        let body = Gate.virtualizationBody(sections: 300)
        let note = try #require(state.noteManager.createNote(from: NoteDraft(title: "Press", body: body, captureKind: .blank)))
        await settle(1.0)
        let host = UIHostingController(rootView: AnyView(NoteDetailView(noteID: note.id).environment(state)))
        let window = makeSceneWindow(width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            host.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        await settle(1.5)
        let reader = try #require(Self.readers(in: window).first, "The long-note reader should have long press attached")
        func press(_ point: CGPoint) { NoteLazyLongPressHit.fire(atWindowPoint: point, registry: reader) }
        let font = UIFont.systemFont(ofSize: MarkdownTypography.notes.baseFontSize)

        // 1. Paragraph in the MarkdownUI group (SwiftUI Text): press on the second word.
        let (label, frame) = try #require(Self.visibleTextElement(prefix: "Paragraph marker", in: window), "The first screen should have a paragraph")
        let word = String(label.split(separator: " ")[1])
        let lead = ("Paragraph " as NSString).size(withAttributes: [.font: font]).width
        let wordWidth = (word as NSString).size(withAttributes: [.font: font]).width
        press(CGPoint(x: frame.minX + lead + wordWidth / 2, y: frame.minY + min(frame.height, font.lineHeight) / 2))
        await settle(1.5)
        var presented = try #require(host.presentedViewController, "Long press should present the select-text panel directly")
        var panel = try #require(Self.descendant(BoundedNoteUITextView.self, of: presented.view))
        var display = panel.textStorage.string as NSString
        #expect(panel.selectedRange == NSRange(location: display.range(of: "Paragraph \(word) ").location + 10, length: (word as NSString).length),
                "The preselected word is the one pressed: \(display.substring(with: panel.selectedRange))")
        presented.dismiss(animated: false)
        await settle(0.8)

        // 2. Code block (UITextView): press on the number.
        let code = try #require(Self.visibleCodeTextView(in: window), "The first screen should have a code block")
        let codeText = (code.text ?? "") as NSString
        let number = codeText.substring(from: 8).trimmingCharacters(in: .whitespacesAndNewlines)
        let start = try #require(code.position(from: code.beginningOfDocument, offset: 8))
        let end = try #require(code.position(from: start, offset: (number as NSString).length))
        let rect = code.convert(code.firstRect(for: try #require(code.textRange(from: start, to: end))), to: nil)
        press(CGPoint(x: rect.midX, y: rect.midY))
        await settle(1.5)
        presented = try #require(host.presentedViewController, "Long-pressing the code block should present the panel")
        panel = try #require(Self.descendant(BoundedNoteUITextView.self, of: presented.view))
        display = panel.textStorage.string as NSString
        #expect(panel.selectedRange == NSRange(location: display.range(of: "val x = \(number)\n").location + 8, length: (number as NSString).length),
                "The preselected number in the code block is the one pressed: \(display.substring(with: panel.selectedRange))")
        presented.dismiss(animated: false)
        await settle(0.5)

        // A short note is a single view: no long press attached, behavior unchanged.
        let shortNote = try #require(state.noteManager.createNote(from: NoteDraft(title: "Short", body: Gate.virtualizationBody(sections: 2), captureKind: .blank)))
        let shortHost = UIHostingController(rootView: NoteDetailView(noteID: shortNote.id).environment(state))
        window.rootViewController = shortHost
        shortHost.view.frame = window.bounds
        await settle(1.5)
        #expect(Self.accessibilityElement(labeled: L10n.tr("Edit", table: .notes), in: shortHost.view) != nil)
        #expect(Self.readers(in: window).isEmpty, "A short note does not use lazy blocks and has no long press attached")
        #expect(shortHost.presentedViewController == nil)
    }

    @Test("Long press mapping: the k-th occurrence of a word in the rendered text maps to the k-th occurrence in the source block range; with no word available, pick one by in-block fraction")
    func longPressSourceMapping() throws {
        let body = Gate.virtualizationBody(sections: 300)
        let units = try #require(NoteLazyMarkdownBody.units(markdown: NoteText.readingMarkdown(body)))
        let index = try #require(units.firstIndex { $0.content.text.contains("marker150 ") })
        let label = "Paragraph marker150 with bold and code."
        let press = NoteLazyLongPress(unitIndex: index, fraction: 0, renderedText: label, renderedWord: (label as NSString).range(of: "marker150"))
        let range = NoteLazyMarkdownBody.selectionRange(for: press, units: units, in: body)
        #expect((body as NSString).substring(with: range) == "marker150")
        #expect(range.location == (body as NSString).range(of: "marker150 ").location)
        let bold = NoteLazyLongPress(unitIndex: index, fraction: 0, renderedText: label, renderedWord: (label as NSString).range(of: "bold"))
        #expect(NoteLazyMarkdownBody.selectionRange(for: bold, units: units, in: body).location
                == (body as NSString).range(of: "**bold**", range: NSRange(location: range.location, length: 200)).location + 2)
        let blind = NoteLazyMarkdownBody.selectionRange(for: NoteLazyLongPress(unitIndex: index, fraction: 0), units: units, in: body)
        #expect(blind.length > 0, "The fraction fallback also lands on a word")
        #expect(blind.location >= NoteLazyMarkdownBody.sourceLocation(ofUnit: index, units: units, in: body))
    }

    /// Lazy reader surfaces with long press attached in this window (decided by whether their registered block anchors are in this window).
    private static func readers(in window: UIWindow) -> [NoteLazyVisibleUnits] {
        NoteLazyVisibleUnits.debugInstances.allObjects.filter { registry in
            registry.onLongPress != nil
                && registry.anchors.objectEnumerator()?.allObjects.contains { ($0 as? UIView)?.window === window } == true
        }
    }

    private static func visibleCodeTextView(in root: UIView) -> UITextView? {
        if let view = root as? UITextView, !(view is BoundedNoteUITextView), view.text.hasPrefix("val x = "),
           let window = view.window, window.bounds.insetBy(dx: 0, dy: 60).contains(view.convert(view.bounds, to: nil)) {
            return view
        }
        for child in root.subviews { if let hit = visibleCodeTextView(in: child) { return hit } }
        return nil
    }

    /// The SwiftUI text element on the first screen whose label starts with `prefix` (frame in window coordinates).
    private static func visibleTextElement(prefix: String, in window: UIWindow) -> (String, CGRect)? {
        var visited = Set<ObjectIdentifier>()
        func search(_ node: NSObject) -> (String, CGRect)? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.isAccessibilityElement, !(node is UIView), let label = node.accessibilityLabel, label.hasPrefix(prefix) {
                let frame = window.convert(node.accessibilityFrame, from: window.screen.coordinateSpace)
                if window.bounds.insetBy(dx: 0, dy: 60).contains(frame) { return (label, frame) }
            }
            var children: [NSObject] = []
            if let elements = node.accessibilityElements as? [NSObject] {
                children.append(contentsOf: elements)
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let child = node.accessibilityElement(at: index) as? NSObject { children.append(child) }
                    }
                }
            }
            if let view = node as? UIView { children.append(contentsOf: view.subviews) }
            for child in children { if let hit = search(child) { return hit } }
            return nil
        }
        return search(window)
    }

    private static func descendant<T: UIView>(_ type: T.Type, of root: UIView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews { if let hit = descendant(type, of: child) { return hit } }
        return nil
    }

    private static func accessibilityElement(labeled label: String, in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func search(_ node: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.isAccessibilityElement, node.accessibilityLabel == label { return node }
            var children: [NSObject] = []
            if let elements = node.accessibilityElements as? [NSObject] {
                children.append(contentsOf: elements)
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let child = node.accessibilityElement(at: index) as? NSObject { children.append(child) }
                    }
                }
            }
            if let view = node as? UIView { children.append(contentsOf: view.subviews) }
            for child in children {
                if let hit = search(child) { return hit }
            }
            return nil
        }
        return search(root)
    }
}
