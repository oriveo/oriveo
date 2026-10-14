import Foundation

/// The single entry point for getting a connection's key by (connection, optional model id).
///
/// Production code reads keys only through here. A single-key connection returns `provider.apiKey` as is: no trim, no fallback, independent of `modelID`.
/// Multiple keys: only relay connections look at `relayKeys` -- if the enabled model's `relayKeyID` hits a non-primary key, that key's value;
/// everything else (default, dangling, model not enabled, modelID nil, bound to the primary key itself) -> the primary key `provider.apiKey`.
/// Fixture `shared/test-fixtures/relay/credential-resolve.v1.json`.
enum ProviderCredentialResolver {
    nonisolated static func apiKey(provider: Provider, modelID: String?) -> String {
        guard provider.kind == .relay,
              let modelID,
              let keyID = provider.models.first(where: { $0.id == modelID })?.relayKeyID else {
            return provider.apiKey
        }
        return secret(provider: provider, keyID: keyID)
    }

    /// The value of a key: the primary (first) key's value is in `provider.apiKey` and the entry's own `apiKey` is ignored;
    /// an id outside the list falls back to the primary key.
    nonisolated static func secret(provider: Provider, keyID: String) -> String {
        guard provider.kind == .relay,
              let keys = provider.relayKeys,
              let index = keys.firstIndex(where: { $0.id == keyID }),
              index > 0 else {
            return provider.apiKey
        }
        return keys[index].apiKey
    }

    /// Used when assembling the redaction list from a "connection": the primary key plus the values of all non-primary keys (empty values excluded).
    nonisolated static func allSecrets(provider: Provider) -> [String] {
        var secrets = [provider.apiKey]
        if provider.kind == .relay, let keys = provider.relayKeys {
            secrets += keys.dropFirst().map(\.apiKey)
        }
        return secrets.filter { !$0.isEmpty }
    }
}
