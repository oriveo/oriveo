import Foundation
import OriveoProviderKit
import Testing

// Runs summaryPromptCases / summaryRequestCases / compactCases / breakerCases of
// `shared/context-contracts/checkpoint.v1.json` case by case, calling only production functions; failure messages carry the fixture case id.

private struct CompactorContract {
    var constants: [String: Any]
    var root: [String: Any]

    init() throws {
        let data = try ContextContractFixture.data("checkpoint.v1.json")
        root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        constants = try #require(root["constants"] as? [String: Any])
    }

    func cases(_ group: String) throws -> [[String: Any]] {
        try #require(root[group] as? [[String: Any]], "\(group)")
    }
}

private func checkpointMessages(_ raw: Any?, id: String) throws -> [ContextCheckpoint.Message] {
    let list = try #require(raw as? [[String: Any]], "\(id)")
    return try list.map { item in
        let role = try #require(item["role"] as? String, "\(id)")
        return ContextCheckpoint.Message(
            id: try #require(item["id"] as? String, "\(id)"),
            role: try #require(ContextMessageRole(rawValue: role), "\(id)"),
            estTokens: try #require(item["estTokens"] as? Int, "\(id)"),
            text: item["text"] as? String,
            isDirective: item["isDirective"] as? Bool ?? false
        )
    }
}

private func spanMessages(_ raw: Any?, id: String) throws -> [ContextCompactor.SpanMessage] {
    let list = try #require(raw as? [[String: Any]], "\(id)")
    return try list.map { item in
        let role = try #require(item["role"] as? String, "\(id)")
        let attachments = try (item["attachments"] as? [[String: Any]] ?? []).map { attachment in
            let kind = try #require(attachment["kind"] as? String, "\(id)")
            return ContextCompactor.Attachment(
                kind: try #require(ContextCompactor.AttachmentKind(rawValue: kind), "\(id)"),
                name: try #require(attachment["name"] as? String, "\(id)")
            )
        }
        return ContextCompactor.SpanMessage(
            id: try #require(item["id"] as? String, "\(id)"),
            role: try #require(ContextMessageRole(rawValue: role), "\(id)"),
            text: try #require(item["text"] as? String, "\(id)"),
            attachments: attachments
        )
    }
}

@Suite("ContextContractCompactor")
struct ContextContractCompactorTests {
    private let contract: CompactorContract

    init() throws {
        contract = try CompactorContract()
    }

    @Test("constants_equal_fixture")
    func constantsMatchFixture() {
        #expect(ContextCompactor.summaryPromptTemplate == contract.constants["summaryPromptTemplate"] as? String)
        #expect(ContextCompactor.languageFallback == contract.constants["languageFallback"] as? String)
        #expect(ContextCompactor.serializedSystem == contract.constants["serializedSystem"] as? String)
        #expect(ContextCompactor.attachmentPlaceholder == contract.constants["attachmentPlaceholder"] as? String)
        #expect(ContextCompactor.maxSummaryAttempts == contract.constants["maxSummaryAttempts"] as? Int)
        let breaker = contract.constants["breaker"] as? [String: Any]
        #expect(ContextCompactionBreaker.failuresToTrip == breaker?["failuresToTrip"] as? Int)
        #expect(ContextCompactionBreaker.fallbackTurns == breaker?["fallbackTurns"] as? Int)
    }

    @Test("summaryPrompt")
    func summaryPrompt() throws {
        let cases = try contract.cases("summaryPromptCases")
        #expect(cases.count == 3)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let text = ContextCompactor.summaryPrompt(
                language: input["language"] as? String,
                summaryMax: try #require(input["summaryMax"] as? Int, "\(id)")
            )
            let expected = try #require(raw["expected"] as? String, "\(id)")
            #expect(Array(text.utf8) == Array(expected.utf8), "\(id)")
        }
    }

    @Test("summaryRequest")
    func summaryRequest() throws {
        let cases = try contract.cases("summaryRequestCases")
        #expect(cases.count == 6)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let expected = try #require(raw["expected"] as? [String: Any], "\(id)")
            let result = ContextCompactor.summaryRequest(ContextCompactor.SummaryRequestInput(
                U: try #require(input["U"] as? Int, "\(id)"),
                prefixTokens: try #require(input["prefixTokens"] as? Int, "\(id)"),
                rhoHi: try #require(input["rhoHi"] as? Double, "\(id)"),
                language: input["language"] as? String,
                summaryMax: try #require(input["summaryMax"] as? Int, "\(id)"),
                previousCheckpointText: input["previousCheckpointText"] as? String,
                previousSummary: input["previousSummary"] as? String,
                span: try spanMessages(input["span"], id: id)
            ))
            #expect(result.shape.rawValue == expected["shape"] as? String, "\(id)")
            if result.shape == .tooLarge {
                #expect(result.appendedTokens == expected["appendedTokens"] as? Int, "\(id)")
                #expect(result.serializedTokens == expected["serializedTokens"] as? Int, "\(id)")
                #expect(result.messages.isEmpty, "\(id)")
                #expect(result.system == nil, "\(id)")
                #expect(result.toolChoice == nil, "\(id)")
                #expect(result.maxOutputTokens == nil, "\(id)")
                #expect(result.estInputTokens == nil, "\(id)")
                continue
            }
            #expect(result.appendedTokens == nil, "\(id)")
            #expect(result.serializedTokens == nil, "\(id)")
            #expect(result.system == expected["system"] as? String, "\(id)")
            #expect(result.toolChoice == expected["toolChoice"] as? String, "\(id)")
            #expect(result.maxOutputTokens == expected["maxOutputTokens"] as? Int, "\(id)")
            #expect(result.estInputTokens == expected["estInputTokens"] as? Int, "\(id)")
            let rawMessages = try #require(expected["messages"] as? [[String: Any]], "\(id)")
            let expectedMessages = try rawMessages.map { item in
                let role = try #require(item["role"] as? String, "\(id)")
                return ContextCompactor.RequestMessage(
                    role: try #require(ContextMessageRole(rawValue: role), "\(id)"),
                    text: try #require(item["text"] as? String, "\(id)")
                )
            }
            #expect(result.messages == expectedMessages, "\(id)")
        }
    }

    @Test("compact")
    func compact() throws {
        let cases = try contract.cases("compactCases")
        #expect(cases.count == 6)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let expected = try #require(raw["expected"] as? [String: Any], "\(id)")
            let previous = try (input["previous"] as? [String: Any]).map { item in
                ContextCompactor.Previous(
                    coversTo: try #require(item["coversTo"] as? String, "\(id)"),
                    summary: item["summary"] as? String
                )
            }
            let outputs = try #require(input["summaryOutputs"] as? [Any], "\(id)").map { $0 as? String }
            let result = ContextCompactor.compact(ContextCompactor.CompactInput(
                conversationId: try #require(input["conversationId"] as? String, "\(id)"),
                B: try #require(input["B"] as? Int, "\(id)"),
                rhoHi: try #require(input["rhoHi"] as? Double, "\(id)"),
                messages: try checkpointMessages(input["messages"], id: id),
                previous: previous,
                summaryOutputs: outputs
            ))
            #expect(result.outcome.rawValue == expected["outcome"] as? String, "\(id)")
            if result.outcome == .noop {
                #expect(result.spanTokens == nil, "\(id)")
                continue
            }
            #expect(result.attempts == expected["attempts"] as? Int, "\(id)")
            #expect(result.failures.map { $0.map(\.rawValue) } == (expected["failures"] as? [[String]]), "\(id)")
            #expect(result.spanTokens == expected["spanTokens"] as? Int, "\(id)")
            guard result.outcome == .summary else {
                // fallback has the fixture shape on every platform, carrying only outcome / attempts / failures / spanTokens.
                #expect(result.coversFrom == nil, "\(id)")
                #expect(result.coversTo == nil, "\(id)")
                #expect(result.messagesCovered == nil, "\(id)")
                #expect(result.keptUserIds == nil, "\(id)")
                #expect(result.checkpointId == nil, "\(id)")
                #expect(result.coversDigest == nil, "\(id)")
                #expect(result.text == nil, "\(id)")
                continue
            }
            #expect(result.coversFrom == expected["coversFrom"] as? String, "\(id)")
            #expect(result.coversTo == expected["coversTo"] as? String, "\(id)")
            #expect(result.messagesCovered == expected["messagesCovered"] as? Int, "\(id)")
            #expect(result.keptUserIds == (expected["keptUserIds"] as? [String]), "\(id)")
            #expect(result.checkpointId == expected["checkpointId"] as? String, "\(id)")
            #expect(result.coversDigest == expected["coversDigest"] as? String, "\(id)")
            let text = try #require(expected["text"] as? String, "\(id)")
            #expect(Array((result.text ?? "").utf8) == Array(text.utf8), "\(id)")
        }
    }

    @Test("breaker")
    func breaker() throws {
        let cases = try contract.cases("breakerCases")
        #expect(cases.count == 4)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let events = try #require(raw["events"] as? [String], "\(id)")
            let expected = try #require(raw["expected"] as? [[String: Any]], "\(id)")
            #expect(events.count == expected.count, "\(id)")
            var breaker = ContextCompactionBreaker()
            for (index, name) in events.enumerated() {
                let event = try #require(ContextCompactionBreaker.Event(rawValue: name), "\(id)")
                let state = breaker.apply(event)
                let want = expected[index]
                #expect(state.mode.rawValue == want["mode"] as? String, "\(id)#\(index)")
                #expect(state.failures == want["failures"] as? Int, "\(id)#\(index)")
                #expect(state.turnsLeft == want["turnsLeft"] as? Int, "\(id)#\(index)")
            }
        }
    }
}
