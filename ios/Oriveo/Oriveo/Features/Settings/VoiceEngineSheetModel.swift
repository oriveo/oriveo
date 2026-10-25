import Foundation
import Observation

/// One row in the engine sheet: the system engine or a model on a cloud connection.
struct VoiceEngineSheetRow: Hashable, Sendable, Identifiable {
    let option: VoiceEngineOption
    let title: String
    let subtitle: String
    let isSelected: Bool

    var id: String {
        switch option {
        case .system:
            return "system"
        case .cloud(let providerKind, let connectionID, let model, _):
            return "\(providerKind.rawValue)|\(connectionID)|\(model)"
        }
    }
}

/// Connections the engine sheet lists, plus their display names; read once per evaluation.
struct VoiceEngineSheetConnections {
    /// Voice connections, in their original order.
    let list: [VoiceConnection]
    /// Connection id -> connection display name (`Provider.displayName`).
    let names: [String: String]

    init(_ list: [VoiceConnection], names: [String: String] = [:]) {
        self.list = list
        self.names = names
    }
}

/// Engine sheet presentation model: catalog state + connections + stored selection -> title, rows, footer.
/// Catalog state and connections are read live from their sources on every access, so an open sheet
/// follows connections or a catalog that arrive late or change (observation flows through the sources).
/// Option and pending-list rules come only from `VoiceEngineResolver`; picks go through `VoiceEngineChooser`.
/// "Add Connection" is exposed as an action title only; navigation belongs to the view.
@MainActor
@Observable
final class VoiceEngineSheetModel {
    let direction: VoiceDirection
    /// Stored selection for this direction; drives the checkmark.
    private(set) var selection: VoiceEngineSelection

    @ObservationIgnored private let catalogStateSource: @MainActor () -> VoiceCatalogState?
    @ObservationIgnored private let connectionsSource: @MainActor () -> VoiceEngineSheetConnections
    @ObservationIgnored private let chooser: VoiceEngineChooser

    /// - Parameters:
    ///   - catalogState: current catalog state; nil means no verdict yet (system row only, no footer).
    ///   - connections: current connections and their display names.
    init(
        direction: VoiceDirection,
        catalogState: @escaping @MainActor () -> VoiceCatalogState?,
        connections: @escaping @MainActor () -> VoiceEngineSheetConnections,
        chooser: VoiceEngineChooser = VoiceEngineChooser()
    ) {
        self.direction = direction
        self.catalogStateSource = catalogState
        self.connectionsSource = connections
        self.chooser = chooser
        self.selection = chooser.settings.selection(for: direction)
    }

    /// nil means the catalog has no verdict yet.
    var catalogState: VoiceCatalogState? {
        catalogStateSource()
    }

    var title: String {
        switch direction {
        case .stt: return L10n.tr("Dictation Engine", table: .voice)
        case .tts: return L10n.tr("Read-Aloud Engine", table: .voice)
        case .realtime: return L10n.tr("Conversation Engine", table: .voice)
        }
    }

    var addConnectionTitle: String {
        L10n.tr("Add Connection", table: .voice)
    }

    /// Catalog for picking; reads the source once.
    private var catalog: VoiceCatalog {
        catalogStateSource()?.catalog ?? .empty
    }

    var rows: [VoiceEngineSheetRow] {
        // Each source is read once per evaluation. No catalog verdict yet: connections are not listed.
        let state = catalogStateSource()
        let connections = state == nil ? VoiceEngineSheetConnections([]) : connectionsSource()
        let options = VoiceEngineResolver.options(
            direction: direction,
            catalog: state?.catalog ?? .empty,
            connections: connections.list
        )
        // Same provider listed on more than one connection: append the connection name to tell them apart.
        var connectionsByKind: [ProviderKind: Set<String>] = [:]
        for case .cloud(let providerKind, let connectionID, _, _) in options {
            connectionsByKind[providerKind, default: []].insert(connectionID)
        }
        return options.map { option in
            switch option {
            case .system:
                // For conversations, "system" means follow the current chat model.
                let isRealtime = direction == .realtime
                return VoiceEngineSheetRow(
                    option: option,
                    title: isRealtime
                        ? L10n.tr("Follow Current Model", table: .voice)
                        : L10n.tr("System", table: .voice),
                    subtitle: isRealtime
                        ? L10n.tr("Dictation → current model → read aloud", table: .voice)
                        : L10n.tr("Built into your device, free", table: .voice),
                    isSelected: selection == .system
                )
            case .cloud(let providerKind, let connectionID, let model, _):
                var subtitle = model
                if (connectionsByKind[providerKind]?.count ?? 0) > 1, let name = connections.names[connectionID] {
                    subtitle += " · \(name)"
                }
                return VoiceEngineSheetRow(
                    option: option,
                    title: providerKind.displayName,
                    subtitle: subtitle,
                    isSelected: Self.matches(selection, providerKind: providerKind, connectionID: connectionID, model: model)
                )
            }
        }
    }

    /// nil means no footer.
    var footer: String? {
        switch catalogStateSource() {
        case nil:
            return nil
        case .unavailable:
            return L10n.tr("No cloud voice engines yet", table: .voice)
        case .loadFailed:
            return L10n.tr("Cloud engines can't be loaded right now", table: .voice)
        case .available(let catalog):
            let pending = VoiceEngineResolver.pendingProviders(
                direction: direction,
                catalog: catalog,
                connections: connectionsSource().list
            )
            guard !pending.isEmpty else { return nil }
            let names = pending.map { Self.providerTitle($0.rawValue) }
            return L10n.format(
                L10n.tr("Voice isn't available yet for your %@ connections", table: .voice),
                ListFormatter.localizedString(byJoining: names)
            )
        }
    }

    /// Pick a row. Cloud rows without disclosure consent return `.needsDisclosure` and leave settings untouched.
    func choose(_ row: VoiceEngineSheetRow) -> VoiceEngineChoiceOutcome {
        let outcome = chooser.choose(row.option, direction: direction, catalog: catalog)
        selection = chooser.settings.selection(for: direction)
        return outcome
    }

    /// Answer to the disclosure; returns whether the selection was written.
    @discardableResult
    func resolveDisclosure(_ engine: VoiceCloudEngine, accepted: Bool) -> Bool {
        let applied = chooser.resolveDisclosure(engine, direction: direction, accepted: accepted)
        selection = chooser.settings.selection(for: direction)
        return applied
    }

    /// Provider display name; unknown provider kinds show the raw string.
    static func providerTitle(_ rawKind: String) -> String {
        ProviderKind(rawValue: rawKind)?.displayName ?? rawKind
    }

    private static func matches(
        _ selection: VoiceEngineSelection,
        providerKind: ProviderKind,
        connectionID: String,
        model: String
    ) -> Bool {
        guard case .cloud(let engine) = selection else { return false }
        return engine.providerKind == providerKind && engine.connectionID == connectionID && engine.model == model
    }
}
