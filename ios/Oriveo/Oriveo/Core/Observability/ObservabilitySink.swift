import Foundation

/// Terminal state of a transaction. Values match the shared fixture `mobile-telemetry.v1.json` `status_values` exactly.
nonisolated enum ObservabilityStatus: String, CaseIterable, Sendable {
    case ok
    case internalError = "internal_error"
    case cancelled
    case deadlineExceeded = "deadline_exceeded"
}

/// Units of measurements / distributions; values match the unit strings in the fixture `measurements`.
nonisolated enum ObservabilityUnit: String, CaseIterable, Sendable {
    case millisecond
    case none
}

nonisolated enum ObservabilityLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
    case fatal
}

/// An in-flight transaction. `finish` and `discard` are both terminal: any call after either is ignored.
///
/// Discard = not reported: a wait such as being replaced, leaving, or going to the background is not UI time, and closing it in any state would pollute the distribution.
@MainActor
protocol ObservabilityTransaction: AnyObject {
    func setTag(_ value: String, key: String)
    func setMeasurement(_ name: String, value: Double, unit: ObservabilityUnit)
    func finish(status: ObservabilityStatus)
    func discard()
    /// Tracing headers (`sentry-trace` / `baggage`) that continue into a downstream service; empty when the backend does not support them.
    var traceHeaders: [String: String] { get }
}

/// The observability exit. The measurement core (`ChatPerformanceMonitor` and the like) only knows this protocol, not any concrete backend:
/// the official build injects `SentryObservabilitySink`, the community build injects `LocalObservabilitySink` (os_log + signpost),
/// and both share the same measurement code and fixture naming.
///
/// Names (transactions, ops, tags, measurements, metrics) must come from the shared fixture; contract tests check them verbatim.
@MainActor
protocol ObservabilitySink: AnyObject {
    func beginTransaction(name: String, op: String) -> ObservabilityTransaction
    func count(_ name: String, value: Int, tags: [String: String])
    func distribution(_ name: String, value: Double, unit: ObservabilityUnit, tags: [String: String])
    func log(level: ObservabilityLevel, message: String, attributes: [String: String])
    /// `name` is the literal registered in the fixture `diagnostics.issue` and must not be interpolated; `context` holds only low-cardinality values, written by tag.
    func issue(name: String, level: ObservabilityLevel, fingerprint: [String], context: [String: String])
    /// Overwrites a whole context key (such as `oriveo_state`) at once; values hold only bucketed numbers and enums, never content or ids.
    func setContext(_ key: String, _ value: [String: String])
    /// Global tag (every later event carries it); nil removes it. Keys must come from the fixture `tags`.
    func setTag(_ value: String?, key: String)
}

/// Entry point for emitting metrics from callers that are not on the main thread (the DB write thread, the SDK's beforeSend): the sink is MainActor-isolated, so this hops over.
/// When already on the main thread it hands off synchronously, so main-thread metrics do not wait an extra round of the main queue.
nonisolated enum ObservabilityRelay {
    static func count(_ name: String, value: Int = 1, tags: [String: String]) {
        onMain { $0.count(name, value: value, tags: tags) }
    }

    static func distribution(_ name: String, value: Double, unit: ObservabilityUnit, tags: [String: String]) {
        onMain { $0.distribution(name, value: value, unit: unit, tags: tags) }
    }

    private static func onMain(_ body: @escaping @MainActor @Sendable (ObservabilitySink) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(Observability.sink) }
        } else {
            Task { @MainActor in body(Observability.sink) }
        }
    }
}

/// Bucketing of context and tags. Boundaries and labels come from the fixture `buckets`; tests assert each case of the fixture `cases`.
nonisolated enum ObservabilityBuckets {
    static let countEdges: [Double] = [0, 1, 10, 50, 200, 1000]
    static let countLabels = ["0", "1-9", "10-49", "50-199", "200-999", "1000+"]
    static let sizeMBEdges: [Double] = [0, 10, 100, 500]
    static let sizeMBLabels = ["<10", "10-99", "100-499", "500+"]
    static let heightPtEdges: [Double] = [0, 1000, 10000, 100_000, 1_000_000]
    static let heightPtLabels = ["<1k", "1k-10k", "10k-100k", "100k-1m", "1m+"]
    static let nonFiniteLabel = "non_finite"

    static func count(_ value: Int) -> String {
        bucket(Double(value), edges: countEdges, labels: countLabels)
    }

    static func sizeMB(_ value: Double) -> String {
        bucket(value, edges: sizeMBEdges, labels: sizeMBLabels)
    }

    /// A layout height may be NaN / inf (geometry anomalies are exactly what we want to observe); it gets its own bucket and is not mixed into any numeric tier.
    static func heightPt(_ value: Double) -> String {
        guard value.isFinite else { return nonFiniteLabel }
        return bucket(value, edges: heightPtEdges, labels: heightPtLabels)
    }

    /// A value in `[edges[i], edges[i+1])` records `labels[i]`; below the first edge records the first tier, and past the last edge records the last tier.
    static func bucket(_ value: Double, edges: [Double], labels: [String]) -> String {
        precondition(edges.count == labels.count && !labels.isEmpty)
        var index = 0
        for (i, edge) in edges.enumerated() where value >= edge {
            index = i
        }
        return labels[index]
    }
}
