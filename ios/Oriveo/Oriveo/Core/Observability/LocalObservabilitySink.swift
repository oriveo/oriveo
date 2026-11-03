import Foundation
import os

/// Local implementation of `ObservabilitySink`: the community edition has no official crash reporting, but the measurement core still runs; output goes to the system log and
/// signpost intervals, so developers can see critical-path timings in Console / Instruments using the same fixture names.
@MainActor
final class LocalObservabilitySink: ObservabilitySink {
    static let subsystem = "ai.oriveo.community"

    private let logger = Logger(subsystem: LocalObservabilitySink.subsystem, category: "observability")
    private let signposter = OSSignposter(subsystem: LocalObservabilitySink.subsystem, category: "transaction")

    func beginTransaction(name: String, op: String) -> ObservabilityTransaction {
        LocalObservabilityTransaction(name: name, signposter: signposter, logger: logger)
    }

    func count(_ name: String, value: Int, tags: [String: String]) {
        logger.info("count \(name, privacy: .public) +\(value) \(Self.describe(tags), privacy: .public)")
    }

    func distribution(_ name: String, value: Double, unit: ObservabilityUnit, tags: [String: String]) {
        logger.info(
            "distribution \(name, privacy: .public) \(value) \(unit.rawValue, privacy: .public) \(Self.describe(tags), privacy: .public)"
        )
    }

    func log(level: ObservabilityLevel, message: String, attributes: [String: String]) {
        let line = "\(message) \(Self.describe(attributes))"
        logger.log(level: Self.osLogType(level), "\(line, privacy: .public)")
    }

    func issue(name: String, level: ObservabilityLevel, fingerprint: [String], context: [String: String]) {
        logger.log(
            level: Self.osLogType(level),
            "issue \(name, privacy: .public) [\(fingerprint.joined(separator: ","), privacy: .public)] \(Self.describe(context), privacy: .public)"
        )
    }

    func setContext(_ key: String, _ value: [String: String]) {
        logger.debug("context \(key, privacy: .public) \(Self.describe(value), privacy: .public)")
    }

    func setTag(_ value: String?, key: String) {
        logger.debug("tag \(key, privacy: .public)=\(value ?? "", privacy: .public)")
    }

    nonisolated static func osLogType(_ level: ObservabilityLevel) -> OSLogType {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .fatal: return .fault
        }
    }

    /// Keys are sorted on output, so the same set of values prints identically each time and is easy to filter and compare in Console.
    nonisolated static func describe(_ values: [String: String]) -> String {
        values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: " ")
    }
}

@MainActor
private final class LocalObservabilityTransaction: ObservabilityTransaction {
    private let name: String
    private let signposter: OSSignposter
    private let logger: Logger
    private var state: OSSignpostIntervalState?
    private var tags: [String: String] = [:]
    private var measurements: [String: String] = [:]

    init(name: String, signposter: OSSignposter, logger: Logger) {
        self.name = name
        self.signposter = signposter
        self.logger = logger
        // The signpost name must be a StaticString; the transaction name goes into the interval message so Instruments groups by message.
        state = signposter.beginInterval("transaction", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
    }

    func setTag(_ value: String, key: String) {
        guard state != nil else { return }
        tags[key] = value
    }

    func setMeasurement(_ name: String, value: Double, unit: ObservabilityUnit) {
        guard state != nil else { return }
        measurements[name] = "\(value)\(unit == .none ? "" : unit.rawValue)"
    }

    func finish(status: ObservabilityStatus) {
        guard let state else { return }
        self.state = nil
        signposter.endInterval("transaction", state, "\(self.name, privacy: .public) \(status.rawValue, privacy: .public)")
        let detail = LocalObservabilitySink.describe(tags.merging(measurements) { tag, _ in tag })
        logger.info("transaction \(self.name, privacy: .public) \(status.rawValue, privacy: .public) \(detail, privacy: .public)")
    }

    func discard() {
        guard let state else { return }
        self.state = nil
        // Intervals must close, otherwise Instruments draws them as never ending; marking discarded tells them apart from real completions.
        signposter.endInterval("transaction", state, "\(self.name, privacy: .public) discarded")
    }

    /// The local implementation has no downstream tracing backend.
    var traceHeaders: [String: String] { [:] }
}

/// The single in-process observability exit. The Community Edition ships only the local sink.
@MainActor
enum Observability {
    static let sink: ObservabilitySink = LocalObservabilitySink()
}
