import Foundation
import Testing
import UIKit
@testable import Oriveo

/// Default relay avatar icon layer: `cases` and `pickerCases` from the fixture `shared/test-fixtures/relay/relay-avatar-icon.v1.json`,
/// run through the production resolvers `RelayAvatarResolver.resolve(providerID:name:urlString:choice:)` and `pickerCells(name:urlString:)`.
@Suite("Relay avatar · default icon")
@MainActor
struct RelayAvatarIconTests {

    // MARK: - Fixture

    private static func fixture() throws -> [String: Any] {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent("shared/test-fixtures/relay/relay-avatar-icon.v1.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func items(_ key: String) throws -> [[String: Any]] {
        try #require(try fixture()[key] as? [[String: Any]])
    }

    /// Fixture expectation -> result on this platform: the brand id is mapped to the existing official asset name through the production brand table.
    private static func expected(_ raw: [String: Any]) throws -> RelayAvatar {
        switch try #require(raw["kind"] as? String) {
        case "icon":
            let id = try #require(raw["icon"] as? String)
            return .icon(try #require(RelayAvatarIcon(rawValue: id), "icon table is missing \(id)"))
        case "brand":
            let id = try #require(raw["brand"] as? String)
            let brand = try #require(RelayAvatarResolver.brands.first { $0.id == id }, "brand table is missing \(id)")
            return .brand(brand.assetName)
        case "initial":
            return .initial(try #require(raw["text"] as? String))
        default:
            return .generic
        }
    }

    private func runCase(_ caseId: String) throws {
        let item = try #require(try Self.items("cases").first { $0["id"] as? String == caseId }, "fixture is missing \(caseId)")
        let providerID = item["providerId"] as? String ?? ""
        let name = item["name"] as? String ?? ""
        let url = item["url"] as? String ?? ""
        let choice = item["choice"] as? String
        let expected = try Self.expected(try #require(item["expected"] as? [String: Any]))
        #expect(
            RelayAvatarResolver.resolve(providerID: providerID, name: name, urlString: url, choice: choice) == expected,
            "\(caseId)"
        )
        if let hash = item["hash"] as? String {
            let value = try #require(UInt32(hash.dropFirst(2), radix: 16))
            #expect(RelayAvatarResolver.fnv1a32(providerID.lowercased()) == value, "\(caseId) hash")
        }
        // Connection ids on this platform are UUIDs: cases whose id parses as a UUID also run through a production connection (id + customName + baseURLText).
        if let uuid = UUID(uuidString: providerID) {
            let provider = TestFactories.makeProvider(
                id: uuid,
                kind: .relay,
                baseURLText: url.isEmpty ? nil : url,
                customName: name.isEmpty ? nil : name
            )
            #expect(RelayAvatarResolver.avatar(for: provider, choice: choice) == expected, "\(caseId) via Provider")
        }
    }

    @Test("RELAY-AVATAR-ICON-default_uuid_upper") func defaultUUIDUpper() throws { try runCase("default_uuid_upper") }
    @Test("RELAY-AVATAR-ICON-default_uuid_lower_same") func defaultUUIDLowerSame() throws { try runCase("default_uuid_lower_same") }
    @Test("RELAY-AVATAR-ICON-default_trims_ascii_space") func defaultTrimsASCIISpace() throws { try runCase("default_trims_ascii_space") }
    @Test("RELAY-AVATAR-ICON-default_relay_1") func defaultRelay1() throws { try runCase("default_relay_1") }
    @Test("RELAY-AVATAR-ICON-default_relay_4") func defaultRelay4() throws { try runCase("default_relay_4") }
    @Test("RELAY-AVATAR-ICON-default_relay_10") func defaultRelay10() throws { try runCase("default_relay_10") }
    @Test("RELAY-AVATAR-ICON-default_non_ascii_id") func defaultNonASCIIID() throws { try runCase("default_non_ascii_id") }
    @Test("RELAY-AVATAR-ICON-default_when_base_generic") func defaultWhenBaseGeneric() throws { try runCase("default_when_base_generic") }
    @Test("RELAY-AVATAR-ICON-brand_beats_default") func brandBeatsDefault() throws { try runCase("brand_beats_default") }
    @Test("RELAY-AVATAR-ICON-choice_icon_beats_brand") func choiceIconBeatsBrand() throws { try runCase("choice_icon_beats_brand") }
    @Test("RELAY-AVATAR-ICON-choice_icon_beats_default") func choiceIconBeatsDefault() throws { try runCase("choice_icon_beats_default") }
    @Test("RELAY-AVATAR-ICON-choice_letter") func choiceLetter() throws { try runCase("choice_letter") }
    @Test("RELAY-AVATAR-ICON-choice_letter_beats_brand") func choiceLetterBeatsBrand() throws { try runCase("choice_letter_beats_brand") }
    @Test("RELAY-AVATAR-ICON-choice_letter_without_initial") func choiceLetterWithoutInitial() throws { try runCase("choice_letter_without_initial") }
    @Test("RELAY-AVATAR-ICON-unknown_choice_ignored") func unknownChoiceIgnored() throws { try runCase("unknown_choice_ignored") }
    @Test("RELAY-AVATAR-ICON-brand_value_not_a_choice") func brandValueNotAChoice() throws { try runCase("brand_value_not_a_choice") }
    @Test("RELAY-AVATAR-ICON-empty_id_keeps_base") func emptyIDKeepsBase() throws { try runCase("empty_id_keeps_base") }
    @Test("RELAY-AVATAR-ICON-empty_id_keeps_base_generic") func emptyIDKeepsBaseGeneric() throws { try runCase("empty_id_keeps_base_generic") }

    // MARK: - Picker cell order

    private static func cellID(_ cell: RelayAvatarPickerCell) -> String {
        switch cell {
        case let .brand(brand): return "brand:\(brand.id)"
        case let .icon(icon): return icon.id
        case let .letter(text): return "letter:\(text)"
        }
    }

    private func runPickerCase(_ caseId: String) throws {
        let item = try #require(try Self.items("pickerCases").first { $0["id"] as? String == caseId }, "fixture is missing \(caseId)")
        let name = item["name"] as? String ?? ""
        let url = item["url"] as? String ?? ""
        let cells = try #require(item["cells"] as? [String])
        #expect(RelayAvatarResolver.pickerCells(name: name, urlString: url).map(Self.cellID) == cells, "\(caseId)")

        // The detail page sheet gets the same cells through a production connection.
        let provider = TestFactories.makeProvider(
            kind: .relay,
            baseURLText: url.isEmpty ? nil : url,
            customName: name.isEmpty ? nil : name
        )
        #expect(RelayAvatarPicker.cells(for: provider).map(Self.cellID) == cells, "\(caseId) via Provider")
    }

    @Test("RELAY-AVATAR-PICKER-picker_with_brand") func pickerWithBrand() throws { try runPickerCase("picker_with_brand") }
    @Test("RELAY-AVATAR-PICKER-picker_no_brand") func pickerNoBrand() throws { try runPickerCase("picker_no_brand") }
    @Test("RELAY-AVATAR-PICKER-picker_no_letter") func pickerNoLetter() throws { try runPickerCase("picker_no_letter") }

    // MARK: - Fixture consistency

    @Test("RELAY-AVATAR-ICON every fixture case has a test of the same name; the icon table matches the fixture item by item")
    func fixtureCoveredAndIconTableMatches() throws {
        let root = try Self.fixture()
        #expect(Set(try Self.items("cases").compactMap { $0["id"] as? String }) == [
            "default_uuid_upper", "default_uuid_lower_same", "default_trims_ascii_space", "default_relay_1",
            "default_relay_4", "default_relay_10", "default_non_ascii_id", "default_when_base_generic",
            "brand_beats_default", "choice_icon_beats_brand", "choice_icon_beats_default", "choice_letter",
            "choice_letter_beats_brand", "choice_letter_without_initial", "unknown_choice_ignored",
            "brand_value_not_a_choice", "empty_id_keeps_base", "empty_id_keeps_base_generic",
        ])
        #expect(Set(try Self.items("pickerCases").compactMap { $0["id"] as? String }) == [
            "picker_with_brand", "picker_no_brand", "picker_no_letter",
        ])
        #expect(RelayAvatarResolver.letterChoice == root["letterChoice"] as? String)
        let icons = try Self.items("icons")
        #expect(RelayAvatarIcon.allCases.map(\.id) == icons.compactMap { $0["id"] as? String })
        #expect(RelayAvatarIcon.allCases.map(\.paletteToken) == icons.compactMap { $0["palette"] as? String })
    }

    @Test("RELAY-AVATAR-GLYPH-01 all 10 original icons resolve a RelayAvatar/<id> asset; the enum matches the fixture icons in order, id and palette")
    func glyph01AssetsExistAndMatchFixture() throws {
        let icons = try Self.items("icons")
        let fixtureIDs = icons.compactMap { $0["id"] as? String }
        #expect(fixtureIDs.count == 10)
        #expect(RelayAvatarIcon.allCases.map(\.id) == fixtureIDs)
        #expect(RelayAvatarIcon.allCases.map(\.paletteToken) == icons.compactMap { $0["palette"] as? String })
        for id in fixtureIDs {
            let icon = try #require(RelayAvatarIcon(rawValue: id), "icon table is missing \(id)")
            #expect(icon.assetName == "RelayAvatar/\(id)")
            #expect(UIImage(named: icon.assetName) != nil, "\(id) is missing its RelayAvatar asset")
        }
    }
}
