import Foundation
import Testing
@testable import Oriveo

/// The eight engineering support states collapse into three user-visible classes.
///
/// Fixes a bug where the **user was told a false fact**: `unsupported` (this model does
/// not accept the parameter; send will be rejected), `accepted` (it will be sent), and
/// `future_supported` (officially planned) all fell through `default` and rendered as
/// "unknown". "We don't know" and "explicitly no" were the same sentence on screen.
///
/// Source of truth is `shared/model-contracts/generation_parameter_contract.v1.json#presentationClasses`.
/// This suite reconciles row by row; **a 9th server state turns this red**, instead of
/// silently rendering as "no data yet".
@Suite("Generation-parameter support presentation classes")
struct GenerationParameterSupportPresentationTests {
    @Test("every contract support value has an iOS-table home, and class/render/editable match row by row")
    func everyContractSupportHasAMapping() throws {
        let contract = try Self.contract()
        let schema = try #require(contract["schema"] as? [String: Any])
        let declared = try #require(schema["support"] as? [String])
        let presentation = try #require(contract["presentationClasses"] as? [String: Any])
        let classes = try #require(presentation["classes"] as? [[String: Any]])
        let supportMap = try #require(presentation["supportMap"] as? [String: Any])

        var classByID: [String: [String: Any]] = [:]
        for entry in classes {
            let id = try #require(entry["classId"] as? String)
            classByID[id] = entry
        }

        #expect(declared.count == 8, "the contract's support values changed; this suite's contract must be reviewed in the same round")

        for support in declared {
            let iosEntry = try #require(
                GenerationParameterSupportPresentation.entry(forRegistered: support),
                "iOS table has no \(support) — it would silently render as \"no data yet\""
            )
            let mapping = try #require(supportMap[support] as? [String: Any], "contract supportMap is missing \(support)")
            let classID = try #require(mapping["class"] as? String)
            #expect(
                iosEntry.presentationClass.rawValue == classID,
                "\(support) class mismatch: iOS \(iosEntry.presentationClass.rawValue) vs contract \(classID)"
            )

            let contractClass = try #require(classByID[classID])
            #expect(iosEntry.renders == (contractClass["renders"] as? Bool ?? true))
            let control = contractClass["control"] as? String
            #expect(
                iosEntry.control.rawValue == control,
                "\(support) editability mismatch: iOS \(iosEntry.control.rawValue) vs contract \(control ?? "nil")"
            )
            // A disabled control must ship a primary action; without one the row is a dead end that
            // tells the user no and offers nothing to do about it.
            if iosEntry.control == .disabled {
                #expect(iosEntry.primaryAction?.isEmpty == false, "\(support) is disabled but has no primary action")
            }
            // Non-silent states must have their own secondary copy; several states must not share "unknown".
            if iosEntry.renders {
                #expect(iosEntry.detail?.isEmpty == false, "\(support) has no secondary copy")
            }
        }
    }

    @Test("the three states that were misreported as \"unknown\" now each speak for themselves, and they differ")
    func theThreeMisreportedStatesNowSpeakForThemselves() throws {
        let unsupported = try #require(GenerationParameterSupportPresentation.entry(forRegistered: "unsupported"))
        let accepted = try #require(GenerationParameterSupportPresentation.entry(forRegistered: "accepted"))
        let future = try #require(GenerationParameterSupportPresentation.entry(forRegistered: "future_supported"))
        let unknown = try #require(GenerationParameterSupportPresentation.entry(forRegistered: "unknown"))

        // "Explicitly no" must never land on the same sentence as "we don't know".
        #expect(unsupported.presentationClass == .notAdjustable)
        #expect(unsupported.detail != unknown.detail)
        #expect(unsupported.control == .disabled)
        // `accepted` is the silent default; it should not say a word.
        #expect(accepted.presentationClass == .silent)
        #expect(accepted.renders == false)
        // "Officially not yet available" is an explicit negative state, not "we have no data".
        #expect(future.presentationClass == .notAdjustable)
        #expect(future.control == .disabled)
        #expect(future.detail != unknown.detail)
    }

    /// Decision:
    /// source / transport always go through the localization vocabulary and **never emit
    /// a wire value**. The previous assertion `text.contains("official catalog")` was
    /// exactly the deleted behavior — the old implementation replaced underscores in
    /// `official_catalog` with spaces and showed that to the user.
    /// Rewritten to assert the new correct behavior: the provenance chain is still there
    /// (the Source segment is kept and taken from the production vocabulary), but what
    /// is shown is the translation, not the id.
    @Test("row secondary copy: silent states stay silent; non-silent states keep Source and show only the localized vocabulary")
    func rowNoteKeepsSourceOnNonSilentStates() throws {
        #expect(GenerationParameterRowStatus.note(support: "supported", source: "authoritative_metadata") == nil)
        #expect(GenerationParameterRowStatus.note(support: "accepted", source: "official_catalog") == nil)

        let text = try #require(
            GenerationParameterRowStatus.note(support: "unsupported", source: "official_catalog")
        )
        #expect(text.isEmpty == false)
        // Provenance chain is still there: the Source segment ends with the production
        // vocabulary translation. Take the expected value from the production function;
        // do not copy a second copy table in the test.
        #expect(text.contains(L10n.tr("Source")), "Source provenance chain was cut")
        #expect(
            text.hasSuffix(GenerationParameterVocabulary.source("official_catalog")),
            "Source segment did not go through the production vocabulary"
        )
        // Emitting a wire value is exactly the behaviour that was removed: neither the raw id
        // nor its "underscores replaced with spaces" form may appear.
        #expect(!text.contains("official_catalog"))
        #expect(!text.contains("official catalog"))
        // The vocabulary is not a constant function: a registered source and an unregistered
        // source must produce different copy, otherwise "everything falls through to other
        // source" would still keep the assertions above green.
        #expect(
            GenerationParameterVocabulary.source("authoritative_metadata")
                != GenerationParameterVocabulary.source("official_catalog")
        )

        // Missing support renders as "no data yet", it does not silently disappear.
        #expect(GenerationParameterRowStatus.note(support: nil, source: nil) != nil)
    }

    @Test("the panel no longer inlines a support switch; it only reads the shared table")
    func panelReadsTheSharedTableOnly() throws {
        let sheet = try Self.source([
            "ios", "Oriveo", "Oriveo", "Features", "Providers",
            "GenerationParameterDefaultsSheet.swift",
        ])
        #expect(sheet.contains("GenerationParameterRowStatus.note("))
        #expect(sheet.contains("GenerationParameterSupportPresentation.entry("))
        // The old five-branch switch must be gone — leaving it is a second source of truth,
        // and the prototype of this bug.
        #expect(
            !sheet.contains("case \"accepted_unverified\": support = "),
            "panel still inlines a supportLabel switch"
        )
        #expect(
            !sheet.contains("if parameter.support == \"fixed\" {"),
            "panel still decides control shape by inlining a support literal"
        )
    }

    // MARK: - helpers

    private static func contract() throws -> [String: Any] {
        let url = findFile(["shared", "model-contracts", "generation_parameter_contract.v1.json"])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    private static func source(_ components: [String]) throws -> String {
        try String(contentsOf: findFile(components), encoding: .utf8)
    }

    private static func findFile(_ components: [String]) -> URL {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while current.path != current.deletingLastPathComponent().path {
            let candidate = components.reduce(current) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            current = current.deletingLastPathComponent()
        }
        fatalError("fixture not found: \(components.joined(separator: "/"))")
    }
}
