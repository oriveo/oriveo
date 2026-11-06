import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { LIGHT_BRAND_PRESETS, providerTextTint as sharedProviderTextTint } from '@oriveo/shared';
import { FALLBACK_PALETTE, RELAY_PALETTE, TINTS, providerTextTint, providerTint } from './provider-tints';
import { PROVIDER_BRAND_COLORS } from '../../lib/constants/provider-brand-colors';
import { heroPillLabelColor, hsbAdjusted } from '../../app/providers/[providerId]/components/ProviderDetailBrandHero';

/**
 * Monochrome brands (xAI / Grok) used a hard-coded near-black hex, which made
 * their dot and donut slice invisible on the dark theme surface. They must
 * resolve to a theme-following token instead of a fixed color.
 */
describe('providerTint', () => {
  it('monochrome brands follow the theme text token instead of a fixed hex', () => {
    expect(providerTint('grok')).toBe('var(--o-text)');
    expect(providerTint('xai')).toBe('var(--o-text)');
    expect(providerTint('xAI', 'p-1')).toBe('var(--o-text)');
    expect(providerTint(' Grok ')).toBe('var(--o-text)');
  });

  it('chromatic brands keep their brand hex', () => {
    expect(providerTint('openai')).toBe('#10a37f');
    expect(providerTint('openAI')).toBe('#10a37f');
    expect(providerTint('anthropic')).toBe('#c7956d');
  });

  it('no provider tint is a near-black literal that disappears on dark surfaces', () => {
    const kinds = ['openai', 'anthropic', 'gemini', 'deepseek', 'grok', 'xai', 'mistral', 'groq', 'qwen', 'moonshot', 'openrouter'];
    for (const kind of kinds) {
      const tint = providerTint(kind);
      const m = /^#([0-9a-f]{6})$/i.exec(tint);
      if (!m) continue;
      const n = parseInt(m[1], 16);
      const lum = 0.2126 * (n >> 16) + 0.7152 * ((n >> 8) & 0xff) + 0.0722 * (n & 0xff);
      expect(lum, `${kind} tint ${tint} is too dark for the dark theme`).toBeGreaterThan(40);
    }
  });
});

// Provider text tint (shared fixture provider-text-tint.v1.json).
const fixture = JSON.parse(
  readFileSync(resolve(process.cwd(), '../../../shared/test-fixtures/provider-tint/provider-text-tint.v1.json'), 'utf8'),
) as { pillLabel: { worstBackground: string }; cases: { id: string; brand: string; light: string; dark: string }[] };

function luminance(hex: string): number {
  const ch = [1, 3, 5].map((i) => {
    const s = parseInt(hex.slice(i, i + 2), 16) / 255;
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
}
function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

describe('providerTextTint', () => {
  it('providerTextTintPalettesMatchFixture', () => {
    const palettes: Record<string, string | undefined> = {};
    for (const [kind, hex] of Object.entries(TINTS)) palettes[`brand.${kind}`] = hex;
    RELAY_PALETTE.forEach((hex, i) => { palettes[`relay.${i}`] = hex; });
    FALLBACK_PALETTE.forEach((hex, i) => { palettes[`fallback.${i}`] = hex; });
    let compared = 0;
    for (const c of fixture.cases) {
      const local = palettes[c.id];
      // entries this port lacks, and monochrome brands that resolve to a CSS variable, are skipped
      if (!local || !local.startsWith('#')) continue;
      expect(local.toUpperCase(), c.id).toBe(c.brand.toUpperCase());
      compared += 1;
    }
    expect(compared).toBeGreaterThanOrEqual(25);
  });

  it('kind entry resolves like providerTint and swaps only the last step', () => {
    expect(providerTextTint('openAI', null, false)).toBe(sharedProviderTextTint('#10a37f', false));
    expect(providerTextTint('openai', null, true)).toBe(sharedProviderTextTint('#10a37f', true));
    expect(providerTextTint('relay', 'relay-7', false)).toBe(sharedProviderTextTint(providerTint('relay', 'relay-7'), false));
    expect(providerTextTint(undefined, 'p-unknown', true)).toBe(sharedProviderTextTint(providerTint(undefined, 'p-unknown'), true));
    // monochrome brands keep their theme-following CSS variable
    expect(providerTextTint('xAI', 'p-1', true)).toBe('var(--o-text)');
    expect(providerTextTint('grok', null, false)).toBe('var(--o-text)');
    // a light-mode green that fails on white gets darkened
    expect(providerTextTint('openai', null, false)).not.toBe('#10A37F');
  });

  it('heroPillLabelMeetsContrast', () => {
    const pill = fixture.pillLabel.worstBackground;
    const sources: [string, string][] = [
      ...Object.entries(PROVIDER_BRAND_COLORS).map(([kind, pair]) => [`brand ${kind}`, pair.light] as [string, string]),
      ...Object.entries(LIGHT_BRAND_PRESETS).map(([id, brand]) => [`relay light ink ${id}`, brand.ink] as [string, string]),
    ];
    for (const [label, raw] of sources) {
      const hsb = hsbAdjusted(raw, 0.62, 0.88);
      const final = heroPillLabelColor(hsb);
      expect(contrast(final, pill), `${label}: ${raw} -> ${final}`).toBeGreaterThanOrEqual(4.5);
    }
  });
});

