import Foundation
import Testing
@testable import Oriveo

/// Layout rules for the capability cards in the model controls panel.
///
/// The rule behind every case here: the panel must never render a control that cannot possibly
/// work. When a capability is not configurable the card degrades to a status row that explains why
/// and offers a real way out, instead of showing a switch or a row of pills that silently do
/// nothing.
@Suite("Model Control Capability Layout Tests")
struct ModelControlCapabilityLayoutTests {
    @Test("Unknown Remains Configurable")
    func unknownRemainsConfigurable() {
        #expect(CapabilityControlPresentation.unknown.isConfigurable)
        #expect(!CapabilityControlPresentation.unsupported.isConfigurable)
    }


    @Test("Pill Row Only Renders Declared Tiers")
    func pillRowOnlyRendersDeclaredTiers() {
        let layout = ModelControlReasoningLayout.layout(
            status: .automaticAvailable, intents: ["off", "balanced"],
            selectedIntent: nil, isEditable: true
        )
        #expect(layout.form == .pillRow)
        #expect(layout.options.map(\.id) == ["off", ModelControlReasoningLayout.automaticIntent, "balanced"])
        #expect(layout.selection == ModelControlReasoningLayout.automaticIntent)
        #expect(!layout.options.map(\.id).contains("low"))
        #expect(!layout.options.map(\.id).contains("deep"))
        #expect(!layout.options.map(\.id).contains("max"))
        #expect(layout.options.allSatisfy { $0.isEnabled })
    }

    @Test("Full Tier Order Is Frozen")
    func fullTierOrderIsFrozen() {
        let layout = ModelControlReasoningLayout.layout(
            status: .automaticAvailable, intents: ["max", "deep", "balanced", "low", "off"],
            selectedIntent: "max", isEditable: true
        )
        #expect(layout.options.map(\.id) == [
            "off", ModelControlReasoningLayout.automaticIntent, "low", "balanced", "deep", "max",
        ])
        #expect(layout.selection == "max")
        #expect(layout.options.contains { $0.id == layout.selection })
    }

    @Test("Annotation Follows The Selected Tier")
    func annotationFollowsTheSelectedTier() {
        let layout = ModelControlReasoningLayout.layout(
            status: .automaticAvailable, intents: ["off", "low", "balanced", "deep", "max"],
            selectedIntent: "deep", isEditable: true
        )
        for option in layout.options {
            #expect(!option.label.isEmpty, "\(option.id) has no level name")
        }
        #expect(layout.selectedAnnotation == ModelControlReasoningLayout.caption(for: "deep"))
        #expect(!layout.selectedAnnotation.isEmpty)

        let switched = ModelControlReasoningLayout.layout(
            status: .automaticAvailable, intents: ["off", "low", "balanced", "deep", "max"],
            selectedIntent: "low", isEditable: true
        )
        #expect(switched.selectedAnnotation == ModelControlReasoningLayout.caption(for: "low"))
        #expect(switched.selectedAnnotation != layout.selectedAnnotation)

        let captions = ["off", ModelControlReasoningLayout.automaticIntent, "low", "balanced", "deep", "max"]
            .map(ModelControlReasoningLayout.caption(for:))
        #expect(captions.allSatisfy { !$0.isEmpty })
        #expect(Set(captions).count == captions.count)
    }

    @Test("Without Off The List Explains Itself")
    func withoutOffTheListExplainsItself() {
        let layout = ModelControlReasoningLayout.layout(
            status: .automaticAvailable, intents: ["low", "balanced", "deep"],
            selectedIntent: nil, isEditable: true
        )
        #expect(!layout.options.map(\.id).contains("off"), "a model whose reasoning cannot be turned off must not show an off pill that is guaranteed to fail")
        #expect(layout.footnote != nil, "hiding the off pill without saying why makes the user think the app cannot turn it off")

        let withOff = ModelControlReasoningLayout.layout(
            status: .automaticAvailable, intents: ["off", "low"], selectedIntent: nil, isEditable: true
        )
        #expect(withOff.footnote == nil, "a model that can be turned off must not carry that footnote")
    }

    @Test("Stale Selection Falls Back To Automatic")
    func staleSelectionFallsBackToAutomatic() {
        let layout = ModelControlReasoningLayout.layout(
            status: .automaticAvailable, intents: ["low", "balanced"],
            selectedIntent: "max", isEditable: true
        )
        #expect(layout.selection == ModelControlReasoningLayout.automaticIntent)
        #expect(layout.options.contains { $0.id == layout.selection })
        #expect(layout.selectedAnnotation == ModelControlReasoningLayout.caption(
            for: ModelControlReasoningLayout.automaticIntent
        ))
    }

    @Test("Fixed Tier Renders A Status Row")
    func fixedTierRendersAStatusRow() {
        let layout = ModelControlReasoningLayout.layout(
            status: .automaticAvailable, intents: [], selectedIntent: nil, isEditable: true
        )
        #expect(layout.form == .statusRow)
        #expect(layout.options.isEmpty, "with no levels at all, a row of buttons that are guaranteed to fail must not be drawn")
        #expect(!layout.statusText.isEmpty)
    }

    @Test("Pending Reasoning Stays Honest")
    func pendingReasoningStaysHonest() {
        for status in [CapabilityControlPresentation.pending, .unknown] {
            let layout = ModelControlReasoningLayout.layout(
                status: status, intents: [], selectedIntent: nil, isEditable: true
            )
            #expect(layout.form == .statusRow, "\(status) must not render a control that cannot work")
            #expect(!layout.statusText.isEmpty)
            #expect(layout.explanation != nil, "\(status): a status row that does nothing when tapped and explains nothing is a dead end")
            #expect(layout.escape == .supportedModels, "\(status) offers no way out")
        }
    }

    @Test("Unsupported Reasoning Offers A Way Out")
    func unsupportedReasoningOffersAWayOut() {
        for status in [CapabilityControlPresentation.unsupported, .externalConnectorOnly] {
            let layout = ModelControlReasoningLayout.layout(
                status: status, intents: [], selectedIntent: nil, isEditable: true
            )
            #expect(layout.form == .statusRow)
            #expect(layout.explanation != nil)
            #expect(layout.escape == .supportedModels)
        }
    }

    @Test("Custom Only Reasoning Points At Advanced Settings")
    func customOnlyReasoningPointsAtAdvancedSettings() {
        let layout = ModelControlReasoningLayout.layout(
            status: .customOnly, intents: [], selectedIntent: nil, isEditable: true
        )
        #expect(layout.form == .statusRow)
        #expect(layout.escape == .advancedSettings)
        #expect(layout.explanation != nil)
    }

    @Test("Read Only Reasoning Shows The Current Value")
    func readOnlyReasoningShowsTheCurrentValue() {
        let layout = ModelControlReasoningLayout.layout(
            status: .automaticAvailable, intents: ["off", "low", "deep"],
            selectedIntent: "deep", isEditable: false
        )
        #expect(layout.form == .statusRow)
        #expect(layout.statusText == ModelControlIntentLabel.text("deep"))
        #expect(layout.explanation == nil)
    }


    @Test("Web Renders A Toggle")
    func webRendersAToggle() {
        let off = ModelControlWebLayout.layout(
            status: .automaticAvailable, availableIntents: ["off", "automatic"],
            selection: .off, isEditable: true
        )
        #expect(off.form == .toggle)
        #expect(!off.isOn)
        #expect(off.caption != nil, "the switch must say what turning it on actually does")

        let on = ModelControlWebLayout.layout(
            status: .automaticAvailable, availableIntents: ["off", "automatic"],
            selection: .automatic, isEditable: true
        )
        #expect(on.isOn)
    }

    @Test("Timing Picker Appears Only When Declared And On")
    func timingPickerAppearsOnlyWhenDeclaredAndOn() {
        let noForce = ModelControlWebLayout.layout(
            status: .automaticAvailable, availableIntents: ["off", "automatic"],
            selection: .automatic, isEditable: true
        )
        #expect(noForce.timingOptions.isEmpty, "a model that cannot force a search must not be offered a timing option it cannot honour")

        let offWithForce = ModelControlWebLayout.layout(
            status: .automaticAvailable, availableIntents: ["off", "automatic", "force"],
            selection: .off, isEditable: true
        )
        #expect(offWithForce.timingOptions.isEmpty, "asking when to search is meaningless while search is off")

        let onWithForce = ModelControlWebLayout.layout(
            status: .automaticAvailable, availableIntents: ["off", "automatic", "force"],
            selection: .force, isEditable: true
        )
        #expect(onWithForce.isOn)
        #expect(onWithForce.timingOptions.map(\.id) == ["automatic", "force"])
        #expect(onWithForce.timingSelection == "force")
        #expect(onWithForce.timingOptions.allSatisfy { $0.isEnabled })
    }

    /// A pending or unknown capability does not keep a switch as an escape hatch. The argument for
    /// one was "let the upstream decide, just try it once", but with no recipe the client cannot
    /// compile any web field at all: the request sent with the switch on is byte-for-byte identical
    /// to the request sent with it off. A switch that changes nothing yet rests in the "on"
    /// position is the interface lying to the user.
    @Test("Pending Web Falls Back To An Honest Status Row")
    func pendingWebFallsBackToAnHonestStatusRow() {
        for status in [CapabilityControlPresentation.pending, .unknown] {
            let layout = ModelControlWebLayout.layout(
                status: status, availableIntents: [], selection: .off, isEditable: true
            )
            #expect(layout.form == .statusRow, "\(status) rendered a switch that cannot work")
            #expect(layout.statusText == L10n.tr("Cannot adjust yet", table: .chat))
            #expect(layout.explanation != nil, "\(status): a status row that does nothing when tapped and explains nothing is a dead end")
            #expect(layout.escape == .supportedModels, "\(status) does not offer switching model as a real way out")
        }
    }

    /// A stored `force` preference is clamped back to `automatic` when the current recipe no longer
    /// offers it. Only some models can force a search; after choosing "search every message" on one
    /// of them and switching to a different model, the stored value stays `force` while the timing
    /// pills are not rendered at all - so the user sees a choice they never made while the request
    /// actually goes out as automatic.
    @Test("Stale Force Is Clamped To Automatic")
    func staleForceIsClampedToAutomatic() {
        let clamped = ModelControlWebLayout.layout(
            status: .automaticAvailable, availableIntents: ["off", "automatic"],
            selection: .force, isEditable: true
        )
        #expect(clamped.isOn)
        #expect(clamped.effectiveSelection == .automatic)
        #expect(clamped.timingSelection == CapabilityWebPreference.automatic.rawValue)
        #expect(clamped.timingOptions.isEmpty)

        let kept = ModelControlWebLayout.layout(
            status: .automaticAvailable, availableIntents: ["off", "automatic", "force"],
            selection: .force, isEditable: true
        )
        #expect(kept.effectiveSelection == .force)
        #expect(kept.timingSelection == CapabilityWebPreference.force.rawValue)

        for status in [CapabilityControlPresentation.pending, .unknown, .customOnly] {
            #expect(
                ModelControlWebLayout.clamp(.force, status: status, availableIntents: []) == .force,
                "\(status) clamped away the force preference the user had chosen"
            )
        }
    }

    @Test("Custom Only Without Schema Points At Supported Models")
    func customOnlyWithoutSchemaPointsAtSupportedModels() {
        for hasSchema in [true, false] {
            let web = ModelControlWebLayout.layout(
                status: .customOnly, availableIntents: [], selection: .off,
                isEditable: true, hasCustomSchema: hasSchema
            )
            let reasoning = ModelControlReasoningLayout.layout(
                status: .customOnly, intents: [], selectedIntent: nil,
                isEditable: true, hasCustomSchema: hasSchema
            )
            let expected: ModelControlCapabilityEscape = hasSchema ? .advancedSettings : .supportedModels
            #expect(web.escape == expected)
            #expect(reasoning.escape == expected)
        }
    }

    @Test("Unsupported Web Offers A Way Out")
    func unsupportedWebOffersAWayOut() {
        for status in [CapabilityControlPresentation.unsupported, .externalConnectorOnly] {
            let layout = ModelControlWebLayout.layout(
                status: status, availableIntents: [], selection: .off, isEditable: true
            )
            #expect(layout.form == .statusRow)
            #expect(!layout.statusText.isEmpty)
            #expect(layout.explanation != nil, "\(status): a status row that does nothing when tapped and explains nothing is a dead end")
            #expect(layout.escape == .supportedModels)
        }
    }

    @Test("Custom Only Web Points At Advanced Settings")
    func customOnlyWebPointsAtAdvancedSettings() {
        let layout = ModelControlWebLayout.layout(
            status: .customOnly, availableIntents: [], selection: .off, isEditable: true
        )
        #expect(layout.form == .statusRow)
        #expect(layout.escape == .advancedSettings)
        #expect(layout.explanation != nil)
    }

    @Test("Read Only Web Shows The Current Value")
    func readOnlyWebShowsTheCurrentValue() {
        let layout = ModelControlWebLayout.layout(
            status: .automaticAvailable, availableIntents: ["off", "automatic"],
            selection: .automatic, isEditable: false
        )
        #expect(layout.form == .statusRow)
        #expect(layout.statusText == ModelControlIntentLabel.webText(.automatic))
        #expect(layout.explanation == nil)
    }

    /// Stale stored preferences: the panel switch, the composer summary and the chat screen now
    /// share this one rule.
    ///
    /// Preferences are stored per connection, model and transport, but whether they can go out
    /// depends on the current metadata. After a model generation change, a retirement or a
    /// transport switch, the stored `automatic` is unchanged and the globe on the chip stays lit
    /// while the request carries no web field at all. That is exactly the "lit globe that never
    /// searches".
    @Test("Stale Web Preference Stops Lighting The Globe")
    func staleWebPreferenceStopsLightingTheGlobe() {
        #expect(CapabilityWebPreferenceLiveness.reachesTheWire(
            status: .automaticAvailable, customIsActive: false
        ))
        #expect(CapabilityWebPreferenceLiveness.reachesTheWire(
            status: .unsupported, customIsActive: true
        ))
        for status: CapabilityControlPresentation in [
            .pending, .unknown, .unsupported, .externalConnectorOnly, .customOnly,
        ] {
            #expect(
                !CapabilityWebPreferenceLiveness.reachesTheWire(status: status, customIsActive: false),
                "\(status) still lit the globe even though no web tool would be sent"
            )
        }
    }


    @Test("Every Unavailable State Has An Escape")
    func everyUnavailableStateHasAnEscape() {
        let unavailable: [CapabilityControlPresentation] = [
            .unsupported, .externalConnectorOnly, .customOnly, .pending, .unknown,
        ]
        for status in unavailable {
            let web = ModelControlWebLayout.layout(
                status: status, availableIntents: [], selection: .off, isEditable: true
            )
            #expect(web.form == .statusRow, "web/\(status) must not render an interactive control")
            #expect(web.explanation != nil, "web/\(status) status row has no explanation")
            #expect(web.escape != .none, "web/\(status) status row offers no way out")

            let reasoning = ModelControlReasoningLayout.layout(
                status: status, intents: [], selectedIntent: nil, isEditable: true
            )
            #expect(reasoning.form == .statusRow, "reasoning/\(status) must not render an interactive control")
            #expect(reasoning.explanation != nil, "reasoning/\(status) status row has no explanation")
            #expect(reasoning.escape != .none, "reasoning/\(status) status row offers no way out")
        }
    }
}
