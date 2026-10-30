import SwiftUI

// Shared copy assembly, logo and card styles for the web search settings pages. Cards / group titles / footers follow the Settings › Theme page (corner radius 14, surface background,
// 13pt group titles and footers, textTertiary); all colors go through OriveoTheme tokens.

enum WebSearchCopy {
    static func tr(_ id: String) -> String {
        L10n.tr("webSearch.\(id)", table: .webSearch)
    }

    static func format(_ id: String, _ arguments: CVarArg...) -> String {
        String(format: tr(id), locale: L10n.formattingLocale(AppLocalization.currentLocale), arguments: arguments)
    }

    /// snake_case → lowerCamel (error card headline / action → second half of the copy key).
    static func camel(_ snake: String) -> String {
        let parts = snake.split(separator: "_").map(String.init)
        guard let first = parts.first else { return snake }
        return first + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    static func integer(_ value: Int) -> String {
        value.formatted(.number.locale(L10n.formattingLocale(AppLocalization.currentLocale)))
    }

    /// Price summary: unit price · free quota · whether a card is required [· international site also available]. nil when there is none.
    static func price(_ summary: SearchPriceSummary, includeOtherRegion: Bool = false) -> String? {
        var parts: [String] = []
        if let price = summary.price {
            parts.append(format(price.unit == "per_request" ? "price.perRequest" : "price.per1k", price.label))
        }
        if let free = summary.free {
            switch free.kind {
            case .monthlyCredits:
                parts.append(format("price.freeCredits", integer(free.count ?? 0)))
            case .monthlyUsd:
                parts.append(format("price.freeUsd", free.amountLabel ?? ""))
            }
            parts.append(tr(free.cardRequired ? "price.cardRequired" : "price.noCard"))
        }
        if includeOtherRegion && summary.otherRegionCount > 0 { parts.append(tr("price.otherRegion")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// List row subtitle and whether to use the warning color.
    static func rowSubtitle(_ item: WebSearchServiceItem) -> (text: String, warning: Bool) {
        let row = item.row
        switch row.status {
        case .ready:
            if row.keySource == .connection {
                return (format("row.viaConnection", row.connectionName ?? ""), false)
            }
            if item.isCustom {
                return (tr(row.keySource == .own ? "row.connected" : "row.noKey"), false)
            }
            let summary = SearchSettings.searchPriceSummary(item.entry, regionId: item.service.regionId)
            return ([tr("row.connected"), price(summary)].compactMap { $0 }.joined(separator: " · "), false)
        case .catalogUnavailable: return (tr("row.catalogUnavailable"), true)
        case .withdrawn: return (tr("row.withdrawn"), true)
        case .hostChanged: return (tr("row.hostChanged"), true)
        case .connectionMissing: return (tr("row.connectionMissing"), true)
        case .needsKey: return (tr("row.needsKey"), true)
        }
    }

    static func consentLine(_ line: SearchConsentLine) -> String {
        let id = "consent.\(line.key)"
        if let name = line.args["name"] { return format(id, name ?? "") }
        if let host = line.args["host"] { return format(id, host ?? "") }
        return tr(id)
    }

    static func testPassed(_ presentation: SearchTestPresentation) -> String {
        let seconds = (Double(presentation.latencyTenths ?? 0) / 10).formatted(
            .number.precision(.fractionLength(1)).locale(L10n.formattingLocale(AppLocalization.currentLocale))
        )
        return format("test.passed", seconds, integer(presentation.count ?? 0))
    }

    static func headline(_ presentation: SearchTestPresentation) -> String {
        tr("error.\(camel(presentation.headline ?? "service_error"))")
    }

    static func regionName(_ regionID: String) -> String {
        switch regionID {
        case "cn": tr("region.cn")
        case "intl": tr("region.intl")
        default: regionID
        }
    }

    /// Secondary line of the custom consent page: "<protocol name> · <host[:port]>".
    static func protocolName(_ protocolID: String, sameAsName: String?) -> String {
        switch protocolID {
        case "searxng": tr("custom.protocolSearxng")
        case "same_as": sameAsName ?? tr("custom.protocolSameAs")
        default: tr("custom.protocolManual")
        }
    }

    static func hostLabel(_ address: SearchServiceAddress) -> String {
        address.host + (address.port.map { ":\($0)" } ?? "")
    }
}

/// Search service logo: deepseek / zhipu / kimi reuse the provider logos (including the dark variants), tavily / exa / brave / perplexity use imported assets,
/// unknown ids and custom services always get the server icon. No stroke, no backing plate.
struct WebSearchServiceLogo: View {
    let serviceId: String?
    var custom = false
    var size: CGFloat = 28

    private static let assets = [
        "tavily": "SearchLogoTavily",
        "exa": "SearchLogoExa",
        "brave": "SearchLogoBrave",
        "perplexity": "SearchLogoPerplexity",
    ]

    private static let providerKinds: [String: ProviderKind] = [
        "deepseek": .deepseek,
        "zhipu": .zhipu,
        "kimi": .moonshot,
    ]

    var body: some View {
        Group {
            if !custom, let kind = serviceId.flatMap({ Self.providerKinds[$0] }) {
                ProviderBadgeIcon(kind: kind, size: size)
            } else if !custom, let asset = serviceId.flatMap({ Self.assets[$0] }) {
                Image(asset)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * 0.86, height: size * 0.86)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// White card for second-level settings pages.
struct WebSearchCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OriveoTheme.Palette.surface)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct WebSearchSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

struct WebSearchFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

/// In-card divider (leading edge starts at the text).
struct WebSearchDivider: View {
    var leading: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(OriveoTheme.Palette.hairline)
            .frame(height: 0.5)
            .padding(.leading, leading)
    }
}

/// Pressed state of a tappable row: light background over the whole row.
struct WebSearchRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? OriveoTheme.Palette.surfaceInset : Color.clear)
    }
}

/// Hint under a field: error in red / warning in orange (13pt).
struct WebSearchFieldMessage: View {
    let text: String
    var warning = false

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(warning ? OriveoTheme.Palette.warningText : OriveoTheme.Palette.danger)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Second-level page top bar (like the theme page: centered title + back on the left).
struct WebSearchTopBar<Leading: View>: View {
    let title: String
    let onBack: @MainActor () -> Void
    @ViewBuilder var titleLeading: Leading

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                titleLeading
                Text(title)
                    .font(OriveoTheme.Typography.title3)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 56)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                OriveoBackButton(action: onBack)
                    .padding(.leading, -OriveoBackButton.edgeInset)
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: OriveoBackButton.hitSize)
        .padding(.horizontal, 20)
    }
}

extension WebSearchTopBar where Leading == EmptyView {
    init(title: String, onBack: @escaping @MainActor () -> Void) {
        self.title = title
        self.onBack = onBack
        self.titleLeading = EmptyView()
    }
}

/// Primary button (brand gradient, corner radius 16, height 52), pinned to the bottom of the sheet.
struct WebSearchPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color(uiColor: OriveoPrimaryButtonStyle.foregroundUIColor))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(configuration.isPressed
                        ? AnyShapeStyle(OriveoTheme.Palette.primaryGradientPressed)
                        : AnyShapeStyle(OriveoTheme.Palette.primaryGradient))
            )
            .opacity(isEnabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

/// "Confirm before enabling" card: sentence by sentence (arrow / dollar / check; the custom first sentence gets an orange warning triangle).
struct WebSearchConsentCard: View {
    let lines: [SearchConsentLine]

    var body: some View {
        WebSearchCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(WebSearchCopy.tr("consent.title"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        icon(line.key)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(WebSearchCopy.consentLine(line))
                            .font(.system(size: 15))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func icon(_ key: String) -> some View {
        switch key {
        case "customUnverified":
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(OriveoTheme.Palette.warning)
        case "sendsQuery", "sendsQueryCustom", "webForwarded":
            Image(systemName: "arrow.forward").foregroundStyle(OriveoTheme.Palette.info)
        case "billing", "billingCustom":
            Image(systemName: "dollarsign.circle").foregroundStyle(OriveoTheme.Palette.info)
        default:
            Image(systemName: "checkmark").foregroundStyle(OriveoTheme.Palette.info)
        }
    }
}

/// Test failure: error headline + action button (above the consent card / in the detail page result row).
struct WebSearchTestFailure: View {
    let presentation: SearchTestPresentation
    let onAction: @MainActor (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(WebSearchCopy.format("test.failed", WebSearchCopy.headline(presentation)))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
            if let action = presentation.action, action != "none" {
                Button(action: { onAction(action) }) {
                    Text(WebSearchCopy.tr("action.\(WebSearchCopy.camel(action))"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(OriveoTheme.Palette.primarySoft))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Test failure on the connect page / custom consent page: a light-red rounded banner above the consent card, error headline (verbatim error.*) on the left, action button on the right.
struct WebSearchTestFailureBanner: View {
    let presentation: SearchTestPresentation
    let onAction: @MainActor (String) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(WebSearchCopy.headline(presentation))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OriveoTheme.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = presentation.action, action != "none" {
                Button(action: { onAction(action) }) {
                    Text(WebSearchCopy.tr("action.\(WebSearchCopy.camel(action))"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OriveoTheme.Palette.danger)
                        .fixedSize()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OriveoTheme.Palette.dangerSoft)
        )
    }
}

/// Small tag (Default / Custom).
struct WebSearchTag: View {
    let text: String
    var neutral = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(neutral ? OriveoTheme.Palette.textSecondary : OriveoTheme.Palette.primaryTextSafe)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(neutral ? OriveoTheme.Palette.surfaceInset : OriveoTheme.Palette.primarySoft)
            )
    }
}
