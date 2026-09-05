import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * The metadata on a composer chip must never be clipped into a lie.
 *
 * What happened: `.meta` was pinned to `max-width:72px + text-overflow:ellipsis`, so a message
 * saying the model does not support a request was cut off right where the negation lives, inverting
 * the meaning. The escape hatch existed but only applied under `[data-read-only]` (the managed
 * read-only state), so none of the BYOK web search / reasoning / model behavior chips benefited.
 */
const css = readFileSync(join(process.cwd(), 'components/chat/ComposerToolButton.module.css'), 'utf8');

function rule(selector: string): string {
  const match = new RegExp(`(?:^|\\n)\\s*${selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*\\{([^}]*)\\}`).exec(css);
  expect(match, `${selector} rule exists`).toBeTruthy();
  return match![1];
}

describe('ComposerToolButton visual contract', () => {
  it('the base .meta rule does not truncate, and the escape hatch is not limited to the managed read-only state', () => {
    const meta = rule('.meta');
    expect(meta).not.toMatch(/text-overflow\s*:\s*ellipsis/);
    expect(meta).not.toMatch(/white-space\s*:\s*nowrap/);
    expect(meta).not.toMatch(/overflow\s*:\s*hidden/);
    expect(meta).toMatch(/white-space\s*:\s*normal/);
    expect(meta).toMatch(/overflow-wrap\s*:\s*anywhere/);
    // A fixed pixel cap is exactly what clipped the text down to a few characters.
    expect(meta).not.toMatch(/max-width\s*:\s*\d+px/);
    expect(meta).toMatch(/max-width\s*:\s*min\(/);
  });

  it('the no-wrap and truncation rules must not be gated on [data-read-only]', () => {
    const gated = /\.button\[data-read-only\]\s+\.meta\s*\{/.test(css);
    expect(gated, 'metadata readability must not be split into a managed and a non-managed variant').toBe(false);
  });

  it('narrow screens only tighten the cap and do not reintroduce truncation', () => {
    const mobile = /@media\s*\(max-width:\s*767px\)\s*\{([\s\S]*?)\n\}/.exec(css);
    expect(mobile).toBeTruthy();
    expect(mobile![1]).not.toMatch(/text-overflow/);
    expect(mobile![1]).not.toMatch(/white-space\s*:\s*nowrap/);
    expect(mobile![1]).toMatch(/max-width\s*:\s*min\(/);
  });

  it('the button itself may shrink inside a narrow composer so the toolbar does not overflow', () => {
    expect(rule('.button')).toMatch(/max-width\s*:\s*100%/);
  });

  it('a short label stays a single-line chip: label keeps nowrap and only metadata wraps', () => {
    expect(rule('.label')).toMatch(/white-space\s*:\s*nowrap/);
  });

  it('the active capability icons and parameter orb keep their compact size', () => {
    expect(rule('.capabilityIcons')).toMatch(/gap\s*:\s*3\.5px/);
    expect(rule('.capabilityIcons > span')).toMatch(/width\s*:\s*11px/);
    expect(rule('.emphasisOrb')).toMatch(/width\s*:\s*12px/);
    expect(css).toMatch(/\.emphasisOrb::after\s*\{/);
  });
});
