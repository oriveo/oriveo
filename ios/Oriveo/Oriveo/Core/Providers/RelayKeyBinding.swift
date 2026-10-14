import Foundation

/// Pure functions for relay multi-key: the key list, model binding, key operations and read models.
///
/// No network, no persistence; the caller writes the result back to the Provider. The source of truth for the rules is the fixture
/// `shared/test-fixtures/relay/key-binding.v1.json` (bindCases / opsCases / readCases).
/// Zero migration: `relayKeys == nil` is treated as one implicit key `initial`, and this file writes no new field for a single-key connection.
nonisolated enum RelayKeyBinding {
    static let implicitKeyID = "initial"

    // MARK: - List and effective key

    /// The connection's key list; default = one implicit key (its value is in `provider.apiKey`).
    static func keys(_ provider: Provider) -> [RelayKey] {
        if let keys = provider.relayKeys, !keys.isEmpty { return keys }
        return [RelayKey(id: implicitKeyID)]
    }

    static func keyIDs(_ provider: Provider) -> [String] {
        keys(provider).map(\.id)
    }

    /// Effective key of an enabled model: if `relayKeyID` is in the list it is that key, otherwise (default / dangling / not enabled) the primary key.
    static func effectiveKeyID(provider: Provider, modelID: String?) -> String {
        let ids = keyIDs(provider)
        let bound = modelID.flatMap { id in provider.models.first(where: { $0.id == id })?.relayKeyID }
        return effectiveKeyID(bound, keyIDs: ids)
    }

    static func effectiveKeyID(_ relayKeyID: String?, keyIDs: [String]) -> String {
        if let relayKeyID, keyIDs.contains(relayKeyID) { return relayKeyID }
        return keyIDs.first ?? implicitKeyID
    }

    /// The lister of a catalog entry; default = listed by the primary key.
    static func listingKeyIDs(_ entry: AIModel, keyIDs: [String]) -> [String] {
        entry.relayListedByKeyIDs ?? [keyIDs.first ?? implicitKeyID]
    }

    // MARK: - Binding (bindCases)

    /// When enabling a catalog model / adding one manually, picks a key for the target model; returns nil when there is only one key (nothing is written).
    /// - family: model id -> vendor family (the cached Server by-model family, falling back to `RelayFamilyHeuristics` when unavailable); nil never matches.
    static func bind(
        keyIDs: [String],
        catalog: [AIModel],
        enabled: [AIModel],
        targetModelID: String,
        family: (String) -> String?
    ) -> String? {
        guard keyIDs.count >= 2 else { return nil }
        let listing = catalog.first(where: { $0.id == targetModelID }).map { listingKeyIDs($0, keyIDs: keyIDs) } ?? []
        let listingKeys = keyIDs.filter { listing.contains($0) }
        if listingKeys.count == 1 { return listingKeys[0] }

        let targetFamily = family(targetModelID)
        let sameFamilyKeys: [String] = targetFamily.map { wanted in
            enabled
                .filter { family($0.id) == wanted }
                .map { effectiveKeyID($0.relayKeyID, keyIDs: keyIDs) }
        } ?? []

        if listingKeys.count >= 2 {
            return sameFamilyKeys.first(where: { listingKeys.contains($0) }) ?? listingKeys[0]
        }
        return sameFamilyKeys.first ?? keyIDs[0]
    }

    // MARK: - Per-key catalog merge (catalogCases)

    /// The catalog result of one key this time.
    enum CatalogFetch {
        /// Catalog entries in upstream order.
        case ok([AIModel])
        /// status nil = network / decode failure; body is the raw response body.
        case failed(status: Int?, body: String)
        /// Not fetched this time (for example only another key was swapped in).
        case skipped
    }

    struct CatalogMerge {
        var catalog: [AIModel]
        /// Status of the keys fetched this time; skipped does not appear (status unchanged).
        var states: [String: (state: RelayKey.Status.State, httpStatus: Int?)]
    }

    /// With two or more keys, merges each key's catalog. Walks in key order: a success contributes this time's entries (upstream order), a failure / skip contributes the entries it listed last time
    /// (last time's order), and whoever appears first wins; `relayListedByKeyIDs` = all keys that list it, in key order. Entries listed by no key leave the catalog
    /// (enabled and manual models are covered by the existing retention logic, not here). Keys missing from the result count as skipped.
    static func mergeCatalog(keyIDs: [String], previous: [AIModel], results: [String: CatalogFetch]) -> CatalogMerge {
        var order: [String] = []
        var entries: [String: AIModel] = [:]
        var listedBy: [String: [String]] = [:]
        var states: [String: (state: RelayKey.Status.State, httpStatus: Int?)] = [:]
        for keyID in keyIDs {
            let contributed: [AIModel]
            switch results[keyID] ?? .skipped {
            case let .ok(models):
                contributed = models
                states[keyID] = (.ok, nil)
            case let .failed(status, body):
                contributed = previous.filter { listingKeyIDs($0, keyIDs: keyIDs).contains(keyID) }
                states[keyID] = (RelayKeyAccess.catalogFailureState(status: status, body: body), status)
            case .skipped:
                contributed = previous.filter { listingKeyIDs($0, keyIDs: keyIDs).contains(keyID) }
            }
            for model in contributed {
                if entries[model.id] == nil {
                    order.append(model.id)
                    entries[model.id] = model
                }
                if listedBy[model.id]?.contains(keyID) != true {
                    listedBy[model.id, default: []].append(keyID)
                }
            }
        }
        let catalog = order.compactMap { id -> AIModel? in
            guard var model = entries[id] else { return nil }
            model.relayListedByKeyIDs = listedBy[id]
            return model
        }
        return CatalogMerge(catalog: catalog, states: states)
    }

    // MARK: - Key operations (opsCases)

    enum Operation: Equatable {
        case add(id: String, name: String?, apiKey: String)
        case rename(id: String, name: String?)
        case replaceSecret(id: String, apiKey: String)
        case move(id: String, toIndex: Int)
        case delete(id: String)
        case rebind(modelID: String, keyID: String)
    }

    /// Returns the Provider after the operation; nil = rejected (deleting the last key, id not found, a list operation on a single-key connection).
    /// After every operation: `relayKeys[0].apiKey` is stored empty, and `provider.apiKey` is the primary key's value.
    static func apply(_ operation: Operation, to provider: Provider) -> Provider? {
        var out = provider
        switch operation {
        case let .add(id, name, apiKey):
            let ids = keyIDs(provider)
            guard !id.isEmpty, !ids.contains(id) else { return nil }
            // The list is generated for the first time: pin all enabled models and fill in the listers of catalog entries, so reordering later cannot silently swap keys.
            let primary = ids[0]
            for index in out.models.indices {
                out.models[index].relayKeyID = effectiveKeyID(out.models[index].relayKeyID, keyIDs: ids)
            }
            for index in out.catalogModels.indices where out.catalogModels[index].relayListedByKeyIDs == nil {
                out.catalogModels[index].relayListedByKeyIDs = [primary]
            }
            out.relayKeys = keys(provider) + [RelayKey(id: id, name: name, apiKey: apiKey)]

        case let .rename(id, name):
            guard var list = provider.relayKeys, let index = list.firstIndex(where: { $0.id == id }) else { return nil }
            list[index].name = name
            out.relayKeys = list

        case let .replaceSecret(id, apiKey):
            let list = keys(provider)
            guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
            if index == 0 {
                out.apiKey = apiKey
                out.apiKeyPreview = APIKeyMask.masked(apiKey)
            }
            if var stored = provider.relayKeys {
                if index > 0 { stored[index].apiKey = apiKey }
                stored[index].status = nil
                out.relayKeys = stored
            }
            mutateModels(&out) { model in
                if model.relayDeniedKeyID == id { model.relayDeniedKeyID = nil }
            }

        case let .move(id, toIndex):
            guard let list = provider.relayKeys,
                  let from = list.firstIndex(where: { $0.id == id }),
                  list.indices.contains(toIndex) else { return nil }
            var secrets = list.indices.map { secretSlot(provider, list: list, index: $0) }
            var entries = list
            entries.insert(entries.remove(at: from), at: toIndex)
            secrets.insert(secrets.remove(at: from), at: toIndex)
            setSecrets(&out, entries: entries, secrets: secrets)

        case let .delete(id):
            let list = keys(provider)
            guard list.count >= 2, let index = list.firstIndex(where: { $0.id == id }) else { return nil }
            let oldIDs = list.map(\.id)
            var secrets = list.indices.map { secretSlot(provider, list: list, index: $0) }
            var entries = list
            entries.remove(at: index)
            secrets.remove(at: index)
            setSecrets(&out, entries: entries, secrets: secrets)
            let newPrimary = entries[0].id
            mutateModels(&out) { model in
                if model.relayKeyID == id { model.relayKeyID = newPrimary }
                if model.relayDeniedKeyID == id { model.relayDeniedKeyID = nil }
            }
            // Catalog entries listed only by this key leave the catalog (enabled models are unaffected); for the rest, remove it.
            out.catalogModels = out.catalogModels.compactMap { entry in
                let remaining = listingKeyIDs(entry, keyIDs: oldIDs).filter { $0 != id }
                guard !remaining.isEmpty else { return nil }
                var kept = entry
                kept.relayListedByKeyIDs = remaining
                return kept
            }
            for index in out.models.indices {
                if let listed = out.models[index].relayListedByKeyIDs {
                    let remaining = listed.filter { $0 != id }
                    out.models[index].relayListedByKeyIDs = remaining.isEmpty ? nil : remaining
                }
            }

        case let .rebind(modelID, keyID):
            guard let list = provider.relayKeys, list.contains(where: { $0.id == keyID }),
                  provider.models.contains(where: { $0.id == modelID }) else { return nil }
            // Rebind: clear the no-access flag and the protocol obtained by probing; protocols chosen by the user / observed on real sends are kept.
            mutateModels(&out, only: modelID) { model in
                model.relayKeyID = keyID
                model.relayDeniedKeyID = nil
                if model.relayTransportSource == .reachable {
                    model.relayTransport = nil
                    model.relayTransportSource = nil
                }
            }
        }
        return out
    }

    /// Key value of slot i: the primary key is in `provider.apiKey`, the others are in the entries.
    private static func secretSlot(_ provider: Provider, list: [RelayKey], index: Int) -> String {
        index == 0 ? provider.apiKey : list[index].apiKey // key-choke: stored-field
    }

    private static func setSecrets(_ provider: inout Provider, entries: [RelayKey], secrets: [String]) {
        var entries = entries
        for index in entries.indices {
            entries[index].apiKey = index == 0 ? "" : secrets[index]
        }
        if provider.apiKey != secrets[0] { // key-choke: stored-field
            provider.apiKey = secrets[0]
            provider.apiKeyPreview = APIKeyMask.masked(secrets[0])
        }
        provider.relayKeys = entries
    }

    /// The enabled list and the catalog entry with the same id are written together (consistent with how the model "Advanced" page writes).
    private static func mutateModels(_ provider: inout Provider, only modelID: String? = nil, _ body: (inout AIModel) -> Void) {
        for index in provider.models.indices where modelID == nil || provider.models[index].id == modelID {
            body(&provider.models[index])
        }
        for index in provider.catalogModels.indices where modelID == nil || provider.catalogModels[index].id == modelID {
            body(&provider.catalogModels[index])
        }
    }

    // MARK: - Read models (readCases)

    struct KeyRow: Equatable {
        let id: String
        let name: String?
        let isPrimary: Bool
        let status: RelayKey.Status.State?
        let catalogCount: Int
        let enabledCount: Int
        /// The mask continues to use this client's `APIKeyMask` and does not take part in the fixture comparison.
        let maskedSecret: String
    }

    struct ModelKeyState: Equatable {
        let boundKeyID: String
        let alternateKeyIDs: [String]
        let deniedOnCurrentKey: Bool
    }

    static func showsKeyUI(_ provider: Provider) -> Bool {
        keys(provider).count >= 2
    }

    static func rows(_ provider: Provider) -> [KeyRow] {
        let list = keys(provider)
        let ids = list.map(\.id)
        let enabledKeys = provider.models.map { effectiveKeyID($0.relayKeyID, keyIDs: ids) }
        return list.enumerated().map { index, key in
            KeyRow(
                id: key.id,
                name: key.name,
                isPrimary: index == 0,
                status: key.status?.state,
                catalogCount: provider.catalogModels.filter { listingKeyIDs($0, keyIDs: ids).contains(key.id) }.count,
                enabledCount: enabledKeys.filter { $0 == key.id }.count,
                maskedSecret: APIKeyMask.masked(ProviderCredentialResolver.secret(provider: provider, keyID: key.id))
            )
        }
    }

    /// Key read model of an enabled model; nil when the model is not enabled.
    static func modelState(_ provider: Provider, modelID: String) -> ModelKeyState? {
        guard let model = provider.models.first(where: { $0.id == modelID }) else { return nil }
        let ids = keyIDs(provider)
        let bound = effectiveKeyID(model.relayKeyID, keyIDs: ids)
        let listing = provider.catalogModels.first(where: { $0.id == modelID }).map { listingKeyIDs($0, keyIDs: ids) } ?? []
        return ModelKeyState(
            boundKeyID: bound,
            alternateKeyIDs: ids.filter { $0 != bound && listing.contains($0) },
            deniedOnCurrentKey: model.relayDeniedKeyID == bound
        )
    }
}
