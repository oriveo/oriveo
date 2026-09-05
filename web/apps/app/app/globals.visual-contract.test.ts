import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Source-level contract for the global stylesheet: form controls must inherit the theme
 * colour.
 *
 * It has to be a source-level assertion because jsdom implements neither the system colours
 * of the UA stylesheet nor the cascade, so `getComputedStyle` only ever returns the literal
 * the author wrote, which is exactly the class of defect ("the author wrote nothing, so the
 * UA default applied") that cannot be observed that way. Precedents in this repo:
 * css-custom-property-audit.visual-contract.test.ts and
 * components/generation/GenerationParameterPanel.visual-contract.test.ts.
 *
 * The mechanism: the UA stylesheet gives `button` / `input` / `textarea` / `select` their
 * own `color: buttontext` / `fieldtext` system colour, and that declaration blocks colour
 * inheritance from the parent. This app also declares no `color-scheme`, so browsers
 * resolve those system colours as light. The result is that in the dark theme any control
 * without an explicit color is black text on a dark background.
 *
 * This is the same class of defect as a framework default that does not flip with the
 * theme: the light theme happens to look right, so it only shows up in dark mode and can
 * survive all the way to users.
 */

const globalsCss = readFileSync(join(process.cwd(), 'app/globals.css'), 'utf8');

describe('globals.css visual contract', () => {
  it('makes form controls inherit both font and colour, since inheriting only the font leaves black text in dark mode', () => {
    const rule = /(?:^|\n)button,\s*\n\s*input,\s*\n\s*textarea,\s*\n\s*select\s*\{([^}]*)\}/.exec(globalsCss);
    expect(rule, 'a unified reset rule for button/input/textarea/select exists').toBeTruthy();

    expect(rule![1], 'without font: inherit, controls fall back to the UA 13.333px Arial').toMatch(/font\s*:\s*inherit/);
    expect(rule![1], 'without color: inherit, controls take the UA buttontext system colour, which is black text in dark mode')
      .toMatch(/(?<![\w-])color\s*:\s*inherit/);
  });

  it('makes the inheritance source itself a theme colour rather than another literal', () => {
    const body = /(?:^|\n)body\s*\{([^}]*)\}/.exec(globalsCss);
    expect(body, 'the body rule exists').toBeTruthy();
    // This is what the controls inherit; if it hardcodes a hex value, the inherit above fixes nothing.
    expect(body![1], 'the body color must go through a theme token').toMatch(/(?<![\w-])color\s*:\s*var\(--o-text\b/);
  });
});
