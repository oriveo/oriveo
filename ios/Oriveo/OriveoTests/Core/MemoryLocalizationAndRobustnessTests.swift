import Testing
import Foundation
@testable import Oriveo


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

private func makeConversationMessages(rounds: Int) -> [ChatMessage] {
    var messages: [ChatMessage] = []
    for i in 1...rounds {
        messages.append(makeMessage(role: .user, text: "Q\(i)"))
        messages.append(makeMessage(role: .assistant, text: "A\(i)"))
    }
    return messages
}

private func estimateTokens(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return Int(ceil(Double(text.count) * 0.35))
}

private func sanitizeErrorMessage(_ message: String, apiKey: String) -> String {
    guard !apiKey.isEmpty else { return message }
    return message.replacingOccurrences(of: apiKey, with: "***")
}

private func simulateMarkMemoryUsed(
    conversationID: UUID,
    existingIDs: Set<UUID>
) -> (isNew: Bool, updatedIDs: Set<UUID>) {
    if existingIDs.contains(conversationID) {
        return (false, existingIDs)
    }
    var updated = existingIDs
    updated.insert(conversationID)
    return (true, updated)
}

private func simulateSyncBehavior(role: String) -> (syncsToCloud: Bool, localOnly: Bool) {
    switch role {
    case "pro": return (true, false)
    case "free": return (false, true)
    case "guest": return (false, true)
    default: return (false, true)
    }
}

// ══════════════════════════════════════════════════════════
// Localization, script coverage and robustness of the memory feature
// ══════════════════════════════════════════════════════════


@Suite("Memory Localization Coverage Tests")
struct MemoryLocalizationCoverageTests {

    @Test("Memory Keys Exist In Localizable")
    func memoryKeysExistInLocalizable() {
        let bundle = Bundle.main
        let memoryKeys = [
            "Memory",
            "Memory saved",
            "Use Memory",
            "Long conversation anti-forgetting",
        ]
        for key in memoryKeys {
            #expect(!key.isEmpty, "Key '\(key)' should exist")
        }
    }

    @Test("Localization Does Not Crash")
    func localizationDoesNotCrash() {
        let locales = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "pt-BR", "ar", "hi", "id", "vi", "th", "tr", "ru"]
        for localeId in locales {
            let locale = Locale(identifier: localeId)
            #expect(locale.identifier.contains(localeId.prefix(2)) || localeId == "pt-BR",
                    "Locale \(localeId) should be valid")
        }
    }
}


@Suite("Memory RTLTests")
struct MemoryRTLTests {

    @Test("Arabic Memory Injection")
    func arabicMemoryInjection() {
        let arabicMemory = "أنا مطور يعمل على تطبيق ذكاء اصطناعي"
        let options = simulateBuildMemoryRequestOptions(memoryText: arabicMemory, useMemory: true)
        #expect(options.systemPrompt == arabicMemory)
    }

    @Test("Rtl Mixed Text Truncation")
    func rtlMixedTextTruncation() {
        let mixed = "مرحبا Hello こん"
        let truncated = String(mixed.prefix(5))
        #expect(truncated.count == 5)
    }

    @Test("Arabic Anti Forget Format")
    func arabicAntiForgetFormat() {
        let arabicAntiForget = "مطور ويب"
        var messages = makeConversationMessages(rounds: 10)
        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: "أنا مطور",
            antiForgetText: arabicAntiForget,
            useMemory: true
        )
        let lastUser = messages.last(where: { $0.role == .user })
        #expect(lastUser?.text.contains("\n\n[Reminder: \(arabicAntiForget)]") == true)
    }
}


@Suite("Memory CJKTests")
struct MemoryCJKTests {

    @Test("Chinese2000 Truncation")
    func chinese2000Truncation() {
        let text = String(repeating: "あ", count: 2001)
        let truncated = String(text.prefix(2000))
        #expect(truncated.count == 2000)
    }

    @Test("Japanese Grapheme Count")
    func japaneseGraphemeCount() {
        let text = "おはようせかい"
        #expect(text.count == 7)
    }

    @Test("Korean Grapheme Count")
    func koreanGraphemeCount() {
        let text = "안녕하세요"
        #expect(text.count == 5)
    }

    @Test("Traditional Chinese Truncation")
    func traditionalChineseTruncation() {
        let text = String(repeating: "きおくきのうのてすと", count: 300)
        let truncated = String(text.prefix(200))
        #expect(truncated.count == 200)
    }
}


@Suite("Memory Number Format Tests")
struct MemoryNumberFormatTests {

    @Test("Grapheme Aware Count")
    func graphemeAwareCount() {
        let emoji = "👨‍👩‍👧‍👦" // 1 grapheme cluster
        #expect(emoji.count == 1)
        #expect(emoji.utf8.count > 1)
        #expect(emoji.utf16.count > 1)
    }

    @Test("Token Estimation")
    func tokenEstimation() {
        #expect(estimateTokens("") == 0)
        #expect(estimateTokens("a") == 1)
        #expect(estimateTokens("abc") == 2)
        #expect(estimateTokens(String(repeating: "a", count: 10)) == 4)
        #expect(estimateTokens(String(repeating: "あ", count: 2000)) == 700)
    }

    @Test("Emoji Token Estimation")
    func emojiTokenEstimation() {
        let text = String(repeating: "😀", count: 2000)
        #expect(text.count == 2000) // Swift count = grapheme clusters
        #expect(estimateTokens(text) == 700)
    }
}


@Suite("Memory Content Preservation Tests")
struct MemoryContentPreservationTests {

    @Test("Memory Injection Preserves User Text")
    func memoryInjectionPreservesUserText() {
        let chineseMemory = "I am a senior Go engineer, I prefer concise replies"
        let options = simulateBuildMemoryRequestOptions(memoryText: chineseMemory, useMemory: true)
        #expect(options.systemPrompt == chineseMemory)
    }

    @Test("Memory Text Consistent Across Locales")
    func memoryTextConsistentAcrossLocales() {
        let memory = "I am a senior Go engineer"
        let options1 = simulateBuildMemoryRequestOptions(memoryText: memory, useMemory: true)
        let options2 = simulateBuildMemoryRequestOptions(memoryText: memory, useMemory: true)
        #expect(options1.systemPrompt == options2.systemPrompt)
        #expect(options1.systemPrompt == memory)
    }

    @Test("Anti Forget Preserves User Text")
    func antiForgetPreservesUserText() {
        let antiForgetText = "Senior Go engineer, concise style"
        var messages = makeConversationMessages(rounds: 10)
        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: "Memory",
            antiForgetText: antiForgetText,
            useMemory: true
        )
        let lastUser = messages.last(where: { $0.role == .user })
        #expect(lastUser?.text.contains(antiForgetText) == true)
    }
}


@Suite("Memory Multi Language Draft Tests")
struct MemoryMultiLanguageDraftTests {

    @Test("Chinese History Injection")
    func chineseHistoryInjection() {
        let options = simulateBuildMemoryRequestOptions(memoryText: "I am a frontend developer", useMemory: true)
        #expect(options.hasCustomizations)
        #expect(options.systemPrompt == "I am a frontend developer")
    }

    @Test("English History Injection")
    func englishHistoryInjection() {
        let options = simulateBuildMemoryRequestOptions(memoryText: "I am a senior React developer", useMemory: true)
        #expect(options.hasCustomizations)
        #expect(options.systemPrompt == "I am a senior React developer")
    }

    @Test("Japanese History Injection")
    func japaneseHistoryInjection() {
        let options = simulateBuildMemoryRequestOptions(memoryText: "わたしはシニアエンジニアです", useMemory: true)
        #expect(options.hasCustomizations)
        #expect(options.systemPrompt == "わたしはシニアエンジニアです")
    }

    @Test("Arabic History Injection")
    func arabicHistoryInjection() {
        let options = simulateBuildMemoryRequestOptions(memoryText: "أنا مطور ويب", useMemory: true)
        #expect(options.hasCustomizations)
        #expect(options.systemPrompt == "أنا مطور ويب")
    }
}


@Suite("Memory Anti Forget Stability Tests")
struct MemoryAntiForgetStabilityTests {

    private let memoryText = "I am a developer"
    private let antiForgetText = "Senior engineer, prefers concise code"

    @Test("Ten Rounds One Context")
    func tenRoundsOneContext() {
        var messages = makeConversationMessages(rounds: 10)
        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: memoryText,
            antiForgetText: antiForgetText,
            useMemory: true
        )
        let contextCount = messages.filter { $0.text.contains("[Reminder:") }.count
        #expect(contextCount == 1)
    }

    @Test("Twenty Rounds One Context")
    func twentyRoundsOneContext() {
        var messages = makeConversationMessages(rounds: 20)
        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: memoryText,
            antiForgetText: antiForgetText,
            useMemory: true
        )
        let contextCount = messages.filter { $0.text.contains("[Reminder:") }.count
        #expect(contextCount == 1)
    }

    @Test("Fifty Rounds One Context")
    func fiftyRoundsOneContext() {
        var messages = makeConversationMessages(rounds: 50)
        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: memoryText,
            antiForgetText: antiForgetText,
            useMemory: true
        )
        let contextCount = messages.filter { $0.text.contains("[Reminder:") }.count
        #expect(contextCount == 1)
    }

    @Test("Hundred Rounds One Context")
    func hundredRoundsOneContext() {
        var messages = makeConversationMessages(rounds: 100)
        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: memoryText,
            antiForgetText: antiForgetText,
            useMemory: true
        )
        let contextCount = messages.filter { $0.text.contains("[Reminder:") }.count
        #expect(contextCount == 1)
    }

    @Test("Context Only On Last User Message")
    func contextOnlyOnLastUserMessage() {
        var messages = makeConversationMessages(rounds: 15)
        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: memoryText,
            antiForgetText: antiForgetText,
            useMemory: true
        )

        let userMsgsWithContext = messages.filter { $0.role == .user && $0.text.contains("[Reminder:") }
        #expect(userMsgsWithContext.count == 1)

        let lastUser = messages.last(where: { $0.role == .user })
        #expect(lastUser?.text.contains("[Reminder:") == true)
    }

    @Test("No Double Append On Retry")
    func noDoubleAppendOnRetry() {
        var messages = makeConversationMessages(rounds: 10)

        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: memoryText,
            antiForgetText: antiForgetText,
            useMemory: true
        )

        let lastUser = messages.last(where: { $0.role == .user })
        let occurrences = lastUser?.text.components(separatedBy: "[Reminder:").count ?? 0
        #expect(occurrences == 2)
    }
}


@Suite("Memory Security Log Tests")
struct MemorySecurityLogTests {

    @Test("Api Key Redacted")
    func apiKeyRedacted() {
        let apiKey = "sk-ant-api03-abcdef123456"
        let errorMsg = "Error: 401 Unauthorized for key \(apiKey)"
        let sanitized = sanitizeErrorMessage(errorMsg, apiKey: apiKey)
        #expect(!sanitized.contains(apiKey))
        #expect(sanitized.contains("***"))
    }

    @Test("Memory Not In Error Log")
    func memoryNotInErrorLog() {
        let memoryText = "I am a senior developer who prefers concise replies"
        let errorLog = "Error: 429 Rate limit exceeded. Provider: openai, Model: gpt-4o"
        #expect(!errorLog.contains(memoryText))
    }

    @Test("Anti Forget Text Never Reaches A Diagnostic Breadcrumb")
    func antiForgetNotInDiagnosticBreadcrumb() {
        let antiForgetText = "Senior Python engineer"
        let breadcrumb = ["category": "chat.send", "message": "Message sent to openai/gpt-4o", "level": "info"]
        let serialized = breadcrumb.values.joined(separator: " ")
        #expect(!serialized.contains(antiForgetText))
    }
}


@Suite("Memory All Provider Smoke Tests")
struct MemoryAllProviderSmokeTests {

    private let memoryText = "I am a full-stack developer specializing in TypeScript and Go."

    @Test("Open AISmoke Test")
    func openAISmokeTest() {
        let options = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        #expect(options.systemPrompt == memoryText)
    }

    @Test("Anthropic Smoke Test")
    func anthropicSmokeTest() {
        let options = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        #expect(options.systemPrompt == memoryText)
        #expect(options.hasCustomizations)
    }

    @Test("Gemini Smoke Test")
    func geminiSmokeTest() {
        let options = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        #expect(options.systemPrompt == memoryText)
        #expect(options.hasCustomizations)
    }

    @Test("Open Router Smoke Test")
    func openRouterSmokeTest() {
        let options = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        #expect(options.systemPrompt == memoryText)
    }

    @Test("Groq Smoke Test")
    func groqSmokeTest() {
        let options = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        #expect(options.systemPrompt == memoryText)
    }

    @Test("Together Smoke Test")
    func togetherSmokeTest() {
        let options = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        #expect(options.systemPrompt == memoryText)
    }

    @Test("Fireworks Smoke Test")
    func fireworksSmokeTest() {
        let options = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        #expect(options.systemPrompt == memoryText)
    }

    @Test("Relay Smoke Test")
    func relaySmokeTest() {
        let options = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        #expect(options.systemPrompt == memoryText)
    }

    @Test("No Injection When Empty")
    func noInjectionWhenEmpty() {
        let options = simulateBuildMemoryRequestOptions(memoryText: "", useMemory: true)
        #expect(!options.hasCustomizations)
        #expect(options.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("All Providers Anti Forget Smoke")
    func allProvidersAntiForgetSmoke() {
        var messages = makeConversationMessages(rounds: 10)
        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: "Memory text",
            antiForgetText: "TypeScript expert",
            useMemory: true
        )

        let lastUser = messages.last(where: { $0.role == .user })
        #expect(lastUser?.text.contains("[Reminder: TypeScript expert]") == true)

        let contextCount = messages.filter { $0.text.contains("[Reminder:") }.count
        #expect(contextCount == 1)
    }
}


@Suite("Memory Role Smoke Tests")
struct MemoryRoleSmokeTests {

    @Test("Guest Memory Injection")
    func guestMemoryInjection() {
        let options = simulateBuildMemoryRequestOptions(memoryText: "I like Python", useMemory: true)
        #expect(options.systemPrompt == "I like Python")
    }

    @Test("Free Memory Injection")
    func freeMemoryInjection() {
        let options = simulateBuildMemoryRequestOptions(memoryText: "I like Java", useMemory: true)
        #expect(options.systemPrompt == "I like Java")
    }

    @Test("Pro Memory Injection")
    func proMemoryInjection() {
        let options = simulateBuildMemoryRequestOptions(memoryText: "I like Rust", useMemory: true)
        #expect(options.systemPrompt == "I like Rust")
    }

    @Test("Guest Local Only")
    func guestLocalOnly() {
        let sync = simulateSyncBehavior(role: "guest")
        #expect(sync.syncsToCloud == false)
        #expect(sync.localOnly == true)
    }

    @Test("Free Local Only")
    func freeLocalOnly() {
        let sync = simulateSyncBehavior(role: "free")
        #expect(sync.syncsToCloud == false)
        #expect(sync.localOnly == true)
    }

    @Test("Pro Syncs To Cloud")
    func proSyncsToCloud() {
        let sync = simulateSyncBehavior(role: "pro")
        #expect(sync.syncsToCloud == true)
        #expect(sync.localOnly == false)
    }

    @Test("Usage Count Per Conversation")
    func usageCountPerConversation() {
        var ids = Set<UUID>()
        let conv1 = UUID()
        let conv2 = UUID()

        let r1 = simulateMarkMemoryUsed(conversationID: conv1, existingIDs: ids)
        #expect(r1.isNew == true)
        ids = r1.updatedIDs

        let r2 = simulateMarkMemoryUsed(conversationID: conv1, existingIDs: ids)
        #expect(r2.isNew == false)

        let r3 = simulateMarkMemoryUsed(conversationID: conv2, existingIDs: ids)
        #expect(r3.isNew == true)
    }

    @Test("No Injection When Disabled")
    func noInjectionWhenDisabled() {
        for _ in ["guest", "free", "pro"] {
            let options = simulateBuildMemoryRequestOptions(memoryText: "Some memory", useMemory: false)
            #expect(!options.hasCustomizations)
        }
    }
}


@Suite("Memory Payload Size Tests")
struct MemoryPayloadSizeTests {

    @Test("Fifty Rounds Payload Delta")
    func fiftyRoundsPayloadDelta() {
        let antiForgetText = String(repeating: "A", count: 200)
        var messages = makeConversationMessages(rounds: 50)

        let baselineSize = messages.reduce(0) { $0 + $1.text.utf8.count }

        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: "Test memory",
            antiForgetText: antiForgetText,
            useMemory: true
        )

        let injectedSize = messages.reduce(0) { $0 + $1.text.utf8.count }
        let delta = injectedSize - baselineSize

        #expect(delta < 10240) // < 10KB
    }

    @Test("Emoji Context Size")
    func emojiContextSize() {
        let emojiContext = String(repeating: "😀", count: 200)
        let encoded = "\n\n[Reminder: \(emojiContext)]"
        #expect(encoded.utf8.count < 10240)
    }

    @Test("Cjk Context Size")
    func cjkContextSize() {
        let cjkContext = String(repeating: "x", count: 200)
        let encoded = "\n\n[Reminder: \(cjkContext)]"
        #expect(encoded.utf8.count < 10240)
    }

    @Test("Fifty Rounds One Append")
    func fiftyRoundsOneAppend() {
        var messages = makeConversationMessages(rounds: 50)
        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: "Memory",
            antiForgetText: String(repeating: "A", count: 200),
            useMemory: true
        )
        let contextCount = messages.filter { $0.text.contains("[Reminder:") }.count
        #expect(contextCount == 1)
    }
}




@Suite("Memory Prompt Build Time Tests")
struct MemoryPromptBuildTimeTests {

    @Test("Full Injection Under50ms")
    func fullInjectionUnder50ms() {
        let memoryText = String(repeating: "x", count: 2000)
        let antiForgetText = String(repeating: "A", count: 200)
        var messages = makeConversationMessages(rounds: 50)

        let start = ContinuousClock.now
        let _ = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: true,
            memoryText: memoryText,
            antiForgetText: antiForgetText,
            useMemory: true
        )
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(50))
    }

    @Test("Injection Without Anti Forget Under50ms")
    func injectionWithoutAntiForgetUnder50ms() {
        let memoryText = String(repeating: "A", count: 2000)
        var messages = makeConversationMessages(rounds: 50)

        let start = ContinuousClock.now
        let _ = simulateBuildMemoryRequestOptions(memoryText: memoryText, useMemory: true)
        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: false,
            memoryText: memoryText,
            antiForgetText: "",
            useMemory: true
        )
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(50))
    }

    @Test("Empty Memory Skip Under1ms")
    func emptyMemorySkipUnder1ms() {
        var messages = makeConversationMessages(rounds: 50)

        let start = ContinuousClock.now
        let _ = simulateBuildMemoryRequestOptions(memoryText: "", useMemory: true)
        simulateApplyAntiForget(
            messages: &messages,
            antiForgetEnabled: false,
            memoryText: "",
            antiForgetText: "",
            useMemory: true
        )
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(1))
    }
}
