import Foundation
import Testing
@testable import Oriveo

/// Chat image dispatch truth table: `shared/studio-contracts/chat_image_dispatch.v1.json`
/// (spec constants, every dispatch case, errorMap) against the pure functions of
/// `ChatImageDispatch`.
@Suite("ChatImageDispatchContractTests")
struct ChatImageDispatchContractTests {
    typealias JSONValue = MetadataClient.JSONValue

    private struct BadFixture: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Fixtures

    private static func repoFile(_ components: [String]) throws -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func fixtureURL() throws -> URL {
        try repoFile(["\u{5171}\u{4EAB}", "studio-contracts", "chat_image_dispatch.v1.json"])
    }

    private static func fixture() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL())) as? [String: Any] else {
            throw BadFixture(description: "chat_image_dispatch.v1.json is not a JSON object")
        }
        return object
    }

    private static func spec() throws -> [String: Any] {
        guard let spec = try fixture()["spec"] as? [String: Any] else { throw BadFixture(description: "spec missing") }
        return spec
    }

    /// Fixture profiles, validated by the production resolver.
    private static func profiles() throws -> [String: ImageProfile] {
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtureURL())),
              case .object(let profiles)? = root["profiles"]
        else { throw BadFixture(description: "profiles missing") }
        var result: [String: ImageProfile] = [:]
        for (name, value) in profiles {
            guard case .object(let object) = value,
                  case .success(let profile) = ImageProfileResolver.validate(object)
            else { throw BadFixture(description: "profile \(name) must validate") }
            result[name] = profile
        }
        return result
    }

    // MARK: - constants

    @Test func constantsEqualSpec() throws {
        let spec = try Self.spec()
        #expect(ChatImageDispatch.studioRoutes.map(\.rawValue) == spec["studioRoutes"] as? [String])
        #expect(ChatImageDispatch.legacyProviderKinds.map(\.rawValue) == spec["legacyProviderKinds"] as? [String])
        let params = try #require(spec["chatParams"] as? [String: Any])
        #expect(ChatImageDispatch.chatParams.aspect == params["aspect"] as? String)
        #expect(ChatImageDispatch.chatParams.resolution.rawValue == params["resolution"] as? String)
        #expect(ChatImageDispatch.chatParams.quality.rawValue == params["quality"] as? String)
        #expect(ChatImageDispatch.chatParams.n == params["n"] as? Int)
    }

    // MARK: - dispatch

    @Test func dispatchMatchesEveryCase() throws {
        let cases = try #require(Self.fixture()["dispatch"] as? [[String: Any]])
        #expect(cases.count == 14)
        let profiles = try Self.profiles()
        for item in cases {
            let caseId = try #require(item["caseId"] as? String)
            let input = try #require(item["input"] as? [String: Any], "\(caseId) input")
            let expect = try #require(item["expect"] as? [String: Any], "\(caseId) expect")
            let kindRaw = try #require(input["providerKind"] as? String, "\(caseId) providerKind")
            let providerKind = try #require(ProviderKind(rawValue: kindRaw), "\(caseId) unknown provider kind \(kindRaw)")
            let gate = try #require(input["legacyImageDispatch"] as? Bool, "\(caseId) legacyImageDispatch")
            var profile: ImageProfile?
            if let ref = input["profileRef"] as? String {
                profile = try #require(profiles[ref], "\(caseId) profileRef \(ref)")
            }
            let rawAttachments = try #require(input["attachments"] as? [[String: Any]], "\(caseId) attachments")
            let attachments = try rawAttachments.map { raw in
                ChatImageDispatch.Attachment(
                    id: try #require(raw["id"] as? String, "\(caseId) attachment id"),
                    hasBytes: try #require(raw["hasBytes"] as? Bool, "\(caseId) attachment hasBytes")
                )
            }

            let expected: ChatImageDispatch.Decision
            switch expect["path"] as? String {
            case "legacy":
                expected = .legacy
            case "studio":
                let operationRaw = try #require(expect["operation"] as? String, "\(caseId) operation")
                let operation = try #require(ImageProfile.Operation(rawValue: operationRaw), "\(caseId) operation")
                let rawImages = try #require(expect["images"] as? [[String: Any]], "\(caseId) images")
                let images = try rawImages.map { raw in
                    ChatImageDispatch.Image(
                        attachmentId: try #require(raw["attachmentId"] as? String, "\(caseId) attachmentId"),
                        slot: try #require(raw["slot"] as? Int, "\(caseId) slot"),
                        role: try #require(raw["role"] as? String, "\(caseId) role")
                    )
                }
                expected = .studio(operation: operation, images: images)
            default:
                throw BadFixture(description: "\(caseId) has an unknown path")
            }

            let actual = ChatImageDispatch.decide(
                providerKind: providerKind,
                legacyImageDispatch: gate,
                profile: profile,
                attachments: attachments
            )
            #expect(actual == expected, "\(caseId)")
        }
    }

    @Test func dispatchMissingMaxReferenceImagesTakesOne() throws {
        var profile = try #require(Self.profiles()["openai_gpt_image"])
        profile.maxReferenceImages = nil
        let actual = ChatImageDispatch.decide(
            providerKind: .openAI,
            legacyImageDispatch: true,
            profile: profile,
            attachments: [
                ChatImageDispatch.Attachment(id: "a1", hasBytes: true),
                ChatImageDispatch.Attachment(id: "a2", hasBytes: true),
            ]
        )
        #expect(actual == .studio(operation: .edit, images: [ChatImageDispatch.Image(attachmentId: "a1", slot: 1, role: "base")]))
    }

    @Test func baseUrlMatchesFixture() throws {
        let cases = try #require(Self.fixture()["baseUrl"] as? [[String: Any]])
        #expect(cases.count == 19)
        for item in cases {
            let caseId = try #require(item["caseId"] as? String)
            let input = try #require(item["input"] as? [String: Any], "\(caseId) input")
            let expect = try #require(item["expect"] as? [String: Any], "\(caseId) expect")
            let routeRaw = try #require(input["route"] as? String, "\(caseId) route")
            let route = try #require(ImageProfile.Route(rawValue: routeRaw), "\(caseId) unknown route \(routeRaw)")
            let got = ChatImageDispatch.studioBaseURL(route: route, connectionBaseURL: input["connectionBaseUrl"] as? String)
            #expect(got == expect["baseUrl"] as? String, "\(caseId) got \(String(describing: got))")
        }
    }

    // MARK: - errorMap

    @Test func errorMapCategoriesEqualSpec() throws {
        let errorMap = try #require(Self.spec()["errorMap"] as? [String: String])
        let mapped = StudioImageErrorKind.allCases.filter { $0 != .partial }
        #expect(Set(errorMap.keys) == Set(mapped.map(\.rawValue)))
        for kind in mapped {
            #expect(ChatImageDispatch.category(for: kind) == errorMap[kind.rawValue], "\(kind.rawValue)")
        }
        #expect(ChatImageDispatch.category(for: .partial) == nil)
        #expect(ChatImageDispatch.chatFailure(kind: .partial, message: "m") == nil)
    }

    @Test func errorMapChatFailureCarriesMessage() throws {
        let errorMap = try #require(Self.spec()["errorMap"] as? [String: String])
        let message = "upstream said no"
        for kind in StudioImageErrorKind.allCases where kind != .partial {
            let category = try #require(errorMap[kind.rawValue], "\(kind.rawValue)")
            let failure = try #require(ChatImageDispatch.chatFailure(kind: kind, message: message), "\(kind.rawValue)")
            let matches: Bool
            switch (category, failure) {
            case ("upstream_400", .upstream(let status, let detail)): matches = status == 400 && detail == message
            case ("upstream_502", .upstream(let status, let detail)): matches = status == 502 && detail == message
            case ("upstream_507", .upstream(let status, let detail)): matches = status == 507 && detail == message
            case ("invalid_key", .invalidAPIKey(let detail)): matches = detail == message
            case ("quota_exceeded", .quotaExceeded(let detail)): matches = detail == message
            case ("rate_limited", .rateLimited(let detail)): matches = detail == message
            case ("model_unavailable", .modelUnavailable(let detail)): matches = detail == message
            case ("network", .network(let detail)): matches = detail == message
            case ("empty_response", .emptyResponse): matches = true
            default: matches = false
            }
            #expect(matches, "\(kind.rawValue) -> \(category) got \(failure)")
        }
    }
}
