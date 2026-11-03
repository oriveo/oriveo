import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

import { WEB_ROOT, collectSourceCssFiles } from './source-css-files';

/**
 * Raw --o-primary as a foreground on light surfaces measured ~3.8:1 (Save as Note, Add another budget).
 * Theme-tinted text and icons on surfaces use --o-primary-text-on-surface; filled controls use
 * --o-primary-text-safe + --o-on-primary. Only decorative, non-text uses may stay on raw primary.
 */
const ALLOWED: Record<string, string> = {
  // Decorative watermark at opacity 0.06, not text.
  'apps/app/app/providers/[providerId]/ProviderBalanceCard.module.css': '.watermark',
};

describe('primary as foreground', () => {
  it('no CSS rule in apps/app or packages/ui paints text with raw var(--o-primary)', () => {
    const hits: string[] = [];
    for (const file of collectSourceCssFiles(['apps/app', 'packages/ui'])) {
      const lines = readFileSync(join(WEB_ROOT, file), 'utf8').split('\n');
      lines.forEach((line, index) => {
        if (/(^|[^-])color:\s*var\(--o-primary\)/.test(line)) hits.push(`${file}:${index + 1}`);
      });
    }
    const unexpected = hits.filter((hit) => !Object.keys(ALLOWED).some((file) => hit.startsWith(`${file}:`)));
    expect(unexpected).toEqual([]);
    // Allowlist stays tight: every entry still has exactly one hit.
    for (const file of Object.keys(ALLOWED)) {
      expect(hits.filter((hit) => hit.startsWith(`${file}:`))).toHaveLength(1);
    }
  });
});
