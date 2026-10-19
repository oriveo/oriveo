import Foundation
import OriveoProviderKit
import Testing

// L3 recall micro-benchmark (same method on every platform): 1000 deterministic synthetic episodic items + 200 queries,
// after the index is built, a single recall runs 30 warm-up times and >= 200 timed times, monotonic clock nearest-rank p95 < 30 ms; index build time is also printed.

private enum RecallBench {
    static let vocabulary = [
        "saga", "ending", "release", "database", "postgres", "logo", "venice", "chapter", "deadline", "budget",
        "sprint", "review", "kickoff", "design", "launch", "version", "backend", "analytics", "epilogue", "cover",
        "\u{5C0F}\u{8BF4}", "\u{7ED3}\u{5C40}", "\u{5C01}\u{9762}", "\u{53D1}\u{5E03}", "\u{6570}\u{636E}\u{5E93}", "\u{6C7A}めた", "データ", "데이터", "결정", "\u{65E5}\u{7A0B}",
    ]
    static let itemCount = 1000
    static let queryCount = 200
    static let warmup = 30
    static let nowMs: Int64 = 1_792_195_200_000

    /// Linear congruential generator, deterministic word picking.
    static func word(_ seed: Int) -> String {
        vocabulary[((seed &* 1_103_515_245 &+ 12345) & 0x7fff_ffff) % vocabulary.count]
    }

    static func sentence(_ seed: Int, length: Int) -> String {
        (0..<length).map { word(seed &* 31 &+ $0 &* 7) + String($0 % 5) }.joined(separator: " ")
    }

    static let items: [MemoryItem] = (0..<itemCount).map { index in
        MemoryItem(
            id: String(format: "30000000-0000-4000-8000-%012d", index),
            layer: .episodic,
            kind: index % 2 == 0 ? .decision : .event,
            content: "Decided \(sentence(index, length: 8 + index % 12)) #\(index)",
            mutationId: "00000000-0000-4000-8000-000000000000",
            deviceId: "bench",
            occurredAt: String(format: "2026-%02d-%02dT09:00:00Z", 1 + index % 9, 1 + index % 28)
        )
    }

    static let queries: [String] = (0..<queryCount).map { sentence($0 &* 13 &+ 5, length: 6 + $0 % 6) }

    static let context = MemoryRecallContext(conversationId: "bench", folderId: nil, nowMs: nowMs)
}

private func milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
}

@Suite("ContextMemoryRecallBenchmark", .serialized)
struct ContextMemoryRecallBenchmarkTests {
    @Test("recall_1000_items_p95")
    func recall_1000_items_p95() {
        let clock = ContinuousClock()
        var index = MemoryRecall.buildIndex([])
        let build = clock.measure { index = MemoryRecall.buildIndex(RecallBench.items) }
        print(String(format: "ContextMemoryRecallBenchmark build_index_1000 ms=%.2f", milliseconds(build)))
        #expect(index.count == RecallBench.itemCount)

        let hitCount = RecallBench.queries.reduce(0) {
            $0 + MemoryRecall.recall(index, query: $1, context: RecallBench.context).count
        }
        #expect(hitCount > 0, "synthetic queries never hit")

        for position in 0..<RecallBench.warmup {
            _ = MemoryRecall.recall(index, query: RecallBench.queries[position], context: RecallBench.context)
        }
        var samples: [Double] = []
        samples.reserveCapacity(RecallBench.queryCount)
        for query in RecallBench.queries {
            let duration = clock.measure {
                _ = MemoryRecall.recall(index, query: query, context: RecallBench.context)
            }
            samples.append(milliseconds(duration))
        }
        samples.sort()
        func rank(_ q: Double) -> Double {
            samples[Int((q * Double(samples.count)).rounded(.up)) - 1]
        }
        let p50 = rank(0.5), p95 = rank(0.95)
        print(String(format: "ContextMemoryRecallBenchmark recall_1000_items p50=%.3f p95=%.3f n=%d", p50, p95, samples.count))
        #expect(samples.count >= 200)
        #expect(p95 < 30, "p95 \(p95) ms")
    }
}
