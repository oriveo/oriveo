import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// Settings > Memory grouped list and the item editor.
@Suite("MemoryItemListPresentation", .serialized)
@MainActor
struct MemoryItemListPresentationTests {

    private static let thisDevice = "device-this"
    private static let otherDevice = "device-other"

    private static func item(
        _ id: String,
        kind: MemoryKind,
        status: MemoryStatus = .active,
        layer: MemoryLayer = .semantic,
        content: String? = nil,
        pinned: Bool = false,
        deviceId: String = otherDevice,
        conflictGroupId: String? = nil,
        scope: MemoryScope = .global,
        occurredAt: String? = nil,
        createdAt: String
    ) -> MemoryItem {
        MemoryItem(
            id: id, layer: layer, kind: kind, status: status, content: content ?? "content \(id)",
            scope: scope, pinned: pinned, mutationId: "m-\(id)", deviceId: deviceId,
            conflictGroupId: conflictGroupId, occurredAt: occurredAt, createdAt: createdAt
        )
    }

    /// Production repository (temporary database); items are written through the repository and then handed to the presentation layer.
    private static func makeRepository() throws -> (MemoryItemRepository, McpTestDatabase) {
        let (repository, _, database) = try makeRepositoryWithStore()
        return (repository, database)
    }

    private static func makeRepositoryWithStore() throws -> (MemoryItemRepository, MemoryItemStore, McpTestDatabase) {
        let database = try McpTestDatabase.make()
        let store = MemoryItemStore(dbPool: database.pool)
        var preferences = AppPreference(theme: .dark, language: .system, memoryText: "")
        let repository = MemoryItemRepository(
            uid: "memory-list-test",
            store: store,
            bridge: MemoryLegacyPrefsBridge(
                read: { preferences.memoryLegacyPrefs },
                write: { compiled in preferences = preferences.applyingMemoryLegacy(compiled, now: Date()) }
            ),
            deviceId: thisDevice,
            migrationScope: "memory-list-test-\(UUID().uuidString)"
        )
        repository.onLocalChange = {}
        return (repository, store, database)
    }

    @Test("Four groups are ordered About me / Preferences / Standing instructions / Projects; within a group pinned first, then by creation time; empty groups are not shown")
    func groupsInListOrder() {
        let items = [
            Self.item("p1", kind: .project, createdAt: "2026-01-05T00:00:00.000Z"),
            Self.item("i1", kind: .constraint, createdAt: "2026-01-02T00:00:00.000Z"),
            Self.item("a2", kind: .fact, createdAt: "2026-01-01T00:00:00.000Z"),
            Self.item("a1", kind: .identity, pinned: true, createdAt: "2026-01-09T00:00:00.000Z"),
            Self.item("i2", kind: .instruction, createdAt: "2026-01-01T00:00:00.000Z"),
            Self.item("p2", kind: .goal, createdAt: "2026-01-01T00:00:00.000Z"),
            Self.item("p3", kind: .decision, pinned: true, createdAt: "2026-01-08T00:00:00.000Z"),
        ]

        let presentation = MemoryItemListPresentation.resolve(items: items, deviceId: Self.thisDevice)

        #expect(presentation.sections.map(\.group) == [.about, .instructions, .projects])
        #expect(presentation.sections.map { $0.rows.map(\.id) } == [["a1", "a2"], ["i2", "i1"], ["p3", "p2", "p1"]])
        #expect(presentation.conflicts.isEmpty)
        #expect(presentation.isEmpty == false)
        #expect(MemoryItemListPresentation.resolve(items: [], deviceId: Self.thisDevice).isEmpty)
    }

    @Test("Tombstoned, superseded, expired and episodic-layer (event) items are not shown")
    func hidesDeletedAndEpisodic() {
        let items = [
            Self.item("keep", kind: .preference, createdAt: "2026-01-01T00:00:00.000Z"),
            Self.item("gone", kind: .preference, status: .deleted, createdAt: "2026-01-02T00:00:00.000Z"),
            Self.item("evt", kind: .event, layer: .episodic, createdAt: "2026-01-03T00:00:00.000Z"),
            Self.item("old", kind: .preference, status: .superseded, createdAt: "2026-01-04T00:00:00.000Z"),
            Self.item("past", kind: .project, status: .expired, createdAt: "2026-01-05T00:00:00.000Z"),
        ]

        let presentation = MemoryItemListPresentation.resolve(items: items, deviceId: Self.thisDevice)

        #expect(presentation.sections.map(\.group) == [.preferences])
        #expect(presentation.sections.flatMap(\.rows).map(\.id) == ["keep"])
        // The episodic-layer item moves into the "Events and decisions" group; the L2 groups still do not contain it
        let rest = MemoryItemListPresentation.resolve(items: Array(items.dropFirst()), deviceId: Self.thisDevice)
        #expect(rest.sections.isEmpty)
        #expect(rest.episodic.rows.map(\.id) == ["evt"])
    }

    @Test("Disabled items stay in their group with a \"Disabled\" marker; pinned items carry a pin marker")
    func pausedBadge() async throws {
        let (repository, _) = try Self.makeRepository()
        let paused = try await repository.create(kind: .instruction, content: "Always answer in Arabic")
        try await repository.setStatus(id: paused.id, status: .paused)
        let pinned = try await repository.create(kind: .instruction, content: "Use SI units", pinned: true)

        let presentation = MemoryItemListPresentation.resolve(items: repository.list(), deviceId: Self.thisDevice)
        let rows = try #require(presentation.sections.first { $0.group == .instructions }).rows

        #expect(rows.map(\.id) == [pinned.id, paused.id])
        #expect(rows.map(\.showsPausedBadge) == [false, true])
        #expect(rows.map(\.isPinned) == [true, false])
        #expect(rows[1].item.content == "Always answer in Arabic")
    }

    @Test("Conflicting items are listed in pairs at the top by conflictGroupId, the local version first and marked, not in the normal groups; the label looks only at the copy's deviceId")
    func conflictPairsThisDeviceFirst() {
        let items = [
            Self.item("c1-remote", kind: .preference, status: .conflicted, content: "Short answers, code when needed",
                      deviceId: Self.otherDevice, conflictGroupId: "G1", createdAt: "2026-01-01T00:00:00.000Z"),
            Self.item("c1-local", kind: .preference, status: .conflicted, content: "Keep answers short",
                      deviceId: Self.thisDevice, conflictGroupId: "g1", createdAt: "2026-01-02T00:00:00.000Z"),
            Self.item("c2-a", kind: .project, status: .conflicted, deviceId: Self.otherDevice,
                      conflictGroupId: "g2", createdAt: "2026-01-03T00:00:00.000Z"),
            Self.item("c2-b", kind: .project, status: .conflicted, deviceId: "device-third",
                      conflictGroupId: "g2", createdAt: "2026-01-04T00:00:00.000Z"),
            Self.item("plain", kind: .preference, createdAt: "2026-01-05T00:00:00.000Z"),
            // The original item's (id = conflictGroupId) deviceId is the local device that pushed it, so it cannot be used to decide
            Self.item("g3", kind: .instruction, status: .conflicted, deviceId: Self.thisDevice,
                      conflictGroupId: "g3", createdAt: "2026-01-06T00:00:00.000Z"),
            Self.item("g3-copy", kind: .instruction, status: .conflicted, deviceId: Self.thisDevice,
                      conflictGroupId: "g3", createdAt: "2026-01-07T00:00:00.000Z"),
            Self.item("g4", kind: .identity, status: .conflicted, deviceId: Self.thisDevice,
                      conflictGroupId: "g4", createdAt: "2026-01-08T00:00:00.000Z"),
            Self.item("g4-copy", kind: .identity, status: .conflicted, deviceId: Self.otherDevice,
                      conflictGroupId: "g4", createdAt: "2026-01-09T00:00:00.000Z"),
        ]

        let presentation = MemoryItemListPresentation.resolve(items: items, deviceId: Self.thisDevice)

        #expect(presentation.conflicts.map(\.id) == ["g1", "g2", "g3", "g4"])
        #expect(presentation.conflicts[0].entries.map(\.id) == ["c1-local", "c1-remote"])
        #expect(presentation.conflicts[0].entries.map(\.isThisDevice) == [true, false])
        #expect(presentation.conflicts[1].entries.map(\.id) == ["c2-a", "c2-b"])
        #expect(presentation.conflicts[1].entries.map(\.isThisDevice) == [false, false])
        // The copy was written locally: copy = this device, original = another device
        #expect(presentation.conflicts[2].entries.map(\.id) == ["g3-copy", "g3"])
        #expect(presentation.conflicts[2].entries.map(\.isThisDevice) == [true, false])
        // The copy comes from another device: original = this device
        #expect(presentation.conflicts[3].entries.map(\.id) == ["g4", "g4-copy"])
        #expect(presentation.conflicts[3].entries.map(\.isThisDevice) == [true, false])
        #expect(presentation.sections.flatMap(\.rows).map(\.id) == ["plain"])
    }

    @Test("Editor category is a four-way choice: creating writes each group's representative kind; an unchanged category keeps the original kind; a changed category writes the new group's representative kind, and saving changes the kind through the repository")
    func editorCategoryMapping() async throws {
        #expect(MemoryItemGroup.about.kind(keeping: nil) == .identity)
        #expect(MemoryItemGroup.about.kind(keeping: .fact) == .fact)
        #expect(MemoryItemGroup.about.kind(keeping: .identity) == .identity)
        #expect(MemoryItemGroup.preferences.kind(keeping: .fact) == .preference)
        #expect(MemoryItemGroup.instructions.kind(keeping: .constraint) == .constraint)
        #expect(MemoryItemGroup.instructions.kind(keeping: .goal) == .instruction)
        #expect(MemoryItemGroup.projects.kind(keeping: .goal) == .goal)
        #expect(MemoryItemGroup.projects.kind(keeping: .decision) == .decision)
        #expect(MemoryItemGroup.projects.kind(keeping: .identity) == .project)

        let created = MemoryItemEditorState.create()
        #expect(created.mode == .create)
        #expect(created.category == .about)
        #expect(created.kind == .identity)
        #expect(MemoryItemEditorState.create(category: .projects).kind == .project)

        let (repository, _) = try Self.makeRepository()
        let fact = try await repository.create(kind: .fact, content: "I live in Berlin")
        var editor = try #require(MemoryItemEditorState.edit(itemId: fact.id, in: repository.list()))
        #expect(editor.category == .about)
        #expect(editor.kind == .fact)

        editor.category = .preferences
        editor.text = "Prefer metric units"
        try await repository.update(id: fact.id, content: editor.trimmedText, kind: editor.kind)
        let stored = try #require(repository.list().first { $0.id == fact.id })
        #expect(stored.kind == .preference)
        #expect(stored.content == "Prefer metric units")
        #expect(MemoryItemListPresentation.resolve(items: repository.list(), deviceId: Self.thisDevice)
            .sections.map(\.group) == [.preferences])
    }

    @Test("The editor counts by code point; over 2000 turns red and cannot be saved; whitespace cannot be saved")
    func editorLimit2000() {
        var editor = MemoryItemEditorState.create()
        #expect(editor.canSave == false)

        editor.text = String(repeating: "a", count: 2000)
        #expect(editor.characterCount == 2000)
        #expect(editor.isTooLong == false)
        #expect(editor.canSave)

        editor.text += "b"
        #expect(editor.characterCount == 2001)
        #expect(editor.isTooLong)
        #expect(editor.canSave == false)

        // "👨‍👩‍👧" is 1 grapheme and 5 code points
        editor.text = String(repeating: "👨‍👩‍👧", count: 400)
        #expect(editor.characterCount == 2000)
        #expect(editor.canSave)
        editor.text += "👍"
        #expect(editor.isTooLong)

        editor.text = "   \n  "
        #expect(editor.canSave == false)
        #expect(MemoryItemEditorState.maxLength == 2000)
    }

    @Test("Opening with editItemId edits that item directly: case-insensitive, brings out the original text and category; does not open when not found or already deleted")
    func editItemIdOpensEditor() async throws {
        let (repository, _) = try Self.makeRepository()
        let target = try await repository.create(kind: .constraint, content: "Never use emojis")
        let removed = try await repository.create(kind: .preference, content: "Dark mode")
        try await repository.remove(id: removed.id)

        let editor = try #require(MemoryItemEditorState.edit(itemId: target.id.uppercased(), in: repository.list()))
        #expect(editor.mode == .edit(id: target.id))
        #expect(editor.text == "Never use emojis")
        #expect(editor.category == .instructions)
        #expect(editor.kind == .constraint)
        #expect(editor.canSave)

        #expect(MemoryItemEditorState.edit(itemId: removed.id, in: repository.allItems()) == nil)
        #expect(MemoryItemEditorState.edit(itemId: "missing", in: repository.list()) == nil)
    }
    // MARK: Events and decisions (L3)

    private static func episodic(
        _ id: String, kind: MemoryKind = .decision, status: MemoryStatus = .active,
        scope: MemoryScope = .global, conflictGroupId: String? = nil,
        occurredAt: String?, createdAt: String = "2026-01-01T00:00:00.000Z"
    ) -> MemoryItem {
        item(id, kind: kind, status: status, layer: .episodic, conflictGroupId: conflictGroupId,
             scope: scope, occurredAt: occurredAt, createdAt: createdAt)
    }

    @Test("Events and decisions: only active / paused episodic items, ordered new -> old by occurredAt (createdAt if missing), the L2 groups do not contain them; the gray text is date · scope")
    func episodicGroupFilterAndOrder() throws {
        let folderId = "F0LDER-1"
        let items = [
            Self.item("pref", kind: .preference, createdAt: "2026-01-01T00:00:00.000Z"),
            Self.episodic("e-mar", scope: MemoryScope(type: .folder, id: folderId), occurredAt: "2026-03-01T00:00:00.000Z"),
            Self.episodic("e-apr", kind: .event, status: .paused, occurredAt: nil, createdAt: "2026-04-02T08:00:00Z"),
            Self.episodic("e-feb", scope: MemoryScope(type: .conversation, id: "c1"), occurredAt: "2026-02-01T00:00:00Z"),
            Self.episodic("e-unknown", scope: MemoryScope(type: .folder, id: "missing"), occurredAt: "2026-01-15T00:00:00.000Z"),
            Self.episodic("e-gone", status: .deleted, occurredAt: "2026-05-01T00:00:00.000Z"),
            Self.episodic("e-old", status: .superseded, occurredAt: "2026-05-01T00:00:00.000Z"),
            Self.episodic("e-exp", status: .expired, occurredAt: "2026-05-01T00:00:00.000Z"),
        ]

        let presentation = MemoryItemListPresentation.resolve(
            items: items, deviceId: Self.thisDevice, folderNames: [folderId.lowercased(): "Trips"]
        )

        #expect(presentation.sections.flatMap(\.rows).map(\.id) == ["pref"])
        let rows = presentation.episodic.rows
        #expect(rows.map(\.id) == ["e-apr", "e-mar", "e-feb", "e-unknown"])
        #expect(rows.map(\.dateLabel) == ["2026-04-02", "2026-03-01", "2026-02-01", "2026-01-15"])
        #expect(rows.map(\.showsPausedBadge) == [true, false, false, false])
        #expect(rows[0].scopeLabel == L10n.tr("memory_scope_all", table: .chat))
        #expect(rows[1].scopeLabel == String(format: L10n.tr("memory_scope_folder_named", table: .chat), "Trips"))
        #expect(rows[1].scopeLabel.contains("Trips"))
        #expect(rows[2].scopeLabel == L10n.tr("memory_scope_conversation", table: .chat))
        #expect(rows[3].scopeLabel == L10n.tr("memory_scope_folder", table: .chat))
        #expect(rows[0].detailLabel == "2026-04-02 · \(L10n.tr("memory_scope_all", table: .chat))")
        #expect(presentation.l3Conflicts.isEmpty)
        // With only L3 items the page is also not empty (this group exists only in the editing state)
        #expect(MemoryItemListPresentation.resolve(items: [items[1]], deviceId: Self.thisDevice).isEmpty == false)
    }

    @Test("More than 20 events and decisions show only the first 20 plus \"Show all (N)\"; expanding shows all; exactly 20 are not collapsed")
    func episodicCollapseThreshold() {
        let many = (0..<21).map { index in
            Self.episodic(String(format: "e%02d", index), occurredAt: String(format: "2026-01-%02dT00:00:00.000Z", index + 1))
        }
        let section = MemoryItemListPresentation.resolve(items: many, deviceId: Self.thisDevice).episodic

        #expect(section.isCollapsible)
        #expect(section.visibleRows(expanded: false).map(\.id) == (1..<21).reversed().map { String(format: "e%02d", $0) })
        #expect(section.visibleRows(expanded: true).count == 21)
        #expect(section.showAllTitle == String(format: L10n.tr("memory_show_all", table: .chat), 21))
        #expect(section.showAllTitle.contains("21"))

        let twenty = MemoryItemListPresentation.resolve(items: Array(many.prefix(20)), deviceId: Self.thisDevice).episodic
        #expect(twenty.isCollapsible == false)
        #expect(twenty.visibleRows(expanded: false).count == 20)
    }

    @Test("Events and decisions sort: each time is parsed once (not repeatedly inside the comparator), and the date column reuses the parse from the sort")
    func episodic_sort_parses_each_date_once() {
        let many = (0..<40).map { index in
            Self.episodic(String(format: "e%02d", index),
                          occurredAt: index.isMultiple(of: 4) ? nil : String(format: "2026-02-%02dT00:00:00.000Z", index % 28 + 1),
                          createdAt: String(format: "2026-01-%02dT00:00:00Z", index % 28 + 1))
        }
        var calls: [String] = []
        let section = MemoryItemListPresentation.episodicSection(many, folderNames: [:]) { raw in
            if let raw { calls.append(raw) }
            return MemoryEpisodicTime.parse(raw)
        }

        // Items with occurredAt are parsed once; items without it parse createdAt once instead
        #expect(calls.count == many.count)
        #expect(section.rows.count == many.count)
        // The result matches the ordering and date column of the production resolve
        let production = MemoryItemListPresentation.resolve(items: many, deviceId: Self.thisDevice).episodic
        #expect(section == production)
        #expect(production.rows.first?.dateLabel == "2026-02-28")
        #expect(production.rows.map(\.id) == many.sorted { MemoryEpisodicTime.isNewer($0, than: $1) }.map(\.id))
    }

    @Test("L3 conflict pair: newer = later occurredAt (the larger id on a tie); keep newer / keep older / keep both are persisted through the repository as useNew / useOld / keepBoth")
    func l3ConflictPairActions() async throws {
        #expect(MemoryL3ConflictChoice.keepNewer.resolution == .useNew)
        #expect(MemoryL3ConflictChoice.keepOlder.resolution == .useOld)
        #expect(MemoryL3ConflictChoice.keepBoth.resolution == .keepBoth)

        let tie = MemoryItemListPresentation.resolve(items: [
            Self.episodic("aaa", status: .conflicted, conflictGroupId: "aaa", occurredAt: "2026-02-01T00:00:00.000Z"),
            Self.episodic("bbb", status: .conflicted, conflictGroupId: "AAA", occurredAt: "2026-02-01T00:00:00Z"),
        ], deviceId: Self.thisDevice)
        #expect(tie.l3Conflicts.map(\.newer.id) == ["bbb"])
        #expect(tie.l3Conflicts.map(\.older.id) == ["aaa"])
        #expect(tie.conflicts.isEmpty)
        #expect(tie.episodic.rows.isEmpty)

        let expected: [(MemoryL3ConflictChoice, MemoryStatus, MemoryStatus)] = [
            (.keepNewer, .active, .superseded),
            (.keepOlder, .superseded, .active),
            (.keepBoth, .active, .active),
        ]
        for (choice, newerStatus, olderStatus) in expected {
            let (repository, store, _) = try Self.makeRepositoryWithStore()
            let older = Self.episodic("11111111-0000-0000-0000-000000000001", status: .conflicted,
                                      conflictGroupId: "11111111-0000-0000-0000-000000000001",
                                      occurredAt: "2026-03-01T00:00:00.000Z")
            let newer = Self.episodic("00000000-0000-0000-0000-000000000002", status: .conflicted,
                                      conflictGroupId: "11111111-0000-0000-0000-000000000001",
                                      occurredAt: "2026-03-05T00:00:00.000Z")
            try store.upsert([older, newer], syncState: .synced)

            let presentation = MemoryItemListPresentation.resolve(items: repository.allItems(), deviceId: Self.thisDevice)
            let pair = try #require(presentation.l3Conflicts.first)
            #expect(presentation.l3Conflicts.count == 1)
            #expect(pair.newer.id == newer.id)
            #expect(pair.older.id == older.id)
            #expect(MemoryEpisodicTime.dayLabel(of: pair.newer) == "2026-03-05")

            _ = try await repository.perform { try pair.apply(choice, writer: $0) }

            let stored = repository.allItems()
            #expect(stored.first { $0.id == newer.id }?.status == newerStatus)
            #expect(stored.first { $0.id == older.id }?.status == olderStatus)
            #expect(stored.allSatisfy { $0.conflictGroupId == nil })
            #expect(MemoryItemListPresentation.resolve(items: stored, deviceId: Self.thisDevice).l3Conflicts.isEmpty)
        }
    }

    @Test("Editor: L3 kind has only Decision / Event, default Decision, the date is stored as 00:00:00Z of that day; the L2 kind options do not contain decision / event")
    func editorEpisodicKindsAndDate() async throws {
        let l2 = MemoryItemEditorState.create()
        #expect(l2.isEpisodic == false)
        #expect(l2.occurredAt == nil)
        #expect(!l2.kindOptions.contains(.decision) && !l2.kindOptions.contains(.event))
        #expect(l2.kindOptions.count == MemoryItemGroup.allCases.count)

        var calendar = Calendar.current
        calendar.timeZone = .current
        let picked = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 3, hour: 23, minute: 30)))
        var l3 = MemoryItemEditorState.createEpisodic(now: picked)
        #expect(l3.isEpisodic)
        #expect(l3.kindOptions == [.decision, .event])
        #expect(l3.kind == .decision)
        #expect(l3.occurredAt == "2026-05-03T00:00:00.000Z")
        l3.episodicKind = .event
        #expect(l3.kind == .event)

        let (repository, _) = try Self.makeRepository()
        let created = try await repository.create(
            kind: l3.kind, content: "Flew to Lisbon", layer: l3.layer, occurredAt: l3.occurredAt
        )
        #expect(created.layer == .episodic)
        #expect(created.occurredAt == "2026-05-03T00:00:00.000Z")

        var editor = try #require(MemoryItemEditorState.edit(itemId: created.id, in: repository.list()))
        #expect(editor.isEpisodic)
        #expect(editor.episodicKind == .event)
        #expect(editor.occurredAt == "2026-05-03T00:00:00.000Z")
        editor.occurredDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 9)))
        editor.episodicKind = .decision
        try await repository.update(id: created.id, content: editor.trimmedText, kind: editor.kind, occurredAt: editor.occurredAt)
        let stored = try #require(repository.list().first { $0.id == created.id })
        #expect(stored.kind == .decision)
        #expect(stored.occurredAt == "2026-06-09T00:00:00.000Z")
        #expect(MemoryItemListPresentation.resolve(items: repository.list(), deviceId: Self.thisDevice)
            .episodic.rows.map(\.dateLabel) == ["2026-06-09"])
    }

    @Test("The raw text view does not contain episodic items")
    func rawViewExcludesEpisodic() async throws {
        let (repository, _) = try Self.makeRepository()
        try await repository.create(kind: .preference, content: "Prefer metric units")
        try await repository.create(kind: .decision, content: "Chose Lisbon for the offsite", layer: .episodic)

        let raw = MemoryRawEditorState(items: repository.list())
        #expect(raw.text.contains("Prefer metric units"))
        #expect(!raw.text.contains("Lisbon"))
    }
}
