import Testing
@testable import Oriveo

@Suite("Expensive Model Hint")
struct ExpensiveModelHintTests {

    @Test("Returns Multiplier When Ratio Exceeds Threshold")
    func returnsMultiplierWhenRatioExceedsThreshold() {
        #expect(evaluateExpensiveModelMultiplier(oldPromptPrice: 0.001, newPromptPrice: 0.007) == 7)
    }

    @Test("Returns Multiplier At Boundary")
    func returnsMultiplierAtBoundary() {
        #expect(evaluateExpensiveModelMultiplier(oldPromptPrice: 0.001, newPromptPrice: 0.0051) == 5)
    }

    @Test("Returns Nil When Ratio Equals Threshold")
    func returnsNilWhenRatioEqualsThreshold() {
        #expect(evaluateExpensiveModelMultiplier(oldPromptPrice: 0.001, newPromptPrice: 0.005) == nil)
    }

    @Test("Returns Nil When Ratio Below Threshold")
    func returnsNilWhenRatioBelowThreshold() {
        #expect(evaluateExpensiveModelMultiplier(oldPromptPrice: 0.001, newPromptPrice: 0.003) == nil)
    }

    @Test("Returns Nil When Old Price Is Nil")
    func returnsNilWhenOldPriceIsNil() {
        #expect(evaluateExpensiveModelMultiplier(oldPromptPrice: nil, newPromptPrice: 0.007) == nil)
    }

    @Test("Returns Nil When New Price Is Nil")
    func returnsNilWhenNewPriceIsNil() {
        #expect(evaluateExpensiveModelMultiplier(oldPromptPrice: 0.001, newPromptPrice: nil) == nil)
    }

    @Test("Returns Nil When Old Price Is Zero")
    func returnsNilWhenOldPriceIsZero() {
        #expect(evaluateExpensiveModelMultiplier(oldPromptPrice: 0, newPromptPrice: 0.007) == nil)
    }

    @Test("Returns Nil For Reverse Switch Cheaper Model")
    func returnsNilForReverseSwitchCheaperModel() {
        #expect(evaluateExpensiveModelMultiplier(oldPromptPrice: 0.007, newPromptPrice: 0.001) == nil)
    }
}
