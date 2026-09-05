import { describe, expect, it } from 'vitest';

import { readCss, readDeclaration, readThemeTokens } from '../../lib/design-system/semantic-text-contrast';

/**
 * **Source-level** visual contract for the skeleton bubble shadow.
 *
 * Background: this rule used to read
 *   `box-shadow: 0 1px 0 color-mix(in srgb, var(--o-shadow) 3%, transparent),
 *                0 8px 24px color-mix(in srgb, var(--o-shadow) 5%, transparent);`
 * but the design system has **no** `--o-shadow` color token (`--o-shadow-sm/md/lg/xl` are complete
 * box-shadow values, not colors). A name that does not exist invalidates the whole box-shadow at
 * computed-value time, so the skeleton bubble never had a shadow in production.
 *
 * It now uses `var(--o-elevation-card)`, and this file pins the reasoning as an executable rule:
 *   - elevation-card in light mode is `0 1px 2px @4%` plus `0 8px 24px @5%`, which nearly coincides
 *     with the intended 3% / 5% and the `0 8px 24px` layer, making it the closest existing token.
 *   - The cost is an extra `inset 0 1px 0 var(--o-hairline)` top highlight. That is acceptable: it is
 *     how all three elevation levels are written in this design system (dark mode expresses depth
 *     through the hairline anyway), and the real user bubble
 *     (MessageBubble `.row[data-role='user'] .bubble`) already carries
 *     `inset 0 1px 0 rgba(255,255,255,.18)`, so a matching highlight makes the skeleton look more
 *     like the thing it stands in for.
 *   - Keeping no shadow at all was rejected: the skeleton stands in for a real bubble, and a real
 *     user bubble has a shadow, so the elevation would jump the instant streaming starts.
 *   - `--o-shadow-md/lg` were rejected: they are single layer and their dark alpha reaches 0.55/0.6,
 *     an order of magnitude heavier than the intended 3-5%.
 */

const tokens = readThemeTokens();
const FILE = 'apps/app/components/chat/ConversationBootstrapState.module.css';

/** Extract the token names referenced by a box-shadow. */
function shadowToken(): string {
  const declared = readDeclaration(FILE, '.bubble', 'box-shadow');
  const match = /var\(\s*(--[a-zA-Z0-9-]+)\s*\)/.exec(declared);
  expect(match, `.bubble box-shadow goes through a design token instead of a hand-mixed color: ${declared}`).toBeTruthy();
  return (match as RegExpExecArray)[1];
}

/** Extract the alpha of every drop-shadow layer, excluding inset ones. */
function dropShadowAlphas(value: string): number[] {
  return [...value.matchAll(/rgba\(\s*[\d.]+\s*,\s*[\d.]+\s*,\s*[\d.]+\s*,\s*([\d.]+)\s*\)/g)]
    .filter((match) => !value.slice(0, match.index).match(/inset[^,]*$/))
    .map((match) => Number.parseFloat(match[1]));
}

describe('ConversationBootstrapState skeleton bubble shadow', () => {
  it('no longer references --o-shadow, which is not a color token and voids the whole box-shadow', () => {
    expect(readCss(FILE)).not.toMatch(/var\(\s*--o-shadow\s*[,)]/);
  });

  it('the shadow uses a token that really exists and is defined in both themes', () => {
    const name = shadowToken();
    expect(tokens.light.get(name), `${name} is defined in the light theme`).toBeTruthy();
    expect(tokens.dark.get(name), `${name} is defined in the dark theme`).toBeTruthy();
  });

  it('the skeleton bubble really has a shadow instead of one silently swallowed, which is what the phantom token caused', () => {
    const name = shadowToken();
    for (const theme of ['light', 'dark'] as const) {
      const value = tokens[theme].get(name) as string;
      expect(dropShadowAlphas(value).length, `${name} needs at least one drop shadow in the ${theme} theme`).toBeGreaterThan(0);
    }
  });

  it('keeps the soft wide shadow layer (blur >= 16px) rather than a single 1px hard edge', () => {
    const value = tokens.light.get(shadowToken()) as string;
    const blurs = [...value.matchAll(/\b\d+px\s+(\d+)px\b/g)].map((match) => Number.parseInt(match[1], 10));
    expect(Math.max(...blurs), `the largest light-mode blur is only ${Math.max(...blurs)}px, far harder than the intended 0 8px 24px`).toBeGreaterThanOrEqual(16);
  });

  it('the shadow stays in the intended 3-5% range and was not swapped for a heavy preset', () => {
    const name = shadowToken();
    // Light: the intent was 3% / 5% and elevation-card is 4% / 5%; --o-shadow-md is already 8% and lg is 10%.
    expect(Math.max(...dropShadowAlphas(tokens.light.get(name) as string))).toBeLessThanOrEqual(0.06);
    // Dark: elevation-card is 0.4 / 0.5, while --o-shadow-lg reaches 0.6 and xl 0.7, a density that would smear the skeleton into a black block.
    expect(Math.max(...dropShadowAlphas(tokens.dark.get(name) as string))).toBeLessThanOrEqual(0.5);
  });
});
