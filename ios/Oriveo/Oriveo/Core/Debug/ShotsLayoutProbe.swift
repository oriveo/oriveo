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
    /// `supportsMultipleWindows` from the SwiftUI environment, written by `AppRootView`; nil = no window has reported yet.
    static var supportsMultipleWindows: Bool?

    /// The latest keyboard frame (screen coordinates); nil = no keyboard, or it is hidden.
    private static var keyboardFrameInScreen: CGRect?
    private static var keyboardObservers: [NSObjectProtocol] = []

    static func runIfRequested(page: String) async {
        guard CommandLine.arguments.contains("-SHOTS_PROBE") else { return }
        observeKeyboard()
        let start = Date()
        var lastSignature = ""
        var stableSince = Date()
        var nodes: [Node] = []
        var timedOut = true
        let scrollToBottom = MemoryShots.isScrollToBottomRequested
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 250_000_000)
            // -SHOTS_SCROLL_BOTTOM: scroll to the bottom once the page has content; if it moved again, restart the stability window and write the layout tree only after scrolling settles
            if scrollToBottom, !nodes.isEmpty, MemoryShots.scrollListToBottom() {
                lastSignature = ""
                stableSince = Date()
                nodes = collect()
                continue
            }
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

    private static func observeKeyboard() {
        guard keyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        keyboardObservers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { keyboardFrameInScreen = frame }
        })
        keyboardObservers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { keyboardFrameInScreen = nil }
        })
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
        /// The UIKit system bar container (class name) the node sits in; nil means the app placed it.
        /// Controls the system places (such as the `.searchable` button in the bottom toolbar) follow the
        /// bar's own rules, so they do not count as intruding into the safe area.
        var systemBar: String?

        var signature: String {
            "\(role)|\(text)|\(value)|\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
        }
    }

    /// The visible area used to filter nodes: the key window's frame in screen coordinates.
    /// Not `UIScreen.main` — on a folding device it reports the folded value (466pt while the
    /// unfolded Duo window is 951pt), and filtering with it drops everything right of 466pt.
    private static var probeWindow: UIWindow?

    private static func collect() -> [Node] {
        var nodes: [Node] = []
        probeWindow = keyWindow()
        for window in appWindows() {
            // When a sheet / full-screen page is presented, only the topmost layer is considered: the covered pages are not exported on the other platforms either
            let root: UIView = topPresented(in: window)?.view ?? window
            visit(root, clip: root.convert(root.bounds, to: nil), systemBar: nil, into: &nodes, depth: 0)
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

    private static func keyWindow() -> UIWindow? {
        let windows = appWindows()
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    /// accessibilityFrame is in screen coordinates while the clip rect, bars and keyboard are in window coordinates; in a windowed iPad the window origin is not the screen origin,
    /// so without conversion they never intersect (every node is clipped away). Nodes are converted to key window coordinates before comparing and output.
    private static func windowFrame(_ screenFrame: CGRect) -> CGRect {
        guard let window = probeWindow, let space = window.windowScene?.screen.coordinateSpace else { return screenFrame }
        return window.convert(screenFrame, from: space)
    }

    private static func topPresented(in window: UIWindow) -> UIViewController? {
        var top = window.rootViewController?.presentedViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top?.isBeingDismissed == true ? nil : top
    }

    /// clip = the visible area on screen of the ancestor view that clips content (a scroll view / the sheet itself); parts scrolled out of it are not "on screen".
    private static func visit(_ object: NSObject, clip: CGRect, systemBar: String?, into nodes: inout [Node], depth: Int) {
        guard depth < 80 else { return }
        var clip = clip
        var systemBar = systemBar
        if let view = object as? UIView {
            if view.isHidden || view.alpha < 0.01 { return }
            if systemBar == nil, let name = systemBarClassName(view) { systemBar = name }
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
                node.systemBar = systemBar
                nodes.append(node)
            }
            return
        }
        for child in children(of: object) {
            visit(child, clip: clip, systemBar: systemBar, into: &nodes, depth: depth + 1)
        }
    }

    /// UIKit's own bar containers (navigation bar, toolbar, tab bar, the floating bars since iOS 26, and
    /// so on): the class name starts with UI or _UI and contains Bar.
    private static func systemBarClassName(_ view: UIView) -> String? {
        let name = String(describing: type(of: view))
        guard name.hasPrefix("UI") || name.hasPrefix("_UI"), name.contains("Bar") else { return nil }
        return name
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
        let frame = windowFrame(object.accessibilityFrame)
        guard frame.width > 0.5, frame.height > 0.5 else { return nil }
        guard probeWindow.map({ frame.intersects($0.bounds) }) ?? true else { return nil }
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

    // MARK: - Wide-screen layout

    private static func sizeClassName(_ value: UIUserInterfaceSizeClass?) -> String {
        switch value {
        case .compact: "compact"
        case .regular: "regular"
        default: "unspecified"
        }
    }

    /// Frame and orientation of each system bar (navigation bar / tab bar / toolbar). On a Duo the
    /// system stands the bars up along the side, so the orientation comes from geometry (taller than
    /// wide means vertical) rather than an API that only exists from the 27.1 SDK; 27.0 still builds.
    /// Only the outermost match is recorded: subviews inside a bar often carry the same words.
    private static func collectBars(in window: UIWindow) -> [[String: Any]] {
        var bars: [[String: Any]] = []
        func visit(_ view: UIView, depth: Int) {
            guard depth < 60, !view.isHidden, view.alpha > 0.01 else { return }
            let name = String(describing: type(of: view))
            let kind: String? = name.contains("TabBar") ? "tab"
                : name.contains("NavigationBar") ? "nav"
                : name.contains("Toolbar") ? "toolbar"
                : nil
            let frame = view.convert(view.bounds, to: window)
            if let kind, frame.width > 1, frame.height > 1, frame.intersects(window.bounds) {
                bars.append([
                    "kind": kind,
                    "class": name,
                    "axis": frame.height > frame.width ? "vertical" : "horizontal",
                    "rect": rectDictionary(frame),
                ])
                return
            }
            for child in view.subviews { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        return bars
    }

    /// The actual width of each column of a split container (a NavigationSplitView is a
    /// UISplitViewController underneath).
    private static func collectSplitColumns(in window: UIWindow) -> [[String: Any]] {
        var result: [[String: Any]] = []
        func visit(_ controller: UIViewController, depth: Int) {
            guard depth < 40 else { return }
            if let split = controller as? UISplitViewController {
                let columns: [[String: Any]] = split.viewControllers.compactMap { child in
                    guard child.isViewLoaded, child.view.window != nil, !child.view.isHidden else { return nil }
                    return [
                        "rect": rectDictionary(child.view.convert(child.view.bounds, to: window)),
                        // HIG: in a split view the detail column's bars run vertically and the sidebar's horizontally, so read each column
                        "verticalBarEdge": verticalBarEdgeName(child.traitCollection),
                    ]
                }
                result.append(["collapsed": split.isCollapsed, "columns": columns])
            }
            for child in controller.children { visit(child, depth: depth + 1) }
            if let presented = controller.presentedViewController, presented.presentingViewController === controller {
                visit(presented, depth: depth + 1)
            }
        }
        if let root = window.rootViewController { visit(root, depth: 0) }
        return result
    }

    /// Each navigation controller's bar state and its top page's safe area: once the system navigation bar is shown for vertical bars on the Duo,
    /// how much room the page top gives up, and to what, cannot be told from the elements' y alone.
    private static func collectNavigationControllers(in window: UIWindow) -> [[String: Any]] {
        var result: [[String: Any]] = []
        func visit(_ controller: UIViewController, depth: Int) {
            guard depth < 40 else { return }
            if let nav = controller as? UINavigationController, nav.isViewLoaded, nav.view.window != nil {
                let bar = nav.navigationBar
                var entry: [String: Any] = [
                    "barHidden": nav.isNavigationBarHidden || bar.isHidden,
                    "barRect": rectDictionary(bar.convert(bar.bounds, to: window)),
                    "depth": nav.viewControllers.count,
                ]
                if let top = nav.topViewController, top.isViewLoaded {
                    let insets = top.view.safeAreaInsets
                    entry["topSafe"] = ["top": insets.top, "bottom": insets.bottom, "left": insets.left, "right": insets.right]
                    entry["topRect"] = rectDictionary(top.view.convert(top.view.bounds, to: window))
                }
                result.append(entry)
            }
            for child in controller.children { visit(child, depth: depth + 1) }
            if let presented = controller.presentedViewController, presented.presentingViewController === controller {
                visit(presented, depth: depth + 1)
            }
        }
        if let root = window.rootViewController { visit(root, depth: 0) }
        return result
    }

    /// Fold regions (division) and occluded regions (occlusion, such as an under-display camera) in window coordinates, inactive ones included.
    /// Half-folded and fully open windows have the same size; only the division's `isActive` tells the two postures apart. Built with the 27.0 SDK or running below iOS 27.1 it outputs an empty array.
    private static func collectReservedRegions(in window: UIWindow) -> [[String: Any]] {
        #if !ORIVEO_SDK_BEFORE_27_1
        if #available(iOS 27.1, *) {
            let kinds: [(String, UIView.ReservedRegion.Kind)] = [("division", .division), ("occlusion", .occlusion)]
            return kinds.flatMap { name, kind in
                window.reservedRegions(kind: kind, options: .includeInactive).map { region -> [String: Any] in
                    [
                        "kind": name,
                        "active": region.isActive,
                        "rect": rectDictionary(region.frame),
                        "margins": ["top": region.margins.top, "left": region.margins.left, "bottom": region.margins.bottom, "right": region.margins.right],
                    ]
                }
            }
        }
        #endif
        return []
    }

    /// The system's preferred vertical bar edge (`UITraitCollection.verticalBarEdge`): leading / trailing / none,
    /// regardless of whether a vertical bar is visible right now. Built with the 27.0 SDK or below iOS 27.1 it records unavailable.
    private static func verticalBarEdgeName(_ traits: UITraitCollection?) -> String {
        #if !ORIVEO_SDK_BEFORE_27_1
        if #available(iOS 27.1, *), let traits {
            switch traits.verticalBarEdge {
            case .leading: return "leading"
            case .trailing: return "trailing"
            default: return "none"
            }
        }
        #endif
        return "unavailable"
    }

    private static func rectDictionary(_ rect: CGRect) -> [String: CGFloat] {
        ["x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height]
    }

    private static func cornerAdaptedSafeArea(in window: UIWindow) -> Any {
        guard #available(iOS 26, *) else { return NSNull() }
        func dictionary(_ insets: UIEdgeInsets) -> [String: CGFloat] {
            ["top": insets.top, "bottom": insets.bottom, "left": insets.left, "right": insets.right]
        }
        return [
            "horizontal": dictionary(window.edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))),
            "vertical": dictionary(window.edgeInsets(for: .safeArea(cornerAdaptation: .vertical))),
            "marginsHorizontal": dictionary(window.edgeInsets(for: .margins(cornerAdaptation: .horizontal))),
            "marginsVertical": dictionary(window.edgeInsets(for: .margins(cornerAdaptation: .vertical))),
        ]
    }

    // MARK: - Output

    private static func write(page: String, nodes: [Node], timedOut: Bool, waited: TimeInterval) {
        let window = keyWindow()
        let insets = window?.safeAreaInsets ?? .zero
        // `screen` keeps its cross-platform meaning, "the area the app can draw in", so it is the window
        // size; the physical screen is recorded separately as `display`.
        let windowSize = window?.bounds.size ?? .zero
        let display = window?.windowScene?.screen.bounds.size ?? .zero
        let traits = window?.traitCollection
        let payload: [String: Any] = [
            "end": "ios",
            "page": page,
            "units": "pt",
            "ready": !timedOut,
            "waitedMs": Int(waited * 1000),
            "screen": ["w": windowSize.width, "h": windowSize.height],
            "display": ["w": display.width, "h": display.height],
            "sizeClass": ["h": sizeClassName(traits?.horizontalSizeClass), "v": sizeClassName(traits?.verticalSizeClass)],
            "safe": ["top": insets.top, "bottom": insets.bottom, "left": insets.left, "right": insets.right],
            "verticalBarEdge": verticalBarEdgeName(traits),
            // The safe area after the system makes room for screen / window corners (iOS 26 layout region); with the status bar on a side the top safe area is 0 and only this covers the corner
            "cornerSafe": window.map(cornerAdaptedSafeArea(in:)) ?? NSNull(),
            "bars": window.map(collectBars(in:)) ?? [],
            "split": window.map(collectSplitColumns(in:)) ?? [],
            "navigation": window.map(collectNavigationControllers(in:)) ?? [],
            "reserved": window.map(collectReservedRegions(in:)) ?? [],
            // The keyboard frame in window coordinates; null when it does not intersect the window (with a hardware keyboard only an off-screen placeholder remains)
            "keyboard": window.flatMap { window -> [String: CGFloat]? in
                guard let screenFrame = keyboardFrameInScreen else { return nil }
                let frame = window.convert(screenFrame, from: window.windowScene?.screen.coordinateSpace ?? window.coordinateSpace)
                return frame.intersects(window.bounds) ? rectDictionary(frame) : nil
            } ?? NSNull(),
            "supportsMultipleWindows": supportsMultipleWindows.map { $0 as Any } ?? NSNull(),
            "supportsMultipleScenes": UIApplication.shared.supportsMultipleScenes,
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
                if let systemBar = node.systemBar { item["systemBar"] = systemBar }
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
