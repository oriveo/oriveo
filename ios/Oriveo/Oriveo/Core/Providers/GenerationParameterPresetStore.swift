import Foundation

nonisolated struct GenerationParameterPreset: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    let providerID: UUID
    let modelID: String
    let profileFingerprint: String
    var syncProfileKey: String? = nil
    var values: GenerationParameterOverrides
    let createdAt: Date
    var updatedAt: Date
    var revision: Int? = nil
    var mutationID: String? = nil
}

final class GenerationParameterPresetStore: @unchecked Sendable {
    static let shared = GenerationParameterPresetStore()

    private let defaults: UserDefaults
    private let key = "generation_parameter_presets.v1"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// `generation_parameter_contract.v1.json#lifecycleRules.presets`).
    func list(
        providerID: UUID,
        modelID: String,
        profileFingerprint: String,
        portableParameterIDs: Set<String> = []
    ) -> [GenerationParameterPreset] {
        records().filter { preset in
            guard preset.providerID == providerID else { return false }
            if preset.modelID == modelID { return true }
            return preset.values.values.keys.contains(where: portableParameterIDs.contains)
        }
    }

    @discardableResult
    func save(
        name: String,
        providerID: UUID,
        modelID: String,
        profileFingerprint: String,
        values: GenerationParameterOverrides,
        id: UUID? = nil
    ) -> GenerationParameterPreset {
        lock.lock()
        defer { lock.unlock() }
        var current = readLocked()
        let old = id.flatMap { candidate in current.first { $0.id == candidate } }
        let preset = GenerationParameterPreset(
            id: old?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            providerID: providerID,
            modelID: modelID,
            profileFingerprint: profileFingerprint,
            syncProfileKey: old?.syncProfileKey,
            values: values.withoutRuntimeSettings,
            createdAt: old?.createdAt ?? Date(),
            updatedAt: Date(),
            revision: (old?.revision ?? 0) + 1,
            mutationID: UUID().uuidString
        )
        current.removeAll { $0.id == preset.id }
        current.append(preset)
        GenerationParameterSyncLedger.clear(recordID: Self.recordID(preset.id), defaults: defaults)
        writeLocked(current)
        return preset
    }

    func remove(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let current = readLocked()
        if let preset = current.first(where: { $0.id == id }) {
            GenerationParameterSyncLedger.putTombstone(
                recordID: Self.recordID(id),
                revision: (preset.revision ?? 0) + 1,
                defaults: defaults
            )
        }
        writeLocked(current.filter { $0.id != id })
    }

    func removeScopes(providerID: UUID? = nil, modelID: String? = nil) {
        guard providerID != nil || modelID != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        let current = readLocked()
        let kept = current.filter { preset in
            if let providerID, preset.providerID != providerID { return true }
            if let modelID, preset.modelID != modelID { return true }
            return false
        }
        for preset in current where !kept.contains(preset) {
            GenerationParameterSyncLedger.putTombstone(
                recordID: Self.recordID(preset.id),
                revision: (preset.revision ?? 0) + 1,
                defaults: defaults
            )
        }
        writeLocked(kept)
    }

    func apply(
        _ preset: GenerationParameterPreset,
        providerID: UUID,
        modelID: String,
        profileFingerprint: String,
        semanticMapping: [String: String]? = nil
    ) -> GenerationParameterOverrides? {
        guard preset.providerID == providerID else { return nil }
        if preset.modelID == modelID { return preset.values.withoutRuntimeSettings }
        guard let semanticMapping else { return nil }
        let mapped = preset.values.values.reduce(into: [String: GenerationParameterOverride]()) { result, item in
            if let targetID = semanticMapping[item.key] { result[targetID] = item.value }
        }
        return mapped.isEmpty ? nil : GenerationParameterOverrides(values: mapped)
    }

    private func records() -> [GenerationParameterPreset] {
        lock.lock()
        defer { lock.unlock() }
        return readLocked()
    }

    private func readLocked() -> [GenerationParameterPreset] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([GenerationParameterPreset].self, from: data)) ?? []
    }

    private func writeLocked(_ records: [GenerationParameterPreset]) {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }

    func syncRecords() -> [GenerationParameterPreset] { records() }

    func replaceSyncRecords(_ records: [GenerationParameterPreset]) {
        lock.lock()
        defer { lock.unlock() }
        writeLocked(records)
    }

    private static func recordID(_ id: UUID) -> String { "preset:\(id.uuidString.lowercased())" }
}

private extension GenerationParameterOverrides {
    static let runtimeParameterIDs: Set<String> = [
        "context_length", "keep_alive", "speculative_decoding", "prompt_cache", "cache_reuse",
    ]

    var withoutRuntimeSettings: GenerationParameterOverrides {
        GenerationParameterOverrides(values: values.filter { !Self.runtimeParameterIDs.contains($0.key) })
    }
}
