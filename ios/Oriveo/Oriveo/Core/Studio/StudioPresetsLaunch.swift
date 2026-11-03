import Foundation

/// Launch-time preset refresh. Hidden entry → nothing (the store is not called). Visible entry →
/// one throttled `refreshIfNeeded` for the preset locale resolved from the app language; when the
/// body was replaced, the sample cache is pruned to the samples of the current styles. Any other
/// outcome leaves the cache alone. Never prefetches sample images. Runs off the main actor (the
/// locale list is read from the bundled snapshot).
nonisolated enum StudioPresetsLaunch {
    /// `entryVisible` = compile flag && remote `studio_enabled` (missing = true), see
    /// `StudioAvailability.evaluate`. Returns nil when the entry is hidden.
    @concurrent
    @discardableResult
    static func run(
        entryVisible: Bool,
        appLanguageTag: String,
        store: StudioPresetsStore,
        sampleCache: StudioPresetSampleCache,
        bundle: Bundle = .main
    ) async -> StudioPresets.Outcome? {
        guard entryVisible else { return nil }
        let locale = StudioPresets.resolveLocale(presetLocales(bundle: bundle), appLanguageTag)
        let outcome = await store.refreshIfNeeded(locale: locale)
        guard outcome == .replaced else { return outcome }
        // Without a readable current set there is nothing to keep against, so the cache stays as is.
        guard let styles = await store.current(locale: locale)?.styles else { return outcome }
        await sampleCache.prune(keep: Set(styles.compactMap { $0.sample?.sha256 }))
        return outcome
    }

    /// The preset locales listed by the bundled snapshot; empty when it cannot be read
    /// (`resolveLocale` then still maps zh by script and falls back to en).
    static func presetLocales(bundle: Bundle = .main) -> [String] {
        StudioPresets.bundledSnapshot(bundle: bundle)?["locales"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}
