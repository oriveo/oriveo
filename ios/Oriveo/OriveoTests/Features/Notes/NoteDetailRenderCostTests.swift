import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Yield the main thread for `seconds`: the test itself runs inside one block on the main queue, and a nested `RunLoop.run` does not drain the main queue again,
/// so the `Task { @MainActor }` in the detail page's `reload()` and CachedMarkdownView's main-thread backfill only run once this block yields.
@MainActor
func settle(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Attach to the test host's window scene: a UIWindow without a scene does not drive SwiftUI's onAppear / rendering,
/// leaving the detail page in its blank "note not loaded yet" state, so the measurement would be of an empty page (the first version of the probe hit this).
@MainActor
func makeSceneWindow(width: CGFloat, height: CGFloat) -> UIWindow {
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
        window = UIWindow(windowScene: scene)
    } else {
        Issue.record("The test host has no window scene")
        window = UIWindow(frame: .zero)
    }
    window.frame = CGRect(x: 0, y: 0, width: width, height: height)
    return window
}

/// Curve of the note detail first-frame cost against body length: mounts the real `NoteDetailView` in an iPhone 12-sized window,
/// with a body that is a sample AI answer mixing headings + paragraphs + lists + code blocks + tables.
@MainActor
@Suite("Note detail first-frame cost", .serialized, .sharedProcessState)
struct NoteDetailRenderCostTests {

    /// One section is about 330 characters and 11 lines; every 3rd section carries a table.
    static func mixedBody(sections: Int) -> String {
        var parts: [String] = []
        for index in 0..<sections {
            var section = """
            ## Section \(index)

            This paragraph explains **step \(index)** with `inline code` and a [link](https://example.com/\(index)).

            - First point for section \(index)
            - Second point with *emphasis*

            ```swift
            let value\(index) = compute(\(index))
            print(value\(index))
            ```
            """
            if index % 3 == 0 {
                section += "\n\n| Key | Value |\n| --- | --- |\n| a\(index) | \(index) |\n| b\(index) | \(index * 2) |"
            }
            parts.append(section)
        }
        return parts.joined(separator: "\n\n")
    }

    nonisolated enum Kind: String, CaseIterable, Sendable {
        case mixed = "code+table mix"
        case tableProse = "table+prose, no code"
        case prose = "prose"
        case plain = "plain text"
    }

    /// Same section structure minus code blocks / tables, hitting the renderer's three routes respectively (segmented code / MarkdownUI / CachedMarkdownView).
    static func body(_ kind: Kind, sections: Int) -> String {
        switch kind {
        case .mixed:
            return mixedBody(sections: sections)
        case .plain:
            return (0..<sections).map { index in
                "Plain paragraph number \(index) talks about rendering cost and layout time in simple words without any markup."
            }.joined(separator: "\n\n")
        case .tableProse, .prose:
            var parts: [String] = []
            for index in 0..<sections {
                var section = """
                ## Section \(index)

                This paragraph explains **step \(index)** with `inline code` and a [link](https://example.com/\(index)).

                - First point for section \(index)
                - Second point with *emphasis*
                """
                if kind == .tableProse, index % 3 == 0 {
                    section += "\n\n| Key | Value |\n| --- | --- |\n| a\(index) | \(index) |\n| b\(index) | \(index * 2) |"
                }
                parts.append(section)
            }
            return parts.joined(separator: "\n\n")
        }
    }

    struct Sample {
        let maxStall: CFTimeInterval
        let jank: CFTimeInterval
    }

    /// Create all notes inside one AppState: closing and recreating the database per measurement collides with the previous database's cleanup (measured: a steady ~10s block each time, unrelated to the body).
    private func measure(state: AppState, label: String, body: String) async -> Sample {
        guard let note = state.noteManager.createNote(from: NoteDraft(title: "Cost", body: body, captureKind: .blank)) else {
            Issue.record("createNote failed")
            return Sample(maxStall: 0, jank: 0)
        }
        // The persistence / mirror / notification aftermath of creating the note is not counted in the cost of opening the detail.
        await settle(1.0)

        let host = UIHostingController(rootView: NoteDetailView(noteID: note.id).environment(state))
        let window = makeSceneWindow(width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds

        let probe = MainThreadStallProbe()
        probe.start()
        host.view.layoutIfNeeded()
        await settle(1.5)
        probe.stop()
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
        func viewCount(_ view: UIView) -> Int { 1 + view.subviews.reduce(0) { $0 + viewCount($1) } }
        print("[NOTE-DETAIL-COST] \(label): \(viewCount(host.view)) UIViews, \(body.utf16.count) UTF-16 / \(lines) lines, longest stall on first appearance \(String(format: "%.0f", probe.maxStall * 1000))ms, cumulative >16ms \(String(format: "%.0f", probe.jankTotal * 1000))ms")
        window.isHidden = true
        window.rootViewController = nil
        await settle(0.2)
        return Sample(maxStall: probe.maxStall, jank: probe.jankTotal)
    }

    @Test("Detail first frame: three body kinds x length")
    func curve() async {
        let state = AppState(seedDemoData: false, sessionUID: "note-detail-cost-\(UUID().uuidString)")
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: state.sessionPartitionUID))
        }
        _ = await measure(state: state, label: "warm-up", body: Self.mixedBody(sections: 2))
        for kind in Kind.allCases {
            var stalls: [Int: CFTimeInterval] = [:]
            for sections in [2, 10, 20, 38, 300, 1500] {
                let body = Self.body(kind, sections: sections)
                stalls[sections] = await measure(state: state, label: "\(kind.rawValue) \(sections) sections", body: body).maxStall
            }
            // Independent of length: the longest tier within the bounded plain-text threshold (38 sections, ~6-9k UTF-16) is the same order as 2 sections.
            // Before the fix (simulator), 38 sections cost 78ms more than 2 (prose) / 85-200ms (table prose) / 340ms+ (code + table).
            #expect((stalls[38] ?? 1) < (stalls[2] ?? 0) + 0.06, "\(kind.rawValue): 38 sections \(stalls[38] ?? -1)s vs 2 sections \(stalls[2] ?? -1)s")
        }
    }
}

/// The detail first frame only builds lazy cells near the viewport (independent of length). Uses the main-thread stall probe, so it is a wall-clock test.
@MainActor
@Suite("Note detail long-body first-frame cell count", .serialized, .sharedProcessState)
struct NoteLazyMarkdownFirstFrameTests {
    private typealias Cost = NoteDetailRenderCostTests

    private func gate(_ body: String) -> [MarkdownLazyUnit]? {
        NoteLazyMarkdownBody.units(markdown: NoteText.readingMarkdown(body))
    }

    @Test("Detail first frame only builds cells near the viewport: doubling the total cell count does not raise the first-frame cell count", arguments: [NoteDetailRenderCostTests.Kind.mixed, .tableProse])
    func firstFrameBuildsOnlyVisibleUnits(kind: NoteDetailRenderCostTests.Kind) async throws {
        let state = AppState(seedDemoData: false, sessionUID: "note-lazy-\(UUID().uuidString)")
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: state.sessionPartitionUID))
        }
        var built: [Int: Int] = [:]
        for sections in [20, 38] {
            let body = Cost.body(kind, sections: sections)
            let total = try #require(gate(body)).count
            let note = try #require(state.noteManager.createNote(from: NoteDraft(title: "Lazy", body: body, captureKind: .blank)))
            let loaded = await state.noteManager.noteDetail(id: note.id)
            #expect(loaded?.body == body, "The detail read path must be able to read this note")
            await settle(1.0)
            NoteLazyMarkdownBody.debugRowBodyCount = 0
            let host = UIHostingController(rootView: NoteDetailView(noteID: note.id).environment(state))
            let window = makeSceneWindow(width: 390, height: 844)
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            let probe = MainThreadStallProbe()
            probe.start()
            host.view.layoutIfNeeded()
            await settle(1.5)
            probe.stop()
            built[sections] = NoteLazyMarkdownBody.debugRowBodyCount
            print("[NOTE-LAZY] \(kind.rawValue) \(sections) sections: \(total) cells in total, first frame built \(NoteLazyMarkdownBody.debugRowBodyCount) cell bodies, longest stall \(String(format: "%.0f", probe.maxStall * 1000))ms, cumulative >16ms \(String(format: "%.0f", probe.jankTotal * 1000))ms")
            #expect(NoteLazyMarkdownBody.debugRowBodyCount > 0, "Long bodies must go through lazy cells")
            #expect(NoteLazyMarkdownBody.debugRowBodyCount < total / 2)
            window.isHidden = true
            window.rootViewController = nil
            await settle(0.2)
        }
        #expect((built[38] ?? .max) <= (built[20] ?? 0) + 4)
    }
}

/// First-frame cost of the card look (same background view + same two shadow layers) does not grow with card height; content is replaced by fixed-height blank space so only the card itself is measured.
/// The old drawing (whole group clipped by the full-card corner radius) is printed for comparison: on the simulator card heights 2000 / 5000 / 10000 / 15000pt -> 24 / 53 / 97 / 130ms, layered drawing 1-2ms.
@MainActor
@Suite("Note card look cost", .serialized, .sharedProcessState)
struct NoteCardSurfaceCostTests {
    @Test("Card background / shadow first-frame cost against card height")
    func cardSurfaceCost() async {
        var current: [CGFloat: CFTimeInterval] = [:]
        for height in [3_500, 5_000, 10_000, 15_000] as [CGFloat] {
            var results: [String] = []
            for variant in ["none", "legacy", "background", "background+shadow"] {
                let card = VStack(spacing: 30) {
                    Color.clear.frame(height: height)
                    Text("end")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                let root: AnyView
                switch variant {
                case "none": root = AnyView(ScrollView { card.padding(20) })
                case "legacy": root = AnyView(ScrollView { card.background(NoteBrandCardBackground.legacy).padding(20) })
                case "background": root = AnyView(ScrollView { card.background(NoteBrandCardBackground()).padding(20) })
                default:
                    root = AnyView(ScrollView {
                        card.background(NoteBrandCardBackground())
                            .shadow(color: OriveoTheme.Palette.shadow.opacity(0.5), radius: 16, y: 8)
                            .shadow(color: OriveoTheme.Palette.primary.opacity(0.10), radius: 30, y: 14)
                            .padding(20)
                    })
                }
                let host = UIHostingController(rootView: root)
                let window = makeSceneWindow(width: 390, height: 844)
                window.rootViewController = host
                window.isHidden = false
                host.view.frame = window.bounds
                let probe = MainThreadStallProbe()
                probe.start()
                host.view.layoutIfNeeded()
                await settle(1.0)
                probe.stop()
                results.append("\(variant) longest stall \(String(format: "%.0f", probe.maxStall * 1000))ms")
                if variant == "background+shadow" { current[height] = probe.maxStall }
                window.isHidden = true
                window.rootViewController = nil
                await settle(0.2)
            }
            print("[NOTE-CARD-COST] card height \(Int(height))pt: \(results.joined(separator: "; "))")
        }
        // Independent of card height: a 15000pt card is the same order as a 3500pt card (the old drawing differs by 80ms+).
        #expect((current[15_000] ?? 1) < (current[3_500] ?? 0) + 0.025)
    }
}
