import Foundation
import Testing
@testable import Oriveo

/// Source assertion: the Total row in the token usage sheet uses the same neutral inset surface
/// as the Input / Output / Cost cells instead of the brand-tinted `primarySoft` fill.
@Suite("Token usage total row")
struct TokenUsageTotalRowTests {
    private static func totalRowSource() throws -> String {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var file: URL?
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("Oriveo/Features/Chat/Cells/AssistantMetadataView.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { file = candidate; break }
            cursor.deleteLastPathComponent()
        }
        let source = try String(contentsOf: try #require(file), encoding: .utf8)
        let start = try #require(source.range(of: "private var total: some View {"))
        let end = try #require(source.range(of: "private var cost: some View {", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    @Test("Total row no longer uses the primarySoft background")
    func totalRowDropsPrimarySoft() throws {
        let body = try Self.totalRowSource()
        #expect(!body.contains("primarySoft"))
        #expect(body.contains(".modelControlSurface(cornerRadius: OriveoTheme.Radius.inset)"))
    }

    @Test("Total value keeps textPrimary")
    func totalValueKeepsTextPrimary() throws {
        #expect(try Self.totalRowSource().contains("OriveoTheme.Palette.textPrimary"))
    }
}
