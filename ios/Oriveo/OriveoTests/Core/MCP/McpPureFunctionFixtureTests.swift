import Foundation
import Testing
@testable import Oriveo

/// Replays the shared vectors in `shared/test-fixtures/mcp/` against the four pure functions
/// and the secret-bearing URL check. Every client replays the same vectors, so editing a fixture changes the contract.
@Suite("MCP pure-function fixture replay")
struct McpPureFunctionFixtureTests {

    // MARK: - Tool names (naming.json)

    @Test("replays every tool-name vector")
    func namingReplay() throws {
        let root = try McpFixture.json("naming.json")
        let cases = root["cases"]?.arrayValue ?? []
        #expect(cases.count == 6)

        for item in cases {
            let caseId = item["caseId"]?.stringValue ?? "?"
            let outbound = McpToolNaming.outboundName(
                slug: item["slug"]?.stringValue ?? "",
                serverId: item["serverId"]?.stringValue ?? "",
                toolName: item["toolName"]?.stringValue ?? "",
                collidesWith: (item["collidesWith"]?.arrayValue ?? []).compactMap(\.stringValue)
            )
            let expect = item["expect"]
            #expect(outbound.name == expect?["outboundName"]?.stringValue, "\(caseId) outboundName")
            #expect(outbound.name.count == expect?["length"]?.intValue, "\(caseId) length")
            #expect(outbound.hashSuffixed == expect?["hashSuffixed"]?.boolValue, "\(caseId) hashSuffixed")
        }
    }

    // MARK: - Tool-name sanitizing edge vectors (identifiers.json › sanitize)

    @Test("sanitizing replaces one UTF-16 code unit at a time: combining marks, surrogate pairs and keycap sequences")
    func sanitizeReplay() throws {
        let root = try McpFixture.json("identifiers.json")
        let cases = root["sanitize"]?["cases"]?.arrayValue ?? []
        #expect(cases.count == 7)

        for item in cases {
            let caseId = item["caseId"]?.stringValue ?? "?"
            let toolName = try #require(item["toolName"]?.stringValue, "\(caseId) toolName")
            let sanitized = McpToolNaming.sanitized(toolName)
            #expect(sanitized == item["expect"]?.stringValue, "\(caseId)")
            // Sanitizing never changes the code-unit count: each unit becomes one `_`, nothing is merged or split.
            #expect(sanitized.utf16.count == toolName.utf16.count, "\(caseId) code-unit count")
            #expect(sanitized.unicodeScalars.allSatisfy { $0.isASCII }, "\(caseId) result is ASCII only")
        }
    }

    // MARK: - slug (identifiers.json › slugMake / slugUnique)

    @Test("replays every slug-generation vector; results always match [a-z0-9]{1,16}")
    func slugMakeReplay() throws {
        let root = try McpFixture.json("identifiers.json")
        let cases = root["slugMake"]?["cases"]?.arrayValue ?? []
        #expect(cases.count == 12)

        for item in cases {
            let caseId = item["caseId"]?.stringValue ?? "?"
            let name = try #require(item["name"]?.stringValue, "\(caseId) name")
            let slug = McpSlug.make(from: name)
            #expect(slug == item["expect"]?.stringValue, "\(caseId)")
            #expect(McpSlug.isValid(slug), "\(caseId) does not match [a-z0-9]{1,16}")
            #expect(!slug.contains("-"), "\(caseId) a slug never contains '-'")
        }
    }

    @Test("replays every slug-dedup vector: digits-only suffix, no separator, at most 16 characters")
    func slugUniqueReplay() throws {
        let root = try McpFixture.json("identifiers.json")
        let cases = root["slugUnique"]?["cases"]?.arrayValue ?? []
        #expect(cases.count == 6)

        for item in cases {
            let caseId = item["caseId"]?.stringValue ?? "?"
            let name = try #require(item["name"]?.stringValue, "\(caseId) name")
            let existing = Set((item["existing"]?.arrayValue ?? []).compactMap(\.stringValue))
            let slug = McpSlug.unique(name: name, existing: existing)
            #expect(slug == item["expect"]?.stringValue, "\(caseId)")
            #expect(McpSlug.isValid(slug), "\(caseId) does not match [a-z0-9]{1,16}")
            #expect(!existing.contains(slug), "\(caseId) result must not collide with an existing slug")
        }
    }

    @Test("slug dedup stays within the length limit when the suffix rolls over to three digits")
    func slugUniqueKeepsLengthAcrossDigitRollover() {
        let base = "averylongservern"
        var existing: Set<String> = [base]
        for index in 2...99 {
            existing.insert(String(base.prefix(16 - String(index).count)) + String(index))
        }
        let slug = McpSlug.unique(name: "averylongservername", existing: existing)
        #expect(slug == "averylongserv100")
        #expect(McpSlug.isValid(slug))
    }

    @Test("slug validity accepts only [a-z0-9]{1,16}")
    func slugValidity() {
        for good in ["a", "linear", "notion2", "0123456789abcdef"] {
            #expect(McpSlug.isValid(good), "\(good)")
        }
        for bad in ["", "home-lab", "Linear", "a_b", "0123456789abcdefg", "café", "ａ"] {
            #expect(!McpSlug.isValid(bad), "\(bad)")
        }
    }

    // MARK: - Content hash (tool-hash.json)

    @Test("replays every content-hash vector")
    func toolHashReplay() throws {
        let root = try McpFixture.json("tool-hash.json")
        let cases = root["cases"]?.arrayValue ?? []
        #expect(cases.count == 5)

        for item in cases {
            let caseId = item["caseId"]?.stringValue ?? "?"
            let before = try #require(item["before"], "\(caseId) before")
            let after = try #require(item["after"], "\(caseId) after")
            let beforeHash = contentHash(of: before)
            let afterHash = contentHash(of: after)
            let expect = item["expect"]

            if item["expectEqual"]?.boolValue == true {
                #expect(beforeHash == afterHash, "\(caseId) should be equivalent")
                if let frozen = expect?["hash"]?.stringValue {
                    #expect(beforeHash == frozen, "\(caseId) hash")
                }
            } else {
                #expect(beforeHash != afterHash, "\(caseId) should count as a change")
                #expect(beforeHash == expect?["beforeHash"]?.stringValue, "\(caseId) beforeHash")
                #expect(afterHash == expect?["afterHash"]?.stringValue, "\(caseId) afterHash")
            }
        }
    }

    // MARK: - Argument summary (args-summary.json)

    @Test("replays every argument-summary vector")
    func argsSummaryReplay() throws {
        let root = try McpFixture.json("args-summary.json")
        let cases = root["cases"]?.arrayValue ?? []
        #expect(cases.count == 7)

        for item in cases {
            let caseId = item["caseId"]?.stringValue ?? "?"
            let summary = McpArgsSummary.summary(
                inputSchema: item["inputSchema"] ?? .object(JSONObject()),
                arguments: item["arguments"] ?? .object(JSONObject())
            )
            let expect = item["expect"]
            #expect(summary == expect?["summary"]?.stringValue, "\(caseId) summary")
            if let length = expect?["length"]?.intValue {
                #expect(summary.count == length, "\(caseId) length")
            }
        }
    }

    // MARK: - Fixed safety prompt text (safety-prompt.txt)

    @Test("safety prompt matches the fixture verbatim")
    func safetyPromptMatchesFixture() throws {
        let raw = try String(contentsOf: McpFixture.url("safety-prompt.txt"), encoding: .utf8)
        let fixtureText = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        #expect(fixtureText == McpSafetyPrompt.text)
    }

    // MARK: - Secret-bearing URL check (local-only.json)

    @Test("replays every secret-bearing URL vector")
    func localOnlyReplay() throws {
        let root = try McpFixture.json("local-only.json")
        let cases = root["cases"]?.arrayValue ?? []
        #expect(cases.count == 10)

        for item in cases {
            let caseId = item["caseId"]?.stringValue ?? "?"
            let verdict = McpLocalOnly.verdict(for: item["url"]?.stringValue ?? "")
            #expect(verdict.isLocalOnly == item["expect"]?["localOnly"]?.boolValue, "\(caseId) localOnly")
            #expect(verdict.reason.rawValue == item["expect"]?["reason"]?.stringValue, "\(caseId) reason")
        }
    }

    // MARK: - helpers

    /// Content hash of one vector entry, using `description ?? null` and `annotations ?? {}`.
    private func contentHash(of value: JSONValue) -> String {
        let description: String? = {
            guard let raw = value["description"], raw != .null else { return nil }
            return raw.stringValue
        }()
        return McpToolHash.contentHash(
            name: value["name"]?.stringValue ?? "",
            description: description,
            inputSchema: value["inputSchema"] ?? .object(JSONObject()),
            annotations: value["annotations"] ?? .object(JSONObject())
        )
    }
}
