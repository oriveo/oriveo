import Foundation
import CryptoKit

nonisolated enum CapabilityWebPreference: String, Codable, CaseIterable, Sendable {
    /// Internal field-level inheritance marker. It is accepted by the seven-scope resolver but is
    /// never exported to sync or presented as a selectable UI value.
    case inherit
    case off
    case automatic
    case force
    case custom

    static let allCases: [Self] = [.off, .automatic, .force, .custom]
}

nonisolated enum CapabilityPreferenceScope: String, Codable, Sendable {
    case conversationConnectionModel = "conversation_connection_model"
    case skillAgent = "skill_agent"
    case connectionModel = "connection_model"
    case connection
}

/// Local-only selection for one request owner. It is stored beside that owner's raw fragment so
/// switching back to automatic configuration can omit the raw without deleting the developer's
/// draft or leaking the selection into the synchronized typed-preference envelope.
nonisolated enum LocalCustomConfigurationMode: String, Codable, Sendable {
    case automatic
    case custom
}

nonisolated struct LocalCustomFragmentConfiguration: Equatable, Sendable {
    var mode: LocalCustomConfigurationMode
    var rawJSON: String
}

nonisolated struct CapabilityPreferenceValues: Codable, Equatable, Hashable, Sendable {
    var web: CapabilityWebPreference
    /// `nil` means provider default. A string preserves server's sparse `availableIntents` exactly
    /// (including `off`) rather than forcing it through the legacy five-case `ReasoningMode`.
    var reasoningIntent: String?

    init(web: CapabilityWebPreference = .off, reasoningIntent: String? = nil) {
        self.web = web
        self.reasoningIntent = reasoningIntent
    }
}

/// Complete runtime identity used by every persisted capability preference scope. The encoded
/// wire value contains only final transport + catalog runtime revision; connection and canonical
/// model remain explicit record fields, and LWW revision never participates in this encoding.
nonisolated struct CapabilityPreferenceRuntimeIdentity: Equatable, Sendable {
    let canonicalModelID: String
    let finalTransport: String
    let runtimeRevision: String

    var wireValue: String {
        "r1.\(Self.base64URL(finalTransport)).\(Self.base64URL(runtimeRevision))"
    }

    static func make(
        provider: Provider,
        model: AIModel,
        resolvedFinalTransport: String? = nil
    ) -> Self? {
        if let subscriptionTransport = CapabilityControlResolution.subscriptionFinalTransport(
            for: provider, model: model
        ) {
            return .init(
                canonicalModelID: trimmed(model.canonicalModelId) ?? model.id,
                finalTransport: subscriptionTransport,
                runtimeRevision: subscriptionRuntimeRevision
            )
        }
        let snapshot = MetadataClient.shared.syncCapabilityRecipeRuntime(
            modelID: model.id, providerKind: provider.kind
        )
        guard let revision = trimmed(snapshot.runtime?.revision) else { return nil }
        let input = MetadataClient.shared.syncCapabilityEvidenceModelInput(
            modelID: model.id, providerKind: provider.kind
        )
        let transport: String?
        if provider.kind == .relay {
            transport = relayFinalTransport(
                provider: provider, resolvedFinalTransport: resolvedFinalTransport
            )
        } else {
            transport = input.resolved?.transport
        }
        guard let finalTransport = trimmed(transport) else { return nil }
        return .init(
            canonicalModelID: trimmed(input.resolved?.canonicalModelId)
                ?? trimmed(model.canonicalModelId) ?? model.id,
            finalTransport: finalTransport,
            runtimeRevision: revision
        )
    }

    static func relayFinalTransport(
        provider: Provider,
        resolvedFinalTransport: String?
    ) -> String? {
        guard provider.kind == .relay else { return trimmed(resolvedFinalTransport) }
        if let resolved = trimmed(resolvedFinalTransport) { return resolved }
        guard let selected = provider.relayRequested?.transport, selected != .auto else {
            // Relay auto is an intent, not the production dispatch selection. UI/persistence
            // cannot invent the final transport before the builder resolves it.
            return nil
        }
        return selected.rawValue
    }

    static let subscriptionRuntimeRevision = "subscription"

    static func decode(_ raw: String) -> Self? {
        let components = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components[0] == "r1",
              let transport = trimmed(decodeBase64URL(String(components[1]))),
              let revision = trimmed(decodeBase64URL(String(components[2]))) else { return nil }
        return .init(canonicalModelID: "", finalTransport: transport, runtimeRevision: revision)
    }

    private static func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> String? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf8),
              base64URL(decoded) == value else { return nil }
        return decoded
    }

    private static func trimmed(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}

nonisolated struct CapabilityLocalCustomForwardPortContext: Equatable, Sendable {
    let providerKind: ProviderKind
    let schemaModelID: String

    init(providerKind: ProviderKind, schemaModelID: String) {
        self.providerKind = providerKind
        self.schemaModelID = schemaModelID
    }
}

/// One field can inherit while the other is explicit in the same scope record. Resolving a whole
/// record at once would let a conversation web choice erase connection-level reasoning (or the
/// inverse), so both namespaces walk the same frozen seven-scope ladder independently.
nonisolated enum CapabilityPreferenceValueResolver {
    private static func layers(
        _ singleSend: CapabilityPreferenceValues?,
        _ conversation: CapabilityPreferenceValues?,
        _ skill: CapabilityPreferenceValues?,
        _ connectionModel: CapabilityPreferenceValues?,
        _ connection: CapabilityPreferenceValues?,
        _ providerRecipe: CapabilityPreferenceValues?,
        _ providerDefault: CapabilityPreferenceValues?
    ) -> [(RequestPreferenceScope, CapabilityPreferenceValues?)] {
        [
            (.singleSend, singleSend),
            (.conversationConnectionModel, conversation),
            (.skillAgent, skill),
            (.connectionModel, connectionModel),
            (.connection, connection),
            (.providerRecipe, providerRecipe),
            (.providerDefault, providerDefault),
        ]
    }

    static func displaySelection(
        conversation: CapabilityPreferenceValues? = nil,
        skill: CapabilityPreferenceValues? = nil,
        connectionModel: CapabilityPreferenceValues? = nil,
        connection: CapabilityPreferenceValues? = nil
    ) -> CapabilityPreferenceValues {
        let ordered = layers(nil, conversation, skill, connectionModel, connection, nil, nil)
            .compactMap(\.1)
        return .init(
            web: ordered.first { $0.web != .inherit }?.web ?? .off,
            reasoningIntent: ordered.first { $0.reasoningIntent != nil }?.reasoningIntent
        )
    }

    static func resolve(
        singleSend: CapabilityPreferenceValues? = nil,
        conversation: CapabilityPreferenceValues? = nil,
        skill: CapabilityPreferenceValues? = nil,
        connectionModel: CapabilityPreferenceValues? = nil,
        connection: CapabilityPreferenceValues? = nil,
        providerRecipe: CapabilityPreferenceValues? = nil,
        providerDefault: CapabilityPreferenceValues? = nil
    ) -> CapabilityPreferenceValues {
        func webOverride(_ values: CapabilityPreferenceValues?) -> RequestPreferenceOverride {
            guard let values else { return .inherit }
            switch values.web {
            case .inherit: return .inherit
            case .off: return .omit
            case .automatic: return .value(.string("automatic"))
            case .force: return .value(.string("force"))
            case .custom: return .value(.string("custom"))
            }
        }
        func reasoningOverride(_ values: CapabilityPreferenceValues?) -> RequestPreferenceOverride {
            guard let intent = values?.reasoningIntent else { return .inherit }
            return intent == "off" ? .omit : .value(.string(intent))
        }
        let valuesByScope = layers(
            singleSend, conversation, skill, connectionModel, connection, providerRecipe, providerDefault
        )
        func resolve(_ field: (CapabilityPreferenceValues?) -> RequestPreferenceOverride) -> ResolvedRequestPreference {
            RequestPreferenceResolver.resolve(layers: valuesByScope.map {
                .init(scope: $0.0, override: field($0.1))
            })
        }

        let web = resolve(webOverride)
        let reasoning = resolve(reasoningOverride)
        let webValue: CapabilityWebPreference
        if case let .value(.string(raw)) = web.override,
           let parsed = CapabilityWebPreference(rawValue: raw) {
            webValue = parsed
        } else {
            webValue = .off
        }
        let reasoningValue: String?
        if case let .value(.string(raw)) = reasoning.override {
            reasoningValue = raw
        } else if reasoning.override == .omit {
            reasoningValue = "off"
        } else {
            reasoningValue = nil
        }
        return .init(web: webValue, reasoningIntent: reasoningValue)
    }
}

final class GenerationParameterSettingsStore: @unchecked Sendable {
    static let shared = GenerationParameterSettingsStore()

    fileprivate struct Record: Codable, Equatable {
        let scope: String?
        let providerID: UUID
        let modelID: String
        let conversationID: UUID?
        let profileFingerprint: String?
        let syncProfileKey: String?
        let values: GenerationParameterOverrides
        let updatedAt: Date?
        let revision: Int?
        let mutationID: String?

        init(
            scope: String? = nil,
            providerID: UUID,
            modelID: String,
            conversationID: UUID?,
            profileFingerprint: String?,
            syncProfileKey: String? = nil,
            values: GenerationParameterOverrides,
            updatedAt: Date?,
            revision: Int? = nil,
            mutationID: String? = nil
        ) {
            self.scope = scope
            self.providerID = providerID
            self.modelID = modelID
            self.conversationID = conversationID
            self.profileFingerprint = profileFingerprint
            self.syncProfileKey = syncProfileKey
            self.values = values
            self.updatedAt = updatedAt
            self.revision = revision
            self.mutationID = mutationID
        }
    }

    fileprivate struct CapabilityRecord: Codable, Equatable {
        let scope: CapabilityPreferenceScope
        let providerID: UUID
        let modelID: String
        let conversationID: UUID?
        /// `skillID` marks the formal `skill_agent` scope. It is deliberately independent of a
        /// conversation: an old Skill without this record remains inherit until the user confirms.
        let skillID: UUID?
        let transportIdentity: String
        let values: CapabilityPreferenceValues
        let updatedAt: Date
        let revision: Int
        let mutationID: String
    }

    fileprivate struct LocalCustomFragmentRecord: Codable, Equatable {
        let providerID: UUID
        let modelID: String
        let conversationID: UUID?
        let transportIdentity: String
        let namespace: String
        let rawJSON: String
        /// Missing on records. A stored raw fragment meant custom mode before mode was explicit.
        let mode: LocalCustomConfigurationMode?
        let updatedAt: Date
    }

    fileprivate let defaults: UserDefaults
    private let lock = NSLock()
    private let storageKey = "generation_parameter_settings.v1"
    private let capabilityStorageKey = "capability_preference_settings.v1"
    private let localCustomStorageKey = "capability_preference_local_custom.v1"
    private let retiredLocalCustomDeveloperModeKey = "capability_preference_local_custom_developer_mode.v1"
    private let maximumRecordCount = 200
    private let recordTTL: TimeInterval = 180 * 24 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateRetiredLocalCustomDeveloperGate()
    }

    private func migrateRetiredLocalCustomDeveloperGate() {
        guard defaults.object(forKey: retiredLocalCustomDeveloperModeKey) != nil else { return }
        let wasEnabled = defaults.bool(forKey: retiredLocalCustomDeveloperModeKey)
        defer { defaults.removeObject(forKey: retiredLocalCustomDeveloperModeKey) }
        guard !wasEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let records = localCustomRecordsLocked()
        guard records.contains(where: { ($0.mode ?? .custom) == .custom }) else { return }
        writeLocalCustomRecordsLocked(records.map { record in
            guard (record.mode ?? .custom) == .custom else { return record }
            return .init(
                providerID: record.providerID, modelID: record.modelID,
                conversationID: record.conversationID, transportIdentity: record.transportIdentity,
                namespace: record.namespace, rawJSON: record.rawJSON, mode: .automatic,
                updatedAt: record.updatedAt
            )
        })
    }

    func modelDefaults(providerID: UUID, modelID: String, profileFingerprint: String? = nil) -> GenerationParameterOverrides? {
        Self.latest(records()) { record in
            Self.effectiveScope(record) == "model_default" && record.providerID == providerID
                && record.modelID == modelID && record.conversationID == nil
        }?.values
    }

    func connectionDefaults(providerID: UUID) -> GenerationParameterOverrides? {
        Self.latest(records()) { $0.scope == "connection_default" && $0.providerID == providerID }?.values
    }

    func sessionOverrides(
        providerID: UUID,
        modelID: String,
        conversationID: UUID,
        profileFingerprint: String? = nil
    ) -> GenerationParameterOverrides? {
        Self.latest(records()) { record in
            record.providerID == providerID && record.modelID == modelID && record.conversationID == conversationID
        }?.values
    }

    func setModelDefaults(_ values: GenerationParameterOverrides?, providerID: UUID, modelID: String, profileFingerprint: String? = nil) {
        replace(values, providerID: providerID, modelID: modelID, conversationID: nil, profileFingerprint: profileFingerprint, scope: "model_default")
    }

    func setConnectionDefaults(_ values: GenerationParameterOverrides?, providerID: UUID) {
        replace(values, providerID: providerID, modelID: "*", conversationID: nil, profileFingerprint: nil, scope: "connection_default")
    }

    func setSessionOverrides(
        _ values: GenerationParameterOverrides?,
        providerID: UUID,
        modelID: String,
        conversationID: UUID,
        profileFingerprint: String? = nil
    ) {
        replace(values, providerID: providerID, modelID: modelID, conversationID: conversationID, profileFingerprint: profileFingerprint, scope: "conversation_override")
    }

    // MARK: - capability preferences ()

    /// Typed web/reasoning preferences are scoped by connection × model × final transport identity.
    /// A nil conversation is the connection-model default; a conversation value is the v2
    /// `conversation_connection_model` scope. `transportIdentity` must be supplied by the real
    /// dispatch path (for Relay it includes the sanitized endpoint fingerprint), never guessed from model id.
    func capabilityPreferences(
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        skillID: UUID? = nil,
        transportIdentity: String
    ) -> CapabilityPreferenceValues? {
        guard CapabilityPreferenceRuntimeIdentity.decode(transportIdentity) != nil else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return capabilityRecordsLocked().filter {
            $0.scope != .connection && $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == conversationID && $0.skillID == skillID
                && $0.transportIdentity == transportIdentity
        }.max { $0.updatedAt < $1.updatedAt }?.values
    }

    func setCapabilityPreferences(
        _ values: CapabilityPreferenceValues?,
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        skillID: UUID? = nil,
        transportIdentity: String
    ) {
        guard CapabilityPreferenceRuntimeIdentity.decode(transportIdentity) != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        var records = capabilityRecordsLocked()
        let scope: CapabilityPreferenceScope = skillID != nil ? .skillAgent : (conversationID != nil ? .conversationConnectionModel : .connectionModel)
        let matches: (CapabilityRecord) -> Bool = {
            $0.scope == scope
                && $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == conversationID && $0.skillID == skillID
                && $0.transportIdentity == transportIdentity
        }
        // A tombstone is a versioned mutation too. Reconfirming after an unconfirm must outrank
        // its own tombstone, otherwise export/merge would keep selecting the old delete.
        let identity = CapabilityRecord(
            scope: scope, providerID: providerID, modelID: modelID, conversationID: conversationID,
            skillID: skillID, transportIdentity: transportIdentity, values: values ?? .init(),
            updatedAt: Date(), revision: 0, mutationID: ""
        )
        let recordID = CapabilityPreferenceSyncContract.recordID(for: identity)
        let baseRevision = max(records.filter(matches).map(\.revision).max() ?? 0,
                               CapabilityPreferenceSyncLedger.revision(for: recordID, defaults: defaults))
        let revision = baseRevision + 1
        records.removeAll(where: matches)
        guard let values else {
            CapabilityPreferenceSyncLedger.put(.init(
                recordId: recordID, revision: revision, mutationId: UUID().uuidString.lowercased()
            ), defaults: defaults)
            writeCapabilityRecordsLocked(records)
            return
        }
        records.append(.init(
            scope: scope,
            providerID: providerID, modelID: modelID, conversationID: conversationID, skillID: skillID,
            transportIdentity: transportIdentity, values: values, updatedAt: Date(),
            revision: revision, mutationID: UUID().uuidString.lowercased()
        ))
        CapabilityPreferenceSyncLedger.clear(recordID: recordID, defaults: defaults)
        writeCapabilityRecordsLocked(records)
    }

    func connectionCapabilityPreferences(
        providerID: UUID, modelID: String, transportIdentity: String
    ) -> CapabilityPreferenceValues? {
        guard !modelID.isEmpty,
              CapabilityPreferenceRuntimeIdentity.decode(transportIdentity) != nil else { return nil }
        lock.lock(); defer { lock.unlock() }
        return capabilityRecordsLocked().filter {
            $0.scope == .connection && $0.providerID == providerID && $0.modelID == modelID
                && $0.transportIdentity == transportIdentity
        }.max { $0.updatedAt < $1.updatedAt }?.values
    }

    func setConnectionCapabilityPreferences(
        _ values: CapabilityPreferenceValues?, providerID: UUID, modelID: String,
        transportIdentity: String
    ) {
        guard !modelID.isEmpty,
              CapabilityPreferenceRuntimeIdentity.decode(transportIdentity) != nil else { return }
        lock.lock(); defer { lock.unlock() }
        var records = capabilityRecordsLocked()
        let matches: (CapabilityRecord) -> Bool = {
            $0.scope == .connection && $0.providerID == providerID && $0.modelID == modelID
                && $0.transportIdentity == transportIdentity
        }
        let removed = records.filter(matches)
        let identity = CapabilityRecord(
            scope: .connection, providerID: providerID, modelID: modelID, conversationID: nil, skillID: nil,
            transportIdentity: transportIdentity, values: values ?? .init(), updatedAt: Date(), revision: 0, mutationID: ""
        )
        let recordID = CapabilityPreferenceSyncContract.recordID(for: identity)
        let revision = max(removed.map(\.revision).max() ?? 0,
                           CapabilityPreferenceSyncLedger.revision(for: recordID, defaults: defaults)) + 1
        records.removeAll(where: matches)
        if let values {
            records.append(.init(scope: .connection, providerID: providerID, modelID: modelID, conversationID: nil, skillID: nil, transportIdentity: transportIdentity, values: values, updatedAt: Date(), revision: revision, mutationID: UUID().uuidString.lowercased()))
            CapabilityPreferenceSyncLedger.clear(recordID: recordID, defaults: defaults)
        } else {
            CapabilityPreferenceSyncLedger.put(.init(recordId: recordID, revision: revision, mutationId: UUID().uuidString.lowercased()), defaults: defaults)
        }
        writeCapabilityRecordsLocked(records)
    }

    /// Source-compatibility shim for pre- tests/readers. New production call sites always pass
    /// canonical model identity; records written through this shim cannot enter the v2 sync wire.
    func connectionCapabilityPreferences(providerID: UUID, transportIdentity: String) -> CapabilityPreferenceValues? {
        connectionCapabilityPreferences(
            providerID: providerID, modelID: "__legacy_incomplete_identity__",
            transportIdentity: transportIdentity
        )
    }

    func setConnectionCapabilityPreferences(
        _ values: CapabilityPreferenceValues?, providerID: UUID, transportIdentity: String
    ) {
        setConnectionCapabilityPreferences(
            values, providerID: providerID, modelID: "__legacy_incomplete_identity__",
            transportIdentity: transportIdentity
        )
    }

    func displayCapabilityPreferences(
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        skillID: UUID?,
        transportIdentity: String
    ) -> CapabilityPreferenceValues {
        let scopes = capabilityScopeValues(
            providerID: providerID, modelID: modelID, conversationID: conversationID,
            skillID: skillID, transportIdentity: transportIdentity
        )
        return CapabilityPreferenceValueResolver.displaySelection(
            conversation: scopes.conversation,
            skill: scopes.skill,
            connectionModel: scopes.connectionModel,
            connection: scopes.connection
        )
    }

    private func capabilityScopeValues(
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        skillID: UUID?,
        transportIdentity: String
    ) -> (
        conversation: CapabilityPreferenceValues?,
        skill: CapabilityPreferenceValues?,
        connectionModel: CapabilityPreferenceValues?,
        connection: CapabilityPreferenceValues?
    ) {
        forwardPortCapabilityPreferencesIfNeeded(
            providerID: providerID, modelID: modelID, conversationID: conversationID,
            skillID: skillID, transportIdentity: transportIdentity
        )
        let conversation = conversationID.flatMap { conversationID in
            capabilityPreferences(
                providerID: providerID, modelID: modelID, conversationID: conversationID,
                transportIdentity: transportIdentity
            )
        }
        let skill = skillID.flatMap { skillID in
            capabilityPreferences(
                providerID: providerID, modelID: modelID, conversationID: nil, skillID: skillID,
                transportIdentity: transportIdentity
            )
        }
        let connectionModel = capabilityPreferences(
            providerID: providerID, modelID: modelID, conversationID: nil,
            transportIdentity: transportIdentity
        )
        let connection = connectionCapabilityPreferences(
            providerID: providerID, modelID: modelID, transportIdentity: transportIdentity
        )
        return (conversation, skill, connectionModel, connection)
    }

    /// Resolution is explicit about precedence. A skill record only participates after a user has
    /// reconfirmed it; missing records are inherit, never a projection of legacy Skill API fields.
    func resolvedCapabilityPreferences(
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        skillID: UUID?,
        transportIdentity: String,
        singleSend: CapabilityPreferenceValues? = nil,
        providerRecipe: CapabilityPreferenceValues? = nil,
        providerDefault: CapabilityPreferenceValues? = nil
    ) -> CapabilityPreferenceValues {
        let scopes = capabilityScopeValues(
            providerID: providerID, modelID: modelID, conversationID: conversationID,
            skillID: skillID, transportIdentity: transportIdentity
        )
        return CapabilityPreferenceValueResolver.resolve(
            singleSend: singleSend,
            conversation: scopes.conversation,
            skill: scopes.skill,
            connectionModel: scopes.connectionModel,
            connection: scopes.connection,
            providerRecipe: providerRecipe,
            providerDefault: providerDefault
        )
    }


    private static func isSameTransportLineage(_ current: String, _ candidate: String) -> Bool {
        guard current != candidate,
              let current = CapabilityPreferenceRuntimeIdentity.decode(current),
              let candidate = CapabilityPreferenceRuntimeIdentity.decode(candidate) else { return false }
        return current.finalTransport == candidate.finalTransport
            && current.runtimeRevision != candidate.runtimeRevision
    }

    private func forwardPortCapabilityPreferencesIfNeeded(
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        skillID: UUID?,
        transportIdentity: String
    ) {
        guard !modelID.isEmpty,
              CapabilityPreferenceRuntimeIdentity.decode(transportIdentity) != nil else { return }
        if let conversationID {
            forwardPortCapabilityScope(
                .conversationConnectionModel, providerID: providerID, modelID: modelID,
                conversationID: conversationID, skillID: nil, transportIdentity: transportIdentity
            )
        }
        if let skillID {
            forwardPortCapabilityScope(
                .skillAgent, providerID: providerID, modelID: modelID,
                conversationID: nil, skillID: skillID, transportIdentity: transportIdentity
            )
        }
        for scope: CapabilityPreferenceScope in [.connectionModel, .connection] {
            forwardPortCapabilityScope(
                scope, providerID: providerID, modelID: modelID,
                conversationID: nil, skillID: nil, transportIdentity: transportIdentity
            )
        }
    }

    private func forwardPortCapabilityScope(
        _ scope: CapabilityPreferenceScope,
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        skillID: UUID?,
        transportIdentity: String
    ) {
        lock.lock()
        let records = capabilityRecordsLocked()
        let matches: (CapabilityRecord) -> Bool = {
            $0.scope == scope && $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == conversationID && $0.skillID == skillID
        }
        let hasCurrent = records.contains { matches($0) && $0.transportIdentity == transportIdentity }
        let candidate = records
            .filter { matches($0) && Self.isSameTransportLineage(transportIdentity, $0.transportIdentity) }
            .max { ($0.updatedAt, $0.revision) < ($1.updatedAt, $1.revision) }
        lock.unlock()

        guard !hasCurrent, let candidate else { return }
        let target = CapabilityRecord(
            scope: scope, providerID: providerID, modelID: modelID, conversationID: conversationID,
            skillID: skillID, transportIdentity: transportIdentity, values: .init(),
            updatedAt: Date(), revision: 0, mutationID: ""
        )
        guard CapabilityPreferenceSyncLedger.revision(
            for: CapabilityPreferenceSyncContract.recordID(for: target), defaults: defaults
        ) == 0 else { return }

        if scope == .connection {
            setConnectionCapabilityPreferences(
                candidate.values, providerID: providerID, modelID: modelID,
                transportIdentity: transportIdentity
            )
        } else {
            setCapabilityPreferences(
                candidate.values, providerID: providerID, modelID: modelID,
                conversationID: conversationID, skillID: skillID, transportIdentity: transportIdentity
            )
        }
    }

    private func forwardPortLocalCustomIfNeeded(
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        transportIdentity: String,
        namespace: String,
        context: CapabilityLocalCustomForwardPortContext
    ) {
        guard let identity = CapabilityPreferenceRuntimeIdentity.decode(transportIdentity),
              let owner = Self.localCustomOwnerNamespaces.first(where: { $0.namespace == namespace })?.owner
        else { return }
        lock.lock()
        let records = localCustomRecordsLocked()
        let matches: (LocalCustomFragmentRecord) -> Bool = {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == conversationID && $0.namespace == namespace
        }
        let hasCurrent = records.contains { matches($0) && $0.transportIdentity == transportIdentity }
        let candidate = records
            .filter { matches($0) && Self.isSameTransportLineage(transportIdentity, $0.transportIdentity) }
            .max { $0.updatedAt < $1.updatedAt }
        lock.unlock()

        guard !hasCurrent, let candidate else { return }
        let staysCustom: Bool
        if (candidate.mode ?? .custom) == .custom {
            staysCustom = {
                if case .success = CapabilityRecipeExecution.redactedSafeCustomPreview(
                    raw: candidate.rawJSON, owner: owner, providerKind: context.providerKind,
                    modelID: context.schemaModelID, transport: identity.finalTransport
                ) { return true }
                return false
            }()
        } else {
            staysCustom = false
        }
        setLocalCustomConfiguration(
            .init(mode: staysCustom ? .custom : .automatic, rawJSON: candidate.rawJSON),
            providerID: providerID, modelID: modelID, conversationID: conversationID,
            transportIdentity: transportIdentity, namespace: namespace
        )
    }

    static let localCustomOwnerNamespaces: [(owner: String, namespace: String)] = [
        ("web", "webPatch"),
        ("reasoning", "reasoningPatch"),
        ("generation", "generationPatch"),
    ]

    func isSkillAgentCapabilityConfirmed(
        providerID: UUID,
        modelID: String,
        skillID: UUID,
        transportIdentity: String
    ) -> Bool {
        forwardPortCapabilityPreferencesIfNeeded(
            providerID: providerID, modelID: modelID, conversationID: nil,
            skillID: skillID, transportIdentity: transportIdentity
        )
        return capabilityPreferences(
            providerID: providerID, modelID: modelID, conversationID: nil,
            skillID: skillID, transportIdentity: transportIdentity
        ) != nil
    }

    /// An explicit confirmation from Skill editing writes this record. There is no Skill API marker:
    /// the sync envelope is the durable cross-device source of truth.
    func confirmSkillAgentCapabilityPreferences(
        _ values: CapabilityPreferenceValues,
        skillID: UUID,
        providerID: UUID,
        modelID: String,
        transportIdentity: String
    ) {
        setCapabilityPreferences(
            values, providerID: providerID, modelID: modelID, conversationID: nil,
            skillID: skillID, transportIdentity: transportIdentity
        )
    }

    /// The raw JSON escape hatch is deliberately local-only. It is isolated by the same complete
    /// connection/model/transport identity but not exported, merged, logged or published to Firestore.
    func localCustomFragment(
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        transportIdentity: String,
        namespace: String
    ) -> String? {
        guard !transportIdentity.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return localCustomRecordsLocked().filter {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == conversationID && $0.transportIdentity == transportIdentity
                && $0.namespace == namespace
        }.max { $0.updatedAt < $1.updatedAt }?.rawJSON
    }

    func localCustomConfiguration(
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        transportIdentity: String,
        namespace: String
    ) -> LocalCustomFragmentConfiguration {
        guard !transportIdentity.isEmpty else {
            return .init(mode: .automatic, rawJSON: "")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let record = localCustomRecordsLocked().filter({
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == conversationID && $0.transportIdentity == transportIdentity
                && $0.namespace == namespace
        }).max(by: { $0.updatedAt < $1.updatedAt }) else {
            return .init(mode: .automatic, rawJSON: "")
        }
        return .init(mode: record.mode ?? .custom, rawJSON: record.rawJSON)
    }

    func effectiveLocalCustomConfiguration(
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        transportIdentity: String,
        namespace: String,
        forwardPort: CapabilityLocalCustomForwardPortContext? = nil
    ) -> LocalCustomFragmentConfiguration {
        guard !transportIdentity.isEmpty else { return .init(mode: .automatic, rawJSON: "") }
        if let forwardPort {
            forwardPortLocalCustomIfNeeded(
                providerID: providerID, modelID: modelID, conversationID: conversationID,
                transportIdentity: transportIdentity, namespace: namespace, context: forwardPort
            )
            if conversationID != nil {
                forwardPortLocalCustomIfNeeded(
                    providerID: providerID, modelID: modelID, conversationID: nil,
                    transportIdentity: transportIdentity, namespace: namespace, context: forwardPort
                )
            }
        }
        lock.lock()
        defer { lock.unlock() }
        let records = localCustomRecordsLocked()
        func latest(_ scope: UUID?) -> LocalCustomFragmentRecord? {
            records.filter {
                $0.providerID == providerID && $0.modelID == modelID
                    && $0.conversationID == scope && $0.transportIdentity == transportIdentity
                    && $0.namespace == namespace
            }.max { $0.updatedAt < $1.updatedAt }
        }
        if let record = latest(conversationID) {
            return .init(mode: record.mode ?? .custom, rawJSON: record.rawJSON)
        }
        guard conversationID != nil, let fallback = latest(nil) else {
            return .init(mode: .automatic, rawJSON: "")
        }
        return .init(mode: fallback.mode ?? .custom, rawJSON: fallback.rawJSON)
    }

    /// Produces only the process-local fragments for the real send boundary. The only condition is
    /// attached so the final compiler fails closed instead of sending a downgraded request.
    func activeLocalCustomFragments(
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        transportIdentity: String,
        forwardPort: CapabilityLocalCustomForwardPortContext? = nil
    ) -> [SafeCustomBodyFragment] {
        Self.localCustomOwnerNamespaces.compactMap { owner, namespace in
            let configuration = effectiveLocalCustomConfiguration(
                providerID: providerID, modelID: modelID, conversationID: conversationID,
                transportIdentity: transportIdentity, namespace: namespace, forwardPort: forwardPort
            )
            guard configuration.mode == .custom else { return nil }
            return .init(raw: configuration.rawJSON, owner: owner, declaredOwners: [:])
        }
    }

    func setLocalCustomConfiguration(
        _ configuration: LocalCustomFragmentConfiguration?,
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        transportIdentity: String,
        namespace: String
    ) {
        guard !transportIdentity.isEmpty,
              ["webPatch", "reasoningPatch", "generationPatch"].contains(namespace) else { return }
        lock.lock()
        defer { lock.unlock() }
        var records = localCustomRecordsLocked()
        records.removeAll {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == conversationID && $0.transportIdentity == transportIdentity
                && $0.namespace == namespace
        }
        if let configuration {
            records.append(.init(
                providerID: providerID, modelID: modelID, conversationID: conversationID,
                transportIdentity: transportIdentity, namespace: namespace,
                rawJSON: configuration.rawJSON, mode: configuration.mode, updatedAt: Date()
            ))
        }
        writeLocalCustomRecordsLocked(records)
    }

    func migrateLocalCustomConfiguration(
        providerID: UUID,
        modelID: String,
        from draftConversationID: UUID,
        to conversationID: UUID,
        transportIdentity: String
    ) {
        guard !transportIdentity.isEmpty, draftConversationID != conversationID else { return }
        lock.lock()
        defer { lock.unlock() }
        var records = localCustomRecordsLocked()
        let moved = records.filter {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == draftConversationID
                && $0.transportIdentity == transportIdentity
        }
        guard !moved.isEmpty else { return }
        let occupied = Set(records.filter {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == conversationID
                && $0.transportIdentity == transportIdentity
        }.map(\.namespace))
        records.removeAll {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == draftConversationID
                && $0.transportIdentity == transportIdentity
        }
        for record in moved where !occupied.contains(record.namespace) {
            records.append(.init(
                providerID: record.providerID, modelID: record.modelID,
                conversationID: conversationID, transportIdentity: record.transportIdentity,
                namespace: record.namespace, rawJSON: record.rawJSON, mode: record.mode,
                updatedAt: record.updatedAt
            ))
        }
        writeLocalCustomRecordsLocked(records)
    }

    func setLocalCustomFragment(
        _ rawJSON: String?,
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        transportIdentity: String,
        namespace: String
    ) {
        guard !transportIdentity.isEmpty, ["webPatch", "reasoningPatch", "generationPatch"].contains(namespace) else { return }
        lock.lock()
        defer { lock.unlock() }
        var records = localCustomRecordsLocked()
        records.removeAll {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == conversationID && $0.transportIdentity == transportIdentity
                && $0.namespace == namespace
        }
        if let rawJSON, !rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            records.append(.init(
                providerID: providerID, modelID: modelID, conversationID: conversationID,
                transportIdentity: transportIdentity, namespace: namespace, rawJSON: rawJSON,
                mode: .custom, updatedAt: Date()
            ))
        }
        writeLocalCustomRecordsLocked(records)
    }

    /// Draft conversation preferences follow the existing parameter-store migration rule.
    func migrateCapabilitySession(
        providerID: UUID,
        modelID: String,
        from sourceConversationID: UUID,
        to destinationConversationID: UUID,
        transportIdentity: String
    ) {
        guard sourceConversationID != destinationConversationID, !transportIdentity.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var records = capabilityRecordsLocked()
        let source = records.first(where: {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == sourceConversationID && $0.transportIdentity == transportIdentity
        })
        if let source {
            records.removeAll {
                $0.providerID == providerID && $0.modelID == modelID
                    && ($0.conversationID == sourceConversationID || $0.conversationID == destinationConversationID)
                    && $0.transportIdentity == transportIdentity
            }
            CapabilityPreferenceSyncLedger.put(.init(
                recordId: CapabilityPreferenceSyncContract.recordID(for: source),
                revision: source.revision + 1, mutationId: UUID().uuidString.lowercased()
            ), defaults: defaults)
            records.append(.init(
                scope: .conversationConnectionModel, providerID: providerID, modelID: modelID, conversationID: destinationConversationID, skillID: nil,
                transportIdentity: transportIdentity, values: source.values, updatedAt: Date(),
                revision: source.revision + 1, mutationID: UUID().uuidString.lowercased()
            ))
            writeCapabilityRecordsLocked(records)
        }
        // raw fragments never leave this device, but a draft becoming a real conversation is
        // the same local identity migration. Leaving it on the draft would silently lose it.
        var fragments = localCustomRecordsLocked()
        let sourceFragments = fragments.filter {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == sourceConversationID && $0.transportIdentity == transportIdentity
        }
        fragments.removeAll {
            $0.providerID == providerID && $0.modelID == modelID
                && ($0.conversationID == sourceConversationID || $0.conversationID == destinationConversationID)
                && $0.transportIdentity == transportIdentity
        }
        fragments.append(contentsOf: sourceFragments.map {
            .init(providerID: $0.providerID, modelID: $0.modelID, conversationID: destinationConversationID,
                  transportIdentity: $0.transportIdentity, namespace: $0.namespace, rawJSON: $0.rawJSON,
                  mode: $0.mode, updatedAt: Date())
        })
        writeLocalCustomRecordsLocked(fragments)
    }

    /// Provider/conversation/model deletion retires both typed records and local raw fragments.
    /// Typed records immediately emit versioned tombstones for cross-device convergence; raw
    /// fragments remain local-only and are never exported.
    func removeCapabilityScopes(providerID: UUID? = nil, modelID: String? = nil, conversationID: UUID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let matches: (CapabilityRecord) -> Bool = { record in
            (providerID == nil || record.providerID == providerID)
                && (modelID == nil || record.modelID == modelID)
                && (conversationID == nil || record.conversationID == conversationID)
        }
        let existing = capabilityRecordsLocked()
        for record in existing where matches(record) {
            CapabilityPreferenceSyncLedger.put(.init(
                recordId: CapabilityPreferenceSyncContract.recordID(for: record),
                revision: record.revision + 1, mutationId: UUID().uuidString.lowercased()
            ), defaults: defaults)
        }
        writeCapabilityRecordsLocked(existing.filter { !matches($0) })
        writeLocalCustomRecordsLocked(localCustomRecordsLocked().filter { record in
            (providerID != nil && record.providerID != providerID)
                || (modelID != nil && record.modelID != modelID)
                || (conversationID != nil && record.conversationID != conversationID)
        })
    }

    func clearLocalCustomCapabilityFragments() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: localCustomStorageKey)
    }

    func resetForAccountBoundary() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: capabilityStorageKey)
        defaults.removeObject(forKey: localCustomStorageKey)
        GenerationParameterSyncLedger.removeAll(defaults: defaults)
        CapabilityPreferenceSyncLedger.removeAll(defaults: defaults)
    }

    func activeOverrideParameterIDs(
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        profileFingerprint: String? = nil,
        activeParameterIDs: Set<String>? = nil
    ) -> Set<String> {
        let session = conversationID.flatMap {
            sessionOverrides(
                providerID: providerID, modelID: modelID, conversationID: $0,
                profileFingerprint: profileFingerprint
            )?.values
        } ?? [:]
        let defaults = modelDefaults(
            providerID: providerID, modelID: modelID, profileFingerprint: profileFingerprint
        )?.values ?? [:]
        var merged = defaults
        for (key, value) in session { merged[key] = value }
        return Set(merged.compactMap { key, override in
            guard override.state != .inherit,
                  activeParameterIDs?.contains(key) ?? true else { return nil }
            return key
        })
    }

    func hasSessionOverrides(
        providerID: UUID,
        modelID: String,
        conversationID: UUID,
        profileFingerprint: String? = nil,
        activeParameterIDs: Set<String>? = nil
    ) -> Bool {
        guard let values = sessionOverrides(
            providerID: providerID,
            modelID: modelID,
            conversationID: conversationID,
            profileFingerprint: profileFingerprint
        )?.values else { return false }
        return values.contains { key, override in
            override.state != .inherit && (activeParameterIDs?.contains(key) ?? true)
        }
    }

    func migrateSession(
        providerID: UUID,
        modelID: String,
        from sourceConversationID: UUID,
        to destinationConversationID: UUID,
        profileFingerprint: String? = nil
    ) {
        guard sourceConversationID != destinationConversationID else { return }
        lock.lock()
        defer { lock.unlock() }
        var current = readRecordsLocked()
        guard let source = Self.latest(current, where: {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == sourceConversationID
        }) else { return }
        current.removeAll {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == sourceConversationID
        }
        let destination = Self.latest(current) {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == destinationConversationID
        }
        current.removeAll {
            $0.providerID == providerID && $0.modelID == modelID
                && $0.conversationID == destinationConversationID
        }
        GenerationParameterSyncLedger.putTombstone(
            recordID: Self.recordID(for: source),
            revision: (source.revision ?? 0) + 1,
            defaults: defaults
        )
        let migrated = Record(
            scope: "conversation_override",
            providerID: providerID,
            modelID: modelID,
            conversationID: destinationConversationID,
            profileFingerprint: profileFingerprint,
            values: source.values,
            updatedAt: Date(),
            revision: (destination?.revision ?? 0) + 1,
            mutationID: UUID().uuidString
        )
        current.append(migrated)
        GenerationParameterSyncLedger.clear(recordID: Self.recordID(for: migrated), defaults: defaults)
        writeRecordsLocked(capped(current))
    }

    func removeScopes(providerID: UUID? = nil, modelID: String? = nil, conversationID: UUID? = nil) {
        guard providerID != nil || modelID != nil || conversationID != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        let all = readRecordsLocked()
        let removed = all.filter { record in
            let matches = (providerID == nil || record.providerID == providerID)
                && (modelID == nil || record.modelID == modelID)
                && (conversationID == nil || record.conversationID == conversationID)
            return matches
        }
        let current = all.filter { record in
            !removed.contains(record)
        }
        for record in removed {
            GenerationParameterSyncLedger.putTombstone(
                recordID: Self.recordID(for: record),
                revision: (record.revision ?? 0) + 1,
                defaults: defaults
            )
        }
        writeRecordsLocked(current)
    }

    func resolve(
        transient: GenerationParameterOverrides?,
        providerID: UUID,
        modelID: String,
        conversationID: UUID,
        profileFingerprint: String? = nil,
        reasoningMode: ReasoningMode? = nil,
        activeParameterIDs: Set<String>? = nil
    ) -> GenerationParameterOverrides? {
        let allowConnectionReasoning = (reasoningMode ?? .automatic) == .automatic
        let layers: [(values: GenerationParameterOverrides?, allowsReasoning: Bool, filtersDormant: Bool)] = [
            (transient, false, false),
            (sessionOverrides(providerID: providerID, modelID: modelID, conversationID: conversationID, profileFingerprint: profileFingerprint), false, true),
            (modelDefaults(providerID: providerID, modelID: modelID, profileFingerprint: profileFingerprint), allowConnectionReasoning, true),
            (connectionDefaults(providerID: providerID), allowConnectionReasoning, true),
        ]
        var resolved: [String: GenerationParameterOverride] = [:]
        for layer in layers {
            guard let values = layer.values?.values else { continue }
            for (key, value) in values where resolved[key] == nil && value.state != .inherit {
                guard layer.allowsReasoning || !Self.reasoningParameterIDs.contains(key) else { continue }
                if layer.filtersDormant, let activeParameterIDs, !activeParameterIDs.contains(key) { continue }
                resolved[key] = value
            }
        }
        return resolved.isEmpty ? nil : GenerationParameterOverrides(values: resolved)
    }

    private func replace(
        _ values: GenerationParameterOverrides?,
        providerID: UUID,
        modelID: String,
        conversationID: UUID?,
        profileFingerprint: String?,
        scope: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        var current = readRecordsLocked()
        let isSameScope: (Record) -> Bool = { record in
            record.providerID == providerID && record.modelID == modelID
                && record.conversationID == conversationID && Self.effectiveScope(record) == scope
        }
        let matches = current.filter(isSameScope)
        current.removeAll(where: isSameScope)
        let baseRevision = matches.compactMap(\.revision).max() ?? 0
        if let values, values.values.values.contains(where: { $0.state != .inherit }) {
            let record = Record(
                scope: scope,
                providerID: providerID,
                modelID: modelID,
                conversationID: conversationID,
                profileFingerprint: profileFingerprint,
                values: values,
                updatedAt: Date(),
                revision: baseRevision + 1,
                mutationID: UUID().uuidString
            )
            current.append(record)
            GenerationParameterSyncLedger.clear(recordID: Self.recordID(for: record), defaults: defaults)
        } else if let existing = matches.first {
            GenerationParameterSyncLedger.putTombstone(
                recordID: Self.recordID(for: existing),
                revision: baseRevision + 1,
                defaults: defaults
            )
        }
        writeRecordsLocked(capped(current))
    }

    private func records() -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        return readRecordsLocked()
    }

    private func readRecordsLocked(includeExpired: Bool = false) -> [Record] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        guard !includeExpired else { return records }
        let cutoff = Date().addingTimeInterval(-recordTTL)
        return records.filter { ($0.updatedAt ?? .distantFuture) >= cutoff }
    }

    private func capped(_ records: [Record]) -> [Record] {
        Array(records.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }.prefix(maximumRecordCount))
    }

    private func writeRecordsLocked(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
        GenerationParameterSyncPublisher.localDidChange()
    }

    private func capabilityRecordsLocked() -> [CapabilityRecord] {
        guard let data = defaults.data(forKey: capabilityStorageKey) else { return [] }
        return (try? JSONDecoder().decode([CapabilityRecord].self, from: data)) ?? []
    }

    private func writeCapabilityRecordsLocked(_ records: [CapabilityRecord]) {
        let capped = Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(maximumRecordCount))
        guard let data = try? JSONEncoder().encode(capped) else { return }
        defaults.set(data, forKey: capabilityStorageKey)
        CapabilityPreferenceSyncPublisher.localDidChange()
    }

    private func localCustomRecordsLocked() -> [LocalCustomFragmentRecord] {
        guard let data = defaults.data(forKey: localCustomStorageKey) else { return [] }
        return (try? JSONDecoder().decode([LocalCustomFragmentRecord].self, from: data)) ?? []
    }

    private func writeLocalCustomRecordsLocked(_ records: [LocalCustomFragmentRecord]) {
        let capped = Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(maximumRecordCount))
        guard let data = try? JSONEncoder().encode(capped) else { return }
        defaults.set(data, forKey: localCustomStorageKey)
        // Do not call the sync publisher: custom raw JSON must have no cloud/export/telemetry path.
    }

    fileprivate func capabilitySyncRecords() -> [CapabilityRecord] {
        lock.lock()
        defer { lock.unlock() }
        return capabilityRecordsLocked()
    }

    fileprivate func replaceCapabilitySyncRecords(_ records: [CapabilityRecord]) {
        lock.lock()
        defer { lock.unlock() }
        // Schema-v1/raw transport identities stay on-device as dormant history. A v2 merge must
        // neither activate nor delete them; only a later explicit confirmation writes a complete
        // r1 identity. They are deliberately excluded from export and resolver reads above.
        let dormantLegacy = capabilityRecordsLocked().filter {
            $0.modelID.isEmpty || CapabilityPreferenceRuntimeIdentity.decode($0.transportIdentity) == nil
        }
        writeCapabilityRecordsLocked(dormantLegacy + records)
    }

    fileprivate func syncRecords() -> [Record] { records() }

    fileprivate func rawSyncRecords() -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        return readRecordsLocked(includeExpired: true)
    }

    fileprivate func replaceSyncRecords(_ records: [Record]) {
        lock.lock()
        defer { lock.unlock() }
        writeRecordsLocked(capped(records))
    }

    private static func latest(_ records: [Record], where predicate: (Record) -> Bool) -> Record? {
        records.filter(predicate).max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
    }

    fileprivate static func effectiveScope(_ record: Record) -> String {
        record.scope ?? (record.conversationID == nil ? "model_default" : "conversation_override")
    }

    fileprivate static func recordID(for record: Record) -> String {
        switch effectiveScope(record) {
        case "connection_default":
            return "scope:connection:\(record.providerID.uuidString.lowercased())"
        case "conversation_override":
            return "scope:conversation:\(record.providerID.uuidString.lowercased()):\(record.modelID):\(record.conversationID?.uuidString.lowercased() ?? "")"
        default:
            return "scope:model:\(record.providerID.uuidString.lowercased()):\(record.modelID)"
        }
    }

    static func portableProfileKey(_ fingerprint: String?) -> String? {
        guard let fingerprint, !fingerprint.isEmpty else { return nil }
        let components = fingerprint.split(separator: "|", omittingEmptySubsequences: false)
        return components.count > 1 ? components.dropFirst().joined(separator: "|") : fingerprint
    }

    private static let reasoningParameterIDs: Set<String> = ["reasoning_effort", "reasoning_budget", "reasoning_mode"]
}

nonisolated struct GenerationParameterSyncTombstone: Codable, Equatable, Sendable {
    let recordId: String
    let revision: Int
    let mutationId: String
}

enum GenerationParameterSyncLedger {
    private static let lock = NSLock()
    private static let key = "generation_parameter_sync_tombstones.v1"

    static func all(defaults: UserDefaults = .standard) -> [GenerationParameterSyncTombstone] {
        lock.lock(); defer { lock.unlock() }
        return readLocked(defaults: defaults)
    }

    static func replace(_ values: [GenerationParameterSyncTombstone], defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        writeLocked(Array(values.suffix(300)), defaults: defaults)
    }

    static func putTombstone(
        recordID: String,
        revision: Int,
        defaults: UserDefaults = .standard
    ) {
        lock.lock(); defer { lock.unlock() }
        var values = readLocked(defaults: defaults).filter { $0.recordId != recordID }
        values.append(.init(
            recordId: recordID,
            revision: max(1, revision),
            mutationId: UUID().uuidString.lowercased()
        ))
        writeLocked(Array(values.suffix(300)), defaults: defaults)
    }

    static func clear(recordID: String, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        writeLocked(readLocked(defaults: defaults).filter { $0.recordId != recordID }, defaults: defaults)
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }

    private static func readLocked(defaults: UserDefaults) -> [GenerationParameterSyncTombstone] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([GenerationParameterSyncTombstone].self, from: data)) ?? []
    }

    private static func writeLocked(_ values: [GenerationParameterSyncTombstone], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
    }
}

nonisolated struct GenerationParameterSyncRecord: Codable, Equatable, Sendable {
    let recordId: String
    let scope: String
    let providerId: String
    let modelId: String?
    let conversationId: String?
    let profileKey: String?
    let values: [String: GenerationParameterOverride]
    let revision: Int
    let mutationId: String
}

nonisolated struct GenerationParameterSyncPreset: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let providerId: String
    let modelId: String
    let profileKey: String
    let values: [String: GenerationParameterOverride]
    let createdAt: String
    let revision: Int
    let mutationId: String
}

nonisolated struct GenerationParameterSyncPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let records: [GenerationParameterSyncRecord]
    let presets: [GenerationParameterSyncPreset]
    let tombstones: [GenerationParameterSyncTombstone]
}

extension GenerationParameterSyncPayload {
    var isEmptyEnvelope: Bool { records.isEmpty && presets.isEmpty && tombstones.isEmpty }
}

enum GenerationParameterSyncContract {
    private struct TimestampSnapshot {
        let updatedAt: Date?
    }

    private enum Candidate {
        case record(GenerationParameterSyncRecord)
        case preset(GenerationParameterSyncPreset)
        case tombstone(GenerationParameterSyncTombstone)

        var revision: Int {
            switch self {
            case .record(let value): return value.revision
            case .preset(let value): return value.revision
            case .tombstone(let value): return value.revision
            }
        }

        var mutationID: String {
            switch self {
            case .record(let value): return value.mutationId
            case .preset(let value): return value.mutationId
            case .tombstone(let value): return value.mutationId
            }
        }
    }

    static func exportPayload(
        settings: GenerationParameterSettingsStore = .shared,
        presets presetStore: GenerationParameterPresetStore = .shared,
        defaults: UserDefaults = .standard
    ) -> GenerationParameterSyncPayload {
        let records = settings.syncRecords().compactMap { record -> GenerationParameterSyncRecord? in
            let values = safeValues(record.values.values)
            guard !values.isEmpty else { return nil }
            return .init(
                recordId: GenerationParameterSettingsStore.recordID(for: record),
                scope: GenerationParameterSettingsStore.effectiveScope(record),
                providerId: record.providerID.uuidString.lowercased(),
                modelId: record.scope == "connection_default" ? nil : record.modelID,
                conversationId: record.conversationID?.uuidString.lowercased(),
                profileKey: record.syncProfileKey
                    ?? GenerationParameterSettingsStore.portableProfileKey(record.profileFingerprint),
                values: values,
                revision: max(1, record.revision ?? 1),
                mutationId: record.mutationID ?? "legacy"
            )
        }
        let presets = presetStore.syncRecords().compactMap { preset -> GenerationParameterSyncPreset? in
            let values = safeValues(preset.values.values)
            let profileKey = preset.syncProfileKey
                ?? GenerationParameterSettingsStore.portableProfileKey(preset.profileFingerprint)
            guard !values.isEmpty, let profileKey, !profileKey.isEmpty else { return nil }
            return .init(
                id: preset.id.uuidString.lowercased(),
                name: String(preset.name.prefix(80)),
                providerId: preset.providerID.uuidString.lowercased(),
                modelId: preset.modelID,
                profileKey: profileKey,
                values: values,
                createdAt: ISO8601DateFormatter.generationParameters.string(from: preset.createdAt),
                revision: max(1, preset.revision ?? 1),
                mutationId: preset.mutationID ?? "legacy"
            )
        }
        return .init(
            schemaVersion: 1,
            records: Array(records.sorted { $0.recordId < $1.recordId }.prefix(200)),
            presets: Array(presets.sorted { $0.id < $1.id }.prefix(100)),
            tombstones: Array(GenerationParameterSyncLedger.all(defaults: defaults).sorted { $0.recordId < $1.recordId }.suffix(300))
        )
    }

    static func exportJSON(
        settings: GenerationParameterSettingsStore = .shared,
        presets: GenerationParameterPresetStore = .shared,
        defaults: UserDefaults = .standard
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(exportPayload(settings: settings, presets: presets, defaults: defaults))
    }

    static func merge(
        _ remote: GenerationParameterSyncPayload,
        settings: GenerationParameterSettingsStore = .shared,
        presets presetStore: GenerationParameterPresetStore = .shared,
        defaults: UserDefaults = .standard
    ) -> GenerationParameterSyncPayload {
        var previousRecordTimestamps: [String: TimestampSnapshot] = [:]
        for record in settings.rawSyncRecords() {
            previousRecordTimestamps[syncVersionKey(
                recordID: GenerationParameterSettingsStore.recordID(for: record),
                revision: max(1, record.revision ?? 1),
                mutationID: record.mutationID ?? "legacy"
            )] = .init(updatedAt: record.updatedAt)
        }
        var previousPresetTimestamps: [String: Date] = [:]
        for preset in presetStore.syncRecords() {
            previousPresetTimestamps[syncVersionKey(
                recordID: "preset:\(preset.id.uuidString.lowercased())",
                revision: max(1, preset.revision ?? 1),
                mutationID: preset.mutationID ?? "legacy"
            )] = preset.updatedAt
        }
        let local = exportPayload(settings: settings, presets: presetStore, defaults: defaults)
        var candidates: [String: Candidate] = [:]
        func put(_ id: String, _ value: Candidate) {
            guard let current = candidates[id] else { candidates[id] = value; return }
            if value.revision > current.revision
                || (value.revision == current.revision && value.mutationID > current.mutationID) {
                candidates[id] = value
            }
        }
        for value in local.records { put(canonicalSyncID(value.recordId), .record(value)) }
        for value in local.presets { put("preset:\(canonicalSyncID(value.id))", .preset(value)) }
        for value in local.tombstones {
            let canonical = canonicalSyncID(value.recordId)
            put(canonical, .tombstone(.init(recordId: canonical, revision: value.revision, mutationId: value.mutationId)))
        }
        for value in remote.records.compactMap({ normalized($0) }) { put(value.recordId, .record(value)) }
        for value in remote.presets.compactMap({ normalized($0) }) { put("preset:\(value.id)", .preset(value)) }
        for value in remote.tombstones where value.revision > 0 && !value.recordId.isEmpty && !value.mutationId.isEmpty {
            let canonical = canonicalSyncID(value.recordId)
            put(canonical, .tombstone(.init(recordId: canonical, revision: value.revision, mutationId: value.mutationId)))
        }

        var mergedRecords: [GenerationParameterSyncRecord] = []
        var mergedPresets: [GenerationParameterSyncPreset] = []
        var mergedTombstones: [GenerationParameterSyncTombstone] = []
        for candidate in candidates.values {
            switch candidate {
            case .record(let value): mergedRecords.append(value)
            case .preset(let value): mergedPresets.append(value)
            case .tombstone(let value): mergedTombstones.append(value)
            }
        }
        let merged = GenerationParameterSyncPayload(
            schemaVersion: 1,
            records: Array(mergedRecords.sorted { $0.recordId < $1.recordId }.prefix(200)),
            presets: Array(mergedPresets.sorted { $0.id < $1.id }.prefix(100)),
            tombstones: Array(mergedTombstones.sorted { $0.recordId < $1.recordId }.suffix(300))
        )
        let mergedAt = Date()
        settings.replaceSyncRecords(merged.records.compactMap { value in
            guard let providerID = UUID(uuidString: value.providerId) else { return nil }
            let timestampKey = syncVersionKey(
                recordID: value.recordId,
                revision: value.revision,
                mutationID: value.mutationId
            )
            let updatedAt: Date?
            if let previous = previousRecordTimestamps[timestampKey] {
                updatedAt = previous.updatedAt
            } else {
                updatedAt = mergedAt
            }
            return .init(
                scope: value.scope,
                providerID: providerID,
                modelID: value.modelId ?? "*",
                conversationID: value.conversationId.flatMap(UUID.init(uuidString:)),
                profileFingerprint: nil,
                syncProfileKey: value.profileKey,
                values: .init(values: value.values),
                updatedAt: updatedAt,
                revision: value.revision,
                mutationID: value.mutationId
            )
        })
        presetStore.replaceSyncRecords(merged.presets.compactMap { value in
            guard let id = UUID(uuidString: value.id), let providerID = UUID(uuidString: value.providerId) else { return nil }
            let timestampKey = syncVersionKey(
                recordID: "preset:\(value.id)",
                revision: value.revision,
                mutationID: value.mutationId
            )
            return .init(
                id: id,
                name: value.name,
                providerID: providerID,
                modelID: value.modelId,
                profileFingerprint: "",
                syncProfileKey: value.profileKey,
                values: .init(values: value.values),
                createdAt: ISO8601DateFormatter.generationParameters.date(from: value.createdAt) ?? Date(),
                updatedAt: previousPresetTimestamps[timestampKey] ?? mergedAt,
                revision: value.revision,
                mutationID: value.mutationId
            )
        })
        GenerationParameterSyncLedger.replace(merged.tombstones, defaults: defaults)
        return merged
    }

    static func importJSON(
        _ data: Data,
        settings: GenerationParameterSettingsStore = .shared,
        presets: GenerationParameterPresetStore = .shared,
        defaults: UserDefaults = .standard
    ) throws -> GenerationParameterSyncPayload {
        let remote = try JSONDecoder().decode(GenerationParameterSyncPayload.self, from: data)
        guard remote.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return merge(remote, settings: settings, presets: presets, defaults: defaults)
    }

    static func decodeFirestore(_ raw: Any) -> GenerationParameterSyncPayload? {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let payload = try? JSONDecoder().decode(GenerationParameterSyncPayload.self, from: data),
              payload.schemaVersion == 1 else { return nil }
        return payload
    }

    static func foundationValue(_ payload: GenerationParameterSyncPayload) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(payload),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value
    }

    static let uuidSegmentPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"#

    static func canonicalSyncID(_ raw: String) -> String {
        raw.split(separator: ":", omittingEmptySubsequences: false)
            .map { segment -> String in
                let value = String(segment)
                return value.range(of: uuidSegmentPattern, options: .regularExpression) == nil
                    ? value
                    : value.lowercased()
            }
            .joined(separator: ":")
    }

    private static func syncVersionKey(recordID: String, revision: Int, mutationID: String) -> String {
        "\(canonicalSyncID(recordID))\u{0}\(revision)\u{0}\(mutationID)"
    }

    private static func normalized(_ value: GenerationParameterSyncRecord) -> GenerationParameterSyncRecord? {
        guard ["connection_default", "model_default", "conversation_override"].contains(value.scope),
              UUID(uuidString: value.providerId) != nil, value.revision > 0, !value.mutationId.isEmpty,
              value.scope == "connection_default" || value.modelId?.isEmpty == false,
              value.scope != "conversation_override" || value.conversationId.flatMap(UUID.init(uuidString:)) != nil else { return nil }
        let values = safeValues(value.values)
        guard !values.isEmpty else { return nil }
        return .init(
            recordId: canonicalSyncID(value.recordId),
            scope: value.scope,
            providerId: value.providerId.lowercased(),
            modelId: value.modelId,
            conversationId: value.conversationId?.lowercased(),
            profileKey: value.profileKey,
            values: values,
            revision: value.revision,
            mutationId: value.mutationId
        )
    }

    private static func normalized(_ value: GenerationParameterSyncPreset) -> GenerationParameterSyncPreset? {
        guard UUID(uuidString: value.id) != nil, UUID(uuidString: value.providerId) != nil,
              !value.modelId.isEmpty, !value.profileKey.isEmpty, value.revision > 0, !value.mutationId.isEmpty else { return nil }
        let values = safeValues(value.values)
        guard !values.isEmpty else { return nil }
        return .init(
            id: value.id.lowercased(),
            name: String(value.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)),
            providerId: value.providerId.lowercased(),
            modelId: value.modelId,
            profileKey: value.profileKey,
            values: values,
            createdAt: value.createdAt,
            revision: value.revision,
            mutationId: value.mutationId
        )
    }

    private static func safeValues(
        _ values: [String: GenerationParameterOverride]
    ) -> [String: GenerationParameterOverride] {
        let excluded: Set<String> = [
            "context_length", "keep_alive", "speculative_decoding", "prompt_cache", "cache_reuse", "stop", "json_schema",
        ]
        return values.filter { key, override in
            guard key.range(of: #"^[a-z][a-z0-9_]{0,63}$"#, options: .regularExpression) != nil,
                  !key.hasPrefix("custom_"), !excluded.contains(key) else { return false }
            guard override.state == .value else { return true }
            switch override.value {
            case .number, .boolean: return true
            case .string(let value):
                return value.count <= 64
                    && value.range(of: #"^[a-zA-Z0-9_.:-]+$"#, options: .regularExpression) != nil
            default: return false
            }
        }
    }
}

/// Independent envelope. `generation_parameter_sync.v1` remains byte-for-byte v1;
/// this shape contains typed preferences only and intentionally has no `custom` field.
nonisolated struct CapabilityPreferenceSyncRecord: Codable, Equatable, Sendable {
    let recordId: String
    let scope: String
    let providerId: String
    let modelId: String?
    let conversationId: String?
    let skillId: String?
    let transportIdentity: String
    let web: CapabilityWebPreference
    let reasoningIntent: String?
    let revision: Int
    let mutationId: String

    enum CodingKeys: String, CodingKey {
        case recordId, scope, providerId, modelId = "canonicalModelId", conversationId, skillId
        case transportIdentity, web, reasoningIntent, revision, mutationId
    }
}

nonisolated struct CapabilityPreferenceSyncPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let records: [CapabilityPreferenceSyncRecord]
    let tombstones: [CapabilityPreferenceSyncTombstone]?
}

extension CapabilityPreferenceSyncPayload {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2,
            records: try container.decodeIfPresent([CapabilityPreferenceSyncRecord].self, forKey: .records) ?? [],
            tombstones: try container.decodeIfPresent([CapabilityPreferenceSyncTombstone].self, forKey: .tombstones)
        )
    }

    var isEmptyEnvelope: Bool { records.isEmpty && (tombstones?.isEmpty ?? true) }
}

nonisolated struct CapabilityPreferenceSyncTombstone: Codable, Equatable, Sendable {
    let recordId: String
    let revision: Int
    let mutationId: String
}

private enum CapabilityPreferenceSyncLedger {
    static let key = "capability_preference_sync_tombstones.v1"
    static func all(defaults: UserDefaults) -> [CapabilityPreferenceSyncTombstone] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CapabilityPreferenceSyncTombstone].self, from: data)) ?? []
    }
    static func put(_ value: CapabilityPreferenceSyncTombstone, defaults: UserDefaults) {
        var values = all(defaults: defaults).filter { $0.recordId != value.recordId }
        values.append(value)
        write(values, defaults: defaults)
    }
    static func revision(for recordID: String, defaults: UserDefaults) -> Int {
        all(defaults: defaults).first(where: { $0.recordId == recordID })?.revision ?? 0
    }
    static func clear(recordID: String, defaults: UserDefaults) {
        write(all(defaults: defaults).filter { $0.recordId != recordID }, defaults: defaults)
    }
    static func replace(_ values: [CapabilityPreferenceSyncTombstone], defaults: UserDefaults) {
        write(values, defaults: defaults)
    }
    static func removeAll(defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
    }
    static func write(_ values: [CapabilityPreferenceSyncTombstone], defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(Array(values.suffix(300))), forKey: key)
    }
}

enum CapabilityPreferenceSyncContract {
    static func exportPayload(settings: GenerationParameterSettingsStore = .shared) -> CapabilityPreferenceSyncPayload {
        let records = settings.capabilitySyncRecords().compactMap { record -> CapabilityPreferenceSyncRecord? in
            // `custom` selects a local-only fragment. It must never cross this typed envelope,
            // even if a future developer surface stores that local selection in the same record.
            guard isSynchronizable(values: record.values),
                  !record.modelID.isEmpty,
                  CapabilityPreferenceRuntimeIdentity.decode(record.transportIdentity) != nil else { return nil }
            return CapabilityPreferenceSyncRecord(
                recordId: recordID(for: record),
                scope: record.scope.rawValue,
                providerId: record.providerID.uuidString.lowercased(), modelId: record.modelID,
                conversationId: record.conversationID?.uuidString.lowercased(),
                skillId: record.skillID?.uuidString.lowercased(),
                transportIdentity: record.transportIdentity, web: record.values.web,
                reasoningIntent: record.values.reasoningIntent, revision: record.revision, mutationId: record.mutationID
            )
        }
        // Wire order is part of the cross-platform contract: Web `compareWireId`, Android
        // `sortedBy`, and this `<` must produce the same array, or the peer that reads an
        // unsorted envelope rewrites it and the two ends ping-pong forever (ORIVEO-APP-2M).
        return .init(
            schemaVersion: 2, records: Array(records.sorted { $0.recordId < $1.recordId }.prefix(200)),
            tombstones: Array(
                CapabilityPreferenceSyncLedger.all(defaults: settings.defaults)
                    .filter(isValid).sorted { $0.recordId < $1.recordId }.suffix(300)
            )
        )
    }

    static func foundationValue(_ payload: CapabilityPreferenceSyncPayload) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(payload),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value
    }

    static func decodeFirestore(_ raw: Any) -> CapabilityPreferenceSyncPayload? {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let payload = try? JSONDecoder().decode(CapabilityPreferenceSyncPayload.self, from: data),
              payload.schemaVersion == 2,
              payload.records.allSatisfy(isValid),
              (payload.tombstones ?? []).allSatisfy(isValid) else { return nil }
        return payload
    }

    @discardableResult
    static func merge(
        _ remote: CapabilityPreferenceSyncPayload,
        settings: GenerationParameterSettingsStore = .shared
    ) -> CapabilityPreferenceSyncPayload {
        guard remote.schemaVersion == 2 else { return exportPayload(settings: settings) }
        var selected: [String: (revision: Int, mutationId: String, record: CapabilityPreferenceSyncRecord?)] = [:]
        func put(_ id: String, revision: Int, mutationId: String, record: CapabilityPreferenceSyncRecord?) {
            if let current = selected[id],
               current.revision > revision || (current.revision == revision && current.mutationId >= mutationId) {
                return
            }
            selected[id] = (revision, mutationId, record)
        }
        for record in exportPayload(settings: settings).records + remote.records where isValid(record) {
            put(record.recordId, revision: record.revision, mutationId: record.mutationId, record: record)
        }
        for tombstone in (exportPayload(settings: settings).tombstones ?? []) + (remote.tombstones ?? [])
            where isValid(tombstone) {
            put(tombstone.recordId, revision: tombstone.revision, mutationId: tombstone.mutationId, record: nil)
        }
        let mergedRecords = selected.values.compactMap { $0.record }.sorted { $0.recordId < $1.recordId }
        let mergedTombstones = selected.compactMap { id, value in
            value.record == nil ? CapabilityPreferenceSyncTombstone(recordId: id, revision: value.revision, mutationId: value.mutationId) : nil
        }.sorted { $0.recordId < $1.recordId }
        let merged = CapabilityPreferenceSyncPayload(schemaVersion: 2, records: Array(mergedRecords.prefix(200)), tombstones: Array(mergedTombstones.suffix(300)))
        settings.replaceCapabilitySyncRecords(merged.records.compactMap { record in
            guard let providerID = UUID(uuidString: record.providerId) else { return nil }
            let conversationID = record.conversationId.flatMap(UUID.init(uuidString:))
            let skillID = record.skillId.flatMap(UUID.init(uuidString:))
            switch record.scope {
            case "connection":
                guard record.modelId?.isEmpty == false, conversationID == nil, skillID == nil else { return nil }
            case "connection_model":
                guard record.modelId != nil, conversationID == nil, skillID == nil else { return nil }
            case "conversation_connection_model":
                guard conversationID != nil, skillID == nil else { return nil }
            case "skill_agent":
                guard skillID != nil, conversationID == nil else { return nil }
            default:
                return nil
            }
            return .init(
                scope: CapabilityPreferenceScope(rawValue: record.scope)!, providerID: providerID, modelID: record.modelId ?? "",
                conversationID: conversationID, skillID: skillID,
                transportIdentity: record.transportIdentity,
                values: .init(web: record.web, reasoningIntent: record.reasoningIntent),
                updatedAt: Date(), revision: record.revision, mutationID: record.mutationId
            )
        })
        CapabilityPreferenceSyncLedger.replace(merged.tombstones ?? [], defaults: settings.defaults)
        return merged
    }

    nonisolated private static func isValid(_ record: CapabilityPreferenceSyncRecord) -> Bool {
        isSynchronizable(web: record.web, reasoningIntent: record.reasoningIntent)
            && UUID(uuidString: record.providerId) != nil
            && record.providerId == record.providerId.lowercased()
            && !(record.modelId?.isEmpty ?? true)
            && CapabilityPreferenceRuntimeIdentity.decode(record.transportIdentity) != nil
            && record.revision > 0 && !record.mutationId.isEmpty
            && {
                switch record.scope {
                case "connection": return record.conversationId == nil && record.skillId == nil
                case "connection_model": return !(record.modelId?.isEmpty ?? true) && record.conversationId == nil && record.skillId == nil
                case "conversation_connection_model": return !(record.modelId?.isEmpty ?? true) && record.conversationId.flatMap(UUID.init(uuidString:)) != nil && record.skillId == nil
                case "skill_agent": return !(record.modelId?.isEmpty ?? true) && record.skillId.flatMap(UUID.init(uuidString:)) != nil && record.conversationId == nil
                default: return false
                }
            }()
            && record.recordId == canonicalRecordID(for: record)
    }

    nonisolated private static func isValid(_ tombstone: CapabilityPreferenceSyncTombstone) -> Bool {
        tombstone.revision > 0
            && !tombstone.mutationId.isEmpty
            && isCanonicalRecordID(tombstone.recordId)
    }

    nonisolated private static func canonicalRecordID(for record: CapabilityPreferenceSyncRecord) -> String? {
        switch record.scope {
        case "connection":
            guard let modelId = record.modelId, !modelId.isEmpty else { return nil }
            return "scope:connection:\(record.providerId):\(modelId):\(record.transportIdentity)"
        case "connection_model":
            guard let modelId = record.modelId, !modelId.isEmpty else { return nil }
            return "scope:model:\(record.providerId):\(modelId):\(record.transportIdentity)"
        case "conversation_connection_model":
            guard let modelId = record.modelId, !modelId.isEmpty,
                  let conversationId = record.conversationId,
                  UUID(uuidString: conversationId) != nil,
                  conversationId == conversationId.lowercased() else { return nil }
            return "scope:conversation:\(record.providerId):\(modelId):\(record.transportIdentity):\(conversationId)"
        case "skill_agent":
            guard let modelId = record.modelId, !modelId.isEmpty,
                  let skillId = record.skillId,
                  UUID(uuidString: skillId) != nil,
                  skillId == skillId.lowercased() else { return nil }
            return "scope:skill:\(record.providerId):\(modelId):\(record.transportIdentity):\(skillId)"
        default:
            return nil
        }
    }

    /// Tombstones carry no scope fields, so their recordId must prove the complete identity by
    /// itself. Accept only IDs that this frozen v1 producer could have emitted; arbitrary remote
    /// strings must never participate in keyed LWW and delete a local record.
    nonisolated private static func isCanonicalRecordID(_ recordId: String) -> Bool {
        func canonicalUUID(_ value: String) -> Bool {
            UUID(uuidString: value) != nil && value == value.lowercased()
        }

        /// Only parse the stable namespace/UUID boundaries. Model IDs and transport fingerprints
        /// are opaque and may both contain `:` (for example `llama3:latest`), so splitting the
        /// entire ID into a fixed number of components rejects IDs emitted by our own producer.
        func body(after prefix: String) -> String? {
            guard recordId.hasPrefix(prefix) else { return nil }
            let suffix = String(recordId.dropFirst(prefix.count))
            guard let separator = suffix.firstIndex(of: ":") else { return nil }
            let provider = String(suffix[..<separator])
            guard canonicalUUID(provider) else { return nil }
            return String(suffix[suffix.index(after: separator)...])
        }
        func hasCompleteModelAndRuntimeIdentity(_ value: String) -> Bool {
            guard let separator = value.lastIndex(of: ":") else { return false }
            let model = String(value[..<separator])
            let wire = String(value[value.index(after: separator)...])
            return !model.isEmpty && CapabilityPreferenceRuntimeIdentity.decode(wire) != nil
        }

        if let remainder = body(after: "scope:connection:") {
            return hasCompleteModelAndRuntimeIdentity(remainder)
        }
        if let remainder = body(after: "scope:model:") {
            return hasCompleteModelAndRuntimeIdentity(remainder)
        }
        for namespace in ["conversation", "skill"] {
            guard let remainder = body(after: "scope:\(namespace):"),
                  let tailSeparator = remainder.lastIndex(of: ":") else { continue }
            let middle = String(remainder[..<tailSeparator])
            let scopeID = String(remainder[remainder.index(after: tailSeparator)...])
            return hasCompleteModelAndRuntimeIdentity(middle) && canonicalUUID(scopeID)
        }
        return false
    }

    nonisolated private static func isSynchronizable(values: CapabilityPreferenceValues) -> Bool {
        isSynchronizable(web: values.web, reasoningIntent: values.reasoningIntent)
    }

    /// This is deliberately narrower than the in-memory `CapabilityWebPreference`: `custom`
    /// is a local editor mode, not a wire value. Reasoning stays at the product's frozen intent
    /// vocabulary; provider-specific aliases such as `high` only appear after recipe compilation.
    nonisolated private static func isSynchronizable(web: CapabilityWebPreference, reasoningIntent: String?) -> Bool {
        guard [.off, .automatic, .force].contains(web) else { return false }
        return reasoningIntent == nil || ["off", "low", "balanced", "deep", "max"].contains(reasoningIntent!)
    }

    fileprivate static func recordID(for record: GenerationParameterSettingsStore.CapabilityRecord) -> String {
        let provider = record.providerID.uuidString.lowercased()
        if record.scope == .connection {
            return "scope:connection:\(provider):\(record.modelID):\(record.transportIdentity)"
        }
        if let skillID = record.skillID?.uuidString.lowercased() {
            return "scope:skill:\(provider):\(record.modelID):\(record.transportIdentity):\(skillID)"
        }
        if let conversationID = record.conversationID?.uuidString.lowercased() {
            return "scope:conversation:\(provider):\(record.modelID):\(record.transportIdentity):\(conversationID)"
        }
        return "scope:model:\(provider):\(record.modelID):\(record.transportIdentity)"
    }
}

private extension ISO8601DateFormatter {
    static var generationParameters: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

@MainActor
final class GenerationParameterSyncPublisher {
    static let shared = GenerationParameterSyncPublisher()
    private var writer: (([String: Any]) -> Void)?
    private var publishQueued = false
    private let makePayload: () -> GenerationParameterSyncPayload

    init(makePayload: @escaping () -> GenerationParameterSyncPayload = {
        GenerationParameterSyncContract.exportPayload()
    }) {
        self.makePayload = makePayload
    }

    func bind(_ writer: @escaping ([String: Any]) -> Void) {
        self.writer = writer
        publish()
    }

    func unbind() { writer = nil }

    nonisolated static func localDidChange() {
        Task { @MainActor in shared.publish() }
    }

    private func publish() {
        guard !publishQueued else { return }
        publishQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            self.publishQueued = false
            let payload = self.makePayload()
            guard let writer = self.writer,
                  !payload.isEmptyEnvelope,
                  let value = GenerationParameterSyncContract.foundationValue(payload) else { return }
            writer(value)
        }
    }
}

/// Separate publisher, not a new store: it keeps the frozen v1 writer contract unchanged while
/// publishing the independent `capabilityPreferenceSettings` Firestore field additively.
@MainActor
final class CapabilityPreferenceSyncPublisher {
    static let shared = CapabilityPreferenceSyncPublisher()
    private var writer: (([String: Any]) -> Void)?
    private var publishQueued = false
    private let makePayload: () -> CapabilityPreferenceSyncPayload

    init(makePayload: @escaping () -> CapabilityPreferenceSyncPayload = {
        CapabilityPreferenceSyncContract.exportPayload()
    }) {
        self.makePayload = makePayload
    }

    func bind(_ writer: @escaping ([String: Any]) -> Void) {
        self.writer = writer
        publish()
    }

    func unbind() { writer = nil }

    nonisolated static func localDidChange() {
        Task { @MainActor in shared.publish() }
    }

    private func publish() {
        guard !publishQueued else { return }
        publishQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            self.publishQueued = false
            let payload = self.makePayload()
            // `GenerationParameterSyncPublisher.publish()`.
            guard let writer = self.writer,
                  !payload.isEmptyEnvelope,
                  let value = CapabilityPreferenceSyncContract.foundationValue(payload) else { return }
            writer(value)
        }
    }
}

enum GenerationParameterAccountBoundary {
    static let stampKey = "generation_parameter_account_stamp.v1"
    private static let guestUID = "guest"

    enum Decision: Equatable {
        case skippedGuest
        case adopted
        case unchanged
        case reset
    }

    static func resetForSignOut(
        settings: GenerationParameterSettingsStore = .shared,
        presets: GenerationParameterPresetStore = .shared,
        defaults: UserDefaults = .standard
    ) {
        settings.resetForAccountBoundary()
        presets.resetForAccountBoundary()
        defaults.removeObject(forKey: stampKey)
    }

    @discardableResult
    static func applyLoginBoundary(
        uid: String,
        settings: GenerationParameterSettingsStore = .shared,
        presets: GenerationParameterPresetStore = .shared,
        defaults: UserDefaults = .standard
    ) -> Decision {
        guard !uid.isEmpty, uid != guestUID else { return .skippedGuest }
        guard let stamp = defaults.string(forKey: stampKey) else {
            defaults.set(uid, forKey: stampKey)
            return .adopted
        }
        guard stamp != uid else { return .unchanged }
        settings.resetForAccountBoundary()
        presets.resetForAccountBoundary()
        defaults.set(uid, forKey: stampKey)
        return .reset
    }
}

enum GenerationParameterProfileFingerprint {
    static func make(provider: Provider, model: AIModel) -> String {
        let endpoint = provider.kind == .relay
            ? (provider.relayRequested?.resolvedAPIBaseURL ?? provider.baseURLText ?? "")
            : ""
        let endpointHash = sanitizedEndpoint(endpoint).map { value in
            "ep_" + String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
        } ?? ""
        let transport = GenerationParameterAvailability.profile(provider: provider, model: model)?.template ?? ""
        return [String(endpointHash), transport, provider.relayRequested?.engineProfile ?? "", model.canonicalModelId ?? model.id]
            .joined(separator: "|")
    }

    private static func sanitizedEndpoint(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if var components = URLComponents(string: trimmed) {
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            let path = components.path.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
            components.path = path.isEmpty ? "/" : path
            if let value = components.string { return value }
        }
        return trimmed.components(separatedBy: CharacterSet(charactersIn: "?#")).first
    }
}
