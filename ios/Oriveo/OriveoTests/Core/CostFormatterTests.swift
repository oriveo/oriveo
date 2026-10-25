import Foundation
import Testing
@testable import Oriveo

// Mirrors the branches in CostFormatter:
//   value <= costEpsilon (0.00001), non-finite or negative -> ""
//   value <  0.0001 -> five decimals
//   value <  0.01   -> four decimals
//   value >= 0.01   -> two decimals

@Suite("CostFormatter")
struct CostFormatterTests {


    @Test("Zero Returns Empty")
    func zeroReturnsEmpty() {
        #expect(CostFormatter.format(0) == "")
    }

    @Test("Negative Returns Empty")
    func negativeReturnsEmpty() {
        #expect(CostFormatter.format(-0.5) == "")
        #expect(CostFormatter.format(-100) == "")
    }

    @Test("Nan Returns Empty")
    func nanReturnsEmpty() {
        #expect(CostFormatter.format(.nan) == "")
    }

    @Test("Infinity Returns Empty")
    func infinityReturnsEmpty() {
        #expect(CostFormatter.format(.infinity) == "")
        #expect(CostFormatter.format(-.infinity) == "")
    }

    @Test("Epsilon Boundary Returns Empty")
    func epsilonBoundaryReturnsEmpty() {
        #expect(CostFormatter.format(CostFormatter.costEpsilon) == "")
    }

    @Test("Below Epsilon Returns Empty")
    func belowEpsilonReturnsEmpty() {
        #expect(CostFormatter.format(0.000005) == "")
        #expect(CostFormatter.format(0.00001) == "")
    }


    @Test("Slightly Above Epsilon Returns Actual Amount")
    func slightlyAboveEpsilonReturnsActualAmount() {
        #expect(CostFormatter.format(0.00002) == "$0.00002")
    }

    @Test("Just Below Four Decimal Bound Keeps Precision")
    func justBelowFourDecimalBoundKeepsPrecision() {
        #expect(CostFormatter.format(0.00009) == "$0.00009")
    }


    @Test("Four Decimal Lower Boundary")
    func fourDecimalLowerBoundary() {
        #expect(CostFormatter.format(0.0001) == "$0.0001")
    }

    @Test("Typical Four Decimal Value")
    func typicalFourDecimalValue() {
        #expect(CostFormatter.format(0.0023) == "$0.0023")
    }

    @Test("Just Below Two Decimal Boundary")
    func justBelowTwoDecimalBoundary() {
        #expect(CostFormatter.format(0.0099) == "$0.0099")
    }


    @Test("Two Decimal Lower Boundary")
    func twoDecimalLowerBoundary() {
        #expect(CostFormatter.format(0.01) == "$0.01")
    }

    @Test("Typical Small Value")
    func typicalSmallValue() {
        #expect(CostFormatter.format(0.05) == "$0.05")
    }

    @Test("Rounding To Two Decimal")
    func roundingToTwoDecimal() {
        #expect(CostFormatter.format(1.234) == "$1.23")
    }

    @Test("Padding To Two Decimal")
    func paddingToTwoDecimal() {
        #expect(CostFormatter.format(12.5) == "$12.50")
    }

    @Test("Large Value")
    func largeValue() {
        #expect(CostFormatter.format(99.99) == "$99.99")
    }


    @Test("All Valid Values Have Dollar Prefix")
    func allValidValuesHaveDollarPrefix() {
        let values: [Double] = [0.00002, 0.0023, 0.01, 0.50, 5.0]
        for value in values {
            let result = CostFormatter.format(value)
            #expect(result.contains("$"))
        }
    }

    @Test("Tiny Per Million Price Returns Actual Amount")
    func tinyPerMillionPriceReturnsActualAmount() {
        #expect(CostFormatter.formatPerMillion(0.000000001) == "$0.001/M")
    }


    @Test("Per-million prices in a non-USD currency use the same precision as the USD label")
    func nonUsdPerMillionMatchesUsdPrecision() {
        let enUS = Locale(identifier: "en_US")
        let cases: [(perToken: Double, usd: String, cny: String)] = [
            (0.000_004, "$4/M", "CN\u{00A5}4/M"),
            (0.000_016, "$16/M", "CN\u{00A5}16/M"),
            (0.000_002_5, "$2.5/M", "CN\u{00A5}2.5/M"),
            (0.000_000_6, "$0.6/M", "CN\u{00A5}0.6/M"),
            (0.000_012_345, "$12.3/M", "CN\u{00A5}12.3/M"),
            (0.000_000_001_23, "$0.00123/M", "CN\u{00A5}0.00123/M"),
            (0.001_234_5, "$1230/M", "CN\u{00A5}1,230/M"),
        ]
        for item in cases {
            #expect(CostFormatter.formatPerMillion(item.perToken) == item.usd)
            #expect(CostFormatter.formatPerMillion(item.perToken, currencyCode: "CNY", locale: enUS) == item.cny)
        }
        #expect(CostFormatter.formatPerMillion(0.000_004, currencyCode: "CNY", locale: Locale(identifier: "zh_CN")) == "\u{00A5}4/M")
        #expect(CostFormatter.formatPerMillion(0.000_002_5, currencyCode: "EUR", locale: Locale(identifier: "de_DE")) == "2,5\u{00A0}\u{20AC}/M")
        #expect(CostFormatter.formatPerMillion(0.000_002_5, currencyCode: "USD", locale: Locale(identifier: "de_DE")) == "$2.5/M")
    }
}
