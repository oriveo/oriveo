import Foundation
import Testing
import ZIPFoundation
@testable import Oriveo

@Suite("ArchiveExtractionSafety")
struct ArchiveExtractionSafetyTests {
    @Test("Reads Entry At Budget Boundary")
    func readsEntryAtBudgetBoundary() throws {
        let archive = try makeArchive([("entry.txt", Data(repeating: 0x61, count: 8))])
        let readable = try #require(Archive(data: archive, accessMode: .read))
        let entry = try #require(readable["entry.txt"])
        var reader = BoundedArchiveReader(
            budget: ArchiveExtractionBudget(maxEntryBytes: 8, maxTotalBytes: 8, maxEntries: 1)
        )

        #expect(try reader.string(from: readable, entry: entry) == "aaaaaaaa")
        #expect(reader.extractedBytes == 8)
        #expect(reader.extractedEntries == 1)
    }

    @Test("Rejects Oversized Entry And Total")
    func rejectsOversizedEntryAndTotal() throws {
        let archiveData = try makeArchive([
            ("a.bin", Data(repeating: 0, count: 8)),
            ("b.bin", Data(repeating: 0, count: 8)),
        ])
        let archive = try #require(Archive(data: archiveData, accessMode: .read))

        #expect(throws: BoundedArchiveError.self) {
            try BoundedArchiveReader.validateDeclaredEntries(
                in: archive,
                budget: ArchiveExtractionBudget(maxEntryBytes: 7, maxTotalBytes: 32, maxEntries: 2)
            )
        }
        #expect(throws: BoundedArchiveError.self) {
            try BoundedArchiveReader.validateDeclaredEntries(
                in: archive,
                budget: ArchiveExtractionBudget(maxEntryBytes: 8, maxTotalBytes: 15, maxEntries: 2)
            )
        }
    }

    @Test("Rejects Too Many Entries And Invalid UTF8")
    func rejectsTooManyEntriesAndInvalidUTF8() throws {
        let archiveData = try makeArchive([
            ("a.bin", Data([0xFF])),
            ("b.bin", Data([0x00])),
        ])
        let archive = try #require(Archive(data: archiveData, accessMode: .read))
        #expect(throws: BoundedArchiveError.self) {
            try BoundedArchiveReader.validateDeclaredEntries(
                in: archive,
                budget: ArchiveExtractionBudget(maxEntryBytes: 8, maxTotalBytes: 8, maxEntries: 1)
            )
        }

        let entry = try #require(archive["a.bin"])
        var reader = BoundedArchiveReader(
            budget: ArchiveExtractionBudget(maxEntryBytes: 8, maxTotalBytes: 8, maxEntries: 1)
        )
        #expect(throws: BoundedArchiveError.self) {
            _ = try reader.string(from: archive, entry: entry)
        }
    }

    private func makeArchive(_ entries: [(String, Data)]) throws -> Data {
        let archive = try #require(Archive(accessMode: .create))
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: UInt32(data.count),
                provider: { position, size in data[position..<(position + size)] }
            )
        }
        return try #require(archive.data)
    }
}
