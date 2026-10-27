import Testing
import UIKit
@testable import Oriveo

/// The user bubble's viewport-anchored vertical gradient:
/// (1) the ported color stops are within 1 per channel of `userBubbleStops` and
///   `custom.derivationCases[].bubble` in `shared/theme-contracts/dark-palettes.v1.json` (cases read live); (2) the pure anchoring functions; (3) the layers of the production bubble cell.
@MainActor
@Suite("User bubble viewport gradient", .serialized)
struct UserBubbleGradientContractTests {
    static func expectStops(_ actual: [UInt], _ expected: [String], _ label: String) throws {
        #expect(actual.count == expected.count, "\(label) stop count")
        for (index, (a, e)) in zip(actual, expected).enumerated() {
            let want = try OriveoDarkPalettesTests.hex(e)
            for shift in [16, 8, 0] {
                let ea = Int((want >> UInt(shift)) & 0xFF)
                let aa = Int((a >> UInt(shift)) & 0xFF)
                #expect(abs(ea - aa) <= 1, "\(label)[\(index)]: expected \(e), got \(OriveoCustomPalette.format(a))")
            }
        }
    }

    // MARK: 1. Color stop contract

    @Test("derived.userBubble: the 7 stops and the inner highlight and outer shadow parameters match the contract")
    func userBubbleSpecMatchesContract() throws {
        let contract = try OriveoDarkPalettesTests.loadContract()
        let derived = try #require(contract["derived"] as? [String: Any])
        let spec = try #require(derived["userBubble"] as? [String: Any])
        #expect(spec["anchor"] as? String == "viewport")
        #expect(spec["axis"] as? String == "vertical")
        #expect(spec["stops"] as? Int == OriveoUserBubble.stopCount)
        #expect((spec["dark"] as? [String: String]) == ["top": "accent", "bottom": "primary"])
        #expect((spec["light"] as? [String: String]) == ["top": "gradEnd", "bottom": "gradStart"])
        let highlight = try #require(spec["highlight"] as? [String: Any])
        let alpha = try #require(highlight["alpha"] as? [String: Double])
        #expect(highlight["width"] as? Double == Double(OriveoUserBubble.highlightWidth))
        #expect(alpha["dark"] == Double(OriveoUserBubble.highlightAlphaDark))
        #expect(alpha["light"] == Double(OriveoUserBubble.highlightAlphaLight))
        let shadow = try #require(spec["shadow"] as? [String: Any])
        #expect(shadow["from"] as? String == "bottom")
        #expect((shadow["alpha"] as? Double).map(Float.init) == OriveoUserBubble.shadowAlpha)
        #expect(shadow["blur"] as? Double == Double(OriveoUserBubble.shadowBlur))
        #expect(shadow["y"] as? Double == Double(OriveoUserBubble.shadowOffsetY))
    }

    @Test("userBubbleStops: 7 presets × dark / light stops, within 1 per channel")
    func presetStopsMatchContract() throws {
        let contract = try OriveoDarkPalettesTests.loadContract()
        let table = try #require(contract["userBubbleStops"] as? [String: [String: [String]]])
        #expect(Set(table.keys) == Set(OriveoDarkPaletteID.allCases.map(\.rawValue)))
        for id in OriveoDarkPaletteID.allCases {
            let entry = try #require(table[id.rawValue], "missing \(id.rawValue)")
            try Self.expectStops(
                OriveoUserBubble.stops(for: .preset(id), dark: true), try #require(entry["dark"]), "\(id.rawValue).dark"
            )
            try Self.expectStops(
                OriveoUserBubble.stops(for: .preset(id), dark: false), try #require(entry["light"]), "\(id.rawValue).light"
            )
        }
    }

    @Test("custom.derivationCases[].bubble: custom palette dark / light stops within 1 per channel")
    func customStopsMatchContract() throws {
        let contract = try OriveoDarkPalettesTests.loadContract()
        let custom = try #require(contract["custom"] as? [String: Any])
        let cases = try #require(custom["derivationCases"] as? [[String: Any]])
        var checked = 0
        for item in cases {
            let seedText = try #require(item["seed"] as? String)
            guard let bubble = item["bubble"] as? [String: [String]] else { continue }
            let choice = OriveoDarkPaletteChoice.custom(seed: try OriveoDarkPalettesTests.hex(seedText))
            try Self.expectStops(OriveoUserBubble.stops(for: choice, dark: true), try #require(bubble["dark"]), "\(seedText).dark")
            try Self.expectStops(OriveoUserBubble.stops(for: choice, dark: false), try #require(bubble["light"]), "\(seedText).light")
            checked += 1
        }
        #expect(checked == cases.count, "every derivationCase must carry bubble")
        #expect(checked > 0)
    }

    // MARK: 2. Pure anchoring functions

    @Test("Anchoring: start y = -t and end y = H - t; the result changes with t")
    func anchorFollowsBubblePosition() {
        let first = OriveoUserBubble.anchor(viewportHeight: 800, bubbleTopInViewport: 120)
        #expect(first.startY == -120)
        #expect(first.endY == 680)
        let scrolled = OriveoUserBubble.anchor(viewportHeight: 800, bubbleTopInViewport: 300)
        #expect(scrolled.startY == -300)
        #expect(scrolled.endY == 500)
        #expect(scrolled.startY != first.startY)

        let points = OriveoUserBubble.unitPoints(viewportHeight: 800, bubbleTopInViewport: 120, bubbleHeight: 60)
        #expect(points.start == CGPoint(x: 0.5, y: -2))
        #expect(points.end == CGPoint(x: 0.5, y: 680.0 / 60.0))
        // With invalid geometry it falls back to the bubble itself, top → bottom
        let fallback = OriveoUserBubble.unitPoints(viewportHeight: 0, bubbleTopInViewport: 0, bubbleHeight: 60)
        #expect(fallback.start == CGPoint(x: 0.5, y: 0))
        #expect(fallback.end == CGPoint(x: 0.5, y: 1))
    }

    // MARK: 3. Production path

    @Test("Production UserMessageCell: 7 vertical stops, shadow = the bottom color at 0.16, and the anchoring updates with the bubble position")
    func productionCellUsesVerticalStops() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 800)
        window.overrideUserInterfaceStyle = .dark
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }

        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: 393, height: 100))
        root.view.addSubview(cell)
        let message = ChatMessage(
            id: UUID(), role: .user, text: "hello gradient", reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0, state: .delivered, attachments: nil, citations: nil
        )
        cell.configure(
            model: ChatCollectionProjectionBuilder.MessageRenderModel(
                messageID: message.id, message: message, presentationKind: .user,
                showMetadata: true, resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o",
                relayKind: nil, renderHint: nil, topPadding: 16,
                displayText: nil, textHash: message.text.hashValue, isStreaming: false, providerMetadataVersion: 0
            ),
            maxBubbleWidth: 320,
            parentViewController: root
        )
        OriveoDarkPaletteSwitcher.apply(.darkOcean, to: [window])
        window.layoutIfNeeded()
        cell.updateTraitsIfNeeded()
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        #expect(cell.traitCollection.oriveoDarkPalette == .darkOcean)

        let ocean = OriveoDarkPalettes.darkOcean
        let stops = cell.bubbleGradientColorsForTesting.map { OriveoDarkPalettesTests.hex(of: UIColor(cgColor: $0)) }
        #expect(stops.count == OriveoUserBubble.stopCount)
        #expect(stops == OriveoUserBubble.stops(for: .darkOcean, dark: true))
        #expect(stops.first == ocean.accent)
        #expect(stops.last == ocean.primary)
        // The old implementation was a 135-degree two-color gradient (primary → accent, top-left → bottom-right)
        #expect(stops != [ocean.primary, ocean.accent])
        let unanchored = cell.bubbleGradientPointsForTesting
        #expect(unanchored.start.x == unanchored.end.x, "the gradient should be vertical")

        let shadow = cell.bubbleShadowLayerForTesting
        #expect(shadow.shadowOpacity == 0.16)
        #expect(shadow.shadowRadius == OriveoUserBubble.shadowRadius)
        #expect(shadow.shadowOffset == CGSize(width: 0, height: OriveoUserBubble.shadowOffsetY))
        let shadowColor = try #require(shadow.shadowColor)
        #expect(OriveoDarkPalettesTests.hex(of: UIColor(cgColor: shadowColor)) == ocean.primary)

        let bubbleHeight = cell.bubbleFrameForTesting.height
        #expect(bubbleHeight > 0, "the bubble has not been laid out")
        cell.updateBubbleGradientAnchor(viewportHeight: 800, bubbleTopInViewport: 120)
        let anchored = cell.bubbleGradientPointsForTesting
        let expected = OriveoUserBubble.unitPoints(viewportHeight: 800, bubbleTopInViewport: 120, bubbleHeight: bubbleHeight)
        #expect(anchored.start == expected.start)
        #expect(anchored.end == expected.end)
        #expect(anchored.start.x == anchored.end.x)

        cell.updateBubbleGradientAnchor(viewportHeight: 800, bubbleTopInViewport: 400)
        let scrolled = cell.bubbleGradientPointsForTesting
        #expect(scrolled.start.y == -400 / bubbleHeight)
        #expect(scrolled.start != anchored.start, "the anchoring should change after scrolling")
    }
}
