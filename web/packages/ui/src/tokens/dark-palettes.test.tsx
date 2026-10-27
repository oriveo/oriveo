import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { beforeAll, describe, expect, it } from 'vitest';
import { customPaletteCssVars } from '../../../shared/src/theme/custom-palette';
import { LIGHT_BRAND_CSS_VARS, customLightBrandCssVars } from '../../../shared/src/theme/light-brand';

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

  it('non-default palette sections write only the 15 fields + --o-glow-k + bubble stops, and derived tokens are not repeated inside the section', () => {
    const allowed = new Set([...Object.values(FIELD_TO_VAR), 'glow-k', 'user-bubble-stops']);
    for (const id of json.order.filter((x) => x !== json.defaultId)) {
      const names = [...paletteBlock(id).matchAll(/--o-([a-z0-9-]+)\s*:/g)].map((m) => m[1]);
      expect(names.filter((n) => !allowed.has(n)), id).toEqual([]);
      expect(names).toHaveLength(allowed.size);
    }
  });

  it('the variables written for the custom palette use the same keys as a preset section (15 fields + --o-glow-k + bubble stops)', () => {
    const presetNames = [...paletteBlock('dark-ocean').matchAll(/--o-([a-z0-9-]+)\s*:/g)].map((m) => `--o-${m[1]}`).sort();
    expect(Object.keys(customPaletteCssVars('#C084FC')).sort()).toEqual(presetNames);
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

  // The bubble is a 180deg vertical gradient of 7 stops (accent to primary); the old 135deg two-color gradient with a 35% primary outer glow became a tight shadow in the bottom stop color @ 16%
  it('dark-ocean: user bubble vertical stops == userBubbleStops.dark-ocean.dark, text color == onPrimary, shadow = primary @ 16%', () => {
    const stops = (json as unknown as { userBubbleStops: Record<string, { dark: string[] }> }).userBubbleStops['dark-ocean'].dark;
    expect(resolveToken('dark-ocean', 'user-bubble-bg').toUpperCase()).toBe(`LINEAR-GRADIENT(180DEG, ${stops.join(', ')})`.toUpperCase());
    expect(resolveToken('dark-ocean', 'user-bubble-fg').toUpperCase()).toBe(String(ocean().onPrimary).toUpperCase());
    expect(resolveToken('dark-ocean', 'user-bubble-shadow').toUpperCase()).toContain(
      `0 4PX 14PX COLOR-MIX(IN SRGB, ${ocean().primary} 16%, TRANSPARENT)`.toUpperCase(),
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

/**
 * Light brand colors: the light sections of the 6 non-default palettes == the fixture's light.palettes mapped through LIGHT_BRAND_CSS_VARS;
 * the default palette's light section, once expanded, is byte-for-byte what it was before this change (the earlier values are written below).
 */
describe('light_brand_follows_palette', () => {
  const lightJson = (json as unknown as { light: { palettes: Record<string, Record<string, string>> } }).light.palettes;
  const lightRoot = () => block(":root,\n[data-theme='light']").replace(/\/\*[\s\S]*?\*\//g, '');
  const lightPaletteBlock = (id: string) => block(`[data-theme='light'][data-palette='${id}']`);
  const sharedBlock = () => block("[data-theme='light'][data-palette]:not([data-palette='dark'])").replace(/\/\*[\s\S]*?\*\//g, '');

  /** Expand var() in the default light section; color-mix(#hex N%, transparent) and rgba() are normalized to rgba(r, g, b, a) before comparing. */
  const hexRgb = (hex: string) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16)).join(', ');
  const normalize = (v: string) => v
    .replace(/color-mix\(in srgb, (#[0-9a-f]{6}) ([\d.]+)%, transparent\)/gi, (_m, hex: string, pct: string) => `rgba(${hexRgb(hex)}, ${Number(pct) / 100})`)
    .replace(/rgba\((\d+), *(\d+), *(\d+), *([\d.]+)\)/g, (_m, r, g, b, al) => `rgba(${r}, ${g}, ${b}, ${Number(al)})`)
    .toLowerCase();
  const resolveLight = (name: string): string => {
    const lookup = (n: string): string => {
      const v = declaration(lightRoot(), n);
      if (v == null) throw new Error(`--o-${n} is not defined`);
      return v.replace(/var\(--o-([a-z0-9-]+)\)/g, (_m, inner: string) => lookup(inner));
    };
    return normalize(lookup(name));
  };

  // Literal values of the default light section before this change
  const BEFORE: Record<string, string> = {
    primary: '#8B5CF6',
    'primary-hover': '#7C3AED',
    'primary-active': '#6D28D9',
    'primary-subtle': 'rgba(139, 92, 246, 0.08)',
    'primary-text': '#ffffff',
    'primary-text-on-surface': '#6D28D9',
    'primary-text-safe': '#6D28D9',
    // New token: the default light icon-only fill == the previous --o-primary
    'primary-fill': '#8B5CF6',
    // Fill that carries text: default light is likewise == the previous --o-primary (buttons of the default palette must not get darker)
    'primary-fill-text': '#8B5CF6',
    'tab-teal': '#0d9488',
    'tab-orange': '#ea580c',
    'gradient-brand': 'linear-gradient(135deg, #8B5CF6, #7C3AED, #6D28D9)',
    'user-bubble-fg': '#fff',
    'glow-primary': '0 0 0 3px rgba(139, 92, 246, 0.12)',
    'glow-primary-strong': '0 0 0 4px rgba(139, 92, 246, 0.2), 0 0 24px rgba(139, 92, 246, 0.08)',
    'bubble-glow': '0 6px 10px rgba(140, 95, 248, 0.10)',
    'screen-bg': 'linear-gradient(135deg, #FAFBFF, #F6F5FA)',
    'chat-aurora-glow-bg':
      'radial-gradient(ellipse 132% 96% at 50% 108%, color-mix(in srgb, #8B5CF6 16%, transparent) 0%, transparent 74%), radial-gradient(ellipse 92% 82% at 8% 92%, color-mix(in srgb, #6366f1 13%, transparent) 0%, transparent 70%), radial-gradient(ellipse 88% 78% at 92% 96%, color-mix(in srgb, #8b7cf0 11%, transparent) 0%, transparent 68%), radial-gradient(ellipse 122% 74% at 50% -4%, color-mix(in srgb, #8B5CF6 10%, transparent) 0%, transparent 70%)',
    'chat-aurora-glow-bg-2':
      'radial-gradient(ellipse 84% 72% at 26% 72%, color-mix(in srgb, #6366f1 11%, transparent) 0%, transparent 66%), radial-gradient(ellipse 80% 68% at 76% 60%, color-mix(in srgb, #8B5CF6 11%, transparent) 0%, transparent 64%), radial-gradient(ellipse 88% 72% at 50% 42%, color-mix(in srgb, #8b7cf0 10%, transparent) 0%, transparent 66%)',
    'lc-aurora':
      'radial-gradient( 120% 100% at 0% 0%, color-mix(in srgb, #8B5CF6 9%, transparent), transparent 62% ), radial-gradient( 110% 90% at 100% 0%, color-mix(in srgb, #b07bf0 7%, transparent), transparent 58% )',
  };

  it.each(Object.keys(BEFORE))('default light --o-%s expands to the same value as before', (name) => {
    expect(resolveLight(name)).toBe(normalize(BEFORE[name]));
  });

  // The default light bubble is the single exception to "default stays value for value": a vertical gradient of 7 stops (userBubbleStops.dark.light) + a gradStart @ 16% shadow
  it('default light --o-user-bubble-bg / shadow follow the new spec, --o-user-bubble-fg is unchanged', () => {
    const f = json as unknown as { userBubbleStops: Record<string, { light: string[] }>; light: { palettes: Record<string, Record<string, string>> } };
    expect(resolveLight('user-bubble-bg')).toBe(normalize(`linear-gradient(180deg, ${f.userBubbleStops.dark.light.join(', ')})`));
    expect(resolveLight('user-bubble-shadow')).toContain(normalize(`0 4px 14px color-mix(in srgb, ${f.light.palettes.dark.gradStart} 16%, transparent)`));
  });

  const nonDefault = json.order.filter((id) => id !== json.defaultId);

  it.each(nonDefault)('%s: the light section brand variables == the fixture light.palettes mapping, and only these keys are written', (id) => {
    const src = lightPaletteBlock(id);
    for (const [token, name] of LIGHT_BRAND_CSS_VARS) {
      expect(declaration(src, name.slice(4))?.toUpperCase(), `${id} ${name}`).toBe(lightJson[id][token].toUpperCase());
    }
    const names = [...src.matchAll(/(--o-[a-z0-9-]+)\s*:/g)].map((m) => m[1]);
    expect(names.sort()).toEqual([...LIGHT_BRAND_CSS_VARS.map(([, n]) => n), '--o-user-bubble-stops'].sort());
  });

  it('the default palette has no light palette section (it uses the hand-tuned :root values)', () => {
    expect(css.includes("[data-theme='light'][data-palette='dark'] {")).toBe(false);
  });

  it('shared non-default section: gradient / bubble / page background / tabs / glow secondary colors only reference brand variables, with no hard-coded colors', () => {
    const src = sharedBlock();
    expect(declaration(src, 'gradient-brand')).toBe('linear-gradient(135deg, var(--o-brand-grad-start), var(--o-brand-grad-end))');
    // The bubble background is no longer overridden to the 135deg brand gradient; it follows the :root 180deg vertical stops (each palette section overrides --o-user-bubble-stops)
    expect(declaration(src, 'user-bubble-bg')).toBeNull();
    expect(declaration(src, 'user-bubble-shadow')).toContain('color-mix(in srgb, var(--o-brand-grad-start) 16%, transparent)');
    expect(declaration(src, 'user-bubble-fg')).toBe('var(--o-primary-text)');
    expect(declaration(src, 'screen-bg')).toBe('linear-gradient(180deg, var(--o-brand-bg-top), var(--o-brand-bg-bottom))');
    expect(declaration(src, 'tab-teal')).toBe('var(--o-primary)');
    expect(declaration(src, 'tab-orange')).toBe('var(--o-primary)');
    expect(declaration(src, 'chat-aurora-tint-a')).toBe('var(--o-brand-accent)');
    expect(declaration(src, 'chat-aurora-tint-b')).toBe('var(--o-primary)');
    expect(declaration(src, 'brand-glow-secondary')).toBe('var(--o-brand-accent)');
    expect(src).not.toMatch(/#[0-9a-f]{3,8}\b|rgba?\(/i);
  });

  /** WCAG 2.x relative-luminance contrast ratio (computed here, not reusing the production implementation). */
  const lum = (hex: string) => {
    const ch = (i: number) => {
      const c = parseInt(hex.slice(i, i + 2), 16) / 255;
      return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    };
    return 0.2126 * ch(1) + 0.7152 * ch(3) + 0.0722 * ch(5);
  };
  const ratio = (a: string, b: string) => {
    const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
  };
  const derivationSeeds = (json as unknown as { custom: { derivationCases: Array<{ seed: string }> } }).custom.derivationCases.map((c) => c.seed);
  const pairCases: Array<[string, () => Record<string, string>]> = [
    ...nonDefault.map((id): [string, () => Record<string, string>] => [
      id,
      () => Object.fromEntries([...lightPaletteBlock(id).matchAll(/(--o-[a-z0-9-]+)\s*:\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()])),
    ]),
    ...derivationSeeds.map((seed): [string, () => Record<string, string>] => [`custom ${seed}`, () => customLightBrandCssVars(seed)]),
  ];

  it.each(pairCases)('%s: --o-primary-text on the fill is >= 3 against --o-primary-fill and >= 4.5 against --o-primary-text-safe', (_name, vars) => {
    const v = vars();
    const fg = v['--o-primary-text'];
    expect(ratio(fg, v['--o-primary-fill']), `fill ${v['--o-primary-fill']}`).toBeGreaterThanOrEqual(3);
    expect(ratio(fg, v['--o-primary-text-safe']), `text-safe ${v['--o-primary-text-safe']}`).toBeGreaterThanOrEqual(4.5);
  });

  it('dark default section: --o-primary-fill points back at --o-primary (dark is unchanged value for value)', () => {
    expect(declaration(defaultBlock(), 'primary-fill')).toBe('var(--o-primary)');
  });

  it('dark default section: --o-primary-fill-text points back at --o-primary; the shared non-default light section points at fillText (--o-primary-text-safe)', () => {
    expect(declaration(defaultBlock(), 'primary-fill-text')).toBe('var(--o-primary)');
    const css = readFileSync(CSS_PATH, 'utf8');
    const shared = css.match(/\[data-theme='light'\]\[data-palette\]:not\(\[data-palette='dark'\]\)\s*\{([^}]*)\}/);
    expect(shared?.[1]).toMatch(/--o-primary-fill-text:\s*var\(--o-primary-text-safe\)/);
  });

  it('the light variables written for the custom palette use the same keys as a preset light section', () => {
    const presetNames = [...lightPaletteBlock('dark-ocean').matchAll(/(--o-[a-z0-9-]+)\s*:/g)].map((m) => m[1]).sort();
    expect(Object.keys(customLightBrandCssVars('#C084FC')).sort()).toEqual(presetNames);
  });
});

/**
 * Regression guard: in bright-fill palettes (mode=bright) --o-primary is the ink color and --o-primary-text is dark,
 * so background: var(--o-primary) + color: var(--o-primary-text) in the same rule block puts dark on dark.
 * Icon-only fills use --o-primary-fill, and fills that carry text use --o-primary-fill-text (default = primary, non-default light = fillText).
 */
describe('primary_fill_pairs_with_primary_text', () => {
  const WEB_ROOT = join(REPO_ROOT, 'web');
  const cssFiles = (dir: string): string[] =>
    (readdirSync(join(WEB_ROOT, dir), { recursive: true }) as string[])
      .filter((f) => f.endsWith('.css') && !/(^|\/)(node_modules|dist|\.[^/]+)\//.test(f))
      .map((f) => join(dir, f));

  it('no CSS rule block in apps/app or packages/ui pairs background: var(--o-primary) with color: var(--o-primary-text)', () => {
    const files = [...cssFiles('apps/app'), ...cssFiles('packages/ui/src')];
    expect(files.length).toBeGreaterThan(50);
    const offenders: string[] = [];
    for (const file of files) {
      const src = readFileSync(join(WEB_ROOT, file), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
      for (const m of src.matchAll(/([^{}]*)\{([^{}]*)\}/g)) {
        const body = m[2];
        if (/background(-color)?\s*:\s*var\(--o-primary\)\s*[;}]?/.test(body) && /(^|[;\s])color\s*:\s*var\(--o-primary-text\)/.test(body)) {
          offenders.push(`${file}: ${m[1].trim().split('\n').pop()}`);
        }
      }
    }
    expect(offenders).toEqual([]);
  });
});
