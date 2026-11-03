import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Long-note performance gate (iOS half). The fixture matches Android in scale and structure:
/// - `seedMarkdown(lines:)` copies Android `BenchmarkSeedReceiver.markdownSection` line by line (headings / paragraphs / lists / ordered lists / tables /
///   code blocks / inline and block formulas / quotes, 33 lines per section); the production figure `BenchmarkSeedScale.Production.longMarkdownLines` = 3200 lines;
/// - `virtualizationBody(sections:)` copies `NoteDetailLongBodyVirtualizationTest.body` (300 / 1500 sections).
/// Locks the longest main-thread stall in three scenarios: first frame of opening a detail (any length is lazy rich text, as on Android), entering edit (a body of ≥ 10k UTF-16
/// goes through a bounded plain-text viewport), and the streaming cross-check of each token chunk; it also asserts that 1500 sections cost about the same as 300.
/// Ratio rule: 1500 sections ≤ 300 sections × 1.3 (when both are single-digit milliseconds, a difference ≤ half a frame, 8ms, also counts as equal, so jitter does not inflate small numbers into a ratio).
/// The length comparison reads the Hodges–Lehmann shift (median of all pairwise 1500 − 300 run differences) against the
/// 300-section median: stalls are bimodal (edit 4–7 / 13–18 ms at every length) with outliers on both sides (probe
/// quantization 0–5 ms), so per-tier medians or minimums pick a mode per side. Absolute ceilings keep the median.
@MainActor
@Suite("Long note performance gate", .serialized, .sharedProcessState)
struct NoteLongBodyPerformanceGateTests {
    static let productionSeedLines = 3_200
    /// Runs per measured tier: ceilings read the median, the length comparison reads all runs.
    private static let sampleCount = 5
    /// Reference workload median of the simulator the absolute ceilings below were set on (the slot simulator runtime iOS 18.0,
    /// same anchor as `ProviderCatalogSearchExpandHangTests.stallCeilingReference`); ceilings scale by "current reference / this anchor".
    /// Not `referenceBaseline` (iOS 27.0, 85.9 ms): that anchor would tighten every ceiling by ~30% on the slot runtime.
    private static let ceilingReference = ProviderCatalogSearchExpandHangTests.stallCeilingReference

    static func seedMarkdown(lines: Int) -> String {
        var out: [String] = []
        var section = 0
        while out.count < lines {
            section += 1
            for line in seedSection(section) where out.count < lines {
                out.append(line)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func seedSection(_ index: Int) -> [String] {
        [
            "## Section \(index): rendering cost breakdown",
            "",
            "This section covers metric group \(index); the focus is the relationship between recomposition count and measure time.",
            "",
            "- Key point A: block-level commits split long text into syntactically complete blocks",
            "- Key point B: the metronome can only advance within the prefix already received",
            "- Key point C: enter catchup when the backlog exceeds the threshold",
            "",
            "1. Measure `Recomposer:recompose` first",
            "2. Then measure `Compose:measure`",
            "3. Only then look at `AndroidOwner:draw`",
            "",
            "| Stage | Time | Share |",
            "| --- | --- | --- |",
            "| Recomposition | \(index * 3) ms | 42% |",
            "| Layout | \(index * 2) ms | 31% |",
            "| Drawing | \(index) ms | 27% |",
            "",
            "```kotlin",
            "fun section\(index)(state: RenderState): Int {",
            "    val blocks = state.blocks.filter { it.isCommitted }",
            "    return blocks.sumOf { it.lineCount }",
            "}",
            "```",
            "",
            "Inline math: frame budget $T_{frame} = 1000 / 120$ ms.",
            "",
            "$$",
            "P_{90}(d) = \\inf\\{x : F(x) \\ge 0.9\\}",
            "$$",
            "",
            "> Quote: simulator numbers are only for relative comparison; absolute values do not decide pass or fail.",
            "",
        ]
    }

    static func virtualizationBody(sections: Int) -> String {
        var out = ""
        for index in 0..<sections {
            out += "## Heading \(index)\n\n"
            out += "Paragraph marker\(index) with **bold** and `code`.\n\n"
            out += "```kotlin\nval x = \(index)\n```\n\n"
            out += "| a | b |\n|---|---|\n| \(index) | \(index + 1) |\n\n"
        }
        return out
    }

    // MARK: - Detail page scenarios

    struct DetailSample {
        let openStall: CFTimeInterval
        let selectStall: CFTimeInterval?
        let closeSelectStall: CFTimeInterval?
        let editStall: CFTimeInterval
    }

    /// Open detail (first frame) → tap "Edit" through the accessibility tree (the same action path as a VoiceOver double-tap) to enter edit mode.
    private func openAndEdit(state: AppState, label: String, body: String) async throws -> DetailSample {
        let note = try #require(state.noteManager.createNote(from: NoteDraft(title: "Gate", body: body, captureKind: .blank)))
        // Persistence and mirror aftermath from creating the note itself is not counted toward the cost of opening the detail.
        await settle(1.0)

        let host = UIHostingController(rootView: NoteDetailView(noteID: note.id).environment(state))
        let window = makeSceneWindow(width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let probe = MainThreadStallProbe()
        probe.start()
        host.view.layoutIfNeeded()
        await settle(1.5)
        probe.stop()
        let openStall = probe.maxStall

        // "Select text": only present for long bodies (the whole note goes into one optional bounded view); measure the main-thread cost of opening the panel, then close it.
        var selectStall: CFTimeInterval?
        var closeSelectStall: CFTimeInterval?
        if let select = Self.accessibilityElement(labeled: L10n.tr("Select text", table: .notes), in: host.view) {
            probe.start()
            #expect(select.accessibilityActivate())
            await settle(1.5)
            probe.stop()
            selectStall = probe.maxStall
            let panel = try #require(host.presentedViewController, "\(label): the select-text panel did not appear")
            // Use the panel's "Done" (SwiftUI dismiss, the same path as the user). A direct UIKit dismiss bypasses the sheet binding,
            // Panel teardown would spill into the next state update and be counted as "enter edit"; 1500 sections came out 10–18ms slower than 300 (measured 2026-10-29).
            let done = try #require(Self.accessibilityElement(labeled: L10n.tr("Done"), in: panel.view), "\(label): cannot find \"Done\" in the panel")
            probe.start()
            #expect(done.accessibilityActivate())
            await settle(1.0)
            probe.stop()
            closeSelectStall = probe.maxStall
            #expect(host.presentedViewController == nil, "\(label): the select-text panel was not dismissed")
            await settle(0.5)
        }

        let edit = try #require(Self.accessibilityElement(labeled: L10n.tr("Edit", table: .notes), in: host.view), "Cannot find \"Edit\"")
        probe.start()
        #expect(edit.accessibilityActivate(), "\"Edit\" did not respond to accessibility activation")
        await settle(1.5)
        probe.stop()
        let editStall = probe.maxStall
        #expect(Self.accessibilityElement(labeled: L10n.tr("Save", table: .notes), in: host.view) != nil, "\(label): did not enter edit mode")

        print("[NOTE-GATE] \(label): \(body.utf16.count) UTF-16 / \(body.split(separator: "\n", omittingEmptySubsequences: false).count) lines; longest open-first-frame stall \(Self.ms(openStall)), select text \(selectStall.map(Self.ms) ?? "-"), close panel \(closeSelectStall.map(Self.ms) ?? "-"), longest enter-edit stall \(Self.ms(editStall))")
        return DetailSample(openStall: openStall, selectStall: selectStall, closeSelectStall: closeSelectStall, editStall: editStall)
    }

    /// Runs `openAndEdit` `sampleCount` times for one tier; `median` feeds the ceilings, `runs` the length comparison.
    private func medianOpenAndEdit(state: AppState, label: String, body: String) async throws -> (median: DetailSample, runs: [DetailSample]) {
        var samples: [DetailSample] = []
        for run in 1...Self.sampleCount {
            samples.append(try await openAndEdit(state: state, label: "\(label) #\(run)", body: body))
        }
        func median(_ values: [CFTimeInterval]) -> CFTimeInterval { values.sorted()[values.count / 2] }
        func medianIfAll(_ values: [CFTimeInterval?]) -> CFTimeInterval? {
            let present = values.compactMap { $0 }
            return present.count == values.count ? median(present) : nil
        }
        let result = DetailSample(
            openStall: median(samples.map(\.openStall)),
            selectStall: medianIfAll(samples.map(\.selectStall)),
            closeSelectStall: medianIfAll(samples.map(\.closeSelectStall)),
            editStall: median(samples.map(\.editStall))
        )
        print("[NOTE-GATE] \(label) median of \(Self.sampleCount): open \(Self.ms(result.openStall)), select \(result.selectStall.map(Self.ms) ?? "-"), close \(result.closeSelectStall.map(Self.ms) ?? "-"), edit \(Self.ms(result.editStall))")
        return (result, samples)
    }

    /// Opens the detail page, optionally opens and closes "Select text", then taps "Edit" through the accessibility tree
    /// and returns how many reading rows had their body evaluated during the edit transition.
    private func editTransitionRowBuilds(state: AppState, body: String, opensSelectionFirst: Bool) async throws -> Int {
        let note = try #require(state.noteManager.createNote(from: NoteDraft(title: "Gate", body: body, captureKind: .blank)))
        await settle(1.0)
        let host = UIHostingController(rootView: NoteDetailView(noteID: note.id).environment(state))
        let window = makeSceneWindow(width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        await settle(1.5)
        if opensSelectionFirst {
            let select = try #require(Self.accessibilityElement(labeled: L10n.tr("Select text", table: .notes), in: host.view))
            #expect(select.accessibilityActivate())
            await settle(1.5)
            let panel = try #require(host.presentedViewController, "select text panel did not open")
            let done = try #require(Self.accessibilityElement(labeled: L10n.tr("Done"), in: panel.view))
            #expect(done.accessibilityActivate())
            await settle(1.5)
        }
        let edit = try #require(Self.accessibilityElement(labeled: L10n.tr("Edit", table: .notes), in: host.view))
        let before = NoteLazyMarkdownBody.debugRowBodyCount
        #expect(edit.accessibilityActivate())
        await settle(1.5)
        let builds = NoteLazyMarkdownBody.debugRowBodyCount - before
        #expect(Self.accessibilityElement(labeled: L10n.tr("Save", table: .notes), in: host.view) != nil, "did not enter edit")
        print("[NOTE-GATE] enter edit row bodies \(builds) (select text first: \(opensSelectionFirst))")
        return builds
    }

    @Test("Entering edit does not rebuild reading rows: 300 / 1500 sections, with and without opening select text first")
    func enterEditKeepsReadingRowsUntouched() async throws {
        let state = AppState(seedDemoData: false, sessionUID: "note-gate-rows-\(UUID().uuidString)")
        for sections in [300, 1_500] {
            for opensSelectionFirst in [true, false] {
                let builds = try await editTransitionRowBuilds(
                    state: state, body: Self.virtualizationBody(sections: sections), opensSelectionFirst: opensSelectionFirst
                )
                #expect(builds <= 2, "\(sections) sections, select text first \(opensSelectionFirst): \(builds) row bodies during enter edit")
            }
        }
    }

    @Test("Open detail / enter edit: the 3200-line production-scale fixture has an upper bound, 1500 sections cost about the same as 300")
    func detailOpenAndEdit() async throws {
        let state = AppState(seedDemoData: false, sessionUID: "note-gate-\(UUID().uuidString)")
        defer {
            await TestPartitionCleanup.remove(state.sessionPartitionUID)
        }
        _ = try await openAndEdit(state: state, label: "warm-up", body: Self.virtualizationBody(sections: 2))
        // The first bounded viewport has a one-time TextKit 1 initialization, which does not count toward any tier.
        _ = try await openAndEdit(state: state, label: "warm-up (bounded viewport)", body: Self.virtualizationBody(sections: 120))
        // The fixture is Chinese: the first Chinese layout loads the CJK font cascade (a one-time cost unrelated to note length; any first Chinese text, such as on the chat page, pays it).
        // Pay that cost first with a short Chinese bounded note, then measure the production-scale fixture.
        _ = try await openAndEdit(state: state, label: "warm-up (Chinese)", body: Self.seedMarkdown(lines: 400))
        // Reference workload around the measured tiers (min of before / after: a spike only tightens the gate).
        let referenceBefore = try await HangReferenceWorkload.measure()
        let seed = try await medianOpenAndEdit(state: state, label: "production \(Self.productionSeedLines) lines", body: Self.seedMarkdown(lines: Self.productionSeedLines)).median
        let (small, smallRuns) = try await medianOpenAndEdit(state: state, label: "300 sections", body: Self.virtualizationBody(sections: 300))
        let (large, largeRuns) = try await medianOpenAndEdit(state: state, label: "1500 sections", body: Self.virtualizationBody(sections: 1_500))
        let referenceAfter = try await HangReferenceWorkload.measure()
        let reference = min(referenceBefore, referenceAfter)
        func ceiling(_ value: CFTimeInterval) -> CFTimeInterval {
            CalibratedNestedGate.absoluteCeiling(value, reference: reference, anchor: Self.ceilingReference)
        }
        print("[NOTE-GATE] reference \(Self.ms(reference)) / anchor \(Self.ms(Self.ceilingReference)): ceiling factor \(String(format: "%.3f", reference / Self.ceilingReference))")

        // Absolute ceiling: under four frames on the simulator (M5 / M1 measurements are in the commit notes); before the change, rendering the same fixture as one rich-text block took hundreds of milliseconds.
        for (label, sample) in [("3200 lines", seed), ("300 sections", small), ("1500 sections", large)] {
            #expect(sample.openStall < ceiling(0.06), "\(label) open first frame \(Self.ms(sample.openStall)) vs \(Self.ms(ceiling(0.06)))")
            // Entering edit on the 3200-line Chinese fixture measured 40–59ms on M1 (CJK font cascade); the ceiling is 80ms. Whether cost grows with length is governed by the ratio assertion below.
            #expect(sample.editStall < ceiling(0.08), "\(label) enter edit \(Self.ms(sample.editStall)) vs \(Self.ms(ceiling(0.08)))")
            let selectStall = try #require(sample.selectStall, "\(label) should have \"Select text\"")
            // Select text is a one-off panel transition the user triggers (including sheet presentation); M1 measured 300 / 1500 sections at 50 / 57ms, and the 3200-line Chinese fixture at 77ms.
            #expect(selectStall < ceiling(0.1), "\(label) select text \(Self.ms(selectStall)) vs \(Self.ms(ceiling(0.1)))")
            // Tap "Done" to close the panel (including the sheet dismissal transition). Before the change, the tint dimming triggered a bounded-view redraw and a full re-layout; M1 measured 300 / 1500 sections at 75 / 150ms.
            let closeStall = try #require(sample.closeSelectStall, "\(label) should measure the close-panel stall")
            #expect(closeStall < ceiling(0.08), "\(label) close select text \(Self.ms(closeStall)) vs \(Self.ms(ceiling(0.08)))")
        }
        // Length comparisons read the pairwise shift over all runs (see the type comment); a missing reading fails.
        func lengthCheck(_ name: String, _ stall: (DetailSample) -> CFTimeInterval?) {
            let largeValues = largeRuns.compactMap(stall), smallValues = smallRuns.compactMap(stall)
            let complete = largeValues.count == largeRuns.count && smallValues.count == smallRuns.count
            let shift = complete ? Self.shift(largeValues, smallValues) : 1
            print("[NOTE-GATE] \(name) 1500 − 300 sections shift \(Self.ms(shift)) (300 median \(Self.ms(stall(small) ?? 0)))")
            #expect(complete && Self.comparable(shift: shift, smallMedian: stall(small) ?? 0), "\(name) 1500 − 300 sections shift \(Self.ms(shift)) vs 300 median \(Self.ms(stall(small) ?? 0))")
        }
        lengthCheck("select text") { $0.selectStall }
        lengthCheck("close select text") { $0.closeSelectStall }
        // Independent of length: a body 5 times longer does not raise the cost.
        lengthCheck("open first frame") { $0.openStall }
        // Entering edit parks the reading face instead of tearing it down (no row rebuild): 300 / 1500 sections under 40 ms.
        for (label, sample) in [("300 sections", small), ("1500 sections", large)] {
            #expect(sample.editStall < ceiling(0.04), "\(label) enter edit \(Self.ms(sample.editStall)) vs \(Self.ms(ceiling(0.04)))")
        }
        lengthCheck("enter edit") { $0.editStall }
    }

    // MARK: - Helpers

    /// 1500 sections ≤ 300 sections × 1.3, or the two differ by less than half a frame (8ms).
    static func comparable(_ large: CFTimeInterval, _ small: CFTimeInterval) -> Bool {
        large <= small * 1.3 || large - small <= 0.008
    }

    /// Same 1.3× / 8 ms rule, with "large − small" read as the pairwise shift and "small" as the 300-section median.
    static func comparable(shift: CFTimeInterval, smallMedian: CFTimeInterval) -> Bool {
        comparable(smallMedian + shift, smallMedian)
    }

    /// Two-sample Hodges–Lehmann shift: median of every `large[i] − small[j]`.
    static func shift(_ large: [CFTimeInterval], _ small: [CFTimeInterval]) -> CFTimeInterval {
        let differences = large.flatMap { l in small.map { l - $0 } }.sorted()
        let middle = differences.count / 2
        return differences.count % 2 == 1 ? differences[middle] : (differences[middle - 1] + differences[middle]) / 2
    }

    private static func ms(_ seconds: CFTimeInterval) -> String {
        String(format: "%.0fms", seconds * 1000)
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
