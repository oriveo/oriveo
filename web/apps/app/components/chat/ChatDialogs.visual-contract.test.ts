import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * The two padded={false} dialogs in chat also draw no shell of their own: background,
 * border and shadow all come from the @oriveo/ui Dialog base class. If the shared
 * `.dialogFlush` modifier ever clears those three along with the padding, the dialogs fall
 * back to content sitting directly on the dark overlay.
 */

const dialogCss = readFileSync(
  join(process.cwd(), '../../packages/ui/src/components/Dialog/Dialog.module.css'),
  'utf8',
);

function ruleBody(source: string, selector: string, label: string): string {
  // Anchor the search on a leading newline so a selector cannot match as the tail of a longer
  // one (`.header h2` would otherwise also match `.compact .header h2`).
  const css = `\n${source}`;
  const marker = `\n${selector} {`;
  const start = css.indexOf(marker);
  expect(start, `${label} has no rule for ${selector}`).toBeGreaterThanOrEqual(0);
  const bodyStart = start + marker.length;
  const end = css.indexOf('\n}', bodyStart);
  expect(end, `the ${selector} rule in ${label} is not closed`).toBeGreaterThan(bodyStart);
  return css.slice(bodyStart, end);
}

const DEPENDENTS = ['LibraryContextPicker', 'MessageTokenUsageDialog'] as const;

describe('chat dialogs rely on the Dialog base class shell', () => {
  it.each(DEPENDENTS)('%s uses padded={false} to take over the padding without ever turning off the shell surface', (name) => {
    const tsx = readFileSync(join(process.cwd(), `components/chat/${name}.tsx`), 'utf8');

    expect(tsx).toContain('padded={false}');
    expect(tsx).not.toContain('surface={false}');
  });

  it('MessageTokenUsageDialog .panel only handles position and padding, not the surface', () => {
    const css = readFileSync(
      join(process.cwd(), 'components/chat/MessageTokenUsageDialog.module.css'),
      'utf8',
    );
    const body = ruleBody(css, '.panel', 'MessageTokenUsageDialog.module.css');

    expect(body).toContain('padding:');
    expect(body).not.toMatch(/(^|[\s;])background(-color|-image)?:/);
    expect(body).not.toMatch(/(^|[\s;])border:/);
    expect(body).not.toMatch(/(^|[\s;])box-shadow:/);
  });

  it('the .dialogFlush they pass clears only padding, never the shell surface', () => {
    const flush = ruleBody(dialogCss, '.dialogFlush', 'Dialog.module.css');

    expect(flush).toContain('padding: 0;');
    expect(flush).not.toMatch(/background/);
    expect(flush).not.toMatch(/border/);
    expect(flush).not.toMatch(/box-shadow/);
  });

  it('the Dialog base class still provides the surface that makes these two dialogs read as overlays', () => {
    const base = ruleBody(dialogCss, '.dialog', 'Dialog.module.css');

    expect(base).toMatch(/background:\s*color-mix\(in srgb, var\(--o-surface\)/);
    expect(base).toMatch(/border:\s*1px solid var\(--o-border\)/);
    expect(base).toMatch(/box-shadow:\s*var\(--o-elevation-modal\)/);
  });

  // LibraryContextPicker has no wrapping container: .header, .scopeCard, .results and
  // .actions are direct children of Dialog and carry their own padding, so flush must keep
  // zeroing the base class padding, or they end up with 24px from the base plus 20px of their own.
  it('the direct children of LibraryContextPicker carry their own padding, so flush must zero the base class padding', () => {
    const css = readFileSync(
      join(process.cwd(), 'components/chat/LibraryContextPicker.module.css'),
      'utf8',
    );

    expect(ruleBody(css, '.header', 'LibraryContextPicker.module.css')).toMatch(/padding:/);
    expect(ruleBody(css, '.results', 'LibraryContextPicker.module.css')).toMatch(/padding:/);
    expect(ruleBody(css, '.actions', 'LibraryContextPicker.module.css')).toMatch(/padding:/);
    expect(ruleBody(dialogCss, '.dialogFlush', 'Dialog.module.css')).toContain('padding: 0;');
  });
});
