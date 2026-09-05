import SwiftUI

struct OpenAISubscriptionAuthorizationSheet: View {
    let config: OpenAISubscriptionAuthConfig
    let onAuthorized: (OpenAISubscriptionTokens) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model = OpenAISubscriptionAuthorizationModel()

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.primary)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Text(L10n.tr("Sign in with your ChatGPT subscription", table: .providers))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

            Text(L10n.tr(
                "Authorize with your ChatGPT account to run Codex with your Plus or Pro plan. Your messages are processed by OpenAI. No API credits are used.",
                table: .providers
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)

            content
                .padding(.horizontal, 24)

            Spacer(minLength: 16)

            Button {
                model.cancel()
                dismiss()
            } label: {
                Text(L10n.tr("Cancel"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .onAppear { model.start(config: config) }
        .onDisappear { model.cancel() }
        .onChange(of: model.phase) { _, phase in
            if case let .succeeded(tokens) = phase {
                onAuthorized(tokens)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .requesting:
            ProgressView()
                .padding(.vertical, 24)

        case let .awaitingAuthorization(authorization):
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(L10n.tr("Your code", table: .providers))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(authorization.userCode)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(OriveoTheme.Palette.surfaceInset)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    model.markVerificationPageOpened()
                    openURL(authorization.verificationURL)
                } label: {
                    Text(model.didOpenVerificationPage
                         ? L10n.tr("Open the authorization page again", table: .providers)
                         : L10n.tr("Open authorization page", table: .providers))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(OriveoTheme.Palette.primary)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if model.didOpenVerificationPage {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("Waiting for authorization…", table: .providers))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case let .failed(error):
            VStack(spacing: 14) {
                Text(error.userFacingMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if error.allowsRetry {
                    Button {
                        model.start(config: config)
                    } label: {
                        Text(L10n.tr("Try again", table: .providers))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(OriveoTheme.Palette.primary)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }

        case .succeeded:
            ProgressView()
                .padding(.vertical, 24)
        }
    }
}
