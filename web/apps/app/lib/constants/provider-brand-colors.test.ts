import { describe, expect, it } from 'vitest';
import { PROVIDER_BRAND_COLORS } from './provider-brand-colors';

describe('PROVIDER_BRAND_COLORS', () => {
  it('defines DeepSeek accent colors to match mobile provider cards', () => {
    expect(PROVIDER_BRAND_COLORS.deepseek).toEqual({
      light: '#4F7BFF',
      dark: '#7EA2FF',
    });
  });
});
