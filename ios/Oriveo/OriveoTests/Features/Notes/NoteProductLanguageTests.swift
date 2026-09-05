import Foundation
import Testing
@testable import Oriveo

@Suite("Note product language")
struct NoteProductLanguageTests {
    @Test("note actions distinguish list pinning from AI conversation context")
    func noteActionsDistinguishListPinningFromConversationContext() throws {
        let notes = try NotesStrings.load()

        #expect(try notes.value("Pin", locale: "en") == "Pin to list")
        #expect(try notes.value("Unpin", locale: "en") == "Unpin from list")
        #expect(try notes.value("Pinned", locale: "en") == "Pinned to list")
        #expect(try notes.value("Notes used in this chat", locale: "en") == "Notes brought into this chat")
        #expect(try notes.value("Related notes", locale: "en") == "Notes you can bring into this chat")
        #expect(try notes.value("Attach", locale: "en") == "Bring in")
        #expect(try notes.value("Pin", locale: "zh-Hans") != "Pin to list")
        #expect(try notes.value("Unpin", locale: "zh-Hans") != "Unpin from list")
    }

    @Test("note update and cross-check labels use user task language")
    func noteUpdateAndCrosscheckUseTaskLanguage() throws {
        let notes = try NotesStrings.load()

        #expect(try notes.value("Replace Current Note", locale: "en") == "Update note with selection")
        #expect(try notes.value("Note replaced", locale: "en") == "Note updated")
        #expect(try notes.value("Cross-check", locale: "en") == "Cross-check with another model")
        #expect(try notes.value("Original snapshot", locale: "en") == "Saved source answer")
        #expect(try notes.value("Replace Current Note", locale: "zh-Hans") != "Update note with selection")
    }

    @Test("note entry and detail labels explain saved chat notes")
    func noteEntryAndDetailLabelsExplainSavedChatNotes() throws {
        let notes = try NotesStrings.load()

        #expect(try notes.value("Body", locale: "en") == "Saved note")
        #expect(try notes.value("Body", locale: "zh-Hans") != "Saved note")
        #expect(try notes.value("Body", locale: "zh-Hant") != "Saved note")
        #expect(try notes.value("Save strong answers with their source, then return to them later.", locale: "en") == "Save chat content as notes")
        #expect(try notes.value("In chat, save a strong answer or select a passage to send it here.", locale: "en") == "Save chat content as notes")
    }
}

private struct NotesStrings {
    let strings: [String: Any]

    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Features/Notes
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // Oriveo
            .appendingPathComponent("Oriveo/Notes.xcstrings")
        let data = try Data(contentsOf: root)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Self(strings: json?["strings"] as? [String: Any] ?? [:])
    }

    func value(_ key: String, locale: String) throws -> String {
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let localization = try #require(localizations[locale] as? [String: Any])
        let unit = try #require(localization["stringUnit"] as? [String: Any])
        return try #require(unit["value"] as? String)
    }
}
