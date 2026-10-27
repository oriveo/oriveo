import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  USER_BUBBLE_STOPS_CSS_VAR,
  bubbleStops,
  customBubbleStops,
  customLightBrandCssVars,
  customLightBubbleStops,
  customPaletteCssVars,
} from '@oriveo/shared';
import { customPaletteCssText } from '../../lib/theme/custom-palette-style';
import { anchoredBubbleGradient } from './user-bubble-gradient';

/**
 * Viewport-anchored vertical gradient of the user bubble:
 * 1) stop contract: each palette section of variables.css / the ported bubbleStops / the custom derivation == the fixture, channel by channel with |difference| <= 1;
 * 2) anchoring geometry: container height H, bubble top t -> gradient start / end at -t / H - t;
 * 3) production styles: the chat bubble uses 180deg vertical stops + background-attachment: fixed, with shadow = bottom stop @ the fixture alpha.
 */
const REPO_ROOT = join(process.cwd(), '../../..');
const css = readFileSync(join(REPO_ROOT, 'web/packages/ui/src/tokens/variables.css'), 'utf8');
const bubbleCss = readFileSync(join(process.cwd(), 'components/chat/MessageBubble.module.css'), 'utf8');
const themeCss = readFileSync(join(process.cwd(), 'app/settings/theme/ThemeSettings.module.css'), 'utf8');

type Stops = { dark: string[]; light: string[] };
interface Fixture {
  defaultId: string;
  order: string[];
  palettes: Record<string, Record<string, string>>;
  light: { palettes: Record<string, Record<string, string>> };
  derived: {
    userBubble: {
      stops: number;
      dark: { top: string; bottom: string };
      light: { top: string; bottom: string };
      highlight: { width: number; alpha: { dark: number; light: number } };
      shadow: { alpha: number; blur: number; y: number };
    };
  };
  userBubbleStops: Record<string, Stops>;
  custom: { derivationCases: Array<{ seed: string; bubble: Stops }> };
}
const fixture = JSON.parse(readFileSync(join(REPO_ROOT, 'shared/theme-contracts/dark-palettes.v1.json'), 'utf8')) as Fixture;
const ub = fixture.derived.userBubble;
const modes = ['dark', 'light'] as const;

const rgb = (hex: string) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
function expectStopsClose(actual: readonly string[], expected: readonly string[], label: string) {
  expect(actual, label).toHaveLength(expected.length);
  actual.forEach((hex, i) => {
    const a = rgb(hex);
    rgb(expected[i]).forEach((v, c) => expect(Math.abs(a[c] - v), `${label}[${i}] ${hex} vs ${expected[i]}`).toBeLessThanOrEqual(1));
  });
}

function block(selector: string): string {
  const start = css.indexOf(`\n${selector} {`);
  if (start < 0) throw new Error(`${selector} not found in variables.css`);
  return css.slice(start, css.indexOf('}', start)).replace(/\/\*[\s\S]*?\*\//g, '');
}
function declaration(source: string, name: string): string | null {
  const m = new RegExp(`--o-${name}\\s*:\\s*([^;]+);`).exec(source);
  return m ? m[1].replace(/\s+/g, ' ').trim() : null;
}
function segment(id: string, mode: 'dark' | 'light'): string {
  if (id === fixture.defaultId) return mode === 'dark' ? block("[data-theme='dark']") : block(":root,\n[data-theme='light']");
  return block(`[data-theme='${mode}'][data-palette='${id}']`);
}
const parseStops = (value: string | null) => (value ?? '').split(',').map((s) => s.trim());

describe('bubble_stops_match_fixture', () => {
  it.each(fixture.order.flatMap((id) => modes.map((mode) => [id, mode] as const)))(
    'variables.css %s / %s: --o-user-bubble-stops == userBubbleStops',
    (id, mode) => {
      const stops = parseStops(declaration(segment(id, mode), 'user-bubble-stops'));
      expect(stops).toHaveLength(ub.stops);
      expectStopsClose(stops, fixture.userBubbleStops[id][mode], `${id}.${mode}`);
    },
  );

  it.each(fixture.order)('ported bubbleStops: both ends of %s (dark accent->primary, light gradEnd->gradStart) == userBubbleStops', (id) => {
    const dark = fixture.palettes[id];
    const light = fixture.light.palettes[id];
    expectStopsClose(bubbleStops(dark[ub.dark.top], dark[ub.dark.bottom], ub.stops), fixture.userBubbleStops[id].dark, `${id}.dark`);
    expectStopsClose(bubbleStops(light[ub.light.top], light[ub.light.bottom], ub.stops), fixture.userBubbleStops[id].light, `${id}.light`);
  });

  it.each(fixture.custom.derivationCases.map((c) => [c.seed, c] as const))('custom %s: derived stops == derivationCases[].bubble', (_seed, c) => {
    expectStopsClose(customBubbleStops(c.seed), c.bubble.dark, `${c.seed}.dark`);
    expectStopsClose(customLightBubbleStops(c.seed), c.bubble.light, `${c.seed}.light`);
  });

  it('custom stops are cached by seed (same seed, same object)', () => {
    const seed = fixture.custom.derivationCases[0].seed;
    expect(customBubbleStops(seed.toLowerCase())).toBe(customBubbleStops(seed));
    expect(customLightBubbleStops(seed.toLowerCase())).toBe(customLightBubbleStops(seed));
  });

  it('the custom palette <style> writes the stops in both sections and passes the variable whitelist', () => {
    const c = fixture.custom.derivationCases[1];
    const text = customPaletteCssText(customPaletteCssVars(c.seed), customLightBrandCssVars(c.seed));
    const [darkPart, lightPart] = text.split("[data-theme='light'][data-palette='custom']");
    const pick = (part: string) => new RegExp(`${USER_BUBBLE_STOPS_CSS_VAR}:([^;]+);`).exec(part)?.[1] ?? null;
    expectStopsClose(parseStops(pick(darkPart)), c.bubble.dark, 'style dark');
    expectStopsClose(parseStops(pick(lightPart)), c.bubble.light, 'style light');
  });
});

describe('anchored_bubble_gradient', () => {
  it('container height H, bubble top t -> start -t, end H - t', () => {
    expect(anchoredBubbleGradient(800, 120)).toEqual({
      startY: -120,
      endY: 680,
      backgroundSize: '100% 800px',
      backgroundPosition: '0 -120px',
    });
  });

  it('the slice taken changes as t changes (scrolling)', () => {
    const before = anchoredBubbleGradient(800, 120);
    const after = anchoredBubbleGradient(800, 420);
    expect(after.startY).toBe(-420);
    expect(after.endY).toBe(380);
    expect(after.endY - after.startY).toBe(before.endY - before.startY);
    expect(after.backgroundPosition).not.toBe(before.backgroundPosition);
  });
});

describe('production_bubble_style', () => {
  const userBubble = (() => {
    const marker = ".row[data-role='user'] .bubble {";
    const start = bubbleCss.indexOf(marker);
    return bubbleCss.slice(start, bubbleCss.indexOf('\n}', start));
  })();

  it('chat bubble: variable gradient + background-attachment: fixed (viewport anchored, zero JS)', () => {
    expect(userBubble).toContain('background: var(--o-user-bubble-bg);');
    // The background shorthand resets attachment, so fixed must come after it
    expect(userBubble.indexOf('background-attachment: fixed;')).toBeGreaterThan(userBubble.indexOf('background: var(--o-user-bubble-bg);'));
    expect(userBubble).toContain('box-shadow: var(--o-user-bubble-shadow);');
  });

  it('the user message row entrance animation does not keep a transform (with a transformed ancestor fixed stops working and each bubble degrades to its own full gradient)', () => {
    const rowRule = bubbleCss.slice(bubbleCss.indexOf(".row[data-role='user'] {"));
    const animation = rowRule.slice(0, rowRule.indexOf('}')).match(/animation:\s*userMsgIn[^;]*;/)?.[0] ?? '';
    expect(animation).not.toBe('');
    expect(animation).not.toMatch(/\b(both|forwards)\b/);
  });

  it('dark / default light bubble backgrounds are 180deg vertical stops, no longer 135deg two-color', () => {
    for (const seg of [block("[data-theme='dark']"), block(":root,\n[data-theme='light']")]) {
      expect(declaration(seg, 'user-bubble-bg')).toBe('linear-gradient(180deg, var(--o-user-bubble-stops))');
    }
    // The shared non-default light section no longer overrides it with a 135deg brand gradient and follows the vertical stops of the default section
    expect(declaration(block("[data-theme='light'][data-palette]:not([data-palette='dark'])"), 'user-bubble-bg')).toBeNull();
  });

  it.each([
    ["[data-theme='dark']", 'var(--o-primary)', ub.highlight.alpha.dark],
    [":root,\n[data-theme='light']", fixture.light.palettes[fixture.defaultId][ub.light.bottom], ub.highlight.alpha.light],
    ["[data-theme='light'][data-palette]:not([data-palette='dark'])", 'var(--o-brand-grad-start)', ub.highlight.alpha.light],
  ])('%s: shadow = bottom stop @ fixture alpha + a white inner highlight on top', (selector, bottom, highlight) => {
    const shadow = declaration(block(selector), 'user-bubble-shadow');
    const pct = (a: number) => `${Math.round(a * 100)}%`;
    expect(ub.shadow.alpha).toBe(0.16);
    expect(shadow).toBe(
      `0 ${ub.shadow.y}px ${ub.shadow.blur}px color-mix(in srgb, ${bottom} ${pct(ub.shadow.alpha)}, transparent), ` +
        `inset 0 ${ub.highlight.width}px 0 0 color-mix(in srgb, white ${pct(highlight)}, transparent)`,
    );
    expect(shadow).not.toContain('35%');
  });

  it('the theme page preview bubble and the palette card bubble use the same stops (no more 135deg gradient-brand / old outer glow)', () => {
    for (const cls of ['previewBubble', 'cardMine']) {
      const start = themeCss.indexOf(`\n.${cls} {`);
      const body = themeCss.slice(start, themeCss.indexOf('\n}', start));
      expect(body, cls).toContain('background: var(--o-user-bubble-bg);');
      expect(body, cls).not.toContain('--o-gradient-brand');
    }
  });
});
