import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Dialog } from './Dialog';

// Named after the repository's `*.visual-contract.test.*` convention; the extension is .tsx because
// the vitest include for packages/ui is `src/**/*.test.tsx`, so a .ts file would not be collected.

// The leading newline lets a rule on the very first line match, and stops `.dialogFlush {` from matching `.dialog {`
const css = `\n${readFileSync(
  join(dirname(fileURLToPath(import.meta.url)), 'Dialog.module.css'),
  'utf8',
)}`;

/** Extract the declaration body of one rule. A whole-file not.toContain would trip over the same property used legitimately elsewhere, so assertions have to be per block. */
function ruleBody(selector: string): string {
  const marker = `\n${selector} {`;
  const start = css.indexOf(marker);
  expect(start, `no rule ${selector} found in Dialog.module.css`).toBeGreaterThanOrEqual(0);
  const bodyStart = start + marker.length;
  const end = css.indexOf('\n}', bodyStart);
  expect(end, `rule ${selector} is never closed`).toBeGreaterThan(bodyStart);
  return css.slice(bodyStart, end);
}

describe('Dialog visual contract: the surface must not be switched off by a padding option', () => {
  // .dialogFlush once also carried background/border/box-shadow, which left every padded={false}
  // caller with its content sitting directly on the dark overlay.
  it('.dialogFlush only touches padding, never background / border / box-shadow', () => {
    const flush = ruleBody('.dialogFlush');

    expect(flush).toContain('padding: 0;');
    expect(flush).not.toMatch(/background/);
    expect(flush).not.toMatch(/border/);
    expect(flush).not.toMatch(/box-shadow/);
    expect(flush).not.toMatch(/backdrop-filter/);
  });

  // Stops the same hole coming back in another form: move the chrome off the base class and flush looks harmless again.
  it('.dialog always provides the background, border and shadow', () => {
    const base = ruleBody('.dialog');

    expect(base).toMatch(/background:\s*color-mix\(in srgb, var\(--o-surface\)/);
    expect(base).toMatch(/border:\s*1px solid var\(--o-border\)/);
    expect(base).toMatch(/box-shadow:\s*\n?\s*var\(--o-elevation-modal\)/);
  });

  it('.dialogSurfaceless is the only way to drop the surface, and must not touch padding', () => {
    const surfaceless = ruleBody('.dialogSurfaceless');

    expect(surfaceless).toMatch(/background:\s*transparent;/);
    expect(surfaceless).toMatch(/border:\s*0;/);
    expect(surfaceless).toMatch(/box-shadow:\s*none;/);
    expect(surfaceless).not.toMatch(/padding/);
  });
});

describe('Dialog padded and surface props each have a single responsibility', () => {
  beforeEach(() => {
    vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback) => {
      callback(0);
      return 1;
    });
  });

  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  function shellClassName(): string {
    return screen.getByRole('button', { name: 'Action' }).parentElement?.className ?? '';
  }

  it('padded={false} only adds flush and does not clear the surface', () => {
    render(
      <Dialog open padded={false}>
        <button type="button">Action</button>
      </Dialog>,
    );

    expect(shellClassName()).toContain('dialogFlush');
    expect(shellClassName()).not.toContain('dialogSurfaceless');
  });

  it('surface={false} only clears the surface and does not clear padding', () => {
    render(
      <Dialog open surface={false}>
        <button type="button">Action</button>
      </Dialog>,
    );

    expect(shellClassName()).toContain('dialogSurfaceless');
    expect(shellClassName()).not.toContain('dialogFlush');
  });

  it('a caller drawing its own shell turns both off and still gets a clean class string', () => {
    render(
      <Dialog open size="xl" padded={false} surface={false}>
        <button type="button">Action</button>
      </Dialog>,
    );

    const className = shellClassName();
    expect(className).toContain('dialogXl');
    expect(className).toContain('dialogFlush');
    expect(className).toContain('dialogSurfaceless');
    expect(className).not.toContain('undefined');
    expect(className).not.toMatch(/\s{2,}|^\s|\s$/);
  });

  it('the default has both padding and a surface', () => {
    render(
      <Dialog open>
        <button type="button">Action</button>
      </Dialog>,
    );

    expect(shellClassName()).not.toContain('dialogFlush');
    expect(shellClassName()).not.toContain('dialogSurfaceless');
  });
});
