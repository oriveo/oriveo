import Foundation

// Compact numbers (context usage, token menu subtitles); spec is the rules in `shared/context-contracts/compact-number.v1.json`.
// The table is a snapshot of CLDR 48.2.3 short formats, written in code and compared item by item against the fixture; no JSON is read and no NumberFormatter / compactName is called.
// Rounds down only, with integer arithmetic throughout.

public enum ContextCompactNumber {
    public struct Tier: Hashable, Sendable {
        public let min: Int
        public let pattern: String
        /// Arabic 1000 tier only: used when frac == 0 and int % 100 falls within 3...10.
        public let few: String?

        public init(min: Int, pattern: String, few: String? = nil) {
            self.min = min
            self.pattern = pattern
            self.few = few
        }
    }

    public struct Table: Hashable, Sendable {
        public let decimal: String
        public let group: String
        public let tiers: [Tier]

        public init(decimal: String, group: String, tiers: [Tier]) {
            self.decimal = decimal
            self.group = group
            self.tiers = tiers
        }
    }

    public struct Entry: Hashable, Sendable {
        public let code: String
        public let table: Table

        public init(code: String, table: Table) {
            self.code = code
            self.table = table
        }
    }

    /// 16 languages, in the same order as the fixture locales.
    public static let localeCodes: [String] = tables.map(\.code)

    /// Per rule 1, maps any language tag to one of the 16 codes; anything unrecognized (including the empty string) becomes en.
    public static func resolveLocale(_ tag: String) -> String {
        var raw = tag
        if let at = raw.firstIndex(of: "@") {
            raw = String(raw[..<at])
        }
        raw = raw.replacingOccurrences(of: "_", with: "-")
        var subtags: [String] = []
        for part in raw.split(separator: "-", omittingEmptySubsequences: false) {
            if part.count == 1 { break }
            subtags.append(part.lowercased())
        }
        guard let language = subtags.first, !language.isEmpty else { return "en" }
        switch language {
        case "zh":
            // Script code first (zh-Hans-HK is still Simplified); only without a script code do we look at the region.
            let rest = subtags.dropFirst()
            if rest.contains("hans") { return "zh-Hans" }
            if rest.contains("hant") { return "zh-Hant" }
            let traditionalRegions: Set<String> = ["tw", "hk", "mo"]
            return rest.contains(where: traditionalRegions.contains) ? "zh-Hant" : "zh-Hans"
        case "pt":
            return "pt-BR"
        case "in":
            return "id"
        default:
            return localeCodes.contains(language) ? language : "en"
        }
    }

    /// value is a non-negative count such as tokens; negatives are treated as 0 and anything above 10^15 as 10^15. locale is any tag and goes through resolveLocale first.
    public static func format(_ value: Int, locale: String) -> String {
        let value = Swift.min(Swift.max(value, 0), 1_000_000_000_000_000)
        if value < 1000 { return String(value) }
        let code = resolveLocale(locale)
        guard let table = tables.first(where: { $0.code == code })?.table,
              let tier = table.tiers.last(where: { $0.min <= value })
        else { return String(value) }

        let zeros = tier.pattern.filter { $0 == "0" }.count
        if zeros == tier.pattern.count {
            return value >= 10_000 ? grouped(value, separator: table.group) : String(value)
        }

        // unit10 = min / 10^(z-1) / 10, which the fixture guarantees is an integer >= 100.
        var unit10 = tier.min
        for _ in 0..<zeros { unit10 /= 10 }
        let tenths = value / unit10
        let integer = tenths / 10
        let fraction = tenths % 10
        let number = fraction == 0 ? String(integer) : "\(integer)\(table.decimal)\(fraction)"
        var pattern = tier.pattern
        if fraction == 0, let few = tier.few, (3...10).contains(integer % 100) {
            pattern = few
        }
        guard let run = pattern.range(of: String(repeating: "0", count: zeros)) else { return number }
        return pattern.replacingCharacters(in: run, with: number)
    }

    private static func grouped(_ value: Int, separator: String) -> String {
        let digits = Array(String(value))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out += separator }
            out.append(digit)
        }
        return out
    }

    public static let tables: [Entry] = [
        Entry(code: "zh-Hans", table: Table(decimal: ".", group: ",", tiers: [
            Tier(min: 1_000, pattern: "0"),
            Tier(min: 10_000, pattern: "0万"),
            Tier(min: 100_000, pattern: "00万"),
            Tier(min: 1_000_000, pattern: "000万"),
            Tier(min: 10_000_000, pattern: "0000万"),
            Tier(min: 100_000_000, pattern: "0亿"),
            Tier(min: 1_000_000_000, pattern: "00亿"),
            Tier(min: 10_000_000_000, pattern: "000亿"),
            Tier(min: 100_000_000_000, pattern: "0000亿"),
            Tier(min: 1_000_000_000_000, pattern: "0万亿"),
        ])),
        Entry(code: "zh-Hant", table: Table(decimal: ".", group: ",", tiers: [
            Tier(min: 1_000, pattern: "0"),
            Tier(min: 10_000, pattern: "0萬"),
            Tier(min: 100_000, pattern: "00萬"),
            Tier(min: 1_000_000, pattern: "000萬"),
            Tier(min: 10_000_000, pattern: "0000萬"),
            Tier(min: 100_000_000, pattern: "0億"),
            Tier(min: 1_000_000_000, pattern: "00億"),
            Tier(min: 10_000_000_000, pattern: "000億"),
            Tier(min: 100_000_000_000, pattern: "0000億"),
            Tier(min: 1_000_000_000_000, pattern: "0兆"),
        ])),
        Entry(code: "en", table: Table(decimal: ".", group: ",", tiers: [
            Tier(min: 1_000, pattern: "0K"),
            Tier(min: 10_000, pattern: "00K"),
            Tier(min: 100_000, pattern: "000K"),
            Tier(min: 1_000_000, pattern: "0M"),
            Tier(min: 10_000_000, pattern: "00M"),
            Tier(min: 100_000_000, pattern: "000M"),
            Tier(min: 1_000_000_000, pattern: "0B"),
            Tier(min: 10_000_000_000, pattern: "00B"),
            Tier(min: 100_000_000_000, pattern: "000B"),
            Tier(min: 1_000_000_000_000, pattern: "0T"),
        ])),
        Entry(code: "ja", table: Table(decimal: ".", group: ",", tiers: [
            Tier(min: 1_000, pattern: "0"),
            Tier(min: 10_000, pattern: "0万"),
            Tier(min: 100_000, pattern: "00万"),
            Tier(min: 1_000_000, pattern: "000万"),
            Tier(min: 10_000_000, pattern: "0000万"),
            Tier(min: 100_000_000, pattern: "0億"),
            Tier(min: 1_000_000_000, pattern: "00億"),
            Tier(min: 10_000_000_000, pattern: "000億"),
            Tier(min: 100_000_000_000, pattern: "0000億"),
            Tier(min: 1_000_000_000_000, pattern: "0兆"),
        ])),
        Entry(code: "ko", table: Table(decimal: ".", group: ",", tiers: [
            Tier(min: 1_000, pattern: "0천"),
            Tier(min: 10_000, pattern: "0만"),
            Tier(min: 100_000, pattern: "00만"),
            Tier(min: 1_000_000, pattern: "000만"),
            Tier(min: 10_000_000, pattern: "0000만"),
            Tier(min: 100_000_000, pattern: "0억"),
            Tier(min: 1_000_000_000, pattern: "00억"),
            Tier(min: 10_000_000_000, pattern: "000억"),
            Tier(min: 100_000_000_000, pattern: "0000억"),
            Tier(min: 1_000_000_000_000, pattern: "0조"),
        ])),
        Entry(code: "de", table: Table(decimal: ",", group: ".", tiers: [
            Tier(min: 1_000, pattern: "0"),
            Tier(min: 10_000, pattern: "0"),
            Tier(min: 100_000, pattern: "0"),
            Tier(min: 1_000_000, pattern: "0\u{00A0}Mio."),
            Tier(min: 10_000_000, pattern: "00\u{00A0}Mio."),
            Tier(min: 100_000_000, pattern: "000\u{00A0}Mio."),
            Tier(min: 1_000_000_000, pattern: "0\u{00A0}Mrd."),
            Tier(min: 10_000_000_000, pattern: "00\u{00A0}Mrd."),
            Tier(min: 100_000_000_000, pattern: "000\u{00A0}Mrd."),
            Tier(min: 1_000_000_000_000, pattern: "0\u{00A0}Bio."),
        ])),
        Entry(code: "fr", table: Table(decimal: ",", group: "\u{202F}", tiers: [
            Tier(min: 1_000, pattern: "0\u{00A0}k"),
            Tier(min: 10_000, pattern: "00\u{00A0}k"),
            Tier(min: 100_000, pattern: "000\u{00A0}k"),
            Tier(min: 1_000_000, pattern: "0\u{00A0}M"),
            Tier(min: 10_000_000, pattern: "00\u{00A0}M"),
            Tier(min: 100_000_000, pattern: "000\u{00A0}M"),
            Tier(min: 1_000_000_000, pattern: "0\u{00A0}Md"),
            Tier(min: 10_000_000_000, pattern: "00\u{00A0}Md"),
            Tier(min: 100_000_000_000, pattern: "000\u{00A0}Md"),
            Tier(min: 1_000_000_000_000, pattern: "0\u{00A0}Bn"),
        ])),
        Entry(code: "es", table: Table(decimal: ",", group: ".", tiers: [
            Tier(min: 1_000, pattern: "0\u{00A0}mil"),
            Tier(min: 10_000, pattern: "00\u{00A0}mil"),
            Tier(min: 100_000, pattern: "000\u{00A0}mil"),
            Tier(min: 1_000_000, pattern: "0\u{00A0}M"),
            Tier(min: 10_000_000, pattern: "00\u{00A0}M"),
            Tier(min: 100_000_000, pattern: "000\u{00A0}M"),
            Tier(min: 1_000_000_000, pattern: "0000\u{00A0}M"),
            Tier(min: 10_000_000_000, pattern: "00\u{00A0}mil\u{00A0}M"),
            Tier(min: 100_000_000_000, pattern: "000\u{00A0}mil\u{00A0}M"),
            Tier(min: 1_000_000_000_000, pattern: "0\u{00A0}B"),
        ])),
        Entry(code: "pt-BR", table: Table(decimal: ",", group: ".", tiers: [
            Tier(min: 1_000, pattern: "0\u{00A0}mil"),
            Tier(min: 10_000, pattern: "00\u{00A0}mil"),
            Tier(min: 100_000, pattern: "000\u{00A0}mil"),
            Tier(min: 1_000_000, pattern: "0\u{00A0}mi"),
            Tier(min: 10_000_000, pattern: "00\u{00A0}mi"),
            Tier(min: 100_000_000, pattern: "000\u{00A0}mi"),
            Tier(min: 1_000_000_000, pattern: "0\u{00A0}bi"),
            Tier(min: 10_000_000_000, pattern: "00\u{00A0}bi"),
            Tier(min: 100_000_000_000, pattern: "000\u{00A0}bi"),
            Tier(min: 1_000_000_000_000, pattern: "0\u{00A0}tri"),
        ])),
        Entry(code: "ru", table: Table(decimal: ",", group: "\u{00A0}", tiers: [
            Tier(min: 1_000, pattern: "0\u{00A0}тыс."),
            Tier(min: 10_000, pattern: "00\u{00A0}тыс."),
            Tier(min: 100_000, pattern: "000\u{00A0}тыс."),
            Tier(min: 1_000_000, pattern: "0\u{00A0}млн"),
            Tier(min: 10_000_000, pattern: "00\u{00A0}млн"),
            Tier(min: 100_000_000, pattern: "000\u{00A0}млн"),
            Tier(min: 1_000_000_000, pattern: "0\u{00A0}млрд"),
            Tier(min: 10_000_000_000, pattern: "00\u{00A0}млрд"),
            Tier(min: 100_000_000_000, pattern: "000\u{00A0}млрд"),
            Tier(min: 1_000_000_000_000, pattern: "0\u{00A0}трлн"),
        ])),
        Entry(code: "tr", table: Table(decimal: ",", group: ".", tiers: [
            Tier(min: 1_000, pattern: "0\u{00A0}B"),
            Tier(min: 10_000, pattern: "00\u{00A0}B"),
            Tier(min: 100_000, pattern: "000\u{00A0}B"),
            Tier(min: 1_000_000, pattern: "0\u{00A0}Mn"),
            Tier(min: 10_000_000, pattern: "00\u{00A0}Mn"),
            Tier(min: 100_000_000, pattern: "000\u{00A0}Mn"),
            Tier(min: 1_000_000_000, pattern: "0\u{00A0}Mr"),
            Tier(min: 10_000_000_000, pattern: "00\u{00A0}Mr"),
            Tier(min: 100_000_000_000, pattern: "000\u{00A0}Mr"),
            Tier(min: 1_000_000_000_000, pattern: "0\u{00A0}Tn"),
        ])),
        Entry(code: "id", table: Table(decimal: ",", group: ".", tiers: [
            Tier(min: 1_000, pattern: "0\u{00A0}rb"),
            Tier(min: 10_000, pattern: "00\u{00A0}rb"),
            Tier(min: 100_000, pattern: "000\u{00A0}rb"),
            Tier(min: 1_000_000, pattern: "0\u{00A0}jt"),
            Tier(min: 10_000_000, pattern: "00\u{00A0}jt"),
            Tier(min: 100_000_000, pattern: "000\u{00A0}jt"),
            Tier(min: 1_000_000_000, pattern: "0\u{00A0}M"),
            Tier(min: 10_000_000_000, pattern: "00\u{00A0}M"),
            Tier(min: 100_000_000_000, pattern: "000\u{00A0}M"),
            Tier(min: 1_000_000_000_000, pattern: "0\u{00A0}T"),
        ])),
        Entry(code: "vi", table: Table(decimal: ",", group: ".", tiers: [
            Tier(min: 1_000, pattern: "0\u{00A0}N"),
            Tier(min: 10_000, pattern: "00\u{00A0}N"),
            Tier(min: 100_000, pattern: "000\u{00A0}N"),
            Tier(min: 1_000_000, pattern: "0\u{00A0}Tr"),
            Tier(min: 10_000_000, pattern: "00\u{00A0}Tr"),
            Tier(min: 100_000_000, pattern: "000\u{00A0}Tr"),
            Tier(min: 1_000_000_000, pattern: "0\u{00A0}T"),
            Tier(min: 10_000_000_000, pattern: "00\u{00A0}T"),
            Tier(min: 100_000_000_000, pattern: "000\u{00A0}T"),
            Tier(min: 1_000_000_000_000, pattern: "0\u{00A0}NT"),
        ])),
        Entry(code: "th", table: Table(decimal: ".", group: ",", tiers: [
            Tier(min: 1_000, pattern: "0K"),
            Tier(min: 10_000, pattern: "00K"),
            Tier(min: 100_000, pattern: "000K"),
            Tier(min: 1_000_000, pattern: "0M"),
            Tier(min: 10_000_000, pattern: "00M"),
            Tier(min: 100_000_000, pattern: "000M"),
            Tier(min: 1_000_000_000, pattern: "0B"),
            Tier(min: 10_000_000_000, pattern: "00B"),
            Tier(min: 100_000_000_000, pattern: "000B"),
            Tier(min: 1_000_000_000_000, pattern: "0T"),
        ])),
        Entry(code: "hi", table: Table(decimal: ".", group: ",", tiers: [
            Tier(min: 1_000, pattern: "0\u{00A0}हज़ार"),
            Tier(min: 10_000, pattern: "00\u{00A0}हज़ार"),
            Tier(min: 100_000, pattern: "0\u{00A0}लाख"),
            Tier(min: 1_000_000, pattern: "00\u{00A0}लाख"),
            Tier(min: 10_000_000, pattern: "0\u{00A0}क॰"),
            Tier(min: 100_000_000, pattern: "00\u{00A0}क॰"),
            Tier(min: 1_000_000_000, pattern: "0\u{00A0}अ॰"),
            Tier(min: 10_000_000_000, pattern: "00\u{00A0}अ॰"),
            Tier(min: 100_000_000_000, pattern: "0\u{00A0}ख॰"),
            Tier(min: 1_000_000_000_000, pattern: "00\u{00A0}ख॰"),
        ])),
        Entry(code: "ar", table: Table(decimal: ".", group: ",", tiers: [
            Tier(min: 1_000, pattern: "0\u{00A0}ألف", few: "0\u{00A0}آلاف"),
            Tier(min: 10_000, pattern: "00\u{00A0}ألف"),
            Tier(min: 100_000, pattern: "000\u{00A0}ألف"),
            Tier(min: 1_000_000, pattern: "0\u{00A0}مليون"),
            Tier(min: 10_000_000, pattern: "00\u{00A0}مليون"),
            Tier(min: 100_000_000, pattern: "000\u{00A0}مليون"),
            Tier(min: 1_000_000_000, pattern: "0\u{00A0}مليار"),
            Tier(min: 10_000_000_000, pattern: "00\u{00A0}مليار"),
            Tier(min: 100_000_000_000, pattern: "000\u{00A0}مليار"),
            Tier(min: 1_000_000_000_000, pattern: "0\u{00A0}ترليون"),
        ])),
    ]
}
