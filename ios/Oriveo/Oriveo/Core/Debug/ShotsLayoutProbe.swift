#if DEBUG
import UIKit

/// Layout probe for the screenshot tool `scripts/shots.sh` (DEBUG only).
///
/// When launched with `-SHOTS_PROBE`, after `-AUTO_OPEN_PAGE` has laid out the page it polls the accessibility tree and counts as "ready" only after 1.5 seconds without change,
/// then writes the visible elements (text, screen frame, role, whether likely truncated, whether secret) to `tmp/shots-probe/<page name>.json`.
/// The script uses the appearance of this file as the screenshot cue instead of a fixed wait; the same JSON also feeds the rule checks, so no one needs to look at images.
@MainActor
enum ShotsLayoutProbe {
    private static let stableInterval: TimeInterval = 1.5
    private static let timeout: TimeInterval = 25

    static func runIfRequested(page: String) async {
        guard CommandLine.arguments.contains("-SHOTS_PROBE") else { return }
        let start = Date()
        var lastSignature = ""
        var stableSince = Date()
        var nodes: [Node] = []
        var timedOut = true
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 250_000_000)
            nodes = collect()
            // Digits are wiped out: a running timer must not keep the page from ever becoming "ready"
            let signature = nodes.map(\.signature).joined(separator: "\n").replacingOccurrences(of: "[0-9]", with: "#", options: .regularExpression)
            if signature != lastSignature || nodes.isEmpty {
                lastSignature = signature
                stableSince = Date()
                continue
            }
            if Date().timeIntervalSince(stableSince) >= stableInterval {
                timedOut = false
                break
            }
        }
        write(page: page, nodes: nodes, timedOut: timedOut, waited: Date().timeIntervalSince(start))
    }

    // MARK: - Collection

    struct Node {
        var text: String
        var value: String
        var role: String
        var frame: CGRect
        var secure: Bool
        var editable: Bool
        var truncated: Bool?

        var signature: String {
            "\(role)|\(text)|\(value)|\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
        }
    }

    private static func collect() -> [Node] {
        var nodes: [Node] = []
        for window in appWindows() {
            // When a sheet / full-screen page is presented, only the topmost layer is considered: the covered pages are not exported on the other platforms either
            let root: UIView = topPresented(in: window)?.view ?? window
            visit(root, clip: root.convert(root.bounds, to: nil), into: &nodes, depth: 0)
        }
        return nodes
    }

    /// Keyboard / text-effects windows are not page content: the keys would drown out the text contrast.
    private static func appWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { window in
                let name = String(describing: type(of: window))
                return !window.isHidden && window.alpha > 0.01 && !name.contains("Keyboard") && !name.contains("TextEffects")
            }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
    }

    private static func topPresented(in window: UIWindow) -> UIViewController? {
        var top = window.rootViewController?.presentedViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top?.isBeingDismissed == true ? nil : top
    }

    /// clip = the visible area on screen of the ancestor view that clips content (a scroll view / the sheet itself); parts scrolled out of it are not "on screen".
    private static func visit(_ object: NSObject, clip: CGRect, into nodes: inout [Node], depth: Int) {
        guard depth < 80 else { return }
        var clip = clip
        if let view = object as? UIView {
            if view.isHidden || view.alpha < 0.01 { return }
            if view.clipsToBounds || view is UIScrollView {
                clip = clip.intersection(view.convert(view.bounds, to: nil))
                if clip.isNull || clip.isEmpty { return }
            }
        }
        if object.accessibilityElementsHidden { return }
        if object.isAccessibilityElement {
            if var node = makeNode(object) {
                let visible = node.frame.intersection(clip)
                guard !visible.isNull, visible.width > 0.5, visible.height > 0.5 else { return }
                node.frame = visible
                nodes.append(node)
            }
            return
        }
        for child in children(of: object) {
            visit(child, clip: clip, into: &nodes, depth: depth + 1)
        }
    }

    private static func children(of object: NSObject) -> [NSObject] {
        if let elements = object.accessibilityElements as? [NSObject], !elements.isEmpty {
            return elements
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            return (0 ..< count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = object as? UIView {
            return view.subviews
        }
        return []
    }

    private static func makeNode(_ object: NSObject) -> Node? {
        let frame = object.accessibilityFrame
        guard frame.width > 0.5, frame.height > 0.5 else { return nil }
        let screen = UIScreen.main.bounds
        guard frame.intersects(screen) else { return nil }
        let label = object.accessibilityLabel ?? ""
        let value = object.accessibilityValue ?? ""
        let traits = object.accessibilityTraits
        // Private trait bit 0x40000 = text input; a SwiftUI input field is not necessarily a UITextField subclass.
        let textEntry = UIAccessibilityTraits(rawValue: 1 << 18)
        let editable = object is UITextField || object is UITextView || traits.contains(textEntry)
        let secure = (object as? UITextField)?.isSecureTextEntry == true || isMasked(value)
        guard !label.isEmpty || !value.isEmpty || editable else { return nil }
        let role: String
        if editable {
            role = "textField"
        } else if traits.contains(.button) || traits.contains(.link) {
            role = "button"
        } else if traits.contains(.header) {
            role = "header"
        } else if traits.contains(.image), label.isEmpty == false, traits.contains(.staticText) == false {
            role = "image"
        } else {
            role = "text"
        }
        let truncated = role == "text" || role == "header" ? estimateTruncated(label, in: frame) : nil
        return Node(text: label, value: value, role: role, frame: frame, secure: secure, editable: editable, truncated: truncated)
    }

    private static func isMasked(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0 == "•" || $0 == "●" }
    }

    /// SwiftUI's Text does not expose its layout result, so we can only estimate: infer the font size and line count from the frame height, then measure how many lines the full text needs.
    /// Only judge truncation when "no candidate font size fits"; better to miss than to misreport. The result is marked truncated, and the rule side treats it as "suspected".
    private static func estimateTruncated(_ text: String, in frame: CGRect) -> Bool? {
        guard !text.isEmpty, frame.width > 4 else { return nil }
        let sizes: [CGFloat] = [11, 12, 13, 15, 16, 17, 20, 22, 28, 34]
        var verdicts: [Bool] = []
        for size in sizes {
            for weight in [UIFont.Weight.regular, .semibold] {
                let font = UIFont.systemFont(ofSize: size, weight: weight)
                let lines = frame.height / font.lineHeight
                let rounded = lines.rounded()
                guard rounded >= 1, abs(lines - rounded) < 0.15 else { continue }
                let needed = (text as NSString).boundingRect(
                    with: CGSize(width: frame.width + 1, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    attributes: [.font: font],
                    context: nil
                ).height / font.lineHeight
                verdicts.append(needed.rounded() > rounded)
            }
        }
        guard !verdicts.isEmpty else { return nil }
        return verdicts.allSatisfy { $0 }
    }

    // MARK: - Output

    private static func write(page: String, nodes: [Node], timedOut: Bool, waited: TimeInterval) {
        let window = appWindows().first { $0.isKeyWindow } ?? appWindows().first
        let insets = window?.safeAreaInsets ?? .zero
        let screen = UIScreen.main.bounds
        let payload: [String: Any] = [
            "end": "ios",
            "page": page,
            "units": "pt",
            "ready": !timedOut,
            "waitedMs": Int(waited * 1000),
            "screen": ["w": screen.width, "h": screen.height],
            "safe": ["top": insets.top, "bottom": insets.bottom],
            "nodes": nodes.map { node -> [String: Any] in
                var item: [String: Any] = [
                    "text": node.text,
                    "role": node.role,
                    "rect": ["x": node.frame.minX, "y": node.frame.minY, "w": node.frame.width, "h": node.frame.height],
                    "secure": node.secure,
                    "editable": node.editable,
                ]
                if !node.value.isEmpty { item["value"] = node.value }
                if let truncated = node.truncated { item["truncated"] = truncated }
                return item
            },
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shots-probe", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            // Write to a temporary name and then rename: the script treats the file appearing as the ready signal and must not read a half-written file.
            let target = directory.appendingPathComponent("\(page).json")
            let partial = directory.appendingPathComponent("\(page).json.partial")
            try data.write(to: partial, options: .atomic)
            _ = try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
            print("[ShotsProbe] \(timedOut ? "timeout" : "ready") \(page) \(nodes.count) nodes")
        } catch {
            print("[ShotsProbe] write failed for \(page): \(error)")
        }
    }
}
#endif
