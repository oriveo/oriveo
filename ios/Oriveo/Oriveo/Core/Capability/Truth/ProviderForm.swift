import Foundation

/// The "form" of a connection: who has the final say on capability truth.
///
/// The form is derived once from the Provider, and every dispatch afterwards reads it instead of judging by `kind` / `authMode` in many places.
/// The declaration order of the cases is the matching order (first hit wins), matching `forms.order` in the shared contract
/// `capability_truth_contract.v1.json` item by item; the contract test runs `forms.cases` row by row.
enum ProviderForm: String, CaseIterable, Sendable {
    /// Relay: the catalog lives on the user's own machine, and only the connection's own declaration exists.
    case relay
    /// Subscription login of an official Provider: the models are not in the metadata catalog, and capabilities follow the upstream per-model declaration.
    case subscription
    /// API Key connection of an official Provider: capabilities follow the official metadata.
    case official

    nonisolated static func of(_ provider: Provider) -> ProviderForm {
        of(kind: provider.kind, authMode: provider.authMode)
    }

    /// Relay is matched before subscription: a Relay connection has no subscription login, so even if the field is written as
    /// subscription it is still treated as Relay and must not obtain the capability sources of an official subscription.
    nonisolated static func of(kind: ProviderKind, authMode: ProviderAuthMode) -> ProviderForm {
        switch kind {
        case .relay:
            return .relay
        default:
            return authMode == .subscription ? .subscription : .official
        }
    }
}
