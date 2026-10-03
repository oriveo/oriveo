import Foundation
import OriveoProviderKit
import Testing
@testable import Oriveo

// The tool loop's handling of results that are neither a success nor a fault, of a stop request that
// arrives in the middle of a leg, and of names that must survive the round trip to the model unchanged.

@Suite("Tool call loop behaviour")
struct ToolCallLoopBehaviorTests {
    @Test("a neutral result is fed back as ok:false and neither counts towards nor resets the failure streak")
    func neutralResultsLeaveTheFailureStreakAlone() async throws {
        let runner = ScriptedLegRunner([
            [.toolCalls([("c1", "lookup"), ("c2", "lookup"), ("c3", "lookup"), ("c4", "lookup")])],
            [.text("Nothing was found.")],
        ])
        let loop = ToolCallLoop(
            registry: ToolRegistry(entries: [ThrowingEntry(name: "lookup", disposition: .neutral(code: "not_found", message: "No such item."))]),
            legRunner: runner,
            limits: ToolCallLoop.Limits(maxSteps: 6, maxConsecutiveToolFailures: 3)
        )

        let result = try await loop.run(messages: [ToolLoopMessage(role: "user", content: "look them up")])

        #expect(result.text == "Nothing was found.", "four neutral results in a row do not end the turn")
        #expect(result.executedToolSteps == 4, "each neutral result still uses up a tool step")
        let fedBack = runner.requests()[1].messages.filter { $0.role == "tool" }.compactMap(\.content)
        #expect(fedBack.count == 4)
        #expect(fedBack.allSatisfy { $0.contains("not_found") && $0.contains("\"ok\":false") })
    }

    @Test("a neutral result between two failures does not reset the streak: the third real failure still throws")
    func neutralResultDoesNotResetTheStreak() async throws {
        let runner = ScriptedLegRunner([
            [.toolCalls([("c1", "broken"), ("c2", "broken"), ("c3", "lookup"), ("c4", "broken")])],
            [.text("unreachable")],
        ])
        let loop = ToolCallLoop(
            registry: ToolRegistry(entries: [
                ThrowingEntry(name: "broken", disposition: .degrade(code: "tool_error", message: "The tool failed.")),
                ThrowingEntry(name: "lookup", disposition: .neutral(code: "not_found", message: "No such item.")),
            ]),
            legRunner: runner,
            limits: ToolCallLoop.Limits(maxSteps: 6, maxConsecutiveToolFailures: 3)
        )

        await #expect(throws: ScriptedToolError.self) {
            _ = try await loop.run(messages: [ToolLoopMessage(role: "user", content: "go")])
        }
        #expect(runner.requests().count == 1, "the turn ended inside the first leg")
    }

    @Test("calls skipped at the step limit are fed back with the configured error code")
    func skippedCallsCarryTheConfiguredErrorCode() async throws {
        let runner = ScriptedLegRunner([
            [.toolCalls([("c1", "echo"), ("c2", "echo")])],
            [.text("Done.")],
        ])
        var prompts = ToolCallLoop.Prompts()
        prompts.stoppedErrorCode = "tool_loop_stopped"
        let loop = ToolCallLoop(
            registry: ToolRegistry(entries: [EchoEntry(name: "echo")]),
            legRunner: runner,
            limits: ToolCallLoop.Limits(maxSteps: 1),
            prompts: prompts
        )

        let result = try await loop.run(messages: [ToolLoopMessage(role: "user", content: "go")])

        #expect(result.stepLimitReached)
        let fedBack = runner.requests()[1].messages.filter { $0.role == "tool" }.compactMap(\.content)
        #expect(fedBack.count == 2)
        #expect(fedBack[0].contains("\"ok\":true"))
        #expect(fedBack[1].contains("tool_loop_stopped"))
        #expect(ToolCallLoop.Prompts().stoppedErrorCode == "research_stopped", "the default code is unchanged")
    }

    @Test("stopping while a tool runs keeps the remaining calls of the same leg from running")
    func cancellationIsCheckedBeforeEveryTool() async throws {
        let runner = ScriptedLegRunner([
            [.toolCalls([("c1", "first"), ("c2", "second")])],
            [.text("unreachable")],
        ])
        let secondRan = Flag()
        let loop = ToolCallLoop(
            registry: ToolRegistry(entries: [
                // The first tool swallows the cancellation it triggers, the way a tool that already sent its
                // request would; the loop itself has to notice before starting the next one.
                BlockEntry(name: "first") { withUnsafeCurrentTask { $0?.cancel() } },
                BlockEntry(name: "second") { secondRan.set() },
            ]),
            legRunner: runner,
            limits: ToolCallLoop.Limits(maxSteps: 6)
        )

        let task = Task { try await loop.run(messages: [ToolLoopMessage(role: "user", content: "go")]) }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!secondRan.isSet)
    }

    @Test("registry entries are listed in registration order")
    func registryListsEntriesInOrder() {
        let registry = ToolRegistry(entries: [EchoEntry(name: "b"), EchoEntry(name: "a"), EchoEntry(name: "b")])
        #expect(registry.entries.map(\.name) == ["b", "a"])
        #expect(registry.names == ["b", "a"])
    }

    @Test("the loop's chat decoder returns function names exactly as they were sent")
    func chatDecoderKeepsWireNames() {
        // `_de` would be read as an escaped byte by the function-name codec.
        let frame: [String: Any] = [
            "choices": [[
                "delta": ["tool_calls": [[
                    "index": 0, "id": "call_1", "type": "function",
                    "function": ["name": "mcp_notes_delete_page", "arguments": "{}"],
                ]]],
                "finish_reason": "tool_calls",
            ]],
        ]
        var decoder = OpenAIChatToolAdapter().makeStreamDecoder()
        #expect(decoder.ingest(frame: frame).map(\.name) == ["mcp_notes_delete_page"])
    }
}

// MARK: - Fixtures

private struct ScriptedToolError: Error {}

private enum ScriptedLegStep {
    case text(String)
    case toolCalls([(id: String, name: String)])
}

/// Replays one scripted leg per request and records the requests it was given.
private final class ScriptedLegRunner: ToolLoopLegRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var legs: [[ScriptedLegStep]]
    private var received: [ToolLoopLegRequest] = []

    init(_ legs: [[ScriptedLegStep]]) {
        self.legs = legs
    }

    func requests() -> [ToolLoopLegRequest] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    func run(request: ToolLoopLegRequest) -> AsyncThrowingStream<ToolLoopLegEvent, Error> {
        lock.lock()
        received.append(request)
        let leg = legs.isEmpty ? [] : legs.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for step in leg {
                switch step {
                case let .text(text):
                    continuation.yield(.textDelta(text))
                case let .toolCalls(calls):
                    continuation.yield(.toolCallDeltas(calls.enumerated().map { index, call in
                        ToolLoopToolCallDelta(index: index, id: call.id, type: "function", name: call.name, arguments: "{}")
                    }))
                }
            }
            continuation.finish()
        }
    }
}

private func scriptedDefinition(_ name: String) -> ToolLoopToolDefinition {
    ToolLoopToolDefinition(function: .init(name: name, description: name, parameters: .object([:])))
}

private struct EchoEntry: ToolRegistryEntry {
    let name: String
    var scope: ToolScope { .mcp }
    var definition: ToolLoopToolDefinition? { scriptedDefinition(name) }

    func execute(_ call: ToolLoopToolCall, context: ToolExecutionContext) async throws -> ToolExecutionOutcome {
        ToolExecutionOutcome(content: ToolCallLoop.jsonContent(["ok": true]))
    }
}

/// Always throws, and reports the given disposition for that failure.
private struct ThrowingEntry: ToolRegistryEntry {
    let name: String
    let disposition: ToolFailureDisposition
    var scope: ToolScope { .mcp }
    var definition: ToolLoopToolDefinition? { scriptedDefinition(name) }

    func execute(_ call: ToolLoopToolCall, context: ToolExecutionContext) async throws -> ToolExecutionOutcome {
        throw ScriptedToolError()
    }

    func failureDisposition(for error: any Error) -> ToolFailureDisposition { disposition }
}

/// Runs a block and reports success.
private struct BlockEntry: ToolRegistryEntry {
    let name: String
    let block: @Sendable () -> Void
    var scope: ToolScope { .mcp }
    var definition: ToolLoopToolDefinition? { scriptedDefinition(name) }

    func execute(_ call: ToolLoopToolCall, context: ToolExecutionContext) async throws -> ToolExecutionOutcome {
        block()
        return ToolExecutionOutcome(content: ToolCallLoop.jsonContent(["ok": true]))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}
