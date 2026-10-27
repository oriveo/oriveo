#if DEBUG
import SwiftUI

/// Debug direct-entry pages for the web search page family: used to capture screenshots; nothing from this file exists in Release builds.
///
/// Usage: `xcrun simctl launch <udid> com.kenny.oriveo -AUTO_OPEN_PAGE <page name> -SHOTS_PROBE`; page names are in `Shot`.
/// Data is read only from the shared cross-platform manifest `shared/test-fixtures/shots/webSearch.v1.json`, all in memory: service list, default id, connections,
/// finished test results. No real storage writes, no key reads, no network, no test searches; the catalog uses the built-in snapshot (adopted in a temporary cache directory).
///
/// The injection points in production views are all `#if DEBUG` (marked "screenshot staging only" next to them); when nothing is staged, behavior is unchanged:
/// 1. `WebSearchSettingsModel.load`: when `staged` has a value, use the manifest data directly, without touching storage or the catalog singleton.
/// 2. `WebSearchSettingsView.onAppear`: `takeOpensAddSheet()` opens the add sheet; no markSeen while staging.
/// 3. `WebSearchAddSheet.onAppear`: `takeAddRoute()` pushes the connect page / custom form.
/// 4. Connect page / custom consent page / detail page: `takeTestPhase()` / `takeDetailTest()` provide finished test results.
/// 5. Custom form: `takeDraft()` prefills the draft, `takeOpensConsent()` goes straight to the consent page.
/// 6. Red dot on the web search cell of the settings home: `badgeOverride`.
/// 7. Model options web card: `takeModelOptions()` presents the production model options panel over the settings page; the web card is drawn through
///    resolveWebSearchRoute → webSearchCardPresentation, with in-memory manifest values as data.
/// 8. Chat staging: `openChat` places a conversation (one user message + one assistant message) in the in-memory AppState and opens it through the production entry;
///    the assistant message state comes from running production startSearchReply → applySearchEvent → finishSearchReply over
///    `shared/search-contracts/search-turn.v1.json` `replyCases[preset.replyCase]`; state values are never hand-written.
enum WebSearchShots {
    enum Shot: String, CaseIterable {
        case webSearchHome, webSearchEmpty, webSearchMain, webSearchAdd
        case webSearchConnectReuse, webSearchConnectPaste, webSearchConnectPassed
        case webSearchDetail, webSearchDetailOwnKey
        case webSearchCustomForm, webSearchCustomManual, webSearchCustomConsent, webSearchCustomConsentFailed
        case webSearchOptExternal, webSearchOptPresearch, webSearchOptNotArmed, webSearchOptReuse, webSearchOptNone
        case webSearchOptNative, webSearchOptFallback, webSearchSourcePicker
        case webSearchChatSearching, webSearchChatAnswer, webSearchChatError, webSearchChatReused
        case webSearchChatErrorRateLimited, webSearchChatErrorFormat, webSearchChatErrorHostChanged, webSearchChatErrorWithdrawn, webSearchChatErrorNetwork
    }

    /// Model options staging: panel facts and the input for the "Search method" sheet.
    struct ModelOptions {
        var facts: ModelOptionsPanelFacts
        var pickerItems: [SearchSourcePickerItem]
        var services: [WebSearchServiceItem]
        var modelName: String
        var opensPicker: Bool
    }

    static var isRequested: Bool { requestedShot(in: CommandLine.arguments) != nil }

    static func requestedShot(in arguments: [String]) -> Shot? {
        guard let index = arguments.firstIndex(of: "-AUTO_OPEN_PAGE"), index + 1 < arguments.count else { return nil }
        return Shot(rawValue: arguments[index + 1])
    }

    // MARK: - Staged data

    struct Staged {
        var items: [WebSearchServiceItem]
        var defaultID: String?
        var connections: [SearchSettingsConnection]
        var entries: [SearchJSON]
        var catalogNames: [String: String]
        /// Per-conversation source (key = conversation id).
        var sources: [String: SearchJSON] = [:]
    }

    /// State read by the injection points; all nil when nothing is staged.
    @MainActor static var staged: Staged?

    @MainActor static var badgeOverride: Bool?
    @MainActor private static var pendingAddSheet = false
    @MainActor private static var pendingRoute: WebSearchAddRoute?
    @MainActor private static var pendingPhase: WebSearchTestPhase?
    @MainActor private static var pendingDetailTest: SearchTestPresentation?
    @MainActor private static var pendingDraft: WebSearchCustomDraft?
    @MainActor private static var pendingConsent = false
    @MainActor private static var pendingModelOptions: ModelOptions?

    @MainActor static func takeOpensAddSheet() -> Bool { defer { pendingAddSheet = false }; return pendingAddSheet }
    @MainActor static func takeAddRoute() -> WebSearchAddRoute? { defer { pendingRoute = nil }; return pendingRoute }
    @MainActor static func takeTestPhase() -> WebSearchTestPhase? { defer { pendingPhase = nil }; return pendingPhase }
    @MainActor static func takeDetailTest() -> SearchTestPresentation? { defer { pendingDetailTest = nil }; return pendingDetailTest }
    @MainActor static func takeDraft() -> WebSearchCustomDraft? { defer { pendingDraft = nil }; return pendingDraft }
    @MainActor static func takeOpensConsent() -> Bool { defer { pendingConsent = false }; return pendingConsent }
    @MainActor static func takeModelOptions() -> ModelOptions? { defer { pendingModelOptions = nil }; return pendingModelOptions }

    // MARK: - Entry

    @MainActor
    static func open(_ shot: Shot, appState: AppState) async {
        let manifest: SearchJSON
        do {
            manifest = try SearchJSON.parse(Data(contentsOf: manifestURL()))
        } catch {
            report("\(shot.rawValue): cannot read manifest \(error)")
            return
        }
        guard let page = manifest["pages"]?.arrayValue?.first(where: { $0["name"]?.stringValue == shot.rawValue }),
              let preset = page["preset"] else {
            report("\(shot.rawValue): manifest has no such page")
            return
        }
        // Catalog: the built-in snapshot is adopted in a temporary cache directory, leaving the real cache untouched
        let catalog = SearchCatalogStore(
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("web-search-shots-\(UUID().uuidString)")
        )
        await catalog.ensureLoaded()
        let entries = await catalog.activeEntries()
        staged = stage(manifest: manifest, page: page, entries: entries)
        badgeOverride = preset["badge"]?.boolValue
        appState.preferences.theme = .system
        appState.selectedTab = .settings

        let test = preset["test"].map(Self.presentation)
        switch preset["open"]?.stringValue {
        case "settingsHome":
            appState.navigation.reset(to: [])
        case "main":
            appState.navigation.reset(to: [.webSearchSettings])
        case "addSheet":
            pendingAddSheet = true
            appState.navigation.reset(to: [.webSearchSettings])
        case "connect":
            let serviceID = preset["serviceId"]?.stringValue ?? ""
            let model = WebSearchSettingsModel()
            await model.load(appState: appState)
            let reuse = preset["via"]?.stringValue == "reuse"
            let rows = model.addSheet.sections.flatMap(\.rows)
            guard var row = rows.first(where: { $0.serviceId == serviceID }) else {
                report("\(shot.rawValue): add sheet has no \(serviceID)")
                return
            }
            if !reuse { row.connectionRef = nil; row.connectionName = nil }
            pendingAddSheet = true
            pendingRoute = .connect(row)
            if let test, test.state == .passed {
                let becameDefault = preset["becameDefault"]?.boolValue == true
                pendingPhase = .passed(message: WebSearchCopy.tr(becameDefault ? "consent.passedDefault" : "consent.passed"))
            } else if let test {
                pendingPhase = .failed(test)
            }
            appState.navigation.reset(to: [.webSearchSettings])
        case "detail":
            pendingDetailTest = test
            appState.navigation.reset(to: [.webSearchSettings, .webSearchServiceDetail(serviceID: preset["service"]?.stringValue ?? "")])
        case "customForm", "customConsent":
            var draft = WebSearchCustomDraft()
            draft.name = preset["draft"]?["name"]?.stringValue ?? ""
            draft.address = preset["draft"]?["address"]?.stringValue ?? ""
            draft.protocolID = preset["draft"]?["protocol"]?.stringValue ?? "searxng"
            pendingDraft = draft
            pendingAddSheet = true
            pendingRoute = .custom
            if preset["open"]?.stringValue == "customConsent" {
                pendingConsent = true
                if let test { pendingPhase = test.state == .passed ? .passed(message: WebSearchCopy.tr("consent.passed")) : .failed(test) }
            }
            appState.navigation.reset(to: [.webSearchSettings])
        case "chat":
            await openChat(shot, manifest: manifest, preset: preset, appState: appState)
        case "modelOptions", "sourcePicker":
            let model = WebSearchSettingsModel()
            await model.load(appState: appState)
            pendingModelOptions = modelOptions(
                manifest: manifest, preset: preset, search: model, opensPicker: preset["open"]?.stringValue == "sourcePicker"
            )
            appState.navigation.reset(to: [.webSearchSettings])
        default:
            report("\(shot.rawValue): unknown preset.open")
        }
    }

    /// Manifest preset.model → production panel facts: the web row carries external search facts, run through the production chain by ModelOptionCapabilityShape.resolve.
    @MainActor
    static func modelOptions(manifest: SearchJSON, preset: SearchJSON, search: WebSearchSettingsModel, opensPicker: Bool) -> ModelOptions {
        let spec = preset["model"]
        let name = spec?["name"]?.stringValue ?? ""
        let connectionID = spec?["connection"]?.stringValue ?? ""
        let connection = manifest["connections"]?.arrayValue?.first { $0["id"]?.stringValue == connectionID }
        let modelKey = "\(connectionID):\(name)"
        let stored = preset["stored"].flatMap { $0.isNull ? nil : $0 }
        let presentation: CapabilityControlPresentation = switch spec?["nativeWeb"]?.stringValue {
        case "available": .automaticAvailable
        case "unavailable": .unsupported
        default: .unknown
        }
        let webOn = preset["webOn"]?.boolValue == true
        let webFacts = ModelOptionsWebSearch.facts(
            form: spec?["form"]?.stringValue.flatMap(WebSearchRouteInput.Form.init(rawValue:)) ?? .byok,
            presentation: presentation, relayWeb: nil, nativeRejected: false, managedWebAvailable: false,
            toolCall: spec?["toolCall"]?.stringValue.flatMap(WebSearchRouteInput.ToolCall.init(rawValue:)) ?? .unknown
        )
        let providerKind = connection?["providerKind"]?.stringValue ?? ""
        let target = SearchRoute.oneTapReuseTarget(
            catalogAvailable: search.catalogAvailable, entries: search.entries,
            connections: search.connections, currentProviderKind: providerKind
        )
        let state = SearchRoute.resolveWebSearchState(.init(
            facts: webFacts, panelWritable: true, webOn: webOn, modelKey: modelKey,
            services: search.items.map { WebSearchStateService(id: $0.id, name: $0.displayName, status: $0.row.status) },
            defaultServiceId: search.defaultID, stored: stored, oneTapTarget: target,
            oneTapServiceName: target.map { search.catalogName($0.serviceId) }
        ))
        var web = ModelOptionCapabilityShape.Input(
            capability: .web, presentation: presentation,
            availableIntents: presentation == .automaticAvailable ? [CapabilityWebPreference.automatic.rawValue] : [],
            selectedIntent: (webOn ? CapabilityWebPreference.automatic : .off).rawValue
        )
        web.webSearchState = state
        let facts = ModelOptionsPanelFacts(
            modelName: name,
            connectionName: connection?["name"]?.stringValue ?? connectionID,
            web: web,
            reasoning: .init(
                capability: .reasoning, presentation: .automaticAvailable,
                availableIntents: ["off", "balanced"], selectedIntent: "balanced"
            )
        )
        let services = search.selectableItems
        let items = state.pickerItems
        return ModelOptions(facts: facts, pickerItems: items, services: services, modelName: name, opensPicker: opensPicker)
    }

    // MARK: - Chat staging

    enum ShotError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { switch self { case .invalid(let message): message } }
    }

    /// Result of running a reply up to the given phase: searching stops at the first send effect; done runs all events and finishes.
    struct ChatReply {
        var effects: [SearchReplyEffect]
        var state: SearchReplyState
        var finish: SearchReplyFinish?
    }

    /// Fixture replyCase (start + events) → state produced step by step by production functions.
    static func chatReply(replyCase: SearchJSON, phase: String) throws -> ChatReply {
        guard let start = replyCase["input"]?["start"], let plan = start["plan"],
              let path = plan["path"]?.stringValue.flatMap(WebSearchRoute.Path.init(rawValue:)),
              let service = start["service"], let rhoHi = start["rhoHi"]?.numberValue else {
            throw ShotError.invalid("replyCase is missing start")
        }
        var state = SearchTurn.startSearchReply(SearchReplyStartInput(
            path: path,
            fallbackReason: plan["fallbackReason"]?.stringValue,
            noticeOnce: plan["noticeOnce"]?.boolValue == true,
            service: SearchTurnService(
                id: service["id"]?.stringValue ?? "", name: service["name"]?.stringValue ?? "",
                protocolID: service["protocol"]?.stringValue ?? "", custom: service["custom"]?.boolValue == true
            ),
            otherServices: (start["otherServices"]?.arrayValue ?? []).map {
                SearchOtherService(id: $0["id"]?.stringValue ?? "", name: $0["name"]?.stringValue ?? "", isDefault: $0["isDefault"]?.boolValue == true)
            },
            windowTokens: start["B"]?.numberValue,
            rhoHi: rhoHi,
            retrievedAt: start["retrievedAt"]?.stringValue ?? "",
            priorBatches: (start["priorBatches"]?.arrayValue ?? []).map {
                SearchCitationBatch(source: $0["source"]?.stringValue ?? "", items: citationItems($0["items"]))
            }
        ))
        var effects: [SearchReplyEffect] = []
        for raw in replyCase["input"]?["events"]?.arrayValue ?? [] {
            let step = try SearchTurn.applySearchEvent(state, try replyEvent(raw))
            state = step.state
            effects.append(step.effect)
            if phase == "searching", case .send = step.effect {
                return ChatReply(effects: effects, state: state, finish: nil)
            }
        }
        return ChatReply(effects: effects, state: state, finish: SearchTurn.finishSearchReply(state))
    }

    private static func citationItems(_ value: SearchJSON?) -> [SearchCitationItem] {
        (value?.arrayValue ?? []).map { SearchCitationItem(libraryKey: $0["libraryKey"]?.stringValue, url: $0["url"]?.stringValue) }
    }

    private static func resultItems(_ value: SearchJSON?) -> [SearchResultItem] {
        (value?.arrayValue ?? []).map {
            SearchResultItem(
                title: $0["title"]?.stringValue ?? "", url: $0["url"]?.stringValue ?? "",
                snippet: $0["snippet"]?.stringValue ?? "", site: $0["site"]?.stringValue, date: $0["date"]?.stringValue
            )
        }
    }

    private static func replyEvent(_ value: SearchJSON) throws -> SearchReplyEvent {
        switch value["type"]?.stringValue {
        case "call":
            return .call(query: value["query"]?.stringValue, count: value["count"]?.safeIntegerValue)
        case "result":
            guard let outcome = value["outcome"] else { throw ShotError.invalid("result is missing outcome") }
            let kind: SearchCallOutcome.Kind
            if let error = outcome["error"], !error.isNull {
                kind = .error(errorClass: error["errorClass"]?.stringValue ?? "", retryOnce: error["retryOnce"]?.boolValue == true)
            } else if let results = outcome["results"], !results.isNull {
                kind = .results(resultItems(results))
            } else {
                kind = .empty
            }
            return .result(.init(kind: kind, latencyMs: outcome["latencyMs"]?.safeIntegerValue ?? 0, sent: outcome["sent"]?.boolValue))
        case "reuse":
            return .reuse(query: value["query"]?.stringValue ?? "", results: resultItems(value["results"]))
        case "other_sources":
            return .otherSources(source: value["source"]?.stringValue ?? "", items: citationItems(value["items"]))
        case "stopped":
            return .stopped
        default:
            throw ShotError.invalid("unknown event \(value["type"]?.stringValue ?? "?")")
        }
    }

    /// Place a conversation (user message + assistant message) in the in-memory AppState and open the chat page through the production entry.
    /// The activity row, source card and error card show as much as they can at that point: the assistant message carries the citations produced by the production finish.
    @MainActor
    static func openChat(_ shot: Shot, manifest: SearchJSON, preset: SearchJSON, appState: AppState) async {
        // With a persisted state, switching connection and conversation would write into real conversations, so do not stage.
        guard !appState.prefersAuthoritativeConversationStore else {
            report("\(shot.rawValue): AppState is not in-memory, demo data not injected")
            return
        }
        let reply: ChatReply
        let providerKind: ProviderKind
        do {
            let turnURL = try manifestURL().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("search-contracts/search-turn.v1.json")
            let fixture = try SearchJSON.parse(Data(contentsOf: turnURL))
            let caseID = preset["replyCase"]?.stringValue ?? ""
            guard let replyCase = fixture["replyCases"]?.arrayValue?.first(where: { $0["caseId"]?.stringValue == caseID }) else {
                throw ShotError.invalid("search-turn has no \(caseID)")
            }
            reply = try chatReply(replyCase: replyCase, phase: preset["phase"]?.stringValue ?? "done")
            let connectionID = preset["model"]?["connection"]?.stringValue ?? ""
            let connection = manifest["connections"]?.arrayValue?.first { $0["id"]?.stringValue == connectionID }
            guard let kind = connection?["providerKind"]?.stringValue.flatMap(ProviderKind.init(rawValue:)) else {
                throw ShotError.invalid("providerKind of connection \(connectionID) is not recognized")
            }
            providerKind = kind
        } catch {
            report("\(shot.rawValue): \(error)")
            return
        }

        let modelID = preset["model"]?["name"]?.stringValue ?? ""
        let model = await CatalogModelBuilder.buildCatalogModel(providerKind: providerKind, runtimeModelId: modelID, fallbackName: modelID)
        let providerID = UUID(uuidString: "5EA2C400-0000-4000-8000-0000000000A1")!
        let conversationID = UUID(uuidString: "5EA2C400-0000-4000-8000-0000000000C1")!
        let userID = UUID(uuidString: "5EA2C400-0000-4000-8000-0000000000D1")!
        let assistantID = UUID(uuidString: "5EA2C400-0000-4000-8000-0000000000D2")!
        let provider = Provider(
            id: providerID, kind: providerKind, status: .connected, models: [model], catalogModels: [model],
            lastCheckedAt: nil, apiKey: "", apiKeyPreview: "", lastError: nil, baseURLText: nil
        )
        let userText = preset["userText"]?.stringValue ?? ""
        let created = Date(timeIntervalSince1970: 1_793_000_000)
        let done = reply.finish != nil
        var assistant = ChatMessage(
            id: assistantID, role: .assistant, text: done ? (preset["answer"]?.stringValue ?? "") : "",
            providerID: providerID, providerKind: providerKind, providerName: providerKind.displayName,
            modelID: modelID, modelName: model.name, estimatedCost: 0,
            state: done ? .delivered : .generating, createdAt: created.addingTimeInterval(5)
        )
        // Sources, source line, error card and notice land on the message through the production finish (same entry as the ChatManager finish); the numbering is the [n] in the body.
        if let finish = reply.finish {
            ChatManager.applyExternalSearchFinish(finish, serviceID: reply.state.service.id, to: &assistant)
        }
        CitationsBlock.debugSearchSourcesExpanded = preset["sourcesExpanded"]?.boolValue == true
        let messages = [
            ChatMessage(
                id: userID, role: .user, text: userText, providerID: providerID, providerKind: providerKind,
                providerName: providerKind.displayName, modelName: model.name, estimatedCost: 0, state: .delivered, createdAt: created
            ),
            assistant,
        ]
        var conversation = Conversation(
            id: conversationID, title: userText, providerID: providerID, providerKind: providerKind, modelID: modelID,
            previewText: messages.last?.text ?? "", estimatedCost: 0, isDraft: false, messages: messages, draftText: ""
        )
        conversation.hasCustomTitle = true
        conversation.createdAt = created
        conversation.updatedAt = created.addingTimeInterval(5)
        appState.providers = [provider]
        appState.upsertConversationProjection(conversation, deletingMessageIDs: [userID, assistantID])

        // The chat page hangs on the home stack: first switch back to home and wait for the home stack to mount, then open the conversation through the production entry (a push at launch would be overwritten by the root view's first-frame stack).
        appState.selectedTab = .home
        appState.navigation.reset(to: [])
        for _ in 0 ..< 40 where !(appState.navigation.path.isEmpty && appState.selectedTab == .home) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        // Searching: the production send / deliver effect activity is fed into the streaming session through the same ChatManager entry (activity row + search-term chips).
        if !done {
            let activities: [SearchActivity?] = reply.effects.compactMap { effect in
                switch effect {
                case .send(_, let activity): return .some(activity)
                case .deliver: return .some(nil)
                default: return nil
                }
            }
            appState.chatManager.debugStageExternalSearchActivity(
                conversationID: conversationID, assistantMessageID: assistantID, activities: activities
            )
        }
        appState.openChat(conversationID: conversationID)
    }

    // MARK: - Manifest → in-memory objects

    static func stage(manifest: SearchJSON, page: SearchJSON, entries: [SearchJSON]) -> Staged {
        // preset.connections = none: no model connections locally (model options staging nodevice / the no-connection variant).
        let rawConnections = page["preset"]?["connections"]?.stringValue == "none" ? [] : (manifest["connections"]?.arrayValue ?? [])
        let connections = rawConnections.map {
            SearchSettingsConnection(
                id: $0["id"]?.stringValue ?? "",
                name: $0["name"]?.stringValue ?? "",
                providerKind: $0["providerKind"]?.stringValue,
                baseUrl: $0["baseUrl"]?.stringValue
            )
        }
        var names: [String: String] = [:]
        for entry in entries {
            if let id = entry["id"]?.stringValue, let name = entry["displayName"]?.stringValue { names[id] = name }
        }
        let rawServices = page["services"]?.stringValue == "all" ? (manifest["services"]?.arrayValue ?? []) : []
        let items: [WebSearchServiceItem] = rawServices.map { raw in
            let custom = raw["kind"]?.stringValue == "custom"
            let viaConnection = raw["keySource"]?.stringValue == "connection"
            let service = StoredSearchService(
                id: raw["id"]?.stringValue ?? "",
                kind: custom ? .custom : (viaConnection ? .reuseConnection : .preset),
                serviceId: raw["serviceId"]?.stringValue,
                regionId: raw["regionId"]?.stringValue,
                boundHost: raw["boundHost"]?.stringValue,
                connectionRef: raw["connectionRef"]?.stringValue,
                name: raw["name"]?.stringValue,
                address: raw["address"]?.stringValue,
                protocolID: raw["protocol"]?.stringValue,
                resultCount: raw["resultCount"]?.safeIntegerValue
            )
            let hasKey = raw["hasKey"]?.boolValue == true
            let entry = custom ? nil : entries.first { $0["id"]?.stringValue == service.serviceId }
            let row = SearchSettings.searchServiceRowState(
                service: service.rowInput(hasKey: hasKey),
                catalogAvailable: !entries.isEmpty,
                entry: entry,
                withdrawn: false,
                connections: connections
            )
            let displayName = SearchSettings.searchServiceDisplayName(
                kind: custom ? .custom : .preset,
                name: service.name,
                serviceId: service.serviceId,
                catalogDisplayName: names[service.serviceId ?? ""]
            )
            return WebSearchServiceItem(
                service: service, entry: entry, row: row, displayName: displayName,
                keyTail: hasKey ? raw["keyLast4"]?.stringValue : nil
            )
        }
        let defaultID = SearchSettings.resolveDefaultSearchService(
            serviceIds: items.map(\.id), storedDefault: manifest["defaultServiceId"]?.stringValue
        )
        return Staged(items: items, defaultID: defaultID, connections: connections, entries: entries, catalogNames: names)
    }

    /// Manifest test (searchTestPresentation input) → production display result.
    static func presentation(_ outcome: SearchJSON) -> SearchTestPresentation {
        if outcome["ok"]?.boolValue == true {
            return SearchSettings.searchTestPresentation(.passed(
                count: outcome["count"]?.safeIntegerValue ?? 0,
                latencyMs: outcome["latencyMs"]?.safeIntegerValue ?? 0
            ))
        }
        let card = outcome["error"]?["card"].flatMap { card -> SearchErrorCard? in
            guard let headline = card["headline"]?.stringValue, let action = card["primaryAction"]?.stringValue else { return nil }
            return SearchErrorCard(headline: headline, primaryAction: action, secondaryAction: nil)
        }
        return SearchSettings.searchTestPresentation(.failed(errorClass: outcome["error"]?["errorClass"]?.stringValue, card: card))
    }

    // MARK: - Manifest location

    /// The manifest is not in the bundle: the simulator process can read host files, so walk up from this source file to the repository root that contains `shared/`.
    static func manifestURL(sourceFile: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            var isDirectory: ObjCBool = false
            let shared = directory.appendingPathComponent("shared")
            if FileManager.default.fileExists(atPath: shared.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return shared.appendingPathComponent("test-fixtures/shots/webSearch.v1.json")
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func report(_ message: String) {
        print("[WebSearchShots] \(message)")
    }
}

/// Host for the model options staging: the production panel shell + production panel; tapping "Search method" / "Switch service" opens the production "Search method" sheet.
struct WebSearchShotModelOptionsHost: View {
    let shot: WebSearchShots.ModelOptions

    @State private var path: [ModelControlsRoute] = []

    var body: some View {
        ModelOptionsSheetScaffold(path: $path) {
            ModelOptionsPanel(model: ModelOptionsPanelModel.make(shot.facts)) { action in
                if case .open(.pickSearchSource, _) = action { path = [.searchSource] }
            }
        } destination: { _ in
            SearchSourcePickerSheet(
                items: shot.pickerItems, services: shot.services, modelName: shot.modelName,
                onPickNative: {}, onPickService: { _ in }, onAdd: {}
            )
        }
        .onAppear { if shot.opensPicker { path = [.searchSource] } }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }
}
#endif
