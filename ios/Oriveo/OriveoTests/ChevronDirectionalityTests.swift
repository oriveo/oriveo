import Foundation
import Testing
import UIKit
@testable import Oriveo

/// RTL gate for directional arrows.
///
/// The SF Symbols `chevron.right` / `chevron.left` are not mirrored under RTL; `chevron.forward` /
/// `chevron.backward` are. Arrows meaning "forward / go to the next level / back / expand" must always use the latter; those that truly mean physical left or right
/// are registered with a reason in the table below. This is a source gate against regressions; the actual look under RTL is still judged on the sample screens.
@Suite("Directional arrows flip with layout direction")
@MainActor
struct ChevronDirectionalityTests {
    private struct Retained {
        /// Path relative to the `Oriveo/` source root.
        let path: String
        let count: Int
        let reason: String
    }

    /// Files allowed to keep the `"chevron.right"` / `"chevron.left"` literals. The table may only shrink:
    /// an occurrence outside the registry fails, and a registered entry that no longer matches or whose count is off also fails.
    private static let retained: [Retained] = []

    private static let fixedDirectionLiterals = ["\"chevron.right\"", "\"chevron.left\""]

    @Test("RL2-LAYOUT-CHEVRON-02 chevron.right / chevron.left appear only in the registry, with counts matching one by one")
    func fixedDirectionChevronsStayInRegistry() throws {
        let hits = try Self.scanFixedDirectionChevrons()
        let registry = Dictionary(Self.retained.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(registry.count == Self.retained.count, "The registry has a duplicate path")

        for (path, lines) in hits.sorted(by: { $0.key < $1.key }) {
            guard let entry = registry[path] else {
                Issue.record(
                    "\(path) line(s) \(lines.map(String.init).joined(separator: ", ")) use an arrow that does not flip under RTL; replace those meaning forward / back / expand with chevron.forward / chevron.backward, and register genuinely physical left/right ones in the table with a reason"
                )
                continue
            }
            #expect(
                lines.count == entry.count,
                "\(path) registers \(entry.count) occurrence(s) but has \(lines.count) (line(s) \(lines.map(String.init).joined(separator: ", ")))"
            )
        }
        for entry in Self.retained where hits[entry.path] == nil {
            Issue.record("\(entry.path) no longer matches; remove it from the registry (registered reason:\(entry.reason)）")
        }
        for entry in Self.retained {
            #expect(!entry.reason.isEmpty, "\(entry.path) has no reason for keeping it")
        }
    }

    @Test("RL2-LAYOUT-CHEVRON-01 a collapse indicator does not use a 'down arrow flipped 180 degrees': collapsed points along the reading direction, expanded points down (down / up is the semantics of menus and popovers)")
    func disclosureArrowsDoNotFlipDownToUp() throws {
        // This kind of issue has been reported several times: the arrow pointed down when collapsed and up when expanded, opposite to the system collapse semantics.
        let rootPath = Self.sourceRoot.standardizedFileURL.path
        var offenders: [String] = []
        for url in try Self.swiftSources() {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains("rotationEffect(.degrees(") && (line.contains("? 180") || line.contains("? -180")) {
                let window = lines[max(0, index - 8)...index].joined(separator: "\n")
                if ["caretDown", "\"chevron.down\"", "\"chevron.up\"", "caretUp"].contains(where: window.contains) {
                    let path = url.standardizedFileURL.path.replacingOccurrences(of: rootPath + "/", with: "")
                    offenders.append("\(path):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "Collapse arrows should be caretRight / chevron.forward when collapsed (flipping under RTL) and caretDown when expanded:\(offenders.joined(separator: ", "))")
    }

    @Test("the scan really read the source: the replaced call sites contain arrows that flip")
    func scannerReadsRealSources() throws {
        // If the scan reads no files because the path is miscomputed, the previous test would pass vacuously; two already-replaced call sites back it up here.
        let row = try Self.source("Shared/Components/Rows/SettingsRow.swift")
        #expect(row.contains("\"chevron.forward\""))
        let back = try Self.source("Features/Chat/ModelControls/AdvancedSettingsPage.swift")
        #expect(back.contains("\"chevron.backward\""))
        let sourceCount = try Self.swiftSources().count
        #expect(sourceCount > 100)
    }

    @Test("thinking block expand arrow: clockwise in LTR, counterclockwise in RTL, both ending up pointing down")
    func reasoningChevronRotationFollowsLayoutDirection() {
        #expect(UIKitReasoningBlock.chevronRotationAngle(expanded: false, layoutDirection: .leftToRight) == 0)
        #expect(UIKitReasoningBlock.chevronRotationAngle(expanded: false, layoutDirection: .rightToLeft) == 0)
        #expect(UIKitReasoningBlock.chevronRotationAngle(expanded: true, layoutDirection: .leftToRight) == CGFloat.pi / 2)
        #expect(UIKitReasoningBlock.chevronRotationAngle(expanded: true, layoutDirection: .rightToLeft) == -CGFloat.pi / 2)
    }

    @Test("after a thinking block really expands, the arrow's rotation follows its own layout direction")
    func reasoningBlockAppliesDirectionalRotation() {
        assertExpandedRotation(semantic: .forceLeftToRight, expectedAngle: CGFloat.pi / 2)
        assertExpandedRotation(semantic: .forceRightToLeft, expectedAngle: -CGFloat.pi / 2)
    }

    // MARK: - Helpers

    private func assertExpandedRotation(semantic: UISemanticContentAttribute, expectedAngle: CGFloat) {
        let block = UIKitReasoningBlock()
        block._testChevronIcon.semanticContentAttribute = semantic
        block.configure(text: "\u{5148}\u{62C6}\u{89E3}\u{95EE}\u{9898}\u{FF0C}\u{518D}\u{9010}\u{6761}\u{6838}\u{5BF9}\u{3002}", durationMs: 1200, isStreaming: false, hasMainText: true)
        #expect(Self.rotation(of: block._testChevronIcon) == 0, "No rotation when collapsed")

        block._testTapHeader()
        #expect(block._testIsExpanded)
        #expect(abs(Self.rotation(of: block._testChevronIcon) - expectedAngle) < 0.0001)

        block._testTapHeader()
        #expect(abs(Self.rotation(of: block._testChevronIcon)) < 0.0001, "Collapsing again returns to no rotation")
    }

    private static func rotation(of view: UIView) -> CGFloat {
        atan2(view.transform.b, view.transform.a)
    }

    /// Returns "relative path -> matching line numbers".
    private static func scanFixedDirectionChevrons() throws -> [String: [Int]] {
        var hits: [String: [Int]] = [:]
        let rootPath = sourceRoot.standardizedFileURL.path
        for url in try swiftSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard fixedDirectionLiterals.contains(where: { text.contains($0) }) else { continue }
            var lines: [Int] = []
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                for literal in fixedDirectionLiterals {
                    let occurrences = line.components(separatedBy: literal).count - 1
                    lines.append(contentsOf: Array(repeating: index + 1, count: occurrences))
                }
            }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
            hits[relative] = lines
        }
        return hits
    }

    private static func swiftSources() throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil),
            "Cannot read the source directory \(sourceRoot.path)"
        )
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            urls.append(url)
        }
        return urls
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// `ios/Oriveo/Oriveo`: this file sits at the root of `OriveoTests/`.
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OriveoTests
            .deletingLastPathComponent()   // Oriveo (project directory)
            .appendingPathComponent("Oriveo")
    }
}
