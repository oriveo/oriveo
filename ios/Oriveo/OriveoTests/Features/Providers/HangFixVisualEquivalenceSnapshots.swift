import SwiftUI
import Testing
import UIKit
@testable import Oriveo

/// Visual equivalence evidence for a hang fix: render the same input to a PNG before and after the change, and compare pixel by pixel.
/// Skipped normally; writes images when `TEST_RUNNER_ORIVEO_SNAPSHOT_DIR=<directory>` is set.
@MainActor
@Suite(
    "Hang fix visual equivalence snapshots",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ORIVEO_SNAPSHOT_DIR"] != nil),
    .sharedProcessState
)
struct HangFixVisualEquivalenceSnapshots {
    private var outputDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORIVEO_SNAPSHOT_DIR"]!)
    }

    private func firstScrollView(_ view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(subview) { return found }
        }
        return nil
    }

    private func capture<V: View>(
        _ name: String,
        width: CGFloat,
        height: CGFloat = 844,
        dark: Bool,
        scrollPages: Int = 1,
        settle: TimeInterval = 1.2,
        @ViewBuilder content: () -> V
    ) throws {
        // The language preference is a persisted global key: if it is not pinned, the two captures differ over the whole image because the copy language differs;
        // restore it afterwards so that later tests are not pinned to Chinese either.
        var preference = AppPreferencesStore.load()
        let originalLanguage = preference.language
        preference.language = .chineseSimplified
        AppPreferencesStore.save(preference)
        L10n.invalidateCache()
        defer {
            var restore = AppPreferencesStore.load()
            restore.language = originalLanguage
            AppPreferencesStore.save(restore)
            L10n.invalidateCache()
        }

        let host = UIHostingController(rootView: content())
        // A UIWindow not attached to a scene only lays out and is not put on screen, and drawHierarchy would give an entirely blank image.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        pumpMainRunLoop(settle)

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let scrollView = firstScrollView(host.view)
        for page in 0..<scrollPages {
            if let scrollView, page > 0 {
                let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                let target = min(CGFloat(page) * (height - 120), maxOffset)
                scrollView.contentOffset = CGPoint(x: 0, y: target)
                scrollView.layoutIfNeeded()
                pumpMainRunLoop(0.4)
            }
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let suffix = dark ? "dark" : "light"
            let url = outputDirectory.appendingPathComponent("\(name)-w\(Int(width))-\(suffix)-p\(page).png")
            try #require(image.pngData()).write(to: url)
        }
        window.isHidden = true
        window.rootViewController = nil
    }

    private func metadataJSON(ids: [String]) -> String {
        let resolve = ids.map { "\"\($0)\":\"\($0)\"" }.joined(separator: ",")
        let models = ids.enumerated().map { index, id in
            let capabilities: String
            switch index % 4 {
            case 0: capabilities = "[\"text\", \"web\", \"vision_input\", \"tool_call\", \"file\"]"
            case 1: capabilities = "[\"text\", \"vision_input\"]"
            case 2: capabilities = "[\"text\", \"tool_call\", \"web\"]"
            default: capabilities = "[\"text\"]"
            }
            return """
            "\(id)": {
              "canonicalModelId": "\(id)",
              "transport": "openai_responses",
              "capabilities": \(capabilities),
              "contextLength": \(index % 3 == 0 ? 1_000_000 : 128_000),
              "maxOutputTokens": 16384,
              "pricing": {"promptPerToken": 0.0000025, "completionPerToken": 0.00001},
              "pricingUnit": "per_token"
            }
            """
        }.joined(separator: ",")
        return """
        {"version": 1, "providers": {"openAI": {"resolveMap": {\(resolve)}, "models": {\(models)}}}}
        """
    }

    private func catalogModels(prefix: String, count: Int, grouped: Bool) -> [AIModel] {
        let capabilitySets: [[ModelCapability]] = [
            [.text, .web, .image, .toolCall, .file, .reasoning],
            [.text, .image],
            [.text, .toolCall, .web],
            [.text],
        ]
        return (0..<count).map { index in
            TestFactories.makeModel(
                id: "\(prefix)-\(index)",
                name: index % 5 == 0 ? "\(prefix.uppercased()) Model \(index) With A Considerably Longer Display Name" : "\(prefix.uppercased())-\(index)",
                capabilities: capabilitySets[index % capabilitySets.count],
                isAvailable: index % 7 != 6,
                isDefault: index == 1,
                priceTier: index % 4 == 3 ? "Free" : "",
                groupKey: grouped ? "vendor-\(index % 3)" : nil,
                groupName: grouped ? "Vendor \(index % 3)" : nil,
                promptPrice: index % 4 == 3 ? nil : 0.0000025,
                completionPrice: index % 4 == 3 ? nil : 0.00001
            )
        }
    }

    private func withState(_ providers: [Provider], _ body: (AppState) throws -> Void) rethrows {
        let state = AppState(seedDemoData: false, sessionUID: "hang-snapshot-\(UUID().uuidString)")
        defer {
            state.flushConversationPersistQueue()
            DatabaseManager.shared.close()
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: state.sessionPartitionUID))
        }
        state.providers = providers
        try body(state)
    }

    @Test("provider detail page: official provider + relay")
    func providerDetailPages() async throws {
        let catalog = catalogModels(prefix: "gpt", count: 24, grouped: true)
        await MetadataClient.shared.resetForTesting()
        try await MetadataClient.shared.loadForTesting(json: metadataJSON(ids: catalog.map(\.id)), metadataETag: "snapshot-etag")

        let official = TestFactories.makeProvider(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            kind: .openAI,
            models: Array(catalog.prefix(8))
        )
        try withState([official]) { state in
            for dark in [false, true] {
                for width in [390.0, 320.0] {
                    try capture("detail-openai", width: width, dark: dark, scrollPages: 4) {
                        ProviderDetailView(providerID: official.id).environment(state)
                    }
                }
            }
        }

        let relayCatalog = catalogModels(prefix: "relay", count: 12, grouped: false)
        var missing = TestFactories.makeModel(id: "relay-missing", name: "relay-missing", capabilities: [.text, .web])
        missing.isManual = false
        let relay = TestFactories.makeProvider(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            kind: .relay,
            models: Array(relayCatalog.prefix(4)) + [missing],
            catalogModels: relayCatalog,
            baseURLText: "https://relay.example.com/v1"
        )
        try withState([relay]) { state in
            for dark in [false, true] {
                try capture("detail-relay", width: 390, dark: dark, scrollPages: 3) {
                    ProviderDetailView(providerID: relay.id).environment(state)
                }
            }
        }
        await MetadataClient.shared.resetForTesting()
    }

    @Test("model library group expanded state")
    func catalogGroupsExpanded() async throws {
        let catalog = catalogModels(prefix: "lib", count: 12, grouped: true)
        let provider = TestFactories.makeProvider(kind: .openAI, models: Array(catalog.prefix(1)))
        let groups = (0..<3).map { group in
            ProviderCatalogGroup(
                id: "vendor-\(group)",
                title: "Vendor \(group)",
                models: catalog.filter { $0.groupKey == "vendor-\(group)" }
            )
        }
        for dark in [false, true] {
            for width in [390.0, 320.0, 280.0] {
                try capture("catalog-groups", width: width, dark: dark, scrollPages: 2) {
                    ScrollView {
                        // The host's only lazy layer: the list emits only sibling group headers and rows, isomorphic to the detail page / home.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ProviderCatalogGroupList(
                                provider: provider,
                                capabilityEvidenceRevision: 1,
                                groups: groups,
                                searchText: "",
                                expandedGroupIDs: ["vendor-0", "vendor-2"],
                                coordinateSpaceName: nil,
                                onToggleGroup: { _ in },
                                onAddModel: { _, _ in }
                            )
                        }
                        .providerPanelGroupSurfaces()
                        .padding(16)
                    }
                    .oriveoScreenBackground()
                }
            }
        }
    }

    @Test("model picker")
    func modelPicker() async throws {
        let kinds: [ProviderKind] = [.openAI, .openRouter, .anthropic]
        let providers = kinds.enumerated().map { offset, kind in
            TestFactories.makeProvider(
                id: UUID(uuidString: "3333333\(offset)-3333-3333-3333-333333333333")!,
                kind: kind,
                models: catalogModels(prefix: kind.rawValue, count: 6, grouped: false).map { model in
                    var model = model
                    model.contextLength = 128_000
                    return model
                }
            )
        }
        try withState(providers) { state in
            for dark in [false, true] {
                for width in [390.0, 320.0, 280.0] {
                    try capture("picker", width: width, dark: dark, scrollPages: 2) {
                        ModelPickerSheet(
                            context: .chat(conversationID: nil),
                            presentation: ModelPickerPresentationSnapshot(
                                context: .chat(conversationID: nil),
                                providers: state.providers,
                                providersVersion: state.providersVersion,
                                currentProviderID: providers[0].id,
                                currentModel: providers[0].models[0]
                            ),
                            onSelect: { _ in }
                        )
                        .environment(state)
                    }
                }
            }
        }
    }

    @Test("chat completed-state table card")
    func chatTableCard() throws {
        let header = "| Model | Context | Input | Output | Notes |\n|:---|:---:|---:|---:|---|"
        let rows = (0..<12).map { index in
            "| **model-\(index)** | 128K | $2.50 | $10.00 | Supports `tools`, vision and [long context](https://example.com) \(index) |"
        }
        let lines = header.components(separatedBy: "\n") + rows
        let narrow = "| A | B |\n|---|---|\n| short | cell |\n| \u{4E2D}\u{6587}\u{5185}\u{5BB9} | \u{5BF9}\u{9F50} |".components(separatedBy: "\n")
        // Inline formulas + wrapping + fractional column widths stretched proportionally at a narrow width: a placeholder exists only after the change, so this group compares the placeholder image with the final image of the same round.
        let mathLatex = [#"x^{2}+y_{1}"#, #"\frac{a}{b}"#]
        let math = [
            "| \u{516C}\u{5F0F} | \u{8BF4}\u{660E} | \u{503C} |",
            "|---|:---:|---:|",
            "| $\(mathLatex[0])$ | \u{5E73}\u{65B9}\u{548C} | 1.5 |",
            "| $\(mathLatex[1])$ | fraction \u{4E2D}\u{6587}\u{6DF7}\u{6392} long text that wraps across lines | 2 |",
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                for latex in mathLatex {
                    _ = LatexImageCache.image(latex: latex, fontSize: 14 * 1.1, textColor: UIColor(OriveoTheme.Palette.textPrimary), inline: true)
                }
            }
        }
        let scheduler = TableCardCellUpgradeScheduler.shared
        defer {
            scheduler.isPausedForTesting = false
        }
        for dark in [false, true] {
            for (name, tableLines) in [("wide", lines), ("narrow", narrow), ("math", math)] {
                for width in [350.0, 240.0] {
                    // chat-table: the final state with every cell upgraded to a UITextView; chat-table-placeholder: no cell upgraded,
                    // only the first-frame placeholder. Both must be pixel-identical to the whole-table UITextView before the change.
                    for placeholdersOnly in [false, true] {
                        scheduler.isPausedForTesting = placeholdersOnly
                        let prefix = placeholdersOnly ? "chat-table-placeholder" : "chat-table"
                        try capture("\(prefix)-\(name)", width: width + 32, height: 900, dark: dark, settle: 1.2) {
                            ChatTableCardSnapshotHost(lines: tableLines, width: width, placeholdersOnly: placeholdersOnly)
                                .padding(16)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(OriveoTheme.Palette.backgroundBase)
                        }
                    }
                }
            }
        }
        // The formula image colors are baked into the image at render time: build the card under the opposite appearance, mount it in a window to commit, return it to the pool, then take it back under this appearance; it must be pixel-identical to chat-table-math.
        scheduler.isPausedForTesting = false
        for dark in [false, true] {
            for width in [350.0, 240.0] {
                try capture("chat-table-other-style-recycle-math", width: width + 32, height: 900, dark: dark, settle: 1.2) {
                    ChatTableCardSnapshotHost(lines: math, width: width, otherStyleRecycleDark: dark)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(OriveoTheme.Palette.backgroundBase)
                }
            }
        }
    }

    @Test("chat completed-state code block")
    func chatCodeBlockCard() throws {
        let content = """
        func greet(_ name: String) -> String {
            return "hello, \\(name)"
        }
        """
        // The three sources must be pixel-identical: built directly / returned to the pool and taken back under the same appearance / built under the other appearance, returned to the pool and taken back under this appearance.
        for dark in [false, true] {
            for origin in ChatCodeBlockCardSnapshotHost.Origin.allCases {
                try capture("chat-code-\(origin.rawValue)", width: 350, height: 280, dark: dark, settle: 0.8) {
                    ChatCodeBlockCardSnapshotHost(
                        language: "swift",
                        content: content,
                        width: 318,
                        origin: origin,
                        dark: dark
                    )
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(OriveoTheme.Palette.backgroundBase)
                }
            }
        }
    }

    @Test("chat composer states")
    func chatComposerInput() throws {
        let provider = TestFactories.makeProvider(kind: .openAI)
        let samples: [(String, String, Bool)] = [
            ("empty", "", false),
            ("one-line", "Hello there", false),
            ("three-lines", "This is a longer message that should wrap across a few lines inside the composer input field.", false),
            ("seven-lines", (1...7).map { "Line \($0)" }.joined(separator: "\n"), false),
            ("arabic", "مرحبا، كيف حالك اليوم؟ أريد أن أسأل عن شيء مهم جدا في هذا الموضوع.", false),
            ("chinese", "\u{8FD9}\u{662F}\u{4E00}\u{6BB5}\u{6BD4}\u{8F83}\u{957F}\u{7684}\u{4E2D}\u{6587}\u{8F93}\u{5165}\u{FF0C}\u{7528}\u{6765}\u{68C0}\u{67E5}\u{8F93}\u{5165}\u{6846}\u{5728}\u{6362}\u{884C}\u{4E4B}\u{540E}\u{7684}\u{884C}\u{9AD8}\u{3001}\u{5149}\u{6807}\u{4F4D}\u{7F6E}\u{4E0E}\u{5185}\u{8FB9}\u{8DDD}\u{662F}\u{5426}\u{4E0E}\u{539F}\u{6765}\u{4E00}\u{81F4}\u{3002}", false),
            ("disabled-empty", "", true),
        ]
        try withState([provider]) { state in
            for dark in [false, true] {
                for (name, text, sending) in samples {
                    try capture("chat-composer-\(name)", width: 390, height: 360, dark: dark, settle: 1.0) {
                        ChatComposerSnapshotHost(provider: provider, text: text, isSending: sending)
                            .environment(state)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .background(OriveoTheme.Palette.backgroundBase)
                    }
                }
            }
        }
    }

    @Test("home hero text view states")
    func homeHeroInput() async throws {
        var preference = AppPreferencesStore.load()
        let originalLanguage = preference.language
        preference.language = .chineseSimplified
        AppPreferencesStore.save(preference)
        L10n.invalidateCache()
        defer {
            var restore = AppPreferencesStore.load()
            restore.language = originalLanguage
            AppPreferencesStore.save(restore)
            L10n.invalidateCache()
        }
        let provider = TestFactories.makeProvider(kind: .openAI)
        let samples: [(String, String)] = [
            ("one-line", "Hello there"),
            ("three-lines", "This is a longer message that should wrap across a few lines inside the hero input field."),
            ("seven-lines", (1...7).map { "Line \($0)" }.joined(separator: "\n")),
            ("arabic", "مرحبا، كيف حالك اليوم؟ أريد أن أسأل عن شيء مهم جدا في هذا الموضوع."),
        ]
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try withState([provider]) { state in
            for dark in [false, true] {
                let host = UIHostingController(rootView: NavigationStack { HomeView() }.environment(state))
                let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                window.overrideUserInterfaceStyle = dark ? .dark : .light
                window.rootViewController = host
                window.makeKeyAndVisible()
                pumpMainRunLoop(1.5)
                let input = try #require(Self.firstEditableTextView(in: host.view), "the home hero text view was not found")
                for (name, text) in samples {
                    input.becomeFirstResponder()
                    pumpMainRunLoop(0.3)
                    input.selectedRange = NSRange(location: 0, length: (input.text as NSString).length)
                    input.insertText(text)
                    // Dismiss the keyboard before the screenshot: a blinking caret would make the two captures differ pixel by pixel.
                    input.resignFirstResponder()
                    pumpMainRunLoop(1.2)
                    let frame = input.convert(input.bounds, to: window)
                    let band = CGRect(x: 0, y: max(0, frame.minY - 24), width: window.bounds.width, height: frame.height + 48)
                    let renderer = UIGraphicsImageRenderer(bounds: band)
                    let image = renderer.image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let url = outputDirectory.appendingPathComponent("home-hero-\(name)-\(dark ? "dark" : "light").png")
                    try #require(image.pngData()).write(to: url)
                }
                window.isHidden = true
                window.rootViewController = nil
            }
        }
    }

    private static func firstEditableTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isEditable, !textView.isHidden { return textView }
        for subview in view.subviews {
            if let found = firstEditableTextView(in: subview) { return found }
        }
        return nil
    }

    @Test("chat user bubble")
    func chatUserBubble() throws {
        let samples: [(String, String)] = [
            ("hi", "hi"),
            ("two-lines", "Could you summarize the key points of this article for me, please?"),
            ("chinese", "\u{8BF7}\u{5E2E}\u{6211}\u{628A}\u{4E0B}\u{9762}\u{8FD9}\u{6BB5}\u{8BDD}\u{6539}\u{5199}\u{5F97}\u{66F4}\u{6B63}\u{5F0F}\u{4E00}\u{4E9B}\u{FF0C}\u{4FDD}\u{7559}\u{539F}\u{610F}\u{FF0C}\u{4E0D}\u{8981}\u{8D85}\u{8FC7}\u{4E09}\u{53E5}\u{8BDD}\u{FF0C}\u{8C22}\u{8C22}\u{3002}"),
            ("arabic", "مرحبا، كيف حالك اليوم؟ أريد أن أسأل عن شيء مهم جدا في هذا الموضوع."),
            ("long", String(repeating: "A long message line that wraps across the bubble several times. ", count: 12)),
            // Beyond UserMessageFold.thresholdUTF16: the folded state (capped + fade-out + "Show full message" pill).
            ("folded-latin", String(repeating: "A long message line that wraps across the bubble several times. ", count: 120)),
            ("folded-arabic", String(repeating: "مرحبا، كيف حالك اليوم؟ أريد أن أسأل عن شيء مهم جدا في هذا الموضوع. ", count: 150)),
        ]
        for dark in [false, true] {
            for width in [CGFloat(393), 430] {
                for (name, text) in samples {
                    try capture("chat-user-\(name)", width: width, height: 640, dark: dark, settle: 0.5) {
                        ChatUserBubbleSnapshotHost(text: text, width: width)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(OriveoTheme.Palette.backgroundBase)
                    }
                }
            }
        }
    }

    @Test("capability metadata row degradation branches")
    func metadataRowBranches() throws {
        let provider = TestFactories.makeProvider(kind: .openAI)
        var priced = TestFactories.makeModel(id: "priced", capabilities: [.text], priceTier: "$2.50/M")
        priced.promptPrice = nil
        let capabilitySets: [[ModelCapability]] = [
            [.reasoning, .web, .image],
            [.web, .toolCall],
            [.file],
        ]
        for dark in [false, true] {
            try capture("metadata-row", width: 390, height: 1400, dark: dark, settle: 0.5) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(capabilitySets.enumerated()), id: \.offset) { _, capabilities in
                        ForEach([360.0, 230.0, 150.0, 96.0], id: \.self) { width in
                            ForEach([false, true], id: \.self) { compact in
                                ModelListMetadataRow(
                                    model: priced,
                                    provider: provider,
                                    capabilityEvidenceRevision: 1,
                                    projectedCapabilities: capabilities,
                                    compact: compact,
                                    showPrice: false
                                )
                                .frame(width: width, alignment: .leading)
                                .background(Color.gray.opacity(0.12))

                                ModelListMetadataRow(
                                    model: priced,
                                    provider: provider,
                                    capabilityEvidenceRevision: 1,
                                    projectedCapabilities: capabilities,
                                    compact: compact,
                                    iconOnly: width < 120,
                                    showPrice: true,
                                    statusTitle: width < 200 ? "Beta" : nil
                                )
                                .frame(width: width, alignment: .leading)
                                .background(Color.orange.opacity(0.10))
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(OriveoTheme.Palette.backgroundBase)
            }
        }
    }

    @Test("settings page and provider list")
    func settingsAndProvidersPages() throws {
        let official = TestFactories.makeProvider(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            kind: .openAI
        )
        try withState([official]) { state in
            for dark in [false, true] {
                try capture("settings", width: 390, dark: dark, scrollPages: 3) {
                    NavigationStack { SettingsView() }.environment(state)
                }
                try capture("providers", width: 390, dark: dark, scrollPages: 2) {
                    NavigationStack { ProvidersView() }.environment(state)
                }
            }
        }
    }
}

/// Build the table card in the real order used in the cell: build the card first (width unknown), then attach the selection callback, then lay out at the message width.
private struct ChatTableCardSnapshotHost: UIViewRepresentable {
    let lines: [String]
    let width: CGFloat
    /// true: lay out only without upgrading, capture the first-frame placeholder (the caller pauses the scheduler).
    var placeholdersOnly = false
    /// non-nil: first build the card via make under the opposite appearance, mount it in a window to lay out and commit, return it to the pool, then take it back under this appearance (true = dark).
    var otherStyleRecycleDark: Bool?

    private func makeCard() -> UIKitTableCard? {
        guard let otherStyleRecycleDark else {
            return UIKitTableCard.parseMarkdownLines(lines).map { UIKitTableCard(tableData: $0) }
        }
        UIKitTableCard.purgeRecycledCards()
        let otherStyle: UIUserInterfaceStyle = otherStyleRecycleDark ? .light : .dark
        var first: UIKitTableCard?
        UITraitCollection(userInterfaceStyle: otherStyle).performAsCurrent {
            first = UIKitTableCard.make(lines: lines)
        }
        guard let first,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width + 32, height: 900)
        window.overrideUserInterfaceStyle = otherStyle
        window.isHidden = false
        window.addSubview(first)
        first.frame = CGRect(x: 16, y: 16, width: width, height: 10)
        first.layoutIfNeeded()
        first.completeDeferredRows()
        first.frame.size.height = first.intrinsicContentSize.height
        first.layoutIfNeeded()
        CATransaction.flush()
        first.removeFromSuperview()
        window.isHidden = true
        UIKitTableCard.recycle(first)
        let card = UIKitTableCard.make(lines: lines)
        #expect(card === first, "a card with the same content built under the opposite appearance should be taken back as the original card after returning to the pool")
        return card
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        guard let card = makeCard() else { return container }
        card.onAskSelection = { _ in }
        container.addSubview(card)
        card.frame = CGRect(x: 0, y: 0, width: width, height: 10)
        card.layoutIfNeeded()
        if !placeholdersOnly {
            card.completeDeferredRows()
        }
        card.frame.size.height = card.intrinsicContentSize.height
        card.layoutIfNeeded()
        let coverage = card._testCellCoverage
        #expect(coverage.rowsWithContent == coverage.rows)
        if placeholdersOnly {
            #expect(coverage.rowsWithTextViews == 0, "a UITextView got mixed into the placeholder snapshot, so the comparison can no longer prove placeholder and final state are identical")
        } else {
            #expect(coverage.placeholders == 0)
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: width, height: uiView.subviews.first?.frame.height ?? 0)
    }
}

/// Completed-state code card: `make` builds the card directly / `recycle` returns to the pool under the same appearance and takes it back / `otherStyle` builds under the opposite appearance,
/// mounts it in a window to lay out and commit, returns it to the pool, then takes it back under this appearance. The three images must be pixel-identical.
///
/// A code card has no intrinsicContentSize (its height comes from internal constraints), so the real height must be taken with systemLayoutSizeFitting;
/// reading intrinsicContentSize on the old host gives -1 and the capture is a single line.
private struct ChatCodeBlockCardSnapshotHost: UIViewRepresentable {
    enum Origin: String, CaseIterable {
        case make
        case recycle
        case otherStyle = "other-style-recycle"
    }

    let language: String?
    let content: String
    let width: CGFloat
    let origin: Origin
    let dark: Bool

    private func makeCard(style: UIUserInterfaceStyle? = nil) -> UIKitCodeBlockCard {
        var card: UIKitCodeBlockCard?
        let build = {
            card = UIKitCodeBlockCard.make(
                language: language,
                content: content,
                parentViewController: nil,
                highlightTransition: false
            )
        }
        if let style {
            UITraitCollection(userInterfaceStyle: style).performAsCurrent(build)
        } else {
            build()
        }
        return card!
    }

    private static func fit(_ card: UIKitCodeBlockCard, width: CGFloat) {
        card.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        card.layoutIfNeeded()
        let size = card.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        card.frame = CGRect(x: 0, y: 0, width: width, height: ceil(size.height))
        card.layoutIfNeeded()
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        let card: UIKitCodeBlockCard
        switch origin {
        case .make:
            card = makeCard(style: style)
        case .recycle:
            let first = makeCard(style: style)
            Self.fit(first, width: width)
            UIKitCodeBlockCard.recycle(first)
            card = makeCard()
            #expect(card === first, "after returning to the pool, the same content should be taken back as the same card")
        case .otherStyle:
            let otherStyle: UIUserInterfaceStyle = dark ? .light : .dark
            let first = makeCard(style: otherStyle)
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width + 32, height: 600)
                window.overrideUserInterfaceStyle = otherStyle
                window.isHidden = false
                window.addSubview(first)
                Self.fit(first, width: width)
                CATransaction.flush()
                first.removeFromSuperview()
                window.isHidden = true
            }
            UIKitCodeBlockCard.recycle(first)
            card = makeCard()
            #expect(card === first, "a card with the same content built under the other appearance should be taken back as the same card after returning to the pool")
        }
        container.addSubview(card)
        Self.fit(card, width: width)
        #expect(card.frame.height > 44 + 40, "the code card should contain a code area (header 44pt + three lines of code), actually \(card.frame.height)")
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: width, height: uiView.subviews.first?.frame.height ?? 0)
    }
}


/// Chat composer snapshot host: pour the text into the composer through the conversation draft (the same path as restoring a draft when entering a conversation).
private struct ChatComposerSnapshotHost: View {
    let provider: Provider
    let text: String
    let isSending: Bool

    @State private var conversationID = UUID()
    @State private var scopeID = UUID()
    @State private var attachments: [Oriveo.Attachment] = []
    @State private var quoteContext: QuoteContext?
    @State private var reasoningMode: ReasoningMode = .automatic
    @State private var reasoningIntent: String?
    @State private var webEnabled = false
    @State private var focused = false

    var body: some View {
        ChatComposerBar(
            provider: provider,
            currentModel: provider.models.first,
            visibleCapabilityKeys: [],
            capabilityEvidenceIdentity: nil,
            generationProjection: nil,
            capabilityDecision: .resolve(
                webRequested: false,
                webPermitted: false,
                reasoningModeRequested: .automatic,
                reasoningModePermitted: true,
                reasoningIntentRequested: nil,
                reasoningIntentPermitted: false
            ),
            isSendingMessage: isSending,
            conversationID: conversationID,
            generationParameterScopeID: scopeID,
            storeDraft: text,
            textPush: ChatComposerTextPush(),
            onDraftCommit: { _, _ in },
            pendingAttachments: $attachments,
            pendingQuoteContext: $quoteContext,
            reasoningMode: $reasoningMode,
            reasoningIntentSelection: $reasoningIntent,
            webEnabled: $webEnabled,
            composerFocused: $focused,
            onSend: { _, _ in },
            onChooseModel: {},
            onCancel: {},
            onShowPhotoPicker: {},
            onShowCamera: {},
            onShowFileImporter: {}
        )
    }
}


/// User bubble snapshot host: the same path as ChatLayout's self-sizing (natural height at full width -> layout at the real size).
private struct ChatUserBubbleSnapshotHost: UIViewRepresentable {
    let text: String
    let width: CGFloat

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let cell = UserMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 100))
        let message = ChatMessage(
            id: UUID(), role: .user, text: text, reasoningText: nil,
            providerKind: .openAI, providerName: "OpenAI", modelName: "GPT-4o",
            estimatedCost: 0, state: .delivered, attachments: nil, citations: nil
        )
        let model = ChatCollectionProjectionBuilder.MessageRenderModel(
            messageID: message.id, message: message, presentationKind: .user,
            showMetadata: true, resolvedProviderName: "OpenAI", resolvedModelName: "GPT-4o",
            relayKind: nil, renderHint: nil, topPadding: 16,
            displayText: nil, textHash: text.hashValue, isStreaming: false, providerMetadataVersion: 0
        )
        cell.configure(
            model: model,
            maxBubbleWidth: 320, parentViewController: UIViewController()
        )
        cell.contentView.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        let fit = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        cell.frame = CGRect(x: 0, y: 0, width: width, height: fit.height)
        container.addSubview(cell)
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: width, height: uiView.subviews.first?.frame.height ?? 0)
    }
}
