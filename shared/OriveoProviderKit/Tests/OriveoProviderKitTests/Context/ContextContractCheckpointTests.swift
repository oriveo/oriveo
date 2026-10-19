import Foundation
import OriveoProviderKit
import Testing

// Runs spanCases / userMessageCases / serializeCases / validateCases / idCases / concurrencyCases / fallbackCases
// of `shared/context-contracts/checkpoint.v1.json` case by case, calling only production functions; failure messages carry the fixture case id.

private struct CheckpointContract {
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

private func string(_ value: Any?) -> String? {
    value as? String
}

private func messages(_ raw: Any?, id: String) throws -> [ContextCheckpoint.Message] {
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

private func kept(_ raw: Any?, id: String) throws -> [ContextCheckpoint.KeptMessage] {
    let list = try #require(raw as? [[String: Any]], "\(id)")
    return try list.map { item in
        ContextCheckpoint.KeptMessage(
            id: try #require(item["id"] as? String, "\(id)"),
            text: try #require(item["text"] as? String, "\(id)"),
            truncated: try #require(item["truncated"] as? Bool, "\(id)")
        )
    }
}

@Suite("ContextContractCheckpoint")
struct ContextContractCheckpointTests {
    private let contract: CheckpointContract

    init() throws {
        contract = try CheckpointContract()
    }

    @Test("constants_equal_fixture")
    func constantsMatchFixture() throws {
        #expect(ContextCheckpoint.note == string(contract.constants["note"]))
        #expect(ContextCheckpoint.truncationMark == string(contract.constants["truncationMark"]))
        #expect(ContextCheckpoint.shortTruncationCodePoints == contract.constants["shortTruncationCodePoints"] as? Int)
        #expect(ContextCheckpoint.packerVersion == string(contract.constants["packerVersion"]))
        #expect(ContextCheckpoint.headings == (contract.constants["headings"] as? [String]))
        let namespace = contract.constants["uuidNamespace"] as? [String: Any]
        #expect(ContextCheckpoint.uuidNamespace == string(namespace?["value"]))
        let boundary = try #require(contract.constants["sentenceBoundary"] as? [String: Any])
        #expect(Set(boundary.keys) == ["terminators", "closers", "lineBreaks", "spaces", "extend", "joiners", "regionalIndicator"])
        let table = ContextCheckpoint.sentenceBoundary
        #expect(table.terminators == (boundary["terminators"] as? [String]))
        #expect(table.closers == (boundary["closers"] as? [String]))
        #expect(table.lineBreaks == (boundary["lineBreaks"] as? [String]))
        #expect(table.spaces == (boundary["spaces"] as? [String]))
        #expect(table.extend == (boundary["extend"] as? [String]))
        #expect(table.joiners == (boundary["joiners"] as? [String]))
        #expect(table.regionalIndicator == string(boundary["regionalIndicator"]))
    }

    @Test("span")
    func span() throws {
        let cases = try contract.cases("spanCases")
        #expect(cases.count == 8)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let expected = try #require(raw["expected"] as? [String: Any], "\(id)")
            let result = ContextCheckpoint.selectSpan(
                messages: try messages(input["messages"], id: id),
                B: try #require(input["B"] as? Int, "\(id)"),
                previousCoversTo: input["previousCoversTo"] as? String
            )
            #expect(result.action.rawValue == string(expected["action"]), "\(id)")
            #expect(result.tailStartId == string(expected["tailStartId"]), "\(id)")
            if result.action == .compact {
                #expect(result.spanIds == (expected["spanIds"] as? [String]), "\(id)")
                #expect(result.coversFrom == string(expected["coversFrom"]), "\(id)")
                #expect(result.coversTo == string(expected["coversTo"]), "\(id)")
                #expect(result.messagesCovered == expected["messagesCovered"] as? Int, "\(id)")
            } else {
                #expect(result.spanIds.isEmpty, "\(id)")
            }
        }
    }

    @Test("userMessages")
    func userMessages() throws {
        let cases = try contract.cases("userMessageCases")
        #expect(cases.count == 3)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let rawCandidates = try #require(input["candidates"] as? [[String: Any]], "\(id)")
            let candidates = try rawCandidates.map { item in
                ContextCheckpoint.Candidate(
                    id: try #require(item["id"] as? String, "\(id)"),
                    text: try #require(item["text"] as? String, "\(id)"),
                    isDirective: item["isDirective"] as? Bool ?? false
                )
            }
            let result = ContextCheckpoint.pickUserMessages(
                candidates: candidates,
                B: try #require(input["B"] as? Int, "\(id)"),
                rhoHi: try #require(input["rhoHi"] as? Double, "\(id)"),
                userMessagesMax: input["userMessagesMax"] as? Int
            )
            let expected = try kept(raw["expected"], id: id)
            #expect(result == expected, "\(id)")
        }
    }

    @Test("normalizeHeadings")
    func normalizeHeadings() throws {
        let cases = try contract.cases("normalizeHeadingCases")
        #expect(cases.count == 9)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let expected = try #require(raw["expected"] as? [String: Any], "\(id)")
            let result = ContextCheckpoint.normalizeHeadings(try #require(input["summary"] as? String, "\(id)"))
            let want = try #require(expected["summary"] as? String, "\(id)")
            // Compare by code point: String == treats "\r\n" and canonically equivalent strings as the same.
            #expect(Array(result.unicodeScalars) == Array(want.unicodeScalars), "\(id): \(result.debugDescription)")
        }
    }

    // Compare the whole string by code point: String == compares by canonical equivalence and would treat combining and precomposed characters as the same.
    @Test("truncate")
    func truncate() throws {
        let cases = try contract.cases("truncateCases")
        #expect(cases.count == 53)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let result = ContextCheckpoint.truncate(
                try #require(input["text"] as? String, "\(id)"),
                head: try #require(input["head"] as? Int, "\(id)"),
                tail: input["tail"] as? Int
            )
            let expected = try #require(raw["expected"] as? String, "\(id)")
            #expect(Array(result.unicodeScalars) == Array(expected.unicodeScalars), "\(id): \(result.debugDescription)")
        }
    }

    @Test("serialize")
    func serialize() throws {
        let cases = try contract.cases("serializeCases")
        #expect(cases.count == 2)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let text = ContextCheckpoint.serialize(
                coversFrom: try #require(input["coversFrom"] as? String, "\(id)"),
                coversTo: try #require(input["coversTo"] as? String, "\(id)"),
                messagesCovered: try #require(input["messagesCovered"] as? Int, "\(id)"),
                kept: try kept(input["kept"], id: id),
                summary: input["summary"] as? String
            )
            let expected = try #require(raw["expected"] as? String, "\(id)")
            #expect(Array(text.utf8) == Array(expected.utf8), "\(id)")
        }
    }

    @Test("validate")
    func validate() throws {
        let cases = try contract.cases("validateCases")
        #expect(cases.count == 10)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let expected = try #require(raw["expected"] as? [String: Any], "\(id)")
            let result = ContextCheckpoint.validateSummary(
                try #require(input["summary"] as? String, "\(id)"),
                summaryMax: try #require(input["summaryMax"] as? Int, "\(id)"),
                spanTokens: try #require(input["spanTokens"] as? Int, "\(id)"),
                rhoHi: try #require(input["rhoHi"] as? Double, "\(id)")
            )
            #expect(result.valid == expected["valid"] as? Bool, "\(id)")
            #expect(result.reasons.map(\.rawValue) == (expected["reasons"] as? [String]), "\(id)")
        }
    }

    @Test("ids")
    func ids() throws {
        let cases = try contract.cases("idCases")
        #expect(cases.count == 4)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let expected = try #require(raw["expected"] as? [String: Any], "\(id)")
            if let rawMessages = input["messages"] as? [[String: Any]] {
                let covered = try rawMessages.map { item in
                    ContextCheckpoint.CoveredMessage(
                        id: try #require(item["id"] as? String, "\(id)"),
                        text: try #require(item["text"] as? String, "\(id)")
                    )
                }
                #expect(covered.map { ContextCheckpoint.textHash($0.text) } == (expected["textHashes"] as? [String]), "\(id)")
                #expect(ContextCheckpoint.coversDigest(covered) == string(expected["coversDigest"]), "\(id)")
            } else {
                let result = ContextCheckpoint.checkpointId(
                    conversationId: try #require(input["conversationId"] as? String, "\(id)"),
                    coversTo: try #require(input["coversTo"] as? String, "\(id)"),
                    packerVersion: try #require(input["packerVersion"] as? String, "\(id)")
                )
                #expect(result == string(expected["checkpointId"]), "\(id)")
            }
        }
    }

    @Test("concurrency")
    func concurrency() throws {
        let cases = try contract.cases("concurrencyCases")
        #expect(cases.count == 3)
        let parser = ISO8601DateFormatter()
        func claim(_ value: Any?, id: String) throws -> ContextCheckpoint.Claim {
            let item = try #require(value as? [String: Any], "\(id)")
            let iso = try #require(item["createdAt"] as? String, "\(id)")
            let createdAt = try #require(parser.date(from: iso), "\(id)")
            return ContextCheckpoint.Claim(
                checkpointId: try #require(item["checkpointId"] as? String, "\(id)"),
                coversToIndex: try #require(item["coversToIndex"] as? Int, "\(id)"),
                createdAtMillis: Int64((createdAt.timeIntervalSince1970 * 1000).rounded())
            )
        }
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let a = try claim(input["a"], id: id)
            let b = try claim(input["b"], id: id)
            let winner = ContextCheckpoint.resolveConcurrency(a, b)
            let expected = try #require(raw["expected"] as? String, "\(id)")
            #expect(winner == (expected == "a" ? a : b), "\(id)")
        }
    }

    // Not from the fixture: the cross-platform ruling is that the minimal stage also carries oldSummary.
    @Test("fallback_minimal_keeps_old_summary")
    func fallbackMinimalKeepsOldSummary() {
        let detail = String(repeating: "detail ", count: 40)
        var messages: [ContextCheckpoint.Message] = []
        for turn in 1...8 {
            messages.append(.init(id: "u\(turn)", role: .user, estTokens: 120, text: "Message \(turn): \(detail)", isDirective: turn == 2))
            messages.append(.init(id: "a\(turn)", role: .assistant, estTokens: 900))
        }
        let summary = "## Goal\nKeep going.\n## Key Facts & Decisions\n(none)\n## Work Produced\n(none)\n## Open Threads\n(none)\n## Style & Language\nEnglish"
        let result = ContextCheckpoint.fallback(messages: messages, B: 7168, rhoHi: 0.5, fixedTokens: 3000, oldSummary: summary)
        #expect(result.stages.last == "minimal")
        #expect(result.keptUserIds == ["u2", "u7"])
        let text = result.checkpointText ?? ""
        #expect(text.contains("<summary>## Goal\nKeep going.\n## Key Facts &amp; Decisions"))
        #expect(text.hasSuffix("</summary>\n</oriveo-context-checkpoint>"))
    }

    @Test("fallback")
    func fallback() throws {
        let cases = try contract.cases("fallbackCases")
        #expect(cases.count == 5)
        for raw in cases {
            let id = try #require(raw["id"] as? String)
            let input = try #require(raw["input"] as? [String: Any], "\(id)")
            let expected = try #require(raw["expected"] as? [String: Any], "\(id)")
            let result = ContextCheckpoint.fallback(
                messages: try messages(input["messages"], id: id),
                B: try #require(input["B"] as? Int, "\(id)"),
                rhoHi: try #require(input["rhoHi"] as? Double, "\(id)"),
                fixedTokens: try #require(input["fixedTokens"] as? Int, "\(id)"),
                oldSummary: input["oldSummary"] as? String
            )
            #expect(result.tailStartId == string(expected["tailStartId"]), "\(id)")
            #expect(result.keptUserIds == (expected["keptUserIds"] as? [String]), "\(id)")
            #expect(result.total == expected["total"] as? Int, "\(id)")
            #expect(result.targetMet == expected["targetMet"] as? Bool, "\(id)")
            #expect(result.stages == (expected["stages"] as? [String]), "\(id)")
            if let text = expected["checkpointText"] as? String {
                let same = result.checkpointText.map { $0.utf8.elementsEqual(text.utf8) } ?? false
                #expect(same, "\(id): \(result.checkpointText.debugDescription)")
            }
        }
    }
}
