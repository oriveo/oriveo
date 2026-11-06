/**
 * Shared fixture studio_presets.v1.json clientCases: envelope decoding, locale
 * resolution, the bundled offline snapshot (loaded through the production
 * bundledStudioPresetsSnapshot), and the refresh plan / response handling.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  applyStudioPresetResponse,
  bundledStudioPresetsSnapshot,
  decodeStudioPresets,
  localizeStudioPresets,
  planStudioPresetRefresh,
  resolveStudioPresetLocale,
  type StudioPresetApplyInput,
  type StudioPresetRefreshInput,
} from '../presets';

const ROOT = resolve(__dirname, '../../../../../../..');
const CONTRACTS = resolve(ROOT, 'shared/studio-contracts');

function readJson<T>(name: string): T {
  return JSON.parse(readFileSync(resolve(CONTRACTS, name), 'utf8')) as T;
}

interface SnapshotExpect {
  locale: string;
  revision: string;
  styles: number;
  effects: number;
  dropped: number;
  everySampleNull: boolean;
  firstStyle: Record<string, unknown>;
  firstEffect: Record<string, unknown>;
  firstStyleGroup: Record<string, unknown>;
}

const fixture = readJson<{
  contractId: string;
  locales: string[];
  clientCases: {
    decode: Array<{ caseId: string; input: unknown; expect: unknown }>;
    locale: Array<{ tag: unknown; expect: string }>;
    snapshot: Array<{ tag: string; expect: SnapshotExpect }>;
    refreshPlan: Array<{ caseId: string; input: StudioPresetRefreshInput; expect: unknown }>;
    refreshApply: Array<{ caseId: string; input: StudioPresetApplyInput; expect: unknown }>;
  };
}>('studio_presets.v1.json');
const cases = fixture.clientCases;

describe('studio_presets.v1 clientCases', () => {
  it('decodeCases', () => {
    expect(cases.decode.length).toBeGreaterThan(0);
    for (const c of cases.decode) {
      expect(decodeStudioPresets(c.input), c.caseId).toStrictEqual(c.expect);
    }
  });

  it('localeCases', () => {
    expect(cases.locale.length).toBeGreaterThan(0);
    for (const c of cases.locale) {
      expect(resolveStudioPresetLocale(fixture.locales, c.tag), `locale tag ${JSON.stringify(c.tag)}`).toBe(c.expect);
    }
  });

  it('snapshotCases', () => {
    expect(cases.snapshot.length).toBeGreaterThan(0);
    for (const c of cases.snapshot) {
      const label = `snapshot tag ${c.tag}`;
      const r = decodeStudioPresets(localizeStudioPresets(bundledStudioPresetsSnapshot(), c.tag));
      expect(r.error, label).toBeNull();
      if (r.error !== null) continue;
      expect(r.locale, `${label} locale`).toBe(c.expect.locale);
      expect(r.revision, `${label} revision`).toBe(c.expect.revision);
      expect(r.styles.length, `${label} styles`).toBe(c.expect.styles);
      expect(r.effects.length, `${label} effects`).toBe(c.expect.effects);
      expect(r.dropped.length, `${label} dropped`).toBe(c.expect.dropped);
      expect(r.styles.every((s) => s.sample === null), `${label} everySampleNull`).toBe(c.expect.everySampleNull);
      const s = r.styles[0];
      expect(
        s && { id: s.id, displayName: s.displayName, description: s.description, placeholderColor: s.placeholderColor },
        `${label} firstStyle`,
      ).toStrictEqual(c.expect.firstStyle);
      const e = r.effects[0];
      expect(e && { id: e.id, displayName: e.displayName }, `${label} firstEffect`).toStrictEqual(c.expect.firstEffect);
      expect(r.styleGroups[0], `${label} firstStyleGroup`).toStrictEqual(c.expect.firstStyleGroup);
    }
  });

  it('refreshPlanCases', () => {
    expect(cases.refreshPlan.length).toBeGreaterThan(0);
    for (const c of cases.refreshPlan) {
      expect(planStudioPresetRefresh(c.input), c.caseId).toStrictEqual(c.expect);
    }
  });

  it('refreshApplyCases', () => {
    expect(cases.refreshApply.length).toBeGreaterThan(0);
    for (const c of cases.refreshApply) {
      expect(applyStudioPresetResponse(c.input), c.caseId).toStrictEqual(c.expect);
    }
  });
});
