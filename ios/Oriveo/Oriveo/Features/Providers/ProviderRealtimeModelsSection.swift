import SwiftUI

// MARK: - Realtime Models Section

/// "Realtime voice" group in provider details, same source as the picker: rows = `modelPickerRealtimeModels` (voice catalog × this connection's official apiKey),
/// no rows, no group; not counted in the header model count (the header is still `provider.enabledModelCount`).
/// Like the added-models section, it has no container of its own: the group header and rows are emitted as siblings, placed row by row by the single lazy stack of the detail page.
struct ProviderRealtimeModelsSection: View, Equatable {
    let provider: Provider
    /// Sorted realtime models; empty means the whole group is not shown (callers use `rows(for:catalog:)`).
    let models: [String]
    let onChat: (String) -> Void
    /// Row checkmark reads only the home's realtime selection (in-memory state, no checkmark on cold start); reading it in body recomputes on selection change.
    @Environment(AppState.self) private var appState

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.provider.id == rhs.provider.id && lhs.models == rhs.models
    }

    /// Realtime models for this connection's column: same exit as the picker's home screen; only passes this connection and takes this connection's group.
    static func rows(for provider: Provider, catalog: VoiceCatalog?) -> [String] {
        modelPickerRealtimeModels(context: .home, providers: [provider], catalog: catalog)
            .byProvider[provider.id] ?? []
    }

    /// Realtime model checked for this connection: the home realtime selection's model if it falls on this connection, otherwise nil.
    @MainActor
    static func checkedModel(for provider: Provider, appState: AppState) -> String? {
        guard let selection = appState.realtimeModelSelection(for: nil),
              selection.providerID == provider.id
        else { return nil }
        return selection.model
    }

    /// Trailing chat button on the row: select as the home realtime selection (does not go through startNewChat, does not write lastUsed).
    /// Takes effect and switches to the home tab immediately; when a disclosure is needed, hand back to the caller to show the existing disclosure, then proceed with `resolveDisclosure` after consent.
    @MainActor
    @discardableResult
    static func startRealtimeChat(
        providerID: UUID,
        model: String,
        appState: AppState,
        disclosures: VoiceDisclosureStore = VoiceDisclosureStore()
    ) -> RealtimeModelSelectionOutcome {
        let outcome = appState.selectRealtimeModel(providerID: providerID, model: model, for: nil, disclosures: disclosures)
        if case .applied = outcome {
            returnToHome(appState)
        }
        return outcome
    }

    /// Disclosure reply: switch to the home tab only if agreed and taken effect; reject (including swipe-to-dismiss) does nothing.
    @MainActor
    @discardableResult
    static func resolveDisclosure(
        _ request: RealtimeModelDisclosureRequest,
        accepted: Bool,
        appState: AppState,
        disclosures: VoiceDisclosureStore = VoiceDisclosureStore()
    ) -> Bool {
        let applied = appState.resolveRealtimeModelDisclosure(
            request.selection, for: request.conversationID, accepted: accepted, disclosures: disclosures
        )
        if applied {
            returnToHome(appState)
        }
        return applied
    }

    /// Back to home: same destination as text model rows (per AppState.presentChat), switch to the home tab; in regular, home sits beneath the outer stack,
    /// it must also clear the stack back to the home root view, otherwise the right column is covered by the detail page.
    @MainActor
    private static func returnToHome(_ appState: AppState) {
        appState.selectedTab = .home
        if appState.navigation.isRegularWidth {
            appState.navigation.popToRoot()
        }
    }

    var body: some View {
        if !models.isEmpty {
            let checkedModel = Self.checkedModel(for: provider, appState: appState)
            ProviderSectionHeader(title: L10n.tr("Realtime Voice", table: .voice))
                .padding(.top, OriveoTheme.Spacing.lg)
                .padding(.bottom, OriveoTheme.Spacing.md)

            ForEach(Array(models.enumerated()), id: \.element) { index, model in
                let slice = ProviderPanelSlice(index: index, count: models.count)
                ProviderRealtimeModelRow(
                    model: model,
                    isChecked: model == checkedModel,
                    isLast: index == models.count - 1,
                    chatAction: { onChat(model) }
                )
                .clipShape(ProviderPanelSliceShape(slice: slice, radius: OriveoTheme.Radius.lg))
                .providerPanelSlice(index: index, count: models.count, group: "realtime-models", style: .enabledPanel(flat: false))
            }
        }
    }
}

/// Realtime model row: follows the layout of added-model rows (name + subtitle, round chat button at trailing edge);
/// when equal to the home realtime selection, the chat button's left side shows the same checkmark as the picker text row.
struct ProviderRealtimeModelRow: View {
    let model: String
    let isChecked: Bool
    let isLast: Bool
    let chatAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: OriveoTheme.Spacing.sm) {
            Button(action: chatAction) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ModelIdentifierBreaks.displayTitle(model))
                        .accessibilityLabel(model)
                        .font(OriveoTheme.Typography.title3)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.tr("Realtime voice · Interrupt anytime", table: .voice))
                        .font(OriveoTheme.Typography.caption)
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isChecked ? .isSelected : [])

            if isChecked {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OriveoTheme.V2.Colors.primary)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }

            Button(action: chatAction) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OriveoTheme.Palette.primary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(OriveoTheme.Palette.primarySoft))
            }
            .accessibilityLabel(L10n.tr("New Chat"))
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(OriveoTheme.Palette.border.opacity(0.45))
                    .frame(height: 0.5)
                    .padding(.leading, 14)
            }
        }
    }
}
