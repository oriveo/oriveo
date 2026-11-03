import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Floating containers that sit over body text (dropdowns, anchored popovers) paint an opaque
 * surface, so text underneath never shows through in light mode. Frosted chrome (toast, context
 * menus) keeps its blur glass and is out of scope here.
 */
const read = (path: string) => readFileSync(join(process.cwd(), path), 'utf8');

const tokensCss = read('../../packages/ui/src/tokens/variables.css');
const memoryUsedCss = read('components/chat/MemoryUsedPopover.module.css');

function ruleBody(selector: string, source: string): string {
  const match = new RegExp(`(?:^|\\n)\\s*${selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{([^}]*)\\}`).exec(source);
  expect(match, `rule ${selector} exists`).toBeTruthy();
  return match![1];
}

function tokenValues(name: string): string[] {
  const re = new RegExp(`${name.replace(/-/g, '\\-')}\\s*:\\s*([^;]+);`, 'g');
  return [...tokensCss.matchAll(re)].map((m) => m[1].trim());
}

describe('Floating containers over text are opaque', () => {
  it('MenuSelect / memory item menu token is opaque in every theme', () => {
    const values = tokenValues('--o-ms-menu-bg');
    expect(values.length).toBeGreaterThanOrEqual(2);
    for (const value of values) {
      expect(value).not.toMatch(/transparent|rgba|--o-surface-overlay/);
    }
  });

  it('memory-used popover paints an opaque surface', () => {
    const body = ruleBody('.popover', memoryUsedCss);
    expect(body).toMatch(/background:\s*var\(--o-surface\);/);
  });
});
