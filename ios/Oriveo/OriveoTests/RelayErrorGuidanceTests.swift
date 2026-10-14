import Foundation
import Testing
@testable import Oriveo

/// Maps the text produced by the production error mapping back to the guidance keys (English source strings) in `BaseAPIService`.
/// Assertions are written on keys, independent of the current language and of whether translations are in the table; other test files use it too, so none hand-copies whole sentences.
enum RelayGuidanceKeys {
    static let modelAdvancedPath = "Providers → this connection → Model Library → this model → Advanced"

    /// All guidance keys in the body of `relayGuidanceFailure`, in order of appearance.
    static func all() throws -> [String] {
        try keys(from: "private static func relayGuidanceFailure(", to: "static func subscriptionFailure(")
    }

    /// The key for the case where a 2xx response carries a web page (`rejectRelayWebPageSuccess`).
    static func webPage() throws -> String {
        let found = try keys(from: "func rejectRelayWebPageSuccess(", to: "func rejectRelayWebPageStreamStart(")
        return try #require(found.first)
    }

    /// The guidance key that produced this text: the guidance sentence comes first and may be followed by the upstream original. Returns nil if it is not guidance.
    static func producing(_ detail: String) throws -> String? {
        try all().first { detail.hasPrefix(L10n.tr($0, table: .providers)) }
    }

    private static func keys(from startMarker: String, to endMarker: String) throws -> [String] {
        let source = try ProductionSource.read("Core/Providers/BaseAPIService.swift")
        let start = try #require(source.range(of: startMarker))
        let end = try #require(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound]) as NSString
        let regex = try NSRegularExpression(pattern: #"L10n\.tr\("([^"]+)", table: \.providers\)"#)
        return regex.matches(in: body as String, range: NSRange(location: 0, length: body.length))
            .map { body.substring(with: $0.range(at: 1)) }
    }
}

/// Where relay runtime error guidance points.
///
/// Each sample hands an upstream error body to production `BaseAPIService.mapHTTPError`, then maps the produced text back to the key in
/// `relayGuidanceFailure` (English source): wrong-protocol errors point to the per-model
/// "Model Library -> this model -> Advanced", the others only point at UI that exists; the no-longer-existing "Relay type"
/// and "Edit -> ..." never appear again, and the bare words relay / Custom LLM are no longer used (spec section 9.3).
@Suite("Relay runtime error guidance")
struct RelayErrorGuidanceTests {
    enum Destination: Sendable, Equatable {
        /// The protocol of this model itself: Model Library -> this model -> Advanced.
        case modelProtocol
        /// A group / row on the edit-connection page, plus the name of the control to change (empty if none).
        case editConnection(section: String, control: String)
        case parameters(control: String)
        case modelLibrary
        /// The API key page of this connection (switch to a key that can use the API).
        case apiKeys
        /// The user cannot change the configuration; only the reason is stated.
        case noPath
    }

    struct Sample: Sendable, CustomTestStringConvertible {
        let name: String
        let status: Int
        let body: String
        var url = "https://relay.example.com/v1/chat/completions"
        var transport: RelayTransport? = .openaiChatCompletions
        let destination: Destination

        var testDescription: String { name }
    }

    static let modelAdvancedPath = RelayGuidanceKeys.modelAdvancedPath

    static let samples: [Sample] = [
        Sample(
            name: "RL2-GUIDE-01 Codex identity 403 (not using Responses)",
            status: 403, body: #"{"error":{"message":"Only Codex official clients are allowed"}}"#,
            destination: .modelProtocol
        ),
        Sample(
            name: "RL2-GUIDE-02 Codex identity 403 (still rejected on Responses)",
            status: 403, body: #"{"error":{"message":"Only Codex official clients are allowed"}}"#,
            url: "https://relay.example.com/v1/responses", transport: .openaiResponses,
            destination: .editConnection(section: "Headers & query params", control: "")
        ),
        Sample(
            name: "RL2-GUIDE-03 no standalone image endpoint 404",
            status: 404, body: #"{"error":{"message":"Not Found"}}"#,
            url: "https://relay.example.com/v1/images/generations", transport: nil,
            destination: .modelProtocol
        ),
        Sample(
            name: "RL2-GUIDE-04 only /v1/responses is open 404",
            status: 404, body: #"{"error":{"message":"Not Found"}}"#,
            url: "https://codex.example.com/v1/chat/completions",
            destination: .modelProtocol
        ),
        Sample(
            name: "RL2-GUIDE-05 image model rejects response_format 400",
            status: 400, body: #"{"error":{"message":"Unknown parameter: 'response_format'."}}"#,
            url: "https://relay.example.com/v1/images/generations", transport: nil,
            destination: .noPath
        ),
        Sample(
            name: "RL2-GUIDE-06 upstream unreachable 502",
            status: 502, body: #"{"error":{"type":"upstream_error","message":"Upstream authentication failed"}}"#,
            destination: .noPath
        ),
        Sample(
            name: "RL2-GUIDE-07 upstream has no such model 404",
            status: 404, body: #"{"error":{"message":"The model `gpt-99` does not exist.","code":"model_not_found"}}"#,
            destination: .modelLibrary
        ),
        Sample(
            name: "RL2-GUIDE-08 requires the Responses protocol 400",
            status: 400,
            body: #"{"error":{"message":"Unknown parameter: 'input[4].content[1].url'.","type":"invalid_request_error","param":"input[4].content[1].url","code":"unknown_parameter"}}"#,
            destination: .modelProtocol
        ),
        Sample(
            name: "RL2-GUIDE-09 rejects the store field 400",
            status: 400, body: #"{"error":{"message":"Unknown parameter: 'store'."}}"#,
            url: "https://relay.example.com/v1/responses", transport: .openaiResponses,
            destination: .editConnection(section: "Compatibility", control: "Don't keep responses in the cloud")
        ),
        Sample(
            name: "RL2-GUIDE-10 invalid service_tier value 400",
            status: 400, body: #"{"error":{"message":"Invalid value for service_tier: 'priority'."}}"#,
            destination: .editConnection(section: "Compatibility", control: "Service Tier")
        ),
        Sample(
            name: "RL2-GUIDE-11 missing max_tokens 400",
            status: 400, body: #"{"error":{"message":"max_tokens: Field required"}}"#,
            url: "https://relay.example.com/v1/messages", transport: .anthropicMessages,
            destination: .parameters(control: "Max Tokens")
        ),
        Sample(
            name: "RL2-GUIDE-12 requires the x-api-key auth header 401",
            status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#,
            url: "https://relay.example.com/v1/messages", transport: .anthropicMessages,
            destination: .editConnection(section: "Auth Mode", control: "x-api-key")
        ),
        Sample(
            name: "RL2-GUIDE-14 official CLI gate 403",
            status: 403,
            body: #"{"type":"error","error":{"type":"permission_error","message":"This API endpoint is only accessible via the official Claude CLI"}}"#,
            url: "https://relay.example.com/v1/messages", transport: .anthropicMessages,
            destination: .apiKeys
        ),
        Sample(
            name: "RL2-GUIDE-13 image format does not match the protocol 400",
            status: 400, body: #"{"error":{"message":"Invalid image_url: expected an object."}}"#,
            destination: .modelProtocol
        ),
    ]

    // MARK: - Production output -> key

    private static func guidanceKeys() throws -> [String] {
        try RelayGuidanceKeys.all()
    }

    private static func map(_ sample: Sample, isRelay: Bool) -> ProviderServiceError {
        BaseAPIService().mapHTTPError(
            statusCode: sample.status, data: Data(sample.body.utf8), url: URL(string: sample.url),
            isRelay: isRelay, relayTransport: isRelay ? sample.transport : nil
        )
    }

    private static func detail(of error: ProviderServiceError) -> String? {
        switch error {
        case let .upstream(_, detail), let .invalidAPIKey(detail): return detail
        default: return nil
        }
    }

    /// Maps the text produced by the production mapping back to its key: the guidance sentence comes first and rendered values follow the current language, so this is independent of the language and of whether translations are in the table.
    private static func producedKey(_ sample: Sample) throws -> String {
        let error = map(sample, isRelay: true)
        let text = try #require(Self.detail(of: error), "\(sample.name): expected an error with guidance, got \(error)")
        return try #require(
            try RelayGuidanceKeys.producing(text), "\(sample.name): the produced text is not any guidance:\(text)"
        )
    }

    // MARK: - Cases

    @Test("every guidance: the guidance produced by production mapHTTPError points to UI that exists, and wrong-protocol cases point to the per-model Advanced", arguments: Self.samples)
    func guidancePointsAtExistingScreens(sample: Sample) throws {
        let key = try Self.producedKey(sample)

        // Entry points and banned words that no longer exist must not appear in any guidance.
        for banned in ["Relay type", "Edit → ", "this Relay", "Connection settings", "Protocol type", "Codex style"] {
            #expect(!key.contains(banned), "\(sample.name): contains '\(banned)'：\(key)")
        }
        #expect(!key.localizedCaseInsensitiveContains("custom LLM"), "\(sample.name): \(key)")
        let withoutProductName = key.replacingOccurrences(of: "Custom Relay", with: "")
        #expect(
            withoutProductName.range(of: #"\brelay\b"#, options: [.regularExpression, .caseInsensitive]) == nil,
            "\(sample.name): bare word relay：\(key)"
        )

        switch sample.destination {
        case .modelProtocol:
            #expect(key.contains(Self.modelAdvancedPath), "\(sample.name): \(key)")
            #expect(key.contains("Protocol"), "\(sample.name): \(key)")
            #expect(!key.contains("Edit connection"), "\(sample.name): a wrong model protocol should not make the user edit the whole connection：\(key)")
        case let .editConnection(section, control):
            #expect(key.contains("Providers → this connection → Edit connection → \(section)"), "\(sample.name): \(key)")
            #expect(control.isEmpty || key.contains("“\(control)”"), "\(sample.name): \(key)")
            #expect(!key.contains("Advanced"), "\(sample.name): \(key)")
        case let .parameters(control):
            #expect(key.contains("Providers → this connection → Parameters"), "\(sample.name): \(key)")
            #expect(key.contains("“\(control)”"), "\(sample.name): \(key)")
        case .modelLibrary:
            #expect(key.contains("Providers → this connection → Model Library"), "\(sample.name): \(key)")
            #expect(!key.contains("Advanced"), "\(sample.name): \(key)")
        case .apiKeys:
            #expect(key.contains("Providers → this connection → API Keys"), "\(sample.name): \(key)")
            #expect(!key.contains("Advanced"), "\(sample.name): \(key)")
            #expect(!key.contains("Edit connection"), "\(sample.name): \(key)")
        case .noPath:
            #expect(!key.contains("→"), "\(sample.name): \(key)")
        }
    }

    @Test("the samples cover every guidance in relayGuidanceFailure; exactly the four F-01 entries plus the image one point to the per-model protocol")
    func samplesCoverEveryGuidance() throws {
        let keys = try Self.guidanceKeys()
        #expect(keys.count == Self.samples.count)
        #expect(Set(keys).count == keys.count)
        let produced = try Self.samples.map { try Self.producedKey($0) }
        #expect(Set(produced) == Set(keys), "guidance not triggered by any sample：\(Set(keys).subtracting(produced))")
        #expect(keys.filter { $0.contains(Self.modelAdvancedPath) }.count == 5)
        #expect(Self.samples.filter { $0.destination == .modelProtocol }.count == 5)
    }

    @Test("RL2-GUIDE-15 relay 429 falls to the generic 'rate limited' and shows no relay guidance")
    func relayRateLimitFallsBackToGenericCategory() throws {
        let sample = Sample(
            name: "RL2-GUIDE-15 relay 429",
            status: 429, body: #"{"error":{"message":"Too many requests"}}"#,
            destination: .noPath
        )
        let error = Self.map(sample, isRelay: true)
        guard case let .rateLimited(detail) = error else {
            Issue.record("relay 429 should fall to the generic rate-limited error, got \(error)")
            return
        }
        #expect(try RelayGuidanceKeys.producing(detail) == nil, "\(detail)")
    }

    /// Call sites with an unknown protocol (catalog sync, standalone image generation) do not pass relayTransport: a Codex identity 403 gets the "still rejected" branch.
    static let codexIdentityUnknownTransportSamples: [Sample] = [
        Sample(
            name: "RL2-GUIDE-19 catalog sync /models Codex identity 403",
            status: 403, body: #"{"error":{"message":"Only Codex official clients are allowed"}}"#,
            url: "https://relay.example.com/v1/models", transport: nil,
            destination: .editConnection(section: "Headers & query params", control: "")
        ),
        Sample(
            name: "RL2-GUIDE-20 standalone image /images/generations Codex identity 403",
            status: 403, body: #"{"error":{"message":"Only Codex official clients are allowed"}}"#,
            url: "https://relay.example.com/v1/images/generations", transport: nil,
            destination: .editConnection(section: "Headers & query params", control: "")
        ),
    ]

    @Test("RL2-GUIDE-19 / 20 Codex identity 403 with unknown protocol: gives 'still rejected -> headers and query parameters', not 'change the model protocol to OpenAI Responses'",
          arguments: Self.codexIdentityUnknownTransportSamples)
    func codexIdentityUnknownTransportStillRejected(sample: Sample) throws {
        let key = try Self.producedKey(sample)
        #expect(key.hasPrefix("This connection still rejects Oriveo's Codex client identity."), "\(sample.name): \(key)")
        #expect(key.contains("Providers → this connection → Edit connection → Headers & query params"), "\(sample.name): \(key)")
        #expect(!key.contains(Self.modelAdvancedPath), "\(sample.name): \(key)")
        #expect(!key.contains("OpenAI Responses"), "\(sample.name): \(key)")
    }

    @Test("RL2-GUIDE-21 relay 429 body with insufficient quota -> quota exhausted, no relay guidance")
    func relayQuota429IsQuotaExceeded() throws {
        let sample = Sample(
            name: "RL2-GUIDE-21 relay 429 insufficient quota",
            status: 429, body: #"{"error":{"message":"You exceeded your current quota: insufficient quota"}}"#,
            destination: .noPath
        )
        let error = Self.map(sample, isRelay: true)
        guard case let .quotaExceeded(detail) = error else {
            Issue.record("relay 429 quota body should fall to quota exhausted, got \(error)")
            return
        }
        #expect(try RelayGuidanceKeys.producing(detail) == nil, "\(detail)")
    }

    @Test("RL2-GUIDE-16 an official provider receiving the same payload falls to the generic classification and shows no relay guidance", arguments: Self.samples)
    func officialProvidersNeverGetGuidance(sample: Sample) throws {
        let error = Self.map(sample, isRelay: false)
        let text = Self.detail(of: error) ?? String(describing: error)
        for key in try Self.guidanceKeys() {
            #expect(!text.contains(L10n.tr(key, table: .providers)), "\(sample.name): \(text)")
            #expect(!text.contains(key), "\(sample.name): \(text)")
        }
        #expect(!text.contains("Model Library"), "\(sample.name): \(text)")
        #expect(!text.contains("Edit connection"), "\(sample.name): \(text)")
    }

    @Test("RL2-WEBPAGE-01 / 02 2xx whose content is a web page: production yields localized text, the source text does not use the bare words relay / Custom LLM; the response-header path and the first-body-line path report the same sentence")
    func webPageSuccessDetailIsLocalizedCopy() throws {
        let key = try RelayGuidanceKeys.webPage()
        #expect(key.range(of: #"\brelay\b"#, options: [.regularExpression, .caseInsensitive]) == nil, "\(key)")
        #expect(!key.localizedCaseInsensitiveContains("custom LLM"), "\(key)")
        let url = try #require(URL(string: "https://relay.example.com/v1/chat/completions"))
        func response(_ contentType: String) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType]
            ))
        }
        let service = BaseAPIService()
        let html = try response("text/html; charset=utf-8")
        let eventStream = try response("text/event-stream")
        var failures: [Error] = []
        do { try service.rejectRelayWebPageSuccess(html, data: nil) } catch { failures.append(error) }
        var settled = false
        do {
            try service.rejectRelayWebPageStreamStart(eventStream, line: "<!DOCTYPE html>", settled: &settled)
        } catch { failures.append(error) }
        #expect(failures.count == 2)
        for failure in failures {
            guard case let .upstream(statusCode, detail)? = failure as? ProviderServiceError else {
                Issue.record("expected upstream, got \(failure)")
                continue
            }
            #expect(statusCode == 200)
            #expect(detail == L10n.tr(key, table: .providers))
        }
        // A normal streaming first line does not trigger it; a blank line does not count as the first body line; once judged, later lines are not examined.
        var streaming = false
        try service.rejectRelayWebPageStreamStart(eventStream, line: "   ", settled: &streaming)
        #expect(!streaming)
        try service.rejectRelayWebPageStreamStart(eventStream, line: #"data: {"choices":[]}"#, settled: &streaming)
        #expect(streaming)
        try service.rejectRelayWebPageStreamStart(eventStream, line: "<html>", settled: &streaming)
    }

    @Test("the screens and controls named in guidance still have those names in the page sources")
    func namedDestinationsStillExist() throws {
        // Screen name -> the page source file that defines it. This turns red when something is renamed, as a reminder to update the guidance.
        let destinations: [(name: String, file: String)] = [
            ("Edit connection", "Features/Providers/RelayEditBoardModel.swift"),
            ("Headers & query params", "Features/Providers/RelayEditBoardModel.swift"),
            ("Compatibility", "Features/Providers/RelayEditBoardModel.swift"),
            ("Auth Mode", "Features/Providers/RelayEditBoardModel.swift"),
            ("Service Tier", "Features/Providers/RelayEditBoardModel.swift"),
            ("Don't keep responses in the cloud", "Features/Providers/RelayEditBoardModel.swift"),
            ("x-api-key", "Features/Providers/RelayEnumLabels.swift"),
            ("Model Library", "Features/Providers/RelayModelLibraryPage.swift"),
            ("Advanced", "Features/Providers/RelayModelAdvancedBoard.swift"),
            ("Protocol", "Features/Providers/RelayModelAdvancedPage.swift"),
            ("Parameters", "Features/Providers/GenerationParameterDefaultsSheet.swift"),
            ("Max Tokens", "Core/Providers/GenerationParameterSupportPresentation.swift"),
            ("API Keys", "Features/Providers/RelayKeysPage.swift"),
        ]
        let keys = try Self.guidanceKeys()
        for destination in destinations {
            #expect(keys.contains { $0.contains(destination.name) }, "no guidance mentions '\(destination.name)', so this row should be removed")
            let source = try ProductionSource.read(destination.file)
            // Only the "used for rendering" forms count: L10n lookups, board row / group titles, option display names; an arbitrary literal with the same name does not.
            let literal = "\"\(destination.name)\""
            let renderForms = [
                "L10n.tr(\(literal)",
                "titleKey: \(literal)",
                "titleKey = \(literal)",
                "GroupKey = \(literal)",
                "return \(literal)",
            ]
            #expect(
                renderForms.contains { source.contains($0) },
                "\(destination.file) no longer renders '\(destination.name)' as a screen title"
            )
        }
        // x-api-key is an option name in the auth-method menu: within the menu option set, its display name is exactly that.
        #expect(RelayAuthMode.allUICases.contains(.xApiKey))
        #expect(relayAuthLabel(.xApiKey) == "x-api-key")
    }
}
