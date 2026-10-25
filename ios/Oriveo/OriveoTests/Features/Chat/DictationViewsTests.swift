import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Oriveo

/// The dictation recording bar: button and accessibility names, only ✕ while busy, and the busy-state copy.
@MainActor
@Suite("Dictation recording bar")
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

    @Test("recording, preparing speech recognition and transcribing (cloud / system) all lay out in a UIHostingController, and stay at least the 44pt hit area")
    func barLaysOutInEveryMode() async throws {
        let modes: [DictationInputRowMode] = [
            .recording(startedAt: Date().addingTimeInterval(-65)),
            .busy(.preparing(progress: 0.4)),
            .busy(.transcribing(engineName: "My Groq")),
            .busy(.transcribing(engineName: nil)),
        ]
        for mode in modes {
            let height = try await layOut(bar(mode))
            #expect(height >= ComposerDictationBar.minimumHitSize, "\(mode) laid-out height \(height)")
        }
        let disabledSend = try await layOut(bar(.recording(startedAt: .now), canSend: false))
        #expect(disabledSend >= ComposerDictationBar.minimumHitSize)
    }

    @Test("recording bar buttons are ✕ / Transcribe / ↑, with the specified accessibility names")
    func recordingControlsAndLabels() {
        #expect(ComposerDictationBar.controls(for: .recording(startedAt: .now))
                == [.discard, .transcribe, .transcribeAndSend])
        #expect(DictationBarControl.discard.accessibilityLabel == voice("Discard Recording"))
        #expect(DictationBarControl.transcribe.accessibilityLabel == voice("Transcribe"))
        #expect(DictationBarControl.transcribeAndSend.accessibilityLabel == voice("Transcribe and Send"))
        for control in DictationBarControl.allCases {
            #expect(!control.accessibilityLabel.isEmpty)
        }
    }

    @Test("while busy only ✕ remains, with no Transcribe or ↑; the normal composer row does not draw the recording bar")
    func busyKeepsOnlyDiscard() {
        for activity: DictationBusyActivity in [.preparing(progress: 0), .transcribing(engineName: "My Groq"),
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
        #expect(caption(.preparing(progress: 0.2), nil) == voice("Preparing speech recognition"))
        #expect(caption(.transcribing(.insert), cloud) == L10n.format(voice("Transcribing · %@"), "My Groq"))
        #expect(caption(.transcribing(.send), nil) == voice("Transcribing"))
    }

    // MARK: - Toggle container and microphone key

    private static let idleMarker = "DictationViewsTests.idle"

    private func row(_ state: DictationState, engineInfo: DictationEngineInfo? = nil) -> some View {
        DictationInputRow(
            mode: DictationInputSwitcher<EmptyView>.rowMode(state: state, engineInfo: engineInfo),
            levelMeter: DictationLevelMeter(),
            canSend: true,
            onDiscard: {},
            onTranscribe: {},
            onTranscribeAndSend: {},
            idle: { Text(Self.idleMarker) }
        )
    }

    /// Render inside a window, let body read the accessibility tree, and tear the window down afterwards.
    private func withHosted<V: View>(_ view: V, _ body: (UIView) throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
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

    @Test("toggle container: idle shows the normal content passed in and no recording bar")
    func switcherIdleShowsHostContent() async throws {
        try await withHosted(row(.idle)) { root in
            let labels = labels(in: root)
            #expect(labels.contains(Self.idleMarker), "\(labels)")
            #expect(!labels.contains(voice("Discard Recording")), "\(labels)")
            #expect(!labels.contains(voice("Transcribe")), "\(labels)")
        }
    }

    @Test("toggle container: recording shows the recording bar (✕ / Transcribe / ↑) and collapses the normal content")
    func switcherRecordingShowsBar() async throws {
        try await withHosted(row(.recording(startedAt: Date().addingTimeInterval(-5)))) { root in
            let labels = labels(in: root)
            #expect(!labels.contains(Self.idleMarker), "\(labels)")
            #expect(labels.contains(voice("Discard Recording")), "\(labels)")
            #expect(labels.contains(voice("Transcribe")), "\(labels)")
            #expect(labels.contains(voice("Transcribe and Send")), "\(labels)")
        }
    }

    @Test("toggle container: transcribing shows the busy state (only ✕ + the transcribing copy) and collapses the normal content")
    func switcherTranscribingShowsBusy() async throws {
        let cloud = DictationEngineInfo(displayName: "My Groq", providerID: UUID())
        try await withHosted(row(.transcribing(.send), engineInfo: cloud)) { root in
            let labels = labels(in: root)
            let caption = L10n.format(voice("Transcribing · %@"), "My Groq")
            #expect(!labels.contains(Self.idleMarker), "\(labels)")
            #expect(labels.contains(voice("Discard Recording")), "\(labels)")
            #expect(labels.contains { $0.contains(caption) }, "\(labels)")
            #expect(!labels.contains(voice("Transcribe")), "\(labels)")
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
        .interrupted, .slotOccupied, .denied(.microphone), .denied(.speechRecognition),
    ]

    @Test("each kind of card in a UIHostingController does not crash, and the title and the two buttons carry the specified accessibility names")
    func promptCardsRenderWithLabels() async throws {
        for state in Self.cardStates {
            let card = try #require(DictationPresentation.card(for: state, savedDuration: 65), "\(state) has no card")
            let view = DictationPromptCardView(card: card, onSecondary: {}, onPrimary: {})
            try await withHosted(view) { root in
                let labels = labels(in: root)
                #expect(labels.contains { $0.contains(card.title) }, "\(state): \(labels)")
                #expect(labels.contains(card.secondary.localizedTitle), "\(state): \(labels)")
                #expect(labels.contains(card.primary.localizedTitle), "\(state): \(labels)")
            }
        }
        let slotOccupied = try #require(DictationPresentation.card(for: .slotOccupied, savedDuration: 65))
        #expect(slotOccupied.title == voice("Previous recording not transcribed yet"))
        #expect(slotOccupied.secondary.localizedTitle == voice("Discard and Re-record"))
        #expect(slotOccupied.primary.localizedTitle == voice("Transcribe First"))
        let denied = try #require(DictationPresentation.card(for: .denied(.speechRecognition), savedDuration: nil))
        #expect(denied.title == voice("Speech recognition access is off"))
        #expect(denied.secondary.localizedTitle == voice("Not Now"))
        #expect(denied.primary.localizedTitle == voice("Open Settings"))
    }

    @Test("failed / permission cards use a warning icon, interrupted / slot-occupied use a waveform")
    func promptCardIcons() throws {
        for state in Self.cardStates {
            let card = try #require(DictationPresentation.card(for: state, savedDuration: nil))
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
        try await withHosted(DictationPromptSlot(controller: rig.controller, onCheckConnection: { _ in })) { root in
            #expect(!labels(in: root).contains(voice("Discard")))
        }
        try await rig.fail()
        try await withHosted(DictationPromptSlot(controller: rig.controller, onCheckConnection: { _ in })) { root in
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
        DictationInputSwitcher(controller: rig.controller, canSend: true) { Text(Self.idleMarker) }
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
            #expect(!labels.contains(voice("Discard Recording")), "\(labels)")
            #expect(!labels.contains(voice("Transcribe")), "\(labels)")
        }
        await recording.controller.discard()

        let failed = try PromptRig()
        try await failed.fail()
        let slot = DictationPromptSlot(controller: failed.controller, onCheckConnection: { _ in })
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
                #expect(!labels.contains(Self.idleMarker), "\(String(describing: hostKey)): \(labels)")
                #expect(labels.contains(voice("Discard Recording")), "\(String(describing: hostKey)): \(labels)")
                #expect(labels.contains(voice("Transcribe")), "\(String(describing: hostKey)): \(labels)")
            }
            await recording.controller.discard()

            let failed = try PromptRig()
            try await failed.fail()
            let slot = DictationPromptSlot(controller: failed.controller, onCheckConnection: { _ in })
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

    private struct Boom: Error {}

    init(providerID: UUID? = nil) throws {
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
        let engines: DictationEngineSource = providerID.map {
            .fixed(engine, displayName: "My Groq", providerID: $0)
        } ?? .fixed(engine)
        controller = DictationController(
            engines: engines, system: .skipped, capture: capture, store: store,
            permission: permission, readAloud: readAloud, screenAwake: ScreenAwakeHolds(timer: FakeIdleTimer()),
            notificationCenter: NotificationCenter(),
            now: { Date(timeIntervalSince1970: 1_000) }
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

    /// Switch away while recording and back -> interrupted.
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
