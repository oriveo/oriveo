import Foundation

/// Builds the prompt sent to the image model from the user text, reference images, the
/// chosen style and effects. Cases: `shared/studio-contracts/studio_prompt_compose.v1.json`,
/// shared by the iOS / Android / Web contract tests; executable reference:
/// `scripts/lib/studio-image-reference.mjs` composePrompt.
nonisolated enum StudioPromptComposer {
    nonisolated struct Spec: Codable, Equatable, Sendable {
        var sectionSeparator: String
        var inlineReference: String
        var referenceTemplate: String
        var baseTemplate: String
        var styleTemplate: String
        var effectsTemplate: String
        var effectsJoiner: String
        var roleWords: [String: String]

        /// Same values as the `spec` block of studio_prompt_compose.v1.json.
        static let v1 = Spec(
            sectionSeparator: "\n\n",
            inlineReference: "image {n}",
            referenceTemplate: "Image {n} is the {role} reference.",
            baseTemplate: "Image {n} is the image to edit.",
            styleTemplate: "Style: {fragment}.",
            effectsTemplate: "Effects: {fragments}.",
            effectsJoiner: "; ",
            roleWords: [
                "subject": "subject",
                "style": "style",
                "composition": "composition",
                "person": "character",
                "element": "element",
            ]
        )
    }

    nonisolated enum Role: String, Codable, CaseIterable, Sendable {
        case base, subject, style, composition, person, element
    }

    nonisolated struct Reference: Equatable, Sendable {
        var n: Int
        var role: Role
    }

    nonisolated struct Input: Equatable, Sendable {
        var userPrompt: String
        var references: [Reference]
        var styleFragment: String?
        var effectFragments: [String]
        var maxPromptChars: Int
    }

    nonisolated enum Failure: String, Error, Sendable {
        case promptTooLong = "prompt_too_long"
    }

    nonisolated enum AdjustmentField: String, Sendable {
        case effect, style
    }

    nonisolated struct Adjustment: Equatable, Sendable {
        var field: AdjustmentField
        var dropped: String
    }

    nonisolated struct Composition: Equatable, Sendable {
        /// `nil` only together with `error`.
        var composed: String?
        var error: Failure?
        var adjustments: [Adjustment]
    }

    /// Sections in order: user text (with `@N` expanded), reference sentences, style, effects.
    /// Over `maxPromptChars` (Unicode code points): drop effects from the last one, then the
    /// style; the user text is never cut, so it may still end in `prompt_too_long`.
    static func compose(_ spec: Spec, _ input: Input) -> Composition {
        var adjustments: [Adjustment] = []
        let user = expandMentions(input.userPrompt, spec)
        let referenceLines = input.references.map { ref -> String in
            if ref.role == .base { return fill(spec.baseTemplate, "{n}", String(ref.n)) }
            let roleWord = spec.roleWords[ref.role.rawValue] ?? ref.role.rawValue
            return fill(fill(spec.referenceTemplate, "{n}", String(ref.n)), "{role}", roleWord)
        }
        var style = input.styleFragment
        var effects = input.effectFragments
        func build() -> String {
            // An empty user text (exactly "", no trimming) adds no section.
            var sections: [String] = user.isEmpty ? [] : [user]
            if !referenceLines.isEmpty { sections.append(referenceLines.joined(separator: " ")) }
            if let style, !style.isEmpty { sections.append(fill(spec.styleTemplate, "{fragment}", style)) }
            if !effects.isEmpty {
                sections.append(fill(spec.effectsTemplate, "{fragments}", effects.joined(separator: spec.effectsJoiner)))
            }
            return sections.joined(separator: spec.sectionSeparator)
        }
        var composed = build()
        while composed.unicodeScalars.count > input.maxPromptChars, let last = effects.popLast() {
            adjustments.append(Adjustment(field: .effect, dropped: last))
            composed = build()
        }
        if composed.unicodeScalars.count > input.maxPromptChars, let dropped = style, !dropped.isEmpty {
            adjustments.append(Adjustment(field: .style, dropped: dropped))
            style = nil
            composed = build()
        }
        if composed.unicodeScalars.count > input.maxPromptChars {
            return Composition(composed: nil, error: .promptTooLong, adjustments: adjustments)
        }
        return Composition(composed: composed, error: nil, adjustments: adjustments)
    }

    /// `@` followed by ASCII digits 0-9 becomes `inlineReference`; other digit scripts and a
    /// bare `@` stay as typed.
    private static func expandMentions(_ text: String, _ spec: Spec) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if scalars[index] == "@" {
                var end = index + 1
                while end < scalars.count, (0x30...0x39).contains(scalars[end].value) { end += 1 }
                if end > index + 1 {
                    let digits = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
                    out.append(contentsOf: fill(spec.inlineReference, "{n}", digits).unicodeScalars)
                    index = end
                    continue
                }
            }
            out.append(scalars[index])
            index += 1
        }
        return String(out)
    }

    /// Replaces the first `key` in `template` with `value`, verbatim (no pattern syntax, no
    /// second pass over the inserted value). Matching is scalar-exact.
    private static func fill(_ template: String, _ key: String, _ value: String) -> String {
        let source = Array(template.unicodeScalars)
        let needle = Array(key.unicodeScalars)
        guard !needle.isEmpty, source.count >= needle.count else { return template }
        for start in 0...(source.count - needle.count)
        where source[start..<(start + needle.count)].elementsEqual(needle) {
            var out = String.UnicodeScalarView()
            out.append(contentsOf: source[..<start])
            out.append(contentsOf: value.unicodeScalars)
            out.append(contentsOf: source[(start + needle.count)...])
            return String(out)
        }
        return template
    }
}
