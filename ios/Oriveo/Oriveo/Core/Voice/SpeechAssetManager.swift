import Foundation
import Observation
import Speech

/// Recognition modules whose on-device models are installed through AssetInventory (SpeechAnalyzer, iOS 26+).
nonisolated enum SpeechAssetModule: String, Sendable, Hashable {
    case speechTranscriber
    case dictationTranscriber
}

nonisolated enum SpeechAssetError: Error, Sendable, Hashable {
    case unsupported
    case reservationFailed
    case installFailed
}

/// Install state of one (module, locale); the UI shows progress from it.
nonisolated enum SpeechAssetInstallState: Sendable, Hashable {
    case notInstalled
    case installing(fraction: Double)
    case installed
    case failed
}

/// Seam over AssetInventory: production uses the system, tests inject a fake.
nonisolated protocol SpeechAssetInventory: Sendable {
    func maximumReservedLocales() async -> Int
    func reservedLocales() async -> [Locale]
    func reserve(_ locale: Locale) async throws
    func release(_ locale: Locale) async
    func isInstalled(_ module: SpeechAssetModule, locale: Locale) async -> Bool
    /// Downloads and installs; progress is delivered on the main actor as 0...1.
    func install(
        _ module: SpeechAssetModule,
        locale: Locale,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws
}

/// On-device speech models: reserves the locale (releasing the least recently used one first when the
/// system limit is reached), installs with published progress, and records last use per locale.
/// A failed install is not cached; the next prepare tries again.
@Observable
final class SpeechAssetManager {

    static let lastUsedDefaultsKey = "voice.speech_assets.last_used"

    private(set) var states: [String: SpeechAssetInstallState] = [:]

    @ObservationIgnored private let inventory: any SpeechAssetInventory
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var inFlight: [String: Task<Void, Error>] = [:]
    /// Limit for reservation / status queries; a timeout counts as failure, inFlight is cleared with it,
    /// and the next prepare runs again. Download and install have no limit.
    @ObservationIgnored private let queryLimit: Duration

    init(
        inventory: any SpeechAssetInventory,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        queryLimit: Duration = VoiceDeadline.systemQuery
    ) {
        self.inventory = inventory
        self.defaults = defaults
        self.now = now
        self.queryLimit = queryLimit
    }

    static func makeDefault() -> SpeechAssetManager {
        if #available(iOS 26, *) {
            return SpeechAssetManager(inventory: SystemSpeechAssetInventory())
        }
        return SpeechAssetManager(inventory: UnsupportedSpeechAssetInventory())
    }

    nonisolated static func localeKey(_ locale: Locale) -> String {
        locale.identifier(.bcp47)
    }

    nonisolated static func stateKey(_ module: SpeechAssetModule, locale: Locale) -> String {
        "\(module.rawValue)|\(localeKey(locale))"
    }

    func state(_ module: SpeechAssetModule, locale: Locale) -> SpeechAssetInstallState {
        states[Self.stateKey(module, locale: locale)] ?? .notInstalled
    }

    /// Makes the model available: records last use, reserves the locale, installs it if missing.
    /// Concurrent calls for the same (module, locale) share one attempt.
    func prepare(_ module: SpeechAssetModule, locale: Locale) async throws {
        let key = Self.stateKey(module, locale: locale)
        if let running = inFlight[key] {
            return try await running.value
        }
        let task = Task { try await self.perform(module, locale: locale, key: key) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        try await task.value
    }

    /// Last-use time per locale (BCP 47), in seconds since 1970.
    func lastUsed() -> [String: Double] {
        defaults.dictionary(forKey: Self.lastUsedDefaultsKey) as? [String: Double] ?? [:]
    }

    // MARK: - Internals

    private func perform(_ module: SpeechAssetModule, locale: Locale, key: String) async throws {
        markUsed(locale)
        do {
            try await ensureReserved(locale)
        } catch {
            states[key] = .failed
            throw SpeechAssetError.reservationFailed
        }
        let inventory = inventory
        let installed: Bool
        do {
            installed = try await VoiceDeadline.run(within: queryLimit) {
                await inventory.isInstalled(module, locale: locale)
            }
        } catch {
            states[key] = .failed
            throw SpeechAssetError.installFailed
        }
        if installed {
            states[key] = .installed
            return
        }
        states[key] = .installing(fraction: 0)
        do {
            try await inventory.install(module, locale: locale) { @MainActor [weak self] fraction in
                self?.updateProgress(key, fraction: fraction)
            }
        } catch {
            states[key] = .failed
            throw SpeechAssetError.installFailed
        }
        states[key] = .installed
    }

    private func updateProgress(_ key: String, fraction: Double) {
        // A late progress callback after install finished must not move the state back
        guard case .installing = states[key] else { return }
        states[key] = .installing(fraction: min(max(fraction, 0), 1))
    }

    private func markUsed(_ locale: Locale) {
        var stamps = lastUsed()
        stamps[Self.localeKey(locale)] = now().timeIntervalSince1970
        defaults.set(stamps, forKey: Self.lastUsedDefaultsKey)
    }

    private func ensureReserved(_ locale: Locale) async throws {
        let key = Self.localeKey(locale)
        let inventory = inventory
        let limit = queryLimit
        let reserved = try await VoiceDeadline.run(within: limit) { await inventory.reservedLocales() }
        if reserved.contains(where: { Self.localeKey($0) == key }) { return }
        let maximum = await inventory.maximumReservedLocales()
        if maximum > 0, reserved.count >= maximum {
            let stamps = lastUsed()
            // A locale with no recorded use counts as the least recently used
            let oldestFirst = reserved.sorted {
                (stamps[Self.localeKey($0)] ?? 0) < (stamps[Self.localeKey($1)] ?? 0)
            }
            for victim in oldestFirst.prefix(reserved.count - maximum + 1) {
                try await VoiceDeadline.run(within: limit) { await inventory.release(victim) }
            }
        }
        try await VoiceDeadline.run(within: limit) { try await inventory.reserve(locale) }
    }
}

// MARK: - Production implementations

/// Before iOS 26 there is no AssetInventory, and no SpeechAnalyzer backend is created.
nonisolated struct UnsupportedSpeechAssetInventory: SpeechAssetInventory {
    func maximumReservedLocales() async -> Int { 0 }
    func reservedLocales() async -> [Locale] { [] }
    func reserve(_ locale: Locale) async throws { throw SpeechAssetError.unsupported }
    func release(_ locale: Locale) async {}
    func isInstalled(_ module: SpeechAssetModule, locale: Locale) async -> Bool { false }
    func install(
        _ module: SpeechAssetModule,
        locale: Locale,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        throw SpeechAssetError.unsupported
    }
}

@available(iOS 26, *)
nonisolated struct SystemSpeechAssetInventory: SpeechAssetInventory {

    /// Limit for assetInstallationRequest; downloadAndInstall has none (downloads are slow by nature and report progress).
    var requestLimit: Duration = VoiceDeadline.systemQuery

    static func module(_ module: SpeechAssetModule, locale: Locale) -> any SpeechModule {
        switch module {
        case .speechTranscriber:
            return SpeechTranscriber(locale: locale, preset: .transcription)
        case .dictationTranscriber:
            return DictationTranscriber(locale: locale, preset: .longDictation)
        }
    }

    func maximumReservedLocales() async -> Int {
        AssetInventory.maximumReservedLocales
    }

    func reservedLocales() async -> [Locale] {
        await AssetInventory.reservedLocales
    }

    func reserve(_ locale: Locale) async throws {
        try await AssetInventory.reserve(locale: locale)
    }

    func release(_ locale: Locale) async {
        await AssetInventory.release(reservedLocale: locale)
    }

    func isInstalled(_ module: SpeechAssetModule, locale: Locale) async -> Bool {
        await AssetInventory.status(forModules: [Self.module(module, locale: locale)]) == .installed
    }

    func install(
        _ module: SpeechAssetModule,
        locale: Locale,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        guard let request = try await VoiceDeadline.run(within: requestLimit, {
            try await AssetInventory.assetInstallationRequest(supporting: [Self.module(module, locale: locale)])
        }) else { return }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
            let fraction = value.fractionCompleted
            Task { @MainActor in progress(fraction) }
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }
}
