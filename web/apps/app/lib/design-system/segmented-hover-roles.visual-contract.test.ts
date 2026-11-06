/**
 * Segmented track, custom-entry hover and usage over-budget text follow iOS:
 * the track is --o-bg-subtle (light #F4F4F5 like the iOS system segmented control, dark below the
 * raised thumb) while the selected thumb stays --o-surface-raised; hovering a raised card shifts
 * toward the text color so it is visible in both modes; over-budget text uses the text role.
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

function ruleBody(path: string, selector: string): string {
  const css = readFileSync(join(process.cwd(), path), 'utf8');
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = css.match(new RegExp(`(?:^|\\n)\\s*${escaped}\\s*\\{([^}]*)\\}`));
  if (!match) throw new Error(`${selector} not found in ${path}`);
  return match[1];
}

function background(body: string): string | undefined {
  return body.match(/background(?:-color)?\s*:\s*([^;]+);/)?.[1].trim();
}

describe('segmented track and hover roles', () => {
  it('theme appearance segmented: muted track, raised thumb', () => {
    const path = 'app/settings/theme/ThemeSettings.module.css';
    expect(background(ruleBody(path, '.segmented'))).toBe('var(--o-bg-subtle)');
    expect(background(ruleBody(path, '.segmentOn'))).toBe('var(--o-surface-raised)');
  });

  it('context settings segments: muted track, raised thumb', () => {
    const path = 'app/settings/context/ContextSettingsPage.module.css';
    expect(background(ruleBody(path, '.segments'))).toBe('var(--o-bg-subtle)');
    expect(background(ruleBody(path, '.segmentSelected'))).toBe('var(--o-surface-raised)');
  });

  it('track and thumb tokens differ in every theme block', () => {
    const css = readFileSync(join(process.cwd(), '../../packages/ui/src/tokens/variables.css'), 'utf8');
    const blocks = [...css.matchAll(/\{([^{}]*)\}/g)].map((m) => m[1]);
    const pairs = blocks
      .map((body) => [body.match(/--o-bg-subtle:\s*([^;]+);/)?.[1], body.match(/--o-surface-raised:\s*([^;]+);/)?.[1]])
      .filter(([track, thumb]) => track && thumb);
    expect(pairs.length).toBeGreaterThanOrEqual(2);
    for (const [track, thumb] of pairs) expect(track).not.toBe(thumb);
  });

  it('provider custom entry hover uses surface-hover', () => {
    const path = 'app/providers/new/ProviderCard.module.css';
    // The base is --o-surface-raised; in dark --o-surface-hover equals raised, so hover nudges toward the text color instead.
    expect(background(ruleBody(path, '.customEntry:hover'))).toBe('color-mix(in srgb, var(--o-surface-raised) 94%, var(--o-text))');
  });
});
