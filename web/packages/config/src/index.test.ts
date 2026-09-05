import { describe, expect, it } from 'vitest';

import {
  brand,
  getProviderDisplayName,
  PROVIDER_DISPLAY_NAMES,
  providerDefaults,
} from './index';

describe('@oriveo/config', () => {
  it('exports brand metadata used across web workspaces', () => {
    expect(brand.name).toBe('Oriveo');
    expect(brand.appUrl).toBe('http://localhost:3001');
    expect(brand.repoUrl.startsWith('https://')).toBe(true);
  });

  it('provides stable defaults for every configured provider', () => {
    expect(Object.keys(providerDefaults)).toEqual(
      expect.arrayContaining([
        'openAI',
        'anthropic',
        'gemini',
        'openRouter',
        'deepseek',
        'groq',
        'togetherAI',
        'fireworksAI',
        'miniMax',
        'zhipu',
        'qwen',
        'moonshot',
        'siliconFlow',
      ]),
    );

    for (const defaults of Object.values(providerDefaults)) {
      expect(defaults.displayName.length).toBeGreaterThan(0);
      expect(defaults.shortName.length).toBeGreaterThan(0);
      expect(defaults.apiKeyPlaceholder.length).toBeGreaterThan(0);
      expect(defaults.defaultBaseURL.startsWith('https://')).toBe(true);
      expect(defaults.keyHelpUrl.startsWith('https://')).toBe(true);
    }

    expect(providerDefaults.openAI.defaultBaseURL).toBe('https://api.openai.com/v1');
    expect(providerDefaults.moonshot.defaultBaseURL).toBe('https://api.moonshot.ai/v1');
    expect(providerDefaults.siliconFlow.keyHelpUrl).toContain('siliconflow');
  });

  it('resolves provider display names from the shared mapping with fallback', () => {
    expect(PROVIDER_DISPLAY_NAMES.relay).toBe('Relay');
    expect(getProviderDisplayName('openAI')).toBe('OpenAI');
    expect(getProviderDisplayName('anthropic')).toBe('Anthropic');
    expect(getProviderDisplayName('customRelay')).toBe('customRelay');
  });
});
