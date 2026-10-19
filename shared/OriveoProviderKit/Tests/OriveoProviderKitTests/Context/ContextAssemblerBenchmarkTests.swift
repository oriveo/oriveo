import Foundation
import OriveoProviderKit
import Testing

// Context assembly micro-benchmark (same method on every platform): deterministic 500-message history of about 100k tokens,
// 30 warm-up runs and 200 timed runs, monotonic clock, nearest-rank p95; the threshold is not relaxed when it is exceeded.
// On iOS each send assembles k = 2 times (refusal pre-check + the actual send).

private enum BenchData {
    static let paragraphs = [
        "\u{4E0A}\u{4E0B}\u{6587}\u{7BA1}\u{7EBF}\u{5728}\u{53D1}\u{9001}\u{524D}\u{7EC4}\u{88C5}\u{5386}\u{53F2}\u{6D88}\u{606F}，\u{5E76}\u{6309}\u{9884}\u{7B97}\u{88C1}\u{526A}\u{6700}\u{65E9}\u{7684}\u{8F6E}\u{6B21}。",
        "The assembler trims the oldest turns first and keeps the current user message intact.",
        "يقوم المجمّع بقص أقدم الأدوار أولاً ويحافظ على رسالة المستخدم الحالية.",
        "```swift\nfunc add(_ a: Int, _ b: Int) -> Int { a + b }\n```",
    ]
    static let rhoHi = 0.5
    static let warmup = 30
    static let iterations = 200
    static let sendPathAssembleCount = 2

    /// Body of message i: paragraph S(i%4) repeated joined with "\n" until the estimate is >= 200.
    static func body(_ index: Int) -> String {
        let paragraph = paragraphs[index % 4]
        var text = paragraph
        while ContextBudget.estimateMessage(text, rhoHi: rhoHi) < 200 {
            text += "\n" + paragraph
        }
        return text
    }

    static let history: [ContextMessage] = (0..<500).map { index in
        ContextMessage(
            id: String(format: "m%03d", index),
            role: index % 2 == 0 ? .user : .assistant,
            text: body(index),
            state: .delivered
        )
    }

    static func input(W: Int) -> ContextAssembleInput {
        ContextAssembleInput(
            purpose: .chat,
            window: ContextWindowInput(
                W: W,
                windowKind: .total,
                maxOutput: ContextMaxOutputSources(model: 8192)
            ),
            rhoHi: rhoHi,
            conversation: ContextConversation(
                id: "bench",
                useMemory: false,
                instructions: Array(repeating: paragraphs[1], count: 6).joined(separator: " ")
            ),
            history: history,
            current: "Summarize the discussion above.",
            currentId: "m500"
        )
    }
}

/// Times n runs after warm-up and returns (p50, p95) in milliseconds; nearest-rank index ceil(q*n)-1.
@discardableResult
private func measure(_ name: String, _ body: () throws -> Void) rethrows -> (p50: Double, p95: Double, max: Double) {
    for _ in 0..<BenchData.warmup { try body() }
    let clock = ContinuousClock()
    var samples: [Double] = []
    samples.reserveCapacity(BenchData.iterations)
    for _ in 0..<BenchData.iterations {
        let duration = try clock.measure { try body() }
        let parts = duration.components
        samples.append(Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
    }
    samples.sort()
    func rank(_ q: Double) -> Double {
        samples[Int((q * Double(samples.count)).rounded(.up)) - 1]
    }
    let p50 = rank(0.5), p95 = rank(0.95), max = samples[samples.count - 1]
    print(String(format: "ContextAssemblerBenchmark %@ p50=%.2f p95=%.2f n=%d", name, p50, p95, samples.count))
    print(String(format: "ContextAssemblerBenchmark %@ max=%.2f", name, max))
    return (p50, p95, max)
}

@Suite("ContextAssemblerBenchmark", .serialized)
struct ContextAssemblerBenchmarkTests {
    @Test("dataset estimate within [100000, 120000]")
    func datasetEstimate() {
        let total = BenchData.history.reduce(0) { $0 + ContextBudget.estimateMessage($1.text, rhoHi: BenchData.rhoHi) }
        #expect((100_000...120_000).contains(total), "estimate total \(total)")
    }

    @Test("assemble_500_messages_100k_tokens_p95")
    func assemble_500_messages_100k_tokens_p95() {
        let input = BenchData.input(W: 200_000)
        let plan = ContextAssembler.assemble(input)
        #expect(plan.messages?.count == 501)
        let result = measure("assemble_500_messages_100k_tokens_p95") {
            _ = ContextAssembler.assemble(input)
        }
        #expect(result.p95 <= 8, "p95 \(result.p95) ms")
    }

    @Test("assemble_trimmed_window_p95")
    func assemble_trimmed_window_p95() {
        let input = BenchData.input(W: 64_000)
        let plan = ContextAssembler.assemble(input)
        // The iOS chat path does not delete messages and gives a compaction suggestion when over budget.
        #expect(plan.compaction == .required)
        let result = measure("assemble_trimmed_window_p95") {
            _ = ContextAssembler.assemble(input)
        }
        #expect(result.p95 <= 8, "p95 \(result.p95) ms")
    }

    @Test("send_path_extra_latency_p95")
    func send_path_extra_latency_p95() throws {
        let input = BenchData.input(W: 200_000)
        let result = try measure("send_path_extra_latency_p95") {
            var plan = ContextAssembler.assemble(input)
            for _ in 1..<BenchData.sendPathAssembleCount {
                plan = ContextAssembler.assemble(input)
            }
            _ = try ContextWireAdapter.project(plan: plan, family: .openaiChat)
        }
        // Split timing (extra printed line): p50 / p95 / max of the k assemble calls and the project call separately.
        try measure("send_path_split_assemble_x\(BenchData.sendPathAssembleCount)") {
            for _ in 0..<BenchData.sendPathAssembleCount {
                _ = ContextAssembler.assemble(input)
            }
        }
        let plan = ContextAssembler.assemble(input)
        try measure("send_path_split_project") {
            _ = try ContextWireAdapter.project(plan: plan, family: .openaiChat)
        }
        #expect(result.p95 <= 15, "p95 \(result.p95) ms")
    }
}
