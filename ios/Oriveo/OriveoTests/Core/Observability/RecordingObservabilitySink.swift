import Foundation
@testable import Oriveo

/// Recording sink: asserts when, in what state, and with which tags and measurements the measurement core finishes.
@MainActor
final class RecordingObservabilitySink: ObservabilitySink {
    enum Phase: Equatable {
        case begin
        case end
        case discard
    }

    struct Event: Equatable {
        let phase: Phase
        let name: String
        let status: ObservabilityStatus?
    }

    final class Transaction: ObservabilityTransaction {
        let name: String
        let op: String
        private(set) var tags: [String: String] = [:]
        private(set) var measurements: [String: (value: Double, unit: ObservabilityUnit)] = [:]
        private(set) var status: ObservabilityStatus?
        private(set) var isDiscarded = false
        private weak var sink: RecordingObservabilitySink?
        let traceHeaders: [String: String]

        init(name: String, op: String, sink: RecordingObservabilitySink) {
            self.name = name
            self.op = op
            self.sink = sink
            traceHeaders = sink.nextTraceHeaders
        }

        private var isOpen: Bool { status == nil && !isDiscarded }

        func setTag(_ value: String, key: String) {
            guard isOpen else { return }
            tags[key] = value
        }

        func setMeasurement(_ name: String, value: Double, unit: ObservabilityUnit) {
            guard isOpen else { return }
            measurements[name] = (value, unit)
        }

        func finish(status: ObservabilityStatus) {
            guard isOpen else { return }
            self.status = status
            sink?.events.append(Event(phase: .end, name: name, status: status))
        }

        func discard() {
            guard isOpen else { return }
            isDiscarded = true
            sink?.events.append(Event(phase: .discard, name: name, status: nil))
        }
    }

    var events: [Event] = []
    /// Trace header reported by transactions created afterwards (for testing trace propagation).
    var nextTraceHeaders: [String: String] = [:]
    private(set) var transactions: [Transaction] = []
    private(set) var counts: [(name: String, value: Int, tags: [String: String])] = []
    private(set) var distributions: [(name: String, value: Double, unit: ObservabilityUnit)] = []
    private(set) var issues: [(name: String, fingerprint: [String])] = []
    private(set) var contexts: [String: [String: String]] = [:]
    private(set) var contextWriteCount = 0
    private(set) var tags: [String: String] = [:]

    func beginTransaction(name: String, op: String) -> ObservabilityTransaction {
        let transaction = Transaction(name: name, op: op, sink: self)
        transactions.append(transaction)
        events.append(Event(phase: .begin, name: name, status: nil))
        return transaction
    }

    func count(_ name: String, value: Int, tags: [String: String]) {
        counts.append((name, value, tags))
    }

    func distribution(_ name: String, value: Double, unit: ObservabilityUnit, tags: [String: String]) {
        distributions.append((name, value, unit))
    }

    func log(level: ObservabilityLevel, message: String, attributes: [String: String]) {}

    func issue(name: String, level: ObservabilityLevel, fingerprint: [String], context: [String: String]) {
        issues.append((name, fingerprint))
    }

    func setContext(_ key: String, _ value: [String: String]) {
        contexts[key] = value
        contextWriteCount += 1
    }

    func setTag(_ value: String?, key: String) {
        tags[key] = value
    }
}
