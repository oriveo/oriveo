import Foundation
import OriveoProviderKit
import Testing

// Runs `shared/context-contracts/budget.v1.json` case by case: inputs go through production pure functions, and expected is decoded into production types and compared as a whole;
// failure messages carry the fixture case id.

private struct BudgetContract: Decodable {
    struct MaxOutput: Decodable {
        var user: Int?
        var recipe: Int?
        var model: Int?
    }

    struct WindowInput: Decodable {
        var W: Int?
        var windowKind: String
        var maxOutput: MaxOutput
        var budgetCap: RawJSONValue
        var priceLineTokens: Int?
    }

    struct WindowCase: Decodable {
        var id: String
        var input: WindowInput
        var expected: ContextWindowBudget
    }

    struct CapTickInput: Decodable {
        var U: Int?
        var priceLineTokens: Int?
    }

    struct CapTickExpected: Decodable {
        var ticks: [Int]
    }

    struct CapTickCase: Decodable {
        var id: String
        var input: CapTickInput
        var expected: CapTickExpected
    }

    struct Constants: Decodable {
        var budgetCapOptions: [String]
        var budgetCapDefault: String
        var customCapMin: Int
        var customCapMax: Int
        var autoCapDefault: Int
        var priceLineCapMin: Int
        var capTickLadder: [Int]
    }

    struct RhoEvent: Decodable {
        var type: String
        var observedInput: Int?
        var mediaTokens: Int?
        var textBytes: Int?
    }

    struct RhoState: Decodable {
        var n: Int
        var rho: Double
        var rhoHi: Double
    }

    struct RhoCase: Decodable {
        var id: String
        var events: [RhoEvent]
        var expected: [RhoState]
    }

    struct EstimateInput: Decodable {
        var text: String
        var rhoHi: Double
    }

    struct EstimateExpected: Decodable {
        var utf8Bytes: Int
        var textTokens: Int
        var messageTokens: Int
    }

    struct EstimateCase: Decodable {
        var id: String
        var input: EstimateInput
        var expected: EstimateExpected
    }

    struct ObservedInput: Decodable {
        var observedPrevious: Int?
        var estDynamicPrevious: Int
        var estAnswerPrevious: Int
        var estNewMessages: [Int]
        var estDynamicNow: Int
        var compactedSincePrevious: Bool
        var estimatedFull: Int
    }

    struct ObservedCase: Decodable {
        var id: String
        var input: ObservedInput
        var expected: ContextPHat
    }

    struct DisplayInput: Decodable {
        var windowKnown: Bool
        var pHat: Int
        var B: Int?
        var basis: String
        var observedEver: Bool
        var overflowed: Bool
    }

    struct DisplayCase: Decodable {
        var id: String
        var input: DisplayInput
        var expected: ContextRingDisplay
    }

    var constants: Constants
    var windowCases: [WindowCase]
    var capTickCases: [CapTickCase]
    var rhoCases: [RhoCase]
    var estimateCases: [EstimateCase]
    var observedCases: [ObservedCase]
    var displayCases: [DisplayCase]
}

/// A JSON scalar decoded into the native Swift value the cap parser receives (String / Int / Double / Bool / nil).
private struct RawJSONValue: Decodable {
    var value: Any?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else {
            value = try container.decode(String.self)
        }
    }
}

@Suite("ContextContractBudget")
struct ContextContractBudgetTests {
    private let contract: BudgetContract

    init() throws {
        contract = try ContextContractFixture.load("budget.v1.json")
    }

    @Test("windowCases")
    func windowCases() throws {
        #expect(contract.windowCases.count == 34)
        // Every expected object must carry exactly the fields ContextWindowBudget encodes, so a field
        // added to the fixture cannot be silently ignored by Codable.
        let root = try #require(
            JSONSerialization.jsonObject(with: ContextContractFixture.data("budget.v1.json")) as? [String: Any]
        )
        let rawCases = try #require(root["windowCases"] as? [[String: Any]])
        let fullBudget = ContextBudget.window(
            ContextWindowInput(W: 200_000, windowKind: .total, maxOutput: ContextMaxOutputSources())
        )
        let encodedKeys = try Set(Self.encodedObject(fullBudget).keys)
        let encodedDerivedKeys = try Set(Self.encodedObject(#require(fullBudget.derived)).keys)
        for raw in rawCases {
            let id = raw["id"] as? String ?? "?"
            let expected = try #require(raw["expected"] as? [String: Any], "\(id)")
            #expect(Set(expected.keys) == encodedKeys, "\(id) keys")
            if let derived = expected["derived"] as? [String: Any] {
                #expect(Set(derived.keys) == encodedDerivedKeys, "\(id) derived keys")
            }
        }
        for item in contract.windowCases {
            let kind = try #require(ContextWindowKind(rawValue: item.input.windowKind), "\(item.id)")
            let cap = try #require(ContextBudgetCap.parse(item.input.budgetCap.value), "\(item.id)")
            let input = ContextWindowInput(
                W: item.input.W,
                windowKind: kind,
                maxOutput: ContextMaxOutputSources(
                    user: item.input.maxOutput.user,
                    recipe: item.input.maxOutput.recipe,
                    model: item.input.maxOutput.model
                ),
                budgetCap: cap,
                priceLineTokens: item.input.priceLineTokens
            )
            let actual = ContextBudget.window(input)
            #expect(actual == item.expected, "\(item.id)")
        }
    }

    private static func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// capCases are read through JSONSerialization (NSNumber, as stored preferences arrive) and through
    /// JSONDecoder (native Swift scalars); both must agree with the fixture.
    @Test("capCases")
    func capCases() throws {
        let root = try #require(
            JSONSerialization.jsonObject(with: ContextContractFixture.data("budget.v1.json"), options: [.fragmentsAllowed])
                as? [String: Any]
        )
        let cases = try #require(root["capCases"] as? [[String: Any]])
        #expect(cases.count == 19)
        for item in cases {
            let id = try #require(item["id"] as? String)
            let expected = try #require(item["expected"] as? [String: Any], "\(id)")
            let rawInput: Any? = item["input"] is NSNull ? nil : item["input"]
            let inputData = try JSONSerialization.data(withJSONObject: item["input"] ?? NSNull(), options: [.fragmentsAllowed])
            let nativeInput = try JSONDecoder().decode(RawJSONValue.self, from: inputData).value

            for (path, raw) in [("nsnumber", rawInput), ("native", nativeInput)] {
                let parsed = ContextBudgetCap.parse(raw)
                if expected["rejected"] as? Bool == true {
                    #expect(parsed == nil, "\(id) \(path)")
                    continue
                }
                let want: ContextBudgetCap
                switch expected["cap"] {
                case let text as String where text == "auto": want = .auto
                case let text as String where text == "unlimited": want = .unlimited
                case let number as NSNumber: want = .custom(number.intValue)
                default:
                    Issue.record("\(id): unexpected cap \(String(describing: expected["cap"]))")
                    continue
                }
                #expect(parsed == want, "\(id) \(path)")
                #expect(ContextBudgetCap.parse(want.wire) == want, "\(id) wire round trip")
                switch (want, want.wire) {
                case (.custom(let tokens), let wire as Int): #expect(wire == tokens, "\(id) wire")
                case (.auto, let wire as String): #expect(wire == "auto", "\(id) wire")
                case (.unlimited, let wire as String): #expect(wire == "unlimited", "\(id) wire")
                default: Issue.record("\(id): wire shape \(want.wire)")
                }
            }
        }
    }

    @Test("capTickCases")
    func capTickCases() {
        #expect(contract.capTickCases.count == 13)
        for item in contract.capTickCases {
            let actual = ContextBudget.capTicks(U: item.input.U, priceLineTokens: item.input.priceLineTokens)
            #expect(actual == item.expected.ticks, "\(item.id)")
        }
    }

    @Test("constants_match_fixture")
    func constantsMatchFixture() {
        let constants = contract.constants
        #expect(ContextBudget.budgetCapOptions.map { $0.wire as? String } == constants.budgetCapOptions)
        #expect(ContextBudgetCap.default.wire as? String == constants.budgetCapDefault)
        #expect(ContextBudget.budgetCapDefault == ContextBudgetCap.default)
        #expect(ContextBudget.customCapMin == constants.customCapMin)
        #expect(ContextBudget.customCapMax == constants.customCapMax)
        #expect(ContextBudget.autoCapDefault == constants.autoCapDefault)
        #expect(ContextBudget.priceLineCapMin == constants.priceLineCapMin)
        #expect(ContextBudget.capTickLadder == constants.capTickLadder)
    }

    @Test("rhoCases")
    func rhoCases() throws {
        #expect(contract.rhoCases.count == 6)
        for item in contract.rhoCases {
            #expect(item.events.count == item.expected.count, "\(item.id)")
            var calibration = RhoCalibration()
            for (index, (event, expected)) in zip(item.events, item.expected).enumerated() {
                switch event.type {
                case "sample":
                    calibration = calibration.recordingSample(
                        observedInput: event.observedInput,
                        mediaTokens: event.mediaTokens ?? 0,
                        textBytes: event.textBytes ?? 0
                    )
                case "overflowMiss":
                    calibration = calibration.recordingOverflowMiss()
                default:
                    Issue.record("\(item.id)#\(index): unknown event \(event.type)")
                }
                let label = "\(item.id)#\(index)"
                #expect(calibration.n == expected.n, "\(label)")
                #expect(ContextContractFixture.close(calibration.rho, expected.rho), "\(label) rho \(calibration.rho)")
                #expect(ContextContractFixture.close(calibration.rhoHi, expected.rhoHi), "\(label) rhoHi \(calibration.rhoHi)")
            }
        }
    }

    @Test("estimateCases")
    func estimateCases() {
        #expect(contract.estimateCases.count == 6)
        for item in contract.estimateCases {
            #expect(ContextBudget.utf8Bytes(item.input.text) == item.expected.utf8Bytes, "\(item.id)")
            #expect(ContextBudget.estimateText(item.input.text, rhoHi: item.input.rhoHi) == item.expected.textTokens, "\(item.id)")
            #expect(ContextBudget.estimateMessage(item.input.text, rhoHi: item.input.rhoHi) == item.expected.messageTokens, "\(item.id)")
        }
    }

    @Test("observedCases")
    func observedCases() {
        #expect(contract.observedCases.count == 3)
        for item in contract.observedCases {
            let actual = ContextBudget.pHat(
                observedPrevious: item.input.observedPrevious,
                estDynamicPrevious: item.input.estDynamicPrevious,
                estAnswerPrevious: item.input.estAnswerPrevious,
                estNewMessages: item.input.estNewMessages,
                estDynamicNow: item.input.estDynamicNow,
                compactedSincePrevious: item.input.compactedSincePrevious,
                estimatedFull: item.input.estimatedFull
            )
            #expect(actual == item.expected, "\(item.id)")
        }
    }

    @Test("displayCases")
    func displayCases() throws {
        #expect(contract.displayCases.count == 6)
        for item in contract.displayCases {
            let basis = try #require(ContextEstimateBasis(rawValue: item.input.basis), "\(item.id)")
            let actual = ContextBudget.display(
                windowKnown: item.input.windowKnown,
                pHat: item.input.pHat,
                B: item.input.B,
                basis: basis,
                observedEver: item.input.observedEver,
                overflowed: item.input.overflowed
            )
            #expect(actual == item.expected, "\(item.id)")
        }
    }
}
