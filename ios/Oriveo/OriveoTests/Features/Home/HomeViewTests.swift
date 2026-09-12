import Foundation
import SwiftUI
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

    @Test("the date eyebrow is uppercased and tracked only for scripts with letter case")
    func headerEyebrowCasingFollowsScript() {
        for identifier in ["en", "de", "fr", "es", "pt-BR", "id", "tr", "vi", "ru"] {
            #expect(homeHeaderUsesCasedEyebrow(Locale(identifier: identifier)), "\(identifier) should be uppercased and tracked")
        }
        for identifier in ["zh-Hans", "zh-Hant", "ja", "ko", "ar", "hi", "th"] {
            #expect(!homeHeaderUsesCasedEyebrow(Locale(identifier: identifier)), "\(identifier) has no letter case and must not be tracked")
        }
    }

    @Test("the top bar capsule buttons keep the design width and a 44pt hit height on the button itself")
    func headerCapsuleButtonsKeepHIGHitHeight() throws {
        #expect(homeHeaderCapsuleHeight == 38)
        #expect(homeHeaderActionHitWidth == 36)
        #expect(homeHeaderActionHitHeight >= 44)

        let buttonSource = try #require(try source(named: "HomeView.swift").slice(
            from: "private func headerCapsuleButton(",
            to: "/// Centred greeting"
        ))
        #expect(buttonSource.contains(".frame(width: homeHeaderActionHitWidth, height: homeHeaderCapsuleHeight)"))
        #expect(buttonSource.contains(".padding(.vertical, (homeHeaderActionHitHeight - homeHeaderCapsuleHeight) / 2)\n                .contentShape(Rectangle())"))
    }

    @Test("the top bar capsule is liquid glass from iOS 26 and keeps a solid fill on earlier systems")
    func headerCapsuleUsesLiquidGlassOnIOS26() throws {
        let capsuleSource = try #require(try source(named: "HomeView.swift").slice(
            from: "private var headerActionCapsule",
            to: "private var headerActionButtons"
        ))
        let modern = try #require(capsuleSource.slice(from: "if #available(iOS 26, *) {", to: "} else {"))
        #expect(modern.contains(".glassEffect(.regular.interactive(), in: Capsule(style: .continuous))"))
        #expect(!modern.contains("chromeFill"), "the iOS 26 branch must not add a solid fill under the glass, it would defeat its adaptation")
        #expect(capsuleSource.contains(".fill(AuroraTheme.Colors.chromeFill)"), "iOS 18–25 keep the solid fill")
    }

    @Test("the trailing half of the top bar always takes part in layout so the brand stays centred without conversations")
    func topBarTrailingSlotAlwaysParticipatesInLayout() throws {
        let topBarSource = try #require(try source(named: "HomeView.swift").slice(
            from: "private var topBar: some View",
            to: "private var brandMark"
        ))
        // topBarTrailing is an empty branch without conversations; it must hang off the always-present
        // flexible placeholder rather than get a frame of its own
        #expect(topBarSource.contains(".overlay(alignment: .trailing) { topBarTrailing }"))
        #expect(!topBarSource.contains("topBarTrailing\n                .frame"))
    }

    @Test("the idle hero is flat: no aurora ring, the 1pt rim stays")
    func heroIdleIsFlat() {
        for isDark in [true, false] {
            let idle = AuroraHeroCardAppearance.resolve(isDark: isDark, focused: false)
            #expect(!idle.showsGlowBorder, "idle must not show the aurora ring (isDark: \(isDark))")
            #expect(idle.showsHairlineBorder)
        }
    }

    @Test("the focused hero shows the aurora ring and hides the 1pt rim")
    func heroFocusedShowsGlowBorder() {
        for isDark in [true, false] {
            let focused = AuroraHeroCardAppearance.resolve(isDark: isDark, focused: true)
            #expect(focused.showsGlowBorder)
            #expect(!focused.showsHairlineBorder, "the 1pt rim gives way to the aurora ring on focus (isDark: \(isDark))")
        }
    }

    @Test("hero shadows: one black layer in dark mode regardless of focus, a single violet layer on focus in light mode")
    func heroShadowsFollowDesignSource() {
        let darkIdle = AuroraHeroCardAppearance.resolve(isDark: true, focused: false)
        let darkFocused = AuroraHeroCardAppearance.resolve(isDark: true, focused: true)
        // 0 12 28 -6 rgba(0,0,0,.36); SwiftUI has no spread, so only blur and y are used
        #expect(darkIdle.ambientShadow == AuroraHeroCardAppearance.Shadow(color: .black.opacity(0.36), radius: 14, y: 12))
        #expect(darkIdle.contactShadow == .none)
        #expect(darkFocused.ambientShadow == darkIdle.ambientShadow)

        let lightIdle = AuroraHeroCardAppearance.resolve(isDark: false, focused: false)
        #expect(lightIdle.contactShadow == AuroraHeroCardAppearance.Shadow(color: Color(hex: 0x0F172A, alpha: 0.04), radius: 1, y: 1))
        #expect(lightIdle.ambientShadow == AuroraHeroCardAppearance.Shadow(color: Color(hex: 0x8B5CF6, alpha: 0.08), radius: 14, y: 10))

        let lightFocused = AuroraHeroCardAppearance.resolve(isDark: false, focused: true)
        #expect(lightFocused.contactShadow == .none)
        #expect(lightFocused.ambientShadow == AuroraHeroCardAppearance.Shadow(color: Color(hex: 0x8B5CF6, alpha: 0.16), radius: 20, y: 14))
    }

    @Test("the hero card has no divider, a solid send button without a shadow, and no attachment button")
    func heroComposerDropsDividerShadowAndAttachment() throws {
        let homeSource = try source(named: "HomeView.swift")
        let cardSource = try #require(homeSource.slice(
            from: "private var auroraComposerCard",
            to: "private var heroComposerInput"
        ))
        #expect(!cardSource.contains("hairline"), "the hero card must not have a hairline divider")
        #expect(!cardSource.contains("paperclip"), "the hero has no attachment button")
        #expect(cardSource.contains(".auroraGlassCard(cornerRadius: 26, focused: heroFocused)"))

        let sendSource = try #require(homeSource.slice(
            from: "private var auroraSendButton",
            to: "private func sendFromHero"
        ))
        #expect(sendSource.contains("AuroraTheme.Colors.sendFill"))
        #expect(!sendSource.contains(".shadow("), "the send button has no shadow")
        #expect(!sendSource.contains("Gradient"), "the send button has no gradient")
    }

    @Test("the Notes entry with notes shows the latest title and the count")
    func notesEntryWithNotesShowsLatestTitle() {
        #expect(HomeNotesEntryCard.previewLine(count: 12, latestTitle: "SwiftUI Metal shader prototyping") == "SwiftUI Metal shader prototyping")
        let label = HomeNotesEntryCard.accessibilityText(count: 12, latestTitle: "SwiftUI Metal shader prototyping")
        #expect(label.hasPrefix(L10n.tr("Notes", table: .notes) + ", "))
        #expect(label.contains(String(format: L10n.tr("%d saved", table: .notes), 12)))
        #expect(label.hasSuffix(", SwiftUI Metal shader prototyping"), "VoiceOver must read the latest title shown on the card")
        #expect(!HomeNotesEntryCard.accessibilityText(count: 12, latestTitle: "").hasSuffix(", "))
    }

    @Test("the empty Notes entry and an untitled latest note fall back to the invitation without a blank line")
    func notesEntryEmptyStateFallsBackToInvitation() {
        let invitation = L10n.tr("Save strong answers with their source, then return to them later.", table: .notes)
        #expect(HomeNotesEntryCard.previewLine(count: 0, latestTitle: nil) == invitation)
        #expect(HomeNotesEntryCard.previewLine(count: 0, latestTitle: "stale title") == invitation)
        #expect(HomeNotesEntryCard.previewLine(count: 3, latestTitle: "") == invitation)
        #expect(HomeNotesEntryCard.accessibilityText(count: 0, latestTitle: nil).hasSuffix(invitation))
    }

    @Test("the Notes entry shares the hero material and uses the gradient notebook glyph, with no chevron, badge, watermark or icon tile")
    func notesEntryFollowsFinalDesign() throws {
        let cardSource = try source(named: "HomeNotesEntryCard.swift")
        #expect(cardSource.contains("AuroraHeroSurface(cornerRadius: Self.cornerRadius, glow: .notesCorner)"))
        #expect(cardSource.contains("Image(\"NotesNotebookLine\")"))
        for stop in ["0xC4B5FD", "0xEC8FEA", "0x8DB4FF"] {
            #expect(cardSource.contains(stop), "the notebook gradient is missing \(stop)")
        }
        #expect(!cardSource.contains("chevron.right"), "no chevron")
        #expect(!cardSource.contains("rotationEffect"), "no watermark")
        #expect(!cardSource.contains("Capsule().fill"), "no count badge")
        #expect(!cardSource.contains(".fill(AuroraTheme.Colors.accent)"), "no solid icon tile")
        // The gradient spans the notebook body's bounding box (4,2)→(20,22), so the bottom-right corner reaches #8DB4FF
        #expect(cardSource.contains("startPoint: UnitPoint(x: 4.0 / 24, y: 2.0 / 24)"))
        #expect(cardSource.contains("endPoint: UnitPoint(x: 20.0 / 24, y: 22.0 / 24)"))
        // Line heights 22 / 18 plus the 1px border (border-box)
        #expect(cardSource.contains(".frame(minHeight: 22)"))
        #expect(cardSource.contains(".frame(minHeight: 18, alignment: .leading)"))
        #expect(cardSource.contains(".padding(.top, 17)") && cardSource.contains(".padding(.leading, 21)"))
    }

    @Test("the dark hero surface is uniform with the aurora on its top edge and outside the card; light mode is unchanged")
    func darkHeroKeepsCardFlatAndPutsAuroraOnItsTopEdge() throws {
        // A directional glow inside the card, high saturation in the dark areas and grey text whose hue
        // did not match the card made the dark card look muddy. The surface now keeps only an even
        // top-to-bottom fill and the aurora moves to the top edge and outside the card.
        let themeSource = try source(named: "AuroraTheme.swift")
        #expect(themeSource.contains("colors: [Color(hex: 0x242235), Self.darkBaseBottom]"))
        #expect(!themeSource.contains("angleDegrees: 150"), "the dark surface no longer uses a 150° diagonal gradient")
        #expect(!themeSource.contains("Color(hex: 0x818CF8"), "no directional glow inside the dark card")
        // The pill is opaque; the grey text inside the hero shares the card's hue and is not the global tertiary
        #expect(themeSource.contains("static let pillFill = Color.dynamic(light: 0xF3F0FA, dark: 0x2F2D3F)"))
        #expect(themeSource.contains("static let heroTextTertiary = Color.dynamic(light: 0x9C95AA, dark: 0x9493A8)"))
        let viewSource = try source(named: "HomeView.swift")
        #expect(viewSource.components(separatedBy: "AuroraTheme.Colors.heroTextTertiary").count - 1 == 4,
                "all four grey texts inside the hero (placeholder, pill placeholder icon, provider name, chevron) use heroTextTertiary")
    }

    @Test("the aurora crown lights the hero with a hot core and a halo, Notes one step weaker, both fading on focus")
    func auroraCrownLightsHeroAndNotesAlike() throws {
        let themeSource = try source(named: "AuroraTheme.swift")
        // Hero: crown plus halo outside the card, fading on focus in favour of the glow ring (two lights would smear)
        #expect(themeSource.contains("AuroraCrownRim(cornerRadius: cornerRadius)"))
        #expect(themeSource.contains("AuroraCrownHalo(cornerRadius: cornerRadius)"))
        #expect(themeSource.contains(".opacity(isDark && !focused ? 1 : 0)"))
        // Notes: the same light one step weaker, without a hot core and without the outer halo
        let cardSource = try source(named: "HomeNotesEntryCard.swift")
        #expect(cardSource.contains("AuroraCrownRim(cornerRadius: Self.cornerRadius, scale: AuroraCrown.notesRimScale, hotCore: false)"))
        #expect(!cardSource.contains("AuroraCrownHalo"))
    }

    @Test("the Notes glyph asset has no zero-height binder ticks")
    func notesGlyphHasNoBinderTicks() throws {
        let svgURL = try sourceRoot()
            .appendingPathComponent("Oriveo/Assets.xcassets/NotesNotebookLine.imageset/icon.svg")
        let svg = try String(contentsOf: svgURL, encoding: .utf8)
        #expect(svg.contains("stroke-width=\"1.6\""))
        for tick in ["M2 6h4", "M2 10h4", "M2 14h4", "M2 18h4"] {
            #expect(!svg.contains(tick), "the binder tick \(tick) is invisible in the design and must not be in the asset")
        }
    }

    @Test("one card per conversation group: date groups, search, pinned and folders draw no separators")
    func conversationGroupsHaveNoDividers() throws {
        let homeSource = try source(named: "HomeView.swift")
        let listSource = try #require(homeSource.slice(
            from: "private var conversationContent",
            to: "// MARK: - Folder Section"
        ))
        #expect(!listSource.contains("Divider()"))
        #expect(listSource.contains("AuroraGroupedCard {"))
        // The Home family no longer uses the shared V2 GroupedCard (it still serves the skill editor)
        #expect(listSource.components(separatedBy: "GroupedCard {").count
            == listSource.components(separatedBy: "AuroraGroupedCard {").count)

        let folderSource = try #require(try source(named: "FolderRow.swift").slice(
            from: "private var folderContent",
            to: "private func conversationInFolder"
        ))
        #expect(!folderSource.contains("Divider()"))
        #expect(folderSource.contains("AuroraGroupedCard {"))
    }

    @Test("the group card honours border-box: content inset by 1pt, the dark inner highlight drawn inside the border")
    func groupedCardHonorsBorderBox() throws {
        let cardSource = try #require(try source(named: "AuroraTheme.swift").slice(
            from: "struct AuroraGroupedCard",
            to: "// MARK: - Greeting"
        ))
        #expect(cardSource.contains("content()\n            .padding(1)"))
        #expect(cardSource.contains("let innerShape = shape.inset(by: 1)"))
        #expect(cardSource.contains("innerShape.subtracting(innerShape.offset(y: 1))"))
    }

    @Test("editing inside a folder: the row knows it is editing and insets the checkmark by 14 off the card edge")
    func folderRowEditingInsetsCheckmark() throws {
        let rowSource = try #require(try source(named: "FolderRow.swift").slice(
            from: "private func conversationInFolder",
            to: "private var newChatButton"
        ))
        #expect(rowSource.contains("isEditing: isEditing,"))
        #expect(rowSource.contains(".padding(.leading, isEditing ? 14 : 0)"))
    }

    @Test("group header metrics: 3×18 bar, 17/bold title, 10 to the card, 22 between groups")
    func sectionHeaderMetricsFollowDesign() throws {
        let themeSource = try source(named: "AuroraTheme.swift")
        #expect(themeSource.contains(".frame(width: 3, height: 18)"))
        #expect(themeSource.contains("static let section = Font.system(size: 17, weight: .bold)"))

        let homeSource = try source(named: "HomeView.swift")
        let insets = try #require(homeSource.slice(
            from: "private struct HomeSectionHeaderInsets",
            to: "private struct HomeHeroBlinkingCursor"
        ))
        #expect(insets.contains(".padding(.horizontal, 4)"))
        #expect(insets.contains(".padding(.bottom, 10)"))
        #expect(homeSource.contains("VStack(alignment: .leading, spacing: 22)"))
    }

    @Test("hero controls match the visible design sizes: arrow 16, chevron 9 in a 12 slot, 44pt pill hit area, 110° ring start, insets include the 1px border")
    func heroControlsMatchVisibleDesignMetrics() throws {
        let homeSource = try source(named: "HomeView.swift")
        let pillSource = try #require(homeSource.slice(from: "private var modelSelectorPill", to: "/// The send button"))
        #expect(pillSource.contains(".font(.system(size: 9, weight: .semibold))"))
        #expect(pillSource.contains(".frame(width: 12, height: 12)"))
        #expect(pillSource.contains(".frame(height: 44)\n        .contentShape(Rectangle())"), "the pill hit area should be 44")

        let sendSource = try #require(homeSource.slice(from: "private var auroraSendButton", to: "private func sendFromHero"))
        #expect(sendSource.contains(".font(.system(size: 16, weight: .semibold))"))

        let cardSource = try #require(homeSource.slice(from: "private var auroraComposerCard", to: "private var heroComposerInput"))
        #expect(cardSource.contains(".padding(.horizontal, 19)"))
        #expect(cardSource.contains(".padding(.top, 19)"))
        #expect(cardSource.contains(".padding(.bottom, 15)"))

        let themeSource = try source(named: "AuroraTheme.swift")
        #expect(themeSource.contains("center: .center, angle: .degrees(110)"), "the aurora ring starts at the conic-gradient 200deg equivalent")
        #expect(themeSource.contains("AuroraGlowBorder(cornerRadius: cornerRadius + 1, active: focused)\n                    .padding(-1)"))
    }

    @Test("the hero input has an accessibility name and the decorative placeholder is hidden from VoiceOver")
    func heroInputAccessibility() throws {
        let inputSource = try #require(try source(named: "HomeView.swift").slice(
            from: "private var heroComposerInput",
            to: "/// The model selector chip"
        ))
        #expect(inputSource.contains(".accessibilityLabel(Text(composerPlaceholder))"))
        #expect(inputSource.contains(".accessibilityHidden(true)"))
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

    /// The `Oriveo` project directory (this file lives under OriveoTests/Features/Home)
    private func sourceRoot() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(named fileName: String) throws -> String {
        let sourceURL = try sourceRoot()
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
