import Foundation
import Testing
@testable import Oriveo

/// The dictation production singleton. The controller is built through an injected factory (fake engine / capture / permission + a RecordingStore in a temporary directory).
@Suite("Dictation hub", .serialized)
@MainActor
struct DictationHubTests {

    private struct FactoryFailure: Error {}

    private final class FactoryCounter {
        var calls = 0
        var providers: (() -> [Provider])?
    }

    private static func makeController() throws -> DictationController {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "DictationHubTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "pending", directoryHint: .isDirectory)
        let store = try RecordingStore(root: root)
        let readAloud = ReadAloudController(
            engine: SilentSpeechEngine(), platform: SilentReadAloudPlatform(),
            notificationCenter: NotificationCenter(), detectLanguage: { _ in "en" }
        )
        return DictationController(
            engines: .fixed(FakeSTTEngine()), system: .skipped,
            capture: FakeAudioCapture(sampleRate: 48_000), store: store,
            permission: FakeMicrophonePermission(), readAloud: readAloud, screenAwake: ScreenAwakeHolds(timer: FakeIdleTimer()),
            notificationCenter: NotificationCenter(),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    @Test("providers returns empty by default")
    func providersDefaultEmpty() {
        let hub = DictationHub(factory: { _ in throw FactoryFailure() })
        #expect(hub.providers().isEmpty)
    }

    @Test("after the host sets providers, providers() returns the list, and the closure the factory received reads the same list")
    func providersReturnsAssigned() throws {
        let counter = FactoryCounter()
        let hub = DictationHub(factory: { providers in
            counter.calls += 1
            counter.providers = providers
            return try Self.makeController()
        })
        let provider = TestFactories.makeProvider(kind: .relay, apiKey: "sk-voice")
        hub.providers = { [provider] }
        #expect(hub.providers().map(\.id) == [provider.id])
        _ = hub.controller
        #expect(counter.providers?().map(\.id) == [provider.id])
        hub.providers = { [] }
        #expect(counter.providers?().isEmpty == true)
    }

    @Test("the injected factory is built only once; two reads return the same instance")
    func controllerBuiltOnce() throws {
        let counter = FactoryCounter()
        let hub = DictationHub(factory: { _ in
            counter.calls += 1
            return try Self.makeController()
        })
        #expect(counter.calls == 0)
        let first = try #require(hub.controller)
        let second = try #require(hub.controller)
        #expect(first === second)
        #expect(counter.calls == 1)
    }

    @Test("controller is nil when the factory throws")
    func controllerNilWhenFactoryThrows() {
        let counter = FactoryCounter()
        let hub = DictationHub(factory: { _ in
            counter.calls += 1
            throw FactoryFailure()
        })
        #expect(hub.controller == nil)
        #expect(hub.controller == nil)
        #expect(counter.calls == 1)
    }
}
