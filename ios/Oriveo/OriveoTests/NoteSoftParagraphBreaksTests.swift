import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Display-only soft paragraph breaks in the bounded note viewport: split correctly, restore the
/// source exactly, never split a character.
@MainActor
@Suite("Note soft paragraph breaks")
struct NoteSoftParagraphBreaksTests {
    private static let limit = NoteSoftParagraphBreaks.maxParagraphUTF16
    private static let key = NoteSoftParagraphBreaks.markerKey

    private static let cjk = String(repeating: "これはとてもながいぶんしょうで、きりわけをためします。", count: 1_000)
    private static let english = String(repeating: "Sentence number one is here. ", count: 800)
    private static let versions = String(repeating: "version 3.14 and example.com/a.b ", count: 700)
    private static let jsonNoBlanks = String(repeating: "{\"pi\":3.14,\"url\":\"https://example.com/a.b\"},", count: 600)
    private static let family = "👨‍👩‍👧‍👦"
    private static let zwj = String(repeating: family, count: 1_200)
    private static let smiles = String(repeating: "😊", count: 5_000)
    private static let combining = String(repeating: "e\u{301}", count: 5_000)
    private static let persian = String(repeating: "سلام دنیا، این یک جمله است. ", count: 700)
    private static let crlf = "はじめ\r\n" + cjk + "\r\nおわり\r\n"
    private static let mixed = "first paragraph\n\n" + english + "\nshort\n" + cjk + "\n"

    private static let samples: [String] = [
        "",
        "a short note",
        String(repeating: "a", count: limit),
        String(repeating: "a", count: limit + 1),
        String(repeating: "a", count: limit * 3 + 7),
        cjk, english, versions, jsonNoBlanks, zwj, smiles, combining, persian, crlf, mixed,
    ]

    /// Index of every soft break in a display string.
    private func softBreaks(in shown: NSAttributedString) -> [Int] {
        var indices: [Int] = []
        shown.enumerateAttribute(Self.key, in: NSRange(location: 0, length: shown.length)) { value, range, _ in
            if value != nil { indices.append(range.location) }
        }
        return indices
    }

    @Test("Stripping soft breaks restores the stored text exactly")
    func roundTrip() {
        for source in Self.samples {
            let shown = BoundedNoteTextView.displayText(for: source)
            #expect(NoteSoftParagraphBreaks.strip(shown) == source, "round trip broke for sample of \(source.utf16.count) units")
        }
    }

    @Test("Text without an over-long paragraph is returned untouched")
    func untouchedWhenNoParagraphExceedsLimit() {
        let atLimit = NSMutableAttributedString(string: String(repeating: "a", count: Self.limit))
        #expect(NoteSoftParagraphBreaks.insertingBreaks(into: atLimit) === atLimit)
        let manyShort = NSMutableAttributedString(string: String(repeating: "short paragraph.\n", count: 5_000))
        #expect(NoteSoftParagraphBreaks.insertingBreaks(into: manyShort) === manyShort)
    }

    @Test("Every display paragraph fits the limit")
    func everyDisplayParagraphFitsLimit() {
        for source in Self.samples {
            let text = BoundedNoteTextView.displayText(for: source).string as NSString
            var location = 0
            while location < text.length {
                var start = 0, end = 0, contentsEnd = 0
                text.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
                #expect(contentsEnd - start <= Self.limit)
                location = max(end, location + 1)
            }
        }
    }

    @Test("Breaks prefer sentence ends: after a full-width full stop, after an ASCII period and space")
    func prefersSentenceEnds() {
        let cjk = BoundedNoteTextView.displayText(for: Self.cjk)
        let cjkText = cjk.string as NSString
        #expect(!softBreaks(in: cjk).isEmpty)
        for index in softBreaks(in: cjk) {
            #expect(cjkText.substring(with: NSRange(location: index - 1, length: 1)) == "。")
        }

        let english = BoundedNoteTextView.displayText(for: Self.english)
        let englishText = english.string as NSString
        #expect(!softBreaks(in: english).isEmpty)
        for index in softBreaks(in: english) {
            #expect(englishText.substring(with: NSRange(location: index - 2, length: 2)) == ". ")
        }
    }

    @Test("An ASCII dot without following whitespace is not a break (3.14, domains, paths)")
    func asciiDotsWithoutBlankAreNotBreaks() {
        let shown = BoundedNoteTextView.displayText(for: Self.versions)
        let text = shown.string as NSString
        #expect(!softBreaks(in: shown).isEmpty)
        for index in softBreaks(in: shown) {
            #expect(text.character(at: index - 1) == 0x20, "soft break must follow a blank, not a bare dot")
        }
    }

    @Test("Hard breaks land on grapheme boundaries and never split ZWJ sequences, surrogates, combining marks or CRLF")
    func hardBreaksRespectGraphemes() {
        let familyUnits = Self.family.utf16.count
        for offset in NoteSoftParagraphBreaks.breakOffsets(in: Self.zwj as NSString) {
            #expect(offset % familyUnits == 0)
        }
        for offset in NoteSoftParagraphBreaks.breakOffsets(in: Self.smiles as NSString) {
            #expect(offset % 2 == 0)
        }
        for offset in NoteSoftParagraphBreaks.breakOffsets(in: Self.combining as NSString) {
            #expect(offset % 2 == 0)
        }
        let crlf = Self.crlf as NSString
        for offset in NoteSoftParagraphBreaks.breakOffsets(in: crlf) {
            #expect(!(crlf.character(at: offset - 1) == 0x0D && crlf.character(at: offset) == 0x0A))
        }
        // No whitespace at all: cut at the limit, every block exactly full.
        let plain = String(repeating: "a", count: Self.limit * 3 + 7) as NSString
        #expect(NoteSoftParagraphBreaks.breakOffsets(in: plain) == [Self.limit, Self.limit * 2, Self.limit * 3])
    }

    @Test("Every block keeps the writing direction of its original paragraph")
    func blocksKeepOriginalParagraphDirection() {
        // The paragraph starts in Persian and continues in English: it is RTL, and so must be the
        // blocks that happen to start with English words.
        let source = "سلام " + String(repeating: "hello world. ", count: 800)
        let shown = BoundedNoteTextView.displayText(for: source)
        #expect(softBreaks(in: shown).count >= 2)
        var directions = Set<Int>()
        shown.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: shown.length)) { value, _, _ in
            directions.insert((value as? NSParagraphStyle)?.baseWritingDirection.rawValue ?? -99)
        }
        #expect(directions == [NSWritingDirection.rightToLeft.rawValue])
    }

    @Test("strip removes only the first newline per break and keeps characters that inherited the marker")
    func stripKeepsInheritedCharacters() {
        let marked: [NSAttributedString.Key: Any] = [Self.key: 0]
        let string = NSMutableAttributedString(string: "before")
        string.append(NSAttributedString(string: "\n", attributes: marked)) // soft break
        string.append(NSAttributedString(string: "\nX", attributes: marked)) // typed right after it
        string.append(NSAttributedString(string: "after"))
        #expect(NoteSoftParagraphBreaks.strip(string) == "before\nXafter")
    }
}

/// Layout cost and editing path of the bounded viewport. Layout assertions check how far the text
/// was laid out (firstUnlaidCharacterIndex), not timing: the former is deterministic.
@MainActor
@Suite("Bounded note text view layout", .serialized)
struct BoundedNoteTextViewLayoutTests {
    /// 120k UTF-16 units in a single paragraph without one newline.
    private static let hugeSingleParagraph: String = {
        let sentence = "このだんらくにはかいぎょうがない、The quick brown fox jumps over the lazy dog. つづけてかく。 "
        return String(repeating: sentence, count: 120_000 / sentence.utf16.count + 1)
    }()

    private static let bound = NoteSoftParagraphBreaks.maxParagraphUTF16 * 3

    private final class Store {
        var text: String
        init(_ text: String) { self.text = text }
    }

    private func makeProductionTextView(
        _ source: String,
        isEditable: Bool
    ) -> (BoundedNoteUITextView, BoundedNoteTextView.Coordinator, Store) {
        let store = Store(source)
        let coordinator = BoundedNoteTextView.Coordinator(text: Binding(get: { store.text }, set: { store.text = $0 }))
        let textView = BoundedNoteTextView.makeTextView(text: source, isEditable: isEditable, coordinator: coordinator)
        return (textView, coordinator, store)
    }

    /// Mirrors SwiftUI sizing the representable: the host bounds go from 0x0 to the real size and
    /// autoresizing sets the text view frame (setBounds, resizeSubviews, UITextView.setFrame).
    private func mount(_ textView: UITextView, size: CGSize) -> (window: UIWindow, host: UIView) {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: .zero)
        }
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        let host = UIView(frame: .zero)
        window.addSubview(host)
        textView.frame = host.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(textView)
        host.bounds = CGRect(origin: .zero, size: size)
        textView.layoutIfNeeded()
        return (window, host)
    }

    private func firstSoftBreak(in textView: UITextView) -> Int? {
        var found: Int?
        let storage = textView.textStorage
        storage.enumerateAttribute(
            NoteSoftParagraphBreaks.markerKey,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if value != nil {
                found = range.location
                stop.pointee = true
            }
        }
        return found
    }

    @Test("A huge single paragraph lays out only the visible part on first sizing")
    func hugeSingleParagraphLayoutStaysBounded() {
        let (textView, _, _) = makeProductionTextView(Self.hugeSingleParagraph, isEditable: false)
        let (window, host) = mount(textView, size: CGSize(width: 386, height: 540))
        defer { window.isHidden = true }
        let laidOut = textView.layoutManager.firstUnlaidCharacterIndex()
        #expect(laidOut < Self.bound, "laid out \(laidOut) of \(textView.textStorage.length) UTF-16 units")

        // A width change (rotation, split view) re-lays out only the visible part as well.
        host.bounds = CGRect(x: 0, y: 0, width: 380, height: 540)
        textView.layoutIfNeeded()
        #expect(textView.layoutManager.firstUnlaidCharacterIndex() < Self.bound)
    }

    @Test("Editing stays bounded and remembers the source text without soft breaks")
    func editableViewStaysBounded() {
        let (textView, coordinator, store) = makeProductionTextView(Self.hugeSingleParagraph, isEditable: true)
        let (window, _) = mount(textView, size: CGSize(width: 386, height: 460))
        defer { window.isHidden = true }
        #expect(textView.layoutManager.firstUnlaidCharacterIndex() < Self.bound)
        #expect(coordinator.appliedSource == store.text)
        #expect(textView.textStorage.length > store.text.utf16.count, "display text carries soft breaks")
    }

    @Test("Text and newlines typed right after a soft break are written back")
    func typingRightAfterSoftBreakIsKept() throws {
        let source = String(repeating: "ぶん。", count: 3_000)
        let (textView, coordinator, store) = makeProductionTextView(source, isEditable: true)
        let soft = try #require(firstSoftBreak(in: textView))

        textView.selectedRange = NSRange(location: soft + 1, length: 0)
        coordinator.textViewDidChangeSelection(textView) // UIKit calls this when the user moves the caret
        #expect(textView.typingAttributes[NoteSoftParagraphBreaks.markerKey] == nil)

        textView.insertText("X\n")
        coordinator.textViewDidChange(textView) // the same write-back path as UIKit's input callback

        let expected = (source as NSString).replacingCharacters(in: NSRange(location: soft, length: 0), with: "X\n")
        #expect(store.text == expected)
        #expect(coordinator.appliedSource == expected)
    }

    @Test("Copy and cut hand out the stored text without soft breaks")
    func copyAndCutUseSourceText() throws {
        let source = String(repeating: "ぶん。", count: 3_000)
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }

        let (reader, _, _) = makeProductionTextView(source, isEditable: false)
        reader.sourcePasteboard = pasteboard
        reader.selectedRange = NSRange(location: 0, length: reader.textStorage.length)
        reader.copy(nil)
        #expect(pasteboard.string == source)

        let (editor, coordinator, store) = makeProductionTextView(source, isEditable: true)
        editor.sourcePasteboard = pasteboard
        let soft = try #require(firstSoftBreak(in: editor))
        // Selection spans the soft break: three characters on each side.
        editor.selectedRange = NSRange(location: soft - 3, length: 7)
        editor.cut(nil)
        coordinator.textViewDidChange(editor)
        let sourceNS = source as NSString
        #expect(pasteboard.string == sourceNS.substring(with: NSRange(location: soft - 3, length: 6)))
        #expect(store.text == sourceNS.replacingCharacters(in: NSRange(location: soft - 3, length: 6), with: ""))
    }
}
