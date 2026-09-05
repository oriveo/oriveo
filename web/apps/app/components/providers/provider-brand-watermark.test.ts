import { describe, expect, it } from 'vitest';
import { resolveProviderWatermark } from './provider-brand-watermark';

describe('resolveProviderWatermark', () => {
  it.each([
    ['openAI', '/plogos/light/openai.png'],
    ['zhipu', '/plogos/light/zai.png'],
    ['siliconFlow', '/plogos/light/siliconflow.png'],
  ])('uses transparent official artwork for %s', (kind, asset) => {
    expect(resolveProviderWatermark(kind)).toEqual({ type: 'mask', asset });
  });

  it('keeps a symbol fallback for Relay', () => {
    expect(resolveProviderWatermark('relay')?.type).toBe('symbol');
  });
});
