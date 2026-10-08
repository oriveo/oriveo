#if DEBUG
import SwiftUI

/// Debug samples of the model options panel, for checking how a given set of facts is drawn. Nothing in this file is part of a Release build.
///
/// Launch arguments:
/// - `-OriveoModelOptionsSample <name>`: after launch the app shows only this sample instead of the main interface,
///   without an account, network or real conversation.
/// - `-OriveoModelOptionsAppearance light|dark`: forces the appearance; follows the system when omitted.
///
/// Example: `xcrun simctl launch <udid> <bundle id> -OriveoModelOptionsSample states-03
/// -OriveoModelOptionsAppearance dark`
///
/// The facts in a sample are fixtures, but every row drawn goes through `ModelOptionsPanelModel.make` and
/// `ModelOptionCapabilityCard.resolve`, and the shell is the `ModelOptionsSheetScaffold` the real panel uses,
/// so the shape and height seen are what these facts look like on the real panel.
enum ModelOptionsSample {
    static let sampleArgument = "-OriveoModelOptionsSample"
    static let appearanceArgument = "-OriveoModelOptionsAppearance"
    /// `-OriveoModelOptionsSamplePush <seconds>`: that long after a panel sample appears, push the advanced
    /// settings sample from it, then pop back 2.5 seconds later. Records both transitions of the sheet.
    static let pushArgument = "-OriveoModelOptionsSamplePush"

    /// Panel samples: two full pages plus the capability card shapes.
    static let panelNames = ["main", "local"] + (1...12).map { String(format: "states-%02d", $0) }
    /// Samples of advanced settings and the additional request body; those pages build them from their own fixtures.
    static let advancedNames = AdvancedSettingsSamples.Name.allCases.map(\.rawValue)

    static var requestedName: String? { value(after: sampleArgument) }

    static var requestedPushDelay: Double? { value(after: pushArgument).flatMap(Double.init) }

    static var requestedColorScheme: ColorScheme? {
        switch value(after: appearanceArgument) {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private static func value(after name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("-") ? nil : value
    }

    // MARK: - Fixtures

    private typealias Input = ModelOptionCapabilityShape.Input

    static func facts(named name: String) -> ModelOptionsPanelFacts? {
        switch name {
        case "main":
            // A model on OpenRouter: web search off, thinking with an Automatic level that cannot be turned off, four items changed in advanced settings.
            return official(
                model: "DeepSeek V4.1 Flash", connection: "OpenRouter",
                web: webOff(),
                reasoning: tiers(["automatic", "low", "deep", "max"], selected: nil),
                advancedRows: [
                    row("temperature", "0.7"), row("max_output_tokens", "4096"),
                    row("top_p", "0.9"), row("seed", "42"),
                ]
            )
        case "local":
            // A local llama.cpp server with no official configuration.
            return custom(
                model: "qwen3-8b-instruct-q4", connection: "My llama.cpp",
                engineProfile: "llamacpp", apiRoot: "http://127.0.0.1:8080",
                advancedRows: [
                    row("mirostat", "v2"), row("temperature", "0.7"), row("top_k", "40"),
                    row("min_p", "0.05"), row("repeat_penalty", "1.1"),
                ]
            )
        case "states-01":
            // On and off only: a plain toggle.
            return official(
                model: "GLM-4.6", connection: "Zhipu",
                web: webOff(), reasoning: tiers(["off", "balanced"], selected: "balanced")
            )
        case "states-02":
            // Several levels, can be turned off.
            return official(
                model: "DeepSeek Reasoner", connection: "DeepSeek",
                web: webOff(), reasoning: tiers(["off", "low", "deep", "max"], selected: "off")
            )
        case "states-03":
            // Several levels, cannot be turned off.
            return official(
                model: "Claude Fable 5", connection: "Anthropic", protocolLabel: "Messages",
                web: webOff(), reasoning: tiers(["low", "balanced", "deep", "max"], selected: "balanced")
            )
        case "states-04":
            // No official configuration yet.
            return official(
                model: "Qwen3.6 Plus", connection: "Qwen",
                web: webOff(), reasoning: Input(capability: .reasoning, presentation: .pending)
            )
        case "states-05":
            // The model itself does not think.
            return official(
                model: "DeepSeek Chat", connection: "DeepSeek",
                web: webOff(), reasoning: Input(capability: .reasoning, presentation: .unsupported)
            )
        case "states-06":
            // Web search on: an extra timing row.
            return official(
                model: "GPT-5 Pro", connection: "OpenAI", protocolLabel: "Responses",
                web: Input(
                    capability: .web, presentation: .automaticAvailable,
                    availableIntents: ["force"], selectedIntent: "automatic"
                ),
                reasoning: tiers(["low", "balanced", "deep", "max"], selected: "balanced")
            )
        case "states-07":
            // Web search needs manual setup.
            return official(
                model: "Llama 4 Scout", connection: "Groq",
                web: Input(capability: .web, presentation: .customOnly),
                reasoning: Input(capability: .reasoning, presentation: .unsupported)
            )
        case "states-08":
            // The model cannot search the web.
            return official(
                model: "DeepSeek Reasoner", connection: "DeepSeek",
                web: Input(capability: .web, presentation: .unsupported),
                reasoning: tiers(["off", "low", "deep", "max"], selected: "deep")
            )
        case "states-10":
            // Custom LLM: the protocol is undecided.
            return ModelOptionsPanelFacts(
                modelName: "my-model", connectionName: "My Server", protocolLabel: nil,
                web: Input(
                    capability: .web, presentation: .unknown, connection: .custom,
                    isWritable: false, protocolUndecided: true
                ),
                reasoning: Input(
                    capability: .reasoning, presentation: .unknown, connection: .custom,
                    isWritable: false, protocolUndecided: true
                )
            )
        case "states-11":
            // Custom LLM / local engine.
            return custom(model: "qwen3-8b-instruct-q4", connection: "My Server", advancedRows: [])
        case "states-12":
            // The provider rejected this item: the panel is reopened after the selection already went back to Balanced.
            return official(
                model: "Claude Fable 5", connection: "Anthropic", protocolLabel: "Messages",
                web: webOff(),
                reasoning: Input(
                    capability: .reasoning, presentation: .automaticAvailable,
                    availableIntents: ["low", "balanced", "deep", "max"],
                    selectedIntent: "balanced", rejectedIntents: ["max"]
                )
            )
        default:
            return nil
        }
    }

    private static func official(
        model: String, connection: String, protocolLabel: String = "Chat Completions",
        web: Input, reasoning: Input, advancedRows: [GenerationParameterRowModel] = []
    ) -> ModelOptionsPanelFacts {
        .init(
            modelName: model, connectionName: connection, protocolLabel: protocolLabel,
            web: web, reasoning: reasoning, advancedRows: advancedRows
        )
    }

    private static func custom(
        model: String, connection: String, engineProfile: String? = nil, apiRoot: String? = nil,
        advancedRows: [GenerationParameterRowModel]
    ) -> ModelOptionsPanelFacts {
        .init(
            modelName: model, connectionName: connection, protocolLabel: "Chat Completions",
            engineProfile: engineProfile, apiRoot: apiRoot,
            web: Input(capability: .web, presentation: .unknown, connection: .custom),
            reasoning: Input(capability: .reasoning, presentation: .unknown, connection: .custom),
            advancedRows: advancedRows
        )
    }

    private static func webOff() -> Input {
        Input(capability: .web, presentation: .automaticAvailable, selectedIntent: "off")
    }

    private static func tiers(_ intents: [String], selected: String?) -> Input {
        Input(
            capability: .reasoning, presentation: .automaticAvailable,
            availableIntents: intents, selectedIntent: selected
        )
    }

    private static func row(_ id: String, _ value: String) -> GenerationParameterRowModel {
        .init(
            id: id, title: GenerationParameterVocabulary.title(id), displayValue: value, source: .conversation
        )
    }
}

/// The host of a sample: a dimmed fake chat page with the panel presented over it as a real modal.
struct ModelOptionsSampleHost: View {
    let name: String

    @State private var path: [ModelControlsRoute] = []

    var body: some View {
        Group {
            if let facts = ModelOptionsSample.facts(named: name) {
                fakeChat
                    .sheet(isPresented: .constant(true)) {
                        ModelOptionsSheetScaffold(path: $path) {
                            ModelOptionsPanel(model: ModelOptionsPanelModel.make(facts)) { _ in }
                        } destination: { _ in
                            AdvancedSettingsSamples.view(.advanced)
                        }
                        .task {
                            guard let delay = ModelOptionsSample.requestedPushDelay else { return }
                            try? await Task.sleep(for: .seconds(delay))
                            path = [.modelBehavior]
                            try? await Task.sleep(for: .seconds(2.5))
                            path = []
                        }
                        .presentationDragIndicator(.visible)
                        .interactiveDismissDisabled()
                        .preferredColorScheme(ModelOptionsSample.requestedColorScheme)
                    }
            } else if let page = AdvancedSettingsSamples.Name(rawValue: name) {
                // Advanced settings and the additional request body: the same look as through the real entry, the page that fills the screen after being pushed from the panel.
                fakeChat
                    .sheet(isPresented: .constant(true)) {
                        NavigationStack {
                            AdvancedSettingsSamples.view(page)
                        }
                        .presentationDetents([.large])
                        .presentationCornerRadius(30)
                        .presentationDragIndicator(.visible)
                        .interactiveDismissDisabled()
                        .preferredColorScheme(ModelOptionsSample.requestedColorScheme)
                    }
            } else {
                message(
                    "Unknown sample “\(name)”.\n"
                        + (ModelOptionsSample.panelNames + ModelOptionsSample.advancedNames)
                        .joined(separator: ", ")
                )
            }
        }
        .preferredColorScheme(ModelOptionsSample.requestedColorScheme)
    }

    /// Only there so the modal has something to dim: a few bubbles without content, reading no real data.
    private var fakeChat: some View {
        VStack(alignment: .leading, spacing: 14) {
            bubble(width: 220, height: 44, isUser: true)
            bubble(width: 300, height: 96, isUser: false)
            bubble(width: 180, height: 44, isUser: true)
            bubble(width: 280, height: 132, isUser: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OriveoTheme.Palette.background.ignoresSafeArea())
        .accessibilityHidden(true)
    }

    private func bubble(width: CGFloat, height: CGFloat, isUser: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isUser ? OriveoTheme.Palette.userBubble : OriveoTheme.Palette.assistantBubble)
            .frame(width: width, height: height)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(OriveoTheme.Palette.textSecondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OriveoTheme.Palette.background.ignoresSafeArea())
    }
}
#endif
