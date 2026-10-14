import Foundation
import Testing
@testable import Oriveo

/// Add step 2, "choose the models to use" (board SetupModels, contract cards C / E).
/// Grouping / expansion / key chips assert the production pure model; saving asserts the production flow (a fake relay counts requests).
@Suite("Add step 2 board · BOARD-SETUPMODELS", .serialized)
@MainActor
struct RelaySetupModelsBoardTests {
    private typealias Board = RelaySetupModelsBoard

    private static let groups: [Board.Group] = [
        .init(id: "anthropic", title: "Claude", modelIDs: ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"]),
        .init(id: "openai", title: "GPT", modelIDs: ["gpt-6", "gpt-5.6"]),
        .init(id: "google", title: "Gemini", modelIDs: ["gemini-2.5-pro"]),
    ]

    private static func makeState(_ stub: RelaySetupHTTPStub) -> AppState {
        AppState(
            seedDemoData: false,
            sessionUID: "rd2-\(UUID().uuidString)",
            providerSession: RelaySetupHTTPStub.session()
        )
    }

    // MARK: - BOARD-SETUPMODELS-01

    @Test("BOARD-SETUPMODELS-01 groups are collapsed by default, a group with a selection is expanded, a search hit expands its group, after select-all in the group the button is disabled, and the first selection follows display order")
    func board01GroupsAndExpansion() throws {
        let idle = Board.make(.init(groups: Self.groups))
        #expect(idle.groups.map(\.id) == ["anthropic", "openai", "google"])
        #expect(idle.groups.allSatisfy { !$0.isExpanded })
        #expect(idle.groups.map(\.count) == [3, 2, 1])
        #expect(idle.groups.filter(\.canSelectAll).count == 3)
        #expect(idle.totalModelCount == 6)
        #expect(!idle.isSaveEnabled)
        #expect(idle.selectedCount == 0)

        let selected = Board.make(.init(groups: Self.groups, selected: ["gpt-5.6", "claude-opus-4-1"]))
        #expect(selected.groups.map(\.isExpanded) == [true, true, false])
        #expect(selected.groups.map(\.selectedCount) == [1, 1, 0])
        // The first selected item in display order: the opus in the earlier Claude group, not the order of tapping.
        #expect(selected.firstSelectedID == "claude-opus-4-1")
        #expect(selected.selectedInDisplayOrder == ["claude-opus-4-1", "gpt-5.6"])
        #expect(selected.isSaveEnabled)
        #expect(selected.selectedCount == 2)
        // An expanded group shows all rows (no "N more" folded row).
        #expect(selected.groups[0].rows.map(\.id) == ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"])

        // If the user manually collapses a group that has a selection or expands an empty group, the user's choice wins.
        let overridden = Board.make(.init(
            groups: Self.groups,
            selected: ["claude-opus-4-1"],
            expansion: ["anthropic": false, "google": true]
        ))
        #expect(overridden.groups.map(\.isExpanded) == [false, false, true])

        // Search: by id substring, case-insensitive; only groups with hits remain, and they are expanded.
        let search = Board.make(.init(groups: Self.groups, searchText: "GEM"))
        #expect(search.groups.map(\.id) == ["google"])
        #expect(search.groups[0].isExpanded)
        #expect(search.groups[0].rows.map(\.id) == ["gemini-2.5-pro"])

        // Select all in the group: every item in the group is selected, after which the button is disabled.
        let all = Board.selectingAll(groupID: "anthropic", groups: Self.groups, selected: ["gpt-6"])
        #expect(all == ["gpt-6", "claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"])
        let afterAll = Board.make(.init(groups: Self.groups, selected: all))
        #expect(!afterAll.groups[0].canSelectAll)
        #expect(afterAll.groups[1].canSelectAll)
        #expect(afterAll.groups[0].selectedCount == 3)

        // Keys for the title, search placeholder and save button text (the 16 languages are already stored by the copy commit).
        #expect(Board.titleKey == "Choose models to use")
        #expect(Board.searchKey == "Search %lld models")
        #expect(Board.groupSelectedKey == "%lld selected")
        #expect(Board.selectGroupKey == "Select all in group")
        #expect(Board.addManualKey == "Add model ID manually")
        #expect(Board.saveSelectedKey == "Save (%lld selected)")
        #expect(Board.saveNoteKey == "After saving, Oriveo sends one tiny request to the first selected model to confirm it works.")
    }

    // MARK: - BOARD-SETUPMODELS-02

    @Test("BOARD-SETUPMODELS-02 key chips appear only with 2 or more keys, are drawn only on selected rows, and the value = the bind result")
    func board02KeyChipsOnlyWithTwoKeys() throws {
        let keys: [Board.KeyLabel] = [
            .init(id: RelayKeyBinding.implicitKeyID, label: "OpenAI group"),
            .init(id: "k2", label: "Claude group"),
        ]
        let listedBy: [String: [String]] = [
            "claude-sonnet-4-5": [RelayKeyBinding.implicitKeyID, "k2"],
            "claude-opus-4-1": ["k2"],
            "claude-haiku-4-5": ["k2"],
            "gpt-6": [RelayKeyBinding.implicitKeyID],
            "gpt-5.6": [RelayKeyBinding.implicitKeyID],
            "gemini-2.5-pro": [RelayKeyBinding.implicitKeyID],
        ]
        let multi = Board.make(.init(
            groups: Self.groups,
            selected: ["claude-opus-4-1", "gpt-6"],
            keys: keys,
            listedBy: listedBy
        ))
        #expect(multi.showsKeyChips)
        #expect(multi.subtitleKeyCount == 2)
        let claudeRows = Dictionary(uniqueKeysWithValues: multi.groups[0].rows.map { ($0.id, $0) })
        #expect(claudeRows["claude-opus-4-1"]?.keyLabel == "Claude group")
        #expect(claudeRows["claude-sonnet-4-5"]?.keyLabel == nil)
        #expect(multi.groups[1].rows.first { $0.id == "gpt-6" }?.keyLabel == "OpenAI group")
        // Binding uses the same function as production enabling: bind one by one in display order, and an already-bound model of the same family affects the later ones.
        let catalog = listedBy.map { id, keys in
            var model = TestFactories.makeModel(id: id, name: id)
            model.relayListedByKeyIDs = keys
            return model
        }
        let expected = RelayKeyBinding.bind(
            keyIDs: keys.map(\.id), catalog: catalog, enabled: [], targetModelID: "claude-opus-4-1",
            family: { RelayFamilyHeuristics.infer(modelID: $0)?.rawValue }
        )
        #expect(multi.boundKeyByModel["claude-opus-4-1"] == expected)

        let single = Board.make(.init(
            groups: Self.groups,
            selected: ["claude-opus-4-1", "gpt-6"],
            keys: [.init(id: RelayKeyBinding.implicitKeyID, label: "sk-…")]
        ))
        #expect(!single.showsKeyChips)
        #expect(single.subtitleKeyCount == nil)
        #expect(single.groups.flatMap(\.rows).allSatisfy { $0.keyLabel == nil })
        #expect(single.boundKeyByModel.isEmpty)
    }

    // MARK: - BOARD-SETUPMODELS-03

    @Test("BOARD-SETUPMODELS-03 only the first selection is verified (one generation request), all selections are enabled, and providers enters the detail page with a one-time notice")
    func board03SaveVerifiesOnlyFirstSelected() async throws {
        let stub = RelaySetupHTTPStub()
        stub.catalog(secret: "sk-main", modelIDs: ["gpt-6", "gpt-5.6", "claude-sonnet-4-5", "deepseek-chat"])
        stub.catalog(secret: "sk-second", modelIDs: ["claude-sonnet-4-5", "claude-haiku-4-5"])
        let state = Self.makeState(stub)
        let flow = RelayQuickSetupFlow.stubbed(stub)
        flow.setEndpoint(stub.endpoint)
        flow.setSecret("sk-main", for: RelayKeyBinding.implicitKeyID)
        flow.setName("OpenAI group", for: RelayKeyBinding.implicitKeyID)
        let second = flow.addKey()
        flow.setSecret("sk-second", for: second)
        flow.setName("Claude group", for: second)

        await flow.next(appState: state)?.value
        #expect(flow.step == .models)
        // Step 1 sends zero chat requests.
        #expect(stub.generationModels.isEmpty)
        // The extra key goes through catalogAPIRoot's /v1/models (the same root as discovery).
        #expect(stub.requests.filter { $0 == "GET /v1/models" }.count >= 2)

        // Groups and group order = the same projection as the model library (the same draft catalog, with no model enabled yet).
        let groups = flow.modelGroups
        #expect(Set(groups.flatMap(\.modelIDs)) == ["gpt-6", "gpt-5.6", "claude-sonnet-4-5", "deepseek-chat", "claude-haiku-4-5"])

        // Select three: the first in display order is the verification sample.
        for id in ["claude-haiku-4-5", "deepseek-chat", "gpt-5.6"] { flow.toggle(modelID: id) }
        let board = flow.modelsBoard
        #expect(board.selectedCount == 3)
        #expect(board.showsKeyChips)
        let first = try #require(board.firstSelectedID)
        #expect(first == board.selectedInDisplayOrder.first)

        let saved = await flow.save(appState: state, entryPoint: .providers)
        #expect(saved)
        // Only one generation request was sent, for the first selection.
        #expect(stub.generationModels == [first])

        let provider = try #require(state.providers.first { $0.kind == .relay })
        #expect(Set(provider.models.map(\.id)) == ["claude-haiku-4-5", "deepseek-chat", "gpt-5.6"])
        #expect(provider.status == .connected)
        #expect(provider.models.allSatisfy { !$0.isDefault })
        #expect(provider.relayRequested?.modelID == nil)
        // The second key has been added and haiku is listed only by it -> bind it (the same result as the step 2 chip).
        let keyIDs = RelayKeyBinding.keyIDs(provider)
        #expect(keyIDs.count == 2)
        #expect(provider.relayKeys?.map(\.name) == ["OpenAI group", "Claude group"])
        let haiku = try #require(provider.models.first { $0.id == "claude-haiku-4-5" })
        #expect(haiku.relayKeyID == keyIDs[1])
        #expect(board.boundKeyByModel["claude-haiku-4-5"] == keyIDs[1])
        // The catalog merges the two keys.
        #expect(Set(provider.catalogModels.map(\.id)).isSuperset(of: ["gpt-6", "claude-haiku-4-5"]))

        // Group order matches the model library: the step 2 groups = the same projection as the saved model library (excluding enabled models).
        var libraryView = provider
        libraryView.models = []
        let library = buildProviderCatalogGroups(for: libraryView, searchText: "")
        #expect(groups.map(\.id) == library.map(\.id))

        // providers entry: enter the detail page, select the model just verified, and the one-time notice on the detail page carries the enabled count.
        #expect(state.navigation.path == [.providerDetail(providerID: provider.id)])
        #expect(state.selectedTab == .providers)
        #expect(state.providerDetailNotice == .init(providerID: provider.id, kind: .addedModels(3)))
        #expect(state.lastUsedModelRef == LastUsedModelRef(providerID: provider.id, modelID: first))
        #expect(state.consumeProviderDetailNotice(for: provider.id) == .addedModels(3))
        #expect(state.providerDetailNotice == nil)
        #expect(state.consumeProviderDetailNotice(for: provider.id) == nil)
    }

    // MARK: - BOARD-SETUPMODELS-04

    @Test("BOARD-SETUPMODELS-04 catalog unavailable -> step 2 manual-add state; 0 items cannot be saved, and adding manually selects it")
    func board04CatalogFailureGoesToManualAdd() async throws {
        let stub = RelaySetupHTTPStub()
        stub.catalog(secret: "sk-empty", modelIDs: [])
        let state = Self.makeState(stub)
        let flow = RelayQuickSetupFlow.stubbed(stub)
        flow.setEndpoint(stub.endpoint)
        flow.setSecret("sk-empty", for: RelayKeyBinding.implicitKeyID)

        await flow.next(appState: state)?.value
        // Empty catalog: stay on step 1, the catalog item gives one sentence, and Next enters the manual-add state.
        #expect(flow.step == .connection)
        let detection = try #require(flow.detection)
        #expect(detection.connection.status == .done)
        #expect(detection.catalog.status == .failed)
        #expect(detection.protocols.status == .skipped)
        #expect(detection.failure == .emptyCatalog)
        #expect(flow.connectionBoard(canAct: true).nextAction == .models(manualAdd: true))

        await flow.next(appState: state)?.value
        #expect(flow.step == .models)
        let empty = flow.modelsBoard
        #expect(empty.groups.isEmpty)
        #expect(empty.showsEmptyNote)
        #expect(!empty.isSaveEnabled)
        #expect(RelaySetupModelsBoard.emptyKey == "Couldn’t get the model list. Add the model IDs you want to use.")

        flow.addManualModel("my-model")
        let added = flow.modelsBoard
        #expect(added.selectedInDisplayOrder == ["my-model"])
        #expect(added.isSaveEnabled)
        #expect(!added.showsEmptyNote)
        #expect(added.saveCount == 1)
    }

    // MARK: - BOARD-SETUPMODELS-05

    @Test("BOARD-SETUPMODELS-05 the first selection fails verification: stay on step 2 and show the failure, nothing is persisted")
    func board05VerificationFailureDoesNotPersist() async throws {
        let stub = RelaySetupHTTPStub()
        stub.catalog(secret: "sk-main", modelIDs: ["gpt-6", "gpt-5.6"])
        stub.failGeneration(status: 500)
        let state = Self.makeState(stub)
        let flow = RelayQuickSetupFlow.stubbed(stub)
        flow.setEndpoint(stub.endpoint)
        flow.setSecret("sk-main", for: RelayKeyBinding.implicitKeyID)

        await flow.next(appState: state)?.value
        #expect(flow.step == .models)
        flow.toggle(modelID: "gpt-5.6")
        let before = state.providers.count

        let saved = await flow.save(appState: state, entryPoint: .providers)
        #expect(!saved)
        #expect(flow.step == .models)
        #expect(flow.saveFailure != nil)
        #expect(state.providers.count == before)
        #expect(!state.providers.contains { $0.kind == .relay })
        #expect(stub.generationModels.allSatisfy { $0 == "gpt-5.6" })
        #expect(!stub.generationModels.isEmpty)
        #expect(state.providerDetailNotice == nil)
    }

    // MARK: - BOARD-SETUPMODELS-06 to 09: edge cases for manually adding a model ID

    /// Run the production flow to step 2: the fake relay serves only the given catalog.
    private static func modelsStepFlow(catalog: [String]) async -> RelayQuickSetupFlow {
        let stub = RelaySetupHTTPStub()
        stub.catalog(secret: "sk-main", modelIDs: catalog)
        let state = makeState(stub)
        let flow = RelayQuickSetupFlow.stubbed(stub)
        flow.setEndpoint(stub.endpoint)
        flow.setSecret("sk-main", for: RelayKeyBinding.implicitKeyID)
        await flow.next(appState: state)?.value
        return flow
    }

    @Test("BOARD-SETUPMODELS-06 empty string / whitespace only: nothing is added or selected, the result is ignored; \"Add\" is disabled")
    func board06BlankInputIsIgnored() async throws {
        let flow = await Self.modelsStepFlow(catalog: ["gpt-6", "gpt-5.6"])
        #expect(flow.step == .models)
        let groupsBefore = flow.modelGroups

        for raw in ["", "   ", "\n\t "] {
            #expect(flow.addManualModel(raw) == .ignored)
            #expect(!RelayQuickSetupFlow.canAddManualModel(raw))
        }
        #expect(flow.manualModelIDs.isEmpty)
        #expect(flow.modelGroups == groupsBefore)
        #expect(flow.modelsBoard.selectedCount == 0)
        #expect(!flow.modelsBoard.isSaveEnabled)
        #expect(!flow.showsManualModelDuplicateNote)
        // It can be tapped only if there is content after trimming whitespace at both ends.
        #expect(RelayQuickSetupFlow.canAddManualModel("  my-model \n"))
    }

    @Test("BOARD-SETUPMODELS-07 duplicate of a catalog ID: nothing is added, it is selected, the result is already-in-list; the notice disappears on the next add / selection toggle / sheet reopen")
    func board07DuplicateOfCatalogIDSelectsIt() async throws {
        let flow = await Self.modelsStepFlow(catalog: ["gpt-6", "gpt-5.6"])
        let groupsBefore = flow.modelGroups
        #expect(!flow.showsManualModelDuplicateNote)

        #expect(flow.addManualModel(" gpt-5.6 ") == .alreadyListed)
        #expect(flow.manualModelIDs.isEmpty)
        #expect(flow.modelGroups == groupsBefore)
        #expect(flow.modelsBoard.selectedInDisplayOrder == ["gpt-5.6"])
        #expect(flow.showsManualModelDuplicateNote)

        // Toggling the selection -> the notice disappears.
        flow.toggle(modelID: "gpt-6")
        #expect(!flow.showsManualModelDuplicateNote)

        // Reopening the sheet -> the notice disappears.
        #expect(flow.addManualModel("gpt-5.6") == .alreadyListed)
        #expect(flow.showsManualModelDuplicateNote)
        flow.clearManualModelDuplicateNote()
        #expect(!flow.showsManualModelDuplicateNote)

        // Select all in the group is also a selection toggle -> the notice disappears.
        #expect(flow.addManualModel("gpt-5.6") == .alreadyListed)
        #expect(flow.showsManualModelDuplicateNote)
        flow.selectAll(groupID: try #require(flow.modelGroups.first).id)
        #expect(!flow.showsManualModelDuplicateNote)

        // The next successful add -> the notice disappears.
        #expect(flow.addManualModel("gpt-5.6") == .alreadyListed)
        #expect(flow.showsManualModelDuplicateNote)
        #expect(flow.addManualModel("brand-new") == .added)
        #expect(!flow.showsManualModelDuplicateNote)

        // Notice text keys and the 16 languages.
        #expect(Board.manualDuplicateNoteKey == "Already in the list. It’s selected now.")
        let note = try ProductionSource.localizations(table: "Providers", key: Board.manualDuplicateNoteKey)
        #expect(note.count == 16)
        #expect(note["en"] == Board.manualDuplicateNoteKey)
    }

    @Test("BOARD-SETUPMODELS-08 duplicate of a manually added ID: nothing is added, it is selected again, and the manual list length is unchanged")
    func board08DuplicateOfManualIDSelectsIt() async throws {
        let flow = await Self.modelsStepFlow(catalog: ["gpt-6"])
        #expect(flow.addManualModel("my-model") == .added)
        #expect(flow.manualModelIDs == ["my-model"])
        flow.toggle(modelID: "my-model")
        #expect(flow.modelsBoard.selectedCount == 0)

        #expect(flow.addManualModel("my-model") == .alreadyListed)
        #expect(flow.manualModelIDs == ["my-model"])
        #expect(flow.modelGroups.flatMap(\.modelIDs).filter { $0 == "my-model" }.count == 1)
        #expect(flow.modelsBoard.selectedInDisplayOrder == ["my-model"])
        #expect(flow.showsManualModelDuplicateNote)
    }

    @Test("BOARD-SETUPMODELS-09 differing only by case: same criterion as enabling, nothing is added, the existing item is selected, the result is already-in-list; saving enables only that one")
    func board09CaseDifferenceIsTheSameModel() async throws {
        let stub = RelaySetupHTTPStub()
        stub.catalog(secret: "sk-main", modelIDs: ["gpt-4o", "gpt-6"])
        let state = Self.makeState(stub)
        let flow = RelayQuickSetupFlow.stubbed(stub)
        flow.setEndpoint(stub.endpoint)
        flow.setSecret("sk-main", for: RelayKeyBinding.implicitKeyID)
        await flow.next(appState: state)?.value
        #expect(flow.step == .models)
        let groupsBefore = flow.modelGroups

        // Catalog item: what gets selected is the spelling in the catalog, not the spelling the user typed.
        #expect(flow.addManualModel("GPT-4o") == .alreadyListed)
        #expect(flow.manualModelIDs.isEmpty)
        #expect(flow.modelGroups == groupsBefore)
        #expect(flow.modelsBoard.selectedInDisplayOrder == ["gpt-4o"])
        #expect(flow.showsManualModelDuplicateNote)

        // The earlier manually added item: differing only by case likewise does not add another.
        #expect(flow.addManualModel("My-Model") == .added)
        flow.toggle(modelID: "My-Model")
        #expect(flow.addManualModel("my-model") == .alreadyListed)
        #expect(flow.manualModelIDs == ["My-Model"])
        #expect(Set(flow.modelsBoard.selectedInDisplayOrder) == ["gpt-4o", "My-Model"])
        flow.toggle(modelID: "My-Model")

        // The criterion is the same function as the enabling path: whatever it treats as the same never becomes two rows here.
        let typed = ProviderManager.relayCatalogModels(modelIDs: ["GPT-4o"], relayRequested: nil)[0]
        let listed = ProviderManager.relayCatalogModels(modelIDs: ["gpt-4o"], relayRequested: nil)[0]
        #expect(ModelResolver.modelsShareSameRemoteModel(typed, listed, providerKind: .relay))

        // Go through the production save: only the catalog one is persisted, and the notice's enabled count matches the actual enabled count.
        let board = flow.modelsBoard
        #expect(board.saveCount == 1)
        let saved = await flow.save(appState: state, entryPoint: .providers)
        #expect(saved)
        let provider = try #require(state.providers.first { $0.kind == .relay })
        #expect(provider.models.map(\.id) == ["gpt-4o"])
        #expect(state.providerDetailNotice == .init(providerID: provider.id, kind: .addedModels(provider.models.count)))
        #expect(stub.generationModels == ["gpt-4o"])
    }

    // MARK: - BOARD-SETUPMODELS-10 to 12: relays judge identity by the literal ID (the earlier date-folding rule is withdrawn)

    @Test("BOARD-SETUPMODELS-10 a date snapshot suffix alone makes it a different model: a new row is added with the result added; after saving both IDs are persisted")
    func board10SnapshotDateSuffixIsAnotherModel() async throws {
        let stub = RelaySetupHTTPStub()
        stub.catalog(secret: "sk-main", modelIDs: ["gpt-4o", "claude-sonnet-4-5-20250929", "gpt-6"])
        let state = Self.makeState(stub)
        let flow = RelayQuickSetupFlow.stubbed(stub)
        flow.setEndpoint(stub.endpoint)
        flow.setSecret("sk-main", for: RelayKeyBinding.implicitKeyID)
        await flow.next(appState: state)?.value
        #expect(flow.step == .models)

        // The catalog has the one without a date: adding the date-snapshot spelling is a new row, and it is selected.
        #expect(flow.addManualModel("gpt-4o-2024-08-06") == .added)
        #expect(!flow.showsManualModelDuplicateNote)
        #expect(flow.manualModelIDs == ["gpt-4o-2024-08-06"])
        #expect(flow.modelGroups.flatMap(\.modelIDs).contains("gpt-4o-2024-08-06"))
        // The same dated spelling differing only by case still lands on the row just added (the case rule is outside this decision).
        #expect(flow.addManualModel("GPT-4o-2024-08-06") == .alreadyListed)
        #expect(flow.manualModelIDs == ["gpt-4o-2024-08-06"])

        // The reverse: the catalog has only the dated one, and adding the undated spelling is likewise a new row.
        #expect(flow.addManualModel("claude-sonnet-4-5") == .added)
        #expect(flow.manualModelIDs == ["gpt-4o-2024-08-06", "claude-sonnet-4-5"])
        flow.toggle(modelID: "claude-sonnet-4-5")

        // The catalog item is selected too: both spellings are saved together.
        flow.toggle(modelID: "gpt-4o")
        let board = flow.modelsBoard
        #expect(Set(board.selectedInDisplayOrder) == ["gpt-4o", "gpt-4o-2024-08-06"])
        #expect(board.saveCount == 2)
        let sampleID = try #require(board.firstSelectedID)

        // Go through the production save: both IDs are persisted, the notice's enabled count matches the actual enabled count, and only the verification sample's one generation request is sent.
        let saved = await flow.save(appState: state, entryPoint: .providers)
        #expect(saved)
        let provider = try #require(state.providers.first { $0.kind == .relay })
        #expect(Set(provider.models.map(\.id)) == ["gpt-4o", "gpt-4o-2024-08-06"])
        #expect(provider.models.count == 2)
        #expect(state.providerDetailNotice == .init(providerID: provider.id, kind: .addedModels(2)))
        #expect(stub.generationModels == [sampleID])
    }

    @Test("BOARD-SETUPMODELS-12 two different date snapshots: with …-20240620 in the catalog, manually adding …-20241022 is a new row, and after saving both are persisted")
    func board12DifferentSnapshotDatesAreBothSaved() async throws {
        let stub = RelaySetupHTTPStub()
        stub.catalog(secret: "sk-main", modelIDs: ["claude-3-5-sonnet-20240620", "gpt-6"])
        let state = Self.makeState(stub)
        let flow = RelayQuickSetupFlow.stubbed(stub)
        flow.setEndpoint(stub.endpoint)
        flow.setSecret("sk-main", for: RelayKeyBinding.implicitKeyID)
        await flow.next(appState: state)?.value
        #expect(flow.step == .models)

        #expect(flow.addManualModel("claude-3-5-sonnet-20241022") == .added)
        #expect(!flow.showsManualModelDuplicateNote)
        #expect(flow.manualModelIDs == ["claude-3-5-sonnet-20241022"])
        flow.toggle(modelID: "claude-3-5-sonnet-20240620")
        let board = flow.modelsBoard
        #expect(Set(board.selectedInDisplayOrder) == ["claude-3-5-sonnet-20240620", "claude-3-5-sonnet-20241022"])
        let sampleID = try #require(board.firstSelectedID)

        let saved = await flow.save(appState: state, entryPoint: .providers)
        #expect(saved)
        let provider = try #require(state.providers.first { $0.kind == .relay })
        #expect(Set(provider.models.map(\.id)) == ["claude-3-5-sonnet-20240620", "claude-3-5-sonnet-20241022"])
        #expect(provider.models.count == 2)
        #expect(state.providerDetailNotice == .init(providerID: provider.id, kind: .addedModels(2)))
        #expect(stub.generationModels == [sampleID])
    }

    @Test("BOARD-SETUPMODELS-11 the notice after saving reports how many were actually enabled: when two catalog rows are treated as the same model by the enabling path, it does not over-report by the selection count")
    func board11NoticeCountsModelsActuallyEnabled() async throws {
        let stub = RelaySetupHTTPStub()
        // The catalog itself lists two spellings of the same model (a historical hand-typed prefix): the enabling path folds them into one.
        stub.catalog(secret: "sk-main", modelIDs: ["gpt-4o", "relay-manual-gpt-4o", "gpt-6"])
        let state = Self.makeState(stub)
        let flow = RelayQuickSetupFlow.stubbed(stub)
        flow.setEndpoint(stub.endpoint)
        flow.setSecret("sk-main", for: RelayKeyBinding.implicitKeyID)
        await flow.next(appState: state)?.value
        #expect(flow.step == .models)

        flow.toggle(modelID: "gpt-4o")
        flow.toggle(modelID: "relay-manual-gpt-4o")
        let saved = await flow.save(appState: state, entryPoint: .providers)
        #expect(saved)

        let provider = try #require(state.providers.first { $0.kind == .relay })
        #expect(provider.models.count == 1)
        #expect(state.providerDetailNotice == .init(providerID: provider.id, kind: .addedModels(provider.models.count)))
    }
}
