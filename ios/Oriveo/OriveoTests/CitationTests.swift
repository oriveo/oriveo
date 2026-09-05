import Foundation
import Testing
@testable import Oriveo

@Suite("Citation model + accumulator")
struct CitationTests {

    @Test("external URL policy only allows credential-free HTTPS URLs")
    func externalURLPolicy() {
        #expect(ExternalURLPolicy.httpsURL(from: "https://docs.example.com/page") != nil)
        #expect(ExternalURLPolicy.httpsURL(from: "HTTPS://docs.example.com/page") != nil)
        #expect(ExternalURLPolicy.httpsURL(from: "http://docs.example.com/page") == nil)
        #expect(ExternalURLPolicy.httpsURL(from: "javascript:alert(1)") == nil)
        #expect(ExternalURLPolicy.httpsURL(from: "https://user@docs.example.com/page") == nil)
        #expect(ExternalURLPolicy.httpsURL(from: "https:///missing-host") == nil)
    }

    // MARK: - normalizeUrl

    @Test("normalizeUrl strips fragment / trailing slash / case-normalizes")
    func normalizeUrlBasics() {
        // Drop fragment
        #expect(Citation.normalizeUrl("https://example.com/page#section") == "https://example.com/page")
        // Drop trailing / (when path is not empty)
        #expect(Citation.normalizeUrl("https://example.com/page/") == "https://example.com/page")
        // Keep trailing / on the root URL
        #expect(Citation.normalizeUrl("https://example.com/") == "https://example.com/")
        // Lowercase the scheme
        #expect(Citation.normalizeUrl("HTTPS://Example.COM/Page") == "https://example.com/Page")
    }

    // MARK: - Codable round-trip

    @Test("Citation Codable round-trip keeps every field")
    func codableRoundTrip() throws {
        let original = Citation(
            url: "https://example.com/a",
            title: "Example",
            snippet: "A short summary",
            faviconUrl: "https://example.com/favicon.ico",
            index: 1,
            startIndex: 10,
            endIndex: 20
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Citation.self, from: data)
        #expect(decoded == original)
    }

    @Test("Citation Codable accepts missing optional fields")
    func codableMinimal() throws {
        let json = #"{"url":"https://only.url/"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Citation.self, from: json)
        #expect(decoded.url == "https://only.url/")
        #expect(decoded.title == nil)
        #expect(decoded.snippet == nil)
    }

    // MARK: - CitationAccumulator

    @Test("Accumulator dedupes on the normalized URL and keeps first-seen order")
    func accumulatorDedupe() {
        var acc = CitationAccumulator()
        acc.ingest(Citation(url: "https://a.com/page#section", title: "A1"))
        acc.ingest(Citation(url: "https://a.com/page/", title: "A2"))  // Same primary key after normalize
        acc.ingest(Citation(url: "https://b.com/", title: "B"))

        let snapshot = acc.snapshot ?? []
        #expect(snapshot.count == 2)
        #expect(snapshot[0].url == "https://a.com/page#section")  // First arrival keeps the raw url
        #expect(snapshot[1].url == "https://b.com/")
    }

    @Test("Accumulator merge on the same key prefers the longer non-empty title / snippet")
    func accumulatorMergeChoosesLonger() {
        var acc = CitationAccumulator()
        acc.ingest(Citation(url: "https://a.com/", title: "A", snippet: nil))
        acc.ingest(Citation(url: "https://a.com/", title: "Apple Inc.", snippet: "Tech company"))

        let snapshot = acc.snapshot ?? []
        #expect(snapshot.count == 1)
        #expect(snapshot[0].title == "Apple Inc.")
        #expect(snapshot[0].snippet == "Tech company")
    }

    @Test("Accumulator falls back to a title+snippet hash key when URL is empty")
    func accumulatorFallbackKey() {
        var acc = CitationAccumulator()
        acc.ingest(Citation(url: "", title: "T", snippet: "S"))
        acc.ingest(Citation(url: "", title: "T", snippet: "S"))  // Same secondary key, should dedupe
        acc.ingest(Citation(url: "", title: "T2", snippet: "S"))  // Different secondary key, should keep

        let snapshot = acc.snapshot ?? []
        #expect(snapshot.count == 2)
    }

    @Test("Empty url plus empty title/snippet is invalid and stays out of the accumulator")
    func accumulatorRejectsEmpty() {
        var acc = CitationAccumulator()
        acc.ingest(Citation(url: "", title: nil, snippet: nil))
        #expect(acc.snapshot == nil)
    }
}

// MARK: - ChatMessage citations field

@Suite("ChatMessage citations field")
struct ChatMessageCitationsTests {

    @Test("ChatMessage Codable round-trip includes citations")
    func roundTrip() throws {
        let original = ChatMessage(
            id: UUID(),
            role: .assistant,
            text: "Hello",
            providerKind: .openAI,
            providerName: "OpenAI",
            modelName: "gpt-4o",
            state: .delivered,
            citations: [
                Citation(url: "https://a.com/", title: "A"),
                Citation(url: "https://b.com/", title: "B"),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded.citations?.count == 2)
        #expect(decoded.citations?[0].url == "https://a.com/")
    }

    @Test("Legacy messages without a citations field still decode (default nil)")
    func backwardCompatible() throws {
        let json = """
        {"id":"\(UUID().uuidString)","role":"assistant","text":"hi",
         "providerKind":"openAI","providerName":"OpenAI","modelName":"gpt-4o",
         "state":"delivered","estimatedCost":0}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded.citations == nil)
    }
}

// MARK: - Persistence layer RecordMappers encodeCitations round-trip

@Suite("RecordMappers citations persistence round-trip")
struct RecordMappersCitationsTests {

    @Test("encodeCitations: nil / empty array / non-empty array")
    func encodeBoundaries() {
        #expect(RecordMappers.encodeCitations(nil) == nil)
        #expect(RecordMappers.encodeCitations([]) == nil)

        let arr = [
            Citation(url: "https://a.com/", title: "A"),
            Citation(url: "https://b.com/", title: "B"),
        ]
        let json = RecordMappers.encodeCitations(arr)
        #expect(json != nil)
        // JSONEncoder may escape `/` (legal but optional), so only assert the host segments exist.
        #expect(json?.contains("a.com") == true)
        #expect(json?.contains("b.com") == true)
        #expect(json?.contains("\"title\":\"A\"") == true)
        #expect(json?.contains("\"title\":\"B\"") == true)
    }

    @Test("encodeCitations output round-trips through JSONDecoder to the same array")
    func roundTrip() throws {
        let original = [
            Citation(url: "https://a.com/", title: "A", snippet: "snip", index: 1),
            Citation(url: "https://b.com/", title: "B"),
        ]
        let json = RecordMappers.encodeCitations(original)
        let data = try #require(json?.data(using: .utf8))
        let decoded = try JSONDecoder().decode([Citation].self, from: data)
        #expect(decoded == original)
    }
}
