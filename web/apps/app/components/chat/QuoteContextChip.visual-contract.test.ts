import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const css = readFileSync(join(process.cwd(), 'components/chat/QuoteContextChip.module.css'), 'utf8');

describe('QuoteContextChip visual contract', () => {
  it('uses restrained dynamic surfaces with distinct shadowless sent presentation', () => {
    expect(css).toContain('var(--o-primary) 10%');
    expect(css).toContain('var(--o-surface-raised)');
    expect(css).toMatch(/\[data-presentation='sent'\][\s\S]*?box-shadow:\s*none/);
    expect(css).not.toContain('backdrop-filter');
    expect(css).not.toContain('text-shadow');
  });

  it('keeps summary single-line, remove hit target 44px, and preview scrollable', () => {
    expect(css).toMatch(/\.summary[\s\S]*?text-overflow:\s*ellipsis[\s\S]*?white-space:\s*nowrap/);
    expect(css).toMatch(/\.remove[\s\S]*?width:\s*44px[\s\S]*?height:\s*44px/);
    expect(css).toMatch(/\.previewBody[\s\S]*?max-height:[\s\S]*?overflow:\s*auto/);
  });

  it('includes reduced-motion and forced-colors accommodations', () => {
    expect(css).toContain('@media (prefers-reduced-motion: reduce)');
    expect(css).toContain('@media (forced-colors: active)');
  });
});
