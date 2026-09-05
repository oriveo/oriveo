import Foundation
import Testing
@testable import Oriveo

@Suite("HomeView")
@MainActor
struct HomeViewTests {
    @Test("the home header date and weekday follow the app language locale")
    func headerDateUsesAppLocaleForWeekday() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-06-01T12:00:00Z"))
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))

        // Ideographic month/day markers are escaped so this source file stays free of ideographs.
        #expect(formatHomeHeaderDate(date, locale: Locale(identifier: "zh-Hans"), timeZone: timeZone) == "6\u{6708}1\u{65E5} \u{661F}\u{671F}\u{4E00}")
        #expect(formatHomeHeaderDate(date, locale: Locale(identifier: "ja"), timeZone: timeZone) == "6\u{6708}1\u{65E5} \u{6708}\u{66DC}\u{65E5}")
        #expect(formatHomeHeaderDate(date, locale: Locale(identifier: "ko"), timeZone: timeZone) == "6월 1일 월요일")
        #expect(formatHomeHeaderDate(date, locale: Locale(identifier: "en"), timeZone: timeZone) == "Monday, June 1")
    }

    @Test("the home header date style recognises CJK locales")
    func headerDateCJKDetectionUsesAppLocale() {
        #expect(isHomeHeaderCJKLocale(Locale(identifier: "zh-Hans")))
        #expect(isHomeHeaderCJKLocale(Locale(identifier: "ja")))
        #expect(isHomeHeaderCJKLocale(Locale(identifier: "ko")))
        #expect(!isHomeHeaderCJKLocale(Locale(identifier: "en")))
    }

    @Test("the home header action buttons keep a clear tap spacing")
    func headerActionButtonsKeepComfortableSpacing() {
        #expect(homeHeaderActionSpacing >= 8)
        #expect(homeHeaderActionButtonSize >= 38)
    }

    @Test("the idle hero cursor uses a single discrete animation layer")
    func heroIdleCursorUsesOneDiscreteLayer() throws {
        let homeSource = try source(named: "HomeView.swift")
        let cursorSource = try #require(homeSource.slice(
            from: "private var heroComposerInput",
            to: "private var modelSelectorPill"
        ))
        let blinkingCursorSource = try #require(homeSource.slice(
            from: "private struct HomeHeroBlinkingCursor",
            to: "private struct HomeConversationEmptyState"
        ))
        let themeSource = try source(named: "AuroraTheme.swift")
        let borderSource = try #require(themeSource.slice(
            from: "struct AuroraGlowBorder",
            to: "extension View"
        ))

        #expect(cursorSource.contains(".transition(.identity)"))
        #expect(cursorSource.contains("transaction.animation = nil"))
        #expect(blinkingCursorSource.contains("TimelineView(.periodic"))
        #expect(!blinkingCursorSource.contains("phaseAnimator"))
        #expect(!blinkingCursorSource.contains(".shadow("))
        #expect(borderSource.contains("guard active && !reduceMotion else { return }"))
    }

    @Test("home search matches both the title and the message body")
    func searchMatchesTitleAndMessageBody() {
        let appState = AppState(seedDemoData: true)
        let providerID = UUID()
        appState.providers = [TestFactories.makeProvider(id: providerID)]

        let convoByTitle = TestFactories.makeConversation(
            id: UUID(),
            title: "Trip Plan",
            providerID: providerID,
            messages: [TestFactories.makeMessage(role: .assistant, text: "hotel shortlist")]
        )
        let convoByMessage = TestFactories.makeConversation(
            id: UUID(),
            title: "Fitness",
            providerID: providerID,
            messages: [TestFactories.makeMessage(role: .assistant, text: "Squat progression")]
        )
        appState.conversations = [convoByTitle, convoByMessage]

        let titleHit = appState.filteredConversations(matching: "trip")
        let messageHit = appState.filteredConversations(matching: "squat")

        #expect(titleHit.contains(where: { $0.id == convoByTitle.id }))
        #expect(messageHit.contains(where: { $0.id == convoByMessage.id }))
    }

    @Test("home conversation buckets follow the today, yesterday, past seven days, earlier order")
    func conversationSectionsFollowExpectedTemporalBuckets() {
        let appState = AppState(seedDemoData: true)
        let providerID = UUID()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        appState.conversationManager.nowProvider = { now }
        appState.providers = [TestFactories.makeProvider(id: providerID)]

        let today = TestFactories.makeConversation(
            title: "Today",
            providerID: providerID,
            updatedAt: now
        )
        let yesterday = TestFactories.makeConversation(
            title: "Yesterday",
            providerID: providerID,
            updatedAt: now.addingTimeInterval(-86_400)
        )
        let past7 = TestFactories.makeConversation(
            title: "Past 7",
            providerID: providerID,
            updatedAt: now.addingTimeInterval(-3 * 86_400)
        )
        let earlier = TestFactories.makeConversation(
            title: "Earlier",
            providerID: providerID,
            updatedAt: now.addingTimeInterval(-12 * 86_400)
        )

        appState.conversations = [today, yesterday, past7, earlier]
        appState.conversationManager.handleConversationsDidChange(now: now)

        let sections = appState.recentConversationSections

        let sectionKinds = sections.map(\.0)
        #expect(sectionKinds == [.today, .yesterday, .past7Days, .earlier])

        let titlesBySection = Dictionary(uniqueKeysWithValues: sections.map { ($0.0, $0.1.map(\.title)) })
        #expect(titlesBySection[.today] == ["Today"])
        #expect(titlesBySection[.yesterday] == ["Yesterday"])
        #expect(titlesBySection[.past7Days] == ["Past 7"])
        #expect(titlesBySection[.earlier] == ["Earlier"])
    }

    @Test("the Earlier bucket shows the first ten conversations and reports how many remain")
    func earlierSectionLimitsVisibleRowsInNormalMode() {
        let conversations = (0..<12).map { index in
            TestFactories.makeConversation(
                title: "Conversation \(index + 1)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let display = resolveHomeConversationSectionDisplay(
            section: .earlier,
            conversations: conversations,
            isEditing: false,
            earlierDisplayCount: 10
        )

        #expect(display.conversations.count == 10)
        #expect(display.remainingCount == 2)
        #expect(display.conversations.map(\.title) == [
            "Conversation 1",
            "Conversation 2",
            "Conversation 3",
            "Conversation 4",
            "Conversation 5",
            "Conversation 6",
            "Conversation 7",
            "Conversation 8",
            "Conversation 9",
            "Conversation 10",
        ])
    }

    @Test("edit mode shows every conversation in the Earlier bucket")
    func earlierSectionShowsAllRowsWhileEditing() {
        let conversations = (0..<12).map { index in
            TestFactories.makeConversation(
                title: "Conversation \(index + 1)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let display = resolveHomeConversationSectionDisplay(
            section: .earlier,
            conversations: conversations,
            isEditing: true,
            earlierDisplayCount: 10
        )

        #expect(display.conversations == conversations)
        #expect(display.remainingCount == 0)
    }

    @Test("buckets other than Earlier are never truncated")
    func nonEarlierSectionKeepsAllRowsVisible() {
        let conversations = (0..<8).map { index in
            TestFactories.makeConversation(
                title: "Conversation \(index + 1)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let display = resolveHomeConversationSectionDisplay(
            section: .today,
            conversations: conversations,
            isEditing: false,
            earlierDisplayCount: 10
        )

        #expect(display.conversations == conversations)
        #expect(display.remainingCount == 0)
    }

    private func source(named fileName: String) throws -> String {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let sourceURL = projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Home")
            .appendingPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let start = range(of: startMarker),
              let end = range(of: endMarker, range: start.upperBound..<endIndex) else {
            return nil
        }
        return String(self[start.lowerBound..<end.lowerBound])
    }
}
