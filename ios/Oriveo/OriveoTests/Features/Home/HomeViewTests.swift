import Combine
import Foundation
import OriveoProviderKit
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

    @Test("greeting pool has five lines per time of day, stays put within a day, and can change the next day")
    func greetingPoolIsDailyStable() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        for bucket: AuroraGreeting.Bucket in [.morning, .afternoon, .evening, .night] {
            #expect(AuroraGreeting.greetings[bucket]?.count == 5, "\(bucket) greeting pool should have 5 lines")
            #expect(AuroraGreeting.taglines[bucket]?.count == 8, "\(bucket) tagline pool should have 8 lines")
        }

        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 9))!
        let laterMorning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 11))!
        #expect(AuroraGreeting.currentKey(date: morning, calendar: calendar) == AuroraGreeting.currentKey(date: laterMorning, calendar: calendar))
        #expect(AuroraGreeting.greetingSalt == 17)
        #expect(AuroraGreeting.taglineSalt == 31)
        #expect(AuroraGreeting.dailyIndex(date: morning, calendar: calendar, salt: 17, count: 5) == 3)
        #expect(AuroraGreeting.dailyIndex(date: morning, calendar: calendar, salt: 31, count: 8) == 2)

        // Same anchor as the Android HomeHeroVisualContractTest: 2026-09-16 afternoon -> greeting 5, tagline 8
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 15))!
        #expect(AuroraGreeting.currentKey(date: anchor, calendar: calendar) == AuroraGreeting.greetings[.afternoon]?[4])
        #expect(AuroraGreeting.taglineKey(date: anchor, calendar: calendar) == AuroraGreeting.taglines[.afternoon]?[7])

        let uniqueGreetings = Set((0..<40).compactMap { offset -> String? in
            calendar.date(byAdding: .day, value: offset, to: morning).map {
                AuroraGreeting.currentKey(date: $0, calendar: calendar)
            }
        })
        #expect(uniqueGreetings.count >= 4)
    }

    @Test("every greeting and tagline key is written for all sixteen locales")
    func greetingAndTaglineKeysCoverEveryLocale() throws {
        let catalogURL = try sourceRoot()
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])

        let keys = Set(AuroraGreeting.greetings.values.flatMap { $0 })
            .union(AuroraGreeting.taglines.values.flatMap { $0 })
        #expect(keys.count == 11 + 32)
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "missing key \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(localizations.count == 16, "\(key) should cover 16 locales, found \(localizations.count)")
            for (language, value) in localizations {
                let text = ((value as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                #expect(text?.isEmpty == false, "\(key) [\(language)] has no text")
            }
        }
    }

    @Test("titles and their counts line up on their visual centers (Latin and CJK)")
    func titleCountInkCentersAlign() throws {
        // The Notes card once used baseline alignment, which dropped the count about 1.5pt below the
        // middle of a Chinese title; the group header added a baselineOffset that lifted it too high.
        // Latin titles avoid descenders, which would pull the ink center down.
        // The tolerance of 0.7pt is two pixels at 3x: top-heavy Chinese glyphs already sit ~0.6pt high.
        // Chinese titles are escaped: notes, yesterday, pinned.
        let chineseTitles = ["\u{7B14}\u{8BB0}", "\u{6628}\u{5929}", "\u{7F6E}\u{9876}"]
        for title in chineseTitles + ["Notes", "Pinned", "ノート", "노트"] {
            for (fontName, font) in [("notes", Font.system(size: 17, weight: .semibold)), ("section", AuroraTheme.Typography.section)] {
                let content = AuroraTitleCount(title: title, titleFont: font, count: 2)
                    .padding(8)
                    .background(Color.white)
                    .environment(\.colorScheme, .light)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 3
                let image = try #require(renderer.cgImage)
                let centers = try #require(Self.inkCenters(image), "\(title) rendered no ink")
                let delta = centers.count - centers.title
                #expect(abs(delta) <= 0.7, "\(title) [\(fontName)] count sits \(delta)pt below the title (negative is above)")
            }
        }

        // Both call sites have to use the component rather than drifting back to their own alignment
        let notesSource = try source(named: "HomeNotesEntryCard.swift")
        let viewSource = try source(named: "HomeView.swift")
        #expect(notesSource.contains("AuroraTitleCount("))
        #expect(viewSource.contains("AuroraTitleCount("))
        #expect(!notesSource.contains(".firstTextBaseline"))
        #expect(!viewSource.contains(".baselineOffset(1)"))
    }

    /// Splits title ink (near black) from count ink (violet) by color and returns their vertical centers
    /// in points for a 3x render.
    private static func inkCenters(_ image: CGImage) -> (title: Double, count: Double)? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var titleRows: [Int] = []
        var countRows: [Int] = []
        for y in 0..<height {
            var hasTitle = false
            var hasCount = false
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                if b - g > 50, b > 150 {
                    hasCount = true
                } else if max(r, g, b) < 120, b - g < 40 {
                    hasTitle = true
                }
            }
            if hasTitle { titleRows.append(y) }
            if hasCount { countRows.append(y) }
        }
        guard let titleTop = titleRows.first, let titleBottom = titleRows.last,
              let countTop = countRows.first, let countBottom = countRows.last else { return nil }
        return (Double(titleTop + titleBottom) / 6, Double(countTop + countBottom) / 6)
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

    @Test("Home realtime idle stage: the left keyboard button switches to typing, with no ✕ or mute; ✕ no longer exits the realtime selection")
    func heroRealtimeIdleStageHasKeyboardNoEnd() throws {
        var switched = 0
        let idle = RealtimeIdleStageSurface(onTap: {}, onSwitchToTyping: { switched += 1 })
        #expect(idle.showsTypingSwitch)
        #expect(!idle.showsEndButton)
        #expect(!idle.showsMuteButton)
        idle.switchToTyping()
        #expect(switched == 1)

        let home = try source(named: "HomeView.swift")
        let card = try #require(home.slice(from: "private var auroraComposerCardContent", to: "private func presentModelPicker"))
        #expect(!card.contains("clearRealtimeModelSelection"))
        let stage = try #require(home.slice(
            from: "private var heroVoiceConversationController", to: "private var heroRealtimeFailureNavigation"
        ))
        #expect(stage.contains("onSwitchToTyping: { heroRealtimeTyping = true }"))
        // Idle stage bottom row: the centered "switch to typing" capsule; no end button.
        #expect(VoiceConversationBarContent.controlSlots(
            showsTypingSwitch: idle.showsTypingSwitch,
            showsMuteButton: idle.showsMuteButton,
            showsEndButton: idle.showsEndButton
        ).map(\.kind) == [.typingCapsule])
    }

    @Test("On the home realtime-selected stage, the model pill sits centered at the top of the voice stage (with the cyan dot); tapping the pill opens the picker; pill bottom to orb box top is 12")
    func heroRealtimeStageShowsModelPill() throws {
        let home = try source(named: "HomeView.swift")
        let card = try #require(home.slice(from: "private var auroraComposerCardContent", to: "private func presentModelPicker"))
        let stageBranch = try #require(card.slice(from: "if let voiceSurface = heroVoiceConversationController", to: "VoiceConversationBar("))
        // The pill also shows while preparing or when the catalog fails (the home realtime selection is stored); the layout does not move once the catalog arrives.
        #expect(stageBranch.contains("if heroRealtimeStage.showsModelPill {"))
        #expect(stageBranch.contains("heroStageModelPill"))
        #expect(HomeHeroStageLayout.pillToOrbGap == 12)
        #expect(HomeHeroStageLayout.pillSpacing
            == HomeHeroStageLayout.pillToOrbGap - VoiceConversationBarContent.orbTop - HomeHeroStageLayout.pillHitInset)

        let pill = try #require(home.slice(from: "private var heroStageModelPill", to: "private var heroVoiceConversationController"))
        #expect(pill.contains("presentModelPicker()"))
        #expect(pill.contains("modelSelectorPill"))
        // modelSelectorPill draws the cyan dot when realtime is selected (locked by modelPillShowsRealtimeDotWhenRealtimeSelected).
        let selector = try #require(home.slice(from: "private var modelSelectorPill", to: "private var heroStageModelPill"))
        #expect(selector.contains("RealtimeModelDot()"))
    }

    @Test("The home back-to-stage button and the conversation page share one view: the accessibility label matches the accessibility identifier")
    func heroBackToStageUsesSharedButton() throws {
        #expect(RealtimeBackToStageButton.accessibilityLabel == VoiceConversationCopy.backToStageA11y)
        #expect(RealtimeBackToStageButton.orbSize == 36)

        let home = try source(named: "HomeView.swift")
        let heroButton = try #require(home.slice(
            from: "private var heroBackToStageButton", to: "private enum HeroVoiceButtonStyle"
        ))
        #expect(heroButton.contains("RealtimeBackToStageButton(\n            accessibilityID: \"home_voice_back_to_stage_button\","))
        #expect(!heroButton.contains("VoiceAuroraOrb("))

        let chat = try String(
            contentsOf: try sourceRoot()
                .appendingPathComponent("Oriveo/Features/Chat/ChatComposerBar.swift"),
            encoding: .utf8
        )
        let chatButton = try #require(chat.slice(
            from: "private var backToStageButton", to: "// MARK: - Shared Surface Helper"
        ))
        #expect(chatButton.contains("RealtimeBackToStageButton(\n            accessibilityID: \"chat_voice_back_to_stage_button\","))
        #expect(!chatButton.contains("VoiceAuroraOrb("))
    }

    @Test("Home has a realtime selection but the voice catalog has not arrived: show the voice stage in preparing directly (orb not tappable, status line Loading); a catalog failure shows the failure card; once the catalog arrives the same stage becomes ready")
    func homeShowsPreparingStageWhileVoiceCatalogPending() throws {
        let (state, catalog) = try Self.homeRealtimeState(selectRealtime: true)
        state.realtimeVoiceCatalog = { nil }
        // Catalog not arrived: the selection used for resolution is nil, but the stored selection is still there.
        #expect(state.realtimeModelSelection(for: nil) == nil)
        #expect(state.realtimeModelSelections[nil] != nil)
        let preparing = HomeHeroStage.resolve(state, catalogState: nil)
        #expect(preparing == .preparing)
        #expect(preparing.showsModelPill)
        #expect(preparing.showsRealtimeDot)

        var taps = 0
        var switched = 0
        let surface = HomeRealtimePreparingStageSurface(onSwitchToTyping: { switched += 1 })
        #expect(surface.idleHint == ChatModelRemovedBanner.voiceCatalogLoadingLabel)
        #expect(surface.failure == nil)
        #expect(surface.showsTypingSwitch)
        #expect(!surface.showsEndButton)
        surface.tapOrb()
        #expect(taps == 0)
        surface.switchToTyping()
        #expect(switched == 1)

        // Catalog load failed: the stage shows the failure card "Couldn't load realtime voice models / Retry"; retry goes through onTap.
        let failed = HomeHeroStage.resolve(state, catalogState: .loadFailed)
        #expect(failed == .catalogFailed)
        #expect(failed.showsModelPill)
        let failure = RealtimeVoiceFailure.catalogUnavailable
        #expect(VoiceConversationCopy.failure(failure) == L10n.tr("Couldn't load realtime voice models", table: .voice))
        #expect(VoiceConversationBarContent.failureButtons(failure) == [.retry])
        let failedSurface = RealtimeIdleStageSurface(failure: failure, onTap: { taps += 1 })
        failedSurface.performFailureAction(.retry)
        #expect(taps == 1)

        // Catalog arrived and still recognizes this realtime model: the same stage becomes ready (the status line switches to "Tap to start speaking").
        state.realtimeVoiceCatalog = { catalog }
        let ready = HomeHeroStage.resolve(state, catalogState: .available(catalog))
        #expect(ready == .ready)
        #expect(ready.showsModelPill)
        #expect(RealtimeIdleStageSurface(onTap: {}).idleHint == VoiceConversationCopy.tapToStartHint)
    }

    @Test("Home has no realtime selection: catalog not arrived / failed / arrived all show the composer card")
    func homeShowsComposerWhenNoRealtimeSelection() throws {
        let (state, catalog) = try Self.homeRealtimeState(selectRealtime: false)
        #expect(state.realtimeModelSelections[nil] == nil)
        #expect(HomeHeroStage.resolve(state, catalogState: .available(catalog)) == .composer)
        state.realtimeVoiceCatalog = { nil }
        for catalogState in [nil, VoiceCatalogState.loadFailed] {
            let stage = HomeHeroStage.resolve(state, catalogState: catalogState)
            #expect(stage == .composer)
            #expect(!stage.showsModelPill)
            #expect(!stage.showsRealtimeDot)
        }
    }

    @Test("Catalog arrived but does not recognize the stored realtime model: switch back to the composer card, and the stored selection is not rewritten (the unavailable-model banner is handled separately)")
    func homeFallsBackToComposerWhenCatalogLacksSelection() throws {
        let (state, _) = try Self.homeRealtimeState(selectRealtime: true)
        let stored = state.realtimeModelSelections[nil]
        #expect(stored != nil)
        state.realtimeVoiceCatalog = { .empty }
        #expect(state.realtimeModelSelection(for: nil) == nil)
        #expect(HomeHeroStage.resolve(state, catalogState: .unavailable) == .composer)
        #expect(state.realtimeModelSelections[nil] == stored)
    }

    @Test("The home pill shows the stored realtime model id in the preparing / catalog-failed / ready stages, never the text model name; the composer card shows the text model")
    func homePillShowsStoredRealtimeModelInEveryStage() throws {
        let (state, catalog) = try Self.homeRealtimeState(selectRealtime: true)
        let stored = try #require(state.realtimeModelSelections[nil])
        let textName = try #require(state.activeModel).model.name
        #expect(textName != stored.model)
        let ready = HomeHeroStage.resolve(state, catalogState: .available(catalog))
        state.realtimeVoiceCatalog = { nil }
        let preparing = HomeHeroStage.resolve(state, catalogState: nil)
        let failed = HomeHeroStage.resolve(state, catalogState: .loadFailed)
        #expect([preparing, failed, ready] == [.preparing, .catalogFailed, .ready])
        for stage in [preparing, failed, ready] {
            #expect(HomeHeroStage.pillModelName(stage: stage, storedSelection: stored, textModelName: textName) == "gpt-realtime")
        }
        #expect(HomeHeroStage.pillModelName(stage: .composer, storedSelection: stored, textModelName: textName) == textName)
        #expect(HomeHeroStage.pillModelName(stage: .composer, storedSelection: nil, textModelName: textName) == textName)

        let home = try source(named: "HomeView.swift")
        let name = try #require(home.slice(from: "private var pillModelName", to: "// MARK: - Conversation Content"))
        #expect(name.contains("HomeHeroStage.pillModelName("))
    }

    @Test("Catalog arrival does not bounce home typing back to the voice stage: it resets only when the stored realtime selection changes")
    func homeTypingSurvivesCatalogArrival() throws {
        let (state, catalog) = try Self.homeRealtimeState(selectRealtime: true)
        state.realtimeVoiceCatalog = { nil }
        let beforeArrival = state.realtimeModelSelections[nil]
        state.realtimeVoiceCatalog = { catalog }
        let afterArrival = state.realtimeModelSelections[nil]
        #expect(state.realtimeModelSelection(for: nil) != nil)
        #expect(!HomeHeroStage.resetsRealtimeTyping(storedBefore: beforeArrival, storedAfter: afterArrival))
        // Switching back to the text model (clearing the home realtime selection): reset.
        state.clearRealtimeModelSelection(for: nil)
        #expect(HomeHeroStage.resetsRealtimeTyping(storedBefore: afterArrival, storedAfter: state.realtimeModelSelections[nil]))
        // Switching to another realtime model: reset.
        let other = try #require(afterArrival).model == "gpt-realtime"
            ? RealtimeModelSelection(providerID: afterArrival!.providerID, providerKind: .openAI, model: "gpt-realtime-mini")
            : afterArrival!
        #expect(HomeHeroStage.resetsRealtimeTyping(storedBefore: afterArrival, storedAfter: other))

        let home = try source(named: "HomeView.swift")
        let reset = try #require(home.slice(from: ".onChange(of: appState.realtimeModelSelections[nil])", to: "}"))
        #expect(reset.contains("HomeHeroStage.resetsRealtimeTyping(storedBefore: before, storedAfter: after)"))
    }

    @Test("On the voice stage, the home pill takes the icon and vendor name of the connection holding the stored realtime selection, not the text model's connection; the composer card takes the text connection")
    func homePillShowsRealtimeSelectionConnection() throws {
        let (state, catalog) = try Self.homeRealtimeState(selectRealtime: true)
        let stored = try #require(state.realtimeModelSelections[nil])
        let textProvider = TestFactories.makeProvider(
            kind: .anthropic, models: [TestFactories.makeModel(id: "claude-text", isDefault: true)]
        )
        state.providers.append(textProvider)
        state.setActiveModel(providerID: textProvider.id, modelID: "claude-text")
        let active = try #require(state.activeModel).provider
        #expect(active.id == textProvider.id)
        #expect(state.realtimeModelSelections[nil] == stored)

        let ready = HomeHeroStage.resolve(state, catalogState: .available(catalog))
        state.realtimeVoiceCatalog = { nil }
        let preparing = HomeHeroStage.resolve(state, catalogState: nil)
        let failed = HomeHeroStage.resolve(state, catalogState: .loadFailed)
        #expect([preparing, failed, ready] == [.preparing, .catalogFailed, .ready])
        for stage in [preparing, failed, ready] {
            let provider = HomeHeroStage.pillProvider(
                stage: stage, storedSelection: stored, provider: state.provider(for:), textProvider: active
            )
            #expect(provider?.id == stored.providerID)
            #expect(provider?.kind == .openAI)
        }
        let composer = HomeHeroStage.pillProvider(
            stage: .composer, storedSelection: stored, provider: state.provider(for:), textProvider: active
        )
        #expect(composer?.id == textProvider.id)

        let pill = try #require(try source(named: "HomeView.swift").slice(
            from: "private func modelSelectorPill(alignment", to: "private var heroStageModelPill"
        ))
        #expect(pill.contains("HomeHeroStage.pillProvider("))
        #expect(!pill.contains("active.provider"))
    }

    /// Home realtime-selection host: the official OpenAI connection plus a catalog listing gpt-realtime; with selectRealtime, home selects it (disclosure accepted).
    private static func homeRealtimeState(selectRealtime: Bool) throws -> (AppState, VoiceCatalog) {
        let state = AppState(seedDemoData: false, sessionUID: "home-stage-\(UUID().uuidString)")
        let provider = TestFactories.makeProvider(kind: .openAI, models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)])
        state.providers = [provider]
        state.setActiveModel(providerID: provider.id, modelID: "gpt-4o")
        let realtimeEntry = VoiceRealtimeEntry(
            model: "gpt-realtime",
            transport: .openaiRealtime,
            path: "/v1/realtime",
            contextWindow: 128_000,
            voices: [VoiceCatalogVoice(id: "marin", isDefault: true)],
            maxSessionSec: nil,
            inputTranscriptionModel: nil,
            isDefault: true
        )
        let catalog = VoiceCatalog(schemaVersion: 2, revision: "home-stage", providers: [
            .openAI: VoiceProviderEntries(realtime: [realtimeEntry])
        ])
        state.realtimeVoiceCatalog = { catalog }
        if selectRealtime {
            let suite = "HomeViewTests-stage-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            state.resolveRealtimeModelDisclosure(
                RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime"),
                for: nil, accepted: true, disclosures: VoiceDisclosureStore(defaults: defaults)
            )
            #expect(state.realtimeModelSelection(for: nil) != nil)
        }
        return (state, catalog)
    }

    @Test("Home realtime typed send: opening from home only plays the realtime session; after ready this sentence goes out, and the conversation is created (the selection follows it) and enters the chat page only when the first message is persisted", .timeLimit(.minutes(1)))
    func heroRealtimeTypedSendOpensConversationAndSendsRealtime() async throws {
        let fixture = try Self.typedSendFixture()
        let state = fixture.state, disclosures = fixture.disclosures, provider = fixture.provider
        let connection = fixture.connection, probe = fixture.probe, session = fixture.session

        // The selection's disclosure is not accepted (revoked): report the disclosure first; no conversation, no connection.
        let pending = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")
        #expect(await HomeRealtimeTypedSend.send("Hello", host: state, session: session, disclosures: disclosures)
            == .needsDisclosure(pending))
        #expect(state.conversations.isEmpty)
        #expect(probe.openedFor.isEmpty)

        disclosures.markAccepted(.openAI, direction: .realtime)
        let homeSelection = try #require(state.realtimeModelSelection(for: nil))
        let outcome = await HomeRealtimeTypedSend.send("  Hello  ", host: state, session: session, disclosures: disclosures)
        #expect(outcome == .sent)
        // Handing off does not pre-create a conversation: the realtime session opens from home (nil); the selection stays on home and the page does not jump.
        #expect(state.conversations.isEmpty)
        #expect(probe.openedFor == [nil])
        #expect(state.realtimeModelSelection(for: nil) == homeSelection)
        #expect(Self.presentedChat(state) == nil)
        // Before ready, the home voice stage observes this session (origin .home); not handed off yet.
        #expect(session.homeVoiceSurface != nil)
        #expect(!session.homeHandedOff)
        let realtime = try #require(session.realtime)

        connection.continuation.yield(.ready)
        connection.continuation.yield(.assistantAudio(itemId: "a1", contentIndex: 0, base64: "AQIDBA==", sampleRateHz: 24_000))
        for await key in realtime.$statusKey.values where key == .speaking { break }
        #expect(connection.texts == ["Hello"])
        // This sentence is actually sent and the first message is persisted: only now is the conversation created and the chat page entered; the home selection follows the conversation.
        let created = try #require(state.conversations.first?.id)
        #expect(state.conversations.count == 1)
        #expect(state.conversation(for: created)?.messages.map(\.text) == ["Hello"])
        #expect(state.realtimeModelSelection(for: created) == homeSelection)
        #expect(state.realtimeModelSelection(for: nil) == nil)
        #expect(Self.presentedChat(state) == created)
        #expect(session.isPresented(in: created))
        // The first persisted message creates the conversation, which hands off: the home voice stage stops observing.
        #expect(session.homeHandedOff)
        #expect(session.homeVoiceSurface == nil)
        #expect(probe.microphoneRequests == 0)
        #expect(!fixture.audio.log.contains("startRealtimeCapture"))
        session.end(.user)
        for _ in 0..<30 { await Task.yield() }
    }

    @Test("Home realtime typed send fails: if the session cannot open (catalog timeout), nothing is handed off; a model_gone end before connecting returns this sentence to home; no conversation is created in either case", .timeLimit(.minutes(1)))
    func heroRealtimeTypedSendFailureKeepsTextAndCreatesNoConversation() async throws {
        // The realtime session cannot open (cold catalog fetch timed out → unknown): not handed off, the draft stays on home; no conversation and no page jump.
        let failing = try Self.typedSendFixture(open: .failed(RealtimeVoiceConversationController.failure(
            category: .unknown, context: RealtimeFailureContext(providerName: "OpenAI", model: "gpt-realtime")
        )))
        failing.disclosures.markAccepted(.openAI, direction: .realtime)
        #expect(await HomeRealtimeTypedSend.send("Hello", host: failing.state, session: failing.session, disclosures: failing.disclosures)
            == .notSent)
        #expect(failing.state.conversations.isEmpty)
        #expect(Self.presentedChat(failing.state) == nil)
        #expect(failing.session.realtimeFailure(in: nil, selection: failing.state.realtimeModelSelection(for: nil))?
            .classification.category == .unknown)

        // Handed off, but the handshake returns 404 (model_gone) before ready: this session ends before a conversation is created, and the sentence is restored to home without leaving an empty conversation.
        let fixture = try Self.typedSendFixture()
        fixture.disclosures.markAccepted(.openAI, direction: .realtime)
        let homeSelection = try #require(fixture.state.realtimeModelSelection(for: nil))
        #expect(await HomeRealtimeTypedSend.send("Hello", host: fixture.state, session: fixture.session, disclosures: fixture.disclosures)
            == .sent)
        // The home voice stage observes this session: the failure lands on it, and after ending it stays in the home stage.
        let surface = try #require(fixture.session.homeVoiceSurface)
        fixture.connection.continuation.finish(throwing: RealtimeHandshakeError(httpStatus: 404))
        while fixture.session.isActive { await Task.yield() }
        #expect(surface.failure?.classification.category == .modelGone)
        #expect(!fixture.session.homeHandedOff)
        let end = try #require(fixture.session.lastEnd)
        #expect(end.conversationID == nil)
        // The input still holds the original text when sent; ending before a conversation is created leaves it as is, without concatenating it twice.
        #expect(HomeRealtimeTypedSend.outcome(after: end) == .endedBeforePersist)
        #expect(HomeRealtimeTypedSend.inputText("Hello", sent: "Hello", outcome: HomeRealtimeTypedSend.outcome(after: end)) == "Hello")
        #expect(fixture.connection.texts.isEmpty)
        #expect(fixture.state.conversations.isEmpty)
        #expect(Self.presentedChat(fixture.state) == nil)
        #expect(fixture.state.realtimeModelSelection(for: nil) == homeSelection)
        #expect(fixture.session.realtimeFailure(in: nil, selection: homeSelection)?.classification.category == .modelGone)
        // Ending after the conversation was created (this sentence persisted) does not restore it.
        let delivered = VoiceConversationSession.EndDelivery(token: UUID(), conversationID: UUID(), draft: nil)
        #expect(HomeRealtimeTypedSend.outcome(after: delivered) == .persisted)
        #expect(HomeRealtimeTypedSend.inputText("Hello", sent: "Hello", outcome: HomeRealtimeTypedSend.outcome(after: delivered)).isEmpty)
    }

    @Test("Home realtime typed input: sending does not clear it, and it clears only when persisted (conversation created); ending before persist keeps the original text without concatenation; text edited while waiting is not cleared on persist")
    func heroRealtimeTypedInputClearsOnlyOnPersist() throws {
        let viewSource = try source(named: "HomeView.swift")
        // .sent only records the in-flight sentence and does not clear the input.
        let sentBranch = try #require(viewSource.range(of: "case .sent:"))
        let afterSent = viewSource[sentBranch.upperBound...].prefix(200)
        #expect(!afterSent.contains("heroText = \"\""))
        #expect(afterSent.contains("heroRealtimeTypedInFlight = trimmed"))
        // The first persisted message creates the conversation (homeHandedOff), which settles the in-flight sentence.
        #expect(viewSource.contains(".onChange(of: VoiceConversationSession.shared.homeHandedOff)"))

        // On persist: clear if the input still holds this sentence (including surrounding whitespace).
        #expect(HomeRealtimeTypedSend.inputText("Hello", sent: "Hello", outcome: .persisted).isEmpty)
        #expect(HomeRealtimeTypedSend.inputText("  Hello \n", sent: "Hello", outcome: .persisted).isEmpty)
        // The user edited the input while waiting: persisting does not clear the new text.
        #expect(HomeRealtimeTypedSend.inputText("Hello again", sent: "Hello", outcome: .persisted) == "Hello again")
        #expect(HomeRealtimeTypedSend.inputText("World", sent: "Hello", outcome: .persisted) == "World")
        // Ended before creation / could not open / disclosure declined / left: the original text stays, without being concatenated again.
        for kind in [RealtimeModelPolicy.TypedSendOutcomeKind.endedBeforePersist, .openFailed, .disclosureDeclined, .hostLeft] {
            #expect(HomeRealtimeTypedSend.inputText("Hello", sent: "Hello", outcome: kind) == "Hello")
            #expect(HomeRealtimeTypedSend.inputText("Hello World", sent: "Hello", outcome: kind) == "Hello World")
        }
    }

    @Test("Home realtime typed in-flight guard: after a hand-off and before settlement, the send key and dictation's transcribe-and-send do not hand off again, and the in-flight sentence is not overwritten; after persist or end, sending is allowed again", .timeLimit(.minutes(1)))
    func heroRealtimeTypedInFlightBlocksResend() async throws {
        // Gate: nothing is handed off while sending or while a sentence is in flight; sending is allowed again only after settlement (in-flight cleared).
        #expect(HomeRealtimeTypedSend.canHandOff(isSending: false, inFlight: nil))
        #expect(!HomeRealtimeTypedSend.canHandOff(isSending: true, inFlight: nil))
        #expect(!HomeRealtimeTypedSend.canHandOff(isSending: false, inFlight: "Hello"))
        #expect(!HomeRealtimeTypedSend.canHandOff(isSending: true, inFlight: "Hello"))

        // The send key, dictation's "transcribe and send", and the dictation host all pass through this gate; the send key is disabled while in flight.
        let viewSource = try source(named: "HomeView.swift")
        let sendBody = try #require(viewSource.slice(from: "private func sendFromHero() async {", to: "pendingHeroVoiceStart.decline()"))
        #expect(sendBody.contains("guard canHandOffFromHero"))
        #expect(viewSource.contains("canSend: { canHandOffFromHero }"))
        #expect(viewSource.contains("DictationInputSwitcher(controller: controller, canSend: canHandOffFromHero)"))
        #expect(viewSource.contains(".disabled(!actions.sendEnabled || heroRealtimeTypedInFlight != nil)"))
        #expect(viewSource.contains("HomeRealtimeTypedSend.canHandOff(isSending: isSendingFromHero, inFlight: heroRealtimeTypedInFlight)"))

        // Production path: after one sentence is handed off, the session is in flight; a second sentence is not handed off and the connection carries only the first.
        let fixture = try Self.typedSendFixture()
        fixture.disclosures.markAccepted(.openAI, direction: .realtime)
        #expect(await HomeRealtimeTypedSend.send("Hello", host: fixture.state, session: fixture.session, disclosures: fixture.disclosures)
            == .sent)
        #expect(await HomeRealtimeTypedSend.send("World", host: fixture.state, session: fixture.session, disclosures: fixture.disclosures)
            == .notSent)
        // This session ends before a conversation is created (settled): once in-flight is cleared, the same sentence can be sent again.
        fixture.connection.continuation.finish(throwing: RealtimeHandshakeError(httpStatus: 404))
        while fixture.session.isActive { await Task.yield() }
        let end = try #require(fixture.session.lastEnd)
        #expect(HomeRealtimeTypedSend.outcome(after: end) == .endedBeforePersist)
        #expect(HomeRealtimeTypedSend.canHandOff(isSending: false, inFlight: nil))
        #expect(!fixture.connection.texts.contains("World"))
    }

    private struct TypedSendFixture {
        let state: AppState
        let provider: Provider
        let disclosures: VoiceDisclosureStore
        let connection: RealtimeVoiceConversationControllerTests.FakeConnection
        let audio: RealtimeVoiceConversationControllerTests.FakeAudio
        let probe: TypedSendProbe
        let session: VoiceConversationSession
    }

    /// Host for home realtime typed send: home selects gpt-realtime (disclosure not accepted); the realtime session persists through the production AppState sink.
    /// When open is given, the opening returns it directly (failure path).
    private static func typedSendFixture(open: RealtimeVoiceStart? = nil) throws -> TypedSendFixture {
        let state = AppState(seedDemoData: false, sessionUID: "home-realtime-typed-\(UUID().uuidString)")
        let provider = TestFactories.makeProvider(kind: .openAI, models: [TestFactories.makeModel(id: "gpt-4o", isDefault: true)])
        state.providers = [provider]
        state.setActiveModel(providerID: provider.id, modelID: "gpt-4o")
        // The conversation's realtime selection is derived from the conversation model field plus the cached catalog: the catalog must list this realtime model.
        let realtimeEntry = VoiceRealtimeEntry(
            model: "gpt-realtime",
            transport: .openaiRealtime,
            path: "/v1/realtime",
            contextWindow: 128_000,
            voices: [VoiceCatalogVoice(id: "marin", isDefault: true)],
            maxSessionSec: nil,
            inputTranscriptionModel: nil,
            isDefault: true
        )
        let catalog = VoiceCatalog(schemaVersion: 2, revision: "home", providers: [
            .openAI: VoiceProviderEntries(realtime: [realtimeEntry])
        ])
        state.realtimeVoiceCatalog = { catalog }
        let suiteName = "HomeViewTests-realtime-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let disclosures = VoiceDisclosureStore(defaults: defaults)
        let acceptedSuite = "HomeViewTests-realtime-accepted-\(UUID().uuidString)"
        let acceptedDefaults = try #require(UserDefaults(suiteName: acceptedSuite))
        acceptedDefaults.removePersistentDomain(forName: acceptedSuite)
        let pending = RealtimeModelSelection(providerID: provider.id, providerKind: .openAI, model: "gpt-realtime")
        state.resolveRealtimeModelDisclosure(
            pending, for: nil, accepted: true, disclosures: VoiceDisclosureStore(defaults: acceptedDefaults)
        )

        let connection = RealtimeVoiceConversationControllerTests.FakeConnection()
        let audio = RealtimeVoiceConversationControllerTests.FakeAudio()
        let plan = try Self.realtimePlan()
        let probe = TypedSendProbe()
        var deps = SessionProbe().dependencies()
        deps.grantMicrophone = {
            probe.microphoneRequests += 1
            return true
        }
        // Same as production: the opening's selection is read from the host, and in-stage failures use it to identify this page.
        deps.realtimeSelection = { conversationID, host in (host as? AppState)?.realtimeModelSelection(for: conversationID) }
        deps.makeRealtime = { [weak state] conversationID, _ in
            probe.openedFor.append(conversationID)
            if let open { return open }
            let attribution = RealtimeVoiceAttribution(
                providerID: provider.id, providerKind: .openAI, providerName: "OpenAI", model: "gpt-realtime"
            )
            guard let state else { return .cascade(toast: nil) }
            return .realtime(RealtimeVoiceSessionParts(
                connection: connection,
                audio: RealtimeVoiceAudio(audio, route: { .speaker }),
                plan: plan,
                sink: AppStateRealtimeTranscriptSink.appState(state, conversationID: conversationID, attribution: attribution),
                attribution: attribution
            ))
        }
        return TypedSendFixture(
            state: state, provider: provider, disclosures: disclosures, connection: connection, audio: audio,
            probe: probe, session: VoiceConversationSession(dependencies: deps)
        )
    }

    /// Records for the typed-send cases: which conversations' realtime sessions were opened, and how many microphone requests were made.
    private final class TypedSendProbe {
        var openedFor: [UUID?] = []
        var microphoneRequests = 0
    }

    /// Plan produced by the production path: ChatMessage → realtimeSessionInput → assembleRealtimeSession → PlannedRealtimeSession.
    private static func realtimePlan() throws -> PlannedRealtimeSession {
        let snapshot = ChatRequestSnapshot(
            conversation: ChatRequestConversationSnapshot(id: UUID(), useMemory: false, skillID: nil, instructions: "Be brief."),
            messages: [TestFactories.makeMessage(role: .user, text: "Typed question")],
            preferences: ChatRequestPreferencesSnapshot(),
            skill: nil,
            sendPath: .send(excludingMessageID: nil)
        )
        let sessionInput = ChatRequestBuilder.realtimeSessionInput(
            snapshot, contextWindow: 128_000, currentSessionId: "rt-1", sessionMessageIds: [], checkpoint: nil
        )
        return try #require(PlannedRealtimeSession.from(ContextAssembler.assembleRealtimeSession(sessionInput)))
    }

    /// Conversation id of the chat page currently shown by navigation (top of the compact stack / regular right pane).
    private static func presentedChat(_ state: AppState) -> UUID? {
        if case .chat(let id) = state.navigation.path.last { return id }
        return state.navigation.chatDetail.conversationID
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
        // The light violet shadow follows the palette; the default palette still resolves to the hand-tuned #8B5CF6
        #expect(Self.lightDefaultRGBA(lightIdle.ambientShadow.color) == Self.rgba(0x8B5CF6, alpha: 0.08))
        #expect(lightIdle.ambientShadow.radius == 14 && lightIdle.ambientShadow.y == 10)

        let lightFocused = AuroraHeroCardAppearance.resolve(isDark: false, focused: true)
        #expect(lightFocused.contactShadow == .none)
        #expect(Self.lightDefaultRGBA(lightFocused.ambientShadow.color) == Self.rgba(0x8B5CF6, alpha: 0.16))
        #expect(lightFocused.ambientShadow.radius == 20 && lightFocused.ambientShadow.y == 14)
    }

    /// The RGBA (0-255, rounded) a dynamic color resolves to under "light + default palette".
    private static func lightDefaultRGBA(_ color: Color) -> [Int] {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = .light
            traits.oriveoDarkPalette = OriveoDarkPaletteChoice.defaultID
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { Int(($0 * 255).rounded()) }
    }

    private static func rgba(_ hex: UInt, alpha: CGFloat) -> [Int] {
        [Int((hex >> 16) & 0xFF), Int((hex >> 8) & 0xFF), Int(hex & 0xFF), Int((alpha * 255).rounded())]
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

    @Test("Home entry row: notes card keeps its fixed size, with the paper stack hidden from VoiceOver")
    func notesEntryFollowsFinalDesign() throws {
        let cardSource = try source(named: "HomeNotesEntryCard.swift")
        let viewSource = try source(named: "HomeView.swift")
        #expect(HomeEntryCardStyle.height == 150)
        #expect(HomeEntryCardStyle.cornerRadius == 22)
        #expect(HomeEntryCardStyle.spacing == 12)
        #expect(viewSource.contains("HStack(spacing: HomeEntryCardStyle.spacing)"))
        #expect(cardSource.contains(".modifier(HomeEntryCardChrome("))
        // Paper stack illustration, not the old notebook glyph on the aurora surface
        #expect(!cardSource.contains("NotesNotebookLine"))
        #expect(!cardSource.contains("AuroraHeroSurface"))
        #expect(cardSource.contains("private var paperStack"))
        #expect(cardSource.contains(".accessibilityHidden(true)"))
        // Fixed colours: no theme palette on the card
        #expect(!cardSource.contains("AuroraTheme.Colors"))
    }

    @Test("Home entry cards: no outer hairline and no pink sheet outlines; dark surface lifted to separate from the page")
    func homeEntryCardsHaveNoOuterStroke() throws {
        let cardSource = try source(named: "HomeNotesEntryCard.swift")
        let chrome = try #require(cardSource.slice(from: "struct HomeEntryCardChrome", to: "/// Pushpin on the front notes sheet"))
        let sheets = try #require(cardSource.slice(from: "private var paperStack", to: "private var previewLine"))
        #expect(!chrome.contains("strokeBorder"))
        #expect(chrome.contains("0x1F1D24"))
        #expect(!sheets.contains("strokeBorder"))
    } //

    @Test("Pushpin: round head about 11pt, at least 3pt of needle showing, tilted up-left, head pokes past the sheet top")
    func pushpinHasRoundHeadAndVisibleNeedle() {
        #expect((9...13).contains(HomeNotesPushpin.headDiameter))
        #expect(HomeNotesPushpin.needleLength - HomeNotesPushpin.headDiameter / 2 >= 3)
        #expect((15...35).contains(HomeNotesPushpin.tiltDegrees))
        #expect(HomeNotesPushpin.pierce == CGPoint(x: 61, y: 10))
        let center = HomeNotesPushpin.headCenter(pierce: HomeNotesPushpin.pierce)
        let radians = 24.0 * Double.pi / 180
        let expected = CGPoint(x: 61 - 9 * sin(radians), y: 10 - 9 * cos(radians))
        #expect(abs(center.x - expected.x) < 0.01, "head centre x \(center.x) vs \(expected.x)")
        #expect(abs(center.y - expected.y) < 0.01, "head centre y \(center.y) vs \(expected.y)")
        #expect(center.y - HomeNotesPushpin.headDiameter / 2 < 0, "head must rise above the sheet top edge")
        #expect(HomeNotesPushpin.headColors.count == 3)
        #expect(HomeNotesPushpin.headStops.count == HomeNotesPushpin.headColors.count)
        func luminance(_ hex: UInt32) -> Double {
            let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        if let first = HomeNotesPushpin.headColors.first, let last = HomeNotesPushpin.headColors.last {
            #expect(luminance(first) > luminance(last), "head gradient must run light to dark")
        }
    } //

    @Test("Pushpin casts a down-right shadow in light and dark, deeper in dark, with a visible highlight")
    func pushpinCastsShadowInBothAppearances() {
        for isDark in [false, true] {
            #expect(HomeNotesPushpin.shadowOpacity(isDark) > 0, "shadow must be visible (dark: \(isDark))")
            #expect(HomeNotesPushpin.highlightOpacity(isDark) >= 0.6, "highlight must be visible (dark: \(isDark))")
        }
        #expect(HomeNotesPushpin.shadowOpacity(true) > HomeNotesPushpin.shadowOpacity(false))
        #expect(HomeNotesPushpin.shadowOffset.width > 0)
        #expect(HomeNotesPushpin.shadowOffset.height > 0)
    } //

    @Test("Notes entry card no longer carries washi tape")
    func notesEntryHasNoWashiTape() throws {
        let cardSource = try source(named: "HomeNotesEntryCard.swift")
        #expect(!cardSource.contains("WashiTape"))
    } //

    @Test("Notes entry subtitle reads recently edited only when the latest note has a title")
    func notesEntrySubtitleOnlyWithTitledLatestNote() {
        #expect(HomeNotesEntryCard.subtitle(count: 12, latestTitle: "Trip memo") == L10n.tr("skills.home.notesRecent", table: .skills))
        #expect(HomeNotesEntryCard.subtitle(count: 12, latestTitle: "Trip memo") != "skills.home.notesRecent")
        #expect(HomeNotesEntryCard.subtitle(count: 3, latestTitle: "") == nil)
        #expect(HomeNotesEntryCard.subtitle(count: 0, latestTitle: nil) == nil)
        #expect(HomeNotesEntryCard.subtitle(count: 0, latestTitle: "stale title") == nil)
    }

    @Test("the Notes entry shares the hero material and uses the gradient notebook glyph, with no chevron, badge, watermark or icon tile")
    func darkHeroKeepsCardFlatAndPutsAuroraOnItsTopEdge() throws {
        // A directional glow inside the card, high saturation in the dark areas and grey text whose hue
        // did not match the card made the dark card look muddy. The surface now keeps only an even
        // top-to-bottom fill and the aurora moves to the top edge and outside the card.
        let themeSource = try source(named: "AuroraTheme.swift")
        #expect(themeSource.contains("colors: [Color.darkPalette(\\.surfaceRaised), Self.darkBaseBottom]"))
        #expect(!themeSource.contains("angleDegrees: 150"), "the dark surface no longer uses a 150° diagonal gradient")
        #expect(!themeSource.contains("Color(hex: 0x818CF8"), "no directional glow inside the dark card")
        // The pill is opaque; the grey text inside the hero shares the card's hue and is not the global tertiary
        #expect(themeSource.contains("static let pillFill = Color.brand(light: \\.pill, dark: \\.surfaceRaised)"))  // light = this palette's pill (#F3F0FA for the default palette)
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
        // The notes entry card no longer wears the aurora crown: home entry cards use fixed colours
        let cardSource = try source(named: "HomeNotesEntryCard.swift")
        #expect(!cardSource.contains("AuroraCrownRim"))
        #expect(!cardSource.contains("AuroraCrownHalo"))
    }

    @Test("the Notes glyph asset has no zero-height binder ticks")
    func conversationGroupsHaveNoDividers() throws {
        let homeSource = try source(named: "HomeView.swift")
        let listSource = try #require(homeSource.slice(
            from: "private var conversationContent",
            to: "private func conversationButton"
        ))
        #expect(!listSource.contains("Divider()"))
        #expect(listSource.contains("AuroraGroupedRowSurface(isFirst: isFirst, isLast: isLast)"))
        #expect(!listSource.contains("VStack(alignment: .leading, spacing: 22)"))
        #expect(!listSource.contains("conversationGroupCard"))

        let folderSource = try #require(try source(named: "FolderRow.swift").slice(
            from: "private var folderContent",
            to: "private func conversationInFolder"
        ))
        #expect(!folderSource.contains("Divider()"))
        #expect(folderSource.contains("AuroraGroupedCard {"))
        #expect(folderSource.contains("conversations.prefix(homeFolderInlineLimit)"))
        #expect(homeFolderInlineLimit == 10)
        #expect(homeFolderInlineLimit == homeEarlierPageSize)
        #expect(folderSource.contains("Show More (%d)"))
        #expect(folderSource.contains(".folderDetail(folderID: folder.id)"))
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
        #expect(homeListGroupSpacing == 22)
        #expect(homeListFirstBlockTopSpacing == 26)
        #expect(homeSource.contains("homeListGroupSpacing"))
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
    func modelPillShowsRealtimeDotWhenRealtimeSelected() throws {
        let pillSource = try #require(try source(named: "HomeView.swift").slice(
            from: "private var modelSelectorPill", to: "/// Model pill at the top of the voice dock"
        ))
        #expect(pillSource.contains("let realtimeSelected = appState.realtimeModelSelection(for: nil) != nil"))
        let beforeName = try #require(pillSource.slice(from: "if realtimeSelected {", to: "Text(pillModelName)"))
        #expect(beforeName.contains("RealtimeModelDot()"))
        #expect(pillSource.components(separatedBy: "RealtimeModelDot()").count - 1 == 1)
    }

    @Test("the hero input has an accessibility name and the decorative placeholder is hidden from VoiceOver")
    func modelPillReadsRealtimeVoiceWhenRealtimeSelected() throws {
        #expect(ChatToolbar.modelNameAccessibilityValue(realtime: true) == L10n.tr("Realtime Voice", table: .voice))
        let pillSource = try #require(try source(named: "HomeView.swift").slice(
            from: "private var modelSelectorPill", to: "/// Model pill at the top of the voice dock"
        ))
        let name = try #require(pillSource.slice(from: "Text(pillModelName)", to: "if let active {"))
        #expect(name.contains(".accessibilityValue(ChatToolbar.modelNameAccessibilityValue(realtime: realtimeSelected))"))
        #expect(!name.contains(".accessibilityLabel("))
    }

    @Test("the hero input has an accessibility name and the decorative placeholder is hidden from VoiceOver")
    func heroInputAccessibility() throws {
        let inputSource = try #require(try source(named: "HomeView.swift").slice(
            from: "private func heroComposerInput",
            to: "/// The model selector chip"
        ))
        // The input is a UIKit view (ComposerTextView) that takes the accessibility name as a parameter and sets it on the UITextView.
        // During dictation the accessibility name reads "Listening…" while the placeholder is composerPlaceholder otherwise
        #expect(inputSource.contains("ChatComposerBar.listeningPlaceholder(phase: phase) ?? composerPlaceholder"))
        #expect(inputSource.contains("accessibilityLabel: placeholder"))
        #expect(inputSource.contains(".accessibilityHidden(true)"))
    }

    @Test("the idle hero cursor uses a single discrete animation layer")
    func heroIdleCursorUsesOneDiscreteLayer() throws {
        let homeSource = try source(named: "HomeView.swift")
        let cursorSource = try #require(homeSource.slice(
            from: "private func heroComposerInput",
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

    @Test("the home timeline flattens groups into LazyVStack rows; 40 search hits are one header plus 40 rows")
    func conversationListItemsAreFlatPerRow() {
        let conversations = (0..<40).map { index in
            TestFactories.makeConversation(
                title: "Conversation \(index + 1)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let today = Array(conversations.prefix(12))
        let earlier = HomeConversationSectionState(
            section: .earlier,
            conversations: Array(conversations.dropFirst(12).prefix(10)),
            remainingCount: 8
        )

        let items = makeHomeConversationListItems(
            isSearching: false,
            searchConversations: [],
            folders: [],
            pinned: [],
            groups: [
                HomeConversationSectionState(section: .today, conversations: today, remainingCount: 0),
                earlier,
            ]
        )

        let conversationCount = items.filter {
            if case .conversation = $0 { return true }
            return false
        }.count
        #expect(conversationCount == 22)
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(items.contains { if case .sectionHeader(kind: .timeline(.today), _, _) = $0 { return true }; return false })
        #expect(items.contains { if case .showMore(remaining: 8) = $0 { return true }; return false })
        #expect(items.contains { item in
            if case .showMore = item {
                return item.topSpacing == homeListShowMoreTopSpacing
            }
            return false
        })
        #expect(homeListShowMoreTopSpacing == 8)
        #expect(!items.contains { if case .folder(_, _) = $0 { return true }; return false })

        let searchItems = makeHomeConversationListItems(
            isSearching: true,
            searchConversations: conversations,
            folders: [],
            pinned: [],
            groups: []
        )
        #expect(searchItems.count == 41)
        #expect(searchItems.first == .sectionHeader(
            kind: .search,
            conversations: conversations,
            topSpacing: homeListFirstBlockTopSpacing
        ))
        if case .conversation(_, let showFolderTag, let isFirst, let isLast) = searchItems[1] {
            #expect(showFolderTag)
            #expect(isFirst)
            #expect(!isLast)
        } else {
            Issue.record("the first search row should be a conversation")
        }
        if case .conversation(_, _, _, let isLast) = searchItems.last {
            #expect(isLast)
        } else {
            Issue.record("the last search row should be a conversation")
        }
    }

    @Test("the home LazyVStack conversation ForEach is not wrapped in a table-wide VStack")
    func conversationForEachIsLazyStackChild() throws {
        let homeSource = try source(named: "HomeView.swift")
        let bodySource = try #require(homeSource.slice(
            from: "var body: some View {",
            to: "// MARK: - Header"
        ))
        #expect(bodySource.contains("LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders])"))
        #expect(bodySource.contains("conversationContent"))
        #expect(!bodySource.contains("conversationContent\n                    .padding(.top, 26)"))

        let listSource = try #require(homeSource.slice(
            from: "private var conversationContent",
            to: "private func conversationButton"
        ))
        #expect(listSource.contains("ForEach(items) { item in"))
        #expect(listSource.contains("homeListItemView(item)"))
        #expect(!listSource.contains("AuroraGroupedCard {"))
        #expect(!listSource.contains("VStack(spacing: 0) {\n                ForEach(conversations)"))
    }

    @Test("a conversation that is both pinned and in the timeline still has unique ForEach ids")
    func pinnedAndTimelineConversationIdsDoNotCollide() {
        let conversation = TestFactories.makeConversation(title: "Pinned and today")
        let items = makeHomeConversationListItems(
            isSearching: false,
            searchConversations: [],
            folders: [],
            pinned: [conversation],
            groups: [
                HomeConversationSectionState(section: .today, conversations: [conversation], remainingCount: 0)
            ]
        )
        let ids = items.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.filter { $0.contains(conversation.id.uuidString) }.count == 2)
    }

    @Test("grouped-row stroke shares the continuous corner with clipShape and draws inner edges outside the row")
    func groupedRowOutlineOmitsInnerEdges() throws {
        let themeSource = try source(named: "AuroraTheme.swift")
        let surface = try #require(themeSource.slice(
            from: "struct AuroraGroupedRowSurface",
            to: "// MARK: - Greeting"
        ))
        #expect(surface.contains("style: .continuous"))
        #expect(surface.contains(".strokeBorder(AuroraTheme.Colors.groupCardBorder, lineWidth: 1)"))
        #expect(surface.contains(".clipShape(Rectangle())"))
        #expect(!surface.contains("path.move(to: CGPoint(x: rect.width, y: rect.height - botR))"))
        #expect(!surface.contains("addArc("))
    }

    @Test("grouped-row stroke geometry: a single row stays in bounds; middle/first/last draw inner edges outside")
    func groupedRowOutlineGeometryExtendsInnerEdgesOutsideRow() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 80)

        let single = AuroraGroupedRowOutline(isFirst: true, isLast: true, radius: 20).path(in: rect)
        let singleBox = single.cgPath.boundingBoxOfPath
        #expect(singleBox.minX >= -0.5)
        #expect(singleBox.minY >= -0.5)
        #expect(singleBox.maxX <= 200.5)
        #expect(singleBox.maxY <= 80.5)
        #expect(single.contains(CGPoint(x: 100, y: 40)))
        #expect(!single.contains(CGPoint(x: 1, y: 1)), "the continuous-corner tip should sit outside the path")

        let middle = AuroraGroupedRowOutline(isFirst: false, isLast: false, radius: 20).path(in: rect)
        let middleBox = middle.cgPath.boundingBoxOfPath
        #expect(middleBox.minY < rect.minY)
        #expect(middleBox.maxY > rect.maxY)

        let first = AuroraGroupedRowOutline(isFirst: true, isLast: false, radius: 20).path(in: rect)
        #expect(first.cgPath.boundingBoxOfPath.maxY > rect.maxY)
        #expect(first.cgPath.boundingBoxOfPath.minY >= -0.5)

        let last = AuroraGroupedRowOutline(isFirst: false, isLast: true, radius: 20).path(in: rect)
        #expect(last.cgPath.boundingBoxOfPath.minY < rect.minY)
        #expect(last.cgPath.boundingBoxOfPath.maxY <= 80.5)
    }

    @Test("home_send_button_has_send_a11y_label: the home ↑ reads 'Send' to screen readers, reusing the existing Send string key")
    func home_send_button_has_send_a11y_label() throws {
        let buttonSource = try #require(try source(named: "HomeView.swift").slice(
            from: "private var auroraSendButton: some View",
            to: "/// Voice entry on home: make sure a model exists"
        ))
        #expect(buttonSource.contains(".accessibilityLabel(L10n.tr(\"Send\", table: .notices))"))

        // This key already has 16 languages in the Notices table; the zh-Hans value is checked below
        let catalogURL = try sourceRoot().appendingPathComponent("Oriveo").appendingPathComponent("Notices.xcstrings")
        let catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let send = try #require(strings["Send"] as? [String: Any])
        let localizations = try #require(send["localizations"] as? [String: Any])
        let zhHans = try #require((localizations["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any])
        #expect(zhHans["value"] as? String == "\u{53D1}\u{9001}")
        #expect(localizations.count == 16)
    }

    @Test("chat_send_button_has_send_a11y_label: the chat page primary key reads 'Send' to screen readers in the ↑ state, the same key as home")
    func chat_send_button_has_send_a11y_label() throws {
        let barURL = try sourceRoot().appendingPathComponent("Oriveo/Features/Chat/ChatComposerBar.swift")
        let barSource = try String(contentsOf: barURL, encoding: .utf8)
        // While waiting for the catalog the label reads "Loading model"; otherwise ≋ reads startA11y and ↑ reads "Send"
        #expect(barSource.contains(": (isVoice ? Text(VoiceConversationCopy.startA11y) : Text(L10n.tr(\"Send\", table: .notices)))"))
        #expect(barSource.contains("? Text(ChatModelRemovedBanner.voiceCatalogLoadingLabel)"))
    }

    /// `ios/Oriveo` (the test file sits under OriveoTests/Features/Home)
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
