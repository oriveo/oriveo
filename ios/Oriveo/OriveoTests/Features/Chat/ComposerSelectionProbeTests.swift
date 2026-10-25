import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Composer selection output: the host reads the original-text selection through `ComposerSelectionProbe` and inserts dictated text at the selection.
/// The selection is given as UTF-16 offsets into the original text (without display-layer soft wraps); inserts land via `DictationRules.insert`,
/// on the same length-cap path as typing.
@MainActor
@Suite("Chat composer - selection output and dictation insert", .serialized)
struct ComposerSelectionProbeTests {
    private final class Box {
        var text = ""
        var focused = false
        var notices = 0
    }

    static let sentence = "\u{8FD9}\u{662F}\u{4E00}\u{6BB5}\u{7528}\u{6765}\u{6491}\u{51FA}\u{8F6F}\u{6362}\u{884C}\u{7684}\u{4E2D}\u{6587}\u{53E5}\u{5B50}\u{FF0C}\u{91CC}\u{9762}\u{5939}\u{7740} English words \u{548C}\u{6570}\u{5B57} 12345\u{3002}"

    static func chinese(utf16: Int) -> String {
        var out = ""
        while out.utf16.count < utf16 { out += sentence }
        return out
    }

    private func makeView(
        box: Box,
        probe: ComposerSelectionProbe,
        maxLength: Int? = nil
    ) -> (ComposerUITextView, ComposerTextView.Coordinator, UIWindow) {
        let representable = ComposerTextView(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            isFocused: Binding(get: { box.focused }, set: { box.focused = $0 }),
            placeholder: "Type a message...",
            font: .systemFont(ofSize: 16),
            textColor: .label,
            maxLength: maxLength,
            onLengthLimitExceeded: { box.notices += 1 },
            selectionProbe: probe
        )
        let coordinator = representable.makeCoordinator()
        // The same production construction entry as makeUIView.
        let container = ComposerTextView.makeContainer(coordinator: coordinator)
        coordinator.applyStyle(representable, to: container, force: true)
        coordinator.apply(box.text, to: container.textView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        container.frame = CGRect(x: 20, y: 100, width: 320, height: 110)
        window.addSubview(container)
        window.isHidden = false
        container.layoutIfNeeded()
        return (container.textView, coordinator, window)
    }

    /// The user changes the selection: the view sets selectedRange and UIKit calls back textViewDidChangeSelection.
    private func select(_ range: NSRange, in textView: ComposerUITextView, _ coordinator: ComposerTextView.Coordinator) {
        textView.selectedRange = range
        coordinator.textViewDidChangeSelection(textView)
    }

    /// Mount the text view, select `selection`, then release the whole text view (the recording bar takes the text view's place).
    private func attachSelectThenRelease(
        box: Box,
        probe: ComposerSelectionProbe,
        maxLength: Int? = nil,
        selection: NSRange
    ) throws {
        weak var released: ComposerUITextView?
        autoreleasepool {
            let (textView, coordinator, window) = makeView(box: box, probe: probe, maxLength: maxLength)
            select(selection, in: textView, coordinator)
            window.isHidden = true
            released = textView
        }
        try #require(released == nil, "the text view should have been released")
        try #require(probe.range == selection)
    }

    /// Display-string offset -> original-text offset (only used to build expected values).
    private func sourceOffset(ofDisplay offset: Int, in textView: UITextView) -> Int {
        let prefix = (textView.textStorage.string as NSString).substring(to: offset)
        return SoftParagraphBreaks.source(fromDisplay: prefix).utf16.count
    }

    @Test("selection change: the probe gives the original-text UTF-16 range (the display string contains soft wraps)")
    func range_followsSelection_inSourceUnits() throws {
        let box = Box()
        box.text = Self.chinese(utf16: 6_000)
        let probe = ComposerSelectionProbe()
        let (textView, coordinator, window) = makeView(box: box, probe: probe)
        defer { window.isHidden = true }
        let display = textView.textStorage.string as NSString
        #expect(display.length > (box.text as NSString).length, "the long text should be split into segments by soft wraps in the display layer")
        let firstBreak = display.range(of: SoftParagraphBreaks.separatorString)
        try #require(firstBreak.location != NSNotFound)

        // After apply the caret is at the end.
        #expect(probe.range == NSRange(location: box.text.utf16.count, length: 0))

        let start = NSMaxRange(firstBreak) + 7
        let end = display.range(of: SoftParagraphBreaks.separatorString, range: NSRange(location: start, length: display.length - start))
        try #require(end.location != NSNotFound)
        let selection = NSRange(location: start, length: NSMaxRange(end) + 5 - start)
        select(selection, in: textView, coordinator)

        let sourceStart = sourceOffset(ofDisplay: selection.location, in: textView)
        let sourceEnd = sourceOffset(ofDisplay: NSMaxRange(selection), in: textView)
        #expect(sourceStart == selection.location - 1)
        #expect(sourceEnd - sourceStart == selection.length - 1)
        #expect(probe.range == NSRange(location: sourceStart, length: sourceEnd - sourceStart))
    }

    @Test("insert at a middle selection: per DictationRules.insert, the caret lands after the inserted text, the binding is synced")
    func insert_atMiddleSelection_followsDictationRules() throws {
        let box = Box()
        box.text = "Hello world"
        let probe = ComposerSelectionProbe()
        let (textView, coordinator, window) = makeView(box: box, probe: probe)
        defer { window.isHidden = true }
        select(NSRange(location: 2, length: 3), in: textView, coordinator)
        #expect(probe.range == NSRange(location: 2, length: 3))

        let expected = DictationRules.insert(transcript: "big", into: "Hello world", selectionStart: 2, selectionEnd: 5)
        let returned = probe.insert(transcript: "big", currentText: "ignored")

        #expect(returned == expected.text)
        #expect(returned == "Hello big world")
        #expect(box.text == expected.text)
        #expect(textView.textStorage.string == expected.text)
        #expect(textView.selectedRange == NSRange(location: expected.cursor, length: 0))
        #expect(probe.range == NSRange(location: expected.cursor, length: 0))
    }

    @Test("insert at a selection after a soft wrap: the original text lands and the caret follows original-text offsets")
    func insert_afterSoftBreak_usesSourceOffsets() throws {
        let box = Box()
        box.text = Self.chinese(utf16: 6_000)
        let probe = ComposerSelectionProbe()
        let (textView, coordinator, window) = makeView(box: box, probe: probe)
        defer { window.isHidden = true }
        let display = textView.textStorage.string as NSString
        let firstBreak = display.range(of: SoftParagraphBreaks.separatorString)
        try #require(firstBreak.location != NSNotFound)
        select(NSRange(location: NSMaxRange(firstBreak) + 3, length: 0), in: textView, coordinator)
        let original = box.text
        let caret = probe.range.location
        #expect(caret == NSMaxRange(firstBreak) + 3 - 1)

        let expected = DictationRules.insert(transcript: "dictated words", into: original, selectionStart: caret, selectionEnd: caret)
        let returned = probe.insert(transcript: "dictated words", currentText: "ignored")

        #expect(returned == expected.text)
        #expect(box.text == expected.text)
        #expect(SoftParagraphBreaks.source(fromDisplay: textView.textStorage.string) == expected.text)
        #expect(probe.range == NSRange(location: expected.cursor, length: 0))
        #expect(sourceOffset(ofDisplay: textView.selectedRange.location, in: textView) == expected.cursor)
    }

    @Test("text view not mounted: append to the end of the original text the host gave, not just return the transcript")
    func insert_detached_appendsToCurrentText() {
        let probe = ComposerSelectionProbe()
        let draft = "Draft \u{8349}\u{7A3F}"
        let expected = DictationRules.insert(transcript: " hello ", into: draft, selectionStart: draft.utf16.count, selectionEnd: draft.utf16.count)

        let returned = probe.insert(transcript: " hello ", currentText: draft)

        #expect(returned == expected.text)
        #expect(returned.hasPrefix(draft))
        #expect(returned.hasSuffix("hello"))
        #expect(probe.range == NSRange(location: 0, length: 0))
    }

    @Test("over the cap: the insert is truncated and onLengthLimitExceeded is called")
    func insert_overLimit_truncatesAndNotifies() throws {
        let box = Box()
        box.text = "0123456789"
        let probe = ComposerSelectionProbe()
        let (textView, coordinator, window) = makeView(box: box, probe: probe, maxLength: 14)
        defer { window.isHidden = true }
        select(NSRange(location: 4, length: 0), in: textView, coordinator)

        let returned = probe.insert(transcript: "abcdefgh", currentText: "ignored")

        #expect(returned.utf16.count == 14)
        // DictationRules adds a space between digits and Latin letters: the inserted segment is " abcdefgh ", of which only the first 4 code units fit.
        #expect(returned == "0123 abc456789")
        #expect(box.text == returned)
        #expect(textView.textStorage.string == returned)
        #expect(box.notices == 1)
        #expect(probe.range == NSRange(location: 8, length: 0))
    }
    @Test("mounted then replaced: insert at the cached selection (clamped by the currentText length), the return value per DictationRules.insert")
    func insert_afterTextViewReleased_usesCachedSelection() throws {
        let box = Box()
        box.text = "Hello world"
        let probe = ComposerSelectionProbe()
        try attachSelectThenRelease(box: box, probe: probe, selection: NSRange(location: 2, length: 3))

        let expected = DictationRules.insert(transcript: "big", into: "Hello world", selectionStart: 2, selectionEnd: 5)
        let returned = probe.insert(transcript: "big", currentText: "Hello world")
        #expect(returned == expected.text)
        #expect(returned == "Hello big world")

        // The host draft is shorter than the cached selection: the selection is clamped to the end of the draft.
        let short = "Hey"
        let clamped = DictationRules.insert(transcript: "big", into: short, selectionStart: 2, selectionEnd: 3)
        let returnedShort = probe.insert(transcript: "big", currentText: short)
        #expect(returnedShort == clamped.text)
        #expect(returnedShort == "Hey big")
    }

    @Test("mounted then replaced and the result exceeds the cap: truncate the inserted segment by the cached cap and call the over-limit callback once")
    func insert_afterTextViewReleased_overLimit_truncatesAndNotifies() throws {
        let box = Box()
        box.text = "0123456789"
        let probe = ComposerSelectionProbe()
        try attachSelectThenRelease(box: box, probe: probe, maxLength: 14, selection: NSRange(location: 4, length: 0))
        #expect(box.notices == 0)

        let returned = probe.insert(transcript: "abcdefgh", currentText: "0123456789")

        #expect(returned.utf16.count == 14)
        // Same result as when mounted: the inserted segment " abcdefgh " only fits its first 4 code units.
        #expect(returned == "0123 abc456789")
        #expect(box.notices == 1)

        // Truncation never cuts a surrogate pair: no spaces are added around Chinese text, and the 3 code units left only fit one emoji (2 code units), leaving no half of one.
        let surrogate = probe.insert(transcript: "😀😀", currentText: "\u{96F6}\u{4E00}\u{4E8C}\u{4E09}\u{56DB}\u{4E94}\u{516D}\u{4E03}\u{516B}\u{4E5D}\u{5341}")
        #expect(surrogate == "\u{96F6}\u{4E00}\u{4E8C}\u{4E09}😀\u{56DB}\u{4E94}\u{516D}\u{4E03}\u{516B}\u{4E5D}\u{5341}")
        #expect(surrogate.utf16.count == 13)
        #expect(box.notices == 2)
    }

    @Test("end to end: real controller + host binding, the text view is replaced while recording, and after finish(.insert) the draft is inserted at the cached selection")
    func dictation_afterTextViewReleased_insertsAtCachedSelection() async throws {
        let box = Box()
        box.text = "Hello world"
        let probe = ComposerSelectionProbe()
        try attachSelectThenRelease(box: box, probe: probe, selection: NSRange(location: 2, length: 3))

        let root = FileManager.default.temporaryDirectory
            .appending(path: "ComposerSelectionProbeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "pending", directoryHint: .isDirectory)
        let store = try RecordingStore(root: root, onLost: { _ in })
        let engine = FakeSTTEngine()
        engine.outcome = .success("  big \n")
        let capture = FakeAudioCapture(sampleRate: 48_000)
        let permission = FakeMicrophonePermission()
        permission.status = .granted
        let controller = DictationController(
            engines: .fixed(engine), system: .skipped,
            capture: capture, store: store,
            permission: permission,
            readAloud: ReadAloudController(
                engine: SilentSpeechEngine(), platform: SilentReadAloudPlatform(),
                notificationCenter: NotificationCenter(), detectLanguage: { _ in "en" }
            ),
            screenAwake: ScreenAwakeHolds(timer: FakeIdleTimer()), notificationCenter: NotificationCenter(),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let host = DictationHostBinding(
            canSend: { false },
            onInsert: { box.text = probe.insert(transcript: $0, currentText: box.text) },
            toast: { _ in }
        )
        host.attach(controller: controller, slotKey: "conversation-a")

        await controller.micTapped()
        capture.feed(seconds: 1, amplitude: 0.1)
        await controller.finish(.insert)
        withExtendedLifetime(host) {}

        let expected = DictationRules.insert(transcript: "big", into: "Hello world", selectionStart: 2, selectionEnd: 5)
        #expect(box.text == expected.text)
        #expect(box.text == "Hello big world")
        #expect(controller.state == .idle)
    }
}
