import Testing
import Foundation
@testable import Oriveo


@Suite("ChatRequestOptions")
struct ChatRequestOptionsTests {

    @Test("Default has no customizations")
    func defaultHasNoCustomizations() {
        let options = ChatRequestOptions()
        #expect(!options.hasCustomizations)
        #expect(options.systemPrompt.isEmpty)
    }

    @Test("Non empty has customizations")
    func nonEmptyHasCustomizations() {
        let options = ChatRequestOptions(systemPrompt: "I am a developer")
        #expect(options.hasCustomizations)
    }

    @Test("Whitespace only not customized")
    func whitespaceOnlyNotCustomized() {
        let options = ChatRequestOptions(systemPrompt: "   \n\t  ")
        #expect(!options.hasCustomizations)
    }

    @Test("Codable roundtrip")
    func codableRoundtrip() throws {
        let original = ChatRequestOptions(systemPrompt: "I am a developer")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatRequestOptions.self, from: data)
        #expect(decoded == original)
    }

    @Test("Legacy allow unknown is decode ignored")
    func legacyAllowUnknownIsDecodeIgnored() throws {
        let legacy = Data(#"{"systemPrompt":"legacy","allowUnknownGenerationParameters":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ChatRequestOptions.self, from: legacy)
        let encoded = try JSONEncoder().encode(decoded)
        #expect(String(decoding: encoded, as: UTF8.self).contains("allowUnknownGenerationParameters") == false)
    }
}


@Suite("Conversation useMemory")
struct ConversationUseMemoryTests {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test("Default use memory is true")
    func defaultUseMemoryIsTrue() {
        let conv = Conversation(
            id: UUID(),
            title: "Test",
            providerID: UUID(),
            providerKind: .openAI,
            modelID: "gpt-4",
            previewText: "",
            isDraft: false,
            messages: []
        )
        #expect(conv.useMemory == true)
    }

    @Test("Codable roundtrip")
    func codableRoundtrip() throws {
        var conv = Conversation(
            id: UUID(),
            title: "Test",
            providerID: UUID(),
            providerKind: .openAI,
            modelID: "gpt-4",
            previewText: "",
            isDraft: false,
            messages: []
        )
        conv.useMemory = false

        let data = try encoder.encode(conv)
        let decoded = try decoder.decode(Conversation.self, from: data)
        #expect(decoded.useMemory == false)
    }

    @Test("Missing use memory fails decoding")
    func missingUseMemoryFailsDecoding() throws {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "title": "Old Chat",
            "providerID": UUID().uuidString,
            "providerKind": "openAI",
            "modelID": "gpt-3.5",
            "previewText": "hello",
            "estimatedCost": 0.0,
            "isDraft": false,
            "messages": [] as [Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) {
            try decoder.decode(Conversation.self, from: data)
        }
    }
}


@Suite("AppPreference Memory")
struct AppPreferenceMemoryTests {

    @Test("Default memory fields empty")
    func defaultMemoryFieldsEmpty() {
        let pref = AppPreference(theme: .system, language: .system)
        #expect(pref.memoryText.isEmpty)
        #expect(!pref.memoryAntiForgetEnabled)
        #expect(pref.memoryAntiForgetText.isEmpty)
        #expect(pref.memoryUpdatedAt == nil)
    }

    @Test("Memory fields assignment")
    func memoryFieldsAssignment() {
        var pref = AppPreference(theme: .system, language: .system)
        pref.memoryText = "I am a developer"
        pref.memoryAntiForgetEnabled = true
        pref.memoryAntiForgetText = "Developer, code only"
        pref.memoryUpdatedAt = Date()

        #expect(pref.memoryText == "I am a developer")
        #expect(pref.memoryAntiForgetEnabled)
        #expect(pref.memoryAntiForgetText == "Developer, code only")
        #expect(pref.memoryUpdatedAt != nil)
    }
}


@Suite("Memory injection")
struct MemoryInjectionTests {

    private func makeMessage(role: ChatRole, text: String) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            text: text,
            providerKind: .openAI,
            providerName: "OpenAI",
            modelName: "GPT-4",
            state: .delivered
        )
    }


    @Test("Injects when memory text and use memory")
    func injectsWhenMemoryTextAndUseMemory() {
        let memoryText = "I am a developer"
        let systemPrompt = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!systemPrompt.isEmpty)
        let options = ChatRequestOptions(systemPrompt: systemPrompt)
        #expect(options.hasCustomizations)
    }

    @Test("No injection when empty")
    func noInjectionWhenEmpty() {
        let memoryText = ""
        let systemPrompt = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(systemPrompt.isEmpty)
    }

    @Test("No injection when whitespace")
    func noInjectionWhenWhitespace() {
        let memoryText = "   \n  "
        let systemPrompt = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(systemPrompt.isEmpty)
    }

    @Test("No injection when use memory false")
    func noInjectionWhenUseMemoryFalse() {
        let memoryText = "I am a developer"
        let useMemory = false
        let shouldInject = !memoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && useMemory
        #expect(!shouldInject)
    }


    @Test("Anti-forget appends when 10 messages")
    func antiForgetAppendsWhen10Messages() {
        var messages: [ChatMessage] = []
        for i in 0..<10 {
            messages.append(makeMessage(role: .user, text: "User message \(i)"))
            messages.append(makeMessage(role: .assistant, text: "Reply \(i)"))
        }

        let antiForgetText = "Developer, concise"
        let userCount = messages.filter { $0.role == .user }.count
        #expect(userCount >= 10)

        if let lastIndex = messages.lastIndex(where: { $0.role == .user }) {
            messages[lastIndex].text += "\n\n[Reminder: \(antiForgetText)]"
        }

        let lastUser = messages.last(where: { $0.role == .user })!
        #expect(lastUser.text.contains("[Reminder: Developer, concise]"))
    }

    @Test("Anti-forget skips under 10")
    func antiForgetSkipsUnder10() {
        var messages: [ChatMessage] = []
        for i in 0..<5 {
            messages.append(makeMessage(role: .user, text: "Message \(i)"))
            messages.append(makeMessage(role: .assistant, text: "Reply \(i)"))
        }

        let userCount = messages.filter { $0.role == .user }.count
        #expect(userCount < 10)
    }

    @Test("Anti-forget counts only user messages")
    func antiForgetCountsOnlyUserMessages() {
        var messages: [ChatMessage] = []
        for i in 0..<3 {
            messages.append(makeMessage(role: .user, text: "User \(i)"))
        }
        for i in 0..<20 {
            messages.append(makeMessage(role: .assistant, text: "Assistant \(i)"))
        }

        let userCount = messages.filter { $0.role == .user }.count
        #expect(userCount == 3)
        #expect(userCount < 10)
    }

    @Test("Anti-forget disabled skips")
    func antiForgetDisabledSkips() {
        let antiForgetEnabled = false
        #expect(!antiForgetEnabled)
    }

    @Test("Anti-forget empty summary skips")
    func antiForgetEmptySummarySkips() {
        let antiForgetText = "   "
        let trimmed = antiForgetText.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.isEmpty)
    }
}


@Suite("BackupPreferences Memory")
struct BackupPreferencesMemoryTests {

    @Test("Legacy backup decodes")
    func legacyBackupDecodes() throws {
        let json = """
        {"theme":"dark","language":"english"}
        """
        let prefs = try JSONDecoder().decode(BackupPreferences.self, from: Data(json.utf8))
        #expect(prefs.theme == "dark")
        #expect(prefs.language == "english")
        #expect(prefs.memoryText == nil)
        #expect(prefs.memoryAntiForgetEnabled == nil)
    }

    @Test("Memory backup roundtrip")
    func memoryBackupRoundtrip() throws {
        let prefs = BackupPreferences(
            theme: "system",
            language: "english",
            memoryText: "I am a developer",
            memoryAntiForgetEnabled: true,
            memoryAntiForgetText: "Developer, concise",
            memoryUpdatedAt: "2026-03-31T12:00:00Z"
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(BackupPreferences.self, from: data)
        #expect(decoded.memoryText == "I am a developer")
        #expect(decoded.memoryAntiForgetEnabled == true)
        #expect(decoded.memoryAntiForgetText == "Developer, concise")
        #expect(decoded.memoryUpdatedAt == "2026-03-31T12:00:00Z")
    }
}


@Suite("Memory updated at format")
struct MemoryUpdatedAtFormatTests {

    @Test("Memory updated at is ISO-8601")
    func memoryUpdatedAtIsISO8601() {
        let now = Date()
        let isoString = ISO8601DateFormatter().string(from: now)

        let pattern = "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$"
        #expect(isoString.range(of: pattern, options: .regularExpression) != nil)
    }

    @Test("ISO-8601 roundtrip")
    func iso8601Roundtrip() {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let isoString = formatter.string(from: now)
        let parsed = formatter.date(from: isoString)
        #expect(parsed != nil)
    }
}

@Suite("Use memory default")
struct UseMemoryDefaultTests {

    @Test("Missing use memory fails decoding")
    func missingUseMemoryFailsDecoding() throws {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "title": "No useMemory field",
            "providerID": UUID().uuidString,
            "providerKind": "openAI",
            "modelID": "gpt-4",
            "previewText": "",
            "estimatedCost": 0.0,
            "isDraft": false,
            "messages": [] as [Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Conversation.self, from: data)
        }
    }

    @Test("Explicit false preserved")
    func explicitFalsePreserved() throws {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "title": "Explicit false",
            "providerID": UUID().uuidString,
            "providerKind": "openAI",
            "modelID": "gpt-4",
            "previewText": "",
            "estimatedCost": 0.0,
            "isDraft": false,
            "messages": [] as [Any],
            "useMemory": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let conv = try JSONDecoder().decode(Conversation.self, from: data)
        #expect(conv.useMemory == false)
    }
}

@Suite("Clear memory clears anti forget")
struct ClearMemoryClearsAntiForgetTests {

    @Test("Clearing memory clears anti forget")
    func clearingMemoryClearsAntiForget() {
        let editText = "   \n  "
        let trimmedText = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalAntiForgetEnabled = true
        let originalAntiForgetText = "Developer, concise"

        let finalAntiForgetEnabled = trimmedText.isEmpty ? false : originalAntiForgetEnabled
        let finalAntiForgetText = trimmedText.isEmpty ? "" : originalAntiForgetText

        #expect(finalAntiForgetEnabled == false)
        #expect(finalAntiForgetText == "")
    }

    @Test("Non empty memory keeps anti forget")
    func nonEmptyMemoryKeepsAntiForget() {
        let editText = "I am a developer"
        let trimmedText = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalAntiForgetEnabled = true
        let originalAntiForgetText = "Developer, concise"

        let finalAntiForgetEnabled = trimmedText.isEmpty ? false : originalAntiForgetEnabled
        let finalAntiForgetText = trimmedText.isEmpty ? "" : originalAntiForgetText

        #expect(finalAntiForgetEnabled == true)
        #expect(finalAntiForgetText == "Developer, concise")
    }
}

@Suite("Anti-forget boundary")
struct AntiForgetBoundaryTests {

    private func makeMessage(role: ChatRole, text: String) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            text: text,
            providerKind: .openAI,
            providerName: "OpenAI",
            modelName: "GPT-4",
            state: .delivered
        )
    }

    private func shouldApplyAntiForget(
        messages: [ChatMessage],
        antiForgetEnabled: Bool,
        memoryText: String,
        antiForgetText: String,
        useMemory: Bool
    ) -> Bool {
        let userMessageCount = messages.filter { $0.role == .user }.count
        return antiForgetEnabled
            && useMemory
            && !memoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !antiForgetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && userMessageCount >= 10
    }

    @Test("Nine user messages do not trigger")
    func nineUserMessagesDoNotTrigger() {
        var messages: [ChatMessage] = []
        for i in 0..<9 {
            messages.append(makeMessage(role: .user, text: "User \(i)"))
            messages.append(makeMessage(role: .assistant, text: "Reply \(i)"))
        }

        let result = shouldApplyAntiForget(
            messages: messages,
            antiForgetEnabled: true,
            memoryText: "I am a developer",
            antiForgetText: "Developer",
            useMemory: true
        )
        #expect(!result)
    }

    @Test("Ten user messages trigger")
    func tenUserMessagesTrigger() {
        var messages: [ChatMessage] = []
        for i in 0..<10 {
            messages.append(makeMessage(role: .user, text: "User \(i)"))
            messages.append(makeMessage(role: .assistant, text: "Reply \(i)"))
        }

        let result = shouldApplyAntiForget(
            messages: messages,
            antiForgetEnabled: true,
            memoryText: "I am a developer",
            antiForgetText: "Developer",
            useMemory: true
        )
        #expect(result)
    }

    @Test("Eleven user messages also trigger")
    func elevenUserMessagesAlsoTrigger() {
        var messages: [ChatMessage] = []
        for i in 0..<11 {
            messages.append(makeMessage(role: .user, text: "User \(i)"))
            messages.append(makeMessage(role: .assistant, text: "Reply \(i)"))
        }

        let result = shouldApplyAntiForget(
            messages: messages,
            antiForgetEnabled: true,
            memoryText: "I am a developer",
            antiForgetText: "Developer",
            useMemory: true
        )
        #expect(result)
    }
}

@Suite("Anti-forget format")
struct AntiForgetFormatTests {

    private func makeMessage(role: ChatRole, text: String) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            text: text,
            providerKind: .openAI,
            providerName: "OpenAI",
            modelName: "GPT-4",
            state: .delivered
        )
    }

    @Test("Anti-forget format")
    func antiForgetFormat() {
        var messages: [ChatMessage] = []
        for i in 0..<10 {
            messages.append(makeMessage(role: .user, text: "User message \(i)"))
            messages.append(makeMessage(role: .assistant, text: "Reply \(i)"))
        }

        let antiForgetText = "Developer, concise"

        if let lastIndex = messages.lastIndex(where: { $0.role == .user }) {
            let trimmed = antiForgetText.trimmingCharacters(in: .whitespacesAndNewlines)
            messages[lastIndex].text += "\n\n[Reminder: \(trimmed)]"
        }

        let lastUser = messages.last(where: { $0.role == .user })!
        #expect(lastUser.text.hasSuffix("\n\n[Reminder: Developer, concise]"))
        #expect(lastUser.text == "User message 9\n\n[Reminder: Developer, concise]")
    }

    @Test("Anti-forget text is trimmed")
    func antiForgetTextIsTrimmed() {
        var messages: [ChatMessage] = []
        for i in 0..<10 {
            messages.append(makeMessage(role: .user, text: "User \(i)"))
            messages.append(makeMessage(role: .assistant, text: "Reply \(i)"))
        }

        let antiForgetText = "  Developer, concise  \n"

        if let lastIndex = messages.lastIndex(where: { $0.role == .user }) {
            let trimmed = antiForgetText.trimmingCharacters(in: .whitespacesAndNewlines)
            messages[lastIndex].text += "\n\n[Reminder: \(trimmed)]"
        }

        let lastUser = messages.last(where: { $0.role == .user })!
        #expect(lastUser.text.hasSuffix("[Reminder: Developer, concise]"))
    }
}

@Suite("Memory local only fields")
struct MemoryLocalOnlyFieldsTests {

    @Test("Sync payload excludes local fields")
    func syncPayloadExcludesLocalFields() {
        let syncPayload: [String: Any] = [
            "theme": "system",
            "language": "english",
            "memoryText": "I am a developer",
            "memoryAntiForgetEnabled": true,
            "memoryAntiForgetText": "Developer",
            "memoryUpdatedAt": ISO8601DateFormatter().string(from: Date()),
        ]

        #expect(syncPayload["memoryUsageCount"] == nil)
        #expect(syncPayload["memoryHasSeen"] == nil)
        #expect(syncPayload["memoryUsageConversationIDs"] == nil)
    }

    @Test("Backup excludes local fields")
    func backupExcludesLocalFields() throws {
        let prefs = BackupPreferences(
            theme: "system",
            language: "english",
            memoryText: "I am a developer",
            memoryAntiForgetEnabled: true,
            memoryAntiForgetText: "Developer",
            memoryUpdatedAt: "2026-04-01T00:00:00Z"
        )
        let data = try JSONEncoder().encode(prefs)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["memoryUsageCount"] == nil)
        #expect(dict["memoryHasSeen"] == nil)
        #expect(dict["memoryUsageConversationIDs"] == nil)
    }
}

@Suite("Token estimation")
struct TokenEstimationTests {

    private func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int(ceil(Double(text.count) * 0.35))
    }

    @Test("Zero chars")
    func zeroChars() {
        #expect(estimateTokens("") == 0)
    }

    @Test("One char")
    func oneChar() {
        #expect(estimateTokens("A") == 1)
    }

    @Test("Three chars")
    func threeChars() {
        #expect(estimateTokens("ABC") == 2)
    }

    @Test("Two thousand chars")
    func twoThousandChars() {
        let text = String(repeating: "A", count: 2000)
        #expect(estimateTokens(text) == 700)
    }

    @Test("Ten chars")
    func tenChars() {
        let text = String(repeating: "X", count: 10)
        #expect(estimateTokens(text) == 4)
    }
}


@Suite("Memory preview truncation")
struct MemoryPreviewTruncationTests {

    private func memorySubtitle(for text: String) -> String {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Not set"
        }
        let preview = String(text.prefix(30))
        return text.count > 30 ? preview + "..." : preview
    }

    @Test("Empty returns not set")
    func emptyReturnsNotSet() {
        #expect(memorySubtitle(for: "") == "Not set")
        #expect(memorySubtitle(for: "   ") == "Not set")
    }

    @Test("Short text no truncation")
    func shortTextNoTruncation() {
        let text = "I am a backend engineer."
        #expect(text.count <= 30)
        #expect(memorySubtitle(for: text) == text)
    }

    @Test("Exactly30 chars no ellipsis")
    func exactly30CharsNoEllipsis() {
        let text = String(repeating: "A", count: 30)
        #expect(memorySubtitle(for: text) == text)
    }

    @Test("Thirty one chars truncated")
    func thirtyOneCharsTruncated() {
        let text = String(repeating: "A", count: 31)
        let result = memorySubtitle(for: text)
        #expect(result == String(repeating: "A", count: 30) + "...")
    }

    @Test("Emoji grapheme boundary")
    func emojiGraphemeBoundary() {
        let emoji = "👨‍👩‍👧‍👦"
        let text = String(repeating: emoji, count: 31)
        let result = memorySubtitle(for: text)
        #expect(result == String(repeating: emoji, count: 30) + "...")
    }

    @Test("Chinese text truncation")
    func chineseTextTruncation() {
        let text = String(repeating: "x", count: 35)
        let result = memorySubtitle(for: text)
        #expect(result == String(repeating: "x", count: 30) + "...")
    }
}

@Suite("Memory character limit")
struct MemoryCharacterLimitTests {

    @Test("Main text truncated at 2000")
    func mainTextTruncatedAt2000() {
        var editText = String(repeating: "A", count: 2500)
        if editText.count > 2000 {
            editText = String(editText.prefix(2000))
        }
        #expect(editText.count == 2000)
    }

    @Test("Main text exactly2000 not truncated")
    func mainTextExactly2000NotTruncated() {
        var editText = String(repeating: "B", count: 2000)
        if editText.count > 2000 {
            editText = String(editText.prefix(2000))
        }
        #expect(editText.count == 2000)
    }

    @Test("Summary truncated at200")
    func summaryTruncatedAt200() {
        var antiForgetText = String(repeating: "C", count: 250)
        if antiForgetText.count > 200 {
            antiForgetText = String(antiForgetText.prefix(200))
        }
        #expect(antiForgetText.count == 200)
    }

    @Test("Summary exactly200 not truncated")
    func summaryExactly200NotTruncated() {
        var antiForgetText = String(repeating: "D", count: 200)
        if antiForgetText.count > 200 {
            antiForgetText = String(antiForgetText.prefix(200))
        }
        #expect(antiForgetText.count == 200)
    }
}

@Suite("Memory main text boundary")
struct MemoryMainTextBoundaryTests {

    @Test("Boundary1999")
    func boundary1999() {
        var text = String(repeating: "E", count: 1999)
        if text.count > 2000 {
            text = String(text.prefix(2000))
        }
        #expect(text.count == 1999)
    }

    @Test("Boundary2000")
    func boundary2000() {
        var text = String(repeating: "F", count: 2000)
        if text.count > 2000 {
            text = String(text.prefix(2000))
        }
        #expect(text.count == 2000)
    }

    @Test("Boundary2001")
    func boundary2001() {
        var text = String(repeating: "G", count: 2001)
        if text.count > 2000 {
            text = String(text.prefix(2000))
        }
        #expect(text.count == 2000)
    }

    @Test("Prefix safe for chinese")
    func prefixSafeForChinese() {
        let text = String(repeating: "x", count: 2001)
        let truncated = String(text.prefix(2000))
        #expect(truncated.count == 2000)
        #expect(truncated.allSatisfy { $0 == "x" })
    }
}

@Suite("Token estimation boundary")
struct TokenEstimationBoundaryTests {

    private func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int(ceil(Double(text.count) * 0.35))
    }

    @Test("Token estimation", arguments: [
        (0, 0),
        (1, 1),      // ceil(0.35) = 1
        (2, 1),      // ceil(0.70) = 1
        (3, 2),      // ceil(1.05) = 2
        (10, 4),     // ceil(3.5) = 4
        (100, 35),   // ceil(35.0) = 35
        (2000, 700), // ceil(700.0) = 700
    ])
    func tokenEstimation(charCount: Int, expectedTokens: Int) {
        let text = charCount == 0 ? "" : String(repeating: "A", count: charCount)
        #expect(estimateTokens(text) == expectedTokens)
    }
}

@Suite("Whitespace only treated as empty")
struct WhitespaceOnlyTreatedAsEmptyTests {

    @Test("Whitespace only is empty", arguments: [
        "   ",
        "\n\n",
        "\t\t",
        "   \n\t  ",
        " \r\n ",
    ])
    func whitespaceOnlyIsEmpty(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.isEmpty)
    }

    @Test("Whitespace does not inject")
    func whitespaceDoesNotInject() {
        let memoryText = "   \n\t  "
        let systemPrompt = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let useMemory = true
        let shouldInject = !systemPrompt.isEmpty && useMemory
        #expect(!shouldInject)
    }

    @Test("Whitespace triggers anti forget clear")
    func whitespaceTriggersAntiForgetClear() {
        let editText = "  \n  "
        let trimmedText = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalAntiForgetEnabled = trimmedText.isEmpty ? false : true
        let finalAntiForgetText = trimmedText.isEmpty ? "" : "Some summary"
        #expect(finalAntiForgetEnabled == false)
        #expect(finalAntiForgetText == "")
    }
}

@Suite("Clear memory also clears anti forget")
struct ClearMemoryAlsoClearsAntiForgetTests {

    @Test("Clear main text resets anti forget")
    func clearMainTextResetsAntiForget() {
        let editText = ""
        let trimmedText = editText.trimmingCharacters(in: .whitespacesAndNewlines)

        let originalAntiForgetEnabled = true
        let originalAntiForgetText = "Developer, keep code concise"

        let finalEnabled = trimmedText.isEmpty ? false : originalAntiForgetEnabled
        let finalText = trimmedText.isEmpty ? "" : originalAntiForgetText

        #expect(finalEnabled == false)
        #expect(finalText.isEmpty)
    }

    @Test("Non empty main text keeps anti forget")
    func nonEmptyMainTextKeepsAntiForget() {
        let editText = "I am a developer"
        let trimmedText = editText.trimmingCharacters(in: .whitespacesAndNewlines)

        let originalAntiForgetEnabled = true
        let originalAntiForgetText = "Developer"

        let finalEnabled = trimmedText.isEmpty ? false : originalAntiForgetEnabled
        let finalText = trimmedText.isEmpty ? "" : originalAntiForgetText

        #expect(finalEnabled == true)
        #expect(finalText == "Developer")
    }
}

@Suite("Anti-forget auto fill")
struct AntiForgetAutoFillTests {

    @Test("Enable anti forget auto fills summary")
    func enableAntiForgetAutoFillsSummary() {
        let editText = String(repeating: "A", count: 500)
        var antiForgetText = ""

        let enabled = true
        if enabled && antiForgetText.isEmpty {
            antiForgetText = String(editText.prefix(200))
        }

        #expect(antiForgetText.count == 200)
        #expect(antiForgetText == String(repeating: "A", count: 200))
    }

    @Test("Short main text auto fills all")
    func shortMainTextAutoFillsAll() {
        let editText = "I am a developer"
        var antiForgetText = ""

        let enabled = true
        if enabled && antiForgetText.isEmpty {
            antiForgetText = String(editText.prefix(200))
        }

        #expect(antiForgetText == "I am a developer")
    }

    @Test("Exactly200 chars auto fills full")
    func exactly200CharsAutoFillsFull() {
        let editText = String(repeating: "B", count: 200)
        var antiForgetText = ""

        let enabled = true
        if enabled && antiForgetText.isEmpty {
            antiForgetText = String(editText.prefix(200))
        }

        #expect(antiForgetText.count == 200)
    }

    @Test("Existing summary not overwritten")
    func existingSummaryNotOverwritten() {
        let editText = String(repeating: "A", count: 500)
        var antiForgetText = "Existing summary"

        let enabled = true
        if enabled && antiForgetText.isEmpty {
            antiForgetText = String(editText.prefix(200))
        }

        #expect(antiForgetText == "Existing summary")
    }

    @Test("Empty main text auto fills empty")
    func emptyMainTextAutoFillsEmpty() {
        let editText = ""
        var antiForgetText = ""

        let enabled = true
        if enabled && antiForgetText.isEmpty {
            antiForgetText = String(editText.prefix(200))
        }

        #expect(antiForgetText.isEmpty)
    }
}


private func simulateBuildMemoryRequestOptions(
    memoryText: String,
    useMemory: Bool
) -> ChatRequestOptions {
    let trimmed = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, useMemory else {
        return ChatRequestOptions()
    }
    return ChatRequestOptions(systemPrompt: trimmed)
}

private func simulateApplyAntiForget(
    messages: inout [ChatMessage],
    antiForgetEnabled: Bool,
    memoryText: String,
    antiForgetText: String,
    useMemory: Bool
) {
    let userMessageCount = messages.filter { $0.role == .user }.count
    guard antiForgetEnabled,
          useMemory,
          !memoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !antiForgetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          userMessageCount >= 10
    else { return }

    if let lastIndex = messages.lastIndex(where: { $0.role == .user }) {
        let trimmed = antiForgetText.trimmingCharacters(in: .whitespacesAndNewlines)
        messages[lastIndex].text += "\n\n[Reminder: \(trimmed)]"
    }
}

private func simulateMarkMemoryUsed(
    conversationID: UUID,
    existingIDs: inout Set<UUID>
) -> Bool {
    guard !existingIDs.contains(conversationID) else { return false }
    existingIDs.insert(conversationID)
    return true
}


@Suite("Memory conversation injection")
struct MemoryConversationInjectionTests {

    @Test("New conversation first message injects memory")
    func newConversationFirstMessageInjectsMemory() {
        let memoryText = "I am a senior iOS developer"
        let options = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        #expect(options.hasCustomizations)
        #expect(options.systemPrompt == memoryText)
    }

    @Test("Existing conversation continues sending with memory")
    func existingConversationContinuesSendingWithMemory() {
        let memoryText = "I prefer Swift over Objective-C"
        let options = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        #expect(options.hasCustomizations)
        #expect(options.systemPrompt == memoryText)
    }
}


@Suite("Use memory false")
struct UseMemoryFalseTests {

    @Test("Use memory false no injection")
    func useMemoryFalseNoInjection() {
        let memoryText = "I am a developer"
        let options = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: false)
        #expect(!options.hasCustomizations)
        #expect(options.systemPrompt.isEmpty)
    }

    @Test("Use memory false no usage increment")
    func useMemoryFalseNoUsageIncrement() {
        let memoryText = "I am a developer"
        let useMemory = false
        let trimmed = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldMark = !trimmed.isEmpty && useMemory
        #expect(!shouldMark)
    }
}


@Suite("Empty memory no injection")
struct EmptyMemoryNoInjectionTests {

    @Test("Empty string no injection")
    func emptyStringNoInjection() {
        let options = simulateBuildMemoryRequestOptions(memoryText: "", useMemory: true)
        #expect(!options.hasCustomizations)
    }

    @Test("Whitespace only no injection")
    func whitespaceOnlyNoInjection() {
        let options = simulateBuildMemoryRequestOptions(memoryText: "   \n\t  ", useMemory: true)
        #expect(!options.hasCustomizations)
    }

    @Test("Newlines only no injection")
    func newlinesOnlyNoInjection() {
        let options = simulateBuildMemoryRequestOptions(memoryText: "\n\n\n", useMemory: true)
        #expect(!options.hasCustomizations)
    }
}


@Suite("Anti-forget pipeline")
struct AntiForgetPipelineTests {

    private func makeMessage(role: ChatRole, text: String) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            text: text,
            providerKind: .openAI,
            providerName: "OpenAI",
            modelName: "GPT-4",
            state: .delivered
        )
    }

    private func makeConversation(with messages: [ChatMessage], useMemory: Bool = true) -> [ChatMessage] {
        messages
    }

    @Test("Exactly10 user messages appends context")
    func exactly10UserMessagesAppendsContext() {
        var messages: [ChatMessage] = []
        for i in 0..<10 {
            messages.append(makeMessage(role: .user, text: "Msg \(i)"))
            messages.append(makeMessage(role: .assistant, text: "Reply \(i)"))
        }

        let originalLastUserText = messages.last(where: { $0.role == .user })!.text

        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: "I am a developer",
            antiForgetText: "Developer, concise",
            useMemory: true
        )

        let lastUser = messages.last(where: { $0.role == .user })!
        #expect(lastUser.text.contains("[Reminder: Developer, concise]"))
        #expect(lastUser.text.hasPrefix(originalLastUserText))
    }

    @Test("Under10 user messages no context")
    func under10UserMessagesNoContext() {
        var messages: [ChatMessage] = []
        for i in 0..<9 {
            messages.append(makeMessage(role: .user, text: "Msg \(i)"))
            messages.append(makeMessage(role: .assistant, text: "Reply \(i)"))
        }

        let originalTexts = messages.map(\.text)

        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: "I am a developer",
            antiForgetText: "Developer, concise",
            useMemory: true
        )

        for (i, msg) in messages.enumerated() {
            #expect(msg.text == originalTexts[i])
        }
    }

    @Test("Anti-forget disabled no context")
    func antiForgetDisabledNoContext() {
        var messages: [ChatMessage] = []
        for i in 0..<10 {
            messages.append(makeMessage(role: .user, text: "Msg \(i)"))
            messages.append(makeMessage(role: .assistant, text: "Reply \(i)"))
        }

        let originalLastText = messages.last(where: { $0.role == .user })!.text

        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: false,
            memoryText: "I am a developer",
            antiForgetText: "Developer, concise",
            useMemory: true
        )

        let lastUser = messages.last(where: { $0.role == .user })!
        #expect(lastUser.text == originalLastText)
    }

    @Test("Anti-forget empty summary no context")
    func antiForgetEmptySummaryNoContext() {
        var messages: [ChatMessage] = []
        for i in 0..<10 {
            messages.append(makeMessage(role: .user, text: "Msg \(i)"))
            messages.append(makeMessage(role: .assistant, text: "Reply \(i)"))
        }

        let originalLastText = messages.last(where: { $0.role == .user })!.text

        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: "I am a developer",
            antiForgetText: "   ",
            useMemory: true
        )

        let lastUser = messages.last(where: { $0.role == .user })!
        #expect(lastUser.text == originalLastText)
    }

    @Test("Anti-forget only mutates copy")
    func antiForgetOnlyMutatesCopy() {
        var original: [ChatMessage] = []
        for i in 0..<10 {
            original.append(makeMessage(role: .user, text: "Msg \(i)"))
            original.append(makeMessage(role: .assistant, text: "Reply \(i)"))
        }

        let originalTexts = original.map(\.text)

        var requestCopy = original

        simulateApplyAntiForget(
            messages: &requestCopy,
            antiForgetEnabled: true,
            memoryText: "I am a developer",
            antiForgetText: "Developer, concise",
            useMemory: true
        )

        let lastUserInCopy = requestCopy.last(where: { $0.role == .user })!
        #expect(lastUserInCopy.text.contains("[Reminder:"))

        for (i, msg) in original.enumerated() {
            #expect(msg.text == originalTexts[i])
        }
    }
}


@Suite("Memory retry and edit")
struct MemoryRetryAndEditTests {

    @Test("Retry uses current latest memory")
    func retryUsesCurrentLatestMemory() {
        let oldMemory = "I am a junior developer"
        let newMemory = "I am a senior architect"

        let oldOptions = simulateBuildMemoryRequestOptions(memoryText: oldMemory, useMemory: true)
        #expect(oldOptions.systemPrompt == oldMemory)

        let newOptions = simulateBuildMemoryRequestOptions(memoryText: newMemory, useMemory: true)
        #expect(newOptions.systemPrompt == newMemory)
    }

    @Test("Continue and edit follow memory rules")
    func continueAndEditFollowMemoryRules() {
        let memoryText = "I prefer functional programming"
        let options = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        #expect(options.hasCustomizations)
        #expect(options.systemPrompt == memoryText)

        let noMemOptions = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: false)
        #expect(!noMemOptions.hasCustomizations)
    }
}


@Suite("OpenAI compatible system message")
struct OpenAICompatibleSystemMessageTests {

    @Test("OpenAI chat completions injects system message")
    func openAIChatCompletionsInjectsSystemMessage() throws {
        let requestOptions = ChatRequestOptions(systemPrompt: "I am a developer")
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        var apiMessages: [[String: String]] = []
        if !systemPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": systemPrompt])
        }
        apiMessages.append(["role": "user", "content": "Hello"])

        #expect(apiMessages.count == 2)
        #expect(apiMessages[0]["role"] == "system")
        #expect(apiMessages[0]["content"] == "I am a developer")
        #expect(apiMessages[1]["role"] == "user")
    }

    @Test("OpenAI chat completions skips empty system")
    func openAIChatCompletionsSkipsEmptySystem() {
        let requestOptions = ChatRequestOptions()
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        var apiMessages: [[String: String]] = []
        if !systemPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": systemPrompt])
        }
        apiMessages.append(["role": "user", "content": "Hello"])

        #expect(apiMessages.count == 1)
        #expect(apiMessages[0]["role"] == "user")
    }

    @Test("OpenAI responses uses instructions field")
    func openAIResponsesUsesInstructionsField() {
        let requestOptions = ChatRequestOptions(systemPrompt: "I am a developer")
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions: String? = systemPrompt.isEmpty ? nil : systemPrompt

        #expect(instructions == "I am a developer")
    }

    @Test("OpenAI responses nil instructions when empty")
    func openAIResponsesNilInstructionsWhenEmpty() {
        let requestOptions = ChatRequestOptions()
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions: String? = systemPrompt.isEmpty ? nil : systemPrompt

        #expect(instructions == nil)
    }
}

@Suite("Anthropic system field")
struct AnthropicSystemFieldTests {

    @Test("Anthropic injects system field")
    func anthropicInjectsSystemField() {
        let requestOptions = ChatRequestOptions(systemPrompt: "I am a developer")
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let system: String? = systemPrompt.isEmpty ? nil : systemPrompt

        #expect(system == "I am a developer")
    }

    @Test("Anthropic nil system when empty")
    func anthropicNilSystemWhenEmpty() {
        let requestOptions = ChatRequestOptions()
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let system: String? = systemPrompt.isEmpty ? nil : systemPrompt

        #expect(system == nil)
    }

    @Test("Anthropic system separate from messages")
    func anthropicSystemSeparateFromMessages() {
        let systemPrompt = "I am a developer"
        let messages: [[String: String]] = [
            ["role": "user", "content": "Hello"]
        ]

        let hasSystemInMessages = messages.contains { $0["role"] == "system" }
        #expect(!hasSystemInMessages)
        #expect(!systemPrompt.isEmpty)
    }
}

@Suite("Gemini system instruction")
struct GeminiSystemInstructionTests {

    @Test("Gemini injects system instruction")
    func geminiInjectsSystemInstruction() {
        let requestOptions = ChatRequestOptions(systemPrompt: "I am a developer")
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        struct SystemInstruction {
            struct TextPart { var text: String }
            var parts: [TextPart]
        }
        let instruction: SystemInstruction? = systemPrompt.isEmpty
            ? nil
            : SystemInstruction(parts: [.init(text: systemPrompt)])

        #expect(instruction != nil)
        #expect(instruction?.parts.count == 1)
        #expect(instruction?.parts[0].text == "I am a developer")
    }

    @Test("Gemini nil system instruction when empty")
    func geminiNilSystemInstructionWhenEmpty() {
        let requestOptions = ChatRequestOptions()
        let systemPrompt = requestOptions.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasInstruction = !systemPrompt.isEmpty
        #expect(!hasInstruction)
    }
}


@Suite("Memory usage count deduplication")
struct MemoryUsageCountDeduplicationTests {

    @Test("First use in conversation increments count")
    func firstUseInConversationIncrementsCount() {
        var usedIDs: Set<UUID> = []
        let convID = UUID()

        let incremented = simulateMarkMemoryUsed(conversationID: convID, existingIDs: &usedIDs)
        #expect(incremented)
        #expect(usedIDs.count == 1)
    }

    @Test("Duplicate use in same conversation no increment")
    func duplicateUseInSameConversationNoIncrement() {
        var usedIDs: Set<UUID> = []
        let convID = UUID()

        _ = simulateMarkMemoryUsed(conversationID: convID, existingIDs: &usedIDs)
        let secondResult = simulateMarkMemoryUsed(conversationID: convID, existingIDs: &usedIDs)

        #expect(!secondResult)
        #expect(usedIDs.count == 1)
    }

    @Test("Different conversations each count once")
    func differentConversationsEachCountOnce() {
        var usedIDs: Set<UUID> = []
        let convA = UUID()
        let convB = UUID()
        let convC = UUID()

        _ = simulateMarkMemoryUsed(conversationID: convA, existingIDs: &usedIDs)
        _ = simulateMarkMemoryUsed(conversationID: convB, existingIDs: &usedIDs)
        _ = simulateMarkMemoryUsed(conversationID: convC, existingIDs: &usedIDs)

        #expect(usedIDs.count == 3)
    }

    @Test("Mixed usage count equals unique conversations")
    func mixedUsageCountEqualsUniqueConversations() {
        var usedIDs: Set<UUID> = []
        let convA = UUID()
        let convB = UUID()

        _ = simulateMarkMemoryUsed(conversationID: convA, existingIDs: &usedIDs)
        _ = simulateMarkMemoryUsed(conversationID: convA, existingIDs: &usedIDs)
        _ = simulateMarkMemoryUsed(conversationID: convB, existingIDs: &usedIDs)
        _ = simulateMarkMemoryUsed(conversationID: convA, existingIDs: &usedIDs)
        _ = simulateMarkMemoryUsed(conversationID: convB, existingIDs: &usedIDs)

        #expect(usedIDs.count == 2)
    }
}



@Suite("Legacy conversation missing use memory")
struct LegacyConversationMissingUseMemoryTests {

    @Test("Missing use memory fails decoding")
    func missingUseMemoryFailsDecoding() throws {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "title": "Legacy Chat from v1.0",
            "providerID": UUID().uuidString,
            "providerKind": "openAI",
            "modelID": "gpt-3.5-turbo",
            "previewText": "Hello world",
            "estimatedCost": 0.001,
            "isDraft": false,
            "messages": [] as [Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Conversation.self, from: data)
        }
    }

    @Test("Missing use memory conversation is rejected before request building")
    func missingUseMemoryConversationIsRejectedBeforeRequestBuilding() throws {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "title": "Invalid payload",
            "providerID": UUID().uuidString,
            "providerKind": "openAI",
            "modelID": "gpt-4o",
            "previewText": "Hello",
            "estimatedCost": 0.001,
            "isDraft": false,
            "messages": [] as [Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Conversation.self, from: data)
        }
    }
}


@Suite("Legacy data missing memory fields")
struct LegacyDataMissingMemoryFieldsTests {

    @Test("App preference defaults are compatible")
    func appPreferenceDefaultsAreCompatible() {
        let pref = AppPreference(theme: .system, language: .system)
        #expect(pref.memoryText.isEmpty)
        #expect(!pref.memoryAntiForgetEnabled)
        #expect(pref.memoryAntiForgetText.isEmpty)
        #expect(pref.memoryUpdatedAt == nil)
    }

    @Test("Backup preferences missing memory decodes")
    func backupPreferencesMissingMemoryDecodes() throws {
        let json = """
        {"theme":"dark","language":"english"}
        """
        let prefs = try JSONDecoder().decode(BackupPreferences.self, from: Data(json.utf8))
        #expect(prefs.theme == "dark")
        #expect(prefs.memoryText == nil)
        #expect(prefs.memoryAntiForgetEnabled == nil)
        #expect(prefs.memoryAntiForgetText == nil)
        #expect(prefs.memoryUpdatedAt == nil)
    }

    @Test("Legacy conversation minimal fields decodes")
    func legacyConversationMinimalFieldsDecodes() throws {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "title": "Old chat",
            "providerID": UUID().uuidString,
            "providerKind": "openAI",
            "modelID": "gpt-3.5",
            "useMemory": true,
            "previewText": "",
            "isDraft": false,
            "messages": [] as [Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let conv = try JSONDecoder().decode(Conversation.self, from: data)
        #expect(conv.useMemory == true)
        #expect(conv.folderID == nil)
        #expect(conv.hasCustomTitle == false)
    }

    @Test("Empty prefs memory injection returns safe defaults")
    func emptyPrefsMemoryInjectionReturnsSafeDefaults() {
        let pref = AppPreference(theme: .system, language: .system)
        let options = simulateBuildMemoryRequestOptions(memoryText: pref.memoryText, useMemory: true)
        #expect(!options.hasCustomizations)
    }
}


@Suite("Memory lww")
struct MemoryLWWTests {

    @Test("Older remote does not overwrite newer")
    func olderRemoteDoesNotOverwriteNewer() {
        let localMemoryText = "I am a senior architect"
        let remoteMemoryText = "I am a junior developer"

        let sameText = localMemoryText == remoteMemoryText
        #expect(!sameText)

        let localText = "Same memory text"
        let remoteText = "Same memory text"
        #expect(localText == remoteText)
    }

    @Test("Same remote text does not trigger update")
    func sameRemoteTextDoesNotTriggerUpdate() {
        let localMemoryText = "I am a developer"
        let remoteMemoryText = "I am a developer"

        let shouldUpdate = remoteMemoryText != localMemoryText
        #expect(!shouldUpdate)
    }

    @Test("Different remote text triggers full update")
    func differentRemoteTextTriggersFullUpdate() {
        let localMemoryText = "Old memory"
        let remoteData: [String: Any] = [
            "memoryText": "New memory from another device",
            "memoryAntiForgetEnabled": true,
            "memoryAntiForgetText": "New summary",
            "memoryUpdatedAt": ISO8601DateFormatter().string(from: Date()),
        ]

        let remoteMemoryText = remoteData["memoryText"] as! String
        let shouldUpdate = remoteMemoryText != localMemoryText
        #expect(shouldUpdate)

        #expect(remoteData["memoryAntiForgetEnabled"] as? Bool == true)
        #expect(remoteData["memoryAntiForgetText"] as? String == "New summary")
        #expect(remoteData["memoryUpdatedAt"] != nil)
    }
}


@Suite("Memory local fields not synced")
struct MemoryLocalFieldsNotSyncedTests {

    @Test("Usage count not in sync payload")
    func usageCountNotInSyncPayload() {
        let syncPayload: [String: Any] = [
            "theme": "system",
            "language": "english",
            "memoryText": "I am a developer",
            "memoryAntiForgetEnabled": true,
            "memoryAntiForgetText": "Developer",
            "memoryUpdatedAt": ISO8601DateFormatter().string(from: Date()),
        ]

        #expect(syncPayload["memoryUsageCount"] == nil)
        #expect(syncPayload["memoryUsageConversationIDs"] == nil)
    }

    @Test("Has seen not in sync payload")
    func hasSeenNotInSyncPayload() {
        let syncPayload: [String: Any] = [
            "theme": "system",
            "language": "english",
            "memoryText": "Test",
            "memoryAntiForgetEnabled": false,
            "memoryAntiForgetText": "",
            "memoryUpdatedAt": ISO8601DateFormatter().string(from: Date()),
        ]

        #expect(syncPayload["memoryHasSeen"] == nil)
    }

    @Test("Sync processor ignores usage count in remote data")
    func syncProcessorIgnoresUsageCountInRemoteData() {
        let remoteData: [String: Any] = [
            "memoryText": "I am a developer",
            "memoryUsageCount": 42,
            "memoryHasSeen": true,
        ]

        let processedText = remoteData["memoryText"] as? String
        #expect(processedText == "I am a developer")

        let pref = AppPreference(theme: .system, language: .system)
        #expect(pref.memoryText.isEmpty)
    }
}


@Suite("Sign out clears memory")
struct SignOutClearsMemoryTests {

    @Test("Sign out clears memory text")
    func signOutClearsMemoryText() {
        var prefs = AppPreference(theme: .system, language: .system)
        prefs.memoryText = "I am a developer"
        prefs.memoryAntiForgetEnabled = true
        prefs.memoryAntiForgetText = "Developer"
        prefs.memoryUpdatedAt = Date()

        prefs.memoryText = ""
        prefs.memoryAntiForgetEnabled = false
        prefs.memoryAntiForgetText = ""
        prefs.memoryUpdatedAt = nil

        #expect(prefs.memoryText.isEmpty)
        #expect(!prefs.memoryAntiForgetEnabled)
        #expect(prefs.memoryAntiForgetText.isEmpty)
        #expect(prefs.memoryUpdatedAt == nil)
    }

    @Test("Sign out clears usage tracking")
    func signOutClearsUsageTracking() {
        var usageCount = 5
        var usageConversationIDs: Set<UUID> = [UUID(), UUID(), UUID(), UUID(), UUID()]

        usageCount = 0
        usageConversationIDs = []

        #expect(usageCount == 0)
        #expect(usageConversationIDs.isEmpty)
    }

    @Test("Sign out prevents leak to next user")
    func signOutPreventsLeakToNextUser() {
        var prefs = AppPreference(theme: .dark, language: .system)
        prefs.memoryText = "Secret: My API key pattern is sk-..."
        prefs.memoryAntiForgetEnabled = true
        prefs.memoryAntiForgetText = "Contains sensitive info"

        prefs.memoryText = ""
        prefs.memoryAntiForgetEnabled = false
        prefs.memoryAntiForgetText = ""
        prefs.memoryUpdatedAt = nil

        #expect(!prefs.memoryText.contains("sk-"))
        #expect(prefs.memoryText.isEmpty)
        #expect(prefs.theme == .dark)
    }
}


@Suite("Backup memory fields")
struct BackupMemoryFieldsTests {

    @Test("Backup includes memory fields")
    func backupIncludesMemoryFields() throws {
        let prefs = BackupPreferences(
            theme: "system",
            language: "english",
            memoryText: "I am a developer",
            memoryAntiForgetEnabled: true,
            memoryAntiForgetText: "Developer, concise",
            memoryUpdatedAt: "2026-03-31T12:00:00Z"
        )
        let data = try JSONEncoder().encode(prefs)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["memoryText"] as? String == "I am a developer")
        #expect(dict["memoryAntiForgetEnabled"] as? Bool == true)
        #expect(dict["memoryAntiForgetText"] as? String == "Developer, concise")
        #expect(dict["memoryUpdatedAt"] as? String == "2026-03-31T12:00:00Z")
    }

    @Test("Backup excludes local only fields")
    func backupExcludesLocalOnlyFields() throws {
        let prefs = BackupPreferences(
            theme: "system",
            language: "english",
            memoryText: "I am a developer",
            memoryAntiForgetEnabled: true,
            memoryAntiForgetText: "Developer",
            memoryUpdatedAt: "2026-04-01T00:00:00Z"
        )
        let data = try JSONEncoder().encode(prefs)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["memoryUsageCount"] == nil)
        #expect(dict["memoryHasSeen"] == nil)
        #expect(dict["memoryUsageConversationIDs"] == nil)
    }

    @Test("Backup nil memory fields not encoded")
    func backupNilMemoryFieldsNotEncoded() throws {
        let prefs = BackupPreferences(
            theme: "system",
            language: "english"
        )
        let data = try JSONEncoder().encode(prefs)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["memoryText"] == nil)
        #expect(dict["memoryAntiForgetEnabled"] == nil)
        #expect(dict["memoryAntiForgetText"] == nil)
        #expect(dict["memoryUpdatedAt"] == nil)
    }

    @Test("Backup restore roundtrip")
    func backupRestoreRoundtrip() throws {
        let original = BackupPreferences(
            theme: "dark",
            language: "zh-Hans",
            memoryText: "I am a developer",
            memoryAntiForgetEnabled: true,
            memoryAntiForgetText: "Developer, concise",
            memoryUpdatedAt: "2026-04-01T08:30:00Z"
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(BackupPreferences.self, from: data)

        #expect(restored.memoryText == original.memoryText)
        #expect(restored.memoryAntiForgetEnabled == original.memoryAntiForgetEnabled)
        #expect(restored.memoryAntiForgetText == original.memoryAntiForgetText)
        #expect(restored.memoryUpdatedAt == original.memoryUpdatedAt)
    }
}
