import Foundation
import UIKit
import OriveoProviderKit
import Testing
@testable import Oriveo

/// The memory page-family screenshots read the shared manifest `shared/test-fixtures/shots/memory.v1.json`: the page-name set matches this platform's page-name table,
/// and every page can be built through the production decoder / presentation model.
@Suite("Screenshot manifest - memory page family")
@MainActor
struct MemoryShotsManifestTests {
    typealias Shots = MemoryShots

    private static func stage(_ shot: Shots.Shot) throws -> Shots.Staged {
        try Shots.stage(shot, manifestData: Shots.manifestData())
    }

    @Test("shotsManifestPagesMatchImplemented: manifest page-name set == this platform's page-name table")
    func shotsManifestPagesMatchImplemented() throws {
        let manifest = try Shots.Manifest.load(from: Shots.manifestData())
        #expect(Set(manifest.pages.map(\.name)) == Set(Shots.Shot.allCases.map(\.rawValue)))
        #expect(manifest.pages.count == Shots.Shot.allCases.count)
    }

    @Test("Launch argument -SHOTS_SCROLL_BOTTOM: naming a memory page sets scrollToBottom = true, and no argument gives false")
    func scrollToBottomLaunchArgument() {
        let base = ["Oriveo", "-AUTO_OPEN_PAGE", "memoryList"]
        #expect(Shots.scrollToBottom(in: base + ["-SHOTS_SCROLL_BOTTOM"]) == true)
        #expect(Shots.scrollToBottom(in: base) == false)
        #expect(Shots.scrollToBottom(in: ["Oriveo", "-SHOTS_SCROLL_BOTTOM"]) == false)
        #expect(Shots.requestedShot(in: base) == .memoryList)
    }

    @Test("hasRecentConversations = false: no page shows the draft row / button")
    func noRecentConversationsHidesDraft() throws {
        for shot in Shots.Shot.allCases {
            let staged = try Self.stage(shot)
            #expect(staged.hasRecentConversations == false, "\(shot.rawValue)")
            let list = MemoryItemListPresentation.resolve(items: staged.items, deviceId: staged.deviceId)
            let page = MemoryViewPresentation.resolve(
                hasItems: !list.isEmpty, hasRecentConversations: staged.hasRecentConversations
            )
            #expect(page.primaryAction != .generateDraft && page.secondaryAction != .generateDraft, "\(shot.rawValue)")
        }
    }

    @Test("Initial state: no items and no candidates, and the memory page shows starter")
    func starterIsEmpty() throws {
        let staged = try Self.stage(.memoryStarter)
        #expect(staged.items.isEmpty && staged.candidates.isEmpty)
        let list = MemoryItemListPresentation.resolve(items: staged.items, deviceId: staged.deviceId)
        #expect(MemoryViewPresentation.resolve(hasItems: !list.isEmpty, hasRecentConversations: false).mode == .starter)
    }

    @Test("List page: 17 items decoded through production, four groups + L2 / L3 conflict pairs + L3 timeline laid out per the manifest")
    func listBuildsEveryGroup() throws {
        let staged = try Self.stage(.memoryList)
        #expect(staged.items.count == 17)
        // Candidate repository order: createdAt new -> old
        #expect(staged.candidates.map(\.id) == ["c-1", "c-3", "c-2"])
        let list = MemoryItemListPresentation.resolve(
            items: staged.items, deviceId: staged.deviceId, folderNames: staged.folderNames
        )
        #expect(list.sections.map(\.group) == [.about, .preferences, .instructions, .projects])
        #expect(list.sections.map(\.rows.count) == [2, 3, 2, 3])
        let pair = try #require(list.conflicts.first)
        #expect(list.conflicts.count == 1)
        #expect(pair.entries.map(\.item.id) == ["m-pref-c2", "m-pref-c1"])
        #expect(pair.entries.map(\.isThisDevice) == [true, false])
        let l3 = try #require(list.l3Conflicts.first)
        #expect([l3.newer.id, l3.older.id] == ["m-ep-c2", "m-ep-c1"])
        #expect(list.episodic.rows.map(\.item.id) == ["m-ep-1", "m-ep-2", "m-ep-3"])
        #expect(list.episodic.rows.map(\.dateLabel) == ["2026-10-11", "2026-10-07", "2026-09-28"])
        #expect(list.episodic.rows[1].scopeLabel.contains("Lisbon trip"))
        #expect(list.sections[1].rows.filter(\.showsPausedBadge).map(\.item.id) == ["m-pref-3"])
    }

    @Test("Two editor pages: preset.editItem lands in the L2 / L3 editing state")
    func editorPresets() throws {
        let l2 = try Self.stage(.memoryEditorL2)
        let l2Item = try #require(l2.editItem)
        let l2State = try #require(MemoryItemEditorState.edit(itemId: l2Item, in: l2.items))
        #expect(!l2State.isEpisodic && l2State.category == .preferences)
        let l3 = try Self.stage(.memoryEditorL3)
        let l3Item = try #require(l3.editItem)
        let l3State = try #require(MemoryItemEditorState.edit(itemId: l3Item, in: l3.items))
        #expect(l3State.isEpisodic && l3State.episodicKind == .decision)
    }

    @Test("Raw-text page: after the 3rd segment is replaced with 2080 characters, production prepareSave judges it too long")
    func rawTooLong() throws {
        let staged = try Self.stage(.memoryRaw)
        let raw = try #require(staged.rawEditor)
        #expect(raw.tooLongIndex == 2)
        // The createdAt omitted by the manifest is left empty per the contract: under production ordering (pinned first, then by id) the first two segments are Berlin and Miso
        let segments = raw.text.components(separatedBy: "\n\(MemoryItems.rawViewSeparator)\n")
        #expect(Array(segments.prefix(2)) == ["I'm a product designer based in Berlin.", "I have a dog named Miso."])
        #expect(staged.items.allSatisfy { $0.createdAt == nil })
        #expect(raw.tooLongMessage != nil)
    }

    @Test("Raw-text page: a text box with a line-number gutter can fit the screenshot text and lay it out (including the --- line style and the over-long segment)")
    func rawTextViewStylesFixture() throws {
        let raw = try #require(try Self.stage(.memoryRaw).rawEditor)
        let view = MemoryRawGutterTextView.make()
        view.frame = CGRect(x: 0, y: 0, width: 370, height: 600)
        view.text = raw.text
        view.errorSegment = raw.tooLongIndex
        view.restyle()
        view.layoutIfNeeded()
        #expect(view.text == raw.text)
    }
}
