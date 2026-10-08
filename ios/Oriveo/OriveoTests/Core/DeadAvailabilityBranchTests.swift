import Foundation
import Testing
@testable import Oriveo

/// Guards against `#available` checks that can never be false.
///
/// ## Why this matters
/// With a deployment target of iOS 18, `if #available(iOS 17.0, *) { … } else { HStack { A; B; C } }` is always
/// true and the `else` branch is dead code. The compiler still type-checks that dead branch, and it does so as
/// if every API were available. Newer SDKs add a `ViewBuilder.buildBlock<each Content>(…) -> TupleContent`
/// overload that is preferred over the older `-> TupleView` one, so a multi-child builder inside the dead branch
/// picks it and bakes `TupleContent` — a type that only exists on newer systems — into the view's `Body` type.
/// On iOS 18 SwiftUI then aborts the moment it resolves that `Body`:
/// `Failed to look up symbolic reference … likely a reference to a missing weak symbol`.
/// Devices on the newest system have the type, so neither development machines nor tests ever see the crash.
///
/// ## What is locked here
/// App sources must not contain an `#available` / `#unavailable` check whose version is at or below the
/// deployment target. Such a check is always true (or always false), one of its branches is necessarily dead,
/// and that dead branch is the only way in for the crash above.
@Suite("Dead #available branches must not exist in app sources")
struct DeadAvailabilityBranchTests {
    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // OriveoTests
        .deletingLastPathComponent() // Oriveo (project directory)
        .appendingPathComponent("Oriveo", isDirectory: true)

    private static let projectFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Oriveo.xcodeproj/project.pbxproj")

    /// The lowest deployment target declared in the project (minimum across configurations).
    static func deploymentTargetMajor() throws -> Int {
        let project = try String(contentsOf: projectFile, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"IPHONEOS_DEPLOYMENT_TARGET = (\d+)"#)
        let majors = regex.matches(in: project, range: NSRange(project.startIndex..., in: project)).compactMap { match in
            Range(match.range(at: 1), in: project).flatMap { Int(project[$0]) }
        }
        return try #require(majors.min(), "IPHONEOS_DEPLOYMENT_TARGET not found in project.pbxproj")
    }

    /// Major versions of every `#available(iOS N` / `#unavailable(iOS N` on one source line (comment lines are skipped).
    static func availabilityMajors(inLine line: String) -> [Int] {
        guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"#(?:un)?available\s*\([^)]*\biOS\s+(\d+)"#) else { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            Range(match.range(at: 1), in: line).flatMap { Int(line[$0]) }
        }
    }

    @Test("Scanner self-check: finds always-true checks, ignores comments, reports real new-OS checks by version")
    func scannerRecognizesDeadChecks() {
        #expect(Self.availabilityMajors(inLine: "        if #available(iOS 17.0, *) {") == [17])
        #expect(Self.availabilityMajors(inLine: "guard #available(macOS 14, iOS 15, *) else { return }") == [15])
        #expect(Self.availabilityMajors(inLine: "if #unavailable(iOS 18) {") == [18])
        #expect(Self.availabilityMajors(inLine: "        if #available(iOS 26, *) {") == [26])
        #expect(Self.availabilityMajors(inLine: "    /// Do not write `if #available(iOS 17.0, *)`").isEmpty)
    }

    @Test("App sources have no #available check at or below the deployment target")
    func noAvailabilityCheckAtOrBelowDeploymentTarget() throws {
        let target = try Self.deploymentTargetMajor()
        #expect(target >= 18, "Deployment target parsed as \(target), which does not look right")
        let enumerator = try #require(FileManager.default.enumerator(at: Self.sourceRoot, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for major in Self.availabilityMajors(inLine: String(line)) where major <= target {
                    offenders.append("\(url.lastPathComponent):\(index + 1) #available(iOS \(major)) is always true (deployment target iOS \(target))")
                }
            }
        }
        // Scanning zero files would also "pass": make the guard fail loudly if #filePath stops resolving.
        #expect(scanned >= 300, "Only \(scanned) source files scanned; #filePath resolution is probably broken")
        #expect(offenders.isEmpty, """
        Remove these always-true checks together with their dead branch (a dead branch is compiled as if every \
        API were available and can pull newer-OS-only types into a view's Body type):
        \(offenders.joined(separator: "\n"))
        """)
    }
}
