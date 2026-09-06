export interface ProviderDefault {
  displayName: string;
  shortName: string;
  apiKeyPlaceholder: string;
  defaultBaseURL: string;
  keyHelpUrl: string;
}

/** Relay has no fixed defaults and uses the separate RelaySetup form. */
export type OfficialProviderKind =
  | "openAI"
  | "anthropic"
  | "gemini"
  | "openRouter"
  | "deepseek"
  | "grok"
  | "mistral"
  | "miniMax"
  | "zhipu"
  | "qwen"
  | "moonshot"
  | "siliconFlow";

/** Third-party aggregators using the OpenAI-compatible format. */
export type AggregatorProviderKind = "groq" | "togetherAI" | "fireworksAI";

/** Every provider that has a fixed default configuration. */
export type ConfiguredProviderKind =
  | OfficialProviderKind
  | AggregatorProviderKind;

/**
 * Display names for every ProviderKind, including relay.
 * This is the single source of these names, replacing the duplicated maps that used to live in
 * individual files.
 */
export const PROVIDER_DISPLAY_NAMES: Record<string, string> = {
  openAI: "OpenAI",
  anthropic: "Anthropic",
  gemini: "Google Gemini",
  openRouter: "OpenRouter",
  deepseek: "DeepSeek",
  grok: "Grok",
  mistral: "Mistral",
  groq: "Groq",
  togetherAI: "Together AI",
  fireworksAI: "Fireworks AI",
  miniMax: "MiniMax",
  zhipu: "Z.ai",
  qwen: "Qwen",
  moonshot: "Kimi",
  siliconFlow: "SiliconFlow",
  relay: "Relay",
};

export function getProviderDisplayName(kind: string): string {
  return PROVIDER_DISPLAY_NAMES[kind] ?? kind;
}

export const providerDefaults: Record<ConfiguredProviderKind, ProviderDefault> =
  {
    openAI: {
      displayName: "OpenAI",
      shortName: "OpenAI",
      apiKeyPlaceholder: "sk-...",
      defaultBaseURL: "https://api.openai.com/v1",
      keyHelpUrl: "https://platform.openai.com/api-keys",
    },
    anthropic: {
      displayName: "Anthropic",
      shortName: "Claude",
      apiKeyPlaceholder: "sk-ant-...",
      defaultBaseURL: "https://api.anthropic.com/v1",
      keyHelpUrl: "https://platform.claude.com/settings/keys",
    },
    gemini: {
      displayName: "Google Gemini",
      shortName: "Gemini",
      apiKeyPlaceholder: "AIza...",
      defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
      keyHelpUrl: "https://aistudio.google.com/apikey",
    },
    openRouter: {
      displayName: "OpenRouter",
      shortName: "OpenRouter",
      apiKeyPlaceholder: "sk-or-...",
      defaultBaseURL: "https://openrouter.ai/api/v1",
      keyHelpUrl: "https://openrouter.ai/keys",
    },
    deepseek: {
      displayName: "DeepSeek",
      shortName: "DeepSeek",
      apiKeyPlaceholder: "sk-...",
      defaultBaseURL: "https://api.deepseek.com/v1",
      keyHelpUrl: "https://platform.deepseek.com/api_keys",
    },
    grok: {
      displayName: "Grok",
      shortName: "Grok",
      apiKeyPlaceholder: "xai-...",
      defaultBaseURL: "https://api.x.ai/v1",
      keyHelpUrl: "https://console.x.ai/",
    },
    mistral: {
      displayName: "Mistral",
      shortName: "Mistral",
      // Mistral API keys have no fixed prefix, so the placeholder does not hint at one.
      apiKeyPlaceholder: "...",
      defaultBaseURL: "https://api.mistral.ai/v1",
      keyHelpUrl: "https://console.mistral.ai/api-keys",
    },
    groq: {
      displayName: "Groq",
      shortName: "Groq",
      apiKeyPlaceholder: "gsk_...",
      defaultBaseURL: "https://api.groq.com/openai/v1",
      keyHelpUrl: "https://console.groq.com/keys",
    },
    togetherAI: {
      displayName: "Together AI",
      shortName: "Together",
      apiKeyPlaceholder: "sk-...",
      defaultBaseURL: "https://api.together.xyz/v1",
      keyHelpUrl: "https://api.together.xyz/settings/api-keys",
    },
    fireworksAI: {
      displayName: "Fireworks AI",
      shortName: "Fireworks",
      apiKeyPlaceholder: "fw_...",
      defaultBaseURL: "https://api.fireworks.ai/inference/v1",
      keyHelpUrl: "https://fireworks.ai/api-keys",
    },
    miniMax: {
      displayName: "MiniMax",
      shortName: "MiniMax",
      apiKeyPlaceholder: "sk-api-...",
      defaultBaseURL: "https://api.minimax.io/v1",
      keyHelpUrl:
        "https://platform.minimax.io/docs/guides/quickstart-preparation",
    },
    zhipu: {
      displayName: "Z.ai",
      shortName: "Z.ai",
      apiKeyPlaceholder: "sk-xxxxxxxx...",
      defaultBaseURL: "https://open.bigmodel.cn/api/paas/v4",
      keyHelpUrl: "https://open.bigmodel.cn/usercenter/apikeys",
    },
    qwen: {
      displayName: "Qwen",
      shortName: "Qwen",
      apiKeyPlaceholder: "sk-...",
      // DashScope's native origin (chat uses the native path; key validation falls back to the metadata
      // validation contract's probePath=/compatible-mode/v1/models).
      defaultBaseURL: "https://dashscope-intl.aliyuncs.com",
      keyHelpUrl: "https://bailian.console.alibabacloud.com/?apiKey=1#/api-key",
    },
    moonshot: {
      displayName: "Kimi",
      shortName: "Kimi",
      apiKeyPlaceholder: "sk-...",
      defaultBaseURL: "https://api.moonshot.ai/v1",
      keyHelpUrl: "https://platform.kimi.ai/console/api-keys",
    },
    siliconFlow: {
      displayName: "SiliconFlow",
      shortName: "SiliconFlow",
      apiKeyPlaceholder: "sk-...",
      defaultBaseURL: "https://api.siliconflow.cn/v1",
      keyHelpUrl: "https://cloud.siliconflow.cn/account/ak",
    },
  };
