import Foundation
import Testing
@testable import Oriveo

/// USD display sites (third-party balance) route through `CostFormatter.usd`.
@MainActor
@Suite("UsdDisplaySites")
struct UsdDisplaySitesTests {
    private let de = Locale(identifier: "de")
    private let zhHans = Locale(identifier: "zh-Hans")

    /// Drops bidi marks and maps narrow / no-break spaces to a plain space before comparing.
    private func normalized(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\u{200E}", "\u{200F}", "\u{061C}":
                continue
            case "\u{00A0}", "\u{202F}":
                out.append(" ")
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    @Test("provider_balance_usd_de")
    func providerBalanceUsdDe() {
        #expect(normalized(ProviderBalanceCard.formatAmount(1234.5, currency: "USD", locale: de)) == "1.234,50 $")
        let balance = ProviderBalance(currency: "USD", total: -3.2)
        #expect(normalized(ProviderListCardPresentation.providerBalanceText(balance, locale: de)) == "-3,20 $")
        let zh = ProviderBalance(currency: "USD", total: 3.2)
        #expect(normalized(ProviderListCardPresentation.providerBalanceText(zh, locale: zhHans)) == "$3.20")
    }

    @Test("provider_balance_cny_platform")
    func providerBalanceCnyPlatform() {
        #expect(normalized(ProviderBalanceCard.formatAmount(1234.5, currency: "CNY", locale: zhHans)) == "\u{00A5}1,234.50")
        #expect(normalized(ProviderBalanceCard.formatAmount(1234.5, currency: "CNY", locale: de)) == "1.234,50 CN\u{00A5}")
        let balance = ProviderBalance(currency: "CNY", total: 1234.5)
        #expect(normalized(ProviderListCardPresentation.providerBalanceText(balance, locale: zhHans)) == "\u{00A5}1,234.50")
    }

    @Test("hero_zero_fallback_de")
    func heroZeroFallbackDe() {
        #expect(normalized(ProviderHeroCard.costTextOrZero("", locale: de)) == "0 $")
        #expect(ProviderHeroCard.costTextOrZero("", locale: Locale(identifier: "en_US")) == "$0")
        #expect(ProviderHeroCard.costTextOrZero("1,20 $", locale: de) == "1,20 $")
    }

    @Test("cost_summary_zero_fallback_de")
    func costSummaryZeroFallbackDe() {
        #expect(normalized(ProvidersCostSummaryCard.costTextOrZero("", locale: de)) == "0 $")
        #expect(ProvidersCostSummaryCard.costTextOrZero("", locale: Locale(identifier: "en_US")) == "$0")
    }

    @Test("per_million_zero_de")
    func perMillionZeroDe() {
        let deText = ModelPickerPricePresentation.formatPerMillion(0, currencyCode: "USD", locale: de)
        #expect(deText.map(normalized) == "0 $/M")
        let enText = ModelPickerPricePresentation.formatPerMillion(0, currencyCode: "USD", locale: Locale(identifier: "en_US"))
        #expect(enText == "$0/M")
    }
}
