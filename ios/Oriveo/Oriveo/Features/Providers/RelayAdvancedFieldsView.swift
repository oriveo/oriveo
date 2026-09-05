import SwiftUI

struct RelayAdvancedFieldsView: View {
    @Binding var transport: RelayTransport
    @Binding var authMode: RelayAuthMode
    @Binding var reasoningEffort: RelayReasoningEffort
    @Binding var serviceTier: String
    @Binding var stream: Bool
    @Binding var disableResponseStorage: Bool

    let isSubmitting: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xl) {
            protocolGroup
            behaviorGroup
        }
    }


    private var protocolGroup: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            RelayGroupHeader(
                title: L10n.tr("Protocol", table: .providers),
                systemImage: "arrow.triangle.branch",
                tint: Color.dynamic(light: 0x6366F1, dark: 0x818CF8)
            )

            RelayRowGroup {
                RelayMenuRow(
                    title: L10n.tr("Transport", table: .providers),
                    value: relayTransportLabel(transport),
                    isEnabled: !isSubmitting
                ) {
                    Picker(L10n.tr("Transport", table: .providers), selection: $transport) {
                        ForEach(RelayTransport.allUICases, id: \.self) { option in
                            Text(relayTransportLabel(option)).tag(option)
                        }
                    }
                }
                RelayRowDivider()
                RelayMenuRow(
                    title: L10n.tr("Auth Mode", table: .providers),
                    value: relayAuthLabel(authMode),
                    isEnabled: !isSubmitting
                ) {
                    Picker(L10n.tr("Auth Mode", table: .providers), selection: $authMode) {
                        ForEach(RelayAuthMode.allUICases, id: \.self) { option in
                            Text(relayAuthLabel(option)).tag(option)
                        }
                    }
                }
            }
        }
    }


    private var behaviorGroup: some View {
        VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
            RelayGroupHeader(
                title: L10n.tr("Request Behavior", table: .providers),
                systemImage: "brain",
                tint: Color.dynamic(light: 0x8C5FF8, dark: 0xC4B5FD)
            )

            RelayRowGroup {
                RelayMenuRow(
                    title: L10n.tr("Reasoning", table: .providers),
                    value: relayReasoningLabel(reasoningEffort),
                    isEnabled: !isSubmitting
                ) {
                    Picker(L10n.tr("Reasoning", table: .providers), selection: $reasoningEffort) {
                        ForEach(RelayReasoningEffort.allUICases, id: \.self) { option in
                            Text(relayReasoningLabel(option)).tag(option)
                        }
                    }
                }
                RelayRowDivider()
                RelayInlineTextRow(
                    title: L10n.tr("Service Tier", table: .providers),
                    text: $serviceTier,
                    placeholder: L10n.tr("auto / default / flex / …", table: .providers),
                    isEnabled: !isSubmitting
                )
                RelayRowDivider()
                RelayToggleRow(
                    title: L10n.tr("Stream", table: .providers),
                    isOn: $stream,
                    isEnabled: !isSubmitting
                )
                RelayRowDivider()
                RelayToggleRow(
                    title: L10n.tr("Don't keep responses in the cloud", table: .providers),
                    isOn: $disableResponseStorage,
                    footnote: L10n.tr("OpenAI Responses only • sets store: false", table: .providers),
                    isEnabled: !isSubmitting
                )
            }
        }
    }

}


func relayTransportLabel(_ t: RelayTransport) -> String {
    switch t {
    case .auto: return L10n.tr("Auto")
    case .openaiResponses: return L10n.tr("OpenAI Responses", table: .providers)
    case .openaiChatCompletions: return L10n.tr("OpenAI Chat Completions", table: .providers)
    case .llamacppNative: return L10n.tr("llama.cpp native completion", table: .providers)
    case .anthropicMessages: return L10n.tr("Anthropic Messages", table: .providers)
    case .geminiGenerateContent: return L10n.tr("Gemini generateContent", table: .providers)
    }
}

func relayAuthLabel(_ a: RelayAuthMode) -> String {
    switch a {
    case .auto: return L10n.tr("Auto")
    case .none: return L10n.tr("No authentication", table: .providers)
    case .bearer: return "Bearer"
    case .xApiKey: return "x-api-key"
    case .xGoogApiKey: return "x-goog-api-key"
    case .queryKey: return L10n.tr("Query key", table: .providers)
    }
}

func relayReasoningLabel(_ r: RelayReasoningEffort) -> String {
    switch r {
    case .automatic: return L10n.tr("Automatic", table: .providers)
    case .low: return L10n.tr("Low", table: .providers)
    case .medium: return L10n.tr("Medium", table: .providers)
    case .high: return L10n.tr("High", table: .providers)
    case .xhigh: return "xhigh"
    }
}


extension RelayTransport {
    static var allUICases: [RelayTransport] {
        [.auto, .openaiResponses, .openaiChatCompletions, .anthropicMessages, .geminiGenerateContent]
    }
}

extension RelayAuthMode {
    static var allUICases: [RelayAuthMode] {
        [.auto, .none, .bearer, .xApiKey, .xGoogApiKey, .queryKey]
    }
}

extension RelayReasoningEffort {
    static var allUICases: [RelayReasoningEffort] {
        [.automatic, .low, .medium, .high, .xhigh]
    }
}
