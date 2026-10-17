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

    @Test("controlled failure when the first 1024 bytes of an XML part after the BOM contain DOCTYPE (case-insensitive)")
    func rejectsDoctypeInXmlParts() throws {
        let declared = Data([0xEF, 0xBB, 0xBF]) + Data("<?xml version=\"1.0\"?>\n<!DOCTYPE r [<!ENTITY x \"y\">]><r>&x;</r>".utf8)
        let lowercase = Data("<?xml version=\"1.0\"?><!doctype r><r/>".utf8)
        let late = Data(("<r>" + String(repeating: " ", count: 1_100) + "<!DOCTYPE x></r>").utf8)
        let plain = Data("<?xml version=\"1.0\"?><r>ok</r>".utf8)
        let archiveData = try makeArchive([("a.xml", declared), ("b.xml", lowercase), ("c.xml", late), ("d.xml", plain)])
        let archive = try #require(Archive(data: archiveData, accessMode: .read))
        var reader = BoundedArchiveReader(budget: .attachment(maxOutputBytes: 1_024))

        for path in ["a.xml", "b.xml"] {
            let entry = try #require(archive[path])
            #expect(throws: BoundedArchiveError.doctypeDeclared(path: path)) {
                _ = try reader.xmlData(from: archive, entry: entry)
            }
        }
        #expect(try reader.xmlData(from: archive, entry: try #require(archive["c.xml"])) == late)
        #expect(try reader.xmlData(from: archive, entry: try #require(archive["d.xml"])) == plain)
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
