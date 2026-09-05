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

}
