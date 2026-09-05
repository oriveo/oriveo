import Foundation
import os

/// On-device diagnostics. Everything written here goes to the unified system log
/// on this device and never leaves it.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Oriveo"

    private static func logger(module: String) -> Logger {
        Logger(subsystem: subsystem, category: module)
    }

    static func error(_ error: Error, module: String, context: [String: String] = [:]) {
        logger(module: module).error("\(describe(error), privacy: .public)\(format(context), privacy: .public)")
    }

    static func warning(_ message: String, module: String, context: [String: String] = [:]) {
        logger(module: module).warning("\(message, privacy: .public)\(format(context), privacy: .public)")
    }

    static func info(_ message: String, module: String, context: [String: String] = [:]) {
        logger(module: module).info("\(message, privacy: .public)\(format(context), privacy: .public)")
    }

    private static func describe(_ error: Error) -> String {
        String(describing: error)
    }

    private static func format(_ context: [String: String]) -> String {
        guard !context.isEmpty else { return "" }
        let pairs = context
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return " [\(pairs)]"
    }

    /// Collapses repeated failures of the same kind so a broken loop cannot flood the log.
    /// Returns how many occurrences were swallowed since the previous report.
    final class FailureThrottle: @unchecked Sendable {
        private let window: TimeInterval
        private let lock = NSLock()
        private var state: [String: (firstAt: Date, suppressed: Int)] = [:]

        init(window: TimeInterval = 60) {
            self.window = window
        }

        func shouldReport(key: String, now: Date = Date()) -> (shouldReport: Bool, suppressedSinceLastReport: Int) {
            lock.lock()
            defer { lock.unlock() }
            if let existing = state[key], now.timeIntervalSince(existing.firstAt) < window {
                state[key] = (existing.firstAt, existing.suppressed + 1)
                return (false, existing.suppressed + 1)
            }
            let suppressed = state[key]?.suppressed ?? 0
            state[key] = (now, 0)
            return (true, suppressed)
        }
    }
}
