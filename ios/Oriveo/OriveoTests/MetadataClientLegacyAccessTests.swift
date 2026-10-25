import Foundation
import Testing
@testable import Oriveo

/// Legacy field type reference lock.
///
/// The app is not inside the OriveoProviderKit package, so the `package` access level is invisible to it; a source scan stands in for access control:
/// scan every `.swift` under `ios/Oriveo/Oriveo/`, and each token may only appear in allowlisted files.
/// A new reference fails the test (go through `CapabilityEvidenceFacade` instead); an allowlisted file that no longer references the token also fails (remove it from the table; the list may only shrink).
/// Comment lines (starting with `//`, `/*` or `*`) are ignored.
@Suite("Metadata legacy field reference lock (iOS)", .sharedProcessState)
struct MetadataClientLegacyAccessTests {

    private struct Token {
        let name: String
        let pattern: String
        /// Only scan this file; nil = scan all files.
        let onlyFile: String?
        let allowed: Set<String>
    }

    /// Allowlist = measured reference set; paths are relative to `ios/Oriveo/Oriveo/`.
    private static let tokens: [Token] = [
        Token(
            name: "RelayTransportEnvelope",
            pattern: #"\bRelayTransportEnvelope\b"#,
            onlyFile: nil,
            allowed: [
                "Core/Providers/MetadataClient.swift",
                "Core/Providers/RelayOfficialCatalogResolver.swift",
            ]
        ),
        Token(
            name: "RelayRuntimeConfig",
            pattern: #"\bRelayRuntimeConfig\b"#,
            onlyFile: nil,
            allowed: [
                "Core/Providers/MetadataClient.swift",
                "Core/Providers/RelayOfficialCatalogResolver.swift",
                "Core/Providers/RelayRuntimeSupport.swift",
                "Core/Tools/ToolLoopLegRunner.swift",
                "Features/Providers/RelayEditView.swift",
            ]
        ),
        Token(
            name: "MetadataClient.AttachmentSupport",
            pattern: #"\bMetadataClient\.AttachmentSupport\b"#,
            onlyFile: nil,
            allowed: []
        ),
        Token(
            name: "AttachmentSupport (MetadataClient.swift)",
            pattern: #"\bAttachmentSupport\b"#,
            onlyFile: "Core/Providers/MetadataClient.swift",
            allowed: ["Core/Providers/MetadataClient.swift"]
        ),
        Token(
            name: ".attachmentSupport",
            pattern: #"\.attachmentSupport\b"#,
            onlyFile: nil,
            allowed: [
                // Attachment entry gating goes through the facade `attachmentImportEntry` only.
                "Core/Providers/CapabilityEvidenceFacade.swift",
                "Core/Providers/MetadataClient.swift",
            ]
        ),
        Token(
            name: "transportEnvelopes",
            pattern: #"\btransportEnvelopes\b"#,
            onlyFile: nil,
            allowed: [
                "Core/Providers/MetadataClient.swift",
                "Core/Providers/RelayOfficialCatalogResolver.swift",
                "Core/Providers/RelayRuntimeSupport.swift",
            ]
        ),
    ]

    private static func appSourceRoot() throws -> URL {
        let relativePath = "ios/Oriveo/Oriveo"
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Core").path) {
                return candidate
            }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Relative path -> code lines with comment lines removed.
    private static func loadSources() throws -> [String: [String]] {
        let root = try appSourceRoot().standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var sources: [String: [String]] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            let relative = String(path.dropFirst(rootPath.count))
            let text = try String(contentsOf: url, encoding: .utf8)
            sources[relative] = text.components(separatedBy: .newlines).filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*"))
            }
        }
        return sources
    }

    @Test("The scan covers the app source root")
    func scanCoversAppSources() throws {
        let sources = try Self.loadSources()
        #expect(sources["Core/Providers/MetadataClient.swift"] != nil)
        #expect(sources["Core/Providers/CapabilityEvidenceFacade.swift"] != nil)
        #expect(sources.count > 100, "Only scanned \(sources.count) .swift files; the source root may be located wrongly")
    }

    @Test("Legacy field types may only be referenced from allowlisted files, and the allowlist may only shrink")
    func legacyTokensStayWithinAllowlist() throws {
        let sources = try Self.loadSources()
        for token in Self.tokens {
            let regex = try NSRegularExpression(pattern: token.pattern)
            var referencing: Set<String> = []
            for (path, lines) in sources {
                if let only = token.onlyFile, only != path { continue }
                let hit = lines.contains { line in
                    regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                }
                if hit { referencing.insert(path) }
            }
            let added = referencing.subtracting(token.allowed).sorted()
            let gone = token.allowed.subtracting(referencing).sorted()
            #expect(
                added.isEmpty,
                "\(token.name) has new references: \(added). Route new references through CapabilityEvidenceFacade instead of widening the allowlist."
            )
            #expect(
                gone.isEmpty,
                "\(token.name) allowlisted files no longer reference it: \(gone). Remove them from the allowlist in MetadataClientLegacyAccessTests.tokens."
            )
        }
    }

    @Test("The facade owns the three input key constants")
    func facadeOwnsInputKeys() {
        #expect(CapabilityEvidenceFacade.visionInputKey == "vision_input")
        #expect(CapabilityEvidenceFacade.fileInputKey == "file_input")
        #expect(CapabilityEvidenceFacade.videoInputKey == "video_input")
    }
}
