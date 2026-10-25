import Foundation
import Testing
@testable import Oriveo

// Three-platform shared fixtures of the attachment extraction output spec (v2) in `shared/test-fixtures/attachments/extraction/`:
// golden cases go through the production entry `FileTextExtractor.extract` and compare `expect.content` / `expect.error` byte for byte;
// the type list, encoding score tables and legacy-format copy are compared with the fixtures entry by entry. This file holds plain-text decoding (`text_`), HTML / EPUB / RTF, OOXML / ODF and type classification;
// goldens for other formats are added by their own cards, and the counts locked below are adjusted accordingly.

private struct GoldenFixture: Decodable {
    struct Expect: Decodable {
        let content: String?
        let error: String?
    }

    struct Case: Decodable {
        let id: String
        let file: String
        let fileName: String
        let mime: String
        let uiLanguage: String
        let expect: Expect
    }

    struct Classification: Decodable {
        let fileName: String
        let mime: String
        let kind: String
    }

    let v: Int
    let cases: [Case]
    let errorCases: [Case]
    let classification: [Classification]
}

/// `pdfCases`: engines differ across the three platforms, so only the count and order of page markers, included / excluded fragments, error code and `scanned` are locked (spec section 12).
private struct PdfGoldenFixture: Decodable {
    struct Expect: Decodable {
        let markers: [String]?
        let contains: [String]?
        let notContains: [String]?
        let scanned: Bool?
        let error: String?
        let scannedWithoutOcr: ErrorOnly?
        let ocr: OcrOnly?
    }

    /// The OCR half of a case (spec section 13).
    struct OcrOnly: Decodable {
        let markers: [String]
        let contains: [String]
        let scanned: Bool
    }

    struct ErrorOnly: Decodable {
        let error: String
    }

    struct Case: Decodable {
        let id: String
        let file: String
        let fileName: String
        let mime: String
        let uiLanguage: String
        let expect: Expect
    }

    let pdfCases: [Case]
}

private extension PdfGoldenFixture.Case {
    var asGoldenCase: GoldenFixture.Case {
        GoldenFixture.Case(
            id: id, file: file, fileName: fileName, mime: mime, uiLanguage: uiLanguage,
            expect: GoldenFixture.Expect(content: nil, error: expect.error)
        )
    }
}

private struct SupportedTypesGroup: Decodable {
    let extensions: [String]
    let mimes: [String]
    let filenames: [String]?
    let anyTextMime: Bool?
}

private struct CharsetTablesFixture: Decodable {
    let v: Int
    let candidates: [String]
    let localeTieBreak: [String: String]
    let commonChars: [String: [String]]
    let punct1252: [String]
    let ok1251: [String]
}

/// `extraction-golden-edges.v1.json`: edge-case rules added to the spec during implementation (sections 3.3, 4A, 5, 7, 8 details, 9, 11).
private struct EdgeGoldenFixture: Decodable {
    let v: Int
    let cases: [GoldenFixture.Case]
    let errorCases: [GoldenFixture.Case]
}

private struct CjkRadicalsFixture: Decodable {
    let v: Int
    let map: [String: String]
}

private struct LegacyCopyFixture: Decodable {
    let v: Int
    let copy: [String: String]
}

@Suite("Attachment extraction golden contract (plain-text decoding and type classification, iOS)")
@MainActor
struct ExtractionGoldenContractTests {
    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private static var fixtureDirectory: URL {
        repoRoot.appendingPathComponent("shared/test-fixtures/attachments/extraction")
    }

    private static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: fixtureDirectory.appendingPathComponent(name)))
    }

    private static func golden() throws -> GoldenFixture {
        let fixture = try load("extraction-golden.v1.json", as: GoldenFixture.self)
        #expect(fixture.v == 1)
        return fixture
    }

    private static func run(_ testCase: GoldenFixture.Case) async throws -> String {
        let data = try Data(contentsOf: fixtureDirectory.appendingPathComponent(testCase.file))
        return try await FileTextExtractor.extractInBackground(
            data: data,
            fileName: testCase.fileName,
            mimeType: testCase.mime,
            uiLanguage: ExtractionUILanguage(code: testCase.uiLanguage)
        ).content
    }

    // MARK: - golden

    @Test("plain-text golden: 12 cases byte-identical")
    func plainTextGolden() async throws {
        let cases = try Self.golden().cases.filter { $0.id.hasPrefix("text_") }
        #expect(cases.count == 12, "the count of text_ cases owned here is locked to prevent silently skipped runs")
        for testCase in cases {
            let expected = try #require(testCase.expect.content, "\(testCase.id) missing expect.content")
            let actual = try await Self.run(testCase)
            #expect(Array(actual.utf8) == Array(expected.utf8), "\(testCase.id): \(actual.debugDescription)")
        }
    }

    @Test("HTML / EPUB / RTF golden: 9 cases byte-identical")
    func markupGolden() async throws {
        let prefixes = ["html_", "epub_", "rtf_"]
        let cases = try Self.golden().cases.filter { testCase in prefixes.contains { testCase.id.hasPrefix($0) } }
        #expect(cases.count == 9, "the count of html_ / epub_ / rtf_ cases owned here is locked to prevent silently skipped runs")
        for testCase in cases {
            let expected = try #require(testCase.expect.content, "\(testCase.id) missing expect.content")
            let actual = try await Self.run(testCase)
            #expect(Array(actual.utf8) == Array(expected.utf8), "\(testCase.id): \(actual.debugDescription)")
        }
    }

    @Test("OOXML / ODF golden: 23 cases byte-identical")
    func officeGolden() async throws {
        let prefixes = ["docx_", "xlsx_", "pptx_", "odt_", "ods_", "odp_"]
        let cases = try Self.golden().cases.filter { testCase in prefixes.contains { testCase.id.hasPrefix($0) } }
        #expect(cases.count == 23, "the count of docx_ / xlsx_ / pptx_ / odt_ / ods_ / odp_ cases owned here is locked to prevent silently skipped runs")
        for testCase in cases {
            let expected = try #require(testCase.expect.content, "\(testCase.id) missing expect.content")
            let actual = try await Self.run(testCase)
            #expect(Array(actual.utf8) == Array(expected.utf8), "\(testCase.id): \(actual.debugDescription)")
        }
    }

    @Test("edge golden: 5 success cases byte-identical")
    func edgeGolden() async throws {
        let fixture = try Self.load("extraction-golden-edges.v1.json", as: EdgeGoldenFixture.self)
        #expect(fixture.v == 1)
        #expect(fixture.cases.count == 5, "extraction-golden-edges success case count is locked to prevent silently skipped runs")
        for testCase in fixture.cases {
            let expected = try #require(testCase.expect.content, "\(testCase.id) missing expect.content")
            let actual = try await Self.run(testCase)
            #expect(Array(actual.utf8) == Array(expected.utf8), "\(testCase.id): \(actual.debugDescription)")
        }
    }

    @Test("edge golden: 3 error cases report corrupted_file")
    func edgeGoldenErrors() async throws {
        let fixture = try Self.load("extraction-golden-edges.v1.json", as: EdgeGoldenFixture.self)
        #expect(fixture.errorCases.count == 3, "extraction-golden-edges error case count is locked to prevent silently skipped runs")
        for testCase in fixture.errorCases {
            let expected = try #require(testCase.expect.error)
            do {
                let content = try await Self.run(testCase)
                Issue.record("\(testCase.id) expected \(expected), but extracted \(content.count) characters")
            } catch let error as ExtractionError {
                #expect(error.code.rawValue == expected, "\(testCase.id)")
            }
        }
    }

    @Test("PDF radical code point mapping matches cjk-radicals.v1.json entry by entry (328 entries), and page text is mapped back to unified ideographs via the production path")
    func cjkRadicalsMatchFixture() throws {
        let fixture = try Self.load("cjk-radicals.v1.json", as: CjkRadicalsFixture.self)
        #expect(fixture.v == 1)
        #expect(fixture.map.count == 328, "cjk-radicals count is locked")
        let expected = try Dictionary(uniqueKeysWithValues: fixture.map.map { key, value in
            (try #require(UInt32(key, radix: 16)), try #require(UInt32(value, radix: 16)))
        })
        #expect(PdfTextExtractor.cjkRadicalEquivalents == expected)
        for (radical, unified) in expected.sorted(by: { $0.key < $1.key }) {
            let source = String(Character(try #require(Unicode.Scalar(radical))))
            let target = String(Character(try #require(Unicode.Scalar(unified))))
            #expect(PdfTextExtractor.normalizePageText("a" + source) == "a" + target, "U+\(String(radical, radix: 16, uppercase: true))")
        }
        // After ligature expansion, swap radicals: the Kangxi/CJK radical code points for "two" and "page" become the unified ideographs.
        #expect(PdfTextExtractor.normalizePageText("\u{FB01}le \u{7B2C}\u{2F06}\u{2EDA}  ") == "file \u{7B2C}\u{4E8C}\u{9875}")
    }

    @Test("PDF golden: page markers, included fragments, scanned and error code (5 cases; goes through the import entry with Vision OCR, both halves of a fully scanned case are tested)")
    func pdfGolden() async throws {
        let cases = try Self.load("extraction-golden.v1.json", as: PdfGoldenFixture.self).pdfCases
        #expect(cases.count == 5, "pdfCases count is locked to prevent silently skipped runs")
        var ocrHalves = 0
        defer { #expect(ocrHalves == 1, "the count of cases with an ocr half is locked") }
        for testCase in cases {
            let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent(testCase.file))
            if let withoutOcr = testCase.expect.scannedWithoutOcr {
                // The half without OCR: a fully scanned file reports scanned_pdf.
                do {
                    let pdf = try PdfTextExtractor.extract(data: data, ocr: nil)
                    Issue.record("\(testCase.id) expected \(withoutOcr.error), but extracted \(pdf.text.count) characters")
                } catch let error as ExtractionError {
                    #expect(error.code.rawValue == withoutOcr.error, "\(testCase.id)")
                }
                // The half with OCR: Vision really runs on the simulator, and the body is returned with (OCR) page markers and scanned set.
                let ocrExpect = try #require(testCase.expect.ocr, "\(testCase.id) missing ocr half")
                let extracted = try await FileTextExtractor.extractInBackground(
                    data: data,
                    fileName: testCase.fileName,
                    mimeType: testCase.mime,
                    uiLanguage: ExtractionUILanguage(code: testCase.uiLanguage)
                )
                let markers = extracted.content.components(separatedBy: "\n").filter { $0.hasPrefix("--- Page ") }
                #expect(markers == ocrExpect.markers, "\(testCase.id) ocr: \(extracted.content.debugDescription)")
                for fragment in ocrExpect.contains {
                    #expect(extracted.content.contains(fragment), "\(testCase.id) ocr should contain \(fragment)")
                }
                #expect(extracted.scanned == ocrExpect.scanned, "\(testCase.id) ocr")
                ocrHalves += 1
                continue
            }
            if let expectedError = testCase.expect.error {
                do {
                    let content = try await Self.run(testCase.asGoldenCase)
                    Issue.record("\(testCase.id) expected \(expectedError), but extracted \(content.count) characters")
                } catch let error as ExtractionError {
                    #expect(error.code.rawValue == expectedError, "\(testCase.id)")
                }
                continue
            }
            // After OCR an image page still yields no recognizable text, so `[no text layer]` is still written (pdf_image_page).
            let extracted = try await FileTextExtractor.extractInBackground(
                data: data,
                fileName: testCase.fileName,
                mimeType: testCase.mime,
                uiLanguage: ExtractionUILanguage(code: testCase.uiLanguage)
            )
            let markers = extracted.content.components(separatedBy: "\n").filter { $0.hasPrefix("--- Page ") }
            #expect(markers == testCase.expect.markers, "\(testCase.id): \(extracted.content.debugDescription)")
            for fragment in testCase.expect.contains ?? [] {
                #expect(extracted.content.contains(fragment), "\(testCase.id) should contain \(fragment)")
            }
            for fragment in testCase.expect.notContains ?? [] {
                #expect(!extracted.content.contains(fragment), "\(testCase.id) should not contain \(fragment)")
            }
            #expect(extracted.scanned == testCase.expect.scanned, "\(testCase.id)")
        }
    }

    @Test("PDF deadline already passed: checked page by page, reports extraction_timeout")
    func pdfDeadlineExpired() throws {
        let testCase = try #require(
            try Self.load("extraction-golden.v1.json", as: PdfGoldenFixture.self).pdfCases.first { $0.id == "pdf_two_pages" }
        )
        let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent(testCase.file))
        do {
            let pdf = try PdfTextExtractor.extract(data: data, deadline: ExtractionDeadline(budgetNanoseconds: 0))
            Issue.record("expected extraction_timeout, but extracted \(pdf.text.count) characters")
        } catch let error as ExtractionError {
            #expect(error.code == .extractionTimeout)
        }
    }

    @Test("PDF OCR extension point: when OCR supplies text for a fully scanned file, return it as body with scanned set and (OCR) markers")
    func pdfOcrHookFillsScannedPages() throws {
        let testCase = try #require(
            try Self.load("extraction-golden.v1.json", as: PdfGoldenFixture.self).pdfCases.first { $0.id == "pdf_full_scan" }
        )
        let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent(testCase.file))
        var seenPages: [Int] = []
        let pdf = try PdfTextExtractor.extract(data: data) { _, pages, _ in
            seenPages = pages
            return Dictionary(uniqueKeysWithValues: pages.map { ($0, PdfOcrPageOutcome.text("ﬁrst 123  ")) })
        }
        #expect(seenPages == [0])
        #expect(pdf.scanned)
        #expect(pdf.text == "--- Page 1 (OCR) ---\nfirst 123")
    }

    @Test("OOXML error cases: DOCTYPE or non-zip reports corrupted_file, OLE encryption reports password_protected_office")
    func officeErrorCases() async throws {
        let ids: Set<String> = ["docx_doctype", "docx_not_zip", "docx_ole_encrypted", "xlsx_ole_encrypted"]
        let cases = try Self.golden().errorCases.filter { ids.contains($0.id) }
        #expect(cases.count == 4, "the count of error cases owned here is locked")
        for testCase in cases {
            let expected = try #require(testCase.expect.error)
            do {
                let content = try await Self.run(testCase)
                Issue.record("\(testCase.id) expected \(expected), but extracted \(content.count) characters")
            } catch let error as ExtractionError {
                #expect(error.code.rawValue == expected, "\(testCase.id)")
            }
        }
    }

    @Test("OOXML / ODF deadline already passed: reports extraction_timeout", arguments: ["docx_tables", "xlsx_layout", "pptx_deck", "ods_sheets", "odt_document"])
    func officeDeadlineExpired(id: String) throws {
        let testCase = try #require(try Self.golden().cases.first { $0.id == id })
        let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent(testCase.file))
        let expired = ExtractionDeadline(budgetNanoseconds: 0)
        do {
            let content: String?
            if testCase.id.hasPrefix("od") {
                content = try OdfTextExtractor.extract(data: data, fileExtension: String(testCase.id.prefix(3)), deadline: expired)
            } else {
                content = try OfficeTextExtractor.extractText(from: data, fileExtension: String(testCase.id.prefix(4)), deadline: expired)
            }
            Issue.record("\(id) expected extraction_timeout, but extracted \(content?.count ?? 0) characters")
        } catch let error as ExtractionError {
            #expect(error.code == .extractionTimeout, "\(id)")
        }
    }

    @Test("EPUB DRM error cases: report unsupported_format with underlying set to epub_drm")
    func epubDrmErrorCases() async throws {
        let ids: Set<String> = ["epub_drm_aes", "epub_drm_lcp"]
        let cases = try Self.golden().errorCases.filter { ids.contains($0.id) }
        #expect(cases.count == 2, "the count of error cases owned here is locked")
        for testCase in cases {
            let expected = try #require(testCase.expect.error)
            do {
                let content = try await Self.run(testCase)
                Issue.record("\(testCase.id) expected \(expected), but extracted \(content.count) characters")
            } catch let error as ExtractionError {
                #expect(error.code.rawValue == expected, "\(testCase.id)")
                #expect(error.underlying == "epub_drm", "\(testCase.id)")
            }
        }
    }

    @Test("plain-text error cases: binary reports unsupported_format")
    func plainTextErrorCases() async throws {
        let cases = try Self.golden().errorCases.filter { $0.id == "text_binary_png" }
        #expect(cases.count == 1, "the count of error cases owned here is locked")
        for testCase in cases {
            let expected = try #require(testCase.expect.error)
            do {
                let content = try await Self.run(testCase)
                Issue.record("\(testCase.id) expected \(expected), but extracted \(content.count) characters")
            } catch let error as ExtractionError {
                #expect(error.code.rawValue == expected, "\(testCase.id)")
            }
        }
    }

    @Test("type classification: all 24 fixture classification entries")
    func classification() throws {
        let rows = try Self.golden().classification
        #expect(rows.count == 24, "classification count is locked")
        for row in rows {
            let kind = AttachmentTypeClassifier.classify(fileName: row.fileName, mimeType: row.mime)
            #expect(kind.rawValue == row.kind, "\(row.fileName) + \(row.mime.debugDescription)")
        }
    }

    // MARK: - Lists and tables

    @Test("type list matches supported-types.v1.json entry by entry")
    func supportedTypesMatchFixture() throws {
        let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("supported-types.v1.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        let groupNames = object.keys.filter { $0 != "v" && $0 != "doc" }.sorted()
        let codeKinds = AttachmentTypeClassifier.entries.map(\.kind.rawValue)
        #expect(groupNames == codeKinds.sorted())
        #expect(Set(codeKinds).count == codeKinds.count)

        for entry in AttachmentTypeClassifier.entries {
            let raw = try #require(object[entry.kind.rawValue])
            let group = try JSONDecoder().decode(
                SupportedTypesGroup.self,
                from: JSONSerialization.data(withJSONObject: raw)
            )
            #expect(entry.extensions == group.extensions, "\(entry.kind.rawValue).extensions")
            #expect(entry.mimes == group.mimes, "\(entry.kind.rawValue).mimes")
            if entry.kind == .text {
                #expect(AttachmentTypeClassifier.textFilenames == group.filenames)
                #expect(AttachmentTypeClassifier.anyTextMime == group.anyTextMime)
            }
        }
    }

    @Test("encoding score tables match charset-tables.v1.json entry by entry")
    func charsetTablesMatchFixture() throws {
        let fixture = try Self.load("charset-tables.v1.json", as: CharsetTablesFixture.self)
        #expect(fixture.v == 1)
        #expect(TextCharsetCandidate.allCases.map(\.rawValue) == fixture.candidates)

        let tieBreak = Dictionary(uniqueKeysWithValues: PlainTextExtractor.localeTieBreak.map { ($0.key.rawValue, $0.value.rawValue) })
        #expect(tieBreak == fixture.localeTieBreak)

        #expect(Set(PlainTextExtractor.commonChars.keys.map(\.rawValue)) == Set(fixture.commonChars.keys))
        for (name, codes) in fixture.commonChars {
            let candidate = try #require(TextCharsetCandidate(rawValue: name))
            let embedded = (PlainTextExtractor.commonChars[candidate] ?? []).map { String(format: "%04X", $0) }
            #expect(embedded == codes, "commonChars.\(name)")
        }
        #expect(PlainTextExtractor.punct1252.map { String(format: "%02X", $0) } == fixture.punct1252)
        #expect(PlainTextExtractor.ok1251.map { String(format: "%02X", $0) } == fixture.ok1251)
    }

    @Test("legacy-format hint in 16 languages matches legacy-format-copy.v1.json character by character")
    func legacyFormatCopyMatchesFixture() throws {
        let fixture = try Self.load("legacy-format-copy.v1.json", as: LegacyCopyFixture.self)
        #expect(fixture.v == 1)
        #expect(fixture.copy.count == 16)

        let catalogURL = Self.repoRoot.appendingPathComponent("ios/Oriveo/Oriveo/Chat.xcstrings")
        let catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let entry = try #require(strings[ExtractionErrorCode.legacyFormat.importFailureMessageKey] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        #expect(Set(localizations.keys) == Set(fixture.copy.keys))
        for (language, text) in fixture.copy {
            let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = unit?["value"] as? String
            let expected = text.replacingOccurrences(of: "{fileName}", with: "%@")
            #expect(value.map { Array($0.utf8) } == Array(expected.utf8), "\(language)")
        }
    }
}
