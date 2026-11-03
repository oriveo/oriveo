import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Usage demo upgrade banner placement contract (source-level CSS assertions).
 *
 * 1. Horizontal placement uses logical insets (inset-inline-start / end), never physical left / right.
 * 2. The banner sits above the mobile tab bar: bottom adds --o-mobile-tabbar-height, also in the narrow layout.
 * 3. The banner keeps a minimum width so a wide sidebar cannot squeeze it into a narrow column.
 * 4. Wide: the banner is as wide as the page content column; narrow: the CTA wraps onto its own full row.
 * 5. Text uses --o-on-primary over the text-safe primary fill (>= 4.5:1 in light and dark).
 * 6. The demo page reserves bottom room for the banner, including the mobile tab bar.
 */
const css = readFileSync(join(process.cwd(), 'components/usage/UsageInsightsDemoCard.module.css'), 'utf8');

function ruleBody(selector: string, source: string): string {
  const match = new RegExp(`(?:^|\\n)\\s*${selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{([^}]*)\\}`).exec(source);
  expect(match, `rule ${selector} exists`).toBeTruthy();
  return match![1];
}

function declaration(body: string, property: string): string {
  const match = new RegExp(`(?:^|;|\\n)\\s*${property}\\s*:\\s*([^;]+)`).exec(body);
  expect(match, `declares ${property}`).toBeTruthy();
  return match![1].trim();
}

function mediaBlock(query: string, source: string): string {
  const start = source.indexOf(`@media ${query}`);
  expect(start, `media ${query} exists`).toBeGreaterThanOrEqual(0);
  const open = source.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < source.length; i += 1) {
    if (source[i] === '{') depth += 1;
    if (source[i] === '}' && (depth -= 1) === 0) return source.slice(open + 1, i);
  }
  throw new Error(`unterminated media ${query}`);
}

const pageCss = readFileSync(join(process.cwd(), 'app/chat/usage/page.module.css'), 'utf8');
const base = ruleBody('.card', css);
const narrow = ruleBody('.card', mediaBlock('(max-width: 640px)', css));

describe('Usage demo banner placement', () => {
  it('uses logical insets instead of left / right', () => {
    expect(declaration(base, 'inset-inline-start')).toContain('--o-sidebar-width');
    expect(declaration(base, 'inset-inline-end')).toBe('24px');
    expect(declaration(narrow, 'inset-inline-start')).toBe('16px');
    expect(declaration(narrow, 'inset-inline-end')).toBe('16px');
    for (const body of [base, narrow]) {
      expect(body).not.toMatch(/(?:^|[;\s])(?:left|right)\s*:/);
    }
  });

  it('clears the mobile tab bar', () => {
    expect(declaration(base, 'bottom')).toContain('var(--o-mobile-tabbar-height');
    expect(declaration(narrow, 'bottom')).toBe('calc(var(--o-mobile-tabbar-height, 0px) + 16px)');
  });

  it('keeps a minimum width beside a wide sidebar', () => {
    expect(declaration(base, 'min-width')).toMatch(/^min\(\d+px, calc\(100vw - \d+px\)\)$/);
  });

  it('matches the content column width on wide screens', () => {
    const contentMax = declaration(ruleBody('.content', pageCss), 'max-width');
    expect(declaration(base, 'max-width')).toBe(contentMax);
  });

  it('stacks the CTA onto its own full-width row on narrow screens', () => {
    const narrowBlock = mediaBlock('(max-width: 640px)', css);
    expect(declaration(narrow, 'flex-wrap')).toBe('wrap');
    expect(declaration(ruleBody('.cta', narrowBlock), 'flex-basis')).toBe('100%');
  });

  it('uses on-primary text over the text-safe primary fill', () => {
    expect(declaration(base, 'background')).toMatch(/var\(--o-primary-text-safe\)\s*$/);
    expect(declaration(base, 'color')).toBe('var(--o-on-primary)');
    for (const selector of ['.title', '.description']) {
      expect(declaration(ruleBody(selector, css), 'color')).toBe('var(--o-on-primary)');
    }
    expect(declaration(ruleBody('.cta', css), 'color')).toBe('var(--o-primary-text-safe)');
  });

  it('reserves bottom room on the demo page, including the mobile tab bar', () => {
    expect(declaration(ruleBody('.pageDemo', pageCss), 'padding-bottom')).toContain('var(--o-mobile-tabbar-height');
    const narrowPage = ruleBody('.pageDemo', mediaBlock('(max-width: 640px)', pageCss));
    expect(declaration(narrowPage, 'padding-bottom')).toContain('var(--o-mobile-tabbar-height');
  });
});
