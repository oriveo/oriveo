import Foundation

extension AppState {

    private static let deterministicMigrationDefaultsPrefix = "oriveo.providers.deterministicIDMigrated."

    private static func deterministicMigrationKey(for uid: String) -> String {
        "\(deterministicMigrationDefaultsPrefix)\(uid)"
    }

    func migrateProvidersToDeterministicIDsIfNeeded(uid: String) {
        let flagKey = Self.deterministicMigrationKey(for: uid)
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let outcome = Self.planDeterministicProviderMigration(
            providers: providers,
            setupCatalog: ProviderSetupCatalog.current()
        )

        defer { UserDefaults.standard.set(true, forKey: flagKey) }

        guard !outcome.idRemap.isEmpty else { return }

        for (oldID, newID) in outcome.idRemap where oldID != newID {
            if let key = ProviderAPIKeyStore.load(providerID: oldID, uid: uid), !key.isEmpty {
                ProviderAPIKeyStore.save(apiKey: key, providerID: newID, uid: uid)
            }
        }
        for oldID in outcome.removedProviderIDs {
            ProviderAPIKeyStore.delete(providerID: oldID, uid: uid)
        }

        providers = outcome.providers

        reassignConversationProviderIDs(remap: outcome.idRemap)

        persistSessionNow(for: uid)
    }

    private func reassignConversationProviderIDs(remap: [UUID: UUID]) {
        guard !remap.isEmpty else { return }
        var changed = false
        var next = conversations
        for index in next.indices {
            let pid = next[index].providerID
            guard let newID = remap[pid], newID != pid else { continue }
            next[index].providerID = newID
            changed = true
        }
        guard changed else { return }
        conversations = next
        try? replaceConversationProjectionOrThrow(next)
    }


    struct DeterministicMigrationOutcome: Equatable {
        var providers: [Provider]
        var idRemap: [UUID: UUID]
        var removedProviderIDs: Set<UUID>
    }

    static func planDeterministicProviderMigration(
        providers: [Provider],
        setupCatalog: ProviderSetupCatalog
    ) -> DeterministicMigrationOutcome {
        var idRemap: [UUID: UUID] = [:]

        struct GroupKey: Hashable { let kind: ProviderKind; let regionID: String }

        func isEligible(_ p: Provider) -> Bool {
            p.kind != .relay
        }

        func groupKey(_ p: Provider) -> GroupKey {
            GroupKey(
                kind: p.kind,
                regionID: DeterministicProviderID.regionID(
                    for: p.kind,
                    baseURLText: p.baseURLText,
                    setupCatalog: setupCatalog
                )
            )
        }

        var groupOrder: [GroupKey] = []
        var grouped: [GroupKey: [Provider]] = [:]
        for p in providers where isEligible(p) {
            let key = groupKey(p)
            if grouped[key] == nil {
                grouped[key] = []
                groupOrder.append(key)
            }
            grouped[key]?.append(p)
        }

        var replacementByOldID: [UUID: Provider] = [:]
        var discarded: Set<UUID> = []

        for key in groupOrder {
            let members = grouped[key] ?? []
            let deterministicID = DeterministicProviderID.make(kind: key.kind, regionID: key.regionID)

            let deterministicMembers = members.filter { $0.id == deterministicID }
            let randomMembers = members.filter { $0.id != deterministicID }

            let existingDeterministic = deterministicMembers.first

            var collapsedDeterministic: Provider? = existingDeterministic
            var anchorOldID: UUID? = existingDeterministic?.id

            for member in randomMembers {
                if let base = collapsedDeterministic {
                    if Self.sameAPIKey(base, member) {
                        collapsedDeterministic = Self.mergeProvider(into: base, absorbing: member)
                        discarded.insert(member.id)
                        idRemap[member.id] = base.id
                    }
                } else {
                    let rewritten = Self.rewriteID(of: member, to: deterministicID)
                    collapsedDeterministic = rewritten
                    anchorOldID = member.id
                    idRemap[member.id] = deterministicID
                }
            }

            if let finalDeterministic = collapsedDeterministic, let anchorOldID {
                replacementByOldID[anchorOldID] = finalDeterministic
            }
        }

        var result: [Provider] = []
        var appendedIDs: Set<UUID> = []
        for p in providers {
            if discarded.contains(p.id) {
                continue
            }
            if let replacement = replacementByOldID[p.id] {
                if !appendedIDs.contains(replacement.id) {
                    result.append(replacement)
                    appendedIDs.insert(replacement.id)
                }
            } else {
                if !appendedIDs.contains(p.id) {
                    result.append(p)
                    appendedIDs.insert(p.id)
                }
            }
        }

        return DeterministicMigrationOutcome(
            providers: result,
            idRemap: idRemap,
            removedProviderIDs: discarded
        )
    }

    private static func sameAPIKey(_ a: Provider, _ b: Provider) -> Bool {
        let ka = a.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let kb = b.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !ka.isEmpty && ka == kb
    }

    private static func rewriteID(of provider: Provider, to newID: UUID) -> Provider {
        var rebuilt = Provider(
            id: newID,
            kind: provider.kind,
            status: provider.status,
            models: provider.models,
            catalogModels: provider.catalogModels,
            lastCheckedAt: provider.lastCheckedAt,
            apiKey: provider.apiKey,
            apiKeyPreview: provider.apiKeyPreview,
            lastError: provider.lastError,
            baseURLText: provider.baseURLText,
            customName: provider.customName,
            relayRequested: provider.relayRequested,
            relayKind: provider.relayKind
        )
        rebuilt.updatedAt = Date()
        return rebuilt
    }

    private static func mergeProvider(into base: Provider, absorbing absorbed: Provider) -> Provider {
        var merged = base
        var seen = Set(base.models.map(\.id))
        for model in absorbed.models where !seen.contains(model.id) {
            merged.models.append(model)
            seen.insert(model.id)
        }
        if (merged.customName?.isEmpty ?? true), let name = absorbed.customName, !name.isEmpty {
            merged.customName = name
        }
        merged.updatedAt = Date()
        return merged
    }
}
