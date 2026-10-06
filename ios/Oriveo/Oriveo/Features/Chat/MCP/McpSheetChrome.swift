import SwiftUI
import UIKit

// MARK: - Shared chrome and buttons for the MCP bottom sheets
//
// Bottom sheets: the content root has a 30pt top inset (enough to clear the grabber), 20pt on the sides and
// 34pt at the bottom. The height follows the content; past the available height the content scrolls and the
// button area stays pinned to the bottom. No lazy containers inside the content (their height cannot be
// measured).

enum McpSheetMetrics {
    static let topPadding: CGFloat = 30
    static let horizontalPadding: CGFloat = 20
    static let bottomPadding: CGFloat = 14
    static let blockSpacing: CGFloat = 18
    static let buttonHeight: CGFloat = 52
    static let buttonCornerRadius: CGFloat = 16
    static let groupCornerRadius: CGFloat = 20
}

/// Reports the height of the enclosing view (placed in a `.background`).
private struct McpHeightReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onChange(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, height in onChange(height) }
        }
    }
}

/// A sheet container whose detent follows the content height. `content` scrolls; `footer` (the button area)
/// is pinned to the bottom.
struct McpFittedSheet<Content: View, Footer: View>: View {
    var fallbackHeight: CGFloat = 420
    var allowsInteractiveDismiss = true
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content()
                    .padding(.horizontal, McpSheetMetrics.horizontalPadding)
                    .padding(.top, McpSheetMetrics.topPadding)
                    .background { McpHeightReader { contentHeight = $0 } }
            }
            .scrollBounceBehavior(.basedOnSize)
            footer()
                .padding(.horizontal, McpSheetMetrics.horizontalPadding)
                .padding(.top, McpSheetMetrics.blockSpacing)
                .padding(.bottom, McpSheetMetrics.bottomPadding)
                .background { McpHeightReader { footerHeight = $0 } }
        }
        .interactiveDismissDisabled(!allowsInteractiveDismiss)
        .presentationDetents([.height(detentHeight)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(OriveoTheme.Palette.background)
    }

    /// Falls back to `fallbackHeight` when no trustworthy height can be measured, so the sheet is not silently
    /// clamped to full screen.
    private var detentHeight: CGFloat {
        let total = contentHeight + footerHeight
        guard total.isFinite, total > 0 else { return fallbackHeight }
        return min(total, UIScreen.main.bounds.height * 0.86)
    }
}

struct McpPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: McpSheetMetrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: McpSheetMetrics.buttonCornerRadius, style: .continuous)
                    .fill(OriveoTheme.Palette.primaryGradient)
            )
            .shadow(
                color: OriveoTheme.Palette.primary.opacity(configuration.isPressed ? 0.08 : 0.26),
                radius: 12, y: 6
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct McpSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: McpSheetMetrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: McpSheetMetrics.buttonCornerRadius, style: .continuous)
                    .fill(OriveoTheme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: McpSheetMetrics.buttonCornerRadius, style: .continuous)
                    .stroke(OriveoTheme.Palette.borderStrong, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct McpTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Loads server icons. The icon address is supplied by a third party: **only `https://` is accepted**
/// (redirects to another scheme are not followed), no cookies or credentials are sent, the size is capped, and
/// when nothing usable comes back the caller falls back to the initial-letter tile.
/// Two cache layers: decoded images are cached in memory by address, raw responses go through this session's
/// own `URLCache`.
nonisolated final class McpServerIconLoader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = McpServerIconLoader()

    static let maxBytes = 512 * 1024

    private let memory = NSCache<NSURL, UIImage>()
    private let cache: URLCache
    private var session: URLSession!

    init(protocolClasses: [AnyClass]? = nil) {
        cache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 16 * 1024 * 1024, diskPath: "mcp-server-icons")
        super.init()
        memory.countLimit = 64
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Accepts only `https://` addresses that have a host name.
    static func acceptedURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    func cachedImage(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        if let cached = cachedImage(for: url) { return cached }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https",
              data.count <= Self.maxBytes,
              let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: url as NSURL)
        return image
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Redirects are followed for https only.
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

/// The server icon: the server's own icon when it has one, otherwise a colored tile with the first letter of
/// its name. No stroke and no decoration beyond the tile.
/// Icons are https-only and cached; until one arrives (or if none can be fetched) the initial-letter tile
/// shows.
struct McpServerIconView: View {
    let name: String
    let iconURL: String?
    var size: CGFloat = 40

    var serverURL: String? = nil

    @State private var loaded: UIImage?
    @State private var loadedURL: URL?

    private var url: URL? { McpServerIconLoader.acceptedURL(iconURL) }

    var body: some View {
        Group {
            if let asset = McpBrandIcons.asset(name: name, serverURL: serverURL) {
                Image(asset).resizable().scaledToFit()
            } else if let image = (loadedURL == url ? loaded : nil) ?? url.flatMap({ McpServerIconLoader.shared.cachedImage(for: $0) }) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                letterTile
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        .accessibilityHidden(true)
        .task(id: url) {
            guard McpBrandIcons.asset(name: name, serverURL: serverURL) == nil, let url else {
                loaded = nil
                return
            }
            let image = await McpServerIconLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            loadedURL = url
            loaded = image
        }
    }

    private var letterTile: some View {
        ZStack {
            OriveoTheme.Palette.primarySoft
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
        }
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// A white rounded group card (the server list in the panel, the key-value rows in the confirmation sheet).
struct McpGroupCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: McpSheetMetrics.groupCornerRadius, style: .continuous)
                    .fill(OriveoTheme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: McpSheetMetrics.groupCornerRadius, style: .continuous)
                    .stroke(OriveoTheme.Palette.border, lineWidth: 1)
            )
    }
}

/// A monospaced code block (arguments and result in the step detail, the full-text page).
struct McpCodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(OriveoTheme.Palette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OriveoTheme.Palette.surfaceInset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(OriveoTheme.Palette.border, lineWidth: 1)
            )
    }
}
