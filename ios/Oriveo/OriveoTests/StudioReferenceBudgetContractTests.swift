import Foundation
import Testing
@testable import Oriveo

/// BYOK reference image budget cases shared by all three clients: reads the shared
/// studio contracts fixture `byok_reference_budget.v1.json` (contractId
/// "byok_reference_budget.v1") and runs spec, encodedBytes and fit against
/// `StudioReferenceBudget`.
@Suite("StudioReferenceBudgetContractTests")
struct StudioReferenceBudgetContractTests {
    static let contractId = "byok_reference_budget.v1"
    static let fixtureName = "byok_reference_budget.v1.json"

    static func repoFile(_ components: [String]) throws -> URL {
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

    static func fixture() throws -> [String: Any] {
        let url = try repoFile(["\u{5171}\u{4EAB}", "studio-contracts", fixtureName])
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        #expect(object["contractId"] as? String == contractId)
        return object
    }

    /// JSON null and a missing member both read as nil.
    static func int(_ value: Any?) -> Int? {
        value is NSNull ? nil : (value as? NSNumber)?.intValue
    }

    static func string(_ value: Any?) -> String? {
        value is NSNull ? nil : value as? String
    }

    static func cases(_ group: String) throws -> [[String: Any]] {
        let list = try #require(try fixture()[group] as? [[String: Any]], "fixture group \(group)")
        #expect(!list.isEmpty, "fixture group \(group) is empty")
        return list
    }

    struct Expected: Equatable, CustomStringConvertible {
        let slot: Int
        let mime: String
        let byteCount: Int
        var description: String { "\(slot):\(mime):\(byteCount)" }
    }

    @Test("spec")
    func spec() throws {
        let spec = try #require(try Self.fixture()["spec"] as? [String: Any])
        #expect(Self.int(spec["overheadBytes"]) == StudioReferenceBudget.overheadBytes)

        let routes = try #require(spec["routes"] as? [String: Any])
        #expect(routes.count == 7)
        #expect(Set(routes.keys) == Set(StudioReferenceBudget.routeLimits.keys))
        for (route, raw) in routes {
            let row = try #require(StudioReferenceBudget.routeLimits[route], "missing route row \(route)")
            if raw is NSNull {
                #expect(row == nil, "\(route) should have no limits")
                continue
            }
            let limits = try #require(raw as? [String: Any], "\(route) limits")
            let expected = StudioReferenceBudget.Limits(
                maxRequestBytes: try #require(Self.int(limits["maxRequestBytes"]), "\(route) maxRequestBytes"),
                maxImageBytes: Self.int(limits["maxImageBytes"])
            )
            #expect(row == expected, "\(route)")
            #expect(StudioReferenceBudget.limits(for: route) == expected, "\(route)")
        }
        #expect(StudioReferenceBudget.limits(for: "unknown_route") == nil)

        let shrink = try #require(spec["shrink"] as? [String: Any])
        #expect(Self.int(shrink["maxLongEdge"]) == StudioReferenceBudget.shrinkMaxLongEdge)
        #expect((shrink["jpegQuality"] as? NSNumber)?.doubleValue == StudioReferenceBudget.shrinkJPEGQuality)
        #expect(Self.string(shrink["mime"]) == StudioReferenceBudget.shrinkMime)

        #expect(Self.string(spec["tooLargeErrorKind"]) == StudioReferenceBudget.tooLargeErrorKind.rawValue)
        #expect(spec["statuses"] as? [String] == StudioReferenceBudget.Status.allCases.map(\.rawValue))
    }

    @Test("encodedBytes")
    func encodedBytes() throws {
        for item in try Self.cases("encodedBytes") {
            let caseId = try #require(item["caseId"] as? String)
            let input = try #require(item["input"] as? [String: Any], "\(caseId) input")
            let actual = StudioReferenceBudget.encodedBytes(
                route: try #require(Self.string(input["route"]), "\(caseId) route"),
                editTransport: Self.string(input["editTransport"]),
                mime: try #require(Self.string(input["mime"]), "\(caseId) mime"),
                byteCount: try #require(Self.int(input["byteCount"]), "\(caseId) byteCount")
            )
            #expect(actual == Self.int(item["expect"]), "\(caseId)")
        }
    }

    @Test("fit")
    func fit() async throws {
        for item in try Self.cases("fit") {
            let caseId = try #require(item["caseId"] as? String)
            let input = try #require(item["input"] as? [String: Any], "\(caseId) input")
            let expect = try #require(item["expect"] as? [String: Any], "\(caseId) expect")
            let rawImages = try #require(input["images"] as? [[String: Any]], "\(caseId) images")

            var images: [StudioReferenceBudget.Item] = []
            var shrunkBySlot: [Int: StudioReferenceBudget.Item?] = [:]
            for raw in rawImages {
                let image = StudioReferenceBudget.Item(
                    slot: try #require(Self.int(raw["slot"]), "\(caseId) slot"),
                    role: try #require(Self.string(raw["role"]), "\(caseId) role"),
                    mime: try #require(Self.string(raw["mime"]), "\(caseId) mime"),
                    byteCount: try #require(Self.int(raw["byteCount"]), "\(caseId) byteCount")
                )
                images.append(image)
                if let shrunk = raw["shrunk"] as? [String: Any] {
                    shrunkBySlot[image.slot] = StudioReferenceBudget.Item(
                        slot: image.slot,
                        role: image.role,
                        mime: try #require(Self.string(shrunk["mime"]), "\(caseId) shrunk mime"),
                        byteCount: try #require(Self.int(shrunk["byteCount"]), "\(caseId) shrunk byteCount")
                    )
                } else {
                    shrunkBySlot[image.slot] = .some(nil)
                }
            }

            let route = try #require(Self.string(input["route"]), "\(caseId) route")
            let prompt = try #require(Self.string(input["prompt"]), "\(caseId) prompt")
            var shrinkCalls: [Int] = []
            let result = await StudioReferenceBudget.fit(
                route: route,
                editTransport: Self.string(input["editTransport"]),
                prompt: prompt,
                images: images,
                describe: { $0 },
                shrink: { image in
                    shrinkCalls.append(image.slot)
                    return shrunkBySlot[image.slot] ?? nil
                }
            )

            #expect(result.status.rawValue == Self.string(expect["status"]), "\(caseId) status")
            #expect(result.errorKind?.rawValue == Self.string(expect["errorKind"]), "\(caseId) errorKind")
            #expect(result.requestBytes == Self.int(expect["requestBytes"]), "\(caseId) requestBytes")

            let expectedImages = try #require(expect["images"] as? [[String: Any]], "\(caseId) expect images").map { raw in
                Expected(
                    slot: try #require(Self.int(raw["slot"])),
                    mime: try #require(Self.string(raw["mime"])),
                    byteCount: try #require(Self.int(raw["byteCount"]))
                )
            }
            let actualImages = result.images.map { Expected(slot: $0.slot, mime: $0.mime, byteCount: $0.byteCount) }
            #expect(actualImages == expectedImages, "\(caseId) images")
            #expect(shrinkCalls == (expect["shrinkCalls"] as? [Int]), "\(caseId) shrinkCalls")
        }
    }
}
