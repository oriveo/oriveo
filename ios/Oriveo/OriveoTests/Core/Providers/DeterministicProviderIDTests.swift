import Foundation
import Testing
@testable import Oriveo

@Suite("DeterministicProviderID")
struct DeterministicProviderIDTests {

    private static let siliconFlowIntlID = "9935660f-5b1a-50ce-b700-42da5090fe1b".uppercased()

    private static let golden: [(name: String, id: String)] = [
        ("openAI|", "CEE693BC-01B3-5542-A639-D3263AF0D47A"),
        ("anthropic|", "F4D47A73-2034-5CEB-B2B7-366412C44A5B"),
        ("gemini|", "EF43015B-FE23-5D59-8D1E-460C5D07D447"),
        ("openRouter|", "644B24B7-E017-5253-BDDA-2E1D24A0608E"),
        ("deepseek|", "72EFDE43-1EBD-5251-8BF8-87596CACCD04"),
        ("grok|", "2238EE91-0BC2-51CC-AA86-595F0B0BF865"),
        ("groq|", "1C71C539-54CF-5613-B913-E994161DF74F"),
        ("together|", "91DD594C-1437-5C33-A923-EA5DEBC43D02"),
        ("fireworks|", "3ABBD200-CAF5-5D8B-A473-4FE3E92AE39D"),
        ("zhipu|", "6993D319-CD3A-5D36-8DDC-17C7D32B00EA"),
        ("mistral|", "986B6CD0-2ECA-570B-BCED-00D4D6708C81"),
        ("siliconFlow|", "DEE48B1E-584B-51F4-8A1F-F921E52796EA"),
        ("miniMax|global", "C1F9299A-51D9-51ED-9B4F-853DEC6875A6"),
        ("miniMax|cn", "53CA3FCB-2E5C-5B51-BDA0-61FC22339096"),
        ("qwen|sg", "B5E00F0C-3E68-5E10-B66C-A6DAD2FD7263"),
        ("qwen|bj", "248F0148-C596-5B0A-A5EE-7D9091F789F0"),
        ("qwen|hk", "B64ED15A-F012-574C-808E-1A728151ECF3"),
        ("qwen|us", "92D43121-6B8A-5E38-A831-6506372A84AB"),
        ("moonshot|intl", "E8BDD52A-8670-5FF1-8BC4-6D7653977089"),
        ("moonshot|cn", "6331C09B-260B-5105-AA15-63380223D72E"),
        ("siliconFlow|intl", siliconFlowIntlID),
    ]

    @Test("Golden Vectors Match Exact Uppercase")
    func goldenVectorsMatchExactUppercase() {
        for vector in Self.golden {
            let produced = DeterministicProviderID.makeV5(name: vector.name)
            #expect(
                produced.uuidString == vector.id,
                "name=\(vector.name) expected=\(vector.id) got=\(produced.uuidString)"
            )
        }
    }

    @Test("Results Are Valid V5 And Round Trip")
    func resultsAreValidV5AndRoundTrip() {
        for vector in Self.golden {
            let reparsed = UUID(uuidString: vector.id)
            #expect(reparsed != nil)
            #expect(vector.id == vector.id.uppercased())
            let segments = vector.id.split(separator: "-")
            #expect(segments.count == 5)
            #expect(segments[2].first == "5")
            let variant = segments[3].first.map(Character.init)
            #expect(["8", "9", "A", "B"].contains(variant.map(String.init) ?? ""), "illegal variant \(vector.id)")
        }
    }

    @Test("Make Kind Region Matches Golden")
    func makeKindRegionMatchesGolden() {
        #expect(DeterministicProviderID.make(kind: .openAI, regionID: "").uuidString == "CEE693BC-01B3-5542-A639-D3263AF0D47A")
        #expect(DeterministicProviderID.make(kind: .together, regionID: "").uuidString == "91DD594C-1437-5C33-A923-EA5DEBC43D02")
        #expect(DeterministicProviderID.make(kind: .fireworks, regionID: "").uuidString == "3ABBD200-CAF5-5D8B-A473-4FE3E92AE39D")
        #expect(DeterministicProviderID.make(kind: .miniMax, regionID: "global").uuidString == "C1F9299A-51D9-51ED-9B4F-853DEC6875A6")
        #expect(DeterministicProviderID.make(kind: .qwen, regionID: "sg").uuidString == "B5E00F0C-3E68-5E10-B66C-A6DAD2FD7263")
        #expect(DeterministicProviderID.make(kind: .moonshot, regionID: "intl").uuidString == "E8BDD52A-8670-5FF1-8BC4-6D7653977089")
        #expect(DeterministicProviderID.make(kind: .siliconFlow, regionID: "cn").uuidString == "DEE48B1E-584B-51F4-8A1F-F921E52796EA")
        #expect(DeterministicProviderID.make(kind: .siliconFlow, regionID: "intl").uuidString == Self.siliconFlowIntlID)
    }

    @Test("Region IDResolution")
    func regionIDResolution() {
        let catalog = ProviderSetupCatalog.fallback
        #expect(DeterministicProviderID.regionID(for: .openAI, baseURLText: nil, setupCatalog: catalog) == "")
        #expect(DeterministicProviderID.regionID(for: .openRouter, baseURLText: "https://x", setupCatalog: catalog) == "")
        #expect(DeterministicProviderID.regionID(for: .mistral, baseURLText: nil, setupCatalog: catalog) == "")
        #expect(DeterministicProviderID.regionID(for: .miniMax, baseURLText: nil, setupCatalog: catalog) == "global")
        #expect(DeterministicProviderID.regionID(for: .qwen, baseURLText: nil, setupCatalog: catalog) == "sg")
        #expect(DeterministicProviderID.regionID(for: .moonshot, baseURLText: nil, setupCatalog: catalog) == "intl")
        #expect(DeterministicProviderID.regionID(for: .siliconFlow, baseURLText: nil, setupCatalog: catalog) == "cn")
        #expect(DeterministicProviderID.regionID(for: .miniMax, baseURLText: "api.minimaxi.com/v1", setupCatalog: catalog) == "cn")
        #expect(DeterministicProviderID.regionID(for: .qwen, baseURLText: "dashscope.aliyuncs.com", setupCatalog: catalog) == "bj")
        #expect(DeterministicProviderID.regionID(for: .moonshot, baseURLText: "api.moonshot.cn/v1", setupCatalog: catalog) == "cn")
        #expect(DeterministicProviderID.regionID(for: .siliconFlow, baseURLText: "api.siliconflow.com/v1", setupCatalog: catalog) == "intl")
    }
}
