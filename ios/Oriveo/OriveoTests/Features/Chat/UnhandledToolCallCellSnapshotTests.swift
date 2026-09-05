import Testing
import UIKit
@testable import Oriveo

/// Renders the real production `AssistantMessageCell` carrying the "the model asked for tool X,
/// this connection does not support it" notice into a window, and can export it as a PNG in light
/// appearance. The app theme does not use dynamic trait colours, so a dark-appearance reference has
/// to be captured on a device.
///
/// The PNG is written only when `ORIVEO_TOOLCALL_SNAPSHOT_DIR` is set; a normal run just asserts
/// that the cell renders the notice.
@Suite("Unhandled tool call notice in a production cell")
@MainActor
struct UnhandledToolCallCellSnapshotTests {
    private func makeModel(text: String, calls: [UnhandledToolCall]) -> ChatCollectionProjectionBuilder.MessageRenderModel {
        let id = UUID()
        var message = ChatMessage(
            id: id, role: .assistant, text: text, reasoningText: nil,
            providerKind: .relay, providerName: "My Relay", modelName: "qwen3-32b",
            estimatedCost: 0, state: .delivered, attachments: nil, citations: nil
        )
        message.unhandledToolCalls = calls
        return ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: id, message: message, presentationKind: .assistant,
            showMetadata: true, resolvedProviderName: "My Relay", resolvedModelName: "qwen3-32b",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: text.hashValue,
            isStreaming: false, providerMetadataVersion: 0
        )
    }

    private func render(style: UIUserInterfaceStyle, expanded: Bool) -> (UIImage, UIKitUnhandledToolCallView?) {
        let width: CGFloat = 390
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        window.overrideUserInterfaceStyle = style
        let parent = UIViewController()
        window.rootViewController = parent
        window.makeKeyAndVisible()

        let cell = AssistantMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        cell.overrideUserInterfaceStyle = style
        cell.configure(
            model: makeModel(
                text: "",
                calls: [
                    UnhandledToolCall(id: "call_1", name: "get_weather", arguments: #"{"city":"Melbourne","unit":"celsius"}"#),
                    UnhandledToolCall(id: "call_2", name: "web_search", arguments: #"{"query":"Melbourne weather today","num_results":5}"#),
                ]
            ),
            parentViewController: parent, onContentHeightDidChange: nil, onRetry: nil, onContinue: nil
        )
        parent.view.addSubview(cell)
        let card = firstDescendant(of: cell, as: UIKitUnhandledToolCallView.self)
        if expanded, let card, let control = firstDescendant(of: card, as: UIControl.self) {
            control.sendActions(for: .touchUpInside)
        }
        let size = cell.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        cell.frame = CGRect(x: 0, y: 0, width: width, height: max(size.height, 80))
        cell.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: cell.bounds.size).image { _ in
            cell.drawHierarchy(in: cell.bounds, afterScreenUpdates: true)
        }
        return (image, card)
    }

    private func firstDescendant<T: UIView>(of view: UIView, as type: T.Type) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = firstDescendant(of: sub, as: type) { return hit }
        }
        return nil
    }

    @Test("Renders Card And Exports Snapshots")
    func rendersCardAndExportsSnapshots() throws {
        let outDir = ProcessInfo.processInfo.environment["ORIVEO_TOOLCALL_SNAPSHOT_DIR"]
        for (style, name) in [(UIUserInterfaceStyle.light, "light")] {
            for expanded in [false, true] {
                let (image, card) = render(style: style, expanded: expanded)
                #expect(card != nil, "the production cell did not mount UIKitUnhandledToolCallView")
                #expect(image.size.height > 60)
                guard let outDir, let data = image.pngData() else { continue }
                let url = URL(fileURLWithPath: outDir)
                    .appendingPathComponent("ios-unhandled-toolcall-\(name)-\(expanded ? "expanded" : "collapsed").png")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        }
    }
}
