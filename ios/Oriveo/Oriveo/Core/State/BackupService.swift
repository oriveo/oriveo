import Foundation
import OriveoProviderKit
import CryptoKit
import ZIPFoundation
import UniformTypeIdentifiers
import SwiftUI


struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.oriveoBackup, .json]

    /// The exported zip in the temporary directory; the export screen deletes it once the exporter is done.
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Export-only document: backups are imported from a file URL instead of being read through this type.
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    /// Hands the exporter the file itself, so the zip is never loaded into memory.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: fileURL, options: [])
    }
}

// MARK: - BackupService

enum BackupService {
    nonisolated static let currentVersion = 1

    /// Import is streamed: the backup file is never read whole and has no size cap, entries are read by name
    /// one at a time, so only a single entry (counted on its inflated bytes, not its header) is bounded.
    nonisolated struct ImportLimits: Equatable, Sendable {
        let maxEntryBytes: Int
        /// The export writes an original and a thumbnail entry per image with no image cap, so this only guards
        /// against a pathological entry flood (65,536 central directory records still walk in milliseconds).
        let maxEntries: Int
        let maxConversations: Int

        /// Per-entry budget for `BoundedArchiveReader`; there is no total budget.
        var archiveBudget: ArchiveExtractionBudget {
            ArchiveExtractionBudget(maxEntryBytes: maxEntryBytes, maxTotalBytes: Int.max, maxEntries: maxEntries)
        }

        static func forPhysicalMemory(_ physicalMemory: UInt64) -> ImportLimits {
            let mib = 1024 * 1024
            let memoryBytes = min(physicalMemory, UInt64(Int.max))
            let entryBytes = min(max(Int(memoryBytes / 48), 64 * mib), 128 * mib)
            return ImportLimits(maxEntryBytes: entryBytes, maxEntries: 65_536, maxConversations: 250_000)
        }

        static var currentDevice: ImportLimits {
            forPhysicalMemory(ProcessInfo.processInfo.physicalMemory)
        }
    }

    /// The asset entries (attachments/) of one parsed backup, read by name one entry at a time through the
    /// zip's central directory; a read holds a single entry's bytes and is bounded by
    /// `ImportLimits.maxEntryBytes` on the inflated bytes. Keys follow `attachmentChecksums`: the name after
    /// `attachments/`. A source made with an owned file deletes that file when it is released.
    nonisolated final class EntrySource: @unchecked Sendable {
        private let lock = NSLock()
        private let archive: Archive?
        private let index: [String: Entry]
        private let digests: [String: String]
        private let memory: [String: Data]
        private let limits: ImportLimits
        /// The plain JSON backup file, reread for the raw-bytes checksum criterion.
        private let jsonFile: URL?
        private let ownedFile: URL?

        fileprivate init(
            archive: Archive?, index: [String: Entry], digests: [String: String], limits: ImportLimits,
            jsonFile: URL?, ownedFile: URL?
        ) {
            self.archive = archive
            self.index = index
            self.digests = digests
            self.memory = [:]
            self.limits = limits
            self.jsonFile = jsonFile
            self.ownedFile = ownedFile
        }

        /// Entries already in memory (the dictionary entry points kept for callers that hold the bytes).
        init(images: [String: Data]) {
            archive = nil
            index = [:]
            digests = [:]
            memory = images
            limits = .currentDevice
            jsonFile = nil
            ownedFile = nil
        }

        deinit {
            if let ownedFile { try? FileManager.default.removeItem(at: ownedFile) }
        }

        func contains(_ key: String) -> Bool {
            archive == nil ? memory[key] != nil : index[key] != nil
        }

        /// One entry's bytes, or nil when the backup has no such entry or it cannot be read within the limit.
        func data(_ key: String) -> Data? {
            try? read(key)
        }

        /// `data(_:)` off the caller's executor, so restores started on the main actor do not inflate there.
        @concurrent
        func load(_ key: String) async -> Data? {
            data(key)
        }

        func read(_ key: String) throws -> Data? {
            guard let archive else { return memory[key] }
            guard let entry = index[key] else { return nil }
            lock.lock()
            defer { lock.unlock() }
            var reader = BoundedArchiveReader(budget: limits.archiveBudget)
            return try BackupService.boundedData(from: archive, entry: entry, reader: &reader)
        }

        /// Every entry at once, for the dictionary entry points.
        func allData() throws -> [String: Data] {
            guard archive != nil else { return memory }
            var images: [String: Data] = [:]
            for key in index.keys {
                images[key] = try read(key)
            }
            return images
        }

        /// Keys whose bytes are missing or hash differently from `expected`. Archive entries use the digest
        /// taken when the backup was parsed, so nothing is inflated again.
        func checksumMismatches(expected: [String: String]) -> [String] {
            expected.compactMap { key, hash in
                let digest = archive == nil ? memory[key].map { CanonicalJSON.checksum(of: $0) } : digests[key]
                return digest == hash ? nil : key
            }
        }

        /// The stored data.json bytes (or the plain JSON file) for the raw checksum criterion.
        fileprivate func storedJSON() -> Data? {
            if let jsonFile {
                return try? BoundedFileReader.data(at: jsonFile, maxBytes: limits.maxEntryBytes)
            }
            guard let archive else { return nil }
            lock.lock()
            defer { lock.unlock() }
            guard let entry = archive["data.json"] else { return nil }
            var reader = BoundedArchiveReader(budget: limits.archiveBudget)
            return try? BackupService.boundedData(from: archive, entry: entry, reader: &reader)
        }
    }

    nonisolated private struct ImageStoreReplacement: Sendable {
        let targetDirectory: URL
        let backupDirectory: URL?
    }

    /// One asset entry of an export: its full zip name and a reader of its bytes. The reader runs once for the
    /// checksum and once while writing, so at most one entry's bytes are held at a time.
    nonisolated private struct BackupAssetEntry: Sendable {
        let name: String
        let read: @Sendable () -> Data?
    }

    private struct PreparedBackupPayload {
        let backupFile: BackupFile
        /// attachments/ entries in message order.
        let entries: [BackupAssetEntry]
    }

    nonisolated private static let attachmentsPrefix = "attachments/"

    #if DEBUG
    @MainActor
    struct TestingHooks {
        var beforeReplaceAllCommit: (() async throws -> Void)?
    }

    @MainActor
    static var testingHooks = TestingHooks()

    @MainActor
    private static func currentBeforeReplaceAllCommitHook() -> (() async throws -> Void)? {
        testingHooks.beforeReplaceAllCommit
    }

    /// Records, for each image disk step of export and import, whether it ran on the main thread. Only records
    /// while enabled.
    nonisolated final class DiskThreadProbe: @unchecked Sendable {
        struct Record: Equatable, Sendable {
            let step: String
            let onMainThread: Bool
        }

        private let lock = NSLock()
        private var enabled = false
        private var records: [Record] = []

        func start() {
            lock.withLock {
                enabled = true
                records = []
            }
        }

        /// Stops recording and returns what was recorded since `start()`.
        func stop() -> [Record] {
            lock.withLock {
                enabled = false
                defer { records = [] }
                return records
            }
        }

        func record(_ step: String) {
            let onMain = Thread.isMainThread
            lock.withLock {
                guard enabled else { return }
                records.append(Record(step: step, onMainThread: onMain))
            }
        }
    }

    nonisolated static let diskThreadProbe = DiskThreadProbe()
    #endif

    nonisolated private static func recordDiskStep(_ step: String) {
        #if DEBUG
        diskThreadProbe.record(step)
        #endif
    }


    /// Thin wrapper over `exportBackupFile` for callers that want the bytes: reads the file back and deletes it.
    static func exportBackup(
        providers: [Provider],
        conversations: [Conversation],
        folders: [Folder] = [],
        skills: [Skill] = [],
        preferences: AppPreference,
        lastUsedModelRef: LastUsedModelRef?,
        includeKeys: Bool,
        password: String?,
        allowEmpty: Bool = false,
        imagePartitionUID: String? = nil,
        notes: [Note] = [],
        noteFolders: [NoteFolder] = []
    ) async throws -> Data {
        let url = try await exportBackupFile(
            providers: providers,
            conversations: conversations,
            folders: folders,
            skills: skills,
            preferences: preferences,
            lastUsedModelRef: lastUsedModelRef,
            includeKeys: includeKeys,
            password: password,
            allowEmpty: allowEmpty,
            imagePartitionUID: imagePartitionUID,
            notes: notes,
            noteFolders: noteFolders
        )
        return try await Task.detached {
            defer { try? FileManager.default.removeItem(at: url) }
            return try Data(contentsOf: url)
        }.value
    }

    /// Writes the backup zip to a temporary file and returns its URL; the caller owns the file. data.json goes
    /// first, then each attachment is read and written one at a time, so the archive is never held in memory.
    static func exportBackupFile(
        providers: [Provider],
        conversations: [Conversation],
        folders: [Folder] = [],
        skills: [Skill] = [],
        preferences: AppPreference,
        lastUsedModelRef: LastUsedModelRef?,
        includeKeys: Bool,
        password: String?,
        allowEmpty: Bool = false,
        imagePartitionUID: String? = nil,
        notes: [Note] = [],
        noteFolders: [NoteFolder] = []
    ) async throws -> URL {
        let payload = try await prepareBackupPayload(
            providers: providers,
            conversations: conversations,
            folders: folders,
            skills: skills,
            preferences: preferences,
            lastUsedModelRef: lastUsedModelRef,
            includeKeys: includeKeys,
            password: password,
            allowEmpty: allowEmpty,
            imagePartitionUID: imagePartitionUID,
            notes: notes,
            noteFolders: noteFolders
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let backupJSON = try encoder.encode(payload.backupFile)
        let entries = payload.entries

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-export-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("oriveo-backup")
        return try await Task.detached {
            do {
                try writeBackupArchive(to: url, header: backupJSON, entries: entries)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return url
        }.value
    }

    /// An entry whose file went away after the checksum pass is left out, as the checksum pass leaves out one
    /// that is already gone; import then only warns about it.
    nonisolated private static func writeBackupArchive(
        to url: URL,
        header: Data,
        entries: [BackupAssetEntry]
    ) throws {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .create)
        } catch {
            throw BackupError.zipCreationFailed
        }
        recordDiskStep("export.write")
        try addArchiveEntry(archive, name: backupHeaderFilename, data: header)
        for entry in entries {
            guard let data = entry.read() else { continue }
            try addArchiveEntry(archive, name: entry.name, data: data)
        }
    }

    nonisolated private static func addArchiveEntry(_ archive: Archive, name: String, data: Data) throws {
        try archive.addEntry(
            with: name,
            type: .file,
            uncompressedSize: UInt32(data.count),
            provider: { (position: Int, size: Int) in
                data[position..<(position + size)]
            }
        )
    }

    nonisolated private struct BackupChunkManifest: Codable {
        struct Chunk: Codable {
            let filename: String
            let count: Int
        }
        let version: Int
        let totalConversations: Int
        let conversationChunks: [Chunk]
        let headerFilename: String
    }

    nonisolated private static let backupManifestFilename = "manifest.json"
    nonisolated private static let backupHeaderFilename = "data.json"

    private static func prepareBackupPayload(
        providers: [Provider],
        conversations: [Conversation],
        folders: [Folder] = [],
        skills: [Skill] = [],
        preferences: AppPreference,
        lastUsedModelRef: LastUsedModelRef?,
        includeKeys: Bool,
        password: String?,
        allowEmpty: Bool,
        imagePartitionUID: String?,
        notes: [Note] = [],
        noteFolders: [NoteFolder] = []
    ) async throws -> PreparedBackupPayload {
        let backupProviders = providers.map { BackupProvider(from: $0) }

        // Cold-start memory is a summary (messages is empty). Export must hydrate
        // full threads from the store, or a backup taken right after launch writes 0 bodies.
        let conversationsForExport = try await Self.conversationsHydratedForExport(
            conversations,
            storeUID: imagePartitionUID
        )
        let backupConversations = conversationsForExport
            .filter { !$0.isDraft || !$0.messages.isEmpty }
            .map { BackupConversation(from: $0) }
        let backupSkills = skills.map(sanitizeSkillForBackup)
        let backupNotes = notes.map { BackupNote(from: $0) }
        let backupNoteFolders = noteFolders.map { BackupNoteFolder(from: $0) }

        // Memory items section (including tombstones); legacy fields such as memoryText are still written in preferences. A table read failure is only logged.
        var memorySection: MemoryBackupSection?
        do {
            memorySection = try backupMemorySection(
                store: imagePartitionUID.flatMap { MemoryItemStore.forPartition($0) }
            )
        } catch {
            print("[BackupService] export memory items failed: \(error.localizedDescription)")
        }
        // Live memory items alone also count as exportable data (tombstones do not)
        let hasLiveMemoryItems = memorySection?.memoryItems.contains { $0.status != .deleted } == true

        guard allowEmpty || !backupProviders.isEmpty || !backupConversations.isEmpty
            || !backupSkills.isEmpty || !backupNotes.isEmpty || hasLiveMemoryItems else {
            throw BackupError.noDataToExport
        }

        let backupPrefs = BackupPreferences(
            theme: preferences.theme.rawValue,
            language: preferences.language.rawValue,
            memoryText: preferences.memoryText.isEmpty ? nil : preferences.memoryText,
            memoryAntiForgetEnabled: preferences.memoryAntiForgetEnabled ? true : nil,
            memoryAntiForgetText: preferences.memoryAntiForgetText.isEmpty ? nil : preferences.memoryAntiForgetText,
            memoryUpdatedAt: preferences.memoryUpdatedAt.map { ISO8601DateFormatter().string(from: $0) },
            darkPalette: preferences.darkPalette,
            darkPaletteCustom: preferences.darkPaletteCustom
        )

        let backupFolders = folders.isEmpty ? nil : folders.map { BackupFolder(from: $0) }
        // Checkpoints are rebuildable derived data: a table read failure is only logged and does not fail the whole backup.
        var backupContextCheckpoints: [BackupContextCheckpoint]?
        do {
            backupContextCheckpoints = try backupCheckpoints(
                store: imagePartitionUID.flatMap { ContextCompactionStore.forPartition($0) }
            )
        } catch {
            print("[BackupService] export checkpoints failed: \(error.localizedDescription)")
        }
        let backupData = BackupData(
            providers: backupProviders,
            conversations: backupConversations,
            skills: backupSkills.isEmpty ? nil : backupSkills,
            preferences: backupPrefs,
            lastUsedModelRef: lastUsedModelRef,
            folders: backupFolders,
            notes: backupNotes.isEmpty ? nil : backupNotes,
            noteFolders: backupNoteFolders.isEmpty ? nil : backupNoteFolders,
            checkpoints: backupContextCheckpoints,
            memorySchemaVersion: memorySection?.memorySchemaVersion,
            memoryItems: memorySection?.memoryItems
        )

        let dataJSON = try CanonicalJSON.encode(backupData)
        let checksum = CanonicalJSON.checksum(of: dataJSON)

        // Each file is read once for its checksum and dropped, off the main actor; the writer reads it again.
        var imageRefs: [AttachmentImageRef] = []
        for conv in backupConversations {
            for msg in conv.messages {
                guard let atts = msg.attachments else { continue }
                for att in atts where att.kind == .image {
                    guard let lid = att.localImageID else { continue }
                    imageRefs.append(AttachmentImageRef(
                        attachmentID: "\(att.id)", localImageID: lid, ext: fileExtension(for: att.mimeType)
                    ))
                }
            }
        }
        let attachmentAssets = await attachmentAssetEntries(imageRefs, partitionUID: imagePartitionUID)
        let attachmentChecksums = attachmentAssets.checksums
        let assetEntries = attachmentAssets.entries

        var encryptedKeys: String?
        if includeKeys, let password, !password.isEmpty {
            let keyEntries = providers.compactMap { provider -> BackupKeyEntry? in
                guard !provider.apiKey.isEmpty else { return nil }
                return BackupKeyEntry(
                    providerID: provider.id,
                    apiKey: provider.apiKey,
                    apiKeyPreview: provider.apiKeyPreview
                )
            }
            if !keyEntries.isEmpty {
                let payload = BackupKeysPayload(keys: keyEntries)
                let payloadData = try JSONEncoder().encode(payload)
                let encrypted = try BackupCrypto.encrypt(payloadData, password: password)
                encryptedKeys = encrypted.base64EncodedString()
            }
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let backupFile = BackupFile(
            version: currentVersion,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion,
            platform: "iOS",
            checksum: checksum,
            containsKeys: encryptedKeys != nil,
            data: backupData,
            attachmentChecksums: attachmentChecksums.isEmpty ? nil : attachmentChecksums,
            encryptedKeys: encryptedKeys
        )
        return PreparedBackupPayload(backupFile: backupFile, entries: assetEntries)
    }

    /// One chat image attachment to export: entry names come from the attachment id and extension, bytes from
    /// the local image id.
    nonisolated private struct AttachmentImageRef: Sendable {
        let attachmentID: String
        let localImageID: String
        let ext: String
    }

    /// The attachments/ entries (original, then thumbnail, in `refs` order) and their checksums keyed by file
    /// name. Each image is read once for its checksum and dropped, off the caller's executor; an image that is
    /// missing is left out.
    @concurrent
    nonisolated private static func attachmentAssetEntries(
        _ refs: [AttachmentImageRef],
        partitionUID: String?
    ) async -> (checksums: [String: String], entries: [BackupAssetEntry]) {
        var checksums: [String: String] = [:]
        var entries: [BackupAssetEntry] = []
        for ref in refs {
            let lid = ref.localImageID
            recordDiskStep("export.read")
            if let imgData = ImageStore.loadImageData(for: lid, partitionUID: partitionUID) {
                let filename = "\(ref.attachmentID).\(ref.ext)"
                checksums[filename] = CanonicalJSON.checksum(of: imgData)
                entries.append(BackupAssetEntry(name: attachmentsPrefix + filename) {
                    ImageStore.loadImageData(for: lid, partitionUID: partitionUID)
                })
            }
            if let thumbData = ImageStore.loadThumbnailData(for: lid, partitionUID: partitionUID) {
                let thumbFilename = "\(ref.attachmentID).thumb.\(ref.ext)"
                checksums[thumbFilename] = CanonicalJSON.checksum(of: thumbData)
                entries.append(BackupAssetEntry(name: attachmentsPrefix + thumbFilename) {
                    ImageStore.loadThumbnailData(for: lid, partitionUID: partitionUID)
                })
            }
        }
        return (checksums, entries)
    }

    /// Summary projections carry no message bodies, so export hydrates them from the authoritative
    /// store; conversations already loaded keep their in-memory version (a background write may not
    /// have landed yet). A failed read throws: silently exporting a backup without bodies is worse
    /// than a failed export. The store is read off the main thread, so an export started on the main
    /// actor does not block it.
    static func conversationsHydratedForExport(
        _ conversations: [Conversation],
        storeUID: String?
    ) async throws -> [Conversation] {
        guard conversations.contains(where: { !$0.messagesAreLoaded }) else {
            return conversations
        }
        guard let storeUID else {
            throw BackupError.noDataToExport
        }
        // One read transaction for the whole store is much faster than querying per conversation;
        // loaded conversations still use their in-memory version below.
        let full = try await storedConversationsForExport(uid: storeUID)
        let byID = Dictionary(full.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return conversations.map { conversation in
            guard !conversation.messagesAreLoaded, let stored = byID[conversation.id] else { return conversation }
            var hydrated = conversation
            hydrated.messages = stored.messages
            hydrated.messagesAreLoaded = true
            return hydrated
        }
    }


    /// The full projection is read on a background queue, because the bridge is main-actor isolated and a
    /// `@concurrent` caller would hop back to the main actor to read it.
    nonisolated private static func storedConversationsForExport(uid: String) async throws -> [Conversation] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                recordDiskStep("export.hydrate")
                continuation.resume(with: Result {
                    try ConversationRuntimeBridge().fetchConversationProjection(uid: uid, hydrateFilePayloads: true)
                })
            }
        }
    }

    /// Copies a picked file into the temporary directory (call it inside the security scope), so the import
    /// can read it by entry after the scope ends. The caller owns the copy.
    nonisolated static func copyImportFile(at url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            // Directories and iCloud placeholders: a localized "unrecognized" rather than a bare type name.
            throw BackupError.unrecognizedFormat
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-import-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension(url.pathExtension.isEmpty ? "oriveo-backup" : url.pathExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// Dictionary entry point kept for callers holding the bytes: the bytes go to a temporary file read by
    /// `parseBackup(at:)`, then every asset entry is read into the dictionary.
    nonisolated static func parseBackup(
        from data: Data,
        limits: ImportLimits = .currentDevice
    ) throws -> (backupFile: BackupFile, images: [String: Data]) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-parse-\(UUID().uuidString)", isDirectory: false)
        try data.write(to: url)
        let parsed = try parseBackup(at: url, limits: limits, ownsFile: true)
        return (parsed.backupFile, try parsed.entries.allData())
    }

    /// Parses the backup file at `url` without reading it whole: a zip is opened for random access, data.json
    /// (or the manifest and its chunks) is decoded, and every asset entry is inflated once, one at a time, to
    /// check its real size and take its checksum. With `ownsFile` the file is deleted when parsing fails or
    /// the returned source is released.
    nonisolated static func parseBackup(
        at url: URL,
        limits: ImportLimits = .currentDevice,
        ownsFile: Bool = false
    ) throws -> (backupFile: BackupFile, entries: EntrySource) {
        do {
            return try parseBackupFile(at: url, limits: limits, ownedFile: ownsFile ? url : nil)
        } catch {
            if ownsFile { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    nonisolated private static func parseBackupFile(
        at url: URL,
        limits: ImportLimits,
        ownedFile: URL?
    ) throws -> (backupFile: BackupFile, entries: EntrySource) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw BackupError.unrecognizedFormat }
        let handle = try FileHandle(forReadingFrom: url)
        // Enough to tell a zip from JSON, and to see past a long whitespace lead-in of an oversized JSON file.
        let head = try handle.read(upToCount: 64 * 1024) ?? Data()
        try? handle.close()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let date = ISO8601Parser.date(from: rawValue) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected date string to be ISO8601-formatted."
            )
        }

        if head.count >= 2, head[0] == 0x50, head[1] == 0x4B {
            let archive: Archive
            do {
                archive = try Archive(url: url, accessMode: .read)
            } catch {
                throw BackupError.zipExtractionFailed
            }
            do {
                try BoundedArchiveReader.validateDeclaredEntries(in: archive, budget: limits.archiveBudget)
            } catch is BoundedArchiveError {
                throw BackupError.resourceLimitExceeded
            }
            var reader = BoundedArchiveReader(budget: limits.archiveBudget)

            if let manifestEntry = archive[backupManifestFilename] {
                let manifestData = try boundedData(from: archive, entry: manifestEntry, reader: &reader)
                let manifest = try decoder.decode(BackupChunkManifest.self, from: manifestData)
                guard manifest.totalConversations >= 0,
                      manifest.totalConversations <= limits.maxConversations,
                      manifest.conversationChunks.count <= limits.maxEntries,
                      manifest.conversationChunks.allSatisfy({ $0.count >= 0 }) else {
                    throw BackupError.resourceLimitExceeded
                }

                guard let headerEntry = archive[manifest.headerFilename] else {
                    throw BackupError.jsonParseFailed
                }
                let headerData = try boundedData(from: archive, entry: headerEntry, reader: &reader)
                let headerBackupFile = try decoder.decode(BackupFile.self, from: headerData)

                var allConvs: [BackupConversation] = []
                var declaredConversationCount = 0
                for chunkDesc in manifest.conversationChunks {
                    let (nextCount, overflow) = declaredConversationCount.addingReportingOverflow(chunkDesc.count)
                    guard !overflow, nextCount <= manifest.totalConversations else {
                        throw BackupError.jsonParseFailed
                    }
                    declaredConversationCount = nextCount
                    guard let chunkEntry = archive[chunkDesc.filename] else {
                        throw BackupError.jsonParseFailed
                    }
                    let chunkData = try boundedData(from: archive, entry: chunkEntry, reader: &reader)
                    let chunk = try decoder.decode([BackupConversation].self, from: chunkData)
                    guard chunk.count == chunkDesc.count else {
                        throw BackupError.jsonParseFailed
                    }
                    allConvs.append(contentsOf: chunk)
                }
                guard declaredConversationCount == manifest.totalConversations,
                      allConvs.count == manifest.totalConversations else {
                    throw BackupError.jsonParseFailed
                }

                let fullData = BackupData(
                    providers: headerBackupFile.data.providers,
                    conversations: allConvs,
                    skills: headerBackupFile.data.skills,
                    preferences: headerBackupFile.data.preferences,
                    lastUsedModelRef: headerBackupFile.data.lastUsedModelRef,
                    folders: headerBackupFile.data.folders,
                    notes: headerBackupFile.data.notes,
                    noteFolders: headerBackupFile.data.noteFolders,
                    checkpoints: headerBackupFile.data.checkpoints,
                    memorySchemaVersion: headerBackupFile.data.memorySchemaVersion,
                    memoryItems: headerBackupFile.data.memoryItems
                )
                let fullBackupFile = BackupFile(
                    version: headerBackupFile.version,
                    createdAt: headerBackupFile.createdAt,
                    appVersion: headerBackupFile.appVersion,
                    platform: headerBackupFile.platform,
                    checksum: headerBackupFile.checksum,
                    containsKeys: headerBackupFile.containsKeys,
                    data: fullData,
                    attachmentChecksums: headerBackupFile.attachmentChecksums,
                    encryptedKeys: headerBackupFile.encryptedKeys
                )

                let entries = try assetEntries(in: archive, limits: limits, ownedFile: ownedFile)
                return (fullBackupFile, entries)
            }

            guard let dataEntry = archive["data.json"] else {
                throw BackupError.jsonParseFailed
            }
            let jsonData = try boundedData(from: archive, entry: dataEntry, reader: &reader)
            let backupFile = try decoder.decode(BackupFile.self, from: jsonData)

            let entries = try assetEntries(in: archive, limits: limits, ownedFile: ownedFile)
            return (backupFile, entries)

        } else if head.count >= 1, head[0] == 0x7B {
            // The whole file is one entry, so it is bounded by the entry limit.
            let data: Data
            do {
                data = try BoundedFileReader.data(at: url, maxBytes: limits.maxEntryBytes)
            } catch BoundedFileReadError.tooLarge {
                throw BackupError.resourceLimitExceeded
            } catch BoundedFileReadError.notRegularFile {
                throw BackupError.unrecognizedFormat
            }
            let backupFile = try decoder.decode(BackupFile.self, from: data)
            guard backupFile.data.conversations.count <= limits.maxConversations else {
                throw BackupError.resourceLimitExceeded
            }
            let entries = EntrySource(
                archive: nil, index: [:], digests: [:], limits: limits, jsonFile: url, ownedFile: ownedFile
            )
            return (backupFile, entries)

        } else {
            throw BackupError.unrecognizedFormat
        }
    }

    /// attachments/<name> entries keyed by `<name>`, the same key attachmentChecksums uses for them.
    /// Each entry is inflated once here, one at a time, so an entry whose real size is over the limit fails the
    /// preview whatever its header says, and its checksum is kept for the warning.
    nonisolated private static func assetEntries(
        in archive: Archive,
        limits: ImportLimits,
        ownedFile: URL?
    ) throws -> EntrySource {
        var index: [String: Entry] = [:]
        var digests: [String: String] = [:]
        for entry in archive where entry.type == .file {
            guard entry.path.hasPrefix("attachments/") else { continue }
            let key = String(entry.path.dropFirst("attachments/".count))
            guard !key.isEmpty else { continue }
            var reader = BoundedArchiveReader(budget: limits.archiveBudget)
            digests[key] = CanonicalJSON.checksum(of: try boundedData(from: archive, entry: entry, reader: &reader))
            index[key] = entry
        }
        return EntrySource(
            archive: archive, index: index, digests: digests, limits: limits, jsonFile: nil, ownedFile: ownedFile
        )
    }

    nonisolated private static func boundedData(
        from archive: Archive,
        entry: Entry,
        reader: inout BoundedArchiveReader
    ) throws -> Data {
        let data: Data
        do {
            data = try reader.data(from: archive, entry: entry)
        } catch is BoundedArchiveError {
            throw BackupError.resourceLimitExceeded
        }
        // The consumer-based extract returns the CRC-32 without checking it: an entry whose bytes do not match
        // its recorded CRC is a corrupt archive, rejected whole as an unrecognized format.
        guard data.crc32(checksum: 0) == entry.checksum else { throw BackupError.unrecognizedFormat }
        return data
    }


    nonisolated static func previewImport(
        backupFile: BackupFile,
        localConversations: [Conversation],
        localProviders: [Provider]
    ) -> ImportPreview {
        let localConvIDs = Set(localConversations.map(\.id))
        let localProviderIDs = Set(localProviders.map(\.id))

        let existingConvs = backupFile.data.conversations.filter { localConvIDs.contains($0.id) }.count
        let existingProvs = backupFile.data.providers.filter { localProviderIDs.contains($0.id) }.count

        let totalMessages = backupFile.data.conversations.reduce(0) { $0 + $1.messages.count }
        let totalImages = backupFile.data.conversations.reduce(0) { total, conv in
            total + conv.messages.reduce(0) { $0 + ($1.attachments?.filter { $0.kind == .image }.count ?? 0) }
        }

        return ImportPreview(
            backupCreatedAt: backupFile.createdAt,
            backupPlatform: backupFile.platform,
            backupAppVersion: backupFile.appVersion,
            containsKeys: backupFile.containsKeys,
            totalConversations: backupFile.data.conversations.count,
            existingConversations: existingConvs,
            totalProviders: backupFile.data.providers.count,
            existingProviders: existingProvs,
            totalMessages: totalMessages,
            totalImages: totalImages
        )
    }


    /// Verify the data checksum. First criterion: re-encode with this app's CanonicalJSON (sorted keys, nil omitted).
    /// The checksum exported by Android / Web is computed over their own serialization (explicit null, insertion-order keys), so re-encoding cannot match;
    /// when the first criterion fails and the raw file bytes are provided, the second criterion recomputes over the data bytes as they appear in the file (whitespace outside strings removed),
    /// matching Android `storedDataMatchesChecksum`. The sharded manifest format has no data.json and only uses the first criterion.
    nonisolated static func validateChecksum(_ backupFile: BackupFile, rawData: Data? = nil) -> Bool {
        if let dataJSON = try? CanonicalJSON.encode(backupFile.data),
           CanonicalJSON.checksum(of: dataJSON) == backupFile.checksum {
            return true
        }
        guard let rawData else { return false }
        return storedDataMatchesChecksum(rawData, expected: backupFile.checksum)
    }

    /// `validateChecksum(_:rawData:)` for a parsed file: the second criterion rereads data.json (or the plain JSON
    /// file) through the entry source instead of holding the file's bytes.
    nonisolated static func validateChecksum(_ backupFile: BackupFile, entries: EntrySource) -> Bool {
        if validateChecksum(backupFile) { return true }
        guard let json = entries.storedJSON() else { return false }
        return storedJSONMatchesChecksum(json, expected: backupFile.checksum)
    }

    /// Second criterion: take the raw bytes of the top-level `data` of the file (data.json inside the ZIP, or plain JSON), compact them, and compute SHA-256.
    nonisolated private static func storedDataMatchesChecksum(_ bytes: Data, expected: String) -> Bool {
        guard !expected.isEmpty else { return false }
        let jsonBytes: Data
        if bytes.count >= 2, bytes[bytes.startIndex] == 0x50, bytes[bytes.startIndex + 1] == 0x4B {
            guard let archive = Archive(data: bytes, accessMode: .read),
                  let entry = archive["data.json"] else { return false }
            var reader = BoundedArchiveReader(budget: ImportLimits.currentDevice.archiveBudget)
            guard let data = try? boundedData(from: archive, entry: entry, reader: &reader) else { return false }
            jsonBytes = data
        } else {
            jsonBytes = bytes
        }
        return storedJSONMatchesChecksum(jsonBytes, expected: expected)
    }

    nonisolated private static func storedJSONMatchesChecksum(_ jsonBytes: Data, expected: String) -> Bool {
        guard !expected.isEmpty,
              let raw = RawJSONScanner.topLevelValue(Array(jsonBytes), key: "data") else { return false }
        return CanonicalJSON.checksum(of: Data(RawJSONScanner.compact(raw))) == expected
    }

    /// Attachment checksums against a parsed file's entries, one entry at a time; a mismatch only warns.
    nonisolated static func validateAttachmentChecksums(
        expected: [String: String],
        entries: EntrySource
    ) -> [String] {
        entries.checksumMismatches(expected: expected)
    }

    nonisolated static func validateAttachmentChecksums(
        expected: [String: String],
        images: [String: Data]
    ) -> [String] {
        var corrupted: [String] = []
        for (filename, expectedHash) in expected {
            guard let data = images[filename] else {
                corrupted.append(filename)
                continue
            }
            let computed = CanonicalJSON.checksum(of: data)
            if computed != expectedHash {
                corrupted.append(filename)
            }
        }
        return corrupted
    }


    /// Dictionary entry point kept for callers holding the bytes in memory.
    static func executeImport(
        backupFile: BackupFile,
        images: [String: Data],
        mode: ImportMode,
        password: String?,
        appState: AppState
    ) async throws -> ImportResult {
        try await executeImport(
            backupFile: backupFile, entries: EntrySource(images: images), mode: mode, password: password,
            appState: appState
        )
    }

    /// Imports a parsed backup, reading each asset entry by name only when it is restored.
    static func executeImport(
        backupFile: BackupFile,
        entries images: EntrySource,
        mode: ImportMode,
        password: String?,
        appState: AppState
    ) async throws -> ImportResult {
        var result = ImportResult()
        let partitionUID = await MainActor.run { appState.sessionPartitionUID }

        var restoredKeys: [UUID: (apiKey: String, preview: String)] = [:]
        if backupFile.containsKeys, let encStr = backupFile.encryptedKeys, let password, !password.isEmpty {
            guard let encData = Data(base64Encoded: encStr) else {
                throw BackupError.invalidEncryptedData
            }
            let decrypted = try BackupCrypto.decrypt(encData, password: password)
            let payload = try JSONDecoder().decode(BackupKeysPayload.self, from: decrypted)
            for entry in payload.keys {
                restoredKeys[entry.providerID] = (entry.apiKey, entry.apiKeyPreview)
            }
        }

        switch mode {
        case .importNewOnly:
            result = await importNewOnly(
                backupFile: backupFile,
                images: images,
                restoredKeys: restoredKeys,
                partitionUID: partitionUID,
                appState: appState
            )
        case .merge:
            result = await importMerge(
                backupFile: backupFile,
                images: images,
                restoredKeys: restoredKeys,
                partitionUID: partitionUID,
                appState: appState
            )
        case .replaceAll:
            result = try await importReplaceAll(
                backupFile: backupFile,
                images: images,
                restoredKeys: restoredKeys,
                partitionUID: partitionUID,
                appState: appState
            )
        }


        if let prefs = backupFile.data.preferences {
            if let theme = ThemeOption(rawValue: prefs.theme) {
                await MainActor.run {
                    appState.preferences.theme = theme
                    appState.preferences.themeSetByUser = true
                }
                result.restoredPreferences = true
            }
            // darkPalette is overwritten by the backup the same way as theme: write it when present; an old backup without the field clears it to unset
            // darkPaletteCustom is overwritten together with darkPalette
            let restoredDarkPalette = prefs.darkPalette
            let restoredDarkPaletteCustom = prefs.darkPaletteCustom
            await MainActor.run {
                appState.preferences.darkPalette = restoredDarkPalette
                appState.preferences.darkPaletteCustom = restoredDarkPaletteCustom
            }
            result.restoredPreferences = true
            if AppLanguagePreferencePolicy.shouldApplySyncedLanguage(
                storedPreference: AppPreferencesStore.savedLanguage
            ), let language = LanguageOption(rawValue: prefs.language) {
                await MainActor.run { appState.preferences.language = language }
                result.restoredPreferences = true
            }
            if let memoryText = prefs.memoryText {
                await MainActor.run {
                    appState.preferences.memoryText = String(memoryText.prefix(2000))
                }
                result.restoredPreferences = true
            }
            if let antiForgetEnabled = prefs.memoryAntiForgetEnabled {
                await MainActor.run {
                    appState.preferences.memoryAntiForgetEnabled = antiForgetEnabled
                }
            }
            if let antiForgetText = prefs.memoryAntiForgetText {
                await MainActor.run {
                    appState.preferences.memoryAntiForgetText = String(antiForgetText.prefix(200))
                }
            }
            if let updatedAtStr = prefs.memoryUpdatedAt {
                let parsed = ISO8601Parser.date(from: updatedAtStr)
                await MainActor.run {
                    appState.preferences.memoryUpdatedAt = parsed
                }
            }
            if result.restoredPreferences {
                await MainActor.run {
                    AppPreferencesStore.save(appState.preferences)
                }
            }
        }

        // Memory items changed: right after the preferences restore, dual-write the legacy fields (memoryText is compiled from the items)
        if result.memoryItemsChanged > 0 {
            await MainActor.run {
                guard appState.sessionPartitionUID == partitionUID else { return }
                appState.memoryItemRepository()?.dualWriteLegacy()
            }
        }

        // Restore the last used model
        if let ref = backupFile.data.lastUsedModelRef {
            await MainActor.run { appState.lastUsedModelRef = ref }
            result.restoredLastUsedModel = true
        }

        await reconcileOfficialProvidersAfterImport(appState: appState)

        return result
    }

    @MainActor
    private static func reconcileOfficialProvidersAfterImport(appState: AppState) async {
        let officialIndexes = appState.providers.enumerated().compactMap { index, provider -> Int? in
            provider.kind == .relay ? nil : index
        }
        guard !officialIndexes.isEmpty else { return }

        // Each restored official provider fetches its own catalog (no request if the revision matches).
        await MetadataClient.shared.forceRefresh(
            providerKinds: Set(officialIndexes.map { appState.providers[$0].kind })
        )

        for index in officialIndexes {
            var provider = appState.providers[index]
            let resolvedCatalog = ProviderCatalogResolver.resolve(provider: provider)
            // Catalog unavailable (offline, etc.): keep the import as is rather than rebuilding or
            // pruning enabled models from a catalog that never loaded.
            guard !resolvedCatalog.catalogPending else { continue }
            let catalogModels = resolvedCatalog.catalog.map(\.model)
            let legacyCatalogModels = provider.catalogModels

            provider.catalogModels = []
            if !catalogModels.isEmpty {
                provider.models = ModelResolver.makeEnabledModels(
                    from: provider.models,
                    catalogModels: catalogModels,
                    providerKind: provider.kind,
                    legacyCatalogModels: legacyCatalogModels,
                    repairLegacyAutoEnabledAll: true
                )
            }
            provider = ModelResolver.synchronizeDefaultSelection(
                in: provider,
                preferredModelID: provider.defaultModel?.id
            )

            let postResolveCatalog = ProviderCatalogResolver.resolve(provider: provider)
            provider.models = ManualRetainedPruningPolicy.apply(
                provider: provider,
                resolvedCatalog: postResolveCatalog
            )
            ManualRetainedPruningPolicy.recordActivation(
                provider: provider,
                count: postResolveCatalog.enabledModels.filter(\.isManual).count
            )

            provider.cachedAvailableModelCount = ProviderCatalogResolver.resolve(provider: provider).availableModelCount
            appState.providers[index] = provider
        }
    }


    private static func importNewOnly(
        backupFile: BackupFile,
        images: EntrySource,
        restoredKeys: [UUID: (apiKey: String, preview: String)],
        partitionUID: String,
        appState: AppState
    ) async -> ImportResult {
        var result = ImportResult()
        var localConvIDs = Set(appState.conversations.map(\.id))
        let localProviderIDs = Set(appState.providers.map(\.id))
        let originalUserSkills = await MainActor.run { appState.skillManager.userSkills }
        var nextUserSkills = originalUserSkills
        var localSkillIDs = Set(nextUserSkills.map(\.id))

        for bp in backupFile.data.providers {
            if localProviderIDs.contains(bp.id) {
                result.skippedProviders += 1
                continue
            }
            var newProvider = bp.toProvider()
            if let keys = restoredKeys[bp.id] {
                newProvider.apiKey = keys.apiKey
                newProvider.apiKeyPreview = keys.preview
                newProvider.status = .issue("Connection has not been verified.")
                newProvider.lastCheckedAt = nil
                newProvider.lastError = "Connection has not been verified."
                result.restoredKeys += 1
            }
            newProvider.cachedAvailableModelCount = ProviderCatalogResolver.resolve(provider: newProvider).availableModelCount
            await MainActor.run {
                appState.providers.append(newProvider)
            }
            result.newProviders += 1
        }

        for bc in backupFile.data.conversations {
            if localConvIDs.contains(bc.id) {
                result.skippedConversations += 1
                continue
            }
            let conv = bc.toConversation()
            await restoreImages(for: conv, from: images, partitionUID: partitionUID, result: &result)
            await MainActor.run {
                appState.upsertConversationProjection(conv)
            }
            localConvIDs.insert(conv.id)
            result.newConversations += 1
        }
        await importCheckpointsAfterConversations(
            backupFile, partitionUID: partitionUID, appState: appState, drainPersistQueue: true
        )
        result.memoryItemsChanged = await importMemoryItems(
            backupFile, mode: .newOnly, partitionUID: partitionUID, appState: appState
        )

        if let backupFolders = backupFile.data.folders {
            let localFolderIDs = Set(appState.folders.map(\.id))
            for bf in backupFolders {
                if !localFolderIDs.contains(bf.id) {
                    await MainActor.run { appState.folders.append(bf.toFolder()) }
                }
            }
        }

        if backupFile.data.notes != nil || backupFile.data.noteFolders != nil {
            let importedNotes = (backupFile.data.notes ?? []).map { $0.toNote() }
            let importedNoteFolders = (backupFile.data.noteFolders ?? []).map { $0.toNoteFolder() }
            // The write runs on the notes' serial write chain (not on the main thread); wait for it to land and
            // for the mirror to reload before continuing.
            let notesImport = await MainActor.run {
                appState.noteManager.importNotes(importedNotes, folders: importedNoteFolders, mode: .importNewOnly)
            }
            await notesImport.value
        }

        for backupSkill in backupFile.data.skills ?? [] {
            if localSkillIDs.contains(backupSkill.id) {
                result.skippedSkills += 1
                continue
            }

            let restoredSkill = restoreSkillFromBackup(backupSkill)
            nextUserSkills.append(restoredSkill.skill)
            localSkillIDs.insert(restoredSkill.skill.id)
            result.newSkills += 1
            if restoredSkill.requiresKnowledgeReupload {
                result.skillsRequiringKnowledgeReupload += 1
            }
        }

        if nextUserSkills != originalUserSkills {
            await MainActor.run {
                appState.skillManager.replaceUserSkills(nextUserSkills)
            }
        }

        return result
    }


    /// Merge imported conversation metadata: take the side with the later updatedAt; instructions / contextCap follow title and come from the same side.
    static func applyMergeMetadata(
        from bc: BackupConversation,
        localUpdatedAt: Date,
        into updated: inout Conversation
    ) {
        guard bc.updatedAt > localUpdatedAt else { return }
        updated.title = bc.title
        updated.hasCustomTitle = bc.hasCustomTitle
        updated.previewText = bc.previewText
        updated.estimatedCost = bc.estimatedCost
        updated.folderID = bc.folderID
        // A backup without the instructions key leaves the local instructions untouched.
        if let instructions = bc.instructions {
            updated.instructions = ConversationInstructions.normalize(instructions)
        }
        updated.contextCap = bc.contextCap?.cap
    }

    private static func importMerge(
        backupFile: BackupFile,
        images: EntrySource,
        restoredKeys: [UUID: (apiKey: String, preview: String)],
        partitionUID: String,
        appState: AppState
    ) async -> ImportResult {
        var result = ImportResult()
        let originalUserSkills = await MainActor.run { appState.skillManager.userSkills }
        var nextUserSkills = originalUserSkills

        for bp in backupFile.data.providers {
            let matchIndex = appState.providers.firstIndex(where: { $0.id == bp.id })

            if let idx = matchIndex {
                await MainActor.run {
                    var existing = appState.providers[idx]
                    let existingModelIDs = Set(existing.models.map(\.id))
                    for model in bp.models where !existingModelIDs.contains(model.id) {
                        existing.models.append(model)
                    }
                    if bp.kind == .relay {
                        let existingCatalogIDs = Set(existing.catalogModels.map(\.id))
                        for model in bp.catalogModels where !existingCatalogIDs.contains(model.id) {
                            existing.catalogModels.append(model)
                        }
                    }
                    if let customName = bp.customName {
                        existing.customName = customName
                    }
                    if bp.kind == .relay {
                        existing.baseURLText = bp.baseURLText
                        existing.relayRequested = bp.relayRequested
                    }
                    if existing.apiKey.isEmpty, let keys = restoredKeys[bp.id] {
                        existing.apiKey = keys.apiKey
                        existing.apiKeyPreview = keys.preview
                        existing.status = .issue("Connection has not been verified.")
                        existing.lastCheckedAt = nil
                        existing.lastError = "Connection has not been verified."
                        result.restoredKeys += 1
                    }
                    existing.cachedAvailableModelCount = ProviderCatalogResolver.resolve(provider: existing).availableModelCount
                    appState.providers[idx] = existing
                }
                result.skippedProviders += 1
            } else {
                var newProvider = bp.toProvider()
                if let keys = restoredKeys[bp.id] {
                    newProvider.apiKey = keys.apiKey
                    newProvider.apiKeyPreview = keys.preview
                    newProvider.status = .issue("Connection has not been verified.")
                    newProvider.lastCheckedAt = nil
                    newProvider.lastError = "Connection has not been verified."
                    result.restoredKeys += 1
                }
                newProvider.cachedAvailableModelCount = ProviderCatalogResolver.resolve(provider: newProvider).availableModelCount
                await MainActor.run {
                    appState.providers.append(newProvider)
                }
                result.newProviders += 1
            }
        }

        for bc in backupFile.data.conversations {
            if let localIdx = appState.conversations.firstIndex(where: { $0.id == bc.id }) {
                let local = appState.conversations[localIdx]
                let localMessages = (try? appState.conversationRuntimeBridge.fetchConversationProjection(
                    id: bc.id,
                    uid: partitionUID
                ))?.messages ?? local.messages
                let merged = mergeMessages(local: localMessages, backup: bc.messages)
                let mergedUpdatedAt = max(local.updatedAt, bc.updatedAt)

                await restoreImages(for: bc.toConversation(), from: images, partitionUID: partitionUID, result: &result)

                await MainActor.run {
                    var updated = appState.conversations[localIdx]
                    updated.messages = merged
                    updated.updatedAt = mergedUpdatedAt
                    applyMergeMetadata(from: bc, localUpdatedAt: local.updatedAt, into: &updated)
                    appState.upsertConversationProjection(updated)
                }
                result.mergedConversations += 1
            } else {
                let conv = bc.toConversation()
                await restoreImages(for: conv, from: images, partitionUID: partitionUID, result: &result)
                await MainActor.run {
                    appState.upsertConversationProjection(conv)
                }
                result.newConversations += 1
            }
        }
        await importCheckpointsAfterConversations(
            backupFile, partitionUID: partitionUID, appState: appState, drainPersistQueue: true
        )
        result.memoryItemsChanged = await importMemoryItems(
            backupFile, mode: .merge, partitionUID: partitionUID, appState: appState
        )

        if let backupFolders = backupFile.data.folders {
            await MainActor.run {
                for bf in backupFolders {
                    if let localIdx = appState.folders.firstIndex(where: { $0.id == bf.id }) {
                        let local = appState.folders[localIdx]
                        if bf.updatedAt > local.updatedAt {
                            appState.folders[localIdx] = bf.toFolder()
                        }
                    } else {
                        appState.folders.append(bf.toFolder())
                    }
                }
            }
        }

        if backupFile.data.notes != nil || backupFile.data.noteFolders != nil {
            let importedNotes = (backupFile.data.notes ?? []).map { $0.toNote() }
            let importedNoteFolders = (backupFile.data.noteFolders ?? []).map { $0.toNoteFolder() }
            let notesImport = await MainActor.run {
                appState.noteManager.importNotes(importedNotes, folders: importedNoteFolders, mode: .merge)
            }
            await notesImport.value
        }

        for backupSkill in backupFile.data.skills ?? [] {
            if let localIndex = nextUserSkills.firstIndex(where: { $0.id == backupSkill.id }) {
                let localSkill = nextUserSkills[localIndex]
                if backupSkill.updatedAt >= localSkill.updatedAt {
                    let restoredSkill = restoreSkillFromBackup(backupSkill)
                    nextUserSkills[localIndex] = restoredSkill.skill
                    result.mergedSkills += 1
                    if restoredSkill.requiresKnowledgeReupload {
                        result.skillsRequiringKnowledgeReupload += 1
                    }
                } else {
                    result.skippedSkills += 1
                }
            } else {
                let restoredSkill = restoreSkillFromBackup(backupSkill)
                nextUserSkills.append(restoredSkill.skill)
                result.newSkills += 1
                if restoredSkill.requiresKnowledgeReupload {
                    result.skillsRequiringKnowledgeReupload += 1
                }
            }
        }

        if nextUserSkills != originalUserSkills {
            await MainActor.run {
                appState.skillManager.replaceUserSkills(nextUserSkills)
            }
        }

        return result
    }


    private static func importReplaceAll(
        backupFile: BackupFile,
        images: EntrySource,
        restoredKeys: [UUID: (apiKey: String, preview: String)],
        partitionUID: String,
        appState: AppState
    ) async throws -> ImportResult {
        var result = ImportResult()

        try await MainActor.run {
            try ensureSessionStillBound(appState, partitionUID: partitionUID)
        }

        var importedProviders: [Provider] = []
        importedProviders.reserveCapacity(backupFile.data.providers.count)
        for bp in backupFile.data.providers {
            var newProvider = bp.toProvider()
            if let keys = restoredKeys[bp.id] {
                newProvider.apiKey = keys.apiKey
                newProvider.apiKeyPreview = keys.preview
                newProvider.status = .issue("Connection has not been verified.")
                newProvider.lastCheckedAt = nil
                newProvider.lastError = "Connection has not been verified."
                result.restoredKeys += 1
            }
            importedProviders.append(newProvider)
            result.newProviders += 1
        }

        var importedConversations: [Conversation] = []
        importedConversations.reserveCapacity(backupFile.data.conversations.count)
        for bc in backupFile.data.conversations {
            let conv = bc.toConversation()
            importedConversations.append(conv)
            result.newConversations += 1
        }

        let importedFolders = backupFile.data.folders?.map { $0.toFolder() } ?? []
        let importedNotes = backupFile.data.notes?.map { $0.toNote() } ?? []
        let importedNoteFolders = backupFile.data.noteFolders?.map { $0.toNoteFolder() } ?? []
        var importedSkills: [Skill] = []
        importedSkills.reserveCapacity(backupFile.data.skills?.count ?? 0)
        for backupSkill in backupFile.data.skills ?? [] {
            let restoredSkill = restoreSkillFromBackup(backupSkill)
            importedSkills.append(restoredSkill.skill)
            result.newSkills += 1
            if restoredSkill.requiresKnowledgeReupload {
                result.skillsRequiringKnowledgeReupload += 1
            }
        }
        let stagedImagesDirectory = try await stageImportedImages(
            for: importedConversations,
            from: images,
            partitionUID: partitionUID,
            result: &result
        )
        let replacement = try await beginImageStoreReplacement(
            with: stagedImagesDirectory,
            partitionUID: partitionUID
        )

        // A conversation table write that returns normally is committed: if the session is switched
        // afterwards, the image directory already matches the restored conversations and is not rolled back.
        var conversationsCommitted = false
        do {
            #if DEBUG
            if let hook = await currentBeforeReplaceAllCommitHook() {
                try await hook()
            }
            #endif

            // Validates the partition first (a switched account throws sessionChangedDuringImport and
            // leaves memory untouched), then swaps memory for the restored content; the whole-table write
            // runs on the persist queue, never on the main thread. Failures throw and take the rollback path.
            try await appState.replaceConversationProjectionOrThrow(
                importedConversations,
                persistedUID: partitionUID
            )
            conversationsCommitted = true
            let notesImport = try await MainActor.run {
                try ensureSessionStillBound(appState, partitionUID: partitionUID)
                try commitReplaceAllProviders(
                    importedProviders,
                    partitionUID: partitionUID,
                    appState: appState
                )
                appState.folders = importedFolders
                let notesImport = appState.noteManager.importNotes(
                    importedNotes, folders: importedNoteFolders, mode: .replaceAll
                )
                appState.skillManager.replaceUserSkills(importedSkills)
                return notesImport
            }
            // Continue after the write lands, without the main thread waiting on the persist queue.
            try await MainActor.run { try ensureSessionStillBound(appState, partitionUID: partitionUID) }
            await appState.persistSessionNowOffMainThread(for: partitionUID)
            await notesImport.value
        } catch {
            if conversationsCommitted {
                // The conversations are committed and the session was rebound afterwards: the images match
                // the restored conversations in the old partition, so they are kept. Providers, folders,
                // notes and skills are not written: they live in the memory of the currently bound AppState,
                // and writing them would land on the rebound account.
                await finalizeImageStoreReplacement(replacement)
            } else {
                await rollbackImageStoreReplacement(replacement)
            }
            throw error
        }

        await finalizeImageStoreReplacement(replacement)
        // persistSessionNowOffMainThread above has already drained the conversation write queue, so the replaced conversations are persisted.
        await importCheckpointsAfterConversations(
            backupFile, partitionUID: partitionUID, appState: appState, drainPersistQueue: false
        )
        // Memory items: the backup lands as a whole, and items alive on this device but absent from the backup become tombstones
        result.memoryItemsChanged = await importMemoryItems(
            backupFile, mode: .replace, partitionUID: partitionUID, appState: appState
        )

        return result
    }

    // MARK: - Context checkpoints

    /// Export the whole checkpoint table; nil when there is no store or the table is empty (the section is not written).
    nonisolated static func backupCheckpoints(store: ContextCompactionStore?) throws -> [BackupContextCheckpoint]? {
        guard let store else { return nil }
        let rows = try store.listAll().map { BackupContextCheckpoint(from: $0) }
        return rows.isEmpty ? nil : rows
    }

    /// Only rows whose conversation exists after import are accepted, upserted by primary key; skipped when rows is nil (old backups). Returns the number of rows written.
    @discardableResult
    nonisolated static func importCheckpoints(
        _ rows: [BackupContextCheckpoint]?,
        store: ContextCompactionStore?
    ) throws -> Int {
        guard let rows, !rows.isEmpty, let store else { return 0 }
        return try store.importRecords(rows.compactMap { $0.toRecord() })
    }

    /// Shared by the three import modes: write checkpoints after the conversations are written. Persisting the conversation projection happens on a background serial queue,
    /// so drain it first when needed, otherwise checkpoints would be dropped because the conversation rows are not persisted yet. Failures are only logged and do not block the import.
    private static func importCheckpointsAfterConversations(
        _ backupFile: BackupFile,
        partitionUID: String,
        appState: AppState,
        drainPersistQueue: Bool
    ) async {
        guard let rows = backupFile.data.checkpoints, !rows.isEmpty else { return }
        if drainPersistQueue {
            await appState.persistSessionNowOffMainThread(for: partitionUID)
        }
        // The store instance is fixed here; the write runs in the background (the main thread never waits for the write lock).
        let store = ContextCompactionStore.forPartition(partitionUID)
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try importCheckpoints(rows, store: store)
            }.value
        } catch {
            print("[BackupService] import checkpoints failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Memory items

    /// Export section: the whole table (including tombstones) via `MemoryItems.backupSection`; nil when there is no store (the section is not written).
    nonisolated static func backupMemorySection(store: MemoryItemStore?) throws -> MemoryBackupSection? {
        guard let store else { return nil }
        return MemoryItems.backupSection(try store.all())
    }

    /// The memory part of a backup: carries the memoryItems section and the legacy preference fields (old backups without the section are migrated from them).
    nonisolated static func memoryBackupInput(_ data: BackupData) -> MemoryBackupInput {
        MemoryBackupInput(
            memoryItems: data.memoryItems,
            preferences: data.preferences.map { prefs in
                MemoryLegacyPrefs(
                    memoryText: prefs.memoryText,
                    antiForgetEnabled: prefs.memoryAntiForgetEnabled ?? false,
                    antiForgetText: prefs.memoryAntiForgetText,
                    memoryUpdatedAt: prefs.memoryUpdatedAt
                )
            }
        )
    }

    /// Shared by the three import modes: write memory items according to the mode and return the number of changes. If the session no longer belongs to the partition or the database write fails, it is only logged and the import is not blocked.
    private static func importMemoryItems(
        _ backupFile: BackupFile,
        mode: MemoryBackupImportMode,
        partitionUID: String,
        appState: AppState
    ) async -> Int {
        let repository: MemoryItemRepository? = await MainActor.run {
            guard appState.sessionPartitionUID == partitionUID else { return nil }
            return appState.memoryItemRepository()
        }
        guard let repository else { return 0 }
        do {
            // Reads and writes run in the background (the main thread never waits for the write lock); the main thread only sets the migrated flag and wakes sync.
            return try await repository.importBackup(memoryBackupInput(backupFile.data), mode: mode)
        } catch {
            print("[BackupService] import memory items failed: \(error.localizedDescription)")
            return 0
        }
    }

    @MainActor
    static func commitReplaceAllProviders(
        _ providers: [Provider],
        partitionUID: String,
        appState: AppState
    ) throws {
        try ensureSessionStillBound(appState, partitionUID: partitionUID)
        appState.providers = providers
    }


    static func mergeMessages(local: [ChatMessage], backup: [ChatMessage]) -> [ChatMessage] {
        func ensureCreatedAt(_ messages: [ChatMessage]) -> [ChatMessage] {
            messages.enumerated().map { i, msg in
                guard msg.createdAt == nil else { return msg }
                var fixed = msg
                fixed.createdAt = Date(timeIntervalSince1970: TimeInterval(i) * 0.001)
                return fixed
            }
        }

        return ChatMessage.mergeByIdAndCreatedAt(ensureCreatedAt(local), ensureCreatedAt(backup))
    }


    private static func attachmentEntryData(
        from images: EntrySource,
        attachment: Attachment,
        localImageID: String,
        suffix: String
    ) async -> Data? {
        var extensions = [fileExtension(for: attachment.mimeType)]
        if !extensions.contains("jpg") { extensions.append("jpg") }

        for name in ["\(attachment.id)", localImageID] {
            for ext in extensions {
                let key = "\(name)\(suffix).\(ext)"
                // The entry is inflated off the main actor, one at a time.
                if images.contains(key), let data = await images.load(key) { return data }
            }
        }
        return nil
    }

    private static func restoreImages(
        for conversation: Conversation,
        from images: EntrySource,
        partitionUID: String,
        result: inout ImportResult
    ) async {
        for msg in conversation.messages {
            guard let atts = msg.attachments else { continue }
            for att in atts where att.kind == .image {
                guard let lid = att.localImageID else { continue }

                if let imgData = await attachmentEntryData(from: images, attachment: att, localImageID: lid, suffix: "") {
                    await saveRestoredImage(imgData, localImageID: lid, thumbnail: false, partitionUID: partitionUID)
                    result.restoredImages += 1
                } else {
                    result.skippedImages += 1
                }

                if let thumbData = await attachmentEntryData(from: images, attachment: att, localImageID: lid, suffix: ".thumb") {
                    await saveRestoredImage(thumbData, localImageID: lid, thumbnail: true, partitionUID: partitionUID)
                }
            }
        }
    }


    /// Saves one restored image (or its thumbnail) off the caller's executor.
    @concurrent
    nonisolated private static func saveRestoredImage(
        _ data: Data,
        localImageID: String,
        thumbnail: Bool,
        partitionUID: String
    ) async {
        recordDiskStep("import.restore")
        if thumbnail {
            ImageStore.saveThumbnail(imageData: data, for: localImageID, partitionUID: partitionUID)
        } else {
            ImageStore.save(imageData: data, for: localImageID, partitionUID: partitionUID)
        }
    }

    private static func stageImportedImages(
        for conversations: [Conversation],
        from images: EntrySource,
        partitionUID: String,
        result: inout ImportResult
    ) async throws -> URL {
        let stagedDirectory = try await makeStagedImagesDirectory(partitionUID: partitionUID)

        do {
            for conversation in conversations {
                try await stageImages(
                    for: conversation,
                    from: images,
                    into: stagedDirectory,
                    result: &result
                )
            }
            return stagedDirectory
        } catch {
            await removeStagedImagesDirectory(stagedDirectory)
            throw error
        }
    }

    /// Creates the empty staging directory of a replace-all import off the caller's executor. The image counts
    /// stay with the main-actor caller; only the disk work moves.
    @concurrent
    nonisolated private static func makeStagedImagesDirectory(partitionUID: String) async throws -> URL {
        recordDiskStep("import.stageDir")
        let stagedDirectory = AppSessionStore.userDir(for: partitionUID)
            .appendingPathComponent("Images-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        return stagedDirectory
    }

    @concurrent
    nonisolated private static func removeStagedImagesDirectory(_ stagedDirectory: URL) async {
        try? FileManager.default.removeItem(at: stagedDirectory)
    }

    private static func stageImages(
        for conversation: Conversation,
        from images: EntrySource,
        into directory: URL,
        result: inout ImportResult
    ) async throws {
        for msg in conversation.messages {
            guard let atts = msg.attachments else { continue }
            for att in atts where att.kind == .image {
                guard let lid = att.localImageID else { continue }

                if let imgData = await attachmentEntryData(from: images, attachment: att, localImageID: lid, suffix: "") {
                    try await writeStagedImage(imgData, to: directory.appendingPathComponent("\(lid).img"))
                    result.restoredImages += 1
                } else {
                    result.skippedImages += 1
                }

                if let thumbData = await attachmentEntryData(from: images, attachment: att, localImageID: lid, suffix: ".thumb") {
                    try await writeStagedImage(thumbData, to: directory.appendingPathComponent("\(lid).thumb"))
                }
            }
        }
    }

    /// Writes one staged image file atomically off the caller's executor.
    @concurrent
    nonisolated private static func writeStagedImage(_ data: Data, to url: URL) async throws {
        recordDiskStep("import.stage")
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    private static func ensureSessionStillBound(_ appState: AppState, partitionUID: String) throws {
        guard appState.sessionPartitionUID == partitionUID else {
            throw BackupError.sessionChangedDuringImport
        }
    }

    /// Moves the live image directory aside and the staged one in, off the caller's executor.
    @concurrent
    nonisolated private static func beginImageStoreReplacement(
        with stagedDirectory: URL,
        partitionUID: String
    ) async throws -> ImageStoreReplacement {
        recordDiskStep("import.swap")
        let fileManager = FileManager.default
        let targetDirectory = AppSessionStore.imagesDir(for: partitionUID)
        let backupDirectory = AppSessionStore.userDir(for: partitionUID)
            .appendingPathComponent("Images-pre-replace-backup-\(UUID().uuidString)", isDirectory: true)
        var replacement = ImageStoreReplacement(targetDirectory: targetDirectory, backupDirectory: nil)

        if fileManager.fileExists(atPath: targetDirectory.path) {
            try fileManager.moveItem(at: targetDirectory, to: backupDirectory)
            replacement = ImageStoreReplacement(targetDirectory: targetDirectory, backupDirectory: backupDirectory)
        }

        do {
            try fileManager.moveItem(at: stagedDirectory, to: targetDirectory)
            ImageStore.clearAllCaches()
            return replacement
        } catch {
            if fileManager.fileExists(atPath: targetDirectory.path) {
                try? fileManager.removeItem(at: targetDirectory)
            }
            if let backupDirectory = replacement.backupDirectory,
               fileManager.fileExists(atPath: backupDirectory.path) {
                try? fileManager.moveItem(at: backupDirectory, to: targetDirectory)
            }
            if fileManager.fileExists(atPath: stagedDirectory.path) {
                try? fileManager.removeItem(at: stagedDirectory)
            }
            throw error
        }
    }

    @concurrent
    nonisolated private static func finalizeImageStoreReplacement(_ replacement: ImageStoreReplacement) async {
        recordDiskStep("import.finalize")
        if let backupDirectory = replacement.backupDirectory {
            try? FileManager.default.removeItem(at: backupDirectory)
        }
        ImageStore.clearAllCaches()
    }

    @concurrent
    nonisolated private static func rollbackImageStoreReplacement(_ replacement: ImageStoreReplacement) async {
        recordDiskStep("import.rollback")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: replacement.targetDirectory.path) {
            try? fileManager.removeItem(at: replacement.targetDirectory)
        }
        if let backupDirectory = replacement.backupDirectory,
           fileManager.fileExists(atPath: backupDirectory.path) {
            try? fileManager.moveItem(at: backupDirectory, to: replacement.targetDirectory)
        }
        ImageStore.clearAllCaches()
    }


    private static func fileExtension(for mimeType: String) -> String {
        let parts = mimeType.split(separator: "/")
        guard parts.count == 2 else { return "jpg" }
        let subtype = String(parts[1]).lowercased()
        switch subtype {
        case "png": return "png"
        case "gif": return "gif"
        case "webp": return "webp"
        case "heic", "heif": return "heic"
        default: return "jpg"
        }
    }

    private static func sanitizeSkillForBackup(_ skill: Skill) -> Skill {
        var sanitized = skill
        sanitized.knowledgeBase = sanitizeKnowledgeBaseForBackup(skill.knowledgeBase)
        return sanitized
    }

    private static func sanitizeKnowledgeBaseForBackup(_ knowledgeBase: SkillKnowledgeBase?) -> SkillKnowledgeBase? {
        guard let knowledgeBase else { return nil }

        return SkillKnowledgeBase(
            provider: knowledgeBase.provider,
            retrievalModel: knowledgeBase.retrievalModel,
            vectorStoreId: "",
            expiresAfterDays: knowledgeBase.expiresAfterDays,
            files: knowledgeBase.files.map { file in
                SkillKnowledgeBaseFile(
                    id: file.id,
                    name: file.name,
                    mimeType: file.mimeType,
                    sizeBytes: file.sizeBytes,
                    ingestionMode: file.ingestionMode,
                    extractedFrom: file.extractedFrom,
                    openAIFileId: nil,
                    status: .disabled,
                    errorCode: file.errorCode,
                    createdAt: file.createdAt,
                    updatedAt: file.updatedAt
                )
            },
            updatedAt: knowledgeBase.updatedAt
        )
    }

    private static func restoreSkillFromBackup(_ skill: Skill) -> (skill: Skill, requiresKnowledgeReupload: Bool) {
        let requiresKnowledgeReupload = !(skill.knowledgeBase?.files.isEmpty ?? true)
        var restored = skill
        restored.source = .user
        restored.knowledgeBase = nil
        return (restored, requiresKnowledgeReupload)
    }

    /// Generates the default backup filename.
    static func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Oriveo-Backup-\(formatter.string(from: Date())).oriveo"
    }
}


extension BackupProvider {
    func toProvider() -> Provider {
        let catalogForRestore: [AIModel]
        switch kind {
        case .relay:
            catalogForRestore = catalogModels
        default:
            catalogForRestore = []
        }

        return Provider(
            id: id,
            kind: kind,
            status: .issue(L10n.tr("Needs setup")),
            models: models,
            catalogModels: catalogForRestore,

            lastCheckedAt: nil,
            apiKey: "",
            apiKeyPreview: "",
            lastError: nil,
            baseURLText: baseURLText,
            customName: customName,
            relayRequested: relayRequested,
            relayKind: relayKind
        )
    }
}

/// A JSON byte scan that only locates: it takes the raw bytes of the value of a key in the top-level object, without decoding or reordering keys.
nonisolated enum RawJSONScanner {
    private static let quote: UInt8 = 0x22
    private static let backslash: UInt8 = 0x5C

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// The value bytes of `key` in the top-level object; nil when it is not an object, the key is missing, or the structure is incomplete.
    static func topLevelValue(_ bytes: [UInt8], key: String) -> ArraySlice<UInt8>? {
        var index = 0
        // Skip the UTF-8 BOM.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        index = skipWhitespace(bytes, index)
        guard index < bytes.count, bytes[index] == 0x7B else { return nil }
        index += 1
        let wanted = Array(key.utf8)
        while true {
            index = skipWhitespace(bytes, index)
            guard index < bytes.count else { return nil }
            if bytes[index] == 0x7D { return nil }
            guard bytes[index] == quote, let keyEnd = stringEnd(bytes, index) else { return nil }
            let keyBytes = bytes[(index + 1)..<(keyEnd - 1)]
            index = skipWhitespace(bytes, keyEnd)
            guard index < bytes.count, bytes[index] == 0x3A else { return nil }
            index = skipWhitespace(bytes, index + 1)
            guard let valueEnd = valueEnd(bytes, index) else { return nil }
            if keyBytes.elementsEqual(wanted) { return bytes[index..<valueEnd] }
            index = skipWhitespace(bytes, valueEnd)
            guard index < bytes.count else { return nil }
            if bytes[index] == 0x2C { index += 1; continue }
            return nil
        }
    }

    /// Strip whitespace outside strings: same shape as the Android / Web compact serialization, with string contents and key order preserved.
    static func compact(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var inString = false
        var escaped = false
        for byte in bytes {
            if inString {
                out.append(byte)
                if escaped { escaped = false } else if byte == backslash { escaped = true } else if byte == quote { inString = false }
            } else if byte == quote {
                inString = true
                out.append(byte)
            } else if !isWhitespace(byte) {
                out.append(byte)
            }
        }
        return out
    }

    private static func skipWhitespace(_ bytes: [UInt8], _ start: Int) -> Int {
        var index = start
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
        return index
    }

    /// `start` is at the opening quote; returns the index after the closing quote.
    private static func stringEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
        var index = start + 1
        while index < bytes.count {
            switch bytes[index] {
            case backslash: index += 2
            case quote: return index + 1
            default: index += 1
            }
        }
        return nil
    }

    /// The index after the end of a value: string, object / array (matched by brackets, skipping strings), literal / number.
    private static func valueEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case quote:
            return stringEnd(bytes, start)
        case 0x7B, 0x5B:
            var depth = 0
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case quote:
                    guard let end = stringEnd(bytes, index) else { return nil }
                    index = end
                    continue
                case 0x7B, 0x5B:
                    depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            return nil
        default:
            var index = start
            while index < bytes.count, !isWhitespace(bytes[index]),
                  bytes[index] != 0x2C, bytes[index] != 0x7D, bytes[index] != 0x5D {
                index += 1
            }
            return index > start ? index : nil
        }
    }
}
