const PROVIDER_PRICING_URLS: Record<string, string> = {
  openAI: 'https://openai.com/api/pricing/',
  anthropic: 'https://www.anthropic.com/pricing',
  gemini: 'https://ai.google.dev/pricing',
  openRouter: 'https://openrouter.ai/models',
  deepseek: 'https://api-docs.deepseek.com/quick_start/pricing',
  grok: 'https://x.ai/api',
  mistral: 'https://mistral.ai/pricing',
  groq: 'https://groq.com/pricing/',
  togetherAI: 'https://www.together.ai/pricing',
  fireworksAI: 'https://fireworks.ai/pricing',
  miniMax: 'https://www.minimax.io/platform/document/pricing',
  zhipu: 'https://www.bigmodel.cn/pricing',
  qwen: 'https://help.aliyun.com/zh/model-studio/getting-started/models',
  siliconFlow: 'https://siliconflow.com/pricing',
  relay: 'https://platform.openai.com/docs/pricing',
};

const PROVIDER_PRICING_URL_ALIASES: Record<string, string> = {
  openai: 'openAI',
  anthropic: 'anthropic',
  gemini: 'gemini',
  openrouter: 'openRouter',
  deepseek: 'deepseek',
  grok: 'grok',
  mistral: 'mistral',
  groq: 'groq',
  together: 'togetherAI',
  togetherai: 'togetherAI',
  fireworks: 'fireworksAI',
  fireworksai: 'fireworksAI',
  minimax: 'miniMax',
  zhipu: 'zhipu',
  qwen: 'qwen',
  siliconflow: 'siliconFlow',
  relay: 'relay',
};

export function getProviderPricingURL(
  providerKind: string | null | undefined,
): string | undefined {
  if (!providerKind) return undefined;
  if (PROVIDER_PRICING_URLS[providerKind]) {
    return PROVIDER_PRICING_URLS[providerKind];
  }

  const normalized = PROVIDER_PRICING_URL_ALIASES[providerKind.toLowerCase()];
  return normalized ? PROVIDER_PRICING_URLS[normalized] : undefined;
}
