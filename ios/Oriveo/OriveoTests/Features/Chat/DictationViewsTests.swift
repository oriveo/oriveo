import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Oriveo

/// The dictation recording bar: button and accessibility names, only ✕ while busy, and the busy-state copy.
@MainActor
@Suite("Dictation capsule", .sharedProcessState)
struct DictationViewsTests {

    private func voice(_ key: String) -> String { L10n.tr(key, table: .voice) }

    private func bar(_ mode: DictationInputRowMode, canSend: Bool = true) -> ComposerDictationBar {
        ComposerDictationBar(
            mode: mode,
            levelMeter: DictationLevelMeter(),
            canSend: canSend,
            onDiscard: {},
            onTranscribe: {},
            onTranscribeAndSend: {}
        )
    }

    private func yieldMainActor(for seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Run a UIHostingController inside a window through layout and return the laid-out height.
    private func layOut(_ view: ComposerDictationBar) async throws -> CGFloat {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        let host = UIHostingController(rootView: view)
        // Does not count the window safe area; measures the view's own height.
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await yieldMainActor(for: 0.3)
        return host.sizeThatFits(in: CGSize(width: 390, height: 200)).height
    }

    @Test("recording and transcribing (cloud / system) all lay out in a UIHostingController, with the capsule 56pt high")
    func barLaysOutInEveryMode() async throws {
        let modes: [DictationInputRowMode] = [
            .recording(startedAt: Date().addingTimeInterval(-65)),
            .busy(.transcribing(engineName: "My Groq")),
            .busy(.transcribing(engineName: nil)),
        ]
        for mode in modes {
            let height = try await layOut(bar(mode))
            #expect(height == ComposerDictationBar.capsuleHeight, "\(mode) layout height \(height)")
        }
        let disabledSend = try await layOut(bar(.recording(startedAt: .now), canSend: false))
        #expect(disabledSend == ComposerDictationBar.capsuleHeight)
    }

    @Test("visual items 2 and 4: capsule 56 high, corner radius 28; send button a 56 circle, 10 from the capsule; \"Done\" 40 high")
    func capsuleAndSendButtonSizes() async throws {
        #expect(ComposerDictationBar.capsuleHeight == 56)
        #expect(ComposerDictationBar.capsuleCornerRadius == 28)
        #expect(ComposerDictationBar.sendButtonSize == 56)
        #expect(ComposerDictationBar.sendButtonSpacing == 10)
        #expect(ComposerDictationBar.doneHeight == 40)
        try await withHosted(bar(.recording(startedAt: .now))) { root in
            let send = try #require(element(voice("Transcribe and Send"), in: root))
            #expect(send.accessibilityFrame.width == 56, "\(send.accessibilityFrame)")
            #expect(send.accessibilityFrame.height == 56, "\(send.accessibilityFrame)")
            let discard = try #require(element(voice("Discard Recording"), in: root))
            #expect(discard.accessibilityFrame.maxX <= send.accessibilityFrame.minX - 10)
        }
    }

    @Test("visual item 3: 22 waveform bars take the last 22 cells of the level meter (newest on the right), the height formula, and the color-ring segments")
    func waveformBarsAndHeights() {
        #expect(DictationWaveform.barCount == 22)
        #expect(DictationLevelMeter.capacity == 24)
        let levels: [Float] = (0..<24).map { Float($0) / 23 }
        let shown = DictationWaveform.displayed(levels)
        #expect(shown.count == 22)
        #expect(shown == Array(levels.suffix(22)))
        let short = DictationWaveform.displayed([0.5, 1])
        #expect(short.count == 22)
        #expect(short.suffix(2) == [0.5, 1])
        #expect(short.prefix(20).allSatisfy { $0 == 0 })

        let heights = DictationWaveform.heights(for: levels)
        #expect(heights.count == 22)
        for (i, v) in shown.enumerated() {
            let expected = 4 + (22 * min(1, max(0, Double(v) * (0.8 + 0.2 * sin(1.9 * Double(i)))))).rounded()
            #expect(heights[i] == CGFloat(expected), "bar \(i)")
        }
        #expect(DictationWaveform.barHeight(level: 0, index: 5) == 4)
        #expect(DictationWaveform.barHeight(level: 5, index: 1) == 26)
        #expect(DictationWaveform.ringIndex(for: 0) == 0)
        #expect(DictationWaveform.ringIndex(for: 5) == 0)
        #expect(DictationWaveform.ringIndex(for: 6) == 1)
        #expect(DictationWaveform.ringIndex(for: 21) == 3)
        #expect(DictationWaveform.ring.count == 5)
    }

    @Test("visual item 1: flowing border 2pt, one revolution per 6 s; under reduced motion it does not rotate and stays at 24°")
    func flowBorderStillUnderReduceMotion() {
        #expect(DictationFlowBorder.lineWidth == 2)
        #expect(DictationFlowBorder.period == 6)
        #expect(DictationFlowBorder.restingAngle == .degrees(24))
        #expect(DictationFlowBorder.rotation(reduceMotion: true) == nil)
        #expect(DictationFlowBorder.rotation(reduceMotion: false) != nil)
    }

    @Test("recording bar buttons are ✕ / Transcribe / ↑, with the specified accessibility names")
    func recordingControlsAndLabels() {
        #expect(ComposerDictationBar.controls(for: .recording(startedAt: .now))
                == [.discard, .transcribe, .transcribeAndSend])
        #expect(DictationBarControl.discard.accessibilityLabel == voice("Discard Recording"))
        #expect(DictationBarControl.transcribe.accessibilityLabel == voice("Done"))
        #expect(DictationBarControl.transcribeAndSend.accessibilityLabel == voice("Transcribe and Send"))
        for control in DictationBarControl.allCases {
            #expect(!control.accessibilityLabel.isEmpty)
        }
    }

    @Test("while busy only ✕ remains, with no Transcribe or ↑; the normal composer row does not draw the recording bar")
    func busyKeepsOnlyDiscard() {
        for activity: DictationBusyActivity in [.transcribing(engineName: "My Groq"),
                                                .transcribing(engineName: nil)] {
            let controls = ComposerDictationBar.controls(for: .busy(activity))
            #expect(controls == [.discard])
            #expect(!controls.contains(.transcribe))
            #expect(!controls.contains(.transcribeAndSend))
        }
        #expect(ComposerDictationBar.controls(for: .normal).isEmpty)
    }

    @Test("busy-state copy (preparing / cloud with the connection name / system) comes from the state mapping")
    func busyCaptions() {
        let cloud = DictationEngineInfo(displayName: "My Groq", providerID: UUID())
        func caption(_ state: DictationState, _ info: DictationEngineInfo?) -> String? {
            guard case .busy(let activity) = DictationPresentation.inputRow(for: state, engineInfo: info) else { return nil }
            return activity.localizedCaption
        }
        #expect(caption(.transcribing(.insert), cloud) == L10n.format(voice("Transcribing · %@"), "My Groq"))
        #expect(caption(.transcribing(.send), nil) == voice("Transcribing"))
    }

    // MARK: - Toggle container and microphone key

    private static let idleMarker = "DictationViewsTests.idle"
    private static let buttonsMarker = "DictationViewsTests.buttons"

    private func row(
        _ state: DictationState,
        engineInfo: DictationEngineInfo? = nil,
        arrangement: DictationInputRowArrangement = .stacked(spacing: 12)
    ) -> some View {
        DictationInputRow(
            mode: DictationInputSwitcher<EmptyView, EmptyView>.rowMode(state: state, engineInfo: engineInfo),
            levelMeter: DictationLevelMeter(),
            canSend: true,
            arrangement: arrangement,
            onDiscard: {},
            onTranscribe: {},
            onTranscribeAndSend: {},
            input: { _ in Text(Self.idleMarker) },
            buttons: { Text(Self.buttonsMarker) }
        )
    }

    /// Renders in a window, lets body be read through the accessibility tree, and collapses the window afterwards.
    private func withHosted<V: View>(_ view: V, width: CGFloat = 390, _ body: (UIView) throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await yieldMainActor(for: 0.6)
        try body(host.view)
    }

    private func accessibilityElements(in root: NSObject) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        func walk(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if node.isAccessibilityElement { found.append(node) }
            var children: [NSObject] = []
            if let elements = node.accessibilityElements as? [NSObject] {
                children.append(contentsOf: elements)
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let child = node.accessibilityElement(at: index) as? NSObject { children.append(child) }
                    }
                }
            }
            if let view = node as? UIView { children.append(contentsOf: view.subviews) }
            children.forEach(walk)
        }
        walk(root)
        return found
    }

    private func labels(in root: UIView) -> [String] {
        accessibilityElements(in: root).compactMap(\.accessibilityLabel)
    }

    private func element(_ label: String, in root: UIView) -> NSObject? {
        accessibilityElements(in: root).first { $0.accessibilityLabel == label }
    }

    @Test("toggle container: idle shows the normal content passed in and no recording bar")
    func switcherIdleShowsHostContent() async throws {
        try await withHosted(row(.idle)) { root in
            let labels = labels(in: root)
            #expect(labels.contains(Self.idleMarker), "\(labels)")
            #expect(labels.contains(Self.buttonsMarker), "\(labels)")
            #expect(!labels.contains(voice("Discard Recording")), "\(labels)")
            #expect(!labels.contains(voice("Done")), "\(labels)")
        }
    }

    @Test("toggle container: recording shows the recording bar (✕ / Transcribe / ↑) and collapses the normal content")
    func switcherRecordingShowsBar() async throws {
        let arrangements: [DictationInputRowArrangement] = [
            .stacked(spacing: 12), .sideBySide(spacing: 7, stackedSpacing: 8),
        ]
        for arrangement in arrangements {
            try await withHosted(row(.recording(startedAt: Date().addingTimeInterval(-5)), arrangement: arrangement)) { root in
                let labels = labels(in: root)
                #expect(labels.contains(Self.idleMarker), "\(labels)")
                #expect(!labels.contains(Self.buttonsMarker), "\(labels)")
                #expect(labels.contains(voice("Discard Recording")), "\(labels)")
                #expect(labels.contains(voice("Done")), "\(labels)")
                #expect(labels.contains(voice("Transcribe and Send")), "\(labels)")
                let input = try #require(element(Self.idleMarker, in: root))
                let discard = try #require(element(voice("Discard Recording"), in: root))
                #expect(discard.accessibilityFrame.minY >= input.accessibilityFrame.maxY,
                        "\(arrangement): input \(input.accessibilityFrame) recording bar \(discard.accessibilityFrame)")
            }
        }
    }

    @Test("toggle container: transcribing keeps the input field, and the button slot shows the busy state (only ✕ plus the transcribing copy)")
    func switcherTranscribingShowsBusy() async throws {
        let cloud = DictationEngineInfo(displayName: "My Groq", providerID: UUID())
        try await withHosted(row(.transcribing(.send), engineInfo: cloud)) { root in
            let labels = labels(in: root)
            let caption = L10n.format(voice("Transcribing · %@"), "My Groq")
            #expect(labels.contains(Self.idleMarker), "\(labels)")
            #expect(!labels.contains(Self.buttonsMarker), "\(labels)")
            #expect(labels.contains(voice("Discard Recording")), "\(labels)")
            #expect(labels.contains { $0.contains(caption) }, "\(labels)")
            #expect(!labels.contains(voice("Done")), "\(labels)")
            #expect(!labels.contains(voice("Transcribe and Send")), "\(labels)")
        }
    }

    @Test("microphone key: accessibility name Dictate, and activating it calls the tap action (production init calls micTapped)")
    func micButtonLabelAndTap() async throws {
        #expect(DictationMicButton.accessibilityLabel == voice("Dictate"))
        #expect(DictationMicButton.minimumHitSize >= 44)
        let taps = TapCounter()
        try await withHosted(DictationMicButton(action: { taps.count += 1 })) { root in
            let element = try #require(
                accessibilityElements(in: root).first { $0.accessibilityLabel == voice("Dictate") },
                "Dictate not found in the accessibility tree"
            )
            #expect(element.accessibilityActivate())
        }
        try await yieldMainActor(for: 0.1)
        #expect(taps.count == 1)
    }

    // MARK: - Inline cards

    /// Every state that has a card; the card comes from the production mapping.
    private static let cardStates: [DictationState] = [
        .failed(.retry), .failed(.checkConnection), .failed(.noTranscript),
        .failed(.system(.network)), .failed(.system(.busy)), .failed(.system(.languageUnsupported)),
        .failed(.system(.noService)), .failed(.system(.other)),
        .interrupted, .slotOccupied, .denied(.microphone), .denied(.speechRecognition),
    ]

    @Test("each kind of card in a UIHostingController does not crash, and the title and the two buttons carry the specified accessibility names")
    func promptCardsRenderWithLabels() async throws {
        for state in Self.cardStates {
            let card = try #require(DictationPresentation.card(for: state, savedDuration: 65, recognitionLanguageName: "English"), "\(state) has no card")
            let view = DictationPromptCardView(card: card, onSecondary: {}, onPrimary: {})
            try await withHosted(view) { root in
                let labels = labels(in: root)
                #expect(labels.contains { $0.contains(card.title) }, "\(state): \(labels)")
                #expect(labels.contains(card.secondary.localizedTitle), "\(state): \(labels)")
                #expect(labels.contains(card.primary.localizedTitle), "\(state): \(labels)")
            }
        }
        let slotOccupied = try #require(DictationPresentation.card(for: .slotOccupied, savedDuration: 65, recognitionLanguageName: "English"))
        #expect(slotOccupied.title == voice("Previous recording not transcribed yet"))
        #expect(slotOccupied.secondary.localizedTitle == voice("Discard and Re-record"))
        #expect(slotOccupied.primary.localizedTitle == voice("Transcribe First"))
        let denied = try #require(DictationPresentation.card(for: .denied(.speechRecognition), savedDuration: nil, recognitionLanguageName: "English"))
        #expect(denied.title == voice("Speech recognition access is off"))
        #expect(denied.secondary.localizedTitle == voice("Not Now"))
        #expect(denied.primary.localizedTitle == voice("Open Settings"))
    }

    @Test("failed card: the two buttons at default font size are 40 high (minimum 40, growing with the font), 10 apart, right-aligned to an 18 inset from the card")
    func promptCardButtonsRightAligned() async throws {
        #expect(DictationPromptCardView.buttonMinHeight == 40)
        #expect(DictationPromptCardView.cornerRadius == 24)
        let card = try #require(DictationPresentation.card(for: .failed(.retry), savedDuration: 65, recognitionLanguageName: "English"))
        let view = DictationPromptCardView(card: card, onSecondary: {}, onPrimary: {})
            .frame(width: 360)
            .fixedSize(horizontal: false, vertical: true)
        try await withHosted(view) { root in
            let secondary = try #require(element(card.secondary.localizedTitle, in: root))
            let primary = try #require(element(card.primary.localizedTitle, in: root))
            let s = secondary.accessibilityFrame
            let p = primary.accessibilityFrame
            #expect(s.height == 40, "\(s)")
            #expect(p.height == 40, "\(p)")
            #expect(abs(p.minX - s.maxX - 10) < 0.5, "secondary \(s) primary \(p)")
            #expect(abs(s.midY - p.midY) < 0.5)
            let cardFrame = root.convert(root.bounds, to: nil)
            let cardRight = cardFrame.midX + 180
            #expect(abs(p.maxX - (cardRight - 18)) < 0.5, "primary \(p) card right edge \(cardRight)")
        }
    }

    /// Renders the failed card at the given font size and returns the accessibility frames of the merged title-body element and the primary button.
    private func promptCardFrames(_ size: DynamicTypeSize) async throws -> (text: CGRect, primary: CGRect) {
        let card = try #require(DictationPresentation.card(for: .failed(.retry), savedDuration: 65, recognitionLanguageName: "English"))
        let view = DictationPromptCardView(card: card, onSecondary: {}, onPrimary: {})
            .frame(width: 360)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.dynamicTypeSize, size)
        var frames: (CGRect, CGRect) = (.zero, .zero)
        try await withHosted(view) { root in
            let text = try #require(accessibilityElements(in: root).first { ($0.accessibilityLabel ?? "").contains(card.title) })
            let primary = try #require(element(card.primary.localizedTitle, in: root))
            frames = (text.accessibilityFrame, primary.accessibilityFrame)
        }
        return frames
    }

    @Test("failed card text scales with Dynamic Type, capped at accessibility2; buttons are no shorter than 40")
    func promptCardTextScalesWithDynamicType() async throws {
        let base = try await promptCardFrames(.large)
        let large = try await promptCardFrames(.accessibility2)
        let capped = try await promptCardFrames(.accessibility5)
        #expect(large.text.height > base.text.height * 1.4, "default \(base.text) large \(large.text)")
        #expect(abs(capped.text.height - large.text.height) < 0.5, "AX2 \(large.text) AX5 \(capped.text)")
        #expect(base.primary.height >= 40 && large.primary.height >= 40, "\(base.primary) \(large.primary)")
        #expect(large.primary.height >= base.primary.height)
    }

    @Test("design §1 row 1: the empty-draft placeholder while recording is \"Listening…\"; transcribing and the normal state do not change the placeholder")
    func listeningPlaceholderWhileRecording() {
        #expect(ChatComposerBar.listeningPlaceholder(phase: .recording) == voice("Listening…"))
        #expect(ChatComposerBar.listeningPlaceholder(phase: .busy) == nil)
        #expect(ChatComposerBar.listeningPlaceholder(phase: .normal) == nil)
        #expect(ChatComposerBar.inputPlaceholder(phase: .recording, isSending: false) == voice("Listening…"))
        #expect(ChatComposerBar.inputPlaceholder(phase: .normal, isSending: false) == L10n.tr("Type a message...", table: .chat))
        #expect(ChatComposerBar.inputPlaceholder(phase: .normal, isSending: true) == L10n.tr("AI is answering...", table: .chat))
    }

    @Test("recording capsule timer and the \"Done\" label scale with Dynamic Type, capped at accessibility2")
    func dictationBarTextCappedAtAccessibility2() {
        #expect(ComposerDictationBar.dynamicTypeCap == .accessibility2)
        #expect(DictationPromptCardView.dynamicTypeCap == .accessibility2)
    }

    /// "Done" in 16 languages (Done in Voice.xcstrings), read straight from the catalog so it does not depend on the current UI language.
    private func doneTitles() throws -> [String: String] {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Oriveo").appendingPathComponent("Voice.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings["Done"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: [String: Any]])
        return try localizations.mapValues { value in
            let unit = try #require(value["stringUnit"] as? [String: Any])
            return try #require(unit["value"] as? String)
        }
    }

    /// Width at which a given run of text neither shrinks nor truncates after AX5 is capped.
    private func idealWidth(_ text: String, font: Font) -> CGFloat {
        UIHostingController(rootView: Text(text)
            .font(font)
            .dynamicTypeSize(...ComposerDictationBar.dynamicTypeCap)
            .environment(\.dynamicTypeSize, .accessibility5)
        ).sizeThatFits(in: CGSize(width: 1000, height: 200)).width
    }

    @Test("at large font sizes (AX5 capped at accessibility2), \"Done\" and the timer are not truncated in any of the 16 languages, and ✕ and the send button stay in bounds; the original size fits 370 width, while 343 / 305 width shrink to at most 0.75")
    func doneNeverTruncatesAtLargestType() async throws {
        // Sample light-en-max: 402pt screen, 16 on each side of the input bar, recording bar usable width 370; a 375 screen gives 343 (the lower bound).
        // If the width is not enough, first shrink the waveform to 0 bars; if still not enough, scale the timer and "Done" down with minimumScaleFactor 0.75 so a single line does not truncate.
        // The original size fits at 370 (regression lock); the lower bound of a 375 screen (343) allows shrinking to 0.75 (pt-BR needs about 0.97);
        // at 305 the original size does not fit, which locks the shrink path (pt-BR needs about 302 when fully shrunk).
        let minimum = ComposerDictationBar.minimumTextScale
        let cases: [(width: CGFloat, scale: CGFloat)] = [(370, 1), (343, minimum), (305, minimum)]
        #expect(ComposerDictationBar.minimumTextScale == 0.75)
        let titles = try doneTitles()
        #expect(titles.count == 16)
        let elapsedText = DictationPresentation.formattedDuration(12)
        let elapsedIdeal = idealWidth(elapsedText, font: ComposerDictationBar.elapsedFont)
        ComposerDictationBar.shotsFrozenElapsedSec = 12
        defer { ComposerDictationBar.shotsFrozenElapsedSec = nil }
        for (width, scale) in cases {
            for (locale, title) in titles.sorted(by: { $0.key < $1.key }) {
                let ideal = idealWidth(title, font: ComposerDictationBar.doneFont)
                var view = bar(.recording(startedAt: .now))
                view.doneTitle = title
                let hosted = view
                    .frame(width: width)
                    .environment(\.dynamicTypeSize, .accessibility5)
                try await withHosted(hosted, width: width) { root in
                    let tag = "\(Int(width)) \(locale)"
                    let done = try #require(element(title, in: root), "\(tag)")
                    let elapsed = try #require(element(elapsedText, in: root), "\(tag)")
                    let discard = try #require(element(voice("Discard Recording"), in: root), "\(tag)")
                    let send = try #require(element(voice("Transcribe and Send"), in: root), "\(tag)")
                    #expect(done.accessibilityFrame.width >= ideal * scale + 2 * ComposerDictationBar.doneHorizontalPadding - 0.5,
                            "\(tag) \"\(title)\" width \(done.accessibilityFrame.width), needs at least \(ideal) × \(scale) + 28")
                    #expect(elapsed.accessibilityFrame.width >= elapsedIdeal * scale - 0.5,
                            "\(tag) timer width \(elapsed.accessibilityFrame.width), needs at least \(elapsedIdeal) × \(scale)")
                    #expect(discard.accessibilityFrame.minX >= 0, "\(tag) \(discard.accessibilityFrame)")
                    #expect(send.accessibilityFrame.maxX <= width + 0.5, "\(tag) \(send.accessibilityFrame)")
                    #expect(done.accessibilityFrame.maxX <= send.accessibilityFrame.minX, "\(tag)")
                    #expect(elapsed.accessibilityFrame.minX >= discard.accessibilityFrame.maxX, "\(tag)")
                    #expect(done.accessibilityFrame.minX >= elapsed.accessibilityFrame.maxX, "\(tag)")
                }
            }
        }
    }

    @Test("failed card icon: no stroke in dark mode (transparent), light mode stroke #B45309 α.18; dark mode icon background #F59E0B α.18, icon #FCD34D")
    func promptCardIconHairlineDarkClear() {
        // UIColor(Color) bridging drops the dynamic provider, so resolve through the SwiftUI environment instead.
        func rgba(_ color: Color, _ style: UIUserInterfaceStyle) -> [Int] {
            var environment = EnvironmentValues()
            environment.colorScheme = style == .dark ? .dark : .light
            let resolved = color.resolve(in: environment)
            return [resolved.red, resolved.green, resolved.blue, resolved.opacity].map { Int(($0 * 255).rounded()) }
        }
        #expect(rgba(DictationPromptCardView.iconHairline, .dark)[3] == 0)
        #expect(rgba(DictationPromptCardView.iconHairline, .light) == [0xB4, 0x53, 0x09, Int((0.18 * 255).rounded())])
        #expect(rgba(DictationPromptCardView.iconFillTop, .dark) == [0xF5, 0x9E, 0x0B, Int((0.18 * 255).rounded())])
        #expect(rgba(DictationPromptCardView.iconTint, .dark) == [0xFC, 0xD3, 0x4D, 255])
    }

    @Test("design draft ④: failed / permission cards use a warning icon, interrupted / slot-occupied use a waveform")
    func promptCardIcons() throws {
        for state in Self.cardStates {
            let card = try #require(DictationPresentation.card(for: state, savedDuration: nil, recognitionLanguageName: "English"))
            let alert: Bool = switch state {
            case .failed, .denied: true
            default: false
            }
            #expect(DictationPromptCardView.isAlert(card) == alert, "\(state)")
        }
    }

    @Test("card slot: no card state (idle) draws no card, and the failed state draws the card buttons")
    func promptSlotFollowsState() async throws {
        let rig = try PromptRig()
        try await withHosted(DictationPromptSlot(controller: rig.controller, onCheckConnection: { _ in }, onOpenVoiceSettings: {})) { root in
            #expect(!labels(in: root).contains(voice("Discard")))
        }
        try await rig.fail()
        try await withHosted(DictationPromptSlot(controller: rig.controller, onCheckConnection: { _ in }, onOpenVoiceSettings: {})) { root in
            let labels = labels(in: root)
            #expect(labels.contains(voice("Discard")), "\(labels)")
            #expect(labels.contains(voice("Retry")), "\(labels)")
        }
    }

    // MARK: - Recording state only shows on the bound host

    /// Inject the dictation host key into the subtree; nil means not inside a host.
    private func inHost<V: View>(_ view: V, slotKey: String?) -> some View {
        view.environment(\.dictationHost, slotKey.map { DictationHostContext(slotKey: $0, activate: {}) })
    }

    private func switcher(_ rig: PromptRig) -> some View {
        DictationInputSwitcher(controller: rig.controller, canSend: true) { _ in
            Text(Self.idleMarker)
        } buttons: {
            Text(Self.buttonsMarker)
        }
    }

    @Test("host key differs from the controller slot: the toggle container shows the normal content and the card slot is empty")
    func otherHostShowsNoDictationState() async throws {
        #expect(!DictationHostContext.isBound(DictationHostContext(slotKey: "other", activate: {}),
                                              controllerSlotKey: PromptRig.slotKey))
        let recording = try PromptRig()
        await recording.record()
        try await withHosted(inHost(switcher(recording), slotKey: "other-host")) { root in
            let labels = labels(in: root)
            #expect(labels.contains(Self.idleMarker), "\(labels)")
            #expect(labels.contains(Self.buttonsMarker), "\(labels)")
            #expect(!labels.contains(voice("Discard Recording")), "\(labels)")
            #expect(!labels.contains(voice("Done")), "\(labels)")
        }
        await recording.controller.discard()

        let failed = try PromptRig()
        try await failed.fail()
        let slot = DictationPromptSlot(controller: failed.controller, onCheckConnection: { _ in }, onOpenVoiceSettings: {})
        try await withHosted(inHost(slot, slotKey: "other-host")) { root in
            let labels = labels(in: root)
            #expect(!labels.contains(voice("Discard")), "\(labels)")
            #expect(!labels.contains(voice("Retry")), "\(labels)")
        }
    }

    @Test("host key equals the controller slot or there is no host: the recording bar and card still show as before")
    func boundOrHostlessShowsDictationState() async throws {
        for hostKey in [PromptRig.slotKey, nil] as [String?] {
            #expect(DictationHostContext.isBound(hostKey.map { DictationHostContext(slotKey: $0, activate: {}) },
                                                 controllerSlotKey: PromptRig.slotKey))
            let recording = try PromptRig()
            await recording.record()
            try await withHosted(inHost(switcher(recording), slotKey: hostKey)) { root in
                let labels = labels(in: root)
                #expect(labels.contains(Self.idleMarker), "\(String(describing: hostKey)): \(labels)")
                #expect(!labels.contains(Self.buttonsMarker), "\(String(describing: hostKey)): \(labels)")
                #expect(labels.contains(voice("Discard Recording")), "\(String(describing: hostKey)): \(labels)")
                #expect(labels.contains(voice("Done")), "\(String(describing: hostKey)): \(labels)")
            }
            await recording.controller.discard()

            let failed = try PromptRig()
            try await failed.fail()
            let slot = DictationPromptSlot(controller: failed.controller, onCheckConnection: { _ in }, onOpenVoiceSettings: {})
            try await withHosted(inHost(slot, slotKey: hostKey)) { root in
                let labels = labels(in: root)
                #expect(labels.contains(voice("Discard")), "\(String(describing: hostKey)): \(labels)")
                #expect(labels.contains(voice("Retry")), "\(String(describing: hostKey)): \(labels)")
            }
        }
    }

    private func perform(_ action: DictationCardAction, _ rig: PromptRig) async {
        await DictationPromptSlot.perform(
            action, controller: rig.controller,
            onCheckConnection: { rig.checkedConnections.append($0) },
            onOpenVoiceSettings: { rig.voiceSettingsOpened += 1 },
            openLanguageSheet: { rig.languageSheetOpened += 1 },
            openSettings: { rig.settingsOpened += 1 }
        )
    }

    @Test("card action: Discard -> discard(), the failed state returns to idle")
    func performDiscard() async throws {
        let rig = try PromptRig()
        try await rig.fail()
        await perform(.discard, rig)
        #expect(rig.controller.state == .idle)
        #expect(rig.controller.pendingDurationSec == nil)
    }

    @Test("card action: Retry -> finish(.insert), transcribe again and insert")
    func performRetry() async throws {
        let rig = try PromptRig()
        try await rig.fail()
        rig.engine.outcome = .success("hello")
        await perform(.retry, rig)
        #expect(rig.engine.calls.count == 2)
        #expect(rig.controller.state == .idle)
        #expect(rig.events == [.insert("hello")])
    }

    @Test("card action: Transcribe Recording -> finish(.insert), transcribe the interrupted recording")
    func performTranscribeRecording() async throws {
        let rig = try PromptRig()
        await rig.interrupt()
        #expect(rig.controller.state == .interrupted)
        await perform(.transcribeRecording, rig)
        #expect(rig.engine.calls.count == 1)
        #expect(rig.events == [.insert("hello")])
    }

    @Test("card action: Transcribe First -> transcribeOccupied(), transcribe the old recording in the slot")
    func performTranscribeFirst() async throws {
        let rig = try PromptRig()
        await rig.occupy()
        #expect(rig.controller.state == .slotOccupied)
        await perform(.transcribeFirst, rig)
        #expect(rig.engine.calls.count == 1)
        #expect(rig.events == [.insert("hello")])
    }

    @Test("card action: Discard and Re-record -> discardAndRerecord(), delete the old recording and start recording directly")
    func performDiscardAndRerecord() async throws {
        let rig = try PromptRig()
        await rig.occupy()
        let startsBefore = rig.capture.startCount
        await perform(.discardAndRerecord, rig)
        guard case .recording = rig.controller.state else {
            Issue.record("should be recording, actually \(rig.controller.state)")
            return
        }
        #expect(rig.capture.startCount == startsBefore + 1)
        #expect(rig.engine.calls.isEmpty)
        await rig.controller.discard()
    }

    @Test("card action: Not Now -> dismissDenied(); Open Settings opens system settings without changing the state")
    func performDeniedActions() async throws {
        let rig = try PromptRig()
        rig.permission.status = .denied
        await rig.controller.micTapped()
        #expect(rig.controller.state == .denied(.microphone))
        await perform(.openSettings, rig)
        #expect(rig.settingsOpened == 1)
        #expect(rig.controller.state == .denied(.microphone))
        await perform(.notNow, rig)
        #expect(rig.controller.state == .idle)
        #expect(rig.settingsOpened == 1)
    }

    @Test("card action: Check Connection hands engineInfo.providerID to the host; a system engine has no id and hands nil")
    func performCheckConnection() async throws {
        let providerID = UUID()
        let cloud = try PromptRig(providerID: providerID)
        try await cloud.fail()
        await perform(.checkConnection, cloud)
        #expect(cloud.checkedConnections == [providerID])
        #expect(cloud.settingsOpened == 0)

        let system = try PromptRig()
        try await system.fail()
        await perform(.checkConnection, system)
        #expect(system.checkedConnections == [nil])
    }

    @Test("change recognition language: opens the language form in place, does not hand off to host settings, and does not change controller state")
    func performChangeLanguageOpensSheet() async throws {
        let rig = try PromptRig()
        try await rig.failNoTranscript()
        await perform(.changeLanguage, rig)
        #expect(rig.languageSheetOpened == 1)
        #expect(rig.voiceSettingsOpened == 0)
        #expect(rig.controller.state == .failed(.noTranscript))
        #expect(rig.checkedConnections.isEmpty)
        #expect(rig.settingsOpened == 0)
        #expect(rig.engine.calls.count == 1)
    }

    @Test("switch dictation engine: still hands off to the host to open voice settings, does not open the language form, and does not change controller state")
    func performSwitchEngineOpensVoiceSettings() async throws {
        let rig = try PromptRig()
        try await rig.fail()
        await perform(.switchEngine, rig)
        #expect(rig.voiceSettingsOpened == 1)
        #expect(rig.languageSheetOpened == 0)
        #expect(rig.controller.state == .failed(.retry))
        #expect(rig.settingsOpened == 0)
        #expect(rig.engine.calls.count == 1)
    }

    @Test("language form picks a new language while the recording is still active: goes through retry, and recognition reads the new language and inserts")
    func languageSheetChangedRetriesWithNewLanguage() async throws {
        let rig = try PromptRig()
        rig.language = "en-US"
        try await rig.failNoTranscript()
        #expect(rig.engine.languages == ["en-US"])
        rig.language = "ja-JP"
        rig.engine.outcome = .success("こんにちは")
        await DictationPromptSlot.languageSheetDone(changed: true, controller: rig.controller)
        #expect(rig.engine.languages == ["en-US", "ja-JP"])
        #expect(rig.controller.state == .idle)
        #expect(rig.events == [.insert("こんにちは")])
    }

    @Test("language form closed without changes: the card stays and does not retry")
    func languageSheetUnchangedKeepsCard() async throws {
        let rig = try PromptRig()
        try await rig.failNoTranscript()
        await DictationPromptSlot.languageSheetDone(changed: false, controller: rig.controller)
        #expect(rig.controller.state == .failed(.noTranscript))
        #expect(rig.engine.calls.count == 1)
        #expect(rig.events.isEmpty)
    }

    @Test("language-pack card Download -> controller.download(), shows downloading and presents one \"Downloading\" toast")
    func performDownload() async throws {
        let inventory = DictationAssetInventoryFake()
        let rig = try PromptRig(languagePack: inventory)
        await rig.record()
        let prompt = try #require(rig.controller.languagePackPrompt)
        #expect(!prompt.downloading)
        ToastManager.shared.performCurrentAction()

        await perform(.download, rig)
        #expect(rig.controller.languagePackPrompt?.downloading == true)
        #expect(ToastManager.shared.current?.message == L10n.format(
            voice("Downloading the %1$@ speech pack. Until it finishes, recognition uses the internet."), prompt.displayName))
        #expect(ToastManager.shared.current?.actionTitle == nil)
        guard case .recording = rig.controller.state else {
            Issue.record("should still be recording, actually \(rig.controller.state)")
            return
        }
        inventory.finishInstall()
        await rig.controller.languagePackDownload?.value
        #expect(rig.controller.languagePackPrompt == nil)
        await rig.controller.discard()
        ToastManager.shared.performCurrentAction()
    }

    @Test("language-pack card Not Now -> dismissLanguagePack(); the hint is cleared and the recording is unaffected")
    func performNotNowOnLanguagePack() async throws {
        let inventory = DictationAssetInventoryFake()
        let rig = try PromptRig(languagePack: inventory)
        await rig.record()
        #expect(rig.controller.languagePackPrompt != nil)

        await perform(.notNow, rig)
        #expect(rig.controller.languagePackPrompt == nil)
        #expect(inventory.installCount == 0)
        guard case .recording = rig.controller.state else {
            Issue.record("should still be recording, actually \(rig.controller.state)")
            return
        }
        await rig.controller.discard()
    }

    // MARK: - Haptics

    /// The injected haptic closure records each firing.
    private final class HapticLog {
        var entries: [String] = []
        var haptics: DictationHaptics {
            DictationHaptics(light: { self.entries.append("light") }, error: { self.entries.append("error") })
        }
    }

    @Test("error fires once when the failed card appears: the same card redrawn, card removed, and non-failed cards do not fire")
    func failureCardTriggersErrorOnce() async throws {
        let log = HapticLog()
        let failed = try PromptRig()
        try await failed.fail()
        let card = try #require(DictationPresentation.card(
            for: failed.controller.state, savedDuration: nil, recognitionLanguageName: "English"
        ))
        DictationPromptSlot.cardChanged(from: nil, to: card, state: failed.controller.state, haptics: log.haptics)
        #expect(log.entries == ["error"])
        DictationPromptSlot.cardChanged(from: card, to: card, state: failed.controller.state, haptics: log.haptics)
        DictationPromptSlot.cardChanged(from: card, to: nil, state: .idle, haptics: log.haptics)
        #expect(log.entries == ["error"])

        let interrupted = try PromptRig()
        await interrupted.interrupt()
        let other = try #require(DictationPresentation.card(
            for: interrupted.controller.state, savedDuration: nil, recognitionLanguageName: "English"
        ))
        DictationPromptSlot.cardChanged(from: nil, to: other, state: interrupted.controller.state, haptics: log.haptics)
        #expect(log.entries == ["error"])
    }

    @Test("host haptics: a light tap on entering recording, and another light tap when the final insert commits")
    func hostHapticsOnRecordingAndInsert() async throws {
        let log = HapticLog()
        let rig = try PromptRig()
        var inserted: [String] = []
        let host = DictationHostBinding(
            canSend: { false }, onInsert: { inserted.append($0) }, toast: { _ in }, haptics: log.haptics
        )
        host.attach(controller: rig.controller, slotKey: PromptRig.slotKey)
        await rig.record()
        #expect(log.entries == ["light"])

        await rig.controller.finish(.insert)
        #expect(inserted == ["hello"])
        #expect(log.entries == ["light", "light"])
        withExtendedLifetime(host) {}
    }
}

/// Controller for the card action tests: a real RecordingStore pointing at a temporary directory; engine / capture / permission use the fakes from DictationControllerTests.
@MainActor
private final class PromptRig {
    static let slotKey = "prompt-slot"

    let engine: FakeSTTEngine
    let capture: FakeAudioCapture
    let permission: FakeMicrophonePermission
    let controller: DictationController
    var events: [DictationEvent] = []
    var checkedConnections: [UUID?] = []
    var settingsOpened = 0
    var voiceSettingsOpened = 0
    var languageSheetOpened = 0
    /// The recognition language the controller reads on each transcription.
    var language: String? {
        get { languageBox.code }
        set { languageBox.code = newValue }
    }

    private final class LanguageBox {
        var code: String?
    }
    private let languageBox = LanguageBox()

    private struct Boom: Error {}

    /// languagePack non-nil: system engine, prepared on iOS 26+; whether the en-US language pack counts as installed is decided by this fake.
    init(providerID: UUID? = nil, languagePack: DictationAssetInventoryFake? = nil) throws {
        let engine = FakeSTTEngine()
        let capture = FakeAudioCapture(sampleRate: 48_000)
        let permission = FakeMicrophonePermission()
        self.engine = engine
        self.capture = capture
        self.permission = permission
        let root = FileManager.default.temporaryDirectory
            .appending(path: "DictationViewsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "pending", directoryHint: .isDirectory)
        let store = try RecordingStore(root: root, onLost: { _ in })
        let readAloud = ReadAloudController(
            engine: SilentSpeechEngine(), platform: SilentReadAloudPlatform(),
            notificationCenter: NotificationCenter(), detectLanguage: { _ in "en" }
        )
        var engines: DictationEngineSource = providerID.map {
            .fixed(engine, displayName: "My Groq", providerID: $0)
        } ?? .fixed(engine)
        var system = DictationSystemPreparation.skipped
        if let languagePack {
            engines = .fixed(engine, isSystem: true)
            let suite = "DictationViewsTests-\(UUID().uuidString)"
            system = DictationSystemPreparation(
                analyzerAvailable: true, authorizer: SystemSpeechAuthorizer(),
                assets: SpeechAssetManager(inventory: languagePack, defaults: UserDefaults(suiteName: suite + "-assets")!),
                assetLocale: { _ in Locale(identifier: "en-US") }
            )
            system.promptDefaults = UserDefaults(suiteName: suite + "-prompted")!
        }
        controller = DictationController(
            engines: engines, system: system, capture: capture, store: store,
            permission: permission, readAloud: readAloud, screenAwake: ScreenAwakeHolds(timer: FakeIdleTimer()),
            notificationCenter: NotificationCenter(),
            now: { Date(timeIntervalSince1970: 1_000) },
            language: { [languageBox] in languageBox.code }
        )
        controller.bind(slotKey: Self.slotKey)
        engine.outcome = .success("hello")
        controller.onEvent = { [weak self] in self?.events.append($0) }
    }

    func record() async {
        permission.status = .granted
        await controller.micTapped()
        capture.feed(seconds: 1, amplitude: 0.1)
    }

    /// Record a clip, transcription fails -> failed(.retry).
    func fail() async throws {
        await record()
        engine.outcome = .failure(Boom())
        await controller.finish(.insert)
        try #require(controller.state == .failed(.retry))
        engine.outcome = .success("hello")
    }

    /// Record a segment; recognition is empty -> failed(.noTranscript) (the failed card carries Change Language).
    func failNoTranscript() async throws {
        await record()
        engine.outcome = .success("")
        await controller.finish(.insert)
        try #require(controller.state == .failed(.noTranscript))
        engine.outcome = .success("hello")
    }

    /// Switch away during recording and back again -> interrupted.
    func interrupt() async {
        await record()
        controller.bind(slotKey: "prompt-slot-other")
        controller.bind(slotKey: Self.slotKey)
        await controller.bindLoad?.value
    }

    /// Tap the microphone again while interrupted -> slotOccupied.
    func occupy() async {
        await interrupt()
        await controller.micTapped()
    }
}

@MainActor
private final class TapCounter {
    var count = 0
}
