export interface ProviderLogoPair {
  light: string;
  dark: string;
}

function themedLogo(slug: string): ProviderLogoPair {
  return {
    light: `/plogos/light/${slug}.png`,
    dark: `/plogos/dark/${slug}.png`,
  };
}

/** Official provider artwork shared by every Web App provider-logo surface. */
export const OFFICIAL_PROVIDER_LOGOS: Record<string, ProviderLogoPair> = {
  openAI: themedLogo('openai'),
  anthropic: themedLogo('anthropic'),
  gemini: themedLogo('gemini'),
  openRouter: themedLogo('openrouter'),
  deepseek: themedLogo('deepseek'),
  grok: themedLogo('grok'),
  mistral: themedLogo('mistral'),
  groq: themedLogo('groq'),
  togetherAI: themedLogo('together'),
  fireworksAI: themedLogo('fireworks'),
  miniMax: themedLogo('minimax'),
  zhipu: themedLogo('zai'),
  qwen: themedLogo('qwen'),
  moonshot: themedLogo('kimi'),
  siliconFlow: themedLogo('siliconflow'),
};

const OFFICIAL_VENDOR_PROVIDER_KIND: Record<string, string> = {
  openai: 'openAI',
  anthropic: 'anthropic',
  google: 'gemini',
  openrouter: 'openRouter',
  deepseek: 'deepseek',
  xai: 'grok',
  // normalizeVendorKey already folds mistralai and mistral into mistral (see VendorIdentity.tsx)
  mistral: 'mistral',
  groq: 'groq',
  together: 'togetherAI',
  fireworks: 'fireworksAI',
  minimax: 'miniMax',
  zai: 'zhipu',
  qwen: 'qwen',
  moonshot: 'moonshot',
  siliconflow: 'siliconFlow',
};

export function resolveOfficialProviderLogo(
  kind: string,
  isDark: boolean,
): string | undefined {
  const pair = OFFICIAL_PROVIDER_LOGOS[kind];
  return pair ? (isDark ? pair.dark : pair.light) : undefined;
}

export function resolveOfficialVendorLogo(
  normalizedVendorKey: string,
  isDark: boolean,
): string | undefined {
  const providerKind = OFFICIAL_VENDOR_PROVIDER_KIND[normalizedVendorKey];
  return providerKind ? resolveOfficialProviderLogo(providerKind, isDark) : undefined;
}
