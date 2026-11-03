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

    // MARK: Live text

    /// Observation of one live-text write plus retract: the original text and selection after the write and after the retract.
    private struct LiveTrace: Equatable {
        let written: String?
        let writtenRange: NSRange
        let restored: String?
        let restoredRange: NSRange
    }

    private static let liveSnapshot = DictationRules.livePartial(finals: ["Big"], partial: "wor")

    /// Text view mounted: select `display` on the display string, then start, write a snapshot, retract.
    private func attachedLiveTrace(text: String, display: NSRange) -> (LiveTrace, NSRange, ComposerUITextView, UIWindow) {
        let box = Box()
        box.text = text
        let probe = ComposerSelectionProbe()
        let (textView, coordinator, window) = makeView(box: box, probe: probe)
        select(display, in: textView, coordinator)
        let source = probe.range
        let written = probe.writeLive(Self.liveSnapshot, generation: 1, currentText: "ignored")
        #expect(written.map { SoftParagraphBreaks.source(fromDisplay: textView.textStorage.string) == $0 } ?? false)
        let writtenRange = probe.range
        let restored = probe.restoreLive()
        return (LiveTrace(written: written, writtenRange: writtenRange, restored: restored, restoredRange: probe.range),
                source, textView, window)
    }

    /// Text view not mounted: cached selection `source`; start from the original text the host gave, write a snapshot, retract.
    private func detachedLiveTrace(text: String, source: NSRange) -> LiveTrace {
        let probe = ComposerSelectionProbe()
        probe.update(range: source)
        let written = probe.writeLive(Self.liveSnapshot, generation: 1, currentText: text)
        let writtenRange = probe.range
        let restored = probe.restoreLive()
        return LiveTrace(written: written, writtenRange: writtenRange, restored: restored, restoredRange: probe.range)
    }

    @Test("live-text write / retract: recomputed from the original text and selection at the start; mounted and unmounted text view give the same result")
    func liveWriteAndRestore_sameAttachedOrDetached() {
        let (attached, source, textView, window) = attachedLiveTrace(text: "Hello world", display: NSRange(location: 2, length: 3))
        defer { window.isHidden = true }
        let detached = detachedLiveTrace(text: "Hello world", source: source)

        let expected = DictationRules.liveInsert(
            finals: ["Big"], partial: "wor", into: "Hello world", selectionStart: 2, selectionEnd: 5
        )
        #expect(attached == detached)
        #expect(attached.written == expected.text)
        #expect(attached.writtenRange == NSRange(location: expected.cursor, length: 0))
        #expect(attached.restored == "Hello world")
        #expect(attached.restoredRange == NSRange(location: 2, length: 3))
        #expect(textView.textStorage.string == "Hello world")
        #expect(textView.selectedRange == NSRange(location: 2, length: 3))
    }

    @Test("soft-wrapped long text: live text lands at original-text offsets; mounted and unmounted give the same result")
    func liveWriteAndRestore_softBreaks_sameAttachedOrDetached() throws {
        let text = Self.chinese(utf16: 6_000)
        let (attached, source, textView, window) = attachedLiveTrace(text: text, display: NSRange(location: 4_500, length: 0))
        defer { window.isHidden = true }
        try #require(source.location < 4_500, "the selection should land after the soft wrap")
        let detached = detachedLiveTrace(text: text, source: source)

        let expected = DictationRules.liveInsert(
            finals: ["Big"], partial: "wor", into: text, selectionStart: source.location, selectionEnd: source.location
        )
        #expect(attached == detached)
        #expect(attached.written == expected.text)
        #expect(attached.restored == text)
        #expect(attached.restoredRange == source)
        #expect(SoftParagraphBreaks.source(fromDisplay: textView.textStorage.string) == text)
    }

    @Test("finalize: after retracting the live text, insert at the selection from the start; the caret lands after the finalized text")
    func liveRestoreThenInsert_cursorAfterFinal() {
        let box = Box()
        box.text = "Hello world"
        let probe = ComposerSelectionProbe()
        let (textView, coordinator, window) = makeView(box: box, probe: probe)
        defer { window.isHidden = true }
        select(NSRange(location: 2, length: 3), in: textView, coordinator)
        _ = probe.writeLive(Self.liveSnapshot, generation: 1, currentText: box.text)

        #expect(probe.restoreLive() == "Hello world")
        let returned = probe.insert(transcript: "Big word", currentText: "ignored")
        let expected = DictationRules.insert(transcript: "Big word", into: "Hello world", selectionStart: 2, selectionEnd: 5)
        #expect(returned == expected.text)
        #expect(textView.selectedRange == NSRange(location: expected.cursor, length: 0))
        #expect(probe.range == NSRange(location: expected.cursor, length: 0))
    }

    @Test("no live text written: retract leaves the original text unchanged and returns nil")
    func liveRestoreWithoutWrite_isNoOp() {
        let probe = ComposerSelectionProbe()
        probe.update(range: NSRange(location: 2, length: 0))
        #expect(probe.restoreLive() == nil)
        #expect(probe.range == NSRange(location: 2, length: 0))
        #expect(probe.restoreLive() == nil)
    }

    @Test("previous generation not retracted (cloud failure or silent preflight, liveDiscarded not sent): the first snapshot of the new generation is based on the user's later original text and selection")
    func liveNewGeneration_refetchesBase() {
        let probe = ComposerSelectionProbe()
        probe.update(range: NSRange(location: 2, length: 3))
        _ = probe.writeLive(Self.liveSnapshot, generation: 1, currentText: "Hello world")

        probe.update(range: NSRange(location: 3, length: 0))
        let written = probe.writeLive(Self.liveSnapshot, generation: 2, currentText: "Bye")
        let expected = DictationRules.liveInsert(finals: ["Big"], partial: "wor", into: "Bye", selectionStart: 3, selectionEnd: 3)
        #expect(written == expected.text)
        // Later snapshots in the same generation still recompute from this generation's original text instead of reading currentText.
        let next = probe.writeLive(DictationRules.livePartial(finals: ["Big", "word"], partial: ""), generation: 2,
                                   currentText: "stale")
        #expect(next == DictationRules.liveInsert(
            finals: ["Big", "word"], partial: "", into: "Bye", selectionStart: 3, selectionEnd: 3
        ).text)
    }

    @Test("after clearing the original text (idle / failed): insert takes the normal insert path and no longer replaces the old live range")
    func liveClear_insertFallsBackToPlainInsert() {
        let probe = ComposerSelectionProbe()
        probe.update(range: NSRange(location: 2, length: 3))
        _ = probe.writeLive(Self.liveSnapshot, generation: 1, currentText: "Hello world")
        probe.clearLive()

        probe.update(range: NSRange(location: 3, length: 0))
        let returned = probe.insert(transcript: "big", currentText: "Bye")
        #expect(returned == DictationRules.insert(transcript: "big", into: "Bye", selectionStart: 3, selectionEnd: 3).text)
    }

    @Test("final text too long: liveInsert(original, selection, [text], \"\") truncates and stays within the cap")
    func liveFinalInsert_overLimit_truncatedByLiveInsert() {
        let text = String(repeating: "\u{5B57}", count: DictationRules.maxTextLength - 2)
        let end = text.utf16.count
        let probe = ComposerSelectionProbe()
        probe.update(range: NSRange(location: end, length: 0))
        _ = probe.writeLive(Self.liveSnapshot, generation: 1, currentText: text)

        let returned = probe.insert(transcript: "Big word", currentText: "ignored")
        let expected = DictationRules.liveInsert(
            finals: ["Big word"], partial: "", into: text, selectionStart: end, selectionEnd: end
        )
        #expect(returned == expected.text)
        #expect(returned.utf16.count <= DictationRules.maxTextLength)
        #expect(probe.range == NSRange(location: expected.cursor, length: 0))
    }

    @Test("end to end: real controller and host binding, the text view stays mounted while recording, and after finish(.insert) the draft is inserted at the selection")
    func dictation_withTextViewMounted_insertsAtSelection() async throws {
        let box = Box()
        box.text = "Hello world"
        let probe = ComposerSelectionProbe()
        let (textView, coordinator, window) = makeView(box: box, probe: probe)
        defer { window.isHidden = true }
        select(NSRange(location: 2, length: 3), in: textView, coordinator)
        try #require(probe.range == NSRange(location: 2, length: 3))

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
        withExtendedLifetime(textView) {}

        let expected = DictationRules.insert(transcript: "big", into: "Hello world", selectionStart: 2, selectionEnd: 5)
        #expect(box.text == expected.text)
        #expect(box.text == "Hello big world")
        #expect(controller.state == .idle)
    }

    // MARK: Unfinalized light style and undo history

    /// Close the group that the undo stack opened automatically per event: steps registered afterwards form their own group.
    private func endEvent() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    /// Text view mounted and first responder; type " there" (one user-undoable step), then select `selection`.
    private func typedView(probe: ComposerSelectionProbe, box: Box, selection: NSRange)
        throws -> (ComposerUITextView, ComposerTextView.Coordinator, UIWindow, UndoManager) {
        box.text = "Hello"
        let (textView, coordinator, window) = makeView(box: box, probe: probe)
        window.makeKeyAndVisible()
        _ = textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.insertText(" there")
        endEvent()
        let undoManager = try #require(textView.undoManager)
        try #require(textView.textStorage.string == "Hello there")
        try #require(undoManager.canUndo, "typing should leave one undoable step")
        select(selection, in: textView, coordinator)
        return (textView, coordinator, window, undoManager)
    }

    @Test("text view mounted, live text written: the unfinalized range uses the dictationVolatile light color, the rest is body text color")
    func liveWrite_volatileRangeUsesDictationVolatileColor() throws {
        let box = Box()
        box.text = "Hello world"
        let probe = ComposerSelectionProbe()
        let (textView, coordinator, window) = makeView(box: box, probe: probe)
        defer { window.isHidden = true }
        select(NSRange(location: 11, length: 0), in: textView, coordinator)

        let written = probe.writeLive(Self.liveSnapshot, generation: 1, currentText: "ignored")
        let expected = DictationRules.liveInsert(
            finals: ["Big"], partial: "wor", into: "Hello world", selectionStart: 11, selectionEnd: 11
        )
        try #require(written == expected.text)
        try #require(!expected.volatile.isEmpty)
        let storage = textView.textStorage
        try #require(storage.string == expected.text)
        for index in 0..<storage.length {
            let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor
            if expected.volatile.contains(index) {
                #expect(color === ComposerTextView.Coordinator.dictationVolatileColor, "offset \(index) should be the light color")
            } else {
                #expect(color == UIColor.label, "offset \(index) should be the body text color")
            }
        }
        let light = ComposerTextView.Coordinator.dictationVolatileColor.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light))
        let dark = ComposerTextView.Coordinator.dictationVolatileColor.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .dark))
        #expect(light == UIColor(oriveoHex: 0x71717A, alpha: 1))
        #expect(dark == UIColor(oriveoHex: 0x8E8E96, alpha: 1))

        // After finalizing, the whole range is body text color.
        _ = probe.insert(transcript: "Big word", currentText: "ignored")
        for index in 0..<textView.textStorage.length {
            let color = textView.textStorage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor
            #expect(color == UIColor.label)
        }
    }

    @Test("after dictation ends: one undo returns to the original text and selection from before recording, redo returns to the result, typing steps from before recording are still undoable")
    func liveFinish_registersOneUndoStep_keepsEarlierSteps() throws {
        let box = Box()
        let probe = ComposerSelectionProbe()
        let selection = NSRange(location: 0, length: 5)
        let (textView, coordinator, window, undoManager) = try typedView(probe: probe, box: box, selection: selection)
        defer { window.isHidden = true }
        defer { withExtendedLifetime(coordinator) {} }

        _ = probe.writeLive(Self.liveSnapshot, generation: 1, currentText: "ignored")
        let returned = probe.insert(transcript: "Big word", currentText: "ignored")
        box.text = returned
        endEvent()
        let expected = DictationRules.liveInsert(
            finals: ["Big word"], partial: "", into: "Hello there", selectionStart: 0, selectionEnd: 5
        )
        #expect(returned == expected.text)
        #expect(undoManager.undoActionName.isEmpty)

        undoManager.undo()
        #expect(textView.textStorage.string == "Hello there")
        #expect(textView.selectedRange == selection)
        #expect(box.text == "Hello there")
        #expect(probe.range == selection)

        endEvent()
        undoManager.redo()
        #expect(textView.textStorage.string == expected.text)
        #expect(textView.selectedRange == NSRange(location: expected.cursor, length: 0))
        #expect(box.text == expected.text)

        endEvent()
        undoManager.undo()
        endEvent()
        #expect(undoManager.canUndo, "the typing step from before recording should still be present")
        undoManager.undo()
        #expect(textView.textStorage.string == "Hello")
    }

    @Test("during recording (live text written) undo and redo do not run; abandoning live text does not register an undo step")
    func liveWriting_suspendsUndo_restoreRegistersNothing() throws {
        let box = Box()
        let probe = ComposerSelectionProbe()
        let (textView, coordinator, window, undoManager) = try typedView(
            probe: probe, box: box, selection: NSRange(location: 11, length: 0)
        )
        defer { window.isHidden = true }
        defer { withExtendedLifetime(coordinator) {} }

        let written = try #require(probe.writeLive(Self.liveSnapshot, generation: 1, currentText: "ignored"))
        endEvent()
        let recording = try #require(textView.undoManager)
        #expect(!recording.canUndo)
        #expect(!recording.canRedo)
        recording.undo()
        #expect(textView.textStorage.string == written)

        #expect(probe.restoreLive() == "Hello there")
        endEvent()
        // After abandoning, the stack top is still the typing step from before recording: one undo goes back to before the typing.
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(textView.textStorage.string == "Hello")
    }

    // MARK: Read-only text view

    @Test("read-only text view (isEditable = false): live text is still written, unfinalized light color; after finalizing the whole range is one undoable step")
    func readOnlyView_liveWriteAndFinish_writeTextAndRegisterUndo() throws {
        let box = Box()
        let probe = ComposerSelectionProbe()
        let selection = NSRange(location: 11, length: 0)
        let (textView, coordinator, window, undoManager) = try typedView(probe: probe, box: box, selection: selection)
        defer { window.isHidden = true }
        defer { withExtendedLifetime(coordinator) {} }
        textView.isEditable = false
        endEvent()

        let written = probe.writeLive(Self.liveSnapshot, generation: 1, currentText: "ignored")
        let live = DictationRules.liveInsert(
            finals: ["Big"], partial: "wor", into: "Hello there", selectionStart: 11, selectionEnd: 11
        )
        #expect(written == live.text)
        #expect(textView.textStorage.string == live.text)
        try #require(!live.volatile.isEmpty)
        for index in 0..<textView.textStorage.length {
            let color = textView.textStorage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor
            if live.volatile.contains(index) {
                #expect(color === ComposerTextView.Coordinator.dictationVolatileColor, "offset \(index) should be the light color")
            } else {
                #expect(color == UIColor.label, "offset \(index) should be the body text color")
            }
        }
        #expect(!textView.isEditable, "restored to read-only after writing")

        let returned = probe.insert(transcript: "Big word", currentText: "ignored")
        box.text = returned
        endEvent()
        let expected = DictationRules.liveInsert(
            finals: ["Big word"], partial: "", into: "Hello there", selectionStart: 11, selectionEnd: 11
        )
        #expect(returned == expected.text)
        #expect(textView.textStorage.string == expected.text)
        #expect(!textView.isEditable, "restored to read-only after finalizing")

        #expect(undoManager.canUndo, "the whole dictation should register one undo step")
        undoManager.undo()
        #expect(textView.textStorage.string == "Hello there")
        #expect(box.text == "Hello there")
    }
}
