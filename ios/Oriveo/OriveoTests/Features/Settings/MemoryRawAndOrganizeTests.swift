import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

/// The Settings > Memory raw-text view and "organize into items". Model requests use a stand-in; no real provider is called.
@Suite("MemoryRawAndOrganize", .serialized)
@MainActor
struct MemoryRawAndOrganizeTests {

    private static let thisDevice = "device-this"

    /// Records the requests the stand-in received.
    @MainActor
    private final class SendRecorder {
        var calls: [(modelId: String, request: MemoryOrganizeRequest)] = []
    }

    /// Production repository (temporary database); the clock advances 1 second each call, so the list order is the creation order.
    private static func makeRepository() throws -> (MemoryItemRepository, McpTestDatabase) {
        let database = try McpTestDatabase.make()
        var preferences = AppPreference(theme: .dark, language: .system, memoryText: "")
        var tick = 0.0
        let repository = MemoryItemRepository(
            uid: "memory-raw-test",
            store: MemoryItemStore(dbPool: database.pool),
            bridge: MemoryLegacyPrefsBridge(
                read: { preferences.memoryLegacyPrefs },
                write: { compiled in preferences = preferences.applyingMemoryLegacy(compiled, now: Date()) }
            ),
            deviceId: thisDevice,
            migrationScope: "memory-raw-test-\(UUID().uuidString)",
            now: {
                tick += 1
                return Date(timeIntervalSince1970: 1_800_000_000 + tick)
            }
        )
        repository.onLocalChange = {}
        return (repository, database)
    }

    private static func candidate(_ id: String) -> MemoryOrganizer.Candidate {
        let model = TestFactories.makeModel(id: id, name: id, isDefault: true)
        return (TestFactories.makeProvider(kind: .openAI, models: [model]), model)
    }

    /// Multi-line items migrated from the old large text (source migration).
    private static func migrationItem(in repository: MemoryItemRepository, content: String) throws -> MemoryItem {
        let item = MemoryItem(
            id: "legacy-0001", kind: .fact, content: content, source: MemorySource(type: .migration),
            mutationId: "m-legacy", deviceId: "device-other", createdAt: "2026-01-01T00:00:00.000Z"
        )
        try repository.store.upsert([item], syncState: .synced)
        return item
    }

    private static func isLowercasedUUID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil && id == id.lowercased()
    }

    // MARK: Raw-text view

    @Test("The raw-text view contains only active items, in list order, each separated by a standalone --- line")
    func rawRendersActiveOnly() throws {
        let (repository, _) = try Self.makeRepository()
        try repository.create(kind: .identity, content: "I write historical novels")
        let paused = try repository.create(kind: .instruction, content: "Always answer in Arabic")
        try repository.setStatus(id: paused.id, status: .paused)
        try repository.create(kind: .preference, content: "Prefer metric units")
        let removed = try repository.create(kind: .fact, content: "Old fact")
        try repository.remove(id: removed.id)

        let state = MemoryRawEditorState(items: repository.allItems())

        #expect(state.text == "I write historical novels\n---\nPrefer metric units")
        #expect(state.tooLongMessage == nil)
        #expect(L10n.tr("memory_raw_view_hint", table: .chat) != "memory_raw_view_hint")
    }

    @Test("Saving an unchanged raw text: nothing changed, no item is written")
    func rawUnchangedSavesNothing() async throws {
        let (repository, _) = try Self.makeRepository()
        try repository.create(kind: .identity, content: "I write historical novels")
        try repository.create(kind: .preference, content: "Prefer metric units")
        let before = repository.allItems()

        var state = MemoryRawEditorState(items: repository.list())
        let opsResult = state.prepareSave()
        let ops = try #require(opsResult)
        #expect(ops.isEmpty)
        try await repository.perform { try MemoryRawEditorState.apply(ops, writer: $0) }

        #expect(repository.allItems() == before)
    }

    @Test("Saving after editing the raw text: edited segments update the original item (kind unchanged), extra segments create new facts, missing segments write tombstones; all through the repository")
    func rawEditAppliesOps() async throws {
        let (repository, _) = try Self.makeRepository()
        let about = try repository.create(kind: .identity, content: "I write historical novels")
        let units = try repository.create(kind: .preference, content: "Prefer metric units")
        let si = try repository.create(kind: .constraint, content: "Use SI units")

        var state = MemoryRawEditorState(items: repository.list())
        state.text = "I write historical novels\n---\nPrefer imperial units\n---\nUse SI units\n---\nLive in Lisbon\n"
        let opsResult = state.prepareSave()
        let ops = try #require(opsResult)
        #expect(ops.count == 2)
        #expect(ops.first == .update(id: units.id, content: "Prefer imperial units"))
        try await repository.perform { try MemoryRawEditorState.apply(ops, writer: $0) }

        let afterEdit = repository.list().filter { $0.status != .deleted }
        #expect(afterEdit.count == 4)
        let updated = try #require(afterEdit.first { $0.id == units.id })
        #expect(updated.content == "Prefer imperial units")
        #expect(updated.kind == .preference)
        let created = try #require(afterEdit.first { $0.content == "Live in Lisbon" })
        #expect(created.kind == .fact)
        #expect(created.source.type == .manual)
        #expect(Self.isLowercasedUUID(created.id))
        #expect(repository.syncState(id: created.id) == .pending)

        var second = MemoryRawEditorState(items: repository.list())
        #expect(second.text == "I write historical novels\n---\nPrefer imperial units\n---\nUse SI units\n---\nLive in Lisbon")
        second.text = "I write historical novels\n---\nPrefer imperial units\n---\nLive in Lisbon"
        let deleteOpsResult = second.prepareSave()
        let deleteOps = try #require(deleteOpsResult)
        #expect(deleteOps == [.delete(id: si.id)])
        try await repository.perform { try MemoryRawEditorState.apply(deleteOps, writer: $0) }

        #expect(repository.allItems().first { $0.id == si.id }?.status == .deleted)
        #expect(repository.allItems().first { $0.id == about.id }?.content == "I write historical novels")
        #expect(MemoryItemListPresentation.resolve(items: repository.list(), deviceId: Self.thisDevice)
            .sections.flatMap(\.rows).map(\.item.content) == ["I write historical novels", "Live in Lisbon", "Prefer imperial units"])
    }

    @Test("A segment over 2000 characters: the hint says \"item n\" (n starts at 1), and no item is written")
    func rawTooLongShowsIndex() throws {
        let (repository, _) = try Self.makeRepository()
        try repository.create(kind: .identity, content: "I write historical novels")
        let before = repository.allItems()

        var state = MemoryRawEditorState(items: repository.list())
        state.text = "I write historical novels\n---\n" + String(repeating: "x", count: 2001)

        let rejected = state.prepareSave()
        #expect(rejected == nil)
        #expect(state.tooLongIndex == 1)
        let template = L10n.tr("memory_raw_view_too_long", table: .chat)
        #expect(template.contains("{index}"))
        #expect(state.tooLongMessage == template.replacingOccurrences(of: "{index}", with: "2"))
        #expect(repository.allItems() == before)

        state.text = "I write historical novels"
        let accepted = state.prepareSave()
        #expect(accepted == [])
        #expect(state.tooLongMessage == nil)
    }

    // MARK: Organize into items

    @Test("Organize: only the first candidate sends organizeRequest (system + user); all selected by default, saving the checked ones creates manual new items and writes tombstones for the originals")
    func organizeProposesAndSavesSelected() async throws {
        let (repository, _) = try Self.makeRepository()
        let source = try Self.migrationItem(
            in: repository,
            content: "I write historical novels.\nPrefer Arabic replies.\nWorking on a novel about Andalusia."
        )
        let row = MemoryItemListPresentation.resolve(items: repository.list(), deviceId: Self.thisDevice)
            .sections.flatMap(\.rows).first { $0.id == source.id }
        #expect(row?.showsOrganizeInline == true)

        let recorder = SendRecorder()
        let organizer = MemoryOrganizer(candidates: [Self.candidate("first"), Self.candidate("second")]) { _, model, request in
            recorder.calls.append((model.id, request))
            if model.id != "first" { throw ProviderServiceError.emptyResponse }
            return """
            Here you go:
            [{"kind":"identity","content":"I write historical novels"},
             {"kind":"preference","content":"Prefer Arabic replies"},
             {"kind":"project","content":"Working on a novel about Andalusia"}]
            """
        }

        let outcome = await organizer.organize(content: source.content)

        #expect(recorder.calls.map(\.modelId) == ["first"])
        let request = try #require(recorder.calls.last?.request)
        #expect(request.system == MemoryItems.organizeRequest(content: source.content).system)
        #expect(request.messages.map(\.role) == [.user])
        #expect(request.messages.map(\.text) == [source.content])
        guard case .entries(let entries) = outcome else {
            Issue.record("expected entries, got \(outcome)")
            return
        }
        #expect(entries.map(\.kind) == [.identity, .preference, .project])

        var selection = MemoryOrganizeSelection(sourceId: source.id, entries: entries)
        #expect(selection.selected == [true, true, true])
        #expect(selection.keepOriginal == false)
        selection.selected[1] = false
        #expect(selection.canSave)
        let chosen = selection
        let created = try await repository.perform { try chosen.save($0) }

        #expect(created.map(\.kind) == [.identity, .project])
        #expect(created.map(\.content) == ["I write historical novels", "Working on a novel about Andalusia"])
        #expect(created.allSatisfy { $0.source.type == .manual && Self.isLowercasedUUID($0.id) })
        #expect(repository.allItems().first { $0.id == source.id }?.status == .deleted)
        let live = repository.list().filter { $0.status != .deleted }
        #expect(Set(live.map(\.id)) == Set(created.map(\.id)))
        #expect(MemoryItemListPresentation.resolve(items: repository.list(), deviceId: Self.thisDevice)
            .sections.map(\.group) == [.about, .projects])
    }

    @Test("When \"Keep original items\" is on the originals are untouched; with nothing checked it cannot be saved")
    func organizeKeepOriginalToggle() async throws {
        let (repository, _) = try Self.makeRepository()
        let source = try Self.migrationItem(in: repository, content: "Answer briefly.\nUse SI units.")
        let organizer = MemoryOrganizer(candidates: [Self.candidate("only")]) { _, _, _ in
            #"[{"kind":"preference","content":"Answer briefly"},{"kind":"CONSTRAINT","content":"Use SI units"}]"#
        }

        guard case .entries(let entries) = await organizer.organize(content: source.content) else {
            Issue.record("expected entries")
            return
        }
        var selection = MemoryOrganizeSelection(sourceId: source.id, entries: entries)
        selection.selected = [false, false]
        #expect(selection.canSave == false)
        selection.selected = [true, true]
        selection.keepOriginal = true
        let chosen = selection
        let created = try await repository.perform { try chosen.save($0) }

        #expect(created.map(\.kind) == [.preference, .constraint])
        let kept = try #require(repository.allItems().first { $0.id == source.id })
        #expect(kept.status == .active)
        #expect(kept.content == source.content)
        #expect(kept.source.type == .migration)
        #expect(repository.list().filter { $0.status != .deleted }.count == 3)
    }

    @Test("A model reply that yields no items, or a failed request: \"empty\" and \"failed\" are reported separately, and no item is written")
    func organizeParseEmptyChangesNothing() async throws {
        let (repository, _) = try Self.makeRepository()
        let source = try Self.migrationItem(in: repository, content: "Answer briefly.\nUse SI units.")
        let before = repository.allItems()

        let prose = MemoryOrganizer(candidates: [Self.candidate("only")]) { _, _, _ in
            "I could not find anything to split."
        }
        #expect(await prose.organize(content: source.content) == .empty)

        let emptyArray = MemoryOrganizer(candidates: [Self.candidate("only")]) { _, _, _ in "[]" }
        #expect(await emptyArray.organize(content: source.content) == .empty)

        let failedRecorder = SendRecorder()
        let failing = MemoryOrganizer(candidates: [Self.candidate("a"), Self.candidate("b")]) { _, model, request in
            failedRecorder.calls.append((model.id, request))
            throw ProviderServiceError.emptyResponse
        }
        #expect(await failing.organize(content: source.content) == .failed)
        // A failure does not switch to the next candidate
        #expect(failedRecorder.calls.map(\.modelId) == ["a"])

        #expect(repository.allItems() == before)
        #expect(L10n.tr("memory_organize_empty", table: .chat) != "memory_organize_empty")
        #expect(L10n.tr("memory_organize_failed", table: .chat) != "memory_organize_failed")
    }

    @Test("No usable model: it hints to pick a default model first, and sends no request")
    func organizeNoModelHint() async {
        let recorder = SendRecorder()
        let send: MemoryOrganizer.Send = { _, model, request in
            recorder.calls.append((model.id, request))
            return "[]"
        }
        let keylessOfficial = TestFactories.makeProvider(
            kind: .anthropic,
            models: [TestFactories.makeModel(id: "claude", name: "claude", isDefault: true)],
            apiKey: ""
        )

        #expect(await MemoryOrganizer(providers: [], lastUsedModelRef: nil, send: send).organize(content: "x\ny") == .noModel)
        #expect(await MemoryOrganizer(providers: [keylessOfficial], lastUsedModelRef: nil, send: send)
            .organize(content: "x\ny") == .noModel)
        #expect(recorder.calls.isEmpty)
        #expect(L10n.tr("memory_organize_no_model", table: .chat) != "memory_organize_no_model")
    }
}
