import Testing
import UIKit
@testable import Oriveo

/// Pins the streaming code block card (`AssistantStreamingCodeRenderer`) and the finalized code
/// block card (`UIKitCodeBlockCard`) to the same height for the same content. The two swap places
/// when a fence closes or the message is finalized, and any height difference makes the content
/// below jump.
///
/// The original defect: the finalized card truncated on "more than 18 newlines" and ignored
/// wrapped long lines, so code with few newlines but 30+ visual lines was clamped to 392px while
/// streaming and then self-sized past 600px after the handoff. Both cards now cap on rendered
/// pixels. Each line of the sample code is about 48 characters, which wraps to two visual lines at
/// 338px, so 17 newlines is roughly 34 visual lines and covers exactly that case.
@MainActor
@Suite("Code block height parity")
struct CodeBlockHeightParityTests {
    private static let contentWidth: CGFloat = 338

    private func makeCode(lines: Int) -> String {
        (0..<lines).map { "let value\($0) = compute(\($0)) + offset // line \($0)" }.joined(separator: "\n")
    }

    private func fittingHeight(_ view: UIView, width: CGFloat) -> CGFloat {
        view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    @Test func finalized() {
        let mono = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        NSLog("[CODEBLOCK-PARITY] mono14 lineHeight=\(mono.lineHeight) ascender=\(mono.ascender) descender=\(mono.descender)")

        for lines in [5, 10, 17, 18, 19, 20, 22, 25, 40] {
            let code = makeCode(lines: lines)

            let frozen = UIKitCodeBlockCard(language: "swift", content: code, parentViewController: nil)
            let frozenContainer = UIView(frame: CGRect(x: 0, y: 0, width: Self.contentWidth, height: 4000))
            frozenContainer.addSubview(frozen)
            frozen.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                frozen.topAnchor.constraint(equalTo: frozenContainer.topAnchor),
                frozen.leadingAnchor.constraint(equalTo: frozenContainer.leadingAnchor),
                frozen.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            ])
            frozenContainer.layoutIfNeeded()
            let fH = fittingHeight(frozen, width: Self.contentWidth)

            let streaming = AssistantStreamingCodeRenderer()
            let streamContainer = UIView(frame: CGRect(x: 0, y: 0, width: Self.contentWidth, height: 4000))
            streamContainer.addSubview(streaming.view)
            streaming.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                streaming.view.topAnchor.constraint(equalTo: streamContainer.topAnchor),
                streaming.view.leadingAnchor.constraint(equalTo: streamContainer.leadingAnchor),
                streaming.view.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            ])
            streamContainer.layoutIfNeeded()
            streaming.update(language: "swift", code: code)
            streamContainer.layoutIfNeeded()
            let sH = fittingHeight(streaming.view, width: Self.contentWidth)

            NSLog("[CODEBLOCK-PARITY] lines=\(lines) streaming=\(sH) frozen=\(fH) delta=\(fH - sH)")
            #expect(abs(fH - sH) <= 2.0,
                    Comment(rawValue: "lines=\(lines): the finalized card is \(fH)pt but the streaming card is \(sH)pt (delta=\(fH - sH)); the handoff would shift everything below it"))
        }
    }
}
