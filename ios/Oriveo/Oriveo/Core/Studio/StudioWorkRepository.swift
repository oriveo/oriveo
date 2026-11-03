import Foundation
import GRDB

/// Push state of a local work row: pending = written on this device and not yet pushed.
nonisolated enum StudioWorkSyncState: String, Hashable, Sendable {
    case synced
    case pending
}

/// Where a work came from (studio_data_model.v1 `enums.workSource`).
nonisolated enum StudioWorkSource: String, CaseIterable, Hashable, Sendable {
    case studio
    case chat
}

nonisolated enum StudioWorkRepositoryError: Error, Equatable, Sendable {
    /// No such work in the active partition, or it is a tombstone.
    case workUnavailable(String)
    /// No such version in the work.
    case versionNotFound(String)
    /// The version exists but is not kept.
    case versionNotKept(String)
    /// The round's versions / refs do not belong to the round or its work.
    case invalidRound(String)
}

/// One `studio_works` row. Id arrays are JSON array TEXT in the table, booleans INTEGER 0 / 1,
/// times epoch milliseconds.
nonisolated struct StudioWorkRow: Equatable, Sendable {
    var id: String
    var title: String?
    var currentVersionId: String?
    var source: String
    var chatConversationId: String?
    var chatMessageId: String?
    var favorite: Bool
    var selectedVersionIds: [String]
    var deletedVersionIds: [String]
    var createdAt: Int64
    var updatedAt: Int64
    var deletedAt: Int64?
    var revision: Int64
    var baseRevision: Int64
    var accountPartition: String?
    var syncState: StudioWorkSyncState
}

/// One `studio_rounds` row. presetIds / params / modelRef / adjustments are JSON TEXT as given.
nonisolated struct StudioRoundRow: Equatable, Sendable {
    var id: String
    var workId: String
    var index: Int
    var baseVersionId: String?
    var operation: String
    var prompt: String?
    var composedPrompt: String?
    var enhancedPrompt: String?
    var presetIds: String?
    var params: String?
    var modelRef: String?
    var status: String
    var errorKind: String?
    var adjustments: String?
    var nRequested: Int?
    var nDelivered: Int?
    var costEstimateUsd: Double?
    var chargedUsd: Double?
    var fundingSource: String?
    var managedJobId: String?
    var clientJobId: String?
    var startedAt: Int64?
    var finishedAt: Int64?
}

/// One `studio_versions` row (a candidate; kept once the user keeps it).
nonisolated struct StudioVersionRow: Equatable, Sendable {
    var id: String
    var roundId: String
    var workId: String
    var parentVersionId: String?
    var assetId: String
    var width: Int?
    var height: Int?
    var mime: String?
    var kept: Bool = false
    var createdAt: Int64
}

/// One `studio_round_refs` row.
nonisolated struct StudioRoundRefRow: Equatable, Sendable {
    var roundId: String
    var order: Int
    var assetId: String
    var role: String
}

/// A work with its rounds (by index), versions (by createdAt, id) and refs (by round index, order).
nonisolated struct StudioWorkDetail: Equatable, Sendable {
    var work: StudioWorkRow
    var rounds: [StudioRoundRow]
    var versions: [StudioVersionRow]
    var refs: [StudioRoundRefRow]
}

/// Studio works of one account partition (studio_data_model.v1 `repository.rules`).
nonisolated final class StudioWorkRepository: @unchecked Sendable {
    private let writer: any DatabaseWriter
    let partitionUID: String
    private let now: @Sendable () -> Int64

    init(writer: any DatabaseWriter, partitionUID: String, now: @escaping @Sendable () -> Int64) {
        self.writer = writer
        self.partitionUID = partitionUID
        self.now = now
    }

    static func fetchWork(_ db: Database, id: String) throws -> StudioWorkRow? { nil }

    func createWork(
        id: String?, source: StudioWorkSource, title: String?,
        chatConversationId: String? = nil, chatMessageId: String? = nil
    ) async throws -> StudioWorkRow {
        throw StudioWorkRepositoryError.workUnavailable(id ?? "")
    }

    func rename(workId: String, title: String) async throws {}

    func setFavorite(workId: String, _ favorite: Bool) async throws {}

    func list() async throws -> [StudioWorkRow] { [] }

    func detail(workId: String) async throws -> StudioWorkDetail? { nil }

    func insertRound(_ round: StudioRoundRow, versions: [StudioVersionRow], refs: [StudioRoundRefRow]) async throws {}

    func finishRound(workId: String, roundId: String) async throws {}

    func pick(workId: String, versionId: String) async throws {}

    func alsoKeep(workId: String, versionId: String) async throws {}

    func setCurrent(workId: String, versionId: String) async throws {}

    func resolvePendingPick(workId: String) async throws {}

    func pendingPickCount(workId: String) async throws -> Int { -1 }

    func versionNumber(workId: String, versionId: String) async throws -> Int? { nil }
}
