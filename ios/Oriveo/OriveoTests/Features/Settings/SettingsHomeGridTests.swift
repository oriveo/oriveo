import Foundation
import Testing
@testable import Oriveo

/// Settings home grid: the layout and the grid line color follow the shared `shared/theme-contracts/settings-home.v1.json`.
/// Expected values are always read from the JSON by case `name`.
@Suite("Settings home grid")
@MainActor
struct SettingsHomeGridTests {
    @Test(
        "grid layout follows the item count",
        arguments: [
            "grid_four_items_two_by_two",
            "grid_three_items_one_by_three",
            "grid_two_items_one_by_two",
            "grid_one_item_full_row",
            "grid_zero_items_hidden",
        ]
    )
    func gridShape(name: String) throws {
        let testCase = try Self.namedCase(name, in: "gridCases")
        let count = try #require(testCase["count"] as? Int)
        let shape = settingsGridShape(count: count)
        #expect(shape.columns == testCase["columns"] as? Int, "\(name)")
        #expect(shape.rows == testCase["rows"] as? Int, "\(name)")
    }

    @Test("the memory tile preview strips leading list markers and joins lines; a list marker alone counts as unset")
    func memoryPreviewStripsListMarkers() {
        #expect(settingsMemoryPreview("- Product manager\n- Short answers") == "Product manager Short answers")
        #expect(settingsMemoryPreview("* a\n• b") == "a b")
        #expect(settingsMemoryPreview("  -  \n") == nil)
        #expect(settingsMemoryPreview("") == nil)
        #expect(settingsMemoryPreview(String(repeating: "x", count: 31)) == String(repeating: "x", count: 30) + "...")
        // A hyphen inside the text is left alone
        #expect(settingsMemoryPreview("a-b - c") == "a-b - c")
    }

    @Test("dark grid line opacity = base + perGlowK × glowK")
    func gridLineAlphaFollowsGlowK() throws {
        let root = try Self.contract()
        let alpha = try #require(root["gridLineAlpha"] as? [String: Any])
        let base = try #require(alpha["base"] as? Double)
        let perGlowK = try #require(alpha["perGlowK"] as? Double)
        for id in OriveoDarkPaletteID.allCases {
            let glowK = id.palette.glowK
            #expect(abs(settingsGridLineDarkAlpha(glowK: glowK) - (base + perGlowK * glowK)) < 1e-9, "\(id.rawValue)")
        }
    }

    @Test("the voice tile value matches the read-aloud row: system -> \"System\", cloud -> provider display name")
    func voiceTileValueMatchesReadAloudRow() throws {
        let suiteName = "SettingsHomeGridTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = VoiceEngineSettings(defaults: defaults)

        let system = settings.selection(for: .tts)
        #expect(VoiceSettingsModel.engineDisplayName(for: system) == VoiceSettingsModel.row(for: system).title)
        #expect(VoiceSettingsModel.engineDisplayName(for: system) == L10n.tr("System", table: .voice))

        settings.setSelection(
            .cloud(VoiceCloudEngine(providerKind: .openAI, connectionID: "c1", model: "gpt-4o-mini-tts", voice: "alloy")),
            for: .tts
        )
        let cloud = settings.selection(for: .tts)
        #expect(VoiceSettingsModel.engineDisplayName(for: cloud) == VoiceSettingsModel.row(for: cloud).title)
        #expect(VoiceSettingsModel.engineDisplayName(for: cloud) == ProviderKind.openAI.displayName)
    }

    @Test("icon asset names are built as Settings<Key>")
    func iconAssetNames() {
        #expect(SettingsHomeIcon.assetName("memory") == "SettingsMemory")
        #expect(SettingsHomeIcon.assetName("mcp") == "SettingsMcp")
        #expect(SettingsHomeIcon.assetName("faq") == "SettingsFaq")
    }

    // MARK: - Helpers

    private static func namedCase(_ name: String, in group: String) throws -> [String: Any] {
        let root = try contract()
        let cases = try #require(root[group] as? [[String: Any]])
        return try #require(cases.first { $0["name"] as? String == name }, "the JSON has no case \(name)")
    }

    private static func contract() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("theme-contracts")
                .appendingPathComponent("settings-home.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
