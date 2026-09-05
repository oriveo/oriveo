import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Source-level visual contract for the model behavior panel.
 *
 * Source level rather than rendered assertions because jsdom does not cascade and does not
 * resolve CSS variables: `getComputedStyle` always returns the literal the author wrote, so it
 * cannot catch "this token is not defined anywhere, so it falls back to a light hex that does
 * not flip with the theme". Precedents in this repo: AppShell.test.tsx and
 * QuoteContextChip.visual-contract.test.ts.
 *
 * A real incident: nine places here referenced `--text-primary` / `--text-secondary` /
 * `--border` and three more referenced `--o-surface-subtle`, none of which are defined anywhere
 * in apps/app or packages/ui, so they always fell back to literal hex values that were all
 * light. In the dark theme the measured contrast of `.row label` was 1.08:1, barely visible and
 * darker than the caption below it, which is meant to be the fainter of the two.
 */

const panelCss = readFileSync(join(process.cwd(), 'components/generation/GenerationParameterPanel.module.css'), 'utf8');
const tokensCss = readFileSync(join(process.cwd(), '../../packages/ui/src/tokens/variables.css'), 'utf8');
const globalsCss = readFileSync(join(process.cwd(), 'app/globals.css'), 'utf8');

/**
 * variables.css has exactly two theme blocks: `:root,[data-theme='light']` and
 * `[data-theme='dark']`.
 *
 * The anchor has to be the start of a rule (line start followed by `{`), not a bare indexOf: a
 * comment inside the light block contains the literal `[data-theme='dark']` (explaining why some
 * tokens cannot be overridden with an attribute selector), and a bare indexOf would cut the
 * light source short there, reporting every token after that comment as undefined.
 */
const darkBlockStart = tokensCss.search(/^\[data-theme='dark'\]\s*\{/m);
const lightSource = tokensCss.slice(0, darkBlockStart);
const darkSource = tokensCss.slice(darkBlockStart);

function collectTokens(source: string): Map<string, string> {
  const tokens = new Map<string, string>();
  for (const match of source.matchAll(/(--[a-zA-Z0-9-]+)\s*:\s*([^;]+);/g)) {
    tokens.set(match[1], match[2].trim());
  }
  return tokens;
}

const lightTokens = collectTokens(lightSource);
// The dark block redefines only some tokens; the rest are inherited from the light block.
const darkTokens = new Map([...lightTokens, ...collectTokens(darkSource)]);
const definedTokenNames = new Set<string>([
  ...lightTokens.keys(),
  ...darkTokens.keys(),
  ...collectTokens(globalsCss).keys(),
  // Local custom properties declared by the module file itself also count as defined.
  ...collectTokens(panelCss).keys(),
]);

type Theme = 'light' | 'dark';
const themeTokens: Record<Theme, Map<string, string>> = { light: lightTokens, dark: darkTokens };

function parseColor(raw: string): [number, number, number] {
  const hex = /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.exec(raw.trim());
  if (hex) {
    const digits = hex[1].length === 3 ? [...hex[1]].map((d) => d + d).join('') : hex[1];
    return [0, 2, 4].map((offset) => parseInt(digits.slice(offset, offset + 2), 16)) as [number, number, number];
  }
  const rgb = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/.exec(raw.trim());
  if (rgb) return [Number(rgb[1]), Number(rgb[2]), Number(rgb[3])];
  throw new Error(`unsupported color literal: ${raw}`);
}

function relativeLuminance(color: [number, number, number]): number {
  const [r, g, b] = color.map((channel) => {
    const value = channel / 255;
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrastRatio(foreground: string, background: string): number {
  const a = relativeLuminance(parseColor(foreground));
  const b = relativeLuminance(parseColor(background));
  const [light, dark] = a >= b ? [a, b] : [b, a];
  return (light + 0.05) / (dark + 0.05);
}

/** Take the token name a rule's property references, not the literal hex, which is the bug itself. */
function declaredTokenName(selector: string, property: string): string {
  const rule = new RegExp(`^\\s*${selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{([^}]*)\\}`, 'm').exec(panelCss);
  expect(rule, `${selector} rule exists`).toBeTruthy();
  const declaration = new RegExp(`(?:^|;|\\s)${property}\\s*:\\s*([^;]+)`).exec(rule![1]);
  expect(declaration, `${selector} declares ${property}`).toBeTruthy();
  const token = /var\(\s*(--[a-zA-Z0-9-]+)/.exec(declaration![1]);
  expect(token, `${selector} uses a design token for ${property} rather than a hardcoded color`).toBeTruthy();
  return token![1];
}

function tokenColor(name: string, theme: Theme): string {
  const value = themeTokens[theme].get(name);
  // No value means the name does not exist in the design system, which means production always falls back to the literal.
  expect(value, `${name} is defined in the ${theme} theme`).toBeTruthy();
  return value!;
}

function resolvedContrast(foregroundSelector: string, backgroundSelector: string, theme: Theme): number {
  return contrastRatio(
    tokenColor(declaredTokenName(foregroundSelector, 'color'), theme),
    tokenColor(declaredTokenName(backgroundSelector, 'background'), theme),
  );
}

describe('GenerationParameterPanel visual contract', () => {
  it('uses only tokens that really exist in the design system, with no phantom namespace', () => {
    const used = [...panelCss.matchAll(/var\(\s*(--[a-zA-Z0-9-]+)/g)].map((match) => match[1]);
    const phantom = [...new Set(used)].filter((name) => !definedTokenNames.has(name)).sort();
    expect(phantom, 'these tokens are undefined everywhere and always fall back to a literal that does not flip with the theme').toEqual([]);
  });

  it('explicitly bans the four phantom names that caused trouble before', () => {
    // `--border` needs a boundary match, otherwise `--o-border` matches too.
    expect(panelCss).not.toMatch(/var\(\s*--text-primary\b/);
    expect(panelCss).not.toMatch(/var\(\s*--text-secondary\b/);
    expect(panelCss).not.toMatch(/var\(\s*--border\b/);
    expect(panelCss).not.toMatch(/var\(\s*--o-surface-subtle\b/);
  });

  it.each(['light', 'dark'] as const)('%s theme meets WCAG AA for both the parameter name and the caption', (theme) => {
    const label = resolvedContrast('.row label', '.panel', theme);
    const caption = resolvedContrast('.labelStack span', '.panel', theme);
    const header = resolvedContrast('.header p', '.panel', theme);

    expect(label, `${theme} .row label contrast ${label.toFixed(2)}:1`).toBeGreaterThanOrEqual(4.5);
    expect(caption, `${theme} .labelStack span contrast ${caption.toFixed(2)}:1`).toBeGreaterThanOrEqual(4.5);
    expect(header, `${theme} .header p contrast ${header.toFixed(2)}:1`).toBeGreaterThanOrEqual(4.5);
    // Hierarchy: the parameter name has to stand out more than the caption below it, not the other way around.
    expect(label, `${theme} parameter name should stand out more than the caption`).toBeGreaterThan(caption);
  });

  it.each(['light', 'dark'] as const)('%s theme keeps button backgrounds in the panel from swallowing their text', (theme) => {
    // These buttons declare `color: inherit`, which is the panel body color --o-text.
    const buttonBackground = tokenColor(declaredTokenName('.presets>button,.preset button,.compatibility button', 'background'), theme);
    const previewBackground = tokenColor(declaredTokenName('.customPreview', 'background'), theme);
    const text = tokenColor(declaredTokenName('.row label', 'color'), theme);

    expect(contrastRatio(text, buttonBackground)).toBeGreaterThanOrEqual(4.5);
    expect(contrastRatio(text, previewBackground)).toBeGreaterThanOrEqual(4.5);
    // The explanation block has its own background, and the body text has to stay readable on it.
    expect(resolvedContrast('.reasoningNotice', '.reasoningNotice', theme)).toBeGreaterThanOrEqual(4.5);
  });

  it('the disabled state differs visually, not only by the disabled attribute', () => {
    const rule = /\.presets>button:disabled[^{]*\{([^}]*)\}/.exec(panelCss);
    expect(rule, 'the preset save button has a :disabled visual rule').toBeTruthy();
    expect(rule![1]).toMatch(/opacity\s*:\s*\.?0?\.\d+/);
    expect(rule![1]).toMatch(/cursor\s*:\s*not-allowed/);
  });

  /**
   * The developer group had no geometric assertion: this file used to pin only color and shape,
   * never a pixel. This row is the only entry to custom request fields, and letting its hit area
   * fall back to the default line height makes that door narrower.
   */
  it('developer group: the entry row has a hit area of at least 44px and a real separator from the parameter table', () => {
    const row = /\.developerRow\s*\{([^}]*)\}/.exec(panelCss);
    expect(row, '.developerRow rule exists').toBeTruthy();
    expect(Number(/min-height\s*:\s*(\d+(?:\.\d+)?)px/.exec(row![1])![1])).toBeGreaterThanOrEqual(44);

    // The group is separated from the parameter table above by a border-top: it is a different kind of thing, not the last parameter.
    const group = /\.developerGroup\s*\{([^}]*)\}/.exec(panelCss);
    expect(group).toBeTruthy();
    expect(group![1]).toMatch(/border-top\s*:\s*1px solid/);
  });

  /**
   * The back button on the custom fields subpage is the only way out of that level, and the
   * ~27px it gets from the line height of 12px text is hard to hit on touch. The visual stays as
   * it is and the hit area is grown with a pseudo-element; both are pinned, since asserting only
   * min-height would go green even after the pseudo-element is dropped.
   */
  it('subpage back button keeps a 28px visual and a hit area of at least 44px', () => {
    const back = /\.subPageBack\s*\{([^}]*)\}/.exec(panelCss);
    expect(back, '.subPageBack rule exists').toBeTruthy();
    const visual = Number(/min-height\s*:\s*(\d+(?:\.\d+)?)px/.exec(back![1])![1]);
    expect(visual, 'the visual height stays at 28px and is not grown into a 44px button').toBeLessThanOrEqual(32);

    const hit = /\.subPageBack::after\s*\{([^}]*)\}/.exec(panelCss);
    expect(hit, 'the hit-area pseudo-element must actually render').toBeTruthy();
    expect(hit![1]).toMatch(/content\s*:\s*''/);
    expect(hit![1]).toMatch(/position\s*:\s*absolute/);
    const outset = Number(/inset-block\s*:\s*-(\d+(?:\.\d+)?)px/.exec(hit![1])![1]);
    expect(visual + outset * 2, `hit area ${visual + outset * 2}px`).toBeGreaterThanOrEqual(44);
    // The subpage title sits right beside it: growing horizontally would turn a run of unclickable text into a clickable area.
    expect(hit![1]).toMatch(/inset-inline\s*:\s*0/);
  });

  /**
   * Every button in this table that also appears in the model options popover needs a hit area
   * of at least 44px.
   *
   * The criterion is always "visual height plus the layer that grows the hit area is at least
   * 44", pinning both: asserting only `min-height` would go green after the pseudo-element is
   * dropped, which is exactly how a hit area quietly falls back to 24px.
   *
   * Two entries are destructive actions (removing a custom field, and the removal confirmation).
   * Missing them costs as much as hitting the wrong one, so they additionally require a zero
   * horizontal outset (or one the container gap can absorb) so adjacent hit areas cannot overlap.
   */
  const hitAreaTargets = [
    { selector: '.customDangerAction', why: 'remove a custom request field (destructive)' },
    { selector: '.customRemoveConfirm button', why: 'keep / remove in the removal confirmation' },
    { selector: '.resetConfirm button', why: 'cancel / restore defaults in the restore confirmation (destructive)' },
    { selector: '.developerCandidates button', why: 'which model to switch to candidates' },
    { selector: '.portableActions button', why: 'backup / import and export / diagnostics / clear learned records' },
    { selector: '.reset', why: 'restore defaults' },
    { selector: '.clear', why: 'the leave-empty / clear icon button on a parameter row' },
    { selector: '.notAdjustableAction', why: 'the only way out of the not-adjustable state' },
  ] as const;

  it.each(hitAreaTargets)('$selector ($why) has a hit area of at least 44px', ({ selector }) => {
    const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const rule = new RegExp(`(?:^|\\n)\\s*${escaped}\\s*\\{([^}]*)\\}`).exec(panelCss);
    expect(rule, `${selector} rule exists`).toBeTruthy();
    const visual = Number(/min-height\s*:\s*(\d+(?:\.\d+)?)px/.exec(rule![1])?.[1]);
    expect(visual, `${selector} declares a visual height`).toBeGreaterThan(0);

    const hit = new RegExp(`(?:^|\\n)\\s*${escaped}::after\\s*\\{([^}]*)\\}`).exec(panelCss);
    expect(hit, `${selector} hit-area pseudo-element must actually render`).toBeTruthy();
    expect(hit![1]).toMatch(/content\s*:\s*''/);
    expect(hit![1]).toMatch(/position\s*:\s*absolute/);
    const outset = Number(/inset(?:-block)?\s*:\s*-(\d+(?:\.\d+)?)px/.exec(hit![1])![1]);
    expect(visual + outset * 2, `${selector} hit area is only ${visual + outset * 2}px`).toBeGreaterThanOrEqual(44);
    // The outset must be at most half the container gap, otherwise two wrapped rows overlap.
    expect(outset, `${selector} block outset ${outset}px exceeds half the container 8px gap`).toBeLessThanOrEqual(4);
  });

  it('hit areas of buttons in a row do not overlap: zero outset, or a container gap that absorbs it', () => {
    // `.clear` is the only one grown on all four sides (it has to reach 44 wide), so its container gap has to be at least twice the outset.
    const control = /(?:^|\n)\s*\.control\s*\{([^}]*)\}/.exec(panelCss);
    expect(control).toBeTruthy();
    const gap = Number(/gap\s*:\s*(\d+(?:\.\d+)?)px/.exec(control![1])![1]);
    const clearOutset = Number(/inset\s*:\s*-(\d+(?:\.\d+)?)px/.exec(/\.clear::after\s*\{([^}]*)\}/.exec(panelCss)![1])![1]);
    expect(gap, `.control gap ${gap}px cannot absorb ${clearOutset}px of outset on each side`).toBeGreaterThanOrEqual(clearOutset * 2);
    const clearWidth = Number(/min-width\s*:\s*(\d+(?:\.\d+)?)px/.exec(/(?:^|\n)\s*\.clear\s*\{([^}]*)\}/.exec(panelCss)![1])![1]);
    expect(clearWidth + clearOutset * 2, '.clear horizontal hit area is under 44px').toBeGreaterThanOrEqual(44);

    // Wrapping containers: with a 4px outset the gap has to be at least 8, so the two rows of hit areas just meet.
    for (const selector of ['.developerCandidates', '.portableActions', '.customRemoveConfirm', '.resetConfirm']) {
      const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const rule = new RegExp(`(?:^|\\n)\\s*${escaped}\\s*\\{([^}]*)\\}`).exec(panelCss);
      expect(rule, `${selector} rule exists`).toBeTruthy();
      expect(Number(/gap\s*:\s*(\d+(?:\.\d+)?)px/.exec(rule![1])![1]), `${selector} gap cannot absorb a 4px outset`)
        .toBeGreaterThanOrEqual(8);
    }
  });

  /** The forward chevron has to be mirrored under RTL, otherwise it points back. */
  it('the developer row forward chevron is mirrored under RTL', () => {
    expect(panelCss).toMatch(/\[dir='rtl'\]\s*\.developerRow svg\s*\{[^}]*scaleX\(-1\)/);
  });

  /**
   * The two sides of the header have to sit side by side, not "top edges aligned, text offset".
   *
   * Two independent causes, and either one alone still leaves it crooked:
   * 1. `.reset` is grown by `min-height:36px` to reach a 44px hit area, while the left column in
   *    the title-hidden form holds a single line of 12px text (~17px). `align-items:start` lines
   *    up the top edges but leaves the text centers ~8px apart.
   * 2. The global `button { font: inherit }` makes `.reset` inherit the 16px root size, one step
   *    larger than the 12px caption on the same row, so a secondary reset action draws more
   *    attention than the thing it describes.
   */
  it('restore defaults on the right of the header sits level with and aligned to the caption on the left', () => {
    const header = /(?:^|\n)\s*\.header\s*\{([^}]*)\}/.exec(panelCss);
    expect(header, '.header rule exists').toBeTruthy();
    expect(header![1], 'start alignment leaves a button grown by min-height sitting below the text on the left')
      .toMatch(/align-items\s*:\s*center/);

    // The premise still holds: buttons really do inherit the font size globally, so without an explicit size this grows to the root size.
    expect(globalsCss).toMatch(/button[^{]*\{[^}]*font\s*:\s*inherit/);
    const captionSize = Number(/font-size\s*:\s*(\d+(?:\.\d+)?)px/
      .exec(/(?:^|\n)\s*\.header p\s*\{([^}]*)\}/.exec(panelCss)![1])![1]);
    const resetSize = Number(/font-size\s*:\s*(\d+(?:\.\d+)?)px/
      .exec(/(?:^|\n)\s*\.reset\s*\{([^}]*)\}/.exec(panelCss)![1])?.[1]);
    expect(resetSize, `restore defaults should match the caption on the same row at ${captionSize}px`).toBe(captionSize);

    // With the title hidden the caption is the only content in the left column, so the 3px top margin that separated it from the title has to go to zero.
    expect(panelCss, 'in the single-line form the top margin of .header p pushes it below the button')
      .toMatch(/\.header p:first-child\s*\{[^}]*margin-top\s*:\s*0/);
  });

  it('the controlled-by-reasoning-shortcut notice is an explanation block and does not borrow the parameter row skeleton', () => {
    const rule = /\.reasoningNotice\s*\{([^}]*)\}/.exec(panelCss);
    expect(rule).toBeTruthy();
    // A parameter row's skeleton is a top hairline plus two columns; the explanation block may have neither, or color is all that tells them apart.
    expect(rule![1]).not.toMatch(/justify-content\s*:\s*space-between/);
    expect(rule![1]).not.toMatch(/border-top\s*:/);
    expect(rule![1]).toMatch(/background\s*:/);
  });
});
