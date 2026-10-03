import SwiftUI
import UIKit

/// Step detail: what this step sent and what came back.
///
/// The arguments and result come from the local step payload. When this device has none (the message came
/// from a backup, or the payload was cleaned up) a one-line note is shown instead.
struct McpStepDetailSheet: View {
    struct Payload: Equatable {
        var arguments: String?
        var resultPrefix: String?
    }

    let step: McpToolStep
    /// Display status (`running` is shown as `interrupted` once the message is no longer generating).
    let status: McpToolStep.Status
    let payload: Payload?

    @State private var copied = false

    var body: some View {
        McpFittedSheet(fallbackHeight: 480) {
            VStack(alignment: .leading, spacing: McpSheetMetrics.blockSpacing) {
                header
                if let payload, payload.arguments != nil || payload.resultPrefix != nil {
                    if let arguments = payload.arguments {
                        section(title: L10n.tr("Sent", table: .mcp)) {
                            McpCodeBlock(text: McpConfirmationContent.allParametersText(storedJSON: arguments))
                        }
                    }
                    if let result = payload.resultPrefix, !result.isEmpty {
                        section(title: L10n.tr("Returned", table: .mcp), trailing: { copyButton(result) }) {
                            McpCodeBlock(text: result)
                        }
                        Text(L10n.tr(
                            "Results come from a third-party server. Only the first 2 KB is shown. Oriveo hasn't checked the content.",
                            table: .mcp
                        ))
                        .font(.system(size: 12.5))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(L10n.tr("Details are only kept on the device that ran this step.", table: .mcp))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, McpSheetMetrics.blockSpacing)
        } footer: {
            EmptyView()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            McpServerIconView(name: step.serverName, iconURL: nil, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                // The tool title and the server name are third-party text and are not translated.
                Text(step.displayTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(OriveoTheme.Typography.caption)
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "server · duration · status"; without a duration (denied, never ran) just "server · status".
    private var subtitle: String {
        let statusText = UIKitToolStepsView.statusText(for: status)
        guard let durationMs = step.durationMs else {
            return [step.serverName, statusText].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return String(
            format: L10n.tr("%1$@ · took %2$@ · %3$@", table: .mcp),
            step.serverName, Self.durationText(milliseconds: durationMs), statusText
        )
    }

    static func durationText(milliseconds: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.locale = Locale(identifier: AppLocalization.currentLanguage.rawValue)
        let seconds = Double(milliseconds) / 1_000
        let number = formatter.string(from: NSNumber(value: seconds)) ?? String(format: "%.1f", seconds)
        return String(format: L10n.tr("%@ s", table: .mcp), number)
    }

    private func section<Trailing: View, Content: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                Spacer()
                trailing()
            }
            content()
        }
    }

    /// Copies the part that is displayed.
    private func copyButton(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            OriveoHaptic.success()
            copied = true
        } label: {
            Text(copied ? L10n.tr("Copied", table: .mcp) : L10n.tr("Copy", table: .mcp))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

/// Presents the step detail from a chat cell (the cell is UIKit, so this wraps a host).
@MainActor
enum McpStepDetailPresenter {
    /// Reads the local step payload. Reads from the current partition's database by default; tests can replace it.
    static var loadPayload: (_ messageID: UUID, _ stepID: String) -> McpStepDetailSheet.Payload? = { messageID, stepID in
        guard let pool = try? DatabaseManager.shared.openIfNeeded(for: AppSessionStore.activeUID),
              let stored = try? McpServerStore(dbPool: pool).fetchStepPayload(messageID: messageID, stepID: stepID)
        else { return nil }
        return McpStepDetailSheet.Payload(arguments: stored.arguments, resultPrefix: stored.resultPrefix)
    }

    static func present(
        step: McpToolStep,
        status: McpToolStep.Status,
        messageID: UUID,
        from host: UIViewController
    ) {
        let sheet = McpStepDetailSheet(step: step, status: status, payload: loadPayload(messageID, step.id))
        let controller = UIHostingController(rootView: sheet)
        controller.modalPresentationStyle = .pageSheet
        controller.view.backgroundColor = .clear
        host.present(controller, animated: true)
    }
}
