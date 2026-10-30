import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Long-note performance gate. Fixtures:
/// - `seedMarkdown(lines:)` builds sections of heading / paragraph / bullets / ordered list / table / code block / inline and block math / quote
///   (33 lines per section) up to 3200 lines;
/// - `virtualizationBody(sections:)` builds bodies of 300 / 1500 sections.
/// Locks the longest main-thread stall in three scenarios: opening the detail first frame (always lazy rich text at any length), Select text, and entering edit (bodies of 10k+ UTF-16
/// use the bounded plain-text viewport); also asserts 1500 sections cost about the same as 300.
/// Ratio rule: 1500 sections <= 300 sections x 1.3 (when both are single-digit ms, a difference within half a frame, 8ms, also counts as comparable, so jitter does not inflate small numbers into ratios).
@MainActor
@Suite("Long note performance gate", .serialized, .sharedProcessState)
struct NoteLongBodyPerformanceGateTests {
    static let productionSeedLines = 3_200

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
            "This section discusses metric group \(index), focusing on the relation between recomposition count and measure time.",
            "",
            "- Point A: block-level commits split long text into syntactically complete blocks",
            "- Point B: the pacer can only advance within the prefix already received",
            "- Point C: when the backlog exceeds the threshold, enter catchup",
            "",
            "1. First measure `Recomposer:recompose`",
            "2. Then measure `Compose:measure`",
            "3. Only last look at `AndroidOwner:draw`",
            "",
            "| Stage | Time | Share |",
            "| --- | --- | --- |",
            "| Recompose | \(index * 3) ms | 42% |",
            "| Layout | \(index * 2) ms | 31% |",
            "| Draw | \(index) ms | 27% |",
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

    // MARK: - Detail page scenario

    struct DetailSample {
        let openStall: CFTimeInterval
        let selectStall: CFTimeInterval?
        let editStall: CFTimeInterval
    }

    /// Open the detail (first frame) -> tap "Edit" through the accessibility tree (same action path as a VoiceOver double tap) to enter edit mode.
    private func openAndEdit(state: AppState, label: String, body: String) async throws -> DetailSample {
        let note = try #require(state.noteManager.createNote(from: NoteDraft(title: "Gate", body: body, captureKind: .blank)))
        // The persistence / mirror aftermath of creating the note is not counted in the cost of opening the detail.
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

        // "Select text" exists only for long bodies (the whole text goes into one selectable bounded view); measure the main-thread cost of opening the panel, then close it.
        var selectStall: CFTimeInterval?
        if let select = Self.accessibilityElement(labeled: L10n.tr("Select text", table: .notes), in: host.view) {
            probe.start()
            #expect(select.accessibilityActivate())
            await settle(1.5)
            probe.stop()
            selectStall = probe.maxStall
            #expect(host.presentedViewController != nil, "\(label): the select-text panel was not presented")
            host.presentedViewController?.dismiss(animated: false)
            await settle(0.5)
        }

        let edit = try #require(Self.accessibilityElement(labeled: L10n.tr("Edit", table: .notes), in: host.view), "Cannot find \"Edit\"")
        probe.start()
        #expect(edit.accessibilityActivate(), "\"Edit\" did not respond to accessibility activation")
        await settle(1.5)
        probe.stop()
        let editStall = probe.maxStall
        #expect(Self.accessibilityElement(labeled: L10n.tr("Save", table: .notes), in: host.view) != nil, "\(label): did not enter edit mode")

        print("[NOTE-GATE] \(label): \(body.utf16.count) UTF-16 / \(body.split(separator: "\n", omittingEmptySubsequences: false).count) lines; open first-frame longest stall \(Self.ms(openStall)), select text \(selectStall.map(Self.ms) ?? "-"), enter-edit longest stall \(Self.ms(editStall))")
        return DetailSample(openStall: openStall, selectStall: selectStall, editStall: editStall)
    }

    @Test("Open detail / enter edit: the 3200-line production-scale fixture has an upper bound, 1500 sections cost about the same as 300")
    func detailOpenAndEdit() async throws {
        let state = AppState(seedDemoData: false, sessionUID: "note-gate-\(UUID().uuidString)")
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: state.sessionPartitionUID))
        }
        _ = try await openAndEdit(state: state, label: "warm-up", body: Self.virtualizationBody(sections: 2))
        // The first bounded viewport pays a one-time TextKit 1 initialization; do not count it in any tier.
        _ = try await openAndEdit(state: state, label: "warm-up (bounded viewport)", body: Self.virtualizationBody(sections: 120))
        let seed = try await openAndEdit(state: state, label: "production scale \(Self.productionSeedLines) lines", body: Self.seedMarkdown(lines: Self.productionSeedLines))
        let small = try await openAndEdit(state: state, label: "300 sections", body: Self.virtualizationBody(sections: 300))
        let large = try await openAndEdit(state: state, label: "1500 sections", body: Self.virtualizationBody(sections: 1_500))

        // Absolute bound: under four frames on the simulator (see the commit message for measurements); before the fix, whole rich-text rendering of the same fixture took hundreds of ms.
        for (label, sample) in [("3200 lines", seed), ("300 sections", small), ("1500 sections", large)] {
            #expect(sample.openStall < 0.06, "\(label) open first frame \(Self.ms(sample.openStall))")
            #expect(sample.editStall < 0.06, "\(label) enter edit \(Self.ms(sample.editStall))")
            let selectStall = try #require(sample.selectStall, "\(label) should have \"Select text\"")
            // Select text is a panel transition the user triggers once (including the sheet presentation), so it gets a looser bound.
            #expect(selectStall < 0.1, "\(label) select text \(Self.ms(selectStall))")
        }
        // Independent of length: a body 5x longer does not cost more.
        #expect(Self.comparable(large.selectStall ?? 1, small.selectStall ?? 0), "select text 1500 sections vs 300 sections")
        #expect(Self.comparable(large.openStall, small.openStall), "open first frame 1500 sections \(Self.ms(large.openStall)) vs 300 sections \(Self.ms(small.openStall))")
        #expect(Self.comparable(large.editStall, small.editStall), "enter edit 1500 sections \(Self.ms(large.editStall)) vs 300 sections \(Self.ms(small.editStall))")
    }

    // MARK: - Helpers

    /// 1500 sections <= 300 sections x 1.3, or the two differ by less than half a frame (8ms).
    static func comparable(_ large: CFTimeInterval, _ small: CFTimeInterval) -> Bool {
        large <= small * 1.3 || large - small <= 0.008
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
