import SwiftUI

// MARK: - Vendor Icon

struct ModelVendorIcon: View {
    let groupKey: String?
    let groupName: String?
    var size: CGFloat = 36

    init(model: AIModel, size: CGFloat = 36) {
        groupKey = model.groupKey
        groupName = model.groupName ?? model.name
        self.size = size
    }

    init(groupKey: String?, groupName: String?, size: CGFloat = 36) {
        self.groupKey = groupKey
        self.groupName = groupName
        self.size = size
    }

    var body: some View {
        if let assetName {
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(backgroundColor)
                .overlay {
                    Text(monogram)
                        .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                        .foregroundStyle(foregroundColor)
                }
                .frame(width: size, height: size)
        }
    }

    private var normalizedGroupKey: String {
        ModelVendorIconResolver.normalizedKey(for: groupKey)
    }

    private var assetName: String? {
        ModelVendorIconResolver.assetName(for: normalizedGroupKey)
    }

    private var monogram: String {
        let words = (groupName ?? "AI")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }

        if words.count >= 2 {
            return String(words.prefix(2).compactMap(\.first)).uppercased()
        }

        let raw = words.first ?? String((groupName ?? "AI").prefix(2))
        return String(raw.prefix(2)).uppercased()
    }

    private var groupHue: Double {
        var hash: UInt64 = 5381
        for byte in normalizedGroupKey.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return Double(hash % 360) / 360.0
    }

    private var backgroundColor: Color {
        switch normalizedGroupKey {
        case "openai":
            return Color.dynamic(light: 0xF4F7F5, dark: 0x1A2420)
        case "anthropic":
            return Color.dynamic(light: 0xF4EFE6, dark: 0x2A2520)
        case "google":
            return Color.dynamic(light: 0xEEF4FF, dark: 0x1A2030)
        case "deepseek":
            return Color.dynamic(light: 0xEEF6FF, dark: 0x1A2230)
        case "meta", "meta-llama":
            return Color.dynamic(light: 0xEEF2FF, dark: 0x1C1E30)
        case "perplexity":
            return Color.dynamic(light: 0xECFEFF, dark: 0x1A2828)
        case "qwen":
            return Color.dynamic(light: 0xFFF7ED, dark: 0x2A2018)
        default:
            if assetName != nil {
                return Color.dynamic(light: 0xF8FAFC, dark: 0x1E2433)
            }
            return Color(hue: groupHue, saturation: 0.08, brightness: 0.97)
        }
    }

    private var foregroundColor: Color {
        switch normalizedGroupKey {
        case "deepseek":
            return Color.dynamic(light: 0x2563EB, dark: 0x60A5FA)
        case "meta", "meta-llama":
            return Color.dynamic(light: 0x4F46E5, dark: 0xA5B4FC)
        case "perplexity":
            return Color.dynamic(light: 0x0F766E, dark: 0x5EEAD4)
        case "qwen":
            return Color.dynamic(light: 0xC2410C, dark: 0xFB923C)
        default:
            if assetName != nil {
                return OriveoTheme.Palette.textPrimary
            }
            return Color(hue: groupHue, saturation: 0.6, brightness: 0.45)
        }
    }
}

enum ModelVendorIconResolver {
    static func normalizedKey(for groupKey: String?) -> String {
        switch groupKey?.lowercased() ?? "other" {
        case "google-gemini", "gemini": return "google"
        case "xai-grok": return "x-ai"
        case "kimi": return "moonshotai"
        case "zhipu-glm", "zhipu": return "zai"
        default: return groupKey?.lowercased() ?? "other"
        }
    }

    static func assetName(for groupKey: String?) -> String? {
        switch normalizedKey(for: groupKey) {
        case "openai":          return "ProviderOpenAI"
        case "anthropic":       return "ProviderAnthropic"
        case "google":          return "ProviderGemini"
        case "openrouter":      return "ProviderOpenRouter"
        case "deepseek", "deepseek-ai": return "ProviderDeepSeek"
        case "meta", "meta-llama": return "VendorMeta"
        case "mistralai":       return "VendorMistral"
        case "perplexity":      return "VendorPerplexity"
        case "qwen":            return "ProviderQwen"
        case "microsoft":       return "VendorMicrosoft"
        case "nvidia":          return "VendorNVIDIA"
        case "bytedance-seed", "bytedance": return "VendorByteDance"
        case "minimax", "minimaxai", "minimax-ai", "minimaxi": return "ProviderMiniMax"
        case "stepfun":         return "VendorStepfun"
        case "upstage":         return "VendorUpstage"
        case "aion-labs":       return "VendorAionLabs"
        case "baidu":           return "VendorBaidu"
        case "allenai":         return "VendorAI2"
        case "arcee-ai":        return "VendorArcee"
        case "cohere":          return "VendorCohere"
        case "together":        return "ProviderTogether"
        case "fireworksai":     return "ProviderFireworks"
        case "cerebras":        return "VendorCerebras"
        case "sambanova":       return "VendorSambaNova"
        case "huggingface":     return "VendorHuggingFace"
        case "alibaba":         return "VendorAlibaba"
        case "deepcogito":      return "VendorDeepCogito"
        case "essentialai":     return "VendorEssentialAI"
        case "kwaipilot":       return "VendorKwaiPilot"
        case "morph":           return "VendorMorph"
        case "tencent":         return "VendorTencent"
        case "amazon":          return "VendorAWS"
        case "x-ai":            return "ProviderGrok"
        case "moonshotai":      return "ProviderKimi"
        case "inception":       return "VendorInception"
        case "ai21":            return "VendorAI21"
        case "nousresearch":    return "VendorNousResearch"
        case "inflection":      return "VendorInflection"
        case "xiaomi":          return "VendorXiaomi"
        case "liquid":          return "VendorLiquid"
        case "manus":           return "VendorManus"
        case "relace":          return "VendorRelace"
        case "ibm-granite":     return "VendorIBM"
        case "zai", "z-ai", "zai-org", "thudm": return "ProviderZAI"
        default:                return nil
        }
    }
}
