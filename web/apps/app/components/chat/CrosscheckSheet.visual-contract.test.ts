import { describe, expect, it } from 'vitest';

import {
  AA_NORMAL_TEXT,
  composite,
  contrastRatio,
  parseColor,
  readCss,
  readDeclaration,
  readThemeTokens,
  relativeLuminance,
  type Rgba,
  type Theme,
} from '../../lib/design-system/semantic-text-contrast';

/**
 * Source-level visual contract for the vendor subheading bar in the crosscheck panel.
 *
 * This rule used to read `color-mix(in srgb, var(--o-surface-muted) 56%, transparent)`, and
 * `--o-surface-muted` does not exist in the design system, so the whole `background` declaration
 * became invalid at computed-value time. The subheading bar was transparent and completely flush
 * with the provider group around it.
 *
 * It now uses `--o-bg-inset`. This file pins why it is bg-inset rather than bg-subtle: the outer
 * `.modelProviderGroup` is `--o-surface-raised` at 78% opacity over `.modelMenu`'s `--o-surface`,
 * which composites to #F6F6F7 in the light theme, not #F4F4F5. `--o-bg-subtle` is therefore not
 * strictly a no-op, but the lightness step it produces is 1.012, invisible in practice, while
 * `--o-bg-inset` gives 1.032, which really does read as a layer. The assertion measures that step
 * directly.
 */

const tokens = readThemeTokens();
const FILE = 'apps/app/components/chat/CrosscheckSheet.module.css';
const THEMES = ['light', 'dark'] as const;

/** Lightness step: the contrast ratio between two adjacent surfaces. 1.0 means no visible layering at all. */
const MIN_VISIBLE_STEP = 1.025;

function surfaces(theme: Theme): { group: Rgba; header: Rgba } {
  // `.modelMenu` appears a second time inside a media query (which only changes positioning, not the background), so its single background declaration is written out here.
  const menu = parseColor('var(--o-surface)', theme, tokens);
  const group = composite(parseColor(readDeclaration(FILE, '.modelProviderGroup', 'background'), theme, tokens), menu);
  const header = composite(parseColor(readDeclaration(FILE, '.modelVendorHeader', 'background'), theme, tokens), group);
  return { group, header };
}

function step(a: Rgba, b: Rgba): number {
  const [x, y] = [relativeLuminance(a), relativeLuminance(b)];
  const [lighter, darker] = x >= y ? [x, y] : [y, x];
  return (lighter + 0.05) / (darker + 0.05);
}

describe('CrosscheckSheet vendor subheading bar', () => {
  it('references no phantom token, since a phantom name invalidates the whole declaration and the line may as well not be there', () => {
    const css = readCss(FILE);
    expect(css).not.toMatch(/var\(\s*--o-surface-muted\b/);
    expect(css).not.toMatch(/var\(\s*--o-surface-elevated\b/);
    expect(css).not.toMatch(/var\(\s*--o-border-subtle\b/);
  });

  it.each(THEMES)('%s theme gives the subheading bar a visible lightness step against the outer group', (theme) => {
    const { group, header } = surfaces(theme);
    const measured = step(group, header);
    expect(
      measured,
      `${theme} step is only ${measured.toFixed(4)} (--o-bg-subtle measures 1.012, which is no layering at all; --o-bg-inset is 1.032)`,
    ).toBeGreaterThanOrEqual(MIN_VISIBLE_STEP);
  });

  it.each(THEMES)('%s theme keeps text on the subheading bar at AA 4.5:1', (theme) => {
    const { header } = surfaces(theme);
    const color = parseColor(readDeclaration(FILE, '.modelVendorHeader', 'color'), theme, tokens);
    const ratio = contrastRatio(composite(color, header), header);
    expect(ratio, `${theme} subheading text ${ratio.toFixed(4)}:1`).toBeGreaterThanOrEqual(AA_NORMAL_TEXT);
  });
});
