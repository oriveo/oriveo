import Foundation
import SwiftUI

/// Migration sheet shown the first time an upgraded existing user taps ≋:
/// "Realtime voice moved to the model picker": switch to the realtime model the user picked in the old version, or keep using the current model and enter ≋.
struct RealtimeMigrationPrompt: Identifiable, Equatable {
    /// Realtime model resolved from the old selection (connection = the old selection's connection, model name = catalog model)
    let selection: RealtimeModelSelection
    /// Which session the switch lands in (nil for home)
    let conversationID: UUID?
    /// Decision input (answer is nil); when answering, the answer is carried back in and the decision is evaluated again.
    let input: RealtimeModelPolicy.MigrationInput

    var id: String {
        "\(selection.providerID.uuidString)|\(selection.model)|\(conversationID?.uuidString ?? "home")"
    }

    var title: String {
        L10n.tr("Realtime voice has moved to the model picker", table: .voice)
    }

    var switchTitle: String {
        L10n.format(L10n.tr("Switch to %1$@", table: .voice), selection.model)
    }

    var keepTitle: String {
        L10n.tr("Keep Current Model", table: .voice)
    }
}

/// Migration decision and answer handling. The rules all live in `RealtimeModelPolicy.migration`; this file only does
/// the shape conversion from settings / Provider / catalog to decision input, plus deleting the old key and selecting the realtime model.
@MainActor
enum RealtimeMigration {
    /// On tapping ≋: enter ≋ as usual, or show the migration sheet first
    enum Entry: Equatable {
        case enterCascade
        case prompt(RealtimeMigrationPrompt)
    }

    /// After choosing "switch"
    enum SwitchResult: Equatable {
        /// Already selected that realtime model (the input area becomes the voice panel with the selected state)
        case selected(RealtimeModelSelection)
        /// This provider has not yet agreed to the realtime disclosure: show the disclosure first; the reply goes through `resolveDisclosure`
        case needsDisclosure(RealtimeModelDisclosureRequest)
        /// The connection is no longer waiting: enter ≋ as usual
        case enterCascade
    }

    /// Checked at this step on tapping ≋. When the catalog has no conclusion yet (cold-start cache not finished reading), no decision is made and the old key is kept until next time, so a parseable old selection is not mistakenly deleted as unparseable.
    static func evaluate(
        conversationID: UUID?,
        providers: [Provider],
        catalog: VoiceCatalog?,
        settings: VoiceEngineSettings = VoiceEngineSettings(),
        disclosures: VoiceDisclosureStore = VoiceDisclosureStore()
    ) -> Entry {
        guard settings.hasLegacyRealtimeSelection() else { return .enterCascade }
        guard let catalog else { return .enterCascade }
        let oldChoice: RealtimeModelPolicy.OldRealtimeChoice?
        let oldProvider: Provider?
        if case .cloud(let engine) = settings.legacyRealtimeSelection() {
            oldProvider = providers.first { $0.id.uuidString.caseInsensitiveCompare(engine.connectionID) == .orderedSame }
            oldChoice = RealtimeModelPolicy.OldRealtimeChoice(
                providerKind: engine.providerKind.rawValue,
                model: engine.model,
                connectionId: oldProvider?.id.uuidString ?? engine.connectionID
            )
        } else {
            oldProvider = nil
            oldChoice = nil
        }
        var realtimeCatalog: RealtimeModelPolicy.RealtimeCatalog = [:]
        for (kind, entries) in catalog.providers where !entries.realtime.isEmpty {
            realtimeCatalog[kind.rawValue] = entries.realtime.map {
                RealtimeModelPolicy.RealtimeCatalogEntry(model: $0.model, isDefault: $0.isDefault)
            }
        }
        let input = RealtimeModelPolicy.MigrationInput(
            oldKeyPresent: true,
            oldChoice: oldChoice,
            realtimeCatalog: realtimeCatalog,
            connections: providers.map {
                RealtimeModelPolicy.Connection(
                    id: $0.id.uuidString,
                    providerKind: $0.kind.rawValue,
                    auth: $0.realtimeConnectionAuth,
                    textModels: []
                )
            },
            consented: oldProvider.map { disclosures.hasAccepted($0.kind, direction: .realtime) } ?? false
        )
        let outcome = RealtimeModelPolicy.migration(input)
        guard outcome.showPrompt, let oldProvider, let oldChoice else {
            if outcome.deleteOldKeys { settings.removeLegacyRealtimeSelection() }
            return .enterCascade
        }
        return .prompt(RealtimeMigrationPrompt(
            selection: RealtimeModelSelection(
                providerID: oldProvider.id, providerKind: oldProvider.kind, model: oldChoice.model
            ),
            conversationID: conversationID,
            input: input
        ))
    }

    /// "Keep using current model": delete the old key, enter ≋ as usual.
    static func keep(
        _ prompt: RealtimeMigrationPrompt,
        settings: VoiceEngineSettings = VoiceEngineSettings()
    ) {
        var input = prompt.input
        input.answer = .keep
        if RealtimeModelPolicy.migration(input).deleteOldKeys {
            settings.removeLegacyRealtimeSelection()
        }
    }

    /// "Switch to <model>": delete the old key; the current session (home) selects that realtime model; if the user has not agreed to that provider's realtime disclosure, show the disclosure first.
    static func switchModel(
        _ prompt: RealtimeMigrationPrompt,
        appState: AppState,
        settings: VoiceEngineSettings = VoiceEngineSettings(),
        disclosures: VoiceDisclosureStore = VoiceDisclosureStore()
    ) -> SwitchResult {
        var input = prompt.input
        input.answer = .switch
        if RealtimeModelPolicy.migration(input).deleteOldKeys {
            settings.removeLegacyRealtimeSelection()
        }
        switch appState.selectRealtimeModel(
            providerID: prompt.selection.providerID,
            model: prompt.selection.model,
            for: prompt.conversationID,
            disclosures: disclosures
        ) {
        case .applied(let selection):
            return .selected(selection)
        case .needsDisclosure(let selection):
            return .needsDisclosure(RealtimeModelDisclosureRequest(selection: selection, conversationID: prompt.conversationID))
        case .pending, .unavailable:
            // Catalog not ready: cascade immediately; the pending selection is re-evaluated when the catalog arrives.
            return .enterCascade
        }
    }

    /// Reply to the disclosure shown after switching: agree → select; reject (including swipe-to-dismiss) → enter ≋ as usual (the old key was already deleted at switch time). Returns whether it was selected.
    @discardableResult
    static func resolveDisclosure(
        _ request: RealtimeModelDisclosureRequest,
        accepted: Bool,
        appState: AppState,
        disclosures: VoiceDisclosureStore = VoiceDisclosureStore()
    ) -> Bool {
        appState.resolveRealtimeModelDisclosure(
            request.selection,
            for: request.conversationID,
            accepted: accepted,
            disclosures: disclosures
        )
    }
}

extension View {
    /// Migration sheet (system alert). Dismissed without a button (interrupted by the system) does not call back: the old key is kept and shown again next time.
    func realtimeMigrationAlert(
        _ prompt: Binding<RealtimeMigrationPrompt?>,
        onAnswer: @escaping (_ prompt: RealtimeMigrationPrompt, _ switchModel: Bool) -> Void
    ) -> some View {
        alert(
            prompt.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { prompt.wrappedValue != nil },
                set: { if !$0 { prompt.wrappedValue = nil } }
            ),
            presenting: prompt.wrappedValue
        ) { current in
            Button(current.switchTitle) { onAnswer(current, true) }
            Button(current.keepTitle, role: .cancel) { onAnswer(current, false) }
        }
    }
}
