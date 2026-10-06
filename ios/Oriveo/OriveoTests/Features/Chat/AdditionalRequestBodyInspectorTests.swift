import Foundation
import Testing
import UIKit
@testable import Oriveo

/// The "when sent" list, error line location and "Format" of the additional request body editor.
/// Whether the body can be sent is decided by `AdditionalRequestBody.parse` alone; what is checked here is that the reason is pinned to a field and a line.
@Suite("Additional request body: per-field list and line numbers")
@MainActor
struct AdditionalRequestBodyInspectorTests {
    private typealias Inspector = AdditionalRequestBodyInspector

    /// The sample used throughout: two fields that will be added, and a protected field on line 6.
    private static let board = """
    {
      "chat_template_kwargs": {
        "enable_thinking": false
      },
      "cache_prompt": true,
      "messages": []
    }
    """

    @Test("sample: nested fields expand into dot paths, and the protected field is marked with its reason and line")
    func boardSample() throws {
        let report = Inspector.inspect(Self.board)
        #expect(report.fields.map(\.path) == ["chat_template_kwargs.enable_thinking", "cache_prompt", "messages"])
        #expect(report.fields.map(\.status) == [.added, .added, .protected])
        #expect(report.fields.map(\.line) == [3, 5, 6])
        #expect(report.addedCount == 2)
        #expect(report.errorLines == [6])

        // The verdict is the same as the send boundary's validation: the same field, the same line.
        let rejection = try #require(report.rejection)
        #expect(rejection == AdditionalRequestBodyRejection(reason: .protectedField, field: "messages", line: 6))
        if case .failure(let authority) = AdditionalRequestBody.parse(Self.board) {
            #expect(authority == rejection)
        } else {
            Issue.record("the send boundary should reject this content")
        }

        let explanation = Inspector.explanation(for: report.fields[2])
        #expect(explanation == String(
            format: L10n.tr("%1$@ Remove line %2$lld to send.", table: .chat),
            L10n.tr("The conversation is filled in by Oriveo.", table: .chat), 6
        ))
    }

    @Test("valid content: one line per top-level field, keys in the order of the text")
    func validContentListsEveryField() {
        let raw = "{\"z\": 1, \"a\": {\"b\": {\"c\": [1, 2]}, \"d\": null}, \"empty\": {}}"
        let report = Inspector.inspect(raw)
        #expect(report.rejection == nil)
        #expect(report.errorLines.isEmpty)
        #expect(report.fields.map(\.path) == ["z", "a.b.c", "a.d", "empty"])
        #expect(report.fields.allSatisfy { $0.status == .added })
        #expect(report.addedCount == 4)
    }

    @Test("an object nested too deep counts as one field at the fourth level")
    func deepObjectsStopExpanding() {
        let report = Inspector.inspect("{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":{\"f\":1}}}}}}")
        #expect(report.fields.map(\.path) == ["a.b.c.d"])
    }

    @Test("each of the 13 protected fields is marked, with a reason; a key of the same name nested elsewhere is not restricted")
    func everyProtectedFieldIsExplained() {
        let protected = AdditionalRequestBody.protectedRootFields
        #expect(protected.count == 13)
        var reasons = Set<String>()
        for name in protected.sorted() {
            let report = Inspector.inspect("{\n  \"temperature\": 0.5,\n  \"\(name)\": 1\n}")
            let field = report.fields.first { $0.path == name }
            #expect(field?.status == .protected, "\(name) was not marked as unchangeable")
            #expect(field?.line == 3)
            #expect(report.errorLines == [3])
            #expect(report.rejection?.reason == .protectedField)
            #expect(report.addedCount == 1)
            if let field {
                let explanation = Inspector.explanation(for: field)
                #expect(!explanation.isEmpty)
                #expect(explanation.contains("3"))
                reasons.insert(explanation)
            }
        }
        // The wording falls into a few classes by what the field is for; it is not one generic sentence on 13 lines.
        #expect(reasons.count >= 5)

        let nested = Inspector.inspect("{\"extra\": {\"messages\": []}}")
        #expect(nested.rejection == nil)
        #expect(nested.fields.map(\.status) == [.added])
    }

    @Test("with two protected fields both lines are marked, and the verdict still agrees with the send boundary")
    func multipleProtectedFieldsAreAllMarked() {
        let raw = "{\n  \"tools\": [],\n  \"x\": 1,\n  \"model\": \"m\"\n}"
        let report = Inspector.inspect(raw)
        #expect(report.fields.filter { $0.status == .protected }.map(\.path) == ["tools", "model"])
        #expect(report.errorLines == [2, 4])
        #expect(report.rejection?.field == "model")
    }

    @Test("a name that cannot be used as a field name is marked")
    func blockedNamesAreMarked() {
        let report = Inspector.inspect("{\n  \"a\": {\n    \"__proto__\": 1\n  }\n}")
        #expect(report.rejection?.reason == .blockedSegment)
        #expect(report.fields.map(\.status) == [.blockedName])
        #expect(report.fields.first?.line == 3)
        #expect(report.errorLines.contains(3))
    }

    @Test("malformed JSON: the faulty line is located and the list is empty")
    func syntaxErrorsAreLocated() {
        let cases: [(String, Int)] = [
            // A missing value: the place to fix is the line with the colon, not the line of the later `}`.
            ("{\n  \"a\": 1,\n  \"b\": \n}", 3),
            ("{\n  \"a\": 1,\n  \"b\":\n\n\n}", 3),
            // A missing comma: the surplus key really is on line 3.
            ("{\n  \"a\": 1\n  \"b\": 2\n}", 3),
            ("{\n  \"a\": tru\n}", 2),
            ("{\n  \"a\": \"unterminated\n}", 2),
            // A missing closing bracket: the last place with content is line 2.
            ("{\n  \"a\": 1\n", 2),
            ("{\n  \"a\":", 2),
            // The extra content after the root object is on line 2.
            ("{}\n}", 2),
        ]
        for (raw, line) in cases {
            let report = Inspector.inspect(raw)
            #expect(report.rejection?.reason == .invalidJSON, "\(raw)")
            #expect(report.errorLines == [line], "\(raw) should be located on line \(line), got \(report.errorLines)")
            #expect(report.fields.isEmpty)
        }
        // Valid JSON, but not an object.
        let array = Inspector.inspect("[1, 2]")
        #expect(array.rejection?.reason == .notObject)
        #expect(array.errorLines == [1])
    }

    @Test("blank content has no list and is not an error")
    func blankContent() {
        for raw in ["", "  \n\t"] {
            let report = Inspector.inspect(raw)
            #expect(report.isBlank)
            #expect(report.fields.isEmpty)
            #expect(report.rejection == nil)
            #expect(report.errorLines.isEmpty)
        }
    }

    @Test("the on-device verdict agrees with the send boundary case by case: what this calls sendable, the boundary accepts")
    func verdictMatchesTheSendBoundary() {
        let samples = [
            Self.board, "{}", "{\"a\":1}", "[]", "nope", "{\"stream\":true}", "{\"a\":{\"constructor\":1}}",
            "{\"a\":[{\"prototype\":1}]}", "{\"a\": 1,}", "\"text\"", "{\"a\":{\"model\":\"x\"}}",
        ]
        // A trailing comma before the close: the system parser at the send boundary accepts it, so the list has to be shown as usual.
        let lenient = ["{\n  \"a\": 1,\n}", "{\"a\": [1, 2,], \"b\": {\"c\": true,},}"]
        for raw in samples + lenient {
            let report = Inspector.inspect(raw)
            switch AdditionalRequestBody.parse(raw) {
            case .success(let object):
                #expect(report.rejection == nil, "\(raw)")
                // For content that can be sent, the top-level fields in the list must correspond one to one with what is really merged into the request.
                #expect(
                    Set(report.fields.map { String($0.path.split(separator: ".")[0]) }) == Set(object.keys),
                    "\(raw) can be sent, yet the list does not match the fields really merged"
                )
                #expect(report.errorLines.isEmpty)
            case .failure(let rejection):
                #expect(report.rejection == rejection, "\(raw)")
            }
        }
        // Should the system parser ever stop accepting these two, the code above takes the failure branch and still agrees;
        // "Format" removes the surplus comma.
        if case .success = AdditionalRequestBody.parse(lenient[1]) {
            #expect(Inspector.formatted(lenient[1])?.contains(",\n}") == false)
            #expect(Inspector.inspect(lenient[1]).fields.map(\.path) == ["a", "b.c"])
        }
    }

    @Test("Format: valid JSON is laid out again with key order unchanged; invalid JSON is left alone")
    func formatting() throws {
        let formatted = try #require(Inspector.formatted("{\"z\":1,\"a\":{\"b\":[1,{\"c\":null}],\"e\":{}},\"s\":\"x\\ny\",\"l\":[]}"))
        #expect(formatted == """
        {
          "z": 1,
          "a": {
            "b": [
              1,
              {
                "c": null
              }
            ],
            "e": {}
          },
          "s": "x\\ny",
          "l": []
        }
        """)
        // Formatting does not change content, and formatting again changes nothing further.
        #expect(Inspector.formatted(formatted) == formatted)
        let before = try JSONSerialization.jsonObject(with: Data("{\"z\":1,\"a\":{\"b\":[1,{\"c\":null}],\"e\":{}},\"s\":\"x\\ny\",\"l\":[]}".utf8))
        let after = try JSONSerialization.jsonObject(with: Data(formatted.utf8))
        #expect((before as? NSDictionary) == (after as? NSDictionary))

        #expect(Inspector.formatted("{\"a\": }") == nil)
        #expect(Inspector.formatted("") == nil)
        // The sample is already in formatted shape.
        #expect(Inspector.formatted(Self.board) == Self.board)
    }

    @Test("coloring tokens: keys and literals each get their class, and a protected key can be found by line and key name")
    func tokens() {
        let tokens = Inspector.tokens(Self.board)
        let keys = tokens.filter { $0.kind == .key }
        #expect(keys.map(\.text) == ["chat_template_kwargs", "enable_thinking", "cache_prompt", "messages"])
        #expect(keys.map(\.line) == [2, 3, 5, 6])
        #expect(keys.map(\.depth) == [1, 2, 1, 1])
        let literals = tokens.filter { $0.kind == .literal }.map { (Self.board as NSString).substring(with: $0.range) }
        #expect(literals == ["false", "true"])
        let messages = keys[3]
        #expect((Self.board as NSString).substring(with: messages.range) == "\"messages\"")
        // Half-written content is tokenized too, without crashing.
        #expect(!Inspector.tokens("{\"a\": \"unterminated").isEmpty)
        #expect(Inspector.tokens("").isEmpty)

        #expect(Inspector.lineCount(Self.board) == 7)
        let lineSix = Inspector.range(ofLine: 6, in: Self.board)
        #expect(lineSix.map { (Self.board as NSString).substring(with: $0) } == "  \"messages\": []")
        #expect(Inspector.range(ofLine: 99, in: Self.board) == nil)
    }

    @Test("engine documentation addresses match the shared contract entry by entry; engines not in the contract and cloud connections get no link")
    func engineDocumentationMatchesTheContract() throws {
        let contract = try GenerationOutboundPerItemContractTests.loadContract()
        let rules = try #require(contract["localEngineRules"] as? [String: Any])
        let sources = try #require(rules["sources"] as? [String: String])
        #expect(Inspector.engineDocumentationSources.mapValues(\.url) == sources)
        for (engine, url) in sources {
            #expect(Inspector.engineDocumentation(engineProfile: engine)?.url.absoluteString == url)
        }
        #expect(Inspector.engineDocumentation(engineProfile: "openwebui") == nil)
        #expect(Inspector.engineDocumentation(engineProfile: nil) == nil)
        #expect(Inspector.engineName(engineProfile: "llamacpp") == "llama.cpp")
        #expect(Inspector.engineName(engineProfile: "openwebui") == "Open WebUI")
    }

    @Test("the entry row's summary: not used / N fields; a body that is off or malformed does not count as in use")
    func entrySummaryCountsOnlyWhatIsSent() {
        let suite = "additional-request-body-entry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GenerationParameterSettingsStore(defaults: defaults)
        let provider = AdvancedSettingsSamples.localProvider
        let model = AdvancedSettingsSamples.localModel
        let conversation = UUID()
        let modelID = CapabilityPreferenceRuntimeIdentity.canonicalModelID(provider: provider, model: model)

        var summary = AdditionalRequestBodyEntry.summary(
            provider: provider, model: model, conversationID: conversation, store: store
        )
        #expect(summary.text == L10n.tr("Not in use", table: .providers))
        #expect(!summary.emphasized)

        store.setAdditionalRequestBody(
            .init(rawJSON: "{\"chat_template_kwargs\":{\"enable_thinking\":false},\"cache_prompt\":true}", sendsWithRequest: true),
            providerID: provider.id, modelID: modelID, conversationID: conversation
        )
        summary = AdditionalRequestBodyEntry.summary(
            provider: provider, model: model, conversationID: conversation, store: store
        )
        #expect(summary.text == String(format: L10n.tr("%lld fields", table: .chat), 2))
        #expect(summary.emphasized)

        store.setAdditionalRequestBody(
            .init(rawJSON: "{\"cache_prompt\":true}", sendsWithRequest: false),
            providerID: provider.id, modelID: modelID, conversationID: conversation
        )
        summary = AdditionalRequestBodyEntry.summary(
            provider: provider, model: model, conversationID: conversation, store: store
        )
        #expect(summary.text == L10n.tr("Not in use", table: .providers))
    }

    @Test("gutter: 7 lines of text yield 1…7, soft-wrapped fragments are not counted again, and an error line is marked together with its number")
    func gutterNumbersLogicalLines() throws {
        let view = LineNumberTextView.make()
        view.isScrollEnabled = false
        view.font = AdditionalRequestBodyEditor.font
        view.textContainerInset = UIEdgeInsets(
            top: 14, left: AdditionalRequestBodyEditor.gutterWidth, bottom: 14, right: 14
        )
        view.textContainer.lineFragmentPadding = 0
        view.frame = CGRect(x: 0, y: 0, width: 220, height: 400)
        // Line 2 is long enough to wrap into several fragments within 220pt.
        let long = "  \"chat_template_kwargs\": { \"enable_thinking\": false, \"another_key\": \"" + String(repeating: "x", count: 80) + "\" },"
        view.text = ["{", long, "  \"a\": 1,", "  \"b\": 2,", "  \"c\": 3,", "  \"messages\": []", "}"].joined(separator: "\n")
        view.errorLines = [6]
        view.layoutIfNeeded()

        #expect(view.hasGutter, "the gutter is not attached to the text view")
        let entries = view.gutterEntries()
        #expect(entries.map(\.number) == Array(1...7))
        #expect(entries.filter(\.isError).map(\.number) == [6])
        // Positions go down line by line and all lie within the view (non-zero width, no overlap).
        for (upper, lower) in zip(entries, entries.dropFirst()) {
            #expect(lower.minY >= upper.minY + upper.height - 0.5)
        }
        #expect(entries.allSatisfy { $0.height > 0 })
        // The wrapped line takes more than one line of height but has a single number.
        #expect(entries[1].height > entries[0].height * 1.9)
        #expect(AdditionalRequestBodyEditor.gutterWidth - 12 > 0)

        // Ending in a newline: the final empty line has a number too. Empty text has line 1.
        view.text = "{\n}\n"
        view.layoutIfNeeded()
        #expect(view.gutterEntries().map(\.number) == [1, 2, 3])
        view.text = ""
        view.layoutIfNeeded()
        #expect(view.gutterEntries().map(\.number) == [1])

        // The line number color is distinguishable from the editor background.
        var gutterWhite: CGFloat = 0
        var backgroundWhite: CGFloat = 0
        AdditionalRequestBodyEditor.Palette.gutter.getWhite(&gutterWhite, alpha: nil)
        AdditionalRequestBodyEditor.Palette.background.getWhite(&backgroundWhite, alpha: nil)
        #expect(gutterWhite - backgroundWhite > 0.2)
    }
}
