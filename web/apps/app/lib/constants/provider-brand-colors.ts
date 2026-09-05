// Brand accent color per provider, used for card tints, metrics icons and charts.
export const PROVIDER_BRAND_COLORS: Record<
  string,
  { light: string; dark: string }
> = {
  openAI: { light: "#10A37F", dark: "#22C18D" },
  anthropic: { light: "#C7956D", dark: "#E0B58E" },
  gemini: { light: "#4285F4", dark: "#7AB2FF" },
  openRouter: { light: "#6D63FF", dark: "#9B93FF" },
  deepseek: { light: "#4F7BFF", dark: "#7EA2FF" },
  mistral: { light: "#FA500F", dark: "#FF8205" },
  groq: { light: "#F55036", dark: "#FF8A74" },
  togetherAI: { light: "#0EA5E9", dark: "#38BDF8" },
  fireworksAI: { light: "#FF6B35", dark: "#FF9B6B" },
  miniMax: { light: "#E8457C", dark: "#FF6B8A" },
  zhipu: { light: "#333333", dark: "#A0A0A8" },
  qwen: { light: "#6C63FF", dark: "#A29BFF" },
  siliconFlow: { light: "#7C3AED", dark: "#A78BFA" },
  relay: { light: "#64748B", dark: "#94A3B8" },
};
