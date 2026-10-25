import Foundation
import GRDB
import Testing
@testable import Oriveo

/// Attachment file cleanup contract, item 7: six cases; sweep hardening contract, item 6: five cases.
/// References are always read from the attachment table of the real schema (production rows written by ConversationStore).
@Suite("ImageOrphanSweeper", .serialized)
struct ImageOrphanSweeperTests {

    private struct Fixture {
        let uid: String
        let pool: DatabasePool
        let store: ConversationStore

        var references: ImageOrphanSweeper.ReferenceReader {
            let pool = pool
            return { try ImageOrphanSweeper.referenceKeys(in: pool) }
        }

        /// This partition stays the active partition throughout (the fixture partition never writes active-uid; the sweep checks the partition via an injected probe).
        var activePartition: ImageOrphanSweeper.PartitionProbe {
            let uid = uid
            return { uid }
        }
    }

    /// From the nth call on (starting at 1) it reports a different partition, simulating an account switch mid-round.
    private final class SwitchingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let uid: String
        private let switchOnCall: Int

        init(uid: String, switchOnCall: Int) {
            self.uid = uid
            self.switchOnCall = switchOnCall
        }

        var probe: ImageOrphanSweeper.PartitionProbe {
            { self.next() }
        }

        private func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return calls >= switchOnCall ? "switched-\(uid)" : uid
        }
    }

    private static let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])

    /// Reads only the content modification date. Cases fake an old mtime via `setAttributes`, which itself refreshes the attribute-change time to now;
    /// the grace period can only be judged against the faked time with this reader. The production default (max(content modification, attribute change)) is covered by `orphanSweep_copiedOldMtimeProtectedByCtime`.
    private static let mtimeOnly: ImageStore.FileDateReader = { $0.contentModificationDate }

    private func withFixture(_ prefix: String, _ body: (Fixture) async throws -> Void) async throws {
        let uid = "\(prefix)-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid)) }
        try FileManager.default.createDirectory(at: AppSessionStore.userDir(for: uid), withIntermediateDirectories: true)
        let pool = try DatabasePool(
            path: AppSessionStore.databasePath(for: uid).path,
            configuration: DatabaseSchema.makeConfiguration()
        )
        let files = AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: uid))
        try DatabaseSchema.makeMigrator(attachmentFileStore: files).migrate(pool)
        try await body(Fixture(uid: uid, pool: pool, store: ConversationStore(dbPool: pool, attachmentFileStore: files)))
    }

    private func saveImage(_ key: String, uid: String, modifiedAt date: Date? = nil) throws {
        ImageStore.save(imageData: Self.bytes, for: key, partitionUID: uid)
        ImageStore.saveThumbnail(imageData: Self.bytes, for: key, partitionUID: uid)
        guard let date else { return }
        let dir = AppSessionStore.imagesDir(for: uid)
        for ext in ["img", "thumb"] {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: dir.appendingPathComponent("\(key).\(ext)").path
            )
        }
    }

    private func thumbnailExists(_ key: String, uid: String) -> Bool {
        FileManager.default.fileExists(
            atPath: AppSessionStore.imagesDir(for: uid).appendingPathComponent("\(key).thumb").path
        )
    }

    /// Stores a conversation with an image attachment and returns that attachment.
    @discardableResult
    private func storeConversation(
        with attachment: Oriveo.Attachment,
        in fixture: Fixture
    ) throws -> Conversation {
        let conversation = TestFactories.makeConversation(
            messages: [TestFactories.makeMessage(role: .user, text: "img", attachments: [attachment])]
        )
        try fixture.store.upsertConversations([conversation])
        return conversation
    }

    // MARK: - purgeUnreferencedImages

    @Test("An unreferenced candidate key is deleted together with its original image and thumbnail")
    func attachmentPurge_deletesUnreferencedCandidate() async throws {
        try await withFixture("purge-unreferenced") { fixture in
            let localImageID = "local-\(UUID().uuidString)"
            let attachment = TestFactories.makeImageAttachment(localImageID: localImageID)
            let conversation = try storeConversation(with: attachment, in: fixture)
            try saveImage(localImageID, uid: fixture.uid)
            try saveImage(attachment.id.uuidString, uid: fixture.uid)

            try fixture.store.deleteConversation(id: conversation.id)
            let deleted = ImageOrphanSweeper.purgeUnreferencedImages(
                [localImageID, attachment.id.uuidString],
                partitionUID: fixture.uid,
                references: fixture.references
            )

            #expect(deleted == [localImageID, attachment.id.uuidString])
            #expect(!ImageStore.imageExists(for: localImageID, partitionUID: fixture.uid))
            #expect(!thumbnailExists(localImageID, uid: fixture.uid))
            #expect(!ImageStore.imageExists(for: attachment.id.uuidString, partitionUID: fixture.uid))
            #expect(!thumbnailExists(attachment.id.uuidString, uid: fixture.uid))
        }
    }

    @Test("A conflict copy still references the same key: deleting one conversation keeps the shared file")
    func attachmentPurge_keepsSharedKey() async throws {
        try await withFixture("purge-shared") { fixture in
            let sharedKey = "shared-\(UUID().uuidString)"
            let original = TestFactories.makeImageAttachment(localImageID: sharedKey)
            let copy = TestFactories.makeImageAttachment(localImageID: sharedKey)
            let deletedConversation = try storeConversation(with: original, in: fixture)
            try storeConversation(with: copy, in: fixture)
            // A downloaded key referenced by another attachment's localImageID also counts as a reference.
            let downloadKeyHolder = TestFactories.makeImageAttachment(localImageID: original.id.uuidString)
            try storeConversation(with: downloadKeyHolder, in: fixture)
            try saveImage(sharedKey, uid: fixture.uid)
            try saveImage(original.id.uuidString, uid: fixture.uid)

            try fixture.store.deleteConversation(id: deletedConversation.id)
            let deleted = ImageOrphanSweeper.purgeUnreferencedImages(
                [sharedKey, original.id.uuidString],
                partitionUID: fixture.uid,
                references: fixture.references
            )

            #expect(deleted.isEmpty)
            #expect(ImageStore.imageExists(for: sharedKey, partitionUID: fixture.uid))
            #expect(ImageStore.imageExists(for: original.id.uuidString, partitionUID: fixture.uid))
        }
    }

    @Test("Reference set read fails: nothing is deleted this round")
    func attachmentPurge_referenceReadFails_deletesNothing() async throws {
        try await withFixture("purge-read-fails") { fixture in
            let key = "orphan-\(UUID().uuidString)"
            try saveImage(key, uid: fixture.uid)
            struct ReadFailure: Error {}

            let deleted = ImageOrphanSweeper.purgeUnreferencedImages(
                [key],
                partitionUID: fixture.uid,
                references: { throw ReadFailure() }
            )
            let swept = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: { throw ReadFailure() },
                launchedAt: Date().addingTimeInterval(48 * 3600),
                currentUID: fixture.activePartition
            )

            #expect(deleted.isEmpty)
            #expect(swept == 0)
            #expect(ImageStore.imageExists(for: key, partitionUID: fixture.uid))
        }
    }

    // MARK: - sweepOnLaunch

    @Test("Launch sweep deletes orphans outside the grace period across all batches and keeps referenced files")
    func orphanSweep_deletesOrphansOutsideGrace() async throws {
        try await withFixture("sweep-orphans") { fixture in
            let launchedAt = Date()
            let old = launchedAt.addingTimeInterval(-25 * 3600)
            let referencedKey = "kept-\(UUID().uuidString)"
            let attachment = TestFactories.makeImageAttachment(localImageID: referencedKey)
            try storeConversation(with: attachment, in: fixture)
            try saveImage(referencedKey, uid: fixture.uid, modifiedAt: old)
            try saveImage(attachment.id.uuidString, uid: fixture.uid, modifiedAt: old)
            // More than one batch, to verify everything is deleted across batches (batch size is injected as 2: the real batch of 200 would first hit the abnormal abort for "candidates > 200 and over half").
            let limits = ImageOrphanSweeper.SweepLimits(batchSize: 2)
            let orphanCount = limits.batchSize * 2 + 1
            let orphans = (0..<orphanCount).map { "orphan-\($0)-\(UUID().uuidString)" }
            for key in orphans { try saveImage(key, uid: fixture.uid, modifiedAt: old) }

            let deleted = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: fixture.references,
                launchedAt: launchedAt,
                currentUID: fixture.activePartition,
                limits: limits,
                fileDate: Self.mtimeOnly
            )

            #expect(deleted == orphanCount)
            #expect(orphans.allSatisfy { !ImageStore.imageExists(for: $0, partitionUID: fixture.uid) })
            #expect(orphans.allSatisfy { !thumbnailExists($0, uid: fixture.uid) })
            #expect(ImageStore.imageExists(for: referencedKey, partitionUID: fixture.uid))
            #expect(ImageStore.imageExists(for: attachment.id.uuidString, partitionUID: fixture.uid))
            #expect(try ImageStore.allImageKeys(partitionUID: fixture.uid).count == 2)
        }
    }

    @Test("Launch sweep skips avatars and files within the grace period; the grace period is injectable")
    func orphanSweep_keepsAvatarAndGrace() async throws {
        try await withFixture("sweep-avatar-grace") { fixture in
            let now = Date()
            let avatarKey = "user-avatar-\(UUID().uuidString)"
            let freshKey = "fresh-\(UUID().uuidString)"
            let staleKey = "stale-\(UUID().uuidString)"
            try saveImage(avatarKey, uid: fixture.uid, modifiedAt: now.addingTimeInterval(-90 * 24 * 3600))
            try saveImage(freshKey, uid: fixture.uid, modifiedAt: now.addingTimeInterval(-23 * 3600))
            try saveImage(staleKey, uid: fixture.uid, modifiedAt: now.addingTimeInterval(-2 * 3600))

            let defaultGrace = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: fixture.references,
                launchedAt: now,
                currentUID: fixture.activePartition,
                fileDate: Self.mtimeOnly
            )
            #expect(defaultGrace == 0)
            #expect(ImageStore.imageExists(for: freshKey, partitionUID: fixture.uid))
            #expect(ImageStore.imageExists(for: staleKey, partitionUID: fixture.uid))

            let shortGrace = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: fixture.references,
                launchedAt: now,
                grace: 3600,
                currentUID: fixture.activePartition,
                fileDate: Self.mtimeOnly
            )
            #expect(shortGrace == 2)
            #expect(!ImageStore.imageExists(for: freshKey, partitionUID: fixture.uid))
            #expect(!ImageStore.imageExists(for: staleKey, partitionUID: fixture.uid))
            #expect(ImageStore.imageExists(for: avatarKey, partitionUID: fixture.uid))
        }
    }

    @Test("Sweep and purge on a read-only database: orphans are still deleted and the database is unchanged")
    func orphanSweep_noDbOrCloudWrites() async throws {
        try await withFixture("sweep-no-writes") { fixture in
            let old = Date().addingTimeInterval(-25 * 3600)
            let referencedKey = "kept-\(UUID().uuidString)"
            let attachment = TestFactories.makeImageAttachment(localImageID: referencedKey)
            try storeConversation(with: attachment, in: fixture)
            let orphan = "orphan-\(UUID().uuidString)"
            let purgeOrphan = "purge-\(UUID().uuidString)"
            try saveImage(referencedKey, uid: fixture.uid, modifiedAt: old)
            try saveImage(orphan, uid: fixture.uid, modifiedAt: old)
            try saveImage(purgeOrphan, uid: fixture.uid)

            let snapshot = try counts(in: fixture.pool)
            let generation = fixture.store.writeGeneration
            // Read-only connection: if the sweep wrote to the database at all, reading the reference set would fail, nothing would be deleted, and the deletion assertions below would turn red.
            var readOnly = Configuration()
            readOnly.readonly = true
            let readOnlyQueue = try DatabaseQueue(
                path: AppSessionStore.databasePath(for: fixture.uid).path,
                configuration: readOnly
            )
            let references: ImageOrphanSweeper.ReferenceReader = {
                try ImageOrphanSweeper.referenceKeys(in: readOnlyQueue)
            }

            let swept = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: references,
                launchedAt: Date(),
                currentUID: fixture.activePartition,
                fileDate: Self.mtimeOnly
            )
            let purged = ImageOrphanSweeper.purgeUnreferencedImages(
                [purgeOrphan, referencedKey],
                partitionUID: fixture.uid,
                references: references
            )

            #expect(swept == 1)
            #expect(purged == [purgeOrphan])
            #expect(!ImageStore.imageExists(for: orphan, partitionUID: fixture.uid))
            #expect(ImageStore.imageExists(for: referencedKey, partitionUID: fixture.uid))
            #expect(try counts(in: fixture.pool) == snapshot)
            #expect(fixture.store.writeGeneration == generation)
        }
    }

    // MARK: - Sweep hardening (contract item 6)

    @Test("Grace counts from launch time: a file older than 24 h at execution but newer than launch minus 24 h is kept")
    func orphanSweep_graceFromLaunchTime() async throws {
        try await withFixture("sweep-grace-launch") { fixture in
            // The process has been running for 10 h: the cutoff is launch - 24 h = now - 34 h, not now - 24 h.
            let now = Date()
            let launchedAt = now.addingTimeInterval(-10 * 3600)
            let beforeCutoff = "before-\(UUID().uuidString)"
            let afterCutoff = "after-\(UUID().uuidString)"
            let writtenThisRun = "this-run-\(UUID().uuidString)"
            try saveImage(beforeCutoff, uid: fixture.uid, modifiedAt: now.addingTimeInterval(-35 * 3600))
            try saveImage(afterCutoff, uid: fixture.uid, modifiedAt: now.addingTimeInterval(-30 * 3600))
            try saveImage(writtenThisRun, uid: fixture.uid, modifiedAt: now.addingTimeInterval(-3600))

            let deleted = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: fixture.references,
                launchedAt: launchedAt,
                currentUID: fixture.activePartition,
                fileDate: Self.mtimeOnly
            )

            #expect(deleted == 1)
            #expect(!ImageStore.imageExists(for: beforeCutoff, partitionUID: fixture.uid))
            #expect(ImageStore.imageExists(for: afterCutoff, partitionUID: fixture.uid))
            #expect(ImageStore.imageExists(for: writtenThisRun, partitionUID: fixture.uid))
        }
    }

    @Test("Partition switched mid-sweep: abandon from the switching batch on, delete nothing further")
    func orphanSweep_partitionSwitchMidRun_aborts() async throws {
        try await withFixture("sweep-partition-switch") { fixture in
            let launchedAt = Date()
            let orphans = (0..<5).map { "orphan-\($0)-\(UUID().uuidString)" }.sorted()
            for key in orphans {
                try saveImage(key, uid: fixture.uid, modifiedAt: launchedAt.addingTimeInterval(-25 * 3600))
            }
            // The check passes before the first batch; by the second batch the partition has been switched away.
            let switching = SwitchingProbe(uid: fixture.uid, switchOnCall: 2)

            let deleted = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: fixture.references,
                launchedAt: launchedAt,
                currentUID: switching.probe,
                limits: ImageOrphanSweeper.SweepLimits(batchSize: 2),
                fileDate: Self.mtimeOnly
            )

            #expect(deleted == 2)
            #expect(orphans.prefix(2).allSatisfy { !ImageStore.imageExists(for: $0, partitionUID: fixture.uid) })
            #expect(orphans.dropFirst(2).allSatisfy { ImageStore.imageExists(for: $0, partitionUID: fixture.uid) })

            // Not the active partition from the start: nothing is deleted.
            let notActive = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: fixture.references,
                launchedAt: launchedAt,
                currentUID: { "someone-else" },
                fileDate: Self.mtimeOnly
            )
            #expect(notActive == 0)
            #expect(try ImageStore.allImageKeys(partitionUID: fixture.uid).count == 3)
        }
    }

    @Test("Candidates > 200 and over half of the stored keys: treated as abnormal, nothing deleted this round")
    func orphanSweep_massDeletionAborts() async throws {
        try await withFixture("sweep-mass-deletion") { fixture in
            let launchedAt = Date()
            let old = launchedAt.addingTimeInterval(-25 * 3600)
            let limits = ImageOrphanSweeper.SweepLimits.standard
            #expect(limits.massDeletionMinCandidates == 200)
            #expect(limits.massDeletionRatio == 0.5)
            let keptKey = "kept-\(UUID().uuidString)"
            try storeConversation(with: TestFactories.makeImageAttachment(localImageID: keptKey), in: fixture)
            try saveImage(keptKey, uid: fixture.uid, modifiedAt: old)
            let orphans = (0..<(limits.massDeletionMinCandidates + 1)).map { "orphan-\($0)-\(UUID().uuidString)" }
            for key in orphans { try saveImage(key, uid: fixture.uid, modifiedAt: old) }

            let deleted = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: fixture.references,
                launchedAt: launchedAt,
                currentUID: fixture.activePartition,
                fileDate: Self.mtimeOnly
            )

            #expect(deleted == 0)
            #expect(orphans.allSatisfy { ImageStore.imageExists(for: $0, partitionUID: fixture.uid) })
            #expect(try ImageStore.allImageKeys(partitionUID: fixture.uid).count == orphans.count + 1)
        }
    }

    @Test("A single round has a deletion cap (default 500); the rest is deleted next round")
    func orphanSweep_capPerRound() async throws {
        try await withFixture("sweep-cap") { fixture in
            #expect(ImageOrphanSweeper.SweepLimits.standard.maxDeletions == 500)
            let launchedAt = Date()
            let orphans = (0..<5).map { "orphan-\($0)-\(UUID().uuidString)" }
            for key in orphans {
                try saveImage(key, uid: fixture.uid, modifiedAt: launchedAt.addingTimeInterval(-25 * 3600))
            }
            let limits = ImageOrphanSweeper.SweepLimits(batchSize: 2, maxDeletions: 3)

            let first = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: fixture.references,
                launchedAt: launchedAt,
                currentUID: fixture.activePartition,
                limits: limits,
                fileDate: Self.mtimeOnly
            )
            #expect(first == 3)
            #expect(try ImageStore.allImageKeys(partitionUID: fixture.uid).count == 2)

            let second = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: fixture.references,
                launchedAt: launchedAt,
                currentUID: fixture.activePartition,
                limits: limits,
                fileDate: Self.mtimeOnly
            )
            #expect(second == 2)
            #expect(orphans.allSatisfy { !ImageStore.imageExists(for: $0, partitionUID: fixture.uid) })
        }
    }

    @Test("Partition switched mid-purge: abandon from the switching batch on")
    func purge_partitionSwitchMidRun_aborts() async throws {
        try await withFixture("purge-partition-switch") { fixture in
            let keys = (0..<5).map { "purge-\($0)-\(UUID().uuidString)" }.sorted()
            for key in keys { try saveImage(key, uid: fixture.uid) }
            // Call 1 is the round-start snapshot, call 2 the check before the first batch, call 3 (before the second batch) has switched away.
            let switching = SwitchingProbe(uid: fixture.uid, switchOnCall: 3)

            let deleted = ImageOrphanSweeper.purgeUnreferencedImages(
                Set(keys),
                partitionUID: fixture.uid,
                references: fixture.references,
                currentUID: switching.probe,
                batchSize: 2
            )

            #expect(deleted == Set(keys.prefix(2)))
            #expect(keys.prefix(2).allSatisfy { !ImageStore.imageExists(for: $0, partitionUID: fixture.uid) })
            #expect(keys.dropFirst(2).allSatisfy { ImageStore.imageExists(for: $0, partitionUID: fixture.uid) })
        }
    }

    // MARK: - Attachment cleanup additions (contract items 1, 3, 8)

    @Test("Copied image keeping an old mtime: the attribute-change time is the copy moment, so the grace period still protects it")
    func orphanSweep_copiedOldMtimeProtectedByCtime() async throws {
        try await withFixture("sweep-copied-ctime") { fixture in
            let sourceUID = "\(fixture.uid)-source"
            defer { try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: sourceUID)) }
            let key = "copied-\(UUID().uuidString)"
            let old = Date().addingTimeInterval(-30 * 24 * 3600)
            try saveImage(key, uid: sourceUID, modifiedAt: old)
            // Copy item by item into the target partition.
            let sourceDir = AppSessionStore.imagesDir(for: sourceUID)
            let targetDir = AppSessionStore.imagesDir(for: fixture.uid)
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            for ext in ["img", "thumb"] {
                try FileManager.default.copyItem(
                    at: sourceDir.appendingPathComponent("\(key).\(ext)"),
                    to: targetDir.appendingPathComponent("\(key).\(ext)")
                )
            }
            let copied = try targetDir.appendingPathComponent("\(key).img")
                .resourceValues(forKeys: [.contentModificationDateKey])
            // Premise: the copy kept the old mtime (judged by mtime alone it is an orphan outside the grace period).
            #expect(try #require(copied.contentModificationDate) < Date().addingTimeInterval(-24 * 3600))

            let swept = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: fixture.references,
                launchedAt: Date(),
                currentUID: fixture.activePartition
            )
            #expect(swept == 0)
            #expect(ImageStore.imageExists(for: key, partitionUID: fixture.uid))

            // Contrast: reading mtime only would delete it.
            let mtimeOnly = await ImageOrphanSweeper.sweepOnLaunch(
                partitionUID: fixture.uid,
                references: fixture.references,
                launchedAt: Date(),
                currentUID: fixture.activePartition,
                fileDate: Self.mtimeOnly
            )
            #expect(mtimeOnly == 1)
            #expect(!ImageStore.imageExists(for: key, partitionUID: fixture.uid))
        }
    }

    @Test("A single purge round has a deletion cap (default 500); the rest is left for the next round")
    func purge_capPerRound() async throws {
        try await withFixture("purge-cap") { fixture in
            #expect(ImageOrphanSweeper.SweepLimits.standard.maxDeletions == 500)
            let keys = (0..<5).map { "purge-\($0)-\(UUID().uuidString)" }.sorted()
            for key in keys { try saveImage(key, uid: fixture.uid) }

            let first = ImageOrphanSweeper.purgeUnreferencedImages(
                Set(keys),
                partitionUID: fixture.uid,
                references: fixture.references,
                currentUID: fixture.activePartition,
                batchSize: 2,
                maxDeletions: 3
            )
            #expect(first == Set(keys.prefix(3)))
            #expect(keys.dropFirst(3).allSatisfy { ImageStore.imageExists(for: $0, partitionUID: fixture.uid) })

            // The remainder (picked up by the next launch sweep in the real path) goes through one more round.
            let second = ImageOrphanSweeper.purgeUnreferencedImages(
                Set(keys.dropFirst(3)),
                partitionUID: fixture.uid,
                references: fixture.references,
                currentUID: fixture.activePartition,
                batchSize: 2,
                maxDeletions: 3
            )
            #expect(second == Set(keys.dropFirst(3)))
            #expect(try ImageStore.allImageKeys(partitionUID: fixture.uid).isEmpty)
        }
    }

    @Test("Launch sidecar prune: inactive partition is not touched, files within grace are kept, a single round has a cap")
    func sidecarPrune_launchGuards() async throws {
        try await withFixture("sidecar-launch") { fixture in
            let files = AttachmentFileStore(rootDirectory: AppSessionStore.filesDir(for: fixture.uid))
            let ids = (0..<3).map { "orphan-\($0)-\(UUID().uuidString)" }
            for id in ids { _ = try files.saveBase64(Self.bytes.base64EncodedString(), for: id) }
            func remaining() -> Int { ids.filter { files.exists(id: $0) }.count }
            let later = Date().addingTimeInterval(48 * 3600)
            let uid = fixture.uid

            try fixture.store.pruneAttachmentFilesToDatabase(launchGuard: AttachmentLaunchPruneGuard(
                partitionUID: uid, launchedAt: later, currentUID: { "someone-else" }
            ))
            #expect(remaining() == 3)

            try fixture.store.pruneAttachmentFilesToDatabase(launchGuard: AttachmentLaunchPruneGuard(
                partitionUID: uid, launchedAt: Date(), currentUID: { uid }
            ))
            #expect(remaining() == 3)

            #expect(AttachmentLaunchPruneGuard(partitionUID: uid, launchedAt: later).maxDeletions == 500)
            try fixture.store.pruneAttachmentFilesToDatabase(launchGuard: AttachmentLaunchPruneGuard(
                partitionUID: uid, launchedAt: later, maxDeletions: 2, currentUID: { uid }
            ))
            #expect(remaining() == 1)

            try fixture.store.pruneAttachmentFilesToDatabase(launchGuard: AttachmentLaunchPruneGuard(
                partitionUID: uid, launchedAt: later, maxDeletions: 2, currentUID: { uid }
            ))
            #expect(remaining() == 0)
        }
    }

    /// Row counts of everything cleanup-related: attachments, messages, conversations, and the deletion journal.
    private func counts(in pool: DatabasePool) throws -> [String: Int] {
        try pool.read { db in
            var result: [String: Int] = [:]
            for table in ["attachment", "message", "conversation", "conversation_deletion_journal"] {
                guard try db.tableExists(table) else { continue }
                result[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return result
        }
    }
}
