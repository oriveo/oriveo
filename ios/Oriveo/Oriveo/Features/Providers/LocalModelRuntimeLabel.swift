import SwiftUI

struct LocalModelRuntimeLabel: View {
    let model: AIModel

    var body: some View {
        if let label {
            Text(label)
                .font(OriveoTheme.Typography.footnote)
                .foregroundStyle(model.executionLocality == .proxiedCloud ? OriveoTheme.Palette.warning : OriveoTheme.Palette.textSecondary)
                .accessibilityLabel(label)
        }
    }

    private var label: String? {
        if model.executionLocality == .proxiedCloud {
            return L10n.tr("Via Ollama Cloud", table: .providers)
        }
        switch model.localLoadState {
        case .loading: return L10n.tr("Loading", table: .providers)
        case .unloaded: return L10n.tr("Unloaded", table: .providers)
        case .unknown: return L10n.tr("State unknown", table: .providers)
        case .loaded, .none: return nil
        }
    }
}
