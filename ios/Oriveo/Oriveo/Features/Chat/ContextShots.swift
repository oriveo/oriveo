#if DEBUG
import CryptoKit
import Foundation
import GRDB
import OriveoProviderKit

/// Debug direct-open pages for the context page family: used for screenshot samples; nothing from this file exists in Release builds.
///
/// Usage: `xcrun simctl launch <udid> ai.oriveo.community -AUTO_OPEN_PAGE <page name>`; page names are listed in `Shot`.
/// When launched with these page names the whole process uses an in-memory `AppState` (`OriveoApp.init` goes through `seedDemoData` according to `isRequested`).
///
/// Data is read only from the manifest shared by all platforms (`test-fixtures/shots/context.v1.json` in the shared directory); when it cannot be read or a field is missing, opening is refused and no hard-coded values are used as a fallback:
/// - Window / output limit / price line / prices are taken only from `models[].entry`, assembled into the metadata catalog shape and pinned into metadata resolution through the production decoder
///   (`MetadataClient.pinCatalogForShots`); models are built by the production `CatalogModelBuilder`, and B is derived by the production window formula.
/// - Ledger rows are built through the production `ContextManifest` decoder and checkpoints through the production `ContextCheckpoint.serialize`,
///   written with the production `appendManifest` / `save` into isolated partitions in a temporary directory (`ContextLedgerStore.shotsPool` /
///   `ContextCompactionStore.shotsPool`); the real database is never read or written and the network is never touched.
///
/// Private page state cannot be set up from outside, so each page got a `#if DEBUG` injection point (marked "screenshots only" next to it):
/// 1. `MetadataClient.resolveCatalogModel`:when a fixture catalog is pinned, providers in the fixture resolve only from the fixture.
/// 2. `ContextLedgerStore.forPartition` / `ContextCompactionStore.forPartition`: return the isolated partition.
/// 3. `ChatView.onAppear`:when `takeOverlay` yields an upper layer, open the checkpoint detail / context panel / conversation settings through the production entries.
/// 4. `ContextUsagePanelSheet.onAppear`:when `takeCapPicker` is true, push the production "This conversation's limit" picker page.
/// The third-compaction notice goes through the production `ChatManager.noteCompactionLanded` (which decides by the row count in the isolated store);
/// suggestion bars use the production state (`directiveSuggestions`, `memorySuggestions`);
/// the confirmation dialog is computed by the production `ContextCapConfirmPresentation.prompt` from the fixture confirm input, held by the production coordinator and then presented by the chat page;
/// the settings page pushes Settings > Context (the `.contextSettings` route).
enum ContextShots {
    enum Shot: String, CaseIterable {
        case contextDividerSummary, contextDividerVerbatim, contextCheckpointDetail, contextCompactHint
        case contextRingNormal, contextRingHigh, contextRingOver, contextRingHidden
        case contextIncompleteFooter, contextDirectiveSuggestion, contextMemorySuggestion
        case contextPanel, contextPanelPriceLine, contextPanelUnknown
        case contextCapPicker, contextCapPickerLarge, contextCapPickerCustom, contextSettings
        case contextConfirmOverCap, contextConfirmPriceLine, contextConversationSettings
    }

    /// The launch arguments name a page of this family.
    static var isRequested: Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-AUTO_OPEN_PAGE"), index + 1 < arguments.count else { return false }
        return Shot(rawValue: arguments[index + 1]) != nil
    }

    /// The layer to open above the chat page (manifest `open`).
    enum Overlay: String {
        case detail, panel, picker, conversationSettings, confirm
    }

    // MARK: - State read by the injection points

    /// The upper layer and conversation to open once the chat page is mounted; the picker opens the panel first, and the panel then pushes the picker page.
    private static var pendingOverlay: (conversationID: UUID, overlay: Overlay)?
    /// The conversation whose picker page is pushed once the panel is mounted.
    private static var pendingCapPicker: UUID?
    /// Fixture clock: the context panel's "Condensed N times · ..." relative time uses it as now (`ContextUsagePanelSheet.now`); nil = system clock.
    private(set) static var pinnedClock: Date?

    /// Pin this page's fixture clock to the panel's relative time; pass nil to unpin.
    static func pinClock(_ staged: Staged?) {
        pinnedClock = staged?.clock
    }

    /// Called when ChatView appears: if it is the conversation the sample names, take the upper layer to open (handed out only once).
    static func takeOverlay(conversationID: UUID?) -> Overlay? {
        guard let pending = pendingOverlay, pending.conversationID == conversationID else { return nil }
        pendingOverlay = nil
        return pending.overlay
    }

    /// Called when the context panel appears: if it is the conversation the sample names, take the flag and return true (handed out only once).
    static func takeCapPicker(conversationID: UUID) -> Bool {
        guard pendingCapPicker == conversationID else { return false }
        pendingCapPicker = nil
        return true
    }

    // MARK: - Entry

    static func open(_ shot: Shot, appState: AppState) async {
        // With a persistent store, switching connections and conversations would write into real conversations and the Keychain, so do not place them.
        guard !appState.prefersAuthoritativeConversationStore else {
            report("\(shot.rawValue): AppState is not in-memory; demo data was not injected")
            return
        }
        let staged: Staged
        let chat: Staged.Chat?
        var confirmPrompt: ContextCapConfirmPresentation.Prompt?
        do {
            staged = try stage(shot, manifestData: manifestData())
            try await writeIsolatedPartition(staged)
            chat = try await install(staged, into: appState)
            if let chat, chat.overlay == .confirm {
                confirmPrompt = try self.confirmPrompt(chat, in: appState)
                guard confirmPrompt != nil else { throw ManifestError.invalid("confirm dialog: production decided not to show it") }
            }
        } catch {
            report("\(shot.rawValue): \(error)")
            return
        }
        pinClock(staged)
        // The demo seed hard-codes the dark theme; samples follow the system, with light / dark decided by simctl appearance
        appState.preferences.theme = .system

        guard let chat else {
            // Settings > Context, preferences use defaults
            appState.selectedTab = .settings
            appState.navigation.reset(to: [])
            appState.navigation.reset(to: [.contextSettings])
            return
        }
        let conversationID = chat.conversation.id
        switch chat.overlay {
        case .confirm?, nil: break
        case let overlay?:
            pendingOverlay = (conversationID, overlay)
            if overlay == .picker { pendingCapPicker = conversationID }
        }

        // The chat page sits on the home stack: switch back to home first, wait for the home stack to mount, then open the conversation through the production entry (a push at launch would be overwritten by the root view's first-frame stack).
        appState.selectedTab = .home
        appState.navigation.reset(to: [])
        guard await waitUntil({ appState.navigation.path.isEmpty && appState.selectedTab == .home }) else { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if let query = chat.initialScrollQuery {
            // Separator page: use the production search jump to bring the row that hosts the separator (the first one after the covered range) just below the navigation bar, instead of staying at the bottom and being covered by it.
            appState.pendingSearchScrollTarget = PendingSearchScrollTarget(conversationID: conversationID, query: query)
        }
        appState.openChat(conversationID: conversationID)

        // Opening a conversation clears pending suggestions, so the notice bar and suggestion bars are placed after opening.
        appState.chatManager.noteCompactionLanded(conversationID: conversationID, uid: appState.sessionPartitionUID)
        if let directive = chat.directive {
            appState.directiveSuggestions.evaluate(
                text: directive.text,
                messageID: directive.messageID,
                conversationID: conversationID,
                instructions: chat.conversation.instructions,
                suggestion: MemoryIntent.classify(directive.text).suggestion
            )
        }
        if let memory = chat.memory {
            appState.memorySuggestions.awaitCandidate(messageID: memory.messageID, conversationID: conversationID)
            appState.memorySuggestions.present(
                memory.candidate,
                messageID: memory.messageID,
                conversationID: conversationID,
                latestAssistantMessageID: chat.conversation.messages.last(where: { $0.role == .assistant })?.id
            )
        }
        if let confirmPrompt {
            // The production coordinator holds this confirmation and the chat page's confirmation presenter shows it; in samples any button only dismisses it.
            let coordinator = appState.contextCapConfirmCoordinator
            let messageID = chat.conversation.messages.last(where: { $0.role == .assistant })?.id ?? conversationID
            Task { @MainActor in
                _ = await coordinator.request(confirmPrompt, conversationID: conversationID, messageID: messageID)
            }
        }
        if chat.overlay != nil, chat.overlay != .confirm {
            guard await waitUntil({ pendingOverlay == nil }) else {
                report("\(shot.rawValue): the chat page was not mounted, \(chat.overlay?.rawValue ?? "") did not open")
                return
            }
        }
        if chat.overlay == .picker {
            guard await waitUntil({ pendingCapPicker == nil }) else {
                report("\(shot.rawValue): the context panel was not mounted, the picker page was not pushed")
                return
            }
        }
    }

    /// Pin this page into the process: pin the fixture catalog into metadata resolution, write preferences into the in-memory state, and put the connection and conversation into AppState.
    /// Returns nil for the settings page (no chat page is opened). Only the in-memory state is touched; nothing is persisted.
    @MainActor
    static func install(_ staged: Staged, into appState: AppState) async throws -> Staged.Chat? {
        try MetadataClient.pinCatalogForShots(staged.catalogPayload)
        appState.preferences.contextAISummaryEnabled = staged.aiSummary
        appState.preferences.contextDefaultCap = staged.defaultCap
        appState.preferences.contextPriceLineReminderEnabled = staged.priceLineReminder

        guard let chat = staged.chat else { return nil }
        let model = await CatalogModelBuilder.buildCatalogModel(
            providerKind: chat.providerKind,
            runtimeModelId: chat.modelID,
            fallbackName: chat.modelName
        )
        let provider = Provider(
            id: chat.providerID,
            kind: chat.providerKind,
            status: .connected,
            models: [model],
            catalogModels: [model],
            lastCheckedAt: nil,
            apiKey: "",
            apiKeyPreview: "",
            lastError: nil,
            baseURLText: nil
        )
        // Replace the existing connections with the fixture connection.
        appState.providers = [provider]
        // All pages share one conversation id and the database keeps the previous page's messages: the production upsert does not delete old rows for an empty message list and does not change the model attribution of a message with the same id.
        // Delete every message that could appear in the manifest before writing this page, so each page sees only the conversation staged for it.
        appState.upsertConversationProjection(chat.conversation, deletingMessageIDs: chat.fixtureMessageIDs)
        return chat
    }

    /// Confirmation dialog: the fixture confirm's device-local conversation state goes into a separate UserDefaults domain that is deleted after use,
    /// and the production `ContextCapConfirmPresentation.prompt` computes the kind and cost from the conversation's current window, the reminder switch and the model prices.
    @MainActor
    static func confirmPrompt(_ chat: Staged.Chat, in appState: AppState) throws -> ContextCapConfirmPresentation.Prompt? {
        guard let confirm = chat.confirm else { throw ManifestError.invalid("the confirm page lacks confirm input") }
        let suite = "oriveo.shots.context.confirm"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ManifestError.invalid("could not create the confirmation state domain") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let conversationID = chat.conversation.id
        defaults.set(
            try JSONEncoder().encode(confirm.conversationState),
            forKey: ContextPriceLineConfirmStore.key(conversationID)
        )
        return ContextCapConfirmPresentation.prompt(
            in: appState,
            conversationID: conversationID,
            attempt: confirm.attempt,
            estimatedInput: confirm.estimatedInput,
            store: ContextPriceLineConfirmStore(defaults: defaults)
        )
    }

    // MARK: - Manifest to in-memory objects

    struct Staged {
        struct Directive {
            let messageID: UUID
            let text: String
        }

        struct MemorySuggestion {
            let messageID: UUID
            let candidate: MemoryCandidate
        }

        struct Confirm {
            let attempt: ContextCapConfirmPresentation.Attempt
            let estimatedInput: Int
            let conversationState: ContextCapConfirmPresentation.ConversationState
        }

        struct Chat {
            let providerID: UUID
            let providerKind: ProviderKind
            let modelID: String
            let modelName: String
            let conversation: Conversation
            /// The layer to open above the chat page; nil = open only the chat page.
            let overlay: Overlay?
            /// Fixture input of the confirmation dialog page (only the confirm page has it).
            let confirm: Confirm?
            /// The B derived by production under the current window (nil when the window is unknown).
            let currentB: Int?
            let directive: Directive?
            let memory: MemorySuggestion?
            /// All message ids that any page in the manifest might write into this conversation (conversation messages + each page's suggestion bar messages).
            let fixtureMessageIDs: Set<UUID>
            /// Initial position: the message body brought to the top through the production search jump when the conversation opens (separator page = the message that hosts the separator); nil = production lands at the bottom.
            let initialScrollQuery: String?
        }

        /// Catalog payload in the metadata shape (all fixture models).
        let catalogPayload: Data
        /// nil = settings page (no chat page is opened).
        let chat: Chat?
        /// Manifest clock.
        let clock: Date
        /// Ledger rows, old to new.
        let manifests: [ContextManifest]
        /// Checkpoint rows, old to new.
        let checkpoints: [ContextCheckpointRecord]
        let aiSummary: Bool
        let defaultCap: ContextBudgetCap
        let priceLineReminder: Bool
    }

    enum ManifestError: Error, CustomStringConvertible {
        case repositoryNotFound
        case invalid(String)

        var description: String {
            switch self {
            case .repositoryNotFound: "Walking up from the source file location did not find a repository root containing the shared directory"
            case let .invalid(reason): reason
            }
        }
    }

    /// The shape of the manifest; keys starting with `$` are notes and are not read. Model entries, ledger rows and limit values stay as JSON and are handed to the production decoders / parsers.
    struct Manifest: Decodable {
        struct Model: Decodable {
            let ref: String
            let provider: String
        }

        struct Message: Decodable {
            let id: String
            let createdAt: String
            let role: String
            let content: String
        }

        struct DemoConversation: Decodable {
            let id: String
            let title: String
            let createdAt: String
            let messages: [Message]
        }

        struct Checkpoint: Decodable {
            let kind: String
            let coversFrom: String
            let coversTo: String
            let summary: String?
            let createdAt: String
        }

        struct Page: Decodable {
            struct Preferences: Decodable {
                let aiSummary: Bool?
                let priceLineReminder: Bool?
            }

            struct Directive: Decodable {
                let createdAt: String
                let userId: String
                let user: String
                let assistantId: String
                let assistant: String
            }

            struct MemorySuggestion: Decodable {
                let createdAt: String
                let userId: String
                let user: String
                let assistantId: String
                let assistant: String
            }

            let name: String
            let model: String?
            let messages: String?
            let checkpoint: String?
            let compactionCount: Int?
            let manifest: String?
            let preferences: Preferences?
            let open: String?
            let lastAssistantStopReason: String?
            let directiveSuggestion: Directive?
            let memorySuggestion: MemorySuggestion?
            let instructions: String?
            let confirm: Confirm?
        }

        struct Confirm: Decodable {
            let attempt: String
            let estimatedInput: Int
            /// The shape is the production device-local confirmation state `{suppressed, acknowledged: {model, T} | null}`.
            let conversationState: ContextCapConfirmPresentation.ConversationState
        }

        let schema: String
        let clock: String
        let models: [Model]
        let conversation: DemoConversation
        let checkpoints: [String: Checkpoint]
        let pages: [Page]

        static func load(from data: Data) throws -> Manifest {
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.schema == "oriveo.shots.context/v1" else {
                throw ManifestError.invalid("schema is not oriveo.shots.context/v1: \(manifest.schema)")
            }
            return manifest
        }
    }

    /// Read the manifest and build everything this page needs; any failing step throws and the caller refuses to open.
    static func stage(_ shot: Shot, manifestData data: Data) throws -> Staged {
        let manifest = try Manifest.load(from: data)
        guard let pageIndex = manifest.pages.firstIndex(where: { $0.name == shot.rawValue }) else {
            throw ManifestError.invalid("The manifest has no page \(shot.rawValue)")
        }
        let page = manifest.pages[pageIndex]
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = root["models"] as? [[String: Any]],
              let rawManifests = root["manifests"] as? [String: Any],
              let rawPages = root["pages"] as? [[String: Any]],
              let rawCandidatePage = rawPages.first(where: { $0["name"] as? String == shot.rawValue })
        else {
            throw ManifestError.invalid("The manifest lacks models / manifests / pages")
        }
        let clockMs = try millis(manifest.clock, field: "clock")
        let clock = Date(timeIntervalSince1970: Double(clockMs) / 1000)
        let catalogPayload = try catalogPayload(models: manifest.models, rawModels: rawModels)

        let rawPreferences = rawCandidatePage["preferences"] as? [String: Any]
        let defaultCap = try cap(rawPreferences?["defaultCap"], field: "preferences.defaultCap") ?? .default
        let aiSummary = page.preferences?.aiSummary ?? false
        let priceLineReminder = page.preferences?.priceLineReminder ?? true

        guard page.open != "settings" else {
            return Staged(
                catalogPayload: catalogPayload, chat: nil, clock: clock, manifests: [], checkpoints: [],
                aiSummary: aiSummary, defaultCap: defaultCap, priceLineReminder: priceLineReminder
            )
        }

        guard let modelRef = page.model,
              let modelIndex = manifest.models.firstIndex(where: { $0.ref == modelRef }),
              let entry = rawModels[modelIndex]["entry"] as? [String: Any],
              let modelID = entry["id"] as? String
        else {
            throw ManifestError.invalid("\(shot.rawValue): model not found or its entry lacks id")
        }
        let providerKind = try providerKind(manifest.models[modelIndex].provider)
        guard let modelName = entry["displayName"] as? String else {
            throw ManifestError.invalid("Model \(modelRef) lacks displayName")
        }
        let providerID = uuid("provider-\(modelRef)")
        let conversationID = uuid(manifest.conversation.id)

        // Messages: manifest id to stable UUID; times come from the manifest createdAt, and for appended suggestion messages the user message is at its createdAt and the assistant 30 seconds later.
        let startMs = try millis(manifest.conversation.createdAt, field: "conversation.createdAt")
        var fixtureMessages: [(id: String, role: String, content: String, createdAt: Int64)] = []
        switch page.messages {
        case nil:
            fixtureMessages = try manifest.conversation.messages.map {
                ($0.id, $0.role, $0.content, try millis($0.createdAt, field: "messages.\($0.id).createdAt"))
            }
        case "none":
            break
        case let other?:
            throw ManifestError.invalid("pages.messages only accepts none: \(other)")
        }
        if let directive = page.directiveSuggestion {
            let at = try millis(directive.createdAt, field: "directiveSuggestion.createdAt")
            fixtureMessages += [
                (directive.userId, "user", directive.user, at),
                (directive.assistantId, "assistant", directive.assistant, at + 30_000)
            ]
        }
        if let memory = page.memorySuggestion {
            let at = try millis(memory.createdAt, field: "memorySuggestion.createdAt")
            fixtureMessages += [
                (memory.userId, "user", memory.user, at),
                (memory.assistantId, "assistant", memory.assistant, at + 30_000)
            ]
        }
        let lastAssistantStopReason = try page.lastAssistantStopReason.map { raw -> StopReason in
            guard let reason = StopReason(rawValue: raw) else {
                throw ManifestError.invalid("lastAssistantStopReason not recognized: \(raw)")
            }
            return reason
        }
        var messages = try fixtureMessages.map { fixture -> ChatMessage in
            guard let role = ChatRole(rawValue: fixture.role) else {
                throw ManifestError.invalid("Message \(fixture.id) has an unrecognized role: \(fixture.role)")
            }
            return ChatMessage(
                id: uuid("message-\(fixture.id)"),
                role: role,
                text: fixture.content,
                providerID: providerID,
                providerKind: providerKind,
                providerName: providerKind.displayName,
                modelID: role == .assistant ? modelID : nil,
                modelName: modelName,
                estimatedCost: 0,
                state: .delivered,
                createdAt: Date(timeIntervalSince1970: Double(fixture.createdAt) / 1000)
            )
        }
        if let lastAssistantStopReason {
            guard let index = messages.firstIndex(where: { $0.id == uuid("message-a6") }) else {
                throw ManifestError.invalid("lastAssistantStopReason has no a6 to attach to")
            }
            messages[index].stopReason = lastAssistantStopReason
        }
        let messageIDs = Dictionary(uniqueKeysWithValues: fixtureMessages.map { ($0.id, uuid("message-\($0.id)")) })
        let fixtureMessageIDs = Set(
            (manifest.conversation.messages.map(\.id) + manifest.pages.flatMap { other in
                [other.directiveSuggestion?.userId, other.directiveSuggestion?.assistantId,
                 other.memorySuggestion?.userId, other.memorySuggestion?.assistantId].compactMap { $0 }
            }).map { uuid("message-\($0)") }
        )

        var conversation = Conversation(
            id: conversationID,
            title: manifest.conversation.title,
            providerID: providerID,
            providerKind: providerKind,
            modelID: modelID,
            previewText: messages.last?.text ?? "",
            estimatedCost: 0,
            isDraft: false,
            messages: messages,
            draftText: ""
        )
        conversation.hasCustomTitle = true
        conversation.createdAt = Date(timeIntervalSince1970: Double(startMs) / 1000)
        conversation.updatedAt = messages.last?.createdAt ?? conversation.createdAt
        conversation.instructions = page.instructions.map(ConversationInstructions.normalize) ?? ""
        conversation.contextCap = try cap(rawCandidatePage["conversationCap"], field: "conversationCap")

        // Current window: the fixture entry goes through production metadata decoding and resolution, then the production window formula derives O / B (the same as the send path).
        // The price line is read from shared metadata by the production `ChatRequestBuilder.priceLineTokens`, with the fixture catalog temporarily pinned during derivation.
        try MetadataClient.pinCatalogForShots(catalogPayload)
        defer { try? MetadataClient.pinCatalogForShots(nil) }
        let resolved = try MetadataClient.resolveShotsCatalogModel(
            catalogPayload, modelID: modelID, providerKind: providerKind
        )
        let budget = ContextBudget.window(ChatRequestBuilder.contextWindowInput(
            providerKind: providerKind,
            model: AIModel(
                id: modelID,
                name: modelName,
                capabilities: [.text],
                reasoningModeAvailable: false,
                isAvailable: true,
                isDefault: false,
                priceTier: "",
                contextLength: resolved?.contextLength,
                maxOutputTokens: resolved?.maxOutputTokens
            ),
            budgetCap: conversation.contextCap ?? defaultCap
        ))

        // Ledger row: one minute before the manifest clock, recorded on the last assistant message; W / B come from the fixture ledger and O from production derivation.
        var manifests: [ContextManifest] = []
        if let name = page.manifest {
            guard let raw = rawManifests[name] as? [String: Any] else {
                throw ManifestError.invalid("The manifest has no ledger \(name)")
            }
            let ledger = try ledgerManifest(
                raw, name: name, conversationId: conversationID.uuidString, transport: providerKind.rawValue,
                model: modelID, O: budget.O, createdAt: clockMs - 60_000
            )
            manifests = [ledger]
        }

        // checkpoint: the latest one follows the manifest; when compactionCount > 1 the earlier ones cover shorter prefixes (u1..a2 / u1..a3,
        // same serializer, same createdAt).
        var checkpoints: [ContextCheckpointRecord] = []
        if let kindName = page.checkpoint {
            guard let fixture = manifest.checkpoints[kindName] else {
                throw ManifestError.invalid("The manifest has no checkpoint \(kindName)")
            }
            guard let B = budget.B else { throw ManifestError.invalid("the checkpoint page window is unknown, so B cannot be derived") }
            let count = page.compactionCount ?? 1
            guard let coversToIndex = messages.firstIndex(where: { $0.id == messageIDs[fixture.coversTo] }),
                  messageIDs[fixture.coversFrom] == messages.first?.id
            else {
                throw ManifestError.invalid("checkpoint covered range is not in the conversation: \(fixture.coversFrom)..\(fixture.coversTo)")
            }
            let assistantIndexes = messages.indices.filter { $0 <= coversToIndex && messages[$0].role == .assistant }
            guard count >= 1, assistantIndexes.count >= count else {
                throw ManifestError.invalid("compactionCount exceeds the number of coverable turns: \(count)")
            }
            let createdAt = try millis(fixture.createdAt, field: "checkpoints.\(kindName).createdAt")
            for endIndex in assistantIndexes.suffix(count) {
                checkpoints.append(try checkpointRecord(
                    fixture,
                    conversationId: conversationID.uuidString,
                    messages: Array(messages[0...endIndex]),
                    B: B,
                    model: modelID,
                    createdAt: createdAt
                ))
            }
        }

        // Separator page: the separator hangs at the top of the row right after the last covered message, and the initial position is that row.
        var initialScrollQuery: String?
        if shot == .contextDividerSummary || shot == .contextDividerVerbatim {
            guard let kindName = page.checkpoint, let fixture = manifest.checkpoints[kindName],
                  let anchorIndex = messages.firstIndex(where: { $0.id == messageIDs[fixture.coversTo] }),
                  anchorIndex + 1 < messages.count
            else {
                throw ManifestError.invalid("\(shot.rawValue): there is no message after the covered range, so the separator has nowhere to hang")
            }
            initialScrollQuery = messages[anchorIndex + 1].text
        }

        let overlay = try page.open.map { raw -> Overlay in
            guard let overlay = Overlay(rawValue: raw) else { throw ManifestError.invalid("open not recognized: \(raw)") }
            return overlay
        }
        var confirm: Staged.Confirm?
        if overlay == .confirm {
            guard let fixture = page.confirm,
                  let attempt = ContextCapConfirmPresentation.Attempt(rawValue: fixture.attempt)
            else {
                throw ManifestError.invalid("the confirm page lacks confirm input or attempt is not recognized")
            }
            confirm = Staged.Confirm(
                attempt: attempt,
                estimatedInput: fixture.estimatedInput,
                conversationState: fixture.conversationState
            )
        }

        var directive: Staged.Directive?
        if let fixture = page.directiveSuggestion, let id = messageIDs[fixture.userId] {
            directive = Staged.Directive(messageID: id, text: fixture.user)
        }
        var memory: Staged.MemorySuggestion?
        if let fixture = page.memorySuggestion, let id = messageIDs[fixture.assistantId] {
            guard let rawSuggestion = rawCandidatePage["memorySuggestion"] as? [String: Any],
                  var rawCandidate = rawSuggestion["candidate"] as? [String: Any]
            else {
                throw ManifestError.invalid("memorySuggestion lacks candidate")
            }
            // The candidate is built on the manifest clock (the same production decoding path as the memory page family).
            rawCandidate["createdAt"] = manifest.clock
            memory = Staged.MemorySuggestion(
                messageID: id,
                candidate: try MemoryShots.candidate(rawCandidate, clockMs: clockMs)
            )
        }

        return Staged(
            catalogPayload: catalogPayload,
            chat: Staged.Chat(
                providerID: providerID,
                providerKind: providerKind,
                modelID: modelID,
                modelName: modelName,
                conversation: conversation,
                overlay: overlay,
                confirm: confirm,
                currentB: budget.B,
                directive: directive,
                memory: memory,
                fixtureMessageIDs: fixtureMessageIDs,
                initialScrollQuery: initialScrollQuery
            ),
            clock: clock,
            manifests: manifests,
            checkpoints: checkpoints,
            aiSummary: aiSummary,
            defaultCap: defaultCap,
            priceLineReminder: priceLineReminder
        )
    }

    /// Fixture model entry to the metadata catalog shape (providers.<backend key>.models / resolveMap), with the entry placed in as is.
    static func catalogPayload(models: [Manifest.Model], rawModels: [[String: Any]]) throws -> Data {
        var providers: [String: [String: Any]] = [:]
        for (index, model) in models.enumerated() {
            guard let entry = rawModels[index]["entry"] as? [String: Any], let id = entry["id"] as? String else {
                throw ManifestError.invalid("models[\(index)].entry lacks id")
            }
            let key = model.provider
            var provider = providers[key] ?? ["models": [String: Any](), "resolveMap": [String: String]()]
            var entries = provider["models"] as? [String: Any] ?? [:]
            var resolveMap = provider["resolveMap"] as? [String: String] ?? [:]
            entries[id] = entry
            resolveMap[id] = id
            provider["models"] = entries
            provider["resolveMap"] = resolveMap
            providers[key] = provider
        }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "providers": providers])
    }

    /// The fixture provider key is the provider key of the server metadata catalog, identical to ProviderKind.rawValue here, so use it directly.
    static func providerKind(_ name: String) throws -> ProviderKind {
        guard let kind = ProviderKind(rawValue: name) else { throw ManifestError.invalid("fixture provider not recognized: \(name)") }
        return kind
    }

    /// Ledger row to the production `ContextManifest` decoder; basis depends on whether observedInput exists.
    static func ledgerManifest(
        _ raw: [String: Any],
        name: String,
        conversationId: String,
        transport: String,
        model: String,
        O: Int,
        createdAt: Int64
    ) throws -> ContextManifest {
        guard let estimatedInput = raw["estimatedInput"] as? Int, let segments = raw["segments"] as? [Any] else {
            throw ManifestError.invalid("Ledger \(name) lacks estimatedInput / segments")
        }
        let observed = raw["observedInput"] as? Int
        let object: [String: Any] = [
            "requestId": "shots-\(name)",
            "conversationId": conversationId,
            "purpose": RequestPurpose.chat.rawValue,
            "transport": transport,
            "model": model,
            "W": raw["W"] ?? NSNull(),
            "O": O,
            "B": raw["B"] ?? NSNull(),
            "basis": (observed == nil ? ContextEstimateBasis.estimated : .observed).rawValue,
            "estimatedInput": estimatedInput,
            "observedInput": observed ?? NSNull(),
            "segments": segments,
            "unansweredMerged": 0,
            "reminder": false,
            "stopReason": raw["stopReason"] ?? NSNull(),
            "createdAt": createdAt
        ]
        do {
            return try JSONDecoder().decode(ContextManifest.self, from: JSONSerialization.data(withJSONObject: object))
        } catch {
            throw ManifestError.invalid("Ledger \(name) failed to decode: \(error)")
        }
    }

    /// checkpoint row: covers the whole `messages` range, user messages are picked by the production `pickUserMessages` and the body is assembled by the production `serialize`;
    /// summary is carried only by the summary kind.
    static func checkpointRecord(
        _ fixture: Manifest.Checkpoint,
        conversationId: String,
        messages: [ChatMessage],
        B: Int,
        model: String,
        createdAt: Int64
    ) throws -> ContextCheckpointRecord {
        guard let kind = ContextCheckpointRecord.Kind(rawValue: fixture.kind),
              let first = messages.first, let last = messages.last
        else {
            throw ManifestError.invalid("checkpoint kind not recognized or covered range is empty: \(fixture.kind)")
        }
        let summary = kind == .summary ? fixture.summary : nil
        if kind == .summary, summary == nil { throw ManifestError.invalid("summary checkpoint lacks summary") }
        // ρHi uses the production default calibration (no samples).
        let kept = ContextCheckpoint.pickUserMessages(
            candidates: messages.filter { $0.role == .user }.map {
                ContextCheckpoint.Candidate(id: $0.id.uuidString, text: $0.text)
            },
            B: B,
            rhoHi: RhoCalibration().rhoHi
        )
        let coversFrom = first.id.uuidString
        let coversTo = last.id.uuidString
        return ContextCheckpointRecord(
            conversationId: conversationId,
            checkpointId: ContextCheckpoint.checkpointId(conversationId: conversationId, coversTo: coversTo),
            kind: kind,
            coversFrom: coversFrom,
            coversTo: coversTo,
            coversDigest: ContextCheckpoint.coversDigest(messages.map { .init(id: $0.id.uuidString, text: $0.text) }),
            messagesCovered: messages.count,
            userMessageIds: kept.map(\.id),
            text: ContextCheckpoint.serialize(
                coversFrom: coversFrom, coversTo: coversTo, messagesCovered: messages.count, kept: kept, summary: summary
            ),
            summary: summary,
            language: nil,
            model: model,
            packerVersion: ContextCheckpoint.packerVersion,
            createdAt: createdAt,
            cost: nil
        )
    }

    /// Limit values go through the production `ContextBudgetCap.parse`; a missing key or null is nil (follow the level above), and anything else unparseable is rejected.
    private static func cap(_ raw: Any?, field: String) throws -> ContextBudgetCap? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let cap = ContextBudgetCap.parse(raw) else { throw ManifestError.invalid("\(field) is not a valid limit: \(raw)") }
        return cap
    }

    private static func millis(_ text: String, field: String) throws -> Int64 {
        guard let date = MemoryEpisodicTime.parse(text) else { throw ManifestError.invalid("\(field) is not RFC 3339: \(text)") }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Manifest id to stable UUID (the same on every launch, so samples can be compared).
    static func uuid(_ name: String) -> UUID {
        var bytes = Array(Insecure.MD5.hash(data: Data("oriveo.shots.context/\(name)".utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Isolated partitions

    /// Create a database in a temporary directory with only these two tables, write into it through the production `appendManifest` / `save`, and then hand it to the two stores' injection points.
    /// Building and filling the database run in the background (the main thread never waits for the write lock); once built it is
    /// handed to the two stores' injection points on the caller's thread.
    static func writeIsolatedPartition(_ staged: Staged) async throws {
        let conversationId = staged.chat?.conversation.id.uuidString
        let manifests = staged.manifests
        let checkpoints = staged.checkpoints
        let pool = try await Task.detached(priority: .userInitiated) {
            try buildIsolatedPartition(conversationId: conversationId, manifests: manifests, checkpoints: checkpoints)
        }.value
        ContextLedgerStore.shotsPool = pool
        ContextCompactionStore.shotsPool = pool
    }

    private nonisolated static func buildIsolatedPartition(
        conversationId: String?,
        manifests: [ContextManifest],
        checkpoints: [ContextCheckpointRecord]
    ) throws -> DatabasePool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("context-shots", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("context.sqlite").path)
        try pool.write { db in
            // Both tables have a foreign key to conversation(id): the isolated database creates only that column and holds the one row of the sample conversation.
            try db.execute(sql: "CREATE TABLE conversation (id TEXT PRIMARY KEY NOT NULL)")
            if let conversationId {
                try db.execute(sql: "INSERT INTO conversation (id) VALUES (?)", arguments: [conversationId])
            }
            try ContextLedgerStore.createTables(in: db)
            try ContextCompactionStore.createTables(in: db)
        }
        let ledger = ContextLedgerStore(dbPool: pool)
        for manifest in manifests { try ledger.appendManifest(manifest) }
        let compaction = ContextCompactionStore(dbPool: pool)
        for record in checkpoints { try compaction.save(record) }
        return pool
    }

    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 40 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    // MARK: - Manifest location

    /// The manifest is not in the bundle: the simulator process can read host files, so walk up from this source file location to the repository root that contains the shared directory.
    static func manifestURL(sourceFile: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            var isDirectory: ObjCBool = false
            let shared = directory.appendingPathComponent("shared")
            if FileManager.default.fileExists(atPath: shared.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return shared.appendingPathComponent("test-fixtures/shots/context.v1.json")
            }
            directory.deleteLastPathComponent()
        }
        throw ManifestError.repositoryNotFound
    }

    static func manifestData() throws -> Data {
        try Data(contentsOf: manifestURL())
    }

    private static func report(_ message: String) {
        print("[ContextShots] \(message)")
    }
}
#endif
