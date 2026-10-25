import AVFoundation
import Foundation

/// The single production dictation controller in the app.
/// The provider list is injected by the app root view (the `providers` closure); the controller is built
/// the first time `controller` is read, not at launch.
@MainActor
final class DictationHub {

    static let shared = DictationHub()

    /// Provider list read when cloud dictation resolves a connection; empty until injected.
    var providers: () -> [Provider] = { [] }

    /// The argument is a closure that reads the hub's current providers on every call.
    typealias Factory = (_ providers: @escaping () -> [Provider]) throws -> DictationController

    private let factory: Factory
    private var built = false
    private var cached: DictationController?

    init(factory: Factory? = nil) {
        self.factory = factory ?? { try Self.makeProduction(providers: $0) }
    }

    /// Built lazily, once. nil when the factory throws (the recordings directory cannot be created);
    /// the host then hides the microphone.
    var controller: DictationController? {
        if !built {
            built = true
            cached = try? factory { [weak self] in self?.providers() ?? [] }
        }
        return cached
    }

    /// Uses the microphone when capture is nil; the DEBUG simulator probe passes a file capture and the
    /// rest of the chain stays the same as production.
    static func makeProduction(providers: @escaping () -> [Provider],
                               capture: AudioCapture? = nil) throws -> DictationController {
        let assets = SpeechAssetManager.makeDefault()
        let store = try RecordingStore(now: Date.init)
        return DictationController(
            engines: .resolving(
                providers: providers,
                makeSystem: { SystemSTTEngine.makeDefault(assets: assets) }
            ),
            system: .makeDefault(assets: assets),
            capture: capture ?? EngineAudioCapture(session: .sharedInstance(), bufferSize: 4096),
            store: store
        )
    }
}
