import { describe, expect, it } from 'vitest';

import {
  getProviderDisplayName,
  PROVIDER_DISPLAY_NAMES,
  providerDefaults,
} from './providers';

describe('provider display names', () => {
  it('uses Z.ai as the shared display name for zhipu', () => {
    expect(PROVIDER_DISPLAY_NAMES.zhipu).toBe('Z.ai');
    expect(getProviderDisplayName('zhipu')).toBe('Z.ai');
    expect(providerDefaults.zhipu.displayName).toBe('Z.ai');
    expect(providerDefaults.zhipu.shortName).toBe('Z.ai');
  });

  it('exposes DeepSeek defaults from the shared provider config', () => {
    expect(PROVIDER_DISPLAY_NAMES.deepseek).toBe('DeepSeek');
    expect(getProviderDisplayName('deepseek')).toBe('DeepSeek');
    expect(providerDefaults.deepseek.displayName).toBe('DeepSeek');
    expect(providerDefaults.deepseek.defaultBaseURL).toBe('https://api.deepseek.com/v1');
  });
});
