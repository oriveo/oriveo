import Foundation
import ZIPFoundation

nonisolated enum BoundedArchiveError: Error, Equatable {
    case tooManyEntries
    case entryTooLarge(path: String)
    case archiveTooLarge
    case invalidUTF8(path: String)
}

nonisolated struct ArchiveExtractionBudget: Equatable, Sendable {
    let maxEntryBytes: Int
    let maxTotalBytes: Int
    let maxEntries: Int

    static func attachment(maxOutputBytes: Int) -> ArchiveExtractionBudget {
        ArchiveExtractionBudget(
            maxEntryBytes: max(8 * 1024 * 1024, maxOutputBytes * 32),
            maxTotalBytes: max(32 * 1024 * 1024, maxOutputBytes * 128),
            maxEntries: 4_096
        )
    }
}

nonisolated struct BoundedArchiveReader {
    let budget: ArchiveExtractionBudget
    private(set) var extractedBytes = 0
    private(set) var extractedEntries = 0

    static func validateDeclaredEntries(
        in archive: Archive,
        budget: ArchiveExtractionBudget
    ) throws {
        var entryCount = 0
        var total: UInt64 = 0
        let maxEntry = UInt64(budget.maxEntryBytes)
        let maxTotal = UInt64(budget.maxTotalBytes)

        for entry in archive {
            guard entryCount < budget.maxEntries else {
                throw BoundedArchiveError.tooManyEntries
            }
            entryCount += 1
            guard entry.uncompressedSize <= maxEntry else {
                throw BoundedArchiveError.entryTooLarge(path: entry.path)
            }
            let (next, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, next <= maxTotal else {
                throw BoundedArchiveError.archiveTooLarge
            }
            total = next
        }
    }

    mutating func data(from archive: Archive, entry: Entry) throws -> Data {
        guard extractedEntries < budget.maxEntries else {
            throw BoundedArchiveError.tooManyEntries
        }
        guard entry.uncompressedSize <= UInt64(budget.maxEntryBytes) else {
            throw BoundedArchiveError.entryTooLarge(path: entry.path)
        }
        guard extractedBytes <= budget.maxTotalBytes else {
            throw BoundedArchiveError.archiveTooLarge
        }

        var result = Data()
        if entry.uncompressedSize <= UInt64(Int.max) {
            result.reserveCapacity(min(Int(entry.uncompressedSize), budget.maxEntryBytes))
        }
        _ = try archive.extract(entry) { chunk in
            guard chunk.count <= budget.maxEntryBytes - result.count else {
                throw BoundedArchiveError.entryTooLarge(path: entry.path)
            }
            guard result.count <= budget.maxTotalBytes - extractedBytes else {
                throw BoundedArchiveError.archiveTooLarge
            }
            guard chunk.count <= budget.maxTotalBytes - extractedBytes - result.count else {
                throw BoundedArchiveError.archiveTooLarge
            }
            result.append(chunk)
        }
        extractedBytes += result.count
        extractedEntries += 1
        return result
    }

    mutating func string(from archive: Archive, entry: Entry) throws -> String {
        let data = try data(from: archive, entry: entry)
        guard let value = String(data: data, encoding: .utf8) else {
            throw BoundedArchiveError.invalidUTF8(path: entry.path)
        }
        return value
    }
}
