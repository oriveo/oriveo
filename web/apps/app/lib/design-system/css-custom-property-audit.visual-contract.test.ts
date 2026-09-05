import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

import { ALLOWED, KNOWN_ALIASES, WEB_ROOT, auditCssCustomProperties, formatViolations } from './css-custom-property-audit';
import { collectSourceCssFiles } from './source-css-files';

/**
 * Guards every `var(--...)` in the workspace stylesheets against a property that is never defined.
 *
 * Such a reference is silently dropped by the browser: the declaration resolves to the
 * guaranteed-invalid value, nothing throws, nothing logs, and jsdom's `getComputedStyle` reports
 * the same empty string whether the token exists or not. Runtime tests cannot see it, so the
 * check has to read the stylesheets.
 */

const audit = auditCssCustomProperties();

describe('CSS custom property audit', () => {
  it('scans the whole workspace and finds the token file', () => {
    expect(audit.scannedFiles).toBeGreaterThan(100);
    expect(audit.tokenCount).toBeGreaterThan(250);
  });

  it('resolves every var() to a token, a local property, a registered injection, or a fallback', () => {
    expect(audit.violations, formatViolations(audit.violations)).toEqual([]);
  });

  it('keeps no registered exception that has lost all of its references', () => {
    expect(audit.staleAllowances, `these allowlist entries have lost every matching reference:\n  ${audit.staleAllowances.join('\n  ')}`).toEqual([]);
  });

  it('requires every registered exception to name its files and explain itself', () => {
    for (const entry of ALLOWED) {
      expect(entry.files.length, `--${entry.name} lists no file`).toBeGreaterThan(0);
      expect(entry.reason.length, `--${entry.name} has no usable reason`).toBeGreaterThan(20);
      if (entry.kind === 'injected') {
        expect(entry.reason, `--${entry.name} does not say which source writes it`).toMatch(/\.(tsx|ts|css)/);
      }
    }
  });

  it('requires an intentional-fallback exception to actually carry a fallback', () => {
    expect(
      audit.fallbacklessAllowances,
      `registered as intentional-fallback but written without one, so it is not a design decision, just a ghost nobody wrote:\n  ${audit.fallbacklessAllowances.join('\n  ')}`,
    ).toEqual([]);
  });

  it('points every known alias at a token that exists, and keeps the old name gone', () => {
    const tokens = new Set(
      [...readFileSync(join(WEB_ROOT, 'packages/ui/src/tokens/variables.css'), 'utf8').matchAll(/--([a-zA-Z0-9-]+)\s*:/g)].map(
        (match) => match[1],
      ),
    );
    for (const [wrong, right] of Object.entries(KNOWN_ALIASES)) {
      expect(tokens.has(right), `--${wrong} is mapped to --${right}, which is not in variables.css`).toBe(true);
      expect(tokens.has(wrong), `--${wrong} is registered as an alias but still defined as a token`).toBe(false);
    }
  });

  it('never reads stylesheets from an ignored directory', () => {
    // Generated stylesheets carry hashed class names and inlined custom properties. If the file
    // list ever stopped honouring .gitignore, a build directory would flood the report with
    // violations that no source file can fix.
    const artifactDir = join(WEB_ROOT, 'apps/app/.vercel/audit-probe');
    mkdirSync(artifactDir, { recursive: true });
    try {
      writeFileSync(
        join(artifactDir, 'ghost.module.css'),
        '.probe{color:var(--o-audit-probe-ghost-token);}\n',
        'utf8',
      );
      writeFileSync(
        join(artifactDir, 'globals.css'),
        ':root{--kind-accent:#f00;--o-mobile-tabbar-height:88px;}\n',
        'utf8',
      );

      expect(collectSourceCssFiles(['apps', 'packages']).filter((file) => file.includes('.vercel/'))).toEqual([]);

      const probed = auditCssCustomProperties();
      expect(
        probed.violations.filter((violation) => violation.file.includes('.vercel/')),
        formatViolations(probed.violations.filter((violation) => violation.file.includes('.vercel/'))),
      ).toEqual([]);
      expect(
        probed.staleAllowances,
        `a build artifact leaked into the global scope and pushed these allowlist entries into stale:\n  ${probed.staleAllowances.join('\n  ')}`,
      ).toEqual([]);
    } finally {
      rmSync(join(WEB_ROOT, 'apps/app/.vercel/audit-probe'), { recursive: true, force: true });
    }
  });
});
