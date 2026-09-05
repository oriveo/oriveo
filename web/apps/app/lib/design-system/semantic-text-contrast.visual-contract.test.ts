import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

import { WEB_ROOT, collectSourceCssFiles } from './source-css-files';
import {
  AA_LARGE_TEXT,
  AA_NORMAL_TEXT,
  KNOWN_GAPS,
  LEGACY_UNTRIAGED,
  REQUIRED_BACKDROPS,
  TEXT_VARIANT_OF,
  VERIFIED_NEUTRAL_TEXT_SITES,
  VERIFIED_TEXT_SITES,
  VIVID_SEMANTIC_TOKENS,
  contrastRatio,
  isLargeText,
  measureKnownGap,
  measureTextSite,
  parseColor,
  readDeclaration,
  readFontMetrics,
  readThemeTokens,
  scanBareVividSemanticText,
} from './semantic-text-contrast';

/**
 * Gate for "a semantic color used as body text must measure at least 4.5:1".
 *
 * The design rationale lives in the comment at the top of semantic-text-contrast.ts; this file only
 * holds the assertions.
 *
 * Every assertion is written so that it fails under a naive implementation:
 *   - the variant token cases: without --o-*-text defined, parseColor throws "not defined".
 *   - the per-site cases: both color and every background layer are read from the source files, so
 *     falling back to var(--o-error) immediately drops to 3.3.
 *   - the scan cases: turning any single site back to a bare vivid semantic color adds an
 *     unregistered key.
 */

const tokens = readThemeTokens();
const THEMES = ['light', 'dark'] as const;

describe('semantic text variant tokens', () => {
  it.each(THEMES)('%s theme: every variant reaches AA 4.5:1 on --o-surface and --o-bg-subtle', (theme) => {
    const failures: string[] = [];
    for (const variant of Object.values(TEXT_VARIANT_OF)) {
      for (const backdrop of REQUIRED_BACKDROPS) {
        const background = parseColor(`var(${backdrop})`, theme, tokens);
        const ratio = contrastRatio(parseColor(`var(${variant})`, theme, tokens), background);
        if (ratio < AA_NORMAL_TEXT) failures.push(`${variant} on ${backdrop} = ${ratio.toFixed(4)}:1`);
      }
    }
    expect(failures, `${theme} theme: these variants are below 4.5:1:\n  ${failures.join('\n  ')}`).toEqual([]);
  });

  it('a dark-theme variant is never darker than the vivid color it derives from, since dark already passes and darkening only loses contrast', () => {
    const regressions: string[] = [];
    for (const [vivid, variant] of Object.entries(TEXT_VARIANT_OF)) {
      for (const backdrop of REQUIRED_BACKDROPS) {
        const background = parseColor(`var(${backdrop})`, 'dark', tokens);
        const before = contrastRatio(parseColor(`var(${vivid})`, 'dark', tokens), background);
        const after = contrastRatio(parseColor(`var(${variant})`, 'dark', tokens), background);
        // Equal is allowed (a dark variant may point back at the original value); worse is not.
        if (after < before - 1e-9) regressions.push(`${variant} on ${backdrop}: ${before.toFixed(4)} → ${after.toFixed(4)}`);
      }
    }
    expect(regressions, `dark contrast got worse:\n  ${regressions.join('\n  ')}`).toEqual([]);
  });

  it('a light variant really is darker than its vivid color, otherwise it is just an alias', () => {
    const useless: string[] = [];
    for (const [vivid, variant] of Object.entries(TEXT_VARIANT_OF)) {
      const white = parseColor('#ffffff', 'light', tokens);
      const before = contrastRatio(parseColor(`var(${vivid})`, 'light', tokens), white);
      const after = contrastRatio(parseColor(`var(${variant})`, 'light', tokens), white);
      if (after <= before) useless.push(`${variant} on white ${after.toFixed(4)} <= ${vivid} at ${before.toFixed(4)}`);
    }
    expect(useless, `these variants did not get darker:\n  ${useless.join('\n  ')}`).toEqual([]);
  });

  it('variants keep their hue identity (red still reads red, green green, purple purple) and have not collapsed to grey', () => {
    const flattened: string[] = [];
    for (const variant of Object.values(TEXT_VARIANT_OF)) {
      const [r, g, b] = parseColor(`var(${variant})`, 'light', tokens);
      const chroma = Math.max(r, g, b) - Math.min(r, g, b);
      if (chroma < 60) flattened.push(`${variant} rgb(${r},${g},${b}) only has chroma ${chroma}`);
    }
    expect(flattened, `these variants are too desaturated to read as a semantic color:\n  ${flattened.join('\n  ')}`).toEqual([]);
  });

  it('the vivid colors themselves are untouched; variants are purely additive', () => {
    expect(parseColor('var(--o-success)', 'light', tokens).slice(0, 3)).toEqual([16, 185, 129]);
    expect(parseColor('var(--o-warning)', 'light', tokens).slice(0, 3)).toEqual([245, 158, 11]);
    expect(parseColor('var(--o-error)', 'light', tokens).slice(0, 3)).toEqual([239, 68, 68]);
    expect(parseColor('var(--o-info)', 'light', tokens).slice(0, 3)).toEqual([59, 130, 246]);
    expect(parseColor('var(--o-primary)', 'light', tokens).slice(0, 3)).toEqual([139, 92, 246]);
  });

  /**
   * The two model-control modal tokens. The same names and the same values are used on every
   * client: `textDisabledOnControl` and `primaryTextSafe`.
   * The literal values here are deliberate: they are the alignment anchor, so a one-sided change on
   * any client fails this assertion.
   */
  it('the model-control tokens match the values used on the other clients exactly', () => {
    expect(parseColor('var(--o-text-disabled-on-control)', 'light', tokens).slice(0, 3)).toEqual([0x6a, 0x6a, 0x73]);
    expect(parseColor('var(--o-text-disabled-on-control)', 'dark', tokens).slice(0, 3)).toEqual([0x9a, 0xa0, 0xac]);
    expect(parseColor('var(--o-primary-text-safe)', 'light', tokens).slice(0, 3)).toEqual([0x6d, 0x28, 0xd9]);
    expect(parseColor('var(--o-primary-text-safe)', 'dark', tokens).slice(0, 3)).toEqual([0xa7, 0x8b, 0xfa]);
  });

  it('the two themes carry two distinct values; writing one value for both would mean the dark step was never tuned', () => {
    for (const token of ['--o-text-disabled-on-control', '--o-primary-text-safe'] as const) {
      expect(parseColor(`var(${token})`, 'light', tokens), `${token} has the same value in both themes`).not.toEqual(
        parseColor(`var(${token})`, 'dark', tokens),
      );
    }
  });

  /**
   * Counter-example: the raw `--o-primary` used as a fill behind text really does fail in the light
   * theme. Without this assertion, switching to the text-safe fill variant would prove nothing.
   */
  it('the raw --o-primary as an accent fill is below AA in the light theme', () => {
    const fill = parseColor('var(--o-primary)', 'light', tokens);
    const ratio = contrastRatio(parseColor('var(--o-primary-text)', 'light', tokens), fill);
    expect(ratio, `--o-primary unexpectedly passes at ${ratio.toFixed(4)}:1, so this counter-example is void`).toBeLessThan(AA_NORMAL_TEXT);
  });

  it('--o-primary itself was not quietly changed to the text-safe step; fills, icons and borders keep the vivid value', () => {
    expect(parseColor('var(--o-primary)', 'light', tokens).slice(0, 3)).toEqual([139, 92, 246]);
    expect(parseColor('var(--o-primary)', 'dark', tokens).slice(0, 3)).toEqual([167, 139, 250]);
  });

  it('--o-primary-text and --o-primary-text-on-surface stay two distinct semantics and are not written as one value', () => {
    // The first is "text on top of a primary fill" (white); the second is "purple used as text on an
    // ordinary surface". Writing one value for both means somebody confused the two, which turns the
    // white label on a filled button purple.
    expect(parseColor('var(--o-primary-text)', 'light', tokens)).not.toEqual(
      parseColor('var(--o-primary-text-on-surface)', 'light', tokens),
    );
    expect(parseColor('var(--o-primary-text)', 'dark', tokens)).not.toEqual(
      parseColor('var(--o-primary-text-on-surface)', 'dark', tokens),
    );
  });
});

describe('measured contrast at each text site', () => {
  const sites = [...VERIFIED_TEXT_SITES, ...VERIFIED_NEUTRAL_TEXT_SITES];

  it('the registry has no duplicate ids, which would make "changed one, missed the other" look green', () => {
    expect(new Set(sites.map((site) => site.id)).size).toBe(sites.length);
  });

  it.each(THEMES)('%s theme: every site meets the threshold it is held to', (theme) => {
    const failures: string[] = [];
    for (const site of sites) {
      const ratio = measureTextSite(site, theme, tokens);
      let threshold = AA_NORMAL_TEXT;
      if (site.largeTextExemption) {
        const metrics = readFontMetrics(site.file, site.selector, tokens);
        // Claiming large text is not enough: if the exact pixel size cannot be read, or is not actually large, the site is held to 4.5:1.
        if (metrics.size !== null && isLargeText(metrics.size, metrics.weight)) threshold = AA_LARGE_TEXT;
      }
      if (ratio < threshold) failures.push(`${site.id} = ${ratio.toFixed(4)}:1 (needs >=${threshold})`);
    }
    expect(failures, `${theme} theme: these sites are below threshold:\n  ${failures.join('\n  ')}`).toEqual([]);
  });

  it('every registered site really switched to a variant or a neutral color, with no bare vivid semantic color left', () => {
    const leftovers: string[] = [];
    for (const site of VERIFIED_TEXT_SITES) {
      const declared = readDeclaration(site.file, site.selector, 'color');
      const vivid = VIVID_SEMANTIC_TOKENS.find((name) => new RegExp(`^var\\(\\s*${name}\\s*[,)]`).test(declared));
      if (vivid) leftovers.push(`${site.id}: color: ${declared} -> should use ${TEXT_VARIANT_OF[vivid]}`);
    }
    expect(leftovers, `these sites still use a non-text vivid value as text:\n  ${leftovers.join('\n  ')}`).toEqual([]);
  });

  it('the large-text exemption rule itself is correct (WCAG: >=24px, or >=18.66px at weight >=700)', () => {
    expect(isLargeText(24, 400)).toBe(true);
    expect(isLargeText(23.9, 400)).toBe(false);
    expect(isLargeText(18.66, 700)).toBe(true);
    expect(isLargeText(18.66, 600)).toBe(false);
    expect(isLargeText(18.65, 700)).toBe(false);
  });

  it('no registered site currently takes the large-text exemption; adding one requires re-checking the real font size, as above', () => {
    // This is not decoration: whoever adds a largeTextExemption is forced to put the element's actual
    // font-size and weight into the source file rather than waving it through with a comment.
    const exempted = sites.filter((site) => site.largeTextExemption);
    for (const site of exempted) {
      const metrics = readFontMetrics(site.file, site.selector, tokens);
      expect(metrics.size, `${site.id} claims large text but no exact px size can be read from the source`).not.toBeNull();
      expect(isLargeText(metrics.size as number, metrics.weight), `${site.id} at ${metrics.size}px/${metrics.weight} does not meet the WCAG large-text rule`).toBe(true);
    }
    expect(exempted.map((site) => site.id)).toEqual([]);
  });
});

describe('known gaps that measure below threshold and are out of scope to fix here', () => {
  it.each(THEMES)('%s theme: measurements still match the registry, so any change up or down comes back for a decision', (theme) => {
    for (const gap of KNOWN_GAPS) {
      const measured = measureKnownGap(gap, theme, tokens);
      expect(measured, `${gap.id} measures ${measured.toFixed(4)} in the ${theme} theme, which does not match the registered ${gap.measured[theme]}`).toBeCloseTo(
        gap.measured[theme],
        3,
      );
    }
  });

  it('every gap states why it is not being fixed here rather than just saying "known"', () => {
    for (const gap of KNOWN_GAPS) expect(gap.reason.length, `${gap.id} has too short a reason`).toBeGreaterThan(60);
  });

  it('the gap list keeps no entry that already passes; a passing entry belongs in VERIFIED_TEXT_SITES', () => {
    const fixed = KNOWN_GAPS.filter((gap) => gap.measured.light >= AA_NORMAL_TEXT && gap.measured.dark >= AA_NORMAL_TEXT);
    expect(fixed.map((gap) => gap.id), 'these gaps now pass in both themes and should be promoted').toEqual([]);
  });
});

describe('repository scan: no new bare semantic color used as body text', () => {
  const scanned = scanBareVividSemanticText();

  it('the scan surface is not idle; a gate that finds nothing is the most expensive kind of false green', () => {
    expect(scanned.length).toBeGreaterThan(20);
  });

  it('every bare semantic color used as text is either fixed or in the frozen baseline; nothing new gets through', () => {
    const registered = new Set([
      ...VERIFIED_TEXT_SITES.map((site) => `${site.file} {${site.selector}}`),
      ...LEGACY_UNTRIAGED,
    ]);
    const unregistered = scanned.filter((usage) => !registered.has(usage.key));
    expect(
      unregistered.map((usage) => `${usage.key}  color: var(${usage.token}) -> should use var(${TEXT_VARIANT_OF[usage.token]})`),
      'these sites use a non-text vivid semantic color directly as body text and cannot reach 4.5:1 in the light theme:\n  ' +
        unregistered.map((usage) => usage.key).join('\n  '),
    ).toEqual([]);
  });

  it('the frozen baseline has no stale entries; a renamed selector or a fixed site is dropped in the same round instead of quietly waving the next one through', () => {
    const live = new Set(scanned.map((usage) => usage.key));
    const stale = LEGACY_UNTRIAGED.filter((key) => !live.has(key));
    expect(stale, `these baseline entries do not exist any more:\n  ${stale.join('\n  ')}`).toEqual([]);
  });

  /**
   * Observed false positive: `apps/app/out-desktop/` (the Electron export output matched by
   * `.gitignore`) was picked up by the scan and reported the same sites again under a different
   * hashed file name and a different hashed class name, turning the gate red without a single source
   * change. Patching a manual directory blacklist with `out-desktop` is exactly how the next
   * `out-*` / `.vercel/` / `.firebase/` gets missed.
   *
   * So this asserts no specific directory name. It creates a build artifact that .gitignore matches
   * (whose content is guaranteed to trip the scanner) and asserts it changes the scan result by not
   * one byte.
   */
  it('build artifacts are not scanned; the scan surface follows .gitignore rather than a manual directory blacklist', () => {
    const artifactDir = join(WEB_ROOT, 'apps/app/.vercel/oriveo-contrast-probe');
    mkdirSync(artifactDir, { recursive: true });
    try {
      writeFileSync(
        join(artifactDir, 'built.css'),
        '.probe_hash{font-size:13px;color:var(--o-error);}\n',
        'utf8',
      );

      expect(collectSourceCssFiles(['apps', 'packages']).filter((file) => file.includes('.vercel/'))).toEqual([]);

      const probed = scanBareVividSemanticText();
      expect(
        probed.filter((usage) => usage.file.includes('.vercel/')).map((usage) => usage.key),
        'a build artifact was picked up by the semantic color gate; the scan surface must be source only',
      ).toEqual([]);
    } finally {
      rmSync(join(WEB_ROOT, 'apps/app/.vercel/oriveo-contrast-probe'), { recursive: true, force: true });
    }
  });

  it('the sites fixed here are out of the baseline, so the baseline cannot wave them back through', () => {
    const overlap = VERIFIED_TEXT_SITES.map((site) => `${site.file} {${site.selector}}`).filter((key) =>
      LEGACY_UNTRIAGED.includes(key),
    );
    expect(overlap, `these sites appear in both the fixed list and the frozen baseline:\n  ${overlap.join('\n  ')}`).toEqual([]);
  });
});
