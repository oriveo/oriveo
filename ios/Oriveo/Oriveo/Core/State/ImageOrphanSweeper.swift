import Foundation
import GRDB
import os

/// Deletes message attachment image files only when nothing references them, and sweeps orphans at launch.
///
/// - Partitioned by uid: each database maps to one `Images/` directory, and the reference set only reads
///   that partition's attachment table.
/// - Both key schemes count as references: the attachment `localImageID` and `attachment.id` (`uuidString`).
/// - A failed reference read, or a partition switch in the middle of a round, abandons the round (fail-closed).
/// - Never writes the database; callers are responsible for running it in the background (no database
///   reads or file deletion on the main thread).
nonisolated enum ImageOrphanSweeper {
    /// Reads every attachment reference key of the partition. The database connection must be bound when the
    /// reader is created (see `ConversationRuntimeBridge.imageReferenceReader`), so background execution
    /// never switches the shared database.
    typealias ReferenceReader = @Sendable () throws -> Set<String>

    /// Reads the currently active partition uid; called before each batch of deletions, and a mismatch with
    /// the round's partition abandons the round.
    typealias PartitionProbe = @Sendable () -> String

    /// Maximum number of keys deleted per batch; the partition is re-checked before each batch.
    static let batchSize = 200
    /// Guard rails for the launch sweep. Tests may inject smaller batches and caps.
    struct SweepLimits: Sendable {
        var batchSize = ImageOrphanSweeper.batchSize
        /// Maximum number of keys deleted per round; the rest wait for the next launch.
        var maxDeletions = 500
        /// A candidate count above this and above `massDeletionRatio` of the stored keys is treated as an
        /// anomaly and nothing is deleted that round.
        var massDeletionMinCandidates = 200
        var massDeletionRatio = 0.5

        static let standard = SweepLimits()
    }
    /// The launch sweep skips files modified after "launch time minus this window": an image that was just
    /// written, whose attachment row is not in the database yet, must not be treated as an orphan.
    static let launchGrace: TimeInterval = 24 * 60 * 60
    /// Avatars live in the images directory too but are not message attachments, so they are never swept.
    static let avatarKeyPrefix = "user-avatar-"

    private static let logger = Logger(subsystem: "com.oriveo", category: "image-orphan-sweep")

    /// Every reference key in the attachment table: localImageID plus id.uuidString.
    static func referenceKeys(in reader: any DatabaseReader) throws -> Set<String> {
        try reader.read { db in
            var keys = Set<String>()
            let rows = try Row.fetchCursor(db, sql: "SELECT id, localImageID FROM attachment")
            while let row = try rows.next() {
                if let rawID: String = row["id"], !rawID.isEmpty {
                    // Downloaded originals are keyed by UUID.uuidString (uppercase); normalize the stored
                    // spelling so both cases map to the same key.
                    keys.insert(UUID(uuidString: rawID)?.uuidString ?? rawID)
                }
                if let localImageID: String = row["localImageID"], !localImageID.isEmpty {
                    keys.insert(localImageID)
                }
            }
            return keys
        }
    }

    /// For each candidate key, deletes the original and thumbnail only if the partition's reference set does
    /// not contain it. If the reference set cannot be read, nothing is deleted.
    /// The partition may differ from the active one (cleaning an old partition's images after sign-out), but
    /// if the active partition changes mid-round the remaining batches are abandoned (fail-closed).
    /// At most `maxDeletions` keys are deleted per round and the rest are left to the next launch sweep;
    /// candidates come from explicit deletions, so there is no mass-deletion abort here.
    /// - Returns: The keys that were actually deleted.
    @discardableResult
    static func purgeUnreferencedImages(
        _ candidates: Set<String>,
        partitionUID: String,
        references: ReferenceReader,
        currentUID: PartitionProbe = { AppSessionStore.activeUID },
        batchSize: Int = ImageOrphanSweeper.batchSize,
        maxDeletions: Int = SweepLimits.standard.maxDeletions
    ) -> Set<String> {
        let keys = candidates.filter { !$0.isEmpty }
        guard !keys.isEmpty else { return [] }
        let startUID = currentUID()
        guard let referenced = try? references() else {
            log("purge", candidates: keys.count, deleted: 0, bytes: 0, abort: "reference-read-failed")
            return []
        }
        let unreferenced = keys.subtracting(referenced).sorted()
        let targets = Array(unreferenced.prefix(max(maxDeletions, 0)))
        let batch = max(batchSize, 1)
        var deleted = Set<String>()
        var bytes = 0
        var abort: String? = targets.count < unreferenced.count ? "cap-reached" : nil
        for start in stride(from: 0, to: targets.count, by: batch) {
            guard currentUID() == startUID else {
                abort = "partition-switched"
                break
            }
            for key in targets[start..<min(start + batch, targets.count)] {
                bytes += deleteImageFiles(key, partitionUID: partitionUID)
                deleted.insert(key)
            }
        }
        log("purge", candidates: unreferenced.count, deleted: deleted.count, bytes: bytes, abort: abort)
        return deleted
    }

    /// Launch orphan sweep: candidates are all keys in the images directory minus the reference set, skipping
    /// avatars and files modified after "launch time minus grace".
    /// - Nothing is deleted if listing the directory or reading the reference set fails, or if the candidate
    ///   count exceeds `massDeletionMinCandidates` and more than `massDeletionRatio` of the stored keys;
    /// - Each batch holds at most `batchSize` keys with `Task.yield()` between batches; before each batch the
    ///   active partition must still be `partitionUID`, otherwise the remaining batches are abandoned;
    /// - At most `maxDeletions` keys are deleted per round; the rest are left to the next launch.
    /// - Parameter launchedAt: When this launch started (captured when AppState is created). The grace window
    ///   counts from it rather than from when the sweep runs, so files written during this run are never
    ///   candidates.
    /// - Parameter fileDate: How a file's date is read, by default max(content modification, attribute
    ///   change); see `ImageStore.lastWriteDate`.
    /// - Returns: The number of keys actually deleted.
    @concurrent
    @discardableResult
    static func sweepOnLaunch(
        partitionUID: String,
        references: ReferenceReader,
        launchedAt: Date,
        grace: TimeInterval = launchGrace,
        currentUID: PartitionProbe = { AppSessionStore.activeUID },
        limits: SweepLimits = .standard,
        fileDate: ImageStore.FileDateReader = ImageStore.lastWriteDate
    ) async -> Int {
        guard let files = try? ImageStore.allImageKeys(partitionUID: partitionUID, fileDate: fileDate) else {
            log("sweep", candidates: 0, deleted: 0, bytes: 0, abort: "list-failed")
            return 0
        }
        guard !files.isEmpty else { return 0 }
        guard let referenced = try? references() else {
            log("sweep", candidates: 0, deleted: 0, bytes: 0, abort: "reference-read-failed")
            return 0
        }
        let cutoff = launchedAt.addingTimeInterval(-grace)
        let orphans = files.compactMap { key, modified -> String? in
            guard !key.hasPrefix(avatarKeyPrefix), !referenced.contains(key), modified < cutoff else { return nil }
            return key
        }.sorted()
        if orphans.count > limits.massDeletionMinCandidates,
           Double(orphans.count) > Double(files.count) * limits.massDeletionRatio {
            log("sweep", candidates: orphans.count, deleted: 0, bytes: 0, abort: "mass-deletion")
            return 0
        }

        let batch = max(limits.batchSize, 1)
        let targets = orphans.prefix(max(limits.maxDeletions, 0))
        var deleted = 0
        var bytes = 0
        var abort: String? = targets.count < orphans.count ? "cap-reached" : nil
        for start in stride(from: 0, to: targets.count, by: batch) {
            if start > 0 { await Task.yield() }
            if Task.isCancelled {
                abort = "cancelled"
                break
            }
            guard currentUID() == partitionUID else {
                abort = "partition-switched"
                break
            }
            for key in targets[start..<min(start + batch, targets.count)] {
                bytes += deleteImageFiles(key, partitionUID: partitionUID)
                deleted += 1
            }
        }
        log("sweep", candidates: orphans.count, deleted: deleted, bytes: bytes, abort: abort)
        return deleted
    }

    /// Deletes one key's original and thumbnail, returning the bytes removed (sizes are read before deleting).
    private static func deleteImageFiles(_ key: String, partitionUID: String) -> Int {
        let dir = AppSessionStore.imagesDir(for: partitionUID)
        var bytes = 0
        for ext in ["img", "thumb"] {
            let path = dir.appendingPathComponent("\(key).\(ext)").path
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                bytes += size.intValue
            }
        }
        ImageStore.deleteImage(for: key, partitionUID: partitionUID)
        return bytes
    }

    /// One line per round: candidates, deleted, bytes, abort reason. Contains no keys or user content.
    private static func log(_ round: String, candidates: Int, deleted: Int, bytes: Int, abort: String?) {
        logger.info(
            "image-\(round, privacy: .public) candidates=\(candidates) deleted=\(deleted) bytes=\(bytes) abort=\(abort ?? "none", privacy: .public)"
        )
    }
}
