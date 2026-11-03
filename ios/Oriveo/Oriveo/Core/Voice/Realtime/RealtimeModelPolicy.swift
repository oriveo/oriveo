import Foundation

/// Pure rules for the realtime voice model: failure classification, capability projection when a realtime model is selected, picker rows, legacy user migration, and session lifecycle.
/// No IO and no clock. Each branch mirrors the same-named function in the reference implementation,
/// and is checked case by case against shared/voice-contracts/realtime-model.v1.json.
enum RealtimeModelPolicy {
    enum Constants {
        static let connectTimeoutMs = 10_000
        static let uplinkBacklogMs = 8_000
        /// Number of automatic reopens with history after an unexpected disconnect (Gemini uses its existing handle reconnect instead, up to geminiHandleReconnects times)
        static let autoReopenAttempts = 1
        static let geminiHandleReconnects = 4
    }

    // MARK: - Failure classification

    enum FailureCategory: String, CaseIterable, Sendable {
        case auth, quota
        case modelGone = "model_gone"
        case maxDuration = "max_duration"
        case network, unknown
    }

    enum FailureAction: String, CaseIterable, Sendable {
        case openConnection, retry, switchModel, continueWithHistory
    }

    /// What the copy placeholder is filled with: provider = provider display name, model = catalog model, none = no placeholder
    enum FailureCopyArg: String, Sendable {
        case provider, model, none
    }

    /// Normalized signals the host collects on connection failure or unexpected session end; all optional, unknown fields are dropped.
    struct FailureSignal: Equatable, Sendable {
        var httpStatus: Int?
        var errorCode: String?
        var endedReason: String?
        var catalogHasModel: Bool?
        var elapsedSec: Double?
        /// Per-session limit given by the catalog; nil = no limit, duration is not checked.
        var maxSessionSec: Double?
        var connectError: Bool?
        var connectTimedOut: Bool?
        var reopenFailed: Bool?
        var uplinkBacklogMs: Double?

        init(
            httpStatus: Int? = nil, errorCode: String? = nil, endedReason: String? = nil,
            catalogHasModel: Bool? = nil, elapsedSec: Double? = nil, maxSessionSec: Double? = nil,
            connectError: Bool? = nil, connectTimedOut: Bool? = nil, reopenFailed: Bool? = nil,
            uplinkBacklogMs: Double? = nil
        ) {
            self.httpStatus = httpStatus
            self.errorCode = errorCode
            self.endedReason = endedReason
            self.catalogHasModel = catalogHasModel
            self.elapsedSec = elapsedSec
            self.maxSessionSec = maxSessionSec
            self.connectError = connectError
            self.connectTimedOut = connectTimedOut
            self.reopenFailed = reopenFailed
            self.uplinkBacklogMs = uplinkBacklogMs
        }
    }

    struct FailureClassification: Equatable, Sendable {
        let category: FailureCategory
        let copyKey: String
        let copyArg: FailureCopyArg
        let actions: [FailureAction]
        /// One-to-one with actions; continueWithHistory is the tap orb itself and has no button label (nil).
        let actionCopyKeys: [String?]
        /// Failure card buttons, left to right: secondary actions first, primary action (actions[0]) last; actions without button text (the tap orb) show no button.
        let buttonCopyKeys: [String]
    }

    static func buttonCopyKeys(for actions: [FailureAction]) -> [String] {
        actions.reversed().compactMap { copyKey(for: $0) }
    }

    static func actions(for category: FailureCategory) -> [FailureAction] {
        switch category {
        case .auth: [.openConnection]
        case .quota: [.retry, .switchModel]
        case .modelGone: [.switchModel]
        case .maxDuration: [.continueWithHistory]
        case .network: [.retry]
        case .unknown: [.retry, .switchModel]
        }
    }

    static func copyKey(for category: FailureCategory) -> String {
        "voice_realtime_failure_\(category.rawValue)"
    }

    static func copyArg(for category: FailureCategory) -> FailureCopyArg {
        switch category {
        case .auth, .quota: .provider
        case .maxDuration: .none
        case .modelGone, .network, .unknown: .model
        }
    }

    static func copyKey(for action: FailureAction) -> String? {
        switch action {
        case .openConnection: "voice_realtime_action_open_connection"
        case .retry: "voice_realtime_action_retry"
        case .switchModel: "voice_realtime_action_switch_model"
        case .continueWithHistory: nil
        }
    }

    /// Takes the first match in the order auth → quota → model_gone → max_duration → network → unknown.
    static func classifyFailure(_ signal: FailureSignal) -> FailureClassification {
        let category = category(of: signal)
        let actions = actions(for: category)
        return FailureClassification(
            category: category,
            copyKey: copyKey(for: category),
            copyArg: copyArg(for: category),
            actions: actions,
            actionCopyKeys: actions.map { copyKey(for: $0) },
            buttonCopyKeys: buttonCopyKeys(for: actions)
        )
    }

    private static func category(of signal: FailureSignal) -> FailureCategory {
        let http = signal.httpStatus
        let code = signal.errorCode
        if http == 401 || http == 403 || code == "invalid_api_key" { return .auth }
        if http == 429 || code == "insufficient_quota" || code == "rate_limit_exceeded" { return .quota }
        // Reopen handshake failure: 404 / model_not_found is not model removal; falls through to network below and does not refetch the catalog.
        let reopenFailed = signal.reopenFailed == true
        if !reopenFailed && (http == 404 || code == "model_not_found") { return .modelGone }
        if signal.catalogHasModel == false { return .modelGone }
        if signal.endedReason == "max_duration" || signal.endedReason == "timeout" { return .maxDuration }
        if let limit = signal.maxSessionSec, let elapsed = signal.elapsedSec, elapsed >= limit { return .maxDuration }
        if signal.connectError == true || signal.connectTimedOut == true || signal.reopenFailed == true { return .network }
        // Backlog must be strictly greater than the limit to count as network (equal to the limit goes to unknown).
        if let backlog = signal.uplinkBacklogMs, backlog > Double(Constants.uplinkBacklogMs) { return .network }
        return .unknown
    }

    // MARK: - Unexpected disconnect handling

    /// drop = unexpected disconnect after Ready; reopenFailed = handshake failure of an automatic reopen.
    enum DropStage: String, Sendable { case drop, reopenFailed }

    /// reopen = reopen with history; end = fail and end with code; dormant = mute and sleep; handleReconnect = Gemini resumes via the existing handle.
    enum DropAction: String, Sendable { case reopen, end, dormant, handleReconnect }

    struct DropOutcome: Equatable, Sendable {
        let action: DropAction
        /// Failure category when ending (FailureCategory.rawValue); nil when not ending.
        let code: String?
        let refetchCatalog: Bool
    }

    /// Unexpected disconnect handling: reopen handshake failure → end with network and do not refetch the catalog; Gemini resumes via the handle;
    /// categories that reopen cannot fix end immediately; a disconnect after a reopen with no progress ends with unknown (checked before the mute check); muted → dormant; otherwise reopen with history.
    /// provider = provider kind (openAI / xai / gemini); reopenedWithoutProgress = this connection came from an automatic reopen and has made no turn progress since Ready.
    static func afterDrop(
        stage: DropStage = .drop, provider: String, category: FailureCategory = .unknown,
        muted: Bool = false, reopenedWithoutProgress: Bool = false
    ) -> DropOutcome {
        if stage == .reopenFailed { return DropOutcome(action: .end, code: FailureCategory.network.rawValue, refetchCatalog: false) }
        if provider == "gemini" { return DropOutcome(action: .handleReconnect, code: nil, refetchCatalog: false) }
        guard category == .network || category == .unknown else {
            return DropOutcome(action: .end, code: category.rawValue, refetchCatalog: false)
        }
        if reopenedWithoutProgress { return DropOutcome(action: .end, code: FailureCategory.unknown.rawValue, refetchCatalog: false) }
        if muted { return DropOutcome(action: .dormant, code: nil, refetchCatalog: false) }
        return DropOutcome(action: .reopen, code: nil, refetchCatalog: false)
    }

    // MARK: - Capability projection

    enum ModelKind: String, Sendable { case text, realtime }

    /// stage = voice stage; typing = typing mode (same realtime model).
    enum ComposerMode: String, Sendable { case stage, typing }

    struct Capability: Equatable, Sendable {
        let attachments: String
        let attachmentsReasonKey: String?
        let webSearch: String
        let webSearchReasonKey: String?
        let thinking: String
        let thinkingReasonKey: String?
        let tools: String
        let toolsReasonKey: String?
        let sendsTools: Bool
        let regenerateEdit: String
        let setAsDefault: String
        let writesLastUsedModel: Bool
        let dictation: String
        let voiceEntry: String
        /// Vision and file tiles and the capability summary in the model options panel: realtime models hidden, text models default.
        let visionTile: String
        let fileTile: String
        let panelSummary: String
    }

    /// UI capability projection when a model is selected.
    static func capability(modelKind: ModelKind, mode: ComposerMode) -> Capability {
        guard modelKind == .realtime else {
            return Capability(
                attachments: "default", attachmentsReasonKey: nil,
                webSearch: "default", webSearchReasonKey: nil,
                thinking: "default", thinkingReasonKey: nil,
                tools: "default", toolsReasonKey: nil, sendsTools: true,
                regenerateEdit: "default", setAsDefault: "default", writesLastUsedModel: true,
                dictation: "available", voiceEntry: "cascade",
                visionTile: "default", fileTile: "default", panelSummary: "default"
            )
        }
        let typing = mode == .typing
        return Capability(
            attachments: typing ? "disabledWithReason" : "hidden",
            attachmentsReasonKey: typing ? "voice_realtime_no_attachments" : nil,
            webSearch: "statusLine", webSearchReasonKey: "voice_realtime_no_web_search",
            thinking: "statusLine", thinkingReasonKey: "voice_realtime_no_thinking",
            tools: typing ? "disabledTappable" : "hidden",
            toolsReasonKey: typing ? "voice_realtime_no_tools" : nil,
            sendsTools: false,
            regenerateEdit: "hidden",
            setAsDefault: "notOffered",
            writesLastUsedModel: false,
            dictation: typing ? "available" : "hidden",
            voiceEntry: typing ? "backToStage" : "stage",
            visionTile: "hidden", fileTile: "hidden", panelSummary: "hidden"
        )
    }

    // MARK: - Connections and catalog (input shared by picker and migration)

    /// subscription = subscription login of an official connection (not the user own key; does not count as realtime).
    enum ConnectionAuth: String, Sendable { case apiKey, subscription, relay, managed, free }

    struct TextModel: Equatable, Sendable {
        let model: String
        let webSearch: Bool
        let thinking: Bool
    }

    struct Connection: Equatable, Sendable {
        let id: String
        let providerKind: String
        let auth: ConnectionAuth
        let textModels: [TextModel]
    }

    /// One item of the catalog realtime[]; isDefault sorts first in the picker.
    struct RealtimeCatalogEntry: Equatable, Sendable {
        let model: String
        let isDefault: Bool
    }

    /// providerKind → that provider realtime models (catalog order).
    typealias RealtimeCatalog = [String: [RealtimeCatalogEntry]]

    // MARK: - Picker realtime rows

    enum PickerContext: String, Sendable { case chat, home, crosscheck }

    enum PickerFilter: String, Sendable { case realtime, webSearch, thinking }

    struct PickerInput: Equatable, Sendable {
        var context: PickerContext
        var filters: [PickerFilter] = []
        var connections: [Connection] = []
        var realtimeCatalog: RealtimeCatalog = [:]
        /// Currently selected item (realtime or text); nil if none.
        var selected: PickerSelected?
    }

    struct PickerSelected: Equatable, Sendable {
        let connectionId: String
        let model: String
    }

    /// The listed row that is checked.
    struct SelectedRow: Equatable, Sendable {
        let connectionId: String
        let model: String
        let kind: ModelKind
    }

    struct PickerRow: Equatable, Sendable {
        let model: String
        let kind: ModelKind
    }

    struct PickerGroup: Equatable, Sendable {
        let connectionId: String
        let rows: [PickerRow]
    }

    struct PickerResult: Equatable, Sendable {
        let showsRealtimeFilter: Bool
        let groups: [PickerGroup]
        /// nil when the selected item is not listed (connection missing, row filtered out, or absent).
        let selectedRow: SelectedRow?
    }

    /// Picker rows: realtime rows come only from official apiKey connections × catalog realtime[]; crosscheck does not list them;
    /// they follow that connection text rows, isDefault first, the rest in catalog order; showsRealtimeFilter only checks whether any realtime row exists,
    /// a realtime filter passed while hidden is ignored; filters intersect, and groups left empty after filtering are removed.
    static func pickerRows(_ input: PickerInput) -> PickerResult {
        func realtimeOf(_ conn: Connection) -> [PickerRow] {
            guard input.context != .crosscheck, conn.auth == .apiKey else { return [] }
            let list = input.realtimeCatalog[conn.providerKind] ?? []
            return (list.filter(\.isDefault) + list.filter { !$0.isDefault })
                .map { PickerRow(model: $0.model, kind: .realtime) }
        }
        let showsRealtimeFilter = input.connections.contains { !realtimeOf($0).isEmpty }
        let active = input.filters.filter { $0 != .realtime || showsRealtimeFilter }
        let textMatches: (TextModel) -> Bool = { m in
            active.allSatisfy { f in
                switch f {
                case .webSearch: m.webSearch
                case .thinking: m.thinking
                case .realtime: false
                }
            }
        }
        let realtimeMatches = active.allSatisfy { $0 == .realtime }
        let groups: [PickerGroup] = input.connections.compactMap { conn in
            let rows = conn.textModels.filter(textMatches).map { PickerRow(model: $0.model, kind: .text) }
                + (realtimeMatches ? realtimeOf(conn) : [])
            return rows.isEmpty ? nil : PickerGroup(connectionId: conn.id, rows: rows)
        }
        let selectedRow: SelectedRow? = input.selected.flatMap { selected in
            groups.first { $0.connectionId == selected.connectionId }?
                .rows.first { $0.model == selected.model }
                .map { SelectedRow(connectionId: selected.connectionId, model: $0.model, kind: $0.kind) }
        }
        return PickerResult(showsRealtimeFilter: showsRealtimeFilter, groups: groups, selectedRow: selectedRow)
    }

    // MARK: - Realtime selection check

    struct SelectionOutcome: Equatable, Sendable {
        let isRealtime: Bool
        let catalogReady: Bool
    }

    /// Realtime selection check: evaluated on every read from the session field (or home selection) + current connection + cached catalog; the result is not stored separately.
    /// connection nil = connection deleted; realtimeCatalog nil = catalog not ready (evaluates to false, but does not rewrite the stored selection field).
    /// Only an official apiKey connection AND a catalog realtime[providerKind] entry for the model counts; subscription login / relay / hosted / free always evaluate to false.
    static func realtimeSelection(connection: Connection?, model: String, realtimeCatalog: RealtimeCatalog?) -> SelectionOutcome {
        guard let realtimeCatalog else { return SelectionOutcome(isRealtime: false, catalogReady: false) }
        let isRealtime = connection.map { conn in
            conn.auth == .apiKey && (realtimeCatalog[conn.providerKind] ?? []).contains { $0.model == model }
        } ?? false
        return SelectionOutcome(isRealtime: isRealtime, catalogReady: true)
    }

    /// Whether sending waits for the voice catalog: catalog not ready AND official apiKey connection AND the stored model is not in that connection text table → wait (send refused, no toast).
    /// Once the catalog arrives, realtimeSelection decides. The only criteria are connection shape + text table + catalog nil; realtime is never guessed from the model id text;
    /// an empty stored value (no model selected) does not wait.
    static func awaitsVoiceCatalog(connection: Connection?, model: String, realtimeCatalog: RealtimeCatalog?) -> Bool {
        guard realtimeCatalog == nil, !model.isEmpty, let connection, connection.auth == .apiKey else { return false }
        return !connection.textModels.contains { $0.model == model }
    }

    struct CatalogStep: Equatable, Sendable {
        /// Whether this step is re-evaluated (catalog content differs from the previous step; the first step is always evaluated).
        let recompute: Bool
        let isRealtime: Bool
    }

    /// Re-evaluate when the catalog arrives late or changes: catalogs is the sequence of catalog states (nil = not ready),
    /// re-evaluated only when content differs from the previous step; identical content is not re-evaluated; the stored selection field is never rewritten.
    static func catalogSequence(connection: Connection?, model: String, catalogs: [RealtimeCatalog?]) -> [CatalogStep] {
        catalogs.enumerated().map { index, catalog in
            CatalogStep(
                recompute: index == 0 || catalog != catalogs[index - 1],
                isRealtime: realtimeSelection(connection: connection, model: model, realtimeCatalog: catalog).isRealtime
            )
        }
    }

    // MARK: - Typing-state reset / typed-send outcome / back to stage

    /// Typing-state reset: the typing state is stored per session; any change to the selected item ({connectionId, model}, nil = none selected) exits typing.
    static func typingAfterSelectionChange(typing: Bool, before: PickerSelected?, after: PickerSelected?) -> Bool {
        typing && before == after
    }

    enum TypedSendContext: String, Sendable { case home, chat }

    /// persisted = this utterance was saved; endedBeforePersist = the session ended after handoff and before saving; openFailed = a realtime session could not be opened;
    /// disclosureDeclined = the disclosure was declined or dismissed; hostLeft = the disclosure was unanswered and the session was switched or the page was left.
    enum TypedSendOutcomeKind: String, Sendable { case persisted, endedBeforePersist, openFailed, disclosureDeclined, hostLeft }

    struct TypedSendResult: Equatable, Sendable {
        /// Text stays in (or returns to) the input box.
        let inputKeepsText: Bool
        /// Home created the session.
        let conversationCreated: Bool
    }

    /// Outcome of a typed send: text is cleared from the input box only after it is saved; a home session is created only when the first message is saved.
    static func typedSendOutcome(context: TypedSendContext, outcome: TypedSendOutcomeKind) -> TypedSendResult {
        let persisted = outcome == .persisted
        return TypedSendResult(inputKeepsText: !persisted, conversationCreated: context == .home && persisted)
    }

    /// none = no realtime session; typingOpened = a session opened by typing is running but not capturing; capturing = already capturing.
    enum BackToStageSession: String, Sendable { case none, typingOpened, capturing }

    enum BackToStageAction: String, Sendable { case resumeCapture, none, idleStage }

    struct BackToStageResult: Equatable, Sendable {
        let action: BackToStageAction
        /// A tap interrupts a reply that is playing.
        let interruptsPlayback: Bool
    }

    /// Back-to-stage button: a session opened by typing → resume capture on the same connection and go straight to the stage (a tap interrupts playback in progress);
    /// already capturing: no change; no session → idle stage.
    static func backToStage(session: BackToStageSession, assistantSpeaking: Bool = false) -> BackToStageResult {
        switch session {
        case .typingOpened: BackToStageResult(action: .resumeCapture, interruptsPlayback: assistantSpeaking)
        case .capturing: BackToStageResult(action: .none, interruptsPlayback: false)
        case .none: BackToStageResult(action: .idleStage, interruptsPlayback: false)
        }
    }

    // MARK: - Legacy user migration

    /// Old "voice model" choice; nil when following the text model.
    struct OldRealtimeChoice: Equatable, Sendable {
        let providerKind: String
        let model: String
        let connectionId: String
    }

    /// switch / keep / dismissed (system interruption without an answer); nil if the prompt has not been shown.
    enum MigrationAnswer: String, Sendable { case `switch`, keep, dismissed }

    enum MigrationResultKind: String, Sendable { case selectRealtime, enterCascade, none }

    struct MigrationInput: Equatable, Sendable {
        var oldKeyPresent: Bool
        var oldChoice: OldRealtimeChoice?
        var realtimeCatalog: RealtimeCatalog = [:]
        var connections: [Connection] = []
        /// Whether a consent record for (providerKind, realtime) already exists.
        var consented: Bool = false
        var answer: MigrationAnswer?
        /// The disclosure shown after "switch" was declined.
        var disclosureDeclined: Bool = false
    }

    struct MigrationOutcome: Equatable, Sendable {
        let showPrompt: Bool
        let result: MigrationResultKind
        let deleteOldKeys: Bool
        let showDisclosure: Bool
    }

    /// Migration decision on the first tap of ≋ after upgrade: if the old key is absent, enter ≋ directly;
    /// an unresolvable old choice shows no prompt and deletes the old keys; a resolvable one shows the prompt once; unanswered does not delete the old keys.
    static func migration(_ input: MigrationInput) -> MigrationOutcome {
        guard input.oldKeyPresent else {
            return MigrationOutcome(showPrompt: false, result: .enterCascade, deleteOldKeys: false, showDisclosure: false)
        }
        let resolvable: Bool = {
            guard let choice = input.oldChoice,
                  let conn = input.connections.first(where: { $0.id == choice.connectionId }) else { return false }
            return conn.providerKind == choice.providerKind && conn.auth == .apiKey
                && (input.realtimeCatalog[choice.providerKind] ?? []).contains { $0.model == choice.model }
        }()
        guard resolvable else {
            return MigrationOutcome(showPrompt: false, result: .enterCascade, deleteOldKeys: true, showDisclosure: false)
        }
        switch input.answer {
        case .switch:
            let showDisclosure = !input.consented
            let declined = showDisclosure && input.disclosureDeclined
            return MigrationOutcome(
                showPrompt: true, result: declined ? .enterCascade : .selectRealtime,
                deleteOldKeys: true, showDisclosure: showDisclosure
            )
        case .keep:
            return MigrationOutcome(showPrompt: true, result: .enterCascade, deleteOldKeys: true, showDisclosure: false)
        case .dismissed, nil:
            return MigrationOutcome(showPrompt: true, result: .none, deleteOldKeys: false, showDisclosure: false)
        }
    }

    // MARK: - Lifecycle

    enum LifecycleEvent: String, CaseIterable, Sendable {
        case enterBackground, screenLock, returnForeground
        case phoneCall, siri, audioFocusLossPermanent
    }

    enum LifecycleAction: String, Sendable { case `continue`, end }

    /// Input passed to RealtimeConversationLogic on end (corresponds to Logic.Input.systemInterruption).
    enum LifecycleReducerInput: String, Sendable { case systemInterruption }

    struct LifecycleOutcome: Equatable, Sendable {
        let action: LifecycleAction
        /// nil when continuing.
        let reducerInput: LifecycleReducerInput?
    }

    /// Entering background, screen lock, or returning to foreground does not end the session; an incoming call, Siri, or permanent audio focus loss ends it (systemInterruption).
    static func lifecycle(_ event: LifecycleEvent) -> LifecycleOutcome {
        switch event {
        case .enterBackground, .screenLock, .returnForeground:
            LifecycleOutcome(action: .continue, reducerInput: nil)
        case .phoneCall, .siri, .audioFocusLossPermanent:
            LifecycleOutcome(action: .end, reducerInput: .systemInterruption)
        }
    }
}
