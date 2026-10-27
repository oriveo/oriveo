import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { beforeAll, describe, expect, it } from 'vitest';

/**
 * The 7 dark palettes: variables.css must equal the shared JSON value for value.
 */
const REPO_ROOT = join(process.cwd(), '../../..');
const CSS_PATH = join(REPO_ROOT, 'web/packages/ui/src/tokens/variables.css');
const JSON_PATH = join(REPO_ROOT, 'shared/theme-contracts/dark-palettes.v1.json');

const FIELD_TO_VAR: Record<string, string> = {
  bg: 'bg',
  bgSubtle: 'bg-subtle',
  bgInset: 'bg-inset',
  surface: 'surface',
  surfaceRaised: 'surface-raised',
  text: 'text',
  textSecondary: 'text-secondary',
  textTertiary: 'text-tertiary',
  primary: 'primary',
  primaryHover: 'primary-hover',
  primaryActive: 'primary-active',
  accent: 'accent',
  onPrimary: 'on-primary',
  codeBg: 'code-bg',
  codeHeaderBg: 'code-header-bg',
};
const STATUS_TO_VAR: Record<string, string> = { success: 'success', warning: 'warning', error: 'error', info: 'info' };
// JSON field to CSS variable name (derived tokens may only reference variables, never hard-coded colors)
const FIELD_VAR = (field: string) => `var(--o-${FIELD_TO_VAR[field]})`;

interface PaletteJson {
  defaultId: string;
  order: string[];
  palettes: Record<string, Record<string, string | number>>;
  shared: { status: Record<string, string> };
  derived: Record<string, { from?: string; alpha?: number; angleDeg?: number; stops?: string[] } & Record<string, unknown>>;
}

const css = readFileSync(CSS_PATH, 'utf8');
const json = JSON.parse(readFileSync(JSON_PATH, 'utf8')) as PaletteJson;

/**
 * Pull a hex value (`--o-<name>: #RRGGBB`) out of the first block that follows `selectorRe`.
 * Returns the upper-case hex without `#`, or null when the block or the variable is missing.
 */
function extractHexFromBlock(content: string, selectorRe: RegExp, cssVarName: string): string | null {
  const selector = content.match(selectorRe);
  if (!selector || selector.index === undefined) return null;
  const blockStart = selector.index + selector[0].length;
  const blockEnd = content.indexOf('}', blockStart);
  const m = content.slice(blockStart, blockEnd).match(new RegExp(`--o-${cssVarName}\\s*:\\s*#([0-9A-Fa-f]{6})\\b`));
  return m ? m[1].toUpperCase() : null;
}

function extractWebDark(content: string, cssVarName: string) {
  return extractHexFromBlock(content, /(^|\n)\s*\[data-theme=['"]dark['"]\]\s*\{/, cssVarName);
}

function extractWebPalette(content: string, id: string, cssVarName: string) {
  const re = new RegExp(`(^|\\n)\\s*\\[data-theme=['"]dark['"]\\]\\[data-palette=['"]${id.replace(/-/g, '\\-')}['"]\\]\\s*\\{`);
  return extractHexFromBlock(content, re, cssVarName);
}

/** Extract every palette field for every palette from variables.css. */
function extractAll(): Record<string, Record<string, string | null>> {
  const vars = [...Object.values(FIELD_TO_VAR), ...Object.values(STATUS_TO_VAR)];
  const out: Record<string, Record<string, string | null>> = {};
  for (const id of json.order) {
    out[id] = {};
    for (const v of vars) {
      out[id][v] = id === json.defaultId ? extractWebDark(css, v) : extractWebPalette(css, id, v);
    }
  }
  return out;
}

let extracted: Record<string, Record<string, string | null>>;

beforeAll(() => {
  extracted = extractAll();
});

function block(selector: string): string {
  const start = css.indexOf(`\n${selector} {`);
  if (start < 0) throw new Error(`variables.css has no ${selector}`);
  return css.slice(start, css.indexOf('}', start));
}
const defaultBlock = () => block("[data-theme='dark']");
const paletteBlock = (id: string) => block(`[data-theme='dark'][data-palette='${id}']`);

function declaration(source: string, name: string): string | null {
  const m = new RegExp(`--o-${name}\\s*:\\s*([^;]+);`).exec(source);
  return m ? m[1].replace(/\s+/g, ' ').trim() : null;
}

const mix = (from: string, alpha: number) => `color-mix(in srgb, ${FIELD_VAR(from)} ${Math.round(alpha * 100)}%, transparent)`;

describe('palette_instances_equal_json', () => {
  it('order and defaultId have not drifted (preferences and the theme menu depend on this order)', () => {
    expect(json.defaultId).toBe('dark');
    expect(json.order).toHaveLength(7);
  });

  it.each(json.order)('%s: the 15 color fields equal the JSON value for value', (id) => {
    const palette = json.palettes[id];
    const drift: string[] = [];
    for (const [field, cssVar] of Object.entries(FIELD_TO_VAR)) {
      const actual = extracted[id][cssVar];
      const expected = String(palette[field]).replace('#', '').toUpperCase();
      if (actual !== expected) drift.push(`${field} (--o-${cssVar}) = ${actual ?? 'missing'}, expected ${expected}`);
    }
    expect(drift).toEqual([]);
  });

  it.each(json.order)('%s: --o-glow-k equals the JSON glowK', (id) => {
    const source = id === json.defaultId ? defaultBlock() : paletteBlock(id);
    expect(Number(declaration(source, 'glow-k'))).toBe(json.palettes[id].glowK);
  });

  it('the 4 status colors in the default section equal JSON shared.status', () => {
    for (const [field, cssVar] of Object.entries(STATUS_TO_VAR)) {
      expect(extracted[json.defaultId][cssVar], field).toBe(json.shared.status[field].replace('#', '').toUpperCase());
    }
  });

  it('non-default palette sections write only the 15 fields + --o-glow-k, and derived tokens are not repeated inside the section', () => {
    const allowed = new Set([...Object.values(FIELD_TO_VAR), 'glow-k']);
    for (const id of json.order.filter((x) => x !== json.defaultId)) {
      const names = [...paletteBlock(id).matchAll(/--o-([a-z0-9-]+)\s*:/g)].map((m) => m[1]);
      expect(names.filter((n) => !allowed.has(n)), id).toEqual([]);
      expect(names).toHaveLength(allowed.size);
    }
  });
});

describe('derived_tokens_follow_json', () => {
  const d = () => json.derived;

  it('alpha-derived tokens reference only the current palette variables, and the alpha equals the JSON', () => {
    const src = defaultBlock();
    const cases: Array<[string, string]> = [
      ['primary-subtle', mix(d().primarySubtle.from!, d().primarySubtle.alpha!)],
      ['accent-subtle', mix(d().accentSubtle.from!, d().accentSubtle.alpha!)],
      ['primary-glow', mix(d().primaryGlow.from!, d().primaryGlow.alpha!)],
      ['composer-border', mix(d().composerBorder.from!, d().composerBorder.alpha!)],
      ['surface-overlay', mix(d().surfaceOverlay.from!, d().surfaceOverlay.alpha!)],
      ['focus-ring', `0 0 0 2px ${mix(d().focusRing.from!, d().focusRing.alpha!)}`],
    ];
    for (const [name, expected] of cases) expect(declaration(src, name), name).toBe(expected);
  });

  it('gradientBrand = 135° primary → accent', () => {
    const { angleDeg, stops } = d().gradientBrand;
    expect(declaration(defaultBlock(), 'gradient-brand')).toBe(
      `linear-gradient(${angleDeg}deg, ${stops!.map(FIELD_VAR).join(', ')})`,
    );
  });

  it('the four aurora layers follow the JSON from/alpha and are multiplied by glowK', () => {
    const aurora = d().aurora as Record<string, { from: string; alpha: number }> & { scaleBy: string };
    expect(aurora.scaleBy).toBe('glowK');
    const value = declaration(defaultBlock(), 'chat-aurora-glow-bg') ?? '';
    for (const layer of ['bottom', 'bottomLeft', 'bottomRight', 'top']) {
      const { from, alpha } = aurora[layer];
      expect(value, layer).toContain(
        `color-mix(in srgb, ${FIELD_VAR(from)} calc(${Math.round(alpha * 100)}% * var(--o-glow-k)), transparent)`,
      );
    }
  });

  it('the default dark section no longer hard-codes any field value of the old default (dark-purple)', () => {
    const old = json.palettes['dark-purple'];
    const current = json.palettes[json.defaultId];
    // Look at declarations only: old values quoted in comments for contrast notes do not count
    const src = defaultBlock().replace(/\/\*[\s\S]*?\*\//g, '').toUpperCase();
    const leftovers = Object.keys(FIELD_TO_VAR)
      .map((field) => String(old[field]).toUpperCase())
      // Fields with the same value as the new default (primary etc.) are supposed to be written literally in this section
      .filter((hex) => !Object.keys(FIELD_TO_VAR).some((f) => String(current[f]).toUpperCase() === hex))
      .filter((hex) => src.includes(hex));
    expect(leftovers).toEqual([]);
  });
});

/**
 * Expand a token under a given palette into literal values: the palette section overrides the 15 fields + glow-k, the rest of the derived tokens come from the default dark section,
 * var() is substituted recursively, and calc(N% * k) is evaluated to a percentage. Same order as the browser cascade (the palette section's selector is more specific).
 */
function resolveToken(id: string, name: string): string {
  const own = id === json.defaultId ? '' : paletteBlock(id);
  const base = defaultBlock().replace(/\/\*[\s\S]*?\*\//g, '');
  const lookup = (n: string): string => {
    const v = (id === json.defaultId ? null : declaration(own, n)) ?? declaration(base, n);
    if (v == null) throw new Error(`--o-${n} is not defined`);
    return v.replace(/var\(--o-([a-z0-9-]+)\)/g, (_m, inner: string) => lookup(inner));
  };
  return lookup(name).replace(/calc\(([\d.]+)% \* ([\d.]+)\)/g, (_m, pct: string, k: string) => `${+(Number(pct) * Number(k)).toFixed(4)}%`);
}

describe('palette_follow_user_bubble_and_aurora', () => {
  const ocean = () => json.palettes['dark-ocean'];

  it('dark-ocean: user bubble gradient ends == ocean primary / accent, text color == onPrimary, shadow uses primary-glow', () => {
    expect(resolveToken('dark-ocean', 'user-bubble-bg').toUpperCase()).toBe(
      `LINEAR-GRADIENT(135DEG, ${ocean().primary}, ${ocean().accent})`.toUpperCase(),
    );
    expect(resolveToken('dark-ocean', 'user-bubble-fg').toUpperCase()).toBe(String(ocean().onPrimary).toUpperCase());
    expect(resolveToken('dark-ocean', 'user-bubble-shadow').toUpperCase()).toContain(
      `0 6PX 16PX COLOR-MIX(IN SRGB, ${ocean().primary} 35%, TRANSPARENT)`.toUpperCase(),
    );
  });

  it.each(json.order)('%s: bottom glow layer == primary x 0.26 x glowK', (id) => {
    const p = json.palettes[id];
    const pct = +(26 * Number(p.glowK)).toFixed(4);
    expect(resolveToken(id, 'chat-aurora-glow-bg').toUpperCase()).toContain(
      `AT 50% 100%, COLOR-MIX(IN SRGB, ${p.primary} ${pct}%, TRANSPARENT)`.toUpperCase(),
    );
  });

  it('the second blob group / halftone dots / screen background in the default dark section no longer hard-code colors', () => {
    for (const name of ['chat-aurora-glow-bg-2', 'chat-aurora-halftone-dot', 'screen-bg', 'lc-aurora', 'user-bubble-bg', 'user-bubble-fg', 'chat-outline-tooltip-bg', 'tab-teal', 'tab-orange']) {
      expect(declaration(defaultBlock(), name) ?? '', name).not.toMatch(/#[0-9a-f]{3,8}\b|rgba?\(/i);
    }
  });
});

describe('palette_follow_inline_code', () => {
  it.each(['dark-forest', 'dark-sunset', json.defaultId])('%s: inline code text == the palette accent, background == white 7%%', (id) => {
    expect(resolveToken(id, 'code-inline-text').toUpperCase()).toBe(String(json.palettes[id].accent).toUpperCase());
    expect(resolveToken(id, 'code-inline-bg')).toBe('rgba(255, 255, 255, 0.07)');
  });

  it('inline code in the light section keeps the code block background + body text color (light has no --o-accent, so it must not reference it)', () => {
    const light = block(":root,\n[data-theme='light']");
    expect(declaration(light, 'code-inline-bg')).toBe('var(--o-code-bg)');
    expect(declaration(light, 'code-inline-text')).toBe('var(--o-code-text)');
  });
});
