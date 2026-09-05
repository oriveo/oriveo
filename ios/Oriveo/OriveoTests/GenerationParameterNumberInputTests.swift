import Foundation
import Testing
@testable import Oriveo

@Suite("Generation parameter number input")
struct GenerationParameterNumberInputTests {
    @Test("Display Round Trips")
    func displayRoundTrips() {
        for value in [4096.0, 1_000_000.0, 0.0, -1.0, 32768.0] {
            let text = GenerationParameterDefaultsSheet.numberDisplayText(value)
            #expect(!text.contains(","), "A thousands separator would ruin the next edit: \(text)")
            #expect(!text.contains(" "))
            let parsed = Double(GenerationParameterDefaultsSheet.normalizedNumberInput(text))
            #expect(parsed == value)
        }
        #expect(GenerationParameterDefaultsSheet.numberDisplayText(4096) == "4096")
        #expect(GenerationParameterDefaultsSheet.numberDisplayText(0.7) == "0.7")
    }

    @Test("Parses Grouped Input In English Locale")
    func parsesGroupedInputInEnglishLocale() {
        let en = Locale(identifier: "en_US")
        #expect(Double(GenerationParameterDefaultsSheet.normalizedNumberInput("4,096", locale: en)) == 4096)
        #expect(Double(GenerationParameterDefaultsSheet.normalizedNumberInput("1,000,000", locale: en)) == 1_000_000)
        #expect(Double(GenerationParameterDefaultsSheet.normalizedNumberInput("0.7", locale: en)) == 0.7)
    }

    @Test("Parses Comma Decimal Locales")
    func parsesCommaDecimalLocales() {
        for identifier in ["de_DE", "fr_FR", "es_ES", "pt_BR"] {
            let locale = Locale(identifier: identifier)
            let normalized = GenerationParameterDefaultsSheet.normalizedNumberInput("0,7", locale: locale)
            #expect(Double(normalized) == 0.7)
        }
        let de = Locale(identifier: "de_DE")
        let grouped = GenerationParameterDefaultsSheet.normalizedNumberInput("4.096,5", locale: de)
        #expect(Double(grouped) == 4096.5)
    }

    @Test("Intermediate Input Stays Unparsed")
    func intermediateInputStaysUnparsed() {
        let en = Locale(identifier: "en_US")
        for raw in ["-", "1e", "", "abc", "--3"] {
            let parsed = Double(GenerationParameterDefaultsSheet.normalizedNumberInput(raw, locale: en))
            #expect(parsed == nil)
        }
        #expect(Double(GenerationParameterDefaultsSheet.normalizedNumberInput("0.", locale: en)) == 0)
    }
}
