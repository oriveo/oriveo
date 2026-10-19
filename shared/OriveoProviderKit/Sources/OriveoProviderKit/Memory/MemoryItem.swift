import CryptoKit
import Foundation

// Pure functions for memory items v2. The spec is the fields / defaults / rules[0..16] of `shared/context-contracts/memory-items.v2.json`:
// normalization, legacy-field migration, injection filtering, list order, deletion tombstones, sync merge and push,
// conflict copies, legacy-field dual-write compile and read-back, raw text view, organize request and parsing, and backup. Same name and algorithm on every platform.
// Pure functions only; app wiring is done separately.

public enum MemoryLayer: String, Codable, Hashable, Sendable, CaseIterable {
    case semantic
    case episodic
}

public enum MemoryKind: String, Codable, Hashable, Sendable, CaseIterable {
    case identity
    case preference
    case instruction
    case constraint
    case project
    case goal
    case decision
    case fact
    case event

    /// The eight semantic kinds allowed in an organize result; event is not among them.
    public static let semanticKinds: [MemoryKind] = [
        .identity, .preference, .instruction, .constraint, .project, .goal, .decision, .fact,
    ]

    /// instruction + constraint go into the standingInstructions section, the rest into the memory section.
    public var isStanding: Bool { self == .instruction || self == .constraint }

    /// The two kinds that belong to L3 (episodic) (memory-propose.v2 episodicKinds).
    public static let episodicKinds: [MemoryKind] = [.decision, .event]

    /// Candidates and new items get their layer from kind: decision / event -> episodic, everything else semantic.
    public var layer: MemoryLayer { Self.episodicKinds.contains(self) ? .episodic : .semantic }
}

public enum MemoryStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case active
    case paused
    case superseded
    case deleted
    case expired
    case conflicted
}

public enum MemorySensitivity: String, Codable, Hashable, Sendable, CaseIterable {
    case normal
    case sensitive
    case restricted
}

public enum MemoryScopeType: String, Codable, Hashable, Sendable, CaseIterable {
    case global
    case folder
    case conversation
}

public struct MemoryScope: Codable, Hashable, Sendable {
    public var type: MemoryScopeType
    public var id: String?

    public static let global = MemoryScope(type: .global, id: nil)

    public init(type: MemoryScopeType, id: String? = nil) {
        self.type = type
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case type, id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(MemoryScopeType.self, forKey: .type)
        id = try container.decodeIfPresent(String.self, forKey: .id)
    }

    /// null is written as null, with key order type, id.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(id, forKey: .id)
    }
}

public enum MemorySourceType: String, Codable, Hashable, Sendable, CaseIterable {
    case manual
    case conversation
    case `import`
    case migration
}

public struct MemorySource: Codable, Hashable, Sendable {
    public var type: MemorySourceType
    public var conversationId: String?
    public var messageIds: [String]
    /// RFC3339 or nil.
    public var observedAt: String?

    public static let manual = MemorySource(type: .manual)

    public init(type: MemorySourceType, conversationId: String? = nil, messageIds: [String] = [], observedAt: String? = nil) {
        self.type = type
        self.conversationId = conversationId
        self.messageIds = messageIds
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case type, conversationId, messageIds, observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Defaults to memory-items.v2 defaults.source.type (items in the memory-search.v1 fixture only write observedAt)
        type = try container.decodeIfPresent(MemorySourceType.self, forKey: .type) ?? .manual
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
        messageIds = try container.decodeIfPresent([String].self, forKey: .messageIds) ?? []
        observedAt = try container.decodeIfPresent(String.self, forKey: .observedAt)
    }

    /// null is written as null, with the same key order as the contract.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(conversationId, forKey: .conversationId)
        try container.encode(messageIds, forKey: .messageIds)
        try container.encode(observedAt, forKey: .observedAt)
    }
}

/// One memory. Missing fields are filled from the contract defaults when decoding; encoding writes all 25 keys (null written as null), key order = the contract fieldOrder.
/// Server-time fields (validFrom / lastConfirmedAt / createdAt / updatedAt) store the RFC3339 value read back from the remote, and are nil if not read back locally.

public struct MemoryItem: Codable, Hashable, Sendable {
    public var id: String
    public var schemaVersion: Int
    public var layer: MemoryLayer
    public var kind: MemoryKind
    public var status: MemoryStatus
    public var content: String
    public var scope: MemoryScope
    public var source: MemorySource
    public var sensitivity: MemorySensitivity
    public var confidence: Double
    public var priority: Int
    public var pinned: Bool
    public var revision: Int
    public var baseRevision: Int
    public var mutationId: String
    public var deviceId: String
    public var conflictGroupId: String?
    public var occurredAt: String?
    public var validFrom: String?
    public var lastConfirmedAt: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var expiresAt: String?
    public var deletedAt: String?
    public var supersedes: [String]

    public init(
        id: String,
        schemaVersion: Int = MemoryItems.schemaVersion,
        layer: MemoryLayer = .semantic,
        kind: MemoryKind,
        status: MemoryStatus = .active,
        content: String,
        scope: MemoryScope = .global,
        source: MemorySource = .manual,
        sensitivity: MemorySensitivity = .normal,
        confidence: Double = 1,
        priority: Int = 0,
        pinned: Bool = false,
        revision: Int = 1,
        baseRevision: Int = 0,
        mutationId: String,
        deviceId: String,
        conflictGroupId: String? = nil,
        occurredAt: String? = nil,
        validFrom: String? = nil,
        lastConfirmedAt: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        expiresAt: String? = nil,
        deletedAt: String? = nil,
        supersedes: [String] = []
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.layer = layer
        self.kind = kind
        self.status = status
        self.content = content
        self.scope = scope
        self.source = source
        self.sensitivity = sensitivity
        self.confidence = confidence
        self.priority = priority
        self.pinned = pinned
        self.revision = revision
        self.baseRevision = baseRevision
        self.mutationId = mutationId
        self.deviceId = deviceId
        self.conflictGroupId = conflictGroupId
        self.occurredAt = occurredAt
        self.validFrom = validFrom
        self.lastConfirmedAt = lastConfirmedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.deletedAt = deletedAt
        self.supersedes = supersedes
    }

    /// Declaration order is the contract fieldOrder, and encoding writes keys in this order.
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id, schemaVersion, layer, kind, status, content, scope, source, sensitivity, confidence
        case priority, pinned, revision, baseRevision, mutationId, deviceId, conflictGroupId, occurredAt
        case validFrom, lastConfirmedAt, createdAt, updatedAt, expiresAt, deletedAt, supersedes
    }

    public static let fieldOrder: [String] = CodingKeys.allCases.map(\.rawValue)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? MemoryItems.schemaVersion
        layer = try c.decodeIfPresent(MemoryLayer.self, forKey: .layer) ?? .semantic
        kind = try c.decode(MemoryKind.self, forKey: .kind)
        status = try c.decodeIfPresent(MemoryStatus.self, forKey: .status) ?? .active
        content = try c.decode(String.self, forKey: .content)
        scope = try c.decodeIfPresent(MemoryScope.self, forKey: .scope) ?? .global
        source = try c.decodeIfPresent(MemorySource.self, forKey: .source) ?? .manual
        sensitivity = try c.decodeIfPresent(MemorySensitivity.self, forKey: .sensitivity) ?? .normal
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        baseRevision = try c.decodeIfPresent(Int.self, forKey: .baseRevision) ?? 0
        mutationId = try c.decode(String.self, forKey: .mutationId)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        conflictGroupId = try c.decodeIfPresent(String.self, forKey: .conflictGroupId)
        occurredAt = try c.decodeIfPresent(String.self, forKey: .occurredAt)
        validFrom = try c.decodeIfPresent(String.self, forKey: .validFrom)
        lastConfirmedAt = try c.decodeIfPresent(String.self, forKey: .lastConfirmedAt)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        supersedes = try c.decodeIfPresent([String].self, forKey: .supersedes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(layer, forKey: .layer)
        try c.encode(kind, forKey: .kind)
        try c.encode(status, forKey: .status)
        try c.encode(content, forKey: .content)
        try c.encode(scope, forKey: .scope)
        try c.encode(source, forKey: .source)
        try c.encode(sensitivity, forKey: .sensitivity)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(priority, forKey: .priority)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(revision, forKey: .revision)
        try c.encode(baseRevision, forKey: .baseRevision)
        try c.encode(mutationId, forKey: .mutationId)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(conflictGroupId, forKey: .conflictGroupId)
        try c.encode(occurredAt, forKey: .occurredAt)
        try c.encode(validFrom, forKey: .validFrom)
        try c.encode(lastConfirmedAt, forKey: .lastConfirmedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(supersedes, forKey: .supersedes)
    }
}

// MARK: - Result types

/// Injection filter result: each of the two sections in list order.
public struct MemoryInjection: Hashable, Sendable {
    public let standingInstructions: [MemoryItem]
    public let memory: [MemoryItem]
}

/// One side's version summary in a sync merge.
public struct MemoryVersion: Hashable, Sendable {
    public var revision: Int
    public var mutationId: String
    public var status: MemoryStatus
    public var content: String
    public var sensitivity: MemorySensitivity

    public init(
        revision: Int, mutationId: String, status: MemoryStatus, content: String,
        sensitivity: MemorySensitivity = .normal
    ) {
        self.revision = revision
        self.mutationId = mutationId
        self.status = status
        self.content = content
        self.sensitivity = sensitivity
    }
}

/// Changes on this device that have not been pushed successfully yet.
public struct MemoryPendingEdit: Hashable, Sendable {
    public var mutationId: String
    public var baseRevision: Int
    public var status: MemoryStatus
    public var content: String
    public var sensitivity: MemorySensitivity

    public init(
        mutationId: String, baseRevision: Int, status: MemoryStatus, content: String,
        sensitivity: MemorySensitivity = .normal
    ) {
        self.mutationId = mutationId
        self.baseRevision = baseRevision
        self.status = status
        self.content = content
        self.sensitivity = sensitivity
    }
}

public enum MemoryMergeResult: String, Codable, Hashable, Sendable {
    case applyRemote
    case noop
    case ignoreRemote
    case conflict
    case pendingConfirmed
    case keepPending
}

public struct MemoryMergeOutcome: Hashable, Sendable {
    public let result: MemoryMergeResult
    /// The version kept after merging (mutationId); on conflict the remote comes first and the local one second.
    public let keep: [String]
    public let status: MemoryStatus
}

public enum MemoryPushAction: Hashable, Sendable {
    case write(revision: Int)
    case confirmed
    case dropPending
    case conflict
    /// A restricted pending push meets a live remote: write this item's tombstone (using the pending mutationId) to retract the remote copy.
    case retract(revision: Int)
    /// A restricted pending push meets a missing / already-tombstoned remote: write nothing, mark local as synced, revision = baseRevision.
    case localOnly(baseRevision: Int)
}

/// Conflict landing: the original item takes the remote content and is marked conflicted, and the local change is saved separately as a copy.
public struct MemoryConflict: Hashable, Sendable {
    public let original: MemoryItem
    public let copy: MemoryItem
}

/// Snapshot of the legacy field (preferences).
public struct MemoryLegacyPrefs: Hashable, Sendable {
    public var memoryText: String?
    public var memoryTextDigest: String?
    public var antiForgetEnabled: Bool
    public var antiForgetText: String?
    public var memoryUpdatedAt: String?

    public init(
        memoryText: String?,
        memoryTextDigest: String? = nil,
        antiForgetEnabled: Bool = false,
        antiForgetText: String? = nil,
        memoryUpdatedAt: String? = nil
    ) {
        self.memoryText = memoryText
        self.memoryTextDigest = memoryTextDigest
        self.antiForgetEnabled = antiForgetEnabled
        self.antiForgetText = antiForgetText
        self.memoryUpdatedAt = memoryUpdatedAt
    }
}

/// The memoryText and digest dual-written for legacy clients.
public struct MemoryLegacyCompile: Hashable, Sendable {
    public let memoryText: String
    public let memoryTextDigest: String
}

public struct MemoryLegacySync: Hashable, Sendable {
    /// Items missing locally, written as create-if-absent.
    public let create: [MemoryItem]
    /// Changes to items that already exist locally (pending push).
    public let update: [MemoryItem]
    /// The legacy fields that need writing back; nil means the legacy fields already match the compile result.
    public let writePrefs: MemoryLegacyCompile?
    /// The compile result differs from the local memoryText: only when true is memoryUpdatedAt refreshed and pushed up; when false only the digest is filled in and only the local copy is written.
    public let textChanged: Bool

    public init(create: [MemoryItem], update: [MemoryItem], writePrefs: MemoryLegacyCompile?, textChanged: Bool = false) {
        self.create = create
        self.update = update
        self.writePrefs = writePrefs
        self.textChanged = textChanged
    }
}

public enum MemoryRawOp: Hashable, Sendable {
    case update(id: String, content: String)
    case create(id: String, kind: MemoryKind, content: String)
    case delete(id: String)
}

public enum MemoryRawApplyResult: Hashable, Sendable {
    case ops([MemoryRawOp])
    /// The index-th segment (numbered after empty segments are removed) exceeds contentMaxCodePoints.
    case tooLong(index: Int)
}

public struct MemoryOrganizeMessage: Hashable, Sendable {
    public let role: ContextMessageRole
    public let text: String
}

public struct MemoryOrganizeRequest: Hashable, Sendable {
    public let system: String
    public let messages: [MemoryOrganizeMessage]
}

public struct MemoryOrganizeEntry: Hashable, Sendable {
    public let kind: MemoryKind
    public let content: String
}

public struct MemoryBackupSection: Hashable, Sendable {
    public let memorySchemaVersion: Int
    public let memoryItems: [MemoryItem]
}

/// The memory part of a backup file: new backups carry memoryItems, old backups have only preferences.
public struct MemoryBackupInput: Hashable, Sendable {
    public var memoryItems: [MemoryItem]?
    public var preferences: MemoryLegacyPrefs?

    public init(memoryItems: [MemoryItem]? = nil, preferences: MemoryLegacyPrefs? = nil) {
        self.memoryItems = memoryItems
        self.preferences = preferences
    }
}

public enum MemoryBackupMode: String, Codable, Hashable, Sendable {
    case merge
    case replace
}

/// The remote document head read inside a push transaction.
public struct MemoryRemoteHead: Hashable, Sendable {
    public var revision: Int
    public var mutationId: String
    public var createdAt: String?

    public init(revision: Int, mutationId: String, createdAt: String? = nil) {
        self.revision = revision
        self.mutationId = mutationId
        self.createdAt = createdAt
    }
}

// MARK: - Pure functions

public enum MemoryItems {
    public static let schemaVersion = 2
    /// UUIDv5(NAMESPACE_URL, "https://oriveo.app/ns/memory-item").
    public static let uuidNamespace = "7b430abd-757c-5561-bdc9-40d1e677748c"
    public static let legacyMemoryTextKey = "legacy-memoryText"
    public static let legacyAntiForgetKey = "legacy-antiforget"
    public static let migrationMutationSuffix = "migration-1"
    public static let conflictMutationSuffix = "conflict-1"
    public static let legacyMutationPrefix = "legacy-"
    public static let contentMaxCodePoints = 2000
    public static let organizeMaxItems = 20
    public static let rawViewSeparator = "---"
    /// Identical verbatim on all platforms; changes must stay in sync with the contract's constants.organizeSystemPrompt.
    public static let organizeSystemPrompt =
        "Split the saved memory below into separate items. Each item states exactly one fact, preference, instruction, constraint or project. Keep the user's language and wording; do not add, infer, merge away or drop information. Reply with only a JSON array, no prose: [{\"kind\": \"identity|preference|instruction|constraint|project|goal|decision|fact\", \"content\": \"...\"}]."

    // MARK: rules[0] normalization

    /// Filling defaults is done by decoding; here id / mutationId / conflictGroupId / supersedes are lowercased and content is left as is.
    public static func canonical(_ item: MemoryItem) -> MemoryItem {
        var result = item
        result.id = item.id.lowercased()
        result.mutationId = item.mutationId.lowercased()
        result.conflictGroupId = item.conflictGroupId?.lowercased()
        result.supersedes = item.supersedes.map { $0.lowercased() }
        return result
    }

    // MARK: rules[1..2] migration

    public static func legacyMemoryTextId(uid: String) -> String {
        uuidV5("\(uid)\n\(legacyMemoryTextKey)")
    }

    public static func legacyAntiForgetId(uid: String) -> String {
        uuidV5("\(uid)\n\(legacyAntiForgetKey)")
    }

    /// Legacy field -> migrated items (0-2 items); id and mutationId are deterministic, and multi-device migration synthesizes one item as create-if-absent.
    public static func migrate(uid: String, deviceId: String, prefs: MemoryLegacyPrefs) -> [MemoryItem] {
        let memoryText = prefs.memoryText ?? ""
        let antiForgetText = prefs.antiForgetText ?? ""
        var result: [MemoryItem] = []
        if !trimmed(memoryText).isEmpty {
            result.append(migrationItem(
                id: legacyMemoryTextId(uid: uid), kind: .fact, status: .active, content: memoryText,
                deviceId: deviceId, observedAt: prefs.memoryUpdatedAt
            ))
        }
        let antiForgetBody = trimmed(antiForgetText)
        if !antiForgetBody.isEmpty, antiForgetBody != trimmed(memoryText) {
            result.append(migrationItem(
                id: legacyAntiForgetId(uid: uid), kind: .instruction,
                status: prefs.antiForgetEnabled ? .active : .paused, content: antiForgetText,
                deviceId: deviceId, observedAt: prefs.memoryUpdatedAt
            ))
        }
        return result
    }

    private static func migrationItem(
        id: String, kind: MemoryKind, status: MemoryStatus, content: String, deviceId: String, observedAt: String?
    ) -> MemoryItem {
        MemoryItem(
            id: id, kind: kind, status: status, content: content,
            source: MemorySource(type: .migration, observedAt: observedAt),
            mutationId: uuidV5("\(id)\n\(migrationMutationSuffix)"), deviceId: deviceId
        )
    }

    // MARK: rules[3..4] injection

    /// semantic, active, unexpired, scope global / this conversation / this folder; split into two sections in list order. restricted items are injected as usual.
    public static func injectable(
        _ items: [MemoryItem], conversationId: String?, folderId: String?, now: Date
    ) -> MemoryInjection {
        let kept = listOrder(items).filter { item in
            guard item.layer == .semantic, item.status == .active else { return false }
            if let expiresAt = item.expiresAt {
                guard let instant = instant(expiresAt), instant > now else { return false }
            }
            switch item.scope.type {
            case .global: return true
            // scope.id ignores case: iOS conversation ids are uppercase UUIDs, Web / Android lowercase.
            case .conversation: return conversationId != nil && item.scope.id?.lowercased() == conversationId?.lowercased()
            case .folder: return folderId != nil && item.scope.id?.lowercased() == folderId?.lowercased()
            }
        }
        return MemoryInjection(
            standingInstructions: kept.filter { $0.kind.isStanding },
            memory: kept.filter { !$0.kind.isStanding }
        )
    }

    // MARK: rules[6] list order

    /// Pinned first, then createdAt ascending (nil first, compared as instants), then id ascending.
    public static func listOrder(_ items: [MemoryItem]) -> [MemoryItem] {
        let keyed = items.map { (item: $0, created: $0.createdAt.flatMap(instant)) }
        return keyed.sorted { lhs, rhs in
            if lhs.item.pinned != rhs.item.pinned { return lhs.item.pinned }
            switch (lhs.created, rhs.created) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (l?, r?) where l != r: return l < r
            default: break
            }
            return Array(lhs.item.id.utf8).lexicographicallyPrecedes(Array(rhs.item.id.utf8))
        }
        .map(\.item)
    }

    // MARK: rules[7] tombstone

    /// Keeps only id / schemaVersion / layer / kind / createdAt and resets the rest to defaults; revision is unchanged before the push, baseRevision = revision.
    public static func tombstone(_ item: MemoryItem, mutationId: String, deviceId: String, deletedAt: String) -> MemoryItem {
        let source = canonical(item)
        return MemoryItem(
            id: source.id, schemaVersion: source.schemaVersion, layer: source.layer, kind: source.kind,
            status: .deleted, content: "",
            revision: source.revision, baseRevision: source.revision,
            mutationId: mutationId.lowercased(), deviceId: deviceId,
            createdAt: source.createdAt, deletedAt: deletedAt
        )
    }

    // MARK: rules[5] + rules[8] merge

    public static func merge(local: MemoryVersion?, remote: MemoryVersion, pending: MemoryPendingEdit?) -> MemoryMergeOutcome {
        // Retraction: a local restricted item is never overwritten by the remote (retraction echoes, and later changes from devices that still hold a copy).
        if let pending, pending.sensitivity == .restricted || local?.sensitivity == .restricted {
            return MemoryMergeOutcome(result: .keepPending, keep: [pending.mutationId], status: pending.status)
        }
        if let local, local.sensitivity == .restricted {
            return MemoryMergeOutcome(result: .ignoreRemote, keep: [local.mutationId], status: local.status)
        }
        if let pending {
            if remote.mutationId == pending.mutationId {
                return MemoryMergeOutcome(result: .pendingConfirmed, keep: [pending.mutationId], status: pending.status)
            }
            // baseRevision 0 is create-if-absent (migration, conflict copy, new item): if the remote already exists, the remote wins.
            if pending.baseRevision == 0 {
                return MemoryMergeOutcome(result: .applyRemote, keep: [remote.mutationId], status: remote.status)
            }
            if remote.revision <= pending.baseRevision || pending.status == .deleted {
                return MemoryMergeOutcome(result: .keepPending, keep: [pending.mutationId], status: pending.status)
            }
            // A newer remote: if it is a tombstone, or content and state are both identical, drop the pending push; otherwise keep both as a conflict.
            if remote.status == .deleted || (remote.content == pending.content && remote.status == pending.status) {
                return MemoryMergeOutcome(result: .applyRemote, keep: [remote.mutationId], status: remote.status)
            }
            return MemoryMergeOutcome(
                result: .conflict, keep: [remote.mutationId, pending.mutationId], status: .conflicted
            )
        }
        guard let local else {
            return MemoryMergeOutcome(result: .applyRemote, keep: [remote.mutationId], status: remote.status)
        }
        if remote.revision == local.revision, remote.mutationId == local.mutationId {
            return MemoryMergeOutcome(result: .noop, keep: [local.mutationId], status: local.status)
        }
        // The same revision with different mutations cannot occur under transactional writes; if it does, the server wins.
        if remote.revision >= local.revision {
            return MemoryMergeOutcome(result: .applyRemote, keep: [remote.mutationId], status: remote.status)
        }
        return MemoryMergeOutcome(result: .ignoreRemote, keep: [local.mutationId], status: local.status)
    }

    // MARK: rules[9] push

    /// After reading the remote inside a transaction, decide how to write.
    public static func push(remote: MemoryVersion?, pending: MemoryPendingEdit) -> MemoryPushAction {
        // Retraction: a restricted item itself is never written; if the remote is alive, write a tombstone at remote + 1, and if it is missing / already a tombstone, keep only the local one.
        if pending.sensitivity == .restricted {
            guard let remote else { return .localOnly(baseRevision: 0) }
            if remote.status == .deleted { return .localOnly(baseRevision: remote.revision) }
            return .retract(revision: remote.revision + 1)
        }
        guard let remote else { return .write(revision: 1) }
        if remote.mutationId == pending.mutationId { return .confirmed }
        if pending.baseRevision == 0 { return .dropPending }
        if remote.revision == pending.baseRevision { return .write(revision: remote.revision + 1) }
        if pending.status == .deleted { return .write(revision: remote.revision + 1) }
        if remote.status == .deleted || remote.content == pending.content { return .dropPending }
        return .conflict
    }

    // MARK: rules[10] conflict copy

    /// The original item takes the remote content, is marked conflicted, conflictGroupId = its own id, and is pushed as an ordinary local change (mutationId / deviceId
    /// are supplied by the caller); the local change is saved separately as a copy, with deterministic id and mutationId.
    public static func conflict(
        itemId: String, pending: MemoryItem, remote: MemoryItem, mutationId: String, deviceId: String
    ) -> MemoryConflict {
        let groupId = itemId.lowercased()
        var original = canonical(remote)
        original.status = .conflicted
        original.conflictGroupId = groupId
        original.baseRevision = original.revision
        original.mutationId = mutationId.lowercased()
        original.deviceId = deviceId

        var copy = canonical(pending)
        copy.id = uuidV5("\(groupId)\n\(pending.mutationId.lowercased())")
        copy.status = .conflicted
        copy.conflictGroupId = groupId
        copy.revision = 1
        copy.baseRevision = 0
        copy.mutationId = uuidV5("\(copy.id)\n\(conflictMutationSuffix)")
        copy.createdAt = nil
        copy.updatedAt = nil
        return MemoryConflict(original: original, copy: copy)
    }

    // MARK: rules[11] legacy-field compile

    /// Contents of items that are semantic, active, non-restricted, global and not Anti-Forget migrated items, joined by blank lines in list order.
    public static func compileLegacy(uid: String, items: [MemoryItem]) -> MemoryLegacyCompile {
        let antiForgetId = legacyAntiForgetId(uid: uid)
        let text = listOrder(items)
            .filter {
                $0.layer == .semantic && $0.status == .active && $0.sensitivity != .restricted
                    && $0.scope.type == .global && $0.id.lowercased() != antiForgetId
            }
            .map(\.content)
            .joined(separator: "\n\n")
        return MemoryLegacyCompile(memoryText: text, memoryTextDigest: sha256Hex(text))
    }

    // MARK: rules[12] legacy-client read-back

    /// Before migration: create the migrated item; after migration: when a legacy client changed memoryText, sync it into the memoryText migrated item. deletedAt is used for the tombstone when cleared.
    public static func legacySync(
        uid: String,
        migrated: Bool,
        deviceId: String,
        items: [MemoryItem],
        prefs: MemoryLegacyPrefs,
        deletedAt: String
    ) -> MemoryLegacySync {
        let memoryText = prefs.memoryText ?? ""
        var create: [MemoryItem] = []
        var update: [MemoryItem] = []
        if !migrated {
            // Another newer client has already migrated and dual-written: only set the migrated flag and create nothing.
            if prefs.memoryTextDigest == sha256Hex(memoryText) {
                return MemoryLegacySync(create: [], update: [], writePrefs: nil)
            }
            let existing = Set(items.map { $0.id.lowercased() })
            create = migrate(uid: uid, deviceId: deviceId, prefs: prefs).filter { !existing.contains($0.id) }
        } else {
            if prefs.memoryTextDigest == sha256Hex(memoryText) {
                return MemoryLegacySync(create: [], update: [], writePrefs: nil)
            }
            if memoryText != compileLegacy(uid: uid, items: items).memoryText {
                let itemId = legacyMemoryTextId(uid: uid)
                let blank = trimmed(memoryText).isEmpty
                let mutationId = uuidV5("\(itemId)\n\(legacyMutationPrefix)\(sha256Hex(blank ? "" : memoryText))")
                let current = items.first { $0.id.lowercased() == itemId }.map(canonical)
                if blank {
                    if let current, current.status != .deleted {
                        update.append(tombstone(current, mutationId: mutationId, deviceId: deviceId, deletedAt: deletedAt))
                    }
                } else if var edited = current {
                    edited.content = memoryText
                    edited.status = .active
                    edited.deletedAt = nil
                    edited.baseRevision = edited.revision
                    edited.mutationId = mutationId
                    edited.deviceId = deviceId
                    update.append(edited)
                } else {
                    var created = migrationItem(
                        id: itemId, kind: .fact, status: .active, content: memoryText,
                        deviceId: deviceId, observedAt: prefs.memoryUpdatedAt
                    )
                    created.mutationId = mutationId
                    create.append(created)
                }
            }
        }
        let changed = Dictionary(update.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let after = items.map { changed[$0.id.lowercased()] ?? $0 } + create
        let compiled = compileLegacy(uid: uid, items: after)
        let prefsMatch = memoryText == compiled.memoryText && prefs.memoryTextDigest == compiled.memoryTextDigest
        return MemoryLegacySync(
            create: create, update: update, writePrefs: prefsMatch ? nil : compiled,
            textChanged: !prefsMatch && memoryText != compiled.memoryText
        )
    }

    // MARK: rules[13] raw text view

    /// semantic, active items joined by separator lines in list order.
    public static func rawRender(_ items: [MemoryItem]) -> String {
        rawViewItems(items).map(\.content).joined(separator: "\n\(rawViewSeparator)\n")
    }

    /// Folds the edited raw text view back into item changes; the ids of newly created items are supplied in order by newId.
    public static func rawApply(_ items: [MemoryItem], text: String, newId: () -> String) -> MemoryRawApplyResult {
        if text == rawRender(items) { return .ops([]) }
        var segments: [String] = []
        var lines: [String] = []
        func flush() {
            let segment = trimmed(lines.joined(separator: "\n"))
            if !segment.isEmpty { segments.append(segment) }
            lines = []
        }
        // Split lines by scalar: \r\n is a single Character in String and cannot be split by Character.
        for scalars in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(String.UnicodeScalarView(scalars))
            let bare = scalars.last == "\r" ? String(String.UnicodeScalarView(scalars.dropLast())) : line
            if bare == rawViewSeparator {
                flush()
            } else {
                lines.append(line)
            }
        }
        flush()
        if let index = segments.firstIndex(where: { $0.unicodeScalars.count > contentMaxCodePoints }) {
            return .tooLong(index: index)
        }

        let candidates = rawViewItems(items)
        var itemUsed = Array(repeating: false, count: candidates.count)
        var segmentUsed = Array(repeating: false, count: segments.count)
        for (segmentIndex, segment) in segments.enumerated() {
            if let itemIndex = candidates.indices.first(where: {
                !itemUsed[$0] && trimmed(candidates[$0].content) == segment
            }) {
                itemUsed[itemIndex] = true
                segmentUsed[segmentIndex] = true
            }
        }
        let restSegments = segments.indices.filter { !segmentUsed[$0] }.map { segments[$0] }
        let restItems = candidates.indices.filter { !itemUsed[$0] }.map { candidates[$0] }
        var ops: [MemoryRawOp] = []
        for (segment, item) in zip(restSegments, restItems) {
            ops.append(.update(id: item.id, content: segment))
        }
        for segment in restSegments.dropFirst(restItems.count) {
            ops.append(.create(id: newId(), kind: .fact, content: segment))
        }
        for item in restItems.dropFirst(restSegments.count) {
            ops.append(.delete(id: item.id))
        }
        return .ops(ops)
    }

    private static func rawViewItems(_ items: [MemoryItem]) -> [MemoryItem] {
        listOrder(items).filter { $0.layer == .semantic && $0.status == .active }
    }

    // MARK: rules[14] organize

    public static func organizeRequest(content: String) -> MemoryOrganizeRequest {
        MemoryOrganizeRequest(
            system: organizeSystemPrompt,
            messages: [MemoryOrganizeMessage(role: .user, text: content)]
        )
    }

    /// Parses a JSON array from the first [ to the last ]; invalid entries are skipped, and an empty array is returned when parsing fails.
    public static func organizeParse(_ response: String) -> [MemoryOrganizeEntry] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"),
              start < end,
              let array = try? JSONSerialization.jsonObject(with: Data(response[start...end].utf8)) as? [Any]
        else { return [] }
        var result: [MemoryOrganizeEntry] = []
        var seen = Set<String>()
        for element in array {
            guard result.count < organizeMaxItems else { break }
            guard let object = element as? [String: Any], let raw = object["content"] as? String else { continue }
            let content = trimmed(raw)
            guard !content.isEmpty, content.unicodeScalars.count <= contentMaxCodePoints,
                  !seen.contains(content) else { continue }
            let kind = (object["kind"] as? String)
                .flatMap { MemoryKind(rawValue: $0.lowercased()) }
                .flatMap { MemoryKind.semanticKinds.contains($0) ? $0 : nil } ?? .fact
            seen.insert(content)
            result.append(MemoryOrganizeEntry(kind: kind, content: content))
        }
        return result
    }

    // MARK: rules[15] backup

    public static func backupSection(_ items: [MemoryItem]) -> MemoryBackupSection {
        MemoryBackupSection(memorySchemaVersion: schemaVersion, memoryItems: listOrder(items).map(canonical))
    }

    /// merge: take the backup when the local item is missing or the backup revision is higher, otherwise keep local; replace: take the backup. Old backups without memoryItems are first migrated from preferences.
    public static func backupMerge(
        mode: MemoryBackupMode, local: [MemoryItem], backup: MemoryBackupInput, uid: String, deviceId: String
    ) -> [MemoryItem] {
        let incoming = (backup.memoryItems
            ?? backup.preferences.map { migrate(uid: uid, deviceId: deviceId, prefs: $0) }
            ?? []).map(canonical)
        switch mode {
        case .replace:
            return listOrder(incoming)
        case .merge:
            var merged = local.map(canonical)
            for item in incoming {
                if let index = merged.firstIndex(where: { $0.id == item.id }) {
                    if item.revision > merged[index].revision { merged[index] = item }
                } else {
                    merged.append(item)
                }
            }
            return listOrder(merged)
        }
    }

    /// Replace: ids of items alive on this device but absent from the backup result (list order); the caller writes one pending tombstone for each so remote copies and other devices converge;
    /// tombstones already on this device are not included (kept as is). `replaced` is the result of `backupMerge(mode: .replace)`.
    public static func backupReplaceTombstonedIds(local: [MemoryItem], replaced: [MemoryItem]) -> [String] {
        let kept = Set(replaced.map { $0.id.lowercased() })
        return listOrder(local.map(canonical)).filter { $0.status != .deleted && !kept.contains($0.id) }.map(\.id)
    }

    // MARK: Helpers

    /// UUIDv5(uuidNamespace, name), lowercase.
    public static func uuidV5(_ name: String) -> String {
        let namespace = UUID(uuidString: uuidNamespace)!.uuid
        let namespaceBytes = withUnsafeBytes(of: namespace) { Array($0) }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data(namespaceBytes))
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let h = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20))"
    }

    /// Lowercase hex SHA-256 of UTF-8 text.
    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// RFC3339 (with optional fractional seconds and timezone offset) -> instant; nil when unparsable.
    public static func instant(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private static func trimmed(_ text: String) -> String {
        ContextSanitizer.trimmed(text)
    }
}
