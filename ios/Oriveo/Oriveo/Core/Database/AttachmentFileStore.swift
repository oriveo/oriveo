import Foundation

final class AttachmentFileStore: @unchecked Sendable {
    private let rootDirectory: URL

    nonisolated init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    nonisolated func saveBase64(_ base64Data: String, for id: String) throws -> String {
        guard let data = Data(base64Encoded: base64Data) else {
            throw AttachmentFileStoreError.invalidBase64Data
        }
        try ensureDirectory()
        try data.write(to: fileURL(for: id), options: .atomic)
        return id
    }

    nonisolated func loadBase64(for id: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return data.base64EncodedString()
    }

    nonisolated func exists(id: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    nonisolated func deleteFile(for id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    nonisolated func prune(keeping ids: Set<String>) {
        try? ensureDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where !ids.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Sidecar cleanup on the launch path: only deletes files that no database row references and whose last write time is
    /// earlier than "launch time - grace"; files whose time cannot be read are skipped; at most `maxDeletions` files per round,
    /// the rest go on the next launch; before every batch of deletions the currently active partition must still be `partitionUID`,
    /// otherwise the remaining batches are abandoned.
    /// - Returns: the number of files actually deleted.
    @discardableResult
    nonisolated func pruneOnLaunch(keeping ids: Set<String>, guard launchGuard: AttachmentLaunchPruneGuard) -> Int {
        guard launchGuard.currentUID() == launchGuard.partitionUID else { return 0 }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: Array(ImageStore.fileDateResourceKeys)
        ) else { return 0 }
        let cutoff = launchGuard.launchedAt.addingTimeInterval(-launchGuard.grace)
        let orphans = files.filter { file in
            guard !ids.contains(file.deletingPathExtension().lastPathComponent) else { return false }
            guard let written = (try? file.resourceValues(forKeys: ImageStore.fileDateResourceKeys))
                .flatMap(ImageStore.lastWriteDate) else { return false }
            return written < cutoff
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let targets = Array(orphans.prefix(max(launchGuard.maxDeletions, 0)))
        let batch = max(launchGuard.batchSize, 1)
        var deleted = 0
        for start in stride(from: 0, to: targets.count, by: batch) {
            guard launchGuard.currentUID() == launchGuard.partitionUID else { break }
            for file in targets[start..<min(start + batch, targets.count)] {
                if (try? FileManager.default.removeItem(at: file)) != nil { deleted += 1 }
            }
        }
        return deleted
    }

    nonisolated private func fileURL(for id: String) -> URL {
        rootDirectory.appendingPathComponent("\(id).bin")
    }

    nonisolated private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }
}

/// Guard rails for the launch-path sidecar cleanup: partition check, per-round limit and grace (the same values as the image launch sweep).
nonisolated struct AttachmentLaunchPruneGuard: Sendable {
    var partitionUID: String
    /// The launch time of this run; the grace period is counted from it.
    var launchedAt: Date
    var grace: TimeInterval = ImageOrphanSweeper.launchGrace
    var maxDeletions = ImageOrphanSweeper.SweepLimits.standard.maxDeletions
    var batchSize = ImageOrphanSweeper.batchSize
    var currentUID: ImageOrphanSweeper.PartitionProbe = { AppSessionStore.activeUID }
}

enum AttachmentFileStoreError: Error {
    case invalidBase64Data
}
