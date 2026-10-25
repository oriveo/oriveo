import Foundation
import Testing
@testable import Oriveo

/// Input capability copy: every reason x medium entry resolves, all 15 non-en locales in Chat.xcstrings
/// are translated, and zh-Hans matches the authored copy verbatim (constants inlined in the test below).
@Suite("Input capability copy · 16 locales")
struct InputCapabilityCopyTests {

    private static let locales = [
        "ar", "de", "es", "fr", "hi", "id", "ja", "ko",
        "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant",
    ]

    private typealias Copy = InputCapabilityCopy

    /// All keys: 5 reasons x 3 media + 3 first-attachment hints + 3 resend-without + 1 bubble.
    private static var allKeys: [String] {
        var keys: [String] = []
        for reason in Copy.Reason.allCases {
            for medium in Copy.Medium.allCases { keys.append(Copy.disabledKey(reason, medium)) }
        }
        for medium in Copy.Medium.allCases {
            keys.append(Copy.hintFirstAttachKey(medium))
            keys.append(Copy.resendWithoutKey(medium))
        }
        keys.append(Copy.bubbleNotSentToModelKey)
        return keys
    }

    @Test("Every reason x medium, hint, resend and bubble entry resolves to a non-empty string")
    func everyEntryResolvesNonEmpty() {
        for reason in Copy.Reason.allCases {
            for medium in Copy.Medium.allCases {
                #expect(!Copy.disabled(reason, medium).isEmpty, "disabled \(reason) \(medium)")
            }
        }
        for medium in Copy.Medium.allCases {
            #expect(!Copy.hintFirstAttach(medium).isEmpty, "hint \(medium)")
            #expect(!Copy.resendWithout(medium).isEmpty, "resend \(medium)")
        }
        #expect(!Copy.bubbleNotSentToModel.isEmpty)
        #expect(Set(Self.allKeys).count == 22)
    }

    @Test("Every key is translated in all 15 non-en locales of Chat.xcstrings")
    func everyKeyTranslatedInCatalog() throws {
        let catalog = try Self.chatCatalog()
        for key in Self.allKeys {
            guard let entry = catalog[key] as? [String: Any] else {
                Issue.record("Chat.xcstrings is missing key: \(key)")
                continue
            }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for locale in Self.locales {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                let state = unit?["state"] as? String
                #expect(state == "translated", "\(locale) · \(key) state=\(state ?? "nil")")
                #expect(!value.isEmpty && value != key, "\(locale) · \(key) is still English or empty: \(value)")
            }
        }
    }

    /// Production lookup path: the zh-Hans.lproj Chat table compiled into the app + the keys the entry point returns.
    @Test("zh-Hans matches the authored copy verbatim")
    func zhHansMatchesAuthoredCopy() throws {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        func zh(_ key: String) -> String { bundle.localizedString(forKey: key, value: key, table: "Chat") }

        let disabled: [Copy.Reason: [Copy.Medium: String]] = [
            .modelAbsent: [.image: "\u{6B64}\u{6A21}\u{578B}\u{4E0D}\u{652F}\u{6301}\u{56FE}\u{7247}\u{8F93}\u{5165}", .file: "\u{6B64}\u{6A21}\u{578B}\u{4E0D}\u{652F}\u{6301}\u{6587}\u{4EF6}\u{8F93}\u{5165}", .video: "\u{6B64}\u{6A21}\u{578B}\u{4E0D}\u{652F}\u{6301}\u{89C6}\u{9891}\u{8F93}\u{5165}"],
            .wireNotImplemented: [.image: "\u{5F53}\u{524D}\u{8FDE}\u{63A5}\u{8FD8}\u{4E0D}\u{80FD}\u{53D1}\u{9001}\u{56FE}\u{7247}", .file: "\u{5F53}\u{524D}\u{8FDE}\u{63A5}\u{8FD8}\u{4E0D}\u{80FD}\u{53D1}\u{9001}\u{6587}\u{4EF6}", .video: "\u{5F53}\u{524D}\u{8FDE}\u{63A5}\u{8FD8}\u{4E0D}\u{80FD}\u{53D1}\u{9001}\u{89C6}\u{9891}"],
            .killSwitch: [.image: "\u{8BE5}\u{4F9B}\u{5E94}\u{5546}\u{7684}\u{56FE}\u{7247}\u{8F93}\u{5165}\u{6682}\u{65F6}\u{5173}\u{95ED}", .file: "\u{8BE5}\u{4F9B}\u{5E94}\u{5546}\u{7684}\u{6587}\u{4EF6}\u{8F93}\u{5165}\u{6682}\u{65F6}\u{5173}\u{95ED}", .video: "\u{8BE5}\u{4F9B}\u{5E94}\u{5546}\u{7684}\u{89C6}\u{9891}\u{8F93}\u{5165}\u{6682}\u{65F6}\u{5173}\u{95ED}"],
            .rejectedRecently: [.image: "\u{8BE5}\u{6A21}\u{578B}\u{521A}\u{62D2}\u{7EDD}\u{8FC7}\u{56FE}\u{7247}", .file: "\u{8BE5}\u{6A21}\u{578B}\u{521A}\u{62D2}\u{7EDD}\u{8FC7}\u{6587}\u{4EF6}", .video: "\u{8BE5}\u{6A21}\u{578B}\u{521A}\u{62D2}\u{7EDD}\u{8FC7}\u{89C6}\u{9891}"],
            .userRemoved: [.image: "\u{4F60}\u{5DF2}\u{4E3A}\u{6B64}\u{6A21}\u{578B}\u{5173}\u{95ED}\u{56FE}\u{7247}\u{8F93}\u{5165}", .file: "\u{4F60}\u{5DF2}\u{4E3A}\u{6B64}\u{6A21}\u{578B}\u{5173}\u{95ED}\u{6587}\u{4EF6}\u{8F93}\u{5165}", .video: "\u{4F60}\u{5DF2}\u{4E3A}\u{6B64}\u{6A21}\u{578B}\u{5173}\u{95ED}\u{89C6}\u{9891}\u{8F93}\u{5165}"],
        ]
        let hint: [Copy.Medium: String] = [
            .image: "\u{5C1A}\u{672A}\u{786E}\u{8BA4}\u{8BE5}\u{6A21}\u{578B}\u{80FD}\u{5426}\u{8BC6}\u{56FE}\u{FF0C}\u{5931}\u{8D25}\u{4F1A}\u{544A}\u{8BC9}\u{4F60}",
            .file: "\u{5C1A}\u{672A}\u{786E}\u{8BA4}\u{8BE5}\u{6A21}\u{578B}\u{80FD}\u{5426}\u{8BFB}\u{6587}\u{4EF6}\u{FF0C}\u{5931}\u{8D25}\u{4F1A}\u{544A}\u{8BC9}\u{4F60}",
            .video: "\u{5C1A}\u{672A}\u{786E}\u{8BA4}\u{8BE5}\u{6A21}\u{578B}\u{80FD}\u{5426}\u{770B}\u{89C6}\u{9891}\u{FF0C}\u{5931}\u{8D25}\u{4F1A}\u{544A}\u{8BC9}\u{4F60}",
        ]
        let resend: [Copy.Medium: String] = [.image: "\u{53BB}\u{6389}\u{56FE}\u{7247}\u{91CD}\u{53D1}", .file: "\u{53BB}\u{6389}\u{6587}\u{4EF6}\u{91CD}\u{53D1}", .video: "\u{53BB}\u{6389}\u{89C6}\u{9891}\u{91CD}\u{53D1}"]

        for reason in Copy.Reason.allCases {
            for medium in Copy.Medium.allCases {
                #expect(zh(Copy.disabledKey(reason, medium)) == disabled[reason]?[medium], "\(reason) \(medium)")
            }
        }
        for medium in Copy.Medium.allCases {
            #expect(zh(Copy.hintFirstAttachKey(medium)) == hint[medium], "hint \(medium)")
            #expect(zh(Copy.resendWithoutKey(medium)) == resend[medium], "resend \(medium)")
        }
        #expect(zh(Copy.bubbleNotSentToModelKey) == "\u{672A}\u{53D1}\u{9001}\u{7ED9}\u{6B64}\u{6A21}\u{578B}")
    }

    private static func chatCatalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oriveo/Chat.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return root?["strings"] as? [String: Any] ?? [:]
    }
}
